import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/models/remote_entry.dart';
import 'package:secure_shell_go/screens/workspace_view.dart';
import 'package:secure_shell_go/services/device_storage.dart';
import 'package:secure_shell_go/services/session_controller.dart';
import 'package:secure_shell_go/services/session_foreground.dart';
import 'package:secure_shell_go/services/session_manager.dart';
import 'package:secure_shell_go/services/sftp_service.dart';
import 'package:secure_shell_go/services/ssh_service.dart';
import 'package:secure_shell_go/services/terminal_workspace.dart';
import 'package:secure_shell_go/theme.dart';

/// A transport that opens no sockets. Same shape as the one in
/// `session_tab_drop_test`: the pane chrome sits far above the transport, so
/// all that matters is that [SessionManager] accepts it and that each session
/// has a distinguishable host label.
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

/// Something for the manager to cancel on dispose. A real periodic Timer
/// would outlive the widget test's teardown.
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

/// Stands in for `SessionsScreen`: subscribes to the workspace and rebuilds,
/// which is the whole of what the screen does for the pane tree.
///
/// The pane content is a marker rather than a real `TerminalPane` — this is a
/// test of the chrome, and a live terminal in it would only add an SSH channel
/// nobody reads.
class WorkspaceHarness extends StatefulWidget {
  const WorkspaceHarness({
    super.key,
    required this.workspace,
    required this.manager,
  });

  final TerminalWorkspace workspace;
  final SessionManager manager;

  @override
  State<WorkspaceHarness> createState() => _WorkspaceHarnessState();
}

class _WorkspaceHarnessState extends State<WorkspaceHarness> {
  StreamSubscription<void>? _changes;

  @override
  void initState() {
    super.initState();
    _changes = widget.workspace.changes.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _changes?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: AppTheme.dark,
      home: Scaffold(
        body: WorkspaceView(
          workspace: widget.workspace,
          sessions: widget.manager.sessions,
          onAddSession: () {},
          paneContent: (entry) => Center(child: Text('body-${entry.id}')),
        ),
      ),
    );
  }
}

/// Every pane border the view drew in the focus colour.
///
/// The focus border now resolves through `Theme.of(context).colorScheme
/// .primary` rather than the raw `AppTheme.accent` constant (v1.4.0's
/// theming wave), so the expected colour has to come from the same place:
/// `AppTheme.dark`'s own derived primary, not the seed literal it was built
/// from.
Iterable<DecoratedBox> focusBorders(WidgetTester tester) {
  final boxes = tester.widgetList<DecoratedBox>(find.byType(DecoratedBox));
  final focusColor = AppTheme.dark.colorScheme.primary;
  return boxes.where((box) {
    final decoration = box.decoration;
    return decoration is BoxDecoration &&
        decoration.border?.top.color == focusColor;
  });
}

/// The handle between two side-by-side panes, found by the cursor it asks
/// for — the divider itself is private to `workspace_view.dart`.
Finder verticalDivider() => find.byWidgetPredicate(
      (w) => w is MouseRegion && w.cursor == SystemMouseCursors.resizeColumn,
    );

void main() {
  late SessionManager manager;
  late TerminalWorkspace workspace;
  late ManagedSession alpha;
  late ManagedSession beta;

  setUp(() {
    manager = buildManager();
    workspace = TerminalWorkspace();
    alpha = manager.open(FakeTransport(id: 'h1', label: 'Alpha'));
    beta = manager.open(FakeTransport(id: 'h2', label: 'Beta'));
    workspace.syncSessions(
      manager.sessions.map((s) => s.id).toList(growable: false),
      activeId: alpha.id,
    );
  });

  tearDown(() async {
    await workspace.dispose();
    await manager.dispose();
  });

  Future<void> pumpWorkspace(WidgetTester tester) async {
    await tester.pumpWidget(
      WorkspaceHarness(workspace: workspace, manager: manager),
    );
    await tester.pump();
  }

  group('a single pane', () {
    testWidgets('draws no header, no divider and no focus border',
        (tester) async {
      await pumpWorkspace(tester);

      expect(find.text('body-${alpha.id}'), findsOneWidget);
      expect(find.byIcon(Icons.more_vert), findsNothing);
      expect(find.byIcon(Icons.arrow_drop_down), findsNothing);
      expect(focusBorders(tester), isEmpty);
    });
  });

  group('a split workspace', () {
    testWidgets('gives every pane a header naming its session',
        (tester) async {
      workspace.splitFocused(WorkspaceAxis.row);
      await pumpWorkspace(tester);

      expect(find.byIcon(Icons.more_vert), findsNWidgets(2));
      // The second pane picked up the session nothing was showing.
      expect(find.text('body-${alpha.id}'), findsOneWidget);
      expect(find.text('body-${beta.id}'), findsOneWidget);
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Beta'), findsOneWidget);
    });

    testWidgets('outlines exactly one pane as focused', (tester) async {
      workspace.splitFocused(WorkspaceAxis.row);
      await pumpWorkspace(tester);

      expect(focusBorders(tester), hasLength(1));
    });

    testWidgets('a click anywhere in a pane gives it the keyboard',
        (tester) async {
      final first = workspace.focusedPane;
      final second = workspace.splitFocused(WorkspaceAxis.row)!;
      await pumpWorkspace(tester);
      expect(workspace.focusedPaneId, second.id);

      await tester.tap(find.text('body-${alpha.id}'));
      await tester.pump();

      expect(workspace.focusedPaneId, first.id);
      expect(focusBorders(tester), hasLength(1));
    });

    testWidgets('the pane menu splits it again', (tester) async {
      workspace.splitFocused(WorkspaceAxis.row);
      await pumpWorkspace(tester);

      await tester.tap(find.byIcon(Icons.more_vert).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Split down'));
      await tester.pumpAndSettle();

      expect(workspace.paneCount, 3);
    });

    testWidgets('the pane menu closes it, and the sibling takes the space',
        (tester) async {
      final first = workspace.focusedPane;
      workspace.splitFocused(WorkspaceAxis.row);
      await pumpWorkspace(tester);

      await tester.tap(find.byIcon(Icons.more_vert).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Close pane'));
      await tester.pumpAndSettle();

      expect(workspace.paneCount, 1);
      expect(workspace.root, same(first));
      // Back to a single pane, so back to no chrome.
      expect(find.byIcon(Icons.more_vert), findsNothing);
    });

    testWidgets('splitting is offered right up to the limit, then greyed out',
        (tester) async {
      workspace.splitFocused(WorkspaceAxis.row);
      workspace.splitFocused(WorkspaceAxis.column);
      workspace.splitFocused(WorkspaceAxis.row);
      await pumpWorkspace(tester);
      expect(workspace.paneCount, TerminalWorkspace.paneLimit);

      await tester.tap(find.byIcon(Icons.more_vert).first);
      await tester.pumpAndSettle();

      // Matched by subtype rather than `byType`, which compares runtimeType
      // exactly: the menu's value type is private to `workspace_view.dart`, so
      // there is no `PopupMenuItem<…>` this test could name.
      final item = tester.widget<PopupMenuItem<Object?>>(
        find.ancestor(
          of: find.text('Split right'),
          matching: find.byWidgetPredicate((w) => w is PopupMenuItem<Object?>),
        ),
      );
      expect(item.enabled, isFalse);
    });

    testWidgets('the header picker swaps two visible sessions', (tester) async {
      final first = workspace.focusedPane;
      final second = workspace.splitFocused(WorkspaceAxis.row)!;
      await pumpWorkspace(tester);
      expect(first.sessionId, alpha.id);
      expect(second.sessionId, beta.id);

      await tester.tap(find.byIcon(Icons.arrow_drop_down).first);
      await tester.pumpAndSettle();
      // The row, not its label: a checked item lays its text out inside an
      // opacity transition that does not take pointers of its own.
      await tester.tap(
        find.ancestor(
          of: find.text('Beta'),
          matching: find.byType(CheckedPopupMenuItem<String>),
        ),
      );
      await tester.pumpAndSettle();

      expect(first.sessionId, beta.id);
      expect(second.sessionId, alpha.id);
    });

    testWidgets('dragging the divider moves it', (tester) async {
      workspace.splitFocused(WorkspaceAxis.row);
      await pumpWorkspace(tester);
      final split = workspace.root as WorkspaceSplit;
      expect(split.ratio, TerminalWorkspace.evenRatio);

      await tester.drag(verticalDivider(), const Offset(120, 0));
      await tester.pump();

      expect(split.ratio, greaterThan(0.6));
      expect(split.ratio, lessThan(0.7));
    });

    testWidgets('a divider cannot be dragged far enough to shut a pane',
        (tester) async {
      workspace.splitFocused(WorkspaceAxis.row);
      await pumpWorkspace(tester);
      final split = workspace.root as WorkspaceSplit;

      await tester.drag(verticalDivider(), const Offset(-2000, 0));
      await tester.pump();

      expect(split.ratio, TerminalWorkspace.minRatio);
    });
  });

  group('an empty pane', () {
    testWidgets('says so and offers every open session', (tester) async {
      // Three panes, two sessions: the third has nothing left to pick up.
      workspace.splitFocused(WorkspaceAxis.row);
      workspace.splitFocused(WorkspaceAxis.column);
      await pumpWorkspace(tester);
      expect(workspace.focusedPane.isEmpty, isTrue);

      expect(find.text('No session in this pane'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Alpha'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Beta'), findsOneWidget);
    });

    testWidgets('filling it from its own buttons takes the session over',
        (tester) async {
      workspace.splitFocused(WorkspaceAxis.row);
      final third = workspace.splitFocused(WorkspaceAxis.column)!;
      await pumpWorkspace(tester);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Alpha'));
      await tester.pumpAndSettle();

      expect(third.sessionId, alpha.id);
      // A session is never in two panes at once, so the pane that had it is
      // the one that is empty now.
      expect(workspace.visibleSessionIds, hasLength(2));
      expect(find.text('No session in this pane'), findsOneWidget);
    });
  });
}
