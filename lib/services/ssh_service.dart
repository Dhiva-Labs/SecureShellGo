import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

import '../models/host.dart';
import 'host_key_policy.dart';
import 'known_hosts_service.dart';

export 'host_key_policy.dart'
    show HostKeyPolicy, HostKeyPrompt, HostKeyPromptKind, HostKeyVerifier;

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

  /// Sends one keep-alive and waits for the server's reply.
  ///
  /// Driven by `SessionKeepalive` rather than by dartssh2's own timer — see
  /// that class, and [SshService.connect], for why the schedule lives up here.
  Future<void> ping();

  void close();
}

/// A live, authenticated SSH connection plus the host it belongs to.
class SshConnection implements SessionTransport {
  SshConnection({
    required this.client,
    required this.host,
    required this.socket,
  });

  final SSHClient client;

  @override
  final Host host;

  final SSHSocket socket;

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
  }
}

/// Establishes SSH connections with OpenSSH-style host key verification.
class SshService {
  SshService({required this.knownHosts})
      : policy = HostKeyPolicy(knownHosts);

  final KnownHostsService knownHosts;

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

  /// Connects, verifies the host key, and authenticates.
  ///
  /// Throws [SshConnectionException] (or [HostKeyRejectedException]) with a
  /// human-readable message on every failure path.
  Future<SshConnection> connect({
    required Host host,
    required SshCredentials credentials,
    required HostKeyVerifier verifyHostKey,
    Duration timeout = defaultTimeout,
  }) async {
    final identities = host.authMethod == SshAuthMethod.privateKey
        ? _parseIdentities(credentials)
        : null;

    if (host.authMethod == SshAuthMethod.password &&
        (credentials.password == null || credentials.password!.isEmpty)) {
      throw const SshConnectionException('Enter a password to connect.');
    }

    final SSHSocket socket;
    try {
      socket = await SSHSocket.connect(
        host.hostname,
        host.port,
        timeout: timeout,
      );
    } on SocketException catch (e) {
      throw SshConnectionException(
        _describeSocketError(e, host),
        details: e.toString(),
      );
    } on TimeoutException catch (e) {
      throw SshConnectionException(
        'Timed out connecting to ${host.hostname}:${host.port}. '
        'Check the address, the port, and that you are on the right network.',
        details: e.toString(),
      );
    } catch (e) {
      throw SshConnectionException(
        'Could not reach ${host.hostname}:${host.port}.',
        details: e.toString(),
      );
    }

    // Set by the verify handler so we can distinguish "user said no" from a
    // genuine handshake failure once the client surfaces the error.
    var userRejectedKey = false;

    final client = SSHClient(
      socket,
      username: host.username,
      identities: identities,
      onPasswordRequest: host.authMethod == SshAuthMethod.password
          ? () => credentials.password
          : null,
      onVerifyHostKey: (type, fingerprintBytes) async {
        final accepted = await policy.evaluate(
          hostname: host.hostname,
          port: host.port,
          keyType: type,
          fingerprint: HostKeyPolicy.decodeFingerprint(fingerprintBytes),
          verify: verifyHostKey,
        );
        if (!accepted) userRejectedKey = true;
        return accepted;
      },
      handshakeTimeout: timeout + hostKeyDecisionBudget,
      // No human is in the loop during auth, so keep this tight.
      authTimeout: timeout,
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
      throw SshConnectionException(
        _describeSshError(e, host),
        details: e.toString(),
      );
    }

    return SshConnection(client: client, host: host, socket: socket);
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

  String _describeSocketError(SocketException e, Host host) {
    final code = e.osError?.errorCode;
    final message = (e.osError?.message ?? e.message).toLowerCase();

    if (message.contains('failed host lookup') ||
        message.contains('name or service not known') ||
        message.contains('nodename nor servname')) {
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
      return _describeSocketError(error, host);
    }
    return 'Could not establish an SSH session with ${host.hostname}.';
  }
}
