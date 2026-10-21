import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../l10n/l10n.dart';

/// The keys a phone keyboard buries that code needs every other line: Tab
/// and outdent, the arrows, brackets and the punctuation programmers type
/// constantly — the editor's answer to the terminal's extra-keys bar.
///
/// Typed characters go through the same auto-close and auto-indent rules as
/// the keyboard (see `CodeEditorFieldState.typeText`), so `(` here closes
/// itself exactly as it does on a hardware keyboard.
class EditorKeyBar extends StatelessWidget {
  const EditorKeyBar({
    super.key,
    required this.theme,
    required this.onIndent,
    required this.onOutdent,
    required this.onType,
    required this.onArrow,
    required this.onUndo,
    required this.onRedo,
  });

  final TerminalTheme theme;
  final VoidCallback onIndent;
  final VoidCallback onOutdent;
  final ValueChanged<String> onType;
  final ValueChanged<AxisDirection> onArrow;
  final VoidCallback onUndo;
  final VoidCallback onRedo;

  static const List<String> symbols = [
    '{', '}', '(', ')', '[', ']', '<', '>', ':', ';', '=', '"', "'",
    '#', '/', r'\', '|', '_', '-', '+', '*', '&', r'$', '`', '~', ',', '.',
  ];

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    Widget key(
      String label, {
      required VoidCallback onTap,
      String? tooltip,
      IconData? icon,
    }) {
      final child = icon != null
          ? Icon(icon, size: 18, color: theme.foreground)
          : Text(
              label,
              style: TextStyle(
                fontSize: 15,
                color: theme.foreground,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            );
      final button = InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        borderRadius: BorderRadius.circular(6),
        child: Container(
          // 48dp each way: this row is for fingers, and a bracket a finger
          // misses types its neighbour. Swiping the row is cheaper than that.
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: child,
        ),
      );
      return tooltip == null ? button : Tooltip(message: tooltip, child: button);
    }

    return Material(
      color: colors.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            children: [
              key('Tab', onTap: onIndent, tooltip: l10n.editorKeyIndent),
              // An icon, not ⇤: phone fonts often lack the glyph.
              key('', icon: Icons.format_indent_decrease,
                  onTap: onOutdent, tooltip: l10n.editorKeyOutdent),
              key('', icon: Icons.keyboard_arrow_left,
                  onTap: () => onArrow(AxisDirection.left),
                  tooltip: l10n.editorKeyLeft),
              key('', icon: Icons.keyboard_arrow_up,
                  onTap: () => onArrow(AxisDirection.up),
                  tooltip: l10n.editorKeyUp),
              key('', icon: Icons.keyboard_arrow_down,
                  onTap: () => onArrow(AxisDirection.down),
                  tooltip: l10n.editorKeyDown),
              key('', icon: Icons.keyboard_arrow_right,
                  onTap: () => onArrow(AxisDirection.right),
                  tooltip: l10n.editorKeyRight),
              const VerticalDivider(width: 12, indent: 10, endIndent: 10),
              for (final symbol in symbols)
                key(symbol, onTap: () => onType(symbol)),
              const VerticalDivider(width: 12, indent: 10, endIndent: 10),
              key('', icon: Icons.undo,
                  onTap: onUndo, tooltip: l10n.editorActionUndo),
              key('', icon: Icons.redo,
                  onTap: onRedo, tooltip: l10n.editorActionRedo),
            ],
          ),
        ),
      ),
    );
  }
}
