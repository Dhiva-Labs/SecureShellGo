import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/app_settings.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/models/host_ai_access.dart';
import 'package:secure_shell_go/screens/bridge_audit_screen.dart';
import 'package:secure_shell_go/screens/bridge_connect_screen.dart';
import 'package:secure_shell_go/screens/settings/ai_bridge_section.dart';
import 'package:secure_shell_go/screens/settings_screen.dart';
import 'package:secure_shell_go/services/bridge/bridge_audit.dart';
import 'package:secure_shell_go/services/bridge/bridge_client_store.dart';
import 'package:secure_shell_go/services/bridge/bridge_connections.dart';
import 'package:secure_shell_go/services/bridge/bridge_launcher_locator.dart';
import 'package:secure_shell_go/services/bridge/bridge_paths.dart';
import 'package:secure_shell_go/services/bridge/bridge_service.dart';
import 'package:secure_shell_go/services/bridge/bridge_redactor.dart';
import 'package:secure_shell_go/services/bridge/bridge_tools.dart';
import 'package:secure_shell_go/services/host_store.dart';
import 'package:secure_shell_go/services/known_hosts_service.dart';
import 'package:secure_shell_go/services/settings_store.dart';

import 'support/settle.dart';
import 'support/tracked_stores.dart';
import 'support/temp_dir.dart';

BridgeConnections _connections() => BridgeConnections(
  openTransport: (_) => null,
  credentialLookup: (_) async => null,
  dialer: (host, _) async => throw StateError('no dialling'),
);

/// A [BridgeService] whose status and connections the test sets, without a
/// listener behind it.
class _FakeBridge extends BridgeService {
  _FakeBridge(Directory dir, BridgeClientStore clients, BridgeAuditLog audit)
    : this._(dir, clients, audit, _connections());

  _FakeBridge._(
    Directory dir,
    BridgeClientStore clients,
    BridgeAuditLog audit,
    BridgeConnections connections,
  ) : super(
        settingsStore: SettingsStore(file: File('${dir.path}/unused.json')),
        clients: clients,
        connections: connections,
        tools: BridgeTools(
          loadHosts: () async => const [],
          settings: () => const AppSettings(),
          isAppLocked: () => false,
          connections: connections,
          redactor: BridgeRedactor(scrub: (s) => s),
          audit: audit,
        ),
        createListener: (_) async => throw StateError('no listener'),
      );

  BridgeStatus current = BridgeStatus.off;
  List<BridgeClient> connected = const [];

  @override
  BridgeStatus get status => current;

  @override
  Stream<BridgeStatus> get statusChanges => const Stream.empty();

  @override
  List<BridgeClient> get connectedClients => connected;

  @override
  Stream<List<BridgeClient>> get connectedClientsChanges =>
      const Stream.empty();
}

/// A log whose Clear always fails.
class _FailingClear extends TrackedAuditLog {
  _FailingClear(super.io, Directory dir)
    : super(scrub: (s) => s, directory: Directory('${dir.path}/failing'));

  @override
  Future<bool> clear() async => false;
}

void main() {
  late Directory dir;
  late BridgeClientStore clients;
  late BridgeAuditLog audit;
  late _FakeBridge bridge;
  late HostStore hostStore;
  late BridgeAuditLog brokenAudit;
  late IoTracker io;
  String? clipboard;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ai_bridge_screens_test');
    io = IoTracker();
    clients = TrackedClientStore(io, file: File('${dir.path}/clients.json'));
    audit = TrackedAuditLog(
      io,
      scrub: (s) => s,
      directory: Directory('${dir.path}/bridge'),
    );
    bridge = _FakeBridge(dir, clients, audit);
    // Built here, not in a test body: a store made inside `testWidgets`
    // queues its first write on the fake clock, which `runAsync` never turns.
    hostStore = TrackedHostStore(io, file: File('${dir.path}/hosts.json'));
    // A log whose directory cannot exist: its parent is a file.
    File('${dir.path}/blocker').writeAsStringSync('x');
    brokenAudit = TrackedAuditLog(
      io,
      scrub: (s) => s,
      directory: Directory('${dir.path}/blocker/bridge'),
    );
    clipboard = null;
  });

  tearDown(() async {
    await audit.dispose();
    await brokenAudit.dispose();
    await deleteTempDir(dir);
  });

  void mockClipboard(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String?;
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

  /// Turns the real event loop, then rebuilds.
  ///
  /// Waits until no store or log call is still running and no progress
  /// indicator is up, rather than for a fixed number of turns, which was
  /// too few on slow CI runners.
  bool busy() =>
      io.busy ||
      find
          .byWidgetPredicate((w) => w is ProgressIndicator)
          .evaluate()
          .isNotEmpty;

  Future<void> settle(WidgetTester tester) async {
    await settleWhile(tester, busy);
    // Past a route or dialog animation, without waiting on a spinner.
    await tester.pump(const Duration(milliseconds: 500));
    await settleWhile(tester, busy);
    await tester.pump(const Duration(milliseconds: 500));
  }

  /// The section, with the settings it is given kept as the test changes them.
  Future<ValueNotifier<AppSettings>> pumpSection(
    WidgetTester tester, {
    AppSettings settings = const AppSettings(),
    HostStore? hostStore,
    BridgeAuditLog? log,
    Size size = const Size(800, 3000),
    double textScale = 1,
    bool failSave = false,
    DateTime Function()? clock,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final current = ValueNotifier(settings);
    // A fresh tree each time, so a second call starts from its own state.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: ValueListenableBuilder<AppSettings>(
            valueListenable: current,
            builder: (context, value, _) => SingleChildScrollView(
              child: AiBridgeSettingsSection(
                settings: value,
                apply: (change) async {
                  if (failSave) throw const FileSystemException('disk full');
                  current.value = change(current.value);
                },
                bridge: bridge,
                clients: clients,
                audit: log ?? audit,
                hostStore: hostStore,
                clock: clock ?? DateTime.now,
              ),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
    return current;
  }

  Future<BridgeClient> pair(WidgetTester tester, String name) async {
    late BridgeClient client;
    await tester.runAsync(() async {
      client = (await clients.create(name)).client;
    });
    return client;
  }

  BridgeAuditEntryRecorder recorder(WidgetTester tester) =>
      (outcome, {String? host, String tool = 'list_dir', String detail = ''}) =>
          tester.runAsync(
            () => audit.record(
              client: 'Desk assistant',
              host: host,
              tool: tool,
              args: const {},
              outcome: outcome,
              detail: detail,
              ms: 3,
            ),
          );

  SwitchListTile switchTile(WidgetTester tester, String title) =>
      tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, title));

  Future<void> tapSwitch(WidgetTester tester, String title) async {
    await tester.tap(find.widgetWithText(SwitchListTile, title));
    await tester.pumpAndSettle();
  }

  group('the settings section', () {
    testWidgets('shows everything, all off by default', (tester) async {
      await pumpSection(tester, hostStore: hostStore);
      expect(find.text('AI Bridge'), findsNWidgets(2)); // header + switch
      expect(switchTile(tester, 'AI Bridge').value, isFalse);
      expect(switchTile(tester, 'Show address and username').value, isFalse);
      expect(switchTile(tester, 'Read sensitive paths').value, isFalse);
      expect(find.text('Off'), findsNWidgets(2)); // status + timed choice
      expect(find.text('Extra blocked paths'), findsOneWidget);
      expect(find.text('Paired assistants'), findsOneWidget);
      expect(find.text('No assistant is paired yet.'), findsOneWidget);
      expect(find.text('Connect an assistant'), findsOneWidget);
      expect(find.text('Activity'), findsOneWidget);
      expect(find.text('Shared hosts — 0 of 0'), findsOneWidget);
    });

    testWidgets('shows the live status in words', (tester) async {
      bridge.current = BridgeStatus.running;
      await pumpSection(tester);
      expect(find.text('Running'), findsOneWidget);

      bridge.current = BridgeStatus.runningElsewhere;
      await pumpSection(tester);
      expect(
        find.text('Running in another SecureShell Go window'),
        findsOneWidget,
      );

      bridge.current = const BridgeError('address in use');
      await pumpSection(tester);
      expect(find.text('Could not start: address in use'), findsOneWidget);
    });

    testWidgets('the first time on, it asks, and says what it means', (
      tester,
    ) async {
      final settings = await pumpSection(tester);
      await tapSwitch(tester, 'AI Bridge');
      expect(find.text('Turn on the AI Bridge?'), findsOneWidget);
      expect(find.textContaining('never gets your passwords'), findsOneWidget);
      expect(find.textContaining('sent by that assistant'), findsOneWidget);
      expect(find.textContaining('Nothing can be changed'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(settings.value.bridgeEnabled, isFalse);

      await tapSwitch(tester, 'AI Bridge');
      await tester.tap(find.text('Turn on'));
      await tester.pumpAndSettle();
      expect(settings.value.bridgeEnabled, isTrue);
    });

    testWidgets('with an assistant already paired, on still asks', (
      tester,
    ) async {
      // Pairing works with the bridge off, so a paired assistant is no sign
      // the explanation was ever shown.
      await pair(tester, 'Desk assistant');
      final settings = await pumpSection(tester);
      await tapSwitch(tester, 'AI Bridge');
      expect(find.text('Turn on the AI Bridge?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(settings.value.bridgeEnabled, isFalse);

      await tapSwitch(tester, 'AI Bridge');
      await tester.tap(find.text('Turn on'));
      await tester.pumpAndSettle();
      expect(settings.value.bridgeEnabled, isTrue);
    });

    testWidgets('off needs no question', (tester) async {
      final settings = await pumpSection(
        tester,
        settings: const AppSettings(bridgeEnabled: true),
      );
      await tapSwitch(tester, 'AI Bridge');
      expect(find.byType(AlertDialog), findsNothing);
      expect(settings.value.bridgeEnabled, isFalse);
    });

    testWidgets('a setting that could not be saved says so', (tester) async {
      final settings = await pumpSection(
        tester,
        settings: const AppSettings(bridgeEnabled: true),
        failSave: true,
      );
      await tapSwitch(tester, 'AI Bridge');
      expect(settings.value.bridgeEnabled, isTrue);
      expect(switchTile(tester, 'AI Bridge').value, isTrue);
      expect(
        find.text('That setting could not be saved, so it was put back.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('"Show address and username" is a plain switch', (
      tester,
    ) async {
      final settings = await pumpSection(tester);
      await tapSwitch(tester, 'Show address and username');
      expect(find.byType(AlertDialog), findsNothing);
      expect(settings.value.bridgeShowAddress, isTrue);
      expect(settings.value.bridgeReadSensitivePaths, isFalse);
    });

    testWidgets('"Read sensitive paths" warns before it turns on', (
      tester,
    ) async {
      final settings = await pumpSection(tester);
      await tapSwitch(tester, 'Read sensitive paths');
      expect(find.text('Allow reading sensitive paths?'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining('key files, .env files'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(settings.value.bridgeReadSensitivePaths, isFalse);

      await tapSwitch(tester, 'Read sensitive paths');
      await tester.tap(find.text('Allow'));
      await tester.pumpAndSettle();
      expect(settings.value.bridgeReadSensitivePaths, isTrue);

      // And off again with no warning.
      await tapSwitch(tester, 'Read sensitive paths');
      expect(find.byType(AlertDialog), findsNothing);
      expect(settings.value.bridgeReadSensitivePaths, isFalse);
    });

    testWidgets('extra blocked paths are added and removed', (tester) async {
      final settings = await pumpSection(tester);
      expect(find.text('No extra patterns.'), findsOneWidget);

      await tester.tap(find.text('Add a pattern'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '  /srv/private/**  ');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(settings.value.bridgeExtraBlockedPaths, ['/srv/private/**']);
      expect(find.text('/srv/private/**'), findsOneWidget);

      // The same pattern twice is kept once; a blank one is not added.
      await tester.tap(find.text('Add a pattern'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '/srv/private/**');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add a pattern'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '   ');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(settings.value.bridgeExtraBlockedPaths, ['/srv/private/**']);

      await tester.tap(find.byTooltip('Remove /srv/private/**'));
      await tester.pumpAndSettle();
      expect(settings.value.bridgeExtraBlockedPaths, isEmpty);
      expect(find.text('No extra patterns.'), findsOneWidget);
    });

    testWidgets('the built-in blocked paths can be read', (tester) async {
      await pumpSection(tester);
      await tester.tap(find.text('View built-in blocked paths'));
      await tester.pumpAndSettle();
      expect(find.text('Built-in blocked paths'), findsOneWidget);
      expect(find.text(BridgePathGuard.builtInPatterns.first), findsOneWidget);
    });

    testWidgets('lists paired assistants, marks the connected one', (
      tester,
    ) async {
      final desk = await pair(tester, 'Desk assistant');
      await pair(tester, 'Laptop assistant');
      bridge.connected = [desk];
      await pumpSection(tester);
      expect(find.text('Desk assistant'), findsOneWidget);
      expect(find.text('Laptop assistant'), findsOneWidget);
      expect(find.text('Connected'), findsOneWidget);
      expect(find.textContaining('not connected yet'), findsNWidgets(2));
      expect(
        find.textContaining(RegExp(r'^Paired (?!assistants)')),
        findsNWidgets(2),
      );
    });

    testWidgets('revoke asks first, and then revokes', (tester) async {
      await pair(tester, 'Desk assistant');
      await pumpSection(tester);

      await tester.tap(find.byTooltip('Revoke'));
      await tester.pumpAndSettle();
      expect(find.text('Revoke Desk assistant?'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect((await tester.runAsync(clients.load))!, hasLength(1));

      await tester.tap(find.byTooltip('Revoke'));
      await tester.pumpAndSettle();
      await tester.runAsync(() => tester.tap(find.text('Revoke').last));
      await settle(tester);
      expect((await tester.runAsync(clients.load))!, isEmpty);
      expect(find.text('Desk assistant'), findsNothing);
      expect(find.text('No assistant is paired yet.'), findsOneWidget);
    });

    testWidgets('Connect an assistant opens the pairing screen', (
      tester,
    ) async {
      await pumpSection(tester);
      await tester.tap(find.text('Connect an assistant'));
      await tester.pumpAndSettle();
      expect(find.byType(BridgeConnectScreen), findsOneWidget);
    });

    testWidgets('Activity opens the log', (tester) async {
      await pumpSection(tester);
      await tester.tap(find.text('Activity'));
      await settle(tester);
      expect(find.byType(BridgeAuditScreen), findsOneWidget);
    });

    testWidgets('warns when the activity log cannot be written', (
      tester,
    ) async {
      await pumpSection(tester);
      expect(find.textContaining('could not be saved'), findsNothing);
      await pumpSection(tester, log: brokenAudit);
      await tester.runAsync(
        () => brokenAudit.record(
          client: 'a',
          host: null,
          tool: 'list_hosts',
          args: const {},
          outcome: BridgeAuditOutcome.ok,
          ms: 1,
        ),
      );
      await tester.pump();
      expect(find.textContaining('could not be saved'), findsOneWidget);
    });

    testWidgets('the warning goes when the log can be written again', (
      tester,
    ) async {
      final log = BridgeAuditLog(
        scrub: (s) => s,
        directory: Directory('${dir.path}/blocker/bridge'),
      );
      addTearDown(log.dispose);
      Future<void> record() => tester.runAsync(
        () => log.record(
          client: 'a',
          host: null,
          tool: 'list_hosts',
          args: const {},
          outcome: BridgeAuditOutcome.ok,
          ms: 1,
        ),
      );
      await pumpSection(tester, log: log);
      await record();
      await tester.pump();
      expect(find.textContaining('could not be saved'), findsOneWidget);

      await tester.runAsync(() => File('${dir.path}/blocker').delete());
      await record();
      await tester.pump();
      expect(find.textContaining('could not be saved'), findsNothing);
    });

    testWidgets('counts the shared hosts', (tester) async {
      final hosts = hostStore;
      Host host(String id, HostAiAccess access) => Host(
        id: id,
        label: id,
        hostname: '$id.test',
        port: 22,
        username: 'u',
        authMethod: SshAuthMethod.password,
        aiAccess: access,
      );
      await tester.runAsync(() async {
        await hosts.add(host('a', HostAiAccess.readOnly));
        await hosts.add(host('b', HostAiAccess.off));
      });
      await pumpSection(tester, hostStore: hosts);
      await settle(tester);
      expect(find.text('Shared hosts — 1 of 2'), findsOneWidget);
    });

    testWidgets('fits a narrow window at large text', (tester) async {
      final desk = await pair(tester, 'A rather long assistant name');
      bridge
        ..connected = [desk]
        ..current = const BridgeError('something went wrong at length');
      await pumpSection(
        tester,
        settings: const AppSettings(
          bridgeEnabled: true,
          bridgeExtraBlockedPaths: ['/srv/a-fairly-long/path/pattern/**'],
        ),
        size: const Size(320, 568),
        textScale: 1.5,
      );
      expect(tester.takeException(), isNull);
      await pumpSection(tester, size: const Size(1920, 1080));
      expect(tester.takeException(), isNull);
    });
  });

  group('the settings screen', () {
    Future<SettingsStore> pumpScreen(
      WidgetTester tester, {
      required bool withBridge,
      String storePath = 'settings.json',
    }) async {
      final store = SettingsStore(file: File('${dir.path}/$storePath'));
      addTearDown(store.dispose);
      await tester.runAsync(store.ensureLoaded);
      tester.view.physicalSize = const Size(800, 5000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            settingsStore: store,
            knownHosts: KnownHostsService(file: File('${dir.path}/kh.json')),
            bridge: withBridge ? bridge : null,
            bridgeClients: withBridge ? clients : null,
            bridgeAudit: withBridge ? audit : null,
          ),
        ),
      );
      await tester.pumpAndSettle();
      return store;
    }

    testWidgets('a bridge setting that cannot be saved goes back', (
      tester,
    ) async {
      // The settings file's parent is a plain file, so every write fails.
      final store = await pumpScreen(
        tester,
        withBridge: true,
        storePath: 'blocker/settings.json',
      );
      expect(store.current.bridgeShowAddress, isFalse);
      await tester.tap(
        find.widgetWithText(SwitchListTile, 'Show address and username'),
      );
      await settle(tester);
      await tester.pumpAndSettle();
      expect(store.current.bridgeShowAddress, isFalse);
      expect(
        tester
            .widget<SwitchListTile>(
              find.widgetWithText(SwitchListTile, 'Show address and username'),
            )
            .value,
        isFalse,
      );
      expect(
        find.text('That setting could not be saved, so it was put back.'),
        findsOneWidget,
      );
    });

    testWidgets('has the section where the bridge exists', (tester) async {
      await pumpScreen(tester, withBridge: true);
      expect(find.byType(AiBridgeSettingsSection), findsOneWidget);
    });

    testWidgets('has nothing about it where it does not', (tester) async {
      await pumpScreen(tester, withBridge: false);
      expect(find.byType(AiBridgeSettingsSection), findsNothing);
      expect(find.text('AI Bridge'), findsNothing);
      expect(find.text('Connect an assistant'), findsNothing);
    });
  });

  group('timed approvals and approvals in force', () {
    ChoiceChip chip(WidgetTester tester, int minutes) => tester.widget(
      find.byKey(ValueKey('bridge-timed-$minutes')),
    );

    testWidgets('Allow for a while is off, and says what it adds', (
      tester,
    ) async {
      await pumpSection(tester, hostStore: hostStore);
      expect(find.text('Allow for a while'), findsOneWidget);
      expect(
        find.text('Only adds a button to approval cards. Off: cards offer '
            'Allow once only.'),
        findsOneWidget,
      );
      expect(chip(tester, 0).selected, isTrue);
      expect(chip(tester, 15).selected, isFalse);
      expect(find.text('5 minutes'), findsOneWidget);
      expect(find.text('60 minutes'), findsOneWidget);
    });

    for (final minutes in [5, 15, 60, 0]) {
      testWidgets('choosing $minutes writes the setting', (tester) async {
        final current = await pumpSection(
          tester,
          settings: AppSettings(
            bridgeTimedApprovalMinutes: minutes == 0 ? 15 : 0,
          ),
        );
        await tester.tap(find.byKey(ValueKey('bridge-timed-$minutes')));
        await tester.pump();
        expect(current.value.bridgeTimedApprovalMinutes, minutes);
        expect(chip(tester, minutes).selected, isTrue);
      });
    }

    testWidgets('a failed save says so and the choice stays', (tester) async {
      final current = await pumpSection(tester, failSave: true);
      await tester.tap(find.byKey(const ValueKey('bridge-timed-15')));
      await tester.pump();
      expect(current.value.bridgeTimedApprovalMinutes, 0);
      expect(chip(tester, 0).selected, isTrue);
      expect(find.byType(SnackBar), findsOneWidget);
    });

    testWidgets('no list while there are no approvals', (tester) async {
      await pumpSection(tester);
      expect(find.byKey(const ValueKey('bridge-grants')), findsNothing);
      expect(find.text('Approvals in force'), findsNothing);
    });

    testWidgets('lists approvals, updates, and Stop now revokes', (
      tester,
    ) async {
      var skew = Duration.zero;
      await pumpSection(tester, clock: () => DateTime.now().add(skew));
      bridge.grants.grant(
        'c1',
        'h1',
        const Duration(minutes: 10),
        clientName: 'Desk assistant',
        hostName: 'web-1',
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Approvals in force'), findsOneWidget);
      expect(find.text('Desk assistant on web-1'), findsOneWidget);
      expect(find.text('10 minutes left'), findsOneWidget);

      skew = const Duration(minutes: 4);
      await tester.pump(const Duration(seconds: 30));
      expect(find.text('6 minutes left'), findsOneWidget);

      skew = const Duration(minutes: 9, seconds: 30);
      await tester.pump(const Duration(seconds: 30));
      expect(find.text('Less than a minute left'), findsOneWidget);

      await tester.tap(find.text('Stop now'));
      await tester.pump();
      await tester.pump();
      expect(bridge.grants.current, isEmpty);
      expect(find.byKey(const ValueKey('bridge-grants')), findsNothing);
    });

    testWidgets('an approval that ends by itself leaves the list', (
      tester,
    ) async {
      await pumpSection(tester);
      bridge.grants.grant(
        'c1',
        'h1',
        const Duration(minutes: 10),
        clientName: 'A',
        hostName: 'B',
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('A on B'), findsOneWidget);
      bridge.grants.revokeHost('h1');
      await tester.pump();
      await tester.pump();
      expect(find.text('A on B'), findsNothing);
    });

    testWidgets('names with control characters are shown visibly', (
      tester,
    ) async {
      await pumpSection(tester);
      bridge.grants.grant(
        'c1',
        'h1',
        const Duration(minutes: 10),
        clientName: 'Evil\u202E',
        hostName: 'web\n1',
      );
      await tester.pump();
      await tester.pump();
      expect(find.text(r'Evil[U+202E] on web\n1'), findsOneWidget);
      bridge.grants.revokeAll();
    });

    testWidgets('fit a narrow window at large text, and a wide one', (
      tester,
    ) async {
      for (final (size, scale) in [
        (const Size(320, 568), 1.5),
        (const Size(1920, 1080), 1.0),
      ]) {
        await pumpSection(tester, size: size, textScale: scale);
        bridge.grants.grant(
          'c1',
          'h1',
          const Duration(minutes: 10),
          clientName: 'A very long assistant name ${'x' * 40}',
          hostName: 'a-very-long-host-name-${'y' * 40}',
        );
        await tester.pump();
        await tester.pump();
        expect(tester.takeException(), isNull);
        bridge.grants.revokeAll();
        await tester.pump();
      }
    });

    testWidgets('the consent text says what can now be allowed per host', (
      tester,
    ) async {
      await pumpSection(tester);
      await tester.tap(find.byType(Switch).first);
      await settle(tester);
      expect(find.textContaining('host by host'), findsOneWidget);
      expect(find.textContaining('allowed list'), findsOneWidget);
      expect(find.textContaining('live shell'), findsOneWidget);
      expect(find.textContaining('off until you switch it on'), findsOneWidget);
    });
  });

  group('pairing', () {
    const missing = BridgeLauncherCommand(
      command: '/opt/app/secureshellgo-mcp',
      exists: false,
    );
    const packaged = BridgeLauncherCommand(
      command: 'secureshellgo-mcp',
      exists: true,
    );

    Future<void> pumpConnect(
      WidgetTester tester, {
      BridgeLauncherCommand launcher = packaged,
      Size size = const Size(800, 2400),
      double textScale = 1,
    }) async {
      mockClipboard(tester);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      );
      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) =>
                BridgeConnectScreen(clients: clients, launcher: launcher),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<String> create(WidgetTester tester, {String name = 'Desk'}) async {
      // In a short window the field may have scrolled out of the list.
      await tester.scrollUntilVisible(
        find.byType(TextField),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(find.byType(TextField), name);
      await tester.scrollUntilVisible(
        find.text('Create pairing token'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.runAsync(
        () => tester.tap(find.text('Create pairing token')),
      );
      await settle(tester);
      await tester.pumpAndSettle();
      return tester
          .widget<SelectableText>(find.byType(SelectableText).first)
          .data!;
    }

    testWidgets('offers the four ways, the plugin first', (tester) async {
      await pumpConnect(tester);
      expect(find.text('Claude Code plugin'), findsOneWidget);
      expect(find.text('Config file (mcp.json)'), findsOneWidget);
      expect(find.text('VS Code'), findsOneWidget);
      expect(find.text('Other'), findsOneWidget);
      final plugin = tester.getTopLeft(find.text('Claude Code plugin')).dy;
      final config = tester.getTopLeft(find.text('Config file (mcp.json)')).dy;
      expect(plugin, lessThan(config));
    });

    testWidgets('shows the token once, with the plugin steps', (tester) async {
      await pumpConnect(tester, launcher: missing);
      final token = await create(tester);

      expect(find.text('This token is shown only once'), findsOneWidget);
      expect(token.length, greaterThanOrEqualTo(43));
      // One block of real shell commands, with the token and launcher in it.
      final block = tester
          .widgetList<SelectableText>(find.byType(SelectableText))
          .map((w) => w.data!)
          .singleWhere((t) => t.startsWith('claude plugin marketplace add'));
      final lines = block.split('\n');
      expect(lines, hasLength(3));
      expect(lines[1], 'claude plugin install secureshellgo@dhiva-labs');
      expect(lines[2], contains(token));
      expect(lines[2], contains('"launcher":"/opt/app/secureshellgo-mcp"'));
      expect(lines[2], endsWith('--values-stdin'));
      // The in-session form is worded as such, and is not a copy block.
      expect(find.textContaining('inside a Claude Code session'), findsOneWidget);
      expect(find.textContaining('/plugin configure'), findsOneWidget);
      expect(find.textContaining('launcher was not found'), findsOneWidget);

      // Stored as a hash only: neither the list nor the file has the token.
      final stored = (await tester.runAsync(clients.load))!;
      expect(stored, hasLength(1));
      expect(stored.single.name, 'Desk');
      expect(stored.single.tokenHash, BridgeClientStore.hashToken(token));
      final raw = await tester.runAsync(
        () => File('${dir.path}/clients.json').readAsString(),
      );
      expect(raw, isNot(contains(token)));

      // Leaving the screen is the end of it: nothing shows the token again.
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.text(token), findsNothing);
      expect(find.byType(BridgeConnectScreen), findsNothing);
    });

    testWidgets('the packaged launcher is not shown for the plugin', (
      tester,
    ) async {
      await pumpConnect(tester);
      await create(tester);
      expect(find.textContaining('launcher command'), findsNothing);
      expect(find.textContaining('launcher was not found'), findsNothing);
      expect(find.textContaining('"launcher"'), findsNothing);
    });

    testWidgets('an empty name is paired under a default one', (tester) async {
      await pumpConnect(tester);
      await create(tester, name: '  ');
      final stored = (await tester.runAsync(clients.load))!;
      expect(stored.single.name, 'Assistant');
    });

    testWidgets('leaving with the token on screen asks first', (tester) async {
      await pumpConnect(tester);
      // Nothing to lose yet: back leaves at once.
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(BridgeConnectScreen), findsNothing);

      await pumpConnect(tester);
      final token = await create(tester);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Leave without the token?'), findsOneWidget);
      expect(find.textContaining('will not be shown again'), findsOneWidget);

      await tester.tap(find.text('Stay'));
      await tester.pumpAndSettle();
      expect(find.byType(BridgeConnectScreen), findsOneWidget);
      expect(find.text(token), findsWidgets);

      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Leave'));
      await tester.pumpAndSettle();
      expect(find.byType(BridgeConnectScreen), findsNothing);
    });

    testWidgets('the config file snippet carries launcher and token', (
      tester,
    ) async {
      await pumpConnect(tester, launcher: missing);
      await tester.tap(find.text('Config file (mcp.json)'));
      await tester.pumpAndSettle();
      final token = await create(tester);
      final snippet = find.text(
        '{"mcpServers":{"secureshellgo":{"command":"/opt/app/secureshellgo-mcp",'
        '"env":{"SSG_BRIDGE_TOKEN":"$token"}}}}',
      );
      expect(snippet, findsOneWidget);
    });

    testWidgets('the VS Code snippet is the servers shape with stdio', (
      tester,
    ) async {
      await pumpConnect(tester);
      await tester.tap(find.text('VS Code'));
      await tester.pumpAndSettle();
      final token = await create(tester);
      expect(
        find.text(
          '{"servers":{"secureshellgo":{"type":"stdio",'
          '"command":"secureshellgo-mcp",'
          '"env":{"SSG_BRIDGE_TOKEN":"$token"}}}}',
        ),
        findsOneWidget,
      );
    });

    testWidgets('Other gives the command and the variable name', (
      tester,
    ) async {
      await pumpConnect(tester);
      await tester.tap(find.text('Other'));
      await tester.pumpAndSettle();
      await create(tester);
      expect(find.text('secureshellgo-mcp'), findsOneWidget);
      expect(find.text('SSG_BRIDGE_TOKEN'), findsOneWidget);
    });

    testWidgets('the copy buttons copy their own snippet', (tester) async {
      await pumpConnect(tester);
      final token = await create(tester);
      await tester.tap(find.byTooltip('Copy').first);
      await tester.pump();
      expect(clipboard, token);
      expect(find.text('Copied'), findsOneWidget);
    });

    testWidgets('fits a narrow window at large text', (tester) async {
      await pumpConnect(
        tester,
        launcher: const BridgeLauncherCommand(
          command:
              r'C:\Users\someone\Downloads\secureshellgo\secureshellgo-mcp.exe',
          exists: false,
        ),
        size: const Size(320, 568),
        textScale: 1.5,
      );
      expect(tester.takeException(), isNull);
      for (final kind in [
        'Config file (mcp.json)',
        'VS Code',
        'Other',
        'Claude Code plugin',
      ]) {
        await tester.ensureVisible(find.text(kind));
        await tester.pumpAndSettle();
        await tester.tap(find.text(kind));
        await tester.pumpAndSettle();
      }
      await create(tester);
      expect(tester.takeException(), isNull);
      // Every way of connecting, once the token is there.
      for (final kind in ['Config file (mcp.json)', 'VS Code', 'Other']) {
        await pumpConnect(
          tester,
          launcher: const BridgeLauncherCommand(
            command:
                r'C:\Users\someone\Downloads\secureshellgo\secureshellgo-mcp.exe',
            exists: false,
          ),
          size: const Size(320, 568),
          textScale: 1.5,
        );
        await tester.ensureVisible(find.text(kind));
        await tester.pumpAndSettle();
        await tester.tap(find.text(kind));
        await tester.pumpAndSettle();
        await create(tester);
        expect(tester.takeException(), isNull, reason: kind);
      }
    });

    testWidgets('fits a wide desktop window', (tester) async {
      await pumpConnect(tester, size: const Size(1920, 1080));
      await create(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a Windows path with spaces makes valid JSON', (tester) async {
      const exe = r'C:\Program Files\SecureShell Go\secureshellgo-mcp.exe';
      for (final kind in ['Config file (mcp.json)', 'VS Code']) {
        await pumpConnect(
          tester,
          launcher: const BridgeLauncherCommand(command: exe, exists: true),
        );
        await tester.tap(find.text(kind));
        await tester.pumpAndSettle();
        final token = await create(tester);
        final snippet = tester
            .widgetList<SelectableText>(find.byType(SelectableText))
            .map((t) => t.data!)
            .singleWhere((t) => t.startsWith('{'));
        final decoded = jsonDecode(snippet) as Map<String, Object?>;
        final server =
            ((decoded['mcpServers'] ?? decoded['servers'])!
                    as Map)['secureshellgo']
                as Map;
        expect(server['command'], exe, reason: kind);
        expect((server['env']! as Map)['SSG_BRIDGE_TOKEN'], token);
      }
    });
  });

  group('the activity screen', () {
    Future<void> pumpAudit(
      WidgetTester tester, {
      Size size = const Size(800, 1200),
      double textScale = 1,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: BridgeAuditScreen(audit: audit),
        ),
      );
      await settle(tester);
    }

    testWidgets('says so when there is nothing', (tester) async {
      await pumpAudit(tester);
      expect(find.textContaining('Nothing yet'), findsOneWidget);
    });

    testWidgets('lists entries newest first, with the outcome and detail', (
      tester,
    ) async {
      final record = recorder(tester);
      await record(BridgeAuditOutcome.ok, host: 'web', tool: 'list_dir');
      await record(
        BridgeAuditOutcome.refused,
        host: 'web',
        tool: 'read_file',
        detail: 'blocked_path',
      );
      await record(
        BridgeAuditOutcome.error,
        tool: 'list_hosts',
        detail: 'it broke',
      );
      await pumpAudit(tester);

      final titles = [
        for (final t in tester.widgetList<ListTile>(find.byType(ListTile)))
          (t.title! as Text).data,
      ];
      expect(titles, ['list_hosts', 'read_file · web', 'list_dir · web']);
      expect(find.text('OK'), findsOneWidget);
      expect(find.text('Refused'), findsOneWidget);
      expect(find.text('Error'), findsOneWidget);
      expect(find.text('blocked_path'), findsOneWidget);
      expect(find.text('it broke'), findsOneWidget);
      expect(find.textContaining('Desk assistant'), findsNWidgets(3));
    });

    testWidgets('shows how each change was allowed', (tester) async {
      for (final approval in BridgeAuditApproval.values) {
        await tester.runAsync(
          () => audit.record(
            client: 'Desk assistant',
            host: 'web',
            tool: 'run_command',
            args: {'n': approval.index},
            outcome: BridgeAuditOutcome.ok,
            ms: 1,
            approval: approval,
          ),
        );
      }
      await pumpAudit(tester, size: const Size(800, 3000));
      for (final label in [
        'Allowed: command on the allowed list',
        'Allowed: timed approval in force',
        'Approved once',
        'Approved for a while',
        'Denied',
        'Timed out: not answered, so denied',
        'Withdrawn while waiting for an answer',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.byKey(const ValueKey('audit-approval')), findsNWidgets(7));
    });

    testWidgets('an approved change that never ran is not read as having run',
        (tester) async {
      await tester.runAsync(
        () => audit.record(
          client: 'Desk assistant',
          host: 'web',
          tool: 'run_command',
          args: const {},
          outcome: BridgeAuditOutcome.refused,
          detail: '${BridgeTools.refusedAfterApprovalPrefix}host_not_available',
          ms: 1,
          approval: BridgeAuditApproval.once,
        ),
      );
      await pumpAudit(tester);
      expect(find.text('Approved once'), findsOneWidget);
      expect(
        find.text('Approved, but not run: host_not_available'),
        findsOneWidget,
      );
      expect(find.textContaining('refused_after_approval'), findsNothing);
    });

    testWidgets('shows new activity while it is open', (tester) async {
      await pumpAudit(tester);
      expect(find.textContaining('Nothing yet'), findsOneWidget);
      await recorder(tester)(BridgeAuditOutcome.ok, tool: 'server_stats');
      await settle(tester);
      expect(find.textContaining('Nothing yet'), findsNothing);
      expect(find.text('server_stats'), findsOneWidget);
    });

    testWidgets('Clear asks first, then empties the log', (tester) async {
      await recorder(tester)(BridgeAuditOutcome.ok, tool: 'list_hosts');
      await pumpAudit(tester);
      expect(find.text('list_hosts'), findsOneWidget);

      await tester.tap(find.byTooltip('Clear'));
      await tester.pumpAndSettle();
      expect(find.text('Clear the activity log?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('list_hosts'), findsOneWidget);

      await tester.tap(find.byTooltip('Clear'));
      await tester.pumpAndSettle();
      await tester.runAsync(() => tester.tap(find.text('Clear').last));
      await settle(tester);
      await tester.pumpAndSettle();
      expect(find.text('list_hosts'), findsNothing);
      expect(find.textContaining('Nothing yet'), findsOneWidget);
      expect(await tester.runAsync(() => audit.recent()), isEmpty);
    });

    testWidgets('says so when Clear fails', (tester) async {
      final failing = _FailingClear(io, dir);
      addTearDown(failing.dispose);
      await tester.runAsync(
        () => failing.record(
          client: 'a',
          host: null,
          tool: 'list_hosts',
          args: const {},
          outcome: BridgeAuditOutcome.ok,
          ms: 1,
        ),
      );
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(home: BridgeAuditScreen(audit: failing)),
      );
      await settle(tester);
      await tester.tap(find.byTooltip('Clear'));
      await tester.pumpAndSettle();
      await tester.runAsync(() => tester.tap(find.text('Clear').last));
      await settle(tester);
      await tester.pumpAndSettle();
      expect(find.text('list_hosts'), findsOneWidget);
      expect(
        find.text('The activity log could not be cleared.'),
        findsOneWidget,
      );
    });

    testWidgets('warns while the log cannot be written', (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(home: BridgeAuditScreen(audit: brokenAudit)),
      );
      await settle(tester);
      expect(find.textContaining('could not be saved'), findsNothing);
      await tester.runAsync(
        () => brokenAudit.record(
          client: 'a',
          host: null,
          tool: 'list_hosts',
          args: const {},
          outcome: BridgeAuditOutcome.ok,
          ms: 1,
        ),
      );
      await tester.pump();
      expect(find.textContaining('could not be saved'), findsOneWidget);
      expect(find.text('list_hosts'), findsOneWidget);
    });

    testWidgets('fits a narrow window at large text', (tester) async {
      final record = recorder(tester);
      await record(
        BridgeAuditOutcome.refused,
        host: 'a-host-with-a-long-name#ab12',
        tool: 'search_files',
        detail: 'a long explanation of why this call was refused here',
      );
      await tester.runAsync(
        () => audit.record(
          client: 'An assistant with a very long name indeed, really very long',
          host: 'another-host-with-an-even-longer-name-than-that#cd34',
          tool: 'read_file',
          args: const {},
          outcome: BridgeAuditOutcome.error,
          detail: 'x' * 400,
          ms: 1,
        ),
      );
      await pumpAudit(tester, size: const Size(320, 568), textScale: 1.5);
      expect(tester.takeException(), isNull);
      await pumpAudit(tester, size: const Size(1920, 1080));
      expect(tester.takeException(), isNull);
    });
  });

  test('the stored file never holds what the log is shown without', () async {
    // The activity screen reads entries as they are; the log itself keeps
    // no output, so there is nothing here to leak. This pins the shape.
    await audit.record(
      client: 'c',
      host: null,
      tool: 't',
      args: const {'a': 1},
      outcome: BridgeAuditOutcome.ok,
      ms: 1,
    );
    final line = File('${dir.path}/bridge/audit.log').readAsLinesSync().single;
    expect((jsonDecode(line) as Map).keys, isNot(contains('output')));
  });
}

typedef BridgeAuditEntryRecorder =
    Future<bool?> Function(
      BridgeAuditOutcome outcome, {
      String? host,
      String tool,
      String detail,
    });
