/// Decoding a [CsrdFrame]'s rects into tiles ready for the GPU: the Dart
/// half of `codec.rs`'s `Decoder`, minus the framebuffer, which lives on the
/// GPU (see `widgets/remote_desktop/frame_compositor.dart`).
///
/// Fill, Raw and Deflate rects are decoded here, in pure Dart. JPEG rects
/// are only checked and passed on: decoding them needs `dart:ui`'s codecs,
/// which run on the engine's own threads anyway.
///
/// Pixels come out as BGRA with alpha forced to 0xFF, which is
/// `ui.PixelFormat.bgra8888` and can be uploaded as it is. The wire's fourth
/// byte is whatever the capture API left there (junk, often zero), so it
/// cannot be passed through as alpha.
library;

import 'dart:io' show RawZLibFilter;
import 'dart:isolate';
import 'dart:typed_data';

import 'csrd_messages.dart';

/// Largest frame area accepted, in pixels: 8192 × 8192, or 256 MiB of BGRA.
///
/// `MAX_DIMENSION` alone would allow 16384 × 16384, a 1 GiB framebuffer,
/// which a hostile agent could make a phone allocate with a frame holding a
/// single one-pixel fill. The largest real displays (8K, 7680 × 4320) are
/// well inside this.
const int csrdMaxFramePixels = 8192 * 8192;

/// Frames needing at most this many bytes of Raw and Deflate output are
/// decoded on the calling isolate; bigger ones on a short-lived isolate.
///
/// Measured (`test/remote_desktop/csrd_decode_benchmark_test.dart`): a
/// 1080p full refresh of text-like tiles takes 8–13 ms to inflate on a fast
/// desktop, so several frames' worth of budget on a phone, while
/// `Isolate.run` keeps the calling isolate's stall to about a millisecond.
/// 256 KiB is sixteen 64 × 64 tiles, a fraction of a millisecond, and covers
/// typing, blinking cursors and most pointer-driven redraws, which then skip
/// the isolate's few milliseconds of latency.
const int csrdInlineDecodeBytes = 256 << 10;

/// One decoded rectangle of a frame, in frame pixels.
sealed class CsrdTile {
  const CsrdTile(this.x, this.y, this.width, this.height);
  final int x;
  final int y;
  final int width;
  final int height;
}

/// A rectangle of one colour.
final class CsrdFillTile extends CsrdTile {
  const CsrdFillTile(super.x, super.y, super.width, super.height, this.color);

  /// 0xAARRGGBB with alpha 0xFF: what `ui.Color` takes.
  final int color;
}

/// A rectangle of pixels from a Raw or Deflate rect.
final class CsrdPixelTile extends CsrdTile {
  const CsrdPixelTile(super.x, super.y, super.width, super.height, this.bgra);

  /// `width * height * 4` bytes, rows packed tightly, BGRA with alpha 0xFF:
  /// `ui.PixelFormat.bgra8888`.
  final Uint8List bgra;
}

/// A JPEG rect, still encoded: the compositor decodes it, and checks that
/// it decodes to exactly [width] × [height].
final class CsrdJpegTile extends CsrdTile {
  const CsrdJpegTile(super.x, super.y, super.width, super.height, this.jpeg);
  final Uint8List jpeg;
}

/// A rectangle copied from elsewhere on the screen: RFB's CopyRect, which
/// VNC servers send for scrolling and dragged windows. The CSRD agent never
/// sends one.
///
/// The source is the screen as it was before this frame, never what an
/// earlier tile of the same frame drew. A producer whose protocol reads
/// sequentially, as RFB does, splits its update into consecutive frames
/// wherever a copy's source was drawn by an earlier rect, and it checks
/// both rects against the frame, since the compositor does not.
final class CsrdCopyTile extends CsrdTile {
  const CsrdCopyTile(
    super.x,
    super.y,
    super.width,
    super.height, {
    required this.srcX,
    required this.srcY,
  });

  /// Top-left of the source rect, which has this tile's size.
  final int srcX;
  final int srcY;
}

/// A frame whose rects have been checked and decoded.
class CsrdDecodedFrame {
  const CsrdDecodedFrame({
    required this.seq,
    required this.width,
    required this.height,
    required this.tiles,
    required this.wireBytes,
  });

  /// What [CsrdFrameAck] is to name once this frame is on screen.
  final int seq;
  final int width;
  final int height;

  /// In wire order. The agent never sends overlapping rects, but if one
  /// did, later tiles win, as in `codec.rs`.
  final List<CsrdTile> tiles;

  /// Compressed bytes the frame carried, for a bandwidth readout.
  final int wireBytes;
}

/// Turns [CsrdFrame]s into [CsrdDecodedFrame]s.
abstract final class CsrdTileDecoder {
  /// Checks a frame as `Decoder::apply` does, and then some: its size, every
  /// rect inside it, and the rects' total area.
  ///
  /// The area check is not in `codec.rs`. Its encoder never overlaps rects,
  /// so their areas never add up to more than the frame's; without the
  /// check, a 64 MiB frame of overlapping full-frame Deflate rects (zlib
  /// manages about 1000:1 on flat input) would ask for tens of gigabytes of
  /// output, each rect within its own bounds.
  static void validate(CsrdFrame frame) {
    final w = frame.width;
    final h = frame.height;
    if (w == 0 || h == 0 || w > csrdMaxDimension || h > csrdMaxDimension) {
      throw CsrdCodecException('bad frame size ${w}x$h');
    }
    if (w * h > csrdMaxFramePixels) {
      throw CsrdCodecException(
        'frame of ${w}x$h is larger than this viewer '
        'accepts',
      );
    }
    var area = 0;
    for (final r in frame.rects) {
      if (r.width == 0 ||
          r.height == 0 ||
          r.x + r.width > w ||
          r.y + r.height > h) {
        throw CsrdCodecException(
          'rect ${r.width}x${r.height}+${r.x}+${r.y} outside ${w}x$h',
        );
      }
      area += r.width * r.height;
    }
    if (area > w * h) {
      throw const CsrdCodecException('rects cover more than the frame');
    }
  }

  /// Bytes of pixels the frame's Raw and Deflate rects decode to: the work
  /// that decides where it is decoded.
  static int pixelBytes(CsrdFrame frame) {
    var n = 0;
    for (final r in frame.rects) {
      if (r.encoding == CsrdEncoding.raw ||
          r.encoding == CsrdEncoding.deflate) {
        n += r.width * r.height * 4;
      }
    }
    return n;
  }

  /// Validates and decodes [frame] on this isolate.
  static CsrdDecodedFrame decodeSync(CsrdFrame frame) {
    validate(frame);
    return CsrdDecodedFrame(
      seq: frame.seq,
      width: frame.width,
      height: frame.height,
      tiles: _decodeAll(frame.rects),
      wireBytes: frame.dataBytes,
    );
  }

  /// Validates and decodes [frame], on a short-lived isolate when its Raw
  /// and Deflate output is over [inlineLimit] bytes (see
  /// [csrdInlineDecodeBytes]), else right here.
  ///
  /// Only the pixel rects travel to the isolate. Their decoded pixels come
  /// back through `Isolate.exit`, which hands the buffer over without
  /// copying it.
  static Future<CsrdDecodedFrame> decode(
    CsrdFrame frame, {
    int inlineLimit = csrdInlineDecodeBytes,
  }) async {
    validate(frame);
    if (pixelBytes(frame) <= inlineLimit) return decodeSync(frame);

    final heavy = <int>[];
    final light = <CsrdRect>[];
    for (var i = 0; i < frame.rects.length; i++) {
      final r = frame.rects[i];
      if (_isPixels(r)) {
        heavy.add(i);
      } else {
        light.add(r);
      }
    }
    final pixels = await _decodeElsewhere([
      for (final i in heavy) frame.rects[i],
    ]);
    final others = _decodeAll(light);
    final tiles = <CsrdTile>[];
    var p = 0, o = 0;
    for (var i = 0; i < frame.rects.length; i++) {
      tiles.add(p < heavy.length && heavy[p] == i ? pixels[p++] : others[o++]);
    }
    return CsrdDecodedFrame(
      seq: frame.seq,
      width: frame.width,
      height: frame.height,
      tiles: tiles,
      wireBytes: frame.dataBytes,
    );
  }

  /// Not inlined into [decode] on purpose: a closure made inside an async
  /// function shares that function's context, and would carry the whole
  /// frame, JPEGs and all, to the other isolate. Here it can only capture
  /// [rects].
  static Future<List<CsrdTile>> _decodeElsewhere(List<CsrdRect> rects) =>
      Isolate.run(() => _decodeAll(rects), debugName: 'csrd-inflate');

  static bool _isPixels(CsrdRect r) =>
      r.encoding == CsrdEncoding.raw || r.encoding == CsrdEncoding.deflate;

  /// Every pixel tile of a frame shares one buffer, each a view into its
  /// own stretch of it: one allocation per frame instead of one per tile.
  /// On the worker isolate that is more than tidiness, because isolates
  /// from `Isolate.run` share the calling isolate's heap, and the worker's
  /// garbage collections stop the UI isolate too. Measured on a 1080p
  /// refresh, the worst stall fell from 8.6 ms to 2.0 ms.
  static List<CsrdTile> _decodeAll(List<CsrdRect> rects) {
    var total = 0;
    for (final r in rects) {
      if (_isPixels(r)) total += r.width * r.height * 4;
    }
    final pixels = Uint8List(total);
    var at = 0;
    final tiles = <CsrdTile>[];
    for (final r in rects) {
      tiles.add(_decodeRect(r, pixels, at));
      if (_isPixels(r)) at += r.width * r.height * 4;
    }
    return tiles;
  }

  /// Decodes [r]; a pixel rect into `pixels[at ..]`.
  static CsrdTile _decodeRect(CsrdRect r, Uint8List pixels, int at) {
    final n = r.width * r.height * 4;
    CsrdCodecException bad(String what) =>
        CsrdCodecException('$what in ${r.encoding.name} rect');
    switch (r.encoding) {
      case CsrdEncoding.fill:
        if (r.data.length != 4) throw bad('fill colour is not 4 bytes');
        final d = r.data;
        return CsrdFillTile(
          r.x,
          r.y,
          r.width,
          r.height,
          0xff000000 | d[2] << 16 | d[1] << 8 | d[0],
        );
      case CsrdEncoding.raw:
        if (r.data.length != n) throw bad('wrong data length');
        // Copied, so the message the rect came in is left as it was.
        final px = Uint8List.sublistView(pixels, at, at + n)
          ..setRange(0, n, r.data);
        _forceOpaque(px);
        return CsrdPixelTile(r.x, r.y, r.width, r.height, px);
      case CsrdEncoding.deflate:
        final px = Uint8List.sublistView(pixels, at, at + n);
        _inflate(r.data, px, bad);
        _forceOpaque(px);
        return CsrdPixelTile(r.x, r.y, r.width, r.height, px);
      case CsrdEncoding.jpeg:
        // SOI. Anything else would reach a general-purpose image codec
        // happy to decode PNG or GIF too.
        if (r.data.length < 2 || r.data[0] != 0xff || r.data[1] != 0xd8) {
          throw bad('not a jpeg');
        }
        return CsrdJpegTile(r.x, r.y, r.width, r.height, r.data);
      case CsrdEncoding.zstd:
        // The handshake refuses an agent that did not accept CAP_DEFLATE,
        // so this is an agent breaking its word.
        throw const CsrdCodecException(
          'the remote side sent a zstd tile after agreeing to deflate',
        );
    }
  }

  /// Inflates a zlib stream into [out], which it must fill exactly.
  ///
  /// `RawZLibFilter` hands output over in 64 KiB pieces, so a stream that
  /// would inflate past its rect is stopped within one piece of the limit,
  /// however much it would have gone on to produce. It does not complain
  /// about a stream cut short, or followed by junk, so the exact length is
  /// what catches a truncated one.
  static void _inflate(
    Uint8List data,
    Uint8List out,
    CsrdCodecException Function(String) bad,
  ) {
    final expected = out.length;
    var filled = 0;
    try {
      final filter = RawZLibFilter.inflateFilter();
      filter.process(data, 0, data.length);
      while (true) {
        final piece = filter.processed(flush: false, end: true);
        if (piece == null) break;
        if (piece.length > expected - filled) {
          throw bad('data inflating past the rect');
        }
        out.setRange(filled, filled + piece.length, piece);
        filled += piece.length;
      }
    } on FormatException {
      throw bad('corrupt deflate data');
    }
    if (filled != expected) throw bad('short deflate data');
  }

  /// BGRX → BGRA, alpha 0xFF, in place.
  ///
  /// A plain byte store. OR-ing whole words is four times faster in a debug
  /// (JIT) build, but a third slower compiled ahead of time, which is what
  /// a release runs: 1.2 ms against 1.8 ms for a 1080p frame.
  static void _forceOpaque(Uint8List px) {
    for (var i = 3; i < px.length; i += 4) {
      px[i] = 0xff;
    }
  }
}
