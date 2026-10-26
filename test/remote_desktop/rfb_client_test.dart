import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/api.dart' show KeyParameter;
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/digests/md5.dart';
import 'package:secure_shell_go/services/remote_desktop/csrd_client.dart';
import 'package:secure_shell_go/services/remote_desktop/csrd_messages.dart';
import 'package:secure_shell_go/services/remote_desktop/csrd_tiles.dart';
import 'package:secure_shell_go/services/remote_desktop/rfb_client.dart';
import 'package:secure_shell_go/services/remote_desktop/rfb_protocol.dart';

import 'csrd_test_support.dart' show CpuFramebuffer;
import 'rfb_test_support.dart';

const fast = RfbTiming(
  handshakeTimeout: Duration(seconds: 5),
  closeFlushTimeout: Duration(milliseconds: 50),
);

Future<({String? username, String password})?> noCredentials(
  RfbAuthKind kind,
) async => throw StateError('no credentials should be needed');

class Session {
  Session(this.client, this.server, this.log);
  final RfbClient client;
  final FakeRfbServer server;
  final EventLog log;
  final screen = CpuFramebuffer();

  /// The next frame, applied to [screen].
  Future<CsrdDecodedFrame> frame() async {
    final f = (await log.next<CsrdFrameEvent>()).frame;
    screen.apply(f);
    return f;
  }

  Future<void> close() async {
    await client.close();
    await server.hangUp();
  }
}

/// A connected session over a 3.8 handshake with no security, with the
/// client's opening messages already read.
Future<Session> connect({
  int width = 64,
  int height = 48,
  RfbCommandKey commandKey = RfbCommandKey.superKey,
}) async {
  final server = FakeRfbServer();
  final client = RfbClient(
    input: server.clientInput,
    output: server.clientOutput,
    timing: fast,
    commandKey: commandKey,
  );
  final log = EventLog(client.events);
  final connecting = client.connect(credentials: noCredentials);
  await server.handshakeNone(width: width, height: height);
  await connecting;
  await server.next<SetEncodingsMsg>();
  final first = await server.next<UpdateRequestMsg>();
  expect(first.incremental, isFalse);
  return Session(client, server, log);
}

List<int> rawRect(Picture p, int x, int y, int w, int h) => [
  ...rectHeader(x, y, w, h, RfbEncoding.raw),
  ...p.sub(x, y, w, h).rawWire(),
];

List<int> copyRect(int sx, int sy, int w, int h, int dx, int dy) => [
  ...rectHeader(dx, dy, w, h, RfbEncoding.copyRect),
  ...be16(sx),
  ...be16(sy),
];

List<int> cutText(List<int> latin1) => [
  3,
  0,
  0,
  0,
  ...be32(latin1.length),
  ...latin1,
];

/// RFC 2409's 1024-bit MODP group, generator 2.
final oakley2 = BigInt.parse(
  'FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA6'
  '3B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245'
  'E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F2411'
  '7C4B1FE649286651ECE65381FFFFFFFFFFFFFFFF',
  radix: 16,
);

Uint8List bytesOf(BigInt v, int n) {
  final out = Uint8List(n);
  for (var i = n - 1; i >= 0; i--) {
    out[i] = (v & BigInt.from(0xff)).toInt();
    v >>= 8;
  }
  return out;
}

BigInt big(Uint8List b) =>
    b.fold(BigInt.zero, (v, x) => (v << 8) | BigInt.from(x));

void main() {
  group('handshake', () {
    test('3.8 with no security, then the pixel format, encodings and a '
        'full request', () async {
      final server = FakeRfbServer();
      final client = RfbClient(
        input: server.clientInput,
        output: server.clientOutput,
        timing: fast,
      );
      final log = EventLog(client.events);
      final connecting = client.connect(credentials: noCredentials);
      expect(await server.exchangeVersion(), 'RFB 003.008\n');
      server.send([2, RfbSecurity.vncAuth + 40, RfbSecurity.none]);
      expect(await server.read(1), [RfbSecurity.none]);
      server.send(be32(0));
      expect(await server.read(1), [1], reason: 'ClientInit asks to share');
      server.send(serverInit(320, 200, 'büro:0'));
      server.parseMessages();
      await connecting;

      final pf = await server.next<SetPixelFormatMsg>();
      // 32 bpp, depth 24, little-endian, true colour, maxes 255, shifts
      // 16/8/0.
      expect(pf.bytes, [
        0,
        0,
        0,
        32,
        24,
        0,
        1,
        0,
        255,
        0,
        255,
        0,
        255,
        16,
        8,
        0,
        0,
        0,
        0,
      ]);
      final enc = await server.next<SetEncodingsMsg>();
      expect(enc.encodings, [16, 1, 0, -239, -223, -308, -224]);
      final req = await server.next<UpdateRequestMsg>();
      expect(
        (req.incremental, req.x, req.y, req.w, req.h),
        (false, 0, 0, 320, 200),
      );

      final connected = await log.next<CsrdConnectedEvent>();
      expect(connected.display, 0);
      expect(connected.displays.single.width, 320);
      expect(connected.displays.single.name, 'büro:0');
      expect(client.state, CsrdClientState.connected);
      expect(client.protocolVersion, 8);
      expect(client.securityType, RfbSecurity.none);
      expect(client.desktopName, 'büro:0');
      expect(client.supportsQuality, isFalse);
      expect(client.rtt, isNull);
      expect(client.display, 0);
      await client.close();
    });

    test('3.7 sends no SecurityResult after None', () async {
      final server = FakeRfbServer();
      final client = RfbClient(
        input: server.clientInput,
        output: server.clientOutput,
        timing: fast,
      );
      final connecting = client.connect(credentials: noCredentials);
      expect(await server.exchangeVersion('RFB 003.007\n'), 'RFB 003.007\n');
      server.send([1, RfbSecurity.none]);
      expect(await server.read(1), [RfbSecurity.none]);
      // Straight to ClientInit: a client waiting for a SecurityResult
      // would hang here.
      expect(await server.read(1), [1]);
      server.send(serverInit(10, 10, ''));
      await connecting;
      expect(client.protocolVersion, 7);
      await client.close();
    });

    test('3.3: the server picks None, and nothing follows it', () async {
      final server = FakeRfbServer();
      final client = RfbClient(
        input: server.clientInput,
        output: server.clientOutput,
        timing: fast,
      );
      final connecting = client.connect(credentials: noCredentials);
      // 3.5 is to be read as 3.3.
      expect(await server.exchangeVersion('RFB 003.005\n'), 'RFB 003.003\n');
      server.send(be32(RfbSecurity.none));
      expect(await server.read(1), [1], reason: 'no choice byte in 3.3');
      server.send(serverInit(10, 10, 'old'));
      await connecting;
      expect(client.protocolVersion, 3);
      await client.close();
    });

    for (final version in ['RFB 003.003\n', 'RFB 003.007\n', 'RFB 003.008\n']) {
      test('VNC authentication on ${version.trim()}', () async {
        final server = FakeRfbServer();
        final client = RfbClient(
          input: server.clientInput,
          output: server.clientOutput,
          timing: fast,
        );
        final asked = <RfbAuthKind>[];
        final connecting = client.connect(
          credentials: (kind) async {
            asked.add(kind);
            return (username: null, password: 'password');
          },
        );
        await server.exchangeVersion(version);
        if (version == 'RFB 003.003\n') {
          server.send(be32(RfbSecurity.vncAuth));
        } else {
          server.send([1, RfbSecurity.vncAuth]);
          expect(await server.read(1), [RfbSecurity.vncAuth]);
        }
        server.send(List.generate(16, (i) => i));
        // The known DES answer (see rfb_auth_test.dart).
        expect(await server.read(16), [
          0xb8, 0x66, 0x92, 0x41, 0x25, 0xc8, 0xee, 0xbb, //
          0x9d, 0xeb, 0xc1, 0xdb, 0x61, 0xc5, 0x38, 0xe2,
        ]);
        server.send(be32(0));
        expect(await server.read(1), [1]);
        server.send(serverInit(10, 10, ''));
        await connecting;
        expect(asked, [RfbAuthKind.vncPassword]);
        expect(client.securityType, RfbSecurity.vncAuth);
        await client.close();
      });
    }

    test('a wrong password fails with the server’s reason, as an auth '
        'failure', () async {
      final server = FakeRfbServer();
      final client = RfbClient(
        input: server.clientInput,
        output: server.clientOutput,
        timing: fast,
      );
      final log = EventLog(client.events);
      final connecting = client.connect(
        credentials: (_) async => (username: null, password: 'wrong'),
      );
      await server.exchangeVersion();
      server.send([1, RfbSecurity.vncAuth]);
      await server.read(1);
      server.send(List.filled(16, 9));
      await server.read(16);
      final reason = utf8.encode('Authentication failure');
      server.send([...be32(1), ...be32(reason.length), ...reason]);
      await expectLater(
        connecting,
        throwsA(
          isA<RfbAuthFailedException>().having(
            (e) => e.reason.text,
            'reason',
            'the VNC password was not accepted (Authentication failure)',
          ),
        ),
      );
      final closed = await log.next<CsrdClosedEvent>();
      expect(closed.reason.kind, CsrdCloseKind.error);
      await server.clientClosed;
    });

    test('Apple Remote Desktop on Apple’s 3.889: DH, then the account '
        'under AES', () async {
      final server = FakeRfbServer();
      final client = RfbClient(
        input: server.clientInput,
        output: server.clientOutput,
        timing: fast,
      );
      final asked = <RfbAuthKind>[];
      final connecting = client.connect(
        credentials: (kind) async {
          asked.add(kind);
          return (username: 'dhiva', password: 'pässwörd');
        },
      );
      // Apple's own version string, answered as plain 3.8.
      expect(await server.exchangeVersion('RFB 003.889\n'), 'RFB 003.008\n');
      // macOS offers Apple's and VNC's (when a VNC password is set); the
      // Mac account is preferred.
      server.send([2, RfbSecurity.vncAuth, RfbSecurity.appleRemoteDesktop]);
      expect(await server.read(1), [RfbSecurity.appleRemoteDesktop]);

      final serverPrivate = BigInt.parse('1234567890abcdef' * 8, radix: 16);
      final serverPublic = BigInt.two.modPow(serverPrivate, oakley2);
      server.send([
        ...be16(2),
        ...be16(128),
        ...bytesOf(oakley2, 128),
        ...bytesOf(serverPublic, 128),
      ]);
      final ciphertext = await server.read(128);
      final clientPublic = big(await server.read(128));
      final shared = clientPublic.modPow(serverPrivate, oakley2);
      final aes = AESEngine()
        ..init(false, KeyParameter(MD5Digest().process(bytesOf(shared, 128))));
      final plain = Uint8List(128);
      for (var i = 0; i < 128; i += 16) {
        aes.processBlock(ciphertext, i, plain, i);
      }
      String field(int at) =>
          utf8.decode(plain.sublist(at, plain.indexOf(0, at)));
      expect(field(0), 'dhiva');
      expect(field(64), 'pässwörd');

      server.send(be32(0));
      expect(await server.read(1), [1]);
      server.send(serverInit(1440, 900, 'Dhiva’s MacBook'));
      await connecting;
      expect(asked, [RfbAuthKind.appleAccount]);
      expect(client.securityType, RfbSecurity.appleRemoteDesktop);
      expect(client.desktopName, 'Dhiva’s MacBook');
      await client.close();
    });

    test('Apple authentication refused', () async {
      final server = FakeRfbServer();
      final client = RfbClient(
        input: server.clientInput,
        output: server.clientOutput,
        timing: fast,
      );
      final connecting = client.connect(
        credentials: (_) async => (username: 'u', password: 'p'),
      );
      await server.exchangeVersion('RFB 003.889\n');
      server.send([1, RfbSecurity.appleRemoteDesktop]);
      await server.read(1);
      server.send([
        ...be16(2),
        ...be16(128),
        ...bytesOf(oakley2, 128),
        ...bytesOf(BigInt.from(12345), 128),
      ]);
      await server.read(256);
      server.send(be32(1));
      await server.hangUp(); // Apple may hang up without a reason.
      await expectLater(
        connecting,
        throwsA(
          isA<RfbAuthFailedException>().having(
            (e) => e.reason.text,
            'reason',
            'the user name or password was not accepted',
          ),
        ),
      );
    });

    Future<int> chosen(List<int> offered) async {
      final server = FakeRfbServer();
      final client = RfbClient(
        input: server.clientInput,
        output: server.clientOutput,
        timing: fast,
      );
      unawaited(
        client
            .connect(credentials: (_) async => null)
            .catchError((Object _) {}),
      );
      await server.exchangeVersion();
      server.send([offered.length, ...offered]);
      final c = (await server.read(1))[0];
      await client.close();
      return c;
    }

    test('None is preferred, then Apple’s, then VNC’s', () async {
      expect(await chosen([2, 30, 1]), 1);
      expect(await chosen([2, 30]), 30);
      expect(await chosen([16, 2, 19]), 2);
    });

    test('a server offering nothing this viewer supports', () async {
      final server = FakeRfbServer();
      final client = RfbClient(
        input: server.clientInput,
        output: server.clientOutput,
        timing: fast,
      );
      final connecting = client.connect(credentials: noCredentials);
      await server.exchangeVersion();
      server.send([3, 5, 16, 19]);
      await expectLater(
        connecting,
        throwsA(
          isA<CsrdConnectException>().having(
            (e) => e.reason.text,
            'reason',
            contains('security types 5, 16, 19'),
          ),
        ),
      );
    });

    test(
      'a refusal before security, with its reason, on 3.8 and 3.3',
      () async {
        for (final version in ['RFB 003.008\n', 'RFB 003.003\n']) {
          final server = FakeRfbServer();
          final client = RfbClient(
            input: server.clientInput,
            output: server.clientOutput,
            timing: fast,
          );
          final connecting = client.connect(credentials: noCredentials);
          await server.exchangeVersion(version);
          final reason = utf8.encode('Too many security failures');
          server.send([
            ...(version.contains('008') ? [0] : be32(0)),
            ...be32(reason.length),
            ...reason,
          ]);
          await expectLater(
            connecting,
            throwsA(
              isA<CsrdConnectException>()
                  .having((e) => e is RfbAuthFailedException, 'auth', isFalse)
                  .having(
                    (e) => e.reason.text,
                    'reason',
                    'the VNC server refused the connection: '
                        'Too many security failures',
                  ),
            ),
          );
        }
      },
    );

    test('cancelling the credentials prompt closes quietly', () async {
      final server = FakeRfbServer();
      final client = RfbClient(
        input: server.clientInput,
        output: server.clientOutput,
        timing: fast,
      );
      final connecting = client.connect(credentials: (_) async => null);
      await server.exchangeVersion();
      server.send([1, RfbSecurity.vncAuth]);
      await server.read(1);
      server.send(List.filled(16, 1));
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
      await server.clientClosed;
      expect(await client.done, const CsrdCloseReason.local());
    });

    test('something that is not a VNC server', () async {
      final server = FakeRfbServer();
      final client = RfbClient(
        input: server.clientInput,
        output: server.clientOutput,
        timing: fast,
      );
      final connecting = client.connect(credentials: noCredentials);
      server.send(ascii.encode('SSH-2.0-OpenSSH_9.6\r\n'));
      await expectLater(
        connecting,
        throwsA(
          isA<CsrdConnectException>().having(
            (e) => e.reason.text,
            'reason',
            contains('not a VNC server: it began with "SSH-2.0-Open"'),
          ),
        ),
      );
    });

    test('RFB 2 is too old', () async {
      final server = FakeRfbServer();
      final client = RfbClient(
        input: server.clientInput,
        output: server.clientOutput,
        timing: fast,
      );
      final connecting = client.connect(credentials: noCredentials);
      server.send(ascii.encode('RFB 002.000\n'));
      await expectLater(
        connecting,
        throwsA(
          isA<CsrdConnectException>().having(
            (e) => e.reason.text,
            'reason',
            contains('too old'),
          ),
        ),
      );
    });

    test('a hang-up during the handshake', () async {
      final server = FakeRfbServer();
      final client = RfbClient(
        input: server.clientInput,
        output: server.clientOutput,
        timing: fast,
      );
      final connecting = client.connect(credentials: noCredentials);
      await server.exchangeVersion();
      await server.hangUp();
      await expectLater(
        connecting,
        throwsA(
          isA<CsrdConnectException>().having(
            (e) => e.reason.text,
            'reason',
            contains('closed the connection during the handshake'),
          ),
        ),
      );
    });

    test('a server that stops answering times out', () async {
      final server = FakeRfbServer();
      final client = RfbClient(
        input: server.clientInput,
        output: server.clientOutput,
        timing: const RfbTiming(
          handshakeTimeout: Duration(milliseconds: 100),
          closeFlushTimeout: Duration(milliseconds: 50),
        ),
      );
      final connecting = client.connect(credentials: noCredentials);
      await server.exchangeVersion();
      await expectLater(
        connecting,
        throwsA(
          isA<CsrdConnectException>().having(
            (e) => e.reason.text,
            'reason',
            contains('did not answer'),
          ),
        ),
      );
    });

    test('the time the person spends typing does not count', () async {
      final server = FakeRfbServer();
      final client = RfbClient(
        input: server.clientInput,
        output: server.clientOutput,
        timing: const RfbTiming(
          handshakeTimeout: Duration(milliseconds: 150),
          closeFlushTimeout: Duration(milliseconds: 50),
        ),
      );
      final connecting = client.connect(
        credentials: (_) async {
          await Future<void>.delayed(const Duration(milliseconds: 400));
          return (username: null, password: 'x');
        },
      );
      await server.exchangeVersion();
      server.send([1, RfbSecurity.vncAuth]);
      await server.read(1);
      server.send(List.filled(16, 1));
      await server.read(16);
      server.send(be32(0));
      await server.read(1);
      server.send(serverInit(8, 8, ''));
      await connecting;
      await client.close();
    });

    test('untrusted ServerInit and DH parameters', () async {
      Future<String> failure(List<int> afterSecurity, {int type = 1}) async {
        final server = FakeRfbServer();
        final client = RfbClient(
          input: server.clientInput,
          output: server.clientOutput,
          timing: fast,
        );
        final connecting = client.connect(
          credentials: (_) async => (username: 'u', password: 'p'),
        );
        await server.exchangeVersion();
        server.send([1, type]);
        await server.read(1);
        if (type == RfbSecurity.none) server.send(be32(0));
        server.send(afterSecurity);
        try {
          await connecting;
        } on CsrdConnectException catch (e) {
          return e.reason.text;
        }
        fail('connected');
      }

      expect(await failure(serverInit(0, 10, '')), contains('0x10'));
      expect(await failure(serverInit(20000, 10, '')), contains('20000x10'));
      expect(await failure(serverInit(9000, 9000, '')), contains('9000x9000'));
      // A 2 MiB name is refused from its length alone.
      expect(
        await failure([
          ...serverInit(8, 8, '').sublist(0, 20),
          ...be32(2 << 20),
        ]),
        contains('desktop name of 2097152 bytes'),
      );
      expect(
        await failure([...be16(2), ...be16(513)], type: 30),
        contains('Diffie-Hellman key of 513 bytes'),
      );
      expect(
        await failure([...be16(2), ...be16(0)], type: 30),
        contains('Diffie-Hellman key of 0 bytes'),
      );
    });
  });

  group('updates', () {
    test('a Raw rect becomes an opaque pixel tile, and the next request '
        'waits for the ack', () async {
      final s = await connect();
      final p = busyPicture(64, 48);
      s.server.send([...updateHeader(1), ...rawRect(p, 0, 0, 64, 48)]);
      final f = await s.frame();
      expect(f.seq, 1);
      expect((f.width, f.height), (64, 48));
      final tile = f.tiles.single as CsrdPixelTile;
      expect(tile.bgra, p.bgra); // X junk replaced by 0xFF
      expect(f.wireBytes, greaterThan(64 * 48 * 4));
      await s.server.settle();
      expect(s.server.all<UpdateRequestMsg>(), hasLength(1));
      s.client.ackFrame(1);
      final req = await s.server.next<UpdateRequestMsg>();
      expect((req.incremental, req.w, req.h), (true, 64, 48));
      // Repeated and unknown acks change nothing.
      s.client
        ..ackFrame(1)
        ..ackFrame(7);
      await s.server.settle();
      expect(s.server.all<UpdateRequestMsg>(), hasLength(2));
      await s.close();
    });

    test('ZRLE rects, solid ones as fills', () async {
      final s = await connect(width: 200, height: 100);
      final z = ZrleEncoder();
      final p = busyPicture(200, 100, seed: 3)
        ..fillRect(0, 64, 64, 36, 0x445566);
      s.server.send([
        ...updateHeader(2),
        ...z.wireRect(p, 0, 0, 200, 64, choose: mixedSub),
        ...z.wireRect(p, 0, 64, 64, 36),
      ]);
      final f = await s.frame();
      expect(f.tiles[0], isA<CsrdPixelTile>());
      expect((f.tiles[1] as CsrdFillTile).color, 0xff445566);
      s.screen.apply(
        CsrdDecodedFrame(
          seq: 0,
          width: 200,
          height: 100,
          tiles: [CsrdPixelTile(64, 64, 136, 36, p.sub(64, 64, 136, 36).bgra)],
          wireBytes: 0,
        ),
      );
      expect(firstDifference(s.screen.bgra, p.bgra), -1);
      expect(s.client.encodingsSeen, {RfbEncoding.zrle});
      await s.close();
    });

    test(
      'a copy whose source an earlier rect drew starts a new frame',
      () async {
        final s = await connect();
        final p = busyPicture(64, 48, seed: 5);
        final model = Picture(64, 48)..blit(0, 0, p);
        s.server.send([...updateHeader(1), ...rawRect(p, 0, 0, 64, 48)]);
        await s.frame();
        s.client.ackFrame(1);
        await s.server.next<UpdateRequestMsg>();

        final q = busyPicture(64, 48, seed: 6);
        // Raw over (0,0,16,16), then a copy from there to (32,0): RFB copies
        // the new pixels.
        model.blit(0, 0, q.sub(0, 0, 16, 16));
        model.copyRect(0, 0, 16, 16, 32, 0);
        s.server.send([
          ...updateHeader(2),
          ...rawRect(q, 0, 0, 16, 16),
          ...copyRect(0, 0, 16, 16, 32, 0),
        ]);
        final a = await s.frame();
        final b = await s.frame();
        expect(a.tiles.single, isA<CsrdPixelTile>());
        expect(b.tiles.single, isA<CsrdCopyTile>());
        expect((a.seq, b.seq), (2, 3));
        expect(firstDifference(s.screen.bgra, model.bgra), -1);

        // Acking the first of them is not enough.
        s.client.ackFrame(2);
        await s.server.settle();
        expect(s.server.all<UpdateRequestMsg>(), hasLength(2));
        s.client.ackFrame(3);
        await s.server.next<UpdateRequestMsg>();
        await s.close();
      },
    );

    test('a copy from somewhere untouched stays in the same frame, and a '
        'chain of copies splits', () async {
      final s = await connect();
      final p = busyPicture(64, 48, seed: 8);
      final model = Picture(64, 48)..blit(0, 0, p);
      s.server.send([...updateHeader(1), ...rawRect(p, 0, 0, 64, 48)]);
      await s.frame();
      s.client.ackFrame(1);
      await s.server.next<UpdateRequestMsg>();

      model
        ..blit(40, 40, busyPicture(8, 8, seed: 2))
        ..copyRect(0, 0, 16, 16, 16, 16) // reads untouched pixels
        ..copyRect(16, 16, 8, 8, 48, 0); // reads what the copy wrote
      s.server.send([
        ...updateHeader(3),
        ...rawRect(model, 40, 40, 8, 8),
        ...copyRect(0, 0, 16, 16, 16, 16),
        ...copyRect(16, 16, 8, 8, 48, 0),
      ]);
      final a = await s.frame();
      final b = await s.frame();
      expect(a.tiles.map((t) => t.runtimeType), [CsrdPixelTile, CsrdCopyTile]);
      expect(b.tiles.single, isA<CsrdCopyTile>());
      expect(firstDifference(s.screen.bgra, model.bgra), -1);
      await s.close();
    });

    test('random updates of Raw, ZRLE and CopyRect come out as RFB '
        'applies them', () async {
      final rng = Random(2024);
      const w = 160, h = 120;
      final s = await connect(width: w, height: h);
      // Drawn and acked as they come, as the compositor would.
      var frames = 0;
      s.client.events.listen((e) {
        if (e is CsrdFrameEvent) {
          s.screen.apply(e.frame);
          frames++;
          s.client.ackFrame(e.frame.seq);
        }
      });
      final z = ZrleEncoder();
      final model = Picture(w, h);
      for (var update = 0; update < 25; update++) {
        final bytes = <int>[];
        final n = 1 + rng.nextInt(8);
        for (var i = 0; i < n; i++) {
          final rw = 1 + rng.nextInt(70), rh = 1 + rng.nextInt(70);
          final x = rng.nextInt(w - rw + 1), y = rng.nextInt(h - rh + 1);
          switch (rng.nextInt(3)) {
            case 0:
              model.blit(x, y, busyPicture(rw, rh, seed: rng.nextInt(1000)));
              bytes.addAll(rawRect(model, x, y, rw, rh));
            case 1:
              final src = busyPicture(rw, rh, seed: rng.nextInt(1000));
              if (rng.nextBool()) {
                src.fillRect(0, 0, rw, rh, rng.nextInt(1 << 24));
              }
              model.blit(x, y, src);
              bytes.addAll(z.wireRect(model, x, y, rw, rh, choose: mixedSub));
            default:
              final sx = rng.nextInt(w - rw + 1), sy = rng.nextInt(h - rh + 1);
              model.copyRect(sx, sy, rw, rh, x, y);
              bytes.addAll(copyRect(sx, sy, rw, rh, x, y));
          }
        }
        s.server.send([...updateHeader(n), ...bytes]);
        // The next request goes out only once the update's last frame is
        // acked, so by then the screen has all of it.
        final req = await s.server.next<UpdateRequestMsg>();
        expect(req.incremental, isTrue);
        expect(
          firstDifference(s.screen.bgra, model.bgra),
          -1,
          reason: 'after update $update',
        );
      }
      expect(frames, greaterThan(25), reason: 'some updates were split');
      await s.close();
    });

    test('an update with nothing to draw asks again at once', () async {
      final s = await connect();
      s.server.send([
        ...updateHeader(1),
        ...rectHeader(1, 1, 2, 2, RfbEncoding.cursor),
        ...List.filled(2 * 2 * 4, 0x80),
        0xc0,
        0x40,
      ]);
      await s.log.next<CsrdCursorShapeEvent>();
      final req = await s.server.next<UpdateRequestMsg>();
      expect(req.incremental, isTrue);
      expect(s.log.all<CsrdFrameEvent>(), isEmpty);
      await s.close();
    });

    test('DesktopSize mid-update: a frame at each size, then a full '
        'request', () async {
      final s = await connect();
      final p = busyPicture(80, 60);
      s.server.send([
        ...updateHeader(3),
        ...rawRect(p, 0, 0, 8, 8),
        ...rectHeader(0, 0, 80, 60, RfbEncoding.desktopSize),
        ...rawRect(p, 70, 50, 10, 10),
      ]);
      final a = await s.frame();
      final displays = await s.log.next<CsrdDisplaysEvent>();
      final b = await s.frame();
      expect((a.width, a.height), (64, 48));
      expect((b.width, b.height), (80, 60));
      expect(displays.displays.single.width, 80);
      expect(s.client.displays.single.height, 60);
      expect(s.client.framebufferWidth, 80);
      s.client.ackFrame(b.seq);
      final req = await s.server.next<UpdateRequestMsg>();
      expect((req.incremental, req.w, req.h), (false, 80, 60));
      await s.close();
    });

    test('ExtendedDesktopSize resizes unless its status says the request '
        'failed', () async {
      final s = await connect();
      List<int> eds(int status, int w, int h, int screens) => [
        ...rectHeader(1, status, w, h, RfbEncoding.extendedDesktopSize),
        screens,
        0,
        0,
        0,
        for (var i = 0; i < screens; i++) ...[
          ...be32(i),
          ...be16(i * 10),
          ...be16(0),
          ...be16(10),
          ...be16(h),
          ...be32(0),
        ],
      ];
      final p = busyPicture(100, 50);
      s.server.send([
        ...updateHeader(2),
        ...eds(3, 300, 300, 1), // refused: size unchanged
        ...rawRect(p, 0, 0, 64, 48),
      ]);
      final a = await s.frame();
      expect((a.width, a.height), (64, 48));
      s.client.ackFrame(a.seq);
      await s.server.next<UpdateRequestMsg>();
      s.server.send([
        ...updateHeader(2),
        ...eds(0, 100, 50, 2),
        ...rawRect(p, 90, 40, 10, 10),
      ]);
      final b = await s.frame();
      expect((b.width, b.height), (100, 50));
      // Still one display, the framebuffer.
      expect(s.client.displays, hasLength(1));
      await s.close();
    });

    test('the cursor shape, its mask as alpha', () async {
      final s = await connect();
      const cw = 10, ch = 3;
      final px = <int>[];
      for (var i = 0; i < cw * ch; i++) {
        px.addAll([i, 100 + i, 200, 0]); // B, G, R, X
      }
      // Row bitmasks, MSB first, two bytes per row for 10 pixels.
      final mask = [0xff, 0xc0, 0x80, 0x00, 0x00, 0x40];
      s.server.send([
        ...updateHeader(2),
        ...rectHeader(4, 2, cw, ch, RfbEncoding.cursor),
        ...px,
        ...mask,
        ...rectHeader(0, 0, 0, 0, RfbEncoding.cursor),
      ]);
      final shape = (await s.log.next<CsrdCursorShapeEvent>()).shape;
      expect(
        (shape.width, shape.height, shape.hotX, shape.hotY),
        (10, 3, 4, 2),
      );
      expect(shape.rgba.sublist(0, 4), [200, 100, 0, 255]); // R, G, B, A
      final alpha = [
        for (var i = 3; i < shape.rgba.length; i += 4) shape.rgba[i],
      ];
      expect(alpha, [
        ...List.filled(10, 255),
        255,
        ...List.filled(9, 0),
        ...List.filled(9, 0),
        255,
      ]);
      expect((await s.log.next<CsrdCursorShapeEvent>()).shape.hidden, isTrue);
      await s.close();
    });

    test('LastRect ends an update of unknown length', () async {
      final s = await connect();
      final p = busyPicture(64, 48);
      s.server.send([
        ...updateHeader(0xffff),
        ...rawRect(p, 0, 0, 4, 4),
        ...rectHeader(0, 0, 0, 0, RfbEncoding.lastRect),
        ...cutText(latin1.encode('after')),
      ]);
      final f = await s.frame();
      expect(f.tiles, hasLength(1));
      expect((await s.log.next<CsrdClipboardEvent>()).text, 'after');
      await s.close();
    });

    test('server cut text is Latin-1; too much of it is dropped, not '
        'fatal', () async {
      final s = await connect();
      s.server.send([
        ...cutText(latin1.encode('café\nñ')),
        3,
        0,
        0,
        0,
        ...be32(rfbMaxText + 1),
        ...List.filled(rfbMaxText + 1, 0x41),
        2, // Bell
        1, 0, ...be16(0), ...be16(2), ...List.filled(12, 7), // colour map
        ...cutText(latin1.encode('next')),
      ]);
      expect((await s.log.next<CsrdClipboardEvent>()).text, 'café\nñ');
      expect((await s.log.next<CsrdClipboardEvent>()).text, 'next');
      expect(s.client.state, CsrdClientState.connected);
      await s.close();
    });

    Future<String> fatal(List<int> bytes, {int width = 64}) async {
      final s = await connect(width: width);
      s.server.send(bytes);
      final reason = await s.client.done.timeout(const Duration(seconds: 5));
      await s.server.hangUp();
      expect(reason.kind, CsrdCloseKind.error);
      return reason.text;
    }

    test('what the server may not send', () async {
      expect(
        await fatal([...updateHeader(1), ...rectHeader(0, 0, 4, 4, 7)]),
        contains('encoding 7'),
      );
      expect(
        await fatal([...updateHeader(1), ...rectHeader(60, 0, 5, 1, 0)]),
        contains('Raw rect 5x1+60+0 outside the 64x48 framebuffer'),
      );
      expect(
        await fatal([...updateHeader(1), ...copyRect(60, 0, 8, 8, 0, 0)]),
        contains('CopyRect source rect 8x8+60+0 outside'),
      );
      expect(
        await fatal([
          ...updateHeader(1),
          ...rectHeader(0, 0, 4, 4, 16),
          ...be32(1 << 30),
        ]),
        contains('ZRLE data for a 4x4 rect'),
      );
      expect(
        await fatal([...updateHeader(1), ...rectHeader(0, 0, 257, 1, -239)]),
        contains('257x1 cursor'),
      );
      expect(
        await fatal([
          ...updateHeader(5),
          for (var i = 0; i < 5; i++) ...copyRect(0, 0, 64, 48, 0, 0),
        ]),
        contains('many times over'),
      );
      expect(
        await fatal([...updateHeader(1), ...rectHeader(0, 0, 0, 1, -223)]),
        contains('0x1 framebuffer'),
      );
      expect(await fatal([9]), contains('unknown message type 9'));
    });

    test(
      'the server hanging up ends the session as the peer’s doing',
      () async {
        final s = await connect();
        await s.server.hangUp();
        expect(await s.client.done, const CsrdCloseReason.peer());
        expect(s.log.events.last, isA<CsrdClosedEvent>());
      },
    );
  });

  group('input', () {
    test(
      'pointer moves are clamped and collapse; buttons make the mask',
      () async {
        final s = await connect();
        s.client
          ..pointerMove(10, 10)
          ..pointerMove(500, -5);
        await s.server.settle();
        s.client
          ..pointerButton(CsrdButton.left, down: true)
          ..pointerButton(CsrdButton.right, down: true)
          ..pointerButton(CsrdButton.middle, down: true)
          ..pointerButton(CsrdButton.back, down: true)
          ..pointerButton(CsrdButton.forward, down: true) // does not fit
          ..pointerButton(CsrdButton.left, down: false)
          ..pointerButton(CsrdButton.left, down: false); // already up
        await s.server.settle();
        expect(s.server.all<PointerMsg>(), const [
          PointerMsg(0, 63, 0),
          PointerMsg(1, 63, 0),
          PointerMsg(5, 63, 0),
          PointerMsg(7, 63, 0),
          PointerMsg(0x87, 63, 0),
          PointerMsg(0x86, 63, 0),
        ]);
        await s.close();
      },
    );

    test('scrolling: a press and release per notch, remainders kept', () async {
      final s = await connect();
      s.client
        ..pointerMove(5, 6)
        ..pointerButton(CsrdButton.left, down: true);
      await s.server.settle();
      s.server.received.clear();
      s.client
        ..scroll(0, 120) // up
        ..scroll(0, -240) // down twice
        ..scroll(0, 60)
        ..scroll(0, 59) // still not a notch
        ..scroll(0, 1) // now one
        ..scroll(120, 0) // right
        ..scroll(-130, 0); // left, 10 left over
      await s.server.settle();
      List<PointerMsg> click(int bit) => [
        PointerMsg(1 | bit, 5, 6),
        const PointerMsg(1, 5, 6),
      ];
      expect(s.server.all<PointerMsg>(), [
        ...click(8),
        ...click(16),
        ...click(16),
        ...click(8),
        ...click(64),
        ...click(32),
      ]);
      await s.close();
    });

    test('keys go out as keysyms, modifiers as their own', () async {
      final s = await connect();
      s.client
        ..key(42, down: true) // Shift_L
        ..key(30, down: true) // a
        ..key(30, down: false)
        ..key(42, down: false)
        ..key(125, down: true) // Meta → Super_L by default
        ..key(125, down: false)
        ..key(103, down: false) // never pressed: dropped
        ..key(116, down: true); // Power: never sent
      await s.server.settle();
      expect(s.server.all<KeyMsg>(), const [
        KeyMsg(0xffe1, down: true),
        KeyMsg(0x61, down: true),
        KeyMsg(0x61, down: false),
        KeyMsg(0xffe1, down: false),
        KeyMsg(0xffeb, down: true),
        KeyMsg(0xffeb, down: false),
      ]);
      await s.close();

      final mac = await connect(commandKey: RfbCommandKey.metaKey);
      mac.client
        ..key(125, down: true)
        ..key(126, down: true);
      await mac.server.settle();
      expect(mac.server.all<KeyMsg>(), const [
        KeyMsg(0xffe7, down: true),
        KeyMsg(0xffe8, down: true),
      ]);
      await mac.close();
    });

    test('releaseAll lets go of every key and sends a zero mask', () async {
      final s = await connect();
      s.client
        ..pointerMove(3, 4)
        ..pointerButton(CsrdButton.left, down: true)
        ..key(29, down: true)
        ..key(46, down: true);
      await s.server.settle();
      s.server.received.clear();
      s.client.releaseAll();
      await s.server.settle();
      expect(s.server.received, const [
        KeyMsg(0xffe3, down: false),
        KeyMsg(0x63, down: false),
        PointerMsg(0, 3, 4),
      ]);
      await s.close();
    });

    test('view-only drops input, and turning it on releases first', () async {
      final s = await connect();
      s.client
        ..pointerMove(1, 1)
        ..key(30, down: true);
      await s.server.settle();
      s.server.received.clear();
      s.client.viewOnly = true;
      s.client
        ..key(31, down: true)
        ..pointerMove(9, 9)
        ..scroll(0, 240)
        ..sendClipboard('no');
      await s.server.settle();
      expect(s.server.received, const [
        KeyMsg(0x61, down: false),
        PointerMsg(0, 1, 1),
      ]);
      expect(s.client.viewOnlyLocked, isFalse);
      s.client.viewOnly = false;
      s.client.key(31, down: true);
      await s.server.settle();
      expect(s.server.received.last, const KeyMsg(0x73, down: true));
      await s.close();
    });

    test('closing releases what is held, then closes the channel', () async {
      final s = await connect();
      s.client
        ..pointerMove(2, 2)
        ..pointerButton(CsrdButton.right, down: true)
        ..key(56, down: true);
      await s.server.settle();
      s.server.received.clear();
      await s.client.close();
      await s.server.clientClosed;
      await s.server.settle();
      expect(s.server.received, const [
        KeyMsg(0xffe9, down: false),
        PointerMsg(0, 2, 2),
      ]);
      expect(await s.client.done, const CsrdCloseReason.local());
    });

    test('closing a view-only session sends no input', () async {
      final s = await connect();
      s.client.pointerMove(2, 2);
      await s.server.settle();
      s.client.viewOnly = true;
      await s.server.settle();
      final before = s.server.received.length;
      await s.client.close();
      await s.server.clientClosed;
      await s.server.settle();
      expect(s.server.received.length, before);
    });

    test('clipboard text goes out as Latin-1 with bare newlines', () async {
      final s = await connect();
      s.client.sendClipboard('naïve ✓\r\nline');
      final m = await s.server.next<CutTextMsg>();
      expect(latin1.decode(m.bytes), 'naïve ?\nline');
      await s.close();
    });

    test('one display; asking for it again asks for a full refresh', () async {
      final s = await connect();
      expect(() => s.client.selectDisplay(1), throwsArgumentError);
      s.client.selectDisplay(0);
      s.server.send([
        ...updateHeader(1),
        ...rawRect(Picture(64, 48), 0, 0, 1, 1),
      ]);
      final f = await s.frame();
      s.client.ackFrame(f.seq);
      expect((await s.server.next<UpdateRequestMsg>()).incremental, isFalse);
      await s.close();
    });
  });

  group('fuzz', () {
    /// The server's whole side of a session, which does not depend on
    /// what the client sends: VNC authentication, then updates using every
    /// encoding, a resize, a cursor, cut text and a bell.
    ({Uint8List bytes, Picture finalScreen}) script() {
      final z = ZrleEncoder();
      final model = Picture(96, 64);
      final b = <int>[
        ...ascii.encode('RFB 003.008\n'),
        1,
        RfbSecurity.vncAuth,
        ...List.generate(16, (i) => i * 3),
        ...be32(0),
        ...serverInit(96, 64, 'fuzz'),
      ];
      final p = busyPicture(96, 64, seed: 11);
      model.blit(0, 0, p);
      b.addAll([
        ...updateHeader(4),
        ...z.wireRect(model, 0, 0, 96, 64, choose: mixedSub),
        ...rectHeader(1, 1, 3, 2, RfbEncoding.cursor),
        ...List.filled(24, 0x55),
        0xe0,
        0xa0,
        ...copyRect(0, 0, 32, 32, 40, 20),
        ...rawRect(model..copyRect(0, 0, 32, 32, 40, 20), 90, 60, 6, 4),
      ]);
      b.addAll([...cutText(latin1.encode('clip')), 2]);
      final q = busyPicture(120, 70, seed: 12);
      final resized = Picture(120, 70)..blit(0, 0, q);
      b.addAll([
        ...updateHeader(0xffff),
        ...rectHeader(0, 0, 120, 70, RfbEncoding.extendedDesktopSize),
        1,
        0,
        0,
        0,
        ...be32(1),
        ...be16(0),
        ...be16(0),
        ...be16(120),
        ...be16(70),
        ...be32(0),
        ...z.wireRect(resized, 0, 0, 120, 70, choose: mixedSub),
        ...copyRect(0, 0, 50, 20, 60, 40),
        ...rectHeader(0, 0, 0, 0, RfbEncoding.lastRect),
      ]);
      resized.copyRect(0, 0, 50, 20, 60, 40);
      return (bytes: Uint8List.fromList(b), finalScreen: resized);
    }

    final whole = script();

    Future<({CsrdCloseReason reason, CpuFramebuffer screen, List<Type> kinds})>
    run(List<int> bytes, {Random? chunker, bool hangUp = true}) async {
      final server = FakeRfbServer(chunker: chunker);
      final client = RfbClient(
        input: server.clientInput,
        output: server.clientOutput,
        timing: fast,
      );
      final screen = CpuFramebuffer();
      final kinds = <Type>[];
      client.events.listen((e) {
        kinds.add(e.runtimeType);
        if (e is CsrdFrameEvent) {
          screen.apply(e.frame);
          client.ackFrame(e.frame.seq);
        }
      });
      unawaited(
        client
            .connect(credentials: (_) async => (username: null, password: 'pw'))
            .catchError((Object _) {}),
      );
      server.send(bytes);
      if (hangUp) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await server.hangUp();
      }
      final reason = await client.done.timeout(const Duration(seconds: 10));
      await Future<void>.delayed(Duration.zero);
      return (reason: reason, screen: screen, kinds: kinds);
    }

    test('the whole script, in one piece and in random pieces, decodes '
        'the same', () async {
      final clean = await run(whole.bytes);
      expect(clean.reason, const CsrdCloseReason.peer());
      expect(firstDifference(clean.screen.bgra, whole.finalScreen.bgra), -1);
      // Each update splits once, at its copy of what its ZRLE rect drew.
      expect(clean.kinds.where((k) => k == CsrdFrameEvent).length, 4);
      for (var seed = 1; seed <= 25; seed++) {
        final chunked = await run(whole.bytes, chunker: Random(seed));
        expect(
          chunked.reason,
          const CsrdCloseReason.peer(),
          reason: 'seed $seed',
        );
        expect(chunked.kinds, clean.kinds, reason: 'seed $seed');
        expect(
          firstDifference(chunked.screen.bgra, whole.finalScreen.bgra),
          -1,
          reason: 'seed $seed',
        );
      }
    });

    test('cut short anywhere, it ends cleanly', () async {
      final rng = Random(7);
      final cuts = {
        for (var i = 0; i < 60; i++) rng.nextInt(whole.bytes.length),
        0,
        5,
        12,
        13,
        30,
        31,
        33,
        whole.bytes.length - 1,
      };
      for (final cut in cuts) {
        final r = await run(whole.bytes.sublist(0, cut), chunker: Random(cut));
        expect(
          r.reason.kind,
          anyOf(CsrdCloseKind.peer, CsrdCloseKind.error),
          reason: 'cut at $cut',
        );
        expect(r.kinds.last, CsrdClosedEvent);
      }
    });

    test('corrupted anywhere, it decodes or closes with an error, and '
        'never throws', () async {
      final rng = Random(99);
      var errors = 0;
      for (var round = 0; round < 150; round++) {
        final bytes = Uint8List.fromList(whole.bytes);
        // Past the handshake, mostly: that is where the parsing is.
        for (var k = 0; k < 1 + rng.nextInt(4); k++) {
          bytes[60 + rng.nextInt(bytes.length - 60)] = rng.nextInt(256);
        }
        final r = await run(bytes, chunker: Random(round));
        if (r.reason.kind == CsrdCloseKind.error) errors++;
        expect(r.kinds.last, CsrdClosedEvent);
      }
      expect(errors, greaterThan(10));
    });
  });
}
