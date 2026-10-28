import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/remote_desktop/csrd_client.dart';
import 'package:secure_shell_go/services/remote_desktop/csrd_messages.dart';
import 'package:secure_shell_go/services/remote_desktop/csrd_tiles.dart';
import 'package:secure_shell_go/widgets/remote_desktop/frame_compositor.dart';

import 'csrd_test_support.dart';

/// A 48 × 32 baseline JPEG of a smooth gradient (PIL, quality 95, 4:4:4):
/// pixel (x, y) is RGB (40 + 4x, 60 + 5y, 200 − 2x), give or take the
/// codec.
final gradientJpeg = base64.decode(
  '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAIBAQEBAQIBAQECAgICAgQDAgICAgUEBAMEBgUG'
  'BgYFBgYGBwkIBgcJBwYGCAsICQoKCgoKBggLDAsKDAkKCgr/2wBDAQICAgICAgUDAwUKBwYH'
  'CgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgr/wAAR'
  'CAAgADADAREAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAA'
  'AgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkK'
  'FhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWG'
  'h4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl'
  '5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREA'
  'AgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYk'
  'NOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOE'
  'hYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk'
  '5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD5O07wWBj9z+lf3vj8fvqflWV5ntqb2neC'
  'ycfuf0r4nH4/fU/RsrzPbU39N8EdP3P6V8Vj8fvqfouV5ntqdBpvgjp+5/Svicwx++p+i5Xm'
  'e2pv6d4LAx+5/Svicfj99T9FyvM9tTe07wWTj9z+lfFY/H76n6NleZ7anBab4I6fuf0r+18f'
  'j99T/GHK8z21Og03wR0/c/pXxOPx++p+jZXme2pv6d4LAxiHP4V8Vj8fvqfouV5ntqb2neCi'
  'cZi/Svicfj99T9FyvM9tTf03wR0/c/pXxWPx++p+i5Xme2p0Gm+COn7n9K+Jx+P31P0XK8z2'
  '1OC07wWBjEOfwr+18fj99T/GLK8z21N7TvBROMxfpXxOPx++p+jZXme2pv6b4I6fuf0r4nH4'
  '/fU/RcrzPbU6DTfBHT9z+lfFY/H76n6LleZ7am/p3gsDGIf0r4rH4/fU/RcrzPbU3tO8FE4z'
  'F+lfE4/H76n6LleZ7anBab4I6fuf0r+18fj99T/GLK8z21Og03wR0/c/pXxWPx++p+jZXme2'
  'pv6d4LAxiH9K+JzDH76n6LleZ7am9p3gonGYv0r4nH4/fU/RcrzPbU39N8EdP3P6V8Tj8fvq'
  'fouV5ntqdBpvgnp+6/Svisfj99T9GyvM9tT/2Q==',
);

int gradientBlue(int x, int y) => 200 - 2 * x;
int gradientGreen(int x, int y) => 60 + 5 * y;
int gradientRed(int x, int y) => 40 + 4 * x;

/// The image's pixels as BGRA, to compare with a [CpuFramebuffer].
Future<Uint8List> bgraOf(ui.Image image) async {
  final rgba = (await image.toByteData(
    format: ui.ImageByteFormat.rawRgba,
  ))!.buffer.asUint8List();
  final out = Uint8List(rgba.length);
  for (var i = 0; i < rgba.length; i += 4) {
    out[i] = rgba[i + 2];
    out[i + 1] = rgba[i + 1];
    out[i + 2] = rgba[i];
    out[i + 3] = rgba[i + 3];
  }
  return out;
}

CsrdDecodedFrame decoded(
  int seq,
  int width,
  int height,
  List<CsrdRect> rects,
) => CsrdTileDecoder.decodeSync(
  CsrdFrame(seq: seq, width: width, height: height, rects: rects),
);

CsrdRect fill(int x, int y, int w, int h, int b, int g, int r) => CsrdRect(
  x: x,
  y: y,
  width: w,
  height: h,
  encoding: CsrdEncoding.fill,
  data: Uint8List.fromList([b, g, r, 0]),
);

/// Counts `ui.Image` handles made and let go of while it is installed.
class ImageCensus {
  ImageCensus() {
    ui.Image.onCreate = live.add;
    ui.Image.onDispose = live.remove;
  }

  final live = <ui.Image>{};

  void uninstall() {
    ui.Image.onCreate = null;
    ui.Image.onDispose = null;
  }
}

/// Presentation that happens when the test says so.
class ManualPresentation {
  final _pending = <Completer<void>>[];

  Future<void> call() {
    final c = Completer<void>();
    _pending.add(c);
    return c.future;
  }

  int get waiting => _pending.length;

  void presentAll() {
    for (final c in _pending) {
      c.complete();
    }
    _pending.clear();
  }
}

Future<void> immediately() async {}

void main() {
  test(
    'fills and pixel tiles land where the CPU framebuffer puts them',
    () async {
      final compositor = FrameCompositor(presentation: immediately);
      const w = 200, h = 130;
      final image = textLikeScreen(w, h);
      for (var y = 64; y < 128; y++) {
        for (var x = 0; x < w; x++) {
          final i = (y * w + x) * 4;
          image
            ..[i] = 1
            ..[i + 1] = 2
            ..[i + 2] = 3;
        }
      }
      final frame = decoded(1, w, h, encodeLossless(image, w, h));
      expect(frame.tiles.whereType<CsrdFillTile>(), isNotEmpty);
      expect(frame.tiles.whereType<CsrdPixelTile>(), isNotEmpty);
      await compositor.apply(frame);
      final cpu = CpuFramebuffer()..apply(frame);
      final got = await bgraOf(compositor.value!);
      expect(firstColourDifference(got, cpu.bgra), -1);
      expect(firstColourDifference(got, image), -1);
      expect((compositor.width, compositor.height), (w, h));
      compositor.dispose();
    },
  );

  test('a partial frame changes only its tiles', () async {
    final compositor = FrameCompositor(presentation: immediately);
    const w = 256, h = 192;
    final first = textLikeScreen(w, h, seed: 1);
    final second = Uint8List.fromList(first);
    // Change a 10 × 10 patch inside tile (1, 1), and one pixel in (3, 2).
    for (var y = 70; y < 80; y++) {
      for (var x = 70; x < 80; x++) {
        second[(y * w + x) * 4] ^= 0xff;
      }
    }
    second[(130 * w + 200) * 4 + 1] ^= 0x0f;
    await compositor.apply(decoded(1, w, h, encodeLossless(first, w, h)));
    final rects = encodeLossless(second, w, h, previous: first);
    expect(rects.length, 2);
    await compositor.apply(decoded(2, w, h, rects));
    final got = await bgraOf(compositor.value!);
    expect(firstColourDifference(got, second), -1);
    expect(compositor.generation, 1);
    compositor.dispose();
  });

  test('JPEG tiles are decoded into place', () async {
    final compositor = FrameCompositor(presentation: immediately);
    final frame = decoded(1, 64, 48, [fill(0, 0, 64, 48, 0, 0, 0)]);
    await compositor.apply(frame);
    await compositor.apply(
      decoded(2, 64, 48, [
        CsrdRect(
          x: 8,
          y: 4,
          width: 48,
          height: 32,
          encoding: CsrdEncoding.jpeg,
          data: gradientJpeg,
        ),
      ]),
    );
    final got = await bgraOf(compositor.value!);
    var error = 0;
    for (var y = 0; y < 32; y++) {
      for (var x = 0; x < 48; x++) {
        final i = ((y + 4) * 64 + x + 8) * 4;
        error +=
            (got[i] - gradientBlue(x, y)).abs() +
            (got[i + 1] - gradientGreen(x, y)).abs() +
            (got[i + 2] - gradientRed(x, y)).abs();
        expect(got[i + 3], 0xff);
      }
    }
    expect(error / (48 * 32 * 3), lessThan(3));
    // Outside the tile: still the black fill.
    expect(got.sublist(0, 4), [0, 0, 0, 0xff]);
    compositor.dispose();
  });

  test('a JPEG that is not its rect’s size is refused', () async {
    final compositor = FrameCompositor(presentation: immediately);
    final frame = decoded(1, 64, 64, [
      CsrdRect(
        x: 0,
        y: 0,
        width: 64,
        height: 64,
        encoding: CsrdEncoding.jpeg,
        data: gradientJpeg,
      ),
    ]);
    await expectLater(
      compositor.apply(frame),
      throwsA(
        isA<CsrdCodecException>().having(
          (e) => e.message,
          'message',
          contains('48x32 jpeg in a 64x64 rect'),
        ),
      ),
    );
    expect(compositor.value, isNull);
    compositor.dispose();
  });

  test('a corrupt JPEG is refused, and later frames still apply', () async {
    final compositor = FrameCompositor(presentation: immediately);
    final corrupt = Uint8List.fromList(gradientJpeg.sublist(0, 40));
    await expectLater(
      compositor.apply(
        decoded(1, 48, 32, [
          CsrdRect(
            x: 0,
            y: 0,
            width: 48,
            height: 32,
            encoding: CsrdEncoding.jpeg,
            data: corrupt,
          ),
        ]),
      ),
      throwsA(isA<CsrdCodecException>()),
    );
    await compositor.apply(decoded(2, 48, 32, [fill(0, 0, 48, 32, 9, 9, 9)]));
    expect((await bgraOf(compositor.value!)).sublist(0, 3), [9, 9, 9]);
    compositor.dispose();
  });

  test('a size change starts again from black', () async {
    final compositor = FrameCompositor(presentation: immediately);
    await compositor.apply(
      decoded(1, 64, 64, [fill(0, 0, 64, 64, 50, 60, 70)]),
    );
    expect(compositor.generation, 1);
    await compositor.apply(decoded(2, 128, 64, [fill(0, 0, 64, 64, 1, 2, 3)]));
    expect((compositor.width, compositor.height), (128, 64));
    expect(compositor.generation, 2);
    final got = await bgraOf(compositor.value!);
    expect(got.sublist(0, 4), [1, 2, 3, 0xff]);
    // The half the frame did not cover is black, not the old screen.
    final right = (10 * 128 + 100) * 4;
    expect(got.sublist(right, right + 4), [0, 0, 0, 0xff]);
    compositor.dispose();
  });

  test('frames apply in order and are presented in order', () async {
    final presentation = ManualPresentation();
    final seen = <int>[];
    final compositor = FrameCompositor(
      presentation: presentation.call,
      onPresented: seen.add,
    );
    const w = 320, h = 128;
    final big = decoded(1, w, h, encodeLossless(textLikeScreen(w, h), w, h));
    final small = decoded(2, w, h, [fill(0, 0, 64, 64, 4, 5, 6)]);
    final done = [compositor.apply(big), compositor.apply(small)];
    while (presentation.waiting < 2) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    // Composited, not yet presented.
    expect(seen, isEmpty);
    final got = await bgraOf(compositor.value!);
    expect(got.sublist(0, 3), [4, 5, 6]); // the small frame went on top
    presentation.presentAll();
    await Future.wait(done);
    expect(seen, [1, 2]);
    compositor.dispose();
  });

  test('listeners hear about every new image', () async {
    final compositor = FrameCompositor(presentation: immediately);
    var notified = 0;
    compositor.addListener(() => notified++);
    await compositor.apply(decoded(1, 8, 8, [fill(0, 0, 8, 8, 1, 1, 1)]));
    await compositor.apply(decoded(2, 8, 8, [fill(0, 0, 4, 4, 2, 2, 2)]));
    expect(notified, 2);
    compositor.dispose();
  });

  group('images', () {
    late ImageCensus census;
    setUp(() => census = ImageCensus());
    tearDown(() => census.uninstall());

    test('only the current screen stays alive, and dispose frees it', () async {
      final compositor = FrameCompositor(presentation: immediately);
      const w = 192, h = 128;
      var image = textLikeScreen(w, h);
      await compositor.apply(decoded(1, w, h, encodeLossless(image, w, h)));
      for (var seq = 2; seq < 6; seq++) {
        final next = textLikeScreen(w, h, seed: seq);
        await compositor.apply(
          decoded(seq, w, h, encodeLossless(next, w, h, previous: image)),
        );
        image = next;
        expect(census.live, {compositor.value});
      }
      await compositor.apply(
        decoded(6, 48, 32, [
          CsrdRect(
            x: 0,
            y: 0,
            width: 48,
            height: 32,
            encoding: CsrdEncoding.jpeg,
            data: gradientJpeg,
          ),
        ]),
      );
      expect(census.live, {compositor.value});
      compositor.dispose();
      expect(census.live, isEmpty);
    });

    test('a refused frame leaves nothing behind', () async {
      final compositor = FrameCompositor(presentation: immediately);
      await expectLater(
        compositor.apply(
          // The raw tile becomes an image before the JPEG fails.
          decoded(1, 96, 32, [
            CsrdRect(
              x: 48,
              y: 0,
              width: 48,
              height: 32,
              encoding: CsrdEncoding.raw,
              data: Uint8List(48 * 32 * 4),
            ),
            CsrdRect(
              x: 0,
              y: 0,
              width: 48,
              height: 32,
              encoding: CsrdEncoding.jpeg,
              data: Uint8List.fromList([0xff, 0xd8, 0, 0]),
            ),
          ]),
        ),
        throwsA(isA<CsrdCodecException>()),
      );
      expect(census.live, isEmpty);
      compositor.dispose();
    });

    test('disposing mid-frame leaks nothing and presents nothing', () async {
      final seen = <int>[];
      final compositor = FrameCompositor(
        presentation: immediately,
        onPresented: seen.add,
      );
      const w = 256, h = 128;
      final pending = compositor.apply(
        decoded(1, w, h, encodeLossless(textLikeScreen(w, h), w, h)),
      );
      compositor.dispose();
      await pending;
      expect(seen, isEmpty);
      expect(census.live, isEmpty);
    });
  });

  group('driving a client', () {
    test('acks a frame only once it has been presented', () async {
      final host = FakeHost();
      final client = CsrdClient(
        input: host.clientInput,
        output: host.clientOutput,
      );
      final presentation = ManualPresentation();
      final compositor = FrameCompositor(presentation: presentation.call);
      final frames = compositor.drive(client);
      final connecting = client.connect(
        CsrdConnectOptions(token: testToken, viewerName: 'test'),
      );
      await host.next<CsrdHello>();
      host.send(
        CsrdWelcome(
          version: csrdVersion,
          caps: csrdCapDeflate,
          displays: [testDisplay(0, primary: true)],
        ),
      );
      await connecting;
      host.send(
        CsrdFrame(
          seq: 1,
          width: 8,
          height: 8,
          rects: [fill(0, 0, 8, 8, 1, 2, 3)],
        ),
      );
      while (presentation.waiting == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(compositor.value, isNotNull);
      expect(host.all<CsrdFrameAck>(), isEmpty);
      presentation.presentAll();
      expect((await host.next<CsrdFrameAck>()).seq, 1);
      await frames.cancel();
      await client.close();
      compositor.dispose();
    });

    test('closes the session when a frame cannot be composited', () async {
      final host = FakeHost();
      final client = CsrdClient(
        input: host.clientInput,
        output: host.clientOutput,
      );
      final compositor = FrameCompositor(presentation: immediately);
      final frames = compositor.drive(client);
      final connecting = client.connect(
        CsrdConnectOptions(token: testToken, viewerName: 'test'),
      );
      await host.next<CsrdHello>();
      host.send(
        CsrdWelcome(
          version: csrdVersion,
          caps: csrdCapDeflate,
          displays: [testDisplay(0, primary: true)],
        ),
      );
      await connecting;
      host.send(
        CsrdFrame(
          seq: 1,
          width: 64,
          height: 64,
          rects: [
            CsrdRect(
              x: 0,
              y: 0,
              width: 64,
              height: 64,
              encoding: CsrdEncoding.jpeg,
              data: gradientJpeg,
            ),
          ],
        ),
      );
      final reason = await client.done.timeout(const Duration(seconds: 5));
      expect(reason.kind, CsrdCloseKind.error);
      expect(reason.text, contains('48x32 jpeg'));
      expect(host.all<CsrdFrameAck>(), isEmpty);
      await frames.cancel();
      compositor.dispose();
    });
  });

  testWidgets('the default presentation waits for a drawn frame', (
    tester,
  ) async {
    var drawn = false;
    unawaited(FrameCompositor.nextFrameDrawn().then((_) => drawn = true));
    await tester.idle();
    expect(drawn, isFalse);
    await tester.pump();
    expect(drawn, isTrue);
  });
}
