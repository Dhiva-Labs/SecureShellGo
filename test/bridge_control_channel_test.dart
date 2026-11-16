import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/app_settings.dart';
import 'package:secure_shell_go/models/host_ai_access.dart';
import 'package:secure_shell_go/services/bridge/bridge_audit.dart';
import 'package:secure_shell_go/services/bridge/bridge_change_tools.dart';
import 'package:secure_shell_go/services/bridge/bridge_channel.dart';
import 'package:secure_shell_go/services/bridge/bridge_client_store.dart';
import 'package:secure_shell_go/services/bridge/bridge_connections.dart';
import 'package:secure_shell_go/services/bridge/bridge_control_launcher.dart';
import 'package:secure_shell_go/services/bridge/bridge_locator.dart';
import 'package:secure_shell_go/services/bridge/bridge_redactor.dart';
import 'package:secure_shell_go/services/bridge/bridge_service.dart';
import 'package:secure_shell_go/services/bridge/bridge_tools.dart';
import 'package:secure_shell_go/services/bridge_remote/remote_bridge_controller.dart';
import 'package:secure_shell_go/services/settings_store.dart';
import 'package:secure_shell_go/models/host.dart';

import 'fake_exec_session.dart';
import 'support/bridge_fakes.dart';
import 'support/bridge_temp_dir.dart';

/// `secureshellgo-mcp control` run in-process, standing in for the exec
/// channel a phone opens over SSH: what the phone writes is the launcher's
/// stdin, the launcher's stdout is what the phone reads.
class _LauncherProcess implements RemoteExecProcess {
  _LauncherProcess(String bridgeDir) {
    final sink = IOSink(_stdout);
    _done = runBridgeControlLauncher(
      input: _stdin.stream,
      output: sink,
      bridgeDir: bridgeDir,
    ).then((code) async {
      exitCode = code;
      await sink.close();
    });
  }

  final _stdin = StreamController<List<int>>();
  final _stdout = StreamController<List<int>>();
  late final Future<void> _done;

  @override
  int? exitCode;

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  void write(List<int> bytes) {
    if (!_stdin.isClosed) _stdin.add(bytes);
  }

  @override
  Future<void> closeInput() async {
    if (!_stdin.isClosed) unawaited(_stdin.close());
  }

  @override
  Future<void> get done => _done;

  @override
  void close() {
    if (!_stdin.isClosed) unawaited(_stdin.close());
  }
}

/// The launcher driven by hand: lines in, lines out, the exit code.
class _RawPhone {
  _RawPhone(this.process) {
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          final m = jsonDecode(line) as Map<String, Object?>;
          received.add(m);
          _wake.add(null);
        });
  }

  final _LauncherProcess process;
  final List<Map<String, Object?>> received = [];
  final _wake = StreamController<void>.broadcast();

  void send(String line) => process.write(utf8.encode('$line\n'));

  Future<Map<String, Object?>> waitFor(
    bool Function(Map<String, Object?> m) test,
  ) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (true) {
      for (final m in received) {
        if (test(m)) return m;
      }
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) fail('not received; got $received');
      await _wake.stream.first.timeout(left, onTimeout: () {});
    }
  }

  Future<int> exit() async {
    await process.done.timeout(const Duration(seconds: 10));
    return process.exitCode!;
  }
}

/// An assistant over MCP.
class _Assistant {
  _Assistant(this.link) {
    link.rest
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          final m = jsonDecode(line) as Map<String, Object?>;
          _replies.remove(m['id'])?.complete(m);
        }, onError: (Object _) {});
  }

  final BridgeLink link;
  final Map<Object?, Completer<Map<String, Object?>>> _replies = {};
  var _id = 0;

  Future<Map<String, Object?>> request(
    String method, [
    Map<String, Object?>? params,
    Duration timeout = const Duration(seconds: 10),
  ]) {
    final id = ++_id;
    final reply = _replies[id] = Completer<Map<String, Object?>>();
    link.socket.add(
      utf8.encode(
        '${jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': ?params})}\n',
      ),
    );
    return reply.future.timeout(timeout);
  }
}

void main() {
  late Directory temp;
  late SettingsStore settings;
  late BridgeClientStore clients;
  late BridgeAuditLog audit;
  late BridgeService service;
  late String assistantToken;
  late String phoneToken;
  late BridgeClient phoneClient;
  final cleanups = <void Function()>[];

  String bridgeDir() => '${temp.path}/bridge';

  setUp(() async {
    temp = await bridgeTempDir('bridge_cch');
    settings = SettingsStore(file: File('${temp.path}/settings.json'));
    clients = BridgeClientStore(file: File('${temp.path}/clients.json'));
    assistantToken = (await clients.create('Desk assistant')).token;
    final phone = await clients.create(
      'Pixel',
      role: BridgeClientRole.controller,
    );
    phoneToken = phone.token;
    phoneClient = phone.client;
    audit = BridgeAuditLog(scrub: (s) => s, directory: Directory(bridgeDir()));
    final connections = BridgeConnections(
      openTransport: (_) => null,
      credentialLookup: (_) async => const SshCredentials(password: 'pw'),
      dialer: (host, _) async => FakeExecTransport(
        host: host,
        respond: (_) => FakeExecSession(stdout: 'done\n'),
      ),
    );
    service = BridgeService(
      settingsStore: settings,
      clients: clients,
      connections: connections,
      localChannel: true,
      tools: BridgeTools(
        loadHosts: () async => [
          bridgeHost('web1', 'web', access: HostAiAccess.askToChange),
        ],
        settings: () => settings.current,
        isAppLocked: () => false,
        connections: connections,
        redactor: BridgeRedactor(scrub: (s) => s),
        audit: audit,
        changeTools: BridgeChangeTools(
          redactor: BridgeRedactor(scrub: (s) => s),
        ).build(),
      ),
      createListener: (verify) async => BridgeListener(
        bridgeDir: bridgeDir(),
        verify: verify,
        transport: platformBridgeTransport,
        failedHandshakeDelay: Duration.zero,
      ),
    );
    await service.start();
  });

  tearDown(() async {
    for (final c in cleanups) {
      c();
    }
    cleanups.clear();
    await service.dispose();
    await audit.dispose();
    await deleteTempDir(temp);
  });

  Future<void> switchOn({bool phoneControl = true}) async {
    await settings.update(
      (s) => s.copyWith(bridgeEnabled: true, bridgePhoneControl: phoneControl),
    );
    for (var i = 0; i < 300 && service.status != BridgeStatus.running; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(service.status, BridgeStatus.running);
  }

  _RawPhone rawPhone(String token) {
    final process = _LauncherProcess(bridgeDir());
    cleanups.add(process.close);
    final phone = _RawPhone(process);
    phone.send(token);
    return phone;
  }

  Future<void> until(bool Function() condition) async {
    for (var i = 0; i < 500 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(condition(), true);
  }

  test('through the launcher: a snapshot, then it ends when the phone leaves',
      () async {
    await switchOn();
    final phone = rawPhone(phoneToken);
    final snapshot = await phone.waitFor((m) => m['type'] == 'snapshot');
    expect((snapshot['state'] as Map)['controller'], 'Pixel');
    await phone.waitFor((m) => m['type'] == 'synced');
    await until(() => service.connectedControllers.length == 1);
    expect(service.connectedClients, isEmpty);
    phone.send('{"type":"ping","re":"p1"}');
    final pong = await phone.waitFor((m) => m['re'] == 'p1');
    expect(pong['ok'], true);
    await phone.process.closeInput();
    expect(await phone.exit(), 0);
    await until(() => service.connectedControllers.isEmpty);
  });

  test('an assistant token cannot open a control session', () async {
    await switchOn();
    final phone = rawPhone(assistantToken);
    final error = await phone.waitFor((m) => m['type'] == 'error');
    expect(error['code'], 'refused');
    expect(await phone.exit(), 1);
    expect(service.connectedControllers, isEmpty);
  });

  test('a controller token cannot open MCP, so it can never call a tool',
      () async {
    await switchOn();
    final endpoint = (await BridgeLocator(bridgeDir()).read())!;
    await expectLater(
      dialBridge(endpoint, token: phoneToken),
      throwsA(isA<BridgeDialException>()),
    );
    expect(service.connectedClients, isEmpty);
    // And the tool host refuses a controller however it got there.
    final result = await service.tools.call(phoneClient, 'list_hosts', {});
    expect(result.isError, true);
  });

  test('an unknown session kind is refused', () async {
    await switchOn();
    final endpoint = (await BridgeLocator(bridgeDir()).read())!;
    await expectLater(
      dialBridge(endpoint, token: assistantToken, session: 'admin'),
      throwsA(isA<BridgeDialException>()),
    );
  });

  test('Phone control off refuses the phone like an unknown token', () async {
    await switchOn(phoneControl: false);
    final phone = rawPhone(phoneToken);
    final error = await phone.waitFor((m) => m['type'] == 'error');
    expect(error['code'], 'refused');
    final unknown = rawPhone('not-a-token');
    final other = await unknown.waitFor((m) => m['type'] == 'error');
    expect(other['message'], error['message']);
    expect(await phone.exit(), 1);
  });

  test('switching Phone control off closes a live session', () async {
    await switchOn();
    final phone = rawPhone(phoneToken);
    await phone.waitFor((m) => m['type'] == 'synced');
    await settings.update((s) => s.copyWith(bridgePhoneControl: false));
    final error = await phone.waitFor((m) => m['type'] == 'error');
    expect(error['code'], 'refused');
    expect(await phone.exit(), 1);
  });

  test("removing the phone's pairing closes its live session at once",
      () async {
    await switchOn();
    final phone = rawPhone(phoneToken);
    await phone.waitFor((m) => m['type'] == 'synced');
    await clients.revoke(phoneClient.id);
    final error = await phone.waitFor((m) => m['type'] == 'error');
    expect(error['code'], 'refused');
    expect(await phone.exit(), 1);
    await until(() => service.connectedControllers.isEmpty);
  });

  test('the app not running: one error line and a non-zero exit', () async {
    final phone = rawPhone(phoneToken);
    final error = await phone.waitFor((m) => m['type'] == 'error');
    expect(error['code'], 'not_running');
    expect(await phone.exit(), 1);
  });

  test('no token line: refused without dialling', () async {
    await switchOn();
    final process = _LauncherProcess(bridgeDir());
    final phone = _RawPhone(process);
    await process.closeInput();
    final error = await phone.waitFor((m) => m['type'] == 'error');
    expect(error['code'], 'refused');
    expect(await phone.exit(), 1);
  });

  test('an oversized token line in one chunk is refused, not dialled', () async {
    await switchOn();
    final process = _LauncherProcess(bridgeDir());
    final phone = _RawPhone(process);
    process.write(utf8.encode('${'x' * 20000}\n'));
    final error = await phone.waitFor((m) => m['type'] == 'error');
    expect(error['code'], 'refused');
    expect(await phone.exit(), 1);
  });

  test(
    'the compiled launcher, as a process (SSG_LAUNCHER_BIN)',
    () async {
      await switchOn();
      final process = await Process.start(
        Platform.environment['SSG_LAUNCHER_BIN']!,
        ['control'],
        environment: {'SSG_BRIDGE_DIR': bridgeDir()},
      );
      final lines = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .map((l) => jsonDecode(l) as Map<String, Object?>)
          .asBroadcastStream();
      final synced = lines.firstWhere((m) => m['type'] == 'synced');
      process.stdin.writeln(phoneToken);
      await synced.timeout(const Duration(seconds: 10));
      final pong = lines.firstWhere((m) => m['re'] == 'p1');
      process.stdin.writeln('{"type":"ping","re":"p1"}');
      expect((await pong.timeout(const Duration(seconds: 10)))['ok'], true);
      await process.stdin.close();
      expect(await process.exitCode.timeout(const Duration(seconds: 10)), 0);
    },
    skip: Platform.environment['SSG_LAUNCHER_BIN'] == null
        ? 'set SSG_LAUNCHER_BIN to a built launcher'
        : null,
  );

  group('RemoteBridgeController', () {
    test(
      'end to end: an assistant asks, the phone answers, the change runs, '
      'the activity log says it was the phone',
      () async {
        await switchOn();
        String? ran;
        final remote = RemoteBridgeController(
          exec: (command) async {
            ran = command;
            return _LauncherProcess(bridgeDir());
          },
          token: phoneToken,
        );
        cleanups.add(() => unawaited(remote.close()));
        await remote.connect();
        expect(ran, contains('secureshellgo-mcp'));
        expect(ran, contains('control'));
        expect(ran, isNot(contains(phoneToken)));
        expect(remote.state.phase, RemoteBridgePhase.live);
        expect(remote.state.controllerName, 'Pixel');
        expect(remote.state.approvals, isEmpty);

        final endpoint = (await BridgeLocator(bridgeDir()).read())!;
        final assistant = _Assistant(
          await dialBridge(endpoint, token: assistantToken),
        );
        cleanups.add(() => assistant.link.socket.destroy());
        await assistant.request('initialize', {
          'protocolVersion': '2025-06-18',
        });
        final call = assistant.request('tools/call', {
          'name': 'run_command',
          'arguments': {'host': 'web', 'command': 'uptime'},
        }, const Duration(seconds: 30));

        Future<RemoteBridgeState> stateWhere(
          bool Function(RemoteBridgeState s) test,
        ) async {
          if (test(remote.state)) return remote.state;
          return remote.states
              .firstWhere(test)
              .timeout(const Duration(seconds: 10));
        }

        unawaited(call.then((r) => printOnFailure('call reply: $r')));
        final withCard = await stateWhere((s) => s.approvals.isNotEmpty);
        final card = withCard.approvals.single;
        expect(card.kind, ControlApprovalKind.command);
        expect(card.host, 'web');
        expect(card.assistant, 'Desk assistant');
        expect(card.command!.command.text, 'uptime');
        expect(card.timedAllowed, false);

        // "Allow for a while" is off on the desktop: refused on the phone.
        final timed = await remote.answer(card.id, ControlAnswer.forMinutes);
        expect(timed.code, ControlErrorCode.notAllowed);

        final answered = await remote.answer(card.id, ControlAnswer.once);
        expect(answered.ok, true);
        expect(answered.outcome, ControlApprovalEnd.allowedOnce);
        final again = await remote.answer(card.id, ControlAnswer.once);
        expect(again.code, ControlErrorCode.notFound);

        final reply = await call;
        final result = reply['result'] as Map;
        expect(result['isError'], false);

        final entry = (await stateWhere(
          (s) => s.activity.isNotEmpty && s.activity.first.tool == 'run_command',
        )).activity;
        expect(entry.first.approval, 'once');
        expect(entry.first.via, 'controller:Pixel');
        expect(remote.state.approvals, isEmpty);

        final logged = await audit.recent();
        final run = logged.firstWhere((e) => e.tool == 'run_command');
        expect(run.via, 'controller:Pixel');
        expect(run.approval, BridgeAuditApproval.once);

        await remote.close();
        expect(remote.state.phase, RemoteBridgePhase.closed);
        expect(remote.state.error, isNull);
        await until(() => service.connectedControllers.isEmpty);
      },
    );

    test('a refused phone gets a readable error from connect()', () async {
      await switchOn(phoneControl: false);
      final remote = RemoteBridgeController(
        exec: (_) async => _LauncherProcess(bridgeDir()),
        token: phoneToken,
      );
      await expectLater(
        remote.connect(),
        throwsA(
          isA<RemoteBridgeError>().having(
            (e) => e.kind,
            'kind',
            RemoteBridgeErrorKind.refused,
          ),
        ),
      );
      expect(remote.state.phase, RemoteBridgePhase.closed);
      expect(remote.state.error!.kind, RemoteBridgeErrorKind.refused);
    });

    test('the app not running', () async {
      final remote = RemoteBridgeController(
        exec: (_) async => _LauncherProcess(bridgeDir()),
        token: phoneToken,
      );
      await expectLater(
        remote.connect(),
        throwsA(
          isA<RemoteBridgeError>().having(
            (e) => e.kind,
            'kind',
            RemoteBridgeErrorKind.notRunning,
          ),
        ),
      );
    });

    test('the bridge switched off under a live session ends it', () async {
      await switchOn();
      final remote = RemoteBridgeController(
        exec: (_) async => _LauncherProcess(bridgeDir()),
        token: phoneToken,
      );
      await remote.connect();
      await settings.update((s) => s.copyWith(bridgeEnabled: false));
      final closed = await remote.states
          .firstWhere((s) => s.phase == RemoteBridgePhase.closed)
          .timeout(const Duration(seconds: 10));
      expect(closed.error!.kind, RemoteBridgeErrorKind.refused);
      final after = await remote.ping();
      expect(after.ok, false);
    });
  });

  group('remoteControlCommand', () {
    test('runs the first launcher found, passing stdin through', () async {
      if (Platform.isWindows) return;
      final bin = Directory('${temp.path}/bin')..createSync();
      final fake = File('${bin.path}/secureshellgo-mcp')
        ..writeAsStringSync(
          '#!/bin/sh\nread t\necho "args=\$* token=\$t"\n',
        );
      await Process.run('chmod', ['755', fake.path]);
      final process = await Process.start(
        '/bin/sh',
        ['-c', remoteControlCommand()],
        environment: {'PATH': '${bin.path}:/usr/bin:/bin'},
        includeParentEnvironment: false,
      );
      process.stdin.writeln('tok-123');
      await process.stdin.close();
      final out = await process.stdout.transform(utf8.decoder).join();
      expect(await process.exitCode, 0);
      expect(out.trim(), 'args=control token=tok-123');
    });

    test('nothing installed: one JSON error line, exit 127', () async {
      if (Platform.isWindows) return;
      final elsewhere = [
        for (final c in remoteLauncherCandidates)
          if (c.startsWith('/') && File(c).existsSync()) c,
      ];
      if (elsewhere.isNotEmpty) {
        markTestSkipped('a launcher is installed here: $elsewhere');
        return;
      }
      // Only `sh` on the PATH: the login shell runs `sh -c`.
      final empty = Directory('${temp.path}/empty')..createSync();
      await Link('${empty.path}/sh').create('/bin/sh');
      final result = await Process.run(
        '/bin/sh',
        ['-c', remoteControlCommand()],
        environment: {'PATH': empty.path},
        includeParentEnvironment: false,
      );
      expect(result.exitCode, 127);
      final line = jsonDecode((result.stdout as String).trim()) as Map;
      expect(line['type'], 'error');
      expect(line['code'], 'launcher_not_found');
    });
  });

  test('settings: Phone control is off by default and never in a backup', () {
    const s = AppSettings();
    expect(s.bridgePhoneControl, false);
    final on = s.copyWith(bridgePhoneControl: true);
    expect(on.toJson()['bridgePhoneControl'], true);
    expect(AppSettings.fromJson(on.toJson()).bridgePhoneControl, true);
    expect(s.toJson().containsKey('bridgePhoneControl'), false);
    expect(on.withBridgeDefaults().bridgePhoneControl, false);
    expect(s.withBridgeFrom(on).bridgePhoneControl, true);
    expect(
      AppSettings.fromJson(const {'bridgePhoneControl': 'yes'})
          .bridgePhoneControl,
      false,
    );
  });
}
