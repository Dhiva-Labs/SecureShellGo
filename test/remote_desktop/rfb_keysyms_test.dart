import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/remote_desktop/csrd_keymap.dart';
import 'package:secure_shell_go/services/remote_desktop/rfb_keysyms.dart';

void main() {
  test('letters, digits and punctuation are their unshifted US keysyms', () {
    const row = {
      CsrdEvdev.keyGrave: '`',
      CsrdEvdev.key1: '1',
      CsrdEvdev.key0: '0',
      CsrdEvdev.keyMinus: '-',
      CsrdEvdev.keyEqual: '=',
      CsrdEvdev.keyQ: 'q',
      CsrdEvdev.keyP: 'p',
      CsrdEvdev.keyLeftBrace: '[',
      CsrdEvdev.keyRightBrace: ']',
      CsrdEvdev.keyBackslash: r'\',
      CsrdEvdev.keyA: 'a',
      CsrdEvdev.keySemicolon: ';',
      CsrdEvdev.keyApostrophe: "'",
      CsrdEvdev.keyZ: 'z',
      CsrdEvdev.keyM: 'm',
      CsrdEvdev.keyComma: ',',
      CsrdEvdev.keyDot: '.',
      CsrdEvdev.keySlash: '/',
      CsrdEvdev.keySpace: ' ',
    };
    for (final e in row.entries) {
      expect(
        rfbKeysymForEvdev(e.key),
        e.value.codeUnitAt(0),
        reason: 'evdev ${e.key}',
      );
    }
    // Every letter key: Latin-1 keysyms are the characters themselves.
    const letters = 'qwertyuiopasdfghjklzxcvbnm';
    const codes = [
      16, 17, 18, 19, 20, 21, 22, 23, 24, 25, //
      30, 31, 32, 33, 34, 35, 36, 37, 38,
      44, 45, 46, 47, 48, 49, 50,
    ];
    for (var i = 0; i < letters.length; i++) {
      expect(rfbKeysymForEvdev(codes[i]), letters.codeUnitAt(i));
    }
  });

  test('modifiers go out as keysyms of their own', () {
    expect(rfbKeysymForEvdev(CsrdEvdev.keyLeftShift), 0xffe1);
    expect(rfbKeysymForEvdev(CsrdEvdev.keyRightShift), 0xffe2);
    expect(rfbKeysymForEvdev(CsrdEvdev.keyLeftCtrl), 0xffe3);
    expect(rfbKeysymForEvdev(CsrdEvdev.keyRightCtrl), 0xffe4);
    expect(rfbKeysymForEvdev(CsrdEvdev.keyLeftAlt), 0xffe9);
    expect(rfbKeysymForEvdev(CsrdEvdev.keyRightAlt), 0xffea);
    expect(rfbKeysymForEvdev(CsrdEvdev.keyCapsLock), 0xffe5);
    expect(rfbKeysymForEvdev(CsrdEvdev.keyLeftMeta), 0xffeb); // Super_L
    expect(rfbKeysymForEvdev(CsrdEvdev.keyRightMeta), 0xffec);
    expect(
      rfbKeysymForEvdev(
        CsrdEvdev.keyLeftMeta,
        commandKey: RfbCommandKey.metaKey,
      ),
      0xffe7, // Meta_L: Command on a Mac
    );
    expect(
      rfbKeysymForEvdev(
        CsrdEvdev.keyRightMeta,
        commandKey: RfbCommandKey.metaKey,
      ),
      0xffe8,
    );
  });

  test('function, editing, cursor and keypad keys', () {
    for (var n = 1; n <= 10; n++) {
      expect(rfbKeysymForEvdev(CsrdEvdev.keyF1 + n - 1), 0xffbe + n - 1);
    }
    expect(rfbKeysymForEvdev(CsrdEvdev.keyF11), 0xffc8);
    expect(rfbKeysymForEvdev(CsrdEvdev.keyF12), 0xffc9);
    expect(rfbKeysymForEvdev(CsrdEvdev.keyF13), 0xffca);
    expect(rfbKeysymForEvdev(CsrdEvdev.keyF24), 0xffd5);
    const named = {
      CsrdEvdev.keyEsc: 0xff1b,
      CsrdEvdev.keyBackspace: 0xff08,
      CsrdEvdev.keyTab: 0xff09,
      CsrdEvdev.keyEnter: 0xff0d,
      CsrdEvdev.keyInsert: 0xff63,
      CsrdEvdev.keyDelete: 0xffff,
      CsrdEvdev.keyHome: 0xff50,
      CsrdEvdev.keyEnd: 0xff57,
      CsrdEvdev.keyPageUp: 0xff55,
      CsrdEvdev.keyPageDown: 0xff56,
      CsrdEvdev.keyLeft: 0xff51,
      CsrdEvdev.keyUp: 0xff52,
      CsrdEvdev.keyRight: 0xff53,
      CsrdEvdev.keyDown: 0xff54,
      CsrdEvdev.keySysRq: 0xff61, // Print Screen
      CsrdEvdev.keyPause: 0xff13,
      CsrdEvdev.keyScrollLock: 0xff14,
      CsrdEvdev.keyNumLock: 0xff7f,
      CsrdEvdev.keyCompose: 0xff67, // Menu
      CsrdEvdev.keyKpEnter: 0xff8d,
      CsrdEvdev.keyKpSlash: 0xffaf,
      CsrdEvdev.keyKpAsterisk: 0xffaa,
      CsrdEvdev.keyKpMinus: 0xffad,
      CsrdEvdev.keyKpPlus: 0xffab,
      CsrdEvdev.keyKpDot: 0xffae,
      CsrdEvdev.keyKp0: 0xffb0,
      CsrdEvdev.keyKp5: 0xffb5,
      CsrdEvdev.keyKp9: 0xffb9,
      CsrdEvdev.keyMute: 0x1008ff12,
      CsrdEvdev.keyVolumeUp: 0x1008ff13,
      CsrdEvdev.keyPlayPause: 0x1008ff14,
    };
    for (final e in named.entries) {
      expect(rfbKeysymForEvdev(e.key), e.value, reason: 'evdev ${e.key}');
    }
  });

  test('keys that act on the machine are never sent', () {
    for (final code in [
      CsrdEvdev.keyPower,
      CsrdEvdev.keySleep,
      CsrdEvdev.keyWakeUp,
      CsrdEvdev.keySuspend,
      CsrdEvdev.keyFn,
    ]) {
      expect(rfbKeysymForEvdev(code), isNull, reason: 'evdev $code');
    }
    expect(rfbKeysymForEvdev(0), isNull);
    expect(rfbKeysymForEvdev(0x2ff), isNull);
  });

  test('nearly every key the screen forwards has a keysym', () {
    final forwarded = <int>{};
    for (var usage = 0x00070000; usage <= 0x000700ff; usage++) {
      final code = csrdEvdevForUsbHid(usage);
      if (code != null) forwarded.add(code);
    }
    for (var usage = 0x000c0000; usage <= 0x000c0300; usage++) {
      final code = csrdEvdevForUsbHid(usage);
      if (code != null) forwarded.add(code);
    }
    final missing = forwarded.where((c) => rfbKeysymForEvdev(c) == null);
    // Props: there is no keysym X servers agree on.
    expect(missing, [CsrdEvdev.keyProps]);
    expect(
      rfbMappedEvdevCodes.toSet().containsAll(
        forwarded.difference({CsrdEvdev.keyProps}),
      ),
      isTrue,
    );
  });
}
