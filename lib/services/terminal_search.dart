import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

// `core.dart`, not `xterm.dart`: searching reads the buffer, which is pure
// Dart, and nothing here draws anything.
import 'package:xterm/core.dart';

/// One printed line of the terminal, read back as text: the rows the terminal
/// wrapped at the right edge joined into one, so a match — or a URL — that
/// ran across the edge is found whole.
///
/// Every UTF-16 code unit of [text] knows the cell it came from, which is
/// what turns a match in the string back into something to highlight.
class BufferText {
  BufferText._(this.text, this.firstRow, this.lastRow, this._rows, this._cols,
      this._widths);

  /// Reads rows [firstRow]..[lastRow] of [buffer], which must be one wrapped
  /// line: every row after the first continues the one before it.
  factory BufferText.read(Buffer buffer, int firstRow, int lastRow) {
    final text = StringBuffer();
    final rows = <int>[];
    final cols = <int>[];
    final widths = <int>[];
    _readCells(buffer, firstRow, lastRow, text, rows, cols, widths);
    return BufferText._(
        text.toString(), firstRow, lastRow, rows, cols, widths);
  }

  /// The whole wrapped line that [row] is part of.
  factory BufferText.lineAt(Buffer buffer, int row) {
    var first = row;
    while (first > 0 && buffer.lines[first].isWrapped) {
      first--;
    }
    var last = row;
    while (last + 1 < buffer.height && buffer.lines[last + 1].isWrapped) {
      last++;
    }
    return BufferText.read(buffer, first, last);
  }

  final String text;
  final int firstRow;
  final int lastRow;
  final List<int> _rows;
  final List<int> _cols;
  final List<int> _widths;

  /// The cell the code unit at [index] was read from.
  CellOffset cellOf(int index) => CellOffset(_cols[index], _rows[index]);

  /// The cell just past the code unit at [index] — the exclusive end of a
  /// range that finishes with it. On the same row even at the right edge,
  /// one column past the last, which is how a highlight reaches the edge.
  CellOffset cellAfter(int index) =>
      CellOffset(_cols[index] + _widths[index], _rows[index]);

  /// The code unit read from the cell at [cell], or null when that cell is
  /// not part of the text (past its end, or on another row).
  int? indexOf(CellOffset cell) {
    if (cell.y < firstRow || cell.y > lastRow) return null;
    for (var i = 0; i < _rows.length; i++) {
      if (_rows[i] == cell.y &&
          cell.x >= _cols[i] &&
          cell.x < _cols[i] + _widths[i]) {
        return i;
      }
    }
    return null;
  }

  /// The cells of the code units [start] (inclusive) to [end] (exclusive),
  /// as a range to select or highlight. [end] must be after [start].
  ({CellOffset begin, CellOffset end}) cellsOf(int start, int end) =>
      (begin: cellOf(start), end: cellAfter(end - 1));
}

/// Just the text of rows [firstRow]..[lastRow], read as [BufferText.read]
/// reads it but without noting where each character came from: what a
/// search runs over. The cells are looked up afterwards, for the lines that
/// matched.
String readLineText(Buffer buffer, int firstRow, int lastRow) {
  final text = StringBuffer();
  _readCells(buffer, firstRow, lastRow, text);
  return text.toString();
}

/// The one reading of a wrapped line, so that [readLineText] and
/// [BufferText.read] can never disagree about where a character is: an
/// offset into one is an offset into the other.
///
/// Cells nothing was ever written to read as spaces, except past the end of
/// the last row, where they are not part of the line at all. The empty cell
/// a wide character leaves behind it is skipped, so `日本` is two characters
/// here as it is on screen.
void _readCells(
  Buffer buffer,
  int firstRow,
  int lastRow,
  StringBuffer text, [
  List<int>? rows,
  List<int>? cols,
  List<int>? widths,
]) {
  final width = buffer.viewWidth;
  var trailingHalf = false;

  for (var row = firstRow; row <= lastRow; row++) {
    final line = buffer.lines[row];
    final length = line.length < width ? line.length : width;
    // A row the next one continues is read to the edge; the last row only
    // as far as anything was written.
    final end = row == lastRow ? line.getTrimmedLength(length) : length;
    for (var col = 0; col < end; col++) {
      var codePoint = line.getCodePoint(col);
      var cellWidth = line.getWidth(col);
      if (codePoint == 0) {
        // The second cell of a wide character — at the edge of a row the
        // terminal puts it at the start of the next one.
        if (trailingHalf) {
          trailingHalf = false;
          continue;
        }
        codePoint = 0x20;
        cellWidth = 1;
      }
      trailingHalf = cellWidth == 2;
      text.writeCharCode(codePoint);
      if (rows == null) continue;
      final units = codePoint > 0xFFFF ? 2 : 1;
      for (var i = 0; i < units; i++) {
        rows.add(row);
        cols!.add(col);
        widths!.add(cellWidth < 1 ? 1 : cellWidth);
      }
    }
  }
}

/// Every wrapped line of [buffer], newest first: the order a search wants,
/// since what was printed last is what the user is usually looking for.
Iterable<BufferText> wrappedLinesNewestFirst(Buffer buffer) sync* {
  var row = buffer.height - 1;
  while (row >= 0) {
    final last = row;
    var first = row;
    while (first > 0 && buffer.lines[first].isWrapped) {
      first--;
    }
    yield BufferText.read(buffer, first, last);
    row = first - 1;
  }
}

/// One wrapped line's text as a search sees it: no cell map, and the line
/// itself rather than its row number, which changes as output scrolls the
/// buffer and the oldest lines are dropped off the top.
class TerminalLineText {
  const TerminalLineText(this.first, this.rows, this.text);

  /// The line's first row; [BufferLine.index] is where it is now.
  final BufferLine first;

  /// How many rows the terminal wrapped it over.
  final int rows;
  final String text;
}

/// The text of every wrapped line in a buffer, kept between searches.
///
/// The find bar searches the whole scrollback — fifty thousand lines — each
/// time the query changes and each time output arrives while it is open.
/// Most of that cannot have changed since the last time: xterm only ever
/// writes to the screen, the last [Buffer.viewHeight] rows, so a line that
/// has scrolled up off it stays as it is until it is dropped off the top.
/// Those lines are read once and kept, against the line itself; the screen
/// is read every time. A resize can rewrap everything, so it starts again.
class TerminalTextIndex {
  Expando<_KeptText> _kept = Expando();
  int _width = -1;
  int _height = -1;

  /// How many wrapped lines the last [read] took from the buffer rather
  /// than from what it kept.
  int get linesRead => _linesRead;
  int _linesRead = 0;

  /// Every wrapped line of [buffer] with any text in it, newest first.
  List<TerminalLineText> read(Buffer buffer) {
    if (buffer.viewWidth != _width || buffer.viewHeight != _height) {
      _kept = Expando();
      _width = buffer.viewWidth;
      _height = buffer.viewHeight;
    }
    _linesRead = 0;
    final lines = buffer.lines;
    // Rows above this one are off the screen, where nothing writes.
    final screenTop = buffer.height - buffer.viewHeight;
    final out = <TerminalLineText>[];
    var row = buffer.height - 1;
    while (row >= 0) {
      final last = row;
      var first = row;
      while (first > 0 && lines[first].isWrapped) {
        first--;
      }
      row = first - 1;

      final firstLine = lines[first];
      final lastLine = lines[last];
      final rows = last - first + 1;
      final settled = last < screenTop;
      String? text;
      if (settled) {
        final kept = _kept[firstLine];
        if (kept != null && kept.rows == rows && identical(kept.last, lastLine)) {
          text = kept.text;
        }
      }
      if (text == null) {
        text = readLineText(buffer, first, last);
        _linesRead++;
        if (settled) _kept[firstLine] = _KeptText(rows, lastLine, text);
      }
      if (text.isNotEmpty) out.add(TerminalLineText(firstLine, rows, text));
    }
    return out;
  }
}

class _KeptText {
  const _KeptText(this.rows, this.last, this.text);

  final int rows;
  final BufferLine last;
  final String text;
}

/// What the find bar is looking for.
class TerminalSearchQuery {
  const TerminalSearchQuery(
    this.pattern, {
    this.caseSensitive = false,
    this.regex = false,
  });

  final String pattern;
  final bool caseSensitive;

  /// [pattern] is a regular expression rather than literal text.
  final bool regex;

  bool get isEmpty => pattern.isEmpty;

  /// Literal text goes through [RegExp] too, escaped: lower-casing both sides
  /// instead would change the length of some strings (`İ` lower-cases to two
  /// code units) and every match after it would land in the wrong cells.
  ///
  /// Throws [FormatException] for a regular expression that does not compile.
  RegExp compile() => RegExp(
        regex ? pattern : RegExp.escape(pattern),
        caseSensitive: caseSensitive,
      );

  @override
  bool operator ==(Object other) =>
      other is TerminalSearchQuery &&
      other.pattern == pattern &&
      other.caseSensitive == caseSensitive &&
      other.regex == regex;

  @override
  int get hashCode => Object.hash(pattern, caseSensitive, regex);
}

/// One hit, in buffer cells: [start] is its first cell and [end] the cell
/// just past its last — on a later row when the match runs across a wrap.
class TerminalMatch {
  const TerminalMatch(this.start, this.end);

  final CellOffset start;
  final CellOffset end;

  @override
  bool operator ==(Object other) =>
      other is TerminalMatch && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'TerminalMatch($start, $end)';
}

class TerminalSearchResult {
  const TerminalSearchResult(this.matches, {this.truncated = false});

  static const empty = TerminalSearchResult([]);

  /// Top to bottom.
  final List<TerminalMatch> matches;

  /// More matched than [searchTerminalBuffer]'s limit; [matches] holds the
  /// newest of them.
  final bool truncated;
}

/// Finds [query] in the whole of [buffer], scrollback included, on this
/// isolate. Quick for literal text, but a regular expression can take as
/// long as it likes: the find bar runs those through [RegexSearch].
///
/// Matches never span two printed lines, but do span the rows of one the
/// terminal wrapped. Empty matches (a regex like `x*`) are skipped: there is
/// nothing to highlight. At most [limit] are returned, the newest ones, so a
/// search for `e` over fifty thousand lines stays quick to paint. An [index]
/// kept from the last search saves reading the scrollback again.
///
/// Throws [FormatException] for a regular expression that does not compile.
TerminalSearchResult searchTerminalBuffer(
  Buffer buffer,
  TerminalSearchQuery query, {
  int limit = 1000,
  TerminalTextIndex? index,
}) {
  if (query.isEmpty) return TerminalSearchResult.empty;
  final pattern = query.compile();
  final lines = (index ?? TerminalTextIndex()).read(buffer);
  final found = matchLines(
    [for (final line in lines) line.text],
    pattern,
    limit: limit,
  );
  return resolveMatches(buffer, lines, found);
}

/// Matches in a list of line texts, newest first: for each, which text it
/// is in and its start and end there, in UTF-16 code units. Flat, so it
/// comes back from a search isolate as one block of memory.
class LineMatches {
  LineMatches(this._flat, {this.truncated = false});

  final Int32List _flat;

  /// More matched than the limit; these are the newest.
  final bool truncated;

  int get length => _flat.length ~/ 3;
  int lineOf(int i) => _flat[i * 3];
  int startOf(int i) => _flat[i * 3 + 1];
  int endOf(int i) => _flat[i * 3 + 2];
}

/// Finds [pattern] in [texts], which are newest first, keeping the newest
/// [limit] matches. Empty matches are skipped.
LineMatches matchLines(
  List<String> texts,
  RegExp pattern, {
  int limit = 1000,
}) {
  final flat = <int>[];
  var count = 0;
  var truncated = false;
  final inLine = <int>[];
  for (var line = 0; line < texts.length && !truncated; line++) {
    inLine.clear();
    for (final m in pattern.allMatches(texts[line])) {
      if (m.end > m.start) inLine..add(m.start)..add(m.end);
    }
    // The last match in a line is the newest.
    for (var j = inLine.length - 2; j >= 0; j -= 2) {
      if (count == limit) {
        truncated = true;
        break;
      }
      flat..add(line)..add(inLine[j])..add(inLine[j + 1]);
      count++;
    }
  }
  return LineMatches(Int32List.fromList(flat), truncated: truncated);
}

/// Turns [found], matches in the texts of [lines], into cells of [buffer]
/// to highlight — reading each matching line's cell map, and only theirs.
///
/// [lines] may be older than [buffer] (a search on another isolate takes a
/// while, and output does not wait): a line is found by where it is now,
/// and one that has changed since, or gone, is left out. Whatever changed it
/// sets off another search.
TerminalSearchResult resolveMatches(
  Buffer buffer,
  List<TerminalLineText> lines,
  LineMatches found,
) {
  final newestFirst = <TerminalMatch>[];
  var readFor = -1;
  BufferText? cells;
  for (var i = 0; i < found.length; i++) {
    final at = found.lineOf(i);
    if (at != readFor) {
      readFor = at;
      cells = _cellsNow(buffer, lines[at]);
    }
    if (cells == null) continue;
    final range = cells.cellsOf(found.startOf(i), found.endOf(i));
    newestFirst.add(TerminalMatch(range.begin, range.end));
  }
  return TerminalSearchResult(
    newestFirst.reversed.toList(growable: false),
    truncated: found.truncated,
  );
}

/// [line] read again with its cell map, or null when it is no longer in
/// [buffer] as it was.
BufferText? _cellsNow(Buffer buffer, TerminalLineText line) {
  final first = line.first;
  if (!first.attached) return null;
  final row = first.index;
  final last = row + line.rows - 1;
  // Attached to this buffer, not the other one (the alternate screen).
  if (last >= buffer.height || !identical(buffer.lines[row], first)) {
    return null;
  }
  final cells = BufferText.read(buffer, row, last);
  return cells.text == line.text ? cells : null;
}

/// A regular-expression search, run on an isolate of its own.
///
/// A regular expression can take as long as it likes: `^(\w+\s?)+$`
/// backtracks for half a minute over one sixty-character line of words, and
/// a search on the UI isolate cannot be stopped once it has started — the
/// app would hang. Here it costs a background thread, and only until
/// [timeLimit], when the isolate is killed mid-match.
class RegexSearch {
  RegexSearch._();

  /// Searches [texts], which are newest first, for [query] — which must
  /// compile — keeping the newest [limit] matches.
  factory RegexSearch.start(
    List<String> texts,
    TerminalSearchQuery query, {
    int limit = 1000,
    required Duration timeLimit,
  }) =>
      RegexSearch._().._spawn(texts, query, limit, timeLimit);

  /// The matches, or null when the time ran out first, the search was
  /// cancelled, or it could not finish (the pattern overflowed the stack).
  Future<LineMatches?> get result => _result.future;
  final Completer<LineMatches?> _result = Completer();

  /// Whether [result] is null because the time ran out.
  bool get timedOut => _timedOut;
  bool _timedOut = false;

  final ReceivePort _port = ReceivePort();
  Isolate? _isolate;
  Timer? _timer;

  Future<void> _spawn(
    List<String> texts,
    TerminalSearchQuery query,
    int limit,
    Duration timeLimit,
  ) async {
    _timer = Timer(timeLimit, () {
      _timedOut = true;
      _finish(null);
    });
    _port.listen((message) {
      // The search's answer, or (from onError) what went wrong.
      if (message is List &&
          message.length == 2 &&
          message[0] is Int32List &&
          message[1] is bool) {
        _finish(LineMatches(message[0] as Int32List,
            truncated: message[1] as bool));
      } else {
        _finish(null);
      }
    });
    try {
      final isolate = await Isolate.spawn(
        _searchInIsolate,
        _SearchRequest(_port.sendPort, texts, query, limit),
        onError: _port.sendPort,
        debugName: 'terminal search',
      );
      if (_result.isCompleted) {
        isolate.kill(priority: Isolate.immediate);
      } else {
        _isolate = isolate;
      }
    } catch (_) {
      _finish(null);
    }
  }

  /// Stops the search, if it is still running; [result] completes with null.
  void cancel() => _finish(null);

  void _finish(LineMatches? matches) {
    if (_result.isCompleted) return;
    _timer?.cancel();
    // Immediate: the isolate is stopped in the middle of a match, not after.
    _isolate?.kill(priority: Isolate.immediate);
    _port.close();
    _result.complete(matches);
  }
}

class _SearchRequest {
  const _SearchRequest(this.reply, this.texts, this.query, this.limit);

  final SendPort reply;
  final List<String> texts;
  final TerminalSearchQuery query;
  final int limit;
}

void _searchInIsolate(_SearchRequest request) {
  final found = matchLines(
    request.texts,
    request.query.compile(),
    limit: request.limit,
  );
  Isolate.exit(request.reply, [found._flat, found.truncated]);
}

/// The match to show first: the last one at or above [row] — the bottom of
/// the screen, usually, where the newest output is — or the first one when
/// all of them are below it. Null when there are none.
int? nearestMatchAbove(List<TerminalMatch> matches, int row) {
  if (matches.isEmpty) return null;
  for (var i = matches.length - 1; i >= 0; i--) {
    if (matches[i].start.y <= row) return i;
  }
  return 0;
}

/// Where [previous] went in a fresh [matches]: the match that starts at the
/// same cell, else the first one after it, else the last.
int? matchNear(List<TerminalMatch> matches, CellOffset previous) {
  if (matches.isEmpty) return null;
  for (var i = 0; i < matches.length; i++) {
    final start = matches[i].start;
    if (start.y > previous.y ||
        (start.y == previous.y && start.x >= previous.x)) {
      return i;
    }
  }
  return matches.length - 1;
}
