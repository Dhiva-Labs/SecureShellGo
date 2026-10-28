/// How long decoding takes, and how much of it lands on the calling
/// isolate: the measurement behind `csrdInlineDecodeBytes`.
///
/// It prints its numbers and asserts only that the pixels come out right:
/// timings under `flutter test` (a JIT build, sharing the machine with
/// other test files) are a guide, not something to fail a build over.
/// Release builds are compiled ahead of time and run the byte loops about
/// three times faster than this; the inflate itself is native zlib either
/// way.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/remote_desktop/csrd_messages.dart';
import 'package:secure_shell_go/services/remote_desktop/csrd_tiles.dart';

import 'csrd_test_support.dart';

int median(List<int> v) => (List.of(v)..sort())[v.length ~/ 2];

/// Runs [body] while a 1 ms timer ticks on this isolate, and returns the
/// longest gap between ticks: how long the isolate could not run anything
/// else, which is what a dropped UI frame is made of.
Future<int> longestStallUs(Future<void> Function() body) async {
  final clock = Stopwatch()..start();
  var last = 0;
  var longest = 0;
  final ticker = Timer.periodic(const Duration(milliseconds: 1), (_) {
    final now = clock.elapsedMicroseconds;
    if (now - last > longest) longest = now - last;
    last = now;
  });
  await body();
  final now = clock.elapsedMicroseconds;
  if (now - last > longest) longest = now - last;
  ticker.cancel();
  return longest;
}

void main() {
  test('1080p full refresh of text-like tiles', () async {
    const w = 1920, h = 1080;
    final image = textLikeScreen(w, h, junkX: false);
    final frame = CsrdFrame(
      seq: 1,
      width: w,
      height: h,
      rects: encodeLossless(image, w, h),
    );
    final deflate = frame.rects.where(
      (r) => r.encoding == CsrdEncoding.deflate,
    );

    // Warm up both paths.
    CsrdTileDecoder.decodeSync(frame);
    await CsrdTileDecoder.decode(frame);

    final inline = <int>[];
    for (var i = 0; i < 5; i++) {
      final watch = Stopwatch()..start();
      CsrdTileDecoder.decodeSync(frame);
      inline.add(watch.elapsedMicroseconds);
    }

    final isolateTotal = <int>[];
    final isolateStall = <int>[];
    late CsrdDecodedFrame last;
    for (var i = 0; i < 5; i++) {
      final watch = Stopwatch()..start();
      isolateStall.add(
        await longestStallUs(() async {
          last = await CsrdTileDecoder.decode(frame);
        }),
      );
      isolateTotal.add(watch.elapsedMicroseconds);
    }
    final idleStall = await longestStallUs(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );

    final fb = CpuFramebuffer()..apply(last);
    expect(firstColourDifference(fb.bgra, image), -1);

    // Incremental frames: a line of text redrawn (two tile rows), and a
    // few characters typed (one tile).
    CsrdFrame changed(int x0, int y0, int x1, int y1) {
      final before = Uint8List.fromList(image);
      for (var y = y0; y < y1; y++) {
        before.fillRange((y * w + x0) * 4, (y * w + x1) * 4, 0);
      }
      return CsrdFrame(
        seq: 2,
        width: w,
        height: h,
        rects: encodeLossless(image, w, h, previous: before),
      );
    }

    String incremental(String what, CsrdFrame f) {
      final times = <int>[];
      for (var i = 0; i < 20; i++) {
        final watch = Stopwatch()..start();
        CsrdTileDecoder.decodeSync(f);
        times.add(watch.elapsedMicroseconds);
      }
      final bytes = CsrdTileDecoder.pixelBytes(f);
      final where = bytes <= csrdInlineDecodeBytes ? 'inline' : 'isolate';
      return '  $what: ${f.rects.length} rects, $bytes pixel bytes '
          '($where), decode median ${median(times)} us';
    }

    final line = incremental('line redrawn', changed(0, 200, w, 260));
    final typed = incremental('chars typed', changed(300, 400, 340, 416));

    final compressed = frame.dataBytes;
    // ignore: avoid_print
    print(
      '1080p text-like full refresh: ${frame.rects.length} rects '
      '(${deflate.length} deflate), ${w * h * 4} bytes of pixels from '
      '$compressed compressed '
      '(${(w * h * 4 / compressed).toStringAsFixed(1)}x)\n'
      '  inline decode:  median ${median(inline)} us '
      '(${inline.join(', ')})\n'
      '  isolate decode: median ${median(isolateTotal)} us latency, '
      'longest stall on this isolate median ${median(isolateStall)} us '
      '(${isolateStall.join(', ')}); idle timer jitter $idleStall us\n'
      '$line\n$typed',
    );
  });
}
