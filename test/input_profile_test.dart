import 'dart:ui' show KeyEventDeviceType;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/app_settings.dart';
import 'package:secure_shell_go/services/input_profile.dart';

/// What the app has seen the user's hands do, and what a screen makes of it.
void main() {
  group('with nothing seen yet', () {
    test('a desktop is a mouse and a keyboard', () {
      for (final platform in [
        TargetPlatform.linux,
        TargetPlatform.windows,
        TargetPlatform.macOS,
      ]) {
        final devices = InputProfile().resolve(platform);
        expect(devices.mouse, isTrue, reason: '$platform');
        expect(devices.keyboard, isTrue, reason: '$platform');
        expect(devices.touch, isFalse, reason: '$platform');
        expect(devices.pointer, PointerClass.mouse, reason: '$platform');
      }
    });

    test('a phone or tablet is touch, with no keyboard', () {
      final devices = InputProfile().resolve(TargetPlatform.android);
      expect(devices.touch, isTrue);
      expect(devices.mouse, isFalse);
      expect(devices.keyboard, isFalse);
      expect(devices.pointer, PointerClass.touch);
    });
  });

  group('transitions', () {
    test('touch on a desktop: a Windows tablet, until a key is typed', () {
      final profile = InputProfile();

      profile.notePointer(PointerDeviceKind.touch);
      var devices = profile.resolve(TargetPlatform.windows);
      expect(devices.touch, isTrue);
      expect(devices.mouse, isFalse);
      // A finger the only pointer seen: no keyboard is assumed any more.
      expect(devices.keyboard, isFalse);
      expect(devices.pointer, PointerClass.touch);

      profile.noteHardwareKey();
      devices = profile.resolve(TargetPlatform.windows);
      expect(devices.keyboard, isTrue);
      expect(devices.touch, isTrue);
    });

    test('a laptop someone touched once keeps its keyboard', () {
      final profile = InputProfile()
        ..notePointer(PointerDeviceKind.mouse)
        ..notePointer(PointerDeviceKind.touch);
      final devices = profile.resolve(TargetPlatform.linux);
      expect(devices.keyboard, isTrue);
      expect(devices.mouse, isTrue);
      expect(devices.touch, isTrue);
      expect(devices.pointer, PointerClass.touch);
    });

    test('a mouse on Android: a DeX desk, then its keyboard', () {
      final profile = InputProfile()..notePointer(PointerDeviceKind.mouse);
      var devices = profile.resolve(TargetPlatform.android);
      expect(devices.mouse, isTrue);
      // Only a mouse has been seen, so no 48dp padding is needed for it.
      expect(devices.touch, isFalse);
      expect(devices.keyboard, isFalse);
      expect(devices.pointer, PointerClass.mouse);

      profile.noteHardwareKey();
      devices = profile.resolve(TargetPlatform.android);
      expect(devices.keyboard, isTrue);
    });

    test('what has been seen stays seen; only the last pointer moves', () {
      final profile = InputProfile()
        ..notePointer(PointerDeviceKind.trackpad)
        ..notePointer(PointerDeviceKind.stylus);
      final devices = profile.resolve(TargetPlatform.android);
      expect(devices.mouse, isTrue);
      expect(devices.touch, isTrue);
      expect(devices.pointer, PointerClass.touch);

      profile.notePointer(PointerDeviceKind.mouse);
      expect(profile.resolve(TargetPlatform.android).pointer,
          PointerClass.mouse);
    });

    test('listeners hear changes, not every event', () {
      final profile = InputProfile();
      var heard = 0;
      profile.addListener(() => heard++);

      profile.notePointer(PointerDeviceKind.touch);
      profile.notePointer(PointerDeviceKind.touch);
      profile.notePointer(PointerDeviceKind.touch);
      expect(heard, 1);

      profile.noteHardwareKey();
      profile.noteHardwareKey();
      expect(heard, 2);

      profile.notePointer(PointerDeviceKind.mouse);
      profile.notePointer(PointerDeviceKind.unknown);
      expect(heard, 3);
    });
  });

  group('attached to the bindings', () {
    late InputProfile profile;

    setUp(() => profile = InputProfile());
    tearDown(() => profile.dispose());

    testWidgets('hears the pointers and keys the app is given',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      profile.attach();
      expect(profile.attached, isTrue);

      // A mouse moving over the window is a mouse in use.
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(100, 100));
      expect(profile.mouseSeen, isFalse,
          reason: 'arriving in the window is not using it');
      await mouse.moveTo(const Offset(120, 120));
      expect(profile.mouseSeen, isTrue);
      expect(profile.touchSeen, isFalse);
      await mouse.removePointer();

      await tester.tapAt(const Offset(200, 200));
      expect(profile.touchSeen, isTrue);
      expect(profile.lastPointer, PointerClass.touch);

      // Keys a soft keyboard sends too, or a phone's own buttons, prove
      // nothing.
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.audioVolumeUp);
      expect(profile.keyboardSeen, isFalse);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      expect(profile.keyboardSeen, isTrue);

      profile.detach();
      expect(profile.attached, isFalse);
    });

    testWidgets('a modifier on its own is a keyboard', (tester) async {
      await tester.pumpWidget(const SizedBox());
      profile.attach();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(profile.keyboardSeen, isTrue);
    });
  });

  group('hardware key evidence', () {
    KeyEvent down(
      LogicalKeyboardKey key, {
      String? character,
      KeyEventDeviceType device = KeyEventDeviceType.keyboard,
      bool synthesized = false,
    }) =>
        KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.keyA,
          logicalKey: key,
          character: character,
          timeStamp: Duration.zero,
          deviceType: device,
          synthesized: synthesized,
        );

    test('printable characters and modifiers count', () {
      expect(
        InputProfile.isHardwareKeyEvidence(
            down(LogicalKeyboardKey.keyQ, character: 'q')),
        isTrue,
      );
      expect(
        InputProfile.isHardwareKeyEvidence(
            down(LogicalKeyboardKey.slash, character: '/')),
        isTrue,
      );
      expect(
        InputProfile.isHardwareKeyEvidence(down(LogicalKeyboardKey.metaLeft)),
        isTrue,
      );
      expect(
        InputProfile.isHardwareKeyEvidence(down(LogicalKeyboardKey.escape)),
        isTrue,
      );
    });

    test('what a soft keyboard or a remote sends does not', () {
      for (final key in [
        LogicalKeyboardKey.backspace,
        LogicalKeyboardKey.enter,
        LogicalKeyboardKey.delete,
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.goBack,
        LogicalKeyboardKey.audioVolumeDown,
      ]) {
        expect(InputProfile.isHardwareKeyEvidence(down(key)), isFalse,
            reason: key.debugName);
      }
      // A space is a character, and the one soft keyboards send most.
      expect(
        InputProfile.isHardwareKeyEvidence(
            down(LogicalKeyboardKey.space, character: ' ')),
        isFalse,
      );
      // A game pad's buttons are not typing.
      expect(
        InputProfile.isHardwareKeyEvidence(down(LogicalKeyboardKey.keyA,
            character: 'a', device: KeyEventDeviceType.gamepad)),
        isFalse,
      );
      expect(
        InputProfile.isHardwareKeyEvidence(down(LogicalKeyboardKey.keyA,
            character: 'a', synthesized: true)),
        isFalse,
      );
      expect(
        InputProfile.isHardwareKeyEvidence(KeyUpEvent(
          physicalKey: PhysicalKeyboardKey.keyA,
          logicalKey: LogicalKeyboardKey.keyA,
          timeStamp: Duration.zero,
        )),
        isFalse,
      );
    });
  });

  group('the extra-keys row', () {
    const touchOnly = InputDevices(
      touch: true,
      mouse: false,
      keyboard: false,
      pointer: PointerClass.touch,
    );
    const keyboardCover = InputDevices(
      touch: true,
      mouse: false,
      keyboard: true,
      pointer: PointerClass.touch,
    );
    const keyboardCoverTypingOnGlass = InputDevices(
      touch: true,
      mouse: false,
      keyboard: true,
      pointer: PointerClass.touch,
      softKeyboardOpen: true,
    );

    test('automatically: there without a keyboard, gone with one', () {
      expect(touchOnly.showsKeyBar(KeyBarMode.auto), isTrue);
      expect(keyboardCover.showsKeyBar(KeyBarMode.auto), isFalse);
      // The cover folded back and the on-screen keyboard up: back it comes.
      expect(keyboardCoverTypingOnGlass.showsKeyBar(KeyBarMode.auto), isTrue);
    });

    test('always and never mean it', () {
      for (final devices in [
        touchOnly,
        keyboardCover,
        keyboardCoverTypingOnGlass,
      ]) {
        expect(devices.showsKeyBar(KeyBarMode.always), isTrue);
        expect(devices.showsKeyBar(KeyBarMode.never), isFalse);
      }
    });
  });

  group('InputProfileScope', () {
    testWidgets('rebuilds what reads it, and pads targets once touch is seen',
        (tester) async {
      final profile = InputProfile();
      addTearDown(profile.dispose);
      final seen = <InputDevices>[];
      final densities = <MaterialTapTargetSize>[];

      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(
          platform: TargetPlatform.linux,
          visualDensity: VisualDensity.compact,
        ),
        builder: (context, child) =>
            InputProfileScope(profile: profile, child: child!),
        home: Builder(builder: (context) {
          seen.add(InputProfile.of(context));
          densities.add(Theme.of(context).materialTapTargetSize);
          return const SizedBox();
        }),
      ));
      expect(seen.last.mouse, isTrue);
      expect(densities.last, MaterialTapTargetSize.shrinkWrap);

      profile.notePointer(PointerDeviceKind.touch);
      await tester.pump();
      expect(seen.last.touch, isTrue);
      expect(seen.last.keyboard, isFalse);
      expect(densities.last, MaterialTapTargetSize.padded);

      tester.view.viewInsets = const FakeViewPadding(bottom: 900);
      addTearDown(tester.view.resetViewInsets);
      await tester.pump();
      expect(seen.last.softKeyboardOpen, isTrue);
    });

    testWidgets('a strip of keyboard toolbar is not a soft keyboard',
        (tester) async {
      final profile = InputProfile();
      addTearDown(profile.dispose);
      late InputDevices devices;
      // Physical pixels: 48dp at the default 3x test ratio.
      tester.view.viewInsets = const FakeViewPadding(bottom: 144);
      addTearDown(tester.view.resetViewInsets);

      await tester.pumpWidget(MaterialApp(
        builder: (context, child) =>
            InputProfileScope(profile: profile, child: child!),
        home: Builder(builder: (context) {
          devices = InputProfile.of(context);
          return const SizedBox();
        }),
      ));
      expect(devices.softKeyboardOpen, isFalse);
    });
  });
}
