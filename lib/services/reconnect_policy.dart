/// Why a reconnection attempt failed, reduced to the only distinction the
/// schedule cares about: whether waiting and trying again could possibly
/// change the answer.
///
/// The reduction is the point. A driver that classified failures by exception
/// type would have to be taught about every error dartssh2 can raise; a
/// schedule that only asks "is this worth retrying" needs four cases and can
/// be reasoned about in one sitting.
enum ReconnectFailure {
  /// The network, the route or the server was not there. Nothing about the
  /// credentials or the host key is in question, and the very next attempt
  /// may well succeed — this is the case the whole feature exists for.
  transport,

  /// The server rejected the credentials we hold.
  ///
  /// Retrying is not merely useless here, it is harmful: N attempts against
  /// a server with `MaxAuthTries` and `fail2ban` in front of it is how an
  /// automatic recovery turns into a lockout of the user's own account. One
  /// failure stops the schedule dead.
  authentication,

  /// The host key on the wire is not the one we trust — or the host is no
  /// longer known at all.
  ///
  /// Never retried and never auto-accepted. A reconnect happens with no human
  /// watching, which is exactly the situation in which silently trusting a new
  /// key would be worst.
  hostKey,

  /// Nothing is saved in the credential store for this host, so there is
  /// nothing to reconnect *with*. Distinct from [authentication] only so the
  /// message can tell the user where to go and fix it.
  noCredentials,
}

/// Where a reconnection has got to.
enum ReconnectPhase {
  /// Not reconnecting, and never was — the ordinary state of a healthy
  /// session.
  idle,

  /// Counting down to the next attempt.
  waiting,

  /// An attempt is in flight.
  connecting,

  /// A transport was obtained and handed over. Terminal.
  connected,

  /// The schedule ran out, or a failure came back that retrying cannot fix.
  /// Terminal.
  givenUp,

  /// The user closed the session (or pressed Stop) while this was running.
  /// Terminal, and deliberately distinct from [givenUp]: nothing failed, so
  /// nothing should be reported as having failed.
  stopped,
}

/// The reconnection schedule, as a pure object: no sockets, no timers, no
/// clock.
///
/// Everything about *when* to try again and *whether* to try again lives here,
/// which is what makes the interesting parts — the backoff caps, the total
/// budget, and the two failures that must never loop — testable by calling
/// methods in a loop rather than by waiting two minutes with a real server on
/// the other end. [SessionReconnector] is the driver that owns a timer and a
/// connect callback and does what this says.
///
/// The budget is measured in *scheduled delay* rather than wall-clock elapsed
/// time, on purpose. Wall-clock would make the number of attempts depend on
/// how long each connect attempt took to fail, which is a property of the
/// network being diagnosed and not something a test can pin down; counting the
/// waits makes the sequence exact and reproducible. The attempts themselves
/// each carry the SSH connect timeout on top, so the real elapsed time is
/// somewhat longer than [budget] — "about two minutes" is the promise, and
/// that is what it delivers.
class ReconnectPolicy {
  ReconnectPolicy({
    List<Duration> backoff = defaultBackoff,
    this.budget = defaultBudget,
  })  : assert(backoff.isNotEmpty, 'a schedule needs at least one delay'),
        _backoff = List.unmodifiable(backoff);

  /// 2s, 4s, 8s, 16s, then 30s for as long as the budget allows.
  ///
  /// The first delay is short because the overwhelmingly common case — a
  /// Wi-Fi handover, a lid closed for ten seconds — is over before the user
  /// has finished noticing it. The cap is 30s because past that the user has
  /// already decided to do something else, and a client hammering a server
  /// that is down for maintenance is not a good citizen.
  static const List<Duration> defaultBackoff = [
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 16),
    Duration(seconds: 30),
  ];

  /// How much total waiting the schedule is allowed before it gives up.
  ///
  /// A session that has been gone two minutes is not a blip, and continuing to
  /// retry silently in the background — possibly on mobile data, possibly for
  /// hours — is not a decision to make on the user's behalf. The banner ends
  /// up saying so and reconnecting by hand is one tap.
  static const Duration defaultBudget = Duration(minutes: 2);

  final List<Duration> _backoff;

  final Duration budget;

  ReconnectPhase get phase => _phase;
  var _phase = ReconnectPhase.idle;

  /// How many attempts have actually been started.
  int get attempts => _attempts;
  var _attempts = 0;

  /// The delays handed out so far, added up. What [budget] is spent against.
  Duration get scheduledDelay => _scheduledDelay;
  var _scheduledDelay = Duration.zero;

  /// Why the schedule ended, for the banner. Null while it is still running,
  /// and null after [succeeded] — a success has nothing to explain.
  String? get stopReason => _stopReason;
  String? _stopReason;

  /// Whether this policy has reached a state it will never leave.
  bool get isFinished =>
      _phase == ReconnectPhase.connected ||
      _phase == ReconnectPhase.givenUp ||
      _phase == ReconnectPhase.stopped;

  /// True while a reconnection is genuinely in progress — which is exactly
  /// when the terminal area should be showing that it is.
  bool get isActive =>
      _phase == ReconnectPhase.waiting || _phase == ReconnectPhase.connecting;

  /// How long to wait before the next attempt, or null when the budget is
  /// spent (in which case the phase becomes [ReconnectPhase.givenUp]).
  ///
  /// Advances the schedule, so calling it is what *makes* the next delay the
  /// next delay. The last entry of the backoff list repeats until the budget
  /// runs out, which is what "capped exponential backoff" means.
  Duration? nextDelay() {
    if (isFinished) return null;

    final delay = _backoff[
        _attempts < _backoff.length ? _attempts : _backoff.length - 1];

    // Spending the delay must not overshoot the budget. Checked before the
    // wait rather than after, so the schedule never sits idle through a delay
    // it was always going to abandon at the end of.
    if (_scheduledDelay + delay > budget) {
      _phase = ReconnectPhase.givenUp;
      _stopReason = 'Could not reconnect after '
          '${_attempts == 1 ? '1 attempt' : '$_attempts attempts'}.';
      return null;
    }

    _scheduledDelay += delay;
    _phase = ReconnectPhase.waiting;
    return delay;
  }

  /// The wait is over and a connection is being attempted.
  void attemptStarted() {
    if (isFinished) return;
    _attempts++;
    _phase = ReconnectPhase.connecting;
  }

  /// A transport was obtained. Terminal, and clears [stopReason] — a schedule
  /// that succeeded on its fifth attempt has nothing to report about the four
  /// that did not.
  void succeeded() {
    if (isFinished) return;
    _phase = ReconnectPhase.connected;
    _stopReason = null;
  }

  /// Records why the attempt in flight failed.
  ///
  /// Retryable failures leave the policy runnable, and the driver asks
  /// [nextDelay] again. The other three end it here and now — an auth failure
  /// in particular must never come back round, which is why this is a state
  /// transition in a tested object rather than an `if` in a callback.
  void failed(ReconnectFailure kind, {String? message}) {
    if (isFinished) return;
    switch (kind) {
      case ReconnectFailure.transport:
        // Stays runnable. The phase goes back to waiting only when the driver
        // asks for the next delay, so a policy inspected between a failure and
        // the next schedule still reads as `connecting` — which is what the
        // banner should keep saying across the gap.
        return;
      case ReconnectFailure.authentication:
        _phase = ReconnectPhase.givenUp;
        _stopReason = message ??
            'The server rejected the saved credentials. Reconnecting stopped '
                'so repeated attempts cannot lock the account out.';
      case ReconnectFailure.hostKey:
        _phase = ReconnectPhase.givenUp;
        _stopReason = message ??
            'The host key could not be verified. Reconnecting stopped — '
                'check the server before connecting again.';
      case ReconnectFailure.noCredentials:
        _phase = ReconnectPhase.givenUp;
        _stopReason = message ??
            'No saved credentials for this host. Connect again from the host '
                'list.';
    }
  }

  /// The user ended it: closed the tab, or pressed Stop. Not a failure, and
  /// not something to explain in a banner that is about to disappear anyway.
  void stop() {
    if (_phase == ReconnectPhase.connected) return;
    _phase = ReconnectPhase.stopped;
    _stopReason = null;
  }
}
