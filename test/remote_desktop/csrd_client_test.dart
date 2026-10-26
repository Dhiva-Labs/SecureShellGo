import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/remote_desktop/csrd_client.dart';
import 'package:secure_shell_go/services/remote_desktop/csrd_messages.dart';
import 'package:secure_shell_go/services/remote_desktop/csrd_tiles.dart';

import 'csrd_test_support.dart';

const fast = CsrdTiming(
  waitingNoticeAfter: Duration(milliseconds: 80),
  handshakeTimeout: Duration(milliseconds: 400),
  pingEvery: Duration(milliseconds: 40),
  deadAfter: Duration(milliseconds: 250),
  closeFlushTimeout: Duration(milliseconds: 100),
);

/// A host's Welcome: display 0, and display 1 as the primary.
CsrdWelcome welcome({int caps = csrdCapDeflate, int version = csrdVersion}) =>
    CsrdWelcome(
      version: version,
      caps: caps,
      displays: [testDisplay(0), testDisplay(1, primary: true)],
    );

CsrdFrame fillFrame(int seq, {int width = 64, int height = 64, int b = 0}) =>
    CsrdFrame(
      seq: seq,
      width: width,
      height: height,
      rects: [
        CsrdRect(
          x: 0,
          y: 0,
          width: width,
          height: height,
          encoding: CsrdEncoding.fill,
          data: Uint8List.fromList([b, 0, 0, 0]),
        ),
      ],
    );

/// A client against a [FakeHost], with every event recorded.
class Harness {
  Harness({CsrdTiming timing = fast, CsrdFrameDecoder? decode}) {
    client = CsrdClient(
      input: host.clientInput,
      output: host.clientOutput,
      timing: timing,
      decode: decode,
    );
    client.events.listen(events.add);
  }

  final host = FakeHost();
  late final CsrdClient client;
  final events = <CsrdEvent>[];

  Future<void> connect({
    int display = 0,
    bool viewOnly = false,
    CsrdWelcome? reply,
    String name = 'pixel-9',
  }) async {
    final connecting = client.connect(
      CsrdConnectOptions(
        token: testToken,
        viewerName: name,
        display: display,
        quality: CsrdQuality.speed,
        maxFps: 45,
        viewOnly: viewOnly,
      ),
    );
    await host.next<CsrdHello>();
    host.send(reply ?? welcome());
    await connecting;
    await host.next<CsrdStart>();
  }

  /// Waits until an event of type [T] has been recorded.
  Future<T> event<T extends CsrdEvent>() async {
    for (var i = 0; i < 200; i++) {
      final found = events.whereType<T>();
      if (found.isNotEmpty) return found.first;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    throw TimeoutException('no $T in $events');
  }

  List<T> all<T extends CsrdEvent>() => events.whereType<T>().toList();
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  group('handshake', () {
    test('hello carries the token, the name and CAP_DEFLATE', () async {
      final h = Harness();
      unawaited(
        h.client
            .connect(
              CsrdConnectOptions(token: testToken, viewerName: 'pixel-9'),
            )
            .catchError((_) {}),
      );
      final hello = await h.host.next<CsrdHello>();
      expect(hello.version, csrdVersion);
      expect(hello.token, testToken);
      expect(hello.viewerName, 'pixel-9');
      expect(hello.caps, csrdCapDeflate);
      await h.client.close();
    });

    test('a long viewer name is cut to what fits before auth', () async {
      final h = Harness();
      unawaited(
        h.client
            .connect(
              CsrdConnectOptions(token: testToken, viewerName: '名' * 5000),
            )
            .catchError((_) {}),
      );
      final hello = await h.host.next<CsrdHello>();
      expect(hello.viewerName, '名' * 64);
      expect(hello.encode().length, lessThan(csrdMaxPreauthPayload));
      await h.client.close();
    });

    test('starts the asked-for display with the asked-for settings', () async {
      final h = Harness();
      await h.connect(display: 0);
      final start = h.host.all<CsrdStart>().single;
      expect(
        start,
        const CsrdStart(display: 0, quality: 2, maxFps: 45, viewOnly: false),
      );
      final connected = await h.event<CsrdConnectedEvent>();
      expect(connected.display, 0);
      expect(connected.displays.length, 2);
      expect(connected.caps, csrdCapDeflate);
      expect(h.client.state, CsrdClientState.connected);
      expect(h.client.display, 0);
      await h.client.close();
    });

    test('falls back to the primary when the display is not there', () async {
      final h = Harness();
      await h.connect(display: 9);
      expect(h.host.all<CsrdStart>().single.display, 1);
      expect(h.client.display, 1);
      await h.client.close();
    });

    test('pings right away and then on schedule', () async {
      final h = Harness();
      await h.connect();
      await h.host.next<CsrdPing>();
      await h.host.next<CsrdPing>();
      await h.client.close();
    });

    Future<CsrdCloseReason> failedConnect(
      Harness h,
      FutureOr<void> Function(FakeHost host) act,
    ) async {
      final connecting = h.client.connect(
        CsrdConnectOptions(token: testToken, viewerName: 'x'),
      );
      await h.host.next<CsrdHello>();
      await act(h.host);
      try {
        await connecting;
        fail('connect() should have thrown');
      } on CsrdConnectException catch (e) {
        expect(await h.client.done, e.reason);
        expect(h.all<CsrdClosedEvent>().single.reason, e.reason);
        expect(h.client.state, CsrdClientState.closed);
        return e.reason;
      }
    }

    test('an agent without CAP_DEFLATE is refused, clearly', () async {
      final h = Harness();
      final reason = await failedConnect(
        h,
        (host) => host.send(welcome(caps: 0)),
      );
      expect(reason.kind, CsrdCloseKind.error);
      expect(reason.text, contains('too old'));
      expect(reason.text, contains('deflate'));
      // No Start: the agent never begins capturing for a viewer it cannot
      // serve.
      await h.host.clientClosed;
      expect(h.host.all<CsrdStart>(), isEmpty);
    });

    test('a reject is reported with its reason', () async {
      final h = Harness();
      final reason = await failedConnect(
        h,
        (host) => host.send(const CsrdReject('bad token')),
      );
      expect(reason.text, contains('bad token'));
    });

    test('another protocol version is refused', () async {
      final h = Harness();
      final reason = await failedConnect(
        h,
        (host) => host.send(welcome(version: 2)),
      );
      expect(reason.text, contains('version 2'));
    });

    test('a host with no displays is refused', () async {
      final h = Harness();
      final reason = await failedConnect(
        h,
        (host) => host.send(
          const CsrdWelcome(version: 1, caps: csrdCapDeflate, displays: []),
        ),
      );
      expect(reason.text, contains('no displays'));
    });

    test('anything but a welcome first is refused', () async {
      final h = Harness();
      final reason = await failedConnect(h, (host) => host.send(fillFrame(1)));
      expect(reason.text, contains('instead of welcome'));
    });

    test('an oversized welcome is refused from its header', () async {
      final h = Harness();
      final reason = await failedConnect(
        h,
        (host) => host.sendBytes([CsrdKind.welcome, 0, 0, 0, 1]), // 16 MiB
      );
      expect(reason.text, contains('exceeds limit'));
    });

    test('a hang-up before answering is reported as such', () async {
      final h = Harness();
      final reason = await failedConnect(h, (host) => host.hangUp());
      expect(reason.text, contains('before answering'));
    });

    test('a slow welcome says so, then times out', () async {
      final h = Harness();
      final reason = await failedConnect(
        h,
        (host) => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      expect(h.all<CsrdWaitingEvent>(), hasLength(1));
      expect(reason.text, contains('did not answer'));
    });

    test('a welcome after the waiting notice still connects', () async {
      final h = Harness();
      final connecting = h.client.connect(
        CsrdConnectOptions(token: testToken, viewerName: 'x'),
      );
      await h.host.next<CsrdHello>();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      h.host.send(welcome());
      await connecting;
      expect(
        h.events.map((e) => e.runtimeType),
        containsAllInOrder([CsrdWaitingEvent, CsrdConnectedEvent]),
      );
      await h.client.close();
    });

    test('closing while waiting is a local close', () async {
      final h = Harness();
      final connecting = h.client.connect(
        CsrdConnectOptions(token: testToken, viewerName: 'x'),
      );
      await h.host.next<CsrdHello>();
      await h.client.close();
      await expectLater(
        connecting,
        throwsA(
          isA<CsrdConnectException>().having(
            (e) => e.reason.kind,
            'kind',
            CsrdCloseKind.local,
          ),
        ),
      );
    });

    test('a token of the wrong length is refused before anything is sent', () {
      final h = Harness();
      expect(
        () => h.client.connect(
          CsrdConnectOptions(token: Uint8List(31), viewerName: 'x'),
        ),
        throwsArgumentError,
      );
    });
  });

  group('frames and flow control', () {
    test('frames arrive decoded and are acknowledged on request', () async {
      final h = Harness();
      await h.connect();
      h.host.send(fillFrame(1, b: 5));
      final event = await h.event<CsrdFrameEvent>();
      expect(event.frame.seq, 1);
      expect((event.frame.tiles.single as CsrdFillTile).color, 0xff000005);
      expect(h.client.unackedFrames, 1);
      expect(h.host.all<CsrdFrameAck>(), isEmpty);
      h.client.ackFrame(1);
      expect((await h.host.next<CsrdFrameAck>()).seq, 1);
      expect(h.client.unackedFrames, 0);
      await h.client.close();
    });

    test(
      'an ack covers the frames before it, and stale ones are ignored',
      () async {
        final h = Harness();
        await h.connect();
        h.host
          ..send(fillFrame(1))
          ..send(fillFrame(2));
        await settle();
        h.client
          ..ackFrame(2)
          ..ackFrame(1)
          ..ackFrame(2)
          ..ackFrame(77);
        await settle();
        expect(h.host.all<CsrdFrameAck>(), [const CsrdFrameAck(2)]);
        expect(h.client.unackedFrames, 0);
        await h.client.close();
      },
    );

    test('two frames in flight are fine, a third ends the session', () async {
      final h = Harness();
      await h.connect();
      h.host
        ..send(fillFrame(1))
        ..send(fillFrame(2));
      await settle();
      expect(h.client.state, CsrdClientState.connected);
      h.host.send(fillFrame(3));
      final reason = await h.client.done;
      expect(reason.kind, CsrdCloseKind.error);
      expect(reason.text, contains('without waiting'));
    });

    test('a host that waits for acks can stream indefinitely', () async {
      final h = Harness();
      await h.connect();
      for (var seq = 1; seq <= 20; seq++) {
        h.host.send(fillFrame(seq, b: seq));
        if (seq >= 2) {
          // Like the agent: frame n+1 only once frame n-1 is acknowledged.
          await h.host.next<CsrdFrameAck>();
        }
        final frames = h.all<CsrdFrameEvent>();
        while (frames.length < seq) {
          await settle();
          frames
            ..clear()
            ..addAll(h.all<CsrdFrameEvent>());
        }
        h.client.ackFrame(seq);
      }
      expect(h.all<CsrdFrameEvent>().map((e) => e.frame.seq), [
        for (var i = 1; i <= 20; i++) i,
      ]);
      expect(h.client.state, CsrdClientState.connected);
      await h.client.close();
    });

    test(
      'frames come out in order however long each takes to decode',
      () async {
        final h = Harness(
          decode: (frame) async {
            // The first frame is the slow one.
            await Future<void>.delayed(
              Duration(milliseconds: frame.seq == 1 ? 60 : 0),
            );
            return CsrdTileDecoder.decodeSync(frame);
          },
        );
        await h.connect();
        h.host
          ..send(fillFrame(1))
          ..send(fillFrame(2));
        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(h.all<CsrdFrameEvent>().map((e) => e.frame.seq), [1, 2]);
        await h.client.close();
      },
    );

    test('a frame that does not decode ends the session', () async {
      final h = Harness();
      await h.connect();
      h.host.send(
        CsrdFrame(
          seq: 1,
          width: 64,
          height: 64,
          rects: [
            CsrdRect(
              x: 60,
              y: 0,
              width: 10,
              height: 1,
              encoding: CsrdEncoding.fill,
              data: Uint8List(4),
            ),
          ],
        ),
      );
      final reason = await h.client.done;
      expect(reason.text, contains('bad frame'));
      expect(reason.text, contains('outside'));
      expect(h.all<CsrdFrameEvent>(), isEmpty);
    });

    test(
      'big frames decode off the calling isolate and still arrive',
      () async {
        final h = Harness();
        await h.connect();
        const w = 640, h2 = 360;
        final image = textLikeScreen(w, h2);
        h.host.send(
          CsrdFrame(
            seq: 1,
            width: w,
            height: h2,
            rects: encodeLossless(image, w, h2),
          ),
        );
        final event = await h.event<CsrdFrameEvent>();
        final fb = CpuFramebuffer()..apply(event.frame);
        expect(firstColourDifference(fb.bgra, image), -1);
        await h.client.close();
      },
    );
  });

  group('messages from the agent', () {
    test('become events', () async {
      final h = Harness();
      await h.connect();
      h.host
        ..send(
          CsrdCursorShape(
            width: 1,
            height: 1,
            hotX: 0,
            hotY: 0,
            rgba: Uint8List.fromList([1, 2, 3, 4]),
          ),
        )
        ..send(const CsrdCursorPos(-3, 9))
        ..send(CsrdDisplaysChanged([testDisplay(4, primary: true)]))
        ..send(const CsrdNotice(CsrdNoticeLevel.warn, 'screen locked'))
        ..send(const CsrdClipboardText('copied over there'));
      await h.event<CsrdClipboardEvent>();
      expect(h.all<CsrdCursorShapeEvent>().single.shape.rgba, [1, 2, 3, 4]);
      final pos = h.all<CsrdCursorPosEvent>().single;
      expect((pos.x, pos.y), (-3, 9));
      expect(h.all<CsrdDisplaysEvent>().single.displays.single.index, 4);
      expect(h.client.displays.single.index, 4);
      final notice = h.all<CsrdNoticeEvent>().single;
      expect(
        (notice.level, notice.text),
        (CsrdNoticeLevel.warn, 'screen locked'),
      );
      expect(h.all<CsrdClipboardEvent>().single.text, 'copied over there');
      await h.client.close();
    });

    test('a ping is answered with the same value', () async {
      final h = Harness();
      await h.connect();
      h.host.send(const CsrdPing(-2));
      expect((await h.host.next<CsrdPong>()).value, -2);
      await h.client.close();
    });

    test('a pong gives the round trip', () async {
      final h = Harness();
      await h.connect();
      final ping = await h.host.next<CsrdPing>();
      await Future<void>.delayed(const Duration(milliseconds: 15));
      h.host.send(CsrdPong(ping.value));
      final rtt = (await h.event<CsrdRttEvent>()).rtt;
      expect(rtt, greaterThanOrEqualTo(const Duration(milliseconds: 15)));
      expect(rtt, lessThan(const Duration(seconds: 2)));
      expect(h.client.rtt, rtt);
      await h.client.close();
    });

    test('a garbled message ends the session', () async {
      final h = Harness();
      await h.connect();
      h.host.sendBytes([CsrdKind.key, 1, 0, 0, 0, 0]);
      expect((await h.client.done).text, contains('bad message'));
    });

    test('a reject mid-session ends it with the reason', () async {
      final h = Harness();
      await h.connect();
      h.host.send(const CsrdReject('taken over by another viewer'));
      expect((await h.client.done).text, contains('taken over'));
    });
  });

  group('the end', () {
    test('a hang-up is a peer close', () async {
      final h = Harness();
      await h.connect();
      await h.host.hangUp();
      expect(await h.client.done, const CsrdCloseReason.peer());
      expect(h.events.last, isA<CsrdClosedEvent>());
      await h.host.clientClosed;
    });

    test('an error notice before a hang-up becomes the reason', () async {
      final h = Harness();
      await h.connect();
      h.host.send(
        const CsrdNotice(CsrdNoticeLevel.error, 'capture failed: boom'),
      );
      await h.host.hangUp();
      expect(
        await h.client.done,
        const CsrdCloseReason.error('capture failed: boom'),
      );
    });

    test('a withdrawn error notice does not', () async {
      final h = Harness();
      await h.connect();
      h.host
        ..send(const CsrdNotice(CsrdNoticeLevel.error, 'capture failed'))
        ..send(const CsrdNotice(CsrdNoticeLevel.info, ''));
      await h.host.hangUp();
      expect(await h.client.done, const CsrdCloseReason.peer());
    });

    test('silence ends the session', () async {
      final h = Harness();
      await h.connect();
      final reason = await h.client.done.timeout(const Duration(seconds: 2));
      expect(reason.text, contains('stopped responding'));
    });

    test('traffic keeps it alive', () async {
      final h = Harness();
      await h.connect();
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        h.host.send(CsrdPong(i));
      }
      expect(h.client.state, CsrdClientState.connected);
      await h.client.close();
    });

    test(
      'close sends what is queued, then ReleaseAll, then hangs up',
      () async {
        final h = Harness();
        await h.connect();
        h.client.key(30, down: true);
        final reason = await h.client.close();
        expect(reason, const CsrdCloseReason.local());
        await h.host.clientClosed;
        final tail = h.host.received.where((m) => m is! CsrdPing).toList();
        expect(tail.sublist(tail.length - 2), [
          const CsrdKey(30, down: true),
          const CsrdReleaseAll(),
        ]);
        expect(h.events.last, isA<CsrdClosedEvent>());
        expect(h.all<CsrdClosedEvent>(), hasLength(1));
      },
    );

    test('close with an error reports it', () async {
      final h = Harness();
      await h.connect();
      final reason = await h.client.close(error: 'corrupt jpeg');
      expect(reason, const CsrdCloseReason.error('corrupt jpeg'));
      expect(h.host.all<CsrdReleaseAll>(), hasLength(1));
    });

    test('closing twice is harmless', () async {
      final h = Harness();
      await h.connect();
      final a = h.client.close();
      final b = h.client.close();
      expect(await a, await b);
      expect(h.host.all<CsrdReleaseAll>(), hasLength(1));
    });

    test('nothing is sent after the end', () async {
      final h = Harness();
      await h.connect();
      await h.client.close();
      final count = h.host.received.length;
      h.client
        ..key(30, down: true)
        ..ackFrame(1)
        ..sendClipboard('late');
      await settle();
      expect(h.host.received.length, count);
    });
  });

  group('input', () {
    test('goes out in order, pointer moves collapsing', () async {
      final h = Harness();
      await h.connect();
      h.client
        ..pointerMove(1, 2)
        ..pointerMove(3, 4)
        ..pointerButton(CsrdButton.left, down: true)
        ..pointerMove(5, 6)
        ..pointerMove(7, 8)
        ..scroll(0, 240)
        ..key(30, down: true)
        ..releaseAll();
      await h.host.next<CsrdReleaseAll>();
      expect(
        h.host.received.where(
          (m) => m is! CsrdPing && m is! CsrdHello && m is! CsrdStart,
        ),
        [
          const CsrdPointerMove(3, 4),
          const CsrdPointerButton(CsrdButton.left, down: true),
          const CsrdPointerMove(7, 8),
          const CsrdScroll(0, 240),
          const CsrdKey(30, down: true),
          const CsrdReleaseAll(),
        ],
      );
      await h.client.close();
    });

    test('is clamped to the wire, and nonsense is dropped', () async {
      final h = Harness();
      await h.connect();
      h.client
        ..pointerMove(1 << 40, -(1 << 40))
        ..scroll(100000, -100000)
        ..scroll(0, 0)
        ..pointerButton(9, down: true)
        ..key(0, down: true)
        ..key(0x10000, down: true)
        ..releaseAll();
      await h.host.next<CsrdReleaseAll>();
      expect(
        h.host.all<CsrdPointerMove>().single,
        const CsrdPointerMove(0x7fffffff, -0x80000000),
      );
      expect(
        h.host.all<CsrdScroll>().single,
        const CsrdScroll(0x7fff, -0x8000),
      );
      expect(h.host.all<CsrdPointerButton>(), isEmpty);
      expect(h.host.all<CsrdKey>(), isEmpty);
      await h.client.close();
    });

    test(
      'a view-only session sends none, and no ReleaseAll at the end',
      () async {
        final h = Harness();
        await h.connect(viewOnly: true);
        expect(h.host.all<CsrdStart>().single.viewOnly, isTrue);
        expect(h.client.viewOnlyLocked, isTrue);
        h.client
          ..viewOnly =
              false // locked: no effect
          ..pointerMove(1, 1)
          ..key(30, down: true)
          ..sendClipboard('secret');
        await h.client.close();
        await h.host.clientClosed;
        expect(h.client.viewOnly, isTrue);
        for (final m in h.host.received) {
          expect(
            m,
            isA<CsrdMessage>().having(
              (m) => m.kind,
              'kind',
              isNot(inInclusiveRange(0x30, 0x40)),
            ),
          );
        }
      },
    );

    test('switching to view-only releases held keys first', () async {
      final h = Harness();
      await h.connect();
      h.client
        ..key(42, down: true)
        ..viewOnly = true
        ..key(30, down: true);
      await h.host.next<CsrdReleaseAll>();
      await settle();
      expect(h.host.all<CsrdKey>(), [const CsrdKey(42, down: true)]);
      h.client
        ..viewOnly = false
        ..key(30, down: true);
      expect((await h.host.next<CsrdKey>()).code, 30);
      await h.client.close();
    });

    test('clipboard text is cut to 1 MiB on a character boundary', () async {
      final h = Harness();
      await h.connect();
      h.client.sendClipboard('x${'é' * csrdMaxClipboard}');
      final sent = await h.host.next<CsrdClipboardText>();
      final bytes = utf8.encode(sent.text).length;
      expect(bytes, lessThanOrEqualTo(csrdMaxClipboard));
      expect(bytes, greaterThan(csrdMaxClipboard - 2));
      await h.client.close();
    });
  });

  group('selecting a display', () {
    test('sends the change, keeping what was not changed', () async {
      final h = Harness();
      await h.connect();
      h.client.selectDisplay(1, quality: CsrdQuality.lossless);
      expect(
        await h.host.next<CsrdSelectDisplay>(),
        const CsrdSelectDisplay(display: 1, quality: 0, maxFps: 45),
      );
      h.client.selectDisplay(1, maxFps: 500);
      expect(
        await h.host.next<CsrdSelectDisplay>(),
        const CsrdSelectDisplay(display: 1, quality: 0, maxFps: 120),
      );
      expect(h.client.display, 1);
      expect(h.client.quality, CsrdQuality.lossless);
      await h.client.close();
    });

    test('refuses a display the agent did not offer', () async {
      final h = Harness();
      await h.connect();
      expect(() => h.client.selectDisplay(7), throwsArgumentError);
      await settle();
      expect(h.host.all<CsrdSelectDisplay>(), isEmpty);
      await h.client.close();
    });
  });
}
