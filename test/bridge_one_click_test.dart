import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/app_settings.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/models/host_ai_access.dart';
import 'package:secure_shell_go/screens/bridge_connect_screen.dart';
import 'package:secure_shell_go/screens/bridge_one_click_screen.dart';
import 'package:secure_shell_go/screens/bridge_shared_hosts_screen.dart';
import 'package:secure_shell_go/screens/settings/ai_bridge_section.dart';
import 'package:secure_shell_go/services/bridge/bridge_audit.dart';
import 'package:secure_shell_go/services/bridge/bridge_cli_connector.dart';
import 'package:secure_shell_go/services/bridge/bridge_client_store.dart';
import 'package:secure_shell_go/services/bridge/bridge_connections.dart';
import 'package:secure_shell_go/services/bridge/bridge_launcher_locator.dart';
import 'package:secure_shell_go/services/bridge/bridge_redactor.dart';
import 'package:secure_shell_go/services/bridge/bridge_service.dart';
import 'package:secure_shell_go/services/bridge/bridge_tools.dart';
import 'package:secure_shell_go/services/host_store.dart';
import 'package:secure_shell_go/services/settings_store.dart';

import 'support/settle.dart';
import 'support/temp_dir.dart';
import 'support/tracked_stores.dart';

const _claudePath = '/home/user/.local/bin/claude';
const _claudeVersion = '2.1.322 (Claude Code)';

BridgeConnections _connections() => BridgeConnections(
  openTransport: (_) => null,
  credentialLookup: (_) async => null,
  dialer: (host, _) async => throw StateError('no dialling'),
);

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

  @override
  BridgeStatus get status => BridgeStatus.off;

  @override
  Stream<BridgeStatus> get statusChanges => const Stream.empty();

  @override
  List<BridgeClient> get connectedClients => const [];

  @override
  Stream<List<BridgeClient>> get connectedClientsChanges =>
      const Stream.empty();
}

/// Stands in for the `claude` command: says what it is told, records what it
/// is asked, and can be held until the test lets it go.
class _FakeConnector extends ClaudeCliConnector {
  _FakeConnector(this.availability);

  /// What `find` says (file checks only).
  ClaudeCliPresence presence = const ClaudeCliPresent([_claudePath]);
  int findCalls = 0;

  ClaudeCliAvailability availability;
  int detectCalls = 0;

  /// While set, `detect` waits for it.
  Completer<void>? holdDetect;

  /// How many calls are waiting on [holdDetect] or [hold] right now: the
  /// test holds them on purpose, so a screen waiting on one is at rest.
  int waiting = 0;

  Future<void> _wait(Future<void> gate) async {
    waiting++;
    try {
      await gate;
    } finally {
      waiting--;
    }
  }
  final List<ClaudePluginSource?> expectedSources = [];
  final List<({String path, String token, String launcher})> connectCalls = [];

  /// What `connect` returns; null means success.
  ClaudeConnectStep? failAt;
  String failMessage = 'it went wrong';

  /// While set, `connect` waits for it, so the test can look at the screen
  /// mid-run.
  Completer<void>? hold;

  /// With [hold], wait just after this step was reported instead of before
  /// the first one.
  ClaudeConnectStep? holdAt;

  /// The marketplace is already there, so the add step is skipped.
  bool skipAdd = false;

  /// When set, `connect` throws this text with the token appended.
  String? throwWith;

  @override
  ClaudeCliPresence find() {
    findCalls++;
    return presence;
  }

  @override
  Future<ClaudeCliAvailability> detect() async {
    detectCalls++;
    final gate = holdDetect;
    if (gate != null) await _wait(gate.future);
    return availability;
  }

  @override
  Future<ClaudeConnectOutcome> connect({
    required String executablePath,
    required String token,
    required String launcherCommand,
    ClaudePluginSource? expectedSource,
    void Function(ClaudeConnectStep step)? onStep,
  }) async {
    connectCalls.add((
      path: executablePath,
      token: token,
      launcher: launcherCommand,
    ));
    expectedSources.add(expectedSource);
    final thrown = throwWith;
    if (thrown != null) throw StateError('$thrown $token');
    final gate = hold;
    if (gate != null && holdAt == null) await _wait(gate.future);
    final at = failAt;
    final run = [
      for (final s in ClaudeConnectStep.values)
        if (!(skipAdd && s == ClaudeConnectStep.marketplaceAdd))
          if (at == null || s.index <= at.index) s,
    ];
    for (final s in run) {
      onStep?.call(s);
      if (gate != null && s == holdAt) await _wait(gate.future);
    }
    ClaudeConnectStepResult ran(ClaudeConnectStep step, int code, String out) =>
        ClaudeConnectStepResult(
          step: step,
          command: [executablePath, ...step.arguments],
          exitCode: code,
          timedOut: false,
          output: out,
        );
    if (at == null) {
      return ClaudeConnected([for (final s in run) ran(s, 0, '')]);
    }
    return ClaudeConnectFailed(
      step: at,
      message: failMessage,
      steps: [
        for (final s in run) ran(s, s == at ? 1 : 0, 'out of ${s.name}'),
      ],
    );
  }
}

Host _host(
  String id, {
  HostAiAccess access = HostAiAccess.off,
  String? group,
  int port = 22,
}) => Host(
  id: id,
  label: 'Host $id',
  hostname: '$id.test',
  port: port,
  username: 'u',
  authMethod: SshAuthMethod.password,
  group: group,
  startupCommand: 'echo $id',
  aiAccess: access,
);

void main() {
  late Directory dir;
  late BridgeClientStore clients;
  late BridgeAuditLog audit;
  late _FakeBridge bridge;
  late HostStore hostStore;
  late _FakeConnector connector;
  late IoTracker io;
  String? clipboard;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('bridge_one_click_test');
    io = IoTracker();
    clients = TrackedClientStore(io, file: File('${dir.path}/clients.json'));
    audit = BridgeAuditLog(
      scrub: (s) => s,
      directory: Directory('${dir.path}/bridge'),
    );
    bridge = _FakeBridge(dir, clients, audit);
    hostStore = TrackedHostStore(io, file: File('${dir.path}/hosts.json'));
    connector = _FakeConnector(
      const ClaudeCliAvailable(
        executablePath: _claudePath,
        version: _claudeVersion,
        pluginSource: ClaudePluginSourceOfficial(),
      ),
    );
    clipboard = null;
  });

  tearDown(() async {
    await audit.dispose();
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

  /// Waits until the screen's own work is done — no host or pairing store
  /// call still running, and no progress indicator except while the fake
  /// `claude` is deliberately held — then past any route animation, and
  /// once more for work that animation started. A fixed number of event
  /// loop turns was too few on slow CI runners.
  bool busy() =>
      io.busy ||
      (connector.waiting == 0 &&
          find
              .byWidgetPredicate((w) => w is ProgressIndicator)
              .evaluate()
              .isNotEmpty);

  Future<void> settle(WidgetTester tester) async {
    await settleWhile(tester, busy);
    await tester.pump(const Duration(milliseconds: 500));
    await settleWhile(tester, busy);
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> addHosts(WidgetTester tester, List<Host> hosts) async {
    await tester.runAsync(() async {
      for (final h in hosts) {
        await hostStore.add(h);
      }
    });
  }

  Future<void> pair(WidgetTester tester, String name) async {
    await tester.runAsync(() => clients.create(name));
  }

  Future<List<BridgeClient>> pairedNow(WidgetTester tester) async {
    late List<BridgeClient> list;
    await tester.runAsync(() async => list = await clients.load());
    return list;
  }

  /// The AI Bridge section on a screen of its own, with the settings kept as
  /// the section changes them. [failSave] makes every save throw, as the
  /// settings screen does after putting the switch back.
  Future<ValueNotifier<AppSettings>> pumpSection(
    WidgetTester tester, {
    AppSettings settings = const AppSettings(),
    Size size = const Size(800, 3000),
    double textScale = 1,
    bool failSave = false,
    bool failSwitchOff = false,
    bool withConnector = true,
    ClaudeCliConnector? useConnector,
    List<bool>? saves,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final current = ValueNotifier(settings);
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
                  final next = change(current.value);
                  if (failSwitchOff && !next.bridgeEnabled) {
                    throw const FileSystemException('disk full');
                  }
                  current.value = next;
                  saves?.add(current.value.bridgeEnabled);
                },
                bridge: bridge,
                clients: clients,
                audit: audit,
                hostStore: hostStore,
                connector: withConnector ? (useConnector ?? connector) : null,
              ),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
    return current;
  }

  Future<void> openFlow(WidgetTester tester) async {
    await tester.ensureVisible(find.text('Connect Claude Code'));
    await tester.pump();
    await tester.tap(find.text('Connect Claude Code'));
    await settle(tester);
  }

  Future<void> confirmFlow(WidgetTester tester) async {
    await tester.scrollUntilVisible(
      find.widgetWithText(FilledButton, 'Connect'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
    await settle(tester);
  }

  /// Every string drawn anywhere in the tree.
  String allText(WidgetTester tester) {
    final out = StringBuffer();
    for (final w in tester.allWidgets) {
      if (w is Text) out.writeln(w.data ?? w.textSpan?.toPlainText());
      if (w is EditableText) out.writeln(w.controller.text);
    }
    return out.toString();
  }

  group('the one-click button', () {
    testWidgets('is offered when claude was found, and runs nothing', (
      tester,
    ) async {
      await pumpSection(tester);
      expect(find.text('Connect Claude Code'), findsOneWidget);
      expect(connector.findCalls, 1);
      await tester.tap(find.byTooltip('Check again for Claude Code'));
      await settle(tester);
      expect(connector.findCalls, 2);
      // The program is run only once the button is pressed.
      expect(connector.detectCalls, 0);
    });

    testWidgets('opening Settings and "Check again" start no process', (
      tester,
    ) async {
      final started = <List<String>>[];
      final real = ClaudeCliConnector(
        runner:
            (
              executable,
              arguments, {
              stdin,
              timeout = const Duration(seconds: 90),
              environment,
              runInShell = false,
            }) async {
              started.add([executable, ...arguments]);
              return const BridgeProcessResult(exitCode: 1);
            },
        environment: const {'PATH': '/usr/bin', 'HOME': '/home/user'},
        isWindows: false,
        resolvedExecutable: '/opt/secureshellgo/secureshellgo',
        fileExists: (path) => path == _claudePath,
      );
      await pumpSection(tester, useConnector: real);
      expect(find.text('Connect Claude Code'), findsOneWidget);
      await tester.tap(find.byTooltip('Check again for Claude Code'));
      await settle(tester);
      await tester.tap(find.byTooltip('Check again for Claude Code'));
      await settle(tester);
      expect(find.text('Connect Claude Code'), findsOneWidget);
      expect(started, isEmpty);

      // Pressing the button is what runs it (and here it does not answer).
      await openFlow(tester);
      expect(started, [
        [_claudePath, '--version'],
      ]);
      expect(
        find.textContaining('was found but could not be run'),
        findsOneWidget,
      );
      expect(find.text('Turn on the AI Bridge?'), findsNothing);
      expect(await pairedNow(tester), isEmpty);
    });

    testWidgets('is not there when claude is not found', (
      tester,
    ) async {
      connector.presence = const ClaudeCliAbsent();
      await pumpSection(tester);
      expect(find.text('Connect Claude Code'), findsNothing);
      expect(find.textContaining('not available in the snap'), findsNothing);

      // Found after all: "check again" brings the button.
      connector.presence = const ClaudeCliPresent([_claudePath]);
      await tester.tap(find.byTooltip('Check again for Claude Code'));
      await settle(tester);
      expect(find.text('Connect Claude Code'), findsOneWidget);
    });

    testWidgets('in the snap or Flatpak says so and points at the manual way', (
      tester,
    ) async {
      connector.presence = const ClaudeCliPresenceSandboxed();
      await pumpSection(tester);
      expect(find.text('Connect Claude Code'), findsNothing);
      expect(
        find.text(
          'One-click connect is not available in the snap or the Flatpak. '
          'Use "Connect an assistant" instead.',
        ),
        findsOneWidget,
      );
      expect(find.text('Connect an assistant'), findsOneWidget);
    });

    testWidgets('is absent without a connector', (tester) async {
      await pumpSection(tester, withConnector: false);
      expect(find.text('Connect Claude Code'), findsNothing);
      expect(find.byTooltip('Check again for Claude Code'), findsNothing);
    });
  });

  group('the confirmation', () {
    testWidgets('shows the consent points and the program, verbatim', (
      tester,
    ) async {
      await pumpSection(tester);
      await openFlow(tester);
      expect(find.text('Connect Claude Code'), findsOneWidget); // app bar
      expect(find.text('Turn on the AI Bridge?'), findsOneWidget);
      expect(
        find.textContaining('never gets your passwords or keys'),
        findsOneWidget,
      );
      expect(
        find.textContaining('sent by that assistant to its provider'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Nothing can be changed on a server'),
        findsOneWidget,
      );
      expect(
        find.text('The AI Bridge is off and will be turned on.'),
        findsOneWidget,
      );
      expect(
        find.text('SecureShell Go will run this program to set up the plugin:'),
        findsOneWidget,
      );
      expect(find.text(_claudePath), findsOneWidget);
      expect(find.text('Version: $_claudeVersion'), findsOneWidget);
    });

    testWidgets('says nothing extra about an official plugin source', (
      tester,
    ) async {
      await pumpSection(tester);
      await openFlow(tester);
      expect(find.textContaining('will be loaded from'), findsNothing);
      expect(find.textContaining('could not check where'), findsNothing);
    });

    testWidgets('names another plugin source, with a warning', (tester) async {
      connector.availability = const ClaudeCliAvailable(
        executablePath: _claudePath,
        version: _claudeVersion,
        pluginSource: ClaudePluginSourceOther('Folder: /home/u/dev/fork'),
      );
      await pumpSection(tester);
      await openFlow(tester);
      expect(
        find.text('The plugin will be loaded from: Folder: /home/u/dev/fork'),
        findsOneWidget,
      );
      expect(
        find.textContaining('not the published SecureShell Go plugin'),
        findsOneWidget,
      );
    });

    testWidgets('says when the plugin source could not be checked', (
      tester,
    ) async {
      connector.availability = const ClaudeCliAvailable(
        executablePath: _claudePath,
        version: _claudeVersion,
      );
      await pumpSection(tester);
      await openFlow(tester);
      expect(
        find.text(
          'SecureShell Go could not check where the plugin will come from.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('passes the source it showed on to connect', (tester) async {
      const shown = ClaudePluginSourceOther('Folder: /home/u/dev/fork');
      connector.availability = const ClaudeCliAvailable(
        executablePath: _claudePath,
        version: _claudeVersion,
        pluginSource: shown,
      );
      await pumpSection(tester);
      await openFlow(tester);
      await confirmFlow(tester);
      expect(connector.expectedSources, [shown]);
    });

    testWidgets('Cancel changes nothing', (tester) async {
      final saves = <bool>[];
      final settings = await pumpSection(tester, saves: saves);
      await openFlow(tester);
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(find.byType(BridgeOneClickScreen), findsNothing);
      expect(settings.value.bridgeEnabled, isFalse);
      expect(saves, isEmpty);
      expect(await pairedNow(tester), isEmpty);
      expect(connector.connectCalls, isEmpty);
    });
  });

  group('connecting', () {
    testWidgets('switches the bridge on, pairs once, connects, then shares', (
      tester,
    ) async {
      mockClipboard(tester);
      await addHosts(tester, [
        _host('a', access: HostAiAccess.readOnly),
        _host('b'),
      ]);
      final saves = <bool>[];
      final settings = await pumpSection(tester, saves: saves);
      await openFlow(tester);
      await confirmFlow(tester);

      expect(settings.value.bridgeEnabled, isTrue);
      expect(saves, [true]);
      final paired = await pairedNow(tester);
      expect(paired, hasLength(1));
      expect(paired.single.name, 'Claude Code');
      // Confirmed once Claude Code reported it set: usable, and kept (a
      // confirmed pairing signs in: see bridge_client_store_test.dart).
      expect(paired.single.pending, isFalse);
      final call = connector.connectCalls.single;
      expect(call.path, _claudePath);
      expect(call.launcher, locateBridgeLauncher().command);
      expect(BridgeClientStore.hashToken(call.token), paired.single.tokenHash);

      // Straight on to the checklist.
      await settle(tester);
      expect(find.byType(SharedHostsChecklist), findsOneWidget);
      expect(find.text('Shared hosts'), findsOneWidget);
      expect(allText(tester), isNot(contains(call.token)));
      expect(clipboard, isNull);
    });

    testWidgets('an existing "Claude Code" gets a number', (tester) async {
      await pair(tester, 'Claude Code');
      await pumpSection(tester);
      await openFlow(tester);
      await confirmFlow(tester);
      final names = [for (final c in await pairedNow(tester)) c.name];
      expect(names, ['Claude Code', 'Claude Code 2']);
    });

    testWidgets('leaves a bridge that was already on alone', (tester) async {
      final saves = <bool>[];
      await pumpSection(
        tester,
        settings: const AppSettings(bridgeEnabled: true),
        saves: saves,
      );
      await openFlow(tester);
      expect(find.textContaining('will be turned on'), findsNothing);
      await confirmFlow(tester);
      expect(saves, isEmpty);
      expect(connector.connectCalls, hasLength(1));
    });

    testWidgets('the token is never on screen or in the clipboard', (
      tester,
    ) async {
      mockClipboard(tester);
      connector.hold = Completer<void>();
      await addHosts(tester, [_host('a')]);
      await pumpSection(tester);
      await openFlow(tester);
      await confirmFlow(tester);

      // Mid-run.
      final token = connector.connectCalls.single.token;
      expect(find.text('Setting up Claude Code…'), findsOneWidget);
      expect(allText(tester), isNot(contains(token)));
      expect(find.textContaining(token), findsNothing);

      connector.hold!.complete();
      await settle(tester);
      expect(find.byType(SharedHostsChecklist), findsOneWidget);
      expect(allText(tester), isNot(contains(token)));
      expect(find.textContaining(token), findsNothing);

      await tester.tap(find.text('Skip for now'));
      await settle(tester);
      expect(
        find.text('Start a new Claude Code session to use it.'),
        findsOneWidget,
      );
      expect(allText(tester), isNot(contains(token)));
      expect(clipboard, isNull);
    });

    testWidgets('leaving is blocked while it runs', (tester) async {
      connector.hold = Completer<void>();
      await pumpSection(tester);
      await openFlow(tester);
      await confirmFlow(tester);
      expect(find.byType(BackButton), findsNothing);

      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      await navigator.maybePop();
      await settle(tester);
      expect(find.byType(BridgeOneClickScreen), findsOneWidget);

      connector.hold!.complete();
      await settle(tester);
      expect(find.byType(SharedHostsChecklist), findsOneWidget);
      await navigator.maybePop();
      await settle(tester);
      expect(find.byType(BridgeOneClickScreen), findsNothing);
    });

    testWidgets('a settings save that fails stops before pairing', (
      tester,
    ) async {
      final settings = await pumpSection(tester, failSave: true);
      await openFlow(tester);
      await confirmFlow(tester);
      expect(settings.value.bridgeEnabled, isFalse);
      expect(await pairedNow(tester), isEmpty);
      expect(connector.connectCalls, isEmpty);
      expect(find.text('Claude Code could not be connected'), findsOneWidget);
      expect(find.textContaining('could not be saved'), findsOneWidget);
    });

    const failures = {
      ClaudeConnectStep.marketplaceList:
          'The setup stopped before anything was sent: the plugin source '
          'changed after you confirmed, or the program could not be run. '
          'Nothing was installed.',
      ClaudeConnectStep.marketplaceAdd:
          'Claude Code could not add the SecureShell Go plugin source.',
      ClaudeConnectStep.install: 'Claude Code could not install the plugin.',
      ClaudeConnectStep.configure:
          'Claude Code could not save the pairing for the plugin.',
      ClaudeConnectStep.verify:
          'Claude Code could not confirm that the pairing was saved.',
    };
    for (final entry in failures.entries) {
      testWidgets('a failure at ${entry.key.name} undoes it all', (
        tester,
      ) async {
        connector.failAt = entry.key;
        connector.failMessage = 'technical words';
        final saves = <bool>[];
        final settings = await pumpSection(tester, saves: saves);
        await openFlow(tester);
        await confirmFlow(tester);
        await settle(tester);

        expect(await pairedNow(tester), isEmpty);
        expect(settings.value.bridgeEnabled, isFalse);
        expect(saves, [true, false]);
        expect(find.text('Claude Code could not be connected'), findsOneWidget);
        expect(find.text(entry.value), findsOneWidget);
        expect(
          find.text(
            'The pairing was removed again, so nothing unusable is '
            'left behind.',
          ),
          findsOneWidget,
        );
        expect(find.text('technical words'), findsNothing);
        await tester.tap(find.text('Technical details'));
        await settle(tester);
        expect(find.text('technical words'), findsOneWidget);
        expect(
          allText(tester),
          isNot(contains(connector.connectCalls.single.token)),
        );
      });
    }

    testWidgets('a failure puts a bridge that was off back off, others or not', (
      tester,
    ) async {
      await pair(tester, 'Desk assistant');
      connector.failAt = ClaudeConnectStep.install;
      final saves = <bool>[];
      final settings = await pumpSection(tester, saves: saves);
      await openFlow(tester);
      await confirmFlow(tester);
      await settle(tester);
      final names = [for (final c in await pairedNow(tester)) c.name];
      expect(names, ['Desk assistant']);
      expect(settings.value.bridgeEnabled, isFalse);
      expect(saves, [true, false]);
    });

    testWidgets('a quit part way leaves no pairing after the next start', (
      tester,
    ) async {
      connector.hold = Completer<void>();
      await pumpSection(tester);
      await openFlow(tester);
      await confirmFlow(tester);
      final token = connector.connectCalls.single.token;
      // Paired, but pending: it cannot sign in while the setup runs.
      final now = await pairedNow(tester);
      expect(now.single.pending, isTrue);
      late BridgeClient? signedIn;
      await tester.runAsync(() async => signedIn = await clients.verify(token));
      expect(signedIn, isNull);

      // The app goes away mid-run; the next start reads the same file.
      await tester.pumpWidget(const SizedBox());
      late List<BridgeClient> afterRestart;
      await tester.runAsync(() async {
        final restarted = BridgeClientStore(file: File('${dir.path}/clients.json'));
        afterRestart = await restarted.load();
      });
      expect(afterRestart, isEmpty);
    });

    testWidgets('a failure leaves a bridge that was already on, on', (
      tester,
    ) async {
      connector.failAt = ClaudeConnectStep.configure;
      final saves = <bool>[];
      final settings = await pumpSection(
        tester,
        settings: const AppSettings(bridgeEnabled: true),
        saves: saves,
      );
      await openFlow(tester);
      await confirmFlow(tester);
      expect(await pairedNow(tester), isEmpty);
      expect(settings.value.bridgeEnabled, isTrue);
      expect(saves, isEmpty);
    });

    testWidgets('a failure offers the manual way', (tester) async {
      connector.failAt = ClaudeConnectStep.install;
      await pumpSection(tester);
      await openFlow(tester);
      await confirmFlow(tester);
      await settle(tester);
      await tester.tap(
        find.widgetWithText(FilledButton, 'Connect an assistant'),
      );
      await settle(tester);
      expect(find.byType(BridgeConnectScreen), findsOneWidget);
      expect(find.byType(BridgeOneClickScreen), findsNothing);
    });

    testWidgets('a second tap on Connect pairs and runs nothing more', (
      tester,
    ) async {
      connector.hold = Completer<void>();
      await pumpSection(tester);
      await openFlow(tester);
      final button = find.widgetWithText(FilledButton, 'Connect');
      await tester.ensureVisible(button);
      await tester.pump();
      // Two taps before the screen has rebuilt.
      await tester.tap(button);
      await tester.tap(button, warnIfMissed: false);
      await settle(tester);
      connector.hold!.complete();
      await settle(tester);
      expect(connector.connectCalls, hasLength(1));
      expect(await pairedNow(tester), hasLength(1));
    });

    testWidgets('a double tap on the button opens one screen', (tester) async {
      connector.holdDetect = Completer<void>();
      await pumpSection(tester);
      final button = find.text('Connect Claude Code');
      await tester.ensureVisible(button);
      await tester.pump();
      await tester.tap(button);
      await tester.tap(button, warnIfMissed: false);
      await settle(tester);
      expect(find.byType(BridgeOneClickScreen), findsOneWidget);
      expect(connector.detectCalls, 1);
      connector.holdDetect!.complete();
      await settle(tester);
    });

    testWidgets('the button works again once the screen was left by back', (
      tester,
    ) async {
      await pumpSection(tester);
      final button = find.text('Connect Claude Code');
      await tester.ensureVisible(button);
      await tester.pump();
      await tester.tap(button);
      await settle(tester);
      expect(find.byType(BridgeOneClickScreen), findsOneWidget);
      // The system back gesture, not the screen's own button.
      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(find.byType(BridgeOneClickScreen), findsNothing);
      await tester.ensureVisible(button);
      await tester.pump();
      await tester.tap(button);
      await settle(tester);
      expect(find.byType(BridgeOneClickScreen), findsOneWidget);
    });

    testWidgets('a revoke that cannot be saved is said, pairing kept', (
      tester,
    ) async {
      await tester.runAsync(() async {
        clients = _NoRevokeStore(File('${dir.path}/clients3.json'));
      });
      await pair(tester, 'Desk assistant');
      await pumpSection(tester);
      await tester.ensureVisible(find.byTooltip('Revoke'));
      await tester.tap(find.byTooltip('Revoke'));
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Revoke'));
      await settle(tester);
      expect(
        find.text('The pairing could not be removed, so it still works. Try again.'),
        findsOneWidget,
      );
      expect(await pairedNow(tester), hasLength(1));
    });

    testWidgets('the manual plugin commands warn about shell history', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: BridgeConnectScreen(
            clients: clients,
            launcher: const BridgeLauncherCommand(
              command: '/opt/secureshellgo/secureshellgo-mcp',
              exists: true,
            ),
          ),
        ),
      );
      await settle(tester);
      await tester.tap(find.text('Create pairing token'));
      await settle(tester);
      expect(
        find.text(
          "Pasting these commands leaves the token in your terminal's "
          'history. Where it is available, "Connect Claude Code" in '
          'Settings avoids this.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('the screen runs claude only when opened, and once', (
      tester,
    ) async {
      connector.holdDetect = Completer<void>();
      await pumpSection(tester);
      expect(connector.detectCalls, 0);
      await openFlow(tester);
      expect(connector.detectCalls, 1);
      expect(find.text('Checking Claude Code…'), findsOneWidget);
      expect(find.text('Turn on the AI Bridge?'), findsNothing);
      connector.holdDetect!.complete();
      await settle(tester);
      expect(find.text('Turn on the AI Bridge?'), findsOneWidget);
      await confirmFlow(tester);
      expect(connector.detectCalls, 1);
    });

    testWidgets('found on disk but not answering: says so, changes nothing', (
      tester,
    ) async {
      connector.availability = const ClaudeCliFailed(
        '$_claudePath: exit 127',
      );
      final saves = <bool>[];
      await pumpSection(tester, saves: saves);
      await openFlow(tester);
      expect(
        find.textContaining('was found but could not be run'),
        findsOneWidget,
      );
      await tester.tap(find.text('Technical details'));
      await settle(tester);
      expect(find.text('$_claudePath: exit 127'), findsOneWidget);
      expect(saves, isEmpty);
      expect(await pairedNow(tester), isEmpty);
      expect(connector.connectCalls, isEmpty);
      await tester.tap(
        find.widgetWithText(FilledButton, 'Connect an assistant'),
      );
      await settle(tester);
      expect(find.byType(BridgeConnectScreen), findsOneWidget);
    });

    testWidgets('progress marks the running step and ticks finished ones', (
      tester,
    ) async {
      connector.hold = Completer<void>();
      connector.holdAt = ClaudeConnectStep.configure;
      connector.skipAdd = true;
      await pumpSection(tester);
      await openFlow(tester);
      await confirmFlow(tester);
      expect(find.byKey(const ValueKey('bridge-step-0-skipped')), findsOne);
      expect(find.text('Already set up, skipped'), findsOneWidget);
      expect(find.byKey(const ValueKey('bridge-step-1-done')), findsOne);
      expect(find.byKey(const ValueKey('bridge-step-2-running')), findsOne);
      expect(find.byKey(const ValueKey('bridge-step-3-pending')), findsOne);
      connector.hold!.complete();
      await settle(tester);
      expect(find.byType(SharedHostsChecklist), findsOneWidget);
    });

    testWidgets('progress before the first step: all pending; add shown', (
      tester,
    ) async {
      connector.hold = Completer<void>();
      connector.holdAt = ClaudeConnectStep.install;
      await pumpSection(tester);
      await openFlow(tester);
      await confirmFlow(tester);
      expect(find.byKey(const ValueKey('bridge-step-0-done')), findsOne);
      expect(find.byKey(const ValueKey('bridge-step-1-running')), findsOne);
      expect(find.text('Already set up, skipped'), findsNothing);
      connector.hold!.complete();
      await settle(tester);
    });

    testWidgets('a failed run shows a skipped add as skipped', (tester) async {
      connector.skipAdd = true;
      connector.failAt = ClaudeConnectStep.install;
      await pumpSection(tester);
      await openFlow(tester);
      await confirmFlow(tester);
      await settle(tester);
      expect(find.byKey(const ValueKey('bridge-step-0-skipped')), findsOne);
      expect(find.byKey(const ValueKey('bridge-step-1-failed')), findsOne);
      expect(find.byKey(const ValueKey('bridge-step-2-notRun')), findsOne);
    });

    testWidgets('connect throwing: undone, said plainly, token scrubbed', (
      tester,
    ) async {
      connector.throwWith = 'boom';
      final saves = <bool>[];
      final settings = await pumpSection(tester, saves: saves);
      await openFlow(tester);
      await confirmFlow(tester);
      await settle(tester);
      final token = connector.connectCalls.single.token;
      expect(await pairedNow(tester), isEmpty);
      expect(settings.value.bridgeEnabled, isFalse);
      expect(saves, [true, false]);
      expect(
        find.text('Something went wrong before the setup finished.'),
        findsOneWidget,
      );
      expect(find.textContaining('pairing was removed'), findsOneWidget);
      await tester.tap(find.text('Technical details'));
      await settle(tester);
      expect(find.text('Bad state: boom [token]'), findsOneWidget);
      expect(allText(tester), isNot(contains(token)));
    });

    testWidgets('a pairing that cannot be removed is said, bridge goes off', (
      tester,
    ) async {
      await tester.runAsync(() async {
        clients = _NoRevokeStore(File('${dir.path}/clients2.json'));
      });
      connector.failAt = ClaudeConnectStep.configure;
      final saves = <bool>[];
      final settings = await pumpSection(tester, saves: saves);
      await openFlow(tester);
      await confirmFlow(tester);
      await settle(tester);
      // Still paired (removing failed), but pending, so it cannot sign in;
      // the bridge this attempt switched on is off again; and the next
      // start removes it.
      final left = await pairedNow(tester);
      expect(left.single.pending, isTrue);
      late List<BridgeClient> afterRestart;
      await tester.runAsync(() async {
        afterRestart = await BridgeClientStore(
          file: File('${dir.path}/clients2.json'),
        ).load();
      });
      expect(afterRestart, isEmpty);
      expect(settings.value.bridgeEnabled, isFalse);
      expect(saves, [true, false]);
      expect(find.textContaining('pairing was removed'), findsNothing);
      expect(
        find.text(
          'The pairing "Claude Code" could not be removed. Remove it under '
          'Paired assistants in Settings.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a confirmation that cannot be saved undoes it all', (
      tester,
    ) async {
      await tester.runAsync(() async {
        clients = _NoConfirmStore(File('${dir.path}/clients4.json'));
      });
      final saves = <bool>[];
      final settings = await pumpSection(tester, saves: saves);
      await openFlow(tester);
      await confirmFlow(tester);
      await settle(tester);
      expect(await pairedNow(tester), isEmpty);
      expect(settings.value.bridgeEnabled, isFalse);
      expect(saves, [true, false]);
      expect(find.text('Claude Code could not be connected'), findsOneWidget);
      expect(find.text('Something went wrong before the setup finished.'),
          findsOneWidget);
      expect(find.textContaining('pairing was removed'), findsOneWidget);
      expect(find.text('Skip for now'), findsNothing);
    });

    testWidgets('a bridge that cannot be switched off again is said', (
      tester,
    ) async {
      connector.failAt = ClaudeConnectStep.install;
      final settings = await pumpSection(tester, failSwitchOff: true);
      await openFlow(tester);
      await confirmFlow(tester);
      await settle(tester);
      expect(await pairedNow(tester), isEmpty);
      expect(settings.value.bridgeEnabled, isTrue);
      expect(
        find.textContaining('could not be switched off again'),
        findsOneWidget,
      );
    });
  });

  group('the shared hosts checklist', () {
    testWidgets('a save that fails part way shows what is stored', (
      tester,
    ) async {
      // Made on the real event loop, as setUp makes the others: its writer
      // would otherwise wait on the test's fake clock.
      await tester.runAsync(() async {
        hostStore = _FailingHostStore(
          io,
          File('${dir.path}/hosts2.json'),
          'c',
        );
      });
      await addHosts(tester, [_host('a'), _host('b'), _host('c')]);
      await pumpSection(tester);
      await tester.ensureVisible(find.text('Shared hosts — 0 of 3'));
      await tester.tap(find.text('Shared hosts — 0 of 3'));
      await settle(tester);
      await tester.tap(find.text('Host a'));
      await tester.tap(find.text('Host c'));
      await tester.pump();
      await tester.tap(find.text('Save'));
      await settle(tester);

      expect(find.byType(BridgeSharedHostsScreen), findsOneWidget);
      expect(
        find.text(
          'Not every change could be saved. The list shows what is saved now.',
        ),
        findsOneWidget,
      );
      late List<Host> saved;
      await tester.runAsync(() async => saved = await hostStore.all());
      final stored = {for (final h in saved) h.id: h.aiAccess};
      bool ticked(String id) => tester
          .widget<CheckboxListTile>(
            find.widgetWithText(CheckboxListTile, 'Host $id'),
          )
          .value!;
      for (final id in ['a', 'b', 'c']) {
        expect(ticked(id), stored[id] == HostAiAccess.readOnly, reason: id);
      }
      expect(stored['a'], HostAiAccess.readOnly);
      expect(stored['b'], HostAiAccess.off);
    });
    testWidgets('starts from what is shared, and Save writes the ticked set', (
      tester,
    ) async {
      await addHosts(tester, [
        _host('a', access: HostAiAccess.readOnly, group: 'Prod', port: 2222),
        _host('b'),
        _host('c', access: HostAiAccess.readOnly),
      ]);
      await pumpSection(tester);
      expect(find.text('Shared hosts — 2 of 3'), findsOneWidget);
      await tester.ensureVisible(find.text('Shared hosts — 2 of 3'));
      await tester.tap(find.text('Shared hosts — 2 of 3'));
      await settle(tester);

      bool ticked(String id) => tester
          .widget<CheckboxListTile>(
            find.widgetWithText(CheckboxListTile, 'Host $id'),
          )
          .value!;
      expect([ticked('a'), ticked('b'), ticked('c')], [true, false, true]);
      expect(find.text('Prod · Read only'), findsOneWidget);

      await tester.tap(find.text('Host b'));
      await tester.tap(find.text('Host c'));
      await tester.pump();
      await tester.tap(find.text('Save'));
      await settle(tester);

      late List<Host> saved;
      await tester.runAsync(() async => saved = await hostStore.all());
      final byId = {for (final h in saved) h.id: h};
      expect(byId['a']!.aiAccess, HostAiAccess.readOnly);
      expect(byId['b']!.aiAccess, HostAiAccess.readOnly);
      expect(byId['c']!.aiAccess, HostAiAccess.off);
      // Everything else about a host is as it was.
      expect(byId['a']!.port, 2222);
      expect(byId['a']!.group, 'Prod');
      expect(byId['a']!.startupCommand, 'echo a');
      expect(byId['c']!.hostname, 'c.test');
      expect(byId['c']!.startupCommand, 'echo c');
      // Back in Settings, with the count refreshed.
      expect(find.byType(BridgeSharedHostsScreen), findsNothing);
      expect(find.text('Shared hosts — 2 of 3'), findsOneWidget);
    });

    testWidgets('says a host must be saved first when there is none', (
      tester,
    ) async {
      await pumpSection(tester);
      await tester.ensureVisible(find.text('Shared hosts — 0 of 0'));
      await tester.tap(find.text('Shared hosts — 0 of 0'));
      await settle(tester);
      expect(find.text('No saved hosts yet'), findsOneWidget);
      expect(
        find.textContaining('A quick connect is not saved'),
        findsOneWidget,
      );
      expect(find.text('Save'), findsNothing);
    });
  });

  group('narrow layout', () {
    const narrow = Size(320, 568);

    Future<void> noOverflow(WidgetTester tester) async {
      await settle(tester);
      expect(tester.takeException(), isNull);
    }

    testWidgets('confirmation, progress, failure and checklist fit', (
      tester,
    ) async {
      connector.hold = Completer<void>();
      connector.failAt = ClaudeConnectStep.verify;
      connector.failMessage = 'A long technical message ' * 12;
      await addHosts(tester, [
        for (var i = 0; i < 8; i++)
          _host('very-long-name-$i', group: 'A fairly long group name'),
      ]);
      await pumpSection(tester, size: narrow, textScale: 1.5);
      await noOverflow(tester);

      await openFlow(tester);
      await noOverflow(tester); // confirmation

      await confirmFlow(tester);
      await noOverflow(tester); // progress

      connector.hold!.complete();
      await settle(tester);
      await noOverflow(tester); // failure
      await tester.scrollUntilVisible(
        find.text('Technical details'),
        200,
        scrollable: find
            .descendant(
              of: find.byType(BridgeOneClickScreen),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.ensureVisible(find.text('Technical details'));
      await tester.pump();
      await tester.tap(find.text('Technical details'));
      await noOverflow(tester);
    });

    testWidgets('checklist and the last message fit', (tester) async {
      await addHosts(tester, [
        for (var i = 0; i < 8; i++)
          _host('very-long-name-$i', group: 'A fairly long group name'),
      ]);
      await pumpSection(tester, size: narrow, textScale: 1.5);
      await openFlow(tester);
      await confirmFlow(tester);
      await noOverflow(tester); // checklist
      await tester.tap(find.text('Skip for now'));
      await noOverflow(tester); // done
    });
  });
}

/// Pairs like the real store but cannot remove a pairing.
class _NoRevokeStore extends BridgeClientStore {
  _NoRevokeStore(File file) : super(file: file);

  @override
  Future<void> revoke(String id) async {
    throw const FileSystemException('read-only');
  }
}

/// Pairs like the real store but cannot save a confirmation.
class _NoConfirmStore extends BridgeClientStore {
  _NoConfirmStore(File file) : super(file: file);

  @override
  Future<void> confirm(String id) async {
    throw const FileSystemException('read-only');
  }
}

/// Saves like the real store but fails to write host [failId].
class _FailingHostStore extends TrackedHostStore {
  _FailingHostStore(super.io, File file, this.failId) : super(file: file);

  final String failId;

  @override
  Future<void> update(Host host) async {
    if (host.id == failId) throw const FileSystemException('disk full');
    await super.update(host);
  }
}
