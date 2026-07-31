import 'dart:async';

import 'session_manager.dart';
import 'transfer_queue.dart';

/// One live session's queue, as [TransferHub] needs it: an id to route
/// retry/cancel/clear-completed back to the right queue, a label for the
/// row, and the queue itself.
///
/// [TransferHub.forSessionManager] builds a list of these from
/// [SessionManager]'s own [ManagedSession]s for production use. Kept as its
/// own tiny shape — rather than [TransferHub] depending on [ManagedSession]
/// directly — so a test can hand the hub a list of these wrapped around bare
/// [TransferQueue]s: no fake SSH transport and no fake [SessionController]
/// needed just to prove the merge logic works.
class TransferQueueSource {
  const TransferQueueSource({
    required this.sessionId,
    required this.sessionLabel,
    required this.queue,
  });

  final String sessionId;
  final String sessionLabel;
  final TransferQueue queue;
}

/// One transfer, with which session it belongs to attached — the one thing
/// the unified panel needs that a single session's [TransferQueue] never had
/// to say, because it only ever had one session to be about.
class AggregatedTransfer {
  const AggregatedTransfer({
    required this.sessionId,
    required this.sessionLabel,
    required this.task,
  });

  final String sessionId;
  final String sessionLabel;
  final TransferTask task;
}

/// Merges every open session's [TransferQueue] into one feed, for a single
/// "every transfer, on every server" panel.
///
/// [TransferQueue] itself is unchanged by this and stays exactly what it was
/// — per-session, sequential, with no idea this class exists. This only ever
/// *reads* a queue's existing public stream and snapshot, and *calls* its
/// existing `retry` / `cancel` / `clearFinished`; nothing here reimplements
/// what a transfer does, only which queue a button on the merged panel
/// should reach.
class TransferHub {
  TransferHub({
    required Stream<void> sessionsChanged,
    required List<TransferQueueSource> Function() sources,
  }) : _sourcesOf = sources {
    _resync();
    _sessionsSub = sessionsChanged.listen((_) => _resync());
  }

  /// The production wiring: follows every session [sessions] currently has
  /// open, and each one's own [SessionController.transfers] queue —
  /// downstream code never has to know that indirection exists.
  factory TransferHub.forSessionManager(SessionManager sessions) {
    return TransferHub(
      sessionsChanged: sessions.changes,
      sources: () => [
        for (final session in sessions.sessions)
          TransferQueueSource(
            sessionId: session.id,
            sessionLabel: session.host.displayName,
            queue: session.controller.transfers,
          ),
      ],
    );
  }

  final List<TransferQueueSource> Function() _sourcesOf;
  StreamSubscription<void>? _sessionsSub;

  /// One subscription per live session's queue, so a change on any of them
  /// republishes the merged snapshot. Keyed by session id: a session closing
  /// tears its subscription down cleanly rather than leaking a listener onto
  /// a queue nobody can reach any more. Session ids are unique for the life
  /// of the process (see [ManagedSession]), so a closed id is never reused
  /// out from under a still-open entry here.
  final Map<String, StreamSubscription<List<TransferTask>>> _queueSubs = {};

  /// The order each `session:task` pair was first observed in, so the merged
  /// list can read newest-first the same way a single session's own panel
  /// already does (`transfer_panel.dart` reverses `queue.tasks`).
  /// [TransferTask.id] resets to `transfer-0` on every session's own queue —
  /// it is only unique *within* one [TransferQueue] — so it cannot be
  /// compared across sessions; this is the ordering an id alone cannot give.
  final Map<String, int> _order = {};
  var _orderCounter = 0;

  final _controller = StreamController<List<AggregatedTransfer>>.broadcast();
  var _current = const <TransferQueueSource>[];

  /// Emits the merged list whenever any session's queue changes, or the set
  /// of open sessions itself changes.
  Stream<List<AggregatedTransfer>> get changes => _controller.stream;

  /// Snapshot of every transfer across every open session, newest first.
  List<AggregatedTransfer> get items => _snapshot();

  int get activeCount =>
      items.where((item) => item.task.status.isActive).length;

  bool get hasFailed =>
      items.any((item) => item.task.status == TransferStatus.failed);

  bool get hasFinished => items.any((item) => item.task.status.isFinished);

  void _resync() {
    final sources = _sourcesOf();
    _current = sources;
    final liveIds = sources.map((s) => s.sessionId).toSet();

    for (final id in _queueSubs.keys.toList()) {
      if (!liveIds.contains(id)) unawaited(_queueSubs.remove(id)?.cancel());
    }
    for (final source in sources) {
      if (_queueSubs.containsKey(source.sessionId)) continue;
      _queueSubs[source.sessionId] =
          source.queue.changes.listen((_) => _publish());
    }
    _publish();
  }

  List<AggregatedTransfer> _snapshot() {
    final items = <AggregatedTransfer>[];
    for (final source in _current) {
      for (final task in source.queue.tasks) {
        final key = '${source.sessionId}:${task.id}';
        _order.putIfAbsent(key, () => _orderCounter++);
        items.add(AggregatedTransfer(
          sessionId: source.sessionId,
          sessionLabel: source.sessionLabel,
          task: task,
        ));
      }
    }
    items.sort((a, b) {
      final orderA = _order['${a.sessionId}:${a.task.id}'] ?? 0;
      final orderB = _order['${b.sessionId}:${b.task.id}'] ?? 0;
      return orderB.compareTo(orderA);
    });
    return items;
  }

  void _publish() {
    if (_controller.isClosed) return;
    _controller.add(_snapshot());
  }

  TransferQueue? _queueFor(String sessionId) {
    for (final source in _current) {
      if (source.sessionId == sessionId) return source.queue;
    }
    return null;
  }

  /// Re-enqueues a failed transfer through its own session's queue — the
  /// only public retry path [TransferQueue] has (see `transfer_queue.dart`).
  /// Nothing here re-runs a transfer itself.
  void retry(String sessionId, String taskId) {
    _queueFor(sessionId)?.retry(taskId);
  }

  /// Cancels a queued or running transfer on its own session's queue.
  void cancel(String sessionId, String taskId) {
    _queueFor(sessionId)?.cancel(taskId);
  }

  /// Clears finished rows on every open session's queue at once — "clear
  /// completed" for the whole app, not just whichever tab happens to be in
  /// front.
  void clearCompleted() {
    for (final source in _current) {
      source.queue.clearFinished();
    }
  }

  Future<void> dispose() async {
    await _sessionsSub?.cancel();
    for (final sub in _queueSubs.values) {
      await sub.cancel();
    }
    _queueSubs.clear();
    await _controller.close();
  }
}
