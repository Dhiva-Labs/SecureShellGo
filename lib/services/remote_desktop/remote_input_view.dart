/// Where the remote screen sits inside the viewer, and the mapping between
/// a point on the viewer and a pixel on the remote.
///
/// This decides what every click means, so it is kept apart from the widget
/// that draws it: the painter and the input handlers both ask the same
/// [RemoteViewport], and the arithmetic is tested without a screen.
///
/// Lengths in the viewer are logical pixels, as everything Flutter hands a
/// pointer handler is; lengths on the remote are the remote's own pixels.
/// The scale between them is [RemoteViewport.scale], logical pixels per
/// remote pixel.
library;

import 'dart:math' as math;

/// What the view starts from when nothing has been zoomed.
enum RemoteViewMode {
  /// The whole remote screen, as large as the viewer allows, letterboxed
  /// in the other direction.
  fit,

  /// One remote pixel for each physical pixel of this device, panned
  /// around. On a phone that is smaller than [fit] but sharper, and usually
  /// what reading small text asks for.
  actual,
}

/// The viewer's window onto the remote screen: how big the remote is
/// drawn, and which part of it shows.
///
/// The state is the remote point at the centre of the viewer and a zoom
/// factor on the mode's base scale, rather than a pixel offset, so that
/// resizing the viewer (a rotation, the soft keyboard opening) keeps the
/// same part of the screen in the middle instead of drifting.
class RemoteViewport {
  RemoteViewport({this.devicePixelRatio = 1});

  /// Physical pixels per logical pixel, which [RemoteViewMode.actual] needs
  /// to put one remote pixel on one physical one. Changes when the window
  /// moves to a screen of another density.
  double devicePixelRatio;

  double _viewWidth = 0;
  double _viewHeight = 0;
  int _remoteWidth = 0;
  int _remoteHeight = 0;
  RemoteViewMode _mode = RemoteViewMode.fit;
  double _zoom = 1;
  double _centreX = 0;
  double _centreY = 0;

  /// The scale 1:1 mode would not go past: a remote pixel taking this many
  /// physical pixels.
  static const double maxPhysicalZoom = 8;

  /// Zoom can only move by this much from a stray gesture before the
  /// result is meaningless.
  static const double _epsilon = 1e-6;

  RemoteViewMode get mode => _mode;
  double get viewWidth => _viewWidth;
  double get viewHeight => _viewHeight;
  int get remoteWidth => _remoteWidth;
  int get remoteHeight => _remoteHeight;

  /// False until both the viewer and the remote have a size, which is
  /// until the first frame has been laid out; no mapping means anything
  /// before.
  bool get isReady =>
      _viewWidth > 0 &&
      _viewHeight > 0 &&
      _remoteWidth > 0 &&
      _remoteHeight > 0;

  /// The scale that shows the whole screen.
  double get fitScale => !isReady
      ? 1
      : math.min(_viewWidth / _remoteWidth, _viewHeight / _remoteHeight);

  double get _baseScale =>
      _mode == RemoteViewMode.fit ? fitScale : 1 / devicePixelRatio;

  double get _minScale =>
      _mode == RemoteViewMode.fit ? fitScale : math.min(fitScale, _baseScale);

  double get _maxScale =>
      math.max(maxPhysicalZoom / devicePixelRatio, fitScale);

  /// Logical pixels per remote pixel.
  double get scale =>
      isReady ? (_baseScale * _zoom).clamp(_minScale, _maxScale).toDouble() : 1;

  /// True when more of the remote is drawn than fits, so the view can pan.
  bool get canPan =>
      isReady &&
      (_remoteWidth * scale > _viewWidth + _epsilon ||
          _remoteHeight * scale > _viewHeight + _epsilon);

  /// The remote screen's rectangle in viewer coordinates. Parts of it can
  /// be outside the viewer when zoomed in.
  ({double left, double top, double width, double height}) get imageRect {
    final s = scale;
    return (
      left: _viewWidth / 2 - _centreX * s,
      top: _viewHeight / 2 - _centreY * s,
      width: _remoteWidth * s,
      height: _remoteHeight * s,
    );
  }

  /// The viewer was laid out at this size.
  void resize(double width, double height) {
    if (width == _viewWidth && height == _viewHeight) return;
    _viewWidth = width;
    _viewHeight = height;
    _clampCentre();
  }

  /// The remote's frames are now this size: a first frame, or another
  /// display. The view starts again, since a position on the old screen
  /// means nothing on the new one.
  void setRemoteSize(int width, int height) {
    if (width == _remoteWidth && height == _remoteHeight) return;
    _remoteWidth = width;
    _remoteHeight = height;
    _zoom = 1;
    _centreX = width / 2;
    _centreY = height / 2;
    _clampCentre();
  }

  /// Switches between [RemoteViewMode.fit] and [RemoteViewMode.actual],
  /// undoing any zoom. [focusX]/[focusY] is a remote point to put in the
  /// middle when going to actual size, so the part you were looking at
  /// stays in view; without it the middle of the screen is used.
  void setMode(RemoteViewMode mode, {double? focusX, double? focusY}) {
    _mode = mode;
    _zoom = 1;
    if (mode == RemoteViewMode.actual && focusX != null && focusY != null) {
      _centreX = focusX;
      _centreY = focusY;
    } else {
      _centreX = _remoteWidth / 2;
      _centreY = _remoteHeight / 2;
    }
    _clampCentre();
  }

  /// Zooms by [factor] keeping the remote point under ([fx], [fy]), in
  /// viewer coordinates, where it is. The result stays between what fits
  /// and [maxPhysicalZoom] physical pixels per remote pixel.
  void zoomAt(double factor, double fx, double fy) {
    if (!isReady || factor <= 0 || !factor.isFinite) return;
    final (px, py) = remoteExactFromView(fx, fy);
    final target = (scale * factor).clamp(_minScale, _maxScale).toDouble();
    _zoom = target / _baseScale;
    _centreX = px - (fx - _viewWidth / 2) / target;
    _centreY = py - (fy - _viewHeight / 2) / target;
    _clampCentre();
  }

  /// Moves the image by ([dx], [dy]) viewer pixels, as a finger dragging
  /// it would.
  void panBy(double dx, double dy) {
    if (!isReady) return;
    final s = scale;
    _centreX -= dx / s;
    _centreY -= dy / s;
    _clampCentre();
  }

  /// Pans just far enough that remote point ([rx], [ry]) is inside the
  /// viewer with [margin] to spare, for a cursor moved with a finger off
  /// the edge of what is showing.
  void ensureVisible(double rx, double ry, {double margin = 24}) {
    if (!isReady) return;
    final (vx, vy) = viewFromRemote(rx, ry);
    final m = math.min(margin, math.min(_viewWidth, _viewHeight) / 2);
    var dx = 0.0;
    var dy = 0.0;
    if (vx < m) dx = m - vx;
    if (vx > _viewWidth - m) dx = _viewWidth - m - vx;
    if (vy < m) dy = m - vy;
    if (vy > _viewHeight - m) dy = _viewHeight - m - vy;
    if (dx != 0 || dy != 0) panBy(dx, dy);
  }

  /// The remote pixel under viewer point ([x], [y]), or null when the
  /// point is outside the remote screen, in the letterbox or past the
  /// zoomed edge.
  ///
  /// With [clamp] a point outside is moved to the nearest pixel instead.
  /// That is what a drag wants once it has left the image: the button is
  /// held, so the pointer should keep following to the edge.
  (int, int)? remoteFromView(double x, double y, {bool clamp = false}) {
    if (!isReady) return null;
    final (u, v) = remoteExactFromView(x, y);
    final inside = u >= 0 && v >= 0 && u < _remoteWidth && v < _remoteHeight;
    if (!inside && !clamp) return null;
    return (
      u.floor().clamp(0, _remoteWidth - 1),
      v.floor().clamp(0, _remoteHeight - 1),
    );
  }

  /// The same, as a fractional remote position, not limited to the screen.
  (double, double) remoteExactFromView(double x, double y) {
    final r = imageRect;
    final s = scale;
    return ((x - r.left) / s, (y - r.top) / s);
  }

  /// Where remote point ([rx], [ry]) is in viewer coordinates.
  (double, double) viewFromRemote(double rx, double ry) {
    final r = imageRect;
    final s = scale;
    return (r.left + rx * s, r.top + ry * s);
  }

  /// Keeps the image from being dragged off the viewer: an axis that fits is
  /// centred, one that does not has its edges held to the viewer's.
  void _clampCentre() {
    if (!isReady) return;
    final s = scale;
    _centreX = _clampAxis(_centreX, _remoteWidth, _viewWidth, s);
    _centreY = _clampAxis(_centreY, _remoteHeight, _viewHeight, s);
  }

  static double _clampAxis(double centre, int remote, double view, double s) {
    if (remote * s <= view + _epsilon) return remote / 2;
    final half = view / 2 / s;
    return centre.clamp(half, remote - half).toDouble();
  }
}
