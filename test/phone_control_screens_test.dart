import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/app_settings.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/screens/pair_phone_screen.dart';
import 'package:secure_shell_go/screens/remote_approvals_screen.dart';
import 'package:secure_shell_go/screens/settings/ai_bridge_section.dart';
import 'package:secure_shell_go/screens/settings/phone_control_section.dart';
import 'package:secure_shell_go/services/bridge/bridge_audit.dart';
import 'package:secure_shell_go/services/bridge/bridge_client_store.dart';
import 'package:secure_shell_go/services/bridge/bridge_connections.dart';
import 'package:secure_shell_go/services/bridge/bridge_redactor.dart';
import 'package:secure_shell_go/services/bridge/bridge_service.dart';
import 'package:secure_shell_go/services/bridge/bridge_tools.dart';
import 'package:secure_shell_go/services/bridge_remote/remote_bridge_controller.dart';
import 'package:secure_shell_go/services/bridge_remote/remote_controller_token_store.dart';
import 'package:secure_shell_go/services/secure_storage_backend.dart';
import 'package:secure_shell_go/services/settings_store.dart';
import 'package:secure_shell_go/widgets/remote_approval_card.dart';

// ------------------------------------------------------------------ fakes

class _MemoryBackend implements SecureStorageBackend {
  final Map<String, String> data = {};
  bool failDelete = false;

  @override
  Future<void> write(String key, String value) async => data[key] = value;

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> delete(String key) async {
    if (failDelete) throw StateError('locked');
    data.remove(key);
  }
}

/// Pairings kept in memory, so a widget test turns no file or timer.
class _MemoryClients extends BridgeClientStore {
  _MemoryClients() : super(file: File('unused-clients.json'));

  final List<BridgeClient> list = [];
  final _stream = StreamController<List<BridgeClient>>.broadcast();
  var _n = 0;
  bool failRevoke = false;
  bool failCreate = false;
  final List<BridgeClientRole> created = [];

  @override
  Stream<List<BridgeClient>> get changes => _stream.stream;

  @override
  Future<List<BridgeClient>> load() async => List.unmodifiable(list);

  @override
  Future<({BridgeClient client, String token})> create(
    String name, {
    bool pending = false,
    BridgeClientRole role = BridgeClientRole.assistant,
  }) async {
    if (failCreate) throw const FileSystemException('disk full');
    created.add(role);
    final client = BridgeClient(
      id: 'id-${++_n}',
      name: name,
      tokenHash: 'hash',
      createdAt: DateTime.utc(2026, 11, 1),
      role: role,
    );
    list.add(client);
    _stream.add(List.unmodifiable(list));
    return (client: client, token: 'tok-secret-$_n');
  }

  @override
  Future<void> revoke(String id) async {
    if (failRevoke) throw const FileSystemException('disk full');
    list.removeWhere((c) => c.id == id);
    _stream.add(List.unmodifiable(list));
  }
}

BridgeConnections _connections() => BridgeConnections(
  openTransport: (_) => null,
  credentialLookup: (_) async => null,
  dialer: (host, _) async => throw StateError('no dialling'),
);

/// A [BridgeService] whose connected phones the test sets, without a
/// listener behind it.
class _FakeBridge extends BridgeService {
  _FakeBridge(Directory dir, BridgeClientStore clients, {bool? localChannel})
    : this._(dir, clients, _connections(), localChannel);

  _FakeBridge._(
    Directory dir,
    BridgeClientStore clients,
    BridgeConnections connections,
    bool? localChannel,
  ) : super(
        localChannel: localChannel,
        settingsStore: SettingsStore(file: File('${dir.path}/unused.json')),
        clients: clients,
        connections: connections,
        tools: BridgeTools(
          loadHosts: () async => const [],
          settings: () => const AppSettings(),
          isAppLocked: () => false,
          connections: connections,
          redactor: BridgeRedactor(scrub: (s) => s),
          audit: BridgeAuditLog(
            scrub: (s) => s,
            directory: Directory('${dir.path}/bridge'),
          ),
        ),
        createListener: (_) async => throw StateError('no listener'),
      );

  List<BridgeClient> online = const [];
  final onlineStream = StreamController<List<BridgeClient>>.broadcast();

  @override
  BridgeStatus get status => BridgeStatus.off;

  @override
  Stream<BridgeStatus> get statusChanges => const Stream.empty();

  @override
  List<BridgeClient> get connectedClients => const [];

  @override
  Stream<List<BridgeClient>> get connectedClientsChanges =>
      const Stream.empty();

  @override
  List<BridgeClient> get connectedControllers => online;

  @override
  Stream<List<BridgeClient>> get connectedControllersChanges =>
      onlineStream.stream;
}

/// A session with the computer driven by the test.
class _FakeLink implements RemoteControlLink {
  _FakeLink(this._state);

  RemoteBridgeState _state;
  final _stream = StreamController<RemoteBridgeState>.broadcast(sync: true);
  final List<(String, ControlAnswer)> answers = [];
  final List<String> grantStops = [];
  final List<(ControlItemKind, String)> itemStops = [];
  bool closed = false;

  /// What the next answer returns.
  RemoteActionResult nextResult = const RemoteActionResult.ok();
  Completer<RemoteActionResult>? hold;

  @override
  RemoteBridgeState get state => _state;

  @override
  Stream<RemoteBridgeState> get states => _stream.stream;

  void push(RemoteBridgeState next) {
    _state = next;
    _stream.add(next);
  }

  @override
  Future<RemoteActionResult> answer(String approvalId, ControlAnswer answer) {
    answers.add((approvalId, answer));
    return hold?.future ?? Future.value(nextResult);
  }

  @override
  Future<RemoteActionResult> stopGrant(String grantId) async {
    grantStops.add(grantId);
    return nextResult;
  }

  @override
  Future<RemoteActionResult> stopItem(ControlItemKind kind, String id) async {
    itemStops.add((kind, id));
    return nextResult;
  }

  @override
  Future<void> close() async => closed = true;
}

ControlApproval _command(
  String id,
  String text, {
  DateTime? at,
  bool timed = false,
  String assistant = 'Desk assistant',
  String host = 'web',
  Duration remaining = const Duration(seconds: 90),
}) => ControlApproval(
  id: id,
  assistant: assistant,
  host: host,
  tool: 'run_command',
  kind: ControlApprovalKind.command,
  remaining: remaining,
  timedAllowed: timed,
  receivedAt: at,
  command: ControlCommand(hosts: [host], command: ControlVisibleText.render(text)),
);

ControlApproval _kind(String id, ControlApprovalKind kind, {DateTime? at}) =>
    ControlApproval(
      id: id,
      assistant: 'Desk assistant',
      host: 'web',
      tool: 'x',
      kind: kind,
      remaining: const Duration(seconds: 90),
      timedAllowed: false,
      receivedAt: at,
      service: kind == ControlApprovalKind.service
          ? const ControlService(unit: 'nginx.service', action: 'restart')
          : null,
      file: kind == ControlApprovalKind.fileWrite
          ? ControlFileWrite(
              path: ControlVisibleText.render('/etc/app.conf', breakLines: false),
              bytes: 2048,
              replacesExisting: true,
              previewKind: ControlPreviewKind.partialDiff,
              preview: ControlVisibleText.render('-a\n+b'),
            )
          : null,
      job: kind == ControlApprovalKind.jobStart
          ? ControlJobStart(
              command: ControlVisibleText.render('npm run dev'),
              cwd: ControlVisibleText.render('/srv/app', breakLines: false),
              name: 'dev server',
            )
          : null,
    );

final _host = Host(
  id: 'h1',
  label: 'My desktop',
  hostname: 'desk.example.test',
  port: 22,
  username: 'me',
  authMethod: SshAuthMethod.password,
);

RemoteBridgeState _live({
  List<ControlApproval> approvals = const [],
  List<ControlGrant> grants = const [],
  List<ControlItem> items = const [],
  List<ControlActivity> activity = const [],
  bool locked = false,
  int timedMinutes = 0,
}) => RemoteBridgeState(
  phase: RemoteBridgePhase.live,
  controllerName: 'Pixel',
  approvals: approvals,
  grants: grants,
  items: items,
  activity: activity,
  locked: locked,
  timedMinutes: timedMinutes,
);

RemoteBridgeState _everyKind(DateTime now) =>
    _live(
          timedMinutes: 15,
          approvals: [
            _command('c', 'uptime && echo ' * 8, at: now, timed: true),
            _kind('s', ControlApprovalKind.service, at: now),
            _kind('f', ControlApprovalKind.fileWrite, at: now),
            _kind('t', ControlApprovalKind.terminal, at: now),
            _kind('d', ControlApprovalKind.desktop, at: now),
            _kind('j', ControlApprovalKind.jobStart, at: now),
            _kind('o', ControlApprovalKind.other, at: now),
          ],
          items: [
            const ControlItem(
              kind: ControlItemKind.terminal,
              id: 't1',
              assistant: 'A very long assistant name that keeps going and going',
              host: 'a-host-with-a-long-name',
              state: 'driving',
            ),
          ],
          grants: [
            ControlGrant(
              id: 'g1',
              assistant: 'Desk assistant',
              host: 'web',
              remaining: const Duration(minutes: 9),
              receivedAt: now,
            ),
          ],
        );

void main() {
  late Directory dir;
  late _MemoryClients clients;
  late _FakeBridge bridge;
  String? clipboard;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('phone_control_screens');
    clients = _MemoryClients();
    bridge = _FakeBridge(dir, clients);
    clipboard = null;
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  void mockClipboard(WidgetTester tester, {String? paste}) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String?;
        }
        if (call.method == 'Clipboard.getData') {
          return <String, Object?>{'text': paste};
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
  }

  // ===================================================== desktop: settings

  group('Settings, AI, Phone control (desktop)', () {
    Future<ValueNotifier<AppSettings>> pumpSection(
      WidgetTester tester, {
      AppSettings settings = const AppSettings(),
      bool failSave = false,
    }) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final current = ValueNotifier(settings);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<AppSettings>(
              valueListenable: current,
              builder: (context, value, _) => SingleChildScrollView(
                child: PhoneControlSettings(
                  settings: value,
                  apply: (change) async {
                    if (failSave) throw const FileSystemException('disk full');
                    current.value = change(current.value);
                  },
                  bridge: bridge,
                  clients: clients,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return current;
    }

    bool switchOn(WidgetTester tester) => tester
        .widget<SwitchListTile>(find.byKey(const ValueKey('phone-control-switch')))
        .value;

    testWidgets('is off by default and says the AI Bridge is off', (
      tester,
    ) async {
      await pumpSection(tester);
      expect(switchOn(tester), isFalse);
      expect(
        find.text('Answer approval cards from your phone'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('phone-control-needs-bridge')),
        findsOneWidget,
      );
      expect(find.text('No phone is paired yet.'), findsOneWidget);
    });

    testWidgets('no bridge hint while the AI Bridge is on', (tester) async {
      await pumpSection(tester, settings: const AppSettings(bridgeEnabled: true));
      expect(
        find.byKey(const ValueKey('phone-control-needs-bridge')),
        findsNothing,
      );
    });

    testWidgets('turning it on explains first; Cancel leaves it off', (
      tester,
    ) async {
      final current = await pumpSection(tester);
      await tester.tap(find.byKey(const ValueKey('phone-control-switch')));
      await tester.pumpAndSettle();
      expect(find.text('Let paired phones answer approval cards?'), findsOneWidget);
      expect(find.textContaining('cannot call tools'), findsOneWidget);
      expect(find.textContaining('through SSH'), findsOneWidget);
      expect(find.textContaining('AI Bridge switch must be on'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(current.value.bridgePhoneControl, isFalse);
      expect(switchOn(tester), isFalse);
    });

    testWidgets('Switch on turns it on, and the explanation comes back every time', (
      tester,
    ) async {
      final current = await pumpSection(tester);
      await tester.tap(find.byKey(const ValueKey('phone-control-switch')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Switch on'));
      await tester.pumpAndSettle();
      expect(current.value.bridgePhoneControl, isTrue);
      // Off needs no question.
      await tester.tap(find.byKey(const ValueKey('phone-control-switch')));
      await tester.pumpAndSettle();
      expect(current.value.bridgePhoneControl, isFalse);
      expect(find.text('Let paired phones answer approval cards?'), findsNothing);
      // On again: asked again.
      await tester.tap(find.byKey(const ValueKey('phone-control-switch')));
      await tester.pumpAndSettle();
      expect(find.text('Let paired phones answer approval cards?'), findsOneWidget);
    });

    testWidgets('a setting that cannot be saved is reported', (tester) async {
      final current = await pumpSection(tester, failSave: true);
      await tester.tap(find.byKey(const ValueKey('phone-control-switch')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Switch on'));
      await tester.pumpAndSettle();
      expect(
        find.text('That setting could not be saved, so it was put back.'),
        findsOneWidget,
      );
      expect(current.value.bridgePhoneControl, isFalse);
    });

    testWidgets('lists only phones, with "connected now", and removes one after asking', (
      tester,
    ) async {
      final phone = (await clients.create(
        'Pixel',
        role: BridgeClientRole.controller,
      )).client;
      await clients.create('Desk assistant');
      bridge.online = [phone];
      await pumpSection(tester);
      expect(find.text('Pixel'), findsOneWidget);
      expect(find.text('Desk assistant'), findsNothing);
      expect(find.text('Connected now'), findsOneWidget);

      await tester.tap(find.byKey(ValueKey('phone-remove-${phone.id}')));
      await tester.pumpAndSettle();
      expect(find.text('Remove Pixel?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(clients.list.where((c) => c.id == phone.id), isNotEmpty);

      await tester.tap(find.byKey(ValueKey('phone-remove-${phone.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();
      expect(clients.list.where((c) => c.id == phone.id), isEmpty);
      expect(find.text('Pixel'), findsNothing);
      expect(find.text('No phone is paired yet.'), findsOneWidget);
    });

    testWidgets('the connected marker follows the live list', (tester) async {
      final phone = (await clients.create(
        'Pixel',
        role: BridgeClientRole.controller,
      )).client;
      await pumpSection(tester);
      expect(find.text('Connected now'), findsNothing);
      bridge.onlineStream.add([phone]);
      await tester.pumpAndSettle();
      expect(find.text('Connected now'), findsOneWidget);
    });

    testWidgets('a removal that cannot be saved is reported and the phone stays', (
      tester,
    ) async {
      final phone = (await clients.create(
        'Pixel',
        role: BridgeClientRole.controller,
      )).client;
      clients.failRevoke = true;
      await pumpSection(tester);
      await tester.tap(find.byKey(ValueKey('phone-remove-${phone.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();
      expect(
        find.text('The pairing could not be removed, so it still works. Try again.'),
        findsOneWidget,
      );
      expect(find.text('Pixel'), findsOneWidget);
    });
  });

  group('the group inside Settings, AI', () {
    Future<void> pumpAi(WidgetTester tester, {required bool localChannel}) async {
      final b = _FakeBridge(dir, clients, localChannel: localChannel);
      tester.view.physicalSize = const Size(800, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AiBridgeSettingsSection(
                settings: const AppSettings(),
                apply: (_) async {},
                bridge: b,
                clients: clients,
                audit: BridgeAuditLog(
                  scrub: (s) => s,
                  directory: Directory('${dir.path}/bridge'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('shown where the local channel exists, with phones kept out of the assistants list', (
      tester,
    ) async {
      await clients.create('Pixel', role: BridgeClientRole.controller);
      await clients.create('Desk assistant');
      await pumpAi(tester, localChannel: true);
      expect(find.text('Phone control'), findsOneWidget);
      expect(find.text('Pixel'), findsOneWidget);
      expect(find.text('Desk assistant'), findsOneWidget);
      // The phone is under Phone control only: one revoke row for the
      // assistant and one removal for the phone.
      expect(find.byIcon(Icons.smart_toy_outlined), findsOneWidget);
    });

    testWidgets('left out without the local channel', (tester) async {
      await pumpAi(tester, localChannel: false);
      expect(find.text('Phone control'), findsNothing);
      expect(find.text('Answer approval cards from your phone'), findsNothing);
    });
  });

  // ======================================================== desktop: pairing

  group('Pair a phone', () {
    Future<void> pumpPair(WidgetTester tester) async {
      mockClipboard(tester);
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => PairPhoneScreen(clients: clients),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('pairs a controller, shows the token once with the steps', (
      tester,
    ) async {
      await pumpPair(tester);
      await tester.enterText(find.byKey(const ValueKey('pair-phone-name')), 'Pixel');
      await tester.tap(find.byKey(const ValueKey('pair-phone-create')));
      await tester.pumpAndSettle();
      expect(clients.created, [BridgeClientRole.controller]);
      expect(clients.list.single.name, 'Pixel');
      expect(find.text('tok-secret-1'), findsOneWidget);
      expect(find.text('This token is shown only once'), findsOneWidget);
      expect(find.textContaining('AI approvals on this computer'), findsOneWidget);
      expect(find.text('On the phone'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('pair-phone-copy')));
      await tester.pumpAndSettle();
      expect(clipboard, 'tok-secret-1');

      // Leaving by the system back asks first; Stay keeps the token.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Leave without the token?'), findsOneWidget);
      await tester.tap(find.text('Stay'));
      await tester.pumpAndSettle();
      expect(find.text('tok-secret-1'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('pair-phone-done')));
      await tester.pumpAndSettle();
      expect(find.text('open'), findsOneWidget);

      // A second visit starts from the form: the token is gone.
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('tok-secret-1'), findsNothing);
      expect(find.byKey(const ValueKey('pair-phone-name')), findsOneWidget);
    });

    testWidgets('a pairing that cannot be saved says so and shows no token', (
      tester,
    ) async {
      clients.failCreate = true;
      await pumpPair(tester);
      await tester.tap(find.byKey(const ValueKey('pair-phone-create')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pair-phone-token')), findsNothing);
      expect(find.textContaining('disk full'), findsOneWidget);
      expect(clients.list, isEmpty);
    });
  });

  // ================================================================ phone

  group('Remote approvals (phone)', () {
    late _MemoryBackend backend;
    late RemoteControllerTokenStore tokens;
    late DateTime now;
    late _FakeLink link;
    var opened = 0;
    Object? openError;
    Completer<void>? openGate;

    setUp(() {
      backend = _MemoryBackend();
      tokens = RemoteControllerTokenStore(backend);
      now = DateTime.utc(2026, 11, 17, 12);
      link = _FakeLink(_live());
      opened = 0;
      openError = null;
      openGate = null;
    });

    /// The screen as the home route, tall by default so that every card of a
    /// list is built (a list builds what is near the window); [viaRoute]
    /// pushes it, to leave it again.
    Future<void> pumpScreen(
      WidgetTester tester, {
      bool withToken = true,
      Size size = const Size(360, 12000),
      String? paste,
      bool viaRoute = false,
    }) async {
      mockClipboard(tester, paste: paste);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      if (withToken) await tokens.save(_host.id, 'phone-token');
      RemoteApprovalsScreen screen() => RemoteApprovalsScreen(
        host: _host,
        tokens: tokens,
        clock: () => now,
        open: (host, token) async {
          opened++;
          expect(token, 'phone-token');
          await openGate?.future;
          final e = openError;
          if (e != null) throw e;
          return link;
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: viaRoute
              ? Builder(
                  builder: (context) => Scaffold(
                    body: Center(
                      child: FilledButton(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(builder: (_) => screen()),
                        ),
                        child: const Text('open'),
                      ),
                    ),
                  ),
                )
              : screen(),
        ),
      );
      if (viaRoute) {
        await tester.tap(find.text('open'));
        // Past the route's slide, which is shorter than the arm delay.
        await tester.pump(const Duration(milliseconds: 400));
      }
      await tester.pump();
      await tester.pump();
    }

    Future<void> tick(WidgetTester tester, [Duration d = const Duration(milliseconds: 1100)]) =>
        tester.pump(d);

    testWidgets('first use: explains, saves the token (never shown again), connects', (
      tester,
    ) async {
      await pumpScreen(tester, withToken: false, paste: '  phone-token  ');
      await tester.pump();
      expect(find.textContaining('lets you answer'), findsOneWidget);
      expect(find.byKey(const ValueKey('remote-token-field')), findsOneWidget);
      expect(opened, 0);

      // Nothing typed: told so, nothing saved.
      await tester.tap(find.byKey(const ValueKey('remote-token-save')));
      await tester.pump();
      expect(find.text('Paste the token first.'), findsOneWidget);
      expect(await tokens.has(_host.id), isFalse);

      // The paste button fills the field (hidden), then Save.
      await tester.tap(find.byIcon(Icons.content_paste));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('remote-token-save')));
      await tester.pump();
      await tester.pump();
      expect(await tokens.load(_host.id), 'phone-token');
      expect(backend.data.keys.single, contains(_host.id));
      expect(opened, 1);
      expect(find.byKey(const ValueKey('remote-token-field')), findsNothing);
      expect(find.text('phone-token'), findsNothing);
      expect(find.byKey(const ValueKey('remote-status')), findsOneWidget);
    });

    testWidgets('a token that cannot be a token is refused', (tester) async {
      await pumpScreen(tester, withToken: false);
      await tester.enterText(
        find.byKey(const ValueKey('remote-token-field')),
        'x' * (RemoteControllerTokenStore.maxTokenChars + 1),
      );
      await tester.tap(find.byKey(const ValueKey('remote-token-save')));
      await tester.pump();
      await tester.pump();
      expect(find.text('That does not look like a pairing token.'), findsOneWidget);
      expect(await tokens.has(_host.id), isFalse);
    });

    testWidgets('shows connecting, then the live screen', (tester) async {
      openGate = Completer<void>();
      await pumpScreen(tester);
      expect(find.byKey(const ValueKey('remote-connecting')), findsOneWidget);
      expect(find.textContaining('My desktop'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      openGate!.complete();
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('remote-connecting')), findsNothing);
      expect(find.text('Connected to My desktop as Pixel.'), findsOneWidget);
      expect(
        find.textContaining('only works while this screen is open'),
        findsOneWidget,
      );
    });

    final errors = <(RemoteBridgeErrorKind, String)>[
      (
        RemoteBridgeErrorKind.notRunning,
        'SecureShell Go is not running on that computer, or its AI Bridge is off.',
      ),
      (
        RemoteBridgeErrorKind.refused,
        'That computer did not accept this phone. The token may be wrong or its pairing removed, or Phone control is off there.',
      ),
      (
        RemoteBridgeErrorKind.launcherNotFound,
        'The SecureShell Go launcher was not found on that computer. Install version 1.8.0 or newer there.',
      ),
      (
        RemoteBridgeErrorKind.tooManySessions,
        'Two phones are already connected to that computer.',
      ),
      (
        RemoteBridgeErrorKind.connectionLost,
        'The connection to the computer ended.',
      ),
      (
        RemoteBridgeErrorKind.protocol,
        'The computer and this phone speak different versions. Update SecureShell Go on both.',
      ),
      (
        RemoteBridgeErrorKind.failed,
        'Could not talk to SecureShell Go on that computer.',
      ),
    ];
    for (final (kind, text) in errors) {
      testWidgets('a ${kind.name} error says it plainly and offers Reconnect', (
        tester,
      ) async {
        openError = RemoteBridgeError(kind, 'detail-${kind.name}');
        await pumpScreen(tester);
        expect(find.text(text), findsOneWidget);
        expect(find.text('detail-${kind.name}'), findsOneWidget);
        expect(find.byKey(const ValueKey('remote-reconnect')), findsOneWidget);

        // Reconnect tries again, and works once the cause is gone.
        openError = null;
        await tester.tap(find.byKey(const ValueKey('remote-reconnect')));
        await tester.pump();
        await tester.pump();
        expect(opened, 2);
        expect(find.text(text), findsNothing);
        expect(find.byKey(const ValueKey('remote-status')), findsOneWidget);
      });
    }

    testWidgets('sign-in problems: one that needs the user, and a plain failure', (
      tester,
    ) async {
      openError = const RemoteConnectFailure(
        'The host key has not been checked yet.',
        needsPerson: true,
      );
      await pumpScreen(tester);
      expect(
        find.text(
          'Signing in to this host needs you. Connect to it once from the host list, then try again.',
        ),
        findsOneWidget,
      );
      expect(find.text('The host key has not been checked yet.'), findsOneWidget);
      openError = const RemoteConnectFailure('Connection refused');
      await tester.tap(find.byKey(const ValueKey('remote-reconnect')));
      await tester.pump();
      await tester.pump();
      expect(find.text('Could not connect to this host.'), findsOneWidget);
    });

    testWidgets('a dropped connection shows the error and Reconnect opens a new session', (
      tester,
    ) async {
      await pumpScreen(tester);
      final first = link;
      link = _FakeLink(_live());
      first.push(
        RemoteBridgeState(
          phase: RemoteBridgePhase.closed,
          error: const RemoteBridgeError(
            RemoteBridgeErrorKind.connectionLost,
            'The connection to the computer ended.',
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('remote-reconnect')), findsOneWidget);
      expect(first.closed, isTrue);
      await tester.tap(find.byKey(const ValueKey('remote-reconnect')));
      await tester.pump();
      await tester.pump();
      expect(opened, 2);
      expect(find.byKey(const ValueKey('remote-status')), findsOneWidget);
    });

    testWidgets('live with no card: says nothing is waiting', (tester) async {
      await pumpScreen(tester);
      expect(find.byKey(const ValueKey('remote-nothing-waiting')), findsOneWidget);
      expect(find.byType(RemoteApprovalCard), findsNothing);
      expect(find.byKey(const ValueKey('remote-locked')), findsNothing);
      expect(find.text('No activity yet.'), findsOneWidget);
    });

    testWidgets('a locked computer shows the banner', (tester) async {
      link = _FakeLink(_live(locked: true));
      await pumpScreen(tester);
      expect(find.byKey(const ValueKey('remote-locked')), findsOneWidget);
      expect(find.textContaining('locked on that computer'), findsOneWidget);
      link.push(_live());
      await tester.pump();
      expect(find.byKey(const ValueKey('remote-locked')), findsNothing);
    });

    testWidgets('several cards, oldest first, each with its own data', (
      tester,
    ) async {
      link = _FakeLink(
        _live(
          approvals: [
            _command('a1', 'uptime', at: now, assistant: 'First', host: 'web'),
            _command('a2', 'df -h', at: now, assistant: 'Second', host: 'db'),
          ],
        ),
      );
      await pumpScreen(tester);
      expect(find.byType(RemoteApprovalCard), findsNWidgets(2));
      final first = tester.getTopLeft(find.byKey(const ValueKey('remote-card-a1')));
      final second = tester.getTopLeft(find.byKey(const ValueKey('remote-card-a2')));
      expect(first.dy, lessThan(second.dy));
      expect(find.text('Asked by First'), findsOneWidget);
      expect(find.text('Asked by Second'), findsOneWidget);
      expect(find.text('On web'), findsOneWidget);
      expect(find.text('On db'), findsOneWidget);
      // A new card arrives live.
      link.push(
        _live(
          approvals: [
            _command('a1', 'uptime', at: now),
            _command('a2', 'df -h', at: now),
            _command('a3', 'free -m', at: now),
          ],
        ),
      );
      await tester.pump();
      expect(find.byType(RemoteApprovalCard), findsNWidgets(3));
    });

    testWidgets('Allow is disabled for the first second; Deny never is', (
      tester,
    ) async {
      link = _FakeLink(_live(approvals: [_command('a1', 'uptime', at: now)]));
      await pumpScreen(tester);
      OutlinedButton once() => tester.widget<OutlinedButton>(
        find.byKey(const ValueKey('approval-allow-once')),
      );
      FilledButton deny() => tester.widget<FilledButton>(
        find.byKey(const ValueKey('approval-deny')),
      );
      expect(once().onPressed, isNull);
      expect(deny().onPressed, isNotNull);
      // A tap inside the delay does nothing.
      await tester.tap(find.byKey(const ValueKey('approval-allow-once')));
      await tester.pump();
      expect(link.answers, isEmpty);
      await tick(tester);
      expect(once().onPressed, isNotNull);
    });

    testWidgets('Allow for N minutes only when the card and the computer allow it', (
      tester,
    ) async {
      link = _FakeLink(
        _live(
          timedMinutes: 15,
          approvals: [
            _command('a1', 'uptime', at: now, timed: true),
            _command('a2', 'reboot', at: now, timed: false),
          ],
        ),
      );
      await pumpScreen(tester);
      expect(find.byKey(const ValueKey('approval-allow-for-a-while')), findsOneWidget);
      expect(find.text('Allow for 15 minutes'), findsOneWidget);
      // Computer's setting off: no timed button on a card that says timed.
      link.push(
        _live(
          timedMinutes: 0,
          approvals: [_command('a1', 'uptime', at: now, timed: true)],
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('approval-allow-for-a-while')), findsNothing);
    });

    testWidgets('Deny, Allow once and Allow for N minutes call the right action', (
      tester,
    ) async {
      link = _FakeLink(
        _live(
          timedMinutes: 15,
          approvals: [
            _command('a1', 'one', at: now, timed: true),
            _command('a2', 'two', at: now, timed: true),
            _command('a3', 'three', at: now, timed: true),
          ],
        ),
      );
      await pumpScreen(tester);
      await tick(tester);
      Finder inCard(String id, String key) => find.descendant(
        of: find.byKey(ValueKey('remote-card-$id')),
        matching: find.byKey(ValueKey(key)),
      );
      for (final id in ['a1', 'a2', 'a3']) {
        await tester.ensureVisible(inCard(id, 'approval-deny'));
        await tester.pump();
      }
      await tester.tap(inCard('a1', 'approval-deny'));
      await tester.pump();
      await tester.ensureVisible(inCard('a2', 'approval-allow-once'));
      await tester.tap(inCard('a2', 'approval-allow-once'));
      await tester.pump();
      await tester.ensureVisible(inCard('a3', 'approval-allow-for-a-while'));
      await tester.tap(inCard('a3', 'approval-allow-for-a-while'));
      await tester.pump();
      expect(link.answers, [
        ('a1', ControlAnswer.deny),
        ('a2', ControlAnswer.once),
        ('a3', ControlAnswer.forMinutes),
      ]);
      // An accepted answer leaves the card inert until the computer removes it.
      expect(
        tester.widget<FilledButton>(inCard('a1', 'approval-deny')).onPressed,
        isNull,
      );
      // The computer removes it, the card goes.
      link.push(
        _live(
          timedMinutes: 15,
          approvals: [
            _command('a2', 'two', at: now, timed: true),
            _command('a3', 'three', at: now, timed: true),
          ],
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('remote-card-a1')), findsNothing);
    });

    testWidgets('a card already answered says so, and stays inert', (tester) async {
      link = _FakeLink(_live(approvals: [_command('a1', 'uptime', at: now)]));
      link.nextResult = const RemoteActionResult.failed(
        ControlErrorCode.notFound,
        'gone',
      );
      await pumpScreen(tester);
      await tick(tester);
      await tester.tap(find.byKey(const ValueKey('approval-allow-once')));
      await tester.pump();
      await tester.pump();
      expect(
        find.text('That card was already answered or has timed out.'),
        findsOneWidget,
      );
      expect(
        tester.widget<OutlinedButton>(find.byKey(const ValueKey('approval-allow-once'))).onPressed,
        isNull,
      );
    });

    testWidgets('another failure shows the computer\'s reason and allows another try', (
      tester,
    ) async {
      link = _FakeLink(_live(approvals: [_command('a1', 'uptime', at: now)]));
      link.nextResult = const RemoteActionResult.failed(
        ControlErrorCode.notAllowed,
        'Not allowed here.',
      );
      await pumpScreen(tester);
      await tick(tester);
      await tester.tap(find.byKey(const ValueKey('approval-allow-once')));
      await tester.pump();
      await tester.pump();
      expect(find.text('That did not work: Not allowed here.'), findsOneWidget);
      link.nextResult = const RemoteActionResult.ok();
      await tester.tap(find.byKey(const ValueKey('approval-allow-once')));
      await tester.pump();
      expect(link.answers.length, 2);
      expect(find.byKey(const ValueKey('approval-failure')), findsNothing);
    });

    testWidgets('a second tap while the answer is on its way does nothing', (
      tester,
    ) async {
      link = _FakeLink(_live(approvals: [_command('a1', 'uptime', at: now)]));
      link.hold = Completer<RemoteActionResult>();
      await pumpScreen(tester);
      await tick(tester);
      await tester.tap(find.byKey(const ValueKey('approval-deny')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('approval-deny')));
      await tester.pump();
      expect(link.answers.length, 1);
      link.hold!.complete(const RemoteActionResult.ok());
      await tester.pump();
    });

    testWidgets('the countdown follows the card and ends in Expired', (
      tester,
    ) async {
      link = _FakeLink(
        _live(
          approvals: [
            _command('a1', 'uptime', at: now, remaining: const Duration(seconds: 90)),
          ],
        ),
      );
      await pumpScreen(tester);
      expect(find.text('Denied automatically in 1:30 if you do not answer.'), findsOneWidget);
      now = now.add(const Duration(seconds: 30));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Denied automatically in 1:00 if you do not answer.'), findsOneWidget);
      now = now.add(const Duration(seconds: 61));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Time ran out. This was denied.'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byKey(const ValueKey('approval-deny'))).onPressed,
        isNull,
      );
    });

    testWidgets('every kind of card draws what it asks, and phone width does not overflow', (
      tester,
    ) async {
      link = _FakeLink(_everyKind(now));
      await pumpScreen(tester, size: const Size(360, 740));
      for (final id in ['c', 's', 'f', 't', 'd', 'j', 'o']) {
        final card = find.byKey(ValueKey('remote-card-$id'));
        await tester.scrollUntilVisible(
          card,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(card, findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('every kind of card says what it asks for', (tester) async {
      link = _FakeLink(_everyKind(now));
      await pumpScreen(tester);
      expect(find.text('Restart the service nginx.service.'), findsOneWidget);
      expect(find.text('/etc/app.conf'), findsOneWidget);
      expect(find.byKey(const ValueKey('approval-terminal-warning')), findsOneWidget);
      expect(find.byKey(const ValueKey('approval-desktop-warning')), findsOneWidget);
      expect(find.text('Name: dev server'), findsOneWidget);
      expect(find.byKey(const ValueKey('approval-partial-warning')), findsOneWidget);
      // A card of a kind this version cannot show can only be denied.
      expect(find.byKey(const ValueKey('approval-unreadable')), findsOneWidget);
      final other = find.byKey(const ValueKey('remote-card-o'));
      expect(
        find.descendant(
          of: other,
          matching: find.byKey(const ValueKey('approval-allow-once')),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('spans are drawn as they arrive: stand-ins marked, legend shown, raw characters never', (
      tester,
    ) async {
      link = _FakeLink(
        _live(approvals: [_command('a1', 'ls\u202E gnp.txt\u0007', at: now)]),
      );
      await pumpScreen(tester);
      final box = find.descendant(
        of: find.byKey(const ValueKey('approval-command')),
        matching: find.byType(SelectableText),
      );
      final text = tester.widget<SelectableText>(box).textSpan!.toPlainText();
      expect(text.contains('\u202E'), isFalse);
      expect(text.contains('\u0007'), isFalse);
      expect(text, contains('ls'));
      expect(find.byKey(const ValueKey('approval-legend')), findsOneWidget);
    });

    testWidgets('Open now and Time-limited approvals: Stop calls the right action', (
      tester,
    ) async {
      link = _FakeLink(
        _live(
          items: const [
            ControlItem(
              kind: ControlItemKind.terminal,
              id: 't1',
              assistant: 'Desk assistant',
              host: 'web',
              state: 'driving',
            ),
            ControlItem(
              kind: ControlItemKind.desktop,
              id: 'd1',
              assistant: 'Desk assistant',
              host: 'web',
              state: 'driving',
            ),
            ControlItem(
              kind: ControlItemKind.job,
              id: 'j1',
              assistant: 'Desk assistant',
              host: 'web',
              state: 'running',
              label: 'dev server',
            ),
          ],
          grants: [
            ControlGrant(
              id: 'g1',
              assistant: 'Desk assistant',
              host: 'web',
              remaining: const Duration(minutes: 9),
              receivedAt: now,
            ),
          ],
        ),
      );
      await pumpScreen(tester);
      expect(find.text('Open now'), findsOneWidget);
      expect(find.text('Time-limited approvals'), findsOneWidget);
      expect(find.text('Job: dev server'), findsOneWidget);
      expect(find.text('9 minutes left'), findsOneWidget);
      for (final key in ['stop-item-job-j1', 'stop-item-terminal-t1', 'stop-item-desktop-d1', 'stop-grant-g1']) {
        await tester.ensureVisible(find.byKey(ValueKey(key)));
        await tester.tap(find.byKey(ValueKey(key)));
        await tester.pump();
        await tester.pump();
      }
      expect(link.itemStops, [
        (ControlItemKind.job, 'j1'),
        (ControlItemKind.terminal, 't1'),
        (ControlItemKind.desktop, 'd1'),
      ]);
      expect(link.grantStops, ['g1']);
    });

    testWidgets('a Stop the computer refuses is reported', (tester) async {
      link = _FakeLink(
        _live(
          items: const [
            ControlItem(
              kind: ControlItemKind.job,
              id: 'j1',
              assistant: 'Desk assistant',
              host: 'web',
              state: 'running',
            ),
          ],
        ),
      );
      link.nextResult = const RemoteActionResult.failed(
        ControlErrorCode.notFound,
        'Already gone.',
      );
      await pumpScreen(tester);
      await tester.tap(find.byKey(const ValueKey('stop-item-job-j1')));
      await tester.pump();
      await tester.pump();
      expect(find.text('That did not work: Already gone.'), findsOneWidget);
    });

    testWidgets('recent activity lists what happened, and from which phone', (
      tester,
    ) async {
      link = _FakeLink(
        _live(
          activity: [
            ControlActivity(
              ts: DateTime.utc(2026, 11, 17, 11),
              assistant: 'Desk assistant',
              host: 'web',
              tool: 'run_command',
              outcome: 'ok',
              approval: 'once',
              detail: '',
              args: '',
              via: 'controller:Pixel',
            ),
          ],
        ),
      );
      await pumpScreen(tester);
      await tester.scrollUntilVisible(
        find.text('run_command on web'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('run_command on web'), findsOneWidget);
      expect(find.textContaining('answered from controller:Pixel'), findsOneWidget);
    });

    testWidgets('leaving the screen closes the session', (tester) async {
      await pumpScreen(tester, viaRoute: true);
      expect(link.closed, isFalse);
      await tester.pageBack();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(link.closed, isTrue);
    });

    testWidgets('Remove token asks, forgets the token, closes the session and shows setup', (
      tester,
    ) async {
      await pumpScreen(tester);
      await tester.tap(find.byKey(const ValueKey('remote-menu')));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      await tester.tap(find.text('Remove token').last);
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.text('Remove the saved token?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(await tokens.has(_host.id), isTrue);

      await tester.tap(find.byKey(const ValueKey('remote-menu')));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      await tester.tap(find.text('Remove token').last);
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      await tester.tap(find.widgetWithText(FilledButton, 'Remove token'));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(await tokens.has(_host.id), isFalse);
      expect(link.closed, isTrue);
      expect(find.byKey(const ValueKey('remote-token-field')), findsOneWidget);
    });

    testWidgets('a token that cannot be removed is reported and kept', (tester) async {
      await pumpScreen(tester);
      backend.failDelete = true;
      await tester.tap(find.byKey(const ValueKey('remote-menu')));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      await tester.tap(find.text('Remove token').last);
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      await tester.tap(find.widgetWithText(FilledButton, 'Remove token'));
      await tester.pump();
      await tester.pump();
      expect(find.text('The token could not be removed. Try again.'), findsOneWidget);
      expect(await tokens.has(_host.id), isTrue);
      expect(link.closed, isFalse);
    });
  });
}
