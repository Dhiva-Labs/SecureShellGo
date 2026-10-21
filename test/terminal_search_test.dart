import 'dart:async';

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

    test('just the text reads exactly what the cell map does', () {
      final terminal = terminalWith(
        '日本\x1b[3Cabcdefghijklmnopqrstuvwxyz🎉\r\n x',
      );
      for (final line in wrappedLinesNewestFirst(terminal.buffer)) {
        expect(readLineText(terminal.buffer, line.firstRow, line.lastRow),
            line.text);
      }
    });
  });

  group('keeping the text between searches', () {
    List<String> fresh(Terminal terminal) => [
          for (final line in TerminalTextIndex().read(terminal.buffer))
            line.text,
        ];

    List<String> texts(TerminalTextIndex index, Terminal terminal) =>
        [for (final line in index.read(terminal.buffer)) line.text];

    test('the scrollback is read once, the screen every time', () {
      final terminal = terminalWith(
        [for (var i = 0; i < 300; i++) 'line $i'].join('\r\n'),
      );
      final index = TerminalTextIndex();
      expect(texts(index, terminal), fresh(terminal));
      expect(index.linesRead, 300);

      expect(texts(index, terminal), fresh(terminal));
      expect(index.linesRead, terminal.viewHeight);

      terminal.write('\r\nmore\r\nand more');
      expect(texts(index, terminal), fresh(terminal));
      // The screen, and the two lines that scrolled up off it.
      expect(index.linesRead, terminal.viewHeight + 2);
    });

    test('what changes on screen is read as it is now', () {
      final terminal = terminalWith(
        [for (var i = 0; i < 30; i++) 'line $i'].join('\r\n'),
      );
      final index = TerminalTextIndex();
      index.read(terminal.buffer);
      // Up two lines, overwrite, erase another; and a long line that wraps
      // from the screen into the scrollback as more output follows it.
      terminal.write('\x1b[2A\rchanged\x1b[K\x1b[1B\r\x1b[2K');
      expect(texts(index, terminal), fresh(terminal));
      expect(texts(index, terminal), contains('changed'));
      terminal.write('\r\n${'w' * 70}\r\nnext\r\nnext\r\nnext');
      expect(texts(index, terminal), fresh(terminal));
      expect(texts(index, terminal), contains('w' * 70));
    });

    test('lines dropped off the top are gone, and a resize starts again', () {
      final terminal = terminalWith(
        [for (var i = 0; i < 40; i++) 'line $i'].join('\r\n'),
        maxLines: 30,
      );
      final index = TerminalTextIndex();
      index.read(terminal.buffer);
      terminal.write('\r\n${[for (var i = 0; i < 5; i++) 'late $i'].join('\r\n')}');
      expect(texts(index, terminal), fresh(terminal));
      expect(texts(index, terminal).last, 'line 15');

      for (final (columns, rows) in [(12, 4), (12, 6), (30, 6)]) {
        terminal.resize(columns, rows);
        expect(texts(index, terminal), fresh(terminal));
        expect(index.linesRead,
            wrappedLinesNewestFirst(terminal.buffer).length);
      }
    });

    test('a search keeps it too', () {
      final terminal = terminalWith(
        [for (var i = 0; i < 300; i++) 'line $i'].join('\r\n'),
      );
      final index = TerminalTextIndex();
      const query = TerminalSearchQuery('line 1');
      final first =
          searchTerminalBuffer(terminal.buffer, query, index: index).matches;
      expect(index.linesRead, 300);
      final second =
          searchTerminalBuffer(terminal.buffer, query, index: index).matches;
      expect(index.linesRead, terminal.viewHeight);
      expect(second, first);
      expect(first, search(terminal, 'line 1'));
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

    /// Until [condition] holds of [find], which notifies as searches end.
    Future<void> until(
      TerminalFindController find,
      bool Function() condition,
    ) async {
      final done = Completer<void>();
      void check() {
        if (condition() && !done.isCompleted) done.complete();
      }

      find.addListener(check);
      check();
      try {
        await done.future.timeout(const Duration(seconds: 10));
      } finally {
        find.removeListener(check);
      }
    }

    test('typing searches once it pauses, not per keystroke', () async {
      final typing = TerminalFindController(
        terminal: terminal,
        controller: controller,
        reveal: revealed.add,
        typingDelay: const Duration(milliseconds: 50),
      );
      addTearDown(typing.dispose);
      typing.open();
      for (final pattern in ['a', 'ap', 'app', 'apple']) {
        typing.typeQuery(TerminalSearchQuery(pattern));
      }
      expect(typing.matches, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(typing.summary, '3 of 3');

      // Enter before the pause searches straight away.
      typing.typeQuery(const TerminalSearchQuery('apples'));
      typing.next();
      expect(typing.summary, '1 of 1');
      // Clearing the field is not waited for.
      typing.typeQuery(const TerminalSearchQuery(''));
      expect(typing.matches, isEmpty);
      expect(controller.highlights, isEmpty);
      typing.close();
    });

    test('a regular expression is searched for on another isolate', () async {
      find.open();
      find.query = const TerminalSearchQuery(r'ap+les?\b', regex: true);
      expect(find.searching, isTrue);
      expect(find.summary, 'Searching…');
      await until(find, () => !find.searching);
      expect(find.matches, search(terminal, r'ap+les?\b', regex: true));
      expect(find.matches, hasLength(3));
      expect(find.summary, '3 of 3');
      expect(controller.highlights, hasLength(4));
    });

    test('one that backtracks for ever is stopped, and nothing waits for it',
        () async {
      // Exponential in the length of the line: this would never finish.
      final slow = terminalWith('${'a' * 59}!', columns: 80);
      final stuck = TerminalFindController(
        terminal: slow,
        controller: controller,
        reveal: revealed.add,
        refreshDelay: Duration.zero,
        regexTimeLimit: const Duration(milliseconds: 300),
      );
      addTearDown(stuck.dispose);
      stuck.open();
      final clock = Stopwatch()..start();
      stuck.query = const TerminalSearchQuery(r'^(\w+\s?)+$', regex: true);
      expect(clock.elapsedMilliseconds, lessThan(250));
      // This isolate is free to run its timers — and so to draw frames.
      final ticked = Completer<void>();
      Timer(const Duration(milliseconds: 20), ticked.complete);
      await ticked.future;
      expect(clock.elapsedMilliseconds, lessThan(250));
      expect(stuck.searching, isTrue);

      await until(stuck, () => !stuck.searching);
      expect(stuck.tooSlow, isTrue);
      expect(stuck.summary, 'Pattern too slow');
      expect(stuck.matches, isEmpty);
      expect(clock.elapsed, lessThan(const Duration(seconds: 5)));

      // More output does not set it off again.
      slow.write('\r\nmore');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(stuck.searching, isFalse);
      expect(stuck.summary, 'Pattern too slow');

      // Another pattern is searched for as usual.
      stuck.query = const TerminalSearchQuery(r'mo+re', regex: true);
      await until(stuck, () => !stuck.searching);
      expect(stuck.tooSlow, isFalse);
      expect(stuck.summary, '1 of 1');
    });

    test('output during a regular-expression search is searched next',
        () async {
      find.open();
      find.query = const TerminalSearchQuery('apple', regex: true);
      terminal.write('\r\nfive apple');
      await until(find, () => find.matches.length == 4 && !find.searching);
      // Still on the match it was on.
      expect(find.summary, '3 of 4');
    });

    test('its colours are translucent, so the text shows through', () {
      expect(find.matchColor.a, lessThan(1));
      expect(find.currentColor.a, lessThan(1));
    });
  });
}
