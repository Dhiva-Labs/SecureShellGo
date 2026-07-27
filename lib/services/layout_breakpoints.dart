/// Material 3 window size classes, at the thresholds Phase 8 was given:
/// compact below 600dp, medium 600-840, expanded from 840 up — tablets,
/// Samsung DeX windows and unfolded foldables all land in medium/expanded.
///
/// A plain classification function rather than a widget, so the boundary
/// arithmetic is unit-testable without a widget tree; screens call
/// [WindowSizeClass.forWidth] with `MediaQuery.sizeOf(context).width` (or a
/// [LayoutBuilder] constraint) and switch on the result. Free of Flutter
/// imports for the same reason the rest of `services/` is — this is a pure
/// function of a width, nothing more.
enum WindowSizeClass {
  compact,
  medium,
  expanded;

  /// The single-pane phone layout.
  bool get isCompact => this == WindowSizeClass.compact;

  /// Wide enough for a side-by-side layout — medium or expanded.
  bool get isAtLeastMedium => this != WindowSizeClass.compact;

  static const double mediumBreakpoint = 600;
  static const double expandedBreakpoint = 840;

  static WindowSizeClass forWidth(double width) {
    if (width >= expandedBreakpoint) return WindowSizeClass.expanded;
    if (width >= mediumBreakpoint) return WindowSizeClass.medium;
    return WindowSizeClass.compact;
  }
}
