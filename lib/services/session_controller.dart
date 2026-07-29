import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
// `core.dart`, not `xterm.dart`: the terminal *buffer* is pure Dart and the
// widget that draws it is not, and only the buffer belongs down here. See
// [SessionController.terminal].
import 'package:xterm/core.dart';

import '../models/host.dart';
import '../models/remote_entry.dart';
import 'device_storage.dart';
import 'direct_remote_copy.dart';
import 'download_announcer.dart';
import 'download_plan.dart';
import 'remote_copy.dart';
import 'remote_path.dart';
import 'session_keepalive.dart';
import 'sftp_service.dart';
import 'ssh_service.dart';
import 'transfer_queue.dart';

export 'direct_remote_copy.dart'
    show
        DirectCopyUnavailableReason,
        DirectCopyWarning,
        SSHDirectCopyUnavailable;

/// Files waiting for a destination directory on this session.
class PendingUpload {
  const PendingUpload(this.files);

  final List<PickedLocalFile> files;

  int get count => files.length;

  int get totalBytes =>
      files.fold<int>(0, (sum, file) => sum + file.size);
}

/// Finds *another* open session, by its id.
///
/// Supplied by `SessionManager`, which is the only thing that knows what else
/// is open. Resolution happens when a transfer runs rather than when it is
/// queued, so a destination closed in between fails the transfer with an
/// explanation instead of writing into a dead channel — and so a retry, which
/// rebuilds the task from its fields, looks the destination up again.
///
/// It hands back the whole session rather than just its filesystem because the
/// destination has to be *told* when something lands on it: its file browser
/// is a different pane on a different session, with no sight of the queue the
/// transfer is running in.
///
/// Throws [SftpFailure] when there is no such live session.
typedef RemoteTargetResolver = Future<SessionController> Function(
  String sessionId,
);

/// Loads the [SshCredentials] saved for [hostId], or null when nothing is
/// saved (or the store cannot be read).
///
/// Injected as a callback so `SessionController` — and every service below
/// it — stays free of the credential store's dependency chain. The direct
/// copy path calls it once per transfer to pull *just the destination's*
/// key, hand it to a [CredentialSSHAgent] scoped to that transfer, and let
/// it fall out of scope when the exec ends.
typedef DestinationCredentialResolver = Future<SshCredentials?> Function(
  String hostId,
);

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
    RemoteTargetResolver? resolveRemoteTarget,
    DestinationCredentialResolver? resolveDestinationCredentials,
    PeriodicScheduler keepaliveScheduler = Timer.periodic,
  })  : _storage = storage ?? createDefaultDeviceStorage(),
        // ignore: prefer_initializing_formals
        _openFileSystem = openFileSystem,
        // ignore: prefer_initializing_formals
        _resolveRemoteTarget = resolveRemoteTarget,
        // ignore: prefer_initializing_formals
        _resolveDestinationCredentials = resolveDestinationCredentials {
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

  /// How this session reaches the other open sessions, for server-to-server
  /// transfers. Null when nothing else is open — or in the tests that do not
  /// exercise them — and a copy queued without one fails rather than hangs.
  final RemoteTargetResolver? _resolveRemoteTarget;

  /// How this session pulls the destination host's [SshCredentials] for a
  /// direct transfer. Null when the app has no credential store wired in
  /// (unit tests), and a direct transfer requested without one falls back
  /// to the relay path.
  final DestinationCredentialResolver? _resolveDestinationCredentials;

  /// Whether this session can copy files straight to another server.
  bool get canTransferToOtherSessions => _resolveRemoteTarget != null;

  /// The download/upload queue. Its executor is wired to this session, so a
  /// transfer cannot outlive the connection that is carrying it.
  late final TransferQueue transfers;

  /// What has already been said about finished downloads.
  ///
  /// Here rather than in the screen that shows the announcement for the same
  /// reason [pendingUpload] is: it is state about the session's transfers,
  /// and a view is too short-lived a thing to be trusted with it.
  final DownloadAnnouncer _announcer = DownloadAnnouncer();

  /// Keeps the socket from idling out while the app is in the background —
  /// the other half of Phase 7, alongside the foreground service that keeps
  /// the *process* alive. Runs for exactly as long as the session does.
  late final SessionKeepalive _keepalive;

  final _changes = StreamController<void>.broadcast();

  /// Directories on *this* server that a transfer running on some *other*
  /// session has just written into.
  ///
  /// Its own stream rather than a flag on [changes] because it carries a
  /// payload (which directory) and because nothing else should have to
  /// re-list on an unrelated notification. The file browser listens and
  /// refreshes when the directory it is showing is named, so a file copied in
  /// from another server appears where it landed instead of leaving the user
  /// looking at a listing that does not contain it.
  final _arrivals = StreamController<String>.broadcast();

  SSHSession? _shell;
  Future<SSHSession>? _shellOpening;
  Future<RemoteFileSystem>? _sftpOpening;
  RemoteFileSystem? _sftp;

  /// The scrollback, cursor and escape-sequence state of this session's shell.
  ///
  /// Here rather than inside the widget that draws it, and that is not a
  /// stylistic choice — it is what Phase 12 cost. Once a session outlives the
  /// screen showing it (leaving for the host list is how a *second* session
  /// gets opened), a `Terminal` owned by a `State` is thrown away every time
  /// the user leaves, taking the scrollback with it and leaving the next view
  /// to re-subscribe to an `SSHSession.stdout` that has already been listened
  /// to — which throws. Found on the emulator by switching tabs after opening
  /// a second session, exactly as described.
  ///
  /// `xterm`'s `Terminal` is pure Dart (`package:xterm/core.dart`), so this
  /// keeps `services/` free of Flutter: the view supplies the font, the theme
  /// and the gestures, and this supplies the bytes.
  late final Terminal terminal = Terminal(
    maxLines: 10000,
    platform: TerminalTargetPlatform.linux,
    onOutput: _sendToShell,
    onResize: _handleTerminalResize,
    onBell: () => onBell?.call(),
  );

  /// Set by the view, since a bell is haptics and a haptic is not a service.
  void Function()? onBell;

  /// Lets the view rewrite a keystroke on the way to the shell.
  ///
  /// Exists for one thing: the extra-key bar's sticky Ctrl. Whether "Ctrl" is
  /// currently armed is a property of a keyboard drawn on a screen, so the
  /// decision stays up there — but every route to the shell (soft keyboard,
  /// hardware keyboard, the bar's own buttons) funnels through [terminal]'s
  /// output callback, so the hook has to be here.
  String Function(String data)? transformInput;

  /// Completes when a view has laid out and reported the real column/row
  /// count, so the PTY is opened at the right size instead of 80×24 followed
  /// by an immediate resize — the remote shell draws its first prompt at
  /// whatever width it was given.
  final Completer<void> _initialSize = Completer<void>();

  Future<void>? _shellReady;
  final List<StreamSubscription<void>> _shellOutput = [];

  /// True once the shell channel is open and wired to [terminal].
  bool get isShellReady => _shellStarted;
  var _shellStarted = false;

  /// Why the shell could not be opened, or null. The session itself may be
  /// perfectly alive — the file browser still works.
  String? get shellError => _shellError;
  String? _shellError;

  var _closed = false;
  var _disposed = false;
  var _announcedDisconnect = false;
  String? _closeReason;

  Host get host => connection.host;

  /// Fires whenever the session's own state changes (connected → closed).
  /// Transfer progress has its own stream on [transfers].
  Stream<void> get changes => _changes.stream;

  /// Emits a directory on this server each time another session finishes
  /// writing a file into it. See [_arrivals].
  Stream<String> get arrivals => _arrivals.stream;

  /// Announces that something landed in [directory] on this server. Called by
  /// the *source* session's transfer, which is the only thing that knows.
  void reportArrival(String directory) {
    if (_disposed || _arrivals.isClosed) return;
    _arrivals.add(directory);
  }

  /// True once the transport is gone, for any reason.
  bool get isClosed => _closed;

  /// Why the session ended, for the disconnected banner.
  String? get closeReason => _closeReason;

  /// The drop worth telling the user about, exactly once, or null.
  ///
  /// Here rather than on the screen for the same reason [_announcer] is: with
  /// several sessions open, a drop on the one in the background still has to
  /// be announced when the user comes back to it, and it must be announced
  /// once — not on every rebuild while the banner is already up, and not
  /// again by whatever `State` replaces the one that said it.
  String? takeDisconnectAnnouncement() {
    if (!_closed || _announcedDisconnect) return null;
    _announcedDisconnect = true;
    return _closeReason ?? 'Connection closed.';
  }

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

  /// Opens the shell and wires it to [terminal] — once per session, however
  /// many views come and go.
  ///
  /// Waits for a view to report the real terminal size first, with a 1.5 s
  /// fallback to xterm's 80×24 default if one somehow never does: a slightly
  /// wrong PTY beats a shell that never opens.
  Future<void> ensureShell() => _shellReady ??= _openShell();

  Future<void> _openShell() async {
    await _initialSize.future.timeout(
      const Duration(milliseconds: 1500),
      onTimeout: () {},
    );

    try {
      final session = await shell(
        columns: terminal.viewWidth,
        rows: terminal.viewHeight,
      );

      // Decoding through the chunked converter (rather than utf8.decode per
      // chunk) keeps multi-byte characters intact when they straddle a packet
      // boundary — otherwise box-drawing and emoji output corrupts.
      const decoder = Utf8Decoder(allowMalformed: true);
      _shellOutput.add(
        session.stdout
            .cast<List<int>>()
            .transform(decoder)
            .listen(terminal.write, onError: (Object _) {}),
      );
      _shellOutput.add(
        session.stderr
            .cast<List<int>>()
            .transform(decoder)
            .listen(terminal.write, onError: (Object _) {}),
      );

      unawaited(
        session.done.then((_) {
          final code = session.exitCode;
          _handleShellEnded(
            code == null
                ? 'Shell session ended.'
                : 'Shell exited with status $code.',
          );
        }).catchError((Object error) {
          _handleShellEnded('Shell session ended: $error');
        }),
      );

      _shellStarted = true;
    } catch (e) {
      _shellError = e.toString();
      _shellStarted = true;
      terminal.write('\r\n\x1b[31mFailed to open a shell: $e\x1b[0m\r\n');
    }
    _notify();
  }

  /// Drops the local handle on a shell channel that has ended, so every later
  /// write and resize is a plain no-op instead of something that throws and
  /// relies on being caught.
  void _handleShellEnded(String reason) {
    _shell = null;
    reportShellEnded(reason);
  }

  void _sendToShell(String data) {
    final shell = _shell;
    if (shell == null || _closed) return;
    final payload = transformInput?.call(data) ?? data;
    try {
      shell.write(Uint8List.fromList(utf8.encode(payload)));
    } catch (_) {
      // Keystroke arrived after the channel closed; the disconnect banner is
      // already on its way.
    }
  }

  void _handleTerminalResize(int width, int height, int pixelWidth,
      int pixelHeight) {
    if (!_initialSize.isCompleted) _initialSize.complete();
    if (_closed) return;
    try {
      // Propagate SIGWINCH so full-screen programs (vim, htop, less) reflow.
      _shell?.resizeTerminal(width, height, pixelWidth, pixelHeight);
    } catch (_) {
      // The channel can close between the layout pass and this call; a resize
      // on a dead session is not worth surfacing.
    }
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

  /// Queues a copy of [remotePath] straight into another open session, named
  /// [asName] in [remoteDirectory] over there.
  ///
  /// [moveSource] makes it a move: the file here is deleted, but only once the
  /// write over there has been verified — see [copyRemoteFile].
  ///
  /// [route] picks between the relay path (bytes through this app; always
  /// available) and the direct path (bytes source→destination on the
  /// network between them). Direct silently falls back to relay when the
  /// direct path is unavailable — see [_runRemoteCopy].
  TransferTask queueRemoteCopy({
    required String remotePath,
    required String name,
    required String destinationSessionId,
    required String destinationLabel,
    required String remoteDirectory,
    String? asName,
    bool overwrite = false,
    bool moveSource = false,
    int? totalBytes,
    TransferRoute route = TransferRoute.relay,
  }) {
    final landingName = asName ?? name;
    return transfers.enqueueRemoteCopy(
      remotePath: remotePath,
      name: landingName,
      destinationSessionId: destinationSessionId,
      destinationLabel: destinationLabel,
      destinationPath: RemotePath.join(remoteDirectory, landingName),
      overwrite: overwrite,
      moveSource: moveSource,
      totalBytes: totalBytes,
      route: route,
    );
  }

  /// The finished downloads that have not been announced to the user yet,
  /// given the queue's latest [tasks]. Empty when there is nothing new to
  /// say, or when the queue is still busy and the batch is not complete.
  ///
  /// Consuming: each task comes back from here exactly once, however many
  /// views ask and however often the queue republishes the same list.
  List<TransferTask> takeDownloadAnnouncement(List<TransferTask> tasks) =>
      _announcer.take(tasks, queueBusy: transfers.hasActive);

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

    switch (task.direction) {
      case TransferDirection.download:
        await _runDownload(sftp, task, handle);
      case TransferDirection.upload:
        await _runUpload(sftp, task, handle);
      case TransferDirection.serverToServer:
        await _runRemoteCopy(sftp, task, handle);
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

  /// Streams one file from this session's server straight to another open
  /// session's, and — for a move — deletes it here once that is verified.
  ///
  /// The destination is resolved *now* rather than when the transfer was
  /// queued: the user may have closed that session while this one sat in the
  /// queue behind three other files, and a retry rebuilds the task from its
  /// fields with no live object to hold on to.
  ///
  /// **Route selection.** [TransferTask.route] is the user's request. Relay
  /// runs the copy through this device (see [copyRemoteFile]) and always
  /// works between two sessions we already have live channels on. Direct
  /// opens an exec on the source and runs `sftp` there, forwarding the
  /// destination's key through the source's agent slot (see
  /// [copyRemoteFileDirect]); on any recoverable failure — the destination
  /// is unreachable from the source, the source has no `sftp`, agent
  /// forwarding was refused, no cached passphrase — we fall back to relay
  /// and record why. An unrecoverable failure — the destination's host key
  /// on the wire is not the one we trust — refuses without falling back,
  /// because a relay from *this* device would not reproduce the anomaly and
  /// so cannot be a valid answer to it.
  Future<void> _runRemoteCopy(
    RemoteFileSystem sftp,
    TransferTask task,
    TransferHandle handle,
  ) async {
    final destinationId = task.destinationSessionId;
    final destinationPath = task.destinationPath;
    final resolve = _resolveRemoteTarget;
    if (destinationId == null || destinationPath == null || resolve == null) {
      throw const SftpFailure(
        'That transfer has no destination server to go to.',
      );
    }

    final target = await resolve(destinationId);
    final destination = await target.sftp();
    handle.throwIfCancelled();

    if (task.totalBytes == null) {
      handle.setTotal(await sftp.sizeOf(task.remotePath));
      handle.throwIfCancelled();
    }

    RemoteCopyOutcome? outcome;
    String? fallbackReason;

    if (task.route == TransferRoute.direct) {
      final resolveCreds = _resolveDestinationCredentials;
      if (resolveCreds == null) {
        fallbackReason =
            'no destination-credential resolver on this session';
      } else {
        final destCreds = await resolveCreds(target.host.id);
        handle.throwIfCancelled();
        if (destCreds == null) {
          fallbackReason = 'no saved credentials for the destination host';
        } else {
          try {
            handle.setRouteUsed(TransferRoute.direct);
            outcome = await copyRemoteFileDirect(
              source: this,
              destHost: target.host,
              destCredentials: destCreds,
              destinationFs: destination,
              sourcePath: task.remotePath,
              destinationPath: destinationPath,
              overwrite: task.overwrite,
              deleteSourceAfterVerify: task.moveSource,
              onProgress: handle.report,
              isCancelled: () => handle.isCancelled,
            );
          } on SSHDirectCopyUnavailable catch (e) {
            if (e.reason == DirectCopyUnavailableReason.hostKeyMismatch) {
              // Refuse: a relay from this device cannot honestly answer a
              // MITM-shaped signal seen on A→B, so surface it instead of
              // silently paving over it.
              rethrow;
            }
            fallbackReason = e.message ?? e.reason.name;
          }
        }
      }
    }

    outcome ??= await () async {
      handle.setRouteUsed(
        TransferRoute.relay,
        fallbackReason: fallbackReason,
      );
      return copyRemoteFile(
        source: sftp,
        destination: destination,
        sourcePath: task.remotePath,
        destinationPath: destinationPath,
        overwrite: task.overwrite,
        deleteSourceAfterVerify: task.moveSource,
        onProgress: handle.report,
        isCancelled: () => handle.isCancelled,
      );
    }();
    handle.throwIfCancelled();

    // The file is over there now, and the browser over there has no way of
    // knowing that from its own queue.
    target.reportArrival(RemotePath.parent(outcome.destinationPath));

    final label = task.destinationLabel;
    handle.setDestination(
      label == null || label.isEmpty
          ? outcome.destinationPath
          : '$label:${outcome.destinationPath}',
    );
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

    for (final subscription in _shellOutput) {
      unawaited(subscription.cancel());
    }
    _shellOutput.clear();

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
    await _arrivals.close();
    await _changes.close();
  }
}
