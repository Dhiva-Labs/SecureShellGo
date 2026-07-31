import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/models/remote_entry.dart';
import 'package:secure_shell_go/screens/session_screen.dart';
import 'package:secure_shell_go/screens/terminal_pane.dart';
import 'package:secure_shell_go/services/device_storage.dart';
import 'package:secure_shell_go/services/keep_awake.dart';
import 'package:secure_shell_go/services/session_controller.dart';
import 'package:secure_shell_go/services/session_foreground.dart';
import 'package:secure_shell_go/services/session_manager.dart';
import 'package:secure_shell_go/services/settings_store.dart';
import 'package:secure_shell_go/services/sftp_service.dart';
import 'package:secure_shell_go/services/ssh_service.dart';
import 'package:secure_shell_go/services/terminal_workspace.dart';

/// A transport that opens no sockets — same stub the other session widget
/// tests use. The shell never opens, which the screen handles: the pane shows
/// its "could not open a shell" state and everything above it carries on.
class FakeTransport implements SessionTransport {
  FakeTransport({
    String id = 'h1',
    String label = 'Alpha',
    String hostname = 'alpha.example.com',
  }) : host = Host(
          id: id,
          label: label,
          hostname: hostname,
          port: 22,
          username: 'dev',
          authMethod: SshAuthMethod.password,
        );

  final _done = Completer<void>();

  @override
  final Host host;

  var closeCount = 0;

  @override
  Future<void> get done => _done.future;

  @override
  bool get isClosed => closeCount > 0;

  @override
  Future<SSHSession> startShell({
    required int columns,
    required int rows,
    String terminalType = 'xterm-256color',
  }) =>
      throw UnimplementedError();

  @override
  Future<SftpClient> openSftp() => throw UnimplementedError();

  @override
  Future<SSHSession> execute(String command) => throw UnimplementedError();

  @override
  MutableSSHAgentHandler get agentSlot => _agentSlot;
  final _agentSlot = MutableSSHAgentHandler();

  @override
  Future<void> ping() async {}

  @override
  void close() => closeCount++;
}

class StubFs implements RemoteFileSystem {
  @override
  Future<String> home() async => '/home/dev';

  @override
  Future<String> resolve(String path) async => path;

  @override
  Future<List<RemoteEntry>> list(String path) async => const [];

  @override
  Future<int?> sizeOf(String path) async => 0;

  @override
  Future<int> download(
    String remotePath, {
    required Future<void> Function(Uint8List chunk) write,
    TransferProgress? onProgress,
    CancelCheck? isCancelled,
  }) async =>
      0;

  @override
  Future<int> upload(
    String localPath,
    String remotePath, {
    TransferProgress? onProgress,
    CancelCheck? isCancelled,
  }) async =>
      0;

  @override
  Future<bool> exists(String path) async => false;

  @override
  Future<void> mkdir(String path) async {}

  @override
  Future<void> removeDirectory(String path) async {}

  @override
  Future<bool> isDirectory(String path) async => false;

  @override
  Future<RemoteFileWriter> openWrite(String remotePath) async =>
      throw UnimplementedError();

  @override
  Future<void> remove(String path) async {}

  @override
  Future<void> rename(String from, String to) async {}

  @override
  Future<void> close() async {}
}

class StubStorage implements DeviceStorage {
  @override
  Future<bool> ensurePermission() async => true;

  @override
  Future<bool> downloadExists(
    String fileName, {
    String relativeDirectory = '',
  }) async =>
      false;

  @override
  Future<DownloadWriter> beginDownload(
    String fileName, {
    String? mimeType,
    bool overwrite = false,
    String relativeDirectory = '',
  }) async =>
      throw UnimplementedError();

  @override
  Future<bool> openDownload(String uri, {String? mimeType}) async => false;

  @override
  Future<PickedLocalFile?> pickFile() async => null;

  @override
  Future<List<PickedLocalFile>> pickFiles() async => const [];

  @override
  Future<PickedTextFile?> pickTextFile({
    int maxBytes = kDefaultPickedTextFileMaxBytes,
  }) async =>
      null;

  @override
  Future<PickedLocalDirectory?> pickDirectory() async => null;
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
  var _cancelled = false;

  @override
  bool get isActive => !_cancelled;

  @override
  int get tick => 0;

  @override
  void cancel() => _cancelled = true;
}

SessionManager buildManager() {
  return SessionManager(
    foreground: SessionForegroundController(channel: FakeForegroundChannel()),
    createController: (connection, resolve, resolveCreds) => SessionController(
      connection: connection,
      storage: StubStorage(),
      openFileSystem: () async => StubFs(),
      resolveRemoteTarget: resolve,
      resolveDestinationCredentials: resolveCreds,
      keepaliveScheduler: (_, _) => NoopTimer(),
    ),
  );
}

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

  /// The screen reads the platform through the theme (same as
  /// `FileBrowserPane`), so a test picks one by handing it a theme rather than
  /// by setting `debugDefaultTargetPlatformOverride` — which the framework
  /// checks has been put back *before* `tearDown` gets a chance to.
  Future<void> pumpScreen(WidgetTester tester, TargetPlatform platform) async {
    // A desktop window, not the 800x600 phone-shaped default: the file
    // browser's action row does not fit in two fifths of 800dp, and a
    // workspace is a thing you only get on a screen with room for one.
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(platform: platform),
      home: SessionsScreen(
        sessions: manager,
        settingsStore: settings,
        workspace: workspace,
        keepAwake: NoopKeepAwake(),
      ),
    ));
    await tester.pump();
  }

  group('the platform gate', () {
    testWidgets('Android gets the tabbed layout, with nothing to split',
        (tester) async {
      manager.open(FakeTransport(id: 'h1', label: 'Alpha'));

      await pumpScreen(tester, TargetPlatform.android);

      expect(find.byIcon(Icons.splitscreen_outlined), findsNothing);
      // The workspace was never even told what is open.
      expect(workspace.visibleSessionIds, isEmpty);
      expect(find.byType(TerminalPane), findsOneWidget);
    });

    testWidgets('desktop offers the split menu and adopts the session',
        (tester) async {
      final alpha = manager.open(FakeTransport(id: 'h1', label: 'Alpha'));

      await pumpScreen(tester, TargetPlatform.linux);

      expect(find.byIcon(Icons.splitscreen_outlined), findsOneWidget);
      expect(workspace.focusedSessionId, alpha.id);
      // One pane still means no pane chrome.
      expect(find.byIcon(Icons.more_vert), findsNothing);
    });
  });

  group('the desktop workspace', () {
    testWidgets('every session is built, whether or not it has a pane',
        (tester) async {
      manager.open(FakeTransport(id: 'h1', label: 'Alpha'));
      manager.open(FakeTransport(id: 'h2', label: 'Beta'));

      await pumpScreen(tester, TargetPlatform.linux);

      // One in the pane, one behind it — laid out, unpainted, still running.
      expect(workspace.visibleSessionIds, hasLength(1));
      expect(find.byType(TerminalPane), findsNWidgets(2));
    });

    testWidgets('the app bar splits the focused pane in two', (tester) async {
      manager.open(FakeTransport(id: 'h1', label: 'Alpha'));
      manager.open(FakeTransport(id: 'h2', label: 'Beta'));
      await pumpScreen(tester, TargetPlatform.linux);

      await tester.tap(find.byIcon(Icons.splitscreen_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Split right'));
      await tester.pumpAndSettle();

      expect(workspace.paneCount, 2);
      // Both servers on screen at once, which is the whole point.
      expect(workspace.visibleSessionIds, hasLength(2));
      expect(find.byIcon(Icons.more_vert), findsNWidgets(2));
      expect(find.byType(TerminalPane), findsNWidgets(2));
    });

    testWidgets('a session opened while split lands in the focused pane',
        (tester) async {
      manager.open(FakeTransport(id: 'h1', label: 'Alpha'));
      await pumpScreen(tester, TargetPlatform.linux);
      workspace.splitFocused(WorkspaceAxis.row);
      await tester.pumpAndSettle();
      final focusedPane = workspace.focusedPaneId;

      final gamma = manager.open(FakeTransport(id: 'h3', label: 'Gamma'));
      await tester.pumpAndSettle();

      expect(workspace.paneById(focusedPane)!.sessionId, gamma.id);
    });

    testWidgets('closing a pane keeps its session connected', (tester) async {
      manager.open(FakeTransport(id: 'h1', label: 'Alpha'));
      manager.open(FakeTransport(id: 'h2', label: 'Beta'));
      await pumpScreen(tester, TargetPlatform.linux);
      final second = workspace.splitFocused(WorkspaceAxis.row)!;
      await tester.pumpAndSettle();
      expect(workspace.visibleSessionIds, hasLength(2));

      workspace.closePane(second.id);
      await tester.pumpAndSettle();

      expect(workspace.paneCount, 1);
      // Two tabs still, two live sessions still: a pane is not a session.
      expect(manager.length, 2);
      expect(manager.liveCount, 2);
      expect(find.byType(TerminalPane), findsNWidgets(2));
    });

    testWidgets('the focused pane is what the app bar calls active',
        (tester) async {
      final alpha = manager.open(FakeTransport(id: 'h1', label: 'Alpha'));
      final beta = manager.open(FakeTransport(id: 'h2', label: 'Beta'));
      await pumpScreen(tester, TargetPlatform.linux);
      // The screen adopted whichever session was in front.
      expect(workspace.focusedSessionId, beta.id);

      // A new pane fills itself with the session nothing was showing, and
      // takes the focus — so the app bar follows it there.
      final second = workspace.splitFocused(WorkspaceAxis.row)!;
      await tester.pumpAndSettle();
      expect(second.sessionId, alpha.id);
      expect(manager.activeId, alpha.id);

      workspace.focusPane(workspace.panes.first.id);
      await tester.pumpAndSettle();

      expect(manager.activeId, beta.id);
    });
  });
}
