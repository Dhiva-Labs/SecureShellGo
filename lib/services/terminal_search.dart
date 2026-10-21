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
  ///
  /// Cells nothing was ever written to read as spaces, except past the end of
  /// the last row, where they are not part of the line at all. The empty cell
  /// a wide character leaves behind it is skipped, so `日本` is two
  /// characters here as it is on screen.
  factory BufferText.read(Buffer buffer, int firstRow, int lastRow) {
    final text = StringBuffer();
    final rows = <int>[];
    final cols = <int>[];
    final widths = <int>[];
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
        final units = codePoint > 0xFFFF ? 2 : 1;
        text.writeCharCode(codePoint);
        for (var i = 0; i < units; i++) {
          rows.add(row);
          cols.add(col);
          widths.add(cellWidth < 1 ? 1 : cellWidth);
        }
      }
    }
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

/// Finds [query] in the whole of [buffer], scrollback included.
///
/// Matches never span two printed lines, but do span the rows of one the
/// terminal wrapped. Empty matches (a regex like `x*`) are skipped: there is
/// nothing to highlight. At most [limit] are returned, the newest ones, so a
/// search for `e` over fifty thousand lines stays quick to paint.
///
/// Throws [FormatException] for a regular expression that does not compile.
TerminalSearchResult searchTerminalBuffer(
  Buffer buffer,
  TerminalSearchQuery query, {
  int limit = 1000,
}) {
  if (query.isEmpty) return TerminalSearchResult.empty;
  final pattern = query.compile();
  final newestFirst = <TerminalMatch>[];
  var truncated = false;

  for (final line in wrappedLinesNewestFirst(buffer)) {
    if (line.text.isEmpty) continue;
    final inLine = <TerminalMatch>[];
    for (final m in pattern.allMatches(line.text)) {
      if (m.end <= m.start) continue;
      final cells = line.cellsOf(m.start, m.end);
      inLine.add(TerminalMatch(cells.begin, cells.end));
    }
    for (var i = inLine.length - 1; i >= 0; i--) {
      if (newestFirst.length == limit) {
        truncated = true;
        break;
      }
      newestFirst.add(inLine[i]);
    }
    if (truncated) break;
  }

  return TerminalSearchResult(
    newestFirst.reversed.toList(growable: false),
    truncated: truncated,
  );
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
