/// The Dart side checked against bytes the Rust side wrote.
///
/// `test/remote_desktop/fixtures/` is produced by CrossShell's
///
/// ```sh
/// cargo run -p crossshell-proto --example ssgo_fixtures -- <dir>
/// ```
///
/// and holds, per case `NAME`:
///
///  * `NAME.frames`: Frame messages back to back, encoded with
///    CAP_DEFLATE on, as an agent would send them;
///  * `NAME.bgrx`: the screen they add up to, tightly packed BGRX;
///  * `NAME.json`: `{width, height, quality, frames, exact,
///    maxMeanAbsError}`;
///
/// and once, `messages.bin` with every Message variant back to back and
/// `messages.json` describing each: `{kind, type, offset, length, fields}`,
/// with `msg.rs`'s field names and bytes as hex.
///
/// Frames are decoded on the CPU path (`CsrdTileDecoder`) into a CPU
/// framebuffer, and also composited on the GPU path (`FrameCompositor`),
/// and both are compared with `NAME.bgrx`: exactly for lossless cases,
/// within `maxMeanAbsError` for lossy ones. JPEG tiles are decoded with
/// `dart:ui`'s own codec, which runs headless under `flutter test`; it is
/// not the decoder the Rust side uses (zune-jpeg), so JPEG cases can only
/// ever match within the error bound.
///
/// A missing or empty fixtures directory fails, loudly, rather than
/// skipping: these are the only tests that pin the Dart port to the Rust
/// encoder's actual output.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/remote_desktop/csrd_messages.dart';
import 'package:secure_shell_go/services/remote_desktop/csrd_tiles.dart';
import 'package:secure_shell_go/widgets/remote_desktop/frame_compositor.dart';

import 'csrd_test_support.dart';

final fixtures = Directory('test/remote_desktop/fixtures');

const regenerate =
    'Generate them with `cargo run -p crossshell-proto --example '
    'ssgo_fixtures -- <secure_shell_go>/test/remote_desktop/fixtures` in '
    'CrossShell\'s engine/ directory.';

List<String> frameCases() {
  if (!fixtures.existsSync()) return const [];
  return [
    for (final f in fixtures.listSync().whereType<File>())
      if (f.path.endsWith('.json') && !f.path.endsWith('messages.json'))
        f.uri.pathSegments.last.replaceAll(RegExp(r'\.json$'), ''),
  ]..sort();
}

File fixture(String name) => File('${fixtures.path}/$name');

void main() {
  final cases = frameCases();

  test('the golden fixtures are there', () {
    expect(
      fixtures.existsSync(),
      isTrue,
      reason: '${fixtures.path} is missing. $regenerate',
    );
    expect(
      cases,
      isNotEmpty,
      reason: '${fixtures.path} has no frame cases. $regenerate',
    );
    for (final name in ['messages.bin', 'messages.json']) {
      expect(
        fixture(name).existsSync(),
        isTrue,
        reason: '${fixtures.path}/$name is missing. $regenerate',
      );
    }
  });

  for (final name in cases) {
    test('frames: $name', () => checkFrameCase(name));
  }

  if (fixture('messages.bin').existsSync()) {
    test('messages.bin decodes and re-encodes byte for byte', () {
      final bin = fixture('messages.bin').readAsBytesSync();
      final messages = readAll(bin);
      expect(messages, isNotEmpty);
      final again = BytesBuilder();
      for (final m in messages) {
        again.add(m.encode());
      }
      expect(again.takeBytes(), bin);
      // Every variant is there, Deflate rects included.
      final kinds = messages.map((m) => m.runtimeType).toSet();
      expect(kinds.length, greaterThanOrEqualTo(19), reason: '$kinds');
    });
  }

  if (fixture('messages.bin').existsSync() &&
      fixture('messages.json').existsSync()) {
    test('messages.json describes the same messages', () {
      final bin = fixture('messages.bin').readAsBytesSync();
      final described = describedMessages(
        fixture('messages.json').readAsStringSync(),
      );
      final messages = readAll(bin);
      expect(described.length, messages.length);
      var offset = 0;
      for (var i = 0; i < messages.length; i++) {
        final m = messages[i];
        final entry = (described[i] as Map).cast<String, Object?>();
        final path = 'messages.json[$i] (${entry['kind']})';
        expect(entry.keys.toSet(), {
          'kind',
          'type',
          'offset',
          'length',
          'fields',
        }, reason: path);
        expect(entry['kind'], variantName(m), reason: path);
        expect(entry['type'], m.kind, reason: path);
        expect(entry['offset'], offset, reason: path);
        expect(entry['length'], m.encode().length, reason: path);
        offset += m.encode().length;
        matchValue(entry['fields'], canonical(m), '$path.fields');
      }
    });
  }
}

List<CsrdMessage> readAll(Uint8List bytes) {
  final reader = CsrdMessageReader();
  final out = <CsrdMessage>[];
  // In socket-sized pieces, as they would arrive.
  const piece = 16 << 10;
  for (var at = 0; at < bytes.length; at += piece) {
    final end = at + piece < bytes.length ? at + piece : bytes.length;
    reader.add(Uint8List.sublistView(bytes, at, end));
    for (CsrdMessage? m; (m = reader.next()) != null;) {
      out.add(m!);
    }
  }
  expect(reader.bufferedBytes, 0, reason: 'trailing bytes');
  return out;
}

Future<void> checkFrameCase(String name) async {
  final meta = jsonDecode(fixture('$name.json').readAsStringSync()) as Map;
  final width = meta['width'] as int;
  final height = meta['height'] as int;
  final exact = meta['exact'] as bool;
  final bound = (meta['maxMeanAbsError'] as num).toDouble();
  final expected = fixture('$name.bgrx').readAsBytesSync();
  expect(expected.length, width * height * 4, reason: '$name.bgrx size');

  final messages = readAll(fixture('$name.frames').readAsBytesSync());
  expect(messages, everyElement(isA<CsrdFrame>()));
  expect(messages.length, meta['frames'], reason: 'frame count');
  final encodings = <String, int>{};
  for (final r in messages.cast<CsrdFrame>().expand((f) => f.rects)) {
    final key = encodingName(r.encoding);
    encodings[key] = (encodings[key] ?? 0) + 1;
  }
  expect(encodings, meta['encodings'], reason: '$name rect encodings');

  final cpu = CpuFramebuffer();
  final gpu = FrameCompositor(presentation: () async {});
  try {
    for (final m in messages.cast<CsrdFrame>()) {
      final frame = CsrdTileDecoder.decodeSync(m);
      final jpegs = <int, Uint8List>{};
      for (var i = 0; i < frame.tiles.length; i++) {
        final t = frame.tiles[i];
        if (t is CsrdJpegTile) jpegs[i] = await decodeJpeg(t);
      }
      cpu.apply(frame, jpegPixels: jpegs);
      await gpu.apply(frame);
    }
    expect((cpu.width, cpu.height), (width, height));
    expect((gpu.width, gpu.height), (width, height));
    final composited = await bgraOf(gpu.value!);

    for (final (path, got) in [('cpu', cpu.bgra), ('gpu', composited)]) {
      final error = meanAbsError(got, expected);
      // ignore: avoid_print
      print(
        '$name ($path): mean abs error ${error.toStringAsFixed(3)} '
        '(Rust\'s own decoder: ${meta['rustMeanAbsError']}, bound $bound)',
      );
      if (exact) {
        final at = firstColourDifference(got, expected);
        expect(
          at,
          -1,
          reason:
              '$name ($path): first wrong pixel at '
              '(${at % width}, ${at ~/ width})',
        );
      } else {
        expect(
          error,
          lessThanOrEqualTo(bound),
          reason: '$name ($path): mean abs error $error, bound $bound',
        );
      }
    }
  } finally {
    gpu.dispose();
  }
}

/// A JPEG tile's pixels, as BGRA, through `dart:ui`'s codec.
Future<Uint8List> decodeJpeg(CsrdJpegTile t) async {
  final codec = await ui.instantiateImageCodec(t.jpeg);
  final image = (await codec.getNextFrame()).image;
  codec.dispose();
  expect((image.width, image.height), (t.width, t.height));
  final px = await bgraOf(image);
  image.dispose();
  return px;
}

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

// ------------------------------------------------------ messages.json

/// The entries of `messages.json`.
///
/// Integers past 2⁶³ (a u64 `Pong`, say) do not fit Dart's int and would
/// come back from `jsonDecode` as a rounded double, so they are quoted
/// before decoding and compared as exact big integers.
List<Object?> describedMessages(String text) {
  final quoted = text.replaceAllMapped(
    RegExp(r'(?<=[\[:,]\s*)(\d{19,})(?=\s*[,\]\}])'),
    (m) => BigInt.parse(m[1]!) > BigInt.from(0x7fffffffffffffff)
        ? '"${m[1]}"'
        : m[1]!,
  );
  return jsonDecode(quoted) as List;
}

/// What a message looks like in `messages.json`: `msg.rs`'s field names,
/// bytes as hex.
Map<String, Object?> canonical(CsrdMessage m) => switch (m) {
  CsrdHello() => {
    'version': m.version,
    'token': csrdToHex(m.token),
    'viewer_name': m.viewerName,
    'caps': m.caps,
  },
  CsrdWelcome() => {
    'version': m.version,
    'caps': m.caps,
    'displays': [for (final d in m.displays) canonicalDisplay(d)],
  },
  CsrdReject() => {'reason': m.reason},
  CsrdStart() => {
    'display': m.display,
    'quality': m.quality,
    'max_fps': m.maxFps,
    'view_only': m.viewOnly,
  },
  CsrdSelectDisplay() => {
    'display': m.display,
    'quality': m.quality,
    'max_fps': m.maxFps,
  },
  CsrdFrame() => {
    'seq': m.seq,
    'width': m.width,
    'height': m.height,
    'rects': [
      for (final r in m.rects)
        {
          'x': r.x,
          'y': r.y,
          'w': r.width,
          'h': r.height,
          'encoding': r.encoding.wire,
          'encoding_name': encodingName(r.encoding),
          'data': csrdToHex(r.data),
        },
    ],
  },
  CsrdFrameAck() => {'seq': m.seq},
  CsrdCursorShape() => {
    'width': m.width,
    'height': m.height,
    'hot_x': m.hotX,
    'hot_y': m.hotY,
    'rgba': csrdToHex(m.rgba),
  },
  CsrdCursorPos() => {'x': m.x, 'y': m.y},
  CsrdDisplaysChanged() => {
    'displays': [for (final d in m.displays) canonicalDisplay(d)],
  },
  CsrdPointerMove() => {'x': m.x, 'y': m.y},
  CsrdPointerButton() => {'button': m.button, 'down': m.down},
  CsrdScroll() => {'dx': m.dx, 'dy': m.dy},
  CsrdKey() => {'code': m.code, 'down': m.down},
  CsrdReleaseAll() => {},
  CsrdClipboardText() => {'text': m.text},
  CsrdPing() => {'value': m.value},
  CsrdPong() => {'value': m.value},
  CsrdNotice() => {'level': m.level, 'text': m.text},
};

Map<String, Object?> canonicalDisplay(CsrdDisplayInfo d) => {
  'index': d.index,
  'name': d.name,
  'x': d.x,
  'y': d.y,
  'width': d.width,
  'height': d.height,
  'primary': d.primary,
};

/// The Rust variant's name, as `Encoding`'s Debug prints it.
String encodingName(CsrdEncoding e) =>
    e.name[0].toUpperCase() + e.name.substring(1);

String variantName(CsrdMessage m) =>
    m.runtimeType.toString().replaceFirst('Csrd', '');

/// [json] against [ours], exactly: maps must have the same keys, so a field
/// added on either side shows up here rather than going unchecked.
void matchValue(Object? json, Object? ours, String path) {
  switch (ours) {
    case Map():
      expect(json, isA<Map>(), reason: path);
      final map = json as Map;
      expect(map.keys.toSet(), ours.keys.toSet(), reason: '$path keys');
      for (final key in ours.keys) {
        matchValue(map[key], ours[key], '$path.$key');
      }
    case List():
      expect(json, isA<List>(), reason: path);
      final list = json as List;
      expect(list.length, ours.length, reason: '$path length');
      for (var i = 0; i < ours.length; i++) {
        matchValue(list[i], ours[i], '$path[$i]');
      }
    case int() when json is String:
      // A u64 past 2⁶³; see [describedMessages].
      expect(
        BigInt.parse(json),
        BigInt.from(ours).toUnsigned(64),
        reason: path,
      );
    default:
      expect(json, ours, reason: path);
  }
}
