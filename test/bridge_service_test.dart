import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/models/host_ai_access.dart';
import 'package:secure_shell_go/services/bridge/bridge_approvals.dart';
import 'package:secure_shell_go/services/bridge/bridge_audit.dart';
import 'package:secure_shell_go/services/bridge/bridge_channel.dart';
import 'package:secure_shell_go/services/bridge/bridge_client_store.dart';
import 'package:secure_shell_go/services/bridge/bridge_connections.dart';
import 'package:secure_shell_go/services/bridge/bridge_locator.dart';
import 'package:secure_shell_go/services/bridge/bridge_policy.dart';
import 'package:secure_shell_go/services/bridge/bridge_redactor.dart';
import 'package:secure_shell_go/services/bridge/bridge_service.dart';
import 'package:secure_shell_go/services/bridge/bridge_tools.dart';
import 'package:secure_shell_go/services/host_store.dart';
import 'package:secure_shell_go/services/settings_store.dart';

import 'fake_exec_session.dart';
import 'support/bridge_fakes.dart';
import 'support/bridge_temp_dir.dart';

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

  BridgeService build({
    Stream<bool>? appLockChanges,
    HostStore? hostStore,
    bool? localChannel,
    bool Function()? builtinOn,
  }) {
    final audit = BridgeAuditLog(
      scrub: (s) => s,
      directory: Directory(bridgeDir()),
    );
    return BridgeService(
      settingsStore: settings,
      clients: clients,
      connections: connections,
      tools: BridgeTools(
        loadHosts: hostStore?.all ?? () async => [bridgeHost('web1', 'web')],
        settings: () => settings.current,
        isAppLocked: () => locked,
        connections: connections,
        redactor: BridgeRedactor(scrub: (s) => s),
        audit: audit,
        builtinAssistantEnabled: builtinOn,
      ),
      localChannel: localChannel,
      createListener: (verify) async => BridgeListener(
        bridgeDir: bridgeDir(),
        verify: verify,
        transport: platformBridgeTransport,
      ),
      appLockChanges: appLockChanges,
      hostChanges: hostStore?.changes,
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
    temp = await bridgeTempDir('bridge_svc');
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
    await deleteTempDir(temp);
  });

  test('the local channel is on Linux and Windows only', () {
    expect(
      BridgeService.channelSupported,
      Platform.isLinux || Platform.isWindows,
    );
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
        transport: platformBridgeTransport,
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

  group('the two halves', () {
    test('without a local channel nothing listens, even switched on, and '
        'the tools still answer the built-in assistant', () async {
      await service.dispose();
      var listeners = 0;
      service = BridgeService(
        settingsStore: settings,
        clients: clients,
        connections: connections,
        tools: BridgeTools(
          loadHosts: () async => [bridgeHost('web1', 'web')],
          settings: () => settings.current,
          isAppLocked: () => locked,
          connections: connections,
          redactor: BridgeRedactor(scrub: (s) => s),
          audit: BridgeAuditLog(
            scrub: (s) => s,
            directory: Directory(bridgeDir()),
          ),
          builtinAssistantEnabled: () => true,
        ),
        localChannel: false,
        createListener: (verify) async {
          listeners++;
          throw StateError('no listener without a channel');
        },
      );
      await settings.save(settings.current.copyWith(bridgeEnabled: true));
      await service.start();
      await settings.update((s) => s.copyWith(bridgeEnabled: false));
      await settings.update((s) => s.copyWith(bridgeEnabled: true));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(listeners, 0);
      expect(service.status, BridgeStatus.off);
      expect(File('${bridgeDir()}/endpoint.json').existsSync(), false);
      final r = await service.tools.call(
        BridgeClient.builtin,
        'list_hosts',
        const {},
      );
      expect(r.isError, false);
      expect(r.text, contains('"web"'));
    });

    test('a controller token is refused at the handshake, like an unknown '
        'one', () async {
      final phone = await clients.create(
        'Phone',
        role: BridgeClientRole.controller,
      );
      await settings.save(settings.current.copyWith(bridgeEnabled: true));
      await service.start();
      await until(() => service.status == BridgeStatus.running);
      final endpoint = await BridgeLocator(bridgeDir()).read();
      await expectLater(
        dialBridge(endpoint!, token: phone.token),
        throwsA(
          isA<BridgeDialException>().having(
            (e) => '$e',
            'message',
            contains('not paired'),
          ),
        ),
      );
      expect(service.connectedClients, isEmpty);
      // The assistant's own token still works.
      await connect();
      await until(() => service.connectedClients.length == 1);
    });
  });

  group('approvals and time-limited approvals', () {
    Future<BridgeApprovalOutcome> ask(BridgeService svc, BridgeClient who) =>
        svc.approvals.ask(
          svc.approvals.request(
            client: who,
            hostId: 'web1',
            hostName: 'web',
            tool: 'run_command',
            summary: CommandSummary(command: 'id', hostNames: ['web']),
          ),
        );

    test('the service exposes the ones the tools use', () {
      expect(identical(service.approvals, service.tools.approvals), true);
      expect(identical(service.grants, service.tools.grants), true);
    });

    test('locking the app withdraws every card and ends every grant',
        () async {
      final lock = StreamController<bool>.broadcast();
      await service.dispose();
      service = build(appLockChanges: lock.stream);
      await settings.save(settings.current.copyWith(bridgeEnabled: true));
      await service.start();
      final pending = ask(service, client);
      service.grants.grant(client.id, 'web1', const Duration(minutes: 5));
      lock.add(false);
      await Future<void>.delayed(Duration.zero);
      expect(service.approvals.current, hasLength(1));
      lock.add(true);
      expect(await pending, BridgeApprovalOutcome.withdrawn);
      expect(service.grants.current, isEmpty);
      await lock.close();
    });

    test('switching the bridge off withdraws every card and ends every grant',
        () async {
      await settings.save(settings.current.copyWith(bridgeEnabled: true));
      await service.start();
      final pending = ask(service, client);
      service.grants.grant(client.id, 'web1', const Duration(minutes: 5));
      await settings.update((s) => s.copyWith(bridgeEnabled: false));
      expect(await pending, BridgeApprovalOutcome.withdrawn);
      await until(() => service.grants.current.isEmpty);
    });

    test('the built-in assistant\'s cards and grants survive the channel '
        'switch and changes to the paired list, but not a lock', () async {
      final lock = StreamController<bool>.broadcast();
      await service.dispose();
      service = build(appLockChanges: lock.stream);
      await settings.save(settings.current.copyWith(bridgeEnabled: true));
      await service.start();
      final builtin = ask(service, BridgeClient.builtin);
      final paired = ask(service, client);
      service.grants.grant(
        BridgeClient.builtinId,
        'web1',
        const Duration(minutes: 5),
      );
      service.grants.grant(client.id, 'web1', const Duration(minutes: 5));

      await settings.update((s) => s.copyWith(bridgeEnabled: false));
      expect(await paired, BridgeApprovalOutcome.withdrawn);
      await until(() => service.grants.current.length == 1);
      expect(service.grants.current.single.clientId, BridgeClient.builtinId);
      expect(service.approvals.current.single.client.id, BridgeClient.builtinId);

      await clients.revoke(client.id);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(service.approvals.current, hasLength(1));
      expect(service.grants.current, hasLength(1));

      lock.add(true);
      expect(await builtin, BridgeApprovalOutcome.withdrawn);
      expect(service.grants.current, isEmpty);
      await lock.close();
    });

    test('revoking a client, connected or not, ends its cards and grants '
        'only', () async {
      final second = (await clients.create('Second assistant')).client;
      await settings.save(settings.current.copyWith(bridgeEnabled: true));
      await service.start();
      final mine = ask(service, client);
      final theirs = ask(service, second);
      service.grants.grant(client.id, 'web1', const Duration(minutes: 5));
      service.grants.grant(second.id, 'web1', const Duration(minutes: 5));
      await clients.revoke(client.id);
      expect(await mine, BridgeApprovalOutcome.withdrawn);
      await until(() => service.approvals.current.length == 1);
      expect(service.approvals.current.single.client.id, second.id);
      expect(service.grants.current.single.clientId, second.id);
      service.approvals.withdrawAll();
      expect(await theirs, BridgeApprovalOutcome.withdrawn);
    });

    group('when a host changes', () {
      late HostStore store;
      late BridgeClient second;

      Future<void> ask(String hostId, BridgeClient who) async {
        unawaited(
          service.approvals.ask(
            service.approvals.request(
              client: who,
              hostId: hostId,
              hostName: hostId,
              tool: 'run_command',
              summary: CommandSummary(command: 'id', hostNames: [hostId]),
            ),
          ),
        );
      }

      Future<void> settle() =>
          Future<void>.delayed(const Duration(milliseconds: 10));

      Set<String> grantedHosts() => {
        for (final g in service.grants.current) g.hostId,
      };
      Set<String> cardHosts() => {
        for (final r in service.approvals.current) r.hostId,
      };

      setUp(() async {
        second = (await clients.create('Second assistant')).client;
        store = HostStore(file: File('${temp.path}/hosts.json'));
        await store.add(
          bridgeHost('web1', 'web', access: HostAiAccess.askToChange),
        );
        await store.add(
          bridgeHost('app1', 'app', access: HostAiAccess.askToChange),
        );
        await service.dispose();
        service = build(hostStore: store);
        await service.start();
        for (final id in ['web1', 'app1']) {
          service.grants.grant(client.id, id, const Duration(minutes: 15));
          service.grants.grant(second.id, id, const Duration(minutes: 15));
        }
        await ask('web1', client);
        await ask('app1', client);
      });

      Future<void> edit(String id, Host Function(Host h) change) =>
          store.modify(id, change);

      test('stepped down to read-only: its grants and cards end at once, '
          'with no call in between; stepping back up brings nothing back',
          () async {
        await edit('web1', (h) => h.copyWith(aiAccess: HostAiAccess.readOnly));
        await settle();
        expect(grantedHosts(), {'app1'});
        expect(cardHosts(), {'app1'});
        await edit(
          'web1',
          (h) => h.copyWith(aiAccess: HostAiAccess.askToChange),
        );
        await settle();
        expect(service.grants.hasLive(client.id, 'web1'), false);
        expect(service.grants.hasLive(second.id, 'web1'), false);
        expect(service.grants.hasLive(client.id, 'app1'), true);
      });

      test('un-shared or deleted: gone', () async {
        await edit('web1', (h) => h.copyWith(aiAccess: HostAiAccess.off));
        await store.delete('app1');
        await settle();
        expect(service.grants.current, isEmpty);
        expect(service.approvals.current, isEmpty);
      });

      for (final (what, change) in <(String, Host Function(Host))>[
        ('hostname', (h) => h.copyWith(hostname: 'elsewhere.example.test')),
        ('port', (h) => h.copyWith(port: 2222)),
        ('user name', (h) => h.copyWith(username: 'root')),
        ('transport', (h) => h.copyWith(transport: HostTransport.mosh)),
      ]) {
        test('pointed at another server ($what): gone', () async {
          await edit('web1', change);
          await settle();
          expect(grantedHosts(), {'app1'});
          expect(cardHosts(), {'app1'});
        });
      }

      test('an unrelated edit (label, group, colour) keeps them', () async {
        await edit(
          'web1',
          (h) => h.copyWith(
            label: 'renamed',
            group: 'prod',
            colorLabel: HostColorLabel.values.last,
          ),
        );
        await store.renameGroup('prod', 'production');
        await settle();
        expect(grantedHosts(), {'web1', 'app1'});
        expect(cardHosts(), {'web1', 'app1'});
      });
    });

    test('turning "allow for a while" off ends the grants it gave', () async {
      await settings.save(
        settings.current.copyWith(
          bridgeEnabled: true,
          bridgeTimedApprovalMinutes: 15,
        ),
      );
      await service.start();
      service.grants.grant(client.id, 'web1', const Duration(minutes: 15));
      await settings.update((s) => s.copyWith(bridgeTimedApprovalMinutes: 60));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(service.grants.current, hasLength(1));
      await settings.update((s) => s.copyWith(bridgeTimedApprovalMinutes: 0));
      await until(() => service.grants.current.isEmpty);
    });
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
