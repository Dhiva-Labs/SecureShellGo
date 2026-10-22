import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/l10n/l10n.dart';
import 'package:secure_shell_go/models/app_settings.dart';
import 'package:secure_shell_go/screens/settings/setting_labels.dart';
import 'package:secure_shell_go/services/app_lock.dart';
import 'package:secure_shell_go/services/app_lock_controller.dart';

/// Plays the part of `windows/runner/windows_hello.cpp` on the channel.
class FakeHelloRunner {
  FakeHelloRunner() {
    _messenger.setMockMethodCallHandler(MethodChannelAppLock.channel, _handle);
  }

  final _messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final List<MethodCall> calls = [];

  /// What "support" answers, or a thrown error.
  Object? support = 'available';

  /// What each "authenticate" answers, in order; the last one repeats.
  List<Object?> prompts = ['success'];

  Future<Object?> _handle(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'support':
        return _answer(support);
      case 'authenticate':
        final next = prompts.length > 1 ? prompts.removeAt(0) : prompts.first;
        return _answer(next);
      default:
        throw MissingPluginException();
    }
  }

  static Object? _answer(Object? value) {
    if (value is Exception) throw value;
    return value;
  }

  int count(String method) => calls.where((c) => c.method == method).length;

  void detach() =>
      _messenger.setMockMethodCallHandler(MethodChannelAppLock.channel, null);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeHelloRunner runner;
  const hello = WindowsHelloAppLock();

  setUp(() => runner = FakeHelloRunner());
  tearDown(() => runner.detach());

  group('support', () {
    test('reads the runner\'s three answers', () async {
      runner.support = 'available';
      expect(await hello.support(), AppLockSupport.available);
      runner.support = 'noDeviceCredential';
      expect(await hello.support(), AppLockSupport.noDeviceCredential);
      runner.support = 'unavailable';
      expect(await hello.support(), AppLockSupport.unsupportedPlatform);
    });

    test('a build without the runner half never offers the lock', () async {
      runner.detach();
      expect(await hello.support(), AppLockSupport.unsupportedPlatform);
    });

    test('a runner that throws never offers the lock', () async {
      runner.support = PlatformException(code: 'boom');
      expect(await hello.support(), AppLockSupport.unsupportedPlatform);
    });
  });

  group('authenticate', () {
    test('passes the reason and reads every answer', () async {
      const answers = {
        'success': AppLockOutcome.success,
        'failed': AppLockOutcome.failed,
        'cancelled': AppLockOutcome.cancelled,
        'lockedOut': AppLockOutcome.lockedOut,
        'unavailable': AppLockOutcome.unavailable,
      };
      for (final entry in answers.entries) {
        runner.prompts = [entry.key];
        expect(
          await hello.authenticate(reason: 'Unlock SecureShell Go'),
          entry.value,
          reason: entry.key,
        );
      }
      expect(
        runner.calls.last.arguments,
        {'reason': 'Unlock SecureShell Go'},
      );
    });

    test('fails closed: a prompt that cannot be raised stays locked',
        () async {
      runner.prompts = [PlatformException(code: 'E_FAIL')];
      expect(
        await hello.authenticate(reason: 'x'),
        AppLockOutcome.cancelled,
      );
      runner.prompts = ['something new'];
      expect(
        await hello.authenticate(reason: 'x'),
        AppLockOutcome.cancelled,
      );
      runner.prompts = [null];
      expect(
        await hello.authenticate(reason: 'x'),
        AppLockOutcome.cancelled,
      );
      runner.detach();
      expect(
        await hello.authenticate(reason: 'x'),
        AppLockOutcome.cancelled,
      );
    });

    test('a reply of the wrong type stays locked too', () async {
      // invokeMethod<String> casts the reply, and a cast that fails is a
      // TypeError, not a PlatformException.
      runner.prompts = [42];
      expect(
        await hello.authenticate(reason: 'x'),
        AppLockOutcome.cancelled,
      );
    });

    test('no screenshot flag is sent: Windows previews are live', () async {
      await hello.setSecureDisplay(true);
      await hello.setSecureDisplay(false);
      expect(runner.calls, isEmpty);
    });
  });

  group('through the lock controller', () {
    late DateTime now;
    late AppLockController controller;

    setUp(() {
      now = DateTime(2026, 10, 21, 9);
      controller = AppLockController(authenticator: hello, clock: () => now);
    });
    tearDown(() => controller.dispose());

    const on = AppSettings(appLockEnabled: true);

    test('locks at launch when Hello is set up, and Hello opens it',
        () async {
      await controller.start(on);
      expect(controller.isLocked, isTrue);
      runner.prompts = ['success'];
      expect(await controller.authenticate(), AppLockOutcome.success);
      expect(controller.isLocked, isFalse);
      expect(runner.count('authenticate'), 1);
    });

    test('a broken prompt keeps the gate shut, unflagged, and can be retried',
        () async {
      await controller.start(on);
      runner.prompts = [PlatformException(code: 'E_FAIL'), 'success'];
      expect(await controller.authenticate(), AppLockOutcome.cancelled);
      expect(controller.isLocked, isTrue);
      expect(controller.state.unavailable, isFalse);
      expect(controller.state.failedAttempts, 0);
      expect(await controller.authenticate(), AppLockOutcome.success);
      expect(controller.isLocked, isFalse);
    });

    test('anything else going wrong keeps the gate shut as well', () async {
      // The controller treats an authenticator that throws as one that
      // cannot run, and opens the gate; nothing may reach it that way.
      await controller.start(on);
      runner.prompts = [42];
      expect(await controller.authenticate(), AppLockOutcome.cancelled);
      expect(controller.isLocked, isTrue);
      expect(controller.state.unavailable, isFalse);
    });

    test('Hello\'s own retry limit counts toward the cooldown', () async {
      await controller.start(on);
      runner.prompts = ['failed'];
      for (var i = 0; i < AppLockController.attemptsBeforeCooldown; i++) {
        await controller.authenticate();
      }
      expect(controller.isInCooldown(), isTrue);
      final before = runner.count('authenticate');
      await controller.authenticate();
      expect(runner.count('authenticate'), before);
    });

    test('Hello switched off after the lock was set opens it, flagged',
        () async {
      await controller.start(on);
      runner.prompts = ['unavailable'];
      expect(await controller.authenticate(), AppLockOutcome.unavailable);
      expect(controller.isLocked, isFalse);
      expect(controller.state.unavailable, isTrue);
    });

    test('a PC without Hello set up does not lock at launch', () async {
      runner.support = 'noDeviceCredential';
      await controller.start(on);
      expect(controller.isLocked, isFalse);
      expect(controller.state.unavailable, isTrue);
      expect(runner.count('authenticate'), 0);
    });

    test('settings carried over from a phone cannot lock a PC with no runner',
        () async {
      runner.detach();
      await controller.start(on);
      expect(controller.isLocked, isFalse);
    });
  });

  group('platform wording', () {
    test('Windows is told to set up Hello, Android a screen lock', () {
      final en = lookupAppLocalizations(const Locale('en'));
      expect(
        AppLockPlatform.setupHintFor(isWindows: true).textIn(en),
        contains('Windows Hello'),
      );
      expect(
        AppLockPlatform.setupHintFor(isWindows: false).textIn(en),
        contains('screen lock'),
      );
      final windows = AppLockPlatform.reasonFor(
        isLinux: false,
        isWindows: true,
        isMacOS: false,
      );
      expect(windows, AppLockUnavailable.windowsHelloOff);
      expect(
        windows.textIn(en),
        isNot(contains('not available in this build')),
      );
    });

    test('the test host gets the class for its own platform', () {
      expect(
        createDefaultAppLockAuthenticator(),
        Platform.isWindows
            ? isA<WindowsHelloAppLock>()
            : isA<MethodChannelAppLock>(),
      );
    });
  });
}
