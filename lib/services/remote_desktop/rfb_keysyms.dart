/// Keys for VNC: evdev codes, which is what the remote-desktop screen hands
/// every backend (see `csrd_keymap.dart`), turned into the X keysyms RFB's
/// KeyEvent carries.
///
/// The table is the US layout's unshifted keysym for each key position:
/// `KEY_A` is `a`, `KEY_1` is `1`, `KEY_SLASH` is `/`. Modifiers go out as
/// keysyms of their own (Shift_L, Control_L, Alt_L, …), and the server
/// combines them with the keys as the remote's own keyboard handling does,
/// so Shift + `a` types `A`. That is how TigerVNC's and libvncserver's
/// servers expect a client to send them, and how Apple's Screen Sharing
/// handles keys it gets from VNC viewers.
///
/// A layout other than US on the client changes nothing here: keys are
/// sent by position, as the CrossShell agent's evdev codes are. Characters
/// a US keyboard cannot type at all (é on a French key, say) are therefore
/// not reachable as keystrokes; pasting them through the clipboard is.
library;

import 'csrd_keymap.dart';

/// Which keysym the Meta / Windows / Command key goes out as.
enum RfbCommandKey {
  /// `Super_L` / `Super_R`: what X desktops bind the Windows key to.
  superKey,

  /// `Meta_L` / `Meta_R`: what macOS Screen Sharing reads as Command.
  metaKey,
}

/// X keysyms used here, from `X11/keysymdef.h` and `XF86keysym.h`.
abstract final class RfbKeysym {
  static const backSpace = 0xff08;
  static const tab = 0xff09;
  static const returnKey = 0xff0d;
  static const pause = 0xff13;
  static const scrollLock = 0xff14;
  static const sysReq = 0xff15;
  static const escape = 0xff1b;
  static const muhenkan = 0xff22;
  static const henkanMode = 0xff23;
  static const hiragana = 0xff25;
  static const katakana = 0xff26;
  static const hiraganaKatakana = 0xff27;
  static const zenkakuHankaku = 0xff2a;
  static const hangul = 0xff31;
  static const hangulHanja = 0xff34;
  static const home = 0xff50;
  static const left = 0xff51;
  static const up = 0xff52;
  static const right = 0xff53;
  static const down = 0xff54;
  static const pageUp = 0xff55;
  static const pageDown = 0xff56;
  static const end = 0xff57;
  static const print = 0xff61;
  static const insert = 0xff63;
  static const undo = 0xff65;
  static const redo = 0xff66;
  static const menu = 0xff67;
  static const find = 0xff68;
  static const cancel = 0xff69;
  static const help = 0xff6a;
  static const numLock = 0xff7f;
  static const kpEnter = 0xff8d;
  static const kpMultiply = 0xffaa;
  static const kpAdd = 0xffab;
  static const kpSeparator = 0xffac;
  static const kpSubtract = 0xffad;
  static const kpDecimal = 0xffae;
  static const kpDivide = 0xffaf;
  static const kp0 = 0xffb0;
  static const kpEqual = 0xffbd;
  static const f1 = 0xffbe;
  static const f13 = 0xffca;
  static const shiftL = 0xffe1;
  static const shiftR = 0xffe2;
  static const controlL = 0xffe3;
  static const controlR = 0xffe4;
  static const capsLock = 0xffe5;
  static const metaL = 0xffe7;
  static const metaR = 0xffe8;
  static const altL = 0xffe9;
  static const altR = 0xffea;
  static const superL = 0xffeb;
  static const superR = 0xffec;
  static const delete = 0xffff;
  static const yen = 0x00a5;

  static const xf86AudioLowerVolume = 0x1008ff11;
  static const xf86AudioMute = 0x1008ff12;
  static const xf86AudioRaiseVolume = 0x1008ff13;
  static const xf86AudioPlay = 0x1008ff14;
  static const xf86AudioStop = 0x1008ff15;
  static const xf86AudioPrev = 0x1008ff16;
  static const xf86AudioNext = 0x1008ff17;
  static const xf86HomePage = 0x1008ff18;
  static const xf86Mail = 0x1008ff19;
  static const xf86Search = 0x1008ff1b;
  static const xf86Calculator = 0x1008ff1d;
  static const xf86Back = 0x1008ff26;
  static const xf86Forward = 0x1008ff27;
  static const xf86Eject = 0x1008ff2c;
  static const xf86Favorites = 0x1008ff30;
  static const xf86Copy = 0x1008ff57;
  static const xf86Cut = 0x1008ff58;
  static const xf86Explorer = 0x1008ff5d;
  static const xf86Open = 0x1008ff6b;
  static const xf86Paste = 0x1008ff6d;
  static const xf86Reload = 0x1008ff73;
  static const xf86Tools = 0x1008ff81;
}

/// The keysym for evdev [code], or null when the key is not sent at all.
///
/// The keys left out are the ones `csrdEvdevForUsbHid` never produces
/// (Power, Sleep, WakeUp, Fn) and the few with no keysym a server would
/// know what to do with.
int? rfbKeysymForEvdev(
  int code, {
  RfbCommandKey commandKey = RfbCommandKey.superKey,
}) {
  switch (code) {
    case CsrdEvdev.keyLeftMeta:
      return commandKey == RfbCommandKey.metaKey
          ? RfbKeysym.metaL
          : RfbKeysym.superL;
    case CsrdEvdev.keyRightMeta:
      return commandKey == RfbCommandKey.metaKey
          ? RfbKeysym.metaR
          : RfbKeysym.superR;
  }
  if (code >= CsrdEvdev.keyF1 && code <= CsrdEvdev.keyF10) {
    return RfbKeysym.f1 + code - CsrdEvdev.keyF1;
  }
  if (code >= CsrdEvdev.keyF13 && code <= CsrdEvdev.keyF24) {
    return RfbKeysym.f13 + code - CsrdEvdev.keyF13;
  }
  return _keysyms[code];
}

/// Every evdev code [rfbKeysymForEvdev] maps, for tests.
Iterable<int> get rfbMappedEvdevCodes => {
  ..._keysyms.keys,
  CsrdEvdev.keyLeftMeta,
  CsrdEvdev.keyRightMeta,
  for (var c = CsrdEvdev.keyF1; c <= CsrdEvdev.keyF10; c++) c,
  for (var c = CsrdEvdev.keyF13; c <= CsrdEvdev.keyF24; c++) c,
};

const Map<int, int> _keysyms = {
  CsrdEvdev.keyEsc: RfbKeysym.escape,
  CsrdEvdev.key1: 0x31, // 1
  CsrdEvdev.key2: 0x32,
  CsrdEvdev.key3: 0x33,
  CsrdEvdev.key4: 0x34,
  CsrdEvdev.key5: 0x35,
  CsrdEvdev.key6: 0x36,
  CsrdEvdev.key7: 0x37,
  CsrdEvdev.key8: 0x38,
  CsrdEvdev.key9: 0x39,
  CsrdEvdev.key0: 0x30,
  CsrdEvdev.keyMinus: 0x2d, // minus
  CsrdEvdev.keyEqual: 0x3d, // equal
  CsrdEvdev.keyBackspace: RfbKeysym.backSpace,
  CsrdEvdev.keyTab: RfbKeysym.tab,
  CsrdEvdev.keyQ: 0x71,
  CsrdEvdev.keyW: 0x77,
  CsrdEvdev.keyE: 0x65,
  CsrdEvdev.keyR: 0x72,
  CsrdEvdev.keyT: 0x74,
  CsrdEvdev.keyY: 0x79,
  CsrdEvdev.keyU: 0x75,
  CsrdEvdev.keyI: 0x69,
  CsrdEvdev.keyO: 0x6f,
  CsrdEvdev.keyP: 0x70,
  CsrdEvdev.keyLeftBrace: 0x5b, // bracketleft
  CsrdEvdev.keyRightBrace: 0x5d, // bracketright
  CsrdEvdev.keyEnter: RfbKeysym.returnKey,
  CsrdEvdev.keyLeftCtrl: RfbKeysym.controlL,
  CsrdEvdev.keyA: 0x61,
  CsrdEvdev.keyS: 0x73,
  CsrdEvdev.keyD: 0x64,
  CsrdEvdev.keyF: 0x66,
  CsrdEvdev.keyG: 0x67,
  CsrdEvdev.keyH: 0x68,
  CsrdEvdev.keyJ: 0x6a,
  CsrdEvdev.keyK: 0x6b,
  CsrdEvdev.keyL: 0x6c,
  CsrdEvdev.keySemicolon: 0x3b, // semicolon
  CsrdEvdev.keyApostrophe: 0x27, // apostrophe
  CsrdEvdev.keyGrave: 0x60, // grave
  CsrdEvdev.keyLeftShift: RfbKeysym.shiftL,
  CsrdEvdev.keyBackslash: 0x5c, // backslash
  CsrdEvdev.keyZ: 0x7a,
  CsrdEvdev.keyX: 0x78,
  CsrdEvdev.keyC: 0x63,
  CsrdEvdev.keyV: 0x76,
  CsrdEvdev.keyB: 0x62,
  CsrdEvdev.keyN: 0x6e,
  CsrdEvdev.keyM: 0x6d,
  CsrdEvdev.keyComma: 0x2c, // comma
  CsrdEvdev.keyDot: 0x2e, // period
  CsrdEvdev.keySlash: 0x2f, // slash
  CsrdEvdev.keyRightShift: RfbKeysym.shiftR,
  CsrdEvdev.keyKpAsterisk: RfbKeysym.kpMultiply,
  CsrdEvdev.keyLeftAlt: RfbKeysym.altL,
  CsrdEvdev.keySpace: 0x20, // space
  CsrdEvdev.keyCapsLock: RfbKeysym.capsLock,
  CsrdEvdev.keyNumLock: RfbKeysym.numLock,
  CsrdEvdev.keyScrollLock: RfbKeysym.scrollLock,
  CsrdEvdev.keyKp7: RfbKeysym.kp0 + 7,
  CsrdEvdev.keyKp8: RfbKeysym.kp0 + 8,
  CsrdEvdev.keyKp9: RfbKeysym.kp0 + 9,
  CsrdEvdev.keyKpMinus: RfbKeysym.kpSubtract,
  CsrdEvdev.keyKp4: RfbKeysym.kp0 + 4,
  CsrdEvdev.keyKp5: RfbKeysym.kp0 + 5,
  CsrdEvdev.keyKp6: RfbKeysym.kp0 + 6,
  CsrdEvdev.keyKpPlus: RfbKeysym.kpAdd,
  CsrdEvdev.keyKp1: RfbKeysym.kp0 + 1,
  CsrdEvdev.keyKp2: RfbKeysym.kp0 + 2,
  CsrdEvdev.keyKp3: RfbKeysym.kp0 + 3,
  CsrdEvdev.keyKp0: RfbKeysym.kp0,
  CsrdEvdev.keyKpDot: RfbKeysym.kpDecimal,
  CsrdEvdev.keyZenkakuHankaku: RfbKeysym.zenkakuHankaku,
  // The extra key left of Z on ISO keyboards; `less` is what it types
  // unshifted on most of them.
  CsrdEvdev.key102nd: 0x3c,
  CsrdEvdev.keyF11: RfbKeysym.f1 + 10,
  CsrdEvdev.keyF12: RfbKeysym.f1 + 11,
  // JIS Ro, which types a backslash on a Japanese layout.
  CsrdEvdev.keyRo: 0x5c,
  CsrdEvdev.keyKatakana: RfbKeysym.katakana,
  CsrdEvdev.keyHiragana: RfbKeysym.hiragana,
  CsrdEvdev.keyHenkan: RfbKeysym.henkanMode,
  CsrdEvdev.keyKatakanaHiragana: RfbKeysym.hiraganaKatakana,
  CsrdEvdev.keyMuhenkan: RfbKeysym.muhenkan,
  CsrdEvdev.keyKpEnter: RfbKeysym.kpEnter,
  CsrdEvdev.keyRightCtrl: RfbKeysym.controlR,
  CsrdEvdev.keyKpSlash: RfbKeysym.kpDivide,
  CsrdEvdev.keySysRq: RfbKeysym.print,
  CsrdEvdev.keyRightAlt: RfbKeysym.altR,
  CsrdEvdev.keyHome: RfbKeysym.home,
  CsrdEvdev.keyUp: RfbKeysym.up,
  CsrdEvdev.keyPageUp: RfbKeysym.pageUp,
  CsrdEvdev.keyLeft: RfbKeysym.left,
  CsrdEvdev.keyRight: RfbKeysym.right,
  CsrdEvdev.keyEnd: RfbKeysym.end,
  CsrdEvdev.keyDown: RfbKeysym.down,
  CsrdEvdev.keyPageDown: RfbKeysym.pageDown,
  CsrdEvdev.keyInsert: RfbKeysym.insert,
  CsrdEvdev.keyDelete: RfbKeysym.delete,
  CsrdEvdev.keyMute: RfbKeysym.xf86AudioMute,
  CsrdEvdev.keyVolumeDown: RfbKeysym.xf86AudioLowerVolume,
  CsrdEvdev.keyVolumeUp: RfbKeysym.xf86AudioRaiseVolume,
  CsrdEvdev.keyKpEqual: RfbKeysym.kpEqual,
  CsrdEvdev.keyPause: RfbKeysym.pause,
  CsrdEvdev.keyKpComma: RfbKeysym.kpSeparator,
  CsrdEvdev.keyHangeul: RfbKeysym.hangul,
  CsrdEvdev.keyHanja: RfbKeysym.hangulHanja,
  CsrdEvdev.keyYen: RfbKeysym.yen,
  CsrdEvdev.keyCompose: RfbKeysym.menu,
  CsrdEvdev.keyStop: RfbKeysym.cancel,
  CsrdEvdev.keyAgain: RfbKeysym.redo,
  CsrdEvdev.keyUndo: RfbKeysym.undo,
  CsrdEvdev.keyCopy: RfbKeysym.xf86Copy,
  CsrdEvdev.keyOpen: RfbKeysym.xf86Open,
  CsrdEvdev.keyPaste: RfbKeysym.xf86Paste,
  CsrdEvdev.keyFind: RfbKeysym.find,
  CsrdEvdev.keyCut: RfbKeysym.xf86Cut,
  CsrdEvdev.keyHelp: RfbKeysym.help,
  CsrdEvdev.keyCalc: RfbKeysym.xf86Calculator,
  CsrdEvdev.keyFile: RfbKeysym.xf86Explorer,
  CsrdEvdev.keyMail: RfbKeysym.xf86Mail,
  CsrdEvdev.keyBookmarks: RfbKeysym.xf86Favorites,
  CsrdEvdev.keyBack: RfbKeysym.xf86Back,
  CsrdEvdev.keyForward: RfbKeysym.xf86Forward,
  CsrdEvdev.keyEjectCd: RfbKeysym.xf86Eject,
  CsrdEvdev.keyNextSong: RfbKeysym.xf86AudioNext,
  CsrdEvdev.keyPlayPause: RfbKeysym.xf86AudioPlay,
  CsrdEvdev.keyPreviousSong: RfbKeysym.xf86AudioPrev,
  CsrdEvdev.keyStopCd: RfbKeysym.xf86AudioStop,
  CsrdEvdev.keyConfig: RfbKeysym.xf86Tools,
  CsrdEvdev.keyHomepage: RfbKeysym.xf86HomePage,
  CsrdEvdev.keyRefresh: RfbKeysym.xf86Reload,
  CsrdEvdev.keyKpLeftParen: 0x28, // parenleft
  CsrdEvdev.keyKpRightParen: 0x29, // parenright
  CsrdEvdev.keySearch: RfbKeysym.xf86Search,
};
