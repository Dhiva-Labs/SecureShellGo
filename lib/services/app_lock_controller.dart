import 'dart:async';

import '../models/app_settings.dart';
import 'app_lock.dart';

/// Where the lock currently stands.
enum AppLockPhase {
  unlocked,

  /// The gate is up. Includes the cooldown case — see
  /// [AppLockState.cooldownRemaining], which is kept as a deadline rather
  /// than a phase so it cannot go stale while nothing is redrawing.
  locked,

  /// The OS prompt is on screen. Lifecycle events are ignored in this phase;
  /// see [AppLockController.onBackgrounded].
  authenticating,
}

class AppLockState {
  const AppLockState({
    this.phase = AppLockPhase.unlocked,
    this.failedAttempts = 0,
    this.cooldownUntil,
    this.unavailable = false,
  });

  final AppLockPhase phase;

  /// Consecutive failures. Reset by a success, untouched by a cancel.
  final int failedAttempts;

  final DateTime? cooldownUntil;

  /// Set when the platform could not show a prompt at all. The gate is open
  /// in this state on purpose — see [AppLockController]'s note on failing
  /// open.
  final bool unavailable;

  bool get isLocked => phase != AppLockPhase.unlocked;

  bool isInCooldown(DateTime now) {
    final until = cooldownUntil;
    return until != null && now.isBefore(until);
  }

  Duration cooldownRemaining(DateTime now) {
    final until = cooldownUntil;
    if (until == null || !now.isBefore(until)) return Duration.zero;
    return until.difference(now);
  }

  AppLockState copyWith({
    AppLockPhase? phase,
    int? failedAttempts,
    DateTime? cooldownUntil,
    bool? unavailable,
    bool clearCooldown = false,
  }) {
    return AppLockState(
      phase: phase ?? this.phase,
      failedAttempts: failedAttempts ?? this.failedAttempts,
      cooldownUntil:
          clearCooldown ? null : (cooldownUntil ?? this.cooldownUntil),
      unavailable: unavailable ?? this.unavailable,
    );
  }
}

/// Decides when the app lock is up and what a failed attempt costs.
///
/// Flutter-free, like the rest of `services/` — the widget layer translates
/// `AppLifecycleState` into [onBackgrounded]/[onForegrounded], and the clock
/// is injectable, so every rule below is testable without a device or a
/// wall-clock wait.
///
/// ## What this deliberately cannot do
///
/// It holds no reference to [CredentialStore], [HostStore] or anything else
/// that persists. A failed unlock cannot wipe data here because there is
/// nothing in scope to wipe, and that is the design, not an accident:
/// "N failures then erase" turns a forgotten PIN and a toddler with a phone
/// into the same event as a stolen device. Repeated failures buy a cooldown
/// and nothing else.
///
/// It also holds no reference to [SessionManager] or [TunnelRuntime]. Locking
/// the screen does not disconnect anything — an SSH session and a port
/// forward keep running behind the gate, because a lock is a lock and not a
/// hang-up. Someone stepping away for a coffee should not come back to a
/// dropped `tail -f`.
///
/// ## Why it fails open
///
/// If the platform cannot show a prompt — no bridge, a broken one, a device
/// with its screen lock removed after the setting was turned on — the gate
/// opens and [AppLockState.unavailable] is set, rather than staying shut.
///
/// That is the right way round *for this specific feature*, and the reasoning
/// matters: this lock is a UI gate, not encryption. Saved passwords are
/// encrypted by the platform keystore whether the lock is on or off, so
/// failing open surrenders no protection that was ever actually there. Failing
/// closed, by contrast, would brick the app — every saved host unreachable,
/// with no recovery path that is not "reinstall and lose the lot". A gate
/// that can permanently separate users from their own data is a worse bug
/// than a gate that opens when the lock is missing.
class AppLockController {
  AppLockController({
    required AppLockAuthenticator authenticator,
    DateTime Function()? clock,
  })  :
        // ignore: prefer_initializing_formals
        _authenticator = authenticator,
        _now = clock ?? DateTime.now;

  /// Consecutive failures that buy a cooldown. Five matches what Android's
  /// own biometric stack allows before it rate-limits, so the app's cooldown
  /// and the platform's tend to arrive together rather than compounding.
  static const int attemptsBeforeCooldown = 5;

  /// The first cooldown. Doubles per further block of failures, capped at
  /// [maxCooldown] — long enough to make an exhaustive attempt pointless,
  /// short enough that a user who genuinely fumbled their PIN five times is
  /// not locked out of their servers for the evening.
  static const Duration baseCooldown = Duration(seconds: 30);
  static const Duration maxCooldown = Duration(minutes: 5);

  final AppLockAuthenticator _authenticator;
  final DateTime Function() _now;

  final _changes = StreamController<AppLockState>.broadcast();

  AppLockState _state = const AppLockState();
  bool _enabled = false;
  AppLockTimeout _timeout = AppLockTimeout.oneMinute;
  DateTime? _backgroundedAt;

  AppLockState get state => _state;
  Stream<AppLockState> get changes => _changes.stream;

  bool get enabled => _enabled;
  bool get isLocked => _state.isLocked;
  bool isInCooldown() => _state.isInCooldown(_now());
  Duration cooldownRemaining() => _state.cooldownRemaining(_now());

  /// Whether this device can back the lock, for the Settings row that has to
  /// decide between offering the toggle and explaining why it cannot.
  Future<AppLockSupport> support() => _authenticator.support();

  /// Called at launch, before the first frame that could show anything.
  ///
  /// Checks platform support first: a `settings.json` carried from a phone to
  /// a desktop can say the lock is on where nothing can open it, and that
  /// must not brick the desktop build.
  Future<void> start(AppSettings settings) async {
    applySettings(settings);
    if (!_enabled) return;
    final support = await _authenticator.support();
    if (support != AppLockSupport.available) {
      _emit(_state.copyWith(
        phase: AppLockPhase.unlocked,
        unavailable: true,
      ));
      return;
    }
    _emit(_state.copyWith(phase: AppLockPhase.locked, unavailable: false));
  }

  /// Picks up a settings change.
  ///
  /// Turning the lock *on* does not lock immediately: the user is standing
  /// right there having just flipped the switch, and demanding a fingerprint
  /// to prove it would be theatre. It takes effect at the next background or
  /// launch. Turning it *off* opens the gate at once, which is the only
  /// sensible reading of "off".
  void applySettings(AppSettings settings) {
    final was = _enabled;
    _enabled = settings.appLockEnabled;
    _timeout = settings.appLockTimeout;
    if (was != _enabled) {
      // Tied to the setting, not to the gate being up: see
      // [AppLockAuthenticator.setSecureDisplay] for why the screenshot flag
      // has to be in place before the app is ever backgrounded.
      unawaited(_authenticator.setSecureDisplay(_enabled));
    }
    if (!_enabled && _state.isLocked) {
      _emit(const AppLockState());
    }
  }

  /// The app went to the background. Starts the idle clock.
  void onBackgrounded() {
    // The OS credential sheet is itself a window: on Android, showing
    // BiometricPrompt backgrounds the activity and dismissing it foregrounds
    // it again. Without this guard a successful unlock would immediately be
    // followed by a resume that re-locked the app, which reads to the user as
    // the fingerprint not having worked.
    if (_state.phase == AppLockPhase.authenticating) return;
    // Earliest wins. Flutter reports `hidden` and then `paused` on the way
    // out, and overwriting would measure the gap from the *last* of those,
    // quietly shortening every idle period. Cleared again on the way back in,
    // so the next trip away records fresh.
    _backgroundedAt ??= _now();
  }

  /// The app came back. Locks if it was away for longer than the timeout.
  void onForegrounded() {
    if (_state.phase == AppLockPhase.authenticating) return;
    final since = _backgroundedAt;
    _backgroundedAt = null;
    if (!_enabled || _state.isLocked || _state.unavailable) return;
    if (since == null) return;
    if (_now().difference(since) >= _timeout.duration) {
      _emit(_state.copyWith(phase: AppLockPhase.locked));
    }
  }

  /// Shows the OS prompt and applies the result.
  ///
  /// A no-op returning success when the gate is already open, so a stray tap
  /// cannot summon a credential sheet over an unlocked app.
  Future<AppLockOutcome> authenticate({
    String reason = 'Unlock SecureShell Go',
  }) async {
    if (!_state.isLocked) return AppLockOutcome.success;
    if (_state.phase == AppLockPhase.authenticating) {
      return AppLockOutcome.cancelled;
    }
    // Refused here rather than at the platform, so a cooldown cannot be
    // skipped by whatever is driving this.
    if (_state.isInCooldown(_now())) return AppLockOutcome.failed;

    _emit(_state.copyWith(phase: AppLockPhase.authenticating));
    final AppLockOutcome outcome;
    try {
      outcome = await _authenticator.authenticate(reason: reason);
    } catch (_) {
      // An authenticator that throws is an authenticator that is not working;
      // treat it exactly like one that reported it could not run.
      _emit(_state.copyWith(
        phase: AppLockPhase.unlocked,
        unavailable: true,
        clearCooldown: true,
        failedAttempts: 0,
      ));
      return AppLockOutcome.unavailable;
    }

    switch (outcome) {
      case AppLockOutcome.success:
        _backgroundedAt = null;
        _emit(const AppLockState());
      case AppLockOutcome.failed:
        final attempts = _state.failedAttempts + 1;
        final blocks = attempts ~/ attemptsBeforeCooldown;
        final hitLimit = attempts % attemptsBeforeCooldown == 0;
        _emit(_state.copyWith(
          phase: AppLockPhase.locked,
          failedAttempts: attempts,
          cooldownUntil: hitLimit
              ? _now().add(_cooldownFor(blocks))
              : _state.cooldownUntil,
        ));
      case AppLockOutcome.cancelled:
        // Backing out of the sheet is not a guess. The gate stays up, the
        // counter stays put.
        _emit(_state.copyWith(phase: AppLockPhase.locked));
      case AppLockOutcome.lockedOut:
        // The platform is already rate-limiting. Stay locked, but do not
        // stack the app's own cooldown on top of the OS one.
        _emit(_state.copyWith(phase: AppLockPhase.locked));
      case AppLockOutcome.unavailable:
        _emit(_state.copyWith(
          phase: AppLockPhase.unlocked,
          unavailable: true,
          clearCooldown: true,
          failedAttempts: 0,
        ));
    }
    return outcome;
  }

  /// Doubling backoff, capped. [blocks] is how many full runs of
  /// [attemptsBeforeCooldown] failures have happened.
  static Duration _cooldownFor(int blocks) {
    var wait = baseCooldown;
    for (var i = 1; i < blocks; i++) {
      wait *= 2;
      if (wait >= maxCooldown) return maxCooldown;
    }
    return wait > maxCooldown ? maxCooldown : wait;
  }

  void _emit(AppLockState next) {
    _state = next;
    if (!_changes.isClosed) _changes.add(next);
  }

  void dispose() {
    unawaited(_changes.close());
  }
}
