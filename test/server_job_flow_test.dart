import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/models/remote_entry.dart';
import 'package:secure_shell_go/services/device_storage.dart';
import 'package:secure_shell_go/services/direct_remote_copy.dart';
import 'package:secure_shell_go/services/remote_copy.dart';
import 'package:secure_shell_go/services/server_side_job.dart';
import 'package:secure_shell_go/services/session_controller.dart';
import 'package:secure_shell_go/services/session_foreground.dart';
import 'package:secure_shell_go/services/session_manager.dart';
import 'package:secure_shell_go/services/sftp_service.dart';
import 'package:secure_shell_go/services/ssh_keygen.dart';
import 'package:secure_shell_go/services/ssh_service.dart';
import 'package:secure_shell_go/services/transfer_queue.dart';

import 'fake_exec_session.dart';

/// A direct server-to-server copy runs as a job on the source server, so
/// that closing the app — or the session going away — does not stop it.
/// These drive the real direct-copy code against scripted transports: the
/// source's ordinary session answers keyscan and job-status commands, and
/// the agent-forwarded connection answers the launch.
void main() {
  late Host destHost;
  late SshCredentials destCredentials;

  final destKey = _verifiedKey('ssh-ed25519', 'b host key');
  final keyscan = 'b.example ssh-ed25519 ${_blob('b host key')}\n';
  const fast = Duration(milliseconds: 5);

  setUp(() {
    final generated = SshKeygen.generateEd25519(comment: 'test@example');
    destCredentials = SshCredentials(privateKeyPem: generated.privateKeyPem);
    destHost = const Host(
      id: 'dest',
      label: 'B',
      hostname: 'b.example',
      port: 22,
      username: 'root',
      authMethod: SshAuthMethod.privateKey,
    );
  });

  /// The source's session: answers keyscan, then each status poll with the
  /// next of [statuses] (repeating the last), and records everything.
  FakeExecTransport sourceSession(List<String> statuses) {
    var poll = 0;
    return FakeExecTransport(
      respond: (command) {
        if (command.startsWith('ssh-keyscan')) {
          return FakeExecSession(stdout: keyscan);
        }
        if (command.contains('kill -0')) {
          final status = statuses[poll < statuses.length ? poll : statuses.length - 1];
          poll++;
          return FakeExecSession(stdout: status);
        }
        return FakeExecSession();
      },
    );
  }

  FakeExecTransport launcher() => FakeExecTransport(
        agentForwarding: true,
        respond: (_) => FakeExecSession(
          stdout: '${ServerSideJob.startedMarker}\n',
          exits: true,
        ),
      );

  SessionController controllerFor(
    FakeExecTransport session, {
    FakeExecTransport? dialled,
  }) {
    final controller = SessionController(
      connection: session,
      storage: _NoStorage(),
      openFileSystem: () async => _RecordingFs({'/src/file.bin': 12}),
      resolveDestinationCredentials: (_) async => destCredentials,
      connectWithAgentForwarding: (_, _) async {
        if (dialled == null) fail('a resumed job must not launch again');
        return dialled;
      },
    );
    addTearDown(controller.dispose);
    return controller;
  }

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 50));

  test('a direct copy runs as a job: launched once, followed to the end, '
      'verified and cleaned up', () async {
    final session = sourceSession([
      'RUNNING\n---\n',
      'EXIT 0\n---\nsftp> bye\n',
    ]);
    final dialled = launcher();
    final id = ServerSideJob.newId();
    var launched = 0;

    final outcome = await copyRemoteFileDirect(
      source: controllerFor(session, dialled: dialled),
      destHost: destHost,
      destCredentials: destCredentials,
      destinationFs: _RecordingFs({'/dst/file.bin': 12}),
      sourcePath: '/src/file.bin',
      destinationPath: '/dst/file.bin',
      destinationHostKey: destKey,
      detached: DetachedRun(
        jobId: id,
        stamp: 1738000000000,
        onLaunched: () async => launched++,
        pollInterval: fast,
      ),
    );
    await settle();

    expect(outcome.bytesCopied, 12);
    expect(launched, 1);
    final launch = dialled.commands.single;
    expect(launch, contains('.cache/secureshellgo/jobs/$id'));
    expect(launch, contains('setsid'));
    expect(launch, contains('StrictHostKeyChecking=yes'));
    expect(dialled.closed, isTrue,
        reason: 'the forwarded connection is let go once the job is up');
    expect(session.commands.where((c) => c.contains('kill -0')), hasLength(2));
    expect(session.commands.last, contains('rm -rf'),
        reason: 'the finished job folder is removed');
  });

  test('a session going away leaves the job running and its files alone',
      () async {
    final session = sourceSession(['RUNNING\n---\n']);
    final destination = _RecordingFs({'/dst/file.bin': 12});
    var cancelled = false;

    await expectLater(
      copyRemoteFileDirect(
        source: controllerFor(session, dialled: launcher()),
        destHost: destHost,
        destCredentials: destCredentials,
        destinationFs: destination,
        sourcePath: '/src/file.bin',
        destinationPath: '/dst/file.bin',
        destinationHostKey: destKey,
        isCancelled: () => cancelled,
        detached: DetachedRun(
          jobId: ServerSideJob.newId(),
          stamp: 1,
          // The tab closes once the job is up.
          onLaunched: () async => cancelled = true,
          isAbandoned: () => true,
          pollInterval: fast,
        ),
      ),
      throwsA(isA<ServerJobLeftRunning>()),
    );
    await settle();

    expect(session.commands.any((c) => c.contains('kill -s TERM')), isFalse,
        reason: 'nothing stops the job');
    expect(session.commands.any((c) => c.contains('rm -rf')), isFalse,
        reason: 'its folder is the next run\'s');
    expect(destination.removed, isEmpty,
        reason: 'the temp it is still writing is left where it is');
  });

  test('the user cancelling stops the job on the server', () async {
    final session = sourceSession(['RUNNING\n---\n']);
    var cancelled = false;

    await expectLater(
      copyRemoteFileDirect(
        source: controllerFor(session, dialled: launcher()),
        destHost: destHost,
        destCredentials: destCredentials,
        destinationFs: _RecordingFs({}),
        sourcePath: '/src/file.bin',
        destinationPath: '/dst/file.bin',
        destinationHostKey: destKey,
        isCancelled: () => cancelled,
        detached: DetachedRun(
          jobId: ServerSideJob.newId(),
          stamp: 1,
          onLaunched: () async => cancelled = true,
          isAbandoned: () => false,
          pollInterval: fast,
        ),
      ),
      throwsA(isA<TransferCancelled>()),
    );
    expect(session.commands.any((c) => c.contains('kill -s TERM')), isTrue);
  });

  test('a resumed job is followed and finished without launching again',
      () async {
    final session = sourceSession(['EXIT 0\n---\n']);
    final outcome = await copyRemoteFileDirect(
      source: controllerFor(session),
      destHost: destHost,
      // Not needed to follow a job, and an empty one must not matter.
      destCredentials: const SshCredentials(),
      destinationFs: _RecordingFs({'/dst/file.bin': 12}),
      sourcePath: '/src/file.bin',
      destinationPath: '/dst/file.bin',
      destinationHostKey: null,
      detached: DetachedRun(
        jobId: ServerSideJob.newId(),
        stamp: 1,
        resuming: true,
        pollInterval: fast,
      ),
    );
    expect(outcome.bytesCopied, 12);
    expect(session.commands.any((c) => c.startsWith('ssh-keyscan')), isFalse);
  });

  test('a job that vanished is reported, not taken for success', () async {
    final session = sourceSession(['GONE\n---\n']);
    await expectLater(
      copyRemoteFileDirect(
        source: controllerFor(session),
        destHost: destHost,
        destCredentials: const SshCredentials(),
        destinationFs: _RecordingFs({'/dst/file.bin': 12}),
        sourcePath: '/src/file.bin',
        destinationPath: '/dst/file.bin',
        destinationHostKey: null,
        detached: DetachedRun(
          jobId: ServerSideJob.newId(),
          stamp: 1,
          resuming: true,
          pollInterval: fast,
        ),
      ),
      throwsA(
        isA<SSHDirectCopyUnavailable>().having(
          (e) => e.message,
          'message',
          contains('restarted'),
        ),
      ),
    );
  });

  test('a replace resumed with the same stamp finds the same staging folder',
      () {
    final fs = _RecordingFs({});
    final first = StagedDirectoryReplace(fs, '/srv/site', stamp: 1738000000000);
    final again = StagedDirectoryReplace(fs, '/srv/site', stamp: 1738000000000);
    expect(again.staging, first.staging);
    expect(again.retired, first.retired);
  });

  group('the queue tells a user cancel from the session ending', () {
    /// A queue whose executor parks on [gate] and hands out its handle.
    Future<(TransferQueue, TransferHandle)> running(Future<void> gate) async {
      final handle = Completer<TransferHandle>();
      final queue = TransferQueue(executor: (task, h) async {
        handle.complete(h);
        await gate;
      });
      queue.enqueueRemoteCopy(
        remotePath: '/a',
        destinationSessionId: 's',
        destinationPath: '/b',
        name: 'a',
      );
      return (queue, await handle.future);
    }

    test('cancelAll marks it abandoned, cancel does not', () async {
      final gate = Completer<void>();
      addTearDown(gate.complete);

      final (ending, h1) = await running(gate.future);
      ending.cancelAll();
      expect(h1.isCancelled, isTrue);
      expect(h1.isAbandoned, isTrue);

      final (byUser, h2) = await running(gate.future);
      byUser.cancel(byUser.tasks.single.id);
      expect(h2.isCancelled, isTrue);
      expect(h2.isAbandoned, isFalse);
    });
  });

  group('the controller remembers a job until it is finished', () {
    late Directory dir;
    late ServerJobStore store;
    late ServerJobRecord record;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('ssg_job_ctl');
      store = ServerJobStore(file: File('${dir.path}/jobs.json'));
      record = ServerJobRecord(
        jobId: ServerSideJob.newId(),
        stamp: 1738000000000,
        sourceHostId: 'h1',
        sourceLabel: 'A',
        destinationHostId: 'dest',
        destinationLabel: 'B',
        sourcePath: '/src/file.bin',
        destinationPath: '/dst/file.bin',
        name: 'file.bin',
        isDirectory: false,
        moveSource: false,
        overwrite: false,
        startedAt: DateTime(2026, 10, 21),
      );
      await store.save(record);
    });

    tearDown(() => dir.delete(recursive: true));

    /// A source controller following [record] with the given job statuses,
    /// and a destination session where the file has landed.
    SessionController source(List<String> statuses) {
      final destination = SessionController(
        connection: FakeExecTransport(host: destHost),
        storage: _NoStorage(),
        openFileSystem: () async => _RecordingFs({'/dst/file.bin': 12}),
      );
      addTearDown(destination.dispose);
      return SessionController(
        connection: sourceSession(statuses),
        storage: _NoStorage(),
        openFileSystem: () async => _RecordingFs({'/src/file.bin': 12}),
        resolveRemoteTarget: (_) async => destination,
        resolveDestinationCredentials: (_) async => null,
        serverJobs: store,
      );
    }

    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 200 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    test('a finished job is verified, completed and forgotten', () async {
      final controller = source(['EXIT 0\n---\n']);
      addTearDown(controller.dispose);

      final task = controller.resumeServerJob(
        record,
        destinationSessionId: 'session-b',
      );
      await until(() => task.status.isFinished);
      await settle();

      expect(task.status, TransferStatus.completed);
      expect(task.routeUsed, TransferRoute.direct);
      expect(await store.all(), isEmpty);
      // The removal reaches the file in the background. Waiting for it keeps
      // tearDown from deleting the folder under its rename, which on a busy
      // machine failed this test after it had passed.
      final file = File('${dir.path}/jobs.json');
      await until(() => !file.readAsStringSync().contains(record.jobId));
      expect(file.readAsStringSync(), isNot(contains(record.jobId)));
    });

    test('a job still running when its session closes is kept', () async {
      final controller = source(['RUNNING\n---\n']);
      final task = controller.resumeServerJob(
        record,
        destinationSessionId: 'session-b',
      );
      await until(() => task.status == TransferStatus.running);
      await settle();

      await controller.dispose();
      await settle();

      expect(task.status, TransferStatus.cancelled);
      expect((await store.all()).single.jobId, record.jobId,
          reason: 'picked up again the next time both servers are open');
    });
  });

  test('the manager picks a job up once both servers are open', () async {
    final dir = await Directory.systemTemp.createTemp('ssg_job_flow');
    addTearDown(() => dir.delete(recursive: true));
    final store = ServerJobStore(file: File('${dir.path}/jobs.json'));
    final record = ServerJobRecord(
      jobId: ServerSideJob.newId(),
      stamp: 1738000000000,
      sourceHostId: 'a',
      sourceLabel: 'A',
      destinationHostId: 'b',
      destinationLabel: 'B',
      sourcePath: '/data/big.iso',
      destinationPath: '/srv/big.iso',
      name: 'big.iso',
      isDirectory: false,
      moveSource: false,
      overwrite: false,
      startedAt: DateTime(2026, 10, 21),
    );
    await store.save(record);

    final manager = SessionManager(
      foreground: SessionForegroundController(channel: _QuietForeground()),
      serverJobs: store,
      createController: (connection, resolve, resolveCreds) =>
          SessionController(
        connection: connection,
        storage: _NoStorage(),
        openFileSystem: () async => _RecordingFs({}),
        resolveRemoteTarget: resolve,
      ),
    );

    final a = manager.open(FakeExecTransport(host: _host('a')));
    await settle();
    expect(a.controller.transfers.tasks, isEmpty,
        reason: 'the destination is not open yet');

    manager.open(FakeExecTransport(host: _host('b')));
    await settle();
    final task = a.controller.transfers.tasks.single;
    expect(task.resumingServerJob, isTrue);
    expect(task.serverJobId, record.jobId);
    expect(task.serverJobStamp, record.stamp);
    expect(task.route, TransferRoute.direct);
    expect(task.destinationPath, '/srv/big.iso');
  });

  group('the manager follows each job once', () {
    late Directory dir;
    late ServerJobStore store;
    late ServerJobRecord record;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('ssg_job_once');
      store = ServerJobStore(file: File('${dir.path}/jobs.json'));
      record = ServerJobRecord(
        jobId: ServerSideJob.newId(),
        stamp: 1738000000000,
        sourceHostId: 'a',
        sourceLabel: 'A',
        destinationHostId: 'b',
        destinationLabel: 'B',
        sourcePath: '/data/big.iso',
        destinationPath: '/srv/big.iso',
        name: 'big.iso',
        isDirectory: false,
        moveSource: false,
        overwrite: false,
        startedAt: DateTime(2026, 10, 21),
      );
    });

    tearDown(() => dir.delete(recursive: true));

    /// The source server: every status poll says the job is still going.
    FakeExecTransport stillRunning() => FakeExecTransport(
          host: _host('a'),
          respond: (command) => FakeExecSession(
            stdout: command.contains('kill -0') ? 'RUNNING\n---\n' : '',
          ),
        );

    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 300 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    List<TransferTask> following(ManagedSession session) => session
        .controller.transfers.tasks
        .where((t) => t.status.isActive)
        .toList();

    SessionManager manager({ReconnectSupport? reconnectB, _Timers? timers}) {
      final manager = SessionManager(
        foreground: SessionForegroundController(channel: _QuietForeground()),
        serverJobs: store,
        createController: (connection, resolve, resolveCreds) =>
            SessionController(
          connection: connection,
          storage: _NoStorage(),
          openFileSystem: () async => _RecordingFs({}),
          resolveRemoteTarget: resolve,
          resolveDestinationCredentials: (_) async => null,
          serverJobs: store,
          reconnect: connection.host.id == 'b' ? reconnectB : null,
          reconnectScheduler: timers?.schedule ?? Timer.new,
        ),
      );
      addTearDown(manager.closeAll);
      return manager;
    }

    test('a job some session is already following gets no second follower',
        () async {
      final sessions = manager();
      final a = sessions.open(stillRunning());
      final b = sessions.open(FakeExecTransport(host: _host('b')));
      await settle();

      // What a copy the app has just launched looks like to the manager: a
      // task on the source following the job, and the job in the store.
      a.controller.resumeServerJob(record, destinationSessionId: b.id);
      await store.save(record);
      await until(() => following(a).single.status == TransferStatus.running);

      // Any session opening — or reconnecting — looks for jobs to pick up.
      sessions.open(FakeExecTransport(host: _host('c')));
      await settle();

      expect(following(a), hasLength(1));
    });

    test('a job handed off after both ends are back is picked up again',
        () async {
      await store.save(record);
      final timers = _Timers();
      final sessions = manager(
        timers: timers,
        reconnectB: ReconnectSupport(
          loadCredentials: (_) async => const SshCredentials(password: 'x'),
          connect: ({
            required host,
            required credentials,
            required verifyHostKey,
          }) async =>
              FakeExecTransport(host: _host('b')),
        ),
      );
      final a = sessions.open(stillRunning());
      final destination = FakeExecTransport(host: _host('b'));
      final b = sessions.open(destination);
      b.controller.terminal.resize(100, 30);
      await until(() => following(a).length == 1);
      final first = following(a).single;
      await until(() => first.status == TransferStatus.running);

      // The destination drops and is back before the follower on A has
      // noticed, let alone let go of the job.
      destination.drop(const SocketException('Connection reset'));
      await settle();
      expect(first.status, TransferStatus.interrupted);
      timers.fireAll();
      await until(() => !b.controller.isClosed);
      expect(following(a), [first], reason: 'it is still the follower');

      await until(() => first.status == TransferStatus.cancelled);
      await until(() => following(a).isNotEmpty);
      expect(following(a).single.serverJobId, record.jobId);
      expect(following(a).single.id, isNot(first.id));
    });
  });
}

/// Backoff timers a test fires by hand.
class _Timers {
  final List<void Function()> _pending = [];

  Timer schedule(Duration delay, void Function() fire) {
    _pending.add(fire);
    return Timer(Duration.zero, () {});
  }

  void fireAll() {
    final pending = List.of(_pending);
    _pending.clear();
    for (final fire in pending) {
      fire();
    }
  }
}

Host _host(String id) => Host(
      id: id,
      label: id.toUpperCase(),
      hostname: '$id.example',
      port: 22,
      username: 'root',
      authMethod: SshAuthMethod.privateKey,
    );

class _QuietForeground implements SessionForegroundChannel {
  @override
  Future<void> start(String label) async {}
  @override
  Future<void> stop() async {}
}

class _RecordingFs implements RemoteFileSystem {
  _RecordingFs(this._sizes);

  final Map<String, int> _sizes;
  final List<String> removed = [];

  @override
  Future<int?> sizeOf(String path) async => _sizes[path];

  @override
  Future<void> remove(String path) async => removed.add(path);

  @override
  Future<List<RemoteEntry>> list(String path) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _NoStorage implements DeviceStorage {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

String _blob(String seed) => base64.encode(utf8.encode(seed));

VerifiedHostKey _verifiedKey(String type, String seed) {
  final digest = sha256.convert(utf8.encode(seed)).bytes;
  return VerifiedHostKey(
    keyType: type,
    fingerprint: 'SHA256:${base64.encode(digest).replaceAll('=', '')}',
  );
}
