import '../models/syntax_token.dart';
import 'remote_path.dart';

/// One line's spans, and the state the line after it starts in.
///
/// The state is an opaque `int` whose meaning belongs to the mode that
/// produced it. Keeping it a plain integer — rather than an object — is what
/// lets the editor cache "line 400 starts in state 1" and re-tokenize only
/// from the first line whose incoming state changed, instead of the whole
/// document on every keystroke.
class LineTokens {
  const LineTokens(this.spans, this.nextState);

  final List<HighlightSpan> spans;
  final int nextState;
}

/// A hand-rolled, line-at-a-time tokenizer for one language.
///
/// **The contract is that it never throws.** Every mode below is a scanner
/// over half-parsed, half-typed, possibly-not-even-that-language text: a user
/// editing a file has it in an invalid state most of the time they are
/// looking at it. A tokenizer that threw on an unterminated string would take
/// the whole editor screen down mid-keystroke. [tokenizeLine] enforces this
/// for every mode at once, so a new mode cannot opt out of it by accident,
/// and the failure mode it degrades to is "this line is not highlighted" —
/// never wrong colours, never a crash.
abstract class SyntaxMode {
  const SyntaxMode();

  /// Stable identifier, persisted nowhere but used to look a mode back up
  /// after a manual override.
  String get id;

  /// What the override menu calls it.
  String get label;

  /// Classifies [line], which never contains a line terminator, starting in
  /// [state]. Never throws; see the class comment.
  LineTokens tokenizeLine(String line, int state) {
    try {
      return scanLine(line, state);
    } catch (_) {
      // Back to the neutral state rather than carrying a state produced by a
      // scan that did not finish: a stuck "inside a block comment" would grey
      // out the entire rest of the file over one bad line.
      return const LineTokens(<HighlightSpan>[], _stNormal);
    }
  }

  /// The per-language scan. Implemented by each mode; called only through
  /// [tokenizeLine].
  LineTokens scanLine(String line, int state);

  /// Whole-document convenience, with spans as offsets into [text].
  ///
  /// The editor does not use this — it goes line by line so it can cache —
  /// but every tokenizer test does, and so would anything that wanted to
  /// colour a fixed snippet.
  List<HighlightSpan> tokenize(String text) {
    final out = <HighlightSpan>[];
    var offset = 0;
    var state = _stNormal;
    for (final line in text.split('\n')) {
      final result = tokenizeLine(line, state);
      for (final span in result.spans) {
        out.add(HighlightSpan(
          offset + span.start,
          offset + span.end,
          span.kind,
        ));
      }
      state = result.nextState;
      offset += line.length + 1;
    }
    return out;
  }
}

// The shared states. A mode may only use the ones its flags can produce, but
// the numbers mean the same thing everywhere so that a mode switch mid-file
// cannot be read as "still inside a string" by the mode taking over.
const int _stNormal = 0;
const int _stBlockComment = 1;
const int _stTripleSingle = 2;
const int _stTripleDouble = 3;
const int _stTemplate = 4;

/// Beyond this many spans, a line stops being highlighted.
///
/// A minified bundle is one line of half a megabyte, and every span becomes a
/// `TextSpan` the text layout has to measure. The cap is a frame-budget
/// guard, not a correctness one: the line still renders, in the base style,
/// from the cut-off onward.
const int _maxSpansPerLine = 2000;

/// Accumulates spans, merging runs and dropping [TokenKind.plain].
///
/// Unclassified text is *absence of a span*, not a span of its own. That is
/// what makes the gaps contiguous, and contiguous gaps are what stop a span
/// boundary from ever landing between the two halves of a surrogate pair —
/// the scanners only ever cut at ASCII delimiters they matched on purpose.
class _Spans {
  final List<HighlightSpan> _spans = <HighlightSpan>[];

  bool get full => _spans.length >= _maxSpansPerLine;

  /// The end of the last span emitted, so a scanner cannot double back.
  int get _mark => _spans.isEmpty ? 0 : _spans.last.end;

  void add(int rawStart, int end, TokenKind kind) {
    if (kind == TokenKind.plain || full) return;
    // Clamped rather than trusted. Spans reaching the renderer must be sorted
    // and non-overlapping — it walks them in order against a moving cursor —
    // and making that structural here means a mode cannot break it by
    // emitting an inner token on top of the outer one it already claimed.
    final start = rawStart < _mark ? _mark : rawStart;
    if (end <= start) return;
    final last = _spans.isEmpty ? null : _spans.last;
    if (last != null && last.kind == kind && last.end == start) {
      _spans[_spans.length - 1] = HighlightSpan(last.start, end, kind);
      return;
    }
    _spans.add(HighlightSpan(start, end, kind));
  }

  List<HighlightSpan> get result => _spans;
}

// ------------------------------------------------------------ char classes

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

bool _isLetter(int c) =>
    (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);

/// Identifier start, generously: anything non-ASCII counts, so an accented
/// or CJK identifier scans as one token instead of a run of unknown bytes.
bool _isIdentStart(int c) => _isLetter(c) || c == 0x5F || c > 0x7F;

bool _isIdentPart(int c) => _isIdentStart(c) || _isDigit(c);

bool _isSpace(int c) => c == 0x20 || c == 0x09;

const String _operatorChars = '+-*/%=<>!&|^~?:;,.()[]{}';

bool _isOperator(int c) => _operatorChars.contains(String.fromCharCode(c));

bool _at(String line, int i, String text) =>
    i + text.length <= line.length && line.startsWith(text, i);

/// Scans an identifier starting at [i]; returns the index just past it.
int _scanIdent(String line, int i) {
  var j = i;
  while (j < line.length && _isIdentPart(line.codeUnitAt(j))) {
    j++;
  }
  return j;
}

/// Scans a number starting at [i]; returns the index just past it.
///
/// Covers `0x`/`0b` prefixes, digit separators, a decimal point, an exponent
/// and a trailing type suffix. It is deliberately permissive — `0x1.5e3ffz`
/// is not a number in any language here, but colouring it as one is a better
/// outcome than a scanner that backtracks.
int _scanNumber(String line, int i) {
  var j = i;
  if (_at(line, j, '0x') || _at(line, j, '0X') ||
      _at(line, j, '0b') || _at(line, j, '0B')) {
    j += 2;
  }
  var seenExponent = false;
  while (j < line.length) {
    final c = line.codeUnitAt(j);
    if (_isDigit(c) || c == 0x5F) {
      j++;
    } else if (c == 0x2E && j + 1 < line.length &&
        _isDigit(line.codeUnitAt(j + 1))) {
      j++;
    } else if (!seenExponent && (c == 0x65 || c == 0x45) &&
        j + 1 < line.length &&
        (_isDigit(line.codeUnitAt(j + 1)) ||
            line.codeUnitAt(j + 1) == 0x2B ||
            line.codeUnitAt(j + 1) == 0x2D)) {
      seenExponent = true;
      j += 2;
    } else if (_isLetter(c)) {
      // `10px`, `1L`, `0xFFu` — a suffix, not the start of a new token.
      j++;
    } else {
      break;
    }
  }
  return j;
}

/// Scans a single-line quoted string from its opening quote at [i].
///
/// Returns the index just past the closing quote, or `line.length` when the
/// quote never closes — an unterminated string colours to end of line, which
/// is exactly what it looks like while someone is still typing it.
int _scanQuoted(
  String line,
  int i, {
  required bool backslashEscapes,
  bool doubledEscapes = false,
}) {
  final quote = line.codeUnitAt(i);
  var j = i + 1;
  while (j < line.length) {
    final c = line.codeUnitAt(j);
    if (backslashEscapes && c == 0x5C) {
      j += 2;
      continue;
    }
    if (c == quote) {
      // SQL's `''`: a doubled quote is one literal quote, not a close
      // followed by an open.
      if (doubledEscapes && j + 1 < line.length &&
          line.codeUnitAt(j + 1) == quote) {
        j += 2;
        continue;
      }
      return j + 1;
    }
    j++;
  }
  return line.length;
}

/// The index just past a `$name`, `${...}` or `$(...)` at [i], or -1 when
/// there is no variable there.
///
/// Shell, Dockerfile and nginx all interpolate the same way, which is why one
/// scanner serves all three.
int _scanVariable(String line, int i, int end) {
  if (i + 1 >= end || line.codeUnitAt(i) != 0x24) return -1;
  final next = line.codeUnitAt(i + 1);
  if (next == 0x7B || next == 0x28) {
    final close = next == 0x7B ? 0x7D : 0x29;
    var k = i + 2;
    while (k < end && line.codeUnitAt(k) != close) {
      k++;
    }
    return k < end ? k + 1 : end;
  }
  if (_isIdentStart(next)) {
    final stop = _scanIdent(line, i + 1);
    return stop > end ? end : stop;
  }
  return -1;
}

/// Adds `[start, end)` as [base], with any variables inside it picked out.
///
/// The region is *split* around each variable rather than having one painted
/// over the other: a variable inside a double-quoted string is the one thing
/// in a shell script most worth seeing at a glance — `"$PATH"` and `'$PATH'`
/// do very different things — and emitting an inner span on top of an outer
/// one would break the sorted, non-overlapping order the renderer walks.
void _addInterpolated(
  _Spans spans,
  String line,
  int start,
  int end,
  TokenKind base,
) {
  var cursor = start;
  var j = start;
  while (j < end) {
    if (line.codeUnitAt(j) != 0x24) {
      j++;
      continue;
    }
    final stop = _scanVariable(line, j, end);
    if (stop <= j) {
      j++;
      continue;
    }
    spans.add(cursor, j, base);
    spans.add(j, stop, TokenKind.builtin);
    cursor = stop;
    j = stop;
  }
  spans.add(cursor, end, base);
}

// ------------------------------------------------------------- C-like modes

/// The shape most of these languages share: line comments, optional block
/// comments, quoted strings, numbers, identifiers looked up in two word sets.
///
/// One configurable scanner rather than five near-copies. The flags are all
/// things that genuinely differ between the languages that use it — Python
/// has no block comment and does have triple quotes, SQL escapes a quote by
/// doubling it and matches its keywords without case, JavaScript has template
/// literals that run across lines.
class _CLikeMode extends SyntaxMode {
  const _CLikeMode({
    required this.id,
    required this.label,
    required this.keywords,
    this.builtins = const <String>{},
    this.lineComment,
    this.altLineComment,
    this.blockComments = false,
    this.tripleQuotes = false,
    this.templates = false,
    this.caseInsensitive = false,
    this.annotations = false,
    this.capitalIsBuiltin = false,
    this.doubledQuoteEscapes = false,
    this.quotedIdentifiers = false,
    this.stringPrefixes = const <String>{},
  });

  @override
  final String id;
  @override
  final String label;

  final Set<String> keywords;
  final Set<String> builtins;

  /// `//`, `#`, `--`. Null for a language with none.
  final String? lineComment;

  /// A second one, for languages that accept both (`--` and `#` in SQL).
  final String? altLineComment;

  final bool blockComments;
  final bool tripleQuotes;
  final bool templates;
  final bool caseInsensitive;

  /// `@Override`, `@decorator`.
  final bool annotations;

  /// Treat a capitalised identifier as a type. True for Dart, where it is
  /// right almost always; false for Python and SQL, where it is not.
  final bool capitalIsBuiltin;

  final bool doubledQuoteEscapes;

  /// `"col"` and `` `col` `` name a column in SQL rather than holding a
  /// string, so they are coloured as what they are.
  final bool quotedIdentifiers;

  /// `r'raw'`, `f"formatted"`, `b'bytes'`.
  final Set<String> stringPrefixes;

  @override
  LineTokens scanLine(String line, int state) {
    final spans = _Spans();
    var i = 0;

    switch (state) {
      case _stBlockComment:
        final end = line.indexOf('*/');
        if (end < 0) {
          spans.add(0, line.length, TokenKind.comment);
          return LineTokens(spans.result, _stBlockComment);
        }
        spans.add(0, end + 2, TokenKind.comment);
        i = end + 2;
      case _stTripleSingle:
      case _stTripleDouble:
      case _stTemplate:
        final delim = switch (state) {
          _stTripleSingle => "'''",
          _stTripleDouble => '"""',
          _ => '`',
        };
        final end = line.indexOf(delim);
        if (end < 0) {
          spans.add(0, line.length, TokenKind.string);
          return LineTokens(spans.result, state);
        }
        spans.add(0, end + delim.length, TokenKind.string);
        i = end + delim.length;
    }

    while (i < line.length) {
      if (spans.full) break;
      final c = line.codeUnitAt(i);

      if (_isSpace(c)) {
        i++;
        continue;
      }

      final comment = lineComment;
      final altComment = altLineComment;
      if ((comment != null && _at(line, i, comment)) ||
          (altComment != null && _at(line, i, altComment))) {
        spans.add(i, line.length, TokenKind.comment);
        break;
      }

      if (blockComments && _at(line, i, '/*')) {
        final end = line.indexOf('*/', i + 2);
        if (end < 0) {
          spans.add(i, line.length, TokenKind.comment);
          return LineTokens(spans.result, _stBlockComment);
        }
        spans.add(i, end + 2, TokenKind.comment);
        i = end + 2;
        continue;
      }

      if (tripleQuotes && (_at(line, i, "'''") || _at(line, i, '"""'))) {
        final delim = line.substring(i, i + 3);
        final end = line.indexOf(delim, i + 3);
        if (end < 0) {
          spans.add(i, line.length, TokenKind.string);
          return LineTokens(
            spans.result,
            delim == "'''" ? _stTripleSingle : _stTripleDouble,
          );
        }
        spans.add(i, end + 3, TokenKind.string);
        i = end + 3;
        continue;
      }

      if (templates && c == 0x60) {
        final end = line.indexOf('`', i + 1);
        if (end < 0) {
          spans.add(i, line.length, TokenKind.string);
          return LineTokens(spans.result, _stTemplate);
        }
        spans.add(i, end + 1, TokenKind.string);
        i = end + 1;
        continue;
      }

      if (c == 0x27 || c == 0x22) {
        final end = _scanQuoted(
          line,
          i,
          backslashEscapes: !doubledQuoteEscapes,
          doubledEscapes: doubledQuoteEscapes,
        );
        final quotedName = quotedIdentifiers && c == 0x22;
        spans.add(i, end, quotedName ? TokenKind.meta : TokenKind.string);
        i = end;
        continue;
      }

      if (quotedIdentifiers && c == 0x60) {
        final end = line.indexOf('`', i + 1);
        spans.add(i, end < 0 ? line.length : end + 1, TokenKind.meta);
        i = end < 0 ? line.length : end + 1;
        continue;
      }

      if (_isDigit(c)) {
        final end = _scanNumber(line, i);
        spans.add(i, end, TokenKind.number);
        i = end;
        continue;
      }

      if (annotations && c == 0x40 && i + 1 < line.length &&
          _isIdentStart(line.codeUnitAt(i + 1))) {
        final end = _scanIdent(line, i + 1);
        spans.add(i, end, TokenKind.meta);
        i = end;
        continue;
      }

      if (_isIdentStart(c)) {
        final end = _scanIdent(line, i);
        final word = line.substring(i, end);
        final lookup = caseInsensitive ? word.toLowerCase() : word;

        // `r'...'` and friends: the prefix and the string are one token, and
        // the string body must not then be re-scanned as identifiers.
        if (stringPrefixes.contains(lookup.toLowerCase()) &&
            end < line.length &&
            (line.codeUnitAt(end) == 0x27 || line.codeUnitAt(end) == 0x22)) {
          final raw = lookup.toLowerCase().contains('r');
          if (tripleQuotes &&
              (_at(line, end, "'''") || _at(line, end, '"""'))) {
            final delim = line.substring(end, end + 3);
            final close = line.indexOf(delim, end + 3);
            if (close < 0) {
              spans.add(i, line.length, TokenKind.string);
              return LineTokens(
                spans.result,
                delim == "'''" ? _stTripleSingle : _stTripleDouble,
              );
            }
            spans.add(i, close + 3, TokenKind.string);
            i = close + 3;
            continue;
          }
          final close = _scanQuoted(line, end, backslashEscapes: !raw);
          spans.add(i, close, TokenKind.string);
          i = close;
          continue;
        }

        if (keywords.contains(lookup)) {
          spans.add(i, end, TokenKind.keyword);
        } else if (builtins.contains(lookup)) {
          spans.add(i, end, TokenKind.builtin);
        } else if (capitalIsBuiltin && _isLetter(c) && c >= 0x41 && c <= 0x5A) {
          spans.add(i, end, TokenKind.builtin);
        }
        i = end;
        continue;
      }

      if (_isOperator(c)) {
        var j = i;
        while (j < line.length && _isOperator(line.codeUnitAt(j))) {
          j++;
        }
        spans.add(i, j, TokenKind.operator);
        i = j;
        continue;
      }

      i++;
    }

    return LineTokens(spans.result, _stNormal);
  }
}

// -------------------------------------------------------------------- shell

/// Shell — bash, sh, zsh.
///
/// Heredocs are not tracked. Doing it properly means carrying the delimiter
/// word across lines, which an `int` state cannot hold, and the failure when
/// it is wrong is loud: everything after a `<<EOF` would be one colour to the
/// end of the file. Leaving the body highlighted as shell is what most
/// editors settle for and is wrong in a way nobody notices.
class _ShellMode extends SyntaxMode {
  const _ShellMode();

  @override
  String get id => 'shell';
  @override
  String get label => 'Shell';

  static const Set<String> _keywords = {
    'if', 'then', 'else', 'elif', 'fi', 'case', 'esac', 'for', 'select',
    'while', 'until', 'do', 'done', 'in', 'function', 'time', 'coproc',
    'return', 'break', 'continue', 'exit',
  };

  static const Set<String> _builtins = {
    'echo', 'printf', 'read', 'cd', 'pwd', 'pushd', 'popd', 'dirs', 'let',
    'eval', 'exec', 'export', 'declare', 'typeset', 'local', 'readonly',
    'set', 'unset', 'shift', 'source', 'alias', 'unalias', 'test', 'trap',
    'wait', 'kill', 'jobs', 'fg', 'bg', 'umask', 'ulimit', 'getopts',
    'command', 'builtin', 'type', 'hash', 'shopt', 'true', 'false',
  };

  @override
  LineTokens scanLine(String line, int state) {
    final spans = _Spans();
    var i = 0;

    // A shebang is a directive, not a comment: it is the one `#` line in a
    // script that changes what the file does.
    if (_at(line, 0, '#!')) {
      spans.add(0, line.length, TokenKind.meta);
      return LineTokens(spans.result, _stNormal);
    }

    while (i < line.length) {
      if (spans.full) break;
      final c = line.codeUnitAt(i);

      if (_isSpace(c)) {
        i++;
        continue;
      }

      if (c == 0x23) {
        spans.add(i, line.length, TokenKind.comment);
        break;
      }

      if (c == 0x27) {
        // Single quotes in shell take no escapes at all — that is the whole
        // difference between `'$HOME'` and `"$HOME"`.
        final end = _scanQuoted(line, i, backslashEscapes: false);
        spans.add(i, end, TokenKind.string);
        i = end;
        continue;
      }

      if (c == 0x22) {
        final end = _scanQuoted(line, i, backslashEscapes: true);
        _addInterpolated(spans, line, i, end, TokenKind.string);
        i = end;
        continue;
      }

      if (c == 0x24) {
        final stop = _scanVariable(line, i, line.length);
        if (stop > i) {
          spans.add(i, stop, TokenKind.builtin);
          i = stop;
        } else {
          i++;
        }
        continue;
      }

      if (c == 0x2D && i + 1 < line.length) {
        // `-f`, `--recursive`: flags read as flags rather than as an
        // operator followed by a word.
        var j = i;
        while (j < line.length && line.codeUnitAt(j) == 0x2D) {
          j++;
        }
        if (j < line.length && _isIdentStart(line.codeUnitAt(j))) {
          final end = _scanIdent(line, j);
          spans.add(i, end, TokenKind.attribute);
          i = end;
          continue;
        }
      }

      if (_isDigit(c)) {
        final end = _scanNumber(line, i);
        spans.add(i, end, TokenKind.number);
        i = end;
        continue;
      }

      if (_isIdentStart(c)) {
        final end = _scanIdent(line, i);
        final word = line.substring(i, end);
        if (_keywords.contains(word)) {
          spans.add(i, end, TokenKind.keyword);
        } else if (_builtins.contains(word)) {
          spans.add(i, end, TokenKind.builtin);
        } else if (end < line.length && line.codeUnitAt(end) == 0x3D) {
          // `NAME=value` — an assignment names something, so it reads as the
          // subject of the line rather than as a bare word.
          spans.add(i, end, TokenKind.meta);
        }
        i = end;
        continue;
      }

      if (_isOperator(c)) {
        var j = i;
        while (j < line.length && _isOperator(line.codeUnitAt(j))) {
          j++;
        }
        spans.add(i, j, TokenKind.operator);
        i = j;
        continue;
      }

      i++;
    }

    return LineTokens(spans.result, _stNormal);
  }
}

// --------------------------------------------------------------------- YAML

class _YamlMode extends SyntaxMode {
  const _YamlMode();

  @override
  String get id => 'yaml';
  @override
  String get label => 'YAML';

  static const Set<String> _constants = {
    'true', 'false', 'yes', 'no', 'on', 'off', 'null', '~',
  };

  @override
  LineTokens scanLine(String line, int state) {
    final spans = _Spans();
    var i = 0;
    while (i < line.length && _isSpace(line.codeUnitAt(i))) {
      i++;
    }
    if (i >= line.length) return LineTokens(spans.result, _stNormal);

    if (line.codeUnitAt(i) == 0x23) {
      spans.add(i, line.length, TokenKind.comment);
      return LineTokens(spans.result, _stNormal);
    }

    if (_at(line, i, '---') || _at(line, i, '...')) {
      spans.add(i, i + 3, TokenKind.operator);
      i += 3;
    }

    // A sequence dash, possibly several for a nested inline sequence.
    while (i < line.length &&
        line.codeUnitAt(i) == 0x2D &&
        (i + 1 >= line.length || _isSpace(line.codeUnitAt(i + 1)))) {
      spans.add(i, i + 1, TokenKind.operator);
      i++;
      while (i < line.length && _isSpace(line.codeUnitAt(i))) {
        i++;
      }
    }

    // The key, when this line has one. Scanning for the *first* colon that is
    // followed by a space or ends the line is what keeps `url: http://x` from
    // reading the `://` as the separator.
    var keyEnd = -1;
    for (var j = i; j < line.length; j++) {
      if (line.codeUnitAt(j) != 0x3A) continue;
      if (j + 1 >= line.length || _isSpace(line.codeUnitAt(j + 1))) {
        keyEnd = j;
        break;
      }
    }
    if (keyEnd > i) {
      spans.add(i, keyEnd, TokenKind.meta);
      spans.add(keyEnd, keyEnd + 1, TokenKind.operator);
      i = keyEnd + 1;
    }

    while (i < line.length) {
      if (spans.full) break;
      final c = line.codeUnitAt(i);

      if (_isSpace(c)) {
        i++;
        continue;
      }

      if (c == 0x23 && i > 0 && _isSpace(line.codeUnitAt(i - 1))) {
        // A `#` only starts a comment when something separates it from the
        // token before, or `http://host/#frag` would lose its fragment.
        spans.add(i, line.length, TokenKind.comment);
        break;
      }

      if (c == 0x27 || c == 0x22) {
        final end = _scanQuoted(line, i, backslashEscapes: c == 0x22);
        spans.add(i, end, TokenKind.string);
        i = end;
        continue;
      }

      if (c == 0x26 || c == 0x2A) {
        // `&anchor` and `*alias`.
        final end = _scanIdent(line, i + 1);
        spans.add(i, end, TokenKind.attribute);
        i = end > i ? end : i + 1;
        continue;
      }

      if (c == 0x21) {
        final end = _scanIdent(line, i + 1);
        spans.add(i, end, TokenKind.attribute);
        i = end > i ? end : i + 1;
        continue;
      }

      if (c == 0x7C || c == 0x3E) {
        spans.add(i, i + 1, TokenKind.operator);
        i++;
        continue;
      }

      if (_isDigit(c)) {
        final end = _scanNumber(line, i);
        spans.add(i, end, TokenKind.number);
        i = end;
        continue;
      }

      if (_isIdentStart(c)) {
        final end = _scanIdent(line, i);
        if (_constants.contains(line.substring(i, end).toLowerCase())) {
          spans.add(i, end, TokenKind.builtin);
        }
        i = end;
        continue;
      }

      if (c == 0x7E) {
        spans.add(i, i + 1, TokenKind.builtin);
        i++;
        continue;
      }

      i++;
    }

    return LineTokens(spans.result, _stNormal);
  }
}

// --------------------------------------------------------------------- JSON

/// JSON, with keys distinguished from string values.
///
/// `//` and `/* */` are highlighted as comments even though strict JSON has
/// neither: the files people actually edit over SSH — `tsconfig.json`,
/// `devcontainer.json`, anything Microsoft ships — are full of them, and
/// colouring a comment as a syntax error helps nobody.
class _JsonMode extends SyntaxMode {
  const _JsonMode();

  @override
  String get id => 'json';
  @override
  String get label => 'JSON';

  @override
  LineTokens scanLine(String line, int state) {
    final spans = _Spans();
    var i = 0;

    if (state == _stBlockComment) {
      final end = line.indexOf('*/');
      if (end < 0) {
        spans.add(0, line.length, TokenKind.comment);
        return LineTokens(spans.result, _stBlockComment);
      }
      spans.add(0, end + 2, TokenKind.comment);
      i = end + 2;
    }

    while (i < line.length) {
      if (spans.full) break;
      final c = line.codeUnitAt(i);

      if (_isSpace(c)) {
        i++;
        continue;
      }

      if (_at(line, i, '//')) {
        spans.add(i, line.length, TokenKind.comment);
        break;
      }
      if (_at(line, i, '/*')) {
        final end = line.indexOf('*/', i + 2);
        if (end < 0) {
          spans.add(i, line.length, TokenKind.comment);
          return LineTokens(spans.result, _stBlockComment);
        }
        spans.add(i, end + 2, TokenKind.comment);
        i = end + 2;
        continue;
      }

      if (c == 0x22) {
        final end = _scanQuoted(line, i, backslashEscapes: true);
        // Look past any spaces for the colon that makes this a key.
        var j = end;
        while (j < line.length && _isSpace(line.codeUnitAt(j))) {
          j++;
        }
        final isKey = j < line.length && line.codeUnitAt(j) == 0x3A;
        spans.add(i, end, isKey ? TokenKind.meta : TokenKind.string);
        i = end;
        continue;
      }

      if (_isDigit(c) || (c == 0x2D && i + 1 < line.length &&
          _isDigit(line.codeUnitAt(i + 1)))) {
        final end = _scanNumber(line, c == 0x2D ? i + 1 : i);
        spans.add(i, end, TokenKind.number);
        i = end;
        continue;
      }

      if (_isIdentStart(c)) {
        final end = _scanIdent(line, i);
        const literals = {'true', 'false', 'null'};
        if (literals.contains(line.substring(i, end))) {
          spans.add(i, end, TokenKind.builtin);
        }
        i = end;
        continue;
      }

      if (_isOperator(c)) {
        spans.add(i, i + 1, TokenKind.operator);
        i++;
        continue;
      }

      i++;
    }

    return LineTokens(spans.result, _stNormal);
  }
}

// ---------------------------------------------------------------- HTML / XML

class _HtmlMode extends SyntaxMode {
  const _HtmlMode();

  @override
  String get id => 'html';
  @override
  String get label => 'HTML / XML';

  @override
  LineTokens scanLine(String line, int state) {
    final spans = _Spans();
    var i = 0;

    if (state == _stBlockComment) {
      final end = line.indexOf('-->');
      if (end < 0) {
        spans.add(0, line.length, TokenKind.comment);
        return LineTokens(spans.result, _stBlockComment);
      }
      spans.add(0, end + 3, TokenKind.comment);
      i = end + 3;
    }

    while (i < line.length) {
      if (spans.full) break;
      final c = line.codeUnitAt(i);

      if (_at(line, i, '<!--')) {
        final end = line.indexOf('-->', i + 4);
        if (end < 0) {
          spans.add(i, line.length, TokenKind.comment);
          return LineTokens(spans.result, _stBlockComment);
        }
        spans.add(i, end + 3, TokenKind.comment);
        i = end + 3;
        continue;
      }

      if (c == 0x26) {
        // `&amp;` — an entity is a character, not markup.
        final semi = line.indexOf(';', i + 1);
        if (semi > i && semi - i <= 10) {
          spans.add(i, semi + 1, TokenKind.builtin);
          i = semi + 1;
          continue;
        }
      }

      if (c != 0x3C) {
        i++;
        continue;
      }

      // Inside a tag, up to the matching `>` or end of line.
      final tagEnd = line.indexOf('>', i);
      final stop = tagEnd < 0 ? line.length : tagEnd + 1;

      var j = i + 1;
      if (j < line.length &&
          (line.codeUnitAt(j) == 0x2F || line.codeUnitAt(j) == 0x21 ||
              line.codeUnitAt(j) == 0x3F)) {
        j++;
      }
      final nameEnd = _scanIdent(line, j);
      spans.add(i, nameEnd > j ? nameEnd : j, TokenKind.meta);

      var k = nameEnd;
      while (k < stop) {
        if (spans.full) break;
        final ch = line.codeUnitAt(k);
        if (_isSpace(ch) || ch == 0x2F || ch == 0x3E || ch == 0x3F) {
          k++;
          continue;
        }
        if (ch == 0x22 || ch == 0x27) {
          final end = _scanQuoted(line, k, backslashEscapes: false);
          spans.add(k, end > stop ? stop : end, TokenKind.string);
          k = end;
          continue;
        }
        if (ch == 0x3D) {
          spans.add(k, k + 1, TokenKind.operator);
          k++;
          continue;
        }
        if (_isIdentStart(ch) || ch == 0x3A || ch == 0x2D) {
          var end = k;
          while (end < stop) {
            final a = line.codeUnitAt(end);
            if (!_isIdentPart(a) && a != 0x3A && a != 0x2D && a != 0x2E) break;
            end++;
          }
          spans.add(k, end, TokenKind.attribute);
          k = end > k ? end : k + 1;
          continue;
        }
        k++;
      }

      i = stop > i ? stop : i + 1;
    }

    return LineTokens(spans.result, _stNormal);
  }
}

// ---------------------------------------------------------------------- CSS

class _CssMode extends SyntaxMode {
  const _CssMode();

  @override
  String get id => 'css';
  @override
  String get label => 'CSS';

  @override
  LineTokens scanLine(String line, int state) {
    final spans = _Spans();
    var i = 0;

    if (state == _stBlockComment) {
      final end = line.indexOf('*/');
      if (end < 0) {
        spans.add(0, line.length, TokenKind.comment);
        return LineTokens(spans.result, _stBlockComment);
      }
      spans.add(0, end + 2, TokenKind.comment);
      i = end + 2;
    }

    // Whether the text before any `{` on this line is a selector. A line
    // holding `color: red;` inside a block has a colon and no braces; a line
    // holding `a:hover {` has both. The brace is the reliable signal, so the
    // selector run is only claimed when one is present.
    final brace = line.indexOf('{');

    while (i < line.length) {
      if (spans.full) break;
      final c = line.codeUnitAt(i);

      if (_isSpace(c)) {
        i++;
        continue;
      }

      if (_at(line, i, '/*')) {
        final end = line.indexOf('*/', i + 2);
        if (end < 0) {
          spans.add(i, line.length, TokenKind.comment);
          return LineTokens(spans.result, _stBlockComment);
        }
        spans.add(i, end + 2, TokenKind.comment);
        i = end + 2;
        continue;
      }

      if (c == 0x40) {
        final end = _scanIdent(line, i + 1);
        spans.add(i, end, TokenKind.keyword);
        i = end > i ? end : i + 1;
        continue;
      }

      if (c == 0x22 || c == 0x27) {
        final end = _scanQuoted(line, i, backslashEscapes: true);
        spans.add(i, end, TokenKind.string);
        i = end;
        continue;
      }

      if (c == 0x23 && i + 1 < line.length &&
          _isIdentPart(line.codeUnitAt(i + 1))) {
        final end = _scanIdent(line, i + 1);
        // `#fff` is a colour, `#main` is a selector. Both read better as
        // something other than plain text; the digits decide which.
        final body = line.substring(i + 1, end);
        final isHex = body.length >= 3 &&
            body.split('').every((ch) => '0123456789abcdefABCDEF'.contains(ch));
        spans.add(i, end, isHex ? TokenKind.number : TokenKind.meta);
        i = end;
        continue;
      }

      if (_isDigit(c) ||
          (c == 0x2E && i + 1 < line.length &&
              _isDigit(line.codeUnitAt(i + 1)))) {
        final end = _scanNumber(line, i);
        spans.add(i, end, TokenKind.number);
        i = end;
        continue;
      }

      if (_isIdentStart(c) || c == 0x2D || c == 0x2E) {
        var end = i;
        while (end < line.length) {
          final a = line.codeUnitAt(end);
          if (!_isIdentPart(a) && a != 0x2D && a != 0x2E) break;
          end++;
        }
        if (end == i) {
          i++;
          continue;
        }
        // A word followed by a colon inside a block is a property; the same
        // word before the line's brace is part of the selector.
        var j = end;
        while (j < line.length && _isSpace(line.codeUnitAt(j))) {
          j++;
        }
        final followedByColon =
            j < line.length && line.codeUnitAt(j) == 0x3A;
        if (brace >= 0 && i < brace) {
          spans.add(i, end, TokenKind.meta);
        } else if (followedByColon && brace < 0) {
          spans.add(i, end, TokenKind.attribute);
        } else {
          spans.add(i, end, TokenKind.builtin);
        }
        i = end;
        continue;
      }

      if (_isOperator(c)) {
        spans.add(i, i + 1, TokenKind.operator);
        i++;
        continue;
      }

      i++;
    }

    return LineTokens(spans.result, _stNormal);
  }
}

// ----------------------------------------------------------------- Markdown

class _MarkdownMode extends SyntaxMode {
  const _MarkdownMode();

  @override
  String get id => 'markdown';
  @override
  String get label => 'Markdown';

  @override
  LineTokens scanLine(String line, int state) {
    final spans = _Spans();

    final bare = line.trimLeft();
    final fence = _at(bare, 0, '```') || _at(bare, 0, '~~~');
    if (state == _stBlockComment) {
      // Inside a fenced block: the whole line is code, and only a closing
      // fence gets out. Highlighting the fenced language properly would mean
      // running a second mode from inside this one, which is more machinery
      // than a Markdown file over SSH is worth.
      spans.add(0, line.length, TokenKind.string);
      return LineTokens(spans.result, fence ? _stNormal : _stBlockComment);
    }
    if (fence) {
      spans.add(0, line.length, TokenKind.operator);
      return LineTokens(spans.result, _stBlockComment);
    }

    var i = 0;
    while (i < line.length && _isSpace(line.codeUnitAt(i))) {
      i++;
    }

    if (i < line.length && line.codeUnitAt(i) == 0x23) {
      spans.add(0, line.length, TokenKind.heading);
      return LineTokens(spans.result, _stNormal);
    }

    if (i < line.length && line.codeUnitAt(i) == 0x3E) {
      spans.add(0, line.length, TokenKind.comment);
      return LineTokens(spans.result, _stNormal);
    }

    // A list bullet or an ordered marker.
    if (i < line.length &&
        (line.codeUnitAt(i) == 0x2D || line.codeUnitAt(i) == 0x2A ||
            line.codeUnitAt(i) == 0x2B) &&
        i + 1 < line.length && _isSpace(line.codeUnitAt(i + 1))) {
      spans.add(i, i + 1, TokenKind.operator);
      i += 2;
    } else if (i < line.length && _isDigit(line.codeUnitAt(i))) {
      final end = _scanNumber(line, i);
      if (end < line.length && line.codeUnitAt(end) == 0x2E) {
        spans.add(i, end + 1, TokenKind.operator);
        i = end + 1;
      }
    }

    while (i < line.length) {
      if (spans.full) break;
      final c = line.codeUnitAt(i);

      if (c == 0x60) {
        final end = line.indexOf('`', i + 1);
        spans.add(i, end < 0 ? line.length : end + 1, TokenKind.string);
        i = end < 0 ? line.length : end + 1;
        continue;
      }

      if ((_at(line, i, '**') || _at(line, i, '__')) ) {
        final marker = line.substring(i, i + 2);
        final end = line.indexOf(marker, i + 2);
        spans.add(i, end < 0 ? line.length : end + 2, TokenKind.keyword);
        i = end < 0 ? line.length : end + 2;
        continue;
      }

      if (c == 0x5B) {
        final close = line.indexOf(']', i + 1);
        if (close > i) {
          spans.add(i, close + 1, TokenKind.attribute);
          i = close + 1;
          if (i < line.length && line.codeUnitAt(i) == 0x28) {
            final paren = line.indexOf(')', i + 1);
            spans.add(i, paren < 0 ? line.length : paren + 1, TokenKind.meta);
            i = paren < 0 ? line.length : paren + 1;
          }
          continue;
        }
      }

      i++;
    }

    return LineTokens(spans.result, _stNormal);
  }
}

// ------------------------------------------------------------- INI and TOML

class _IniMode extends SyntaxMode {
  const _IniMode();

  @override
  String get id => 'ini';
  @override
  String get label => 'INI / TOML';

  @override
  LineTokens scanLine(String line, int state) {
    final spans = _Spans();
    var i = 0;
    while (i < line.length && _isSpace(line.codeUnitAt(i))) {
      i++;
    }
    if (i >= line.length) return LineTokens(spans.result, _stNormal);

    final first = line.codeUnitAt(i);
    if (first == 0x23 || first == 0x3B) {
      spans.add(i, line.length, TokenKind.comment);
      return LineTokens(spans.result, _stNormal);
    }

    if (first == 0x5B) {
      final close = line.lastIndexOf(']');
      spans.add(i, close < i ? line.length : close + 1, TokenKind.heading);
      return LineTokens(spans.result, _stNormal);
    }

    final eq = line.indexOf('=', i);
    if (eq > i) {
      spans.add(i, eq, TokenKind.meta);
      spans.add(eq, eq + 1, TokenKind.operator);
      i = eq + 1;
    }

    while (i < line.length) {
      if (spans.full) break;
      final c = line.codeUnitAt(i);

      if (_isSpace(c)) {
        i++;
        continue;
      }

      if (c == 0x23 || c == 0x3B) {
        spans.add(i, line.length, TokenKind.comment);
        break;
      }

      if (c == 0x22 || c == 0x27) {
        final end = _scanQuoted(line, i, backslashEscapes: c == 0x22);
        spans.add(i, end, TokenKind.string);
        i = end;
        continue;
      }

      if (_isDigit(c)) {
        final end = _scanNumber(line, i);
        spans.add(i, end, TokenKind.number);
        i = end;
        continue;
      }

      if (_isIdentStart(c)) {
        final end = _scanIdent(line, i);
        const constants = {'true', 'false', 'yes', 'no', 'on', 'off', 'null'};
        if (constants.contains(line.substring(i, end).toLowerCase())) {
          spans.add(i, end, TokenKind.builtin);
        }
        i = end;
        continue;
      }

      i++;
    }

    return LineTokens(spans.result, _stNormal);
  }
}

// --------------------------------------------------------------- Dockerfile

class _DockerfileMode extends SyntaxMode {
  const _DockerfileMode();

  @override
  String get id => 'dockerfile';
  @override
  String get label => 'Dockerfile';

  static const Set<String> _instructions = {
    'from', 'run', 'cmd', 'label', 'maintainer', 'expose', 'env', 'add',
    'copy', 'entrypoint', 'volume', 'user', 'workdir', 'arg', 'onbuild',
    'stopsignal', 'healthcheck', 'shell',
  };

  @override
  LineTokens scanLine(String line, int state) {
    final spans = _Spans();
    var i = 0;
    while (i < line.length && _isSpace(line.codeUnitAt(i))) {
      i++;
    }
    if (i >= line.length) return LineTokens(spans.result, _stNormal);

    if (line.codeUnitAt(i) == 0x23) {
      // `# syntax=docker/dockerfile:1` is a parser directive when it is the
      // first line; treating every such comment as one is harmless and saves
      // carrying "is this still the preamble" in the state.
      final kind =
          line.contains('=') && i == 0 ? TokenKind.meta : TokenKind.comment;
      spans.add(i, line.length, kind);
      return LineTokens(spans.result, _stNormal);
    }

    // Only a leading word is an instruction. A continued line — the previous
    // one ended in a backslash — has no instruction, and mis-colouring the
    // first word of a long `RUN` chain as one is the visible bug this avoids
    // only for state 0; the continuation state is not tracked, deliberately,
    // because an int cannot also carry which instruction it continues.
    final instrEnd = _scanIdent(line, i);
    if (instrEnd > i &&
        _instructions.contains(line.substring(i, instrEnd).toLowerCase())) {
      spans.add(i, instrEnd, TokenKind.keyword);
      i = instrEnd;
    }

    while (i < line.length) {
      if (spans.full) break;
      final c = line.codeUnitAt(i);

      if (_isSpace(c)) {
        i++;
        continue;
      }

      if (c == 0x22 || c == 0x27) {
        final end = _scanQuoted(line, i, backslashEscapes: c == 0x22);
        _addInterpolated(spans, line, i, end, TokenKind.string);
        i = end;
        continue;
      }

      if (c == 0x24) {
        final stop = _scanVariable(line, i, line.length);
        if (stop > i) {
          spans.add(i, stop, TokenKind.builtin);
          i = stop;
        } else {
          i++;
        }
        continue;
      }

      if (c == 0x2D && i + 1 < line.length && line.codeUnitAt(i + 1) == 0x2D) {
        final end = _scanIdent(line, i + 2);
        spans.add(i, end > i + 2 ? end : i + 2, TokenKind.attribute);
        i = end > i ? end : i + 2;
        continue;
      }

      if (_isDigit(c)) {
        final end = _scanNumber(line, i);
        spans.add(i, end, TokenKind.number);
        i = end;
        continue;
      }

      if (_isIdentStart(c)) {
        final end = _scanIdent(line, i);
        if (end < line.length && line.codeUnitAt(end) == 0x3D) {
          spans.add(i, end, TokenKind.meta);
        }
        i = end;
        continue;
      }

      i++;
    }

    return LineTokens(spans.result, _stNormal);
  }
}

// ----------------------------------------------------------- nginx / apache

/// nginx and Apache configuration.
///
/// One mode for both because they are the same shape at the level a
/// highlighter cares about: a directive word, some arguments, and blocks —
/// nginx with braces, Apache with `<Section>` tags, both handled here.
class _ConfMode extends SyntaxMode {
  const _ConfMode();

  @override
  String get id => 'nginx';
  @override
  String get label => 'nginx / Apache conf';

  static const Set<String> _blocks = {
    'http', 'server', 'location', 'events', 'upstream', 'stream', 'map',
    'types', 'if', 'limit_except', 'geo', 'split_clients', 'mail',
    'directory', 'virtualhost', 'files', 'filesmatch', 'locationmatch',
    'directorymatch', 'ifmodule', 'proxy', 'requireall', 'requireany',
  };

  @override
  LineTokens scanLine(String line, int state) {
    final spans = _Spans();
    var i = 0;
    while (i < line.length && _isSpace(line.codeUnitAt(i))) {
      i++;
    }
    if (i >= line.length) return LineTokens(spans.result, _stNormal);

    if (line.codeUnitAt(i) == 0x23) {
      spans.add(i, line.length, TokenKind.comment);
      return LineTokens(spans.result, _stNormal);
    }

    // Apache's `<Directory /srv>` / `</Directory>`.
    if (line.codeUnitAt(i) == 0x3C) {
      var j = i + 1;
      if (j < line.length && line.codeUnitAt(j) == 0x2F) j++;
      final nameEnd = _scanIdent(line, j);
      final name = line.substring(j, nameEnd).toLowerCase();
      spans.add(
        i,
        nameEnd,
        _blocks.contains(name) ? TokenKind.keyword : TokenKind.meta,
      );
      i = nameEnd;
    } else {
      final end = _scanIdent(line, i);
      if (end > i) {
        final word = line.substring(i, end).toLowerCase();
        spans.add(
          i,
          end,
          _blocks.contains(word) ? TokenKind.keyword : TokenKind.meta,
        );
        i = end;
      }
    }

    while (i < line.length) {
      if (spans.full) break;
      final c = line.codeUnitAt(i);

      if (_isSpace(c)) {
        i++;
        continue;
      }

      if (c == 0x23) {
        spans.add(i, line.length, TokenKind.comment);
        break;
      }

      if (c == 0x22 || c == 0x27) {
        final end = _scanQuoted(line, i, backslashEscapes: true);
        _addInterpolated(spans, line, i, end, TokenKind.string);
        i = end;
        continue;
      }

      if (c == 0x24) {
        final stop = _scanVariable(line, i, line.length);
        if (stop > i) {
          spans.add(i, stop, TokenKind.builtin);
          i = stop;
        } else {
          i++;
        }
        continue;
      }

      if (_isDigit(c)) {
        final end = _scanNumber(line, i);
        spans.add(i, end, TokenKind.number);
        i = end;
        continue;
      }

      if (c == 0x7B || c == 0x7D || c == 0x3B) {
        spans.add(i, i + 1, TokenKind.operator);
        i++;
        continue;
      }

      if (_isIdentStart(c)) {
        final end = _scanIdent(line, i);
        const constants = {'on', 'off', 'true', 'false'};
        if (constants.contains(line.substring(i, end).toLowerCase())) {
          spans.add(i, end, TokenKind.builtin);
        }
        i = end;
        continue;
      }

      i++;
    }

    return LineTokens(spans.result, _stNormal);
  }
}

// ------------------------------------------------------------- the registry

const SyntaxMode plainTextMode = _PlainMode();

class _PlainMode extends SyntaxMode {
  const _PlainMode();

  @override
  String get id => 'plain';
  @override
  String get label => 'Plain text';

  @override
  LineTokens scanLine(String line, int state) =>
      const LineTokens(<HighlightSpan>[], _stNormal);
}

const SyntaxMode _dartMode = _CLikeMode(
  id: 'dart',
  label: 'Dart',
  lineComment: '//',
  blockComments: true,
  tripleQuotes: true,
  annotations: true,
  capitalIsBuiltin: true,
  stringPrefixes: {'r'},
  keywords: {
    'abstract', 'as', 'assert', 'async', 'await', 'base', 'break', 'case',
    'catch', 'class', 'const', 'continue', 'covariant', 'default', 'deferred',
    'do', 'else', 'enum', 'export', 'extends', 'extension', 'external',
    'factory', 'final', 'finally', 'for', 'get', 'hide', 'if', 'implements',
    'import', 'in', 'interface', 'is', 'late', 'library', 'mixin', 'new',
    'on', 'operator', 'part', 'required', 'rethrow', 'return', 'sealed',
    'set', 'show', 'static', 'super', 'switch', 'sync', 'this', 'throw',
    'try', 'typedef', 'var', 'when', 'while', 'with', 'yield',
  },
  builtins: {
    'bool', 'double', 'dynamic', 'false', 'int', 'null', 'num', 'print',
    'String', 'true', 'void',
  },
);

const SyntaxMode _pythonMode = _CLikeMode(
  id: 'python',
  label: 'Python',
  lineComment: '#',
  tripleQuotes: true,
  annotations: true,
  stringPrefixes: {'r', 'b', 'f', 'u', 'rb', 'br', 'fr', 'rf'},
  keywords: {
    'and', 'as', 'assert', 'async', 'await', 'break', 'class', 'continue',
    'def', 'del', 'elif', 'else', 'except', 'finally', 'for', 'from',
    'global', 'if', 'import', 'in', 'is', 'lambda', 'match', 'nonlocal',
    'not', 'or', 'pass', 'raise', 'return', 'try', 'while', 'with', 'yield',
  },
  builtins: {
    'abs', 'all', 'any', 'bool', 'bytes', 'dict', 'enumerate', 'False',
    'float', 'format', 'frozenset', 'int', 'isinstance', 'len', 'list',
    'None', 'object', 'open', 'print', 'range', 'repr', 'reversed', 'self',
    'set', 'sorted', 'str', 'sum', 'super', 'True', 'tuple', 'type', 'zip',
  },
);

const SyntaxMode _javaScriptMode = _CLikeMode(
  id: 'javascript',
  label: 'JavaScript / TypeScript',
  lineComment: '//',
  blockComments: true,
  templates: true,
  annotations: true,
  keywords: {
    'abstract', 'any', 'as', 'async', 'await', 'break', 'case', 'catch',
    'class', 'const', 'continue', 'debugger', 'declare', 'default', 'delete',
    'do', 'else', 'enum', 'export', 'extends', 'finally', 'for', 'from',
    'function', 'get', 'if', 'implements', 'import', 'in', 'instanceof',
    'interface', 'is', 'keyof', 'let', 'namespace', 'new', 'of', 'private',
    'protected', 'public', 'readonly', 'return', 'satisfies', 'set',
    'static', 'super', 'switch', 'this', 'throw', 'try', 'type', 'typeof',
    'var', 'void', 'while', 'with', 'yield',
  },
  builtins: {
    'Array', 'BigInt', 'Boolean', 'Date', 'Error', 'false', 'Infinity',
    'JSON', 'Map', 'Math', 'NaN', 'null', 'Number', 'Object', 'Promise',
    'RegExp', 'Set', 'String', 'Symbol', 'boolean', 'console', 'never',
    'number', 'string', 'true', 'undefined', 'unknown',
  },
);

const SyntaxMode _sqlMode = _CLikeMode(
  id: 'sql',
  label: 'SQL',
  lineComment: '--',
  altLineComment: '#',
  blockComments: true,
  caseInsensitive: true,
  doubledQuoteEscapes: true,
  quotedIdentifiers: true,
  keywords: {
    'add', 'all', 'alter', 'and', 'as', 'asc', 'begin', 'between', 'by',
    'case', 'cascade', 'check', 'column', 'commit', 'constraint', 'create',
    'cross', 'database', 'default', 'delete', 'desc', 'distinct', 'drop',
    'else', 'end', 'exists', 'foreign', 'from', 'full', 'grant', 'group',
    'having', 'if', 'in', 'index', 'inner', 'insert', 'into', 'is', 'join',
    'key', 'left', 'like', 'limit', 'not', 'null', 'offset', 'on', 'or',
    'order', 'outer', 'primary', 'references', 'rename', 'replace',
    'returning', 'right', 'rollback', 'select', 'set', 'table', 'then',
    'to', 'transaction', 'truncate', 'union', 'unique', 'update', 'using',
    'values', 'view', 'when', 'where', 'with',
  },
  builtins: {
    'bigint', 'blob', 'boolean', 'char', 'coalesce', 'count', 'current_date',
    'current_timestamp', 'date', 'datetime', 'decimal', 'double', 'false',
    'float', 'int', 'integer', 'json', 'jsonb', 'max', 'min', 'now',
    'numeric', 'real', 'serial', 'smallint', 'sum', 'text', 'timestamp',
    'true', 'uuid', 'varchar',
  },
);

/// Every mode the override menu offers, in the order it shows them.
const List<SyntaxMode> syntaxModes = <SyntaxMode>[
  plainTextMode,
  _ShellMode(),
  _YamlMode(),
  _JsonMode(),
  _dartMode,
  _pythonMode,
  _javaScriptMode,
  _HtmlMode(),
  _CssMode(),
  _MarkdownMode(),
  _IniMode(),
  _sqlMode,
  _DockerfileMode(),
  _ConfMode(),
];

/// Looks a mode back up by [SyntaxMode.id], falling back to plain text.
SyntaxMode syntaxModeById(String? id) {
  for (final mode in syntaxModes) {
    if (mode.id == id) return mode;
  }
  return plainTextMode;
}

/// Bare names that name their own language.
const Map<String, String> _modeByName = {
  'dockerfile': 'dockerfile',
  'containerfile': 'dockerfile',
  'nginx.conf': 'nginx',
  'httpd.conf': 'nginx',
  'apache2.conf': 'nginx',
  'sshd_config': 'nginx',
  'ssh_config': 'nginx',
  'config': 'nginx',
  'makefile': 'shell',
  'gnumakefile': 'shell',
  '.bashrc': 'shell',
  '.bash_profile': 'shell',
  '.zshrc': 'shell',
  '.profile': 'shell',
  '.env': 'shell',
  'crontab': 'shell',
  'fstab': 'nginx',
  'hosts': 'nginx',
  'readme': 'markdown',
  'pubspec.lock': 'yaml',
  'cmakelists.txt': 'plain',
};

const Map<String, String> _modeByExtension = {
  '.sh': 'shell', '.bash': 'shell', '.zsh': 'shell', '.ksh': 'shell',
  '.profile': 'shell', '.bashrc': 'shell', '.zshrc': 'shell', '.env': 'shell',
  '.yaml': 'yaml', '.yml': 'yaml',
  '.json': 'json', '.jsonc': 'json', '.lock': 'json', '.webmanifest': 'json',
  '.dart': 'dart',
  '.py': 'python', '.pyw': 'python', '.pyi': 'python',
  '.js': 'javascript', '.mjs': 'javascript', '.cjs': 'javascript',
  '.jsx': 'javascript', '.ts': 'javascript', '.tsx': 'javascript',
  '.html': 'html', '.htm': 'html', '.xhtml': 'html', '.xml': 'html',
  '.svg': 'html', '.vue': 'html', '.plist': 'html', '.pom': 'html',
  '.css': 'css', '.scss': 'css', '.less': 'css', '.sass': 'css',
  '.md': 'markdown', '.markdown': 'markdown', '.mdx': 'markdown',
  '.ini': 'ini', '.toml': 'ini', '.cfg': 'ini', '.properties': 'ini',
  '.service': 'ini', '.timer': 'ini', '.socket': 'ini', '.target': 'ini',
  '.mount': 'ini', '.desktop': 'ini', '.gitconfig': 'ini',
  '.editorconfig': 'ini',
  '.sql': 'sql', '.psql': 'sql', '.ddl': 'sql',
  '.conf': 'nginx', '.nginx': 'nginx', '.htaccess': 'nginx',
};

/// The mode to open [name] in, from its name alone.
///
/// Name before extension: `Dockerfile` has no extension, and `nginx.conf`
/// would otherwise land on the generic `.conf` mode, which is the same mode
/// here but would not be if a later phase splits them.
SyntaxMode modeForFileName(String name) {
  final lower = name.toLowerCase();
  final byName = _modeByName[lower];
  if (byName != null) return syntaxModeById(byName);

  // `Dockerfile.dev`, `nginx.conf.bak` — the meaningful part is the stem.
  final stem = RemotePath.stem(lower);
  if (stem.isNotEmpty && stem != lower) {
    final byStem = _modeByName[stem];
    if (byStem != null) return syntaxModeById(byStem);
  }

  final ext = RemotePath.extension(lower);
  final byExtension = _modeByExtension[ext];
  if (byExtension != null) return syntaxModeById(byExtension);

  if (lower.startsWith('dockerfile')) return syntaxModeById('dockerfile');
  return plainTextMode;
}
