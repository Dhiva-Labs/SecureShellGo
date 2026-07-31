/// What a tokenizer decided a run of characters is.
///
/// Deliberately a small, language-neutral set. Every mode in
/// `services/syntax_highlighter.dart` maps onto these ten, so one palette in
/// `theme.dart` colours all thirteen languages and a new mode cannot invent a
/// colour the user's terminal scheme has no answer for.
///
/// Lives in `models/` — not next to the tokenizer — for the same reason
/// [TerminalColorScheme] does: the colour mapping needs both this and xterm's
/// `TerminalTheme`, and `services/` is not allowed the Flutter or xterm
/// import that would take.
enum TokenKind {
  /// Not classified. Never emitted as a span — the renderer fills the gaps
  /// between spans with the document's base style, which is what makes a
  /// tokenizer that gives up mid-line degrade to plain text rather than to
  /// something wrong.
  plain,

  /// Reserved words: `if`, `def`, `SELECT`, `FROM` in a Dockerfile.
  keyword,

  /// Types, built-in functions, and the literal constants that behave like
  /// them — `true`, `null`, `String`, `echo`.
  builtin,

  string,
  number,
  comment,

  /// The thing being named or configured: a YAML key, an INI section, an
  /// HTML tag, an nginx directive, a shell variable.
  meta,

  /// A modifier on that thing: an HTML attribute, a Dockerfile `--flag`, a
  /// CSS property.
  attribute,

  /// Markdown headings, and nothing else. Its own kind because it is the one
  /// token anywhere that wants weight as well as colour.
  heading,

  operator,
}

/// One classified run, as `[start, end)` offsets into the text it came from.
class HighlightSpan {
  const HighlightSpan(this.start, this.end, this.kind);

  final int start;
  final int end;
  final TokenKind kind;

  int get length => end - start;

  @override
  String toString() => 'HighlightSpan($start, $end, ${kind.name})';

  @override
  bool operator ==(Object other) =>
      other is HighlightSpan &&
      other.start == start &&
      other.end == end &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(start, end, kind);
}
