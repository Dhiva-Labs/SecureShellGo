import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/transfer_hub.dart';
import 'package:secure_shell_go/services/transfer_queue.dart';

void main() {
  // A minimal stand-in for SessionManager.changes: TransferHub only needs a
  // stream to know "re-read the source list now" and a callback that hands
  // back the current sources, so tests drive both directly instead of
  // building a real SessionManager/SessionController/SSH transport just to
  // prove the merge logic.
  late StreamController<void> sessionsChanged;

  setUp(() {
    sessionsChanged = StreamController<void>.broadcast();
  });

  tearDown(() async {
    await sessionsChanged.close();
  });

  TransferQueue queue({Future<void> Function(TransferTask, TransferHandle)? run}) {
    return TransferQueue(executor: run ?? (task, handle) async {});
  }

  test('starts empty when there are no sessions', () {
    final hub = TransferHub(
      sessionsChanged: sessionsChanged.stream,
      sources: () => const [],
    );
    addTearDown(hub.dispose);

    expect(hub.items, isEmpty);
    expect(hub.activeCount, 0);
  });

  test('merges tasks from more than one session\'s queue', () async {
    final gate = Completer<void>();
    final queueA = queue(run: (task, handle) async => gate.future);
    final queueB = queue();

    final hub = TransferHub(
      sessionsChanged: sessionsChanged.stream,
      sources: () => [
        TransferQueueSource(sessionId: 's1', sessionLabel: 'Box A', queue: queueA),
        TransferQueueSource(sessionId: 's2', sessionLabel: 'Box B', queue: queueB),
      ],
    );
    addTearDown(() async {
      if (!gate.isCompleted) gate.complete();
      await hub.dispose();
    });

    queueA.enqueueDownload(remotePath: '/a', name: 'a.txt');
    queueB.enqueueDownload(remotePath: '/b', name: 'b.txt');
    await Future<void>.delayed(Duration.zero);

    expect(hub.items, hasLength(2));
    expect(
      hub.items.map((i) => i.sessionLabel),
      unorderedEquals(['Box A', 'Box B']),
    );
    expect(
      hub.items.map((i) => i.task.name),
      unorderedEquals(['a.txt', 'b.txt']),
    );
  });

  test('republishes when a task on any session\'s queue changes', () async {
    final started = Completer<void>();
    final gate = Completer<void>();
    final queueA = queue(
      run: (task, handle) async {
        started.complete();
        await gate.future;
      },
    );

    final hub = TransferHub(
      sessionsChanged: sessionsChanged.stream,
      sources: () => [
        TransferQueueSource(sessionId: 's1', sessionLabel: 'Box A', queue: queueA),
      ],
    );
    addTearDown(() async {
      if (!gate.isCompleted) gate.complete();
      await hub.dispose();
    });

    final seen = <TransferStatus>[];
    final sub = hub.changes.listen((items) {
      if (items.isNotEmpty) seen.add(items.first.task.status);
    });
    addTearDown(sub.cancel);

    queueA.enqueueDownload(remotePath: '/a', name: 'a.txt', totalBytes: 10);
    await started.future;
    gate.complete();

    await hub.changes.firstWhere(
      (items) => items.isNotEmpty && items.first.task.status.isFinished,
    );

    expect(seen, contains(TransferStatus.running));
    expect(seen.last, TransferStatus.completed);
  });

  test('a new session opening is picked up without rebuilding the hub',
      () async {
    final queueA = queue();
    var sources = [
      TransferQueueSource(sessionId: 's1', sessionLabel: 'Box A', queue: queueA),
    ];

    final hub = TransferHub(
      sessionsChanged: sessionsChanged.stream,
      sources: () => sources,
    );
    addTearDown(hub.dispose);

    queueA.enqueueDownload(remotePath: '/a', name: 'a.txt');
    await Future<void>.delayed(Duration.zero);
    expect(hub.items, hasLength(1));

    final queueB = queue();
    sources = [
      ...sources,
      TransferQueueSource(sessionId: 's2', sessionLabel: 'Box B', queue: queueB),
    ];
    sessionsChanged.add(null);
    await Future<void>.delayed(Duration.zero);

    queueB.enqueueDownload(remotePath: '/b', name: 'b.txt');
    await Future<void>.delayed(Duration.zero);

    expect(hub.items, hasLength(2));
  });

  test('a session closing drops its tasks from the merged list', () async {
    final queueA = queue();
    final queueB = queue();
    var sources = [
      TransferQueueSource(sessionId: 's1', sessionLabel: 'Box A', queue: queueA),
      TransferQueueSource(sessionId: 's2', sessionLabel: 'Box B', queue: queueB),
    ];

    final hub = TransferHub(
      sessionsChanged: sessionsChanged.stream,
      sources: () => sources,
    );
    addTearDown(hub.dispose);

    queueA.enqueueDownload(remotePath: '/a', name: 'a.txt');
    queueB.enqueueDownload(remotePath: '/b', name: 'b.txt');
    await Future<void>.delayed(Duration.zero);
    expect(hub.items, hasLength(2));

    // Session 2 closes: its source drops out of the list SessionManager
    // would hand back.
    sources = [sources.first];
    sessionsChanged.add(null);
    await Future<void>.delayed(Duration.zero);

    expect(hub.items, hasLength(1));
    expect(hub.items.single.sessionId, 's1');

    // A change on the now-untracked queue must not resurrect it or throw.
    queueB.enqueueDownload(remotePath: '/c', name: 'c.txt');
    await Future<void>.delayed(Duration.zero);
    expect(hub.items, hasLength(1));
  });

  test('activeCount sums active tasks across every session', () async {
    final gateA = Completer<void>();
    final gateB = Completer<void>();
    final queueA = queue(run: (task, handle) async => gateA.future);
    final queueB = queue(run: (task, handle) async => gateB.future);

    final hub = TransferHub(
      sessionsChanged: sessionsChanged.stream,
      sources: () => [
        TransferQueueSource(sessionId: 's1', sessionLabel: 'Box A', queue: queueA),
        TransferQueueSource(sessionId: 's2', sessionLabel: 'Box B', queue: queueB),
      ],
    );
    addTearDown(() async {
      if (!gateA.isCompleted) gateA.complete();
      if (!gateB.isCompleted) gateB.complete();
      await hub.dispose();
    });

    queueA.enqueueDownload(remotePath: '/a', name: 'a.txt');
    queueB.enqueueDownload(remotePath: '/b', name: 'b.txt');
    await Future<void>.delayed(Duration.zero);

    expect(hub.activeCount, 2);

    gateA.complete();
    await hub.changes.firstWhere(
      (items) => items.any((i) => i.task.name == 'a.txt' && i.task.status.isFinished),
    );

    expect(hub.activeCount, 1);
  });

  test('hasFailed and hasFinished reflect status across every session',
      () async {
    final queueA = queue(
      run: (task, handle) async => throw StateError('boom'),
    );
    final queueB = queue();

    final hub = TransferHub(
      sessionsChanged: sessionsChanged.stream,
      sources: () => [
        TransferQueueSource(sessionId: 's1', sessionLabel: 'Box A', queue: queueA),
        TransferQueueSource(sessionId: 's2', sessionLabel: 'Box B', queue: queueB),
      ],
    );
    addTearDown(hub.dispose);

    queueA.enqueueDownload(remotePath: '/a', name: 'a.txt');
    await hub.changes.firstWhere(
      (items) => items.any((i) => i.task.status == TransferStatus.failed),
    );

    expect(hub.hasFailed, isTrue);
    expect(hub.hasFinished, isTrue);
  });

  test('retry re-enqueues on the failed task\'s own session queue, not '
      'another one', () async {
    var attempts = 0;
    final queueA = queue(
      run: (task, handle) async {
        attempts++;
        if (attempts == 1) throw StateError('link down');
      },
    );
    final queueB = queue();

    final hub = TransferHub(
      sessionsChanged: sessionsChanged.stream,
      sources: () => [
        TransferQueueSource(sessionId: 's1', sessionLabel: 'Box A', queue: queueA),
        TransferQueueSource(sessionId: 's2', sessionLabel: 'Box B', queue: queueB),
      ],
    );
    addTearDown(hub.dispose);

    queueA.enqueueDownload(remotePath: '/a', name: 'a.txt');
    await hub.changes.firstWhere(
      (items) => items.any((i) => i.task.status == TransferStatus.failed),
    );

    final failed = hub.items.firstWhere((i) => i.task.name == 'a.txt');
    hub.retry(failed.sessionId, failed.task.id);

    await hub.changes.firstWhere(
      (items) => items.any(
        (i) => i.task.name == 'a.txt' && i.task.status == TransferStatus.completed,
      ),
    );

    // Retry went through queueA's own public API — queueB never saw a task.
    expect(queueB.tasks, isEmpty);
    expect(queueA.tasks, hasLength(1));
    expect(queueA.tasks.single.status, TransferStatus.completed);
  });

  test('retry against an unknown session id is a harmless no-op', () async {
    final queueA = queue(
      run: (task, handle) async => throw StateError('boom'),
    );

    final hub = TransferHub(
      sessionsChanged: sessionsChanged.stream,
      sources: () => [
        TransferQueueSource(sessionId: 's1', sessionLabel: 'Box A', queue: queueA),
      ],
    );
    addTearDown(hub.dispose);

    queueA.enqueueDownload(remotePath: '/a', name: 'a.txt');
    await hub.changes.firstWhere(
      (items) => items.any((i) => i.task.status == TransferStatus.failed),
    );

    expect(
      () => hub.retry('no-such-session', hub.items.first.task.id),
      returnsNormally,
    );
  });

  test('cancel reaches the right session\'s queue', () async {
    final gate = Completer<void>();
    final queueA = queue(run: (task, handle) async => gate.future);
    final queueB = queue();

    final hub = TransferHub(
      sessionsChanged: sessionsChanged.stream,
      sources: () => [
        TransferQueueSource(sessionId: 's1', sessionLabel: 'Box A', queue: queueA),
        TransferQueueSource(sessionId: 's2', sessionLabel: 'Box B', queue: queueB),
      ],
    );
    addTearDown(() async {
      if (!gate.isCompleted) gate.complete();
      await hub.dispose();
    });

    final task = queueA.enqueueDownload(remotePath: '/a', name: 'a.txt');
    await Future<void>.delayed(Duration.zero);

    hub.cancel('s1', task.id);

    expect(task.status, TransferStatus.cancelled);
  });

  test('clearCompleted clears finished rows on every session at once',
      () async {
    final queueA = queue();
    final queueB = queue();

    final hub = TransferHub(
      sessionsChanged: sessionsChanged.stream,
      sources: () => [
        TransferQueueSource(sessionId: 's1', sessionLabel: 'Box A', queue: queueA),
        TransferQueueSource(sessionId: 's2', sessionLabel: 'Box B', queue: queueB),
      ],
    );
    addTearDown(hub.dispose);

    queueA.enqueueDownload(remotePath: '/a', name: 'a.txt');
    queueB.enqueueDownload(remotePath: '/b', name: 'b.txt');
    await hub.changes.firstWhere(
      (items) => items.length == 2 && items.every((i) => i.task.status.isFinished),
    );

    hub.clearCompleted();

    expect(queueA.tasks, isEmpty);
    expect(queueB.tasks, isEmpty);
    expect(hub.items, isEmpty);
  });

  test('newest transfer across every session sorts first', () async {
    final queueA = queue();
    final queueB = queue();

    final hub = TransferHub(
      sessionsChanged: sessionsChanged.stream,
      sources: () => [
        TransferQueueSource(sessionId: 's1', sessionLabel: 'Box A', queue: queueA),
        TransferQueueSource(sessionId: 's2', sessionLabel: 'Box B', queue: queueB),
      ],
    );
    addTearDown(hub.dispose);

    // Both queues hand out ids starting at "transfer-0" independently, so
    // an id alone cannot say which of these came later — the hub has to
    // track that itself.
    queueA.enqueueDownload(remotePath: '/1', name: 'first');
    await Future<void>.delayed(Duration.zero);
    queueB.enqueueDownload(remotePath: '/2', name: 'second');
    await Future<void>.delayed(Duration.zero);
    queueA.enqueueDownload(remotePath: '/3', name: 'third');
    await Future<void>.delayed(Duration.zero);

    expect(hub.items.map((i) => i.task.name), ['third', 'second', 'first']);
  });
}
