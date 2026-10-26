import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/remote_desktop/csrd_tiles.dart';
import 'package:secure_shell_go/services/remote_desktop/rfb_client.dart';
import 'package:secure_shell_go/services/remote_desktop/rfb_protocol.dart';
import 'package:secure_shell_go/widgets/remote_desktop/frame_compositor.dart';

import 'csrd_test_support.dart' show CpuFramebuffer;
import 'rfb_test_support.dart';

/// The image's pixels as BGRA.
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

Future<void> immediately() async {}

CsrdDecodedFrame frame(int seq, int w, int h, List<CsrdTile> tiles) =>
    CsrdDecodedFrame(seq: seq, width: w, height: h, tiles: tiles, wireBytes: 0);

CsrdPixelTile pixels(Picture p, int x, int y, int w, int h) =>
    CsrdPixelTile(x, y, w, h, p.sub(x, y, w, h).bgra);

/// Applies [frames] to a compositor and to the CPU reference, and checks
/// they agree after each.
Future<Uint8List> both(List<CsrdDecodedFrame> frames) async {
  final compositor = FrameCompositor(presentation: immediately);
  final cpu = CpuFramebuffer();
  late Uint8List got;
  for (final f in frames) {
    await compositor.apply(f);
    cpu.apply(f);
    got = await bgraOf(compositor.value!);
    expect(firstDifference(got, cpu.bgra), -1, reason: 'frame ${f.seq}');
    for (var i = 3; i < got.length; i += 4) {
      expect(got[i], 0xff);
    }
  }
  compositor.dispose();
  return got;
}

void main() {
  const w = 64, h = 48;
  final first = busyPicture(w, h, seed: 4);

  test('a copy reads the screen as it was before the frame', () async {
    final got = await both([
      frame(1, w, h, [pixels(first, 0, 0, w, h)]),
      frame(2, w, h, [
        const CsrdFillTile(0, 0, 16, 16, 0xff102030),
        const CsrdCopyTile(32, 0, 16, 16, srcX: 0, srcY: 0),
      ]),
    ]);
    final want = Picture(w, h)
      ..blit(0, 0, first)
      ..copyRect(0, 0, 16, 16, 32, 0)
      ..fillRect(0, 0, 16, 16, 0x102030);
    expect(firstDifference(got, want.bgra), -1);
  });

  test('overlapping source and destination: a scroll', () async {
    final got = await both([
      frame(1, w, h, [pixels(first, 0, 0, w, h)]),
      frame(2, w, h, [
        const CsrdCopyTile(0, 0, w, h - 8, srcX: 0, srcY: 8),
        const CsrdFillTile(0, h - 8, w, 8, 0xff000000),
      ]),
    ]);
    final want = Picture(w, h)
      ..blit(0, 0, first.sub(0, 8, w, h - 8))
      ..fillRect(0, h - 8, w, 8, 0);
    expect(firstDifference(got, want.bgra), -1);
  });

  test('a frame covering the screen, copies included, still reads the '
      'previous screen', () async {
    final second = busyPicture(w, h, seed: 5);
    final got = await both([
      frame(1, w, h, [pixels(first, 0, 0, w, h)]),
      frame(2, w, h, [
        const CsrdCopyTile(32, 0, 32, h, srcX: 0, srcY: 0),
        pixels(second, 0, 0, 32, h),
      ]),
    ]);
    final want = Picture(w, h)
      ..blit(32, 0, first.sub(0, 0, 32, h))
      ..blit(0, 0, second.sub(0, 0, 32, h));
    expect(firstDifference(got, want.bgra), -1);
  });

  test('with nothing before it, a copy is of black', () async {
    final got = await both([
      frame(1, w, h, [
        const CsrdFillTile(0, 0, 8, 8, 0xffffffff),
        const CsrdCopyTile(8, 0, 8, 8, srcX: 0, srcY: 0),
      ]),
      // A size change starts from black too.
      frame(2, 32, 32, [const CsrdCopyTile(0, 0, 8, 8, srcX: 8, srcY: 8)]),
    ]);
    expect(got.sublist(0, 4), [0, 0, 0, 0xff]);
  });

  test('copy tiles leave no images behind', () async {
    final live = <ui.Image>{};
    ui.Image.onCreate = live.add;
    ui.Image.onDispose = live.remove;
    try {
      final compositor = FrameCompositor(presentation: immediately);
      await compositor.apply(frame(1, w, h, [pixels(first, 0, 0, w, h)]));
      for (var seq = 2; seq < 6; seq++) {
        await compositor.apply(
          frame(seq, w, h, [
            CsrdCopyTile(seq, 0, 16, 16, srcX: 0, srcY: seq),
            pixels(first, 40, 30, 8, 8),
          ]),
        );
        expect(live, {compositor.value});
      }
      compositor.dispose();
      expect(live, isEmpty);
    } finally {
      ui.Image.onCreate = null;
      ui.Image.onDispose = null;
    }
  });

  test('driving an RfbClient: split updates land as RFB means them, and '
      'each request waits for the screen', () async {
    final server = FakeRfbServer();
    final client = RfbClient(
      input: server.clientInput,
      output: server.clientOutput,
      timing: const RfbTiming(closeFlushTimeout: Duration(milliseconds: 50)),
    );
    final presented = <int>[];
    final compositor = FrameCompositor(
      presentation: immediately,
      onPresented: presented.add,
    );
    final frames = compositor.drive(client);
    final connecting = client.connect(credentials: (_) async => null);
    await server.handshakeNone(width: w, height: h);
    await connecting;
    await server.next<UpdateRequestMsg>();

    final z = ZrleEncoder();
    final model = Picture(w, h)..blit(0, 0, first);
    server.send([
      ...updateHeader(1),
      ...z.wireRect(model, 0, 0, w, h, choose: mixedSub),
    ]);
    expect((await server.next<UpdateRequestMsg>()).incremental, isTrue);

    final patch = busyPicture(20, 20, seed: 9);
    model
      ..blit(10, 10, patch)
      ..copyRect(0, 0, 30, 30, 34, 18) // reads the patch: a second frame
      ..copyRect(34, 18, 30, 30, 0, 0); // reads that copy: a third
    server.send([
      ...updateHeader(3),
      ...rectHeader(10, 10, 20, 20, RfbEncoding.raw),
      ...patch.rawWire(),
      ...rectHeader(34, 18, 30, 30, RfbEncoding.copyRect),
      ...be16(0),
      ...be16(0),
      ...rectHeader(0, 0, 30, 30, RfbEncoding.copyRect),
      ...be16(34),
      ...be16(18),
    ]);
    await server.next<UpdateRequestMsg>();
    expect(presented, [1, 2, 3, 4]);
    final got = await bgraOf(compositor.value!);
    expect(firstDifference(got, model.bgra), -1);

    await frames.cancel();
    await client.close();
    await server.hangUp();
    compositor.dispose();
  });
}
