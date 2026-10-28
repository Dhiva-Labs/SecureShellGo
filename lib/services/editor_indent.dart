import 'remote_path.dart';

/// How a file indents: tabs, or a number of spaces per level.
///
/// Detected from the file itself (see [detectIndentStyle]) rather than taken
/// from a setting, because the one thing an editor must never do to an
/// indentation-sensitive file — Python, YAML, a Makefile — is add a level in
/// a style the rest of the file does not use.
class IndentStyle {
  const IndentStyle.spaces(this.size) : useTabs = false;

  /// [size] is how wide a tab is drawn, in columns.
  const IndentStyle.tabs([this.size = 4]) : useTabs = true;

  final bool useTabs;
  final int size;

  /// What one level of indentation is.
  String get unit => useTabs ? '\t' : ' ' * size;

  String get label => useTabs ? 'Tabs' : 'Spaces: $size';

  @override
  bool operator ==(Object other) =>
      other is IndentStyle && other.useTabs == useTabs && other.size == size;

  @override
  int get hashCode => Object.hash(useTabs, size);
}

/// What the editor needs to know about a language to edit it the way a
/// programmer expects.
class EditorLanguage {
  const EditorLanguage({
    required this.defaultIndent,
    this.lineComment,
    this.indentAfterColon = false,
    this.bracketIndent = false,
    this.dedentAfterKeywords = const <String>{},
    this.requiresTabs = false,
  });

  /// Used only when the file itself shows no indentation to learn from.
  final IndentStyle defaultIndent;

  /// What Ctrl+/ puts at the start of a line. Null for a language without
  /// line comments, where the shortcut does nothing.
  final String? lineComment;

  /// Python and YAML: a line ending in `:` opens a block.
  final bool indentAfterColon;

  /// `{`, `[` and `(` open a block, and the matching closer ends one.
  final bool bracketIndent;

  /// Python: the line after `return`, `pass`, `break`, `continue` or `raise`
  /// goes back out a level, because nothing more can follow in that block.
  final Set<String> dedentAfterKeywords;

  /// Makefile recipes must start with a real tab; spaces are a syntax error.
  final bool requiresTabs;

  static const plain = EditorLanguage(defaultIndent: IndentStyle.spaces(4));

  /// The rules for a file, from its name and the syntax mode it opened in.
  static EditorLanguage forFile(String name, String modeId) {
    final lower = RemotePath.basename(name).toLowerCase();
    if (lower == 'makefile' ||
        lower == 'gnumakefile' ||
        lower.endsWith('.mk') ||
        lower.endsWith('.make')) {
      return const EditorLanguage(
        defaultIndent: IndentStyle.tabs(),
        lineComment: '#',
        requiresTabs: true,
      );
    }
    return switch (modeId) {
      'python' => const EditorLanguage(
          defaultIndent: IndentStyle.spaces(4),
          lineComment: '#',
          indentAfterColon: true,
          bracketIndent: true,
          dedentAfterKeywords: {'return', 'pass', 'break', 'continue', 'raise'},
        ),
      'yaml' => const EditorLanguage(
          defaultIndent: IndentStyle.spaces(2),
          lineComment: '#',
          indentAfterColon: true,
          bracketIndent: true,
        ),
      'go' => const EditorLanguage(
          defaultIndent: IndentStyle.tabs(),
          lineComment: '//',
          bracketIndent: true,
        ),
      'dart' || 'javascript' => const EditorLanguage(
          defaultIndent: IndentStyle.spaces(2),
          lineComment: '//',
          bracketIndent: true,
        ),
      'c' || 'java' || 'rust' || 'php' || 'kotlin' => const EditorLanguage(
          defaultIndent: IndentStyle.spaces(4),
          lineComment: '//',
          bracketIndent: true,
        ),
      'ruby' => const EditorLanguage(
          defaultIndent: IndentStyle.spaces(2),
          lineComment: '#',
          bracketIndent: true,
        ),
      'json' => const EditorLanguage(
          defaultIndent: IndentStyle.spaces(2),
          lineComment: '//',
          bracketIndent: true,
        ),
      'css' => const EditorLanguage(
          defaultIndent: IndentStyle.spaces(2),
          bracketIndent: true,
        ),
      'html' => const EditorLanguage(defaultIndent: IndentStyle.spaces(2)),
      'sql' => const EditorLanguage(
          defaultIndent: IndentStyle.spaces(4),
          lineComment: '--',
          bracketIndent: true,
        ),
      'shell' || 'dockerfile' || 'ini' => const EditorLanguage(
          defaultIndent: IndentStyle.spaces(4),
          lineComment: '#',
          bracketIndent: true,
        ),
      'nginx' => const EditorLanguage(
          defaultIndent: IndentStyle.spaces(4),
          lineComment: '#',
          bracketIndent: true,
        ),
      _ => plain,
    };
  }
}

/// A document after an edit: its text and the new selection.
class EditResult {
  const EditResult(this.text, this.start, this.end);

  final String text;
  final int start;
  final int end;

  @override
  String toString() => 'EditResult(${text.length} chars, $start..$end)';
}

/// Learns how [text] indents, VS Code-style: tabs if more lines are
/// tab-indented than space-indented, otherwise the commonest step between
/// consecutive indentation levels. Falls back to [language]'s default when
/// the file has no indentation to learn from.
IndentStyle detectIndentStyle(String text, EditorLanguage language) {
  if (language.requiresTabs) return const IndentStyle.tabs();
  var tabLines = 0;
  var spaceLines = 0;
  final steps = <int, int>{};
  var previous = 0;
  var start = 0;
  while (start <= text.length) {
    var end = text.indexOf('\n', start);
    if (end < 0) end = text.length;
    var i = start;
    while (i < end && text.codeUnitAt(i) == 0x20) {
      i++;
    }
    final spaces = i - start;
    final startsWithTab = start < end && text.codeUnitAt(start) == 0x09;
    final blank = text.substring(start, end).trim().isEmpty;
    if (!blank) {
      if (startsWithTab) {
        tabLines++;
      } else {
        if (spaces > 0) spaceLines++;
        final step = (spaces - previous).abs();
        if (step >= 2 && step <= 8) steps[step] = (steps[step] ?? 0) + 1;
        previous = spaces;
      }
    }
    start = end + 1;
  }
  if (tabLines > spaceLines) {
    return IndentStyle.tabs(language.defaultIndent.size);
  }
  if (spaceLines == 0 || steps.isEmpty) {
    return language.defaultIndent.useTabs && tabLines == 0 && spaceLines > 0
        ? const IndentStyle.spaces(4)
        : language.defaultIndent;
  }
  var best = 4;
  var bestCount = -1;
  for (final size in const [2, 4, 8, 3, 6]) {
    final count = steps[size] ?? 0;
    if (count > bestCount) {
      best = size;
      bestCount = count;
    }
  }
  return IndentStyle.spaces(best);
}

int _lineStart(String text, int offset) {
  if (offset <= 0) return 0;
  final i = text.lastIndexOf('\n', offset - 1);
  return i < 0 ? 0 : i + 1;
}

int _lineEnd(String text, int offset) {
  final i = text.indexOf('\n', offset);
  return i < 0 ? text.length : i;
}

String _leadingWhitespace(String line) {
  var i = 0;
  while (i < line.length &&
      (line.codeUnitAt(i) == 0x20 || line.codeUnitAt(i) == 0x09)) {
    i++;
  }
  return line.substring(0, i);
}

/// The visual column of [offset] on its line, with tabs to the next stop.
int visualColumn(String text, int offset, int tabSize) {
  var column = 0;
  for (var i = _lineStart(text, offset); i < offset; i++) {
    column = text.codeUnitAt(i) == 0x09
        ? column + tabSize - column % tabSize
        : column + 1;
  }
  return column;
}

/// The lines a selection touches, as [first line start, last line end].
/// A selection that ends at the very start of a line does not take that
/// line with it — the same rule every editor uses for "indent selection".
(int, int) _touchedLines(String text, int start, int end) {
  final first = _lineStart(text, start);
  var lastAnchor = end;
  if (end > start && end > 0 && text.codeUnitAt(end - 1) == 0x0A) {
    lastAnchor = end - 1;
  }
  return (first, _lineEnd(text, lastAnchor));
}

/// Applies [edit] to each line in [from]..[to] and keeps the selection over
/// the same text.
EditResult _mapLines(
  String text,
  int start,
  int end,
  String Function(String line) edit,
) {
  final (from, to) = _touchedLines(text, start, end);
  final lines = text.substring(from, to).split('\n');
  final edited = lines.map(edit).toList();
  final replaced = edited.join('\n');
  final newText = text.substring(0, from) + replaced + text.substring(to);

  // Shift the selection by what changed before it on its own line, and the
  // end by the whole block's change when it sits on a later line.
  final firstDelta = edited.first.length - lines.first.length;
  final totalDelta = replaced.length - (to - from);
  final collapsed = start == end;
  final firstIndent = _leadingWhitespace(lines.first).length;
  final newStart = (start - from) <= firstIndent && !collapsed && start == from
      ? start
      : (start + firstDelta).clamp(from, from + replaced.length);
  final newEnd = collapsed
      ? newStart
      : (end + totalDelta).clamp(newStart, from + replaced.length);
  return EditResult(newText, newStart, newEnd);
}

/// Tab: with a multi-line selection, indents every line it touches;
/// otherwise inserts one level at the caret — a tab, or spaces to the next
/// tab stop.
EditResult indent(String text, int start, int end, IndentStyle style) {
  final multiLine = text.substring(start, end).contains('\n');
  if (multiLine) {
    return _mapLines(text, start, end, (line) {
      if (line.trim().isEmpty) return line;
      return style.unit + line;
    });
  }
  if (start != end) {
    // A selection within one line indents the line rather than replacing
    // what is selected: Tab should never delete code.
    final lineStart = _lineStart(text, start);
    final newText =
        text.substring(0, lineStart) + style.unit + text.substring(lineStart);
    final shift = style.unit.length;
    return EditResult(newText, start + shift, end + shift);
  }
  final insert = style.useTabs
      ? '\t'
      : ' ' * (style.size - visualColumn(text, start, style.size) % style.size);
  return EditResult(
    text.substring(0, start) + insert + text.substring(end),
    start + insert.length,
    start + insert.length,
  );
}

/// Ctrl+]: indents every line the selection touches — the caret's line when
/// nothing is selected — wherever the caret is on it.
EditResult indentLines(String text, int start, int end, IndentStyle style) {
  return _mapLines(
    text,
    start,
    end,
    (line) => line.trim().isEmpty ? line : style.unit + line,
  );
}

String _removeOneLevel(String line, IndentStyle style) {
  if (line.startsWith('\t')) return line.substring(1);
  var spaces = 0;
  while (spaces < line.length &&
      spaces < style.size &&
      line.codeUnitAt(spaces) == 0x20) {
    spaces++;
  }
  return line.substring(spaces);
}

/// Shift+Tab: takes one level off every line the selection touches (the
/// caret's line when nothing is selected). Never removes anything but
/// leading whitespace.
EditResult outdent(String text, int start, int end, IndentStyle style) {
  return _mapLines(text, start, end, (line) => _removeOneLevel(line, style));
}

bool _isBlankBefore(String text, int lineStart, int offset) {
  for (var i = lineStart; i < offset; i++) {
    final c = text.codeUnitAt(i);
    if (c != 0x20 && c != 0x09) return false;
  }
  return true;
}

String _lastSignificant(String before, String? lineComment) {
  var line = before;
  if (lineComment != null) {
    // A trailing comment does not end the statement: `if x:  # why` still
    // opens a block. Approximate (a `#` inside a string), but only ever
    // costs a missed auto-indent, never a wrong edit.
    final at = line.indexOf(lineComment);
    if (at > 0) line = line.substring(0, at);
  }
  return line.trimRight();
}

const Map<String, String> _pairs = {'(': ')', '[': ']', '{': '}'};

/// Enter: a new line at the caret's indentation, one level deeper after a
/// block opener (`:` in Python and YAML, `{ [ (` in bracket languages), one
/// level shallower after `return`/`pass`/… in Python, and — between a
/// bracket pair — the closer moved to its own line, the way VS Code does it.
/// A line left holding nothing but indentation is cleared, so Enter never
/// leaves trailing whitespace behind.
EditResult newline(
  String text,
  int start,
  int end,
  IndentStyle style,
  EditorLanguage language,
) {
  final lineStart = _lineStart(text, start);
  final lineEnd = _lineEnd(text, end);
  final before = text.substring(lineStart, start);
  final after = text.substring(end, lineEnd);
  var indentation = _leadingWhitespace(before);

  var leaveBehind = lineStart;
  final keptBefore = _isBlankBefore(text, lineStart, start)
      ? '' // a whitespace-only line is cleared, not left with spaces
      : before;
  if (keptBefore.isEmpty) {
    // Indentation the caret was sitting in still carries to the new line.
    indentation = before;
  }

  final significant = _lastSignificant(before, language.lineComment);
  final lastChar = significant.isEmpty
      ? ''
      : significant.substring(significant.length - 1);
  var deeper = false;
  if (language.indentAfterColon && lastChar == ':') deeper = true;
  if (language.bracketIndent && _pairs.containsKey(lastChar)) deeper = true;

  final firstWord = RegExp(r'^\s*(\w+)').firstMatch(before)?.group(1);
  final shallower = language.dedentAfterKeywords.contains(firstWord) &&
      !deeper &&
      keptBefore.isNotEmpty;

  var newIndent = indentation;
  if (deeper) newIndent = indentation + style.unit;
  if (shallower) newIndent = _removeOneLevel(indentation, style);

  final trimmedAfter = after.trimLeft();
  final closer = _pairs[lastChar];
  if (deeper &&
      language.bracketIndent &&
      closer != null &&
      trimmedAfter.startsWith(closer)) {
    // `{|}` → `{\n    |\n}`
    final inserted = '\n$newIndent\n$indentation';
    final newText = text.substring(0, leaveBehind) +
        keptBefore +
        inserted +
        trimmedAfter +
        text.substring(lineEnd);
    final caret = leaveBehind + keptBefore.length + 1 + newIndent.length;
    return EditResult(newText, caret, caret);
  }

  final inserted = '\n$newIndent';
  final newText = text.substring(0, leaveBehind) +
      keptBefore +
      inserted +
      trimmedAfter +
      text.substring(lineEnd);
  final caret = leaveBehind + keptBefore.length + inserted.length;
  return EditResult(newText, caret, caret);
}

/// Backspace in leading spaces: removes back to the previous tab stop, so a
/// level of four spaces goes in one keystroke, as it went in with one Tab.
/// Backspace between an empty bracket or quote pair removes both. Null when
/// the ordinary one-character delete is what should happen.
EditResult? smartBackspace(
  String text,
  int start,
  int end,
  IndentStyle style,
) {
  if (start != end || start == 0) return null;
  final prev = text[start - 1];
  if (start < text.length) {
    final next = text[start];
    final closer = _pairs[prev] ?? (_quotes.contains(prev) ? prev : null);
    if (closer != null && next == closer) {
      return EditResult(
        text.substring(0, start - 1) + text.substring(start + 1),
        start - 1,
        start - 1,
      );
    }
  }
  if (style.useTabs || prev != ' ') return null;
  final lineStart = _lineStart(text, start);
  for (var i = lineStart; i < start; i++) {
    if (text.codeUnitAt(i) != 0x20) return null;
  }
  final column = start - lineStart;
  final remove = column % style.size == 0 ? style.size : column % style.size;
  final from = start - remove;
  return EditResult(
    text.substring(0, from) + text.substring(start),
    from,
    from,
  );
}

const Set<String> _quotes = {'"', "'", '`'};
const Set<String> _closers = {')', ']', '}'};

bool _isWordChar(String c) => RegExp(r'[A-Za-z0-9_]').hasMatch(c);

/// One typed character, given the chance to do what an IDE would:
/// - an opener auto-closes (`(` → `()` with the caret inside), or wraps a
///   selection in the pair;
/// - a quote does the same, except after a letter (`don't`) or a digit;
/// - typing a closer, or the quote, that is already next to the caret just
///   steps over it;
/// - a closer typed on a line of nothing but indentation goes out a level.
/// Null when the character should simply be inserted.
EditResult? typeCharacter(
  String text,
  int start,
  int end,
  String char,
  IndentStyle style,
  EditorLanguage language,
) {
  final next = end < text.length ? text[end] : '';
  final prev = start > 0 ? text[start - 1] : '';

  if (start == end && (_closers.contains(char) || _quotes.contains(char)) &&
      next == char) {
    return EditResult(text, start + 1, start + 1);
  }

  final closer = _pairs[char] ?? (_quotes.contains(char) ? char : null);
  if (closer != null) {
    if (start != end) {
      final selected = text.substring(start, end);
      return EditResult(
        text.substring(0, start) + char + selected + closer + text.substring(end),
        start + 1,
        end + 1,
      );
    }
    if (_quotes.contains(char) && (_isWordChar(prev) || prev == char)) {
      return null;
    }
    final nextIsOpenSpace = next.isEmpty ||
        next.trim().isEmpty ||
        _closers.contains(next) ||
        next == ',' ||
        next == ';' ||
        next == ':';
    if (!nextIsOpenSpace) return null;
    return EditResult(
      text.substring(0, start) + char + closer + text.substring(end),
      start + 1,
      start + 1,
    );
  }

  if (language.bracketIndent && _closers.contains(char) && start == end) {
    final lineStart = _lineStart(text, start);
    if (start > lineStart && _isBlankBefore(text, lineStart, start)) {
      final indentation = text.substring(lineStart, start);
      final reduced = _removeOneLevel(indentation, style);
      if (reduced.length != indentation.length) {
        final newText = text.substring(0, lineStart) +
            reduced +
            char +
            text.substring(end);
        final caret = lineStart + reduced.length + 1;
        return EditResult(newText, caret, caret);
      }
    }
  }
  return null;
}

/// Ctrl+/: comments every touched line out, or — when every non-blank one
/// already is — back in. The marker goes at the shallowest indentation in
/// the block, so the code under it keeps its shape.
EditResult? toggleLineComment(
  String text,
  int start,
  int end,
  EditorLanguage language,
) {
  final marker = language.lineComment;
  if (marker == null) return null;
  final (from, to) = _touchedLines(text, start, end);
  final lines = text.substring(from, to).split('\n');
  final nonBlank = lines.where((l) => l.trim().isNotEmpty).toList();
  if (nonBlank.isEmpty) return null;

  final allCommented =
      nonBlank.every((l) => l.trimLeft().startsWith(marker));
  if (allCommented) {
    return _mapLines(text, start, end, (line) {
      final ws = _leadingWhitespace(line);
      final rest = line.substring(ws.length);
      if (!rest.startsWith(marker)) return line;
      var body = rest.substring(marker.length);
      if (body.startsWith(' ')) body = body.substring(1);
      return ws + body;
    });
  }
  var column = 1 << 30;
  for (final l in nonBlank) {
    final w = _leadingWhitespace(l).length;
    if (w < column) column = w;
  }
  return _mapLines(text, start, end, (line) {
    if (line.trim().isEmpty) return line;
    return '${line.substring(0, column)}$marker ${line.substring(column)}';
  });
}

/// Shift+Alt+↓/↑: copies the touched lines below themselves, keeping the
/// selection on the copy when going down.
EditResult duplicateLines(String text, int start, int end, {bool down = true}) {
  final (from, to) = _touchedLines(text, start, end);
  final block = text.substring(from, to);
  final newText =
      '${text.substring(0, to)}\n$block${text.substring(to)}';
  if (!down) return EditResult(newText, start, end);
  final shift = block.length + 1;
  return EditResult(newText, start + shift, end + shift);
}

/// Alt+↑/↓: swaps the touched lines with the line above or below. Null at
/// the edge of the document.
EditResult? moveLines(String text, int start, int end, {required bool up}) {
  final (from, to) = _touchedLines(text, start, end);
  final block = text.substring(from, to);
  if (up) {
    if (from == 0) return null;
    final prevStart = _lineStart(text, from - 1);
    final prevLine = text.substring(prevStart, from - 1);
    final newText =
        '${text.substring(0, prevStart)}$block\n$prevLine${text.substring(to)}';
    final shift = prevLine.length + 1;
    return EditResult(newText, start - shift, end - shift);
  }
  if (to >= text.length) return null;
  final nextEnd = _lineEnd(text, to + 1);
  final nextLine = text.substring(to + 1, nextEnd);
  final newText =
      '${text.substring(0, from)}$nextLine\n$block${text.substring(nextEnd)}';
  final shift = nextLine.length + 1;
  return EditResult(newText, start + shift, end + shift);
}

/// Whether [text] mixes tabs and spaces in its indentation — the thing that
/// makes Python raise `TabError` and that a proportional rendering hides.
bool hasMixedIndentation(String text) {
  var tabs = false;
  var spaces = false;
  for (final line in text.split('\n')) {
    final ws = _leadingWhitespace(line);
    if (ws.isEmpty || line.trim().isEmpty) continue;
    if (ws.contains('\t') && ws.contains(' ')) return true;
    if (ws.startsWith('\t')) tabs = true;
    if (ws.startsWith(' ')) spaces = true;
    if (tabs && spaces) return true;
  }
  return false;
}
