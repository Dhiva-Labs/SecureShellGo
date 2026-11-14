import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/services/bridge/bridge_audit.dart';
import 'package:secure_shell_go/services/bridge/bridge_channel.dart';
import 'package:secure_shell_go/services/bridge/bridge_client_store.dart';
import 'package:secure_shell_go/services/bridge/bridge_connections.dart';
import 'package:secure_shell_go/services/bridge/bridge_locator.dart';
import 'package:secure_shell_go/services/bridge/bridge_policy.dart';
import 'package:secure_shell_go/services/bridge/bridge_redactor.dart';
import 'package:secure_shell_go/services/bridge/bridge_service.dart';
import 'package:secure_shell_go/services/bridge/bridge_tools.dart';
import 'package:secure_shell_go/services/settings_store.dart';

import 'fake_exec_session.dart';
import 'support/bridge_fakes.dart';

/// One assistant on the far side of the launcher: MCP lines in and out.
class _Peer {
  _Peer(this.link) {
    link.rest
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            final message = jsonDecode(line) as Map<String, Object?>;
            received.add(message);
            _replies.remove(message['id'])?.complete(message);
          },
          onDone: () => closed.complete(),
          onError: (Object _) {
            if (!closed.isCompleted) closed.complete();
          },
        );
  }

  final BridgeLink link;
  final Completer<void> closed = Completer<void>();
  final List<Map<String, Object?>> received = [];
  final Map<Object?, Completer<Map<String, Object?>>> _replies = {};
  var _id = 0;

  Future<Map<String, Object?>> request(
    String method, [
    Map<String, Object?>? params,
  ]) {
    final id = ++_id;
    final reply = _replies[id] = Completer<Map<String, Object?>>();
    link.socket.add(
      utf8.encode(
        '${jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': ?params})}\n',
      ),
    );
    return reply.future.timeout(const Duration(seconds: 5));
  }

  Future<({String text, bool isError})> callTool(
    String name, [
    Map<String, Object?> args = const {},
  ]) async {
    final reply = await request('tools/call', {
      'name': name,
      'arguments': args,
    });
    final result = reply['result'] as Map<String, Object?>;
    final content = (result['content'] as List).single as Map;
    return (
      text: content['text'] as String,
      isError: result['isError'] as bool,
    );
  }

  void destroy() => link.socket.destroy();
}

void main() {
  late Directory temp;
  late SettingsStore settings;
  late BridgeClientStore clients;
  late BridgeConnections connections;
  late List<FakeExecTransport> dialled;
  late bool locked;
  late BridgeService service;
  late String token;
  late BridgeClient client;
  Duration? commandDelay;
  final peers = <_Peer>[];

  String bridgeDir() => '${temp.path}/bridge';

  BridgeService build() {
    final audit = BridgeAuditLog(
      scrub: (s) => s,
      directory: Directory(bridgeDir()),
    );
    return BridgeService(
      settingsStore: settings,
      clients: clients,
      connections: connections,
      tools: BridgeTools(
        loadHosts: () async => [bridgeHost('web1', 'web')],
        settings: () => settings.current,
        isAppLocked: () => locked,
        connections: connections,
        redactor: BridgeRedactor(scrub: (s) => s),
        audit: audit,
      ),
      createListener: (verify) async => BridgeListener(
        bridgeDir: bridgeDir(),
        verify: verify,
        transport: BridgeTransportKind.unix,
      ),
    );
  }

  Future<_Peer> connect() async {
    final endpoint = await BridgeLocator(bridgeDir()).read();
    final peer = _Peer(await dialBridge(endpoint!, token: token));
    peers.add(peer);
    await peer.request('initialize', {'protocolVersion': '2025-06-18'});
    return peer;
  }

  Future<void> until(bool Function() condition) async {
    for (var i = 0; i < 200 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(condition(), true);
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('bridge_svc');
    settings = SettingsStore(file: File('${temp.path}/settings.json'));
    clients = BridgeClientStore(file: File('${temp.path}/clients.json'));
    final created = await clients.create('Desk assistant');
    token = created.token;
    client = created.client;
    dialled = [];
    locked = false;
    commandDelay = null;
    connections = BridgeConnections(
      openTransport: (_) => null,
      credentialLookup: (_) async => const SshCredentials(password: 'pw'),
      dialer: (host, _) async {
        final t = FakeExecTransport(
          host: host,
          respond: (_) => FakeExecSession(
            stdout: '#=ssg=host\nweb1\n',
            exitDelay: commandDelay,
          ),
        );
        dialled.add(t);
        return t;
      },
    );
    service = build();
  });

  tearDown(() async {
    for (final p in peers) {
      p.destroy();
    }
    peers.clear();
    await service.dispose();
    await temp.delete(recursive: true);
  });

  test('supported on Linux and Windows only', () {
    expect(BridgeService.supported, Platform.isLinux || Platform.isWindows);
  });

  test('off by default: nothing listens', () async {
    await service.start();
    expect(service.status, BridgeStatus.off);
    expect(File('${bridgeDir()}/endpoint.json').existsSync(), false);
  });

  test(
    'switching it on serves tools; switching it off closes everything',
    () async {
      await service.start();
      final statuses = <BridgeStatus>[];
      service.statusChanges.listen(statuses.add);

      await settings.update((s) => s.copyWith(bridgeEnabled: true));
      await until(() => service.status == BridgeStatus.running);
      expect(File('${bridgeDir()}/endpoint.json').existsSync(), true);

      final peer = await connect();
      await until(() => service.connectedClients.length == 1);
      expect(service.connectedClients.single.id, client.id);

      final hosts = await peer.callTool('list_hosts');
      expect(hosts.isError, false);
      expect(hosts.text, contains('"web"'));
      final stats = await peer.callTool('server_stats', {'host': 'web'});
      expect(stats.isError, false);
      expect(dialled, hasLength(1));
      expect(connections.cachedCount, 1);

      await settings.update((s) => s.copyWith(bridgeEnabled: false));
      await until(() => service.status == BridgeStatus.off);
      await peer.closed.future.timeout(const Duration(seconds: 5));
      expect(service.connectedClients, isEmpty);
      expect(dialled.single.closed, true);
      expect(connections.cachedCount, 0);
      expect(File('${bridgeDir()}/endpoint.json').existsSync(), false);
      expect(statuses, [BridgeStatus.running, BridgeStatus.off]);
    },
  );

  test('while the app is locked every call is refused', () async {
    await settings.save(settings.current.copyWith(bridgeEnabled: true));
    await service.start();
    final peer = await connect();
    locked = true;
    final r = await peer.callTool('list_hosts');
    expect(r.isError, true);
    expect(r.text, BridgeRefusals.appLocked.message);
    locked = false;
    expect((await peer.callTool('list_hosts')).isError, false);
  });

  test('revoking a client closes its open connection', () async {
    await settings.save(settings.current.copyWith(bridgeEnabled: true));
    await service.start();
    final peer = await connect();
    await until(() => service.connectedClients.length == 1);
    await clients.revoke(client.id);
    await peer.closed.future.timeout(const Duration(seconds: 5));
    await until(() => service.connectedClients.isEmpty);
    expect(service.status, BridgeStatus.running);
  });

  test('a second instance reports runningElsewhere', () async {
    await settings.save(settings.current.copyWith(bridgeEnabled: true));
    await service.start();
    expect(service.status, BridgeStatus.running);

    final otherSettings = SettingsStore(
      file: File('${temp.path}/settings.json'),
    );
    final other = BridgeService(
      settingsStore: otherSettings,
      clients: clients,
      connections: connections,
      tools: service.tools,
      createListener: (verify) async => BridgeListener(
        bridgeDir: bridgeDir(),
        verify: verify,
        transport: BridgeTransportKind.unix,
      ),
    );
    await other.start();
    expect(other.status, BridgeStatus.runningElsewhere);
    await other.dispose();
    // The first one is untouched by the second's failed start.
    expect(service.status, BridgeStatus.running);
    expect(File('${bridgeDir()}/endpoint.json').existsSync(), true);
  });

  test('a listener that cannot start reports the error', () async {
    await settings.save(settings.current.copyWith(bridgeEnabled: true));
    final broken = BridgeService(
      settingsStore: settings,
      clients: clients,
      connections: connections,
      tools: service.tools,
      createListener: (_) async =>
          throw const BridgeChannelException('cannot listen here'),
    );
    await broken.start();
    expect(broken.status, const BridgeError('cannot listen here'));
    await broken.dispose();
  });

  test(
    'toggling the setting quickly ends in the state last asked for',
    () async {
      await service.start();
      for (final on in [true, false, true, false, true, false]) {
        unawaited(settings.update((s) => s.copyWith(bridgeEnabled: on)));
      }
      await until(() => service.status == BridgeStatus.off);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(service.status, BridgeStatus.off);
      expect(File('${bridgeDir()}/endpoint.json').existsSync(), false);

      for (final on in [true, false, true]) {
        unawaited(settings.update((s) => s.copyWith(bridgeEnabled: on)));
      }
      await until(() => service.status == BridgeStatus.running);
      final peer = await connect();
      expect((await peer.callTool('list_hosts')).isError, false);
    },
  );

  test('a call that was already running when the bridge is switched off '
      'finishes without reopening anything', () async {
    await settings.save(settings.current.copyWith(bridgeEnabled: true));
    await service.start();
    final peer = await connect();
    final pending = peer.callTool('server_stats', {'host': 'web'});
    await settings.update((s) => s.copyWith(bridgeEnabled: false));
    await until(() => service.status == BridgeStatus.off);
    // The reply may be an answer or a closed connection, never a hang.
    await pending
        .then((_) {}, onError: (Object _) {})
        .timeout(const Duration(seconds: 5));
    expect(connections.cachedCount, 0);
  });

  group('a call in flight when its answer has nowhere to go', () {
    Future<(_Peer, Future<Object?>)> startSlowCall() async {
      commandDelay = const Duration(seconds: 5);
      await settings.save(settings.current.copyWith(bridgeEnabled: true));
      await service.start();
      final peer = await connect();
      final pending = peer
          .callTool('server_stats', {'host': 'web'})
          .then<Object?>((r) => r, onError: (Object e) => e);
      await until(() => dialled.isNotEmpty && dialled.single.sessions.isNotEmpty);
      return (peer, pending);
    }

    Future<void> expectStoppedAndSilent(_Peer peer) async {
      await peer.closed.future.timeout(const Duration(seconds: 5));
      await until(() => service.tools.inFlight == 0);
      final session = dialled.single.sessions.single;
      expect(session.stdinClosed, true, reason: 'remote work ended');
      expect(session.wasClosed, true);
      // Only the initialize reply ever came back.
      expect(peer.received.map((m) => m['id']), [1]);
    }

    test('revoking the client stops it on the server and sends nothing',
        () async {
      final (peer, _) = await startSlowCall();
      await clients.revoke(client.id);
      await expectStoppedAndSilent(peer);
    });

    test('switching the bridge off stops it on the server and sends nothing',
        () async {
      final (peer, _) = await startSlowCall();
      await settings.update((s) => s.copyWith(bridgeEnabled: false));
      await expectStoppedAndSilent(peer);
      await until(() => service.status == BridgeStatus.off);
      expect(dialled.single.closed, true);
    });
  });
}
