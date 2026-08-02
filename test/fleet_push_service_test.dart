import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/models/remote_entry.dart';
import 'package:secure_shell_go/services/fleet_push_service.dart';
import 'package:secure_shell_go/services/sftp_service.dart';

/// A remote filesystem with scripted contents, in memory. Mirrors
/// `FakeRemoteFs` in `session_controller_test.dart` closely enough to read
/// the same way, but local to this file since fleet-push wants a couple of
/// extra failure injection knobs that test does not.
class FakeRemoteFs implements RemoteFileSystem {
  FakeRemoteFs();

  /// path -> size, standing in for what is actually on the server.
  final Map<String, int> files = {};
  final List<String> renamed = [];
  final List<String> removed = [];
  final List<String> opened = [];

  Object? existsError;
  Object? openWriteError;
  Object? sizeOfLie;

  @override
  Future<bool> exists(String path) async {
    if (existsError != null) throw existsError!;
    return files.containsKey(path);
  }

  @override
  Future<RemoteFileWriter> openWrite(String remotePath) async {
    if (openWriteError != null) throw openWriteError!;
    opened.add(remotePath);
    return _FakeWriter(this, remotePath);
  }

  @override
  Future<int?> sizeOf(String path) async {
    if (sizeOfLie != null) return sizeOfLie as int?;
    return files[path];
  }

  @override
  Future<void> remove(String path) async {
    removed.add(path);
    files.remove(path);
  }

  @override
  Future<void> rename(String from, String to) async {
    final size = files[from];
    if (size == null) {
      throw SftpFailure('"$from" is not there any more.');
    }
    files.remove(from);
    files[to] = size;
    renamed.add('$from -> $to');
  }

  @override
  Future<String> home() async => '/home/dev';

  @override
  Future<String> resolve(String path) async => path;

  @override
  Future<List<RemoteEntry>> list(String path) async => const [];

  @override
  Future<int> download(
    String remotePath, {
    required Future<void> Function(Uint8List chunk) write,
    TransferProgress? onProgress,
    CancelCheck? isCancelled,
  }) =>
      throw UnimplementedError('fleet push never downloads');

  @override
  Future<int> upload(
    String localPath,
    String remotePath, {
    TransferProgress? onProgress,
    CancelCheck? isCancelled,
  }) =>
      throw UnimplementedError('the fake queue path never calls this');

  @override
  Future<void> mkdir(String path) async {}

  @override
  Future<void> removeDirectory(String path) async {}

  @override
  Future<bool> isDirectory(String path) async => false;

  @override
  Future<void> close() async {}
}

class _FakeWriter implements RemoteFileWriter {
  _FakeWriter(this._fs, this._path);

  final FakeRemoteFs _fs;
  final String _path;
  var _written = 0;
  var _closed = false;

  var failOnAdd = false;

  @override
  Future<void> add(Uint8List chunk) async {
    if (failOnAdd) throw const SftpFailure('disk full');
    _written += chunk.length;
  }

  @override
  Future<void> close() async {
    _closed = true;
    _fs.files[_path] = _written;
  }

  @override
  Future<void> abort() async {
    if (!_closed) _closed = true;
    _fs.files.remove(_path);
  }
}

/// A host with a session already open: the byte-moving is faked as an
/// async task rather than a real `TransferQueue`, since `FleetOpenSession`
/// exists precisely so this service does not need to know that type.
class FakeOpenSession implements FleetOpenSession {
  FakeOpenSession(
    this.fs, {
    this.uploadDelay = Duration.zero,
    this.failWith,
  });

  final FakeRemoteFs fs;
  final Duration uploadDelay;
  final Object? failWith;

  final List<String> queuedPaths = [];
  var queueCount = 0;

  @override
  Future<RemoteFileSystem> sftp() async => fs;

  @override
  FleetQueuedUpload queueUpload({
    required FleetLocalFile file,
    required String remotePath,
    required String displayName,
    required void Function(int bytes) onProgress,
  }) {
    queueCount++;
    queuedPaths.add(remotePath);
    var cancelled = false;
    final completer = Completer<void>();

    Future<void>(() async {
      if (uploadDelay > Duration.zero) {
        await Future<void>.delayed(uploadDelay);
      }
      if (cancelled) {
        completer.completeError(const SftpFailure('cancelled'));
        return;
      }
      if (failWith != null) {
        completer.completeError(failWith!);
        return;
      }
      onProgress(file.size);
      fs.files[remotePath] = file.size;
      completer.complete();
    });

    return FleetQueuedUpload(
      done: completer.future,
      cancel: () => cancelled = true,
    );
  }
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('fleet_push_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<FleetLocalFile> writeLocalFile(String name, String content) async {
    final file = File('${tempDir.path}/$name');
    await file.writeAsString(content);
    return FleetLocalFile(path: file.path, name: name, size: content.length);
  }

  Host host(String id, {String label = ''}) => Host(
        id: id,
        label: label,
        hostname: '$id.example.com',
        port: 22,
        username: 'dev',
        authMethod: SshAuthMethod.password,
      );

  group('partial failure', () {
    test(
      'one host failing to connect leaves the others done, and the '
      'summary reads N of M',
      () async {
        final file = await writeLocalFile('notes.md', 'hello world');
        final openFs = FakeRemoteFs();
        final open = FakeOpenSession(openFs);

        final service = FleetPushService(
          request: FleetPushRequest(
            hosts: [host('h1'), host('h2'), host('h3')],
            files: [file],
            destinationDirectory: '/home/dev',
            overwritePolicy: FleetOverwritePolicy.overwrite,
          ),
          openSessionLookup: (id) => id == 'h1' || id == 'h3' ? open : null,
          credentialLookup: (id) async =>
              const SshCredentials(password: 'x'),
          dialer: (h, creds) async {
            if (h.id == 'h2') {
              throw const SshConnectionExceptionStub('could not reach h2');
            }
            return FleetDialedConnection(sftp: FakeRemoteFs(), close: () {});
          },
        );

        service.start();
        await _untilDone(service);

        final byId = {for (final p in service.hosts) p.hostId: p};
        expect(byId['h1']!.status, FleetHostStatus.done);
        expect(byId['h3']!.status, FleetHostStatus.done);
        expect(byId['h2']!.status, FleetHostStatus.failed);
        expect(
          byId['h2']!.failureReason,
          FleetHostFailureReason.connectFailed,
        );
        expect(service.summary, '2 of 3 succeeded');
        expect(service.succeededCount, 2);
        expect(service.totalCount, 3);
      },
    );
  });

  group('bounded concurrency', () {
    test('no more than maxConcurrentHosts dial at once, and the cap is '
        'actually reached', () async {
      final file = await writeLocalFile('a.txt', 'x');
      var concurrent = 0;
      var peak = 0;

      final service = FleetPushService(
        request: FleetPushRequest(
          hosts: [for (var i = 0; i < 6; i++) host('h$i')],
          files: [file],
          destinationDirectory: '/home/dev',
          overwritePolicy: FleetOverwritePolicy.overwrite,
        ),
        openSessionLookup: (_) => null,
        credentialLookup: (_) async => const SshCredentials(password: 'x'),
        maxConcurrentHosts: 3,
        dialer: (h, creds) async {
          concurrent++;
          peak = concurrent > peak ? concurrent : peak;
          await Future<void>.delayed(const Duration(milliseconds: 30));
          concurrent--;
          return FleetDialedConnection(sftp: FakeRemoteFs(), close: () {});
        },
      );

      service.start();
      await _untilDone(service);

      expect(peak, lessThanOrEqualTo(3));
      expect(peak, 3, reason: 'six hosts and a cap of three should reach it');
      expect(service.succeededCount, 6);
    });
  });

  group('missing credentials', () {
    test('a host with nothing saved fails just that host, without ever '
        'dialling it', () async {
      final file = await writeLocalFile('a.txt', 'x');
      final open = FakeOpenSession(FakeRemoteFs());
      var dialCount = 0;

      final service = FleetPushService(
        request: FleetPushRequest(
          hosts: [host('h1'), host('h2')],
          files: [file],
          destinationDirectory: '/home/dev',
          overwritePolicy: FleetOverwritePolicy.overwrite,
        ),
        openSessionLookup: (id) => id == 'h1' ? open : null,
        credentialLookup: (id) async => id == 'h2' ? null : const SshCredentials(password: 'x'),
        dialer: (h, creds) async {
          dialCount++;
          return FleetDialedConnection(sftp: FakeRemoteFs(), close: () {});
        },
      );

      service.start();
      await _untilDone(service);

      final byId = {for (final p in service.hosts) p.hostId: p};
      expect(byId['h1']!.status, FleetHostStatus.done);
      expect(byId['h2']!.status, FleetHostStatus.failed);
      expect(
        byId['h2']!.failureReason,
        FleetHostFailureReason.missingCredentials,
      );
      expect(byId['h2']!.files.single.status, FleetFileStatus.failed);
      expect(dialCount, 0, reason: 'h2 has no session and no credentials, '
          'so nothing should ever be dialled for it');
    });
  });

  group('cancel', () {
    test('stops hosts still queued and leaves already-finished hosts '
        'reported', () async {
      final file = await writeLocalFile('a.txt', 'x');
      late FleetPushService service;
      final started = <String>[];

      service = FleetPushService(
        request: FleetPushRequest(
          hosts: [host('h1'), host('h2'), host('h3'), host('h4')],
          files: [file],
          destinationDirectory: '/home/dev',
          overwritePolicy: FleetOverwritePolicy.overwrite,
        ),
        openSessionLookup: (_) => null,
        credentialLookup: (_) async => const SshCredentials(password: 'x'),
        maxConcurrentHosts: 1,
        dialer: (h, creds) async {
          started.add(h.id);
          // Only h1 is allowed to actually finish before cancel() lands;
          // every later host should never even get this far.
          if (h.id != 'h1') {
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
          return FleetDialedConnection(sftp: FakeRemoteFs(), close: () {});
        },
      );

      service.start();
      // Give h1 (cap of 1) time to run to completion, then cancel while
      // h2/h3/h4 are still queued behind it.
      await Future<void>.delayed(const Duration(milliseconds: 60));
      service.cancel();
      await _untilDone(service);

      final byId = {for (final p in service.hosts) p.hostId: p};
      expect(byId['h1']!.status, FleetHostStatus.done);
      expect(byId['h2']!.status, FleetHostStatus.cancelled);
      expect(byId['h3']!.status, FleetHostStatus.cancelled);
      expect(byId['h4']!.status, FleetHostStatus.cancelled);
      // h3 and h4 were still in the pending queue and must never have been
      // dialled at all.
      expect(started, contains('h1'));
      expect(started, isNot(contains('h3')));
      expect(started, isNot(contains('h4')));
    });
  });

  group('overwrite policy', () {
    Future<FleetPushService> runWithPolicy(
      FleetOverwritePolicy policy,
      FakeRemoteFs fs,
    ) async {
      final file = await writeLocalFile('report.pdf', 'contents');
      fs.files['/home/dev/report.pdf'] = 999; // already there

      final service = FleetPushService(
        request: FleetPushRequest(
          hosts: [host('h1')],
          files: [file],
          destinationDirectory: '/home/dev',
          overwritePolicy: policy,
        ),
        openSessionLookup: (_) => null,
        credentialLookup: (_) async => const SshCredentials(password: 'x'),
        dialer: (h, creds) async =>
            FleetDialedConnection(sftp: fs, close: () {}),
      );
      service.start();
      await _untilDone(service);
      return service;
    }

    test('overwrite replaces the existing file', () async {
      final fs = FakeRemoteFs();
      final service = await runWithPolicy(FleetOverwritePolicy.overwrite, fs);

      final file = service.hosts.single.files.single;
      expect(file.status, FleetFileStatus.done);
      expect(fs.files['/home/dev/report.pdf'], 8); // 'contents'.length
    });

    test('skipExisting marks the file skipped and leaves the server copy '
        'alone', () async {
      final fs = FakeRemoteFs();
      final service =
          await runWithPolicy(FleetOverwritePolicy.skipExisting, fs);

      final file = service.hosts.single.files.single;
      expect(file.status, FleetFileStatus.skipped);
      expect(fs.files['/home/dev/report.pdf'], 999); // untouched
      expect(service.hosts.single.status, FleetHostStatus.done);
    });

    test('failOnExisting fails that file (and so that host)', () async {
      final fs = FakeRemoteFs();
      final service =
          await runWithPolicy(FleetOverwritePolicy.failOnExisting, fs);

      final file = service.hosts.single.files.single;
      expect(file.status, FleetFileStatus.failed);
      expect(fs.files['/home/dev/report.pdf'], 999); // untouched
      expect(service.hosts.single.status, FleetHostStatus.failed);
    });
  });

  group('temp-name-then-rename', () {
    test('a fresh-dial upload never appears under the final name until it '
        'is whole, and a failure leaves nothing under either name', () async {
      final file = await writeLocalFile('big.bin', 'abcdefgh');
      final fs = FakeRemoteFs();

      final service = FleetPushService(
        request: FleetPushRequest(
          hosts: [host('h1')],
          files: [file],
          destinationDirectory: '/home/dev',
          overwritePolicy: FleetOverwritePolicy.overwrite,
        ),
        openSessionLookup: (_) => null,
        credentialLookup: (_) async => const SshCredentials(password: 'x'),
        dialer: (h, creds) async {
          return FleetDialedConnection(
            sftp: _FailingFirstWriteFs(fs),
            close: () {},
          );
        },
      );
      service.start();
      await _untilDone(service);

      expect(service.hosts.single.files.single.status, FleetFileStatus.failed);
      // Nothing under the final name, and nothing left under a temp name
      // either — the writer's abort() removed it.
      expect(fs.files.containsKey('/home/dev/big.bin'), isFalse);
      expect(fs.files.keys.where((k) => k.contains('.ssg-fleet-')), isEmpty);
    });

    test('a queued (open-session) upload also only appears under the final '
        'name after it is whole', () async {
      final file = await writeLocalFile('notes.md', 'hello');
      final fs = FakeRemoteFs();
      final open = FakeOpenSession(fs);

      final service = FleetPushService(
        request: FleetPushRequest(
          hosts: [host('h1')],
          files: [file],
          destinationDirectory: '/home/dev',
          overwritePolicy: FleetOverwritePolicy.overwrite,
        ),
        openSessionLookup: (_) => open,
        credentialLookup: (_) async => null,
        dialer: (h, creds) async =>
            throw UnimplementedError('h1 has an open session'),
      );
      service.start();
      await _untilDone(service);

      expect(service.hosts.single.files.single.status, FleetFileStatus.done);
      expect(fs.files['/home/dev/notes.md'], 5);
      // The queue wrote to a temporary name, not the final one directly.
      expect(open.queuedPaths.single, isNot('/home/dev/notes.md'));
      expect(open.queuedPaths.single, contains('.ssg-fleet-'));
      // And it was renamed away — nothing left under the temp name.
      expect(fs.files.keys.where((k) => k.contains('.ssg-fleet-')), isEmpty);
    });
  });

  group('destination "~"', () {
    test('resolves against each host\'s own home directory rather than '
        'being sent to the server literally', () async {
      final file = await writeLocalFile('a.txt', 'x');
      final fs = FakeRemoteFs();

      final service = FleetPushService(
        request: FleetPushRequest(
          hosts: [host('h1')],
          files: [file],
          destinationDirectory: '~/uploads',
          overwritePolicy: FleetOverwritePolicy.overwrite,
        ),
        openSessionLookup: (_) => null,
        credentialLookup: (_) async => const SshCredentials(password: 'x'),
        dialer: (h, creds) async =>
            FleetDialedConnection(sftp: fs, close: () {}),
      );
      service.start();
      await _untilDone(service);

      expect(service.hosts.single.files.single.status, FleetFileStatus.done);
      // FakeRemoteFs.home() answers '/home/dev'.
      expect(fs.files.containsKey('/home/dev/uploads/a.txt'), isTrue);
    });
  });

  group('retryFailedHosts', () {
    test('requeues only the failed hosts and can succeed the second time',
        () async {
      final file = await writeLocalFile('a.txt', 'x');
      var attempt = 0;

      final service = FleetPushService(
        request: FleetPushRequest(
          hosts: [host('h1'), host('h2')],
          files: [file],
          destinationDirectory: '/home/dev',
          overwritePolicy: FleetOverwritePolicy.overwrite,
        ),
        openSessionLookup: (_) => null,
        credentialLookup: (_) async => const SshCredentials(password: 'x'),
        dialer: (h, creds) async {
          if (h.id == 'h2' && attempt == 0) {
            attempt++;
            throw const SshConnectionExceptionStub('flaky');
          }
          return FleetDialedConnection(sftp: FakeRemoteFs(), close: () {});
        },
      );

      service.start();
      await _untilDone(service);
      expect(service.hosts.firstWhere((p) => p.hostId == 'h2').status,
          FleetHostStatus.failed);

      service.retryFailedHosts();
      await _untilDone(service);

      final byId = {for (final p in service.hosts) p.hostId: p};
      expect(byId['h1']!.status, FleetHostStatus.done);
      expect(byId['h2']!.status, FleetHostStatus.done);
      expect(service.summary, '2 of 2 succeeded');
    });
  });
}

/// Wraps a [FakeRemoteFs] so the very first [openWrite] throws, simulating a
/// write that fails partway (the writer this hands back fails on `add`).
class _FailingFirstWriteFs implements RemoteFileSystem {
  _FailingFirstWriteFs(this._inner);
  final FakeRemoteFs _inner;

  @override
  Future<RemoteFileWriter> openWrite(String remotePath) async {
    final writer = _FakeWriter(_inner, remotePath)..failOnAdd = true;
    return writer;
  }

  @override
  Future<bool> exists(String path) => _inner.exists(path);
  @override
  Future<int?> sizeOf(String path) => _inner.sizeOf(path);
  @override
  Future<void> remove(String path) => _inner.remove(path);
  @override
  Future<void> rename(String from, String to) => _inner.rename(from, to);
  @override
  Future<String> home() => _inner.home();
  @override
  Future<String> resolve(String path) => _inner.resolve(path);
  @override
  Future<List<RemoteEntry>> list(String path) => _inner.list(path);
  @override
  Future<int> download(
    String remotePath, {
    required Future<void> Function(Uint8List chunk) write,
    TransferProgress? onProgress,
    CancelCheck? isCancelled,
  }) =>
      _inner.download(
        remotePath,
        write: write,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );
  @override
  Future<int> upload(
    String localPath,
    String remotePath, {
    TransferProgress? onProgress,
    CancelCheck? isCancelled,
  }) =>
      _inner.upload(
        localPath,
        remotePath,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );
  @override
  Future<void> mkdir(String path) => _inner.mkdir(path);
  @override
  Future<void> removeDirectory(String path) => _inner.removeDirectory(path);
  @override
  Future<bool> isDirectory(String path) => _inner.isDirectory(path);
  @override
  Future<void> close() => _inner.close();
}

/// A stand-in for `SshConnectionException` (which needs `dartssh2` transitively
/// through `ssh_service.dart` — fine to import, but this keeps the dial
/// failure in these tests independent of that type's exact shape).
class SshConnectionExceptionStub implements Exception {
  const SshConnectionExceptionStub(this.message);
  final String message;
  @override
  String toString() => message;
}

Future<void> _untilDone(FleetPushService service) async {
  while (service.isRunning) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  // One more tick so the final publish (worker decrement) has landed.
  await Future<void>.delayed(Duration.zero);
}
