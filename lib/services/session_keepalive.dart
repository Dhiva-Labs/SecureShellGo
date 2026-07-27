import 'dart:async';

/// How a [SessionKeepalive] gets its periodic tick.
///
/// Injected purely so the schedule can be exercised in a unit test without
/// waiting [SessionKeepalive.interval] of real time. Production passes
/// `Timer.periodic`, which is exactly this signature.
typedef PeriodicScheduler = Timer Function(
  Duration interval,
  void Function(Timer timer) tick,
);

/// Sends an SSH keep-alive on a fixed interval for as long as a session is
/// open.
///
/// Why this exists at all, given `SSHClient` has a `keepAliveInterval` of its
/// own: the session — not the client — is what knows when keep-alives are
/// wanted, and the app's whole Phase 7 problem is a *backgrounded* process, so
/// this is the one piece of session plumbing most worth being able to test.
/// `SshService` therefore constructs the client with `keepAliveInterval: null`
/// and there is exactly one owner of the schedule: this.
///
/// Two behaviours differ from dartssh2's `SSHKeepAlive`, and both matter here:
///
///  * **The in-flight guard self-heals.** `SSHKeepAlive` sets an `_isPinging`
///    flag and clears it in a `finally` after `await ping()`. A ping that never
///    completes — which is precisely what a silently dropped NAT mapping looks
///    like — leaves that flag latched and no further keep-alive is ever sent
///    again. Here the ping is raced against [pingTimeout], so the next tick
///    always gets its turn.
///  * **A failed ping is not reported.** If the transport really is gone,
///    `connection.done` is what says so, and `SessionController` already
///    watches it. A keep-alive that throws would otherwise race that with a
///    worse-worded message.
class SessionKeepalive {
  SessionKeepalive({
    required Future<void> Function() ping,
    PeriodicScheduler scheduler = Timer.periodic,
    Duration timeout = pingTimeout,
  })  : _ping = ping, // ignore: prefer_initializing_formals
        // ignore: prefer_initializing_formals
        _scheduler = scheduler,
        // ignore: prefer_initializing_formals
        _timeout = timeout;

  /// Deliberately a constant rather than a setting.
  ///
  /// The number is not a preference the user can reason about — it is a
  /// property of the middleboxes between the phone and the server. 30 s sits
  /// under the common NAT/UDP-adjacent idle windows (most consumer routers
  /// expire an idle TCP mapping somewhere between 5 and 30 minutes, mobile
  /// carrier NATs far sooner) while costing a couple of packets a minute, and
  /// it is three times gentler on the radio than dartssh2's 10 s default.
  static const Duration interval = Duration(seconds: 30);

  /// How long a single keep-alive is given before the next tick may proceed.
  /// Shorter than [interval] so ticks can never pile up.
  static const Duration pingTimeout = Duration(seconds: 20);

  final Future<void> Function() _ping;
  final PeriodicScheduler _scheduler;

  /// Overridable only so a test can watch the self-healing guard without
  /// waiting [pingTimeout] of real time. Production takes the default.
  final Duration _timeout;

  Timer? _timer;
  var _inFlight = false;
  var _stopped = false;

  /// How many keep-alives have been dispatched. Diagnostics, and what the
  /// scheduling test asserts on.
  var pingCount = 0;

  /// Ticks that fell on top of a keep-alive that had not answered yet.
  var skippedCount = 0;

  bool get isRunning => _timer != null;

  /// Begins the schedule. Idempotent, and a no-op after [stop] — a session
  /// ends once, and a keep-alive restarted on a dead transport would only
  /// produce noise.
  void start() {
    if (_stopped || _timer != null) return;
    _timer = _scheduler(interval, (_) => unawaited(_tick()));
  }

  Future<void> _tick() async {
    if (_stopped) return;
    if (_inFlight) {
      skippedCount++;
      return;
    }
    _inFlight = true;
    pingCount++;
    try {
      await _ping().timeout(_timeout);
    } catch (_) {
      // Swallowed on purpose — see the class doc. `connection.done` is the
      // single source of truth for "the session is gone".
    } finally {
      _inFlight = false;
    }
  }

  /// Ends the schedule permanently. Idempotent.
  void stop() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
  }
}
