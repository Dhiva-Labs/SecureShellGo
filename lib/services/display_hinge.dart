import 'dart:ui';

/// Which way a hinge splits the window.
enum HingeAxis {
  /// A vertical hinge or fold: one pane each side of it — a book-posture
  /// foldable, or a dual-screen device spanned across both screens.
  sideBySide,

  /// A horizontal fold, half open: one pane above it, one below — a foldable
  /// stood on a table like a laptop.
  stacked,
}

/// Where a separating hinge or fold crosses a box, in that box's coordinates.
///
/// Pure arithmetic over [DisplayFeature]s, which `MediaQuery` reports in
/// window coordinates; the widget that uses it (`widgets/hinge_split.dart`)
/// supplies the box's place in the window.
class HingeCut {
  const HingeCut({required this.axis, required this.start, required this.end});

  final HingeAxis axis;

  /// Where the hinge begins and ends across the split: x for
  /// [HingeAxis.sideBySide], y for [HingeAxis.stacked]. Equal for a fold,
  /// which has no width; a hinge between two screens does, and nothing is
  /// drawn there.
  final double start;
  final double end;

  double get extent => end - start;

  /// A pane narrower or shorter than this beside a hinge is not worth having;
  /// a hinge that close to the edge is left to the ordinary layout.
  static const double minPane = 160;

  /// Whether [feature] divides the screen into two: a hinge always does; a
  /// fold only while half open. A flat fold is one screen, and content may
  /// cross it — the same rule Android's `FoldingFeature.isSeparating` uses.
  static bool separates(DisplayFeature feature) => switch (feature.type) {
        DisplayFeatureType.hinge => true,
        DisplayFeatureType.fold =>
          feature.state == DisplayFeatureState.postureHalfOpened,
        DisplayFeatureType.cutout || DisplayFeatureType.unknown => false,
      };

  /// The first separating feature that runs right across [box] (in window
  /// coordinates) with room for a pane on each side, as a cut in the box's
  /// own coordinates — or null when there is none.
  static HingeCut? within(List<DisplayFeature> features, Rect box) {
    for (final feature in features) {
      if (!separates(feature)) continue;
      final bounds = feature.bounds;
      // A fold is a line: zero wide when vertical, zero tall when not.
      final vertical = bounds.height > bounds.width;
      if (vertical) {
        if (bounds.top > box.top || bounds.bottom < box.bottom) continue;
        final start = bounds.left - box.left;
        final end = bounds.right - box.left;
        if (start < minPane || box.width - end < minPane) continue;
        return HingeCut(axis: HingeAxis.sideBySide, start: start, end: end);
      } else {
        if (bounds.left > box.left || bounds.right < box.right) continue;
        final start = bounds.top - box.top;
        final end = bounds.bottom - box.top;
        if (start < minPane || box.height - end < minPane) continue;
        return HingeCut(axis: HingeAxis.stacked, start: start, end: end);
      }
    }
    return null;
  }

  /// How the window as a whole is split, before anything inside it has been
  /// laid out: the axis of the first separating feature, or null.
  static HingeAxis? axisOf(List<DisplayFeature> features, Size window) =>
      within(features, Offset.zero & window)?.axis;

  @override
  bool operator ==(Object other) =>
      other is HingeCut &&
      other.axis == axis &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(axis, start, end);

  @override
  String toString() => 'HingeCut(${axis.name}, $start..$end)';
}
