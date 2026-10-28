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

  /// Material 3's compact *height*: below this, a window is a phone on its
  /// side, however wide.
  static const double compactHeightBreakpoint = 480;

  /// Whether two panes fit side by side: wide enough for both, and tall
  /// enough that each is still worth reading. A phone in landscape is wider
  /// than a small tablet, but its 390dp, less an app bar and a soft keyboard,
  /// leaves a terminal of a dozen lines; split in two, neither half is usable.
  ///
  /// The window's height, not what the soft keyboard leaves of it: a layout
  /// that rearranged itself whenever the keyboard came up would move the
  /// field being typed in.
  static bool fitsSideBySide(double width, double height) =>
      forWidth(width).isAtLeastMedium && height >= compactHeightBreakpoint;
}
