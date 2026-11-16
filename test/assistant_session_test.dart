import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/remote_entry.dart';
import 'package:secure_shell_go/screens/session_screen.dart';
import 'package:secure_shell_go/services/assistant_drive.dart';
import 'package:secure_shell_go/services/device_storage.dart';
import 'package:secure_shell_go/services/keep_awake.dart';
import 'package:secure_shell_go/services/session_controller.dart';
import 'package:secure_shell_go/services/session_foreground.dart';
import 'package:secure_shell_go/services/session_manager.dart';
import 'package:secure_shell_go/services/settings_store.dart';
import 'package:secure_shell_go/services/sftp_service.dart';
import 'package:secure_shell_go/services/terminal_workspace.dart';

import 'support/fake_transport.dart';
import 'support/link_transport.dart';

/// A session an AI assistant drives: the tab marker, and the banner with
/// Take over and Stop, which follows the drive as it moves forward.

/// An empty home directory, for the file browser beside the terminal.
class EmptyFs implements RemoteFileSystem {
  @override
  Future<String> home() async => '/home/dev';

  @override
  Future<String> resolve(String path) async => path;

  @override
  Future<List<RemoteEntry>> list(String path) async => const [];

  @override
  Future<int?> sizeOf(String path) async => 0;

  @override
  Future<bool> exists(String path) async => false;

  @override
  Future<bool> isDirectory(String path) async => false;

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not faked');
}

class StubStorage implements DeviceStorage {
  @override
  Future<bool> ensurePermission() async => true;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not faked');
}

class SilentForeground implements SessionForegroundChannel {
  @override
  Future<void> start(String label) async {}

  @override
  Future<void> stop() async {}
}

class NoopKeepAwake implements KeepAwakeController {
  @override
  Future<void> setEnabled(bool enabled) async {}
}


final _drives = <String, AssistantDrive>{};

SessionManager buildManager() => SessionManager(
  foreground: SessionForegroundController(channel: SilentForeground()),
  createController: (connection, resolve, resolveCreds) {
    final controller = SessionController(
      connection: connection,
      storage: StubStorage(),
      openFileSystem: () async => EmptyFs(),
      resolveRemoteTarget: resolve,
      resolveDestinationCredentials: resolveCreds,
      keepaliveScheduler: (_, tick) => CrankTimer(tick),
    );
    final drive = _drives[connection.host.label];
    if (drive != null) controller.attachAssistant(drive);
    return controller;
  },
);

LinkTransport link(String id, String label) =>
    LinkTransport(host: FakeTransportBase.hostFor(id: id, label: label));

void main() {
  late SessionManager manager;
  late TerminalWorkspace workspace;
  late SettingsStore settings;
  late AssistantDrive drive;

  setUp(() {
    _drives.clear();
    drive = AssistantDrive(
      terminalId: 't-1',
      clientId: 'c-1',
      clientName: 'Desk assistant',
      hostName: 'Driven',
    );
    _drives['Driven'] = drive;
    manager = buildManager();
    workspace = TerminalWorkspace();
    settings = SettingsStore();
  });

  tearDown(() async {
    await workspace.dispose();
    await manager.dispose();
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<ManagedSession> pumpScreen(
    WidgetTester tester, {
    Size size = const Size(412, 900),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    manager.open(link('h1', 'Mine'));
    final driven = manager.open(link('h2', 'Driven'));
    manager.select(driven.id);
    final screen = SessionsScreen(
      sessions: manager,
      settingsStore: settings,
      workspace: workspace,
      keepAwake: NoopKeepAwake(),
    );
    final pushed = size.width < 600;
    await tester.pumpWidget(
      MaterialApp(home: pushed ? const Scaffold(body: Text('Host list')) : screen),
    );
    if (pushed) {
      unawaited(
        tester
            .state<NavigatorState>(find.byType(Navigator))
            .push(MaterialPageRoute<void>(builder: (_) => screen)),
      );
    }
    await settle(tester);
    return driven;
  }

  testWidgets('the tab of an assistant session carries a marker, the user\'s '
      'does not', (tester) async {
    await pumpScreen(tester);
    expect(find.byKey(const ValueKey('assistant-tab-marker')), findsOneWidget);
  });

  testWidgets('driving: the banner names the assistant, with Take over and '
      'Stop', (tester) async {
    await pumpScreen(tester);
    expect(find.byKey(const ValueKey('assistant-banner-driving')),
        findsOneWidget);
    expect(find.text('Desk assistant is using this terminal. You can watch it.'),
        findsOneWidget);
    expect(find.byKey(const ValueKey('assistant-take-over')), findsOneWidget);
    expect(find.byKey(const ValueKey('assistant-stop')), findsOneWidget);
  });

  testWidgets('Take over moves to the quiet note and removes the buttons',
      (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.byKey(const ValueKey('assistant-take-over')));
    await settle(tester);
    expect(drive.state, AssistantDriveState.takenOver);
    expect(find.byKey(const ValueKey('assistant-banner-takenOver')),
        findsOneWidget);
    expect(find.text('You took over. Desk assistant can no longer type here.'),
        findsOneWidget);
    expect(find.byKey(const ValueKey('assistant-take-over')), findsNothing);
    expect(find.byKey(const ValueKey('assistant-stop')), findsNothing);
  });

  testWidgets('the banner follows the user typing, which takes over',
      (tester) async {
    await pumpScreen(tester);
    drive.userTyped();
    await settle(tester);
    expect(find.byKey(const ValueKey('assistant-banner-takenOver')),
        findsOneWidget);
  });

  testWidgets('Stop with no bridge service closes the tab', (tester) async {
    final driven = await pumpScreen(tester);
    await tester.tap(find.byKey(const ValueKey('assistant-stop')));
    await settle(tester);
    // The ordinary tab close: it asks first, as it does for any live session.
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(manager.byId(driven.id), isNotNull);
  });

  testWidgets('ended shows the reason', (tester) async {
    await pumpScreen(tester);
    drive.end('The assistant closed it.');
    await settle(tester);
    expect(find.byKey(const ValueKey('assistant-banner-ended')),
        findsOneWidget);
    expect(
      find.text("The terminal of Desk assistant ended: The assistant closed it."),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('assistant-stop')), findsNothing);
  });

  testWidgets('a name with control characters is shown visibly',
      (tester) async {
    _drives['Driven'] = AssistantDrive(
      terminalId: 't-2',
      clientId: 'c-2',
      clientName: 'Evil\u202E\u001b',
      hostName: 'Driven',
    );
    await pumpScreen(tester);
    expect(find.textContaining(r'Evil[U+202E]\x1b'), findsOneWidget);
  });

  for (final size in [const Size(320, 568), const Size(1400, 900)]) {
    testWidgets('fits ${size.width.toInt()} wide at large text',
        (tester) async {
      await pumpScreen(tester, size: size, textScale: 1.5);
      expect(tester.takeException(), isNull);
      drive.takeOver();
      await settle(tester);
      expect(tester.takeException(), isNull);
    });
  }
}
