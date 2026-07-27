import 'dart:async';

import 'package:dartssh2/dartssh2.dart';

import '../models/host.dart';
import '../models/remote_entry.dart';
import 'device_storage.dart';
import 'download_plan.dart';
import 'remote_path.dart';
import 'session_keepalive.dart';
import 'sftp_service.dart';
import 'ssh_service.dart';
import 'transfer_queue.dart';

/// Files waiting for a destination directory on this session.
class PendingUpload {
  const PendingUpload(this.files);

  final List<PickedLocalFile> files;

  int get count => files.length;

  int get totalBytes =>
      files.fold<int>(0, (sum, file) => sum + file.size);
}

/// One live authenticated session, shared by every view of it.
///
/// Phase 1 let `TerminalScreen` own the [SshConnection] and close it in
/// `dispose()`. That was fine while the terminal was the only thing on the
/// connection, and wrong the moment a file browser wanted the *same*
/// authenticated transport — `SSHClient.sftp()` opens another channel on it,
/// which is what spares the user a second password and a second host-key
/// prompt. So ownership lifts here: the session outlives any individual view,
/// and dies only when the user leaves the session or the transport does.
///
/// Deliberately free of Flutter imports, like the rest of `services/`:
/// listeners get a plain broadcast [Stream] rather than `ChangeNotifier`, so
/// the state machine is testable without a widget tree.
class SessionController {
  SessionController({
    required this.connection,
    DeviceStorage? storage,
    Future<RemoteFileSystem> Function()? openFileSystem,
    PeriodicScheduler keepaliveScheduler = Timer.periodic,
  })  : _storage = storage ?? const MethodChannelDeviceStorage(),
        // ignore: prefer_initializing_formals
        _openFileSystem = openFileSystem {
    transfers = TransferQueue(executor: _runTransfer);
    _keepalive = SessionKeepalive(
      ping: connection.ping,
      scheduler: keepaliveScheduler,
    )..start();
    _watchTransport();
  }

  final SessionTransport connection;
  final DeviceStorage _storage;

  /// Test seam. Production leaves this null and opens SFTP on [connection].
  final Future<RemoteFileSystem> Function()? _openFileSystem;

  /// The download/upload queue. Its executor is wired to this session, so a
  /// transfer cannot outlive the connection that is carrying it.
  late final TransferQueue transfers;

  /// Keeps the socket from idling out while the app is in the background —
  /// the other half of Phase 7, alongside the foreground service that keeps
  /// the *process* alive. Runs for exactly as long as the session does.
  late final SessionKeepalive _keepalive;

  final _changes = StreamController<void>.broadcast();

  SSHSession? _shell;
  Future<SSHSession>? _shellOpening;
  Future<RemoteFileSystem>? _sftpOpening;
  RemoteFileSystem? _sftp;

  var _closed = false;
  var _disposed = false;
  String? _closeReason;

  Host get host => connection.host;

  /// Fires whenever the session's own state changes (connected → closed).
  /// Transfer progress has its own stream on [transfers].
  Stream<void> get changes => _changes.stream;

  /// True once the transport is gone, for any reason.
  bool get isClosed => _closed;

  /// Why the session ended, for the disconnected banner.
  String? get closeReason => _closeReason;

  /// True once the shell channel has been opened.
  bool get hasShell => _shell != null;

  /// Whether keep-alives are still being sent. Diagnostics and tests.
  bool get isKeepaliveRunning => _keepalive.isRunning;

  void _watchTransport() {
    connection.done.then((_) {
      _markClosed('Connection closed by the remote host.');
    }).catchError((Object error) {
      _markClosed('Connection lost: $error');
    });
  }

  void _markClosed(String reason) {
    if (_closed) return;
    _closed = true;
    _closeReason = reason;
    // Nothing left to keep alive. Stopping here rather than only in dispose()
    // matters for the background case: a drop that happens while the app is
    // in the background must not leave a timer pinging a dead socket until
    // the user comes back and pops the route.
    _keepalive.stop();
    // Anything still queued is now unrunnable; failing it loudly beats a
    // progress bar that never moves again.
    transfers.cancelAll();
    _notify();
  }

  /// Called by the terminal view when the shell channel itself ends, which can
  /// happen (a plain `exit`) while the transport is still perfectly alive.
  void reportShellEnded(String reason) {
    if (_closed) return;
    _closeReason ??= reason;
    _notify();
  }

  void _notify() {
    if (_disposed || _changes.isClosed) return;
    _changes.add(null);
  }

  /// Opens the interactive shell, once. Repeat calls get the same session, so
  /// switching to the file browser and back never restarts the user's shell.
  ///
  /// The size is only honoured on the first call — the PTY is created there,
  /// and every later change flows through [SSHSession.resizeTerminal].
  Future<SSHSession> shell({required int columns, required int rows}) {
    final existing = _shell;
    if (existing != null) return Future<SSHSession>.value(existing);
    return _shellOpening ??= connection
        .startShell(columns: columns, rows: rows)
        .then((session) {
      _shell = session;
      _notify();
      return session;
    }).catchError((Object error) {
      _shellOpening = null;
      throw error;
    });
  }

  /// Opens the SFTP subsystem, once, on the connection that is already
  /// authenticated. No second login, no second host-key prompt.
  Future<RemoteFileSystem> sftp() {
    final existing = _sftp;
    if (existing != null) return Future<RemoteFileSystem>.value(existing);
    if (_closed) {
      return Future<RemoteFileSystem>.error(
        const SftpFailure('The session has ended. Reconnect to browse files.'),
      );
    }
    final open = _openFileSystem ??
        () => connection.openSftp().then<RemoteFileSystem>(SftpService.new);
    return _sftpOpening ??= open().then((service) {
      _sftp = service;
      return service;
    }).catchError((Object error) {
      _sftpOpening = null;
      throw error is SftpFailure
          ? error
          : SftpFailure(
              'The server refused an SFTP session. It may have the sftp '
              'subsystem disabled.',
              details: error.toString(),
            );
    });
  }

  // -------------------------------------------------------------- transfers

  /// Whether Downloads is writable, prompting for the legacy permission on
  /// API < 29 where scoped storage does not apply.
  Future<bool> ensureDownloadPermission() => _storage.ensurePermission();

  /// Whether a download of [fileName] would collide with an existing file.
  Future<bool> downloadWouldCollide(String fileName) =>
      _storage.downloadExists(RemotePath.sanitiseFileName(fileName));

  /// Queues [entry] for download. [overwrite] replaces a colliding file;
  /// otherwise the platform de-duplicates to `name (1).ext`.
  TransferTask queueDownload(RemoteEntry entry, {bool overwrite = false}) {
    return transfers.enqueueDownload(
      remotePath: entry.path,
      name: entry.name,
      saveAsName: RemotePath.sanitiseFileName(entry.name),
      overwrite: overwrite,
      totalBytes: entry.size,
    );
  }

  /// Queues one file of a recursive directory download, which unlike a
  /// single-file download carries the subdirectory it belongs in.
  TransferTask queuePlannedDownload(PlannedDownload planned) {
    return transfers.enqueueDownload(
      remotePath: planned.remotePath,
      name: planned.fileName,
      saveAsName: planned.fileName,
      totalBytes: planned.size,
      relativeDirectory: planned.relativeDirectory,
    );
  }

  /// Queues an upload of a locally staged file into [remoteDirectory],
  /// optionally under a different name — which is how "keep both" lands a
  /// second `notes.md` as `notes (1).md` instead of over the first.
  TransferTask queueUpload(
    PickedLocalFile file,
    String remoteDirectory, {
    String? asName,
  }) {
    final name = asName ?? file.name;
    return transfers.enqueueUpload(
      localPath: file.path,
      remotePath: RemotePath.join(remoteDirectory, name),
      name: name,
      totalBytes: file.size,
    );
  }

  // ------------------------------------------------------- shared-in uploads

  /// Files handed to this session from outside the browser — the share sheet,
  /// so far — waiting for the user to pick a destination directory.
  ///
  /// Held as state rather than published as an event because the file browser
  /// may not exist yet when the request arrives (a share can land on a
  /// session showing the terminal, or on one that is still connecting); a
  /// pane that builds later has to be able to find the request, not miss it.
  PendingUpload? get pendingUpload => _pendingUpload;
  PendingUpload? _pendingUpload;

  void requestUpload(List<PickedLocalFile> files) {
    if (files.isEmpty) return;
    _pendingUpload = PendingUpload(files);
    _notify();
  }

  void clearPendingUpload() {
    if (_pendingUpload == null) return;
    _pendingUpload = null;
    _notify();
  }

  Future<void> _runTransfer(TransferTask task, TransferHandle handle) async {
    if (_closed) {
      throw const SftpFailure('The session has ended. Reconnect to transfer.');
    }
    final sftp = await this.sftp();
    handle.throwIfCancelled();

    if (task.direction == TransferDirection.download) {
      await _runDownload(sftp, task, handle);
    } else {
      await _runUpload(sftp, task, handle);
    }
  }

  Future<void> _runDownload(
    RemoteFileSystem sftp,
    TransferTask task,
    TransferHandle handle,
  ) async {
    if (task.totalBytes == null) {
      handle.setTotal(await sftp.sizeOf(task.remotePath));
    }
    handle.throwIfCancelled();

    final fileName = task.saveAsName ?? RemotePath.sanitiseFileName(task.name);
    final directory = task.relativeDirectory;
    final writer = await _storage.beginDownload(
      fileName,
      mimeType: SftpService.mimeTypeFor(fileName),
      overwrite: task.overwrite,
      relativeDirectory: directory,
    );

    var completed = false;
    try {
      await sftp.download(
        task.remotePath,
        write: writer.add,
        onProgress: handle.report,
        isCancelled: () => handle.isCancelled,
      );
      handle.throwIfCancelled();
      final saved = await writer.finish();
      completed = true;
      handle.setDestination(
        directory.isEmpty
            ? 'Downloads/${saved.displayName}'
            : 'Downloads/$directory/${saved.displayName}',
        uri: saved.uri,
      );
    } finally {
      if (!completed) {
        await writer.abort();
      }
    }
  }

  Future<void> _runUpload(
    RemoteFileSystem sftp,
    TransferTask task,
    TransferHandle handle,
  ) async {
    await sftp.upload(
      task.localPath!,
      task.remotePath,
      onProgress: handle.report,
      isCancelled: () => handle.isCancelled,
    );
    handle.throwIfCancelled();
    handle.setDestination(task.remotePath);
  }

  /// Opens the system picker and stages the chosen file locally.
  Future<PickedLocalFile?> pickLocalFile() => _storage.pickFile();

  /// Opens the system picker for any number of files, staging each one.
  Future<List<PickedLocalFile>> pickLocalFiles() => _storage.pickFiles();

  /// Hands a finished download to whatever app can display it. False when
  /// nothing on the device can, or when the transfer has no URI to open —
  /// an upload, or a download that never finished.
  Future<bool> openDownload(TransferTask task) async {
    final uri = task.destinationUri;
    if (uri == null || uri.isEmpty) return false;
    return _storage.openDownload(
      uri,
      mimeType: SftpService.mimeTypeFor(task.saveAsName ?? task.name),
    );
  }

  // ----------------------------------------------------------------- teardown

  /// Ends the session: cancels transfers, closes the SFTP and shell channels,
  /// then the transport. Idempotent.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    _keepalive.stop();
    transfers.cancelAll();
    await transfers.dispose();

    final sftp = _sftp;
    _sftp = null;
    _sftpOpening = null;
    if (sftp != null) {
      try {
        await sftp.close();
      } catch (_) {
        // Already gone.
      }
    }

    try {
      _shell?.close();
    } catch (_) {
      // Already gone.
    }
    _shell = null;
    _shellOpening = null;

    connection.close();
    _closed = true;
    await _changes.close();
  }
}
