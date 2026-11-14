import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/remote_desktop/csrd_keymap.dart';
import 'package:secure_shell_go/services/remote_desktop/remote_input_text.dart';

void main() {
  group('the US layout table', () {
    test('lower-case letters are their keys, upper-case are shifted', () {
      expect(keyStrokeForCharacter('a'), const KeyStroke(CsrdEvdev.keyA));
      expect(
        keyStrokeForCharacter('A'),
        const KeyStroke(CsrdEvdev.keyA, shift: true),
      );
      expect(keyStrokeForCharacter('z'), const KeyStroke(CsrdEvdev.keyZ));
      expect(keyStrokeForCharacter('m'), const KeyStroke(CsrdEvdev.keyM));
      expect(
        keyStrokeForCharacter('Q'),
        const KeyStroke(CsrdEvdev.keyQ, shift: true),
      );
    });

    test('every letter has both cases on the same key', () {
      for (var c = 0x61; c <= 0x7a; c++) {
        final lower = keyStrokeForCharacter(String.fromCharCode(c))!;
        final upper = keyStrokeForCharacter(String.fromCharCode(c - 32))!;
        expect(lower.shift, isFalse);
        expect(upper.shift, isTrue);
        expect(upper.evdev, lower.evdev);
      }
    });

    test('digits, and the symbols above them', () {
      expect(keyStrokeForCharacter('1'), const KeyStroke(CsrdEvdev.key1));
      expect(keyStrokeForCharacter('0'), const KeyStroke(CsrdEvdev.key0));
      expect(
        keyStrokeForCharacter('!'),
        const KeyStroke(CsrdEvdev.key1, shift: true),
      );
      expect(
        keyStrokeForCharacter('@'),
        const KeyStroke(CsrdEvdev.key2, shift: true),
      );
      expect(
        keyStrokeForCharacter('\$'),
        const KeyStroke(CsrdEvdev.key4, shift: true),
      );
      expect(
        keyStrokeForCharacter(')'),
        const KeyStroke(CsrdEvdev.key0, shift: true),
      );
      expect(
        keyStrokeForCharacter('('),
        const KeyStroke(CsrdEvdev.key9, shift: true),
      );
    });

    test('punctuation keys, plain and shifted', () {
      const pairs = {
        '-': (CsrdEvdev.keyMinus, '_'),
        '=': (CsrdEvdev.keyEqual, '+'),
        '[': (CsrdEvdev.keyLeftBrace, '{'),
        ']': (CsrdEvdev.keyRightBrace, '}'),
        '\\': (CsrdEvdev.keyBackslash, '|'),
        ';': (CsrdEvdev.keySemicolon, ':'),
        "'": (CsrdEvdev.keyApostrophe, '"'),
        '`': (CsrdEvdev.keyGrave, '~'),
        ',': (CsrdEvdev.keyComma, '<'),
        '.': (CsrdEvdev.keyDot, '>'),
        '/': (CsrdEvdev.keySlash, '?'),
      };
      pairs.forEach((plain, entry) {
        final (code, shifted) = entry;
        expect(keyStrokeForCharacter(plain), KeyStroke(code), reason: plain);
        expect(
          keyStrokeForCharacter(shifted),
          KeyStroke(code, shift: true),
          reason: shifted,
        );
      });
    });

    test(
      'every printable ASCII character can be typed, and only once each',
      () {
        final seen = <KeyStroke>{};
        for (var c = 0x20; c < 0x7f; c++) {
          final stroke = keyStrokeForCharacter(String.fromCharCode(c));
          expect(stroke, isNotNull, reason: 'U+${c.toRadixString(16)}');
          expect(
            seen.add(stroke!),
            isTrue,
            reason: 'two characters on $stroke',
          );
        }
        expect(seen, hasLength(95));
      },
    );

    test('space, newline, tab and backspace', () {
      expect(keyStrokeForCharacter(' '), const KeyStroke(CsrdEvdev.keySpace));
      expect(keyStrokeForCharacter('\n'), const KeyStroke(CsrdEvdev.keyEnter));
      expect(keyStrokeForCharacter('\r'), const KeyStroke(CsrdEvdev.keyEnter));
      expect(keyStrokeForCharacter('\t'), const KeyStroke(CsrdEvdev.keyTab));
      expect(
        keyStrokeForCharacter('\b'),
        const KeyStroke(CsrdEvdev.keyBackspace),
      );
    });

    test('characters with no key on a US keyboard have no stroke', () {
      for (final c in ['é', 'ß', 'ü', 'あ', '字', '€', '£', '😀', '\u0000']) {
        expect(keyStrokeForCharacter(c), isNull, reason: c);
      }
    });
  });

  group('keystrokesForText', () {
    test('turns a string into strokes in order', () {
      final plan = keystrokesForText('Hi!\n');
      expect(plan.strokes, [
        const KeyStroke(CsrdEvdev.keyH, shift: true),
        const KeyStroke(CsrdEvdev.keyI),
        const KeyStroke(CsrdEvdev.key1, shift: true),
        const KeyStroke(CsrdEvdev.keyEnter),
      ]);
      expect(plan.untypable, isEmpty);
    });

    test(
      'reports what it cannot type, repeats included, and types the rest',
      () {
        final plan = keystrokesForText('café é ✓');
        expect(plan.untypable, ['é', 'é', '✓']);
        expect(plan.strokes.map((s) => s.evdev), [
          CsrdEvdev.keyC,
          CsrdEvdev.keyA,
          CsrdEvdev.keyF,
          CsrdEvdev.keySpace,
          CsrdEvdev.keySpace,
        ]);
      },
    );

    test('an emoji is one untypable character, not two halves', () {
      final plan = keystrokesForText('a\u{1F600}b');
      expect(plan.untypable, ['\u{1F600}']);
      expect(plan.strokes, hasLength(2));
    });

    test('Windows line endings are one Enter', () {
      final plan = keystrokesForText('a\r\nb\rc\n');
      expect(plan.strokes.map((s) => s.evdev), [
        CsrdEvdev.keyA,
        CsrdEvdev.keyEnter,
        CsrdEvdev.keyB,
        CsrdEvdev.keyEnter,
        CsrdEvdev.keyC,
        CsrdEvdev.keyEnter,
      ]);
    });

    test('nothing is nothing', () {
      final plan = keystrokesForText('');
      expect(plan.strokes, isEmpty);
      expect(plan.untypable, isEmpty);
    });
  });

  group('diffEditing', () {
    test('a typed character is an insertion', () {
      expect(diffEditing('  ', '  a'), const EditingChange(0, 'a'));
      expect(diffEditing('  ', '   '), const EditingChange(0, ' '));
      expect(diffEditing('  ', '  hello'), const EditingChange(0, 'hello'));
    });

    test('Backspace is a deletion', () {
      expect(diffEditing('  ', ' '), const EditingChange(1, ''));
      expect(diffEditing('  ', ''), const EditingChange(2, ''));
    });

    test('a replacement is a deletion and an insertion', () {
      expect(diffEditing('  ', ' x'), const EditingChange(1, 'x'));
    });

    test('nothing changed is empty', () {
      expect(diffEditing('  ', '  ').isEmpty, isTrue);
      expect(diffEditing('', '').isEmpty, isTrue);
    });

    test('counts characters, not UTF-16 units', () {
      expect(
        diffEditing('  ', '  \u{1F600}'),
        const EditingChange(0, '\u{1F600}'),
      );
      expect(diffEditing('  \u{1F600}', '  '), const EditingChange(1, ''));
    });
  });
}
