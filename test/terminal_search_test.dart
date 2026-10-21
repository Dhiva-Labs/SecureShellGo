import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/terminal_search.dart';
import 'package:secure_shell_go/widgets/terminal_find_bar.dart';
import 'package:xterm/xterm.dart';

/// A terminal [columns] wide and [rows] high with [text] written into it.
Terminal terminalWith(
  String text, {
  int columns = 20,
  int rows = 5,
  int maxLines = 1000,
}) {
  final terminal = Terminal(maxLines: maxLines);
  terminal.resize(columns, rows);
  terminal.write(text);
  return terminal;
}

List<TerminalMatch> search(
  Terminal terminal,
  String pattern, {
  bool caseSensitive = false,
  bool regex = false,
  int limit = 1000,
}) =>
    searchTerminalBuffer(
      terminal.buffer,
      TerminalSearchQuery(pattern, caseSensitive: caseSensitive, regex: regex),
      limit: limit,
    ).matches;

void main() {
  group('reading the buffer', () {
    test('rows the terminal wrapped are read as one line', () {
      // 26 letters on a 20-column terminal: the line wraps after "t".
      final terminal = terminalWith('abcdefghijklmnopqrstuvwxyz\r\nnext');
      final line = BufferText.lineAt(terminal.buffer, 1);
      expect(line.text, 'abcdefghijklmnopqrstuvwxyz');
      expect(line.firstRow, 0);
      expect(line.lastRow, 1);
      expect(line.cellOf(19), const CellOffset(19, 0));
      expect(line.cellOf(20), const CellOffset(0, 1));
      expect(BufferText.lineAt(terminal.buffer, 2).text, 'next');
    });

    test('a wide character is one character, two cells', () {
      final terminal = terminalWith('日本abc');
      final line = BufferText.lineAt(terminal.buffer, 0);
      expect(line.text, '日本abc');
      expect(line.cellOf(1), const CellOffset(2, 0));
      expect(line.cellAfter(1), const CellOffset(4, 0));
      expect(line.indexOf(const CellOffset(3, 0)), 1);
      expect(line.indexOf(const CellOffset(4, 0)), 2);
    });

    test('a cell the cursor skipped over reads as a space', () {
      // Cursor forward 3 leaves three cells nothing was written to.
      final terminal = terminalWith('ab\x1b[3Ccd');
      expect(BufferText.lineAt(terminal.buffer, 0).text, 'ab   cd');
    });

    test('newest first, scrollback included', () {
      final terminal = terminalWith(
        [for (var i = 0; i < 12; i++) 'line $i'].join('\r\n'),
      );
      final texts = wrappedLinesNewestFirst(terminal.buffer)
          .map((l) => l.text)
          .where((t) => t.isNotEmpty)
          .toList();
      expect(texts.first, 'line 11');
      expect(texts.last, 'line 0');
      expect(texts, hasLength(12));
    });
  });

  group('searching', () {
    test('finds matches in scrollback, top to bottom', () {
      final terminal = terminalWith(
        [for (var i = 0; i < 30; i++) i == 3 || i == 25 ? 'ERROR $i' : 'ok $i']
            .join('\r\n'),
      );
      // Five rows on screen: line 3 scrolled out of view long ago.
      expect(terminal.buffer.scrollBack, greaterThan(20));
      final matches = search(terminal, 'error');
      expect(matches, [
        const TerminalMatch(CellOffset(0, 3), CellOffset(5, 3)),
        const TerminalMatch(CellOffset(0, 25), CellOffset(5, 25)),
      ]);
    });

    test('a match running across a wrap spans both rows', () {
      final terminal =
          terminalWith('xxxxxxxxxxxxxxxxxneedle here\r\n'); // wraps at 20
      final matches = search(terminal, 'needle');
      expect(matches, [
        const TerminalMatch(CellOffset(17, 0), CellOffset(3, 1)),
      ]);
    });

    test('a match ending at the right edge ends one past the last column',
        () {
      final terminal = terminalWith('${'.' * 14}target');
      expect(search(terminal, 'target'), [
        const TerminalMatch(CellOffset(14, 0), CellOffset(20, 0)),
      ]);
    });

    test('ignores case unless asked not to', () {
      final terminal = terminalWith('Error error ERROR');
      expect(search(terminal, 'error'), hasLength(3));
      expect(search(terminal, 'error', caseSensitive: true), [
        const TerminalMatch(CellOffset(6, 0), CellOffset(11, 0)),
      ]);
    });

    test('literal text is literal', () {
      final terminal = terminalWith('a.c abc a.c');
      expect(search(terminal, 'a.c'), hasLength(2));
      expect(search(terminal, 'a.c', regex: true), hasLength(3));
    });

    test('regular expressions, and case with them', () {
      final terminal = terminalWith('pid 123 PID 4567\r\nport 80');
      expect(
        search(terminal, r'\d{3,}', regex: true),
        [
          const TerminalMatch(CellOffset(4, 0), CellOffset(7, 0)),
          const TerminalMatch(CellOffset(12, 0), CellOffset(16, 0)),
        ],
      );
      expect(search(terminal, r'^p\w+', regex: true), hasLength(2));
      expect(
        search(terminal, r'PID', regex: true, caseSensitive: true),
        hasLength(1),
      );
    });

    test('a regular expression that does not compile says so', () {
      final terminal = terminalWith('anything');
      expect(
        () => search(terminal, '(unclosed', regex: true),
        throwsFormatException,
      );
    });

    test('empty matches are skipped', () {
      final terminal = terminalWith('abc');
      expect(search(terminal, 'x*', regex: true), isEmpty);
    });

    test('wide characters land in the right cells', () {
      final terminal = terminalWith('日本語 text');
      expect(search(terminal, 'text'), [
        const TerminalMatch(CellOffset(7, 0), CellOffset(11, 0)),
      ]);
      expect(search(terminal, '本'), [
        const TerminalMatch(CellOffset(2, 0), CellOffset(4, 0)),
      ]);
    });

    test('over the limit, the newest matches are kept', () {
      final terminal = terminalWith(
        [for (var i = 0; i < 40; i++) 'hit $i'].join('\r\n'),
      );
      final result = searchTerminalBuffer(
        terminal.buffer,
        const TerminalSearchQuery('hit'),
        limit: 10,
      );
      expect(result.truncated, isTrue);
      expect(result.matches, hasLength(10));
      expect(result.matches.first.start.y, 30);
      expect(result.matches.last.start.y, 39);
    });

    test('an empty query finds nothing', () {
      expect(search(terminalWith('abc'), ''), isEmpty);
    });
  });

  group('choosing the current match', () {
    const matches = [
      TerminalMatch(CellOffset(0, 2), CellOffset(3, 2)),
      TerminalMatch(CellOffset(4, 2), CellOffset(7, 2)),
      TerminalMatch(CellOffset(0, 9), CellOffset(3, 9)),
    ];

    test('the newest at or above a row', () {
      expect(nearestMatchAbove(matches, 20), 2);
      expect(nearestMatchAbove(matches, 5), 1);
      expect(nearestMatchAbove(matches, 0), 0);
      expect(nearestMatchAbove(const [], 3), isNull);
    });

    test('where a match went after searching again', () {
      expect(matchNear(matches, const CellOffset(4, 2)), 1);
      expect(matchNear(matches, const CellOffset(5, 2)), 2);
      expect(matchNear(matches, const CellOffset(0, 30)), 2);
    });
  });

  group('the find controller', () {
    late Terminal terminal;
    late TerminalController controller;
    late TerminalFindController find;
    late List<TerminalMatch> revealed;

    setUp(() {
      terminal = terminalWith(
        'one apple\r\ntwo apples\r\nthree\r\nfour apple pie',
      );
      controller = TerminalController();
      revealed = [];
      find = TerminalFindController(
        terminal: terminal,
        controller: controller,
        reveal: revealed.add,
        refreshDelay: Duration.zero,
      );
    });

    tearDown(() {
      find.dispose();
      controller.dispose();
    });

    List<BufferRange?> ranges() =>
        [for (final h in controller.highlights) h.range];

    test('highlights every match, and the current one on top', () {
      find.open();
      find.query = const TerminalSearchQuery('apple');
      expect(find.matches, hasLength(3));
      // Newest first: the one at the bottom.
      expect(find.current, 2);
      expect(find.summary, '3 of 3');
      expect(revealed.single, find.matches[2]);
      expect(ranges(), [
        BufferRangeLine(const CellOffset(4, 0), const CellOffset(9, 0)),
        BufferRangeLine(const CellOffset(4, 1), const CellOffset(9, 1)),
        BufferRangeLine(const CellOffset(5, 3), const CellOffset(10, 3)),
        BufferRangeLine(const CellOffset(5, 3), const CellOffset(10, 3)),
      ]);
      expect(controller.highlights.last.color, find.currentColor);
      expect(controller.highlights.first.color, find.matchColor);
    });

    test('starts from the bottom of what is on screen', () {
      final scrolledUp = TerminalFindController(
        terminal: terminal,
        controller: controller,
        reveal: revealed.add,
        bottomRow: () => 1,
      );
      addTearDown(scrolledUp.dispose);
      scrolledUp.open();
      scrolledUp.query = const TerminalSearchQuery('apple');
      expect(scrolledUp.current, 1);
      expect(scrolledUp.summary, '2 of 3');
      scrolledUp.close();
    });

    test('next and previous wrap around', () {
      find.open();
      find.query = const TerminalSearchQuery('apple');
      find.next();
      expect(find.current, 0);
      expect(find.summary, '1 of 3');
      find.previous();
      expect(find.current, 2);
      find.previous();
      expect(find.current, 1);
      expect(revealed.last, find.matches[1]);
      expect(controller.highlights.last.range,
          BufferRangeLine(const CellOffset(4, 1), const CellOffset(9, 1)));
    });

    test('closing takes every highlight away', () {
      find.open();
      find.query = const TerminalSearchQuery('apple');
      expect(controller.highlights, isNotEmpty);
      find.close();
      expect(controller.highlights, isEmpty);
      expect(find.matches, isEmpty);
    });

    test('an invalid pattern is reported, not thrown', () {
      find.open();
      find.query = const TerminalSearchQuery('[', regex: true);
      expect(find.error, isNotNull);
      expect(find.summary, 'Invalid pattern');
      expect(controller.highlights, isEmpty);
    });

    test('new output searches again and keeps the current match', () async {
      find.open();
      find.query = const TerminalSearchQuery('apple');
      find.next(); // the first, on row 0
      final before = find.matches[find.current!];
      terminal.write('\r\nfive apple');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(find.matches, hasLength(4));
      expect(find.matches[find.current!], before);
      expect(find.summary, '1 of 4');
    });

    test('shows "1000+" when there are more than it keeps', () {
      final many = terminalWith(
        [for (var i = 0; i < 1100; i++) 'x'].join('\r\n'),
        rows: 10,
        maxLines: 2000,
      );
      final big = TerminalFindController(
        terminal: many,
        controller: controller,
        reveal: (_) {},
      );
      addTearDown(big.dispose);
      big.open();
      big.query = const TerminalSearchQuery('x');
      expect(big.truncated, isTrue);
      expect(big.summary, '1000 of 1000+');
      big.close();
    });

    test('its colours are translucent, so the text shows through', () {
      expect(find.matchColor.a, lessThan(1));
      expect(find.currentColor.a, lessThan(1));
    });
  });
}
