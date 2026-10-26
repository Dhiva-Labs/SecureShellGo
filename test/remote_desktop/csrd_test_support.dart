import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:secure_shell_go/services/remote_desktop/csrd_messages.dart';
import 'package:secure_shell_go/services/remote_desktop/csrd_tiles.dart';

/// A deterministic "page of text": white background, rows of 8 × 16 glyph
/// cells drawn from a small bank of anti-aliased greys. Compresses about as
/// well as a real terminal or document does (10–14× with zlib), which a
/// flat or random image would not.
///
/// The X byte is junk by default, as some capture APIs leave it; with
/// [junkX] false it is zero, as most do, which compresses three times
/// better.
Uint8List textLikeScreen(
  int width,
  int height, {
  int seed = 1,
  bool junkX = true,
}) {
  final px = Uint8List(width * height * 4);
  var s = seed | 1;
  int next() {
    s ^= (s << 13) & 0xffffffff;
    s ^= s >> 17;
    s ^= (s << 5) & 0xffffffff;
    return s;
  }

  final glyphs = List.generate(
    96,
    (_) => List.generate(128, (_) {
      final r = next() % 10;
      return r < 6 ? 255 : (r < 7 ? 170 : (r < 8 ? 85 : 30));
    }),
  );
  for (var y = 0; y < height; y++) {
    final line = y ~/ 18;
    final gy = y % 18;
    for (var x = 0; x < width; x++) {
      final col = x ~/ 8;
      var v = 255;
      if (gy < 16 && (line * 7 + col * 13) % 11 != 0 && col % 80 < 70) {
        v = glyphs[(line * 31 + col * 17) % 96][gy * 8 + x % 8];
      }
      final i = (y * width + x) * 4;
      px[i] = v;
      px[i + 1] = v;
      px[i + 2] = (v + line) & 0xff;
      px[i + 3] = junkX ? (x * 7 + y) & 0xff : 0;
    }
  }
  return px;
}

/// Noise, for tiles that should not compress.
Uint8List noise(int length, {int seed = 7}) {
  final out = Uint8List(length);
  var s = seed | 1;
  for (var i = 0; i < length; i++) {
    s ^= (s << 13) & 0xffffffff;
    s ^= s >> 17;
    s ^= (s << 5) & 0xffffffff;
    out[i] = s & 0xff;
  }
  return out;
}

/// The pixels of rect ([x], [y], [w], [h]) of a tightly packed BGRX image.
Uint8List gather(Uint8List image, int width, int x, int y, int w, int h) {
  final out = Uint8List(w * h * 4);
  for (var row = 0; row < h; row++) {
    final from = ((y + row) * width + x) * 4;
    out.setRange(row * w * 4, (row + 1) * w * 4, image, from);
  }
  return out;
}

/// A lossless encoder in the shape of `codec.rs`'s: 64 × 64 tiles, Fill for
/// flat ones, Deflate (or Raw, when that is smaller) for the rest, and
/// horizontal runs of non-flat tiles merged up to 512 pixels wide. With
/// [previous], only tiles that differ from it are sent.
List<CsrdRect> encodeLossless(
  Uint8List image,
  int width,
  int height, {
  Uint8List? previous,
  int level = 6,
}) {
  const tile = 64;
  const maxMerged = 512;
  final tilesX = (width + tile - 1) ~/ tile;
  final tilesY = (height + tile - 1) ~/ tile;
  final rects = <CsrdRect>[];

  bool dirty(int tx, int ty) {
    if (previous == null) return true;
    final x = tx * tile, y = ty * tile;
    final w = (width - x).clamp(0, tile), h = (height - y).clamp(0, tile);
    for (var row = 0; row < h; row++) {
      final o = ((y + row) * width + x) * 4;
      for (var i = 0; i < w * 4; i++) {
        if (image[o + i] != previous[o + i]) return true;
      }
    }
    return false;
  }

  int? flat(int x, int y, int w, int h) {
    final o = (y * width + x) * 4;
    final b = image[o], g = image[o + 1], r = image[o + 2];
    for (var row = 0; row < h; row++) {
      for (var col = 0; col < w; col++) {
        final i = ((y + row) * width + x + col) * 4;
        if (image[i] != b || image[i + 1] != g || image[i + 2] != r) {
          return null;
        }
      }
    }
    return b | g << 8 | r << 16;
  }

  for (var ty = 0; ty < tilesY; ty++) {
    var tx = 0;
    while (tx < tilesX) {
      if (!dirty(tx, ty)) {
        tx++;
        continue;
      }
      final x = tx * tile, y = ty * tile;
      final h = (height - y).clamp(0, tile);
      final w0 = (width - x).clamp(0, tile);
      final fill = flat(x, y, w0, h);
      if (fill != null) {
        rects.add(
          CsrdRect(
            x: x,
            y: y,
            width: w0,
            height: h,
            encoding: CsrdEncoding.fill,
            data: Uint8List.fromList([
              fill & 0xff,
              (fill >> 8) & 0xff,
              (fill >> 16) & 0xff,
              0,
            ]),
          ),
        );
        tx++;
        continue;
      }
      var end = tx + 1;
      while (end < tilesX &&
          (end - tx + 1) * tile <= maxMerged &&
          dirty(end, ty) &&
          flat(end * tile, y, (width - end * tile).clamp(0, tile), h) == null) {
        end++;
      }
      final w = (end * tile).clamp(0, width) - x;
      final raw = gather(image, width, x, y, w, h);
      final z = Uint8List.fromList(ZLibCodec(level: level).encode(raw));
      rects.add(
        CsrdRect(
          x: x,
          y: y,
          width: w,
          height: h,
          encoding: z.length < raw.length
              ? CsrdEncoding.deflate
              : CsrdEncoding.raw,
          data: z.length < raw.length ? z : raw,
        ),
      );
      tx = end;
    }
  }
  return rects;
}

/// A CPU framebuffer applying decoded frames the way `codec.rs`'s `Decoder`
/// does, in tightly packed BGRA: what the golden fixtures and the
/// compositor's output are checked against.
class CpuFramebuffer {
  int width = 0;
  int height = 0;
  Uint8List bgra = Uint8List(0);

  /// [jpegPixels] holds each JPEG tile's decoded BGRA, by tile index; JPEG
  /// tiles without an entry are skipped.
  void apply(CsrdDecodedFrame frame, {Map<int, Uint8List>? jpegPixels}) {
    if (frame.width != width || frame.height != height) {
      width = frame.width;
      height = frame.height;
      bgra = Uint8List(width * height * 4);
      for (var i = 3; i < bgra.length; i += 4) {
        bgra[i] = 0xff;
      }
    }
    for (var k = 0; k < frame.tiles.length; k++) {
      final t = frame.tiles[k];
      switch (t) {
        case CsrdFillTile(:final color):
          for (var row = 0; row < t.height; row++) {
            for (var col = 0; col < t.width; col++) {
              final i = ((t.y + row) * width + t.x + col) * 4;
              bgra[i] = color & 0xff;
              bgra[i + 1] = (color >> 8) & 0xff;
              bgra[i + 2] = (color >> 16) & 0xff;
              bgra[i + 3] = 0xff;
            }
          }
        case CsrdPixelTile(:final bgra):
          _blit(t, bgra);
        case CsrdJpegTile():
          final px = jpegPixels?[k];
          if (px != null) _blit(t, px);
      }
    }
  }

  void _blit(CsrdTile t, Uint8List px) {
    for (var row = 0; row < t.height; row++) {
      bgra.setRange(
        ((t.y + row) * width + t.x) * 4,
        ((t.y + row) * width + t.x + t.width) * 4,
        px,
        row * t.width * 4,
      );
    }
  }
}

/// Mean absolute difference of the B, G and R bytes of two BGR(X/A)
/// images; the fourth byte is ignored, since the wire's is junk.
double meanAbsError(Uint8List a, Uint8List b) {
  assert(a.length == b.length);
  var sum = 0;
  for (var i = 0; i < a.length; i += 4) {
    sum +=
        (a[i] - b[i]).abs() +
        (a[i + 1] - b[i + 1]).abs() +
        (a[i + 2] - b[i + 2]).abs();
  }
  return sum / (a.length / 4 * 3);
}

/// Index of the first pixel whose B, G or R differ, or -1.
int firstColourDifference(Uint8List a, Uint8List b) {
  for (var i = 0; i < a.length; i += 4) {
    if (a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2]) {
      return i ~/ 4;
    }
  }
  return -1;
}

/// An agent at the far end of an in-memory pipe: what the client writes
/// arrives here as messages, and what the test [send]s arrives at the
/// client as bytes, in whatever chunks the test likes.
class FakeHost {
  FakeHost() {
    _fromClient.stream.listen(
      (bytes) {
        _reader.add(bytes);
        for (CsrdMessage? m; (m = _reader.next()) != null;) {
          received.add(m!);
        }
        _wake();
      },
      onDone: () {
        _clientClosed.complete();
        _wake();
      },
    );
  }

  final _toClient = StreamController<Uint8List>();
  final _fromClient = StreamController<List<int>>();
  final _reader = CsrdMessageReader();
  final _clientClosed = Completer<void>();
  final _waiters = <Completer<void>>[];
  var _cursor = 0;

  /// Everything the client has sent, in order.
  final received = <CsrdMessage>[];

  /// The client's end: what it reads.
  Stream<Uint8List> get clientInput => _toClient.stream;

  /// The client's end: where it writes.
  StreamSink<List<int>> get clientOutput => _fromClient.sink;

  /// Completes when the client closes its output.
  Future<void> get clientClosed => _clientClosed.future;

  void send(CsrdMessage m) => _toClient.add(m.encode());

  void sendBytes(List<int> bytes) => _toClient.add(Uint8List.fromList(bytes));

  /// Hangs up on the client.
  Future<void> hangUp() => _toClient.close();

  void _wake() {
    for (final w in _waiters) {
      if (!w.isCompleted) w.complete();
    }
    _waiters.clear();
  }

  /// The next message the client sends that is a [T], skipping (but
  /// keeping in [received]) anything else, such as pings.
  Future<T> next<T extends CsrdMessage>({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      while (_cursor < received.length) {
        final m = received[_cursor++];
        if (m is T) return m;
      }
      if (_clientClosed.isCompleted) {
        throw StateError('client closed before sending a $T');
      }
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) throw TimeoutException('no $T', timeout);
      final w = Completer<void>();
      _waiters.add(w);
      await w.future.timeout(left, onTimeout: () {});
    }
  }

  /// Messages of type [T] received so far.
  List<T> all<T extends CsrdMessage>() => received.whereType<T>().toList();
}

/// A display for handshakes.
CsrdDisplayInfo testDisplay(int index, {bool primary = false}) =>
    CsrdDisplayInfo(
      index: index,
      name: 'Monitor $index — ünïcode',
      x: index * 1920 - 1920,
      y: 0,
      width: 1920,
      height: 1080,
      primary: primary,
    );

final testToken = Uint8List.fromList(List.filled(csrdTokenLength, 7));
