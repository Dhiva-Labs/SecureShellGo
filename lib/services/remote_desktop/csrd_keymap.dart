/// Keyboard mapping for the remote desktop: the port of `crossshell-proto`'s
/// `keymap.rs` evdev constants, and the table that turns the keys Flutter
/// reports into them.
///
/// The wire carries Linux evdev keycodes (`linux/input-event-codes.h`):
/// physical key positions, not characters. The remote's own keyboard layout
/// decides what a key types, exactly as for a keyboard plugged into it, so
/// nothing here knows about layouts. The agent maps evdev onward itself
/// (to XKB keycodes on X11, to set-1 scancodes for `SendInput` on Windows).
///
/// Flutter names a physical key by its USB HID usage
/// (`PhysicalKeyboardKey.usbHidUsage`) on every platform, which is what
/// [csrdEvdevForUsbHid] takes. No Flutter import is needed for that: it is
/// just an int.
library;

/// evdev codes from `linux/input-event-codes.h`: every one `keymap.rs`
/// names, plus the rest of the main block and function row, and the codes
/// [csrdEvdevForUsbHid] produces.
abstract final class CsrdEvdev {
  static const keyEsc = 1;
  static const key1 = 2;
  static const key2 = 3;
  static const key3 = 4;
  static const key4 = 5;
  static const key5 = 6;
  static const key6 = 7;
  static const key7 = 8;
  static const key8 = 9;
  static const key9 = 10;
  static const key0 = 11;
  static const keyMinus = 12;
  static const keyEqual = 13;
  static const keyBackspace = 14;
  static const keyTab = 15;
  static const keyQ = 16;
  static const keyW = 17;
  static const keyE = 18;
  static const keyR = 19;
  static const keyT = 20;
  static const keyY = 21;
  static const keyU = 22;
  static const keyI = 23;
  static const keyO = 24;
  static const keyP = 25;
  static const keyLeftBrace = 26;
  static const keyRightBrace = 27;
  static const keyEnter = 28;
  static const keyLeftCtrl = 29;
  static const keyA = 30;
  static const keyS = 31;
  static const keyD = 32;
  static const keyF = 33;
  static const keyG = 34;
  static const keyH = 35;
  static const keyJ = 36;
  static const keyK = 37;
  static const keyL = 38;
  static const keySemicolon = 39;
  static const keyApostrophe = 40;
  static const keyGrave = 41;
  static const keyLeftShift = 42;
  static const keyBackslash = 43;
  static const keyZ = 44;
  static const keyX = 45;
  static const keyC = 46;
  static const keyV = 47;
  static const keyB = 48;
  static const keyN = 49;
  static const keyM = 50;
  static const keyComma = 51;
  static const keyDot = 52;
  static const keySlash = 53;
  static const keyRightShift = 54;
  static const keyKpAsterisk = 55;
  static const keyLeftAlt = 56;
  static const keySpace = 57;
  static const keyCapsLock = 58;
  static const keyF1 = 59;
  static const keyF2 = 60;
  static const keyF3 = 61;
  static const keyF4 = 62;
  static const keyF5 = 63;
  static const keyF6 = 64;
  static const keyF7 = 65;
  static const keyF8 = 66;
  static const keyF9 = 67;
  static const keyF10 = 68;
  static const keyNumLock = 69;
  static const keyScrollLock = 70;
  static const keyKp7 = 71;
  static const keyKp8 = 72;
  static const keyKp9 = 73;
  static const keyKpMinus = 74;
  static const keyKp4 = 75;
  static const keyKp5 = 76;
  static const keyKp6 = 77;
  static const keyKpPlus = 78;
  static const keyKp1 = 79;
  static const keyKp2 = 80;
  static const keyKp3 = 81;
  static const keyKp0 = 82;
  static const keyKpDot = 83;
  static const keyZenkakuHankaku = 85;
  static const key102nd = 86;
  static const keyF11 = 87;
  static const keyF12 = 88;
  static const keyRo = 89;
  static const keyKatakana = 90;
  static const keyHiragana = 91;
  static const keyHenkan = 92;
  static const keyKatakanaHiragana = 93;
  static const keyMuhenkan = 94;
  static const keyKpEnter = 96;
  static const keyRightCtrl = 97;
  static const keyKpSlash = 98;
  static const keySysRq = 99;
  static const keyRightAlt = 100;
  static const keyHome = 102;
  static const keyUp = 103;
  static const keyPageUp = 104;
  static const keyLeft = 105;
  static const keyRight = 106;
  static const keyEnd = 107;
  static const keyDown = 108;
  static const keyPageDown = 109;
  static const keyInsert = 110;
  static const keyDelete = 111;
  static const keyMute = 113;
  static const keyVolumeDown = 114;
  static const keyVolumeUp = 115;
  static const keyPower = 116;
  static const keyKpEqual = 117;
  static const keyPause = 119;
  static const keyKpComma = 121;
  static const keyHangeul = 122;
  static const keyHanja = 123;
  static const keyYen = 124;
  static const keyLeftMeta = 125;
  static const keyRightMeta = 126;
  static const keyCompose = 127;
  static const keyStop = 128;
  static const keyAgain = 129;
  static const keyProps = 130;
  static const keyUndo = 131;
  static const keyCopy = 133;
  static const keyOpen = 134;
  static const keyPaste = 135;
  static const keyFind = 136;
  static const keyCut = 137;
  static const keyHelp = 138;
  static const keyCalc = 140;
  static const keySleep = 142;
  static const keyWakeUp = 143;
  static const keyFile = 144;
  static const keyMail = 155;
  static const keyBookmarks = 156;
  static const keyBack = 158;
  static const keyForward = 159;
  static const keyEjectCd = 161;
  static const keyNextSong = 163;
  static const keyPlayPause = 164;
  static const keyPreviousSong = 165;
  static const keyStopCd = 166;
  static const keyConfig = 171;
  static const keyHomepage = 172;
  static const keyRefresh = 173;
  static const keyKpLeftParen = 179;
  static const keyKpRightParen = 180;
  static const keyF13 = 183;
  static const keyF14 = 184;
  static const keyF15 = 185;
  static const keyF16 = 186;
  static const keyF17 = 187;
  static const keyF18 = 188;
  static const keyF19 = 189;
  static const keyF20 = 190;
  static const keyF21 = 191;
  static const keyF22 = 192;
  static const keyF23 = 193;
  static const keyF24 = 194;
  static const keySuspend = 205;
  static const keySearch = 217;
  static const keyPower2 = 356;
  static const keyFn = 0x1d0;

  static const btnLeft = 0x110;
  static const btnRight = 0x111;
  static const btnMiddle = 0x112;
  static const btnSide = 0x113;
  static const btnExtra = 0x114;
}

/// The evdev code for the key Flutter reports as [usbHidUsage]
/// (`PhysicalKeyboardKey.usbHidUsage`), or null when it is not forwarded.
///
/// The keys forwarded are the ones CrossShell's own viewer forwards, and
/// the same ones it leaves out: Power, Sleep and WakeUp act on the machine,
/// not the session, and Fn never leaves the keyboard. The codes are the
/// inverse of Flutter's own evdev → key mapping on Linux, so on a Linux
/// client every key reaches the remote as the code it had locally. Two keys
/// differ from CrossShell's table for that reason (LaunchApp1 is
/// `KEY_FILE`, MediaSelect `KEY_CONFIG`), and Props, for which Flutter has
/// no evdev code, follows CrossShell (`KEY_PROPS`).
///
/// On Linux, keys Flutter has no name for arrive in its GTK plane as the
/// raw XKB keycode, which is evdev + 8 on every modern keymap; those are
/// passed through as CrossShell does for winit's unidentified keys, minus
/// the same machine-level keys.
int? csrdEvdevForUsbHid(int usbHidUsage) {
  final known = _usbHidToEvdev[usbHidUsage];
  if (known != null) return known;
  if (usbHidUsage & _planeMask == _gtkPlane) {
    final code = (usbHidUsage & _valueMask) - 8;
    if (code < 1 || code > 0x2ff || _machineKeys.contains(code)) return null;
    if (code >= CsrdEvdev.keyFn && code <= _keyFnLast) return null;
    return code;
  }
  return null;
}

/// Flutter's `KeyboardKey.planeMask`, `valueMask` and `gtkPlane`.
const _planeMask = 0x0ff00000000;
const _valueMask = 0x000ffffffff;
const _gtkPlane = 0x01500000000;

/// `KEY_FN_RIGHT_SHIFT`, the last of the Fn-combination codes.
const _keyFnLast = 0x1e5;

/// Keys that act on the machine rather than the session.
const _machineKeys = {
  CsrdEvdev.keyPower,
  CsrdEvdev.keySleep,
  CsrdEvdev.keyWakeUp,
  CsrdEvdev.keySuspend,
  CsrdEvdev.keyPower2,
};

/// USB HID usage (page << 16 | id, as Flutter reports it) → evdev. Generated
/// from Flutter's `physical_key_data.g.json`, restricted to CrossShell's
/// forwarded set; the comment is the key's W3C `code` name.
const Map<int, int> _usbHidToEvdev = {
  // Keyboard page (0x07).
  0x00070004: 30, // KeyA
  0x00070005: 48, // KeyB
  0x00070006: 46, // KeyC
  0x00070007: 32, // KeyD
  0x00070008: 18, // KeyE
  0x00070009: 33, // KeyF
  0x0007000a: 34, // KeyG
  0x0007000b: 35, // KeyH
  0x0007000c: 23, // KeyI
  0x0007000d: 36, // KeyJ
  0x0007000e: 37, // KeyK
  0x0007000f: 38, // KeyL
  0x00070010: 50, // KeyM
  0x00070011: 49, // KeyN
  0x00070012: 24, // KeyO
  0x00070013: 25, // KeyP
  0x00070014: 16, // KeyQ
  0x00070015: 19, // KeyR
  0x00070016: 31, // KeyS
  0x00070017: 20, // KeyT
  0x00070018: 22, // KeyU
  0x00070019: 47, // KeyV
  0x0007001a: 17, // KeyW
  0x0007001b: 45, // KeyX
  0x0007001c: 21, // KeyY
  0x0007001d: 44, // KeyZ
  0x0007001e: 2, // Digit1
  0x0007001f: 3, // Digit2
  0x00070020: 4, // Digit3
  0x00070021: 5, // Digit4
  0x00070022: 6, // Digit5
  0x00070023: 7, // Digit6
  0x00070024: 8, // Digit7
  0x00070025: 9, // Digit8
  0x00070026: 10, // Digit9
  0x00070027: 11, // Digit0
  0x00070028: 28, // Enter
  0x00070029: 1, // Escape
  0x0007002a: 14, // Backspace
  0x0007002b: 15, // Tab
  0x0007002c: 57, // Space
  0x0007002d: 12, // Minus
  0x0007002e: 13, // Equal
  0x0007002f: 26, // BracketLeft
  0x00070030: 27, // BracketRight
  0x00070031: 43, // Backslash
  0x00070033: 39, // Semicolon
  0x00070034: 40, // Quote
  0x00070035: 41, // Backquote
  0x00070036: 51, // Comma
  0x00070037: 52, // Period
  0x00070038: 53, // Slash
  0x00070039: 58, // CapsLock
  0x0007003a: 59, // F1
  0x0007003b: 60, // F2
  0x0007003c: 61, // F3
  0x0007003d: 62, // F4
  0x0007003e: 63, // F5
  0x0007003f: 64, // F6
  0x00070040: 65, // F7
  0x00070041: 66, // F8
  0x00070042: 67, // F9
  0x00070043: 68, // F10
  0x00070044: 87, // F11
  0x00070045: 88, // F12
  0x00070046: 99, // PrintScreen
  0x00070047: 70, // ScrollLock
  0x00070048: 119, // Pause
  0x00070049: 110, // Insert
  0x0007004a: 102, // Home
  0x0007004b: 104, // PageUp
  0x0007004c: 111, // Delete
  0x0007004d: 107, // End
  0x0007004e: 109, // PageDown
  0x0007004f: 106, // ArrowRight
  0x00070050: 105, // ArrowLeft
  0x00070051: 108, // ArrowDown
  0x00070052: 103, // ArrowUp
  0x00070053: 69, // NumLock
  0x00070054: 98, // NumpadDivide
  0x00070055: 55, // NumpadMultiply
  0x00070056: 74, // NumpadSubtract
  0x00070057: 78, // NumpadAdd
  0x00070058: 96, // NumpadEnter
  0x00070059: 79, // Numpad1
  0x0007005a: 80, // Numpad2
  0x0007005b: 81, // Numpad3
  0x0007005c: 75, // Numpad4
  0x0007005d: 76, // Numpad5
  0x0007005e: 77, // Numpad6
  0x0007005f: 71, // Numpad7
  0x00070060: 72, // Numpad8
  0x00070061: 73, // Numpad9
  0x00070062: 82, // Numpad0
  0x00070063: 83, // NumpadDecimal
  0x00070064: 86, // IntlBackslash
  0x00070065: 127, // ContextMenu
  0x00070067: 117, // NumpadEqual
  0x00070068: 183, // F13
  0x00070069: 184, // F14
  0x0007006a: 185, // F15
  0x0007006b: 186, // F16
  0x0007006c: 187, // F17
  0x0007006d: 188, // F18
  0x0007006e: 189, // F19
  0x0007006f: 190, // F20
  0x00070070: 191, // F21
  0x00070071: 192, // F22
  0x00070072: 193, // F23
  0x00070073: 194, // F24
  0x00070074: 134, // Open
  0x00070075: 138, // Help
  0x00070079: 129, // Again
  0x0007007a: 131, // Undo
  0x0007007b: 137, // Cut
  0x0007007c: 133, // Copy
  0x0007007d: 135, // Paste
  0x0007007e: 136, // Find
  0x0007007f: 113, // AudioVolumeMute
  0x00070080: 115, // AudioVolumeUp
  0x00070081: 114, // AudioVolumeDown
  0x00070085: 121, // NumpadComma
  0x00070087: 89, // IntlRo
  0x00070088: 93, // KanaMode
  0x00070089: 124, // IntlYen
  0x0007008a: 92, // Convert
  0x0007008b: 94, // NonConvert
  0x00070090: 122, // Lang1
  0x00070091: 123, // Lang2
  0x00070092: 90, // Lang3
  0x00070093: 91, // Lang4
  0x00070094: 85, // Lang5
  0x000700a3: 130, // Props
  0x000700b6: 179, // NumpadParenLeft
  0x000700b7: 180, // NumpadParenRight
  0x000700e0: 29, // ControlLeft
  0x000700e1: 42, // ShiftLeft
  0x000700e2: 56, // AltLeft
  0x000700e3: 125, // MetaLeft
  0x000700e4: 97, // ControlRight
  0x000700e5: 54, // ShiftRight
  0x000700e6: 100, // AltRight
  0x000700e7: 126, // MetaRight
  // Consumer page (0x0c).
  0x000c00b5: 163, // MediaTrackNext
  0x000c00b6: 165, // MediaTrackPrevious
  0x000c00b7: 166, // MediaStop
  0x000c00b8: 161, // Eject
  0x000c00cd: 164, // MediaPlayPause
  0x000c0183: 171, // MediaSelect
  0x000c018a: 155, // LaunchMail
  0x000c0192: 140, // LaunchApp2
  0x000c0194: 144, // LaunchApp1
  0x000c0221: 217, // BrowserSearch
  0x000c0223: 172, // BrowserHome
  0x000c0224: 158, // BrowserBack
  0x000c0225: 159, // BrowserForward
  0x000c0226: 128, // BrowserStop
  0x000c0227: 173, // BrowserRefresh
  0x000c022a: 156, // BrowserFavorites
};
