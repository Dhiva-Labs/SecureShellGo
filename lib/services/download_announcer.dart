import 'transfer_queue.dart';

/// Decides which finished downloads are worth mentioning, and remembers what
/// has already been mentioned.
///
/// Owned by `SessionController` rather than by the widget that draws the
/// announcement, and that placement is the whole point of the class existing
/// separately at all. A view is free to be rebuilt, to be moved between the
/// compact `IndexedStack` and the expanded `Row` on a fold or a window
/// resize, or to be destroyed and recreated outright — but the queue it is
/// announcing *from* keeps its completed rows the entire time. Hold the
/// record of what has been said in the view and every fresh `State` that
/// subscribes starts with an empty memory in front of a queue that still
/// contains the same finished download, and says it all again. Held here it
/// lives exactly as long as the transfers it describes.
class DownloadAnnouncer {
  /// Ids already announced. A [Set] rather than a "last announced" marker
  /// because the queue publishes its whole list every time, and rows can
  /// finish out of order once a retry is in the mix.
  final Set<String> _announced = {};

  /// Downloads that finished while the queue was still busy, waiting for it
  /// to go quiet.
  final List<TransferTask> _waiting = [];

  /// The downloads to announce right now, given the queue's latest [tasks],
  /// or an empty list when there is nothing new to say yet.
  ///
  /// Batched — announced when [queueBusy] goes false rather than per file —
  /// because a recursive folder download finishes four hundred times, and
  /// four hundred queued announcements would take minutes to drain past a
  /// user who has long since moved on.
  List<TransferTask> take(
    List<TransferTask> tasks, {
    required bool queueBusy,
  }) {
    for (final task in tasks) {
      if (task.direction != TransferDirection.download) continue;
      if (task.status != TransferStatus.completed) continue;
      // add() returning false is the dedupe: this one has been said already.
      if (!_announced.add(task.id)) continue;
      _waiting.add(task);
    }

    if (_waiting.isEmpty || queueBusy) return const [];

    final batch = List<TransferTask>.of(_waiting);
    _waiting.clear();
    return batch;
  }
}
