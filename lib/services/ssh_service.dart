import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

import '../models/host.dart';
import '../models/known_host.dart';
import 'host_field_input.dart';
import 'host_key_policy.dart';
import 'jump_host_chain.dart';
import 'known_hosts_service.dart';
import 'login_prompt.dart';
import 'ssh_agent_backend.dart';
import 'ssh_agent_client.dart';

export 'host_key_policy.dart'
    show HostKeyPolicy, HostKeyPrompt, HostKeyPromptKind, HostKeyVerifier;
export 'jump_host_chain.dart'
    show JumpHostChain, JumpHostChainError, JumpHostChainException;
export 'login_prompt.dart'
    show
        LoginChallenge,
        LoginPrompt,
        LoginPromptField,
        LoginPromptHandler,
        ServerBanner,
        ServerBannerHandler;
export 'ssh_agent_backend.dart'
    show
        CredentialSSHAgent,
        MutableSSHAgentHandler,
        SSHAgentUnavailable,
        SSHAgentUnavailableReason;
export 'ssh_agent_client.dart'
    show
        SshAgentClient,
        SshAgentErrorKind,
        SshAgentException,
        SshAgentIdentity;

/// A connection failure with a message that is safe to show to a human.
class SshConnectionException implements Exception {
  const SshConnectionException(this.message, {this.details});

  /// Short, human-readable explanation, e.g. "Connection refused by host".
  final String message;

  /// Optional technical detail for a "show details" affordance.
  final String? details;

  @override
  String toString() => message;
}

/// Raised when the user declined the host key. Distinct from a generic failure
/// so the UI can say "you rejected the key" instead of "connection failed".
class HostKeyRejectedException extends SshConnectionException {
  const HostKeyRejectedException(super.message, {super.details});
}

/// Raised when the server rejected the credentials themselves.
///
/// A subclass rather than a flag, so every existing `on SshConnectionException`
/// site keeps catching it and keeps showing the same message it always did.
/// What the distinction buys is the automatic reconnect path: a dropped
/// network should be retried and a wrong password must not be, and telling
/// those apart by matching on a human-readable message string is exactly the
/// sort of thing that stops working the first time someone improves the
/// wording. See `reconnect_policy.dart`.
class SshAuthenticationException extends SshConnectionException {
  const SshAuthenticationException(super.message, {super.details});
}

/// Which leg of a jump-host connection went wrong.
///
/// The four are worth telling apart because they point at four different
/// things to go and fix, and because "the bastion is down" and "the box
/// behind the bastion is down" look identical from the banner otherwise.
enum JumpHostPhase {
  /// The jump host itself could not be reached from this device.
  unreachable,

  /// The jump host refused our credentials.
  authentication,

  /// The jump host's key was rejected or had changed.
  hostKey,

  /// The jump host was fine, but could not open a channel onward to the next
  /// hop — a firewall on the far side, or the target being down.
  targetUnreachable,
}

/// A failure on one of the jump hops rather than on the target itself.
///
/// Retryable, so it stays a plain [SshConnectionException]: a bastion that is
/// briefly unreachable is exactly the case auto-reconnect exists for. Jump
/// *authentication* failures are [JumpHostAuthException] instead, which is
/// not retryable — see [SshAuthenticationException].
class JumpHostException extends SshConnectionException {
  const JumpHostException(
    super.message, {
    required this.jumpHost,
    required this.phase,
    super.details,
  });

  /// The hop that failed, not the host the user asked to connect to.
  final Host jumpHost;

  final JumpHostPhase phase;
}

/// A jump host rejected our credentials.
///
/// Extends [SshAuthenticationException] so the reconnect schedule stops
/// instead of hammering a bastion with a password it has already refused —
/// the same reasoning as the target-side case, and the reason this is a
/// separate type from [JumpHostException] rather than a phase on it.
class JumpHostAuthException extends SshAuthenticationException {
  const JumpHostAuthException(
    super.message, {
    required this.jumpHost,
    super.details,
  });

  final Host jumpHost;

  JumpHostPhase get phase => JumpHostPhase.authentication;
}

/// Supplies the saved host record and credentials behind a `jumpHostId`.
///
/// Injected rather than reached for, because `SshService` sits below both
/// stores and must stay connectable in a test without either. When this is
/// absent, a host that names a jump host fails with a clear message instead
/// of quietly connecting direct — silently ignoring a configured bastion
/// would send traffic somewhere the user did not intend.
class JumpHostResolver {
  const JumpHostResolver({
    required this.lookupHost,
    required this.loadCredentials,
  });

  /// `HostStore.get` fits this.
  final Future<Host?> Function(String id) lookupHost;

  /// `CredentialStore.load` fits this.
  final Future<SshCredentials?> Function(String id) loadCredentials;
}

/// One authenticated hop a tunnelled session is riding on.
///
/// Held by the [SshConnection] at the far end so that closing the session
/// also tears down the bastions it was reached through; nothing else owns
/// them, and a leaked jump client keeps a TCP connection and a PTY-less SSH
/// session alive on the bastion until the process exits.
class SshJumpLink {
  const SshJumpLink({
    required this.host,
    required this.client,
    required this.socket,
  });

  final Host host;
  final SSHClient client;
  final SSHSocket socket;

  void close() {
    try {
      client.close();
    } catch (_) {
      // Already gone.
    }
    try {
      socket.destroy();
    } catch (_) {
      // Already gone.
    }
  }
}

/// The parts of a live connection a session needs.
///
/// Exists so `SessionController` can be exercised without a server: dartssh2's
/// `SSHClient` cannot be faked usefully, but this can. [SshConnection] is the
/// only production implementation.
abstract class SessionTransport {
  Host get host;

  /// Completes when the transport goes away for any reason.
  Future<void> get done;

  bool get isClosed;

  /// Opens an interactive shell with a PTY of the given size.
  Future<SSHSession> startShell({
    required int columns,
    required int rows,
    String terminalType,
  });

  /// Opens the SFTP subsystem on this same authenticated connection.
  Future<SftpClient> openSftp();

  /// Runs [command] on the remote side over a fresh exec channel.
  ///
  /// Every exec the app runs comes through here — the stats probe, the log
  /// tail, the service and process actions, the public-key push — so a
  /// connection has to serve as many of them as the session lives for. That
  /// is the whole reason an ordinary transport carries no [agentSlot]:
  /// dartssh2 sends `auth-agent-req@openssh.com` on *every* session channel
  /// a client with an agent handler opens, and throws if the server refuses
  /// it. OpenSSH grants that request once per connection, so a client born
  /// with a handler runs exactly one exec and then fails every later one.
  ///
  /// The direct server-to-server copy is the one feature that does need
  /// forwarding, and it dials a connection of its own for its single exec
  /// rather than borrowing this one. See `direct_remote_copy.dart` and
  /// [SessionTransport.agentSlot].
  Future<SSHSession> execute(String command) =>
      throw UnimplementedError('This transport does not support exec.');

  /// The swappable agent handler wired into this connection's SSH client, or
  /// null — the ordinary case — when the client was built without one.
  ///
  /// Only the short-lived connection a direct transfer dials for its one
  /// exec has a slot, because carrying a handler costs the connection every
  /// exec after the first (see [execute]). On that connection the transfer
  /// plugs in a [CredentialSSHAgent] with [MutableSSHAgentHandler.install],
  /// runs its exec, and calls the returned release. No identity is ever
  /// reachable from the session's own connection, and none persists past the
  /// transfer that installed it.
  MutableSSHAgentHandler? get agentSlot => null;

  /// Sends one keep-alive and waits for the server's reply.
  ///
  /// Driven by `SessionKeepalive` rather than by dartssh2's own timer — see
  /// that class, and [SshService.connect], for why the schedule lives up here.
  Future<void> ping();

  void close();
}

/// A live, authenticated SSH connection plus the host it belongs to.
/// The host key a handshake presented, once the trust store accepted it.
class VerifiedHostKey {
  const VerifiedHostKey({required this.keyType, required this.fingerprint});

  /// Canonical key type — see [KnownHostKey.canonicalKeyType].
  final String keyType;

  /// OpenSSH-style `SHA256:...` fingerprint.
  final String fingerprint;
}

class SshConnection implements SessionTransport {
  SshConnection({
    required this.client,
    required this.host,
    required this.socket,
    this.agentSlot,
    this.jumpLinks = const [],
    this.hostKey,
  });

  final SSHClient client;

  /// The jump hosts this connection is tunnelled through, in dial order
  /// (the hop nearest this device first). Empty for a direct connection.
  ///
  /// Nothing reads these except [close]; they exist so the chain dies with
  /// the session. A jump link dropping on its own does not need handling
  /// here — the forwarded channel carrying this connection dies with it, so
  /// [done] completes and the ordinary reconnect path re-dials the whole
  /// chain from the start.
  final List<SshJumpLink> jumpLinks;

  @override
  final Host host;

  final SSHSocket socket;

  /// The agent slot handed to [SSHClient.agentHandler] at construction, or
  /// null on every connection not dialled with `agentForwarding: true` —
  /// which is all of them bar the one a direct transfer opens for its single
  /// exec. The direct copy path installs a per-transfer [CredentialSSHAgent]
  /// into it and clears it again when the exec ends.
  @override
  final MutableSSHAgentHandler? agentSlot;

  /// The host key this connection's handshake presented and the user's trust
  /// store accepted. Null only for a connection built outside
  /// [SshService.connect].
  ///
  /// A direct server-to-server copy pins the source's `sftp` to exactly this
  /// key, so the source accepts the destination only if it is the machine
  /// this device has verified — see `direct_remote_copy.dart`.
  final VerifiedHostKey? hostKey;

  @override
  bool get isClosed => client.isClosed;

  @override
  Future<void> get done => client.done;

  /// The SFTP subsystem runs as a second channel on this already-authenticated
  /// connection — no second login, no second host-key prompt.
  @override
  Future<SftpClient> openSftp() => client.sftp();

  /// `keepalive@openssh.com` as a global request, with `want_reply` set, so
  /// the round trip proves the *server* is still there and not merely that the
  /// local socket has not noticed yet.
  @override
  Future<void> ping() => client.ping();

  /// Runs [command] over a fresh exec channel.
  ///
  /// dartssh2 adds an `auth-agent-req@openssh.com` request to this channel
  /// if and only if the client was built with an agent handler — so on an
  /// ordinary connection ([agentSlot] null) this is repeatable for the life
  /// of the session, and on a transfer's own connection the source server's
  /// `sftp` gets a path back to whatever key the caller installed just
  /// before this call. See [SessionTransport.execute].
  @override
  Future<SSHSession> execute(String command) => client.execute(command);

  @override
  Future<SSHSession> startShell({
    required int columns,
    required int rows,
    String terminalType = 'xterm-256color',
  }) {
    return client.shell(
      pty: SSHPtyConfig(
        type: terminalType,
        width: columns > 0 ? columns : 80,
        height: rows > 0 ? rows : 24,
      ),
    );
  }

  @override
  void close() {
    try {
      client.close();
    } catch (_) {
      // Already gone.
    }
    try {
      socket.destroy();
    } catch (_) {
      // Already gone.
    }
    // Innermost first: closing a bastion would tear down the forwarded
    // channel the hop above it is riding on, so unwinding the other way
    // turns an orderly shutdown into a cascade of transport errors.
    for (final link in jumpLinks.reversed) {
      link.close();
    }
  }
}

/// Establishes SSH connections with OpenSSH-style host key verification.
class SshService {
  SshService({required this.knownHosts, this.jumpHosts})
      : policy = HostKeyPolicy(knownHosts);

  final KnownHostsService knownHosts;

  /// How a `jumpHostId` is turned into a host record and its credentials.
  /// Null in tests and anywhere jump hosts are not wired; a host that names
  /// one then fails with a clear message rather than connecting direct.
  final JumpHostResolver? jumpHosts;

  /// Decides what to do about each host key the server presents.
  final HostKeyPolicy policy;

  static const Duration defaultTimeout = Duration(seconds: 20);

  /// Extra head-room on the handshake timer to cover the host key dialog.
  ///
  /// dartssh2 starts its handshake timer when the client is constructed and
  /// only cancels it once the transport is ready — which is *after* our
  /// `onVerifyHostKey` callback returns. Since that callback blocks on a human
  /// comparing a fingerprint against an out-of-band source, a plain 20s
  /// handshake timeout would kill the connection under a user who is doing
  /// exactly the careful thing we asked them to do. The socket-level timeout
  /// still catches unreachable hosts, so nothing is lost by being generous
  /// here.
  static const Duration hostKeyDecisionBudget = Duration(minutes: 5);

  /// How long the server gets to come back after a person answers a login
  /// prompt.
  ///
  /// Far longer than [defaultTimeout], because an answer is often the start
  /// of a wait rather than the end of one: choosing "Duo Push" sends the
  /// server off to wait for a phone, and it replies only once the person
  /// has approved the login there. The time a prompt spends on screen is not
  /// counted at all — see [_LoginDeadline] — so this is only the server's
  /// share.
  static const Duration loginReplyBudget = Duration(minutes: 2);

  /// Connects, verifies the host key, and authenticates.
  ///
  /// When [host] names a jump host, every hop in the chain is dialled and
  /// authenticated first, in order, and this host's SSH session then runs
  /// over a `direct-tcpip` channel opened by the last hop. Every hop's host
  /// key goes through the same [policy] as the target's — there is no
  /// "trust the bastion implicitly" shortcut.
  ///
  /// Throws [SshConnectionException] (or [HostKeyRejectedException]) with a
  /// human-readable message on every failure path; failures that happened on
  /// a hop rather than on [host] are [JumpHostException] or
  /// [JumpHostAuthException], which name the hop.
  ///
  /// [agentForwarding] gives the connection an [SshConnection.agentSlot], and
  /// with it the ability to carry `auth-agent-req@openssh.com`. It is off by
  /// default and exactly one caller turns it on — the direct server-to-server
  /// copy, for the one connection it dials per transfer. A connection that
  /// carries a handler can only ever run *one* exec, so this is never right
  /// for a session the user is going to keep working in; see
  /// [SessionTransport.execute].
  ///
  /// [answerPrompts] is how a keyboard-interactive question — a one-time
  /// code, a Duo menu, a password the server will only take this way —
  /// reaches a person, for the target and for every hop alike; each
  /// [LoginPrompt] names the host asking. A password host's saved password
  /// answers the first plain password question by itself, so a server that
  /// only offers keyboard-interactive needs nobody (see
  /// [KeyboardInteractiveResponder]). Leave it null when no one is there to
  /// ask — a reconnect, a background transfer: a question the saved
  /// credentials cannot answer then fails the connect at once with an
  /// [SshAuthenticationException] that says what was asked, instead of
  /// waiting on an answer that will never come.
  ///
  /// [onBanner] receives the text a server shows before login, already
  /// stripped down to plain text, from the target and from every hop.
  Future<SshConnection> connect({
    required Host host,
    required SshCredentials credentials,
    required HostKeyVerifier verifyHostKey,
    LoginPromptHandler? answerPrompts,
    ServerBannerHandler? onBanner,
    Duration timeout = defaultTimeout,
    bool agentForwarding = false,
  }) async {
    // Resolved before any socket is opened, so a self-reference or a loop
    // costs nothing and cannot recurse.
    final hops = await _resolveHops(host);

    // Likewise the target's own credentials: an empty password or an
    // undecodable key is a question for the user, and asking it after
    // dialling every bastion in the chain would be both slow and rude.
    final identities = await _prepareIdentities(host, credentials);

    final links = <SshJumpLink>[];
    try {
      final socket = await _openSocket(
        target: host,
        hops: hops,
        links: links,
        verifyHostKey: verifyHostKey,
        answerPrompts: answerPrompts,
        onBanner: onBanner,
        timeout: timeout,
      );
      return await _login(
        host: host,
        credentials: credentials,
        identities: identities,
        socket: socket,
        redial: () => hops.isEmpty
            ? _openDirectSocket(host, timeout)
            : _openForwardedSocket(
                through: links.last,
                to: host,
                timeout: timeout,
              ),
        verifyHostKey: verifyHostKey,
        answerPrompts: answerPrompts,
        onBanner: onBanner,
        timeout: timeout,
        jumpLinks: List.unmodifiable(links),
        agentForwarding: agentForwarding,
      );
    } catch (_) {
      // Any hop already standing is ours to tear down — nothing else has a
      // reference to it yet, so leaving them open would leak a live SSH
      // connection per failed attempt, and reconnect retries in a loop.
      for (final link in links.reversed) {
        link.close();
      }
      rethrow;
    }
  }

  /// The jump chain for [host], or empty for a direct connection.
  Future<List<Host>> _resolveHops(Host host) async {
    if (host.jumpHostId == null) return const [];

    final resolver = jumpHosts;
    if (resolver == null) {
      throw SshConnectionException(
        '"${host.displayName}" is set to connect via a jump host, but jump '
        'hosts are not available here.',
      );
    }

    try {
      return await JumpHostChain.resolve(
        host: host,
        lookup: resolver.lookupHost,
      );
    } on JumpHostChainException catch (e) {
      // Already phrased for a human, and always a configuration problem
      // rather than a transport one.
      throw SshConnectionException(e.message);
    }
  }

  /// Opens the socket [host] itself will be spoken to over: a plain TCP
  /// connection when there are no [hops], otherwise a forwarded channel from
  /// the last hop. Authenticated hops are appended to [links] as they come
  /// up so the caller can close them on failure.
  Future<SSHSocket> _openSocket({
    required Host target,
    required List<Host> hops,
    required List<SshJumpLink> links,
    required HostKeyVerifier verifyHostKey,
    required LoginPromptHandler? answerPrompts,
    required ServerBannerHandler? onBanner,
    required Duration timeout,
  }) async {
    if (hops.isEmpty) return _openDirectSocket(target, timeout);

    for (var i = 0; i < hops.length; i++) {
      final hop = hops[i];
      // The first hop is the only one this device dials itself; every
      // later one is reached through the tunnel built so far.
      final through = i == 0 ? null : links.last;
      Future<SSHSocket> dial() => through == null
          ? _openDirectSocket(hop, timeout, asJumpHost: true)
          : _openForwardedSocket(through: through, to: hop, timeout: timeout);
      links.add(
        await _authenticateHop(
          hop: hop,
          target: target,
          socket: await dial(),
          redial: dial,
          verifyHostKey: verifyHostKey,
          answerPrompts: answerPrompts,
          onBanner: onBanner,
          timeout: timeout,
        ),
      );
    }

    return _openForwardedSocket(
      through: links.last,
      to: target,
      timeout: timeout,
    );
  }

  /// A plain TCP connection to [host].
  Future<SSHSocket> _openDirectSocket(
    Host host,
    Duration timeout, {
    bool asJumpHost = false,
  }) async {
    try {
      return await SSHSocket.connect(host.hostname, host.port,
          timeout: timeout);
    } on SocketException catch (e) {
      throw _reachError(host, describeSocketError(e, host), e, asJumpHost);
    } on TimeoutException catch (e) {
      throw _reachError(
        host,
        'Timed out connecting to ${host.hostname}:${host.port}. '
        'Check the address, the port, and that you are on the right network.',
        e,
        asJumpHost,
      );
    } catch (e) {
      throw _reachError(
        host,
        'Could not reach ${host.hostname}:${host.port}.',
        e,
        asJumpHost,
      );
    }
  }

  SshConnectionException _reachError(
    Host host,
    String message,
    Object error,
    bool asJumpHost,
  ) {
    if (!asJumpHost) {
      return SshConnectionException(message, details: error.toString());
    }
    return JumpHostException(
      'Could not reach the jump host "${host.displayName}" '
      '(${host.hostname}:${host.port}). $message',
      jumpHost: host,
      phase: JumpHostPhase.unreachable,
      details: error.toString(),
    );
  }

  /// Asks [through] to open a `direct-tcpip` channel to [to], and dresses the
  /// resulting channel up as the socket the next SSH client will speak over.
  ///
  /// This is the whole of the ProxyJump mechanism: dartssh2's
  /// [SSHForwardChannel] already implements [SSHSocket], so a forwarded
  /// channel can be handed to [SSHClient] anywhere a real socket goes, and
  /// the next hop's handshake, host key check and auth all run inside the
  /// previous hop's encrypted session.
  Future<SSHSocket> _openForwardedSocket({
    required SshJumpLink through,
    required Host to,
    required Duration timeout,
  }) async {
    try {
      return await through.client
          .forwardLocal(to.hostname, to.port)
          .timeout(timeout);
    } catch (e) {
      throw JumpHostException(
        'The jump host "${through.host.displayName}" could not open a '
        'connection to ${to.hostname}:${to.port}. The target may be down, or '
        'the jump host may not be allowed to reach it.',
        jumpHost: through.host,
        phase: JumpHostPhase.targetUnreachable,
        details: e.toString(),
      );
    }
  }

  /// Authenticates one jump hop, using that hop's own saved credentials and
  /// its own host key check. Its login prompts name it, and [target] as the
  /// host it is the way to.
  Future<SshJumpLink> _authenticateHop({
    required Host hop,
    required Host target,
    required SSHSocket socket,
    required Future<SSHSocket> Function() redial,
    required HostKeyVerifier verifyHostKey,
    required LoginPromptHandler? answerPrompts,
    required ServerBannerHandler? onBanner,
    required Duration timeout,
  }) async {
    final resolver = jumpHosts!;
    final credentials = await resolver.loadCredentials(hop.id);
    if (credentials == null) {
      socket.destroy();
      throw JumpHostAuthException(
        'No saved credentials for the jump host "${hop.displayName}". Open it '
        'in the host editor and save its password or key first.',
        jumpHost: hop,
      );
    }

    try {
      final connection = await _login(
        host: hop,
        jumpHostFor: target,
        credentials: credentials,
        // The hop's socket is already open by now — unavoidable, since the
        // channel it rides on is what proves the previous hop can reach it —
        // so anything unusable here has to take the socket down with it.
        identities: await _prepareIdentitiesOrClose(hop, credentials, socket),
        socket: socket,
        redial: redial,
        verifyHostKey: verifyHostKey,
        answerPrompts: answerPrompts,
        onBanner: onBanner,
        timeout: timeout,
        jumpLinks: const [],
      );
      return SshJumpLink(
        host: hop,
        client: connection.client,
        socket: connection.socket,
      );
    } on JumpHostException {
      // Only a redial (see [_login]) can raise one in here, and it already
      // names the hop that could not be reached.
      rethrow;
    } on HostKeyRejectedException catch (e) {
      throw JumpHostException(
        'The host key for the jump host "${hop.displayName}" was not '
        'trusted. ${e.message}',
        jumpHost: hop,
        phase: JumpHostPhase.hostKey,
        details: e.details,
      );
    } on SshAuthenticationException catch (e) {
      throw JumpHostAuthException(
        'Authentication failed on the jump host "${hop.displayName}". '
        '${e.message}',
        jumpHost: hop,
        details: e.details,
      );
    } on SshConnectionException catch (e) {
      throw JumpHostException(
        'The jump host "${hop.displayName}" could not be used. ${e.message}',
        jumpHost: hop,
        phase: JumpHostPhase.unreachable,
        details: e.details,
      );
    }
  }

  /// [_authenticate], with one more go when the server turned down the saved
  /// password and a person is there to type the right one.
  ///
  /// The second go needs a fresh socket from [redial]: OpenSSH ends a
  /// keyboard-interactive exchange with a failure as soon as PAM says no,
  /// and dartssh2 tries each method once per connection, so there is no
  /// asking again on the same one. The host key was trusted moments ago, so
  /// the second handshake matches it silently.
  Future<SshConnection> _login({
    required Host host,
    required SshCredentials credentials,
    required List<SSHKeyPair>? identities,
    required SSHSocket socket,
    required Future<SSHSocket> Function() redial,
    required HostKeyVerifier verifyHostKey,
    required LoginPromptHandler? answerPrompts,
    required ServerBannerHandler? onBanner,
    required Duration timeout,
    required List<SshJumpLink> jumpLinks,
    Host? jumpHostFor,
    bool agentForwarding = false,
  }) async {
    // A server sends its banner on every connection, and the user should
    // see it once per connect, not once per socket.
    final bannersShown = <String>{};
    void showBanner(String text) {
      if (!bannersShown.add(text)) return;
      onBanner?.call(
        ServerBanner(host: host, jumpHostFor: jumpHostFor, text: text),
      );
    }

    Future<SshConnection> attempt(
      SSHSocket socket, {
      required bool savedPasswordRejected,
    }) {
      return _authenticate(
        host: host,
        credentials: credentials,
        identities: identities,
        socket: socket,
        verifyHostKey: verifyHostKey,
        answerPrompts: answerPrompts,
        showBanner: showBanner,
        timeout: timeout,
        jumpLinks: jumpLinks,
        jumpHostFor: jumpHostFor,
        savedPasswordRejected: savedPasswordRejected,
        agentForwarding: agentForwarding,
      );
    }

    try {
      return await attempt(socket, savedPasswordRejected: false);
    } on _SavedPasswordRejected {
      // Cannot recur: with savedPasswordRejected set, the saved password is
      // never sent, so it cannot be what the server refuses.
      return attempt(await redial(), savedPasswordRejected: true);
    }
  }

  /// Runs the SSH handshake and authentication for [host] over an already
  /// open [socket], whichever kind it is.
  Future<SshConnection> _authenticate({
    required Host host,
    required SshCredentials credentials,
    required List<SSHKeyPair>? identities,
    required SSHSocket socket,
    required HostKeyVerifier verifyHostKey,
    required LoginPromptHandler? answerPrompts,
    required void Function(String text) showBanner,
    required Duration timeout,
    required List<SshJumpLink> jumpLinks,
    required Host? jumpHostFor,
    required bool savedPasswordRejected,
    bool agentForwarding = false,
  }) async {
    // Set by the verify handler so we can distinguish "user said no" from a
    // genuine handshake failure once the client surfaces the error.
    var userRejectedKey = false;
    VerifiedHostKey? verifiedKey;

    // Null unless the caller asked for forwarding, and the difference is not
    // cosmetic: dartssh2 decides per *client* whether to put an
    // `auth-agent-req@openssh.com` on every session channel it opens, and
    // OpenSSH answers that request once per connection. A session that keeps
    // a handler therefore loses every exec after its first — which is the
    // stats poll, the log tail, the service actions and the key push. So the
    // handler goes on the connection that needs it and nowhere else.
    //
    // When there is a slot it starts empty, and empty replies to sign
    // requests with SSH_AGENT_FAILURE — what OpenSSH reads as "no key here".
    // A forward that reaches us before the transfer installs its key is
    // refused rather than answered with something we did not mean to hand
    // out.
    final agentSlot = agentForwarding ? MutableSSHAgentHandler() : null;

    // Completes when the login is over either way, so a prompt still on
    // screen when the server hangs up can close itself.
    final loginOver = Completer<void>();

    late final SSHClient client;
    final deadline = _LoginDeadline(() => client.close());

    final usesPassword = host.authMethod == SshAuthMethod.password;
    final responder = KeyboardInteractiveResponder(
      host: host,
      jumpHostFor: jumpHostFor,
      savedPassword: usesPassword ? credentials.password : null,
      savedPasswordRejected: savedPasswordRejected,
      withdrawn: loginOver.future,
      ask: answerPrompts == null
          ? null
          : (prompt) async {
              // The clock stops while a person reads and types, and restarts
              // with room for whatever their answer sets off on the server.
              deadline.hold();
              try {
                return await answerPrompts(prompt);
              } finally {
                deadline.arm(loginReplyBudget);
              }
            },
    );

    // Everything the server said before login, for the error message if the
    // login then fails.
    final banners = <String>[];

    client = SSHClient(
      socket,
      username: host.username,
      identities: identities,
      agentHandler: agentSlot,
      // Not offered again once the server has refused it — see [_login].
      onPasswordRequest: usesPassword && !savedPasswordRejected
          ? () => credentials.password
          : null,
      // Set for every host, key hosts included: `AuthenticationMethods
      // publickey,keyboard-interactive` accepts the key only as the first
      // of two factors, and dartssh2 cannot tell that from a refusal, so the
      // only way to reach the second is to always be ready for it.
      onUserInfoRequest: (request) => responder.respond(
        LoginChallenge.fromServer(
          name: request.name,
          instruction: request.instruction,
          prompts: [
            for (final prompt in request.prompts)
              (text: prompt.promptText, echo: prompt.echo),
          ],
        ),
      ),
      onUserauthBanner: (raw) {
        final text = cleanServerText(raw);
        if (text.isEmpty) return;
        banners.add(text);
        showBanner(text);
      },
      onVerifyHostKey: (type, fingerprintBytes) async {
        final fingerprint = HostKeyPolicy.decodeFingerprint(fingerprintBytes);
        final accepted = await policy.evaluate(
          hostname: host.hostname,
          port: host.port,
          keyType: type,
          fingerprint: fingerprint,
          verify: verifyHostKey,
        );
        if (accepted) {
          verifiedKey = VerifiedHostKey(
            keyType: KnownHostKey.canonicalKeyType(type),
            fingerprint: fingerprint,
          );
          // dartssh2 calls the transport ready the moment this returns true
          // and starts authenticating there, so the login clock starts here.
          deadline.arm(timeout);
        } else {
          userRejectedKey = true;
        }
        return accepted;
      },
      handshakeTimeout: timeout + hostKeyDecisionBudget,
      // Kept by [deadline] instead: dartssh2's timer runs on while a prompt
      // is on screen, and would cut off someone reading a code off their
      // phone.
      authTimeout: null,
      // dartssh2's own 10 s keep-alive timer is switched off; the session
      // owns the schedule instead, at SessionKeepalive.interval. One owner
      // rather than two, a gentler interval on a phone radio, and — the part
      // that actually matters — a guard that recovers when a ping goes
      // unanswered rather than latching keep-alives off forever. See
      // session_keepalive.dart.
      keepAliveInterval: null,
    );

    try {
      await client.authenticated;
    } catch (e) {
      client.close();
      socket.destroy();
      if (userRejectedKey) {
        throw const HostKeyRejectedException(
          'Connection cancelled: the server\'s host key was not trusted.',
        );
      }
      if (e is SSHAuthFailError &&
          answerPrompts != null &&
          responder.lastAnswerWasSavedPassword) {
        throw const _SavedPasswordRejected();
      }
      throw _loginFailure(
        e,
        host: host,
        responder: responder,
        timedOut: deadline.expired,
        serverText: [...banners, ...responder.notices],
      );
    } finally {
      deadline.finish();
      if (!loginOver.isCompleted) loginOver.complete();
    }

    return SshConnection(
      client: client,
      host: host,
      socket: socket,
      agentSlot: agentSlot,
      jumpLinks: jumpLinks,
      hostKey: verifiedKey,
    );
  }

  /// The exception a failed login surfaces as.
  ///
  /// Everything that comes down to the credentials — refused, cancelled, or
  /// needing a person who is not there — is an [SshAuthenticationException],
  /// which the reconnect schedule never retries. Anything the server said
  /// along the way rides in `details`: a denial from a second factor ("Login
  /// request denied") arrives as exactly that kind of text, and is usually
  /// the only useful thing about the failure.
  SshConnectionException _loginFailure(
    Object error, {
    required Host host,
    required KeyboardInteractiveResponder responder,
    required bool timedOut,
    required List<String> serverText,
  }) {
    final details = serverText.isEmpty
        ? error.toString()
        : 'The server said:\n${serverText.join('\n\n')}\n\n$error';

    if (timedOut) {
      return SshConnectionException(
        'The server stopped responding during login.',
        details: details,
      );
    }
    if (error is! SSHAuthFailError) {
      return SshConnectionException(
        _describeSshError(error, host),
        details: details,
      );
    }
    if (responder.cancelled) {
      return SshAuthenticationException(
        'Connection cancelled: the login prompt from "${host.displayName}" '
        'was not answered.',
        details: details,
      );
    }
    final unanswered = responder.unansweredPrompt;
    if (unanswered != null) {
      final asked = unanswered.label.isEmpty
          ? 'a question'
          : '"${_shorten(unanswered.label, 60)}"';
      return SshAuthenticationException(
        '"${host.displayName}" asks $asked at login, which needs you to '
        'answer it, and nobody was asked here. Connect to it from the host '
        'list to log in.',
        details: details,
      );
    }
    if (responder.personAnswered) {
      return SshAuthenticationException(
        'Authentication failed for "${host.username}". The server did not '
        'accept the answers to its login prompts.',
        details: details,
      );
    }
    return SshAuthenticationException(
      _describeSshError(error, host),
      details: details,
    );
  }

  static String _shorten(String text, int max) =>
      text.length <= max ? text : '${text.substring(0, max - 1)}…';

  /// Fails an agent-auth host with the most specific reason available.
  ///
  /// Always throws. The agent is probed first so the common, fixable cases —
  /// no agent running, agent running but empty — are what the user is told
  /// about, rather than the deeper limitation below them.
  Future<Never> _failAgentAuth(Host host) async {
    if (!SshAgentClient.isSupportedPlatform) {
      throw SshConnectionException(
        'No SSH agent found. "${host.displayName}" is set to use the OS SSH '
        'agent, which this device does not have. Edit the host and choose a '
        'password or a private key instead.',
      );
    }

    try {
      await SshAgentClient().listIdentities();
    } on SshAgentException catch (e) {
      throw SshConnectionException(e.message, details: e.details);
    }

    // The agent is reachable and holding keys, and we still cannot use it:
    // dartssh2's `SSHKeyPair.sign` is synchronous, so an identity backed by
    // a socket round-trip cannot satisfy it, and the types its interface
    // returns are not exported to implement in the first place. Signing is
    // ready (see `ssh_agent_client.dart`, which is complete and tested) —
    // the missing piece is entirely on the dartssh2 side.
    throw SshConnectionException(
      'The SSH agent is available, but this build cannot yet authenticate '
      'with it. Use a password or a private key for '
      '"${host.displayName}".',
    );
  }

  /// [_prepareIdentities], destroying [socket] if it throws.
  Future<List<SSHKeyPair>?> _prepareIdentitiesOrClose(
    Host host,
    SshCredentials credentials,
    SSHSocket socket,
  ) async {
    try {
      return await _prepareIdentities(host, credentials);
    } catch (_) {
      socket.destroy();
      rethrow;
    }
  }

  /// Turns [credentials] into the identities [host] will authenticate with,
  /// failing on anything unusable.
  ///
  /// Deliberately does no I/O of its own beyond probing the agent, so every
  /// caller can run it *before* opening a socket — that ordering is what
  /// keeps "you did not type a password" from arriving as a connection error
  /// several seconds and several handshakes later.
  Future<List<SSHKeyPair>?> _prepareIdentities(
    Host host,
    SshCredentials credentials,
  ) async {
    switch (host.authMethod) {
      case SshAuthMethod.agent:
        await _failAgentAuth(host);
      case SshAuthMethod.password:
        if (credentials.password == null || credentials.password!.isEmpty) {
          throw const SshConnectionException('Enter a password to connect.');
        }
        return null;
      case SshAuthMethod.privateKey:
        return _parseIdentities(credentials);
    }
  }

  List<SSHKeyPair> _parseIdentities(SshCredentials credentials) {
    final pem = credentials.privateKeyPem?.trim();
    if (pem == null || pem.isEmpty) {
      throw const SshConnectionException('Paste a private key to connect.');
    }

    final passphrase = credentials.passphrase?.isEmpty ?? true
        ? null
        : credentials.passphrase;

    bool encrypted;
    try {
      encrypted = SSHKeyPair.isEncryptedPem(pem);
    } on FormatException catch (e) {
      throw SshConnectionException(
        'That does not look like a private key. Paste the whole file, '
        'including the BEGIN and END lines.',
        details: e.toString(),
      );
    } on UnsupportedError catch (e) {
      throw SshConnectionException(
        'Unsupported private key format. Use an OpenSSH or PEM key '
        '(RSA, ECDSA or ed25519).',
        details: e.toString(),
      );
    } catch (e) {
      throw SshConnectionException(
        'The private key could not be read.',
        details: e.toString(),
      );
    }

    if (encrypted && passphrase == null) {
      throw const SshConnectionException(
        'This private key is passphrase-protected. Enter its passphrase.',
      );
    }

    try {
      final pairs = SSHKeyPair.fromPem(pem, passphrase);
      if (pairs.isEmpty) {
        throw const SshConnectionException(
          'No usable key was found in that private key file.',
        );
      }
      return pairs;
    } on SshConnectionException {
      rethrow;
    } on SSHKeyDecodeError catch (e) {
      throw SshConnectionException(
        encrypted
            ? 'Could not decrypt the private key. Check the passphrase.'
            : 'The private key could not be decoded.',
        details: e.toString(),
      );
    } catch (e) {
      throw SshConnectionException(
        encrypted
            ? 'Could not decrypt the private key. Check the passphrase.'
            : 'The private key could not be decoded.',
        details: e.toString(),
      );
    }
  }

  String _describeSshError(Object error, Host host) {
    if (error is SSHAuthFailError) {
      return host.authMethod == SshAuthMethod.password
          ? 'Authentication failed for "${host.username}". '
              'Check the username and password.'
          : 'Authentication failed for "${host.username}". The server rejected '
              'this key — make sure its public half is in the account\'s '
              'authorized_keys.';
    }
    if (error is SSHAuthAbortError) {
      return 'Authentication was interrupted: ${error.message}';
    }
    if (error is SSHHandshakeError) {
      return 'SSH handshake failed: ${error.message}';
    }
    if (error is SSHKeyDecodeError) {
      return 'The private key could not be decoded. Check the passphrase.';
    }
    if (error is SSHStateError || error is SSHPacketError) {
      return 'The server sent something unexpected. It may not be an SSH '
          'server, or the connection was interrupted.';
    }
    if (error is TimeoutException) {
      return 'The server stopped responding during the SSH handshake.';
    }
    if (error is SocketException) {
      return describeSocketError(error, host);
    }
    return 'Could not establish an SSH session with ${host.hostname}.';
  }
}

/// Thrown by [SshService._authenticate] when the server refused the saved
/// password inside keyboard-interactive and a person is on hand to type the
/// right one. Never escapes [SshService._login], which redials and asks.
class _SavedPasswordRejected implements Exception {
  const _SavedPasswordRejected();
}

/// The authentication timeout, kept by [SshService] rather than handed to
/// dartssh2, because it has to stop while a person is answering a login
/// prompt and dartssh2's runs on regardless.
class _LoginDeadline {
  _LoginDeadline(this._onExpired);

  final void Function() _onExpired;
  Timer? _timer;
  var _finished = false;

  /// Whether the clock ran out, as opposed to the login ending some other
  /// way.
  bool get expired => _expired;
  var _expired = false;

  /// Starts the clock afresh with [budget] to go.
  void arm(Duration budget) {
    if (_finished) return;
    _timer?.cancel();
    _timer = Timer(budget, () {
      _finished = true;
      _expired = true;
      _onExpired();
    });
  }

  /// Stops the clock until the next [arm]: a person is answering.
  void hold() => _timer?.cancel();

  /// The login is over, and nothing restarts the clock.
  void finish() {
    _finished = true;
    _timer?.cancel();
  }
}

/// Turns a [SocketException] into a line fit to put in front of a person.
///
/// A free function rather than a method on [SshService], for the same reason
/// `mapSecureStorageWriteError` is one: it is a pure mapping from an
/// exception to a sentence, and it can then be tested by handing it a
/// hand-made exception rather than by arranging for a real socket to fail in
/// six different ways.
String describeSocketError(SocketException e, Host host) {
  final code = e.osError?.errorCode;
  final message = (e.osError?.message ?? e.message).toLowerCase();

  if (message.contains('failed host lookup') ||
      message.contains('name or service not known') ||
      message.contains('nodename nor servname')) {
    // A hostname with a port or a username baked into it is the one cause of
    // this the app can identify, and "check the spelling" is the wrong thing
    // to tell someone whose spelling is fine and whose address is already an
    // IP. See `host_field_input.dart`.
    final misplaced = misplacedHostFieldAdvice(host.hostname);
    if (misplaced != null) return misplaced;
    return 'Could not find a host called "${host.hostname}". '
        'Check the spelling, or use its IP address.';
  }
  if (code == 111 || message.contains('connection refused')) {
    return 'Connection refused by ${host.hostname} on port ${host.port}. '
        'Is the SSH server running and is that the right port?';
  }
  if (code == 113 || message.contains('no route to host')) {
    return 'No route to ${host.hostname}. The host is unreachable from this '
        'network.';
  }
  if (code == 101 || message.contains('network is unreachable')) {
    return 'The network is unreachable. Check your Wi-Fi or mobile data.';
  }
  if (code == 110 || message.contains('timed out')) {
    return 'Timed out connecting to ${host.hostname}:${host.port}. '
        'A firewall may be dropping the connection.';
  }
  return 'Could not connect to ${host.hostname}:${host.port}.';
}
