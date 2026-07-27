import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/transfer_queue.dart';

void main() {
  test('a queued transfer runs and completes', () async {
    final queue = TransferQueue(
      executor: (task, handle) async {
        handle.setTotal(100);
        handle.report(100);
        handle.setDestination('Downloads/a.txt');
      },
    );
    addTearDown(queue.dispose);

    final task = queue.enqueueDownload(remotePath: '/a.txt', name: 'a.txt');
    // The pump starts eagerly, so the first task is already running by the
    // time enqueue returns.
    expect(task.status, TransferStatus.running);

    await queue.changes.firstWhere(
      (tasks) => tasks.every((t) => t.status.isFinished),
    );

    expect(task.status, TransferStatus.completed);
    expect(task.transferredBytes, 100);
    expect(task.percent, 100);
    expect(task.destination, 'Downloads/a.txt');
  });

  test('transfers run one at a time, in order', () async {
    final running = <String>[];
    var concurrent = 0;
    var maxConcurrent = 0;

    final queue = TransferQueue(
      executor: (task, handle) async {
        concurrent++;
        maxConcurrent = concurrent > maxConcurrent ? concurrent : maxConcurrent;
        running.add(task.name);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        concurrent--;
      },
    );
    addTearDown(queue.dispose);

    queue.enqueueDownload(remotePath: '/1', name: 'one');
    queue.enqueueDownload(remotePath: '/2', name: 'two');
    queue.enqueueDownload(remotePath: '/3', name: 'three');

    await queue.changes.firstWhere(
      (tasks) =>
          tasks.length == 3 && tasks.every((t) => t.status.isFinished),
    );

    expect(running, ['one', 'two', 'three']);
    expect(maxConcurrent, 1, reason: 'the queue must serialise transfers');
  });

  test('progress is published as it is reported', () async {
    final seen = <int>[];
    final completer = Completer<void>();

    final queue = TransferQueue(
      executor: (task, handle) async {
        handle.setTotal(4);
        for (var i = 1; i <= 4; i++) {
          handle.report(i);
          await Future<void>.delayed(Duration.zero);
        }
        completer.complete();
      },
    );
    addTearDown(queue.dispose);

    final sub = queue.changes.listen((tasks) {
      if (tasks.isNotEmpty) seen.add(tasks.first.transferredBytes);
    });
    addTearDown(sub.cancel);

    final task = queue.enqueueDownload(remotePath: '/f', name: 'f');
    await completer.future;
    await Future<void>.delayed(Duration.zero);

    expect(seen, containsAllInOrder([1, 2, 3, 4]));
    expect(task.progress, 1.0);
  });

  test('cancelling a queued transfer stops it ever starting', () async {
    var started = 0;
    final gate = Completer<void>();

    final queue = TransferQueue(
      executor: (task, handle) async {
        started++;
        if (task.name == 'first') await gate.future;
      },
    );
    addTearDown(queue.dispose);

    queue.enqueueDownload(remotePath: '/1', name: 'first');
    final second = queue.enqueueDownload(remotePath: '/2', name: 'second');

    // Let the first one start and block.
    await Future<void>.delayed(Duration.zero);
    queue.cancel(second.id);
    gate.complete();

    await queue.changes.firstWhere(
      (tasks) => tasks.every((t) => t.status.isFinished),
    );

    expect(second.status, TransferStatus.cancelled);
    expect(started, 1, reason: 'a cancelled task must never reach the executor');
  });

  test('cancelling a running transfer flags the handle and marks it cancelled',
      () async {
    var sawCancel = false;
    final started = Completer<void>();

    final queue = TransferQueue(
      executor: (task, handle) async {
        started.complete();
        for (var i = 0; i < 100; i++) {
          if (handle.isCancelled) {
            sawCancel = true;
            return;
          }
          handle.report(i);
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      },
    );
    addTearDown(queue.dispose);

    final task = queue.enqueueDownload(remotePath: '/big', name: 'big');
    await started.future;
    queue.cancel(task.id);

    await queue.changes.firstWhere(
      (tasks) => tasks.every((t) => t.status.isFinished),
    );

    expect(sawCancel, isTrue);
    expect(task.status, TransferStatus.cancelled);
  });

  test('an executor returning normally after a cancel does not report success',
      () async {
    final started = Completer<void>();
    final queue = TransferQueue(
      executor: (task, handle) async {
        started.complete();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        // Returns cleanly, unaware of the cancel.
      },
    );
    addTearDown(queue.dispose);

    final task = queue.enqueueDownload(remotePath: '/x', name: 'x');
    await started.future;
    queue.cancel(task.id);

    await queue.changes.firstWhere(
      (tasks) => tasks.every((t) => t.status.isFinished),
    );
    expect(task.status, TransferStatus.cancelled);
  });

  test('a failure is recorded and does not stall the queue', () async {
    final queue = TransferQueue(
      executor: (task, handle) async {
        if (task.name == 'bad') throw Exception('disk full');
        handle.report(1);
      },
    );
    addTearDown(queue.dispose);

    final bad = queue.enqueueDownload(remotePath: '/bad', name: 'bad');
    final good = queue.enqueueDownload(remotePath: '/good', name: 'good');

    await queue.changes.firstWhere(
      (tasks) => tasks.length == 2 && tasks.every((t) => t.status.isFinished),
    );

    expect(bad.status, TransferStatus.failed);
    expect(bad.error, contains('disk full'));
    expect(good.status, TransferStatus.completed);
  });

  test('a TransferCancelled thrown by the executor reads as cancelled', () async {
    final queue = TransferQueue(
      executor: (task, handle) async => throw const TransferCancelled(),
    );
    addTearDown(queue.dispose);

    final task = queue.enqueueDownload(remotePath: '/x', name: 'x');
    await queue.changes.firstWhere(
      (tasks) => tasks.every((t) => t.status.isFinished),
    );

    expect(task.status, TransferStatus.cancelled);
    expect(task.error, isNull);
  });

  test('aggregate progress spans every unfinished transfer', () async {
    final gate = Completer<void>();
    final queue = TransferQueue(
      executor: (task, handle) async {
        handle.report(50);
        await gate.future;
      },
    );
    addTearDown(() async {
      if (!gate.isCompleted) gate.complete();
      await queue.dispose();
    });

    queue.enqueueDownload(remotePath: '/1', name: 'one', totalBytes: 100);
    queue.enqueueDownload(remotePath: '/2', name: 'two', totalBytes: 100);
    await Future<void>.delayed(Duration.zero);

    // One running at 50/100, one queued at 0/100.
    expect(queue.activeCount, 2);
    expect(queue.aggregateProgress, closeTo(0.25, 0.001));
  });

  test('clearFinished drops only the finished rows', () async {
    final gate = Completer<void>();
    final queue = TransferQueue(
      executor: (task, handle) async {
        if (task.name == 'slow') await gate.future;
      },
    );
    addTearDown(() async {
      if (!gate.isCompleted) gate.complete();
      await queue.dispose();
    });

    final done = queue.enqueueDownload(remotePath: '/1', name: 'quick');
    await queue.changes.firstWhere(
      (tasks) => tasks.any((t) => t.id == done.id && t.status.isFinished),
    );
    queue.enqueueDownload(remotePath: '/2', name: 'slow');
    await Future<void>.delayed(Duration.zero);

    queue.clearFinished();
    expect(queue.tasks.map((t) => t.name), ['slow']);
  });

  test('an upload carries its local source and remote destination', () async {
    final queue = TransferQueue(executor: (task, handle) async {});
    addTearDown(queue.dispose);

    final task = queue.enqueueUpload(
      localPath: '/data/cache/notes.md',
      remotePath: '/home/dev/notes.md',
      name: 'notes.md',
      totalBytes: 12,
    );

    expect(task.direction, TransferDirection.upload);
    expect(task.localPath, '/data/cache/notes.md');
    expect(task.remotePath, '/home/dev/notes.md');
    expect(task.totalBytes, 12);
  });

  group('retry', () {
    test('re-queues a failed transfer with everything it needs to run again',
        () async {
      var attempts = 0;
      final queue = TransferQueue(
        executor: (task, handle) async {
          attempts++;
          if (attempts == 1) throw StateError('link went down');
        },
      );
      addTearDown(queue.dispose);

      final failed = queue.enqueueDownload(
        remotePath: '/srv/logs/app.log',
        name: 'app.log',
        saveAsName: 'app.log',
        overwrite: true,
        relativeDirectory: 'logs/app',
      );
      await queue.changes.firstWhere(
        (tasks) => tasks.any((t) => t.status == TransferStatus.failed),
      );
      expect(failed.error, contains('link went down'));

      final again = queue.retry(failed.id)!;
      await queue.changes.firstWhere(
        (tasks) => tasks.every((t) => t.status.isFinished),
      );

      expect(again.status, TransferStatus.completed);
      expect(again.remotePath, '/srv/logs/app.log');
      expect(again.saveAsName, 'app.log');
      expect(again.overwrite, isTrue);
      expect(again.relativeDirectory, 'logs/app');
      // The failed row goes with the retry: one file, one row, no history of
      // an attempt the user has already replaced.
      expect(queue.tasks.map((t) => t.id), [again.id]);
    });

    test('an upload retry keeps its staged source and size', () async {
      var attempts = 0;
      final queue = TransferQueue(
        executor: (task, handle) async {
          attempts++;
          if (attempts == 1) throw StateError('connection reset');
        },
      );
      addTearDown(queue.dispose);

      final failed = queue.enqueueUpload(
        localPath: '/data/cache/uploads/b1/0/notes.md',
        remotePath: '/home/dev/notes.md',
        name: 'notes.md',
        totalBytes: 42,
      );
      await queue.changes.firstWhere(
        (tasks) => tasks.any((t) => t.status == TransferStatus.failed),
      );

      final again = queue.retry(failed.id)!;
      expect(again.direction, TransferDirection.upload);
      expect(again.localPath, '/data/cache/uploads/b1/0/notes.md');
      expect(again.totalBytes, 42);
    });

    test('only failures can be retried', () async {
      final queue = TransferQueue(executor: (task, handle) async {});
      addTearDown(queue.dispose);

      final done = queue.enqueueDownload(remotePath: '/a', name: 'a');
      await queue.changes.firstWhere(
        (tasks) => tasks.every((t) => t.status.isFinished),
      );

      // A cancelled transfer is a decision the user made, not something to
      // quietly offer to undo; a completed one has nothing to redo.
      expect(queue.retry(done.id), isNull);
      expect(queue.retry('no-such-id'), isNull);
      expect(queue.tasks, hasLength(1));
    });
  });

  test('progress is indeterminate until a total is known', () {
    final task = TransferTask(
      id: 't',
      name: 'x',
      remotePath: '/x',
      direction: TransferDirection.download,
    );
    expect(task.progress, isNull);
    expect(task.percent, isNull);

    task.totalBytes = 200;
    task.transferredBytes = 50;
    expect(task.percent, 25);

    // A server that under-reports its own file size must not push the bar
    // past the end of the track.
    task.transferredBytes = 400;
    expect(task.progress, 1.0);
  });
}
