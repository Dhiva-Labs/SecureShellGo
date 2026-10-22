import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/editor_indent.dart';

/// The text with `|` marking a caret, or `[` `]` a selection, turned into
/// (text, start, end) — and back, so an expectation reads like the editor.
(String, int, int) _parse(String marked) {
  final caret = marked.indexOf('|');
  if (caret >= 0) {
    final text = marked.replaceFirst('|', '');
    return (text, caret, caret);
  }
  final s = marked.indexOf('[');
  final e = marked.indexOf(']') - 1;
  final text = marked.replaceFirst('[', '').replaceFirst(']', '');
  return (text, s, e);
}

String _show(EditResult? r) {
  if (r == null) return '<default>';
  if (r.start == r.end) {
    return '${r.text.substring(0, r.start)}|${r.text.substring(r.start)}';
  }
  return '${r.text.substring(0, r.start)}[${r.text.substring(r.start, r.end)}]'
      '${r.text.substring(r.end)}';
}

void main() {
  const python = EditorLanguage(
    defaultIndent: IndentStyle.spaces(4),
    lineComment: '#',
    indentAfterColon: true,
    bracketIndent: true,
    dedentAfterKeywords: {'return', 'pass', 'break', 'continue', 'raise'},
  );
  final js = EditorLanguage.forFile('app.js', 'javascript');
  final yaml = EditorLanguage.forFile('ci.yml', 'yaml');
  final make = EditorLanguage.forFile('Makefile', 'shell');
  const four = IndentStyle.spaces(4);
  const two = IndentStyle.spaces(2);
  const tabs = IndentStyle.tabs();

  group('detecting how a file indents', () {
    test('four-space Python', () {
      const src = 'def f():\n    if x:\n        return 1\n    return 2\n';
      expect(detectIndentStyle(src, python), four);
    });

    test('two-space YAML', () {
      const src = 'jobs:\n  build:\n    steps:\n      - run: make\n';
      expect(detectIndentStyle(src, yaml), two);
    });

    test('tab-indented code', () {
      const src = 'func main() {\n\tif x {\n\t\treturn\n\t}\n}\n';
      expect(detectIndentStyle(src, js).useTabs, isTrue);
    });

    test('a file with no indentation falls back to the language', () {
      expect(detectIndentStyle('a = 1\nb = 2\n', python), four);
      expect(detectIndentStyle('a: 1\n', yaml), two);
    });

    test('a Makefile is always tabs', () {
      expect(detectIndentStyle('all:\n    echo spaces\n', make).useTabs, isTrue);
    });

    test('mixed indentation is noticed', () {
      expect(hasMixedIndentation('if x:\n    a\n\tb\n'), isTrue);
      expect(hasMixedIndentation('if x:\n    a\n    b\n'), isFalse);
    });
  });

  group('Tab and Shift+Tab', () {
    test('Tab inserts spaces to the next stop, not a fixed four', () {
      final (t, s, e) = _parse('ab|');
      expect(_show(indent(t, s, e, four)), 'ab  |');
    });

    test('Tab inserts a real tab in a tab-indented file', () {
      final (t, s, e) = _parse('all:\n|');
      expect(_show(indent(t, s, e, tabs)), 'all:\n\t|');
    });

    test('Tab over several lines indents each, skipping blank ones', () {
      final (t, s, e) = _parse('[a\n\nb]\nc');
      expect(_show(indent(t, s, e, four)), '[    a\n\n    b]\nc');
    });

    test('Tab on a part-line selection indents the line, deleting nothing',
        () {
      final (t, s, e) = _parse('x = [foo]\n');
      expect(_show(indent(t, s, e, four)), '    x = [foo]\n');
    });

    test('Shift+Tab takes one level off, never more than there is', () {
      final (t, s, e) = _parse('[        a\n  b\nc]');
      expect(_show(outdent(t, s, e, four)), '[    a\nb\nc]');
    });

    test('Shift+Tab removes one tab in a tab-indented file', () {
      final (t, s, e) = _parse('\t\tx|');
      expect(_show(outdent(t, s, e, tabs)), '\tx|');
    });
  });

  group('Enter', () {
    test('keeps the line\'s indentation', () {
      final (t, s, e) = _parse('    x = 1|');
      expect(_show(newline(t, s, e, four, python)), '    x = 1\n    |');
    });

    test('goes a level deeper after a Python colon, comment or not', () {
      final (t, s, e) = _parse('def f():|');
      expect(_show(newline(t, s, e, four, python)), 'def f():\n    |');
      final (t2, s2, e2) = _parse('    if x:  # why|');
      expect(_show(newline(t2, s2, e2, four, python)),
          '    if x:  # why\n        |');
    });

    test('goes back out a level after return in Python', () {
      final (t, s, e) = _parse('def f():\n    return 1|');
      expect(_show(newline(t, s, e, four, python)),
          'def f():\n    return 1\n|');
    });

    test('a YAML key opens a block, a value does not', () {
      final (t, s, e) = _parse('jobs:|');
      expect(_show(newline(t, s, e, two, yaml)), 'jobs:\n  |');
      final (t2, s2, e2) = _parse('  url: http://x|');
      expect(_show(newline(t2, s2, e2, two, yaml)), '  url: http://x\n  |');
    });

    test('between braces, the closer moves to its own line', () {
      final (t, s, e) = _parse('function f() {|}');
      expect(_show(newline(t, s, e, two, js)), 'function f() {\n  |\n}');
    });

    test('a line of only indentation is cleared, not left trailing', () {
      final (t, s, e) = _parse('if x:\n    |');
      expect(_show(newline(t, s, e, four, python)), 'if x:\n\n    |');
    });

    test('the text moved down loses the spaces it split on', () {
      final (t, s, e) = _parse('a = 1|   # note');
      expect(_show(newline(t, s, e, four, python)), 'a = 1\n|# note');
    });

    test('in a Makefile, a recipe line under a target gets a tab', () {
      final (t, s, e) = _parse('all:\n\tgcc a.c|');
      expect(_show(newline(t, s, e, tabs, make)), 'all:\n\tgcc a.c\n\t|');
    });
  });

  group('Backspace', () {
    test('in leading spaces removes back to the previous stop', () {
      final (t, s, e) = _parse('        |x');
      expect(_show(smartBackspace(t, s, e, four)), '    |x');
      final (t2, s2, e2) = _parse('      |x');
      expect(_show(smartBackspace(t2, s2, e2, four)), '    |x');
    });

    test('after text is an ordinary one-character delete', () {
      final (t, s, e) = _parse('x = 1  |');
      expect(smartBackspace(t, s, e, four), isNull);
    });

    test('between an empty pair removes both', () {
      final (t, s, e) = _parse('f(|)');
      expect(_show(smartBackspace(t, s, e, four)), 'f|');
    });
  });

  group('typing pairs', () {
    test('an opener closes itself, the caret inside', () {
      final (t, s, e) = _parse('print|');
      expect(_show(typeCharacter(t, s, e, '(', four, python)), 'print(|)');
    });

    test('typing the closer that is already there steps over it', () {
      final (t, s, e) = _parse('print(x|)');
      expect(_show(typeCharacter(t, s, e, ')', four, python)), 'print(x)|');
    });

    test('a quote after a letter is just a quote', () {
      final (t, s, e) = _parse('don|');
      expect(typeCharacter(t, s, e, "'", four, python), isNull);
    });

    test('an opener before a word does not pair', () {
      final (t, s, e) = _parse('|foo');
      expect(typeCharacter(t, s, e, '(', four, python), isNull);
    });

    test('a selection is wrapped, not replaced', () {
      final (t, s, e) = _parse('x = [a + b]');
      expect(_show(typeCharacter(t, s, e, '(', four, python)),
          'x = ([a + b])');
    });

    test('a closer on an indentation-only line goes out a level', () {
      final (t, s, e) = _parse('if (x) {\n    a();\n    |');
      expect(_show(typeCharacter(t, s, e, '}', four, js)),
          'if (x) {\n    a();\n}|');
    });
  });

  group('line operations', () {
    test('Ctrl+/ comments at the shallowest indentation, and back', () {
      final (t, s, e) = _parse('[if x:\n    y()]');
      final commented = toggleLineComment(t, s, e, python)!;
      expect(commented.text, '# if x:\n#     y()');
      final back = toggleLineComment(
          commented.text, commented.start, commented.end, python)!;
      expect(back.text, 'if x:\n    y()');
    });

    test('a language without line comments is left alone', () {
      final (t, s, e) = _parse('<p>|');
      expect(toggleLineComment(t, s, e, EditorLanguage.plain), isNull);
    });

    test('duplicate copies the line below', () {
      final (t, s, e) = _parse('a\nb|\nc');
      expect(_show(duplicateLines(t, s, e)), 'a\nb\nb|\nc');
    });

    test('move swaps with the neighbour and stops at the edge', () {
      final (t, s, e) = _parse('a\nb|\nc');
      expect(_show(moveLines(t, s, e, up: true)), 'b|\na\nc');
      expect(_show(moveLines(t, s, e, up: false)), 'a\nc\nb|');
      final (t2, s2, e2) = _parse('a|\nb');
      expect(moveLines(t2, s2, e2, up: true), isNull);
    });
  });

  test('visual column counts tabs to the next stop', () {
    expect(visualColumn('\tab', 3, 4), 6);
    expect(visualColumn('ab\tc', 3, 4), 4);
  });
}
