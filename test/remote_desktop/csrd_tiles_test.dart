import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/remote_desktop/csrd_messages.dart';
import 'package:secure_shell_go/services/remote_desktop/csrd_tiles.dart';

import 'csrd_test_support.dart';

CsrdRect rect(
  int x,
  int y,
  int w,
  int h,
  CsrdEncoding encoding,
  List<int> data,
) => CsrdRect(
  x: x,
  y: y,
  width: w,
  height: h,
  encoding: encoding,
  data: Uint8List.fromList(data),
);

CsrdFrame frame(int w, int h, List<CsrdRect> rects, {int seq = 1}) =>
    CsrdFrame(seq: seq, width: w, height: h, rects: rects);

Matcher codecError(String fragment) => throwsA(
  isA<CsrdCodecException>().having(
    (e) => e.message,
    'message',
    contains(fragment),
  ),
);

void main() {
  test('a fill becomes an opaque ARGB colour', () {
    final f = CsrdTileDecoder.decodeSync(
      frame(64, 64, [
        rect(0, 0, 64, 64, CsrdEncoding.fill, [1, 2, 3, 0x99]),
      ]),
    );
    final tile = f.tiles.single as CsrdFillTile;
    expect(tile.color, 0xff030201);
    expect((tile.x, tile.y, tile.width, tile.height), (0, 0, 64, 64));
  });

  test('raw pixels come out BGRA with alpha forced, the input untouched', () {
    final data = [10, 20, 30, 0, 40, 50, 60, 0x7f];
    final r = rect(1, 2, 2, 1, CsrdEncoding.raw, data);
    final tile =
        CsrdTileDecoder.decodeSync(frame(4, 4, [r])).tiles.single
            as CsrdPixelTile;
    expect(tile.bgra, [10, 20, 30, 0xff, 40, 50, 60, 0xff]);
    expect(r.data, data);
  });

  test('deflate tiles inflate to their rect, alpha forced', () {
    final px = textLikeScreen(64, 32);
    final z = ZLibCodec().encode(px);
    final tile =
        CsrdTileDecoder.decodeSync(
              frame(64, 32, [rect(0, 0, 64, 32, CsrdEncoding.deflate, z)]),
            ).tiles.single
            as CsrdPixelTile;
    for (var i = 0; i < px.length; i += 4) {
      expect(tile.bgra.sublist(i, i + 3), px.sublist(i, i + 3));
      expect(tile.bgra[i + 3], 0xff);
    }
  });

  test('JPEG tiles pass through, checked for a JPEG start marker', () {
    final jpeg = [0xff, 0xd8, 0xff, 0xe0, 1, 2, 3];
    final tile =
        CsrdTileDecoder.decodeSync(
              frame(8, 8, [rect(0, 0, 8, 8, CsrdEncoding.jpeg, jpeg)]),
            ).tiles.single
            as CsrdJpegTile;
    expect(tile.jpeg, jpeg);
    expect(
      () => CsrdTileDecoder.decodeSync(
        // A PNG signature: an image codec would happily decode it.
        frame(8, 8, [
          rect(0, 0, 8, 8, CsrdEncoding.jpeg, [0x89, 0x50]),
        ]),
      ),
      codecError('not a jpeg'),
    );
  });

  test('tiles keep wire order and the frame its seq and byte count', () {
    final f = CsrdTileDecoder.decodeSync(
      frame(128, 64, seq: 42, [
        rect(64, 0, 64, 64, CsrdEncoding.fill, [0, 0, 0, 0]),
        rect(0, 0, 1, 1, CsrdEncoding.raw, [1, 1, 1, 1]),
      ]),
    );
    expect(f.seq, 42);
    expect(f.wireBytes, 8);
    expect(f.tiles[0], isA<CsrdFillTile>());
    expect(f.tiles[1], isA<CsrdPixelTile>());
  });

  group('refuses', () {
    test('frames of no size, or over the limits', () {
      for (final (w, h) in [
        (0, 64),
        (64, 0),
        (csrdMaxDimension + 1, 1),
        (1, csrdMaxDimension + 1),
        // Within MAX_DIMENSION, over the area cap: 1 GiB of framebuffer.
        (csrdMaxDimension, csrdMaxDimension),
      ]) {
        expect(
          () => CsrdTileDecoder.decodeSync(frame(w, h, [])),
          throwsA(isA<CsrdCodecException>()),
          reason: '${w}x$h',
        );
      }
    });

    test('rects outside the frame, or empty', () {
      for (final r in [
        rect(60, 0, 10, 1, CsrdEncoding.fill, [0, 0, 0, 0]),
        rect(0, 60, 1, 10, CsrdEncoding.fill, [0, 0, 0, 0]),
        rect(0, 0, 0, 1, CsrdEncoding.fill, [0, 0, 0, 0]),
        rect(0, 0, 1, 0, CsrdEncoding.fill, [0, 0, 0, 0]),
        rect(0xffff, 0xffff, 0xffff, 0xffff, CsrdEncoding.fill, [0, 0, 0, 0]),
      ]) {
        expect(
          () => CsrdTileDecoder.decodeSync(frame(64, 64, [r])),
          codecError('outside'),
          reason: '$r',
        );
      }
    });

    test('rects that between them cover more than the frame', () {
      final whole = rect(0, 0, 64, 64, CsrdEncoding.fill, [0, 0, 0, 0]);
      expect(
        () => CsrdTileDecoder.decodeSync(frame(64, 64, [whole, whole])),
        codecError('more than the frame'),
      );
    });

    test('fills that are not four bytes, raw of the wrong length', () {
      expect(
        () => CsrdTileDecoder.decodeSync(
          frame(4, 4, [
            rect(0, 0, 1, 1, CsrdEncoding.fill, [0, 0, 0]),
          ]),
        ),
        codecError('fill colour'),
      );
      expect(
        () => CsrdTileDecoder.decodeSync(
          frame(4, 4, [rect(0, 0, 2, 2, CsrdEncoding.raw, List.filled(15, 0))]),
        ),
        codecError('wrong data length'),
      );
    });

    test('corrupt, short and junk deflate data', () {
      final z = ZLibCodec().encode(Uint8List(64 * 64 * 4));
      final corrupt = [...z]..[z.length - 1] ^= 0xff; // the adler32
      expect(
        () => CsrdTileDecoder.decodeSync(
          frame(64, 64, [rect(0, 0, 64, 64, CsrdEncoding.deflate, corrupt)]),
        ),
        codecError('corrupt'),
      );
      // One row short of the rect.
      final short = ZLibCodec().encode(Uint8List(64 * 63 * 4));
      expect(
        () => CsrdTileDecoder.decodeSync(
          frame(64, 64, [rect(0, 0, 64, 64, CsrdEncoding.deflate, short)]),
        ),
        codecError('short'),
      );
      expect(
        () => CsrdTileDecoder.decodeSync(
          frame(64, 64, [
            rect(0, 0, 64, 64, CsrdEncoding.deflate, [1, 2, 3]),
          ]),
        ),
        throwsA(isA<CsrdCodecException>()),
      );
      expect(
        () => CsrdTileDecoder.decodeSync(
          frame(64, 64, [rect(0, 0, 64, 64, CsrdEncoding.deflate, [])]),
        ),
        throwsA(isA<CsrdCodecException>()),
      );
    });

    test('a deflate bomb, quickly and without inflating it', () {
      // 256 MiB of zeros in about 260 KiB, claiming to be one 64 × 64 tile.
      final bomb = ZLibCodec(level: 9).encode(Uint8List(256 << 20));
      final watch = Stopwatch()..start();
      expect(
        () => CsrdTileDecoder.decodeSync(
          frame(64, 64, [rect(0, 0, 64, 64, CsrdEncoding.deflate, bomb)]),
        ),
        codecError('inflating past the rect'),
      );
      // Stopped within one 64 KiB piece, not after 256 MiB.
      expect(watch.elapsedMilliseconds, lessThan(200));
    });

    test('zstd, which the handshake ruled out', () {
      expect(
        () => CsrdTileDecoder.decodeSync(
          frame(4, 4, [
            rect(0, 0, 1, 1, CsrdEncoding.zstd, [0x28, 0xb5]),
          ]),
        ),
        codecError('zstd'),
      );
    });
  });

  group('off the calling isolate', () {
    test('decodes the same as on it, in the same order', () async {
      const w = 640, h = 200;
      final image = textLikeScreen(w, h, seed: 3);
      // A flat band, so fills are mixed in with the pixel tiles.
      for (var i = 0; i < w * 64 * 4; i += 4) {
        image
          ..[i] = 9
          ..[i + 1] = 8
          ..[i + 2] = 7;
      }
      final f = frame(w, h, encodeLossless(image, w, h));
      final here = CsrdTileDecoder.decodeSync(f);
      final there = await CsrdTileDecoder.decode(f, inlineLimit: 0);
      expect(there.tiles.length, here.tiles.length);
      for (var i = 0; i < here.tiles.length; i++) {
        final a = here.tiles[i], b = there.tiles[i];
        expect(b.runtimeType, a.runtimeType);
        expect((b.x, b.y, b.width, b.height), (a.x, a.y, a.width, a.height));
        if (a is CsrdPixelTile) expect((b as CsrdPixelTile).bgra, a.bgra);
        if (a is CsrdFillTile) expect((b as CsrdFillTile).color, a.color);
      }
      final fb = CpuFramebuffer()..apply(there);
      expect(firstColourDifference(fb.bgra, image), -1);
    });

    test('reports a bad tile as a codec error', () async {
      final f = frame(64, 64, [
        rect(0, 0, 64, 64, CsrdEncoding.deflate, [1, 2, 3]),
      ]);
      await expectLater(
        CsrdTileDecoder.decode(f, inlineLimit: 0),
        throwsA(isA<CsrdCodecException>()),
      );
    });

    test('small frames stay on the calling isolate', () {
      final f = frame(64, 64, [
        rect(0, 0, 64, 64, CsrdEncoding.raw, Uint8List(64 * 64 * 4)),
      ]);
      expect(CsrdTileDecoder.pixelBytes(f), 64 * 64 * 4);
      expect(CsrdTileDecoder.pixelBytes(f), lessThan(csrdInlineDecodeBytes));
    });
  });
}
