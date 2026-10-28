import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/remote_desktop/csrd_messages.dart';

import 'csrd_test_support.dart';

/// One of every message, with values that exercise each field's range: the
/// same set `msg.rs`'s `every_message_round_trips` uses, plus Deflate.
List<CsrdMessage> everyMessage() => [
  CsrdHello(
    version: 1,
    token: testToken,
    viewerName: 'linux-pc',
    caps: 0xdeadbeef,
  ),
  CsrdWelcome(
    version: 1,
    caps: 3,
    displays: [testDisplay(0, primary: true), testDisplay(1)],
  ),
  const CsrdReject('bad token'),
  const CsrdStart(display: 1, quality: 2, maxFps: 30, viewOnly: true),
  const CsrdSelectDisplay(display: 0, quality: 1, maxFps: 60),
  CsrdFrame(
    seq: 9,
    width: 1920,
    height: 1080,
    rects: [
      CsrdRect(
        x: 0,
        y: 64,
        width: 64,
        height: 64,
        encoding: CsrdEncoding.fill,
        data: Uint8List.fromList([1, 2, 3, 0]),
      ),
      CsrdRect(
        x: 64,
        y: 0,
        width: 2,
        height: 1,
        encoding: CsrdEncoding.raw,
        data: Uint8List.fromList(List.filled(8, 9)),
      ),
      CsrdRect(
        x: 128,
        y: 0,
        width: 1,
        height: 1,
        encoding: CsrdEncoding.deflate,
        data: Uint8List.fromList([0x78, 0x9c, 1, 2]),
      ),
    ],
  ),
  const CsrdFrameAck(0xffffffff),
  CsrdCursorShape(
    width: 2,
    height: 2,
    hotX: 1,
    hotY: 0,
    rgba: Uint8List.fromList(List.filled(16, 255)),
  ),
  CsrdCursorShape(width: 0, height: 0, hotX: 0, hotY: 0, rgba: Uint8List(0)),
  const CsrdCursorPos(-5, 700),
  CsrdDisplaysChanged([testDisplay(3)]),
  const CsrdPointerMove(10, 20),
  const CsrdPointerButton(CsrdButton.right, down: true),
  const CsrdScroll(-120, 240),
  const CsrdKey(30, down: false),
  const CsrdReleaseAll(),
  const CsrdClipboardText('héllo\nworld'),
  const CsrdPing(123456789),
  // u64::MAX: the bit pattern survives, as -1.
  const CsrdPong(-1),
  const CsrdNotice(CsrdNoticeLevel.warn, 'screen locked'),
];

CsrdMessage roundTrip(CsrdMessage m) {
  final bytes = m.encode();
  final reader = CsrdMessageReader()..add(bytes);
  final back = reader.next()!;
  expect(reader.next(), isNull);
  expect(reader.bufferedBytes, 0);
  return back;
}

Uint8List payloadOf(CsrdMessage m) => Uint8List.sublistView(m.encode(), 5);

void main() {
  group('every message', () {
    test('round-trips to an equal message and the same bytes', () {
      for (final m in everyMessage()) {
        final back = roundTrip(m);
        expect(back, m, reason: '$m');
        expect(back.encode(), m.encode(), reason: '$m');
      }
    });

    test('has a distinct type byte', () {
      final kinds = everyMessage().map((m) => m.kind).toSet();
      // Two CursorShapes in the list.
      expect(kinds.length, everyMessage().length - 1);
    });
  });

  group('byte layout', () {
    test('header is type, then little-endian payload length', () {
      expect(const CsrdKey(30, down: true).encode(), [
        0x33, 3, 0, 0, 0, //
        30, 0, 1,
      ]);
      expect(const CsrdReleaseAll().encode(), [0x34, 0, 0, 0, 0]);
    });

    test('hello is magic, version, token, name, caps', () {
      final b = CsrdHello(
        version: 1,
        token: testToken,
        viewerName: 'ab',
        caps: csrdCapDeflate,
      ).encode();
      expect(b.sublist(0, 5), [0x01, 46, 0, 0, 0]);
      expect(ascii.decode(b.sublist(5, 9)), 'CSRD');
      expect(b.sublist(9, 11), [1, 0]);
      expect(b.sublist(11, 43), testToken);
      expect(b.sublist(43, 45), [2, 0]);
      expect(ascii.decode(b.sublist(45, 47)), 'ab');
      expect(b.sublist(47), [1, 0, 0, 0]);
    });

    test('signed fields are two’s complement', () {
      expect(payloadOf(const CsrdCursorPos(-1, -2)), [
        0xff, 0xff, 0xff, 0xff, //
        0xfe, 0xff, 0xff, 0xff,
      ]);
      expect(payloadOf(const CsrdScroll(-120, 1)), [0x88, 0xff, 1, 0]);
      expect(payloadOf(const CsrdPing(-1)), List.filled(8, 0xff));
    });

    test('a rect is x, y, w, h, encoding, length, data', () {
      final p = payloadOf(
        CsrdFrame(
          seq: 1,
          width: 2,
          height: 3,
          rects: [
            CsrdRect(
              x: 1,
              y: 2,
              width: 3,
              height: 4,
              encoding: CsrdEncoding.deflate,
              data: Uint8List.fromList([0xaa]),
            ),
          ],
        ),
      );
      expect(p, [
        1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0, // seq, width, height
        1, 0, // rect count
        1, 0, 2, 0, 3, 0, 4, 0, 4, // x y w h, Deflate
        1, 0, 0, 0, 0xaa,
      ]);
    });

    test('a display is index, name, x, y, w, h, primary', () {
      final p = payloadOf(
        const CsrdDisplaysChanged([
          CsrdDisplayInfo(
            index: 2,
            name: 'A',
            x: -1,
            y: 1,
            width: 3,
            height: 4,
            primary: true,
          ),
        ]),
      );
      expect(p, [
        1, // count
        2, 1, 0, 0x41, //
        0xff, 0xff, 0xff, 0xff, 1, 0, 0, 0, //
        3, 0, 0, 0, 4, 0, 0, 0, 1,
      ]);
    });

    test('clipboard text is unprefixed utf-8', () {
      expect(payloadOf(const CsrdClipboardText('é')), [0xc3, 0xa9]);
    });

    test('long strings are cut on a character boundary', () {
      final m = CsrdReject('é' * 40000); // 80000 bytes
      final back = roundTrip(m) as CsrdReject;
      expect(utf8.encode(back.reason).length, lessThanOrEqualTo(0xffff));
      expect(back.reason, 'é' * (0xffff ~/ 2));
    });

    test('display and rect counts are capped at their field widths', () {
      final displays = List.generate(300, (i) => testDisplay(i & 0xff));
      final back =
          roundTrip(CsrdWelcome(version: 1, caps: 0, displays: displays))
              as CsrdWelcome;
      expect(back.displays.length, 255);
    });
  });

  group('hostile input', () {
    test('an oversized payload is refused from its header alone', () {
      final reader = CsrdMessageReader(maxPayload: csrdMaxPreauthPayload)
        ..add([CsrdKind.hello, 0x10, 0x27, 0, 0]); // 10000 bytes
      expect(reader.next, throwsA(isA<CsrdProtocolException>()));
      // And stays refused: there is no telling where the next message is.
      expect(reader.next, throwsA(isA<CsrdProtocolException>()));
    });

    test('the limit never exceeds MAX_PAYLOAD', () {
      final reader = CsrdMessageReader(maxPayload: 1 << 40);
      expect(reader.maxPayload, csrdMaxPayload);
      reader.add([CsrdKind.frame, 1, 0, 0, 4]); // 64 MiB + 1
      expect(reader.next, throwsA(isA<CsrdProtocolException>()));
    });

    test('a 64 MiB header costs nothing until the bytes arrive', () {
      final reader = CsrdMessageReader()..add([CsrdKind.frame, 0, 0, 0, 4]);
      expect(reader.next(), isNull);
      expect(reader.bufferedBytes, 5);
    });

    test('truncated and trailing payloads are errors', () {
      final full = payloadOf(const CsrdKey(1, down: true));
      expect(
        () => CsrdMessage.decode(
          CsrdKind.key,
          Uint8List.sublistView(full, 0, full.length - 1),
        ),
        throwsA(isA<CsrdProtocolException>()),
      );
      expect(
        () =>
            CsrdMessage.decode(CsrdKind.key, Uint8List.fromList([...full, 0])),
        throwsA(isA<CsrdProtocolException>()),
      );
      expect(
        () => CsrdMessage.decode(0xee, Uint8List(0)),
        throwsA(isA<CsrdProtocolException>()),
      );
    });

    test('a hostile rect count is refused before allocating', () {
      final p = ByteData(14)
        ..setUint32(0, 1, Endian.little)
        ..setUint32(4, 1, Endian.little)
        ..setUint32(8, 1, Endian.little)
        ..setUint16(12, 0xffff, Endian.little);
      expect(
        () => CsrdMessage.decode(CsrdKind.frame, p.buffer.asUint8List()),
        throwsA(isA<CsrdProtocolException>()),
      );
    });

    test('a rect longer than the payload is refused', () {
      final p = payloadOf(
        CsrdFrame(
          seq: 1,
          width: 1,
          height: 1,
          rects: [
            CsrdRect(
              x: 0,
              y: 0,
              width: 1,
              height: 1,
              encoding: CsrdEncoding.raw,
              data: Uint8List(4),
            ),
          ],
        ),
      );
      // Claim 2 GiB of data in the rect's length field.
      p[23] = 0;
      p[24] = 0;
      p[25] = 0;
      p[26] = 0x80;
      expect(
        () => CsrdMessage.decode(CsrdKind.frame, p),
        throwsA(isA<CsrdProtocolException>()),
      );
    });

    test('unknown rect encodings are refused', () {
      final p = payloadOf(everyMessage()[5]);
      p[22] = 9; // the first rect's encoding byte
      expect(
        () => CsrdMessage.decode(CsrdKind.frame, p),
        throwsA(
          isA<CsrdProtocolException>().having(
            (e) => e.message,
            'message',
            contains('encoding 9'),
          ),
        ),
      );
    });

    test('cursors over 256 × 256 are refused', () {
      final p = ByteData(8)
        ..setUint16(0, 257, Endian.little)
        ..setUint16(2, 1, Endian.little);
      expect(
        () => CsrdMessage.decode(CsrdKind.cursorShape, p.buffer.asUint8List()),
        throwsA(isA<CsrdProtocolException>()),
      );
    });

    test('a cursor with fewer pixels than it claims is refused', () {
      final p = payloadOf(everyMessage()[7]);
      expect(
        () => CsrdMessage.decode(
          CsrdKind.cursorShape,
          Uint8List.sublistView(p, 0, p.length - 1),
        ),
        throwsA(isA<CsrdProtocolException>()),
      );
    });

    test('bad magic is refused', () {
      final b = CsrdHello(
        version: 1,
        token: testToken,
        viewerName: '',
        caps: 0,
      ).encode();
      b[5] = 0x58;
      expect(
        () => (CsrdMessageReader()..add(b)).next(),
        throwsA(isA<CsrdProtocolException>()),
      );
    });

    test('invalid utf-8 is refused in strings and clipboard text', () {
      expect(
        () => CsrdMessage.decode(
          CsrdKind.reject,
          Uint8List.fromList([2, 0, 0xc3, 0x28]),
        ),
        throwsA(isA<CsrdProtocolException>()),
      );
      expect(
        () => CsrdMessage.decode(
          CsrdKind.clipboardText,
          Uint8List.fromList([0xff]),
        ),
        throwsA(isA<CsrdProtocolException>()),
      );
    });

    test('clipboard text over 1 MiB is refused', () {
      final big = Uint8List(csrdMaxClipboard + 1)..fillRange(0, 10, 0x41);
      expect(
        () => CsrdMessage.decode(CsrdKind.clipboardText, big),
        throwsA(isA<CsrdProtocolException>()),
      );
    });

    test('garbage only ever throws CsrdProtocolException', () {
      // The deterministic fuzz `msg.rs` runs, over every type byte.
      var seed = 0x12345678;
      int next() {
        seed ^= (seed << 13) & 0xffffffff;
        seed ^= seed >> 17;
        seed ^= (seed << 5) & 0xffffffff;
        return seed;
      }

      for (var i = 0; i < 20000; i++) {
        final kind = next() & 0x7f;
        final len = next() % 96;
        final payload = Uint8List.fromList([
          for (var j = 0; j < len; j++) next() & 0xff,
        ]);
        try {
          CsrdMessage.decode(kind, payload);
        } on CsrdProtocolException {
          // Expected for most of it.
        }
      }
    });

    test('a decode error consumes the bad message and reading goes on', () {
      final bad = [CsrdKind.key, 1, 0, 0, 0, 0]; // one byte short of a key
      final good = const CsrdPing(5).encode();
      final reader = CsrdMessageReader()
        ..add(bad)
        ..add(good);
      expect(reader.next, throwsA(isA<CsrdProtocolException>()));
      expect(reader.next(), const CsrdPing(5));
    });
  });

  group('reader', () {
    final stream = [for (var round = 0; round < 3; round++) ...everyMessage()];
    final bytes = Uint8List.fromList([for (final m in stream) ...m.encode()]);

    List<CsrdMessage> readChunked(List<int> sizes) {
      final reader = CsrdMessageReader();
      final out = <CsrdMessage>[];
      var at = 0;
      var k = 0;
      while (at < bytes.length) {
        final n = min(sizes[k++ % sizes.length], bytes.length - at);
        reader.add(Uint8List.sublistView(bytes, at, at + n));
        at += n;
        for (CsrdMessage? m; (m = reader.next()) != null;) {
          out.add(m!);
        }
      }
      expect(reader.bufferedBytes, 0);
      return out;
    }

    test('survives a byte at a time', () {
      expect(readChunked([1]), stream);
    });

    test('survives random chunk boundaries', () {
      final random = Random(42);
      for (var trial = 0; trial < 200; trial++) {
        final sizes = List.generate(
          16,
          (_) => 1 + random.nextInt(random.nextBool() ? 8 : 400),
        );
        expect(readChunked(sizes), stream, reason: 'chunk sizes $sizes');
      }
    });

    test('takes everything at once', () {
      expect(readChunked([bytes.length]), stream);
    });

    test('enforces its limit', () {
      final reader = CsrdMessageReader(maxPayload: 10)
        ..add(CsrdClipboardText('x' * 100).encode());
      expect(reader.next, throwsA(isA<CsrdProtocolException>()));
    });

    test('leaves the chunks it was given untouched', () {
      final chunk = Uint8List.fromList(bytes);
      final reader = CsrdMessageReader()..add(chunk);
      while (reader.next() != null) {}
      expect(chunk, bytes);
    });
  });

  group('hex', () {
    test('round-trips, either case, trimmed', () {
      final b = [0, 1, 0xab, 0xff, 0x10];
      expect(csrdToHex(b), '0001abff10');
      expect(csrdFromHex(csrdToHex(b)), b);
      expect(csrdFromHex(' 0A \n'), [0x0a]);
      expect(csrdFromHex('abc'), isNull);
      expect(csrdFromHex('zz'), isNull);
    });
  });
}
