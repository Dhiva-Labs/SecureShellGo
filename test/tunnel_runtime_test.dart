import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/models/tunnel_profile.dart';
import 'package:secure_shell_go/services/ssh_service.dart';
import 'package:secure_shell_go/services/tunnel_runtime.dart';
import 'package:secure_shell_go/services/tunnel_store.dart';

/// The tunnels here are real: real listeners, real loopback sockets, real
/// half-closes. Only the SSH connection is faked — [_FakeCarrier] answers a
/// `forwardLocal` by dialling an in-process service on loopback, which is
/// exactly what the far side of a forward looks like from the runtime's point
/// of view, and means the byte pumping and the EOF handling are exercised
/// rather than described.
void main() {
  late Directory tempDir;
  late TunnelStore store;
  late ServerSocket service;
  late Host savedHost;
  TunnelRuntime? runtime;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tunnel_runtime_test');
    store = TunnelStore(file: File('${tempDir.path}/tunnels.json'));
    service = await _startEchoService();
    savedHost = const Host(
      id: 'host-1',
      label: 'Bastion',
      hostname: 'bastion.example.com',
      port: 22,
      username: 'ops',
      authMethod: SshAuthMethod.password,
    );
  });

  tearDown(() async {
    await runtime?.dispose();
    runtime = null;
    await service.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  TunnelProfile profile({
    String id = 'tunnel-1',
    TunnelType type = TunnelType.local,
    String localHost = TunnelProfile.loopback,
    int localPort = 0,
    String remoteHost = 'db.internal',
    int remotePort = 5432,
  }) {
    return TunnelProfile(
      id: id,
      name: 'Test tunnel',
      hostId: 'host-1',
      type: type,
      localHost: localHost,
      localPort: localPort,
      remoteHost: remoteHost,
      remotePort: remotePort,
    );
  }

  TunnelRuntime build({
    TunnelCarrier? session,
    TunnelConnector? connect,
    Stream<void>? sessionChanges,
    TunnelCarrier? Function(String hostId)? findSessionCarrier,
    TunnelRetryScheduler? retryScheduler,
    Future<Host?> Function(String hostId)? lookupHost,
    Future<SshCredentials?> Function(String hostId)? loadCredentials,
  }) {
    return runtime = TunnelRuntime(
      profiles: store,
      support: TunnelSupport(
        lookupHost: lookupHost ?? (id) async => savedHost,
        loadCredentials: loadCredentials ??
            (id) async => const SshCredentials(password: 'hunter2'),
        connect: connect,
        findSessionCarrier:
            findSessionCarrier ?? (session == null ? null : (id) => session),
        sessionChanges: sessionChanges,
      ),
      retryScheduler: retryScheduler ?? Timer.new,
    );
  }

  group('local forwards', () {
    test('carry bytes both ways, and count them in each direction', () async {
      final carrier = _FakeCarrier(forwardTo: service.port);
      final tunnels = build(session: carrier);
      await store.add(profile(remotePort: 5432));

      await tunnels.start('tunnel-1');
      final started = tunnels.statusFor('tunnel-1');
      expect(started.state, TunnelState.active);
      expect(started.message, isNull);
      expect(started.dedicated, isFalse);

      final client = await Socket.connect(
        InternetAddress.loopbackIPv4,
        started.boundPort!,
      );
      client.add(utf8.encode('PING'));
      await client.flush();
      // Half-close: everything this client has to say is said. The echo
      // service only answers once it sees this EOF, so a reply arriving at
      // all is the proof that the shutdown was propagated on its own rather
      // than collapsing the whole connection.
      unawaited(client.close());
      final reply = utf8.decode(await _drain(client));

      expect(reply, 'PONG:PING');
      expect(carrier.requests, ['db.internal:5432']);

      final after = tunnels.statusFor('tunnel-1');
      expect(after.bytesUp, 4);
      expect(after.bytesDown, 'PONG:PING'.length);
      expect(after.totalConnections, 1);
      await _eventually(
        () => tunnels.statusFor('tunnel-1').connections == 0,
        'the finished connection should have been let go',
      );
    });

    test('carry several connections at once, and count them', () async {
      final carrier = _FakeCarrier(forwardTo: service.port);
      final tunnels = build(session: carrier);
      await store.add(profile());
      await tunnels.start('tunnel-1');
      final port = tunnels.statusFor('tunnel-1').boundPort!;

      final clients = [
        for (var i = 0; i < 3; i++)
          await Socket.connect(InternetAddress.loopbackIPv4, port),
      ];
      await _eventually(
        () => tunnels.statusFor('tunnel-1').connections == 3,
        'all three connections should be open at once',
      );

      for (final client in clients) {
        client.add(utf8.encode('x'));
        await client.flush();
        unawaited(client.close());
        expect(utf8.decode(await _drain(client)), 'PONG:x');
      }
      expect(tunnels.statusFor('tunnel-1').totalConnections, 3);
    });

    test('stay up when one connection cannot be opened at the far end',
        () async {
      final carrier = _FakeCarrier(forwardTo: service.port)
        ..refuseForward = true;
      final tunnels = build(session: carrier);
      await store.add(profile());
      await tunnels.start('tunnel-1');
      final port = tunnels.statusFor('tunnel-1').boundPort!;

      final client = await Socket.connect(InternetAddress.loopbackIPv4, port);
      expect(await _drain(client), isEmpty);

      await _eventually(
        () => tunnels.statusFor('tunnel-1').message != null,
        'the failed connection should have been noted',
      );
      final status = tunnels.statusFor('tunnel-1');
      // Still listening: one connection failing is not the tunnel failing.
      expect(status.state, TunnelState.active);
      expect(status.message, contains('db.internal:5432'));
    });

    test('stop closes the listener and the connections through it', () async {
      final carrier = _FakeCarrier(forwardTo: service.port);
      final tunnels = build(session: carrier);
      await store.add(profile());
      await tunnels.start('tunnel-1');
      final port = tunnels.statusFor('tunnel-1').boundPort!;
      final client = await Socket.connect(InternetAddress.loopbackIPv4, port);

      await tunnels.stop('tunnel-1');

      expect(tunnels.statusFor('tunnel-1').state, TunnelState.stopped);
      expect(tunnels.statusFor('tunnel-1').connections, 0);
      // The live connection was torn down with the listener.
      await _drain(client);
      await expectLater(
        Socket.connect(InternetAddress.loopbackIPv4, port,
            timeout: const Duration(seconds: 2)),
        throwsA(isA<SocketException>()),
      );
    });

    test('a busy port is refused with a message, not a crash', () async {
      final blocker = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(blocker.close);

      final tunnels = build(session: _FakeCarrier(forwardTo: service.port));
      await store.add(profile(localPort: blocker.port));

      await tunnels.start('tunnel-1');

      final status = tunnels.statusFor('tunnel-1');
      expect(status.state, TunnelState.error);
      expect(status.message, contains('already in use'));
      expect(status.message, contains('${blocker.port}'));
    });

    test('a tunnel that is already running is not started twice', () async {
      final tunnels = build(session: _FakeCarrier(forwardTo: service.port));
      await store.add(profile());
      await tunnels.start('tunnel-1');
      final port = tunnels.statusFor('tunnel-1').boundPort;

      await tunnels.start('tunnel-1');

      expect(tunnels.statusFor('tunnel-1').boundPort, port);
      expect(tunnels.statusFor('tunnel-1').state, TunnelState.active);
    });
  });

  group('remote forwards', () {
    test('dial the local target when the server hands a connection back',
        () async {
      final carrier = _FakeCarrier(forwardTo: service.port);
      final tunnels = build(session: carrier);
      await store.add(
        profile(
          type: TunnelType.remote,
          localPort: service.port,
          remoteHost: '127.0.0.1',
          remotePort: 9000,
        ),
      );

      await tunnels.start('tunnel-1');
      expect(tunnels.statusFor('tunnel-1').state, TunnelState.active);
      expect(tunnels.statusFor('tunnel-1').boundPort, 9000);

      // The server accepted a connection over there and forwarded it here.
      final pair = await _socketPair();
      carrier.remoteListener!.accept(_SocketChannel(pair.channelSide));

      pair.testSide.add(utf8.encode('PING'));
      await pair.testSide.flush();
      unawaited(pair.testSide.close());
      expect(utf8.decode(await _drain(pair.testSide)), 'PONG:PING');

      final status = tunnels.statusFor('tunnel-1');
      expect(status.totalConnections, 1);
      expect(status.bytesDown, 4);
      expect(status.bytesUp, 'PONG:PING'.length);
    });

    test('a server that refuses to listen is reported, with what to check',
        () async {
      final carrier = _FakeCarrier(forwardTo: service.port)
        ..refuseRemote = true;
      final tunnels = build(session: carrier);
      await store.add(profile(type: TunnelType.remote, remotePort: 9000));

      await tunnels.start('tunnel-1');

      final status = tunnels.statusFor('tunnel-1');
      expect(status.state, TunnelState.error);
      expect(status.message, contains('refused to listen on port 9000'));
      expect(status.message, contains('AllowTcpForwarding'));
    });
  });

  group('dynamic forwards', () {
    test('complete a SOCKS5 CONNECT and then carry the connection', () async {
      final carrier = _FakeCarrier(forwardTo: service.port);
      final tunnels = build(session: carrier);
      await store.add(profile(type: TunnelType.dynamic));
      await tunnels.start('tunnel-1');
      final port = tunnels.statusFor('tunnel-1').boundPort!;

      final client = await Socket.connect(InternetAddress.loopbackIPv4, port);
      final reader = _Reader(client);

      client.add([0x05, 0x01, 0x00]);
      expect(await reader.take(2), [0x05, 0x00]);

      client.add([
        0x05, 0x01, 0x00, 0x03,
        11, ...'example.com'.codeUnits,
        0x00, 0x50,
      ]);
      final reply = await reader.take(10);
      expect(reply.sublist(0, 4), [0x05, 0x00, 0x00, 0x01]);
      expect(carrier.requests, ['example.com:80']);

      client.add(utf8.encode('PING'));
      await client.flush();
      unawaited(client.close());
      expect(utf8.decode(await reader.rest()), 'PONG:PING');
    });

    test('carry bytes the client pipelined behind its CONNECT', () async {
      final carrier = _FakeCarrier(forwardTo: service.port);
      final tunnels = build(session: carrier);
      await store.add(profile(type: TunnelType.dynamic));
      await tunnels.start('tunnel-1');
      final port = tunnels.statusFor('tunnel-1').boundPort!;

      final client = await Socket.connect(InternetAddress.loopbackIPv4, port);
      final reader = _Reader(client);
      client.add([0x05, 0x01, 0x00]);
      expect(await reader.take(2), [0x05, 0x00]);

      // Request and payload in one write, the way a client that does not
      // wait for the reply sends them. The payload must not be swallowed by
      // the handshake reader.
      client.add([
        0x05, 0x01, 0x00, 0x01,
        127, 0, 0, 1,
        0x00, 0x50,
        ...utf8.encode('PING'),
      ]);
      await client.flush();
      await reader.take(10);
      unawaited(client.close());

      expect(utf8.decode(await reader.rest()), 'PONG:PING');
    });

    test('refuse a client that will not go unauthenticated, cleanly',
        () async {
      final tunnels = build(session: _FakeCarrier(forwardTo: service.port));
      await store.add(profile(type: TunnelType.dynamic));
      await tunnels.start('tunnel-1');
      final port = tunnels.statusFor('tunnel-1').boundPort!;

      final client = await Socket.connect(InternetAddress.loopbackIPv4, port);
      final reader = _Reader(client);
      client.add([0x05, 0x02, 0x01, 0x02]);

      expect(await reader.take(2), [0x05, 0xFF]);
      // Told, then closed — not left hanging.
      expect(await reader.rest(), isEmpty);
      // And the listener is still up for the next client.
      expect(tunnels.statusFor('tunnel-1').state, TunnelState.active);
    });

    test('refuse BIND, and an address type nobody supports', () async {
      final tunnels = build(session: _FakeCarrier(forwardTo: service.port));
      await store.add(profile(type: TunnelType.dynamic));
      await tunnels.start('tunnel-1');
      final port = tunnels.statusFor('tunnel-1').boundPort!;

      final bind = await Socket.connect(InternetAddress.loopbackIPv4, port);
      final bindReader = _Reader(bind);
      bind.add([0x05, 0x01, 0x00]);
      await bindReader.take(2);
      bind.add([0x05, 0x02, 0x00, 0x01, 127, 0, 0, 1, 0x00, 0x50]);
      expect((await bindReader.take(10))[1], 0x07);

      final odd = await Socket.connect(InternetAddress.loopbackIPv4, port);
      final oddReader = _Reader(odd);
      odd.add([0x05, 0x01, 0x00]);
      await oddReader.take(2);
      odd.add([0x05, 0x01, 0x00, 0x09, 0, 0, 0, 0, 0x00, 0x50]);
      expect((await oddReader.take(10))[1], 0x08);
    });

    test('report a destination the server cannot reach', () async {
      final carrier = _FakeCarrier(forwardTo: service.port)
        ..refuseForward = true;
      final tunnels = build(session: carrier);
      await store.add(profile(type: TunnelType.dynamic));
      await tunnels.start('tunnel-1');
      final port = tunnels.statusFor('tunnel-1').boundPort!;

      final client = await Socket.connect(InternetAddress.loopbackIPv4, port);
      final reader = _Reader(client);
      client.add([0x05, 0x01, 0x00]);
      await reader.take(2);
      client.add([0x05, 0x01, 0x00, 0x01, 10, 0, 0, 9, 0x1F, 0x90]);

      expect((await reader.take(10))[1], 0x04);
    });
  });

  group('carriers', () {
    test('reuse a live session rather than opening a second connection',
        () async {
      var connects = 0;
      final tunnels = build(
        session: _FakeCarrier(forwardTo: service.port),
        connect: ({
          required host,
          required credentials,
          required verifyHostKey,
        }) async {
          connects++;
          return _FakeCarrier(forwardTo: service.port, isDedicated: true);
        },
      );
      await store.add(profile());

      await tunnels.start('tunnel-1');

      expect(connects, 0);
      expect(tunnels.statusFor('tunnel-1').dedicated, isFalse);
    });

    test('open a dedicated connection when no session is up', () async {
      final opened = <_FakeCarrier>[];
      final tunnels = build(
        connect: ({
          required host,
          required credentials,
          required verifyHostKey,
        }) async {
          final carrier = _FakeCarrier(
            forwardTo: service.port,
            isDedicated: true,
          );
          opened.add(carrier);
          return carrier;
        },
      );
      await store.add(profile());

      await tunnels.start('tunnel-1');

      expect(tunnels.statusFor('tunnel-1').state, TunnelState.active);
      expect(tunnels.statusFor('tunnel-1').dedicated, isTrue);
      expect(opened, hasLength(1));

      // Stopping closes what the tunnel opened, and only that.
      await tunnels.stop('tunnel-1');
      expect(opened.single.released, isTrue);
    });

    test('stopping never closes a session the user is working in', () async {
      final carrier = _FakeCarrier(forwardTo: service.port);
      final tunnels = build(session: carrier);
      await store.add(profile());
      await tunnels.start('tunnel-1');

      await tunnels.stop('tunnel-1');

      expect(carrier.released, isFalse);
      expect(carrier.isClosed, isFalse);
    });

    test('a tunnel whose saved host was deleted says so', () async {
      final tunnels = build(
        session: _FakeCarrier(forwardTo: service.port),
        lookupHost: (id) async => null,
      );
      await store.add(profile());

      await tunnels.start('tunnel-1');

      final status = tunnels.statusFor('tunnel-1');
      expect(status.state, TunnelState.error);
      expect(status.message, contains('has been deleted'));
    });

    test('a host with no saved credentials says what to go and fix', () async {
      final tunnels = build(
        connect: ({
          required host,
          required credentials,
          required verifyHostKey,
        }) async =>
            _FakeCarrier(forwardTo: service.port, isDedicated: true),
        loadCredentials: (id) async => null,
      );
      await store.add(profile());

      await tunnels.start('tunnel-1');

      expect(
        tunnels.statusFor('tunnel-1').message,
        contains('No saved credentials'),
      );
    });

    test('with nothing to ride on, it says so instead of failing obscurely',
        () async {
      final tunnels = build();
      await store.add(profile());

      await tunnels.start('tunnel-1');

      expect(
        tunnels.statusFor('tunnel-1').message,
        contains('no open session'),
      );
    });
  });

  group('losing the connection underneath', () {
    test('a session-carried tunnel waits, then re-listens on the new '
        'transport', () async {
      var carrier = _FakeCarrier(forwardTo: service.port);
      final sessions = StreamController<void>.broadcast();
      addTearDown(sessions.close);

      final tunnels = build(
        findSessionCarrier: (id) => carrier,
        sessionChanges: sessions.stream,
      );
      await store.add(profile());
      await tunnels.start('tunnel-1');
      expect(tunnels.statusFor('tunnel-1').state, TunnelState.active);

      carrier.die();
      await _eventually(
        () => tunnels.statusFor('tunnel-1').state == TunnelState.error,
        'the tunnel should notice its transport dying',
      );
      final dropped = tunnels.statusFor('tunnel-1');
      expect(dropped.awaitingSession, isTrue);
      expect(dropped.message, contains('reconnects'));

      // A change on the same dead transport is not a reconnection.
      sessions.add(null);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(tunnels.statusFor('tunnel-1').state, TunnelState.error);

      // The session adopted a new transport — this is the notification
      // `SessionController.adoptTransport` publishes.
      carrier = _FakeCarrier(forwardTo: service.port);
      sessions.add(null);
      await _eventually(
        () => tunnels.statusFor('tunnel-1').state == TunnelState.active,
        'the tunnel should adopt the session\'s new transport',
      );
      expect(tunnels.statusFor('tunnel-1').awaitingSession, isFalse);

      // And it is genuinely listening again.
      final client = await Socket.connect(
        InternetAddress.loopbackIPv4,
        tunnels.statusFor('tunnel-1').boundPort!,
      );
      client.add(utf8.encode('PING'));
      await client.flush();
      unawaited(client.close());
      expect(utf8.decode(await _drain(client)), 'PONG:PING');
    });

    test('a dedicated tunnel re-dials on its own', () async {
      final opened = <_FakeCarrier>[];
      final tunnels = build(
        connect: ({
          required host,
          required credentials,
          required verifyHostKey,
        }) async {
          final carrier = _FakeCarrier(
            forwardTo: service.port,
            isDedicated: true,
          );
          opened.add(carrier);
          return carrier;
        },
        retryScheduler: (delay, fire) {
          fire();
          return Timer(Duration.zero, () {});
        },
      );
      await store.add(profile());
      await tunnels.start('tunnel-1');

      opened.single.die();

      await _eventually(
        () =>
            opened.length >= 2 &&
            tunnels.statusFor('tunnel-1').state == TunnelState.active,
        'the tunnel should have opened a replacement connection',
      );
      // Exactly one replacement: a tunnel that re-dialled in a loop would
      // pass the check above and still be wrong.
      expect(opened, hasLength(2));
    });

    test('a dedicated tunnel gives up eventually, and says how to retry',
        () async {
      var attempts = 0;
      final tunnels = build(
        connect: ({
          required host,
          required credentials,
          required verifyHostKey,
        }) async {
          attempts++;
          if (attempts == 1) {
            return _FakeCarrier(forwardTo: service.port, isDedicated: true);
          }
          throw const SshConnectionException('Connection refused by host.');
        },
        retryScheduler: (delay, fire) {
          fire();
          return Timer(Duration.zero, () {});
        },
      );
      await store.add(profile());
      await tunnels.start('tunnel-1');
      final carrier = tunnels.statusFor('tunnel-1');
      expect(carrier.dedicated, isTrue);

      // Every re-dial fails from here.
      await tunnels.stop('tunnel-1');
      await tunnels.start('tunnel-1');
      await _eventually(
        () => tunnels.statusFor('tunnel-1').message?.contains(
                  'Connection refused',
                ) ??
            false,
        'the failure should be reported in the tunnel\'s own words',
      );
      expect(tunnels.statusFor('tunnel-1').state, TunnelState.error);
    });
  });

  group('describeBindError', () {
    test('names the port when something else already has it', () {
      const error = SocketException(
        'Failed to create server socket',
        osError: OSError('Address already in use', 98),
      );
      final message = describeBindError(error, '127.0.0.1', 8080);
      expect(message, contains('8080'));
      expect(message, contains('already in use'));
    });

    test('explains a privileged port rather than just refusing it', () {
      const error = SocketException(
        'Failed to create server socket',
        osError: OSError('Permission denied', 13),
      );
      expect(
        describeBindError(error, '127.0.0.1', 80),
        contains('privileged'),
      );
      expect(
        describeBindError(error, '127.0.0.1', 8080),
        isNot(contains('privileged')),
      );
    });

    test('explains an address this device does not have', () {
      const error = SocketException(
        'Failed to create server socket',
        osError: OSError('Cannot assign requested address', 99),
      );
      expect(
        describeBindError(error, '10.1.2.3', 8080),
        contains('10.1.2.3'),
      );
    });

    test('falls back to what the system said', () {
      const error = SocketException(
        'Failed to create server socket',
        osError: OSError('Some novel failure', 4242),
      );
      expect(
        describeBindError(error, '127.0.0.1', 8080),
        contains('Some novel failure'),
      );
    });
  });
}

// ------------------------------------------------------------------ helpers

/// Stands in for the service on the far side of the tunnel: reads until the
/// client says it is finished, *then* answers and closes. Only a connection
/// whose half-close was propagated one direction at a time ever sees a reply.
Future<ServerSocket> _startEchoService() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((socket) => unawaited(_serve(socket)));
  return server;
}

Future<void> _serve(Socket socket) async {
  try {
    final received = <int>[];
    await socket.forEach(received.addAll);
    socket.add(utf8.encode('PONG:${utf8.decode(received)}'));
    await socket.flush();
    await socket.close();
  } catch (_) {
    socket.destroy();
  }
}

/// Two connected sockets: one for the test to drive, one to hand to the
/// runtime as though the SSH server had forwarded it back.
Future<({Socket testSide, Socket channelSide})> _socketPair() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final connecting = Socket.connect(InternetAddress.loopbackIPv4, server.port);
  final accepted = await server.first;
  final client = await connecting;
  await server.close();
  return (testSide: client, channelSide: accepted);
}

Future<List<int>> _drain(Stream<List<int>> source) =>
    source.fold<List<int>>([], (all, chunk) => all..addAll(chunk));

Future<void> _eventually(bool Function() condition, String reason) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail(reason);
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Reads exact byte counts off the test's own end of a socket, so a SOCKS
/// handshake can be stepped through message by message.
class _Reader {
  _Reader(Stream<List<int>> source) {
    source.listen(
      (chunk) {
        _buffer.addAll(chunk);
        _wake();
      },
      onDone: () {
        _done = true;
        _wake();
      },
      onError: (Object _) {
        _done = true;
        _wake();
      },
    );
  }

  final List<int> _buffer = [];
  Completer<void>? _waiting;
  var _done = false;

  void _wake() {
    final waiting = _waiting;
    _waiting = null;
    if (waiting != null && !waiting.isCompleted) waiting.complete();
  }

  Future<List<int>> take(int count) async {
    while (_buffer.length < count) {
      if (_done) fail('the connection closed after ${_buffer.length} bytes');
      await (_waiting = Completer<void>()).future;
    }
    return [for (var i = 0; i < count; i++) _buffer.removeAt(0)];
  }

  /// Everything else, once the far end has closed.
  Future<List<int>> rest() async {
    while (!_done) {
      await (_waiting = Completer<void>()).future;
    }
    return List<int>.from(_buffer);
  }
}

/// A [TunnelCarrier] with no SSH in it: `forwardLocal` dials an in-process
/// service on loopback, which is what the runtime would get back from a real
/// `direct-tcpip` channel.
class _FakeCarrier implements TunnelCarrier {
  _FakeCarrier({required this.forwardTo, this.isDedicated = false});

  /// The port every forward is answered with, whatever was asked for.
  final int forwardTo;

  @override
  final bool isDedicated;

  /// What was asked for, as `host:port`, in order.
  final List<String> requests = [];

  bool refuseForward = false;
  bool refuseRemote = false;
  bool released = false;
  _FakeRemoteListener? remoteListener;

  final Completer<void> _done = Completer<void>();
  final List<Socket> _channels = [];
  var _closed = false;

  @override
  Object get identity => this;

  @override
  bool get isClosed => _closed;

  @override
  Future<void> get done => _done.future;

  @override
  Future<SSHSocket> forwardLocal(String host, int port) async {
    requests.add('$host:$port');
    if (refuseForward) {
      throw SSHChannelOpenError(1, 'administratively prohibited');
    }
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      forwardTo,
    );
    _channels.add(socket);
    return _SocketChannel(socket);
  }

  @override
  Future<TunnelRemoteListener?> forwardRemote(String host, int port) async {
    if (refuseRemote) return null;
    return remoteListener = _FakeRemoteListener(port);
  }

  @override
  void release() {
    released = true;
    die();
  }

  /// The transport dying underneath the tunnel.
  void die() {
    if (_closed) return;
    _closed = true;
    if (!_done.isCompleted) _done.complete();
    for (final channel in _channels) {
      channel.destroy();
    }
  }
}

class _FakeRemoteListener implements TunnelRemoteListener {
  _FakeRemoteListener(this.port);

  @override
  final int port;

  final StreamController<SSHSocket> _connections =
      StreamController<SSHSocket>();

  @override
  Stream<SSHSocket> get connections => _connections.stream;

  /// The server accepted something over there.
  void accept(SSHSocket channel) => _connections.add(channel);

  @override
  void close() {
    if (!_connections.isClosed) unawaited(_connections.close());
  }
}

/// A plain socket dressed up as a forwarded SSH channel.
class _SocketChannel implements SSHSocket {
  _SocketChannel(this.socket);

  final Socket socket;

  @override
  Stream<Uint8List> get stream => socket;

  @override
  StreamSink<List<int>> get sink => socket;

  @override
  Future<void> get done => socket.done.then((_) {});

  @override
  Future<void> close() async {
    await socket.close();
  }

  @override
  void destroy() => socket.destroy();

  @override
  Future<void> flush() => socket.flush();
}
