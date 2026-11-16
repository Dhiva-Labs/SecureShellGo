/// Display-only rendering of text so that every character in it can be seen.
///
/// The approval card shows a command the user is asked to allow. What the
/// shell receives is the raw string; what the user reads must not differ from
/// it. Text can look different from what it is in three ways, and each is
/// made visible here:
///
/// - control characters (a line feed, a tab, an escape, a carriage return
///   that returns the cursor and hides what came before it),
/// - bidirectional marks, embeddings, overrides and isolates, which reorder
///   what is drawn so the text reads in a different order than it runs,
/// - characters with no width, and spaces that are not the space the shell
///   splits words on.
///
/// This never changes what runs: it produces a picture of a string, nothing
/// reads it back. It is total (it never throws, whatever it is given, lone
/// surrogates included) and deterministic.
///
/// Pure Dart; no Flutter.
library;

/// What kind of character was made visible, for the card's small legend.
enum VisibleKind {
  /// A line feed, shown as `\n` and then a real line break.
  lineBreak,

  /// Another control character: `\t`, `\r`, `\x1b`, DEL, C1 controls.
  control,

  /// A bidirectional mark, embedding, override or isolate: `[U+202E]`.
  bidi,

  /// A zero-width or otherwise invisible character: `[U+200B]`.
  invisible,

  /// A space that is not the ordinary space: `[U+00A0]`.
  space,

  /// A character that is not valid text (a lone surrogate, a
  /// noncharacter, an unassigned or private-use code point): `[U+D800]`.
  invalid,

  /// A combining mark that could be drawn over its neighbours: every
  /// enclosing mark, the generic combining blocks (accents, overlays,
  /// strokes) wherever they appear, any combining mark on a plain ASCII
  /// character, and the third and later marks in a row. `[U+0336]`.
  combining,
}

/// A piece of the rendering: [text] is either ordinary text (as it was) or,
/// when [escape] is true, a visible stand-in for one hidden character. The
/// card draws escapes in a different style, so a literal backslash and `n`
/// in the command can be told from a stand-in for a line feed.
class VisibleSpan {
  const VisibleSpan(this.text, {this.escape = false});

  final String text;
  final bool escape;

  @override
  bool operator ==(Object other) =>
      other is VisibleSpan && other.text == text && other.escape == escape;

  @override
  int get hashCode => Object.hash(text, escape);

  @override
  String toString() => escape ? '«$text»' : text;
}

/// The rendering of one string.
class VisibleText {
  const VisibleText(this.spans, this.kinds, {this.truncated = false});

  final List<VisibleSpan> spans;

  /// Which kinds of character were made visible; empty when the text had
  /// none, in which case [text] is the input itself.
  final Set<VisibleKind> kinds;

  /// True when the input was longer than the limit asked for and its end was
  /// left out (only with `maxChars`).
  final bool truncated;

  /// The rendering as plain text.
  String get text => spans.map((s) => s.text).join();

  /// Whether any character was replaced by a stand-in.
  bool get hasEscapes => kinds.isNotEmpty;

  /// Whether the text holds something other than plain, visible characters
  /// and line feeds, i.e. whether the legend is worth showing for something
  /// the user could otherwise mistake.
  bool get hasSurprises => kinds.any((k) => k != VisibleKind.lineBreak);
}

/// Renders [input] with every control, bidirectional, invisible and unusual
/// space character replaced by a visible stand-in.
///
/// - line feed: `\n` and then a real line break (so the lines are laid out
///   as the shell sees them); with [breakLines] false only the stand-in,
///   for one-line places such as a name;
/// - carriage return `\r`, tab `\t`, other C0 and C1 controls and DEL:
///   `\xNN` (two lowercase hex digits);
/// - everything else hidden: `[U+XXXX]` (four to six uppercase hex digits).
///
/// [maxChars], when given, keeps only the first [maxChars] characters of
/// [input] (counted in code points, before escaping) and ends with `…`; the
/// result's [VisibleText.truncated] says so. Without it nothing is left out.
VisibleText visibleText(String input, {int? maxChars, bool breakLines = true}) {
  try {
    return _render(input, maxChars, breakLines);
  } catch (_) {
    // Cannot happen for a String; kept so a display helper never takes a
    // security prompt down with it.
    return const VisibleText(
      [VisibleSpan('[unreadable text]', escape: true)],
      {VisibleKind.invalid},
    );
  }
}

/// [visibleText] as one line of plain text, for places that take a String
/// (a list tile's title, a log line). Never longer than [maxChars] input
/// characters plus their stand-ins.
String visibleLine(String input, {int? maxChars}) =>
    visibleText(input, maxChars: maxChars, breakLines: false).text;

VisibleText _render(String input, int? maxChars, bool breakLines) {
  final spans = <VisibleSpan>[];
  final kinds = <VisibleKind>{};
  final plain = StringBuffer();

  void flush() {
    if (plain.isEmpty) return;
    spans.add(VisibleSpan(plain.toString()));
    plain.clear();
  }

  void escape(String text, VisibleKind kind) {
    flush();
    spans.add(VisibleSpan(text, escape: true));
    kinds.add(kind);
  }

  var count = 0;
  var truncated = false;
  // The character the next combining mark would attach to, and how many
  // marks are already on it.
  var base = -1;
  var marks = 0;
  for (final c in input.runes) {
    if (maxChars != null && count >= maxChars) {
      truncated = true;
      break;
    }
    count++;
    if (c == 0x0A) {
      escape(r'\n', VisibleKind.lineBreak);
      if (breakLines) plain.write('\n');
    } else if (c < 0x20 || (c >= 0x7F && c <= 0x9F)) {
      final String name;
      if (c == 0x09) {
        name = r'\t';
      } else if (c == 0x0D) {
        name = r'\r';
      } else {
        name = '\\x${c.toRadixString(16).padLeft(2, '0')}';
      }
      escape(name, VisibleKind.control);
    } else {
      var kind = _kindOf(c);
      if (kind == null && c >= 0x0300) {
        if (_isMark(c)) {
          marks++;
          if (_alwaysShownMark(c) || base < 0x80 || marks > 2) {
            kind = VisibleKind.combining;
          }
        } else {
          kind = _kindByCategory(c);
        }
      }
      if (kind == null) {
        if (!_isMark(c)) {
          base = c;
          marks = 0;
        }
        plain.writeCharCode(c);
      } else {
        escape(
          '[U+${c.toRadixString(16).toUpperCase().padLeft(4, '0')}]',
          kind,
        );
        if (kind != VisibleKind.combining) {
          base = -1;
          marks = 0;
        }
      }
    }
    if (c < 0x20 || (c >= 0x7F && c <= 0x9F)) {
      // A mark after a stand-in would be drawn on the stand-in.
      base = -1;
      marks = 0;
    }
  }
  if (truncated) plain.write('…');
  flush();
  return VisibleText(
    List<VisibleSpan>.unmodifiable(spans),
    Set<VisibleKind>.unmodifiable(kinds),
    truncated: truncated,
  );
}

/// The kind of hidden character [c] is, or null for a character that is
/// drawn as itself. [c] is neither a C0 nor a C1 control.
final RegExp _markPattern = RegExp(r'^[\p{Mn}\p{Me}]$', unicode: true);
final RegExp _enclosingPattern = RegExp(r'^\p{Me}$', unicode: true);
final RegExp _formatPattern = RegExp(r'^\p{Cf}$', unicode: true);
final RegExp _unassignedPattern = RegExp(r'^[\p{Co}\p{Cn}]$', unicode: true);

/// Whether [c] is a non-spacing or enclosing combining mark.
bool _isMark(int c) =>
    c >= 0x0300 && _markPattern.hasMatch(String.fromCharCode(c));

/// Marks shown as stand-ins wherever they are: enclosing marks (drawn
/// around, and far beyond, their base) and the script-neutral combining
/// blocks, which include overlays and strokes that can hide a character.
bool _alwaysShownMark(int c) =>
    (c >= 0x0300 && c <= 0x036F) ||
    (c >= 0x1AB0 && c <= 0x1AFF) ||
    (c >= 0x1DC0 && c <= 0x1DFF) ||
    (c >= 0x20D0 && c <= 0x20FF) ||
    (c >= 0xFE20 && c <= 0xFE2F) ||
    _enclosingPattern.hasMatch(String.fromCharCode(c));

/// Format characters not listed by name in [_kindOf] (they draw nothing),
/// and private-use, unassigned and noncharacter code points (they are drawn
/// as whatever a font happens to have, or as nothing).
VisibleKind? _kindByCategory(int c) {
  final s = String.fromCharCode(c);
  if (_formatPattern.hasMatch(s)) return VisibleKind.invisible;
  if (_unassignedPattern.hasMatch(s)) return VisibleKind.invalid;
  return null;
}

VisibleKind? _kindOf(int c) {
  if (c >= 0xD800 && c <= 0xDFFF) return VisibleKind.invalid;
  if (c == 0xFFFE || c == 0xFFFF || (c >= 0xFDD0 && c <= 0xFDEF)) {
    return VisibleKind.invalid;
  }
  if (c > 0x10FFFF) return VisibleKind.invalid;
  if (c == 0x061C || // Arabic letter mark
      c == 0x200E || // LRM
      c == 0x200F || // RLM
      (c >= 0x202A && c <= 0x202E) || // embeddings and overrides
      (c >= 0x2066 && c <= 0x2069)) {
    // isolates
    return VisibleKind.bidi;
  }
  if (c == 0x00A0 || // no-break space
      c == 0x1680 ||
      (c >= 0x2000 && c <= 0x200A) || // en/em/thin/hair spaces…
      c == 0x2028 || // line separator
      c == 0x2029 || // paragraph separator
      c == 0x202F ||
      c == 0x205F ||
      c == 0x3000) {
    return VisibleKind.space;
  }
  if (c == 0x00AD || // soft hyphen
      c == 0x034F || // combining grapheme joiner
      c == 0x115F ||
      c == 0x1160 || // Hangul fillers
      c == 0x17B4 ||
      c == 0x17B5 ||
      c == 0x180B ||
      c == 0x180C ||
      c == 0x180D ||
      c == 0x180E ||
      c == 0x180F ||
      (c >= 0x200B && c <= 0x200D) || // zero-width space, non-joiner, joiner
      c == 0x2060 || // word joiner
      (c >= 0x2061 && c <= 0x2064) || // invisible operators
      (c >= 0x206A && c <= 0x206F) || // deprecated format characters
      c == 0x2800 || // braille blank
      c == 0x3164 || // Hangul filler
      (c >= 0xFE00 && c <= 0xFE0F) || // variation selectors
      c == 0xFEFF || // byte-order mark / zero-width no-break space
      c == 0xFFA0 || // halfwidth Hangul filler
      (c >= 0xFFF9 && c <= 0xFFFC) || // interlinear annotation, object
      (c >= 0x1D173 && c <= 0x1D17A) || // musical formatting
      (c >= 0xE0000 && c <= 0xE0FFF)) {
    // tag characters and variation selectors supplement
    return VisibleKind.invisible;
  }
  return null;
}
