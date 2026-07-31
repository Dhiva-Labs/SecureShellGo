import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../models/syntax_token.dart';
import '../services/editor_search.dart';
import '../services/syntax_highlighter.dart';
import '../theme.dart';

/// Past this many characters, highlighting is switched off and the document
/// renders in the base style.
///
/// A `TextField` rebuilds its entire span tree on every keystroke, and the
/// tokenize-plus-build cost is linear in the document. A quarter of a
/// megabyte of shell script is already an unusual thing to be editing over
/// SSH, and a file that types smoothly with no colour is a better outcome
/// than one that colours beautifully at four frames a second.
const int editorMaxHighlightChars = 256 * 1024;

/// The line-box multiplier the field and the gutter both use.
///
/// Pinned rather than left to the font, because the gutter's arithmetic
/// depends on knowing the line height exactly: any disagreement between the
/// two shows up as line numbers drifting away from their lines further down a
/// long file.
const double editorLineHeightFactor = 1.35;

/// A [TextEditingController] that colours what it holds.
///
/// The document model is the controller's own string — deliberately. A rope
/// or a piece table would be the textbook answer, and would mean hand-rolling
/// selection, composing regions, the undo stack and every IME interaction
/// that `EditableText` already gets right. The editor is a competent editor,
/// not an IDE; the string is the model, and this class is the only thing
/// between it and the screen.
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

  /// Memoised tokenizer output.
  ///
  /// Keyed on the exact string it was produced from, because the controller
  /// is rebuilt for selection and focus changes far more often than for text
  /// changes — moving the caret must not re-tokenize the file.
  String? _cachedFor;
  List<HighlightSpan>? _cachedSpans;

  SyntaxMode get mode => _mode;

  set mode(SyntaxMode value) {
    if (identical(_mode, value)) return;
    _mode = value;
    _cachedFor = null;
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
    final spans = _mode.tokenize(source);
    _cachedFor = source;
    _cachedSpans = spans;
    return spans;
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
    if (source.length > editorMaxHighlightChars) {
      return TextSpan(text: source, style: base);
    }

    final syntax = _spansFor(source);
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

      children.add(TextSpan(
        text: source.substring(cursor, next),
        style: sliceStyle,
      ));
      cursor = next;
    }

    return TextSpan(style: base, children: children);
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
/// while you type. So the field scrolls itself, and the gutter is translated
/// by the field's own offset — which cannot drift, because there is only one
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
  });

  final EditorHighlightController controller;
  final FocusNode focusNode;
  final TerminalTheme theme;
  final double fontSize;

  /// Off by default for a code editor, and the reason the gutter's
  /// arithmetic is exact: with wrapping off, one logical line is one row.
  final bool softWrap;

  final bool readOnly;

  @override
  State<CodeEditorField> createState() => _CodeEditorFieldState();
}

class _CodeEditorFieldState extends State<CodeEditorField> {
  final ScrollController _vertical = ScrollController();
  final ScrollController _horizontal = ScrollController();

  /// Line heights for the gutter when wrapping is on, cached against the text
  /// and width they were measured for.
  List<double>? _wrappedHeights;
  String? _measuredText;
  double? _measuredWidth;
  double? _measuredFontSize;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void didUpdateWidget(CodeEditorField old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, widget.controller)) {
      old.controller.removeListener(_onTextChanged);
      widget.controller.addListener(_onTextChanged);
      _invalidateMeasurements();
    }
    if (old.softWrap != widget.softWrap || old.fontSize != widget.fontSize) {
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

  TextStyle get _textStyle => TextStyle(
        fontFamily: AppTheme.monoFontFamily,
        fontFamilyFallback: AppTheme.monoFontFamilyFallback,
        fontSize: widget.fontSize,
        height: editorLineHeightFactor,
        color: widget.theme.foreground,
      );

  double get _lineHeight => widget.fontSize * editorLineHeightFactor;

  /// Width of one character in the monospace face, measured rather than
  /// guessed — the fallback font differs per platform and a guess would put
  /// the horizontal extent visibly wrong on one of them.
  double _measureCharWidth() {
    final painter = TextPainter(
      text: TextSpan(text: '0' * 10, style: _textStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    return painter.width / 10;
  }

  /// Per-line heights when wrapping is on.
  ///
  /// One `TextPainter` layout per line, cached against the text and the
  /// width. Only paid while soft-wrap is on: with it off, every line is
  /// exactly one row and the gutter needs no measuring at all. The document
  /// cap in `editor_document.dart` is what bounds the cost of this.
  List<double> _lineHeights(List<String> lines, double width) {
    if (!widget.softWrap) {
      return List<double>.filled(lines.length, _lineHeight);
    }
    final text = widget.controller.text;
    if (_measuredText == text &&
        _measuredWidth == width &&
        _measuredFontSize == widget.fontSize &&
        _wrappedHeights != null) {
      return _wrappedHeights!;
    }
    final painter = TextPainter(textDirection: TextDirection.ltr);
    final heights = <double>[];
    for (final line in lines) {
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
    _measuredFontSize = widget.fontSize;
    return heights;
  }

  /// Which 1-based line the caret is on, for the gutter's highlight.
  int get _caretLine {
    final selection = widget.controller.selection;
    if (!selection.isValid) return -1;
    return lineForOffset(widget.controller.text, selection.baseOffset);
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.controller.text;
    final lines = text.split('\n');
    final charWidth = _measureCharWidth();
    final digits = lines.length.toString().length;
    final gutterWidth = digits * charWidth + 20;

    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth - gutterWidth;
        final textWidth = available > 0 ? available : constraints.maxWidth;

        // With wrapping off the field is given room for its longest line and
        // scrolls sideways inside the viewport; with it on the field is
        // exactly the viewport, so it wraps where the screen ends.
        var longest = 0;
        if (!widget.softWrap) {
          for (final line in lines) {
            if (line.length > longest) longest = line.length;
          }
        }
        final contentWidth = widget.softWrap
            ? textWidth
            : math.max(textWidth, longest * charWidth + charWidth * 4);

        final heights = _lineHeights(lines, textWidth);

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: gutterWidth,
              child: ClipRect(
                child: ListenableBuilder(
                  listenable: _vertical,
                  builder: (context, _) => Transform.translate(
                    offset: Offset(
                      0,
                      -(_vertical.hasClients ? _vertical.offset : 0.0),
                    ),
                    child: _Gutter(
                      count: lines.length,
                      heights: heights,
                      activeLine: _caretLine,
                      theme: widget.theme,
                      fontSize: widget.fontSize,
                      width: gutterWidth,
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
                  child: TextField(
                    controller: widget.controller,
                    focusNode: widget.focusNode,
                    scrollController: _vertical,
                    readOnly: widget.readOnly,
                    maxLines: null,
                    expands: true,
                    style: _textStyle,
                    cursorColor: widget.theme.cursor,
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
                      contentPadding: EdgeInsets.fromLTRB(6, 8, 6, 8),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The line-number column.
class _Gutter extends StatelessWidget {
  const _Gutter({
    required this.count,
    required this.heights,
    required this.activeLine,
    required this.theme,
    required this.fontSize,
    required this.width,
  });

  final int count;
  final List<double> heights;
  final int activeLine;
  final TerminalTheme theme;
  final double fontSize;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Padding(
      // Matches the field's own vertical content padding, so line 1 sits
      // level with the first line of text rather than one padding above it.
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < count; i++)
            Container(
              height: i < heights.length ? heights[i] : fontSize,
              alignment: Alignment.topRight,
              padding: const EdgeInsets.only(right: 8),
              color: i + 1 == activeLine
                  ? AppTheme.editorCurrentLine(theme)
                  : null,
              child: Text(
                '${i + 1}',
                style: TextStyle(
                  fontFamily: AppTheme.monoFontFamily,
                  fontFamilyFallback: AppTheme.monoFontFamilyFallback,
                  fontSize: fontSize,
                  height: editorLineHeightFactor,
                  color: i + 1 == activeLine
                      ? AppTheme.editorGutterActiveText(theme)
                      : AppTheme.editorGutterText(theme),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
