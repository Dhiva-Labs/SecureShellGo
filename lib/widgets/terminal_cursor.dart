import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../models/app_settings.dart';

/// The terminal's cursor, drawn over the terminal instead of by it.
///
/// xterm 4.0.0 cannot be trusted with the cursor. Its painter leaves the row
/// out when it draws the underline and bar shapes, so both land on the top
/// line of the view instead of the line being typed on; its block is an
/// opaque rectangle that hides the character under it; and it has no
/// blinking. So the pane hands xterm a theme whose cursor is transparent
/// ([withoutCursor]) and this draws the real one, at the rectangle xterm
/// reports for it: a block with the character under it in reverse, an
/// underline, or a bar — hollow while the terminal does not have the
/// keyboard, as xterm's was — and, if asked, blinking while it does.
class TerminalCursorOverlay extends StatefulWidget {
  const TerminalCursorOverlay({
    super.key,
    required this.terminal,
    required this.viewKey,
    required this.focusNode,
    required this.scrollController,
    required this.shape,
    required this.blink,
    required this.theme,
    required this.textStyle,
  });

  final Terminal terminal;

  /// The [TerminalView] the cursor belongs to, for where its cursor is.
  final GlobalKey<TerminalViewState> viewKey;
  final FocusNode focusNode;
  final ScrollController scrollController;
  final TerminalCursorStyle shape;
  final bool blink;

  /// The real theme, cursor colour included.
  final TerminalTheme theme;
  final TerminalStyle textStyle;

  /// How long the cursor stays on, and off, while blinking — the rate
  /// Flutter's own text fields blink at.
  static const Duration blinkHalfPeriod = Duration(milliseconds: 500);

  /// [theme] with its cursor taken out, for the [TerminalView] under this.
  ///
  /// The same object every time for the same [theme]: xterm compares themes
  /// by identity, and a new one throws away every glyph it has laid out.
  static TerminalTheme withoutCursor(TerminalTheme theme) =>
      _cursorless[theme] ??= TerminalTheme(
        cursor: const Color(0x00000000),
        selection: theme.selection,
        foreground: theme.foreground,
        background: theme.background,
        black: theme.black,
        red: theme.red,
        green: theme.green,
        yellow: theme.yellow,
        blue: theme.blue,
        magenta: theme.magenta,
        cyan: theme.cyan,
        white: theme.white,
        brightBlack: theme.brightBlack,
        brightRed: theme.brightRed,
        brightGreen: theme.brightGreen,
        brightYellow: theme.brightYellow,
        brightBlue: theme.brightBlue,
        brightMagenta: theme.brightMagenta,
        brightCyan: theme.brightCyan,
        brightWhite: theme.brightWhite,
        searchHitBackground: theme.searchHitBackground,
        searchHitBackgroundCurrent: theme.searchHitBackgroundCurrent,
        searchHitForeground: theme.searchHitForeground,
      );

  static final Expando<TerminalTheme> _cursorless = Expando();

  @override
  State<TerminalCursorOverlay> createState() => TerminalCursorOverlayState();
}

@visibleForTesting
class TerminalCursorOverlayState extends State<TerminalCursorOverlay> {
  final GlobalKey _paintKey = GlobalKey();
  final _repaint = _Repaint();
  Timer? _blinkTimer;

  /// In the "on" half of a blink. Always true when not blinking.
  bool get blinkOn => _blinkOn;
  bool _blinkOn = true;

  /// Whether a blink timer is running — only while blinking is on and the
  /// terminal has the keyboard, so a session in a background tab costs
  /// nothing.
  @visibleForTesting
  bool get blinking => _blinkTimer != null;

  @override
  void initState() {
    super.initState();
    widget.terminal.addListener(_handleTerminalChange);
    widget.focusNode.addListener(_handleFocusChange);
    widget.scrollController.addListener(_repaint.notify);
    _syncBlink();
  }

  @override
  void didUpdateWidget(TerminalCursorOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.terminal != widget.terminal) {
      oldWidget.terminal.removeListener(_handleTerminalChange);
      widget.terminal.addListener(_handleTerminalChange);
    }
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_handleFocusChange);
      widget.focusNode.addListener(_handleFocusChange);
    }
    if (oldWidget.scrollController != widget.scrollController) {
      oldWidget.scrollController.removeListener(_repaint.notify);
      widget.scrollController.addListener(_repaint.notify);
    }
    _syncBlink();
  }

  @override
  void dispose() {
    widget.terminal.removeListener(_handleTerminalChange);
    widget.focusNode.removeListener(_handleFocusChange);
    widget.scrollController.removeListener(_repaint.notify);
    _blinkTimer?.cancel();
    _repaint.dispose();
    super.dispose();
  }

  /// Output, or a keystroke echoed back: the cursor has probably moved, and
  /// a cursor that moves is shown, not caught in the off half of a blink.
  void _handleTerminalChange() {
    if (_blinkTimer != null) _restartBlink();
    _repaint.notify();
  }

  void _handleFocusChange() {
    _syncBlink();
    _repaint.notify();
  }

  void _syncBlink() {
    final wanted = widget.blink && widget.focusNode.hasFocus;
    if (wanted && _blinkTimer == null) {
      _restartBlink();
    } else if (!wanted && _blinkTimer != null) {
      _blinkTimer!.cancel();
      _blinkTimer = null;
      _blinkOn = true;
    }
  }

  void _restartBlink() {
    _blinkTimer?.cancel();
    _blinkOn = true;
    _blinkTimer = Timer.periodic(TerminalCursorOverlay.blinkHalfPeriod, (_) {
      _blinkOn = !_blinkOn;
      _repaint.notify();
    });
  }

  /// Where the cursor is drawn, in this overlay's coordinates.
  @visibleForTesting
  Rect? get cursorRect => _cursorRect();

  /// The cursor's cell in this overlay's coordinates, or null before the
  /// terminal has been laid out.
  Rect? _cursorRect() {
    final view = widget.viewKey.currentState;
    final box = _paintKey.currentContext?.findRenderObject() as RenderBox?;
    if (view == null || !view.mounted || box == null || !box.attached) {
      return null;
    }
    try {
      final global = view.globalCursorRect;
      return box.globalToLocal(global.topLeft) & global.size;
    } catch (_) {
      // Not laid out yet: no viewport to measure against.
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          key: _paintKey,
          size: Size.infinite,
          painter: _CursorPainter(
            repaint: _repaint,
            state: this,
            textScaler: MediaQuery.textScalerOf(context),
          ),
        ),
      ),
    );
  }
}

class _Repaint extends ChangeNotifier {
  void notify() => notifyListeners();
}

class _CursorPainter extends CustomPainter {
  _CursorPainter({
    required _Repaint repaint,
    required this.state,
    required this.textScaler,
  }) : super(repaint: repaint);

  final TerminalCursorOverlayState state;
  final TextScaler textScaler;

  @override
  void paint(Canvas canvas, Size size) {
    final widget = state.widget;
    final terminal = widget.terminal;
    if (!terminal.cursorVisibleMode) return;
    final focused = widget.focusNode.hasFocus;
    if (focused && !state._blinkOn) return;
    final rect = state._cursorRect();
    if (rect == null) return;

    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final paint = Paint()..color = widget.theme.cursor;

    if (!focused) {
      paint
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1;
      canvas.drawRect(rect.deflate(0.5), paint);
      canvas.restore();
      return;
    }

    switch (widget.shape) {
      case TerminalCursorStyle.block:
        canvas.drawRect(rect, paint);
        _paintCharacterUnder(canvas, rect);
      case TerminalCursorStyle.underline:
        final thickness = (rect.height / 10).clamp(1.0, 3.0);
        canvas.drawRect(
          Rect.fromLTWH(
            rect.left,
            rect.bottom - thickness,
            rect.width,
            thickness,
          ),
          paint,
        );
      case TerminalCursorStyle.bar:
        final thickness = (rect.width / 6).clamp(1.0, 2.5);
        canvas.drawRect(
          Rect.fromLTWH(rect.left, rect.top, thickness, rect.height),
          paint,
        );
    }
    canvas.restore();
  }

  /// The character under a block cursor, in the background colour, laid out
  /// exactly as xterm lays out each of its own cells so it sits where the
  /// original did.
  void _paintCharacterUnder(Canvas canvas, Rect rect) {
    final widget = state.widget;
    final buffer = widget.terminal.buffer;
    final row = buffer.absoluteCursorY;
    if (row < 0 || row >= buffer.height) return;
    final line = buffer.lines[row];
    final x = buffer.cursorX;
    if (x >= line.length) return;
    final codePoint = line.getCodePoint(x);
    if (codePoint == 0 || codePoint == 0x20) return;

    final style = widget.textStyle.toTextStyle(
      color: widget.theme.background,
    );
    final builder = ui.ParagraphBuilder(style.getParagraphStyle())
      ..pushStyle(style.getTextStyle(textScaler: textScaler))
      ..addText(String.fromCharCode(codePoint));
    final paragraph = builder.build()
      ..layout(const ui.ParagraphConstraints(width: double.infinity));
    canvas.drawParagraph(paragraph, rect.topLeft);
    paragraph.dispose();
  }

  @override
  bool shouldRepaint(_CursorPainter oldDelegate) => true;
}
