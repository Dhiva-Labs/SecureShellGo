/// Typing text on the remote when all there is to send is key positions.
///
/// The wire carries evdev key codes, physical keys, and the remote's own
/// layout decides what each one types. A soft keyboard produces characters
/// instead, so each character has to be turned back into the key that makes
/// it, which means assuming a layout. This is the US one: it is the layout
/// the keycaps in `csrd_keymap.dart` are named for, and the one a server
/// with no desktop configuration has. On a remote set to another layout the
/// letters that moved will come out differently, which is what "Paste to
/// remote" is for; a character with no key here (an accented letter, CJK)
/// cannot be typed this way at all, and [KeystrokePlan.untypable] says so.
library;

import 'csrd_keymap.dart';

/// One key press: a key, and whether Shift is held for it.
class KeyStroke {
  const KeyStroke(this.evdev, {this.shift = false});

  /// A Linux evdev code, one of `CsrdEvdev`.
  final int evdev;
  final bool shift;

  @override
  bool operator ==(Object other) =>
      other is KeyStroke && other.evdev == evdev && other.shift == shift;

  @override
  int get hashCode => Object.hash(evdev, shift);

  @override
  String toString() => 'KeyStroke($evdev${shift ? ', shift' : ''})';
}

/// The key strokes for a run of text, in order, and the characters that
/// have none.
class KeystrokePlan {
  const KeystrokePlan(this.strokes, this.untypable);

  final List<KeyStroke> strokes;

  /// Characters skipped because the US layout has no key for them, in the
  /// order they came, repeats included.
  final List<String> untypable;
}

/// The stroke that types [character] on a US keyboard, or null when none
/// does. Newline is Enter, tab is Tab and the backspace character is
/// Backspace; [character] is one character (a single rune).
KeyStroke? keyStrokeForCharacter(String character) => _strokes[character];

/// The strokes for all of [text]. A carriage return followed by a newline
/// (what a Windows-style paste carries) is one Enter, not two.
KeystrokePlan keystrokesForText(String text) {
  final strokes = <KeyStroke>[];
  final untypable = <String>[];
  final runes = text.runes.toList();
  for (var i = 0; i < runes.length; i++) {
    final c = String.fromCharCode(runes[i]);
    if (c == '\r' && i + 1 < runes.length && runes[i + 1] == 0x0a) continue;
    final stroke = _strokes[c];
    if (stroke == null) {
      untypable.add(c);
    } else {
      strokes.add(stroke);
    }
  }
  return KeystrokePlan(strokes, untypable);
}

/// What a text field's content changed by: [deleted] characters removed
/// from the end of the part that stayed, then [inserted] typed in their
/// place.
class EditingChange {
  const EditingChange(this.deleted, this.inserted);

  final int deleted;
  final String inserted;

  bool get isEmpty => deleted == 0 && inserted.isEmpty;

  @override
  bool operator ==(Object other) =>
      other is EditingChange &&
      other.deleted == deleted &&
      other.inserted == inserted;

  @override
  int get hashCode => Object.hash(deleted, inserted);

  @override
  String toString() =>
      'EditingChange(deleted: $deleted, inserted: "$inserted")';
}

/// What turned the text [before] into [after].
///
/// The soft keyboard is attached to a text input that is only a window onto
/// the keystrokes, holding a couple of characters of padding so Backspace
/// has something to delete. Its content is put back to [before] after every
/// change, so comparing the two says what was typed: what the two share at
/// the start and at the end stayed, and the rest of [before] was deleted and
/// the rest of [after] typed. Works in runes, so an emoji is one character.
EditingChange diffEditing(String before, String after) {
  final a = before.runes.toList();
  final b = after.runes.toList();
  var prefix = 0;
  while (prefix < a.length && prefix < b.length && a[prefix] == b[prefix]) {
    prefix++;
  }
  var suffix = 0;
  while (suffix < a.length - prefix &&
      suffix < b.length - prefix &&
      a[a.length - 1 - suffix] == b[b.length - 1 - suffix]) {
    suffix++;
  }
  return EditingChange(
    a.length - prefix - suffix,
    String.fromCharCodes(b.sublist(prefix, b.length - suffix)),
  );
}

KeyStroke _plain(int code) => KeyStroke(code);
KeyStroke _shift(int code) => KeyStroke(code, shift: true);

/// US layout, one character to one stroke.
final Map<String, KeyStroke> _strokes = () {
  final map = <String, KeyStroke>{};
  const letters = [
    CsrdEvdev.keyA, CsrdEvdev.keyB, CsrdEvdev.keyC, CsrdEvdev.keyD,
    CsrdEvdev.keyE, CsrdEvdev.keyF, CsrdEvdev.keyG, CsrdEvdev.keyH,
    CsrdEvdev.keyI, CsrdEvdev.keyJ, CsrdEvdev.keyK, CsrdEvdev.keyL,
    CsrdEvdev.keyM, CsrdEvdev.keyN, CsrdEvdev.keyO, CsrdEvdev.keyP,
    CsrdEvdev.keyQ, CsrdEvdev.keyR, CsrdEvdev.keyS, CsrdEvdev.keyT,
    CsrdEvdev.keyU, CsrdEvdev.keyV, CsrdEvdev.keyW, CsrdEvdev.keyX,
    CsrdEvdev.keyY, CsrdEvdev.keyZ, //
  ];
  for (var i = 0; i < letters.length; i++) {
    map[String.fromCharCode(0x61 + i)] = _plain(letters[i]);
    map[String.fromCharCode(0x41 + i)] = _shift(letters[i]);
  }
  const digits = [
    CsrdEvdev.key0, CsrdEvdev.key1, CsrdEvdev.key2, CsrdEvdev.key3,
    CsrdEvdev.key4, CsrdEvdev.key5, CsrdEvdev.key6, CsrdEvdev.key7,
    CsrdEvdev.key8, CsrdEvdev.key9, //
  ];
  const aboveDigits = ')!@#\$%^&*(';
  for (var i = 0; i < 10; i++) {
    map['$i'] = _plain(digits[i]);
    map[aboveDigits[i]] = _shift(digits[i]);
  }
  // The punctuation keys: unshifted, then shifted.
  const pairs = <(int, String, String)>[
    (CsrdEvdev.keyMinus, '-', '_'),
    (CsrdEvdev.keyEqual, '=', '+'),
    (CsrdEvdev.keyLeftBrace, '[', '{'),
    (CsrdEvdev.keyRightBrace, ']', '}'),
    (CsrdEvdev.keyBackslash, '\\', '|'),
    (CsrdEvdev.keySemicolon, ';', ':'),
    (CsrdEvdev.keyApostrophe, "'", '"'),
    (CsrdEvdev.keyGrave, '`', '~'),
    (CsrdEvdev.keyComma, ',', '<'),
    (CsrdEvdev.keyDot, '.', '>'),
    (CsrdEvdev.keySlash, '/', '?'),
  ];
  for (final (code, plain, shifted) in pairs) {
    map[plain] = _plain(code);
    map[shifted] = _shift(code);
  }
  map[' '] = _plain(CsrdEvdev.keySpace);
  map['\n'] = _plain(CsrdEvdev.keyEnter);
  map['\r'] = _plain(CsrdEvdev.keyEnter);
  map['\t'] = _plain(CsrdEvdev.keyTab);
  // Backspace as a character, and DEL, which some keyboards send for it.
  map['\b'] = _plain(CsrdEvdev.keyBackspace);
  map['\u007f'] = _plain(CsrdEvdev.keyBackspace);
  return map;
}();
