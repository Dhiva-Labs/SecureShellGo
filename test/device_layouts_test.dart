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
import 'package:secure_shell_go/screens/host_edit_screen.dart';
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

/// A home with one folder in it, for the file browser, noting every listing.
class OneFolderFs extends EmptyFs {
  final List<String> listed = [];

  @override
  Future<List<RemoteEntry>> list(String path) async {
    listed.add(path);
    if (path != '/home/dev') return const [];
    return const [
      RemoteEntry(
        name: 'app',
        path: '/home/dev/app',
        kind: RemoteEntryKind.directory,
      ),
    ];
  }

  @override
  Future<bool> exists(String path) async => true;

  @override
  Future<bool> isDirectory(String path) async => true;
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

SessionManager buildManager({RemoteFileSystem Function()? fileSystem}) =>
    SessionManager(
      foreground:
          SessionForegroundController(channel: FakeForegroundChannel()),
      createController: (connection, resolve, resolveCreds) =>
          SessionController(
        connection: connection,
        storage: StubStorage(),
        openFileSystem: () async => fileSystem?.call() ?? EmptyFs(),
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
    Future<SessionController> pumpTerminal(
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
      return session;
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

    testWidgets('a sticky Ctrl does not outlast the row', (tester) async {
      final profile = profileOf([PointerDeviceKind.touch]);
      final session = await pumpTerminal(tester, profile);
      await tester.tap(find.text('Ctrl'));
      await tester.pump();
      expect(session.transformInput!('c'), '\x03');

      await tester.tap(find.text('Ctrl'));
      await tester.pump();
      // A keyboard cover's Ctrl, pressed on its own: the row goes, and with
      // it the only sign that Ctrl was armed.
      profile.noteHardwareKey();
      await tester.pump();
      expect(find.byType(TerminalKeyBar), findsNothing);
      expect(session.transformInput!('c'), 'c');
    });

    testWidgets('Paste is an icon, not a glyph a font may lack',
        (tester) async {
      await pumpTerminal(tester, profileOf([PointerDeviceKind.touch]));
      expect(
        find.descendant(
          of: find.byType(TerminalKeyBar),
          matching: find.byIcon(Icons.content_paste),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('⎘'), findsNothing);
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

  group('the editor tab strip', () {
    testWidgets('under touch, a close button is a whole 48dp target',
        (tester) async {
      // A phone: wider windows list open files in a side panel instead.
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(app(
        profile: profileOf([PointerDeviceKind.touch]),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => openRemoteEditor(
                context,
                filesystem: OneFileFs(),
                settingsStore: settings,
                paths: const ['/srv/app.py', '/srv/lib.py'],
                hostLabel: 'demo',
              ),
              child: const Text('open editor'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open editor'));
      await tester.pumpAndSettle();

      // 21dp above the button's middle: inside 48dp, outside a 38dp strip.
      final close = find.byTooltip('Close app.py');
      await tester.tapAt(tester.getCenter(close) - const Offset(0, 21));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Close app.py'), findsNothing);
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

  group('the host form', () {
    testWidgets('fits a 320dp window, all the way down', (tester) async {
      final sessions = SessionManager();
      addTearDown(sessions.dispose);
      await tester.runAsync(() async {
        await hosts.add(FakeTransportBase.hostFor(
          id: 'bastion',
          label: 'Bastion in the old datacentre, eu-west',
        ));
      });
      // Tall: a ListView builds only what is on screen, and the jump host
      // field is well below the fold of a phone.
      tester.view.physicalSize = const Size(320, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(app(
        profile: profileOf([PointerDeviceKind.touch]),
        home: HostEditScreen(
          hostStore: hosts,
          credentialStore: CredentialStore(backend: MemoryBackend()),
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
      expect(find.text('Connect via jump host'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Direct connection'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('the session screen', () {
    late SessionManager manager;
    late TerminalWorkspace workspace;

    /// What the sessions' file browsers list; nothing, unless a test says.
    RemoteFileSystem? fileSystem;

    setUp(() {
      fileSystem = null;
      manager = buildManager(fileSystem: () => fileSystem ?? EmptyFs());
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

      testWidgets('a middle click does not open the menu', (tester) async {
        manager.open(ShellTransport());
        await pumpSessions(
          tester,
          profile: profileOf([PointerDeviceKind.mouse]),
          platform: TargetPlatform.linux,
        );
        await tester.tap(
          find.byType(TerminalPane),
          buttons: kMiddleMouseButton,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        expect(find.text('Select all'), findsNothing);
      });

      testWidgets('a finger right after a mouse still opens a file row',
          (tester) async {
        final fs = OneFolderFs();
        fileSystem = fs;
        manager.open(ShellTransport(id: 'h1', label: 'Alpha'));
        // A second session, so a row has somewhere to be dragged to.
        manager.open(ShellTransport(id: 'h2', label: 'Beta'));
        final profile = profileOf([PointerDeviceKind.mouse]);
        // Listening to the app's pointers, as it does in the app.
        profile.attach();
        addTearDown(profile.detach);
        await pumpSessions(tester, profile: profile);
        for (var i = 0; i < 5; i++) {
          await tester.pump();
        }
        // The other session's browser is built too, behind this one.
        final row = find.text('app').hitTestable();
        expect(row, findsOneWidget);

        // A real tap takes a frame or two between finger down and up, and
        // that frame is where the row was rebuilt for the new pointer.
        final finger = await tester.startGesture(
          tester.getCenter(row),
          kind: PointerDeviceKind.touch,
        );
        await tester.pump();
        expect(profile.lastPointer, PointerClass.touch);
        await finger.up();
        await tester.pump();
        await tester.pump();
        expect(fs.listed.last, '/home/dev/app');
      });

      testWidgets('the path bar has one slash between each folder',
          (tester) async {
        fileSystem = OneFolderFs();
        manager.open(ShellTransport());
        await pumpSessions(
          tester,
          profile: profileOf([PointerDeviceKind.touch]),
        );
        for (var i = 0; i < 5; i++) {
          await tester.pump();
        }
        // "/ home / dev": the root's own crumb, then one separator.
        Finder inFiles(Finder finder) =>
            find.descendant(of: find.byType(FileBrowserPane), matching: finder);
        expect(inFiles(find.text('home')), findsOneWidget);
        expect(inFiles(find.text('/')), findsNWidgets(2));
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

      testWidgets('a 320dp phone keeps room for the host name',
          (tester) async {
        manager.open(ShellTransport(label: 'Production web'));
        var asked = 0;
        await pumpSessions(
          tester,
          profile: profileOf([PointerDeviceKind.touch]),
          size: const Size(320, 640),
          onAddSession: () => asked++,
        );
        expect(find.byTooltip('Browse files'), findsOneWidget);
        expect(find.byTooltip('Snippets'), findsNothing);
        expect(
          tester.getSize(find.text('Production web')).width,
          greaterThan(120),
        );

        await tester.tap(find.byTooltip('More'));
        await tester.pumpAndSettle();
        expect(find.text('Server stats'), findsOneWidget);
        expect(find.text('Disconnect'), findsOneWidget);
        await tester.tap(find.text('New session'));
        await tester.pumpAndSettle();
        expect(asked, 1);
      });

      testWidgets('a wider phone keeps its buttons', (tester) async {
        manager.open(ShellTransport());
        await pumpSessions(
          tester,
          profile: profileOf([PointerDeviceKind.touch]),
          size: const Size(393, 852),
        );
        expect(find.byTooltip('Snippets'), findsOneWidget);
        // The session's ⋮ menu is there at every width; here the buttons
        // stay beside it rather than moving into it.
        expect(find.byTooltip('Disconnect'), findsOneWidget);
      });

      testWidgets('touch makes a split pane\'s header a 48dp target',
          (tester) async {
        manager.open(ShellTransport(id: 'h1', label: 'Alpha'));
        manager.open(ShellTransport(id: 'h2', label: 'Beta'));
        final profile = profileOf([PointerDeviceKind.mouse]);
        await pumpSessions(tester, profile: profile);
        workspace.splitFocused(WorkspaceAxis.row);
        // Then a finger on a touch laptop: the split stays.
        profile.notePointer(PointerDeviceKind.touch);
        await tester.pump();
        await tester.pump();
        // A finger at the edge of a 48dp target, 21dp above the middle of
        // the button: inside the target, outside a 30dp strip.
        for (final (tooltip, item) in [
          ('Pane', 'Split right'),
          ('Session in this pane', 'Leave this pane empty'),
        ]) {
          final button = find.byTooltip(tooltip).first;
          await tester.tapAt(tester.getCenter(button) - const Offset(0, 21));
          await tester.pumpAndSettle();
          expect(find.text(item), findsOneWidget, reason: tooltip);
          await tester.tapAt(const Offset(5, 795));
          await tester.pumpAndSettle();
        }
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
      Future<void> chord(
        WidgetTester tester,
        LogicalKeyboardKey key, {
        bool shift = false,
      }) async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(key);
        if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        // Twice: the focus a page puts back lands after the frame.
        await tester.pump();
        await tester.pump();
      }

      testWidgets('Ctrl+Tab and Ctrl+Shift+Tab walk the tabs',
          (tester) async {
        // Three, so that the next tab and the previous one differ.
        final alpha = manager.open(ShellTransport(id: 'h1', label: 'Alpha'));
        final beta = manager.open(ShellTransport(id: 'h2', label: 'Beta'));
        final gamma = manager.open(ShellTransport(id: 'h3', label: 'Gamma'));
        manager.select(beta.id);
        await pumpSessions(
          tester,
          profile: profileOf([PointerDeviceKind.touch], keyboard: true),
        );

        await chord(tester, LogicalKeyboardKey.tab);
        expect(manager.activeId, gamma.id);
        await chord(tester, LogicalKeyboardKey.tab, shift: true);
        expect(manager.activeId, beta.id);
        await chord(tester, LogicalKeyboardKey.tab, shift: true);
        expect(manager.activeId, alpha.id);
        // And round the end.
        await chord(tester, LogicalKeyboardKey.tab, shift: true);
        expect(manager.activeId, gamma.id);
      });

      testWidgets('Ctrl+PgDn and Ctrl+PgUp are left to the shell',
          (tester) async {
        manager.open(ShellTransport(id: 'h1', label: 'Alpha'));
        final beta = manager.open(ShellTransport(id: 'h2', label: 'Beta'));
        await pumpSessions(
          tester,
          profile: profileOf([PointerDeviceKind.touch], keyboard: true),
        );
        await chord(tester, LogicalKeyboardKey.pageDown);
        expect(manager.activeId, beta.id);
        await chord(tester, LogicalKeyboardKey.pageUp);
        expect(manager.activeId, beta.id);
      });

      testWidgets('Ctrl+Shift+E goes to the files and back to the terminal',
          (tester) async {
        final alpha = manager.open(ShellTransport());
        await pumpSessions(
          tester,
          profile: profileOf([PointerDeviceKind.touch], keyboard: true),
          size: const Size(412, 915),
        );
        expect(FocusManager.instance.primaryFocus?.debugLabel, 'terminal');

        await chord(tester, LogicalKeyboardKey.keyE, shift: true);
        expect(alpha.view, SessionView.files);
        expect(find.byTooltip('Back to terminal (Ctrl+Shift+E)'),
            findsOneWidget);

        // The same chord again, with nothing clicked in between.
        await chord(tester, LogicalKeyboardKey.keyE, shift: true);
        expect(alpha.view, SessionView.terminal);
        expect(FocusManager.instance.primaryFocus?.debugLabel, 'terminal');

        await chord(tester, LogicalKeyboardKey.keyE, shift: true);
        expect(alpha.view, SessionView.files);
      });

      testWidgets('from the files, the other shortcuts still work',
          (tester) async {
        final alpha = manager.open(ShellTransport(id: 'h1', label: 'Alpha'));
        final beta = manager.open(ShellTransport(id: 'h2', label: 'Beta'));
        var asked = 0;
        await pumpSessions(
          tester,
          profile: profileOf([PointerDeviceKind.touch], keyboard: true),
          size: const Size(412, 915),
          onAddSession: () => asked++,
        );
        await chord(tester, LogicalKeyboardKey.keyE, shift: true);
        expect(beta.view, SessionView.files);

        await chord(tester, LogicalKeyboardKey.tab);
        expect(manager.activeId, alpha.id);
        // Alpha shows its terminal, so the caret goes there.
        expect(FocusManager.instance.primaryFocus?.debugLabel, 'terminal');

        // Back to Beta, which is still on its files: no terminal to type in,
        // and the keys still reach the screen.
        await chord(tester, LogicalKeyboardKey.tab);
        expect(manager.activeId, beta.id);
        await chord(tester, LogicalKeyboardKey.keyT, shift: true);
        expect(asked, 1);
      });

      testWidgets('Ctrl+Tab moves between panes rather than swapping them',
          (tester) async {
        final alpha = manager.open(ShellTransport(id: 'h1', label: 'Alpha'));
        final beta = manager.open(ShellTransport(id: 'h2', label: 'Beta'));
        final gamma = manager.open(ShellTransport(id: 'h3', label: 'Gamma'));
        await pumpSessions(
          tester,
          profile: profileOf([PointerDeviceKind.mouse], keyboard: true),
          platform: TargetPlatform.linux,
        );
        final left = workspace.focusedPaneId;
        expect(workspace.focusedSessionId, gamma.id);
        // The new pane on the right takes the first session not on screen.
        final right = workspace.splitFocused(WorkspaceAxis.row)!.id;
        await tester.pump();
        await tester.pump();
        expect(workspace.focusedSessionId, alpha.id);

        // Back from Alpha, round the end, is Gamma — in the left pane.
        await chord(tester, LogicalKeyboardKey.tab, shift: true);
        expect(workspace.focusedPaneId, left);
        expect(workspace.paneById(left)!.sessionId, gamma.id);
        expect(workspace.paneById(right)!.sessionId, alpha.id);
        expect(manager.activeId, gamma.id);

        await chord(tester, LogicalKeyboardKey.tab);
        expect(workspace.focusedPaneId, right);
        expect(workspace.paneById(left)!.sessionId, gamma.id);
        expect(workspace.paneById(right)!.sessionId, alpha.id);

        // Beta has no pane, so it comes to the one in focus.
        await chord(tester, LogicalKeyboardKey.tab);
        expect(workspace.focusedPaneId, right);
        expect(workspace.paneById(right)!.sessionId, beta.id);
        expect(workspace.paneById(left)!.sessionId, gamma.id);
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
