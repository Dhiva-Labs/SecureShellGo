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
///  * **One failed ping is not reported.** If the transport really is gone,
///    `connection.done` is usually what says so, and `SessionController`
///    already watches it. A keep-alive that threw on its first miss would race
///    that with a worse-worded message.
///
/// **Dead links.** `done` is not always told, though. A NAT mapping that
/// expired, a phone that moved from Wi-Fi to mobile data, a laptop that slept
/// through its lease: the socket stays open on this side, nothing comes back,
/// and TCP may not give up for a quarter of an hour. So the keep-alive also
/// judges the link itself, and calls [onDead] when
///
///  * the server has answered at least one keep-alive on this connection —
///    a server that ignores them entirely is never judged by them;
///  * the last [deadAfterMisses] keep-alives in a row went unanswered; and
///  * nothing at all has arrived from the server since the first of those
///    was sent. Shell output, an SFTP reply, anything: a link busy enough to
///    delay a keep-alive's answer is still a link.
///
/// [probe] asks the same question at once, for the moments a link is most
/// likely to have died — the network changing, the app coming back, the
/// computer waking up — instead of waiting a minute and a half to find out.
class SessionKeepalive {
  SessionKeepalive({
    required Future<void> Function() ping,
    PeriodicScheduler scheduler = Timer.periodic,
    Duration timeout = pingTimeout,
    DateTime? Function()? lastInbound,
    void Function()? onDead,
    DateTime Function() clock = DateTime.now,
  })  : _ping = ping, // ignore: prefer_initializing_formals
        // ignore: prefer_initializing_formals
        _scheduler = scheduler,
        // ignore: prefer_initializing_formals
        _timeout = timeout,
        // ignore: prefer_initializing_formals
        _lastInbound = lastInbound,
        // ignore: prefer_initializing_formals
        _onDead = onDead,
        // ignore: prefer_initializing_formals
        _clock = clock;

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

  /// How many keep-alives in a row must go unanswered, with nothing else
  /// heard in the meantime, before the link is called dead. Three is about a
  /// minute and a half at [interval]: long enough to ride out a tunnel or a
  /// lift, short enough that the user is not left typing into nothing.
  static const int deadAfterMisses = 3;

  /// How long [probe] waits for its answer. Shorter than [pingTimeout]: a
  /// probe runs because something just changed, and a radio coming out of
  /// idle answers within a few seconds or not at all.
  static const Duration probeTimeout = Duration(seconds: 10);

  final Future<void> Function() _ping;
  final PeriodicScheduler _scheduler;

  /// Overridable only so a test can watch the self-healing guard without
  /// waiting [pingTimeout] of real time. Production takes the default.
  final Duration _timeout;

  /// When bytes last arrived from the server. Null (no way to tell) means
  /// only the keep-alives themselves are counted.
  final DateTime? Function()? _lastInbound;
  final void Function()? _onDead;
  final DateTime Function() _clock;

  Timer? _timer;
  var _inFlight = false;
  var _stopped = false;

  /// Whether the server has answered a keep-alive on this connection yet.
  bool get hasAnswered => _answered;
  var _answered = false;

  /// When each keep-alive in the current run of unanswered ones was sent.
  final List<DateTime> _misses = [];

  /// How many keep-alives in a row have gone unanswered.
  int get missedInARow => _misses.length;

  /// True once [onDead] has been called. Permanent, like [stop].
  bool get isDead => _dead;
  var _dead = false;

  Future<bool>? _probing;

  /// How many keep-alives have been dispatched. Diagnostics, and what the
  /// scheduling test asserts on.
  var pingCount = 0;

  /// Ticks that fell on top of a keep-alive that had not answered yet.
  var skippedCount = 0;

  bool get isRunning => _timer != null;

  /// Begins the schedule. Idempotent, and a no-op after [stop] — a session
  /// ends once, and a keep-alive restarted on a dead transport would only
  /// produce noise.
  ///
  /// [pingNow] sends the first keep-alive straight away rather than one
  /// [interval] in, so the link has a known-good answer behind it from its
  /// first seconds. Without one, nothing — not even [probe] — can call it
  /// dead.
  void start({bool pingNow = false}) {
    if (_stopped || _timer != null) return;
    _timer = _scheduler(interval, (_) => unawaited(_tick()));
    if (pingNow) unawaited(_tick());
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
      await _send(_timeout);
    } finally {
      _inFlight = false;
    }
  }

  /// Sends one keep-alive and records how it went. True when it was answered.
  Future<bool> _send(Duration timeout) async {
    final sentAt = _clock();
    try {
      await _ping().timeout(timeout);
      if (_stopped) return true;
      _answered = true;
      _misses.clear();
      return true;
    } catch (_) {
      // Not reported — see the class doc. It is only counted.
      if (_stopped) return false;
      _misses.add(sentAt);
      if (_misses.length >= deadAfterMisses &&
          !_heardSince(_misses[_misses.length - deadAfterMisses])) {
        _declareDead();
      }
      return false;
    }
  }

  /// Whether anything arrived from the server at or after [moment].
  bool _heardSince(DateTime moment) {
    final heard = _lastInbound?.call();
    return heard != null && !heard.isBefore(moment);
  }

  void _declareDead() {
    if (!_answered || _dead || _stopped) return;
    _dead = true;
    stop();
    _onDead?.call();
  }

  /// Checks the link now, with one keep-alive outside the schedule.
  ///
  /// True when the link answered — or when it cannot honestly be called dead:
  /// something else arrived while the probe waited, or this server has never
  /// answered a keep-alive and so a silence from it proves nothing. False
  /// only after [onDead] has been called. A probe asked for while one is
  /// already out shares its answer.
  Future<bool> probe({Duration timeout = probeTimeout}) {
    if (_dead) return Future<bool>.value(false);
    if (_stopped) return Future<bool>.value(true);
    return _probing ??= () async {
      try {
        final startedAt = _clock();
        if (await _send(timeout)) return true;
        if (_dead) return false;
        if (_heardSince(startedAt)) return true;
        _declareDead();
        return !_dead;
      } finally {
        _probing = null;
      }
    }();
  }

  /// Ends the schedule permanently. Idempotent.
  void stop() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
  }
}
