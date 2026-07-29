import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/models/remote_entry.dart';
import 'package:secure_shell_go/screens/file_browser_pane.dart';
import 'package:secure_shell_go/screens/session_screen.dart';
import 'package:secure_shell_go/services/device_storage.dart';
import 'package:secure_shell_go/services/session_controller.dart';
import 'package:secure_shell_go/services/session_foreground.dart';
import 'package:secure_shell_go/services/session_manager.dart';
import 'package:secure_shell_go/services/sftp_service.dart';
import 'package:secure_shell_go/services/ssh_service.dart';
import 'package:secure_shell_go/services/transfer_queue.dart';

/// A stub of the SSH transport that lets us build real ManagedSession objects
/// without opening any sockets. Copied from `session_manager_test.dart` in
/// shape — the drag-and-drop behaviour we are testing lives above the
/// transport, so the details of the fake do not matter as long as
/// [SessionManager] accepts it.
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
}

class FakeForegroundChannel implements SessionForegroundChannel {
  @override
  Future<void> start(String label) async {}

  @override
  Future<void> stop() async {}
}

/// A hand-cranked Timer: the manager just wants something to cancel on
/// dispose. The real keep-alive doesn't matter to what we're testing, and a
/// real periodic Timer would leak past the widget-test teardown.
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

/// A single remote file the drag can carry.
RemoteEntry fileEntry(String name) => RemoteEntry(
      name: name,
      path: '/home/dev/$name',
      kind: RemoteEntryKind.file,
      size: 42,
      modified: DateTime(2026, 1, 1),
    );

void main() {
  group('SessionTabStrip drop target', () {
    testWidgets(
      'dropping a payload onto another session\'s tab fires onDrop with '
      'that session and the payload',
      (tester) async {
        final manager = buildManager();
        addTearDown(manager.dispose);
        final alpha = manager.open(FakeTransport(id: 'h1', label: 'Alpha'));
        final beta = manager.open(FakeTransport(id: 'h2', label: 'Beta'));

        final drops = <(String targetId, TabDropPayload payload)>[];

        final payload = TabDropPayload(
          sourceSessionId: alpha.id,
          entries: [fileEntry('notes.txt')],
          sourceDirectory: '/home/dev',
        );

        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                SessionTabStrip(
                  sessions: manager.sessions,
                  activeId: manager.activeId,
                  compact: false,
                  onSelect: (_) {},
                  onClose: (_) {},
                  onAdd: () {},
                  onDrop: (target, p) => drops.add((target.id, p)),
                ),
                const SizedBox(height: 40),
                LongPressDraggable<TabDropPayload>(
                  data: payload,
                  feedback: const Material(
                    child: SizedBox(
                      width: 80,
                      height: 20,
                      child: Text('notes.txt'),
                    ),
                  ),
                  child: const SizedBox(
                    width: 120,
                    height: 40,
                    child: Center(child: Text('source-row')),
                  ),
                ),
              ],
            ),
          ),
        ));

        // Drag from the source row onto Beta's tab.
        final gesture = await tester.startGesture(
          tester.getCenter(find.text('source-row')),
        );
        // Wait past the long-press threshold so LongPressDraggable takes over.
        await tester.pump(kLongPressTimeout + const Duration(milliseconds: 200));
        // Small nudge to actually start the drag, then move to target.
        await gesture.moveBy(const Offset(1, 0));
        await tester.pump();
        await gesture.moveTo(tester.getCenter(find.text('Beta')));
        await tester.pump();
        await gesture.up();
        await tester.pumpAndSettle();

        expect(drops, hasLength(1));
        expect(drops.single.$1, beta.id);
        expect(drops.single.$2.sourceSessionId, alpha.id);
        expect(drops.single.$2.entries.single.name, 'notes.txt');
      },
    );

    testWidgets(
      'a drop onto the source session\'s own tab is refused',
      (tester) async {
        final manager = buildManager();
        addTearDown(manager.dispose);
        final alpha = manager.open(FakeTransport(id: 'h1', label: 'Alpha'));
        manager.open(FakeTransport(id: 'h2', label: 'Beta'));

        final drops = <(String, TabDropPayload)>[];

        final payload = TabDropPayload(
          sourceSessionId: alpha.id,
          entries: [fileEntry('notes.txt')],
          sourceDirectory: '/home/dev',
        );

        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                SessionTabStrip(
                  sessions: manager.sessions,
                  activeId: manager.activeId,
                  compact: false,
                  onSelect: (_) {},
                  onClose: (_) {},
                  onAdd: () {},
                  onDrop: (target, p) => drops.add((target.id, p)),
                ),
                const SizedBox(height: 40),
                LongPressDraggable<TabDropPayload>(
                  data: payload,
                  feedback: const Material(
                    child: SizedBox(width: 80, height: 20),
                  ),
                  child: const SizedBox(
                    width: 120,
                    height: 40,
                    child: Center(child: Text('source-row')),
                  ),
                ),
              ],
            ),
          ),
        ));

        // Drop onto Alpha's own tab.
        final gesture = await tester.startGesture(
          tester.getCenter(find.text('source-row')),
        );
        await tester.pump(kLongPressTimeout + const Duration(milliseconds: 200));
        await gesture.moveBy(const Offset(1, 0));
        await tester.pump();
        await gesture.moveTo(tester.getCenter(find.text('Alpha')));
        await tester.pump();
        await gesture.up();
        await tester.pumpAndSettle();

        // Refused: no accept fired.
        expect(drops, isEmpty);
      },
    );

    testWidgets(
      'a drop programmatically runs the shared transfer flow: pick a folder, '
      'confirm, and a transfer lands on the source session\'s queue',
      (tester) async {
        final manager = buildManager();
        addTearDown(manager.dispose);
        final alpha = manager.open(FakeTransport(id: 'h1', label: 'Alpha'));
        final beta = manager.open(FakeTransport(id: 'h2', label: 'Beta'));

        // The tab strip lives on a Navigator so pickRemoteDirectory has
        // somewhere to push.
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: Builder(builder: (context) {
              return TextButton(
                onPressed: () => sendEntriesToSession(
                  context,
                  source: alpha.controller,
                  destination: beta,
                  entries: [fileEntry('notes.txt')],
                  move: false,
                ),
                child: const Text('go'),
              );
            }),
          ),
        ));

        expect(alpha.controller.transfers.tasks, isEmpty);

        // Kick off the shared flow.
        await tester.tap(find.text('go'));
        await tester.pumpAndSettle();

        // Route pick dialog is up; confirm with "Copy".
        expect(find.text('Copy to server'), findsOneWidget);
        await tester.tap(find.text('Copy'));
        await tester.pumpAndSettle();

        // Directory picker is on screen; the home directory ("/home/dev" per
        // the stub) is already the shown path — tap "Copy here".
        expect(find.text('Copy here'), findsOneWidget);
        await tester.tap(find.text('Copy here'));
        await tester.pumpAndSettle();

        // The transfer was enqueued on Alpha's queue (the source), pointing
        // at Beta as the destination.
        final tasks = alpha.controller.transfers.tasks;
        expect(tasks, hasLength(1));
        expect(tasks.single.direction, TransferDirection.serverToServer);
        expect(tasks.single.destinationSessionId, beta.id);
        expect(tasks.single.destinationLabel, beta.host.displayName);
        expect(tasks.single.remotePath, '/home/dev/notes.txt');
      },
    );

    testWidgets(
      'a tab under a hovering payload highlights so the aim is visible',
      (tester) async {
        final manager = buildManager();
        addTearDown(manager.dispose);
        final alpha = manager.open(FakeTransport(id: 'h1', label: 'Alpha'));
        manager.open(FakeTransport(id: 'h2', label: 'Beta'));

        final payload = TabDropPayload(
          sourceSessionId: alpha.id,
          entries: [fileEntry('notes.txt')],
          sourceDirectory: '/home/dev',
        );

        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                SessionTabStrip(
                  sessions: manager.sessions,
                  activeId: manager.activeId,
                  compact: false,
                  onSelect: (_) {},
                  onClose: (_) {},
                  onAdd: () {},
                  onDrop: (_, _) {},
                ),
                const SizedBox(height: 40),
                LongPressDraggable<TabDropPayload>(
                  data: payload,
                  feedback: const Material(
                    child: SizedBox(width: 80, height: 20),
                  ),
                  child: const SizedBox(
                    width: 120,
                    height: 40,
                    child: Center(child: Text('source-row')),
                  ),
                ),
              ],
            ),
          ),
        ));

        // Before hovering, Beta's tab-Material has no border shape.
        Material materialAround(String label) {
          return tester.widget<Material>(
            find
                .ancestor(
                  of: find.text(label),
                  matching: find.byType(Material),
                )
                .first,
          );
        }

        expect(materialAround('Beta').shape, isNull);

        // Start a drag and hover over Beta.
        final gesture = await tester.startGesture(
          tester.getCenter(find.text('source-row')),
        );
        await tester.pump(kLongPressTimeout + const Duration(milliseconds: 200));
        await gesture.moveBy(const Offset(1, 0));
        await tester.pump();
        await gesture.moveTo(tester.getCenter(find.text('Beta')));
        await tester.pump();

        // Now the tab shows a border shape — the accent-coloured highlight.
        expect(materialAround('Beta').shape, isNotNull);

        // Release without dropping, then settle. (The gesture must be
        // completed or Flutter complains about a leaked timer.)
        await gesture.up();
        await tester.pumpAndSettle();
      },
    );
  });
}
