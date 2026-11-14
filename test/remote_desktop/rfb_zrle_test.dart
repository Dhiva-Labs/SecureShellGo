import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/remote_desktop/rfb_protocol.dart';
import 'package:secure_shell_go/services/remote_desktop/rfb_zrle.dart';

import 'rfb_test_support.dart';

/// A picture whose tiles suit [sub]: few colours for the palettes, long
/// runs for RLE.
Picture pictureFor(Sub sub, int w, int h) {
  final p = Picture(w, h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final rgb = switch (sub) {
        Sub.raw => (x * 37 + y * 11) << 8 ^ (x * y) & 0xffffff,
        Sub.solid => 0x123456,
        Sub.packed => const [0x000000, 0xffffff, 0xff0000][(x ~/ 3 + y) % 3],
        Sub.plainRle => (y ~/ 5) * 0x101010 ^ (x < 40 ? 0x00ff00 : 0),
        Sub.paletteRle => const [
          0x0000ff,
          0x00ff00,
          0x777777,
        ][(x ~/ 9 + y ~/ 4) % 3],
      };
      p.set(x, y, rgb & 0xffffff);
    }
  }
  return p;
}

Uint8List decodeWith(
  RfbZrleDecoder d,
  ZrleEncoder e,
  Picture p, {
  required Sub Function(int, Picture) choose,
}) {
  final data = e.encodeRect(p, 0, 0, p.width, p.height, choose);
  final r = d.decode(data, p.width, p.height);
  if (r.color != null) {
    final out = Picture(p.width, p.height)
      ..fillRect(0, 0, p.width, p.height, r.color! & 0xffffff);
    return out.bgra;
  }
  return r.bgra!;
}

void main() {
  // 100 × 70: two tile columns (64 and 36 wide), two rows (64 and 6).
  const w = 100, h = 70;

  for (final sub in Sub.values) {
    test('${sub.name} tiles decode exactly, edge tiles included', () {
      final p = pictureFor(sub, w, h);
      final got = decodeWith(
        RfbZrleDecoder(),
        ZrleEncoder(),
        p,
        choose: (_, t) =>
            sub == Sub.solid || colours(t).length > 1 ? sub : Sub.solid,
      );
      expect(firstDifference(got, p.bgra), -1);
      for (var i = 3; i < got.length; i += 4) {
        expect(got[i], 0xff);
      }
    });
  }

  test('packed palettes of every size, at 1, 2 and 4 bits per index', () {
    for (var size = 2; size <= 16; size++) {
      // Odd width so rows end mid-byte at every depth.
      final p = Picture(37, 9);
      for (var y = 0; y < 9; y++) {
        for (var x = 0; x < 37; x++) {
          p.set(x, y, ((x + 2 * y) % size) * 0x0f0f0f);
        }
      }
      expect(colours(p).length, size);
      final got = decodeWith(
        RfbZrleDecoder(),
        ZrleEncoder(),
        p,
        choose: (_, _) => Sub.packed,
      );
      expect(firstDifference(got, p.bgra), -1, reason: 'palette of $size');
    }
  });

  test('palette RLE with 127 colours and runs over 255 pixels', () {
    final p = Picture(64, 64);
    var i = 0;
    for (var y = 0; y < 64; y++) {
      for (var x = 0; x < 64; x++) {
        // The first 600 pixels one colour: a run needing 255, 255, 89.
        final rgb = i < 600 ? 0xabcdef : (i % 126) * 0x020304;
        p.set(x, y, rgb & 0xffffff);
        i++;
      }
    }
    expect(colours(p).length, 127);
    final got = decodeWith(
      RfbZrleDecoder(),
      ZrleEncoder(),
      p,
      choose: (_, _) => Sub.paletteRle,
    );
    expect(firstDifference(got, p.bgra), -1);
  });

  test('a run exactly the length of a tile, and one of 256', () {
    for (final run in [4096, 256, 255, 1]) {
      final p = Picture(64, 64);
      for (var k = 0; k < 4096; k++) {
        p.set(k % 64, k ~/ 64, k < run ? 0x010203 : 0x0a0b0c);
      }
      final got = decodeWith(
        RfbZrleDecoder(),
        ZrleEncoder(),
        p,
        choose: (_, _) => Sub.plainRle,
      );
      expect(firstDifference(got, p.bgra), -1, reason: 'run $run');
    }
  });

  test('a rect of one solid colour comes out as a fill', () {
    final p = Picture(150, 130)..fillRect(0, 0, 150, 130, 0x336699);
    final data = ZrleEncoder().encodeRect(p, 0, 0, 150, 130, bestSub);
    final r = RfbZrleDecoder().decode(data, 150, 130);
    expect(r.color, 0xff336699);
    expect(r.bgra, isNull);
  });

  test('solid tiles of different colours are pixels, not a fill', () {
    final p = Picture(128, 64)
      ..fillRect(0, 0, 64, 64, 0x111111)
      ..fillRect(64, 0, 64, 64, 0x222222);
    final r = RfbZrleDecoder().decode(
      ZrleEncoder().encodeRect(p, 0, 0, 128, 64, bestSub),
      128,
      64,
    );
    expect(r.color, isNull);
    expect(firstDifference(r.bgra!, p.bgra), -1);
  });

  test('one zlib stream runs through every rect of the connection', () {
    final e = ZrleEncoder();
    final d = RfbZrleDecoder();
    final p = busyPicture(200, 90);
    for (var round = 0; round < 3; round++) {
      final data = e.encodeRect(p, 0, 0, 200, 90, bestSub);
      final r = d.decode(data, 200, 90);
      expect(firstDifference(r.bgra!, p.bgra), -1, reason: 'round $round');
      if (round > 0) {
        // The same picture again compresses to back-references into the
        // last rect, which a fresh decoder has never seen.
        expect(
          () => RfbZrleDecoder().decode(data, 200, 90),
          throwsA(isA<RfbProtocolException>()),
        );
      }
    }
  });

  test('a zero-sized rect still moves the stream along', () {
    final e = ZrleEncoder();
    final d = RfbZrleDecoder();
    final empty = e.compress(const []);
    expect(d.decode(empty, 0, 0).bgra, isEmpty);
    final p = busyPicture(64, 64);
    final r = d.decode(e.encodeRect(p, 0, 0, 64, 64, bestSub), 64, 64);
    expect(firstDifference(r.bgra!, p.bgra), -1);
  });

  group('untrusted data', () {
    RfbProtocolException fails(List<int> tile, {int w = 8, int h = 8}) {
      final data = ZrleEncoder().compress(tile);
      try {
        RfbZrleDecoder().decode(data, w, h);
      } on RfbProtocolException catch (e) {
        return e;
      }
      fail('accepted $tile');
    }

    test('a palette index past the palette', () {
      // 3 colours at 2 bits per index: index 3 is out of range.
      final e = fails([
        3,
        ...cpixel(1),
        ...cpixel(2),
        ...cpixel(3),
        0xff,
        ...List.filled(15, 0),
      ]);
      expect(e.message, contains('palette index 3 of a 3-colour palette'));
      final rle = fails([130, ...cpixel(1), ...cpixel(2), 5]);
      expect(rle.message, contains('palette index 5'));
    });

    test('runs that overrun the tile', () {
      expect(fails([128, ...cpixel(1), 64]).message, contains('overruns'));
      expect(
        fails([128, ...cpixel(1), 30, ...cpixel(2), 33]).message,
        contains('overruns'),
      );
      // A run of 255s that never ends is stopped as soon as it passes the
      // tile, not after reading all of them.
      expect(
        fails([
          130,
          ...cpixel(1),
          ...cpixel(2),
          0x81,
          ...List.filled(500, 255),
        ]).message,
        contains('overruns'),
      );
    });

    test('unused subencodings', () {
      for (final sub in [17, 100, 127, 129]) {
        expect(
          fails([sub, ...List.filled(200, 0)]).message,
          contains('unknown ZRLE subencoding $sub'),
        );
      }
    });

    test('data that ends inside a tile', () {
      expect(fails([0, 1, 2, 3]).message, contains('ends inside a tile'));
      expect(fails([1, 1]).message, contains('ends inside a tile'));
      expect(fails([]).message, contains('ends inside a tile'));
    });

    test('inflated output is capped at what the rect could need', () {
      // A 2 × 2 rect needs at most 4 × 4 + 382 bytes; 1 MiB of zeros
      // compresses to about a kilobyte.
      final huge = List.filled(1 << 20, 0);
      final e = fails(huge, w: 2, h: 2);
      expect(e.message, contains('inflates past its rect'));
    });

    test('corrupt zlib data', () {
      expect(
        () => RfbZrleDecoder().decode(
          Uint8List.fromList([0x78, 0x9c, 0xff, 0xff, 0xff, 0x00, 0x12]),
          8,
          8,
        ),
        throwsA(
          isA<RfbProtocolException>().having(
            (e) => e.message,
            'message',
            contains('corrupt'),
          ),
        ),
      );
    });

    test('a broken stream stays broken', () {
      final d = RfbZrleDecoder();
      expect(
        () => d.decode(Uint8List.fromList([1, 2, 3, 4]), 8, 8),
        throwsA(isA<RfbProtocolException>()),
      );
      final good = ZrleEncoder().compress([1, ...cpixel(5)]);
      expect(() => d.decode(good, 8, 8), throwsA(isA<RfbProtocolException>()));
    });

    test('mutated rects only ever fail with RfbProtocolException', () {
      final rng = Random(42);
      final p = busyPicture(96, 80, seed: 9);
      final clean = ZrleEncoder.plainRect(p, 0, 0, 96, 80, mixedSub);
      var refused = 0;
      for (var round = 0; round < 400; round++) {
        final m = Uint8List.fromList(clean);
        final edits = 1 + rng.nextInt(6);
        for (var k = 0; k < edits; k++) {
          m[rng.nextInt(m.length)] = rng.nextInt(256);
        }
        final cut = rng.nextInt(4) == 0 ? rng.nextInt(m.length) : m.length;
        final data = ZrleEncoder().compress(m.sublist(0, cut));
        try {
          final r = RfbZrleDecoder().decode(data, 96, 80);
          expect(r.bgra?.length ?? 96 * 80 * 4, 96 * 80 * 4);
        } on RfbProtocolException {
          refused++;
        }
      }
      expect(refused, greaterThan(0));
    });
  });

  test('the caps are a true upper bound for well-formed rects', () {
    // Plain RLE with every run one pixel long is the worst case.
    final p = Picture(64, 64);
    for (var k = 0; k < 4096; k++) {
      p.set(k % 64, k ~/ 64, k.isEven ? 0x010101 : 0x020202);
    }
    final plain = encodeTile(p, Sub.plainRle);
    expect(plain.length, 1 + 4096 * 4);
    expect(plain.length, lessThanOrEqualTo(RfbZrleDecoder.maxInflated(64, 64)));
    final r = RfbZrleDecoder().decode(ZrleEncoder().compress(plain), 64, 64);
    expect(firstDifference(r.bgra!, p.bgra), -1);
  });
}
