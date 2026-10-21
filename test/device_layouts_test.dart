import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/app_settings.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/models/remote_entry.dart';
import 'package:secure_shell_go/screens/file_browser_pane.dart';
import 'package:secure_shell_go/screens/host_list_screen.dart';
import 'package:secure_shell_go/screens/remote_editor_screen.dart';
import 'package:secure_shell_go/screens/session_screen.dart';
import 'package:secure_shell_go/screens/terminal_pane.dart';
import 'package:secure_shell_go/services/credential_store.dart';
import 'package:secure_shell_go/services/device_storage.dart';
import 'package:secure_shell_go/services/display_hinge.dart';
import 'package:secure_shell_go/services/host_store.dart';
import 'package:secure_shell_go/services/input_profile.dart';
import 'package:secure_shell_go/services/keep_awake.dart';
import 'package:secure_shell_go/services/known_hosts_service.dart';
import 'package:secure_shell_go/services/session_controller.dart';
import 'package:secure_shell_go/services/session_foreground.dart';
import 'package:secure_shell_go/services/session_manager.dart';
import 'package:secure_shell_go/services/settings_store.dart';
import 'package:secure_shell_go/services/sftp_service.dart';
import 'package:secure_shell_go/services/ssh_service.dart';
import 'package:secure_shell_go/services/terminal_workspace.dart';
import 'package:secure_shell_go/theme.dart';
import 'package:secure_shell_go/widgets/editor_key_bar.dart';
import 'package:secure_shell_go/widgets/terminal_key_bar.dart';

import 'support/fake_transport.dart';

/// Layouts by the device in hand: key bars by Settings and keyboard, the
/// workspace by pointer, side by side by size, and splits at a hinge.

/// A shell channel with no SSH underneath, so the terminal gets as far as
/// showing its key bar.
class FakeShell implements SSHSession {
  final _stdout = StreamController<Uint8List>.broadcast();
  final _done = Completer<void>();

  @override
  Stream<Uint8List> get stdout => _stdout.stream;

  @override
  Stream<Uint8List> get stderr => const Stream.empty();

  @override
  Future<void> get done => _done.future;

  @override
  int? get exitCode => null;

  @override
  void write(Uint8List data) {}

  @override
  void close() {}

  @override
  void resizeTerminal(int width, int height, [int? pw, int? ph]) {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not faked');
}

class ShellTransport extends FakeTransportBase {
  ShellTransport({String id = 'h1', String label = 'Alpha'})
      : super(host: FakeTransportBase.hostFor(id: id, label: label));

  @override
  Future<SSHSession> startShell({
    required int columns,
    required int rows,
    String terminalType = 'xterm-256color',
  }) async =>
      FakeShell();
}

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

/// One readable file, for the editor.
class OneFileFs extends EmptyFs {
  static final Uint8List bytes =
      Uint8List.fromList(utf8.encode('def main():\n    pass\n'));

  @override
  Future<int?> sizeOf(String path) async => bytes.length;

  @override
  Future<bool> exists(String path) async => true;

  @override
  Future<int> download(
    String remotePath, {
    required Future<void> Function(Uint8List chunk) write,
    TransferProgress? onProgress,
    CancelCheck? isCancelled,
  }) async {
    await write(bytes);
    return bytes.length;
  }
}

class MemoryBackend implements SecureStorageBackend {
  final Map<String, String> data = {};
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> delete(String key) async => data.remove(key);
}

class StubStorage implements DeviceStorage {
  @override
  Future<bool> ensurePermission() async => true;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not faked');
}

class FakeForegroundChannel implements SessionForegroundChannel {
  @override
  Future<void> start(String label) async {}

  @override
  Future<void> stop() async {}
}

class NoopKeepAwake implements KeepAwakeController {
  @override
  Future<void> setEnabled(bool enabled) async {}
}

class NoopTimer implements Timer {
  @override
  bool get isActive => false;

  @override
  int get tick => 0;

  @override
  void cancel() {}
}

SessionController buildSession(SessionTransport transport) =>
    SessionController(
      connection: transport,
      storage: StubStorage(),
      openFileSystem: () async => EmptyFs(),
      keepaliveScheduler: (_, _) => NoopTimer(),
    );

SessionManager buildManager() => SessionManager(
      foreground:
          SessionForegroundController(channel: FakeForegroundChannel()),
      createController: (connection, resolve, resolveCreds) =>
          SessionController(
        connection: connection,
        storage: StubStorage(),
        openFileSystem: () async => EmptyFs(),
        resolveRemoteTarget: resolve,
        resolveDestinationCredentials: resolveCreds,
        keepaliveScheduler: (_, _) => NoopTimer(),
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

void main() {
  late Directory dir;
  late SettingsStore settings;
  late HostStore hosts;
  late KnownHostsService knownHosts;

  // Built here, outside the test's fake clock: a store made inside a
  // `testWidgets` body chains its writes on that clock, and `runAsync` then
  // waits on them for ever.
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('device_layouts_test');
    settings =
        SettingsStore(file: File('${dir.path}/${SettingsStore.fileName}'));
    hosts = HostStore(file: File('${dir.path}/${HostStore.fileName}'));
    knownHosts = KnownHostsService(
      file: File('${dir.path}/${KnownHostsService.fileName}'),
    );
  });

  tearDown(() async {
    settings.dispose();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<void> useKeyBarMode(WidgetTester tester, KeyBarMode mode) =>
      tester.runAsync(
        () => settings.update((s) => s.copyWith(keyBarMode: mode)),
      );

  Widget app({
    required InputProfile profile,
    required Widget home,
    TargetPlatform platform = TargetPlatform.android,
  }) =>
      MaterialApp(
        theme: AppTheme.dark.copyWith(platform: platform),
        builder: (context, child) =>
            InputProfileScope(profile: profile, child: child!),
        home: home,
      );

  group('the host list', () {
    // Not pumpAndSettle: the host list keeps a spinner turning somewhere
    // while it has anything to wait on, and settling would wait for ever.
    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
    }

    testWidgets('right-click opens the host menu at the pointer',
        (tester) async {
      final sessions = SessionManager();
      addTearDown(sessions.dispose);
      await tester.runAsync(() => hosts.add(const Host(
            id: 'h1',
            label: 'Build box',
            hostname: 'build.example.org',
            port: 22,
            username: 'ci',
            authMethod: SshAuthMethod.password,
          )));

      await tester.pumpWidget(app(
        profile: profileOf([PointerDeviceKind.mouse]),
        platform: TargetPlatform.linux,
        home: HostListScreen(
          hostStore: hosts,
          credentialStore: CredentialStore(backend: MemoryBackend()),
          knownHosts: knownHosts,
          sshService: SshService(knownHosts: knownHosts),
          settingsStore: settings,
          sessions: sessions,
        ),
      ));
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump();
      }

      final row = find.text('Build box');
      final at = tester.getCenter(row);
      await tester.tapAt(
        at,
        buttons: kSecondaryMouseButton,
        kind: PointerDeviceKind.mouse,
      );
      await settle(tester);

      // A menu: one line per action, beside the row clicked — not the
      // sheet, whose rows explain themselves.
      expect(find.text('Forget host keys'), findsOneWidget);
      expect(find.text('Undoes trust-on-first-use for this server'),
          findsNothing);
      final item = tester.getRect(find.text('Edit'));
      expect((item.top - at.dy).abs(), lessThan(300));
      // The keyboard is named in the search hint, there being one.
      expect(find.text('Search hosts · Ctrl+K for everything'),
          findsOneWidget);

      await tester.tap(find.text('Copy user@host'));
      await settle(tester);
      expect(find.text('Forget host keys'), findsNothing);
    });

    testWidgets('long-press still opens the sheet', (tester) async {
      final sessions = SessionManager();
      addTearDown(sessions.dispose);
      await tester.runAsync(() => hosts.add(const Host(
            id: 'h1',
            label: 'Build box',
            hostname: 'build.example.org',
            port: 22,
            username: 'ci',
            authMethod: SshAuthMethod.password,
          )));

      await tester.pumpWidget(app(
        profile: profileOf([PointerDeviceKind.touch]),
        home: HostListScreen(
          hostStore: hosts,
          credentialStore: CredentialStore(backend: MemoryBackend()),
          knownHosts: knownHosts,
          sshService: SshService(knownHosts: knownHosts),
          settingsStore: settings,
          sessions: sessions,
        ),
      ));
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump();
      }

      await tester.longPress(find.text('Build box'));
      await settle(tester);
      expect(find.text('Undoes trust-on-first-use for this server'),
          findsOneWidget);
      expect(find.text('Search hosts'), findsOneWidget);
    });
  });

  group('the terminal key bar', () {
    Future<void> pumpTerminal(
      WidgetTester tester,
      InputProfile profile, {
      TargetPlatform platform = TargetPlatform.android,
    }) async {
      final session = buildSession(ShellTransport());
      addTearDown(session.dispose);
      await tester.pumpWidget(app(
        profile: profile,
        platform: platform,
        // Rebuilt on the session's changes, as the session page does, so
        // the pane sees its shell open.
        home: Scaffold(
          body: StreamBuilder<void>(
            stream: session.changes,
            builder: (context, _) =>
                TerminalPane(session: session, settingsStore: settings),
          ),
        ),
      ));
      // The shell opens once the view has reported its size.
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }
      expect(session.isShellReady, isTrue);
    }

    testWidgets('automatically: there for touch, gone with a keyboard',
        (tester) async {
      final profile = profileOf([PointerDeviceKind.touch]);
      await pumpTerminal(tester, profile);
      expect(find.byType(TerminalKeyBar), findsOneWidget);

      // The keyboard cover's first keystroke.
      profile.noteHardwareKey();
      await tester.pump();
      expect(find.byType(TerminalKeyBar), findsNothing);

      // Cover folded back, the on-screen keyboard up: the row comes back.
      tester.view.viewInsets = const FakeViewPadding(bottom: 900);
      addTearDown(tester.view.resetViewInsets);
      await tester.pump();
      expect(find.byType(TerminalKeyBar), findsOneWidget);
    });

    testWidgets('automatically, a desktop has its keyboard', (tester) async {
      await pumpTerminal(tester, InputProfile(),
          platform: TargetPlatform.linux);
      expect(find.byType(TerminalKeyBar), findsNothing);
    });

    testWidgets('always shows it beside a keyboard', (tester) async {
      await useKeyBarMode(tester, KeyBarMode.always);
      await pumpTerminal(tester, InputProfile(),
          platform: TargetPlatform.linux);
      expect(find.byType(TerminalKeyBar), findsOneWidget);
    });

    testWidgets('never hides it from touch, and Settings applies live',
        (tester) async {
      await useKeyBarMode(tester, KeyBarMode.never);
      await pumpTerminal(tester, profileOf([PointerDeviceKind.touch]));
      expect(find.byType(TerminalKeyBar), findsNothing);

      await useKeyBarMode(tester, KeyBarMode.auto);
      await tester.pump();
      expect(find.byType(TerminalKeyBar), findsOneWidget);
    });
  });

  group('the editor key bar', () {
    Future<void> pumpEditor(
      WidgetTester tester,
      InputProfile profile, {
      TargetPlatform platform = TargetPlatform.android,
    }) async {
      await tester.pumpWidget(app(
        profile: profile,
        platform: platform,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => openRemoteEditor(
                context,
                filesystem: OneFileFs(),
                settingsStore: settings,
                paths: const ['/srv/app.py'],
                hostLabel: 'demo',
              ),
              child: const Text('open editor'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open editor'));
      await tester.pumpAndSettle();
      expect(find.text('Nothing open.'), findsNothing);
    }

    bool fieldHasFocus(WidgetTester tester) {
      final field = tester.widget<TextField>(find.byType(TextField).first);
      return field.focusNode?.hasFocus ?? false;
    }

    testWidgets('a phone gets the row, and no keyboard over the file',
        (tester) async {
      await pumpEditor(tester, InputProfile());
      expect(find.byType(EditorKeyBar), findsOneWidget);
      expect(fieldHasFocus(tester), isFalse);
    });

    testWidgets('a tablet with a keyboard: no row, and the field has focus',
        (tester) async {
      // Android, so the old platform check would have said "phone" — the
      // keystroke seen is what makes it a keyboard tablet.
      await pumpEditor(
        tester,
        profileOf([PointerDeviceKind.touch], keyboard: true),
      );
      expect(find.byType(EditorKeyBar), findsNothing);
      expect(fieldHasFocus(tester), isTrue);
    });

    testWidgets('always and never override the keyboard', (tester) async {
      await useKeyBarMode(tester, KeyBarMode.always);
      await pumpEditor(tester, InputProfile(), platform: TargetPlatform.linux);
      expect(find.byType(EditorKeyBar), findsOneWidget);

      await useKeyBarMode(tester, KeyBarMode.never);
      await tester.pump();
      expect(find.byType(EditorKeyBar), findsNothing);
    });

    testWidgets('a Windows tablet with no keyboard gets the row',
        (tester) async {
      await pumpEditor(
        tester,
        profileOf([PointerDeviceKind.touch]),
        platform: TargetPlatform.windows,
      );
      expect(find.byType(EditorKeyBar), findsOneWidget);
    });
  });

  group('HingeCut', () {
    const window = Rect.fromLTWH(0, 0, 1200, 900);

    DisplayFeature feature(
      Rect bounds, {
      DisplayFeatureType type = DisplayFeatureType.hinge,
      DisplayFeatureState state = DisplayFeatureState.postureFlat,
    }) =>
        DisplayFeature(bounds: bounds, type: type, state: state);

    test('a vertical hinge splits side by side, in the box\'s coordinates',
        () {
      final cut = HingeCut.within(
        [feature(const Rect.fromLTWH(580, 0, 40, 900))],
        const Rect.fromLTWH(0, 80, 1200, 820),
      );
      expect(cut, const HingeCut(
        axis: HingeAxis.sideBySide,
        start: 580,
        end: 620,
      ));
    });

    test('a half-open horizontal fold is tabletop', () {
      final cut = HingeCut.within(
        [
          feature(
            const Rect.fromLTWH(0, 450, 1200, 0),
            type: DisplayFeatureType.fold,
            state: DisplayFeatureState.postureHalfOpened,
          ),
        ],
        const Rect.fromLTWH(0, 80, 1200, 820),
      );
      expect(cut, const HingeCut(
        axis: HingeAxis.stacked,
        start: 370,
        end: 370,
      ));
    });

    test('a flat fold, a cutout or a hinge by the edge does not split', () {
      expect(
        HingeCut.within([
          feature(
            const Rect.fromLTWH(600, 0, 0, 900),
            type: DisplayFeatureType.fold,
          ),
        ], window),
        isNull,
      );
      expect(
        HingeCut.within([
          feature(
            const Rect.fromLTWH(560, 0, 80, 40),
            type: DisplayFeatureType.cutout,
            state: DisplayFeatureState.unknown,
          ),
        ], window),
        isNull,
      );
      expect(
        HingeCut.within(
            [feature(const Rect.fromLTWH(100, 0, 20, 900))], window),
        isNull,
      );
    });

    test('a hinge that misses the box does not split it', () {
      // The box is the right-hand screen alone.
      expect(
        HingeCut.within(
          [feature(const Rect.fromLTWH(580, 0, 40, 900))],
          const Rect.fromLTWH(620, 0, 580, 900),
        ),
        isNull,
      );
    });
  });

  group('the session screen', () {
    late SessionManager manager;
    late TerminalWorkspace workspace;

    setUp(() {
      manager = buildManager();
      workspace = TerminalWorkspace();
    });

    tearDown(() async {
      await workspace.dispose();
      await manager.dispose();
    });

    Future<void> pumpSessions(
      WidgetTester tester, {
      required InputProfile profile,
      Size size = const Size(1280, 800),
      TargetPlatform platform = TargetPlatform.android,
      List<DisplayFeature> features = const [],
      VoidCallback? onAddSession,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.view.displayFeatures = features;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(app(
        profile: profile,
        platform: platform,
        home: SessionsScreen(
          sessions: manager,
          settingsStore: settings,
          workspace: workspace,
          keepAwake: NoopKeepAwake(),
          onAddSession: onAddSession,
        ),
      ));
      // Twice more: a hinge is measured after the first frame.
      await tester.pump();
      await tester.pump();
    }

    group('by pointer', () {
      testWidgets('a mouse on Android gets the split workspace',
          (tester) async {
        final alpha = manager.open(ShellTransport());
        await pumpSessions(
          tester,
          profile: profileOf([PointerDeviceKind.mouse]),
        );
        expect(find.byIcon(Icons.splitscreen_outlined), findsOneWidget);
        expect(workspace.focusedSessionId, alpha.id);
      });

      testWidgets('touch on a desktop gets tabs', (tester) async {
        manager.open(ShellTransport());
        await pumpSessions(
          tester,
          profile: profileOf([PointerDeviceKind.touch]),
          platform: TargetPlatform.windows,
        );
        expect(find.byIcon(Icons.splitscreen_outlined), findsNothing);
        expect(workspace.visibleSessionIds, isEmpty);
      });

      testWidgets('a mouse arriving later brings the workspace',
          (tester) async {
        final alpha = manager.open(ShellTransport());
        final profile = profileOf([PointerDeviceKind.touch]);
        await pumpSessions(tester, profile: profile);
        expect(find.byIcon(Icons.splitscreen_outlined), findsNothing);

        profile.notePointer(PointerDeviceKind.mouse);
        await tester.pump();
        expect(find.byIcon(Icons.splitscreen_outlined), findsOneWidget);
        expect(workspace.focusedSessionId, alpha.id);
      });

      testWidgets('right-click on the terminal opens its menu, with a mouse',
          (tester) async {
        manager.open(ShellTransport());
        await pumpSessions(
          tester,
          profile: profileOf([PointerDeviceKind.mouse]),
          platform: TargetPlatform.linux,
        );
        await tester.tap(
          find.byType(TerminalPane),
          buttons: kSecondaryMouseButton,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        expect(find.text('Paste'), findsOneWidget);
        expect(find.text('Select all'), findsOneWidget);
        // Named, because there is a keyboard to press them on.
        expect(find.text('Ctrl+Shift+V'), findsOneWidget);
      });
    });

    group('by size', () {
      testWidgets('a tablet shows terminal and files together',
          (tester) async {
        manager.open(ShellTransport());
        await pumpSessions(
          tester,
          profile: profileOf([PointerDeviceKind.touch]),
        );
        expect(find.byType(FileBrowserPane), findsOneWidget);
        expect(find.byTooltip('Browse files'), findsNothing);
        expect(find.byTooltip('Terminal full width'), findsOneWidget);
      });

      testWidgets('a phone on its side is wide but too short for both',
          (tester) async {
        manager.open(ShellTransport());
        await pumpSessions(
          tester,
          profile: profileOf([PointerDeviceKind.touch]),
          size: const Size(852, 393),
        );
        expect(find.byType(FileBrowserPane), findsNothing);
        expect(find.byTooltip('Browse files'), findsOneWidget);
        expect(find.byTooltip('Terminal full width'), findsNothing);
      });

      testWidgets('the terminal can have the whole width, and give it back',
          (tester) async {
        manager.open(ShellTransport());
        await pumpSessions(
          tester,
          profile: profileOf([PointerDeviceKind.touch]),
        );
        final paneWidth =
            tester.getSize(find.byType(TerminalPane)).width;
        expect(paneWidth, lessThan(1000));

        await tester.tap(find.byTooltip('Terminal full width'));
        await tester.pump();
        expect(tester.getSize(find.byType(TerminalPane)).width, 1280);
        // Taking turns now, so the files are a toggle away.
        expect(find.byTooltip('Browse files'), findsOneWidget);

        await tester.tap(find.byTooltip('Show files beside the terminal'));
        await tester.pump();
        expect(tester.getSize(find.byType(TerminalPane)).width, paneWidth);
      });

      testWidgets('touch makes the tab strip a 48dp target', (tester) async {
        manager.open(ShellTransport(id: 'h1', label: 'Alpha'));
        manager.open(ShellTransport(id: 'h2', label: 'Beta'));
        await pumpSessions(
          tester,
          profile: profileOf([PointerDeviceKind.touch]),
        );
        final close = find.byTooltip('Disconnect Alpha');
        expect(tester.getSize(close).height, greaterThanOrEqualTo(48));
        expect(tester.getSize(close).width, greaterThanOrEqualTo(48));
      });
    });

    group('at a hinge', () {
      testWidgets('a vertical hinge puts a pane on each screen',
          (tester) async {
        manager.open(ShellTransport());
        await pumpSessions(
          tester,
          profile: profileOf([PointerDeviceKind.touch]),
          size: const Size(1200, 900),
          features: const [
            DisplayFeature(
              bounds: Rect.fromLTWH(580, 0, 40, 900),
              type: DisplayFeatureType.hinge,
              state: DisplayFeatureState.postureFlat,
            ),
          ],
        );
        final terminal = tester.getRect(find.byType(TerminalPane));
        final files = tester.getRect(find.byType(FileBrowserPane));
        expect(terminal.left, 0);
        expect(terminal.right, 580);
        expect(files.left, 620);
        expect(files.right, 1200);
      });

      testWidgets('tabletop puts the terminal above the fold, files below',
          (tester) async {
        manager.open(ShellTransport());
        await pumpSessions(
          tester,
          profile: profileOf([PointerDeviceKind.touch]),
          // A Flip-sized phone: far too narrow for side by side.
          size: const Size(412, 915),
          features: const [
            DisplayFeature(
              bounds: Rect.fromLTWH(0, 457, 412, 0),
              type: DisplayFeatureType.fold,
              state: DisplayFeatureState.postureHalfOpened,
            ),
          ],
        );
        final terminal = tester.getRect(find.byType(TerminalPane));
        final files = tester.getRect(find.byType(FileBrowserPane));
        expect(terminal.bottom, moreOrLessEquals(457));
        expect(files.top, greaterThanOrEqualTo(457));
        expect(files.bottom, 915);
        expect(find.byTooltip('Browse files'), findsNothing);
      });

      testWidgets('a fold opened flat is one screen', (tester) async {
        manager.open(ShellTransport());
        await pumpSessions(
          tester,
          profile: profileOf([PointerDeviceKind.touch]),
          size: const Size(1200, 900),
          features: const [
            DisplayFeature(
              bounds: Rect.fromLTWH(600, 0, 0, 900),
              type: DisplayFeatureType.fold,
              state: DisplayFeatureState.postureFlat,
            ),
          ],
        );
        // The ordinary 3:2, straight across the crease.
        expect(
          tester.getRect(find.byType(TerminalPane)).right,
          moreOrLessEquals((1200 - 1) * 3 / 5, epsilon: 1),
        );
      });
    });

    group('shortcuts', () {
      testWidgets('Ctrl+Tab and Ctrl+Shift+Tab walk the tabs',
          (tester) async {
        final alpha = manager.open(ShellTransport(id: 'h1', label: 'Alpha'));
        final beta = manager.open(ShellTransport(id: 'h2', label: 'Beta'));
        await pumpSessions(
          tester,
          profile: profileOf([PointerDeviceKind.touch], keyboard: true),
        );
        expect(manager.activeId, beta.id);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
        expect(manager.activeId, alpha.id);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
        expect(manager.activeId, beta.id);
      });

      testWidgets('Ctrl+Shift+T from inside the terminal asks for a session',
          (tester) async {
        manager.open(ShellTransport());
        var asked = 0;
        await pumpSessions(
          tester,
          profile: profileOf([PointerDeviceKind.touch], keyboard: true),
          onAddSession: () => asked++,
        );
        // The terminal has the focus, as it does nearly all the time.
        expect(FocusManager.instance.primaryFocus?.debugLabel, 'terminal');

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
        expect(asked, 1);
        // And the tooltip says so, there being a keyboard.
        expect(find.byTooltip('New session (Ctrl+Shift+T)'), findsOneWidget);
      });

      testWidgets('Ctrl+Shift+Enter gives the terminal the width',
          (tester) async {
        manager.open(ShellTransport());
        await pumpSessions(
          tester,
          profile: profileOf([PointerDeviceKind.touch], keyboard: true),
        );
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
        expect(tester.getSize(find.byType(TerminalPane)).width, 1280);
      });
    });
  });
}
