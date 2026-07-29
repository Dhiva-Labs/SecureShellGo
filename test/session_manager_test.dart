import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/models/remote_entry.dart';
import 'package:secure_shell_go/services/device_storage.dart';
import 'package:secure_shell_go/services/session_controller.dart';
import 'package:secure_shell_go/services/session_foreground.dart';
import 'package:secure_shell_go/services/session_manager.dart';
import 'package:secure_shell_go/services/sftp_service.dart';
import 'package:secure_shell_go/services/ssh_service.dart';
import 'package:secure_shell_go/services/transfer_queue.dart';

/// One fake connection. Several of these is the whole point of this file.
class FakeTransport implements SessionTransport {
  FakeTransport({
    String id = 'h1',
    String label = 'Test box',
    String hostname = 'example.com',
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
  var pingCount = 0;

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
  Future<SftpClient> openSftp() =>
      throw UnimplementedError('tests inject a RemoteFileSystem instead');

  @override
  Future<SSHSession> execute(String command) =>
      throw UnimplementedError('exec needs a real SSH channel');

  @override
  MutableSSHAgentHandler get agentSlot => _agentSlot;
  final _agentSlot = MutableSSHAgentHandler();

  @override
  Future<void> ping() async => pingCount++;

  @override
  void close() => closeCount++;

  void drop() {
    if (!_done.isCompleted) _done.complete();
  }
}

/// Enough of a filesystem for a session to hand one out, and for a
/// server-to-server transfer between two of them to run end to end.
///
/// Empty files: what these tests are about is which session a transfer
/// reaches, not what it carries. `remote_copy_test.dart` is where the bytes
/// are checked.
class StubFs implements RemoteFileSystem {
  var closed = false;

  final Map<String, int> files = {};

  @override
  Future<String> home() async => '/home/dev';

  @override
  Future<String> resolve(String path) async => path;

  @override
  Future<List<RemoteEntry>> list(String path) async => const [];

  @override
  Future<int?> sizeOf(String path) async => files[path] ?? 0;

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
      StubWriter(this, remotePath);

  @override
  Future<void> remove(String path) async => files.remove(path);

  @override
  Future<void> rename(String from, String to) async {
    final size = files.remove(from);
    if (size != null) files[to] = size;
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

class StubWriter implements RemoteFileWriter {
  StubWriter(this._fs, this._path);

  final StubFs _fs;
  final String _path;
  var _written = 0;

  @override
  Future<void> add(Uint8List chunk) async => _written += chunk.length;

  @override
  Future<void> close() async => _fs.files[_path] = _written;

  @override
  Future<void> abort() async => _fs.files.remove(_path);
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

/// Records what the foreground service was asked to do, in order.
class FakeForegroundChannel implements SessionForegroundChannel {
  final List<String> calls = [];
  final List<String> labels = [];

  @override
  Future<void> start(String label) async {
    calls.add('start');
    labels.add(label);
  }

  @override
  Future<void> stop() async => calls.add('stop');
}

/// A keep-alive timer the test drives, so nothing here waits 30 s or leaves a
/// live periodic timer behind.
class HandCrankedTimer implements Timer {
  HandCrankedTimer(this.callback);

  final void Function(Timer timer) callback;

  var cancelCount = 0;

  @override
  bool get isActive => cancelCount == 0;

  @override
  int get tick => 0;

  @override
  void cancel() => cancelCount++;

  void fire() => callback(this);
}

void main() {
  late FakeForegroundChannel channel;
  late SessionForegroundController foreground;
  late List<HandCrankedTimer> timers;
  late Map<SessionController, StubFs> filesystems;

  SessionManager buildManager() {
    return SessionManager(
      foreground: foreground,
      createController: (connection, resolve, resolveCreds) {
        final fs = StubFs();
        late final SessionController controller;
        controller = SessionController(
          connection: connection,
          storage: StubStorage(),
          openFileSystem: () async => fs,
          resolveRemoteTarget: resolve,
          resolveDestinationCredentials: resolveCreds,
          keepaliveScheduler: (_, tick) {
            final timer = HandCrankedTimer(tick);
            timers.add(timer);
            return timer;
          },
        );
        filesystems[controller] = fs;
        return controller;
      },
    );
  }

  setUp(() {
    channel = FakeForegroundChannel();
    foreground = SessionForegroundController(channel: channel);
    timers = [];
    filesystems = {};
  });

  /// The foreground controller chains its platform calls onto one future, so
  /// a couple of turns of the event loop is what it takes for them to land.
  Future<void> settle() async {
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  group('opening', () {
    test('the first session becomes the active one', () async {
      final manager = buildManager();
      addTearDown(manager.dispose);

      final entry = manager.open(FakeTransport());

      expect(manager.length, 1);
      expect(manager.activeId, entry.id);
      expect(manager.active, same(entry));
      expect(entry.host.hostname, 'example.com');
    });

    test('a second session joins the list and takes the front', () async {
      final manager = buildManager();
      addTearDown(manager.dispose);

      final first = manager.open(FakeTransport(id: 'h1', label: 'alpha'));
      final second = manager.open(FakeTransport(id: 'h2', label: 'beta'));

      expect(manager.sessions.map((s) => s.id), [first.id, second.id]);
      expect(manager.activeId, second.id);
      // The first one is untouched by the second opening.
      expect(first.isClosed, isFalse);
      expect(first.controller.isKeepaliveRunning, isTrue);
    });

    test('a second session to the same host is allowed, and is its own',
        () async {
      final manager = buildManager();
      addTearDown(manager.dispose);

      final first = manager.open(FakeTransport(id: 'h1', label: 'alpha'));
      final second = manager.open(FakeTransport(id: 'h1', label: 'alpha'));

      expect(first.id, isNot(second.id));
      expect(manager.liveForHost('h1').map((s) => s.id), [
        first.id,
        second.id,
      ]);
      expect(identical(first.controller, second.controller), isFalse);
    });

    test('a session opened with shared files starts on the file browser',
        () async {
      final manager = buildManager();
      addTearDown(manager.dispose);

      final entry = manager.open(
        FakeTransport(),
        uploads: const [
          PickedLocalFile(path: '/c/0/a.txt', name: 'a.txt', size: 10),
        ],
      );

      expect(entry.view, SessionView.files);
      expect(entry.filesBuilt, isTrue);
      expect(entry.controller.pendingUpload!.count, 1);
    });
  });

  group('the foreground service', () {
    test('the first session starts it, named after the host', () async {
      final manager = buildManager();
      addTearDown(manager.dispose);

      manager.open(FakeTransport(label: 'MyLinuxPC'));
      await settle();

      expect(channel.calls, ['start']);
      expect(channel.labels, ['MyLinuxPC']);
      expect(foreground.holders, 1);
    });

    test('a second session counts, and the notification says how many',
        () async {
      final manager = buildManager();
      addTearDown(manager.dispose);

      manager.open(FakeTransport(id: 'h1', label: 'MyLinuxPC'));
      manager.open(FakeTransport(id: 'h2', label: 'build-box'));
      await settle();

      // Two holders, one service, and a label that is true of both — naming
      // the first of two reads as it being the only one.
      expect(foreground.holders, 2);
      expect(channel.calls, ['start', 'start']);
      expect(channel.labels, ['MyLinuxPC', '2 sessions connected']);
    });

    test('closing one of two leaves it running, named after the survivor',
        () async {
      final manager = buildManager();
      addTearDown(manager.dispose);

      final first = manager.open(FakeTransport(id: 'h1', label: 'MyLinuxPC'));
      manager.open(FakeTransport(id: 'h2', label: 'build-box'));
      await settle();

      await manager.close(first.id);
      await settle();

      expect(channel.calls, isNot(contains('stop')));
      expect(foreground.holders, 1);
      expect(channel.labels.last, 'build-box');
    });

    test('closing the last one stops it', () async {
      final manager = buildManager();
      addTearDown(manager.dispose);

      final first = manager.open(FakeTransport(id: 'h1', label: 'MyLinuxPC'));
      final second = manager.open(FakeTransport(id: 'h2', label: 'build-box'));
      await settle();

      await manager.close(first.id);
      await manager.close(second.id);
      await settle();

      expect(channel.calls.last, 'stop');
      expect(foreground.holders, isZero);
      expect(manager.isEmpty, isTrue);
    });

    test('a third session relabels once, not once per session', () async {
      final manager = buildManager();
      addTearDown(manager.dispose);

      manager.open(FakeTransport(id: 'h1', label: 'a'));
      manager.open(FakeTransport(id: 'h2', label: 'b'));
      manager.open(FakeTransport(id: 'h3', label: 'c'));
      await settle();

      expect(channel.labels, ['a', '2 sessions connected', '3 sessions connected']);
    });

    test('a dropped transport still holds the service until the tab closes',
        () async {
      // The hold follows the *session*, not the connection: a dropped session
      // is still a tab on screen with a banner on it, and the process has to
      // stay alive long enough for the user to see that.
      final manager = buildManager();
      addTearDown(manager.dispose);

      final transport = FakeTransport();
      final entry = manager.open(transport);
      await settle();

      transport.drop();
      await entry.controller.changes.first;
      await settle();

      expect(foreground.holders, 1);
      expect(channel.calls, ['start']);

      await manager.close(entry.id);
      await settle();
      expect(channel.calls, ['start', 'stop']);
    });
  });

  group('switching between sessions', () {
    test('selecting one leaves every other session alone', () async {
      final manager = buildManager();
      addTearDown(manager.dispose);

      final first = manager.open(FakeTransport(id: 'h1'));
      final second = manager.open(FakeTransport(id: 'h2'));
      final firstSftp = await first.controller.sftp();

      manager.select(first.id);

      expect(manager.activeId, first.id);
      expect(second.isClosed, isFalse);
      expect(second.controller.isKeepaliveRunning, isTrue);
      // The channel the background session opened is still the same one — a
      // switch must not cost a reconnect or a second SFTP open.
      expect(identical(await first.controller.sftp(), firstSftp), isTrue);
      expect(filesystems[second.controller]!.closed, isFalse);
    });

    test('the view each session is showing is its own', () async {
      final manager = buildManager();
      addTearDown(manager.dispose);

      final first = manager.open(FakeTransport(id: 'h1'));
      final second = manager.open(FakeTransport(id: 'h2'));

      manager.showView(first.id, SessionView.files);

      expect(first.view, SessionView.files);
      expect(first.filesBuilt, isTrue);
      // Before this lived on the manager it was a field on the screen, and
      // this is exactly what that cost: switching tabs reshuffled the other
      // session's panes.
      expect(second.view, SessionView.terminal);
      expect(second.filesBuilt, isFalse);
    });

    test('selecting an unknown id changes nothing', () async {
      final manager = buildManager();
      addTearDown(manager.dispose);

      final entry = manager.open(FakeTransport());
      manager.select('session-nope');

      expect(manager.activeId, entry.id);
    });

    test('a change anywhere reaches one listener on the manager', () async {
      final manager = buildManager();
      addTearDown(manager.dispose);

      manager.open(FakeTransport(id: 'h1'));
      final background = manager.open(FakeTransport(id: 'h2'));
      manager.select(manager.sessions.first.id);

      final notified = manager.changes.first;
      // A drop on the session that is *not* in front: its tab still has to
      // repaint its status dot, which is why the manager folds every
      // session's own stream into its own.
      background.controller.reportShellEnded('Shell exited with status 0.');
      await notified;
    });
  });

  group('closing', () {
    test('closing one session does not disturb the others', () async {
      final manager = buildManager();
      addTearDown(manager.dispose);

      final first = manager.open(FakeTransport(id: 'h1'));
      final firstTransport = FakeTransport(id: 'h2');
      final second = manager.open(firstTransport);

      await manager.close(first.id);

      expect(manager.length, 1);
      expect(manager.sessions.single.id, second.id);
      expect(second.isClosed, isFalse);
      expect(firstTransport.closeCount, isZero);
      expect(second.controller.isKeepaliveRunning, isTrue);
    });

    test('closing a session closes its transport', () async {
      final manager = buildManager();
      addTearDown(manager.dispose);

      final transport = FakeTransport();
      final entry = manager.open(transport);

      await manager.close(entry.id);

      expect(transport.closeCount, 1);
    });

    test('closing the session in front moves to the next one along', () async {
      final manager = buildManager();
      addTearDown(manager.dispose);

      final first = manager.open(FakeTransport(id: 'h1'));
      final middle = manager.open(FakeTransport(id: 'h2'));
      final last = manager.open(FakeTransport(id: 'h3'));
      manager.select(middle.id);

      await manager.close(middle.id);

      expect(manager.activeId, last.id);
      expect(manager.sessions.map((s) => s.id), [first.id, last.id]);
    });

    test('closing the last session in the strip falls back to the one before',
        () async {
      final manager = buildManager();
      addTearDown(manager.dispose);

      final first = manager.open(FakeTransport(id: 'h1'));
      final last = manager.open(FakeTransport(id: 'h2'));

      await manager.close(last.id);

      expect(manager.activeId, first.id);
    });

    test('closing a background session leaves the front one in front',
        () async {
      final manager = buildManager();
      addTearDown(manager.dispose);

      final background = manager.open(FakeTransport(id: 'h1'));
      final front = manager.open(FakeTransport(id: 'h2'));

      await manager.close(background.id);

      expect(manager.activeId, front.id);
    });

    test('closing an unknown id does nothing', () async {
      final manager = buildManager();
      addTearDown(manager.dispose);

      manager.open(FakeTransport());
      await manager.close('session-nope');

      expect(manager.length, 1);
    });

    test('closing everything closes every transport', () async {
      final manager = buildManager();
      final first = FakeTransport(id: 'h1');
      final second = FakeTransport(id: 'h2');
      manager.open(first);
      manager.open(second);

      await manager.dispose();

      expect(first.closeCount, 1);
      expect(second.closeCount, 1);
      expect(manager.isEmpty, isTrue);
    });
  });

  group('transfers are per session', () {
    test('a queue belongs to one session and is not shared', () async {
      final manager = buildManager();
      addTearDown(manager.dispose);

      final first = manager.open(FakeTransport(id: 'h1'));
      final second = manager.open(FakeTransport(id: 'h2'));

      first.controller.transfers.enqueueDownload(
        remotePath: '/srv/a.txt',
        name: 'a.txt',
      );

      expect(first.controller.transfers.tasks, hasLength(1));
      expect(second.controller.transfers.tasks, isEmpty);
    });

    test('closing one session does not cancel another session\'s transfers',
        () async {
      final manager = buildManager();
      addTearDown(manager.dispose);

      final first = manager.open(FakeTransport(id: 'h1'));
      final second = manager.open(FakeTransport(id: 'h2'));

      final task = second.controller.transfers.enqueueDownload(
        remotePath: '/srv/a.txt',
        name: 'a.txt',
      );
      await manager.close(first.id);

      expect(task.status, isNot(TransferStatus.cancelled));
    });
  });

  group('resolving a destination for a server-to-server transfer', () {
    test('another live session resolves to its controller', () async {
      final manager = buildManager();
      addTearDown(manager.dispose);

      final source = manager.open(FakeTransport(id: 'h1'));
      final target = manager.open(FakeTransport(id: 'h2'));

      final task = source.controller.transfers.enqueueRemoteCopy(
        remotePath: '/srv/a/report.pdf',
        destinationSessionId: target.id,
        destinationPath: '/srv/b/report.pdf',
        name: 'report.pdf',
      );

      // The executor runs on the source session and reaches the destination
      // through the manager's resolver; getting that far is what is being
      // checked here, and a StubFs download of 0 bytes is enough to do it.
      await source.controller.transfers.changes
          .firstWhere((tasks) => tasks.every((t) => t.status.isFinished));

      expect(task.status, TransferStatus.completed);
      expect(source.controller.canTransferToOtherSessions, isTrue);
    });

    test('a session that has been closed fails the transfer with a reason',
        () async {
      final manager = buildManager();
      addTearDown(manager.dispose);

      final source = manager.open(FakeTransport(id: 'h1'));
      final target = manager.open(FakeTransport(id: 'h2'));
      final targetId = target.id;
      await manager.close(targetId);

      final task = source.controller.transfers.enqueueRemoteCopy(
        remotePath: '/srv/a/report.pdf',
        destinationSessionId: targetId,
        destinationPath: '/srv/b/report.pdf',
        name: 'report.pdf',
      );
      await source.controller.transfers.changes
          .firstWhere((tasks) => tasks.every((t) => t.status.isFinished));

      expect(task.status, TransferStatus.failed);
      expect(task.error, contains('closed'));
    });

    test('a session whose transport dropped fails the transfer', () async {
      final manager = buildManager();
      addTearDown(manager.dispose);

      final source = manager.open(FakeTransport(id: 'h1'));
      final targetTransport = FakeTransport(id: 'h2');
      final target = manager.open(targetTransport);

      targetTransport.drop();
      await target.controller.changes.first;

      final task = source.controller.transfers.enqueueRemoteCopy(
        remotePath: '/srv/a/report.pdf',
        destinationSessionId: target.id,
        destinationPath: '/srv/b/report.pdf',
        name: 'report.pdf',
      );
      await source.controller.transfers.changes
          .firstWhere((tasks) => tasks.every((t) => t.status.isFinished));

      expect(task.status, TransferStatus.failed);
      expect(task.error, contains('dropped'));
    });

    test('a session cannot be its own destination', () async {
      final manager = buildManager();
      addTearDown(manager.dispose);

      final source = manager.open(FakeTransport(id: 'h1'));

      final task = source.controller.transfers.enqueueRemoteCopy(
        remotePath: '/srv/a/report.pdf',
        destinationSessionId: source.id,
        destinationPath: '/srv/a/copy.pdf',
        name: 'copy.pdf',
      );
      await source.controller.transfers.changes
          .firstWhere((tasks) => tasks.every((t) => t.status.isFinished));

      expect(task.status, TransferStatus.failed);
      expect(task.error, contains('already on'));
    });

    test('the destinations offered are the other live sessions', () async {
      final manager = buildManager();
      addTearDown(manager.dispose);

      final first = manager.open(FakeTransport(id: 'h1'));
      final second = manager.open(FakeTransport(id: 'h2'));
      final droppedTransport = FakeTransport(id: 'h3');
      final dropped = manager.open(droppedTransport);

      droppedTransport.drop();
      await dropped.controller.changes.first;

      expect(manager.destinationsFor(first.id).map((s) => s.id), [second.id]);
      expect(manager.destinationsFor(second.id).map((s) => s.id), [first.id]);
    });
  });

  group('counting what is open', () {
    test('a dropped session still counts as open, but not as connected',
        () async {
      final manager = buildManager();
      addTearDown(manager.dispose);

      manager.open(FakeTransport(id: 'h1'));
      final droppedTransport = FakeTransport(id: 'h2');
      final dropped = manager.open(droppedTransport);

      droppedTransport.drop();
      await dropped.controller.changes.first;

      expect(manager.length, 2);
      expect(manager.liveCount, 1);
      expect(manager.liveForHost('h2'), isEmpty);
    });
  });
}
