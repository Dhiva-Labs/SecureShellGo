import 'dart:async';

/// Which way the bytes are moving.
///
/// [serverToServer] is a third direction rather than an upload with an unusual
/// source, because almost everything a view wants to know differs: it has two
/// remote ends instead of one, nothing on the device to open afterwards, and a
/// "move" variant that deletes what it read. Making it a case of its own is
/// what stops the panel from calling it "saved to Downloads".
enum TransferDirection { download, upload, serverToServer }

/// How a [TransferDirection.serverToServer] transfer physically moves the
/// bytes between the two servers.
///
/// [relay] streams the file through this app — the source's SFTP read feeds
/// the destination's SFTP write on this device, with backpressure the whole
/// way (see `remote_copy.dart`). Works whenever the app can talk to both
/// servers, which is the guaranteed case since it *did* — that is how each
/// session got opened.
///
/// [direct] dials a second, short-lived connection to the source and runs
/// `sftp` there over one exec channel, pointing at the destination. Bytes
/// flow source → destination on the network between them; agent forwarding
/// sends signing challenges back through that exec channel to a
/// [MutableSSHAgentHandler] held on that connection alone, so the
/// destination's private key never touches the source — and the session's
/// own connection never carries an agent handler, which is what keeps its
/// execs reusable. Faster when the two
/// servers are on the same LAN; falls back to [relay] when the source
/// cannot reach the destination or the destination auth cannot be
/// forwarded.
enum TransferRoute { relay, direct }

enum TransferStatus {
  queued,
  running,
  completed,
  failed,
  cancelled;

  bool get isFinished =>
      this == TransferStatus.completed ||
      this == TransferStatus.failed ||
      this == TransferStatus.cancelled;

  bool get isActive =>
      this == TransferStatus.queued || this == TransferStatus.running;
}

/// One queued file transfer, and its live progress.
///
/// Mutable on purpose: the queue owns it and publishes a snapshot after every
/// change, so the UI reads a single object instead of reconciling a stream of
/// deltas against a list.
class TransferTask {
  TransferTask({
    required this.id,
    required this.name,
    required this.remotePath,
    required this.direction,
    this.totalBytes,
    this.localPath,
    this.saveAsName,
    this.overwrite = false,
    this.relativeDirectory = '',
    this.destinationSessionId,
    this.destinationPath,
    this.destinationLabel,
    this.moveSource = false,
    this.route = TransferRoute.relay,
    this.isDirectoryTransfer = false,
  });

  final String id;

  /// What to show as the transfer's title.
  final String name;

  /// The remote file this transfer reads or writes. For a
  /// [TransferDirection.serverToServer] copy it is the **source** path, on the
  /// session that owns this queue; the far end is [destinationPath].
  final String remotePath;

  final TransferDirection direction;

  /// For uploads, the local source. Null for downloads until [destination] is
  /// known.
  final String? localPath;

  /// For downloads, the device-side file name to ask for. Already sanitised
  /// and collision-resolved by the caller.
  final String? saveAsName;

  /// Whether an existing file of that name should be replaced rather than
  /// de-duplicated — the device side for a download, the destination server
  /// for a server-to-server copy.
  final bool overwrite;

  /// For a server-to-server copy, which open session receives the bytes.
  ///
  /// An id rather than a session object so a retry, which builds a fresh task
  /// from these fields alone, resolves the destination again at the moment it
  /// runs. A destination that has been closed in the meantime fails the
  /// transfer with something worth reading instead of writing into a dead
  /// channel.
  final String? destinationSessionId;

  /// For a server-to-server copy, the absolute path on the destination.
  final String? destinationPath;

  /// For a server-to-server copy, the destination host's display name — for
  /// the panel, which otherwise cannot say which of two servers a path is on.
  final String? destinationLabel;

  /// For a server-to-server copy, whether the source is deleted once the
  /// destination write has been verified. This is what makes it a "move".
  final bool moveSource;

  /// For a server-to-server copy, which physical path the bytes take. See
  /// [TransferRoute]. Ignored for downloads and uploads.
  ///
  /// [TransferRoute.direct] can be requested by the UI but is silently
  /// downgraded to [TransferRoute.relay] when the source cannot reach the
  /// destination — the panel surfaces which route actually ran through
  /// [routeUsed] once the transfer starts.
  final TransferRoute route;

  /// The route that actually ran, once the executor has picked one. Null
  /// until the transfer starts. Set to [TransferRoute.relay] when a direct
  /// attempt fell back so the UI can name it explicitly.
  TransferRoute? routeUsed;

  /// Why the direct route was skipped or abandoned, for the panel's
  /// subtitle on a fallen-back transfer. Null when direct was not
  /// attempted or succeeded.
  String? routeFallbackReason;

  /// For downloads, the directory under `Download/` to save into — set by a
  /// recursive directory download so the tree's shape survives the trip.
  /// Empty means straight into Downloads, which is every single-file case.
  final String relativeDirectory;

  /// Whether this task's [remotePath] / [localPath] names a *directory* rather
  /// than a file — the whole-folder upload, and the whole-folder
  /// server-to-server copy or move. The executor branches on this: a folder
  /// upload walks its local root and streams every file under it under one
  /// row in the panel; a folder S2S transfer picks between the recursive
  /// relay path and the direct `put -r` path exactly as its file cousin does.
  ///
  /// One row per top-level folder is what the UI shows: 300 files inside a
  /// moved `Documents/` should not become 300 rows on the transfer panel.
  final bool isDirectoryTransfer;

  /// Bytes, when known up front. Downloads learn it from `stat`, uploads from
  /// the picked file.
  int? totalBytes;

  int transferredBytes = 0;
  TransferStatus status = TransferStatus.queued;

  /// Human-readable failure reason, set when [status] is
  /// [TransferStatus.failed].
  String? error;

  /// Where the bytes ended up — the MediaStore display name for a download,
  /// the remote path for an upload. Set on completion.
  String? destination;

  /// For a finished download, the `content://` URI it landed on, so the panel
  /// can offer "Open" rather than leaving the user to go hunting for the file
  /// in a file manager.
  String? destinationUri;

  DateTime? startedAt;
  DateTime? finishedAt;

  /// 0..1, or null while the total is unknown (indeterminate bar).
  double? get progress {
    final total = totalBytes;
    if (total == null || total <= 0) return null;
    final ratio = transferredBytes / total;
    return ratio.clamp(0.0, 1.0);
  }

  /// Whole percent, or null while indeterminate.
  int? get percent {
    final value = progress;
    return value == null ? null : (value * 100).round();
  }

  /// Bytes per second over the life of the transfer, or null if it has not
  /// run long enough to mean anything.
  double? get bytesPerSecond {
    final started = startedAt;
    if (started == null || transferredBytes == 0) return null;
    final end = finishedAt ?? DateTime.now();
    final seconds = end.difference(started).inMilliseconds / 1000;
    if (seconds < 0.25) return null;
    return transferredBytes / seconds;
  }
}

/// Handed to the executor so it can publish progress and notice cancellation.
class TransferHandle {
  TransferHandle._(this._task, this._onChanged);

  final TransferTask _task;
  final void Function() _onChanged;

  var _cancelled = false;

  /// True once the user asked for this transfer to stop. Executors must check
  /// it between chunks and return (or throw [TransferCancelled]) promptly.
  bool get isCancelled => _cancelled;

  void _cancel() => _cancelled = true;

  /// Declares the total size once it is known (e.g. after a remote `stat`).
  void setTotal(int? total) {
    if (_task.totalBytes == total) return;
    _task.totalBytes = total;
    _onChanged();
  }

  /// Reports cumulative bytes moved so far.
  void report(int transferredBytes) {
    if (_task.transferredBytes == transferredBytes) return;
    _task.transferredBytes = transferredBytes;
    _onChanged();
  }

  /// Records where the bytes landed, for the completed row's subtitle and its
  /// "Open" action.
  void setDestination(String destination, {String? uri}) {
    if (_task.destination == destination && _task.destinationUri == uri) return;
    _task.destination = destination;
    _task.destinationUri = uri;
    _onChanged();
  }

  /// Records the route the executor actually took. Set once the executor
  /// has committed to a path — direct on entry, or relay after a
  /// [SSHDirectCopyUnavailable] fallback.
  void setRouteUsed(TransferRoute route, {String? fallbackReason}) {
    if (_task.routeUsed == route &&
        _task.routeFallbackReason == fallbackReason) {
      return;
    }
    _task.routeUsed = route;
    _task.routeFallbackReason = fallbackReason;
    _onChanged();
  }

  /// Throws if the user cancelled. A convenience for executors that would
  /// otherwise litter their loops with early returns.
  void throwIfCancelled() {
    if (_cancelled) throw const TransferCancelled();
  }
}

/// Thrown by an executor that noticed [TransferHandle.isCancelled].
class TransferCancelled implements Exception {
  const TransferCancelled();

  @override
  String toString() => 'Transfer cancelled';
}

/// Moves the bytes for one task. Injected so the queue's sequencing,
/// progress and cancellation logic can be tested without an SSH server.
typedef TransferExecutor = Future<void> Function(
  TransferTask task,
  TransferHandle handle,
);

/// Runs transfers one at a time and publishes a snapshot after every change.
///
/// Sequential on purpose. Two concurrent SFTP reads over one SSH connection
/// share the same TCP window, so they finish no sooner in aggregate but make
/// both progress bars crawl — and a queue the user can reason about ("this
/// one, then that one") is worth more than an illusion of parallelism.
class TransferQueue {
  // ignore: prefer_initializing_formals — the field is private, the param is not.
  TransferQueue({required TransferExecutor executor}) : _executor = executor;

  final TransferExecutor _executor;
  final List<TransferTask> _tasks = [];
  final _controller = StreamController<List<TransferTask>>.broadcast();
  final Map<String, TransferHandle> _handles = {};

  var _pumping = false;
  var _closed = false;
  var _idCounter = 0;

  /// Emits the full task list whenever anything changes.
  Stream<List<TransferTask>> get changes => _controller.stream;

  /// Snapshot of every task, newest last.
  List<TransferTask> get tasks => List.unmodifiable(_tasks);

  List<TransferTask> get active =>
      _tasks.where((t) => t.status.isActive).toList(growable: false);

  bool get hasActive => _tasks.any((t) => t.status.isActive);

  int get activeCount => _tasks.where((t) => t.status.isActive).length;

  /// Combined progress across all unfinished transfers, or null when none of
  /// them has a known size.
  double? get aggregateProgress {
    final unfinished = active.where((t) => t.totalBytes != null).toList();
    if (unfinished.isEmpty) return null;
    final total = unfinished.fold<int>(0, (sum, t) => sum + t.totalBytes!);
    if (total <= 0) return null;
    final moved = unfinished.fold<int>(0, (sum, t) => sum + t.transferredBytes);
    return (moved / total).clamp(0.0, 1.0);
  }

  String _nextId() => 'transfer-${_idCounter++}';

  /// Queues a download of [remotePath] and starts the pump.
  TransferTask enqueueDownload({
    required String remotePath,
    required String name,
    String? saveAsName,
    bool overwrite = false,
    int? totalBytes,
    String relativeDirectory = '',
  }) {
    return _enqueue(
      TransferTask(
        id: _nextId(),
        name: name,
        remotePath: remotePath,
        direction: TransferDirection.download,
        totalBytes: totalBytes,
        saveAsName: saveAsName ?? name,
        overwrite: overwrite,
        relativeDirectory: relativeDirectory,
      ),
    );
  }

  /// Queues an upload of [localPath] to [remotePath].
  TransferTask enqueueUpload({
    required String localPath,
    required String remotePath,
    required String name,
    int? totalBytes,
  }) {
    return _enqueue(
      TransferTask(
        id: _nextId(),
        name: name,
        remotePath: remotePath,
        direction: TransferDirection.upload,
        totalBytes: totalBytes,
        localPath: localPath,
      ),
    );
  }

  /// Queues an upload of the local directory at [localPath] to [remotePath] —
  /// the top-level destination folder. The executor walks the local tree,
  /// mkdirs the shape, and streams every file underneath.
  ///
  /// One task, one row: the panel shows the folder's progress in aggregate,
  /// not each file inside it.
  TransferTask enqueueUploadDirectory({
    required String localPath,
    required String remotePath,
    required String name,
    int? totalBytes,
    bool overwrite = false,
  }) {
    return _enqueue(
      TransferTask(
        id: _nextId(),
        name: name,
        remotePath: remotePath,
        direction: TransferDirection.upload,
        totalBytes: totalBytes,
        localPath: localPath,
        overwrite: overwrite,
        isDirectoryTransfer: true,
      ),
    );
  }

  /// Queues a copy of [remotePath] on this session straight into
  /// [destinationPath] on another open session, without the bytes touching
  /// the device.
  ///
  /// It goes on the *source* session's queue: that is the session the user
  /// started it from, and the one whose SFTP channel does the reading, so it
  /// takes its turn behind that session's other transfers rather than
  /// competing with them for the same window.
  TransferTask enqueueRemoteCopy({
    required String remotePath,
    required String destinationSessionId,
    required String destinationPath,
    required String name,
    String? destinationLabel,
    bool overwrite = false,
    bool moveSource = false,
    int? totalBytes,
    TransferRoute route = TransferRoute.relay,
    bool isDirectoryTransfer = false,
  }) {
    return _enqueue(
      TransferTask(
        id: _nextId(),
        name: name,
        remotePath: remotePath,
        direction: TransferDirection.serverToServer,
        totalBytes: totalBytes,
        overwrite: overwrite,
        destinationSessionId: destinationSessionId,
        destinationPath: destinationPath,
        destinationLabel: destinationLabel,
        moveSource: moveSource,
        route: route,
        isDirectoryTransfer: isDirectoryTransfer,
      ),
    );
  }

  TransferTask _enqueue(TransferTask task) {
    if (_closed) return task;
    _tasks.add(task);
    _publish();
    unawaited(_pump());
    return task;
  }

  /// Cancels a queued or running transfer. A finished one is left alone.
  void cancel(String id) {
    final task = _find(id);
    if (task == null || task.status.isFinished) return;

    if (task.status == TransferStatus.queued) {
      task.status = TransferStatus.cancelled;
      task.finishedAt = DateTime.now();
      _publish();
      return;
    }

    // Running: flag the handle and let the executor unwind. Marking the task
    // cancelled here as well means the UI reacts immediately even if the
    // executor is blocked on a slow chunk.
    _handles[id]?._cancel();
    task.status = TransferStatus.cancelled;
    task.finishedAt = DateTime.now();
    _publish();
  }

  /// Cancels everything still queued or running.
  void cancelAll() {
    for (final task in _tasks.where((t) => t.status.isActive).toList()) {
      cancel(task.id);
    }
  }

  /// Queues a failed transfer again, and drops the row it failed on.
  ///
  /// A fresh task rather than a reset of the old one: progress, timings and
  /// the error belong to the attempt that failed, and a row that silently
  /// goes from "failed" back to "waiting" reads as the app losing track of
  /// itself. Only failures can be retried — a cancelled transfer is a
  /// decision the user made, not something to offer to undo behind a button
  /// that says "retry".
  ///
  /// Returns null when the id is unknown or the task is not in [failed].
  TransferTask? retry(String id) {
    final task = _find(id);
    if (task == null || task.status != TransferStatus.failed) return null;
    _tasks.remove(task);

    return _enqueue(
      TransferTask(
        id: _nextId(),
        name: task.name,
        remotePath: task.remotePath,
        direction: task.direction,
        // Downloads re-learn their size from the server if it was never
        // known; uploads knew it from the picked file all along, and a
        // server-to-server copy learns it the same way a download does.
        totalBytes: task.direction == TransferDirection.upload
            ? task.totalBytes
            : null,
        localPath: task.localPath,
        saveAsName: task.saveAsName,
        overwrite: task.overwrite,
        relativeDirectory: task.relativeDirectory,
        // A retried move is still a move, and still lands where the user
        // said — including the "replace" they agreed to at the prompt, which
        // must not quietly come back as a question they never see.
        destinationSessionId: task.destinationSessionId,
        destinationPath: task.destinationPath,
        destinationLabel: task.destinationLabel,
        moveSource: task.moveSource,
        // A retry keeps the route the user asked for the first time. The
        // fallback record is *this* attempt's, not something to carry over.
        route: task.route,
        isDirectoryTransfer: task.isDirectoryTransfer,
      ),
    );
  }

  /// Drops finished rows from the panel.
  void clearFinished() {
    _tasks.removeWhere((t) => t.status.isFinished);
    _publish();
  }

  TransferTask? _find(String id) {
    for (final task in _tasks) {
      if (task.id == id) return task;
    }
    return null;
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (true) {
        final next = _tasks.cast<TransferTask?>().firstWhere(
              (t) => t!.status == TransferStatus.queued,
              orElse: () => null,
            );
        if (next == null) break;
        await _run(next);
      }
    } finally {
      _pumping = false;
    }
  }

  Future<void> _run(TransferTask task) async {
    task.status = TransferStatus.running;
    task.startedAt = DateTime.now();
    _publish();

    final handle = TransferHandle._(task, _publish);
    _handles[task.id] = handle;

    try {
      await _executor(task, handle);
      // A cancel that landed mid-flight has already set the status; do not
      // overwrite it with "completed" just because the executor returned
      // normally after noticing the flag.
      if (task.status == TransferStatus.running) {
        task.status = handle.isCancelled
            ? TransferStatus.cancelled
            : TransferStatus.completed;
        if (task.status == TransferStatus.completed && task.totalBytes == null) {
          task.totalBytes = task.transferredBytes;
        }
      }
    } on TransferCancelled {
      task.status = TransferStatus.cancelled;
    } catch (e) {
      if (handle.isCancelled) {
        task.status = TransferStatus.cancelled;
      } else {
        task.status = TransferStatus.failed;
        task.error = e.toString();
      }
    } finally {
      _handles.remove(task.id);
      task.finishedAt = DateTime.now();
      _publish();
    }
  }

  void _publish() {
    if (_closed || _controller.isClosed) return;
    _controller.add(List.unmodifiable(_tasks));
  }

  /// Cancels outstanding work and closes the change stream.
  Future<void> dispose() async {
    cancelAll();
    _closed = true;
    await _controller.close();
  }
}
