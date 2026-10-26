/// The remote desktop's framebuffer, kept on the GPU.
///
/// Each frame from the agent changes a few tiles of the screen. Rather than
/// keep a CPU copy of the whole screen and upload it every frame, the
/// compositor keeps the current screen as a `ui.Image` and makes the next
/// one by recording a picture of the previous image with only the changed
/// tiles drawn over it, then rasterising that with `toImageSync`. The
/// framebuffer never leaves the GPU, and a frame costs an upload of just its
/// own tiles.
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../../services/remote_desktop/csrd_client.dart';
import '../../services/remote_desktop/csrd_messages.dart';
import '../../services/remote_desktop/csrd_tiles.dart';

/// Completes once the newest framebuffer is on screen.
typedef FramePresentation = Future<void> Function();

/// Turns decoded frames into the current screen image, [value], for a
/// `CustomPainter` to draw, and says when each frame has been shown.
///
/// The usual wiring is [drive], which applies every frame [CsrdClient]
/// decodes and acknowledges it once it has been drawn:
///
/// ```dart
/// final compositor = FrameCompositor();
/// final frames = compositor.drive(client); // before client.connect()
/// // CustomPaint(painter: ScreenPainter(compositor)), repainting on it
/// ...
/// await frames.cancel();
/// compositor.dispose();
/// ```
///
/// Acknowledging on presentation rather than on decode is what makes the
/// agent's two-frame window follow this device's real drawing speed. It
/// also means a backgrounded app, whose frames are not being drawn, stops
/// acknowledging and so pauses the stream, and resumes it when it comes
/// back.
///
/// [value] belongs to the compositor and is disposed when the next frame
/// replaces it: draw it during paint and do not keep it, or keep a
/// `clone()` of it and dispose that.
class FrameCompositor extends ChangeNotifier
    implements ValueListenable<ui.Image?> {
  /// [presentation] decides when a frame counts as shown. The default,
  /// [nextFrameDrawn], waits for the next Flutter frame to be drawn; tests
  /// pass their own.
  FrameCompositor({this.onPresented, FramePresentation? presentation})
    : _presentation = presentation ?? nextFrameDrawn;

  /// Called with each frame's sequence number once it is on screen, in
  /// order. [drive] acknowledges frames itself; this is for anything else
  /// that wants to know, such as a frame-rate readout.
  void Function(int seq)? onPresented;

  final FramePresentation _presentation;

  ui.Image? _image;
  var _width = 0;
  var _height = 0;
  var _generation = 0;
  var _disposed = false;
  Future<void> _chain = Future.value();

  /// The current screen, or null before the first frame.
  @override
  ui.Image? get value => _image;

  int get width => _width;
  int get height => _height;

  /// Goes up whenever the frame size changes, which also clears the screen.
  int get generation => _generation;

  /// Waits for the next Flutter frame to finish drawing, asking for one so
  /// it is not left waiting on something else to repaint.
  ///
  /// While the app is in the background no frames are drawn, so this does
  /// not complete until it is back.
  static Future<void> nextFrameDrawn() {
    final drawn = Completer<void>();
    SchedulerBinding.instance
      ..addPostFrameCallback((_) => drawn.complete())
      ..ensureVisualUpdate();
    return drawn.future;
  }

  /// Applies [frame] on top of the current screen. Frames are applied in
  /// the order this is called, whatever their tiles cost to prepare.
  ///
  /// Completes once the result is on screen (see [onPresented]), or with a
  /// [CsrdCodecException] when a tile cannot be decoded. A JPEG tile that
  /// is not exactly its rect's size counts as undecodable: the agent never
  /// sends one, and the size check happens before any pixels are decoded.
  Future<void> apply(CsrdDecodedFrame frame) {
    final composited = _chain.then((_) => _composite(frame));
    // A failed frame must not stop the ones queued behind it.
    _chain = composited.then<void>((_) {}, onError: (Object _) {});
    return composited.then((shown) async {
      if (!shown) return;
      await _presentation();
      if (_disposed) return;
      onPresented?.call(frame.seq);
    });
  }

  /// Applies every frame [client] decodes, acknowledges each one once it
  /// has been drawn, and closes the session with an error when one cannot
  /// be decoded.
  ///
  /// Subscribe before [CsrdClient.connect], so the first frame is not
  /// missed. Cancel the subscription to stop.
  StreamSubscription<CsrdEvent> drive(CsrdClient client) {
    return client.events.listen((event) {
      if (event is! CsrdFrameEvent) return;
      final seq = event.frame.seq;
      apply(event.frame).then(
        (_) {
          if (!_disposed) client.ackFrame(seq);
        },
        onError: (Object e) {
          unawaited(client.close(error: 'bad frame from the remote side: $e'));
        },
      );
    });
  }

  /// False when the compositor was disposed before the frame landed.
  Future<bool> _composite(CsrdDecodedFrame frame) async {
    if (_disposed) return false;
    final tiles = frame.tiles;
    final images = List<ui.Image?>.filled(tiles.length, null);
    final pending = <Future<void>>[];
    for (var i = 0; i < tiles.length; i++) {
      final Future<ui.Image>? image = switch (tiles[i]) {
        final CsrdPixelTile t => _pixelImage(t),
        final CsrdJpegTile t => _jpegImage(t),
        CsrdFillTile() => null,
      };
      if (image != null) pending.add(image.then((img) => images[i] = img));
    }
    try {
      // Waits for all of them, even after one fails, so that every image
      // that was made is in [images] to be disposed.
      await Future.wait(pending);
    } catch (_) {
      _disposeAll(images);
      rethrow;
    }
    if (_disposed) {
      _disposeAll(images);
      return false;
    }

    if (frame.width != _width || frame.height != _height) {
      _image?.dispose();
      _image = null;
      _width = frame.width;
      _height = frame.height;
      _generation++;
    }

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final copy = ui.Paint()
      ..blendMode = ui.BlendMode.src
      ..filterQuality = ui.FilterQuality.none
      ..isAntiAlias = false;
    final previous = _image;
    var covered = 0;
    for (final t in tiles) {
      covered += t.width * t.height;
    }
    // A full refresh paints every pixel itself; anything less goes over
    // the previous screen, or over black, as `codec.rs` clears to on a size
    // change.
    if (covered < _width * _height) {
      if (previous != null) {
        canvas.drawImage(previous, ui.Offset.zero, copy);
      } else {
        canvas.drawRect(
          ui.Rect.fromLTWH(0, 0, _width.toDouble(), _height.toDouble()),
          ui.Paint()
            ..color = const ui.Color(0xff000000)
            ..blendMode = ui.BlendMode.src,
        );
      }
    }
    for (var i = 0; i < tiles.length; i++) {
      final t = tiles[i];
      if (t is CsrdFillTile) {
        canvas.drawRect(
          ui.Rect.fromLTWH(
            t.x.toDouble(),
            t.y.toDouble(),
            t.width.toDouble(),
            t.height.toDouble(),
          ),
          ui.Paint()
            ..color = ui.Color(t.color)
            ..blendMode = ui.BlendMode.src
            ..isAntiAlias = false,
        );
      } else {
        canvas.drawImage(
          images[i]!,
          ui.Offset(t.x.toDouble(), t.y.toDouble()),
          copy,
        );
      }
    }
    final picture = recorder.endRecording();
    final next = picture.toImageSync(_width, _height);
    // The picture holds its own references to everything drawn into it, so
    // the handles can all go now, before it has been rasterised.
    picture.dispose();
    _disposeAll(images);
    previous?.dispose();
    _image = next;
    notifyListeners();
    return true;
  }

  static Future<ui.Image> _pixelImage(CsrdPixelTile t) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(t.bgra);
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: t.width,
      height: t.height,
      pixelFormat: ui.PixelFormat.bgra8888,
    );
    try {
      final codec = await descriptor.instantiateCodec();
      try {
        return (await codec.getNextFrame()).image;
      } finally {
        codec.dispose();
      }
    } finally {
      descriptor.dispose();
      buffer.dispose();
    }
  }

  static Future<ui.Image> _jpegImage(CsrdJpegTile t) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(t.jpeg);
    ui.ImageDescriptor? descriptor;
    try {
      // Reads the header only. Checking the size here keeps a hostile
      // agent's 60000 × 60000 JPEG from ever being decoded.
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width != t.width || descriptor.height != t.height) {
        throw CsrdCodecException(
          'a ${descriptor.width}x${descriptor.height} jpeg in a '
          '${t.width}x${t.height} rect',
        );
      }
      final codec = await descriptor.instantiateCodec();
      try {
        return (await codec.getNextFrame()).image;
      } finally {
        codec.dispose();
      }
    } on CsrdCodecException {
      rethrow;
    } catch (_) {
      throw CsrdCodecException('corrupt jpeg in a ${t.width}x${t.height} rect');
    } finally {
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  static void _disposeAll(List<ui.Image?> images) {
    for (final image in images) {
      image?.dispose();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _image?.dispose();
    _image = null;
    super.dispose();
  }
}
