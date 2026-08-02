import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import '../models/host.dart';
import 'remote_path.dart';
import 'sftp_service.dart';
import 'ssh_service.dart' show SshConnectionException;

/// A local file to push, in terms this service understands.
///
/// Deliberately not `PickedLocalFile` from `device_storage.dart` — that file
/// imports `package:flutter/services.dart` for its platform channel, and this
/// service has to stay pure Dart so the fan-out logic below can be exercised
/// with fakes and no real sockets. The screen that starts a push converts a
/// `PickedLocalFile` into one of these.
class FleetLocalFile {
  const FleetLocalFile({
    required this.path,
    required this.name,
    required this.size,
  });

  final String path;
  final String name;
  final int size;
}

/// What to do, for every host, about a file that already exists at the
/// destination path. Chosen once, up front, for the whole push — there is no
/// per-host or per-file prompt once a fan-out is running.
enum FleetOverwritePolicy {
  /// Replace whatever is there.
  overwrite,

  /// Leave the existing file alone and mark that file `skipped` for that
  /// host.
  skipExisting,

  /// Leave the existing file alone and mark that file `failed` for that
  /// host.
  failOnExisting;

  String get label => switch (this) {
        FleetOverwritePolicy.overwrite => 'Overwrite',
        FleetOverwritePolicy.skipExisting => 'Skip existing files',
        FleetOverwritePolicy.failOnExisting => 'Fail on existing files',
      };
}

/// One file's progress on one host.
enum FleetFileStatus {
  queued,
  running,
  done,
  failed,
  skipped,
  cancelled;

  bool get isTerminal => this != FleetFileStatus.queued && this != FleetFileStatus.running;
}

/// One host's overall progress across every file being pushed to it.
enum FleetHostStatus {
  queued,
  running,
  done,
  failed,
  cancelled;

  bool get isTerminal =>
      this != FleetHostStatus.queued && this != FleetHostStatus.running;
}

/// Why a host failed outright, before or instead of any per-file detail —
/// distinct from a per-file [FleetFileProgress.error], which explains one
/// file rather than the whole host.
enum FleetHostFailureReason {
  /// Nothing saved in the credential store for this host. Never prompted for
  /// mid-fan-out — see [FleetPushService]'s class doc.
  missingCredentials,

  /// Could not get an SFTP channel to the host at all: the open session's
  /// channel would not open, or a fresh dial failed (unreachable host,
  /// rejected credentials, or an untrusted/changed host key).
  connectFailed,

  /// Every file failed or the host was cancelled mid-transfer; see the
  /// per-file [FleetFileProgress.error] entries for specifics.
  transferFailed,
}

/// One file's live state on one host, as the results UI reads it.
///
/// Mutable and owned by the [FleetPushService] that created it, mirroring
/// `TransferTask` in `transfer_queue.dart`: the service publishes a snapshot
/// on its [FleetPushService.changes] stream after every change, rather than
/// the UI reconciling a stream of deltas.
class FleetFileProgress {
  FleetFileProgress(this.source);

  final FleetLocalFile source;

  String get name => source.name;
  int get totalBytes => source.size;

  FleetFileStatus status = FleetFileStatus.queued;
  int transferredBytes = 0;

  /// Set on [FleetFileStatus.failed] (why) and [FleetFileStatus.skipped]
  /// (name already existed).
  String? error;

  void _reset() {
    status = FleetFileStatus.queued;
    transferredBytes = 0;
    error = null;
  }
}

/// One host's live state across every file being pushed to it.
class FleetHostProgress {
  FleetHostProgress({
    required this.hostId,
    required this.label,
    required List<FleetLocalFile> files,
  }) : files = [for (final f in files) FleetFileProgress(f)];

  final String hostId;
  final String label;
  final List<FleetFileProgress> files;

  FleetHostStatus status = FleetHostStatus.queued;
  FleetHostFailureReason? failureReason;

  /// Set when [failureReason] is [FleetHostFailureReason.missingCredentials]
  /// or [FleetHostFailureReason.connectFailed] — there is no single per-file
  /// error to point at in that case, the host itself never got a channel.
  String? error;

  void _reset() {
    status = FleetHostStatus.queued;
    failureReason = null;
    error = null;
    for (final file in files) {
      file._reset();
    }
  }
}

/// One fan-out push, as the caller describes it: which hosts, which files,
/// where they land, and what to do about a name that is already taken.
class FleetPushRequest {
  const FleetPushRequest({
    required this.hosts,
    required this.files,
    required this.destinationDirectory,
    required this.overwritePolicy,
  });

  final List<Host> hosts;
  final List<FleetLocalFile> files;

  /// Applied verbatim to every host — per-host paths are out of scope. The
  /// screen that builds this defaults it to `~` and lets the user edit it.
  final String destinationDirectory;

  final FleetOverwritePolicy overwritePolicy;
}

/// A file handed to an already-open session's own `TransferQueue`, and a way
/// to track or cancel it without [FleetPushService] having to know
/// `TransferTask` or `TransferQueue` exist.
///
/// [done] resolves once the queue's own task finishes, one way or another,
/// and throws (with a message fit for a human) on anything but a clean
/// completion — the same contract [RemoteFileSystem.upload] already has, so
/// [FleetPushService] can treat the two upload paths identically past this
/// point.
class FleetQueuedUpload {
  const FleetQueuedUpload({required this.done, required this.cancel});

  final Future<void> done;

  /// Asks the queue to stop this transfer. A no-op once [done] has completed.
  final void Function() cancel;
}

/// What [FleetPushService] needs from a host that already has a live
/// session open, expressed narrowly enough to fake in a test without a real
/// transport or a real `TransferQueue` pump.
///
/// The production implementation (built where `SessionManager` is in scope,
/// not in this file — see its class doc) adapts a `ManagedSession`: `sftp()`
/// wraps `SessionController.sftp()`, and `queueUpload` calls
/// `TransferQueue.enqueueUpload` directly (not the higher-level
/// `SessionController.queueUpload`, which ties the panel's display name to
/// the remote path) so the file lands under [FleetPushService]'s chosen
/// temporary name while the panel still shows the real file name.
abstract class FleetOpenSession {
  /// This session's own (already-open, or opened-on-demand) SFTP channel —
  /// used for the existence pre-check and, once the queued upload finishes,
  /// to rename the temporary file into place.
  Future<RemoteFileSystem> sftp();

  /// Queues [file] onto this session's own `TransferQueue`, to be written to
  /// the exact [remotePath] given (always a temporary name [FleetPushService]
  /// has already chosen), while showing [displayName] in the transfer panel.
  FleetQueuedUpload queueUpload({
    required FleetLocalFile file,
    required String remotePath,
    required String displayName,
    required void Function(int bytes) onProgress,
  });
}

/// Finds the live [FleetOpenSession] for a host, or null when nothing is
/// open on it — in which case [FleetPushService] dials its own.
typedef FleetOpenSessionLookup = FleetOpenSession? Function(String hostId);

/// Loads the credentials saved for a host, or null when nothing is saved.
/// `CredentialStore.load` fits this.
typedef FleetCredentialLookup = Future<SshCredentials?> Function(String hostId);

/// What a freshly-dialled connection gives this service: an SFTP channel to
/// use, and how to close the whole connection once that host's files are
/// done.
///
/// Deliberately not `SessionTransport` itself — dartssh2's `SftpClient`
/// (what `SessionTransport.openSftp()` returns) cannot be faked usefully, the
/// same reason `SessionController` takes an injectable `openFileSystem`
/// rather than opening one off its transport directly in tests. The
/// production [FleetDialer] opens the real SFTP channel and wraps it in
/// `SftpService`; a test's dialer hands back a fake [RemoteFileSystem]
/// directly.
class FleetDialedConnection {
  const FleetDialedConnection({required this.sftp, required this.close});

  final RemoteFileSystem sftp;

  /// Closes the whole connection, not just the SFTP channel — this service
  /// calls it once, when that host's files are all done (or it failed before
  /// any were attempted).
  final void Function() close;
}

/// Dials a fresh connection to [host] with [credentials], through the same
/// TOFU host-key path an ordinary connect uses — see [FleetDialedConnection].
/// Throws on any connection or authentication failure, including a rejected
/// or changed host key: this service never weakens that check to keep a
/// fan-out moving.
typedef FleetDialer = Future<FleetDialedConnection> Function(
  Host host,
  SshCredentials credentials,
);

/// Thrown internally to unwind an upload once cancellation is noticed
/// between chunks. Never escapes this file.
class _FleetUploadCancelled implements Exception {
  const _FleetUploadCancelled();
}

/// Runs one fan-out push: the same file(s), to the same destination
/// directory, on many hosts at once.
///
/// **Where the bytes go.** For a host with a session already open, the
/// upload is queued on *that session's own* `TransferQueue` (via
/// [FleetOpenSession.queueUpload]) — so it takes its turn behind whatever
/// else that session is transferring, shares nothing else with it, and shows
/// up on the ordinary transfer panel like any other upload. For a host with
/// no open session, this service dials its own connection (through
/// [FleetDialer], the same TOFU host-key verification as an ordinary
/// connect — an unknown or changed key fails that host, never auto-accepted)
/// and closes it once that host's files are done, whether they succeeded or
/// not.
///
/// **Temp-name-then-rename.** Neither upload path above writes to the final
/// destination path directly. Both write to a hidden temporary name in the
/// same directory, and only this service's [_publishFromTemp] renames it
/// into place — after a fresh `sizeOf` confirms every byte landed. This is
/// the same discipline `remote_copy.dart` already applies to a
/// server-to-server copy, applied here because neither upload path this
/// service reuses has it on its own: `SftpService.upload` (what the queue's
/// own executor calls) writes straight to the final name and only cleans up
/// after an explicit cancel, not after every failure. A push that is
/// cancelled or fails partway therefore never leaves anything recognisable
/// as the user's file under its real name — at worst a `.name.ssg-fleet-…`
/// left behind, identifiable clutter rather than a corrupted "real" file.
///
/// **Missing credentials never prompt.** A host with nothing in the
/// credential store fails immediately as
/// [FleetHostFailureReason.missingCredentials]. Stopping a twenty-host
/// fan-out to pop a login dialog for host eleven would be worse than just
/// telling the user afterward which ones need attention.
///
/// **Partial failure is normal.** One host's connection dropping, one file
/// colliding, one host having no saved password — none of it stops any other
/// host. Every host runs to its own conclusion and the aggregate is read off
/// [hosts] once [isRunning] goes false.
///
/// **Concurrency.** At most [maxConcurrentHosts] hosts are ever connecting or
/// transferring at once — twenty servers must not mean twenty sockets
/// opening in the same instant. A simple pull-from-a-shared-queue pool, not a
/// batch-of-N-then-wait: a fast host's slot is handed to the next pending
/// host immediately rather than waiting for the whole batch to finish.
///
/// **Cancel.** [cancel] stops every host still queued (it is never dialled at
/// all) and asks every host mid-transfer to stop between chunks. A host that
/// had already finished — successfully or not — is left exactly as it was.
class FleetPushService {
  FleetPushService({
    required FleetPushRequest request,
    required this.openSessionLookup,
    required this.credentialLookup,
    required this.dialer,
    this.maxConcurrentHosts = defaultMaxConcurrentHosts,
  }) : _request = request {
    for (final host in request.hosts) {
      _hostById[host.id] = host;
      _hosts[host.id] = FleetHostProgress(
        hostId: host.id,
        label: host.displayName,
        files: request.files,
      );
    }
  }

  /// Twenty servers must not mean twenty sockets opening in the same
  /// instant; three at a time is generous enough that a fan-out to a handful
  /// of hosts still runs at full speed.
  static const int defaultMaxConcurrentHosts = 3;

  final FleetPushRequest _request;
  final FleetOpenSessionLookup openSessionLookup;
  final FleetCredentialLookup credentialLookup;
  final FleetDialer dialer;
  final int maxConcurrentHosts;

  final Map<String, Host> _hostById = {};
  final Map<String, FleetHostProgress> _hosts = {};
  final Queue<String> _pending = Queue<String>();

  /// Cancellers for whichever upload is in flight right now, keyed by host —
  /// present only while that host has a chunk actually moving. [cancel] and
  /// [cancelHost] call through this to stop an in-flight queued upload
  /// immediately rather than waiting for the next poll of [_wantsCancel].
  final Map<String, void Function()> _activeCancel = {};

  /// Hosts that should stop at their next opportunity: every host once
  /// [cancel] is called, or just the one named by [cancelHost].
  final Set<String> _cancelledHosts = {};

  var _started = false;
  var _activeWorkers = 0;
  var _tempNameCounter = 0;

  final _controller = StreamController<List<FleetHostProgress>>.broadcast();

  /// Emits every host's progress whenever any of it changes.
  Stream<List<FleetHostProgress>> get changes => _controller.stream;

  /// Snapshot of every host's progress, in the order they were selected.
  List<FleetHostProgress> get hosts => List.unmodifiable(_hosts.values);

  /// True once [start] has been called and at least one host is still
  /// queued or running.
  bool get isRunning => _activeWorkers > 0 || _pending.isNotEmpty;

  int get totalCount => _hosts.length;

  int get succeededCount =>
      _hosts.values.where((h) => h.status == FleetHostStatus.done).length;

  /// "6 of 8 succeeded" — the aggregate the results screen and its final
  /// summary line read off directly.
  String get summary => '$succeededCount of $totalCount succeeded';

  /// Starts the fan-out. A second call is a no-op — this service runs one
  /// push, once; build a new one for another.
  void start() {
    if (_started) return;
    _started = true;
    _pending.addAll(_hosts.keys);
    _fillWorkerSlots();
  }

  void _fillWorkerSlots() {
    while (_activeWorkers < maxConcurrentHosts && _pending.isNotEmpty) {
      _activeWorkers++;
      unawaited(_workerLoop());
    }
  }

  Future<void> _workerLoop() async {
    while (_pending.isNotEmpty) {
      final hostId = _pending.removeFirst();
      await _runHost(hostId);
    }
    _activeWorkers--;
    _publish();
  }

  bool _wantsCancel(String hostId) => _cancelledHosts.contains(hostId);

  /// Cancels the whole push: every host still queued is marked cancelled
  /// without ever being dialled or having its session touched, and every
  /// host mid-transfer is asked to stop between chunks. A host that had
  /// already finished is left exactly as it was.
  void cancel() {
    final stillPending = _pending.toList();
    _pending.clear();
    for (final id in stillPending) {
      _cancelledHosts.add(id);
      _markHostCancelledIfNotFinished(_hosts[id]!);
    }
    // Running hosts: flag them so the next chunk (or the next file) notices,
    // and stop whichever upload is in flight right now rather than waiting
    // for it to poll.
    _cancelledHosts.addAll(_hosts.keys);
    for (final stop in _activeCancel.values.toList()) {
      stop();
    }
    _publish();
  }

  /// Cancels just [hostId] — pending or in flight. Every other host is
  /// untouched.
  void cancelHost(String hostId) {
    if (!_hosts.containsKey(hostId)) return;
    _cancelledHosts.add(hostId);
    _pending.remove(hostId);
    _activeCancel[hostId]?.call();
    final progress = _hosts[hostId]!;
    if (progress.status == FleetHostStatus.queued) {
      _markHostCancelledIfNotFinished(progress);
      _publish();
    }
  }

  /// Requeues every host currently [FleetHostStatus.failed], resetting its
  /// files back to queued. Still bounded by [maxConcurrentHosts] — this
  /// gives the same worker pool more to do rather than bypassing the cap.
  /// Hosts that succeeded, were skipped, or were cancelled are untouched: use
  /// [cancel]/[cancelHost] and a fresh [FleetPushService] to redo those.
  void retryFailedHosts() {
    var any = false;
    for (final progress in _hosts.values) {
      if (progress.status != FleetHostStatus.failed) continue;
      any = true;
      _cancelledHosts.remove(progress.hostId);
      progress._reset();
      _pending.add(progress.hostId);
    }
    if (!any) return;
    _publish();
    _fillWorkerSlots();
  }

  void _markHostCancelledIfNotFinished(FleetHostProgress progress) {
    if (progress.status.isTerminal) return;
    for (final file in progress.files) {
      if (!file.status.isTerminal) file.status = FleetFileStatus.cancelled;
    }
    progress.status = FleetHostStatus.cancelled;
  }

  Future<void> _runHost(String hostId) async {
    final progress = _hosts[hostId]!;
    if (_wantsCancel(hostId)) {
      _markHostCancelledIfNotFinished(progress);
      _publish();
      return;
    }

    progress.status = FleetHostStatus.running;
    _publish();

    final open = openSessionLookup(hostId);
    void Function()? closeDialed;
    RemoteFileSystem fs;

    try {
      if (open != null) {
        fs = await open.sftp();
      } else {
        final creds = await credentialLookup(hostId);
        if (creds == null) {
          _failHost(
            progress,
            FleetHostFailureReason.missingCredentials,
            'No saved credentials for this host.',
          );
          return;
        }
        if (_wantsCancel(hostId)) {
          _markHostCancelledIfNotFinished(progress);
          _publish();
          return;
        }
        final host = _hostById[hostId]!;
        final connection = await dialer(host, creds);
        closeDialed = connection.close;
        fs = connection.sftp;
      }
    } catch (e) {
      closeDialed?.call();
      _failHost(
        progress,
        FleetHostFailureReason.connectFailed,
        _messageOf(e),
      );
      return;
    }

    if (_wantsCancel(hostId)) {
      _markHostCancelledIfNotFinished(progress);
      closeDialed?.call();
      _publish();
      return;
    }

    final String destinationDirectory;
    try {
      destinationDirectory = await _resolveDestinationDirectory(fs);
    } catch (e) {
      closeDialed?.call();
      _failHost(progress, FleetHostFailureReason.connectFailed, _messageOf(e));
      return;
    }

    var anyFailed = false;
    for (final file in progress.files) {
      if (_wantsCancel(hostId)) {
        file.status = FleetFileStatus.cancelled;
        continue;
      }
      await _runFile(
        hostId: hostId,
        fs: fs,
        open: open,
        file: file,
        destinationDirectory: destinationDirectory,
      );
      if (file.status == FleetFileStatus.failed) anyFailed = true;
    }

    closeDialed?.call();

    if (progress.files.any((f) => f.status == FleetFileStatus.cancelled)) {
      progress.status = FleetHostStatus.cancelled;
    } else if (anyFailed) {
      progress.status = FleetHostStatus.failed;
      progress.failureReason = FleetHostFailureReason.transferFailed;
    } else {
      progress.status = FleetHostStatus.done;
    }
    _publish();
  }

  /// `~` and `~/rest/of/path` are resolved against this host's own home
  /// directory rather than sent to the server literally: SFTP is not a
  /// shell, and nothing in the protocol guarantees a server expands a tilde
  /// the way a login shell would. Everything else is used exactly as typed.
  Future<String> _resolveDestinationDirectory(RemoteFileSystem fs) async {
    final dir = _request.destinationDirectory.trim();
    if (dir == '~' || dir.isEmpty) return fs.home();
    if (dir.startsWith('~/')) {
      final home = await fs.home();
      return RemotePath.join(home, dir.substring(2));
    }
    return dir;
  }

  Future<void> _runFile({
    required String hostId,
    required RemoteFileSystem fs,
    required FleetOpenSession? open,
    required FleetFileProgress file,
    required String destinationDirectory,
  }) async {
    final destinationPath = RemotePath.join(destinationDirectory, file.name);
    final policy = _request.overwritePolicy;

    if (policy != FleetOverwritePolicy.overwrite) {
      bool exists;
      try {
        exists = await fs.exists(destinationPath);
      } catch (_) {
        // A server that will not say is not a reason to refuse the upload —
        // proceed and let the write (and the rename below) report the real
        // problem, if there is one.
        exists = false;
      }
      if (exists) {
        if (policy == FleetOverwritePolicy.skipExisting) {
          file.status = FleetFileStatus.skipped;
          file.error = 'A file already exists at that path.';
        } else {
          file.status = FleetFileStatus.failed;
          file.error = 'A file already exists at that path.';
        }
        _publish();
        return;
      }
    }

    if (_wantsCancel(hostId)) {
      file.status = FleetFileStatus.cancelled;
      _publish();
      return;
    }

    file.status = FleetFileStatus.running;
    _publish();

    final tempPath = RemotePath.join(
      destinationDirectory,
      _temporaryName(file.name),
    );

    try {
      if (open != null) {
        await _runQueuedUpload(
          hostId: hostId,
          open: open,
          fs: fs,
          file: file,
          tempPath: tempPath,
          destinationPath: destinationPath,
        );
      } else {
        await _uploadDirectWithTempRename(
          fs: fs,
          file: file,
          tempPath: tempPath,
          destinationPath: destinationPath,
          overwritePolicy: policy,
          onProgress: (bytes) {
            file.transferredBytes = bytes;
            _publish();
          },
          isCancelled: () => _wantsCancel(hostId),
        );
      }
      file.status = FleetFileStatus.done;
    } on _FleetUploadCancelled {
      file.status = FleetFileStatus.cancelled;
    } catch (e) {
      if (_wantsCancel(hostId)) {
        file.status = FleetFileStatus.cancelled;
      } else {
        file.status = FleetFileStatus.failed;
        file.error = _messageOf(e);
      }
    } finally {
      _publish();
    }
  }

  /// The open-session path: the actual bytes move through that session's own
  /// `TransferQueue` (via [FleetOpenSession.queueUpload]), landing at
  /// [tempPath]; once that finishes, this service does the same verify-then-
  /// rename [_publishFromTemp] does for a freshly-dialled host, so both paths
  /// give the same "nothing under the final name until it is whole"
  /// guarantee even though only one of them owns the write end of the file
  /// handle.
  Future<void> _runQueuedUpload({
    required String hostId,
    required FleetOpenSession open,
    required RemoteFileSystem fs,
    required FleetFileProgress file,
    required String tempPath,
    required String destinationPath,
  }) async {
    final queued = open.queueUpload(
      file: file.source,
      remotePath: tempPath,
      displayName: file.name,
      onProgress: (bytes) {
        file.transferredBytes = bytes;
        _publish();
      },
    );
    _activeCancel[hostId] = queued.cancel;
    try {
      await queued.done;
    } finally {
      _activeCancel.remove(hostId);
    }
    if (_wantsCancel(hostId)) {
      // The queue's own task may have finished cleanly a moment after the
      // cancel flag was set — the bytes are complete at [tempPath], just
      // never renamed into place. Clearing it here is tidiness, not
      // correctness: [destinationPath] was never going to see it either way.
      try {
        await fs.remove(tempPath);
      } catch (_) {
        // Best effort.
      }
      throw const _FleetUploadCancelled();
    }

    try {
      await _publishFromTemp(
        fs: fs,
        tempPath: tempPath,
        destinationPath: destinationPath,
        expectedBytes: file.transferredBytes,
        overwritePolicy: _request.overwritePolicy,
      );
    } catch (e) {
      try {
        await fs.remove(tempPath);
      } catch (_) {
        // Best effort — a stray `.name.ssg-fleet-…` is clutter, not a file
        // masquerading as the user's upload.
      }
      rethrow;
    }
  }

  /// The freshly-dialled path: this service owns the write end of the file
  /// handle directly, so it applies the same temp-name-then-rename discipline
  /// `remote_copy.dart` uses for a server-to-server copy — see the class doc.
  Future<void> _uploadDirectWithTempRename({
    required RemoteFileSystem fs,
    required FleetFileProgress file,
    required String tempPath,
    required String destinationPath,
    required FleetOverwritePolicy overwritePolicy,
    required void Function(int) onProgress,
    required bool Function() isCancelled,
  }) async {
    final writer = await fs.openWrite(tempPath);
    var published = false;
    try {
      var moved = 0;
      final source = File(file.source.path);
      await for (final chunk in source.openRead()) {
        if (isCancelled()) throw const _FleetUploadCancelled();
        final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
        await writer.add(bytes);
        moved += bytes.length;
        onProgress(moved);
      }
      if (isCancelled()) throw const _FleetUploadCancelled();
      await writer.close();

      await _publishFromTemp(
        fs: fs,
        tempPath: tempPath,
        destinationPath: destinationPath,
        expectedBytes: moved,
        overwritePolicy: overwritePolicy,
      );
      published = true;
    } finally {
      if (!published) {
        try {
          await writer.abort();
        } catch (_) {
          // Channel already gone, or the remove inside it failed — nothing
          // more this can do.
        }
      }
    }
  }

  /// Confirms every byte landed, then swaps the temporary file into place —
  /// the one step both upload paths share. Nothing appears under
  /// [destinationPath] before this returns successfully.
  Future<void> _publishFromTemp({
    required RemoteFileSystem fs,
    required String tempPath,
    required String destinationPath,
    required int expectedBytes,
    required FleetOverwritePolicy overwritePolicy,
  }) async {
    final landed = await fs.sizeOf(tempPath);
    if (landed != null && landed != expectedBytes) {
      throw SftpFailure(
        'The upload did not land completely on the server.',
        details: 'wrote $expectedBytes bytes, the server reports $landed',
      );
    }

    if (overwritePolicy == FleetOverwritePolicy.overwrite) {
      // Removing first because SSH_FXP_RENAME is not required to clobber an
      // existing target, and plenty of servers refuse when it does — same
      // reasoning as `remote_copy.dart`'s `copyRemoteFile`.
      try {
        await fs.remove(destinationPath);
      } catch (_) {
        // Not there, or already gone. The rename below decides.
      }
    }
    await fs.rename(tempPath, destinationPath);
  }

  void _failHost(
    FleetHostProgress progress,
    FleetHostFailureReason reason,
    String message,
  ) {
    progress.status = FleetHostStatus.failed;
    progress.failureReason = reason;
    progress.error = message;
    for (final file in progress.files) {
      if (!file.status.isTerminal) {
        file.status = FleetFileStatus.failed;
        file.error = message;
      }
    }
    _publish();
  }

  /// `report.pdf` → `.report.pdf.ssg-fleet-1738000000000-3`. Hidden, and
  /// named after this app and this feature specifically, so anything a
  /// killed process left behind is recognisable — same idea as
  /// `remote_copy.dart`'s own temporary name, given its own counter suffix
  /// since a fast host can otherwise pick two names in the same millisecond.
  String _temporaryName(String finalName) {
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final salt = _tempNameCounter++;
    final head = finalName.length > 180 ? finalName.substring(0, 180) : finalName;
    return '.$head.ssg-fleet-$stamp-$salt';
  }

  String _messageOf(Object error) {
    if (error is SshConnectionException) return error.message;
    if (error is SftpFailure) return error.message;
    return error.toString();
  }

  void _publish() {
    if (_controller.isClosed) return;
    _controller.add(hosts);
  }

  /// Releases the [changes] stream. Does not cancel anything still running —
  /// call [cancel] first if that is what is wanted.
  void dispose() {
    if (!_controller.isClosed) unawaited(_controller.close());
  }
}
