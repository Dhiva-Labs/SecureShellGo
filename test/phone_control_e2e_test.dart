import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/models/host_ai_access.dart';
import 'package:secure_shell_go/screens/remote_approvals_screen.dart';
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
import 'package:secure_shell_go/services/bridge_remote/remote_controller_token_store.dart';
import 'package:secure_shell_go/services/secure_storage_backend.dart';
import 'package:secure_shell_go/services/settings_store.dart';

import 'fake_exec_session.dart';
import 'support/bridge_fakes.dart';
import 'support/bridge_temp_dir.dart';
import 'support/settle.dart';

/// `secureshellgo-mcp control` run in-process, standing in for the exec
/// channel a phone opens over SSH (the same stand-in the channel test uses).
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
  ]) {
    final id = ++_id;
    final reply = _replies[id] = Completer<Map<String, Object?>>();
    link.socket.add(
      utf8.encode(
        '${jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': ?params})}\n',
      ),
    );
    return reply.future.timeout(const Duration(seconds: 30));
  }
}

class _MemoryBackend implements SecureStorageBackend {
  final Map<String, String> data = {};

  @override
  Future<void> write(String key, String value) async => data[key] = value;

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> delete(String key) async => data.remove(key);
}

/// The phone's screen against the real controller and the real control
/// server (the launcher run in-process in place of SSH): an assistant asks
/// for a change, the card shows up on the screen, a tap answers it, and the
/// change runs. What is not here: a real SSH connection.
void main() {
  testWidgets(
    'a card raised by an assistant is answered from the phone screen',
    (tester) async {
      late Directory temp;
      late SettingsStore settings;
      late BridgeClientStore clients;
      late BridgeAuditLog audit;
      late BridgeService service;
      late String phoneToken;
      late String assistantToken;
      late _Assistant assistant;
      late Future<Map<String, Object?>> call;
      final cleanups = <Future<void> Function()>[];

      await tester.runAsync(() async {
        temp = await bridgeTempDir('phone_e2e');
        final bridgeDir = '${temp.path}/bridge';
        settings = SettingsStore(file: File('${temp.path}/settings.json'));
        clients = BridgeClientStore(file: File('${temp.path}/clients.json'));
        assistantToken = (await clients.create('Desk assistant')).token;
        phoneToken = (await clients.create(
          'Pixel',
          role: BridgeClientRole.controller,
        )).token;
        audit = BridgeAuditLog(
          scrub: (s) => s,
          directory: Directory(bridgeDir),
        );
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
            bridgeDir: bridgeDir,
            verify: verify,
            transport: platformBridgeTransport,
            failedHandshakeDelay: Duration.zero,
          ),
        );
        await service.start();
        await settings.update(
          (s) => s.copyWith(bridgeEnabled: true, bridgePhoneControl: true),
        );
        for (var i = 0; i < 300 && service.status != BridgeStatus.running; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(service.status, BridgeStatus.running);
        cleanups.add(() async {
          await service.dispose();
          await audit.dispose();
          await deleteTempDir(temp);
        });
      });

      // The phone: its token is saved, and "connecting" is the real
      // controller over the in-process launcher.
      final backend = _MemoryBackend();
      final tokens = RemoteControllerTokenStore(backend);
      await tester.runAsync(() => tokens.save('h1', phoneToken));
      final host = Host(
        id: 'h1',
        label: 'My desktop',
        hostname: 'desk.example.test',
        port: 22,
        username: 'me',
        authMethod: SshAuthMethod.password,
      );
      // The session is connected on the real event loop beforehand (sockets
      // do not run on the test's fake clock); the screen takes it as its
      // "connect" result.
      final controller = (await tester.runAsync(() async {
        final c = RemoteBridgeController(
          exec: (_) async => _LauncherProcess('${temp.path}/bridge'),
          token: phoneToken,
        );
        await c.connect();
        return c;
      }))!;
      tester.view.physicalSize = const Size(360, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: RemoteApprovalsScreen(
            host: host,
            tokens: tokens,
            open: (host, token) async => ControllerLink(controller),
          ),
        ),
      );
      await settleUntil(
        tester,
        () => find.byKey(const ValueKey('remote-status')).evaluate().isNotEmpty,
      );
      expect(find.text('Connected to My desktop as Pixel.'), findsOneWidget);
      expect(find.byKey(const ValueKey('remote-nothing-waiting')), findsOneWidget);

      // An assistant asks to run a command on the computer.
      await tester.runAsync(() async {
        final endpoint = (await BridgeLocator('${temp.path}/bridge').read())!;
        assistant = _Assistant(
          await dialBridge(endpoint, token: assistantToken),
        );
        cleanups.add(() async => assistant.link.socket.destroy());
        await assistant.request('initialize', {'protocolVersion': '2025-06-18'});
        call = assistant.request('tools/call', {
          'name': 'run_command',
          'arguments': {'host': 'web', 'command': 'uptime'},
        });
      });

      // Its card arrives on the phone's screen.
      await settleUntil(
        tester,
        () => find.byKey(const ValueKey('approval-command')).evaluate().isNotEmpty,
      );
      expect(find.text('Asked by Desk assistant'), findsOneWidget);
      expect(find.text('On web'), findsOneWidget);
      final shown = tester
          .widget<SelectableText>(
            find.descendant(
              of: find.byKey(const ValueKey('approval-command')),
              matching: find.byType(SelectableText),
            ),
          )
          .textSpan!
          .toPlainText();
      expect(shown, 'uptime');

      // Allow is armed after a second; one tap answers it.
      await tester.pump(const Duration(milliseconds: 1100));
      await tester.tap(find.byKey(const ValueKey('approval-allow-once')));
      await settleUntil(
        tester,
        () => find.byKey(const ValueKey('approval-command')).evaluate().isEmpty,
      );
      expect(find.byKey(const ValueKey('approval-command')), findsNothing);
      expect(find.byKey(const ValueKey('remote-nothing-waiting')), findsOneWidget);

      // The change ran on the computer, and the log says it was the phone.
      final reply = await tester.runAsync(() => call);
      expect((reply!['result'] as Map)['isError'], false);
      await tester.runAsync(() async {
        final logged = await audit.recent();
        final run = logged.firstWhere((e) => e.tool == 'run_command');
        expect(run.via, 'controller:Pixel');
        expect(run.approval, BridgeAuditApproval.once);
      });
      // And the screen's activity list shows it.
      await settleUntil(
        tester,
        () => find.text('run_command on web').evaluate().isNotEmpty,
      );
      expect(find.text('run_command on web'), findsOneWidget);

      // Leaving the screen ends the phone's session on the computer.
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        for (var i = 0; i < 300 && service.connectedControllers.isNotEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(service.connectedControllers, isEmpty);
        for (final c in cleanups.reversed) {
          await c();
        }
      });
    },
  );
}
