import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/remote_desktop/csrd_keymap.dart';

/// The keymap is pure Dart and takes plain ints, but the ints come from
/// Flutter's `PhysicalKeyboardKey`, so that is what these tests feed it.
int? evdev(PhysicalKeyboardKey key) => csrdEvdevForUsbHid(key.usbHidUsage);

const gtkPlane = 0x01500000000;

void main() {
  test('letters, digits and punctuation sit where evdev puts them', () {
    expect(evdev(PhysicalKeyboardKey.keyA), CsrdEvdev.keyA);
    expect(evdev(PhysicalKeyboardKey.keyQ), CsrdEvdev.keyQ);
    expect(evdev(PhysicalKeyboardKey.keyZ), CsrdEvdev.keyZ);
    expect(evdev(PhysicalKeyboardKey.digit1), CsrdEvdev.key1);
    expect(evdev(PhysicalKeyboardKey.digit0), CsrdEvdev.key0);
    expect(evdev(PhysicalKeyboardKey.minus), CsrdEvdev.keyMinus);
    expect(evdev(PhysicalKeyboardKey.backquote), CsrdEvdev.keyGrave);
    expect(evdev(PhysicalKeyboardKey.quote), CsrdEvdev.keyApostrophe);
    expect(evdev(PhysicalKeyboardKey.intlBackslash), CsrdEvdev.key102nd);
  });

  test('modifiers, both sides', () {
    expect(evdev(PhysicalKeyboardKey.controlLeft), CsrdEvdev.keyLeftCtrl);
    expect(evdev(PhysicalKeyboardKey.controlRight), CsrdEvdev.keyRightCtrl);
    expect(evdev(PhysicalKeyboardKey.shiftLeft), CsrdEvdev.keyLeftShift);
    expect(evdev(PhysicalKeyboardKey.shiftRight), CsrdEvdev.keyRightShift);
    expect(evdev(PhysicalKeyboardKey.altLeft), CsrdEvdev.keyLeftAlt);
    expect(evdev(PhysicalKeyboardKey.altRight), CsrdEvdev.keyRightAlt);
    expect(evdev(PhysicalKeyboardKey.metaLeft), CsrdEvdev.keyLeftMeta);
    expect(evdev(PhysicalKeyboardKey.metaRight), CsrdEvdev.keyRightMeta);
  });

  test('navigation keys and the keypad are different keys', () {
    expect(evdev(PhysicalKeyboardKey.arrowUp), CsrdEvdev.keyUp);
    expect(evdev(PhysicalKeyboardKey.numpad8), CsrdEvdev.keyKp8);
    expect(evdev(PhysicalKeyboardKey.enter), CsrdEvdev.keyEnter);
    expect(evdev(PhysicalKeyboardKey.numpadEnter), CsrdEvdev.keyKpEnter);
    expect(evdev(PhysicalKeyboardKey.delete), CsrdEvdev.keyDelete);
    expect(evdev(PhysicalKeyboardKey.numpadDecimal), CsrdEvdev.keyKpDot);
    expect(evdev(PhysicalKeyboardKey.printScreen), CsrdEvdev.keySysRq);
    expect(evdev(PhysicalKeyboardKey.contextMenu), CsrdEvdev.keyCompose);
  });

  test('function keys, F1 to F24', () {
    expect(evdev(PhysicalKeyboardKey.f1), CsrdEvdev.keyF1);
    expect(evdev(PhysicalKeyboardKey.f10), CsrdEvdev.keyF10);
    expect(evdev(PhysicalKeyboardKey.f11), CsrdEvdev.keyF11);
    expect(evdev(PhysicalKeyboardKey.f12), CsrdEvdev.keyF12);
    expect(evdev(PhysicalKeyboardKey.f13), CsrdEvdev.keyF13);
    expect(evdev(PhysicalKeyboardKey.f24), CsrdEvdev.keyF24);
  });

  test('media keys from both HID pages', () {
    expect(evdev(PhysicalKeyboardKey.audioVolumeMute), CsrdEvdev.keyMute);
    expect(evdev(PhysicalKeyboardKey.audioVolumeUp), CsrdEvdev.keyVolumeUp);
    expect(evdev(PhysicalKeyboardKey.mediaPlayPause), CsrdEvdev.keyPlayPause);
    expect(evdev(PhysicalKeyboardKey.mediaTrackNext), CsrdEvdev.keyNextSong);
    expect(evdev(PhysicalKeyboardKey.browserBack), CsrdEvdev.keyBack);
    expect(evdev(PhysicalKeyboardKey.launchApp1), CsrdEvdev.keyFile);
    expect(evdev(PhysicalKeyboardKey.mediaSelect), CsrdEvdev.keyConfig);
    expect(evdev(PhysicalKeyboardKey.props), CsrdEvdev.keyProps);
  });

  test('CJK input keys', () {
    expect(evdev(PhysicalKeyboardKey.lang1), CsrdEvdev.keyHangeul);
    expect(evdev(PhysicalKeyboardKey.lang2), CsrdEvdev.keyHanja);
    expect(evdev(PhysicalKeyboardKey.lang3), CsrdEvdev.keyKatakana);
    expect(evdev(PhysicalKeyboardKey.lang4), CsrdEvdev.keyHiragana);
    expect(evdev(PhysicalKeyboardKey.lang5), CsrdEvdev.keyZenkakuHankaku);
    expect(evdev(PhysicalKeyboardKey.kanaMode), CsrdEvdev.keyKatakanaHiragana);
    expect(evdev(PhysicalKeyboardKey.convert), CsrdEvdev.keyHenkan);
    expect(evdev(PhysicalKeyboardKey.nonConvert), CsrdEvdev.keyMuhenkan);
    expect(evdev(PhysicalKeyboardKey.intlRo), CsrdEvdev.keyRo);
    expect(evdev(PhysicalKeyboardKey.intlYen), CsrdEvdev.keyYen);
  });

  test('keys that act on the machine are not forwarded', () {
    expect(evdev(PhysicalKeyboardKey.power), isNull);
    expect(evdev(PhysicalKeyboardKey.sleep), isNull);
    expect(evdev(PhysicalKeyboardKey.wakeUp), isNull);
    expect(evdev(PhysicalKeyboardKey.fn), isNull);
    expect(evdev(PhysicalKeyboardKey.fnLock), isNull);
    expect(evdev(PhysicalKeyboardKey.brightnessUp), isNull);
  });

  test('every key with a Linux code reaches the remote as that code', () {
    // Where Flutter itself maps evdev → key on Linux, the table is its
    // inverse; checked through Flutter's own GTK table, via the XKB code.
    for (final entry in kLinuxToPhysicalKey.entries) {
      final xkb = entry.key;
      final mapped = csrdEvdevForUsbHid(entry.value.usbHidUsage);
      if (mapped != null) {
        expect(mapped, xkb - 8, reason: entry.value.debugName);
      }
    }
  });

  group('unidentified Linux keys', () {
    test('pass their XKB keycode through as evdev', () {
      // KEY_PROG3 (202): not a key Flutter has a name for.
      expect(csrdEvdevForUsbHid(gtkPlane | (202 + 8)), 202);
    });

    test('except the machine-level ones and the Fn combinations', () {
      expect(csrdEvdevForUsbHid(gtkPlane | (CsrdEvdev.keySuspend + 8)), isNull);
      expect(csrdEvdevForUsbHid(gtkPlane | (CsrdEvdev.keyPower2 + 8)), isNull);
      expect(csrdEvdevForUsbHid(gtkPlane | (CsrdEvdev.keyFn + 8)), isNull);
      expect(csrdEvdevForUsbHid(gtkPlane | (0x1e5 + 8)), isNull);
    });

    test('and nothing out of evdev range', () {
      expect(csrdEvdevForUsbHid(gtkPlane | 8), isNull);
      expect(csrdEvdevForUsbHid(gtkPlane | (0x300 + 8)), isNull);
    });

    test('from other platforms are not evdev, so are dropped', () {
      const androidPlane = 0x01100000000;
      const windowsPlane = 0x01600000000;
      expect(csrdEvdevForUsbHid(androidPlane | 38), isNull);
      expect(csrdEvdevForUsbHid(windowsPlane | 38), isNull);
    });
  });
}
