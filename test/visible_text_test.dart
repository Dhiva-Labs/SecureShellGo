import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/allowed_command_check.dart';
import 'package:secure_shell_go/services/visible_text.dart';

void main() {
  group('visibleText', () {
    test('plain text is returned as it is, with nothing marked', () {
      final v = visibleText('ls -la /var/log && echo "ok"');
      expect(v.text, 'ls -la /var/log && echo "ok"');
      expect(v.hasEscapes, isFalse);
      expect(v.kinds, isEmpty);
      expect(v.spans.single.escape, isFalse);
    });

    test('empty text', () {
      expect(visibleText('').text, '');
      expect(visibleText('').hasEscapes, isFalse);
    });

    test('a line feed shows a marker and keeps a real line break', () {
      final v = visibleText('a\nb');
      expect(v.text, 'a\\n\nb');
      expect(v.kinds, {VisibleKind.lineBreak});
      expect(v.hasSurprises, isFalse);
      expect(v.spans.where((s) => s.escape).single.text, r'\n');
    });

    test('with breakLines false only the marker remains', () {
      expect(visibleText('a\nb', breakLines: false).text, r'a\nb');
      expect(visibleLine('a\nb'), r'a\nb');
    });

    test('tab, carriage return and other controls', () {
      expect(visibleText('a\tb').text, r'a\tb');
      expect(visibleText('a\rb').text, r'a\rb');
      expect(visibleText('\u001b[31m').text, r'\x1b[31m');
      expect(visibleText('\u0000').text, r'\x00');
      expect(visibleText('\u007f').text, r'\x7f');
      expect(visibleText('\u0085').text, r'\x85');
      expect(visibleText('\u009f').text, r'\x9f');
      expect(visibleText('\u0007').kinds, {VisibleKind.control});
    });

    test('a carriage return that overwrites is visible', () {
      expect(visibleText('safe\rrm -rf /').text, r'safe\rrm -rf /');
    });

    test('every C0 and C1 control except line feed is a \\xNN escape', () {
      for (var c = 0; c < 0x20; c++) {
        if (c == 0x0A) continue;
        final v = visibleText(String.fromCharCode(c));
        expect(v.kinds, {
          VisibleKind.control,
        }, reason: 'U+${c.toRadixString(16)}');
        expect(v.text.contains(String.fromCharCode(c)), isFalse);
      }
      for (var c = 0x7F; c <= 0x9F; c++) {
        final v = visibleText(String.fromCharCode(c));
        expect(v.kinds, {VisibleKind.control});
        expect(v.text.contains(String.fromCharCode(c)), isFalse);
      }
    });

    test('bidirectional characters are tagged', () {
      final marks = [
        0x061C,
        0x200E,
        0x200F,
        0x202A,
        0x202B,
        0x202C,
        0x202D,
        0x202E,
        0x2066,
        0x2067,
        0x2068,
        0x2069,
      ];
      for (final c in marks) {
        final v = visibleText('a${String.fromCharCode(c)}b');
        final tag = '[U+${c.toRadixString(16).toUpperCase().padLeft(4, '0')}]';
        expect(v.text, 'a${tag}b', reason: tag);
        expect(v.kinds, {VisibleKind.bidi});
      }
    });

    test('a right-to-left override in a command is shown', () {
      final v = visibleText('cat \u202Etxt.sh');
      expect(v.text, 'cat [U+202E]txt.sh');
      expect(v.hasSurprises, isTrue);
    });

    test('zero-width and invisible characters are tagged', () {
      for (final c in [
        0x00AD,
        0x200B,
        0x200C,
        0x200D,
        0x2060,
        0x2061,
        0x2064,
        0x206A,
        0xFEFF,
        0x2800,
        0x3164,
        0x034F,
        0xFE0F,
        0xE0041,
        0xFFA0,
      ]) {
        final v = visibleText('a${String.fromCharCode(c)}b');
        expect(v.kinds, {VisibleKind.invisible}, reason: c.toRadixString(16));
        expect(v.text.runes.contains(c), isFalse);
        expect(v.text, contains('[U+'));
      }
      expect(visibleText('\u200B').text, '[U+200B]');
      expect(visibleText('\u{E0041}').text, '[U+E0041]');
    });

    test('unusual spaces are tagged, the ordinary space is not', () {
      expect(visibleText('a b').hasEscapes, isFalse);
      for (final c in [
        0x00A0,
        0x1680,
        0x2000,
        0x2003,
        0x200A,
        0x2028,
        0x2029,
        0x202F,
        0x205F,
        0x3000,
      ]) {
        final v = visibleText('a${String.fromCharCode(c)}b');
        expect(v.kinds, {VisibleKind.space}, reason: c.toRadixString(16));
        expect(v.text.runes.contains(c), isFalse);
      }
      expect(visibleText('ls\u00A0-l').text, 'ls[U+00A0]-l');
    });

    test('lone surrogates are tagged as invalid and do not throw', () {
      final v = visibleText('a${String.fromCharCode(0xD800)}b');
      expect(v.text, 'a[U+D800]b');
      expect(v.kinds, {VisibleKind.invalid});
      expect(visibleText(String.fromCharCode(0xDC00)).text, '[U+DC00]');
    });

    test('characters outside the basic plane are kept', () {
      expect(visibleText('echo 😀 日本語').text, 'echo 😀 日本語');
      expect(visibleText('echo 😀 日本語').hasEscapes, isFalse);
    });

    test('several kinds at once and the legend kinds', () {
      final v = visibleText('a\n\t\u202E\u200B\u00A0');
      expect(v.kinds, {
        VisibleKind.lineBreak,
        VisibleKind.control,
        VisibleKind.bidi,
        VisibleKind.invisible,
        VisibleKind.space,
      });
    });

    test(
      'a literal backslash-n differs from a line feed marker by its span',
      () {
        final literal = visibleText(r'echo a\nb');
        final real = visibleText('echo a\nb');
        expect(literal.spans.every((s) => !s.escape), isTrue);
        expect(real.spans.any((s) => s.escape), isTrue);
      },
    );

    test('long input is not cut, and escapes in it are all there', () {
      final input = List.filled(4096, 'x').join();
      final v = visibleText(input);
      expect(v.text.length, 4096);
      final hostile = '${'a\u202E\n' * 1500}z';
      final w = visibleText(hostile);
      expect(w.text, contains('[U+202E]'));
      expect('[U+202E]'.allMatches(w.text).length, 1500);
      expect(r'\n'.allMatches(w.text).length, 1500);
    });

    test('maxChars cuts, marks the cut, and counts code points', () {
      final v = visibleText('abcdef', maxChars: 3);
      expect(v.text, 'abc…');
      expect(v.truncated, isTrue);
      expect(visibleText('abc', maxChars: 3).truncated, isFalse);
      expect(visibleText('😀😀😀', maxChars: 2).text, '😀😀…');
      expect(visibleLine('a\nb\u202Ec', maxChars: 4), r'a\nb[U+202E]…');
    });

    test('rendering is deterministic', () {
      const input = 'a\n\u202E\t\u200B x';
      expect(visibleText(input).text, visibleText(input).text);
      expect(visibleText(input).spans, visibleText(input).spans);
    });

    test('the output never holds a hidden character other than the line '
        'break it adds', () {
      final all = StringBuffer();
      for (var c = 0; c < 0x3200; c++) {
        if (c >= 0xD800 && c <= 0xDFFF) continue;
        all.writeCharCode(c);
      }
      for (final c in [0xFEFF, 0xFFFE, 0xFFFF, 0xE0001, 0xE007F, 0x10FFFF]) {
        all.writeCharCode(c);
      }
      final shown = visibleText(all.toString(), breakLines: false).text;
      for (final c in shown.runes) {
        expect(c >= 0x20 && !(c >= 0x7F && c <= 0x9F), isTrue);
        // A combining mark is judged by what it sits on, so alone it is
        // always marked; the check of the whole output below covers it.
        expect(
          visibleText(
            String.fromCharCode(c),
          ).kinds.difference({VisibleKind.combining}),
          isEmpty,
          reason: 'U+${c.toRadixString(16)} left in the output',
        );
      }
      // The output, in context, has nothing left to mark.
      expect(visibleText(shown, breakLines: false).hasEscapes, isFalse);
    });

    test('combining marks that could hide a neighbour are marked', () {
      String shown(String s) => visibleText(s, breakLines: false).text;
      // An overlay stroke, a long run and an enclosing circle on ASCII.
      expect(shown('r\u0336m'), 'r[U+0336]m');
      expect(shown('a\u20DD'), 'a[U+20DD]');
      expect(shown('x${'\u0346' * 3}'), 'x[U+0346][U+0346][U+0346]');
      // Any mark on ASCII, even outside the generic blocks.
      expect(shown('a\u0E31'), 'a[U+0E31]');
      // A mark at the very start sits on nothing.
      expect(shown('\u0301a'), '[U+0301]a');
      // Thai with a vowel and a tone mark draws as itself...
      expect(shown('\u0E01\u0E34\u0E48'), '\u0E01\u0E34\u0E48');
      // ...but a third mark in a row is marked.
      expect(shown('\u0E01\u0E34\u0E48\u0E48'), '\u0E01\u0E34\u0E48[U+0E48]');
      expect(
        visibleText('r\u0336m').kinds,
        {VisibleKind.combining},
      );
      expect(visibleText('r\u0336m').hasSurprises, isTrue);
    });

    test('format, private-use and unassigned code points are marked', () {
      String shown(String s) => visibleText(s, breakLines: false).text;
      expect(shown('a\u{13430}b'), 'a[U+13430]b');
      expect(shown('a\u{1BCA0}b'), 'a[U+1BCA0]b');
      expect(shown('a\uE000b'), 'a[U+E000]b');
      expect(shown('a\u{F0000}b'), 'a[U+F0000]b');
      expect(shown('a\u{1FFFE}b'), 'a[U+1FFFE]b');
      expect(shown('a\u0378b'), 'a[U+0378]b');
      // Ordinary non-Latin text is untouched.
      expect(shown('\u65E5\u672C \u0645\u0631\u062D\u0628\u0627 caf\u00E9'),
          '\u65E5\u672C \u0645\u0631\u062D\u0628\u0627 caf\u00E9');
    });

    test('never throws, whatever it is given', () {
      final nasty = [
        '',
        '\u0000' * 5000,
        String.fromCharCodes([0xD800, 0xD800, 0xDC00, 0xDC00, 0xDFFF]),
        String.fromCharCodes(List.generate(70000, (i) => i % 0xFFFF)),
        '\u202E' * 10000,
      ];
      for (final s in nasty) {
        expect(() => visibleText(s), returnsNormally);
        expect(() => visibleText(s, maxChars: 0), returnsNormally);
        expect(() => visibleLine(s, maxChars: 10), returnsNormally);
      }
      expect(visibleText('abc', maxChars: 0).text, '…');
      expect(visibleText('abc', maxChars: -1).text, '…');
    });
  });

  group('allowedCommandProblem', () {
    test('accepts an ordinary command', () {
      expect(allowedCommandProblem('systemctl status nginx', []), isNull);
      expect(allowedCommandProblem('  uptime  ', []), isNull);
    });

    test('names each reason', () {
      expect(allowedCommandProblem('   ', []), AllowedCommandProblem.empty);
      expect(
        allowedCommandProblem('a\nb', []),
        AllowedCommandProblem.lineBreak,
      );
      expect(allowedCommandProblem('a\u2028b', []), AllowedCommandProblem.lineBreak);
      expect(
        allowedCommandProblem('a\u001bb', []),
        AllowedCommandProblem.hiddenCharacter,
      );
      expect(
        allowedCommandProblem('a\u202Eb', []),
        AllowedCommandProblem.hiddenCharacter,
      );
      expect(
        allowedCommandProblem('a\u00A0b', []),
        AllowedCommandProblem.hiddenCharacter,
      );
      expect(
        allowedCommandProblem('x' * 4097, []),
        AllowedCommandProblem.tooLong,
      );
      expect(
        allowedCommandProblem('uptime', ['uptime']),
        AllowedCommandProblem.duplicate,
      );
      expect(
        allowedCommandProblem('new', List.generate(50, (i) => 'c$i')),
        AllowedCommandProblem.listFull,
      );
    });
  });
}
