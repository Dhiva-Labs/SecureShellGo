import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'x11_forwarding.dart';

/// What a session's shell channel asks the server to forward back to this
/// device: the SSH agent ([Host.agentForwarding]), X11 windows
/// ([Host.x11Forwarding]), or both.
class ShellForwarding {
  const ShellForwarding({this.agent, this.x11, this.notices = const []});

  /// Answers the server's `auth-agent@openssh.com` channels.
  final SSHAgentHandler? agent;

  /// Carries the server's `x11` channels to the local X server.
  final X11Forwarder? x11;

  /// Things to tell the person at the top of the shell, decided before it
  /// opened — X11 asked for on a device with no display, say.
  final List<String> notices;

  bool get isEmpty => agent == null && x11 == null && notices.isEmpty;
}

/// An [SSHClient] that asks for forwarding on its *shell* channels only.
///
/// dartssh2 decides per client, not per channel: a client built with an
/// [SSHClient.agentHandler] sends `auth-agent-req@openssh.com` on every
/// session channel it opens and throws when the server refuses one, and
/// OpenSSH grants that request once per connection. A session that simply
/// carried a handler would lose every exec after its first — the stats
/// poll, the log tail, the service actions, the key push. See
/// `SessionTransport.execute`.
///
/// So this overrides the one thing dartssh2 reads to decide, the
/// [agentHandler] getter, and answers it per call site: null while an exec
/// channel is being set up, the forwarded agent everywhere else — which is
/// the shell's setup and the server opening an agent channel back to us.
/// Which call site is asking is carried by a [Zone] value around [execute]
/// (see [withoutAgentRequest]) because dartssh2 reads the getter after the
/// channel-open round trip, by when anything else could be running too: a
/// zone follows that exec's own continuation and nothing else's, so a
/// stats poll that opens a channel while the shell is opening does not see
/// the shell's answer, nor the other way round.
///
/// The shell also gets the X11 request, and a server that refuses either
/// request still opens the shell — without it, and with a line at the top
/// of the terminal saying so, the way `ssh` prints "X11 forwarding request
/// failed on channel 0". See [openForwardedShell].
///
/// With no [forwarding] — every connection but those to hosts that turn it
/// on — this is a plain [SSHClient]: [agentHandler] is whatever was passed
/// in, which is how the direct server-to-server copy's own connection keeps
/// its per-transfer slot on its one exec, unchanged.
class ForwardingSSHClient extends SSHClient {
  ForwardingSSHClient(
    super.socket, {
    required super.username,
    super.identities,
    super.algorithms,
    super.onPasswordRequest,
    super.onUserInfoRequest,
    super.onUserauthBanner,
    super.onVerifyHostKey,
    super.agentHandler,
    super.handshakeTimeout,
    super.authTimeout,
    super.keepAliveInterval,
    super.printDebug,
    super.printTrace,
    this.forwarding,
  }) : super(
          onX11Forward: forwarding?.x11 == null
              ? null
              : (channel) => unawaited(forwarding!.x11!.handle(channel)),
        );

  final ShellForwarding? forwarding;

  @override
  SSHAgentHandler? get agentHandler {
    final own = super.agentHandler;
    if (own != null) return own;
    final agent = forwarding?.agent;
    if (agent == null || agentRequestWithheld) return null;
    return agent;
  }

  @override
  Future<SSHSession> execute(
    String command, {
    SSHPtyConfig? pty,
    SSHX11Config? x11,
    Map<String, String>? environment,
  }) {
    Future<SSHSession> open() => super.execute(
          command,
          pty: pty,
          x11: x11,
          environment: environment,
        );
    return forwarding?.agent == null ? open() : withoutAgentRequest(open);
  }

  @override
  Future<SSHSession> shell({
    SSHPtyConfig? pty = const SSHPtyConfig(),
    SSHX11Config? x11,
    Map<String, String>? environment,
  }) {
    final forwarding = this.forwarding;
    if (forwarding == null || forwarding.isEmpty || x11 != null) {
      return super.shell(pty: pty, x11: x11, environment: environment);
    }
    return openForwardedShell(
      forwarding: forwarding,
      open: ({required bool agent, required SSHX11Config? x11}) {
        Future<SSHSession> open() =>
            super.shell(pty: pty, x11: x11, environment: environment);
        return agent ? open() : withoutAgentRequest(open);
      },
    );
  }

  @override
  Future<void> close() {
    forwarding?.x11?.closeAll();
    return super.close();
  }
}

final Object _withholdAgentRequest = Object();

/// Runs [body] with [ForwardingSSHClient.agentHandler] reading null, so a
/// session channel opened inside it carries no `auth-agent-req`.
Future<T> withoutAgentRequest<T>(Future<T> Function() body) =>
    runZoned(body, zoneValues: {_withholdAgentRequest: true});

/// Whether the code running now is inside [withoutAgentRequest].
bool get agentRequestWithheld => Zone.current[_withholdAgentRequest] == true;

/// Opens one shell channel, a [ForwardingSSHClient.shell], with what
/// [forwarding] asks for — and without whatever the server refuses.
///
/// [open] opens the channel with or without the agent request and with the
/// given X11 request. dartssh2 asks for each in turn — agent, then pty,
/// then X11 — and throws [SSHChannelRequestError] at the first refusal,
/// having closed that channel, so a refusal is answered with another
/// channel that leaves the refused request out, and the shell opens either
/// way. A server with `AllowAgentForwarding no` or `X11Forwarding no` is
/// common, and must not cost the person their shell.
///
/// One wrinkle: a channel turned down for X11 had already been granted the
/// agent, and OpenSSH grants that once per connection — to the connection,
/// so the shell that follows has it too, and the next channel's agent
/// request is refused for having been granted already, not for being
/// disallowed. That refusal is not reported. The request is still made,
/// for servers such as Dropbear that grant it per channel.
///
/// What was dropped, and [ShellForwarding.notices], is written at the top
/// of the shell's output; see [ShellSessionWithNotices].
Future<SSHSession> openForwardedShell({
  required ShellForwarding forwarding,
  required Future<SSHSession> Function({
    required bool agent,
    required SSHX11Config? x11,
  }) open,
}) async {
  var agent = forwarding.agent != null;
  var agentGranted = false;
  var x11 = forwarding.x11?.config;
  final notices = [...forwarding.notices];
  while (true) {
    try {
      final session = await open(agent: agent, x11: x11);
      return notices.isEmpty
          ? session
          : ShellSessionWithNotices(session, notices);
    } on SSHChannelRequestError catch (e) {
      final message = e.message.toLowerCase();
      if (agent && message.contains(refusedAgentRequest)) {
        agent = false;
        if (!agentGranted) {
          notices.add('The server refused agent forwarding, so keys on this '
              'device cannot be used from this shell. Its sshd_config may '
              'have AllowAgentForwarding no.');
        }
        continue;
      }
      if (x11 != null && message.contains(refusedX11Request)) {
        // Asked for after the agent, so the agent was granted.
        if (agent) agentGranted = true;
        x11 = null;
        notices.add('The server refused X11 forwarding, so graphical '
            'programs cannot open windows here. Its sshd_config may have '
            'X11Forwarding no, or xauth may not be installed there.');
        continue;
      }
      rethrow;
    }
  }
}

/// What dartssh2's `SSHChannelRequestError` says, lowercased, when the
/// server refuses the agent request ("Failed to request agent
/// forwarding") or the X11 one ("Failed to request x11 forwarding").
/// Pinned by the tests against a scripted server, so a reworded error in
/// a later dartssh2 shows up as a failing test rather than as shells that
/// stop opening.
const refusedAgentRequest = 'request agent forwarding';
const refusedX11Request = 'request x11 forwarding';

/// A shell session whose output starts with a few lines from this app.
///
/// The lines go out on stderr ahead of anything the server sends, the way
/// `ssh` writes its own warnings into the terminal; everything else is the
/// wrapped session's, untouched.
class ShellSessionWithNotices implements SSHSession {
  ShellSessionWithNotices(this._inner, List<String> notices)
      : _notice = Uint8List.fromList([
          for (final notice in notices)
            ...'\x1b[33m$notice\x1b[0m\r\n'.codeUnits,
        ]);

  final SSHSession _inner;
  final Uint8List _notice;

  late final Stream<Uint8List> _stderr = _prefixed();

  Stream<Uint8List> _prefixed() async* {
    yield _notice;
    yield* _inner.stderr;
  }

  @override
  Stream<Uint8List> get stderr => _stderr;

  @override
  Stream<Uint8List> get stdout => _inner.stdout;

  @override
  StreamSink<Uint8List> get stdin => _inner.stdin;

  @override
  int? get exitCode => _inner.exitCode;

  @override
  SSHSessionExitSignal? get exitSignal => _inner.exitSignal;

  @override
  Future<void> get done => _inner.done;

  @override
  void write(Uint8List data) => _inner.write(data);

  @override
  Future<void> flush() => _inner.flush();

  @override
  void resizeTerminal(
    int width,
    int height, [
    int pixelWidth = 0,
    int pixelHeight = 0,
  ]) =>
      _inner.resizeTerminal(width, height, pixelWidth, pixelHeight);

  @override
  void close() => _inner.close();

  @override
  Future<int?> waitForExit({Duration? timeout}) =>
      _inner.waitForExit(timeout: timeout);

  @override
  void kill(SSHSignal signal) => _inner.kill(signal);

  // [SSHSession.channel] is the one member not spelled out above: its type
  // is not exported by dartssh2, so it cannot be named here. It still
  // reaches the wrapped session's.
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      invocation.isGetter && invocation.memberName == #channel
          ? _inner.channel
          : super.noSuchMethod(invocation);
}
