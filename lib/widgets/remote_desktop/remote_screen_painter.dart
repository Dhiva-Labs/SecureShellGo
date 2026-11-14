import 'package:flutter/material.dart';

import '../../services/remote_desktop/remote_input_view.dart';
import 'frame_compositor.dart';
import 'remote_cursor.dart';

/// A way to ask for a repaint of something whose state is not a
/// `Listenable` of its own: the pan and zoom in a [RemoteViewport].
class RepaintSignal extends ChangeNotifier {
  void signal() => notifyListeners();
}

/// The smallest a remote cursor is drawn, in logical pixels per cursor pixel.
///
/// Fit mode on a phone scales a 1080p screen to a third, and a cursor drawn
/// to scale with it is a speck. Floored here, it stays findable; the hot spot
/// scales with it, so the tip is still where the pointer is.
const double remoteCursorMinScale = 0.7;

/// Draws the remote screen and its cursor into the viewer.
///
/// It repaints on the compositor (a new frame), the cursor and the signal,
/// and reads the screen image only inside [paint]: the compositor disposes
/// each image when the next frame replaces it, so one kept past this call
/// would be a dead handle.
class RemoteScreenPainter extends CustomPainter {
  RemoteScreenPainter({
    required this.compositor,
    required this.viewport,
    required this.cursor,
    required this.background,
    required this.devicePixelRatio,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final FrameCompositor compositor;
  final RemoteViewport viewport;
  final RemoteCursor cursor;

  /// What the letterbox is filled with: the theme's background, so the bars
  /// look like the app rather than like part of the remote screen.
  final Color background;
  final double devicePixelRatio;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = background);
    final image = compositor.value;
    if (image == null || !viewport.isReady) return;

    final rect = viewport.imageRect;
    final scale = viewport.scale;
    // One remote pixel on one device pixel: nearest-neighbour keeps text
    // sharp, and the image sits on the pixel grid so it is not smeared
    // across two. Anything else is resampled, and smoothly.
    final exact = (scale * devicePixelRatio - 1).abs() < 1e-3;
    var left = rect.left;
    var top = rect.top;
    if (exact) {
      left = (left * devicePixelRatio).roundToDouble() / devicePixelRatio;
      top = (top * devicePixelRatio).roundToDouble() / devicePixelRatio;
    }
    final destination = Rect.fromLTWH(left, top, rect.width, rect.height);
    final source = Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.drawImageRect(
      image,
      source,
      destination,
      Paint()
        ..filterQuality = exact ? FilterQuality.none : FilterQuality.medium
        ..isAntiAlias = false,
    );
    canvas.restore();

    _paintCursor(canvas, destination, scale);
  }

  void _paintCursor(Canvas canvas, Rect screen, double scale) {
    final picture = cursor.image;
    if (picture == null || !cursor.hasPosition) return;
    final s = scale < remoteCursorMinScale ? remoteCursorMinScale : scale;
    final tip = Offset(
      screen.left + cursor.x * scale,
      screen.top + cursor.y * scale,
    );
    final at = tip - Offset(cursor.hotX * s, cursor.hotY * s);
    canvas.drawImageRect(
      picture,
      Rect.fromLTWH(0, 0, picture.width.toDouble(), picture.height.toDouble()),
      Rect.fromLTWH(at.dx, at.dy, picture.width * s, picture.height * s),
      Paint()
        ..filterQuality = s == 1 ? FilterQuality.none : FilterQuality.medium
        ..isAntiAlias = false,
    );
  }

  @override
  bool shouldRepaint(RemoteScreenPainter old) =>
      old.compositor != compositor ||
      old.viewport != viewport ||
      old.cursor != cursor ||
      old.background != background ||
      old.devicePixelRatio != devicePixelRatio;
}
