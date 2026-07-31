import 'dart:async';

import '../models/host.dart';
import 'reconnect_policy.dart';
// Also re-exports `host_key_policy.dart`, which is where [HostKeyPrompt] and
// [HostKeyVerifier] come from.
import 'ssh_service.dart';

export 'reconnect_policy.dart'
    show ReconnectFailure, ReconnectPhase, ReconnectPolicy;

/// How a [SessionReconnector] waits out a backoff delay.
///
/// Injected purely so a test can fire the timer by hand instead of waiting
/// thirty real seconds. Production passes `Timer.new`, which is exactly this
/// signature.
typedef ReconnectDelayScheduler = Timer Function(
  Duration delay,
  void Function() fire,
);

/// Opens a fresh authenticated transport, verifying the host key through
/// [verifyHostKey].
///
/// `SshService.connect` fits this with a lambda. It is a callback rather than
/// the service itself so that everything below `services/` stays testable
/// without a socket, and so the reconnect path cannot quietly acquire the
/// ability to do anything to a connection *except* open one.
typedef ReconnectConnector = Future<SessionTransport> Function({
  required Host host,
  required SshCredentials credentials,
  required HostKeyVerifier verifyHostKey,
});

/// Everything a session needs in order to be able to rebuild its own
/// transport, and nothing else.
///
/// Bundled into one object because it travels a long way — from `main.dart`,
/// where the SSH service and the credential store are built, through
/// `SessionManager`, to each `SessionController` — and two more parameters on
/// every constructor along that path would be two more things for the next
/// caller to forget.
///
/// Note what is *not* here: no password, no key, no passphrase. Secrets are
/// fetched one host at a time from the existing credential store at the moment
/// an attempt runs, used for that attempt, and dropped. Nothing is cached in a
/// new place, which is the whole of this feature's contribution to the app's
/// secret-handling surface.
class ReconnectSupport {
  const ReconnectSupport({
    required this.loadCredentials,
    required this.connect,
  });

  /// The saved credentials for a host id, or null when nothing is saved.
  /// `CredentialStore.load` fits this exactly.
  final Future<SshCredentials?> Function(String hostId) loadCredentials;

  final ReconnectConnector connect;
}

/// Rebuilds one session's transport after it dies unexpectedly.
///
/// Owns a [ReconnectPolicy] (which decides *whether* and *when*) and adds the
/// three things a policy cannot have: a timer, the credential lookup, and the
/// connect itself. Everything that could deadlock, loop or leak lives in this
/// ninety lines rather than being spread across the session and the screen.
///
/// **Host keys.** The verifier handed to [ReconnectSupport.connect] refuses
/// every prompt. That is not a shortcut around the TOFU flow — it *is* the
/// TOFU flow, run with the only answer that is safe when no human is looking:
/// `HostKeyPolicy` still consults known-hosts first and still accepts a key
/// that matches silently, which is the case every ordinary reconnect takes. A
/// key that has *changed*, or a host that is no longer known at all, reaches
/// the prompt — and a prompt with nobody in front of it can only honestly be
/// answered "no". The attempt then fails as a host-key failure, which the
/// policy never retries, and the banner says so. A changed key is never
/// accepted by this path, automatically or otherwise.
class SessionReconnector {
  SessionReconnector({
    required this.host,
    required ReconnectSupport support,
    required Future<void> Function(SessionTransport transport) adopt,
    ReconnectPolicy? policy,
    ReconnectDelayScheduler scheduler = Timer.new,
  })  : _policy = policy ?? ReconnectPolicy(),
        // ignore: prefer_initializing_formals
        _support = support,
        // ignore: prefer_initializing_formals
        _adopt = adopt,
        // ignore: prefer_initializing_formals
        _scheduler = scheduler;

  final Host host;

  final ReconnectSupport _support;

  /// Hands the new transport to whatever is going to use it — in production
  /// `SessionController.adoptTransport`, which is what puts a fresh shell in
  /// the same tab and the same pane.
  final Future<void> Function(SessionTransport transport) _adopt;

  final ReconnectPolicy _policy;
  final ReconnectDelayScheduler _scheduler;

  Timer? _timer;
  final _changes = StreamController<void>.broadcast();

  /// Fires on every phase change, so the banner can follow along. Folded into
  /// `SessionController.changes` by the session that owns this, so a view
  /// needs one subscription rather than two.
  Stream<void> get changes => _changes.stream;

  ReconnectPhase get phase => _policy.phase;

  /// True while a reconnection is genuinely in progress.
  bool get isActive => _policy.isActive;

  int get attempts => _policy.attempts;

  /// What the terminal area should be saying right now, or null when there is
  /// nothing to say.
  String? get message {
    switch (_policy.phase) {
      case ReconnectPhase.idle:
      case ReconnectPhase.connected:
      case ReconnectPhase.stopped:
        return null;
      case ReconnectPhase.waiting:
        return _policy.attempts == 0
            ? 'Connection lost. Reconnecting to ${host.displayName}…'
            : 'Reconnecting to ${host.displayName}… '
                '(attempt ${_policy.attempts + 1})';
      case ReconnectPhase.connecting:
        return 'Reconnecting to ${host.displayName}… '
            '(attempt ${_policy.attempts})';
      case ReconnectPhase.givenUp:
        return _policy.stopReason;
    }
  }

  /// Whether the schedule ended without getting a transport. What decides
  /// between the "reconnecting" banner and the ordinary disconnected one.
  bool get hasGivenUp => _policy.phase == ReconnectPhase.givenUp;

  /// The transport died in a way worth retrying. Idempotent: a second call
  /// while a schedule is already running is ignored, so a session that
  /// notices its own death twice does not end up with two ladders of timers.
  void begin() {
    if (_policy.isFinished || _policy.isActive) return;
    _schedule();
  }

  void _schedule() {
    final delay = _policy.nextDelay();
    if (delay == null) {
      _notify();
      return;
    }
    _timer?.cancel();
    _timer = _scheduler(delay, () => unawaited(_attempt()));
    _notify();
  }

  Future<void> _attempt() async {
    if (_policy.isFinished) return;
    _policy.attemptStarted();
    _notify();

    // Captured by the verifier below, so a refusal can be told apart from any
    // other handshake failure and described precisely.
    HostKeyPrompt? refused;

    try {
      final credentials = await _support.loadCredentials(host.id);
      if (_policy.isFinished) return;
      if (credentials == null) {
        _policy.failed(ReconnectFailure.noCredentials);
        _notify();
        return;
      }

      final transport = await _support.connect(
        host: host,
        credentials: credentials,
        verifyHostKey: (prompt) async {
          refused = prompt;
          return false;
        },
      );

      // Stopped while the handshake was in flight — the user closed the tab,
      // or pressed Stop. The transport we just authenticated is nobody's, so
      // it has to be closed here or it stays open until the process ends.
      if (_policy.isFinished) {
        transport.close();
        return;
      }

      await _adopt(transport);
      _policy.succeeded();
      _notify();
      return;
    } catch (error) {
      if (_policy.isFinished) return;
      final prompt = refused;
      if (prompt != null) {
        _policy.failed(
          ReconnectFailure.hostKey,
          message: _describeHostKeyRefusal(prompt),
        );
      } else if (error is SshAuthenticationException) {
        _policy.failed(ReconnectFailure.authentication, message: error.message);
      } else if (error is HostKeyRejectedException) {
        _policy.failed(ReconnectFailure.hostKey, message: error.message);
      } else {
        _policy.failed(ReconnectFailure.transport);
      }
    }

    // Only reached on failure. A retryable one leaves the policy runnable and
    // the ladder continues; anything else has already set its own reason.
    if (_policy.isFinished) {
      _notify();
    } else {
      _schedule();
    }
  }

  String _describeHostKeyRefusal(HostKeyPrompt prompt) {
    switch (prompt.kind) {
      case HostKeyPromptKind.changed:
        return 'The host key for ${prompt.hostLabel} has CHANGED since you '
            'last connected. Reconnecting stopped. This can mean the server '
            'was rebuilt — or that something is intercepting the connection. '
            'Verify the new key out of band before connecting again.';
      case HostKeyPromptKind.unknown:
        return '${prompt.hostLabel} is no longer in known hosts, so its key '
            'cannot be verified without you. Connect from the host list to '
            'review it.';
    }
  }

  /// The user ended it — closed the tab, or pressed Stop. Terminal: nothing
  /// restarts a cancelled reconnector, because the thing it was going to
  /// reconnect no longer wants to exist.
  void cancel() {
    _timer?.cancel();
    _timer = null;
    if (_policy.isFinished) return;
    _policy.stop();
    _notify();
  }

  void _notify() {
    if (_changes.isClosed) return;
    _changes.add(null);
  }

  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;
    _policy.stop();
    await _changes.close();
  }
}
