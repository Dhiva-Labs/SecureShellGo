import 'package:flutter/material.dart';

import '../models/host.dart';
import '../theme.dart';

/// A small filled circle for a [HostColorLabel] — the leading dot on a
/// saved-host tile (`host_list_screen.dart`) and each option in the edit
/// screen's colour-tag row (`host_edit_screen.dart`), so both places resolve
/// the palette the same way instead of duplicating swatch code.
class HostColorDot extends StatelessWidget {
  const HostColorDot({
    super.key,
    required this.colorLabel,
    this.size = 14,
    this.selected = false,
  });

  /// Null renders as a hollow ring — "no colour tag" as a pickable option in
  /// the edit screen, or (when the caller chooses to show it at all) the
  /// same on a tile.
  final HostColorLabel? colorLabel;

  final double size;

  /// Thicker, theme-coloured ring around the dot — how the edit screen's
  /// picker marks the currently chosen swatch. Unused on a tile's dot.
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final color = AppTheme.hostColorFor(colorLabel?.name);
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        border: Border.all(
          color: selected
              ? onSurface
              : (color ?? onSurface).withValues(alpha: color == null ? 0.4 : 0),
          width: selected ? 2.5 : 1,
        ),
      ),
    );
  }
}
