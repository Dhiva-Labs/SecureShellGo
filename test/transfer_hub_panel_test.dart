import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/transfer_hub.dart';
import 'package:secure_shell_go/services/transfer_queue.dart';
import 'package:secure_shell_go/theme.dart';
import 'package:secure_shell_go/widgets/transfer_hub_panel.dart';

void main() {
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

  Future<void> pump(WidgetTester tester, TransferHub hub) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              actions: [TransferHubAction(hub: hub, onTap: () {})],
            ),
          ),
        ),
      );

  testWidgets('shows nothing when no session has ever queued a transfer',
      (tester) async {
    final hub = TransferHub(
      sessionsChanged: sessionsChanged.stream,
      sources: () => const [],
    );
    addTearDown(hub.dispose);

    await pump(tester, hub);

    expect(find.byIcon(Icons.swap_calls), findsNothing);
  });

  testWidgets('badge count tracks the number of active transfers',
      (tester) async {
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
    await pump(tester, hub);

    var badge = tester.widget<Badge>(find.byType(Badge));
    expect(badge.isLabelVisible, isTrue);
    expect((badge.label as Text?)?.data, '1');

    // No delay needed before the next pump: TransferQueue.enqueueDownload
    // starts the task (and publishes) synchronously — see
    // transfer_queue_test.dart's "the pump starts eagerly" note — and
    // `pump()` here rebuilds the widget fresh against the queues' current
    // state regardless. A real `Future.delayed` would hang forever: widget
    // tests virtualize Timer, and nothing here ever advances the fake clock.
    queueB.enqueueDownload(remotePath: '/b', name: 'b.txt');
    await pump(tester, hub);

    badge = tester.widget<Badge>(find.byType(Badge));
    expect((badge.label as Text?)?.data, '2');

    // One finishes: the badge count must follow it down, not just up.
    gateA.complete();
    await hub.changes.firstWhere(
      (items) => items.any((i) => i.task.name == 'a.txt' && i.task.status.isFinished),
    );
    await pump(tester, hub);

    badge = tester.widget<Badge>(find.byType(Badge));
    expect((badge.label as Text?)?.data, '1');
  });

  testWidgets(
      'a failure with nothing active shows a danger badge and no count',
      (tester) async {
    final queueA = queue(run: (task, handle) async => throw StateError('x'));

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
    await pump(tester, hub);

    final badge = tester.widget<Badge>(find.byType(Badge));
    expect(badge.isLabelVisible, isTrue);
    expect(badge.label, isNull);
    expect(badge.backgroundColor, AppTheme.danger);
  });
}
