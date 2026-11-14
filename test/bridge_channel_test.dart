import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/bridge/bridge_channel.dart';
import 'package:secure_shell_go/services/bridge/bridge_client_store.dart';
import 'package:secure_shell_go/services/bridge/bridge_locator.dart';

import 'support/bridge_temp_dir.dart';

final _client = BridgeClient(
  id: 'c1',
  name: 'Desk assistant',
  tokenHash: 'unused',
  createdAt: DateTime.utc(2026),
);

Future<BridgeClient?> _verify(String token) async =>
    token == 'good-token' ? _client : null;

/// A raw peer on the channel, speaking lines by hand so the tests see
/// exactly what the listener sends.
class _Peer {
  _Peer(this.socket)
    : _lines = StreamIterator(
        utf8.decoder.bind(socket).transform(const LineSplitter()),
      );

  final Socket socket;
  final StreamIterator<String> _lines;

  static Future<_Peer> connect(BridgeEndpoint endpoint) async {
    final socket = switch (endpoint) {
      BridgeUnixEndpoint(:final path) => await Socket.connect(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
      ),
      BridgeTcpEndpoint(:final port) => await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
      ),
    };
    return _Peer(socket);
  }

  void send(String line) => socket.write('$line\n');

  /// The whole launcher side of the handshake, up to (not including) the
  /// final reply: on tcp, the hello and a check of the proof first.
  Future<void> handshake(
    BridgeEndpoint endpoint, {
    String token = 'good-token',
  }) async {
    if (endpoint is BridgeTcpEndpoint) {
      final nonce = bridgeNonce();
      send(bridgeHelloLine(nonce));
      final answer = await nextJson();
      expect(answer, {'proof': bridgeProof(endpoint.secret, nonce)});
    }
    send(
      bridgeHandshakeLine(
        token: token,
        secret: endpoint is BridgeTcpEndpoint ? endpoint.secret : null,
      ),
    );
  }

  /// The next line, or null once the listener has closed the connection.
  ///
  /// A reset counts as closed: a listener that drops a peer with some of
  /// its bytes still unread resets the connection, which Windows reports
  /// as an error where Linux usually shows an ordinary end.
  Future<String?> next() async {
    try {
      return await _lines.moveNext().timeout(const Duration(seconds: 10))
          ? _lines.current
          : null;
    } on SocketException {
      return null;
    }
  }

  Future<Map<String, Object?>?> nextJson() async {
    final line = await next();
    return line == null ? null : jsonDecode(line) as Map<String, Object?>;
  }

  void destroy() => socket.destroy();
}

void main() {
  late Directory temp;
  late String bridgeDir;

  setUp(() async {
    // Short on purpose: unix socket paths are capped near 100 bytes.
    temp = await bridgeTempDir('ssgb');
    bridgeDir = '${temp.path}/bridge';
  });

  // Runs after each test's own teardown, so its listener is stopped first.
  tearDown(() => deleteTempDir(temp));

  for (final kind in BridgeTransportKind.values) {
    final skip = kind == BridgeTransportKind.unix
        ? skipUnixSocketOnWindows
        : null;
    group('${kind.name} transport', skip: skip, () {
      late BridgeListener listener;
      late List<BridgeConnection> accepted;
      late StreamSubscription<BridgeConnection> sub;

      setUp(() async {
        listener = BridgeListener(
          bridgeDir: bridgeDir,
          verify: _verify,
          transport: kind,
          environment: const {},
          handshakeTimeout: const Duration(milliseconds: 300),
          maxLineBytes: 4096,
          failedHandshakeDelay: Duration.zero,
        );
        accepted = [];
        sub = listener.connections.listen(accepted.add);
        await listener.start();
      });

      tearDown(() async {
        await sub.cancel();
        await listener.stop();
      });

      test('writes the locator file, owner-only, with the endpoint', () async {
        final endpoint = await BridgeLocator(bridgeDir).read();
        expect(endpoint, isNotNull);
        expect(endpoint!.toJson(), listener.endpoint!.toJson());
        if (kind == BridgeTransportKind.unix) {
          expect(endpoint, isA<BridgeUnixEndpoint>());
          final path = (endpoint as BridgeUnixEndpoint).path;
          expect(path, '$bridgeDir/bridge.sock');
          expect(File(path).statSync().mode & 0x1ff, 0x180); // 0600
        } else {
          expect(endpoint, isA<BridgeTcpEndpoint>());
          expect((endpoint as BridgeTcpEndpoint).secret.length, 43);
        }
        // Windows has no POSIX modes; the profile's ACL keeps these private.
        if (!Platform.isWindows) {
          expect(BridgeLocator(bridgeDir).file.statSync().mode & 0x1ff, 0x180);
          expect(Directory(bridgeDir).statSync().mode & 0x1ff, 0x1c0); // 0700
        }
      });

      test('accepts a good handshake and carries lines both ways', () async {
        final peer = await _Peer.connect(listener.endpoint!);
        await peer.handshake(listener.endpoint!);
        // Sent before the reply arrives: must still reach the connection.
        peer.send('{"early":true}');
        expect(await peer.nextJson(), {'ok': true});
        await pumpUntil(() => accepted.isNotEmpty);
        final conn = accepted.single;
        expect(conn.client.id, 'c1');
        final lines = StreamIterator(conn.lines);
        expect(await lines.moveNext(), isTrue);
        expect(lines.current, '{"early":true}');
        peer.send('{"later":1}');
        expect(await lines.moveNext(), isTrue);
        expect(lines.current, '{"later":1}');
        conn.send('{"reply":2}');
        expect(await peer.next(), '{"reply":2}');
        expect(() => conn.send('a\nb'), throwsArgumentError);
        peer.destroy();
        expect(await lines.moveNext(), isFalse);
      });

      test('refuses an unknown token and closes', () async {
        final peer = await _Peer.connect(listener.endpoint!);
        await peer.handshake(listener.endpoint!, token: 'nope');
        final reply = await peer.nextJson();
        expect(reply!['ok'], false);
        expect(reply['error'], contains('not paired'));
        expect(await peer.next(), isNull);
        expect(accepted, isEmpty);
      });

      test('refuses an empty token without asking verify', () async {
        final peer = await _Peer.connect(listener.endpoint!);
        await peer.handshake(listener.endpoint!, token: '');
        expect((await peer.nextJson())!['ok'], false);
        expect(await peer.next(), isNull);
      });

      test('refuses another handshake version', () async {
        final peer = await _Peer.connect(listener.endpoint!);
        peer.send(jsonEncode({'ssg_bridge': 2, 'token': 'good-token'}));
        final reply = await peer.nextJson();
        expect(reply!['ok'], false);
        expect(reply['error'], contains('version'));
      });

      test('refuses something that is not a handshake', () async {
        final peer = await _Peer.connect(listener.endpoint!);
        peer.send('{"jsonrpc":"2.0","id":1,"method":"initialize"}');
        expect((await peer.nextJson())!['ok'], false);
        expect(await peer.next(), isNull);
      });

      test('times a silent peer out', () async {
        final peer = await _Peer.connect(listener.endpoint!);
        final reply = await peer.nextJson();
        expect(reply!['ok'], false);
        expect(reply['error'], contains('timed out'));
        expect(await peer.next(), isNull);
      });

      test('drops a line past the cap, during the handshake', () async {
        final peer = await _Peer.connect(listener.endpoint!);
        peer.socket.add(List<int>.filled(5000, 0x41));
        expect(await peer.next(), isNull);
      });

      test('drops a line past the cap, after the handshake', () async {
        final peer = await _Peer.connect(listener.endpoint!);
        await peer.handshake(listener.endpoint!);
        expect(await peer.nextJson(), {'ok': true});
        await pumpUntil(() => accepted.isNotEmpty);
        final done = accepted.single.lines.toList();
        peer.send('x' * 5000);
        expect(await done, isEmpty);
        expect(await peer.next(), isNull);
      });

      test('drops a line that is not UTF-8', () async {
        final peer = await _Peer.connect(listener.endpoint!);
        peer.socket.add([0xff, 0xfe, 0x0a]);
        expect(await peer.next(), isNull);
      });

      test('stop closes live connections and removes its files', () async {
        final peer = await _Peer.connect(listener.endpoint!);
        await peer.handshake(listener.endpoint!);
        expect(await peer.nextJson(), {'ok': true});
        final endpoint = listener.endpoint!;
        await listener.stop();
        expect(await peer.next(), isNull);
        expect(BridgeLocator(bridgeDir).file.existsSync(), isFalse);
        if (endpoint is BridgeUnixEndpoint) {
          expect(File(endpoint.path).existsSync(), isFalse);
        }
        expect(listener.isRunning, isFalse);
      });

      test('a second listener on the same directory is refused', () async {
        final second = BridgeListener(
          bridgeDir: bridgeDir,
          verify: _verify,
          transport: kind,
          environment: const {},
        );
        await expectLater(second.start(), throwsA(isA<BridgeAlreadyRunning>()));
        // The first one is untouched.
        final peer = await _Peer.connect(listener.endpoint!);
        await peer.handshake(listener.endpoint!);
        expect(await peer.nextJson(), {'ok': true});
      });
    });
  }

  test(
    'a refused start leaves the running instance\'s locator alone',
    () async {
      final first = BridgeListener(
        bridgeDir: bridgeDir,
        verify: _verify,
        transport: platformBridgeTransport,
        environment: const {},
      );
      await first.start();
      addTearDown(first.stop);
      final second = BridgeListener(
        bridgeDir: bridgeDir,
        verify: _verify,
        transport: platformBridgeTransport,
        environment: const {},
      );
      await expectLater(second.start(), throwsA(isA<BridgeAlreadyRunning>()));
      await second.stop();
      expect(BridgeLocator(bridgeDir).file.existsSync(), isTrue);
    },
  );

  test('a failing verify refuses the peer instead of escaping', () async {
    final errors = <Object>[];
    await runZonedGuarded(() async {
      final listener = BridgeListener(
        bridgeDir: bridgeDir,
        verify: (_) async => throw const FileSystemException('disk /secret/x'),
        transport: platformBridgeTransport,
        environment: const {},
      );
      await listener.start();
      addTearDown(listener.stop);
      final peer = await _Peer.connect(listener.endpoint!);
      await peer.handshake(listener.endpoint!);
      final reply = await peer.nextJson();
      expect(reply!['ok'], false);
      expect(jsonEncode(reply), isNot(contains('secret')));
      expect(await peer.next(), isNull);
    }, (e, _) => errors.add(e));
    expect(errors, isEmpty);
  });

  test('stop does not hang on a peer that never reads', () async {
    final listener = BridgeListener(
      bridgeDir: bridgeDir,
      verify: _verify,
      transport: platformBridgeTransport,
      environment: const {},
      // High enough that the backlog below is not dropped first: this is
      // about close() giving up on a peer that never drains.
      maxQueuedOutputBytes: 64 * 1024 * 1024,
    );
    final accepted = <BridgeConnection>[];
    listener.connections.listen(accepted.add);
    await listener.start();
    // A peer that reads nothing past the handshake reply: its socket is
    // paused, so the kernel buffers fill and the listener's writes back up.
    final peer = await _Peer.connect(listener.endpoint!);
    await peer.handshake(listener.endpoint!);
    expect(await peer.nextJson(), {'ok': true});
    await pumpUntil(() => accepted.isNotEmpty);
    final big = 'x' * 500000;
    for (var i = 0; i < 40; i++) {
      accepted.single.send(big);
    }
    await listener.stop().timeout(const Duration(seconds: 8));
    peer.destroy();
  });

  test(
    'tcp refuses a handshake with the wrong secret before the token',
    () async {
      var asked = 0;
      final listener = BridgeListener(
        bridgeDir: bridgeDir,
        verify: (t) async {
          asked++;
          return _verify(t);
        },
        transport: BridgeTransportKind.tcp,
      );
      await listener.start();
      addTearDown(listener.stop);
      final peer = await _Peer.connect(listener.endpoint!);
      final nonce = bridgeNonce();
      peer.send(bridgeHelloLine(nonce));
      expect((await peer.nextJson())!['proof'], isA<String>());
      peer.send(bridgeHandshakeLine(token: 'good-token', secret: 'wrong'));
      final reply = await peer.nextJson();
      expect(reply!['ok'], false);
      expect(reply['error'], contains('out of date'));
      expect(asked, 0);
    },
  );

  test(
    'unix clears a stale socket file left by a crash',
    skip: skipUnixSocketOnWindows,
    () async {
      await Directory(bridgeDir).create(recursive: true);
      // A socket file nobody listens on any more, the way a killed process
      // leaves it. Dart's own ServerSocket unlinks its file on close, so the
      // leftover is made by a process that exits without cleaning up.
      final path = '$bridgeDir/bridge.sock';
      try {
        await Process.run('python3', [
          '-c',
          'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])',
          path,
        ]);
      } on ProcessException {
        // No python3: a plain file refuses connections the same way.
      }
      if (FileSystemEntity.typeSync(path, followLinks: false) ==
          FileSystemEntityType.notFound) {
        await File(path).writeAsString('');
      }
      final listener = BridgeListener(
        bridgeDir: bridgeDir,
        verify: _verify,
        transport: BridgeTransportKind.unix,
      );
      await listener.start();
      addTearDown(listener.stop);
      final peer = await _Peer.connect(listener.endpoint!);
      await peer.handshake(listener.endpoint!);
      expect(await peer.nextJson(), {'ok': true});
    },
  );

  test('tcp treats a stale locator file as stale', () async {
    await Directory(bridgeDir).create(recursive: true);
    // A port that was ours once and now has nobody on it.
    final gone = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = gone.port;
    await gone.close();
    await BridgeLocator(bridgeDir).write(BridgeTcpEndpoint(port, 'old'));
    final listener = BridgeListener(
      bridgeDir: bridgeDir,
      verify: _verify,
      transport: BridgeTransportKind.tcp,
    );
    await listener.start();
    addTearDown(listener.stop);
    expect(listener.isRunning, isTrue);
  });

  test('tcp treats a port taken by something else as stale', () async {
    await Directory(bridgeDir).create(recursive: true);
    // Not ours: answers with a line that is not our reply shape.
    final other = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(other.close);
    other.listen((s) {
      s.write('HTTP/1.0 400 Bad Request\n');
      s.close();
    });
    await BridgeLocator(bridgeDir).write(BridgeTcpEndpoint(other.port, 's'));
    final listener = BridgeListener(
      bridgeDir: bridgeDir,
      verify: _verify,
      transport: BridgeTransportKind.tcp,
    );
    await listener.start();
    addTearDown(listener.stop);
    expect(listener.isRunning, isTrue);
  });

  test('a verified connection nobody is listening for is closed', () async {
    final listener = BridgeListener(
      bridgeDir: bridgeDir,
      verify: _verify,
      transport: BridgeTransportKind.tcp,
    );
    await listener.start();
    addTearDown(listener.stop);
    final peer = await _Peer.connect(listener.endpoint!);
    await peer.handshake(listener.endpoint!);
    expect(await peer.nextJson(), {'ok': true});
    expect(await peer.next(), isNull);
  });

  group('tcp mutual handshake', () {
    late BridgeListener listener;
    late List<String> tokensAsked;

    setUp(() async {
      tokensAsked = [];
      listener = BridgeListener(
        bridgeDir: bridgeDir,
        verify: (t) async {
          tokensAsked.add(t);
          return _verify(t);
        },
        transport: BridgeTransportKind.tcp,
        failedHandshakeDelay: Duration.zero,
      );
      await listener.start();
    });

    tearDown(() => listener.stop());

    test('answers a hello with HMAC-SHA256(secret, nonce)', () async {
      final endpoint = listener.endpoint! as BridgeTcpEndpoint;
      final peer = await _Peer.connect(endpoint);
      const nonce = 'abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG';
      peer.send(bridgeHelloLine(nonce));
      final proof = (await peer.nextJson())!['proof'] as String;
      expect(proof, bridgeProof(endpoint.secret, nonce));
      expect(proof, matches(RegExp(r'^[0-9a-f]{64}$')));
      peer.destroy();
    });

    test('a token sent without a hello first is refused unread', () async {
      final endpoint = listener.endpoint! as BridgeTcpEndpoint;
      final peer = await _Peer.connect(endpoint);
      peer.send(
        bridgeHandshakeLine(token: 'good-token', secret: endpoint.secret),
      );
      final reply = await peer.nextJson();
      expect(reply!['ok'], false);
      expect(reply['error'], contains('version'));
      expect(await peer.next(), isNull);
      expect(tokensAsked, isEmpty);
    });

    test('a hello with a silly nonce is refused', () async {
      for (final nonce in ['short', 'x' * 300]) {
        final peer = await _Peer.connect(listener.endpoint!);
        peer.send(bridgeHelloLine(nonce));
        expect((await peer.nextJson())!['ok'], false, reason: nonce);
      }
    });

    test('dialBridge goes through the whole exchange', () async {
      final accepted = <BridgeConnection>[];
      final sub = listener.connections.listen(accepted.add);
      addTearDown(sub.cancel);
      final link = await dialBridge(listener.endpoint!, token: 'good-token');
      addTearDown(link.socket.destroy);
      await pumpUntil(() => accepted.isNotEmpty);
      expect(tokensAsked, ['good-token']);
    });

    test('the alive probe sends no token', () async {
      expect(
        await bridgeTcpPeerIsLive(listener.endpoint! as BridgeTcpEndpoint),
        isTrue,
      );
      expect(
        await bridgeTcpPeerIsLive(
          BridgeTcpEndpoint(listener.endpoint!.toJson()['port'] as int, 'old'),
        ),
        isFalse,
      );
      expect(tokensAsked, isEmpty);
    });
  });

  group('a stale port held by something that cannot prove the secret', () {
    // Each fake records every byte it is sent, then answers the first line
    // its own way.
    final answers = <String, String?>{
      'a wrong proof': '{"proof":"${'0' * 64}"}',
      'a forged ok': '{"ok":true}',
      'not JSON': 'HTTP/1.0 400 Bad Request',
      'an echo of the hello': null,
      'silence': '',
    };
    for (final MapEntry(key: what, value: answer) in answers.entries) {
      test('$what: never receives the token', () async {
        final received = <int>[];
        final fake = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(fake.close);
        fake.listen((s) {
          var answered = false;
          s.listen((bytes) {
            received.addAll(bytes);
            if (answered || !bytes.contains(0x0a)) return;
            answered = true;
            if (answer == null) {
              s.add(bytes);
            } else if (answer.isNotEmpty) {
              s.write('$answer\n');
            }
          }, onError: (Object _) {});
        });
        final endpoint = BridgeTcpEndpoint(fake.port, 'the-real-secret');
        await expectLater(
          dialBridge(
            endpoint,
            token: 'pairing-token',
            timeout: const Duration(milliseconds: 500),
          ),
          throwsA(
            isA<BridgeDialException>().having(
              (e) => e.message,
              'message',
              anyOf(bridgeNotRunningMessage, bridgeNoAnswerMessage),
            ),
          ),
        );
        expect(
          await bridgeTcpPeerIsLive(
            endpoint,
            timeout: const Duration(milliseconds: 500),
          ),
          isFalse,
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final sent = utf8.decode(received);
        expect(sent, contains('"hello"'));
        expect(sent, isNot(contains('pairing-token')));
        expect(sent, isNot(contains('the-real-secret')));
      });
    }

    test('a wrong proof is reported as not running', () async {
      final fake = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(fake.close);
      fake.listen((s) {
        s.listen((_) => s.write('{"proof":"${'a' * 64}"}\n'));
      });
      await expectLater(
        dialBridge(BridgeTcpEndpoint(fake.port, 's'), token: 't'),
        throwsA(
          isA<BridgeDialException>().having(
            (e) => e.message,
            'message',
            bridgeNotRunningMessage,
          ),
        ),
      );
    });
  });

  test('handshake lines are capped at 4 KiB, MCP lines are not', () async {
    final listener = BridgeListener(
      bridgeDir: bridgeDir,
      verify: _verify,
      transport: platformBridgeTransport,
      environment: const {},
      failedHandshakeDelay: Duration.zero,
    );
    final accepted = <BridgeConnection>[];
    listener.connections.listen(accepted.add);
    await listener.start();
    addTearDown(listener.stop);

    final early = await _Peer.connect(listener.endpoint!);
    early.send('{"ssg_bridge":1,"token":"${'x' * 5000}"}');
    expect(await early.next(), isNull);

    final peer = await _Peer.connect(listener.endpoint!);
    await peer.handshake(listener.endpoint!);
    expect(await peer.nextJson(), {'ok': true});
    await pumpUntil(() => accepted.isNotEmpty);
    final lines = StreamIterator(accepted.single.lines);
    final big = '"${'y' * 100000}"';
    peer.send(big);
    expect(await lines.moveNext(), isTrue);
    expect(lines.current, big);
  });

  test('the handshake cap holds while the token is being looked up', () async {
    final lookup = Completer<BridgeClient?>();
    final listener = BridgeListener(
      bridgeDir: bridgeDir,
      verify: (_) => lookup.future,
      transport: platformBridgeTransport,
      environment: const {},
    );
    final accepted = <BridgeConnection>[];
    listener.connections.listen(accepted.add);
    await listener.start();
    addTearDown(listener.stop);

    final peer = await _Peer.connect(listener.endpoint!);
    await peer.handshake(listener.endpoint!);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    // Still being verified: a line far over 4 KiB, though under the MCP cap.
    peer.send('"${'y' * 100000}"');
    expect(await peer.next(), isNull);

    lookup.complete(_client);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(accepted, isEmpty);
  });

  test('at most 8 peers may be in the handshake at once', () async {
    final listener = BridgeListener(
      bridgeDir: bridgeDir,
      verify: _verify,
      transport: platformBridgeTransport,
      environment: const {},
      handshakeTimeout: const Duration(seconds: 20),
    );
    final accepted = <BridgeConnection>[];
    listener.connections.listen(accepted.add);
    await listener.start();
    addTearDown(listener.stop);

    final silent = <_Peer>[];
    for (var i = 0; i < 8; i++) {
      silent.add(await _Peer.connect(listener.endpoint!));
    }
    // Give the listener time to accept all eight.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final ninth = await _Peer.connect(listener.endpoint!);
    final watch = Stopwatch()..start();
    expect(await ninth.next(), isNull);
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)));

    // A finished handshake frees its slot: one of the eight completes, and
    // a newcomer is let in.
    await silent.first.handshake(listener.endpoint!);
    expect(await silent.first.nextJson(), {'ok': true});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final tenth = await _Peer.connect(listener.endpoint!);
    await tenth.handshake(listener.endpoint!);
    expect(await tenth.nextJson(), {'ok': true});
    for (final p in silent) {
      p.destroy();
    }
  });

  test('a refused handshake is answered only after 500 ms', () async {
    final listener = BridgeListener(
      bridgeDir: bridgeDir,
      verify: _verify,
      transport: platformBridgeTransport,
      environment: const {},
    );
    await listener.start();
    addTearDown(listener.stop);
    final peer = await _Peer.connect(listener.endpoint!);
    final watch = Stopwatch()..start();
    await peer.handshake(listener.endpoint!, token: 'guess');
    final reply = await peer.nextJson();
    expect(reply!['ok'], false);
    expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(480));
  });

  group('a peer that stops reading', () {
    late BridgeListener listener;
    late List<BridgeConnection> accepted;

    setUp(() async {
      listener = BridgeListener(
        bridgeDir: bridgeDir,
        verify: _verify,
        transport: platformBridgeTransport,
        environment: const {},
        maxQueuedOutputBytes: 256 * 1024,
      );
      accepted = [];
      listener.connections.listen(accepted.add);
      await listener.start();
    });

    tearDown(() => listener.stop());

    Future<bool> pushUntilDropped(BridgeConnection conn, int rounds) async {
      var dropped = false;
      conn.lines.listen(null, onDone: () => dropped = true);
      final chunk = 'z' * 64 * 1024;
      for (var i = 0; i < rounds && !dropped; i++) {
        conn.send(chunk);
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return dropped;
    }

    test('is dropped once its replies back up', () async {
      final peer = await _Peer.connect(listener.endpoint!);
      await peer.handshake(listener.endpoint!);
      expect(await peer.nextJson(), {'ok': true});
      await pumpUntil(() => accepted.isNotEmpty);
      // The peer never asks for another line, so its socket is paused.
      expect(await pushUntilDropped(accepted.single, 400), isTrue);
      peer.destroy();
    });

    test('while one that reads is not', () async {
      final link = await dialBridge(listener.endpoint!, token: 'good-token');
      addTearDown(link.socket.destroy);
      var received = 0;
      link.rest.listen((b) => received += b.length);
      await pumpUntil(() => accepted.isNotEmpty);
      expect(await pushUntilDropped(accepted.single, 100), isFalse);
      await pumpUntil(() => received >= 100 * 64 * 1024);
    });
  });

  group('a bind that fails', () {
    for (final kind in BridgeTransportKind.values) {
      test('${kind.name}: is a BridgeChannelException, with nothing left '
          'behind', () async {
        final listener = BridgeListener(
          bridgeDir: bridgeDir,
          verify: _verify,
          transport: kind,
          environment: const {},
          bind: (address, port) async => throw const SocketException(
            'Only one usage of each socket address is permitted',
          ),
        );
        await expectLater(
          listener.start(),
          throwsA(
            isA<BridgeChannelException>().having(
              (e) => e.message,
              'message',
              contains('could not listen'),
            ),
          ),
        );
        expect(listener.isRunning, isFalse);
        expect(listener.endpoint, isNull);
        expect(listener.locator.file.existsSync(), isFalse);
        await listener.stop();
      });
    }
  });

  group('a peer that hangs up while the launcher writes to it', () {
    // A write to a closed peer fails on the socket's `done`; when nothing
    // watches that it is an uncaught error, which kills the launcher with a
    // stack trace instead of its readable reply.
    Future<List<Object>> uncaughtDuring(Future<void> Function() body) async {
      final uncaught = <Object>[];
      final finished = Completer<void>();
      runZonedGuarded(() async {
        try {
          await body();
        } finally {
          // Late write errors surface a moment after the call returns.
          await Future<void>.delayed(const Duration(milliseconds: 300));
          finished.complete();
        }
      }, (e, st) => uncaught.add(e));
      await finished.future;
      return uncaught;
    }

    test('dialBridge and the alive probe report not running, quietly', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      var n = 0;
      server.listen((s) {
        // Alternately: close at once, and send junk first then close.
        if ((n++).isOdd) s.add(const [1, 2, 3]);
        s.destroy();
      });
      final endpoint = BridgeTcpEndpoint(server.port, 'secret');
      final uncaught = await uncaughtDuring(() async {
        for (var i = 0; i < 12; i++) {
          await expectLater(
            dialBridge(
              endpoint,
              token: 'good-token',
              timeout: const Duration(seconds: 2),
            ),
            throwsA(isA<BridgeDialException>()),
          );
          expect(
            await bridgeTcpPeerIsLive(
              endpoint,
              timeout: const Duration(seconds: 2),
            ),
            isFalse,
          );
        }
      });
      expect(uncaught, isEmpty);
    });
  });

  test('the listener survives peers that leave before its reply', () async {
    final uncaught = <Object>[];
    final finished = Completer<void>();
    runZonedGuarded(() async {
      final listener = BridgeListener(
        bridgeDir: bridgeDir,
        verify: _verify,
        transport: BridgeTransportKind.tcp,
        failedHandshakeDelay: const Duration(milliseconds: 20),
      );
      try {
        await listener.start();
        final endpoint = listener.endpoint! as BridgeTcpEndpoint;
        for (var i = 0; i < 30; i++) {
          final peer = await _Peer.connect(endpoint);
          // A hello (answered) or junk (refused), then gone before either
          // reply can be read.
          peer.send(
            i.isEven ? bridgeHelloLine(bridgeNonce()) : 'not a handshake',
          );
          peer.destroy();
        }
        await Future<void>.delayed(const Duration(milliseconds: 400));
        expect(listener.isRunning, isTrue);
      } finally {
        await listener.stop();
        finished.complete();
      }
    }, (e, st) {
      uncaught.add(e);
      if (!finished.isCompleted) finished.complete();
    });
    await finished.future;
    expect(uncaught, isEmpty);
  });

  group('bridgeSocketPath', () {
    test('uses the bridge directory when the path is short enough', () {
      expect(
        bridgeSocketPath('/home/u/.local/share/x/bridge', const {}),
        '/home/u/.local/share/x/bridge/bridge.sock',
      );
    });

    test('falls back to XDG_RUNTIME_DIR past 100 bytes', () {
      final long = '/home/u/${'d' * 100}/bridge';
      expect(
        bridgeSocketPath(long, const {'XDG_RUNTIME_DIR': '/run/user/1000'}),
        '/run/user/1000/secureshellgo-bridge.sock',
      );
    });

    test('counts bytes, not characters', () {
      // 40 three-byte characters: 40 chars, 120 bytes.
      final dir = '/h/${'€' * 40}';
      expect(
        bridgeSocketPath(dir, const {'XDG_RUNTIME_DIR': '/run/user/1'}),
        '/run/user/1/secureshellgo-bridge.sock',
      );
    });

    test('refuses rather than falling back to a shared directory', () {
      final long = '/home/u/${'d' * 100}/bridge';
      expect(
        () => bridgeSocketPath(long, const {}),
        throwsA(isA<BridgeChannelException>()),
      );
      expect(
        () => bridgeSocketPath(long, const {'XDG_RUNTIME_DIR': 'relative'}),
        throwsA(isA<BridgeChannelException>()),
      );
    });

    test('a Flatpak falls back to the directory its instances share', () {
      // The Flatpak's real bridge directory for a 9-letter user name: 108
      // bytes with the socket's name, past the limit.
      const dir =
          '/home/dhivakar/.var/app/com.dhivalabs.secure_shell_go/data/'
          'com.dhivalabs.secure_shell_go/bridge';
      expect(
        bridgeSocketPath(dir, const {
          'XDG_RUNTIME_DIR': '/run/user/1000',
          'FLATPAK_ID': 'com.dhivalabs.secure_shell_go',
        }),
        '/run/user/1000/app/com.dhivalabs.secure_shell_go/'
        'secureshellgo-bridge.sock',
      );
      // Short enough: the bridge directory, as everywhere else.
      expect(
        bridgeSocketPath('/h/bridge', const {
          'XDG_RUNTIME_DIR': '/run/user/1000',
          'FLATPAK_ID': 'com.dhivalabs.secure_shell_go',
        }),
        '/h/bridge/bridge.sock',
      );
    });

    test('a Flatpak ID that is not a plain name is not used', () {
      final long = '/home/u/${'d' * 100}/bridge';
      for (final id in ['../x', 'a/b', '..']) {
        expect(
          () => bridgeSocketPath(long, {
            'XDG_RUNTIME_DIR': '/run/user/1000',
            'FLATPAK_ID': id,
          }),
          throwsA(isA<BridgeChannelException>()),
        );
      }
    });
  });
}

Future<void> pumpUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition never became true');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
