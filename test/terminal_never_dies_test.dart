import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/models/remote_entry.dart';
import 'package:secure_shell_go/services/device_storage.dart';
import 'package:secure_shell_go/services/persistent_shell.dart';
import 'package:secure_shell_go/services/session_controller.dart';
import 'package:secure_shell_go/services/sftp_service.dart';
import 'package:secure_shell_go/services/ssh_service.dart';
import 'package:secure_shell_go/services/transfer_queue.dart';

import 'support/link_transport.dart';

/// A remote file system that serves one download, and can be made to stall
/// halfway through it until [release].
class StallingFs implements RemoteFileSystem {
  StallingFs({this.stall = false});

  final bool stall;
  final _gate = Completer<void>();
  final List<String> downloaded = [];

  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  Future<int?> sizeOf(String path) async => 300;

  @override
  Future<int> download(
    String remotePath, {
    required Future<void> Function(Uint8List chunk) write,
    TransferProgress? onProgress,
    CancelCheck? isCancelled,
  }) async {
    downloaded.add(remotePath);
    await write(Uint8List(150));
    onProgress?.call(150);
    if (stall) {
      await _gate.future;
      // What a real download does when it finds itself cancelled: stops.
      if (isCancelled?.call() ?? false) return 150;
    }
    await write(Uint8List(150));
    onProgress?.call(300);
    return 300;
  }

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not faked');
}

class CountingWriter implements DownloadWriter {
  var written = 0;
  var finished = false;
  var aborted = false;

  @override
  Future<void> add(Uint8List chunk) async => written += chunk.length;

  @override
  Future<SavedDownload> finish() async {
    finished = true;
    return const SavedDownload(displayName: 'a.txt', uri: 'content://a');
  }

  @override
  Future<void> abort() async => aborted = true;
}

class CountingStorage implements DeviceStorage {
  final List<CountingWriter> writers = [];

  @override
  Future<DownloadWriter> beginDownload(
    String fileName, {
    String? mimeType,
    bool overwrite = false,
    String relativeDirectory = '',
  }) async {
    final writer = CountingWriter();
    writers.add(writer);
    return writer;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not faked');
}

/// One session, wired the way `SessionManager` wires one in production, with
/// every clock in the test's hands.
class Harness {
  Harness({
    Host? host,
    List<RemoteFileSystem> filesystems = const [],
    bool reconnect = true,
  }) : first = LinkTransport(host: host) {
    dialer = Dialer(LinkTransport(name: 'second', host: host));
    controller = SessionController(
      connection: first,
      storage: storage,
      openFileSystem: filesystems.isEmpty
          ? null
          : () async => filesystems[_opened++],
      keepaliveScheduler: (_, tick) {
        final timer = CrankTimer(tick);
        keepalives.add(timer);
        return timer;
      },
      reconnect: reconnect
          ? ReconnectSupport(
              loadCredentials: (_) async => testCredentials,
              connect: dialer.connect,
            )
          : null,
      reconnectScheduler: reconnects.schedule,
      clock: () => now,
    );
    // What a terminal view does on its first layout; without it a shell
    // waits its 1.5 s fallback for a size.
    controller.terminal.resize(100, 30);
  }

  final LinkTransport first;
  late final Dialer dialer;
  late final SessionController controller;
  final storage = CountingStorage();
  final keepalives = <CrankTimer>[];
  final reconnects = ManualScheduler();
  var now = DateTime(2026, 10, 21, 12);
  var _opened = 0;

  LinkTransport get second => dialer.next as LinkTransport;

  /// Thirty seconds pass and the current keep-alive ticks.
  Future<void> tick() async {
    now = now.add(const Duration(seconds: 30));
    keepalives.last.fire();
    await pump();
  }

  String get screen => controller.terminal.buffer.getText();
}

/// Waits for [task] to finish, unless it already has.
Future<void> finished(SessionController session, TransferTask task) async {
  if (task.status.isFinished) return;
  await session.transfers.changes
      .firstWhere((_) => task.status.isFinished)
      .timeout(const Duration(seconds: 5));
}

RemoteEntry entry(String name) => RemoteEntry(
      name: name,
      path: '/home/dev/$name',
      kind: RemoteEntryKind.file,
      size: 300,
    );

void main() {
  group('a dead link', () {
    test('is closed as dropped and reconnected', () async {
      final harness = Harness();
      addTearDown(harness.controller.dispose);
      await pump();
      expect(harness.first.pingCount, 1,
          reason: 'the first keep-alive goes out as the session opens');

      // The network goes away without telling the socket: nothing errors,
      // nothing answers.
      harness.first.answering = false;
      await harness.tick();
      await harness.tick();
      expect(harness.controller.isClosed, isFalse);
      await harness.tick();

      expect(harness.controller.isClosed, isTrue);
      expect(harness.controller.isReconnecting, isTrue);
      expect(harness.controller.closeReason, contains('stopped answering'));
      expect(harness.first.closeCount, greaterThan(0),
          reason: 'the silent socket is shut, not left to TCP');

      await harness.reconnects.fire();

      expect(identical(harness.controller.connection, harness.second), isTrue);
      expect(harness.controller.isClosed, isFalse);
      expect(harness.controller.isKeepaliveRunning, isTrue);
    });

    test('never leaves a keep-alive running beside its replacement',
        () async {
      final harness = Harness();
      await pump();
      expect(harness.keepalives, hasLength(1));

      // A transport handed over while the last one's keep-alive still runs.
      await harness.controller.adoptTransport(LinkTransport(name: 'other'));
      expect(harness.keepalives, hasLength(2));
      expect(harness.keepalives.first.cancelled, isTrue);

      await harness.controller.dispose();
      expect(harness.keepalives.every((timer) => timer.cancelled), isTrue,
          reason: 'no timer outlives the session');
    });

    test('a quiet link that answers is left alone', () async {
      final harness = Harness();
      addTearDown(harness.controller.dispose);

      // An idle shell for ten minutes.
      for (var i = 0; i < 20; i++) {
        await harness.tick();
      }

      expect(harness.controller.isClosed, isFalse);
      expect(harness.reconnects.delays, isEmpty);
      expect(harness.dialer.calls, 0);
    });

    test('a link still delivering output is left alone', () async {
      final harness = Harness();
      addTearDown(harness.controller.dispose);
      await pump();

      harness.first.answering = false;
      for (var i = 0; i < 6; i++) {
        await harness.tick();
        harness.first.lastInboundAt = harness.now;
      }

      expect(harness.controller.isClosed, isFalse);
    });

    test('is found at once when the network changes', () async {
      final harness = Harness();
      addTearDown(harness.controller.dispose);
      await pump();

      harness.first.answering = false;
      await harness.controller.networkCameBack();
      await pump();

      expect(harness.controller.isReconnecting, isTrue);
    });

    test('a live link that answers survives a network change', () async {
      final harness = Harness();
      addTearDown(harness.controller.dispose);
      await pump();

      await harness.controller.networkCameBack();
      await pump();

      expect(harness.controller.isClosed, isFalse);
    });
  });

  group('never a dead end', () {
    test('the network coming back skips the wait', () async {
      final harness = Harness();
      addTearDown(harness.controller.dispose);
      harness.first.drop(const SocketException('Network is unreachable'));
      await pump();
      expect(harness.reconnects.delays, const [Duration(seconds: 2)]);

      await harness.controller.networkCameBack();
      await pump();

      expect(harness.dialer.calls, 1);
      expect(harness.controller.isClosed, isFalse);
    });

    test('a schedule that ran out tries again when the network returns',
        () async {
      final harness = Harness();
      addTearDown(harness.controller.dispose);
      final secondTransport = harness.second;
      harness.dialer.next = const SshConnectionException('No route to host.');
      harness.first.drop(const SocketException('Network is unreachable'));
      await pump();

      while (!harness.controller.reconnectGaveUp) {
        await harness.reconnects.fire();
      }
      expect(harness.controller.isReconnecting, isFalse);

      harness.dialer.next = secondTransport;
      await harness.controller.networkCameBack();
      await pump();

      expect(harness.controller.isClosed, isFalse);
      expect(identical(harness.controller.connection, secondTransport), isTrue);
    });

    test('a refused login waits for the user, who can still ask', () async {
      final harness = Harness();
      addTearDown(harness.controller.dispose);
      final secondTransport = harness.second;
      harness.dialer.next =
          const SshAuthenticationException('Authentication failed for "dev".');
      harness.first.drop(const SocketException('Connection reset'));
      await pump();
      await harness.reconnects.fire();
      expect(harness.controller.reconnectGaveUp, isTrue);

      await harness.controller.networkCameBack();
      await pump();
      expect(harness.dialer.calls, 1, reason: 'no lockout by network change');

      harness.dialer.next = secondTransport;
      harness.controller.reconnectNow();
      await pump();
      expect(harness.dialer.calls, 2);
      expect(harness.controller.isClosed, isFalse);
    });

    test('Stop is respected, and Reconnect undoes it', () async {
      final harness = Harness();
      addTearDown(harness.controller.dispose);
      harness.first.drop(const SocketException('Connection reset'));
      await pump();
      harness.controller.stopReconnecting();

      await harness.controller.networkCameBack();
      await pump();
      expect(harness.dialer.calls, 0);
      expect(harness.controller.canReconnect, isTrue);

      harness.controller.reconnectNow();
      await pump();
      expect(harness.dialer.calls, 1);
      expect(harness.controller.isClosed, isFalse);
    });

    test('a later drop of the new connection is reconnected too', () async {
      final harness = Harness();
      addTearDown(harness.controller.dispose);
      harness.first.drop(const SocketException('Connection reset'));
      await pump();
      await harness.reconnects.fire();
      final secondTransport = harness.second;
      harness.dialer.next = LinkTransport(name: 'third');

      harness.now = harness.now.add(const Duration(minutes: 5));
      secondTransport.drop(const SocketException('Connection reset'));
      await pump();

      // A fresh schedule: the first delay again.
      expect(harness.reconnects.delays, const [
        Duration(seconds: 2),
        Duration(seconds: 2),
      ]);
      await harness.reconnects.fire();
      expect(harness.controller.isClosed, isFalse);
    });

    test('a connection that dies at once carries on the old schedule',
        () async {
      final harness = Harness();
      addTearDown(harness.controller.dispose);
      harness.first.drop(const SocketException('Connection reset'));
      await pump();
      await harness.reconnects.fire();

      harness.now = harness.now.add(const Duration(seconds: 3));
      harness.second.drop(const SocketException('Connection reset'));
      await pump();

      // Not dialled every two seconds for ever by a server that hangs up
      // straight after every login.
      expect(harness.reconnects.delays, const [
        Duration(seconds: 2),
        Duration(seconds: 4),
      ]);
    });
  });

  group('transfers cut off by a drop', () {
    test('are interrupted, re-queued on reconnect, and complete', () async {
      final stalled = StallingFs(stall: true);
      final fresh = StallingFs();
      final harness = Harness(filesystems: [stalled, fresh]);
      addTearDown(harness.controller.dispose);

      final task = harness.controller.queueDownload(entry('a.txt'));
      await pump();
      expect(task.status, TransferStatus.running);

      harness.first.drop(const SocketException('Connection reset'));
      await pump();
      stalled.release();
      await pump();

      expect(task.status, TransferStatus.interrupted);
      expect(harness.storage.writers.single.aborted, isTrue,
          reason: 'the half-written file is not published');

      await harness.reconnects.fire();
      await finished(harness.controller, task);

      expect(task.status, TransferStatus.completed);
      expect(harness.controller.transfers.tasks.single.id, task.id);
      expect(fresh.downloaded, ['/home/dev/a.txt']);
      expect(harness.storage.writers.last.finished, isTrue);
      expect(harness.storage.writers.last.written, 300);
    });

    test('a dead link interrupts them the same way', () async {
      final stalled = StallingFs(stall: true);
      final harness = Harness(filesystems: [stalled, StallingFs()]);
      addTearDown(harness.controller.dispose);
      await pump();
      final task = harness.controller.queueDownload(entry('a.txt'));
      await pump();

      harness.first.answering = false;
      for (var i = 0; i < 3; i++) {
        await harness.tick();
      }
      stalled.release();
      await pump();

      expect(task.status, TransferStatus.interrupted);
      await harness.reconnects.fire();
      await finished(harness.controller, task);
      expect(task.status, TransferStatus.completed);
    });

    test('without a way to reconnect they end, as before', () async {
      final stalled = StallingFs(stall: true);
      final harness = Harness(filesystems: [stalled], reconnect: false);
      addTearDown(harness.controller.dispose);
      final task = harness.controller.queueDownload(entry('a.txt'));
      await pump();

      harness.first.drop(const SocketException('Connection reset'));
      await pump();
      stalled.release();
      await pump();

      expect(task.status.isFinished, isTrue);
      expect(harness.controller.canReconnect, isFalse);
    });
  });

  group('a shell that ends', () {
    test('with its transport is a drop, whichever is heard of first',
        () async {
      final harness = Harness();
      addTearDown(harness.controller.dispose);
      await harness.controller.ensureShell();

      // The shell's channel ends first, normally and with no exit status —
      // what dartssh2 does to every channel of a transport that has died.
      harness.first.drop(const SocketException('Connection reset'));
      await pump();

      expect(harness.first.shells.single.exitCode, isNull);
      expect(harness.controller.isReconnecting, isTrue);
      await harness.reconnects.fire();
      expect(harness.controller.isClosed, isFalse);
      expect(harness.second.shells, hasLength(1));
    });

    test('leaves the connection up and offers a restart', () async {
      final harness = Harness();
      addTearDown(harness.controller.dispose);
      await harness.controller.ensureShell();

      harness.first.shells.single.exit();
      await pump();

      expect(harness.controller.isClosed, isFalse);
      expect(harness.controller.hasShellEnded, isTrue);
      expect(harness.controller.shellEndedReason, 'Shell exited with status 0.');
      expect(harness.reconnects.delays, isEmpty);

      await harness.controller.restartShell();

      expect(harness.first.shells, hasLength(2));
      expect(harness.controller.hasShellEnded, isFalse);
      expect(harness.controller.isShellReady, isTrue);
      expect(harness.screen, contains('new shell'));
    });
  });

  group('a persistent session', () {
    Host persistentHost({
      PersistentSession kind = PersistentSession.tmux,
      String? startup = 'htop',
    }) =>
        Host(
          id: 'h1',
          label: 'Test box',
          hostname: 'example.com',
          port: 22,
          username: 'dev',
          authMethod: SshAuthMethod.password,
          persistentSession: kind,
          startupCommand: startup,
        );

    test('starts its shell inside tmux, under this tab\'s name', () async {
      final harness = Harness(host: persistentHost());
      addTearDown(harness.controller.dispose);
      harness.controller.persistentSlot = 2;
      await harness.controller.ensureShell();

      expect(harness.first.shellCommands, [
        persistentShellCommand(PersistentSession.tmux, 'ssg-test-box-2_'),
      ]);
    });

    test('types the startup command only into a new one', () async {
      final harness = Harness(host: persistentHost());
      addTearDown(harness.controller.dispose);
      await harness.controller.ensureShell();

      expect(harness.first.executed, [
        persistentProbeCommand(PersistentSession.tmux, 'ssg-test-box-1_'),
      ]);
      expect(harness.first.shells.single.writes, ['htop\n']);
    });

    test('never types it into one left running', () async {
      final harness = Harness(host: persistentHost());
      addTearDown(harness.controller.dispose);
      harness.first.probeAnswer = 'attach\n';
      await harness.controller.ensureShell();

      expect(harness.first.shells.single.writes, isEmpty);
    });

    test('a reconnect goes back to the same session', () async {
      final harness = Harness(host: persistentHost(startup: null));
      addTearDown(harness.controller.dispose);
      await harness.controller.ensureShell();

      harness.first.drop(const SocketException('Connection reset'));
      await pump();
      await harness.reconnects.fire();

      expect(harness.second.shellCommands, harness.first.shellCommands);
      expect(harness.first.executed, isEmpty,
          reason: 'no startup command, so nothing to probe for');
    });

    test('screen is used when chosen', () async {
      final harness = Harness(
        host: persistentHost(kind: PersistentSession.screen, startup: null),
      );
      addTearDown(harness.controller.dispose);
      await harness.controller.ensureShell();

      expect(harness.first.shellCommands, [
        persistentShellCommand(PersistentSession.screen, 'ssg-test-box-1_'),
      ]);
    });

    test('that fails as it starts gives way to the login shell', () async {
      // tmux or screen failing is caught by the script on the server; this
      // is the script itself not running — a restricted shell refusing
      // `exec`, say.
      final harness = Harness(host: persistentHost(startup: null));
      addTearDown(harness.controller.dispose);
      await harness.controller.ensureShell();

      harness.first.shells.single.exit(1);
      await pump();

      expect(harness.first.shellCommands, [
        persistentShellCommand(PersistentSession.tmux, 'ssg-test-box-1_'),
        null,
      ]);
      expect(harness.screen, contains('could not be started'));
      expect(harness.controller.hasShellEnded, isFalse);
      expect(harness.controller.isShellReady, isTrue);

      // And it stays the login shell: a reconnect does not run the failing
      // command again either.
      harness.first.drop(const SocketException('Connection reset'));
      await pump();
      await harness.reconnects.fire();
      expect(harness.second.shellCommands, [null]);
    });

    test('that ran a while and then failed is left ended', () async {
      final harness = Harness(host: persistentHost(startup: null));
      addTearDown(harness.controller.dispose);
      await harness.controller.ensureShell();

      harness.now = harness.now.add(const Duration(minutes: 5));
      harness.first.shells.single.exit(1);
      await pump();

      expect(harness.first.shellCommands, hasLength(1));
      expect(harness.controller.hasShellEnded, isTrue);
      expect(harness.controller.shellEndedReason, contains('status 1'));
    });

    test('falls back to the login shell, saying so, when it cannot start',
        () async {
      final harness = Harness(host: persistentHost());
      addTearDown(harness.controller.dispose);
      harness.first.commandShells = false;
      await harness.controller.ensureShell();

      expect(harness.first.shellCommands, [null]);
      expect(harness.screen, contains('could not be started'));
      expect(harness.first.shells.single.writes, ['htop\n'],
          reason: 'the login shell is a new one');
    });
  });
}
