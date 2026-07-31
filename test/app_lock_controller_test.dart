import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/app_settings.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/services/app_lock.dart';
import 'package:secure_shell_go/services/app_lock_controller.dart';
import 'package:secure_shell_go/services/credential_store.dart';

/// A scripted stand-in for the OS credential sheet.
class FakeAuthenticator implements AppLockAuthenticator {
  FakeAuthenticator({
    this.supported = AppLockSupport.available,
    this.outcome = AppLockOutcome.success,
  });

  AppLockSupport supported;
  AppLockOutcome outcome;

  /// How many times a prompt was actually raised. The cooldown tests read
  /// this to prove the platform is not being called at all while the
  /// cooldown is running, rather than being called and ignored.
  int prompts = 0;

  /// When set, [authenticate] throws instead of returning.
  Object? throwOnAuthenticate;

  /// The last value pushed to FLAG_SECURE, or null if it was never set.
  bool? secureDisplay;

  @override
  Future<AppLockSupport> support() async => supported;

  @override
  Future<AppLockOutcome> authenticate({required String reason}) async {
    prompts++;
    final error = throwOnAuthenticate;
    if (error != null) throw error;
    return outcome;
  }

  @override
  Future<void> setSecureDisplay(bool enabled) async {
    secureDisplay = enabled;
  }
}

void main() {
  late FakeAuthenticator auth;
  late DateTime now;
  late AppLockController controller;

  const enabled = AppSettings(
    appLockEnabled: true,
    appLockTimeout: AppLockTimeout.oneMinute,
  );

  setUp(() {
    auth = FakeAuthenticator();
    now = DateTime(2026, 7, 31, 12);
    controller = AppLockController(authenticator: auth, clock: () => now);
  });

  tearDown(() => controller.dispose());

  /// Drives the controller to [count] consecutive failures.
  Future<void> fail(int count) async {
    auth.outcome = AppLockOutcome.failed;
    for (var i = 0; i < count; i++) {
      await controller.authenticate();
    }
  }

  group('startup', () {
    test('stays open when the lock is off', () async {
      await controller.start(const AppSettings());
      expect(controller.isLocked, isFalse);
      expect(auth.prompts, 0);
    });

    test('locks on launch when the lock is on', () async {
      await controller.start(enabled);
      expect(controller.isLocked, isTrue);
      expect(controller.state.phase, AppLockPhase.locked);
    });

    test('opens, flagged unavailable, when the platform cannot help',
        () async {
      // The settings.json-copied-from-a-phone case. Locking here would brick
      // the desktop build with no way through.
      auth.supported = AppLockSupport.unsupportedPlatform;
      await controller.start(enabled);
      expect(controller.isLocked, isFalse);
      expect(controller.state.unavailable, isTrue);
    });

    test('opens when the device has no screen lock set up', () async {
      auth.supported = AppLockSupport.noDeviceCredential;
      await controller.start(enabled);
      expect(controller.isLocked, isFalse);
      expect(controller.state.unavailable, isTrue);
    });
  });

  group('authentication', () {
    setUp(() async => controller.start(enabled));

    test('a success opens the gate and resets the counter', () async {
      await fail(2);
      expect(controller.state.failedAttempts, 2);
      auth.outcome = AppLockOutcome.success;
      expect(await controller.authenticate(), AppLockOutcome.success);
      expect(controller.isLocked, isFalse);
      expect(controller.state.failedAttempts, 0);
    });

    test('a failure keeps the gate up and counts', () async {
      await fail(1);
      expect(controller.isLocked, isTrue);
      expect(controller.state.failedAttempts, 1);
    });

    test('a cancel keeps the gate up but does not count', () async {
      auth.outcome = AppLockOutcome.cancelled;
      await controller.authenticate();
      await controller.authenticate();
      expect(controller.isLocked, isTrue);
      // Dismissing the sheet is not a guess at the credential. If it counted,
      // a pocketful of stray taps would walk the user into a cooldown.
      expect(controller.state.failedAttempts, 0);
      expect(controller.state.cooldownUntil, isNull);
    });

    test('a platform lockout does not stack the app cooldown on top',
        () async {
      auth.outcome = AppLockOutcome.lockedOut;
      await controller.authenticate();
      expect(controller.isLocked, isTrue);
      expect(controller.state.cooldownUntil, isNull);
    });

    test('authenticating on an open gate is a no-op', () async {
      auth.outcome = AppLockOutcome.success;
      await controller.authenticate();
      expect(controller.isLocked, isFalse);
      final before = auth.prompts;
      expect(await controller.authenticate(), AppLockOutcome.success);
      expect(auth.prompts, before, reason: 'no sheet over an unlocked app');
    });

    test('an authenticator that throws fails open rather than bricking',
        () async {
      auth.throwOnAuthenticate = StateError('bridge is broken');
      expect(await controller.authenticate(), AppLockOutcome.unavailable);
      expect(controller.isLocked, isFalse);
      expect(controller.state.unavailable, isTrue);
    });

    test('an unavailable outcome fails open too', () async {
      auth.outcome = AppLockOutcome.unavailable;
      await controller.authenticate();
      expect(controller.isLocked, isFalse);
      expect(controller.state.unavailable, isTrue);
    });
  });

  group('cooldown', () {
    setUp(() async => controller.start(enabled));

    test('arrives after the configured number of failures', () async {
      await fail(AppLockController.attemptsBeforeCooldown - 1);
      expect(controller.isInCooldown(), isFalse);

      await fail(1);
      expect(controller.isInCooldown(), isTrue);
      expect(
        controller.cooldownRemaining(),
        AppLockController.baseCooldown,
      );
    });

    test('refuses without raising a prompt while it runs', () async {
      await fail(AppLockController.attemptsBeforeCooldown);
      final before = auth.prompts;
      expect(await controller.authenticate(), AppLockOutcome.failed);
      expect(auth.prompts, before);
      expect(controller.isLocked, isTrue);
    });

    test('expires on its own and lets the user back in', () async {
      await fail(AppLockController.attemptsBeforeCooldown);
      now = now.add(AppLockController.baseCooldown);
      expect(controller.isInCooldown(), isFalse);

      auth.outcome = AppLockOutcome.success;
      expect(await controller.authenticate(), AppLockOutcome.success);
      expect(controller.isLocked, isFalse);
    });

    test('doubles for each further run of failures', () async {
      await fail(AppLockController.attemptsBeforeCooldown);
      expect(controller.cooldownRemaining(), const Duration(seconds: 30));

      now = now.add(const Duration(seconds: 31));
      await fail(AppLockController.attemptsBeforeCooldown);
      expect(controller.cooldownRemaining(), const Duration(seconds: 60));

      now = now.add(const Duration(seconds: 61));
      await fail(AppLockController.attemptsBeforeCooldown);
      expect(controller.cooldownRemaining(), const Duration(seconds: 120));
    });

    test('is capped, so nobody is shut out for the evening', () async {
      for (var block = 0; block < 8; block++) {
        now = now.add(const Duration(minutes: 10));
        await fail(AppLockController.attemptsBeforeCooldown);
      }
      expect(
        controller.cooldownRemaining(),
        lessThanOrEqualTo(AppLockController.maxCooldown),
      );
      expect(controller.cooldownRemaining(), AppLockController.maxCooldown);
    });

    test('a success clears it', () async {
      await fail(AppLockController.attemptsBeforeCooldown);
      now = now.add(AppLockController.baseCooldown);
      auth.outcome = AppLockOutcome.success;
      await controller.authenticate();
      expect(controller.state.cooldownUntil, isNull);
      expect(controller.state.failedAttempts, 0);
    });

    test('never wipes anything, however many times it is failed', () async {
      // The controller has no store in scope, so this cannot regress without
      // someone deliberately wiring one in — which is exactly the change this
      // test exists to fail on.
      final backend = FakeSecureStorageBackend();
      final credentials = CredentialStore(backend: backend);
      await credentials.save('h1', const SshCredentials(password: 'hunter2'));

      for (var block = 0; block < 10; block++) {
        now = now.add(const Duration(minutes: 10));
        await fail(AppLockController.attemptsBeforeCooldown);
      }
      expect(controller.state.failedAttempts, 50);
      expect((await credentials.load('h1'))!.password, 'hunter2');
      expect(backend.data, isNotEmpty);
    });
  });

  group('idle timeout', () {
    test('immediately locks on any return to the foreground', () async {
      await controller.start(
        const AppSettings(
          appLockEnabled: true,
          appLockTimeout: AppLockTimeout.immediately,
        ),
      );
      auth.outcome = AppLockOutcome.success;
      await controller.authenticate();
      expect(controller.isLocked, isFalse);

      controller.onBackgrounded();
      now = now.add(const Duration(milliseconds: 1));
      controller.onForegrounded();
      expect(controller.isLocked, isTrue);
    });

    test('a short trip away does not cost an unlock', () async {
      await controller.start(enabled);
      auth.outcome = AppLockOutcome.success;
      await controller.authenticate();

      controller.onBackgrounded();
      // Nipping out to a password manager and straight back.
      now = now.add(const Duration(seconds: 30));
      controller.onForegrounded();
      expect(controller.isLocked, isFalse);
    });

    test('a long trip away locks', () async {
      await controller.start(enabled);
      auth.outcome = AppLockOutcome.success;
      await controller.authenticate();

      controller.onBackgrounded();
      now = now.add(const Duration(minutes: 2));
      controller.onForegrounded();
      expect(controller.isLocked, isTrue);
    });

    test('the boundary itself locks', () async {
      await controller.start(enabled);
      auth.outcome = AppLockOutcome.success;
      await controller.authenticate();

      controller.onBackgrounded();
      now = now.add(const Duration(minutes: 1));
      controller.onForegrounded();
      expect(controller.isLocked, isTrue);
    });

    test('does nothing at all when the lock is off', () async {
      await controller.start(const AppSettings());
      controller.onBackgrounded();
      now = now.add(const Duration(hours: 2));
      controller.onForegrounded();
      expect(controller.isLocked, isFalse);
    });

    test('the credential sheet backgrounding the app does not re-lock it',
        () async {
      // The regression this guards: on Android, raising BiometricPrompt
      // backgrounds the activity and dismissing it foregrounds it again. If
      // those events were honoured, every successful unlock would be followed
      // by an immediate re-lock and the fingerprint would look broken.
      await controller.start(
        const AppSettings(
          appLockEnabled: true,
          appLockTimeout: AppLockTimeout.immediately,
        ),
      );
      var sheetRaised = false;
      auth = FakeAuthenticator();
      controller.dispose();
      controller = AppLockController(
        authenticator: _LifecycleAuthenticator(
          onPrompt: () {
            sheetRaised = true;
            controller.onBackgrounded();
          },
        ),
        clock: () => now,
      );
      await controller.start(
        const AppSettings(
          appLockEnabled: true,
          appLockTimeout: AppLockTimeout.immediately,
        ),
      );
      expect(controller.isLocked, isTrue);

      await controller.authenticate();
      // The sheet closing brings the app back to the foreground.
      controller.onForegrounded();

      expect(sheetRaised, isTrue);
      expect(controller.isLocked, isFalse);
    });
  });

  group('settings changes', () {
    test('turning the lock off opens the gate at once', () async {
      await controller.start(enabled);
      expect(controller.isLocked, isTrue);
      controller.applySettings(const AppSettings());
      expect(controller.isLocked, isFalse);
    });

    test('turning the lock on does not demand a credential there and then',
        () async {
      await controller.start(const AppSettings());
      controller.applySettings(enabled);
      // The user is standing right there having just flipped the switch.
      expect(controller.isLocked, isFalse);
      expect(auth.prompts, 0);

      // It takes effect on the next trip away.
      controller.onBackgrounded();
      now = now.add(const Duration(minutes: 2));
      controller.onForegrounded();
      expect(controller.isLocked, isTrue);
    });

    test('screenshot blocking follows the setting, not the gate', () async {
      // FLAG_SECURE has to be up before the app is ever backgrounded — the
      // recent-apps thumbnail is taken on the way out, long before any lock
      // screen is drawn.
      await controller.start(const AppSettings());
      expect(auth.secureDisplay, isNull);
      controller.applySettings(enabled);
      expect(auth.secureDisplay, isTrue);
      controller.applySettings(const AppSettings());
      expect(auth.secureDisplay, isFalse);
    });

    test('a changed timeout is honoured immediately', () async {
      await controller.start(enabled);
      auth.outcome = AppLockOutcome.success;
      await controller.authenticate();

      controller.applySettings(
        const AppSettings(
          appLockEnabled: true,
          appLockTimeout: AppLockTimeout.fifteenMinutes,
        ),
      );
      controller.onBackgrounded();
      now = now.add(const Duration(minutes: 5));
      controller.onForegrounded();
      expect(controller.isLocked, isFalse);
    });
  });

  group('change stream', () {
    test('reports each transition', () async {
      final seen = <AppLockPhase>[];
      controller.changes.listen((s) => seen.add(s.phase));
      await controller.start(enabled);
      auth.outcome = AppLockOutcome.success;
      await controller.authenticate();
      await Future<void>.delayed(Duration.zero);
      expect(
        seen,
        containsAllInOrder([
          AppLockPhase.locked,
          AppLockPhase.authenticating,
          AppLockPhase.unlocked,
        ]),
      );
    });
  });
}

/// Fires a callback at the moment the prompt goes up, so a test can simulate
/// the OS sheet backgrounding the app mid-authentication.
class _LifecycleAuthenticator implements AppLockAuthenticator {
  _LifecycleAuthenticator({required this.onPrompt});

  final void Function() onPrompt;

  @override
  Future<AppLockSupport> support() async => AppLockSupport.available;

  @override
  Future<AppLockOutcome> authenticate({required String reason}) async {
    onPrompt();
    return AppLockOutcome.success;
  }

  @override
  Future<void> setSecureDisplay(bool enabled) async {}
}

/// Same in-memory backend the credential-store tests use.
class FakeSecureStorageBackend implements SecureStorageBackend {
  final Map<String, String> data = {};

  @override
  Future<void> write(String key, String value) async {
    data[key] = value;
  }

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> delete(String key) async {
    data.remove(key);
  }
}
