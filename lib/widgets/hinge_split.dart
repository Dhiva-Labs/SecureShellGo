import 'dart:ui' show DisplayFeature;

import 'package:flutter/material.dart';

import '../services/display_hinge.dart';

/// Two panes on one screen: [first] left of (or above) [second].
///
/// Where a hinge or a half-open fold runs across this box along [axis], the
/// split is *at* it — each pane gets one side, and nothing is drawn on the
/// hinge itself, which on a dual-screen device is not even screen. Otherwise
/// the panes share the box 3:2, [first] the larger, with a hairline between.
///
/// `MediaQuery.displayFeatures` are in window coordinates and this box sits
/// somewhere under an app bar, so it measures where it landed after each
/// frame that has a hinge to think about, and rebuilds when that moves. The
/// first frame of a new hinge therefore uses the 3:2 split; the next one has
/// it right. A frame is cheaper than every caller having to say where it is.
class HingeSplit extends StatefulWidget {
  const HingeSplit({
    super.key,
    required this.axis,
    required this.first,
    required this.second,
    this.followHinge = true,
  });

  final HingeAxis axis;
  final Widget first;
  final Widget second;

  /// False ignores hinges: for a box that is already one of several panes.
  final bool followHinge;

  @override
  State<HingeSplit> createState() => _HingeSplitState();
}

class _HingeSplitState extends State<HingeSplit> {
  /// Where this box's top-left corner was in the window, last time it was
  /// measured. Null until a hinge has given a reason to look.
  Offset? _origin;
  bool _measureScheduled = false;

  void _measureAfterFrame() {
    if (_measureScheduled) return;
    _measureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureScheduled = false;
      if (!mounted) return;
      final box = context.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) return;
      final origin = box.localToGlobal(Offset.zero);
      if (origin != _origin) setState(() => _origin = origin);
    });
  }

  @override
  Widget build(BuildContext context) {
    final features = widget.followHinge
        ? MediaQuery.displayFeaturesOf(context)
        : const <DisplayFeature>[];
    final hinged = features.any(HingeCut.separates);
    if (hinged) _measureAfterFrame();

    return LayoutBuilder(
      builder: (context, constraints) {
        final origin = _origin;
        final cut = hinged && origin != null
            ? HingeCut.within(features, origin & constraints.biggest)
            : null;
        return _arrange(cut != null && cut.axis == widget.axis ? cut : null);
      },
    );
  }

  Widget _arrange(HingeCut? cut) {
    final sideBySide = widget.axis == HingeAxis.sideBySide;
    final Widget gap;
    final Widget first;
    if (cut == null) {
      first = Expanded(flex: 3, child: widget.first);
      gap = sideBySide
          ? const VerticalDivider(width: 1)
          : const Divider(height: 1);
    } else {
      first = sideBySide
          ? SizedBox(width: cut.start, child: widget.first)
          : SizedBox(height: cut.start, child: widget.first);
      // A fold has no width, so mark it; a hinge between two screens is
      // its own divider.
      gap = cut.extent < 1
          ? (sideBySide
              ? const VerticalDivider(width: 1)
              : const Divider(height: 1))
          : (sideBySide
              ? SizedBox(width: cut.extent)
              : SizedBox(height: cut.extent));
    }
    final second = Expanded(flex: 2, child: widget.second);
    return Flex(
      direction: sideBySide ? Axis.horizontal : Axis.vertical,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [first, gap, second],
    );
  }
}
