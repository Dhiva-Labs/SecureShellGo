/// ZRLE (RFB encoding 16): the rect is cut into 64 × 64 tiles, each sent
/// raw, as one colour, as a packed palette, or run-length encoded, and the
/// whole lot goes through zlib. One zlib stream runs for the whole
/// connection, every ZRLE rect continuing it, so the decoder here is
/// stateful and belongs to one connection.
///
/// Pixels come out as BGRA with alpha 0xFF, ready for the compositor. With
/// the pixel format this client asks for (see `rfbSetPixelFormat`), a
/// CPIXEL is three bytes, B, G, R.
///
/// The server is untrusted. Its compressed data is inflated only up to the
/// most a well-formed rect of that size could need, and every palette
/// index, run length and tile read is checked against the tile and the
/// data actually there.
library;

import 'dart:io' show RawZLibFilter;
import 'dart:typed_data';

import 'rfb_protocol.dart';

/// One decoded ZRLE rect: a single colour when every tile of it was the
/// same solid colour, else its pixels.
class RfbZrleRect {
  const RfbZrleRect.fill(int this.color) : bgra = null;
  const RfbZrleRect.pixels(Uint8List this.bgra) : color = null;

  /// 0xAARRGGBB with alpha 0xFF.
  final int? color;

  /// `width * height * 4` bytes, BGRA with alpha 0xFF.
  final Uint8List? bgra;
}

class RfbZrleDecoder {
  final RawZLibFilter _inflater = RawZLibFilter.inflateFilter();
  var _broken = false;

  static const tileSide = 64;

  /// The most inflated data a well-formed [width] × [height] rect can need.
  ///
  /// Per tile of n pixels: plain RLE with every run one pixel long is the
  /// worst, a CPIXEL and a length byte each, 4n; palette RLE is at most
  /// 2n plus a 127-colour palette (381 bytes); raw is 3n. Plus one
  /// subencoding byte per tile.
  static int maxInflated(int width, int height) {
    final tiles =
        ((width + tileSide - 1) ~/ tileSide) *
        ((height + tileSide - 1) ~/ tileSide);
    return width * height * 4 + tiles * (1 + 127 * 3);
  }

  /// The most compressed data accepted for such a rect: what zlib's stored
  /// blocks would make of [maxInflated] bytes, with room to spare.
  static int maxCompressed(int width, int height) {
    final n = maxInflated(width, height);
    return n + (n >> 6) + 4096;
  }

  /// Decodes one rect from its [compressed] data, continuing the stream.
  ///
  /// After a failure the stream is out of step with the server's, so every
  /// later call fails too; the connection has to go.
  RfbZrleRect decode(Uint8List compressed, int width, int height) {
    if (_broken) {
      throw const RfbProtocolException('ZRLE stream is already broken');
    }
    try {
      final data = _inflate(compressed, maxInflated(width, height));
      return _tiles(data, width, height);
    } catch (_) {
      _broken = true;
      rethrow;
    }
  }

  /// Everything [compressed] inflates to, refusing more than [cap] bytes.
  ///
  /// `RawZLibFilter` hands output over in pieces of up to 64 KiB, so a
  /// stream that would inflate far past the cap is stopped within one piece
  /// of it. The stream is never ended: the next rect carries on from here.
  Uint8List _inflate(Uint8List compressed, int cap) {
    final out = BytesBuilder(copy: false);
    try {
      _inflater.process(compressed, 0, compressed.length);
      while (true) {
        final piece = _inflater.processed(flush: true, end: false);
        if (piece == null) break;
        if (out.length + piece.length > cap) {
          throw const RfbProtocolException('ZRLE data inflates past its rect');
        }
        out.add(piece);
      }
    } on FormatException {
      throw const RfbProtocolException('corrupt ZRLE data');
    }
    return out.takeBytes();
  }

  RfbZrleRect _tiles(Uint8List data, int width, int height) {
    final out = Uint8List(width * height * 4);
    final r = _TileReader(data);
    int? solid;
    var allSolid = true;
    for (var ty = 0; ty < height; ty += tileSide) {
      final th = height - ty < tileSide ? height - ty : tileSide;
      for (var tx = 0; tx < width; tx += tileSide) {
        final tw = width - tx < tileSide ? width - tx : tileSide;
        final sub = r.u8();
        if (sub == 1) {
          final c = r.cpixel();
          _fill(out, width, tx, ty, tw, th, c);
          if (allSolid) {
            if (solid == null) {
              solid = c;
            } else if (solid != c) {
              allSolid = false;
            }
          }
          continue;
        }
        allSolid = false;
        if (sub == 0) {
          _raw(r, out, width, tx, ty, tw, th);
        } else if (sub <= 16) {
          _packedPalette(r, out, width, tx, ty, tw, th, sub);
        } else if (sub == 128) {
          _plainRle(r, out, width, tx, ty, tw, th);
        } else if (sub >= 130) {
          _paletteRle(r, out, width, tx, ty, tw, th, sub - 128);
        } else {
          throw RfbProtocolException('unknown ZRLE subencoding $sub');
        }
      }
    }
    // Bytes left over are ignored: they cannot affect any pixel, and the
    // stream's position is already right for the next rect, since every
    // rect's compressed data is flushed on its own.
    if (allSolid && solid != null) return RfbZrleRect.fill(solid);
    return RfbZrleRect.pixels(out);
  }

  /// [c] is 0xAARRGGBB.
  static void _fill(
    Uint8List out,
    int stride,
    int tx,
    int ty,
    int tw,
    int th,
    int c,
  ) {
    final b = c & 0xff, g = (c >> 8) & 0xff, rr = (c >> 16) & 0xff;
    for (var y = 0; y < th; y++) {
      var i = ((ty + y) * stride + tx) * 4;
      for (var x = 0; x < tw; x++) {
        out[i] = b;
        out[i + 1] = g;
        out[i + 2] = rr;
        out[i + 3] = 0xff;
        i += 4;
      }
    }
  }

  static void _raw(
    _TileReader r,
    Uint8List out,
    int stride,
    int tx,
    int ty,
    int tw,
    int th,
  ) {
    r.need(tw * th * 3);
    final d = r.data;
    var p = r.pos;
    for (var y = 0; y < th; y++) {
      var i = ((ty + y) * stride + tx) * 4;
      for (var x = 0; x < tw; x++) {
        out[i] = d[p];
        out[i + 1] = d[p + 1];
        out[i + 2] = d[p + 2];
        out[i + 3] = 0xff;
        p += 3;
        i += 4;
      }
    }
    r.pos = p;
  }

  static List<int> _palette(_TileReader r, int size) => [
    for (var i = 0; i < size; i++) r.cpixel(),
  ];

  static void _packedPalette(
    _TileReader r,
    Uint8List out,
    int stride,
    int tx,
    int ty,
    int tw,
    int th,
    int size,
  ) {
    final palette = _palette(r, size);
    final bits = size == 2 ? 1 : (size <= 4 ? 2 : 4);
    final mask = (1 << bits) - 1;
    final rowBytes = (tw * bits + 7) >> 3;
    r.need(rowBytes * th);
    final d = r.data;
    for (var y = 0; y < th; y++) {
      final row = r.pos + y * rowBytes;
      var i = ((ty + y) * stride + tx) * 4;
      for (var x = 0; x < tw; x++) {
        final bit = x * bits;
        final index = (d[row + (bit >> 3)] >> (8 - bits - (bit & 7))) & mask;
        if (index >= size) {
          throw RfbProtocolException(
            'ZRLE palette index $index of a $size-colour palette',
          );
        }
        final c = palette[index];
        out[i] = c & 0xff;
        out[i + 1] = (c >> 8) & 0xff;
        out[i + 2] = (c >> 16) & 0xff;
        out[i + 3] = 0xff;
        i += 4;
      }
    }
    r.pos += rowBytes * th;
  }

  static void _plainRle(
    _TileReader r,
    Uint8List out,
    int stride,
    int tx,
    int ty,
    int tw,
    int th,
  ) {
    final total = tw * th;
    var done = 0;
    while (done < total) {
      final c = r.cpixel();
      final run = r.runLength(total - done);
      _run(out, stride, tx, ty, tw, done, run, c);
      done += run;
    }
  }

  static void _paletteRle(
    _TileReader r,
    Uint8List out,
    int stride,
    int tx,
    int ty,
    int tw,
    int th,
    int size,
  ) {
    final palette = _palette(r, size);
    final total = tw * th;
    var done = 0;
    while (done < total) {
      final b = r.u8();
      final index = b & 0x7f;
      if (index >= size) {
        throw RfbProtocolException(
          'ZRLE palette index $index of a $size-colour palette',
        );
      }
      final run = b & 0x80 != 0 ? r.runLength(total - done) : 1;
      _run(out, stride, tx, ty, tw, done, run, palette[index]);
      done += run;
    }
  }

  /// Writes [run] pixels of [c] from tile pixel [start] on, row by row.
  static void _run(
    Uint8List out,
    int stride,
    int tx,
    int ty,
    int tw,
    int start,
    int run,
    int c,
  ) {
    final b = c & 0xff, g = (c >> 8) & 0xff, rr = (c >> 16) & 0xff;
    var x = start % tw;
    var y = start ~/ tw;
    var i = ((ty + y) * stride + tx + x) * 4;
    for (var n = 0; n < run; n++) {
      out[i] = b;
      out[i + 1] = g;
      out[i + 2] = rr;
      out[i + 3] = 0xff;
      if (++x == tw) {
        x = 0;
        y++;
        i = ((ty + y) * stride + tx) * 4;
      } else {
        i += 4;
      }
    }
  }
}

class _TileReader {
  _TileReader(this.data);
  final Uint8List data;
  var pos = 0;

  void need(int n) {
    if (pos + n > data.length) {
      throw const RfbProtocolException('ZRLE data ends inside a tile');
    }
  }

  int u8() {
    need(1);
    return data[pos++];
  }

  /// A CPIXEL as 0xAARRGGBB.
  int cpixel() {
    need(3);
    final c = 0xff000000 | data[pos + 2] << 16 | data[pos + 1] << 8 | data[pos];
    pos += 3;
    return c;
  }

  /// A run length: 1 plus bytes summed while they are 255. Refused once it
  /// passes [left], the pixels the tile still has, so a hostile run of
  /// 255s is stopped as soon as it overruns.
  int runLength(int left) {
    var n = 1;
    while (true) {
      final b = u8();
      n += b;
      if (n > left) {
        throw const RfbProtocolException('ZRLE run overruns its tile');
      }
      if (b != 255) return n;
    }
  }
}
