/// What the find bar is currently looking for.
///
/// A value object so the search logic can be tested without a widget, and so
/// "the query changed" is one comparison rather than three.
class EditorQuery {
  const EditorQuery({
    required this.pattern,
    this.isRegex = false,
    this.caseSensitive = false,
  });

  final String pattern;
  final bool isRegex;
  final bool caseSensitive;

  bool get isEmpty => pattern.isEmpty;

  EditorQuery copyWith({
    String? pattern,
    bool? isRegex,
    bool? caseSensitive,
  }) =>
      EditorQuery(
        pattern: pattern ?? this.pattern,
        isRegex: isRegex ?? this.isRegex,
        caseSensitive: caseSensitive ?? this.caseSensitive,
      );

  @override
  bool operator ==(Object other) =>
      other is EditorQuery &&
      other.pattern == pattern &&
      other.isRegex == isRegex &&
      other.caseSensitive == caseSensitive;

  @override
  int get hashCode => Object.hash(pattern, isRegex, caseSensitive);
}

/// One hit, as `[start, end)` offsets, with any capture groups.
class SearchMatch {
  const SearchMatch(this.start, this.end, [this.groups = const <String?>[]]);

  final int start;
  final int end;

  /// Groups 1..n. Empty for a plain-text query, which has none.
  final List<String?> groups;

  bool get isEmpty => end == start;

  @override
  String toString() => 'SearchMatch($start, $end)';
}

/// A query turned into something that can be run, or the reason it cannot be.
class CompiledQuery {
  const CompiledQuery._(this.expression, this.error);

  final RegExp? expression;

  /// Written for the find bar to show under the field. Non-null exactly when
  /// [expression] is null and the pattern was not simply empty.
  final String? error;

  bool get isUsable => expression != null;
}

/// Compiles [query]. Never throws — an unfinished regex is the normal state
/// of the field while someone is typing one, so `(foo|` has to be a message
/// under the box rather than an exception out of a keystroke handler.
CompiledQuery compileQuery(EditorQuery query) {
  if (query.pattern.isEmpty) return const CompiledQuery._(null, null);
  final source =
      query.isRegex ? query.pattern : RegExp.escape(query.pattern);
  try {
    return CompiledQuery._(
      RegExp(source, caseSensitive: query.caseSensitive, multiLine: true),
      null,
    );
  } on FormatException catch (e) {
    return CompiledQuery._(null, e.message);
  }
}

/// How many hits the find bar will hold at once.
///
/// `.` as a regex over a 2 MB file is two million matches, and a list of two
/// million objects is not a thing to build inside a keystroke handler. The
/// bar shows "1 of 10000+" past this point; [replaceAll] is unaffected,
/// because it never materialises the list.
const int editorMaxMatches = 10000;

/// Every match of [query] in [text], left to right, up to
/// [editorMaxMatches].
///
/// Zero-width matches — `a*`, `^`, `\b` — are handled by `allMatches`, which
/// advances past an empty match rather than spinning on it. That is worth
/// stating because a regex box is exactly where a user types `x*` by
/// accident, and the alternative to advancing is an infinite loop that takes
/// the app with it.
List<SearchMatch> findMatches(String text, EditorQuery query) {
  final expression = compileQuery(query).expression;
  if (expression == null) return const <SearchMatch>[];

  final out = <SearchMatch>[];
  for (final match in expression.allMatches(text)) {
    out.add(SearchMatch(
      match.start,
      match.end,
      <String?>[for (var g = 1; g <= match.groupCount; g++) match.group(g)],
    ));
    if (out.length >= editorMaxMatches) break;
  }
  return out;
}

/// The index of the first match at or after [caret], wrapping to 0.
///
/// Returns -1 for no matches at all, which is the only case the find bar has
/// to treat differently.
int matchIndexAtOrAfter(List<SearchMatch> matches, int caret) {
  if (matches.isEmpty) return -1;
  for (var i = 0; i < matches.length; i++) {
    if (matches[i].start >= caret) return i;
  }
  return 0;
}

/// The index of the last match strictly before [caret], wrapping to the end.
int matchIndexBefore(List<SearchMatch> matches, int caret) {
  if (matches.isEmpty) return -1;
  for (var i = matches.length - 1; i >= 0; i--) {
    if (matches[i].start < caret) return i;
  }
  return matches.length - 1;
}

/// What a replacement did.
class ReplaceResult {
  const ReplaceResult({
    required this.text,
    required this.count,
    required this.caret,
  });

  final String text;

  /// How many hits were replaced. Reported to the user verbatim — "Replaced
  /// 0" is a materially different outcome from "Replaced 41" and the bar says
  /// which happened.
  final int count;

  /// Where the caret should end up: just past the last replacement, so
  /// repeated "Replace" walks forward through the file.
  final int caret;
}

/// Expands `$1`…`$9`, `$&` and `$$` in [replacement] against [match].
///
/// Only for a regex query. A plain-text replacement is inserted literally,
/// because someone replacing `cost` with `$5` means five dollars.
String _expand(String replacement, SearchMatch match, String text) {
  if (!replacement.contains(r'$')) return replacement;
  final out = StringBuffer();
  for (var i = 0; i < replacement.length; i++) {
    final c = replacement[i];
    if (c != r'$' || i + 1 >= replacement.length) {
      out.write(c);
      continue;
    }
    final next = replacement[i + 1];
    if (next == r'$') {
      out.write(r'$');
      i++;
    } else if (next == '&') {
      out.write(text.substring(match.start, match.end));
      i++;
    } else if (next.codeUnitAt(0) >= 0x31 && next.codeUnitAt(0) <= 0x39) {
      final group = next.codeUnitAt(0) - 0x30;
      out.write(group <= match.groups.length
          ? (match.groups[group - 1] ?? '')
          : '');
      i++;
    } else {
      out.write(c);
    }
  }
  return out.toString();
}

/// Replaces every match of [query] in [text].
///
/// Built by splicing from a single left-to-right pass rather than by
/// `String.replaceAll`, for two reasons: the count has to be exact, and the
/// replacement must not be reinterpreted — `replaceAll` with a `RegExp` gives
/// `$1` a meaning in the replacement string whether or not the user asked for
/// a regex search.
ReplaceResult replaceAll(String text, EditorQuery query, String replacement) {
  final expression = compileQuery(query).expression;
  if (expression == null) {
    return ReplaceResult(text: text, count: 0, caret: 0);
  }

  final out = StringBuffer();
  var cursor = 0;
  var caret = 0;
  var count = 0;
  for (final match in expression.allMatches(text)) {
    out.write(text.substring(cursor, match.start));
    final piece = query.isRegex
        ? _expand(
            replacement,
            SearchMatch(
              match.start,
              match.end,
              <String?>[
                for (var g = 1; g <= match.groupCount; g++) match.group(g),
              ],
            ),
            text,
          )
        : replacement;
    out.write(piece);
    caret = out.length;
    cursor = match.end;
    count++;
  }
  if (count == 0) return ReplaceResult(text: text, count: 0, caret: 0);
  out.write(text.substring(cursor));
  return ReplaceResult(text: out.toString(), count: count, caret: caret);
}

/// Replaces the first match at or after [from], wrapping once.
///
/// Wrapping matters: "Replace" pressed repeatedly should clear the file, not
/// stop dead at the last hit and leave the ones above the caret behind.
ReplaceResult replaceOne(
  String text,
  EditorQuery query,
  String replacement, {
  int from = 0,
}) {
  final matches = findMatches(text, query);
  final index = matchIndexAtOrAfter(matches, from);
  if (index < 0) return ReplaceResult(text: text, count: 0, caret: from);

  final match = matches[index];
  final piece =
      query.isRegex ? _expand(replacement, match, text) : replacement;
  final replaced = text.replaceRange(match.start, match.end, piece);
  return ReplaceResult(
    text: replaced,
    count: 1,
    caret: match.start + piece.length,
  );
}

/// The offset the caret goes to for "go to line [line]" (1-based).
///
/// Clamped rather than refused: a user who types 9999 into the box on a
/// 40-line file means the end of the file, and an error toast for that is
/// pedantry.
int offsetForLine(String text, int line) {
  if (line <= 1) return 0;
  var seen = 1;
  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) != 0x0A) continue;
    seen++;
    if (seen == line) return i + 1;
  }
  return text.length;
}

/// Which 1-based line [offset] falls on.
int lineForOffset(String text, int offset) {
  final limit = offset > text.length ? text.length : offset;
  var line = 1;
  for (var i = 0; i < limit; i++) {
    if (text.codeUnitAt(i) == 0x0A) line++;
  }
  return line;
}
