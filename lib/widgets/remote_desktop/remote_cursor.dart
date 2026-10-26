import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../../services/remote_desktop/csrd_messages.dart';

/// The largest cursor image taken, each way. Real cursors are 24 to 64
/// pixels, the biggest accessibility ones a few hundred; the wire allows
/// 65535, which is not a cursor.
const int remoteCursorMaxSize = 512;

/// The remote pointer: its picture and where it is.
///
/// Where it is comes from two places that must not fight. The agent says
/// where the pointer is after every move, but that arrives a round trip late,
/// so while the person is moving the pointer themselves the position is the
/// local one, which is what they are looking for: the cursor under a finger
/// or mouse with no lag. Once they stop, the agent's word is taken again,
/// which also covers the remote moving the pointer by itself.
class RemoteCursor extends ChangeNotifier {
  ui.Image? _image;
  int _hotX = 0;
  int _hotY = 0;
  double _x = 0;
  double _y = 0;
  var _hasPosition = false;
  var _local = false;
  var _generation = 0;
  var _disposed = false;

  /// The cursor's picture, or null when it is hidden or not yet known. It
  /// belongs to this object and is disposed when replaced: draw it, do not
  /// keep it.
  ui.Image? get image => _image;

  /// The hot spot, within the picture: the pixel that is the pointer's
  /// position.
  int get hotX => _hotX;
  int get hotY => _hotY;

  /// The pointer's position in remote pixels; fractional while it is being
  /// moved locally.
  double get x => _x;
  double get y => _y;

  /// False until something has said where the pointer is.
  bool get hasPosition => _hasPosition;

  /// True while the position is being driven from this device.
  bool get isLocal => _local;

  /// Takes a new picture, or hides the cursor when [shape] is empty.
  ///
  /// Decoding is asynchronous, so a shape that was replaced before its
  /// picture was ready is dropped when it arrives.
  void setShape(CsrdCursorShape shape) {
    final generation = ++_generation;
    final w = shape.width;
    final h = shape.height;
    if (shape.hidden ||
        w > remoteCursorMaxSize ||
        h > remoteCursorMaxSize ||
        shape.rgba.length < w * h * 4) {
      _replaceImage(null, 0, 0);
      return;
    }
    // Clamped, since the protocol does not check it: a hot spot outside the
    // picture would draw the cursor somewhere it is not.
    final hotX = shape.hotX.clamp(0, w - 1);
    final hotY = shape.hotY.clamp(0, h - 1);
    ui.decodeImageFromPixels(
      premultiplyRgba(shape.rgba, w * h),
      w,
      h,
      ui.PixelFormat.rgba8888,
      (image) {
        if (_disposed || generation != _generation) {
          image.dispose();
          return;
        }
        _replaceImage(image, hotX, hotY);
      },
    );
  }

  /// The agent says the pointer is at ([x], [y]). Ignored while the person is
  /// moving it themselves.
  void setEchoed(num x, num y) {
    if (_local) return;
    _set(x.toDouble(), y.toDouble());
  }

  /// The person moved the pointer to ([x], [y]) from this device.
  void setLocal(double x, double y) {
    _local = true;
    _set(x, y);
  }

  /// The person stopped moving the pointer: the agent's position counts
  /// again.
  void releaseLocal() => _local = false;

  /// Forgets the position, after a display switch.
  void clearPosition() {
    _hasPosition = false;
    _local = false;
    notifyListeners();
  }

  void _set(double x, double y) {
    if (_hasPosition && x == _x && y == _y) return;
    _x = x;
    _y = y;
    _hasPosition = true;
    notifyListeners();
  }

  void _replaceImage(ui.Image? image, int hotX, int hotY) {
    _image?.dispose();
    _image = image;
    _hotX = hotX;
    _hotY = hotY;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _image?.dispose();
    _image = null;
    super.dispose();
  }
}

/// Straight RGBA, as the wire carries a cursor, as premultiplied RGBA, as
/// the engine expects pixels it is given.
///
/// Uploading straight alpha as it is would draw the soft edge of every
/// cursor shadow as a bright halo. [pixels] is the number of pixels to
/// convert, so a buffer longer than needed is not read past.
Uint8List premultiplyRgba(Uint8List straight, int pixels) {
  final out = Uint8List(pixels * 4);
  for (var i = 0; i < pixels * 4; i += 4) {
    final a = straight[i + 3];
    out[i] = (straight[i] * a + 127) ~/ 255;
    out[i + 1] = (straight[i + 1] * a + 127) ~/ 255;
    out[i + 2] = (straight[i + 2] * a + 127) ~/ 255;
    out[i + 3] = a;
  }
  return out;
}
