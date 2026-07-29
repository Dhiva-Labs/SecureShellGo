import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/models/remote_entry.dart';
import 'package:secure_shell_go/services/device_storage.dart';
import 'package:secure_shell_go/services/download_plan.dart';
import 'package:secure_shell_go/services/session_controller.dart';
import 'package:secure_shell_go/services/sftp_service.dart';
import 'package:secure_shell_go/services/ssh_service.dart';
import 'package:secure_shell_go/services/transfer_queue.dart';

/// Stands in for a live [SshConnection]. dartssh2's `SSHClient` cannot be
/// faked usefully, which is exactly why [SessionTransport] exists.
class FakeTransport implements SessionTransport {
  FakeTransport({this.sftpError});

  final _done = Completer<void>();
  final Object? sftpError;

  var closeCount = 0;
  var openSftpCount = 0;
  var pingCount = 0;
  var startShellCount = 0;

  @override
  final Host host = const Host(
    id: 'h1',
    label: 'Test box',
    hostname: 'example.com',
    port: 22,
    username: 'dev',
    authMethod: SshAuthMethod.password,
  );

  @override
  Future<void> get done => _done.future;

  @override
  bool get isClosed => closeCount > 0;

  /// The one thing about a shell that can be tested without a real SSH
  /// channel is *how many times it is opened*, which is the whole question
  /// once several views can come and go over one session.
  @override
  Future<SSHSession> startShell({
    required int columns,
    required int rows,
    String terminalType = 'xterm-256color',
  }) {
    startShellCount++;
    columnsAsked = columns;
    rowsAsked = rows;
    throw UnimplementedError('the shell needs a real SSH channel');
  }

  int? columnsAsked;
  int? rowsAsked;

  @override
  Future<SftpClient> openSftp() {
    openSftpCount++;
    throw UnimplementedError('tests inject a RemoteFileSystem instead');
  }

  @override
  Future<void> ping() async => pingCount++;

  @override
  void close() => closeCount++;

  /// Simulates the transport going away underneath the session.
  void dropConnection([Object? error]) {
    if (_done.isCompleted) return;
    if (error == null) {
      _done.complete();
    } else {
      _done.completeError(error);
    }
  }
}

/// A remote filesystem with scripted contents.
class FakeRemoteFs implements RemoteFileSystem {
  FakeRemoteFs({this.bytes = 300, this.failWith});

  final int bytes;
  final Object? failWith;

  var openCount = 0;
  var closed = false;
  final List<String> downloaded = [];
  final List<String> uploaded = [];

  /// Files that exist here, by path, with the size the server would report.
  /// Empty to start: the download tests script their bytes through [bytes]
  /// instead, and only the server-to-server ones care what is on disk.
  final Map<String, int> files = {};

  final List<FakeRemoteWriter> writers = [];
  final List<String> removed = [];
  final List<String> renamed = [];

  @override
  Future<String> home() async => '/home/dev';

  @override
  Future<String> resolve(String path) async => path;

  @override
  Future<List<RemoteEntry>> list(String path) async => const [];

  @override
  Future<int?> sizeOf(String path) async => files[path] ?? bytes;

  @override
  Future<RemoteFileWriter> openWrite(String remotePath) async {
    if (failWith != null) throw failWith!;
    final writer = FakeRemoteWriter(this, remotePath);
    writers.add(writer);
    return writer;
  }

  @override
  Future<void> remove(String path) async {
    removed.add(path);
    files.remove(path);
  }

  @override
  Future<void> rename(String from, String to) async {
    renamed.add('$from -> $to');
    final size = files.remove(from);
    if (size != null) files[to] = size;
  }

  @override
  Future<int> download(
    String remotePath, {
    required Future<void> Function(Uint8List chunk) write,
    TransferProgress? onProgress,
    CancelCheck? isCancelled,
  }) async {
    downloaded.add(remotePath);
    if (failWith != null) throw failWith!;

    var moved = 0;
    const chunk = 100;
    while (moved < bytes) {
      if (isCancelled?.call() ?? false) break;
      final size = (bytes - moved).clamp(0, chunk);
      await write(Uint8List(size));
      moved += size;
      onProgress?.call(moved);
      await Future<void>.delayed(Duration.zero);
    }
    return moved;
  }

  @override
  Future<int> upload(
    String localPath,
    String remotePath, {
    TransferProgress? onProgress,
    CancelCheck? isCancelled,
  }) async {
    uploaded.add(remotePath);
    if (failWith != null) throw failWith!;
    onProgress?.call(bytes);
    return bytes;
  }

  @override
  Future<bool> exists(String path) async => files.containsKey(path);

  @override
  Future<void> close() async {
    closed = true;
  }
}

/// One file being written into a [FakeRemoteFs]. Nothing is visible under the
/// path until [close], which is the property the copy logic depends on.
class FakeRemoteWriter implements RemoteFileWriter {
  FakeRemoteWriter(this._fs, this.path);

  final FakeRemoteFs _fs;
  final String path;

  var written = 0;
  var closed = false;
  var aborted = false;

  @override
  Future<void> add(Uint8List chunk) async {
    written += chunk.length;
  }

  @override
  Future<void> close() async {
    closed = true;
    _fs.files[path] = written;
  }

  @override
  Future<void> abort() async {
    aborted = true;
    _fs.files.remove(path);
  }
}

class FakeWriter implements DownloadWriter {
  FakeWriter(this.name, {this.uri});

  final String name;
  final String? uri;
  var written = 0;
  var finished = false;
  var aborted = false;

  @override
  Future<void> add(Uint8List chunk) async {
    written += chunk.length;
  }

  @override
  Future<SavedDownload> finish() async {
    finished = true;
    return SavedDownload(displayName: name, uri: uri);
  }

  @override
  Future<void> abort() async {
    aborted = true;
  }
}

class FakeStorage implements DeviceStorage {
  FakeStorage({this.permitted = true, this.existing = const {}});

  final bool permitted;
  final Set<String> existing;

  final List<FakeWriter> writers = [];
  final List<String> requestedNames = [];
  final List<bool> overwriteFlags = [];
  final List<String> relativeDirectories = [];
  final List<String> opened = [];
  PickedLocalFile? pickResult;
  List<PickedLocalFile> pickManyResult = const [];
  var canOpen = true;

  @override
  Future<bool> ensurePermission() async => permitted;

  @override
  Future<bool> downloadExists(
    String fileName, {
    String relativeDirectory = '',
  }) async =>
      existing.contains(fileName);

  @override
  Future<DownloadWriter> beginDownload(
    String fileName, {
    String? mimeType,
    bool overwrite = false,
    String relativeDirectory = '',
  }) async {
    requestedNames.add(fileName);
    overwriteFlags.add(overwrite);
    relativeDirectories.add(relativeDirectory);
    final writer = FakeWriter(
      fileName,
      uri: 'content://downloads/${writers.length}',
    );
    writers.add(writer);
    return writer;
  }

  @override
  Future<bool> openDownload(String uri, {String? mimeType}) async {
    opened.add(uri);
    return canOpen;
  }

  @override
  Future<PickedLocalFile?> pickFile() async => pickResult;

  @override
  Future<List<PickedLocalFile>> pickFiles() async => pickManyResult;

  @override
  Future<PickedTextFile?> pickTextFile({
    int maxBytes = kDefaultPickedTextFileMaxBytes,
  }) async =>
      null;
}

/// Hands the session a keep-alive timer the test drives by hand, so no test
/// here waits 30 s — or leaves a live periodic timer behind when it ends.
/// The schedule itself is covered in `session_keepalive_test.dart`.
class HandCrankedTimer implements Timer {
  HandCrankedTimer(this.callback);

  final void Function(Timer timer) callback;

  var cancelCount = 0;
  var _tick = 0;

  @override
  bool get isActive => cancelCount == 0;

  @override
  int get tick => _tick;

  @override
  void cancel() => cancelCount++;

  void fire() {
    _tick++;
    callback(this);
  }
}

/// Stands in for `_SessionScreenState`, which subscribes to the queue and
/// asks the session what to announce on every publication.
///
/// Disposable and recreatable on purpose: the real one is a widget `State`,
/// and a fold, a window resize or any other reason to rebuild the route is
/// free to replace it while the session — and the finished rows still in its
/// queue — carry on unchanged.
class AnnouncementView {
  AnnouncementView(this.session) {
    _subscription = session.transfers.changes.listen((tasks) {
      final batch = session.takeDownloadAnnouncement(tasks);
      if (batch.isNotEmpty) announcements.add(batch);
    });
  }

  final SessionController session;
  late final StreamSubscription<List<TransferTask>> _subscription;

  /// One entry per snackbar this view would have shown.
  final List<List<TransferTask>> announcements = [];

  /// The names in each announcement, which is what the snackbar reads from.
  List<List<String>> get announcedNames => announcements
      .map((batch) => batch.map((t) => t.name).toList())
      .toList();

  Future<void> dispose() => _subscription.cancel();
}

void main() {
  late FakeTransport transport;
  late FakeStorage storage;
  late FakeRemoteFs fs;
  late List<HandCrankedTimer> keepaliveTimers;

  SessionController build({
    FakeRemoteFs? filesystem,
    FakeStorage? store,
    RemoteTargetResolver? resolveRemoteTarget,
  }) {
    fs = filesystem ?? FakeRemoteFs();
    storage = store ?? FakeStorage();
    return SessionController(
      connection: transport,
      storage: storage,
      openFileSystem: () async {
        fs.openCount++;
        return fs;
      },
      resolveRemoteTarget: resolveRemoteTarget,
      keepaliveScheduler: (_, tick) {
        final timer = HandCrankedTimer(tick);
        keepaliveTimers.add(timer);
        return timer;
      },
    );
  }

  setUp(() {
    transport = FakeTransport();
    keepaliveTimers = [];
  });

  RemoteEntry file(String name, {int? size = 300}) => RemoteEntry(
        name: name,
        path: '/home/dev/$name',
        kind: RemoteEntryKind.file,
        size: size,
      );

  Future<void> settle(SessionController session) =>
      session.transfers.changes.firstWhere(
        (tasks) => tasks.isNotEmpty && tasks.every((t) => t.status.isFinished),
      );

  group('lifetime', () {
    test('starts live and reports the host', () async {
      final session = build();
      addTearDown(session.dispose);

      expect(session.isClosed, isFalse);
      expect(session.host.hostname, 'example.com');
      expect(session.closeReason, isNull);
    });

    test('a dropped transport closes the session and names the reason',
        () async {
      final session = build();
      addTearDown(session.dispose);

      final closed = session.changes.first;
      transport.dropConnection();
      await closed;

      expect(session.isClosed, isTrue);
      expect(session.closeReason, contains('closed by the remote host'));
    });

    test('an errored transport is reported as a lost connection', () async {
      final session = build();
      addTearDown(session.dispose);

      final closed = session.changes.first;
      transport.dropConnection(StateError('reset by peer'));
      await closed;

      expect(session.isClosed, isTrue);
      expect(session.closeReason, contains('Connection lost'));
    });

    test('a shell that exits does not end the session', () async {
      final session = build();
      addTearDown(session.dispose);

      session.reportShellEnded('Shell exited with status 0.');

      // The transport is still up: the file browser must keep working after a
      // plain `exit` in the terminal.
      expect(session.isClosed, isFalse);
      expect(session.closeReason, 'Shell exited with status 0.');
    });

    test('dispose closes the transport exactly once, even if called twice',
        () async {
      final session = build();
      await session.dispose();
      await session.dispose();
      expect(transport.closeCount, 1);
    });

    test('dispose closes the SFTP subsystem it opened', () async {
      final session = build();
      await session.sftp();
      await session.dispose();
      expect(fs.closed, isTrue);
    });
  });

  group('keep-alive', () {
    test('runs for as long as the session does', () async {
      final session = build();
      addTearDown(session.dispose);

      expect(session.isKeepaliveRunning, isTrue);
      expect(keepaliveTimers, hasLength(1));

      keepaliveTimers.single.fire();
      await Future<void>.delayed(Duration.zero);

      expect(transport.pingCount, 1);
    });

    test('stops when the transport drops', () async {
      final session = build();
      addTearDown(session.dispose);

      final closed = session.changes.first;
      transport.dropConnection();
      await closed;

      // The background case is the one that matters: a drop noticed while the
      // app is in another app must not leave a timer pinging a dead socket
      // until the user comes back and pops the route.
      expect(session.isKeepaliveRunning, isFalse);
      expect(keepaliveTimers.single.isActive, isFalse);
    });

    test('stops on dispose', () async {
      final session = build();
      await session.dispose();

      expect(session.isKeepaliveRunning, isFalse);
      expect(keepaliveTimers.single.isActive, isFalse);
    });

    test('a shell that exits does not stop it', () async {
      final session = build();
      addTearDown(session.dispose);

      session.reportShellEnded('Shell exited with status 0.');

      // The transport is still up — the file browser is still usable, so the
      // socket still needs holding open.
      expect(session.isKeepaliveRunning, isTrue);
    });
  });

  group('sftp', () {
    test('is opened once and shared, so switching views costs nothing',
        () async {
      final session = build();
      addTearDown(session.dispose);

      final first = await session.sftp();
      final second = await session.sftp();

      expect(identical(first, second), isTrue);
      expect(fs.openCount, 1);
      expect(transport.openSftpCount, 0);
    });

    test('concurrent callers share the same open', () async {
      final session = build();
      addTearDown(session.dispose);

      final results = await Future.wait([session.sftp(), session.sftp()]);
      expect(identical(results[0], results[1]), isTrue);
      expect(fs.openCount, 1);
    });

    test('a closed session refuses to open one', () async {
      final session = build();
      addTearDown(session.dispose);

      final closed = session.changes.first;
      transport.dropConnection();
      await closed;

      await expectLater(session.sftp(), throwsA(isA<SftpFailure>()));
    });
  });

  group('downloads', () {
    test('streams to storage, reports progress and records where it landed',
        () async {
      final session = build();
      addTearDown(session.dispose);

      final task = session.queueDownload(file('notes.txt'));
      await settle(session);

      expect(task.status, TransferStatus.completed);
      expect(task.transferredBytes, 300);
      expect(storage.requestedNames, ['notes.txt']);
      expect(storage.writers.single.written, 300);
      expect(storage.writers.single.finished, isTrue);
      expect(task.destination, 'Downloads/notes.txt');
    });

    test('a hostile remote name cannot steer where the file is saved',
        () async {
      final session = build();
      addTearDown(session.dispose);

      session.queueDownload(
        RemoteEntry(
          name: '../../evil.sh',
          path: '/tmp/../../evil.sh',
          kind: RemoteEntryKind.file,
          size: 300,
        ),
      );
      await settle(session);

      expect(storage.requestedNames, ['evil.sh']);
    });

    test('a size the listing did not carry is fetched before writing',
        () async {
      final session = build(filesystem: FakeRemoteFs(bytes: 250));
      addTearDown(session.dispose);

      final task = session.queueDownload(file('big.bin', size: null));
      await settle(session);

      expect(task.totalBytes, 250);
      expect(task.percent, 100);
    });

    test('the overwrite choice is passed through to the platform', () async {
      final session = build();
      addTearDown(session.dispose);

      session.queueDownload(file('a.txt'), overwrite: true);
      await settle(session);

      expect(storage.overwriteFlags, [true]);
    });

    test('a failed download aborts the partial file rather than publishing it',
        () async {
      final session = build(
        filesystem: FakeRemoteFs(failWith: const SftpFailure('link went down')),
      );
      addTearDown(session.dispose);

      final task = session.queueDownload(file('a.txt'));
      await settle(session);

      expect(task.status, TransferStatus.failed);
      expect(storage.writers.single.aborted, isTrue);
      expect(storage.writers.single.finished, isFalse);
    });

    test('a cancelled download aborts the partial file too', () async {
      final session = build(filesystem: FakeRemoteFs(bytes: 100000));
      addTearDown(session.dispose);

      final task = session.queueDownload(file('huge.bin', size: 100000));
      // Let it get going, then pull the plug.
      await session.transfers.changes.firstWhere(
        (tasks) => tasks.first.transferredBytes > 0,
      );
      session.transfers.cancel(task.id);
      await settle(session);

      expect(task.status, TransferStatus.cancelled);
      expect(storage.writers.single.aborted, isTrue);
      expect(storage.writers.single.finished, isFalse);
    });

    test('collision detection sanitises before asking the platform', () async {
      final session = build(store: FakeStorage(existing: {'bashrc'}));
      addTearDown(session.dispose);

      expect(await session.downloadWouldCollide('.bashrc'), isTrue);
      expect(await session.downloadWouldCollide('other'), isFalse);
    });

    test('a transfer queued after the session died fails instead of hanging',
        () async {
      final session = build();
      addTearDown(session.dispose);

      final closed = session.changes.first;
      transport.dropConnection();
      await closed;

      final task = session.queueDownload(file('a.txt'));
      await settle(session);

      // cancelAll on close claims anything already queued; anything queued
      // afterwards fails fast. Either way it does not sit at 0% forever.
      expect(task.status.isFinished, isTrue);
      expect(task.status, isNot(TransferStatus.completed));
    });
  });

  // The queue publishes through a broadcast controller, so a listener hears
  // an event a turn of the event loop after it is added. Two turns is enough
  // for a publication and anything it schedules in response.
  Future<void> deliver() async {
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  group('announcing finished downloads', () {
    test('a finished download is announced exactly once', () async {
      final session = build();
      addTearDown(session.dispose);
      final view = AnnouncementView(session);
      addTearDown(view.dispose);

      session.queueDownload(file('notes.txt'));
      await settle(session);
      await deliver();

      expect(view.announcedNames, [
        ['notes.txt'],
      ]);
    });

    test('a later publication of the same queue says nothing more', () async {
      final session = build();
      addTearDown(session.dispose);
      final view = AnnouncementView(session);
      addTearDown(view.dispose);

      session.queueDownload(file('notes.txt'));
      await settle(session);
      await deliver();

      // Anything at all that moves republishes the whole list, completed rows
      // and all. An upload is the honest version of that: several more
      // publications, none of them news about the download.
      session.queueUpload(
        const PickedLocalFile(
          path: '/data/cache/uploads/a.md',
          name: 'a.md',
          size: 300,
        ),
        '/home/dev',
      );
      await settle(session);
      await deliver();

      expect(view.announcedNames, [
        ['notes.txt'],
      ]);
    });

    test('a recreated view does not repeat what the old one announced',
        () async {
      final session = build();
      addTearDown(session.dispose);

      final first = AnnouncementView(session);
      session.queueDownload(file('notes.txt'));
      await settle(session);
      await deliver();
      expect(first.announcedNames, [
        ['notes.txt'],
      ]);

      // The compact ↔ expanded case: the widget `State` is thrown away and
      // rebuilt, and subscribes to a queue that still holds the completed
      // row. The memory of what was announced belongs to the session, so the
      // new view starts knowing.
      await first.dispose();
      final second = AnnouncementView(session);
      addTearDown(second.dispose);

      session.queueUpload(
        const PickedLocalFile(
          path: '/data/cache/uploads/a.md',
          name: 'a.md',
          size: 300,
        ),
        '/home/dev',
      );
      await settle(session);
      await deliver();

      expect(second.announcements, isEmpty);
    });

    test('a keep-alive tick does not bring the announcement back', () async {
      final session = build();
      addTearDown(session.dispose);
      final view = AnnouncementView(session);
      addTearDown(view.dispose);

      session.queueDownload(file('notes.txt'));
      await settle(session);
      await deliver();

      // 30 s of an idle session, with the completed row still in the queue.
      for (var i = 0; i < 3; i++) {
        keepaliveTimers.single.fire();
        await deliver();
      }

      expect(transport.pingCount, 3);
      expect(view.announcedNames, [
        ['notes.txt'],
      ]);
    });

    test('a whole batch is announced once, when the queue goes quiet',
        () async {
      final session = build();
      addTearDown(session.dispose);
      final view = AnnouncementView(session);
      addTearDown(view.dispose);

      session.queueDownload(file('a.txt'));
      session.queueDownload(file('b.txt'));
      session.queueDownload(file('c.txt'));
      await settle(session);
      await deliver();

      // One snackbar naming three files, not three snackbars — and nothing
      // half-announced while the second and third were still running.
      expect(view.announcedNames, [
        ['a.txt', 'b.txt', 'c.txt'],
      ]);
    });

    test('a second download later is its own announcement', () async {
      final session = build();
      addTearDown(session.dispose);
      final view = AnnouncementView(session);
      addTearDown(view.dispose);

      session.queueDownload(file('a.txt'));
      await settle(session);
      await deliver();

      session.queueDownload(file('b.txt'));
      await settle(session);
      await deliver();

      expect(view.announcedNames, [
        ['a.txt'],
        ['b.txt'],
      ]);
    });

    test('uploads are never announced as saved downloads', () async {
      final session = build();
      addTearDown(session.dispose);
      final view = AnnouncementView(session);
      addTearDown(view.dispose);

      session.queueUpload(
        const PickedLocalFile(
          path: '/data/cache/uploads/a.md',
          name: 'a.md',
          size: 300,
        ),
        '/home/dev',
      );
      await settle(session);
      await deliver();

      expect(view.announcements, isEmpty);
    });
  });

  group('uploads', () {
    test('targets the current remote directory', () async {
      final session = build();
      addTearDown(session.dispose);

      final task = session.queueUpload(
        const PickedLocalFile(
          path: '/data/cache/uploads/notes.md',
          name: 'notes.md',
          size: 300,
        ),
        '/home/dev/src',
      );
      await settle(session);

      expect(task.status, TransferStatus.completed);
      expect(task.remotePath, '/home/dev/src/notes.md');
      expect(fs.uploaded, ['/home/dev/src/notes.md']);
      expect(task.destination, '/home/dev/src/notes.md');
    });

    test('a "keep both" name is what lands on the server', () async {
      final session = build();
      addTearDown(session.dispose);

      final task = session.queueUpload(
        const PickedLocalFile(
          path: '/data/cache/uploads/b1/0/notes.md',
          name: 'notes.md',
          size: 300,
        ),
        '/home/dev/src',
        asName: 'notes (1).md',
      );
      await settle(session);

      expect(task.name, 'notes (1).md');
      expect(fs.uploaded, ['/home/dev/src/notes (1).md']);
    });

    test('the multi-file picker is passed straight through', () async {
      final session = build(
        store: FakeStorage()
          ..pickManyResult = const [
            PickedLocalFile(path: '/c/0/a.txt', name: 'a.txt', size: 1),
            PickedLocalFile(path: '/c/1/b.txt', name: 'b.txt', size: 2),
          ],
      );
      addTearDown(session.dispose);

      final picked = await session.pickLocalFiles();
      expect(picked.map((f) => f.name), ['a.txt', 'b.txt']);
    });
  });

  group('shared-in uploads', () {
    test('a request is held for a pane that may not exist yet', () async {
      final session = build();
      addTearDown(session.dispose);

      expect(session.pendingUpload, isNull);

      final notified = session.changes.first;
      session.requestUpload(const [
        PickedLocalFile(path: '/c/0/a.txt', name: 'a.txt', size: 10),
        PickedLocalFile(path: '/c/1/b.txt', name: 'b.txt', size: 20),
      ]);
      await notified;

      expect(session.pendingUpload!.count, 2);
      expect(session.pendingUpload!.totalBytes, 30);
    });

    test('an empty request is not a request', () async {
      final session = build();
      addTearDown(session.dispose);

      session.requestUpload(const []);
      expect(session.pendingUpload, isNull);
    });

    test('clearing it tells the panes to stop showing the banner', () async {
      final session = build();
      addTearDown(session.dispose);

      session.requestUpload(const [
        PickedLocalFile(path: '/c/0/a.txt', name: 'a.txt', size: 10),
      ]);
      final notified = session.changes.first;
      session.clearPendingUpload();
      await notified;

      expect(session.pendingUpload, isNull);
    });
  });

  group('directory downloads', () {
    test('each planned file keeps its subdirectory under Downloads', () async {
      final session = build();
      addTearDown(session.dispose);

      final task = session.queuePlannedDownload(
        const PlannedDownload(
          remotePath: '/home/dev/project/src/main.dart',
          fileName: 'main.dart',
          relativeDirectory: 'project/src',
          size: 300,
        ),
      );
      await settle(session);

      expect(task.status, TransferStatus.completed);
      expect(storage.relativeDirectories, ['project/src']);
      expect(task.destination, 'Downloads/project/src/main.dart');
    });

    test('a single-file download still goes straight into Downloads',
        () async {
      final session = build();
      addTearDown(session.dispose);

      session.queueDownload(file('notes.txt'));
      await settle(session);

      expect(storage.relativeDirectories, ['']);
    });
  });

  group('server-to-server transfers', () {
    late FakeTransport destinationTransport;
    late FakeRemoteFs destinationFs;
    late SessionController destination;

    /// A source session wired to a second, live session as its destination —
    /// the shape `SessionManager` builds in production.
    SessionController buildWithDestination({FakeRemoteFs? sourceFs}) {
      destinationTransport = FakeTransport();
      destinationFs = FakeRemoteFs(bytes: 0);
      destination = SessionController(
        connection: destinationTransport,
        storage: FakeStorage(),
        openFileSystem: () async => destinationFs,
        keepaliveScheduler: (_, tick) {
          final timer = HandCrankedTimer(tick);
          keepaliveTimers.add(timer);
          return timer;
        },
      );
      addTearDown(destination.dispose);
      return build(
        filesystem: sourceFs,
        resolveRemoteTarget: (_) async => destination,
      );
    }

    TransferTask queueCopy(
      SessionController session, {
      bool move = false,
      int? totalBytes = 300,
    }) {
      return session.queueRemoteCopy(
        remotePath: '/srv/a/report.pdf',
        name: 'report.pdf',
        destinationSessionId: 'session-1',
        destinationLabel: 'build-box',
        remoteDirectory: '/srv/b',
        moveSource: move,
        totalBytes: totalBytes,
      );
    }

    test('streams to the other session and says where it landed', () async {
      final session = buildWithDestination();
      addTearDown(session.dispose);

      final task = queueCopy(session);
      await settle(session);

      expect(task.status, TransferStatus.completed);
      expect(task.direction, TransferDirection.serverToServer);
      expect(task.transferredBytes, 300);
      expect(destinationFs.files['/srv/b/report.pdf'], 300);
      // Named with the host, because a bare path is ambiguous the moment
      // there are two servers in play.
      expect(task.destination, 'build-box:/srv/b/report.pdf');
    });

    test('the destination path is built from the directory and the name',
        () async {
      final session = buildWithDestination();
      addTearDown(session.dispose);

      final task = session.queueRemoteCopy(
        remotePath: '/srv/a/report.pdf',
        name: 'report.pdf',
        destinationSessionId: 'session-1',
        destinationLabel: 'build-box',
        remoteDirectory: '/srv/b',
        // "Keep both" resolved the collision to a different name over there.
        asName: 'report (1).pdf',
      );

      expect(task.destinationPath, '/srv/b/report (1).pdf');
      expect(task.name, 'report (1).pdf');
      await settle(session);
      expect(destinationFs.files.keys, ['/srv/b/report (1).pdf']);
    });

    test('nothing is published under the final name until it is complete',
        () async {
      final session = buildWithDestination();
      addTearDown(session.dispose);

      queueCopy(session);
      await settle(session);

      // One temporary file, renamed into place exactly once.
      expect(destinationFs.renamed, hasLength(1));
      expect(
        destinationFs.renamed.single,
        endsWith('-> /srv/b/report.pdf'),
      );
    });

    test('a move deletes the source only after the copy is verified',
        () async {
      final session = buildWithDestination();
      addTearDown(session.dispose);

      final task = queueCopy(session, move: true);
      await settle(session);

      expect(task.status, TransferStatus.completed);
      expect(fs.removed, ['/srv/a/report.pdf']);
      expect(destinationFs.files['/srv/b/report.pdf'], 300);
    });

    test('a copy leaves the source alone', () async {
      final session = buildWithDestination();
      addTearDown(session.dispose);

      queueCopy(session);
      await settle(session);

      expect(fs.removed, isEmpty);
    });

    test('the destination session is told something landed on it', () async {
      final session = buildWithDestination();
      addTearDown(session.dispose);

      // The destination's file browser is a different pane on a different
      // session with no sight of this queue, so it is told directly.
      final arrival = destination.arrivals.first;
      queueCopy(session);
      await settle(session);

      expect(await arrival, '/srv/b');
    });

    test('a cancel mid-copy leaves nothing on the destination', () async {
      final session = buildWithDestination(
        sourceFs: FakeRemoteFs(bytes: 100000),
      );
      addTearDown(session.dispose);

      final task = queueCopy(session, totalBytes: 100000);
      await session.transfers.changes.firstWhere(
        (tasks) => tasks.first.transferredBytes > 0,
      );
      session.transfers.cancel(task.id);
      await settle(session);

      expect(task.status, TransferStatus.cancelled);
      expect(destinationFs.files, isEmpty);
      expect(destinationFs.writers.single.aborted, isTrue);
      // A cancelled move is not a move.
      expect(fs.removed, isEmpty);
    });

    test('a session with nowhere to send fails the transfer rather than '
        'hanging', () async {
      // No resolver at all: the manager only supplies one, so this is a
      // session built outside it.
      final session = build();
      addTearDown(session.dispose);

      final task = queueCopy(session);
      await settle(session);

      expect(session.canTransferToOtherSessions, isFalse);
      expect(task.status, TransferStatus.failed);
      expect(task.error, contains('no destination server'));
    });

    test('a destination that refuses to open the file fails the transfer',
        () async {
      final session = build(
        resolveRemoteTarget: (_) async {
          final broken = SessionController(
            connection: FakeTransport(),
            storage: FakeStorage(),
            openFileSystem: () async =>
                FakeRemoteFs(failWith: const SftpFailure('Permission denied.')),
            keepaliveScheduler: (_, tick) {
              final timer = HandCrankedTimer(tick);
              keepaliveTimers.add(timer);
              return timer;
            },
          );
          addTearDown(broken.dispose);
          return broken;
        },
      );
      addTearDown(session.dispose);

      final task = queueCopy(session);
      await settle(session);

      expect(task.status, TransferStatus.failed);
      expect(task.error, contains('Permission denied'));
    });
  });

  group('the shell and its buffer', () {
    test('the terminal belongs to the session, so a new view finds it filled',
        () async {
      final session = build();
      addTearDown(session.dispose);

      // A view is free to be destroyed and rebuilt — a fold, a window resize,
      // or leaving the sessions screen for the host list to open a second
      // server. Whatever it reattaches to has to be the same buffer.
      final terminal = session.terminal;
      terminal.write('hello from the shell');

      expect(identical(session.terminal, terminal), isTrue);
      expect(
        session.terminal.buffer.getText().contains('hello from the shell'),
        isTrue,
      );
    });

    test('the shell is opened once, however many views ask for it', () async {
      final session = build();
      addTearDown(session.dispose);

      // The size a view reports is what the PTY is created at.
      session.terminal.resize(120, 40);

      await session.ensureShell();
      await session.ensureShell();

      // Two opens would mean two subscriptions to one `SSHSession.stdout`,
      // which throws "Stream has already been listened to" and leaves the
      // user looking at an error instead of their shell. Observed on the
      // emulator before the buffer moved onto the session.
      expect(transport.startShellCount, 1);
      expect(transport.columnsAsked, 120);
      expect(transport.rowsAsked, 40);
    });

    test('a shell that will not open is reported without ending the session',
        () async {
      final session = build();
      addTearDown(session.dispose);
      session.terminal.resize(80, 24);

      await session.ensureShell();

      expect(session.isShellReady, isTrue);
      expect(session.shellError, contains('real SSH channel'));
      expect(
        session.terminal.buffer.getText().contains('Failed to open a shell'),
        isTrue,
      );
      // The transport is fine; the file browser must still work.
      expect(session.isClosed, isFalse);
    });
  });

  group('announcing a disconnect', () {
    test('a live session has nothing to announce', () async {
      final session = build();
      addTearDown(session.dispose);

      expect(session.takeDisconnectAnnouncement(), isNull);
    });

    test('a drop is announced exactly once, however often it is asked',
        () async {
      final session = build();
      addTearDown(session.dispose);

      final closed = session.changes.first;
      transport.dropConnection();
      await closed;

      expect(
        session.takeDisconnectAnnouncement(),
        contains('closed by the remote host'),
      );
      // The banner stays up and the view rebuilds many times behind it; the
      // snackbar must not come back with every one of them, and a `State`
      // replaced by a fold must not start over with an empty memory.
      expect(session.takeDisconnectAnnouncement(), isNull);
    });
  });

  group('opening a finished download', () {
    test('hands the saved URI to the platform', () async {
      final session = build();
      addTearDown(session.dispose);

      final task = session.queueDownload(file('notes.txt'));
      await settle(session);

      expect(task.destinationUri, 'content://downloads/0');
      expect(await session.openDownload(task), isTrue);
      expect(storage.opened, ['content://downloads/0']);
    });

    test('a transfer with nowhere to point reports false without a call',
        () async {
      final session = build();
      addTearDown(session.dispose);

      final task = session.queueUpload(
        const PickedLocalFile(path: '/c/0/a.txt', name: 'a.txt', size: 1),
        '/home/dev',
      );
      await settle(session);

      expect(await session.openDownload(task), isFalse);
      expect(storage.opened, isEmpty);
    });
  });
}
