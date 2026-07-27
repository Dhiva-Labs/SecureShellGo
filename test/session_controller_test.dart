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

  @override
  Future<SSHSession> startShell({
    required int columns,
    required int rows,
    String terminalType = 'xterm-256color',
  }) =>
      throw UnimplementedError('the shell needs a real SSH channel');

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

  @override
  Future<String> home() async => '/home/dev';

  @override
  Future<String> resolve(String path) async => path;

  @override
  Future<List<RemoteEntry>> list(String path) async => const [];

  @override
  Future<int?> sizeOf(String path) async => bytes;

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
  Future<bool> exists(String path) async => false;

  @override
  Future<void> close() async {
    closed = true;
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

void main() {
  late FakeTransport transport;
  late FakeStorage storage;
  late FakeRemoteFs fs;
  late List<HandCrankedTimer> keepaliveTimers;

  SessionController build({FakeRemoteFs? filesystem, FakeStorage? store}) {
    fs = filesystem ?? FakeRemoteFs();
    storage = store ?? FakeStorage();
    return SessionController(
      connection: transport,
      storage: storage,
      openFileSystem: () async {
        fs.openCount++;
        return fs;
      },
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
