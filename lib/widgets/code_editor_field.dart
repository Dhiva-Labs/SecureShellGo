import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../l10n/l10n.dart';
import '../models/syntax_token.dart';
import '../services/editor_document.dart';
import '../services/editor_indent.dart';
import '../services/editor_search.dart';
import '../services/syntax_highlighter.dart';
import '../theme.dart';

/// Past this many characters, highlighting is switched off and the document
/// renders in the base style.
///
/// A `TextField` rebuilds its entire span tree on every keystroke. The
/// tokenizer is cached per line now (see [EditorHighlightController]), but
/// the span tree is still linear in the document, and a file that types
/// smoothly with no colour beats one that colours beautifully at four frames
/// a second.
const int editorMaxHighlightChars = 256 * 1024;

/// The line-box multiplier the field and the gutter both use.
///
/// Pinned rather than left to the font, because the gutter's arithmetic
/// depends on knowing the line height exactly: any disagreement between the
/// two shows up as line numbers drifting away from their lines further down a
/// long file.
const double editorLineHeightFactor = 1.35;

/// The field's content padding. The gutter starts its first number this far
/// down, and wrapped lines are measured this much narrower than the field.
const double _padTop = 8;
const double _padSide = 6;

/// What `RenderEditable` keeps clear at the end of a line for the caret
/// (`_kCaretGap` + the default cursor width). Wrapped-line measurement has to
/// leave the same room or line numbers drift where a line nearly fills it.
const double _caretMargin = 3;

/// A [TextEditingController] that colours what it holds.
///
/// The document model is the controller's own string — deliberately. A rope
/// or a piece table would be the textbook answer, and would mean hand-rolling
/// selection, composing regions, the undo stack and every IME interaction
/// that `EditableText` already gets right. The editor is a competent editor,
/// not an IDE; the string is the model, and this class is the only thing
/// between it and the screen.
///
/// **Tabs.** Flutter draws a tab as a space, one character wide, so a
/// tab-indented file looked indented by a single space and mixed tabs and
/// spaces were invisible. Each tab is now its own span with its font size
/// multiplied by the columns it spans to the next tab stop, and its line
/// height divided by the same, so it is exactly that wide and no taller.
/// Carets and taps land correctly because the width is the glyph's own
/// advance, and the text itself is never changed. (Letter spacing, the
/// obvious tool, is placed half before the glyph by the engine: the text
/// after a tab drew half a stop further right than the caret went.)
class EditorHighlightController extends TextEditingController {
  // Both fields are private because both have setters that invalidate the
  // token cache, and a private *named* parameter is not a thing Dart allows —
  // so an initialising formal cannot be used here however much the lint
  // would like one.
  EditorHighlightController({
    super.text,
    required SyntaxMode mode,
    required TerminalTheme theme,
  })  :
        // ignore: prefer_initializing_formals
        _mode = mode,
        // ignore: prefer_initializing_formals
        _theme = theme;

  SyntaxMode _mode;
  TerminalTheme _theme;
  List<SearchMatch> _matches = const <SearchMatch>[];
  int _currentMatch = -1;
  bool _showCurrentLine = true;

  int _tabSize = 4;
  bool _showWhitespace = false;

  /// Memoised tokenizer output for the whole document.
  ///
  /// Keyed on the exact string it was produced from, because the controller
  /// is rebuilt for selection and focus changes far more often than for text
  /// changes — moving the caret must not re-tokenize the file.
  String? _cachedFor;
  List<HighlightSpan>? _cachedSpans;

  /// Per-line tokenizer results, keyed by the state a line starts in and its
  /// text. A keystroke changes one line, so every other line — and, once the
  /// state stops changing, everything after it — is a lookup rather than a
  /// scan. Rebuilt on each pass so it only ever holds the current lines.
  Map<String, LineTokens> _lineCache = <String, LineTokens>{};

  SyntaxMode get mode => _mode;

  set mode(SyntaxMode value) {
    if (identical(_mode, value)) return;
    _mode = value;
    _cachedFor = null;
    _lineCache = <String, LineTokens>{};
    notifyListeners();
  }

  TerminalTheme get theme => _theme;

  set theme(TerminalTheme value) {
    if (identical(_theme, value)) return;
    _theme = value;
    notifyListeners();
  }

  bool get showCurrentLine => _showCurrentLine;

  set showCurrentLine(bool value) {
    if (_showCurrentLine == value) return;
    _showCurrentLine = value;
    notifyListeners();
  }

  /// How tabs are drawn and whether whitespace is shown. Set by
  /// [CodeEditorField] while it builds, so it does not notify: the field is
  /// already rebuilding the text that uses it.
  void configureLayout({
    required int tabSize,
    required bool showWhitespace,
  }) {
    _tabSize = tabSize < 1 ? 1 : tabSize;
    _showWhitespace = showWhitespace;
  }

  /// The find bar's hits, highlighted in the terminal scheme's own search
  /// colours. [current] is the one the caret is parked on.
  void setMatches(List<SearchMatch> matches, {int current = -1}) {
    _matches = matches;
    _currentMatch = current;
    notifyListeners();
  }

  void clearMatches() => setMatches(const <SearchMatch>[]);

  List<HighlightSpan> _spansFor(String source) {
    if (_cachedFor == source) return _cachedSpans!;
    final out = <HighlightSpan>[];
    final next = <String, LineTokens>{};
    var state = 0;
    var lineStart = 0;
    while (true) {
      var lineEnd = source.indexOf('\n', lineStart);
      final last = lineEnd < 0;
      if (last) lineEnd = source.length;
      final line = source.substring(lineStart, lineEnd);
      final key = '$state\u0000$line';
      final tokens =
          _lineCache[key] ?? next[key] ?? _mode.tokenizeLine(line, state);
      next[key] = tokens;
      for (final span in tokens.spans) {
        out.add(
          HighlightSpan(
            lineStart + span.start,
            lineStart + span.end,
            span.kind,
          ),
        );
      }
      state = tokens.nextState;
      if (last) break;
      lineStart = lineEnd + 1;
    }
    _lineCache = next;
    _cachedFor = source;
    _cachedSpans = out;
    return out;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final base = style ?? const TextStyle();
    final source = text;
    if (source.isEmpty) return TextSpan(text: '', style: base);
    final highlight = source.length <= editorMaxHighlightChars;

    final syntax = highlight ? _spansFor(source) : const <HighlightSpan>[];
    final matches = _matches;

    // The caret's line, so it can be tinted. Computed once here rather than
    // per slice: `lineForOffset` walks the document, and doing that inside
    // the slice loop would make rendering quadratic.
    var lineStart = -1;
    var lineEnd = -1;
    if (_showCurrentLine && selection.isValid && selection.isCollapsed) {
      final caret = selection.baseOffset.clamp(0, source.length);
      lineStart = source.lastIndexOf('\n', caret > 0 ? caret - 1 : 0);
      lineStart = lineStart < 0 ? 0 : lineStart + 1;
      if (caret == 0) lineStart = 0;
      final nextBreak = source.indexOf('\n', caret);
      lineEnd = nextBreak < 0 ? source.length : nextBreak;
    }

    final shaping = _TabAndWhitespaceShaper(
      source: source,
      tabSize: _tabSize,
      fontSize: base.fontSize ?? 14,
      lineHeight: base.height ?? editorLineHeightFactor,
      showWhitespace: _showWhitespace,
      theme: _theme,
    );
    final children = <InlineSpan>[];
    var cursor = 0;
    var si = 0;
    var mi = 0;

    while (cursor < source.length) {
      while (si < syntax.length && syntax[si].end <= cursor) {
        si++;
      }
      while (mi < matches.length && matches[mi].end <= cursor) {
        mi++;
      }

      final span = si < syntax.length ? syntax[si] : null;
      final match = mi < matches.length ? matches[mi] : null;
      final inSyntax = span != null && span.start <= cursor;
      final inMatch = match != null && match.start <= cursor;
      final inCurrentLine = cursor >= lineStart && cursor < lineEnd;

      // The next point at which *any* of the three overlays changes.
      var next = source.length;
      if (span != null) next = math.min(next, inSyntax ? span.end : span.start);
      if (match != null) {
        next = math.min(next, inMatch ? match.end : match.start);
      }
      if (lineStart >= 0) {
        if (cursor < lineStart) next = math.min(next, lineStart);
        if (inCurrentLine) next = math.min(next, lineEnd);
      }
      if (next <= cursor) next = cursor + 1;

      var sliceStyle = inSyntax
          ? base.merge(AppTheme.syntaxStyleFor(span.kind, _theme))
          : base;
      if (inCurrentLine) {
        sliceStyle = sliceStyle.copyWith(
          backgroundColor: AppTheme.editorCurrentLine(_theme),
        );
      }
      if (inMatch) {
        // A hit outranks both the syntax colour's background and the current
        // line: the whole reason it is highlighted is to be found by eye.
        final isCurrent = mi == _currentMatch;
        sliceStyle = sliceStyle.copyWith(
          backgroundColor: isCurrent
              ? AppTheme.editorCurrentMatch(_theme)
              : AppTheme.editorMatch(_theme),
          color: AppTheme.editorMatchText(_theme),
        );
      }

      shaping.emit(
        children,
        cursor,
        next,
        sliceStyle,
        highlightOverride: inMatch,
      );
      cursor = next;
    }

    return TextSpan(style: base, children: children);
  }
}

/// Splits a styled slice so each tab gets the spacing that carries it to the
/// next tab stop, and — with "show whitespace" on — tints leading tabs,
/// leading spaces and trailing whitespace. A slice with neither in it is
/// passed through as one span.
class _TabAndWhitespaceShaper {
  _TabAndWhitespaceShaper({
    required this.source,
    required this.tabSize,
    required this.fontSize,
    required this.lineHeight,
    required this.showWhitespace,
    required this.theme,
  }) : _shape = showWhitespace || source.contains('\t');

  final String source;
  final int tabSize;

  /// The text's font size and line-height factor, which a tab's span scales
  /// in opposite directions.
  final double fontSize;
  final double lineHeight;
  final bool showWhitespace;
  final TerminalTheme theme;
  final bool _shape;

  /// Visual column at [_position], carried from slice to slice (slices are
  /// emitted in document order).
  int _column = 0;
  int _position = 0;

  int _lineContentStart = 0;
  int _lineContentEnd = 0;
  int _lineEnd = -1;

  void _enterLineAt(int offset) {
    var end = source.indexOf('\n', offset);
    if (end < 0) end = source.length;
    var first = offset;
    while (first < end &&
        (source.codeUnitAt(first) == 0x20 ||
            source.codeUnitAt(first) == 0x09)) {
      first++;
    }
    var last = end;
    while (last > first &&
        (source.codeUnitAt(last - 1) == 0x20 ||
            source.codeUnitAt(last - 1) == 0x09)) {
      last--;
    }
    _lineContentStart = first;
    _lineContentEnd = first == end ? end : last;
    _lineEnd = end;
  }

  /// 0 none, 1 leading tab, 2 leading space, 3 trailing whitespace.
  int _whitespaceKind(int offset, int unit) {
    if (!showWhitespace) return 0;
    if (unit != 0x20 && unit != 0x09) return 0;
    if (offset < _lineContentStart) return unit == 0x09 ? 1 : 2;
    if (offset >= _lineContentEnd && _lineContentEnd < _lineEnd) return 3;
    return 0;
  }

  void emit(
    List<InlineSpan> out,
    int start,
    int end,
    TextStyle style, {
    bool highlightOverride = false,
  }) {
    if (!_shape) {
      out.add(TextSpan(text: source.substring(start, end), style: style));
      return;
    }
    if (_position != start || _lineEnd < 0) {
      // Slices arrive in order; this only runs for the first one.
      _position = start;
      _enterLineAt(start - _columnLineOffset(start));
      _column = _columnAt(start);
    }

    var runStart = start;
    var runKind = -1;
    void flush(int upTo) {
      if (upTo <= runStart) return;
      var runStyle = style;
      if (!highlightOverride) {
        final tint = switch (runKind) {
          1 => AppTheme.editorIndentTab(theme),
          2 => AppTheme.editorIndentSpace(theme),
          3 => AppTheme.editorTrailingWhitespace(theme),
          _ => null,
        };
        if (tint != null) runStyle = runStyle.copyWith(backgroundColor: tint);
      }
      out.add(
        TextSpan(text: source.substring(runStart, upTo), style: runStyle),
      );
      runStart = upTo;
    }

    for (var i = start; i < end; i++) {
      final unit = source.codeUnitAt(i);
      if (unit == 0x0A) {
        flush(i);
        runKind = -1;
        _column = 0;
        _enterLineAt(i + 1);
        continue;
      }
      if (i >= _lineEnd) _enterLineAt(i);
      final kind = _whitespaceKind(i, unit);
      if (unit == 0x09) {
        flush(i);
        final width = tabSize - _column % tabSize;
        var tabStyle = style;
        if (!highlightOverride && kind != 0) {
          tabStyle = tabStyle.copyWith(
            backgroundColor: kind == 3
                ? AppTheme.editorTrailingWhitespace(theme)
                : AppTheme.editorIndentTab(theme),
          );
        }
        if (width > 1) {
          // Width × the glyph, at 1/width of the line height: the same row.
          tabStyle = tabStyle.copyWith(
            fontSize: fontSize * width,
            height: lineHeight / width,
          );
        }
        out.add(TextSpan(text: '\t', style: tabStyle));
        runStart = i + 1;
        runKind = -1;
        _column += width;
        continue;
      }
      if (kind != runKind) {
        flush(i);
        runKind = kind;
      }
      _column++;
    }
    flush(end);
    _position = end;
  }

  int _columnLineOffset(int offset) {
    final lineStart = offset == 0
        ? 0
        : source.lastIndexOf('\n', offset - 1) + 1;
    return offset - lineStart;
  }

  int _columnAt(int offset) {
    final lineStart = offset == 0
        ? 0
        : source.lastIndexOf('\n', offset - 1) + 1;
    var column = 0;
    for (var i = lineStart; i < offset; i++) {
      column = source.codeUnitAt(i) == 0x09
          ? column + tabSize - column % tabSize
          : column + 1;
    }
    return column;
  }
}

/// Turns what the keyboard did into what an IDE would have done: Enter
/// carries indentation, openers close themselves, Backspace takes a whole
/// indent level, and pasted Windows line breaks become `\n` (see
/// [normaliseInsertedLineBreaks]).
///
/// A formatter rather than key bindings because that is the one place every
/// input path meets — a hardware keyboard, a phone's soft keyboard, a paste —
/// and because the edit it returns is one undo step with the keystroke that
/// caused it.
class _EditorInputFormatter extends TextInputFormatter {
  _EditorInputFormatter(this._style, this._language, this._smart);

  final IndentStyle Function() _style;
  final EditorLanguage Function() _language;
  final bool Function() _smart;

  static TextEditingValue _value(EditResult r) => TextEditingValue(
    text: r.text,
    selection: TextSelection(baseOffset: r.start, extentOffset: r.end),
  );

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    // Mid-composition (CJK input, a predictive word in progress) the text is
    // the input method's, not ours to rewrite.
    if (newValue.composing.isValid && !newValue.composing.isCollapsed) {
      return newValue;
    }

    var value = newValue;
    final normalised = normaliseInsertedLineBreaks(
      oldText: oldValue.text,
      newText: newValue.text,
      base: newValue.selection.baseOffset,
      extent: newValue.selection.extentOffset,
    );
    if (normalised != null) {
      value = TextEditingValue(
        text: normalised.text,
        selection: TextSelection(
          baseOffset: normalised.base,
          extentOffset: normalised.extent,
        ),
      );
    }
    if (!_smart()) return value;

    final selection = oldValue.selection;
    if (!selection.isValid || !value.selection.isValid) return value;
    final old = oldValue.text;
    final start = selection.start;
    final end = selection.end;

    // One character typed over the selection.
    if (value.selection.isCollapsed &&
        value.selection.baseOffset == start + 1 &&
        value.text.length == old.length - (end - start) + 1 &&
        value.text.startsWith(old.substring(0, start)) &&
        value.text.endsWith(old.substring(end))) {
      final char = value.text[start];
      final result = char == '\n'
          ? newline(old, start, end, _style(), _language())
          : typeCharacter(old, start, end, char, _style(), _language());
      return result == null ? value : _value(result);
    }

    // Backspace: the character before a caret removed.
    if (selection.isCollapsed &&
        start > 0 &&
        value.selection.isCollapsed &&
        value.selection.baseOffset == start - 1 &&
        value.text.length == old.length - 1 &&
        value.text == old.substring(0, start - 1) + old.substring(start)) {
      final result = smartBackspace(old, start, start, _style());
      if (result != null) return _value(result);
    }
    return value;
  }
}

/// The editor's text surface: a gutter of line numbers beside a monospace
/// field, scrolled as one.
///
/// **Why the field keeps its own scrolling.** The obvious layout — one
/// scroll view holding gutter and field together — desynchronises nothing but
/// breaks caret-follow: `EditableText` reveals the caret by scrolling *its*
/// controller, and a field with `NeverScrollableScrollPhysics` inside someone
/// else's viewport simply lets the caret walk off the bottom of the screen
/// while you type. So the field scrolls itself, and the gutter paints from
/// the field's own offset — which cannot drift, because there is only one
/// offset in the system.
class CodeEditorField extends StatefulWidget {
  const CodeEditorField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.theme,
    required this.fontSize,
    required this.softWrap,
    this.readOnly = false,
    this.autofocus = false,
    this.undoController,
    this.indentStyle = const IndentStyle.spaces(4),
    this.language = EditorLanguage.plain,
    this.showWhitespace = false,
    this.smartEditing = true,
  });

  final EditorHighlightController controller;
  final FocusNode focusNode;
  final TerminalTheme theme;
  final double fontSize;

  /// Off by default for a code editor, and the reason the gutter's
  /// arithmetic is exact: with wrapping off, one logical line is one row.
  final bool softWrap;

  final bool readOnly;

  /// Whether the field takes the keyboard as soon as it is built. Left to the
  /// caller because it is a platform decision, not a field one: on a desktop
  /// it is what makes Ctrl+A and friends work on the file you just opened,
  /// and on a phone it would throw up the soft keyboard over half of it.
  final bool autofocus;

  /// A handle on the undo history the field already keeps, so a menu can
  /// drive the same stack Ctrl+Z does. Optional — undo works either way; this
  /// only makes it reachable without a keyboard.
  final UndoHistoryController? undoController;

  /// How this file indents — what Tab inserts, Backspace removes and Enter
  /// carries. Detected per file by the screen; see `editor_indent.dart`.
  final IndentStyle indentStyle;

  final EditorLanguage language;

  /// Tints leading tabs, leading spaces and trailing whitespace apart.
  final bool showWhitespace;

  /// Auto-indent, auto-close and smart Backspace. Pasted line breaks are
  /// normalised either way.
  final bool smartEditing;

  @override
  State<CodeEditorField> createState() => CodeEditorFieldState();
}

class CodeEditorFieldState extends State<CodeEditorField> {
  final ScrollController _vertical = ScrollController();
  final ScrollController _horizontal = ScrollController();

  late final _EditorInputFormatter _formatter = _EditorInputFormatter(
    () => widget.indentStyle,
    () => widget.language,
    () => widget.smartEditing && !widget.readOnly,
  );

  /// Line heights for the gutter when wrapping is on, cached against the text
  /// and width they were measured for.
  List<double>? _wrappedHeights;
  String? _measuredText;
  double? _measuredWidth;
  double? _measuredFontSize;

  /// The size the text is actually laid out at: the editor's own size
  /// through the system text scale. Scaled here, once, and the field is told
  /// not to scale again — it used to scale its text while the gutter and
  /// every measurement here used the unscaled size, so on a phone set to
  /// large text the line numbers walked away from their lines.
  double _fontSize = 14;

  /// One row's height as the engine lays it out; see [_measureText].
  double _rowHeight = 14 * editorLineHeightFactor;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void didUpdateWidget(CodeEditorField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onTextChanged);
      widget.controller.addListener(_onTextChanged);
      _invalidateMeasurements();
    }
    if (oldWidget.softWrap != widget.softWrap ||
        oldWidget.fontSize != widget.fontSize ||
        oldWidget.indentStyle != widget.indentStyle) {
      _invalidateMeasurements();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  void _invalidateMeasurements() {
    _wrappedHeights = null;
    _measuredText = null;
  }

  void _onTextChanged() {
    // The gutter's line count and the content width both follow the text, and
    // the caret's line follows the selection. Cheap: this only marks dirty.
    if (mounted) setState(() {});
  }

  /// Runs one of the line operations in `editor_indent.dart` against the
  /// document. Public so a key bar or a menu can drive the same edits the
  /// keyboard does. Recorded by the field's undo history like any edit.
  void apply(EditResult? Function(String text, int start, int end) edit) {
    if (widget.readOnly) return;
    final value = widget.controller.value;
    final selection = value.selection;
    if (!selection.isValid) return;
    final result = edit(value.text, selection.start, selection.end);
    if (result == null) return;
    widget.controller.value = TextEditingValue(
      text: result.text,
      selection: TextSelection(
        baseOffset: result.start,
        extentOffset: result.end,
      ),
    );
  }

  /// Types [text] at the caret as if from the keyboard — through the same
  /// auto-close and auto-indent rules — for the touch key bar.
  void typeText(String text) {
    if (widget.readOnly) return;
    final old = widget.controller.value;
    final selection = old.selection.isValid
        ? old.selection
        : TextSelection.collapsed(offset: old.text.length);
    final inserted = old.text.replaceRange(
      selection.start,
      selection.end,
      text,
    );
    final proposed = TextEditingValue(
      text: inserted,
      selection: TextSelection.collapsed(offset: selection.start + text.length),
    );
    widget.controller.value = _formatter.formatEditUpdate(
      old.copyWith(selection: selection),
      proposed,
    );
  }

  void indentSelection() =>
      apply((t, s, e) => indent(t, s, e, widget.indentStyle));

  void outdentSelection() =>
      apply((t, s, e) => outdent(t, s, e, widget.indentStyle));

  TextStyle get _textStyle => TextStyle(
    fontFamily: AppTheme.monoFontFamily,
    fontFamilyFallback: AppTheme.monoFontFamilyFallback,
    fontSize: _fontSize,
    height: editorLineHeightFactor,
    // Both pinned rather than inherited from Material 3's field style.
    // Its 0.5 of letter spacing was seen by none of the measuring here: a
    // 60-character line drew 30px wider than measured, so it wrapped with
    // wrapping off and wrapped-line numbers drifted. Its even leading would
    // make a row holding a tab (a bigger glyph at a smaller line height)
    // taller than the rest; proportional leading keeps every row one size.
    letterSpacing: 0,
    leadingDistribution: TextLeadingDistribution.proportional,
    color: widget.theme.foreground,
  );

  /// The gutter's row height, for tests that hold it against the field's.
  @visibleForTesting
  double get rowHeight => _rowHeight;

  /// The gutter's per-line heights with wrapping on, likewise.
  @visibleForTesting
  List<double>? get wrappedLineHeights => _wrappedHeights;

  /// Width of one character and height of one row in the monospace face,
  /// measured rather than computed. A guessed width is visibly wrong
  /// wherever the fallback font differs, and the engine rounds row heights:
  /// font size × line-height factor drifted from the rows actually drawn by
  /// up to a third of a pixel a line, a row or more by the end of a long
  /// file.
  ({double charWidth, double rowHeight}) _measureText() {
    final painter = TextPainter(
      text: TextSpan(text: '0' * 10, style: _textStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    final metrics = (charWidth: painter.width / 10, rowHeight: painter.height);
    painter.dispose();
    return metrics;
  }

  /// Per-line heights when wrapping is on.
  ///
  /// One `TextPainter` layout per line, cached against the text and the
  /// width. Only paid while soft-wrap is on: with it off, every line is
  /// exactly one row and the gutter needs no measuring at all. The document
  /// cap in `editor_document.dart` is what bounds the cost of this.
  List<double>? _lineHeights(String text, double width) {
    if (!widget.softWrap) return null;
    if (_measuredText == text &&
        _measuredWidth == width &&
        _measuredFontSize == _fontSize &&
        _wrappedHeights != null) {
      return _wrappedHeights!;
    }
    final painter = TextPainter(textDirection: TextDirection.ltr);
    final heights = <double>[];
    for (final line in text.split('\n')) {
      painter.text = TextSpan(
        text: line.isEmpty ? ' ' : line,
        style: _textStyle,
      );
      painter.layout(maxWidth: width);
      heights.add(painter.height);
    }
    _wrappedHeights = heights;
    _measuredText = text;
    _measuredWidth = width;
    _measuredFontSize = _fontSize;
    return heights;
  }

  /// Which 1-based line the caret is on, for the gutter's highlight.
  int get _caretLine {
    final selection = widget.controller.selection;
    if (!selection.isValid) return -1;
    return lineForOffset(widget.controller.text, selection.baseOffset);
  }

  Map<ShortcutActivator, VoidCallback> get _bindings {
    final style = widget.indentStyle;
    final language = widget.language;
    final bindings = <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.tab): indentSelection,
      const SingleActivator(LogicalKeyboardKey.tab, shift: true):
          outdentSelection,
      const SingleActivator(LogicalKeyboardKey.arrowUp, alt: true): () =>
          apply((t, s, e) => moveLines(t, s, e, up: true)),
      const SingleActivator(LogicalKeyboardKey.arrowDown, alt: true): () =>
          apply((t, s, e) => moveLines(t, s, e, up: false)),
      const SingleActivator(
        LogicalKeyboardKey.arrowUp,
        alt: true,
        shift: true,
      ): () =>
          apply((t, s, e) => duplicateLines(t, s, e, down: false)),
      const SingleActivator(
        LogicalKeyboardKey.arrowDown,
        alt: true,
        shift: true,
      ): () =>
          apply((t, s, e) => duplicateLines(t, s, e)),
    };
    for (final modifier in const [_Mod.control, _Mod.meta]) {
      bindings[modifier.activator(LogicalKeyboardKey.bracketRight)] = () =>
          apply((t, s, e) => indentLines(t, s, e, style));
      bindings[modifier.activator(LogicalKeyboardKey.bracketLeft)] = () =>
          apply((t, s, e) => outdent(t, s, e, style));
      bindings[modifier.activator(LogicalKeyboardKey.slash)] = () =>
          apply((t, s, e) => toggleLineComment(t, s, e, language));
    }
    return bindings;
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.controller.text;
    _fontSize = MediaQuery.textScalerOf(context).scale(widget.fontSize);
    final metrics = _measureText();
    final charWidth = metrics.charWidth;
    _rowHeight = metrics.rowHeight;
    widget.controller.configureLayout(
      tabSize: widget.indentStyle.size,
      showWhitespace: widget.showWhitespace,
    );

    // Line count and longest line in one pass, without splitting the
    // document into a list on every keystroke.
    var lineCount = 1;
    var longest = 0;
    var current = 0;
    for (var i = 0; i < text.length; i++) {
      final unit = text.codeUnitAt(i);
      if (unit == 0x0A) {
        lineCount++;
        if (current > longest) longest = current;
        current = 0;
      } else {
        current += unit == 0x09 ? widget.indentStyle.size : 1;
      }
    }
    if (current > longest) longest = current;

    final digits = lineCount.toString().length;
    final gutterWidth = digits * charWidth + 20;

    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth - gutterWidth;
        final textWidth = available > 0 ? available : constraints.maxWidth;

        // With wrapping off the field is given room for its longest line and
        // scrolls sideways inside the viewport; with it on the field is
        // exactly the viewport, so it wraps where the screen ends.
        final contentWidth = widget.softWrap
            ? textWidth
            : math.max(textWidth, longest * charWidth + charWidth * 4);

        final heights = _lineHeights(
          text,
          textWidth - _padSide * 2 - _caretMargin,
        );

        Widget field = TextField(
          controller: widget.controller,
          focusNode: widget.focusNode,
          scrollController: _vertical,
          undoController: widget.undoController,
          autofocus: widget.autofocus,
          readOnly: widget.readOnly,
          maxLines: null,
          expands: true,
          style: _textStyle,
          cursorColor: widget.theme.cursor,
          inputFormatters: [_formatter],
          // Everything a code field must not do to what is typed
          // into it: no capitalisation, no autocorrect, no
          // suggestion bar rewriting an identifier.
          keyboardType: TextInputType.multiline,
          textCapitalization: TextCapitalization.none,
          autocorrect: false,
          enableSuggestions: false,
          smartDashesType: SmartDashesType.disabled,
          smartQuotesType: SmartQuotesType.disabled,
          decoration: const InputDecoration(
            border: InputBorder.none,
            focusedBorder: InputBorder.none,
            enabledBorder: InputBorder.none,
            filled: false,
            isDense: true,
            contentPadding: EdgeInsets.fromLTRB(
              _padSide,
              _padTop,
              _padSide,
              _padTop,
            ),
          ),
        );
        // Already scaled, in `_fontSize`.
        field = MediaQuery.withNoTextScaling(child: field);
        if (!widget.readOnly) {
          // Tab indents instead of moving focus to the next control, and the
          // line operations a programmer reaches for by habit are here.
          field = CallbackShortcuts(bindings: _bindings, child: field);
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: gutterWidth,
              height: constraints.maxHeight,
              child: ClipRect(
                child: Semantics(
                  container: true,
                  // Painted, not built from widgets, so a screen reader is
                  // told what the column is rather than nothing at all.
                  label: context.l10n.editorGutterLabel(lineCount),
                  child: CustomPaint(
                    painter: _GutterPainter(
                      scroll: _vertical,
                      count: lineCount,
                      heights: heights,
                      lineHeight: _rowHeight,
                      activeLine: _caretLine,
                      theme: widget.theme,
                      style: _textStyle,
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                controller: _horizontal,
                scrollDirection: Axis.horizontal,
                // Nothing to scroll to when the field is already the width of
                // the viewport, and a sideways drag on a wrapped document
                // reads as a mis-swipe.
                physics: widget.softWrap
                    ? const NeverScrollableScrollPhysics()
                    : const ClampingScrollPhysics(),
                child: SizedBox(
                  width: contentWidth,
                  height: constraints.maxHeight,
                  child: field,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

enum _Mod {
  control,
  meta;

  SingleActivator activator(LogicalKeyboardKey key) => switch (this) {
    _Mod.control => SingleActivator(key, control: true),
    _Mod.meta => SingleActivator(key, meta: true),
  };
}

/// The line-number column: paints only the numbers in view, from the field's
/// own scroll offset. A widget per line meant ten thousand widgets rebuilt
/// on every keystroke of a long file.
class _GutterPainter extends CustomPainter {
  _GutterPainter({
    required this.scroll,
    required this.count,
    required this.heights,
    required this.lineHeight,
    required this.activeLine,
    required this.theme,
    required this.style,
  }) : super(repaint: scroll);

  final ScrollController scroll;
  final int count;

  /// Per-line heights when wrapping; null when every line is [lineHeight].
  final List<double>? heights;
  final double lineHeight;
  final int activeLine;
  final TerminalTheme theme;
  final TextStyle style;

  @override
  void paint(Canvas canvas, Size size) {
    final offset = scroll.hasClients ? scroll.offset : 0.0;
    final top = offset - _padTop;
    final bottom = top + size.height;

    var line = 0;
    var y = 0.0;
    if (heights == null) {
      line = math.max(0, (top / lineHeight).floor());
      y = line * lineHeight;
    } else {
      while (line < heights!.length && y + heights![line] < top) {
        y += heights![line];
        line++;
      }
    }

    final painter = TextPainter(textDirection: TextDirection.ltr);
    final activeBand = AppTheme.editorCurrentLine(theme);
    while (line < count && y <= bottom) {
      final height = heights != null && line < heights!.length
          ? heights![line]
          : lineHeight;
      final drawY = y - offset + _padTop;
      final active = line + 1 == activeLine;
      if (active) {
        canvas.drawRect(
          Rect.fromLTWH(0, drawY, size.width, height),
          Paint()..color = activeBand,
        );
      }
      painter.text = TextSpan(
        text: '${line + 1}',
        style: style.copyWith(
          color: active
              ? AppTheme.editorGutterActiveText(theme)
              : AppTheme.editorGutterText(theme),
        ),
      );
      painter.layout();
      painter.paint(canvas, Offset(size.width - 8 - painter.width, drawY));
      y += height;
      line++;
    }
  }

  @override
  bool shouldRepaint(_GutterPainter oldDelegate) =>
      oldDelegate.count != count ||
      oldDelegate.activeLine != activeLine ||
      oldDelegate.lineHeight != lineHeight ||
      !identical(oldDelegate.heights, heights) ||
      !identical(oldDelegate.theme, theme) ||
      oldDelegate.style != style;
}
