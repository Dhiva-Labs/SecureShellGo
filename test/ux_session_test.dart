import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/models/remote_entry.dart';
import 'package:secure_shell_go/screens/session_screen.dart';
import 'package:secure_shell_go/screens/terminal_pane.dart';
import 'package:secure_shell_go/services/device_storage.dart';
import 'package:secure_shell_go/services/input_profile.dart';
import 'package:secure_shell_go/services/keep_awake.dart';
import 'package:secure_shell_go/services/login_prompt.dart';
import 'package:secure_shell_go/services/session_controller.dart';
import 'package:secure_shell_go/services/session_foreground.dart';
import 'package:secure_shell_go/services/session_manager.dart';
import 'package:secure_shell_go/services/settings_store.dart';
import 'package:secure_shell_go/services/sftp_service.dart';
import 'package:secure_shell_go/services/terminal_workspace.dart';
import 'package:secure_shell_go/widgets/login_prompt_dialog.dart';
import 'package:secure_shell_go/widgets/session_shortcuts.dart';

import 'support/fake_transport.dart';
import 'support/link_transport.dart';

/// The session screen's rough edges, smoothed: a banner's Close that went
/// nowhere, a dropped connection said twice, two transfer buttons for one
/// list, a banner sheet only a pointer could dismiss, and the keys for
/// closing a session, stepping between panes, and ⌘ on a Mac.
///
/// The fakes are the ones `device_layouts_test.dart` uses, spelled out here
/// rather than imported: that suite pulls in the host list, and a session
/// screen test has no business failing on a change there.

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

SessionManager buildManager() => SessionManager(
      foreground: SessionForegroundController(channel: SilentForeground()),
      createController: (connection, resolve, resolveCreds) =>
          SessionController(
        connection: connection,
        storage: StubStorage(),
        openFileSystem: () async => EmptyFs(),
        resolveRemoteTarget: resolve,
        resolveDestinationCredentials: resolveCreds,
        keepaliveScheduler: (_, tick) => CrankTimer(tick),
      ),
    );

/// A profile that has seen [pointers] and, with [keyboard], a key typed.
InputProfile profileOf(
  List<PointerDeviceKind> pointers, {
  bool keyboard = false,
}) {
  final profile = InputProfile();
  for (final kind in pointers) {
    profile.notePointer(kind);
  }
  if (keyboard) profile.noteHardwareKey();
  return profile;
}

LinkTransport link(String id, String label) =>
    LinkTransport(host: FakeTransportBase.hostFor(id: id, label: label));

void main() {
  late SessionManager manager;
  late TerminalWorkspace workspace;
  late SettingsStore settings;

  setUp(() {
    manager = buildManager();
    workspace = TerminalWorkspace();
    settings = SettingsStore();
  });

  tearDown(() async {
    await workspace.dispose();
    await manager.dispose();
  });

  /// The sessions screen pushed over a stand-in for the host list, as the
  /// app pushes it — so that the screen going away has somewhere to go.
  ///
  /// A desktop window gets it as the home route instead: a split there has
  /// a file browser per pane, each with its own floating button, and a push
  /// animates those as heroes that share a tag.
  Future<void> pumpScreen(
    WidgetTester tester, {
    TargetPlatform platform = TargetPlatform.android,
    InputProfile? profile,
    Size size = const Size(412, 900),
    VoidCallback? onAddSession,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final screen = SessionsScreen(
      sessions: manager,
      settingsStore: settings,
      workspace: workspace,
      keepAwake: NoopKeepAwake(),
      onAddSession: onAddSession,
    );
    final pushed = size.width < 600;
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(platform: platform),
      builder: profile == null
          ? null
          : (context, child) =>
              InputProfileScope(profile: profile, child: child!),
      home: pushed ? const Scaffold(body: Text('Host list')) : screen,
    ));
    if (pushed) {
      unawaited(
        tester
            .state<NavigatorState>(find.byType(Navigator))
            .push(MaterialPageRoute<void>(builder: (_) => screen)),
      );
    }
    await settle(tester);
  }

  /// Ctrl (or, with [command], ⌘) and Shift with [key], then the frames the
  /// focus a page puts back lands in.
  Future<void> chord(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool command = false,
  }) async {
    final modifier = command
        ? LogicalKeyboardKey.metaLeft
        : LogicalKeyboardKey.controlLeft;
    await tester.sendKeyDownEvent(modifier);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(modifier);
    await settle(tester);
  }

  void drop(LinkTransport transport) =>
      transport.drop(const SocketException('Connection reset'));

  InputProfile touchAndKeys() =>
      profileOf([PointerDeviceKind.touch], keyboard: true);

  group('closing a session from its banner', () {
    testWidgets('a dropped one closes, and the screen goes with it',
        (tester) async {
      final transport = link('h1', 'Alpha');
      manager.open(transport);
      await pumpScreen(tester);

      drop(transport);
      await settle(tester);
      await tester.tap(find.text('Close'));
      await settle(tester);

      // Nothing was left to lose, so nothing was asked.
      expect(find.byType(AlertDialog), findsNothing);
      expect(manager.isEmpty, isTrue);
      expect(find.byType(SessionsScreen), findsNothing);
      expect(find.text('Host list'), findsOneWidget);
    });

    testWidgets('one whose shell ended asks first, as the app bar does',
        (tester) async {
      final transport = link('h1', 'Alpha');
      manager.open(transport);
      await pumpScreen(tester);

      transport.shells.single.exit();
      await settle(tester);
      await tester.tap(find.text('Close'));
      await settle(tester);
      expect(find.text('Close the session on Alpha?'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Disconnect'));
      await settle(tester);
      expect(manager.isEmpty, isTrue);
      expect(find.text('Host list'), findsOneWidget);
    });

    testWidgets('a dropped one still holding transfers asks before losing '
        'them', (tester) async {
      final transport = link('h1', 'Alpha');
      final alpha = manager.open(transport);
      await pumpScreen(tester);
      drop(transport);
      await settle(tester);
      // What a session that can reconnect is left with: a transfer waiting
      // for the connection to come back.
      alpha.controller.transfers
        ..interruptAll()
        ..enqueueDownload(remotePath: '/home/dev/a.log', name: 'a.log');
      await settle(tester);

      await tester.tap(find.text('Close'));
      await settle(tester);
      expect(find.textContaining('1 transfer is still running'),
          findsOneWidget);
      await tester.tap(find.text('Stay'));
      await settle(tester);
      expect(manager.length, 1);

      await tester.tap(find.text('Close'));
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Close tab'));
      await settle(tester);
      expect(manager.isEmpty, isTrue);
      expect(find.text('Host list'), findsOneWidget);
    });
  });

  group('a dropped connection', () {
    testWidgets('on screen, is said by its banner alone', (tester) async {
      final transport = link('h1', 'Alpha');
      manager.open(transport);
      await pumpScreen(tester);

      drop(transport);
      await settle(tester);

      expect(find.text('Reconnect'), findsNothing);
      expect(find.text('Close'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('behind another tab, gets a snackbar naming the host',
        (tester) async {
      final transport = link('h1', 'Alpha');
      manager.open(transport);
      final beta = manager.open(link('h2', 'Beta'));
      manager.select(beta.id);
      await pumpScreen(tester, profile: touchAndKeys());

      drop(transport);
      await settle(tester);

      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.textContaining('Alpha: '), findsOneWidget);
    });

    testWidgets('in a pane of a split, focused or not, is left to its banner',
        (tester) async {
      final left = link('h1', 'Alpha');
      manager.open(left);
      manager.open(link('h2', 'Beta'));
      await pumpScreen(
        tester,
        platform: TargetPlatform.linux,
        size: const Size(1400, 900),
      );
      workspace.splitFocused(WorkspaceAxis.row);
      await settle(tester);
      expect(workspace.visibleSessionIds, hasLength(2));

      drop(left);
      await settle(tester);

      expect(find.text('Close'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
    });
  });

  group('the transfer buttons', () {
    /// A transfer that stays queued, for a badge to count.
    void queueOne(ManagedSession entry) => entry.controller.transfers
      ..interruptAll()
      ..enqueueDownload(remotePath: '/home/dev/a.log', name: 'a.log');

    testWidgets('one session has one, which opens its own list',
        (tester) async {
      final alpha = manager.open(link('h1', 'Alpha'));
      await pumpScreen(tester);
      queueOne(alpha);
      await settle(tester);

      expect(find.byTooltip('All transfers'), findsOneWidget);
      expect(find.byTooltip('Transfers'), findsNothing);

      await tester.tap(find.byTooltip('All transfers'));
      await settle(tester);
      // The session's own sheet, with Open on what it downloads.
      expect(find.text('Transfers'), findsOneWidget);
      expect(find.text('a.log'), findsOneWidget);
    });

    testWidgets('two sessions have both', (tester) async {
      final alpha = manager.open(link('h1', 'Alpha'));
      manager.open(link('h2', 'Beta'));
      manager.select(alpha.id);
      await pumpScreen(tester);
      queueOne(alpha);
      await settle(tester);

      expect(find.byTooltip('All transfers'), findsOneWidget);
      expect(find.byTooltip('Transfers'), findsOneWidget);
    });
  });

  group('the banner sheet after login', () {
    const host = Host(
      id: 'h1',
      label: 'Build box',
      hostname: 'build.example.com',
      port: 22,
      username: 'dev',
      authMethod: SshAuthMethod.password,
    );

    for (final key in [LogicalKeyboardKey.enter, LogicalKeyboardKey.space]) {
      testWidgets('${key.keyLabel} dismisses it', (tester) async {
        await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: Text('Connecting'))),
        );
        var dismissed = false;
        unawaited(
          showServerBannerSheet(
            tester.element(find.text('Connecting')),
            const [ServerBanner(host: host, text: 'Authorised use only.')],
          ).then((_) => dismissed = true),
        );
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsOneWidget);

        await tester.sendKeyEvent(key);
        await tester.pumpAndSettle();

        expect(find.byType(BottomSheet), findsNothing);
        expect(dismissed, isTrue);
      });
    }
  });

  group('keys', () {
    testWidgets('Ctrl+Shift+W closes the session in front, asking first',
        (tester) async {
      manager.open(link('h1', 'Alpha'));
      await pumpScreen(tester, profile: touchAndKeys());
      expect(find.byTooltip('Disconnect (Ctrl+Shift+W)'), findsOneWidget);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'terminal');

      await chord(tester, LogicalKeyboardKey.keyW);
      expect(find.text('Close the session on Alpha?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Disconnect'));
      await settle(tester);

      expect(manager.isEmpty, isTrue);
      expect(find.text('Host list'), findsOneWidget);
    });

    testWidgets('Ctrl+Shift+N and Ctrl+Shift+P step between the panes',
        (tester) async {
      final alpha = manager.open(link('h1', 'Alpha'));
      final beta = manager.open(link('h2', 'Beta'));
      final gamma = manager.open(link('h3', 'Gamma'));
      await pumpScreen(
        tester,
        platform: TargetPlatform.linux,
        size: const Size(1400, 900),
      );
      final left = workspace.focusedPaneId;
      final right = workspace.splitFocused(WorkspaceAxis.row)!.id;
      await settle(tester);
      expect(workspace.paneById(left)!.sessionId, gamma.id);
      expect(workspace.paneById(right)!.sessionId, alpha.id);

      await chord(tester, LogicalKeyboardKey.keyN);
      // Round the end, to the left; and the keys went with the focus.
      expect(workspace.focusedPaneId, left);
      expect(manager.activeId, gamma.id);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'terminal');

      await chord(tester, LogicalKeyboardKey.keyP);
      expect(workspace.focusedPaneId, right);
      expect(manager.activeId, alpha.id);

      // Stepping moved the focus, never a session: Beta stays off screen.
      expect(workspace.paneById(left)!.sessionId, gamma.id);
      expect(workspace.paneById(right)!.sessionId, alpha.id);
      expect(workspace.paneForSession(beta.id), isNull);
    });

    testWidgets('Ctrl+Shift+N and Ctrl+Shift+P are the shell\'s until there '
        'is a pane to go to', (tester) async {
      manager.open(link('h1', 'Alpha'));
      await pumpScreen(
        tester,
        platform: TargetPlatform.linux,
        size: const Size(1400, 900),
      );

      /// What the terminal does with the chord on its way in: claims it for
      /// the screen, or lets it go on to the shell, as plain Ctrl+N or P.
      Future<KeyEventResult> offer(LogicalKeyboardKey key) async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        final result = SessionShortcuts.dispatch(
          tester.element(find.byType(TerminalPane).first),
          KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.keyN,
            logicalKey: key,
            timeStamp: Duration.zero,
          ),
        );
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await settle(tester);
        return result;
      }

      expect(await offer(LogicalKeyboardKey.keyN), KeyEventResult.ignored);
      expect(await offer(LogicalKeyboardKey.keyP), KeyEventResult.ignored);

      // Split, but the new pane is empty: still nowhere to go.
      workspace.splitFocused(WorkspaceAxis.row);
      await settle(tester);
      expect(await offer(LogicalKeyboardKey.keyN), KeyEventResult.ignored);

      // A second session fills it.
      manager.open(link('h2', 'Beta'));
      await settle(tester);
      expect(await offer(LogicalKeyboardKey.keyN), KeyEventResult.handled);
    });

    testWidgets('on a Mac, ⌘ stands in for Ctrl, and the tooltips say so',
        (tester) async {
      manager.open(link('h1', 'Alpha'));
      var asked = 0;
      await pumpScreen(
        tester,
        platform: TargetPlatform.macOS,
        size: const Size(1400, 900),
        onAddSession: () => asked++,
      );
      expect(find.byTooltip('New session (⇧⌘T)'), findsOneWidget);
      expect(find.byTooltip('Disconnect (⇧⌘W)'), findsOneWidget);

      await chord(tester, LogicalKeyboardKey.keyT, command: true);
      expect(asked, 1);
      // And Ctrl still works there too.
      await chord(tester, LogicalKeyboardKey.keyT);
      expect(asked, 2);

      await chord(tester, LogicalKeyboardKey.keyW, command: true);
      expect(find.text('Close the session on Alpha?'), findsOneWidget);
    });

    testWidgets('elsewhere, ⌘ is not Ctrl', (tester) async {
      manager.open(link('h1', 'Alpha'));
      var asked = 0;
      await pumpScreen(
        tester,
        platform: TargetPlatform.linux,
        size: const Size(1400, 900),
        onAddSession: () => asked++,
      );
      await chord(tester, LogicalKeyboardKey.keyT, command: true);
      expect(asked, 0);
    });
  });
}

/// Frames enough for a push or a pop to finish, and for the async hops a
/// session's own changes take. Not `pumpAndSettle`: a connecting terminal
/// can keep something animating for as long as it is on screen.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump();
  }
  // A page transition's length, which on Android is most of a second.
  await tester.pump(const Duration(seconds: 1));
  await tester.pump();
}
