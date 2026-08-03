import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/host.dart';
import '../models/path_bookmark.dart';
import '../models/remote_entry.dart';
import '../services/bookmark_store.dart';
import '../services/device_storage.dart';
import '../services/download_plan.dart';
import '../services/editor_document.dart';
import '../services/remote_path.dart';
import '../services/remote_transfer_plan.dart';
import '../services/session_controller.dart';
import '../services/session_manager.dart';
import '../services/settings_store.dart';
import '../services/sftp_service.dart';
import '../services/transfer_queue.dart';
import '../services/upload_plan.dart';
import '../theme.dart';
import '../widgets/bookmark_sheet.dart';
import '../widgets/transfer_panel.dart';
import 'log_viewer_screen.dart';
import 'remote_directory_picker.dart';
import 'remote_editor_screen.dart';

/// What to do when a download would land on an existing file name.
enum _CollisionChoice { keepBoth, overwrite, cancel }

/// Whether the direct route is offered for this destination, and — when it
/// is not — a plain-English reason we can put under the disabled toggle so
/// the user is not left wondering.
class _DirectRouteOffer {
  const _DirectRouteOffer({required this.eligible, this.reason});

  final bool eligible;
  final String? reason;
}

/// The payload of a drag from a file row in one session's browser onto
/// another session's tab in the strip above.
///
/// Immutable and self-contained: it names its source (so the drop target can
/// refuse a drop on the same session, and so the transfer can be queued on
/// the source session's queue), the entries the user dragged (a single row,
/// or every selected row when the drag starts in selection mode), and the
/// directory those rows came from (informational — the drop dialog names it
/// when picking the destination folder).
///
/// A public type on purpose: the drop target is defined in `session_screen.dart`
/// and must know the payload's shape at compile time. Flutter's `DragTarget`
/// silently drops payloads whose type does not match its type parameter, so
/// mismatching this would look like "the drop simply did nothing" with no
/// error message to grep for.
class TabDropPayload {
  const TabDropPayload({
    required this.sourceSessionId,
    required this.entries,
    required this.sourceDirectory,
  });

  final String sourceSessionId;
  final List<RemoteEntry> entries;
  final String sourceDirectory;
}

/// The remote file browser: the other view on a live session.
///
/// Reuses the session's authenticated connection through
/// [SessionController.sftp], so opening it costs one extra SSH channel and no
/// extra credentials.
class FileBrowserPane extends StatefulWidget {
  // Not const: the bookmarkStore fallback below is a static final, not a
  // compile-time constant, so this constructor can no longer be one either.
  // No call site in the app built this with `const` (its `session` argument
  // never was), so nothing downstream is affected.
  FileBrowserPane({
    super.key,
    required this.session,
    required this.settingsStore,
    this.sessions,
    this.sessionId,
    this.initialShowHidden = false,
    BookmarkStore? bookmarkStore,
  }) : bookmarkStore = bookmarkStore ?? BookmarkStore.instance;

  final SessionController session;

  /// Where the editor gets the terminal font size and colour scheme from, so
  /// a file opened out of this browser is drawn in the same palette as the
  /// terminal next to it.
  final SettingsStore settingsStore;

  /// The other open sessions, so a file can be sent straight to one of them.
  /// Null in a context with no manager behind it, which simply hides the
  /// server-to-server actions.
  final SessionManager? sessions;

  /// Which entry in [sessions] this pane is showing — the *source* of a
  /// server-to-server transfer, and the one destination it must not offer.
  final String? sessionId;

  /// Seeds the per-session "show hidden files" toggle from Settings. The
  /// toggle itself stays per-session after that — this only sets where it
  /// starts.
  final bool initialShowHidden;

  /// Per-host saved paths, for the path bar's star toggle and its bookmarks
  /// sheet. Defaults to the process-wide store — see
  /// [BookmarkStore.instance] for why this is not threaded down from
  /// `main.dart` instead. Tests hand in their own instance, backed by a temp
  /// file, so runs do not share state with each other.
  final BookmarkStore bookmarkStore;

  @override
  State<FileBrowserPane> createState() => _FileBrowserPaneState();
}

class _FileBrowserPaneState extends State<FileBrowserPane>
    with AutomaticKeepAliveClientMixin {
  RemoteFileSystem? _sftp;

  String _path = RemotePath.root;
  List<RemoteEntry> _entries = const [];
  final Set<String> _selected = {};

  bool _loading = true;
  bool _showHidden = false;
  SftpFailure? _failure;

  /// Watches for a share arriving on this session while the browser is
  /// already open — the pending request lives on the controller, not in an
  /// event, so a pane built *after* the share still finds it.
  StreamSubscription<void>? _sessionChanges;

  StreamSubscription<List<TransferTask>>? _transferChanges;

  /// Files arriving from *another* session's transfer queue, which this pane
  /// cannot see from its own.
  StreamSubscription<String>? _arrivals;

  /// Transfers already counted, so each finishing is noticed exactly once.
  final Set<String> _refreshedFor = {};

  /// Set when a transfer changed the directory on screen, cleared by the
  /// refresh it triggers once the queue is quiet.
  bool _uploadLanded = false;

  /// This host's saved paths, for the star toggle and the bookmarks sheet.
  /// Loaded once in [initState] and kept in sync by hand after every add,
  /// remove or rename — a session's host never changes mid-life, so there is
  /// nothing to re-fetch this for beyond the pane's own edits.
  List<PathBookmark> _bookmarks = const [];

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _showHidden = widget.initialShowHidden;
    _sessionChanges = widget.session.changes.listen((_) {
      if (mounted) setState(() {});
    });
    _transferChanges =
        widget.session.transfers.changes.listen(_handleTransfers);
    _arrivals = widget.session.arrivals.listen(_handleArrival);
    unawaited(_openHome());
    unawaited(_reloadBookmarks());
  }

  @override
  void dispose() {
    _sessionChanges?.cancel();
    _transferChanges?.cancel();
    _arrivals?.cancel();
    super.dispose();
  }

  /// A file copied in from another server landed here.
  void _handleArrival(String directory) {
    if (!mounted || _loading || directory != _path) return;
    unawaited(_refresh());
  }

  /// Shows a finished transfer in the listing the moment it changes it.
  ///
  /// The file went into (or out of) the directory on screen, so leaving the
  /// user looking at a listing that does not reflect that — until they think
  /// to pull to refresh — makes a successful transfer look like a failed one.
  void _handleTransfers(List<TransferTask> tasks) {
    for (final task in tasks) {
      if (task.status != TransferStatus.completed) continue;
      // An upload lands here; a *move* to another server takes a file away
      // from here. Both change what this listing should say. A plain copy to
      // another server changes nothing on this side.
      final changesThisDirectory = switch (task.direction) {
        TransferDirection.upload => true,
        TransferDirection.serverToServer => task.moveSource,
        TransferDirection.download => false,
      };
      if (!changesThisDirectory) continue;
      if (!_refreshedFor.add(task.id)) continue;
      if (RemotePath.parent(task.remotePath) == _path) _uploadLanded = true;
    }
    // One listing after the batch, not one per file: uploading five files
    // should not cost five round trips just to redraw the same directory.
    if (!_uploadLanded || widget.session.transfers.hasActive) return;
    _uploadLanded = false;
    if (mounted && !_loading) unawaited(_refresh());
  }

  List<RemoteEntry> get _visible => _showHidden
      ? _entries
      : _entries.where((e) => !e.isHidden).toList(growable: false);

  bool get _selecting => _selected.isNotEmpty;

  Future<RemoteFileSystem> _client() async {
    final existing = _sftp;
    if (existing != null) return existing;
    final service = await widget.session.sftp();
    _sftp = service;
    return service;
  }

  Future<void> _openHome() async {
    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      final sftp = await _client();
      final home = await sftp.home();
      await _navigate(home, showSpinner: false);
    } on SftpFailure catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failure = e;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failure = SftpFailure(
          'Could not start a file session.',
          details: e.toString(),
        );
      });
    }
  }

  Future<void> _navigate(String path, {bool showSpinner = true}) async {
    if (showSpinner) {
      setState(() {
        _loading = true;
        _failure = null;
      });
    }

    try {
      final sftp = await _client();
      final entries = await sftp.list(path);
      if (!mounted) return;
      setState(() {
        _path = RemotePath.normalize(path);
        _entries = entries;
        _selected.clear();
        _loading = false;
        _failure = null;
      });
    } on SftpFailure catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failure = e;
        // Staying put on a failed navigation matters: a permission-denied
        // directory should leave the user where they were, with an
        // explanation, not on a blank screen with no way back.
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failure = SftpFailure('Could not open $path.', details: e.toString());
      });
    }
  }

  Future<void> _refresh() => _navigate(_path, showSpinner: false);

  void _goUp() {
    final parent = RemotePath.parent(_path);
    if (parent != _path) unawaited(_navigate(parent));
  }

  // ------------------------------------------------------------- bookmarks

  bool get _isBookmarked => _bookmarks.any((b) => b.path == _path);

  Future<void> _reloadBookmarks() async {
    final list =
        await widget.bookmarkStore.bookmarksForHost(widget.session.host.id);
    if (mounted) setState(() => _bookmarks = list);
  }

  /// Stars or un-stars the directory on screen. No dialog either way — a
  /// bookmark is cheap to undo by tapping the same star again, unlike a
  /// remove from inside the sheet, which is the one path that goes through
  /// [showBookmarksSheet] and its per-row menu instead.
  Future<void> _toggleBookmark() async {
    final hostId = widget.session.host.id;
    if (_isBookmarked) {
      await widget.bookmarkStore.removeForPath(hostId, _path);
    } else {
      await widget.bookmarkStore.add(hostId, _path);
    }
    await _reloadBookmarks();
  }

  Future<void> _openBookmarks() async {
    await showBookmarksSheet(
      context,
      store: widget.bookmarkStore,
      hostId: widget.session.host.id,
      currentPath: _path,
      bookmarks: _bookmarks,
      onJump: (path) => unawaited(_navigate(path)),
    );
    // The sheet can add, rename or remove rows on its own (rename/remove
    // live entirely inside it) — reload once it closes rather than trying to
    // keep two copies of "this host's bookmarks" in sync action by action.
    await _reloadBookmarks();
  }

  // ------------------------------------------------------------- selection

  void _toggleSelection(RemoteEntry entry) {
    if (!entry.isDownloadable) return;
    setState(() {
      if (!_selected.remove(entry.path)) _selected.add(entry.path);
    });
  }

  void _selectAll() {
    setState(() {
      _selected
        ..clear()
        ..addAll(_visible.where((e) => e.isDownloadable).map((e) => e.path));
    });
  }

  void _clearSelection() => setState(_selected.clear);

  // ------------------------------------------------------------- transfers

  Future<void> _downloadSelected() async {
    final chosen = _visible
        .where((e) => _selected.contains(e.path))
        .toList(growable: false);
    _clearSelection();
    await _download(chosen);
  }

  Future<void> _download(List<RemoteEntry> entries) async {
    if (entries.isEmpty) return;

    final permitted = await widget.session.ensureDownloadPermission();
    if (!mounted) return;
    if (!permitted) {
      _snack(
        'Storage permission is needed to save files to Downloads.',
        isError: true,
      );
      return;
    }

    // Resolve collisions once, up front, rather than interrupting the user
    // mid-queue with a dialog per file.
    var applyToAll = false;
    var overwriteAll = false;

    for (final entry in entries) {
      final saveAs = RemotePath.sanitiseFileName(entry.name);
      var overwrite = overwriteAll;

      if (!applyToAll) {
        final collides = await widget.session.downloadWouldCollide(saveAs);
        if (!mounted) return;
        if (collides) {
          final choice = await _askAboutCollision(
            saveAs,
            offerApplyToAll: entries.length > 1,
          );
          if (!mounted) return;
          switch (choice.$1) {
            case _CollisionChoice.cancel:
              return;
            case _CollisionChoice.overwrite:
              overwrite = true;
            case _CollisionChoice.keepBoth:
              overwrite = false;
          }
          if (choice.$2) {
            applyToAll = true;
            overwriteAll = overwrite;
          }
        }
      }

      widget.session.queueDownload(entry, overwrite: overwrite);
    }

    if (!mounted) return;
    _snack(
      entries.length == 1
          ? 'Downloading ${entries.first.name}'
          : 'Queued ${entries.length} downloads',
    );
  }

  /// Returns the choice, and whether it applies to the rest of the batch.
  Future<(_CollisionChoice, bool)> _askAboutCollision(
    String fileName, {
    required bool offerApplyToAll,
  }) async {
    var applyToAll = false;
    final choice = await showDialog<_CollisionChoice>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('File already exists'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Downloads already contains "$fileName".',
                style: const TextStyle(height: 1.35),
              ),
              if (offerApplyToAll)
                CheckboxListTile(
                  value: applyToAll,
                  onChanged: (v) =>
                      setDialogState(() => applyToAll = v ?? false),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text(
                    'Do this for the rest of this batch',
                    style: TextStyle(fontSize: 13),
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.of(context).pop(_CollisionChoice.cancel),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.of(context).pop(_CollisionChoice.overwrite),
              child: const Text('Replace'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(context).pop(_CollisionChoice.keepBoth),
              child: const Text('Keep both'),
            ),
          ],
        ),
      ),
    );
    return (choice ?? _CollisionChoice.cancel, applyToAll);
  }

  // --------------------------------------------------------------- uploads

  /// The primary upload path: pick any number of files, and land them in the
  /// directory the user is looking at.
  Future<void> _pickAndUpload() async {
    try {
      final picked = await widget.session.pickLocalFiles();
      if (!mounted || picked.isEmpty) return;
      await _uploadFiles(picked);
    } on DeviceStorageException catch (e) {
      if (mounted) _snack(e.message, isError: true);
    }
  }

  /// The other upload path: pick a whole folder and land it in the directory
  /// the user is looking at. The shape is preserved: empty subfolders too.
  ///
  /// The local walk happens synchronously before anything is queued, so the
  /// user can be told a count and a total before any bytes move — the same
  /// courtesy the recursive download path extends before it schedules
  /// hundreds of files.
  Future<void> _pickAndUploadFolder() async {
    final PickedLocalDirectory? picked;
    try {
      picked = await widget.session.pickLocalDirectory();
    } on DeviceStorageException catch (e) {
      if (mounted) _snack(e.message, isError: true);
      return;
    }
    if (!mounted || picked == null) return;

    // Captured now, in case the user navigates while the walk is running.
    final directory = _path;

    final LocalDirectoryTree tree;
    try {
      tree = await readLocalDirectoryTree(picked.path);
    } on LocalDirectoryWalkFailure catch (e) {
      if (mounted) _snack(e.message, isError: true);
      return;
    }
    if (!mounted) return;

    if (tree.isEmpty) {
      _snack('${picked.name} is empty — nothing to upload.');
      return;
    }

    // Whole-folder collision decision at the top level. Every file below
    // cascades from this choice, the same rule the S2S folder path uses.
    UploadCollisionResponse? decision;
    final sftp = await _client();
    if (!mounted) return;
    final existing = await remoteNamesIn(sftp, directory, [picked.name]);
    if (!mounted) return;
    if (existing.contains(picked.name)) {
      decision = await askAboutRemoteCollisionDialog(
        context,
        picked.name,
        directory,
        offerApplyToAll: false,
        hostLabel: widget.session.host.displayName,
      );
      if (!mounted || decision == null) return;
    }

    String landingName = picked.name;
    var overwrite = false;
    if (decision != null) {
      switch (decision.action) {
        case UploadCollisionAction.overwrite:
          overwrite = true;
        case UploadCollisionAction.keepBoth:
          landingName = RemotePath.deduplicate(
            picked.name,
            (candidate) => existing.contains(candidate),
          );
        case UploadCollisionAction.skip:
          _snack('Skipped ${picked.name}.');
          return;
      }
    }

    widget.session.queueUploadDirectory(
      pickedPath: picked.path,
      pickedName: picked.name,
      remoteDirectory: directory,
      asName: landingName,
      overwrite: overwrite,
      totalBytes: tree.totalBytes,
    );
    _snack(
      'Uploading ${picked.name} '
      '(${tree.fileCount} file${tree.fileCount == 1 ? '' : 's'}, '
      '${RemotePath.formatBytes(tree.totalBytes)}) '
      'to $directory/$landingName',
    );
  }

  /// Uploads [files] into the directory currently on screen, resolving name
  /// collisions with the server first.
  ///
  /// Shared by the picker and by files handed to the session from the Android
  /// share sheet — from here down they are the same thing.
  Future<void> _uploadFiles(List<PickedLocalFile> files) async {
    if (files.isEmpty) return;
    // Captured now: the user can navigate away while a collision dialog is
    // up, and the upload must land where they said, not where they ended up.
    final directory = _path;

    try {
      final sftp = await _client();
      final existing = await remoteNamesIn(
        sftp,
        directory,
        files.map((f) => f.name),
      );
      if (!mounted) return;

      final plan = await resolveUploadPlan(
        fileNames: files.map((f) => f.name).toList(growable: false),
        existingNames: existing,
        ask: (fileName, {required offerApplyToAll}) => _askAboutRemoteCollision(
          fileName,
          directory,
          offerApplyToAll: offerApplyToAll,
        ),
      );
      if (!mounted || plan.cancelled) return;

      if (plan.uploads.isEmpty) {
        _snack('Nothing uploaded — every file was skipped.');
        return;
      }
      for (final upload in plan.uploads) {
        widget.session.queueUpload(
          files[upload.sourceIndex],
          directory,
          asName: upload.remoteName,
        );
      }
      _snack(_uploadQueuedMessage(plan, directory));
    } on SftpFailure catch (e) {
      if (mounted) _snack(e.message, isError: true);
    }
  }

  String _uploadQueuedMessage(UploadPlan plan, String directory) {
    final count = plan.uploads.length;
    final head = count == 1
        ? 'Uploading ${plan.uploads.single.remoteName} to $directory'
        : 'Uploading $count files to $directory';
    if (plan.skipped.isEmpty) return head;
    return '$head · ${plan.skipped.length} skipped';
  }

  Future<UploadCollisionResponse?> _askAboutRemoteCollision(
    String fileName,
    String directory, {
    required bool offerApplyToAll,
    String? hostLabel,
  }) =>
      askAboutRemoteCollisionDialog(
        context,
        fileName,
        directory,
        offerApplyToAll: offerApplyToAll,
        hostLabel: hostLabel,
      );

  /// Takes the files a share handed to this session and uploads them here.
  Future<void> _uploadShared(PendingUpload pending) async {
    widget.session.clearPendingUpload();
    await _uploadFiles(pending.files);
  }

  // ---------------------------------------------------- server to server

  /// The other sessions this pane could send files to, or an empty list when
  /// there is no manager behind it.
  List<ManagedSession> get _destinations {
    final manager = widget.sessions;
    final id = widget.sessionId;
    if (manager == null || id == null) return const [];
    return manager.destinationsFor(id);
  }

  /// Copies (or moves) [entries] straight to another connected server.
  ///
  /// The bytes go source → this app → destination, chunk by chunk, and never
  /// touch the device's storage: see `remote_copy.dart` for how the read side
  /// is held back by the write side. Nothing here waits for that — the plan is
  /// made, the transfers are queued on this session, and both sessions stay
  /// usable while they run.
  Future<void> _sendToServer(
    List<RemoteEntry> entries, {
    required bool move,
  }) async {
    if (entries.isEmpty) return;
    final destinations = _destinations;
    if (destinations.isEmpty) {
      _snack(
        'Open a second server in another session first — then files can go '
        'straight from one to the other.',
      );
      return;
    }

    final target = destinations.length == 1
        ? destinations.single
        : await _pickDestinationSession(destinations, move: move);
    if (!mounted || target == null) return;

    // Once the destination is known, the rest of the flow — route pick,
    // folder pick, collision plan, queue, snackbar — is shared with the
    // drag-onto-tab entry point in `session_screen.dart`, which walks in
    // already knowing which tab was dropped on.
    await sendEntriesToSession(
      context,
      source: widget.session,
      destination: target,
      entries: entries,
      move: move,
      onQueued: _clearSelection,
    );
  }

  /// Which of several open servers the files are going to.
  Future<ManagedSession?> _pickDestinationSession(
    List<ManagedSession> destinations, {
    required bool move,
  }) {
    final theme = Theme.of(context);
    return showModalBottomSheet<ManagedSession>(
      context: context,
      backgroundColor: theme.colorScheme.surfaceContainerHigh,
      // One row per open session, so this list has no fixed height — enough
      // servers and a Column would overflow instead of scrolling, hiding the
      // destinations at the bottom. Shrink-wrapped so a short list still
      // sizes itself to its content.
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title:
                  Text(move ? 'Move to which server?' : 'Copy to which server?'),
              subtitle: const Text('The files never touch this device'),
            ),
            const Divider(height: 1),
            for (final destination in destinations)
              ListTile(
                leading: Icon(Icons.dns_outlined,
                    color: theme.colorScheme.primary),
                title: Text(destination.host.displayName),
                subtitle: Text(destination.host.target),
                onTap: () => Navigator.of(context).pop(destination),
              ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------ recursive folder download

  /// Walks [directory] and downloads everything under it, keeping the shape
  /// of the tree under `Download/<name>/`.
  ///
  /// The walk happens first and as its own step: a folder is the one thing in
  /// this browser whose size is invisible from the row that was tapped, so
  /// the user gets a count and a total before anything moves, and a way out
  /// while the scan is still running.
  Future<void> _downloadDirectory(RemoteEntry directory) async {
    final permitted = await widget.session.ensureDownloadPermission();
    if (!mounted) return;
    if (!permitted) {
      _snack(
        'Storage permission is needed to save files to Downloads.',
        isError: true,
      );
      return;
    }

    final RemoteFileSystem sftp;
    try {
      sftp = await _client();
    } on SftpFailure catch (e) {
      if (mounted) _snack(e.message, isError: true);
      return;
    }
    if (!mounted) return;

    final outcome = await showDialog<_ScanOutcome>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _ScanningDialog(
        filesystem: sftp,
        directory: directory.path,
        name: directory.name,
      ),
    );
    if (!mounted || outcome == null || outcome.cancelled) return;

    final failure = outcome.error;
    if (failure != null) {
      _snack(
        failure is SftpFailure
            ? failure.message
            : 'Could not read ${directory.name} from the server.',
        isError: true,
      );
      return;
    }

    final plan = outcome.plan!;
    if (plan.isEmpty) {
      _snack(
        plan.unreadable.isEmpty
            ? 'There are no files in ${directory.name}.'
            : 'Nothing in ${directory.name} could be read.',
      );
      return;
    }

    final confirmed = await _confirmDirectoryDownload(directory.name, plan);
    if (!mounted || confirmed != true) return;

    for (final file in plan.files) {
      widget.session.queuePlannedDownload(file);
    }
    _snack(
      'Downloading ${plan.fileCount} file'
      '${plan.fileCount == 1 ? '' : 's'} to Downloads/${plan.rootName}/',
    );
  }

  Future<bool?> _confirmDirectoryDownload(
    String name,
    DirectoryDownloadPlan plan,
  ) {
    final notes = <String>[
      if (plan.skippedLinks > 0)
        '${plan.skippedLinks} symbolic link'
            '${plan.skippedLinks == 1 ? '' : 's'} will be skipped — following '
            'them can loop back into the same folder.',
      if (plan.unreadable.isNotEmpty)
        '${plan.unreadable.length} folder'
            '${plan.unreadable.length == 1 ? '' : 's'} could not be read and '
            'will be left out.',
      if (plan.truncated)
        'This folder is larger than one download can cover; only the first '
            '${plan.fileCount} files are included.',
    ];

    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Download $name?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${plan.fileCount} file${plan.fileCount == 1 ? '' : 's'}, '
              '${RemotePath.formatBytes(plan.totalBytes)}, into '
              'Downloads/${plan.rootName}/ — subfolders and all.',
              style: const TextStyle(height: 1.35),
            ),
            for (final note in notes) ...[
              const SizedBox(height: 10),
              Text(
                note,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.3,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Download'),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- editing

  /// Opens [entry] in the built-in editor, over this session's SFTP channel.
  ///
  /// The same [RemoteFileSystem] the listing came from is handed straight to
  /// the editor: no second connection, no second credential prompt, and no
  /// interaction with the transfer queue — an edit is a round trip, not a
  /// transfer. The refusals (binary, too large) belong to the editor, which
  /// is where the bytes are, so nothing is pre-judged from the row here.
  Future<void> _edit(RemoteEntry entry) async {
    final RemoteFileSystem sftp;
    try {
      sftp = await _client();
    } on SftpFailure catch (e) {
      if (mounted) _snack(e.message, isError: true);
      return;
    }
    if (!mounted) return;

    await openRemoteEditor(
      context,
      filesystem: sftp,
      settingsStore: widget.settingsStore,
      paths: [entry.path],
      hostLabel: widget.session.host.displayName,
    );
    // A save changes the size and the timestamp on the row behind the
    // editor; coming back to a listing that still shows the old ones makes a
    // successful save look like it did nothing.
    if (mounted && !_loading) unawaited(_refresh());
  }

  /// Opens the live log viewer on [entry].
  ///
  /// Straight to the viewer with no SFTP round trip first: the tail runs over
  /// an exec channel, not the filesystem, and the viewer does its own
  /// readable check before it starts anything.
  Future<void> _tail(RemoteEntry entry) async {
    await openLogViewer(
      context,
      session: widget.session,
      path: entry.path,
      settingsStore: widget.settingsStore,
    );
  }

  /// Puts the remote path on the clipboard, so it can be pasted straight into
  /// the terminal pane next door.
  Future<void> _copyPath(RemoteEntry entry) async {
    await Clipboard.setData(ClipboardData(text: entry.path));
    if (mounted) _snack('Copied ${entry.path}');
  }

  void _snack(String message, {bool isError = false}) {
    final theme = Theme.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? theme.colorScheme.error : null,
      ),
    );
  }

  Future<void> _sendSelected({required bool move}) async {
    final chosen = _visible
        .where((e) => _selected.contains(e.path))
        .toList(growable: false);
    await _sendToServer(chosen, move: move);
  }

  Future<void> _showEntryActions(RemoteEntry entry) async {
    // Read before the sheet is built, so the "another server" rows appear only
    // when there is in fact another server open right now. Directories are
    // first-class targets since Phase 12.5 — the folder-copy and folder-move
    // paths handle them the same way the file paths do at this layer.
    final canSend = (entry.kind == RemoteEntryKind.file ||
            entry.kind == RemoteEntryKind.directory) &&
        _destinations.isNotEmpty;
    final isFolder = entry.kind == RemoteEntryKind.directory;
    final theme = Theme.of(context);

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: theme.colorScheme.surfaceContainerHigh,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(entry.name, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                '${RemotePath.formatBytes(entry.size)} · '
                '${_formatTime(entry.modified)}',
              ),
            ),
            const Divider(height: 1),
            if (entry.isDownloadable)
              ListTile(
                leading: Icon(Icons.edit_note,
                    color: theme.colorScheme.primary),
                title: const Text('Edit'),
                subtitle: const Text('Opens on the server, saves back in place'),
                onTap: () {
                  Navigator.of(context).pop();
                  unawaited(_edit(entry));
                },
              ),
            if (entry.isDownloadable)
              ListTile(
                leading: const Icon(Icons.download),
                title: const Text('Download'),
                subtitle: const Text('Saves to this device\'s Downloads'),
                onTap: () {
                  Navigator.of(context).pop();
                  unawaited(_download([entry]));
                },
              ),
            // Same predicate as Edit and Download: a regular file the server
            // will let us read. `tail -F` on a directory follows nothing, and
            // the viewer's own readable check would only refuse it a round
            // trip later.
            if (entry.isDownloadable)
              ListTile(
                leading: const Icon(Icons.subject),
                title: const Text('Tail file'),
                subtitle: const Text('Follows new lines as they are written'),
                onTap: () {
                  Navigator.of(context).pop();
                  unawaited(_tail(entry));
                },
              ),
            if (entry.isNavigable)
              ListTile(
                leading: const Icon(Icons.download_for_offline_outlined),
                title: const Text('Download folder'),
                subtitle: Text(
                  'Everything under it, into Downloads/${entry.name}/',
                ),
                onTap: () {
                  Navigator.of(context).pop();
                  unawaited(_downloadDirectory(entry));
                },
              ),
            if (canSend) ...[
              ListTile(
                leading: const Icon(Icons.drive_file_move_outlined),
                title: Text(
                  isFolder
                      ? 'Copy folder to another server…'
                      : 'Copy to another server…',
                ),
                subtitle: const Text('Straight across, without downloading'),
                onTap: () {
                  Navigator.of(context).pop();
                  unawaited(_sendToServer([entry], move: false));
                },
              ),
              ListTile(
                leading: const Icon(Icons.drive_file_move_rtl_outlined),
                title: Text(
                  isFolder
                      ? 'Move folder to another server…'
                      : 'Move to another server…',
                ),
                subtitle: Text(
                  isFolder
                      ? 'Deletes this folder once every file has been '
                          'verified over there'
                      : 'Deletes this copy once the other is verified',
                ),
                onTap: () {
                  Navigator.of(context).pop();
                  unawaited(_sendToServer([entry], move: true));
                },
              ),
            ],
            if (entry.isDownloadable)
              ListTile(
                leading: const Icon(Icons.checklist),
                title: const Text('Select'),
                onTap: () {
                  Navigator.of(context).pop();
                  _toggleSelection(entry);
                },
              ),
            ListTile(
              leading: const Icon(Icons.copy_all_outlined),
              title: const Text('Copy path'),
              subtitle: Text(entry.path, maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () {
                Navigator.of(context).pop();
                unawaited(_copyPath(entry));
              },
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    super.build(context);

    final pending = widget.session.pendingUpload;

    // A Scaffold *inside* the pane, not around both panes: on a tablet the
    // browser sits next to the terminal, and an upload button anchored to the
    // window would float over the wrong half of it. Nested here, the FAB
    // belongs to the file list, sits above the transfer bar (which is this
    // Scaffold's bottom bar, so the two can never overlap), and stays clear
    // of the app bar's transfers badge.
    return Scaffold(
      body: Column(
        children: [
          _PathBar(
            path: _path,
            onNavigate: (target) => unawaited(_navigate(target)),
            onUp: _goUp,
            isBookmarked: _isBookmarked,
            onToggleBookmark: () => unawaited(_toggleBookmark()),
            onOpenBookmarks: () => unawaited(_openBookmarks()),
          ),
          if (pending != null)
            _SharedFilesBanner(
              pending: pending,
              directory: _path,
              onUpload: () => unawaited(_uploadShared(pending)),
              onDismiss: widget.session.clearPendingUpload,
            ),
          if (_selecting)
            _SelectionBar(
              count: _selected.length,
              onSelectAll: _selectAll,
              onClear: _clearSelection,
              onDownload: () => unawaited(_downloadSelected()),
              onSendToServer: _destinations.isEmpty
                  ? null
                  : (move) => unawaited(_sendSelected(move: move)),
            )
          else
            _BrowserActions(
              showHidden: _showHidden,
              onToggleHidden: () => setState(() => _showHidden = !_showHidden),
              onRefresh: () => unawaited(_refresh()),
              onUpload: () => unawaited(_pickAndUpload()),
              onUploadFolder: _folderPickerAvailable
                  ? () => unawaited(_pickAndUploadFolder())
                  : null,
            ),
          const Divider(height: 1),
          Expanded(child: _buildBody()),
        ],
      ),
      // Hidden while selecting: that bar has its own primary action, and two
      // competing ones is how a user ends up tapping neither.
      floatingActionButton: _selecting
          ? null
          : FloatingActionButton.extended(
              onPressed: () => unawaited(
                pending != null ? _uploadShared(pending) : _pickAndUpload(),
              ),
              icon: const Icon(Icons.upload_file),
              // The label names the destination, because "here" is the whole
              // point: uploads land in the directory on screen, and the path
              // bar directly above says which one that is.
              label: Text(
                pending != null
                    ? 'Upload ${pending.count} here'
                    : 'Upload here',
              ),
              tooltip: 'Upload files into $_path',
            ),
      bottomNavigationBar: TransferSummaryBar(
        queue: widget.session.transfers,
        onTap: () => showTransfersSheet(
          context,
          widget.session.transfers,
          onOpen: widget.session.openDownload,
        ),
      ),
    );
  }

  /// Which rows the user meant to drag when they long-pressed [entry].
  ///
  /// Not selecting: the row under their finger, if it is a file or a
  /// directory — Phase 12.5 made folders first-class here, so a dragged
  /// folder queues one recursive-copy task on drop. Selecting: if the
  /// pressed row is *in* the selection, every selected file and folder in
  /// the selection goes; if the pressed row is not in the selection, the
  /// drag is empty and the long-press falls through to its ordinary
  /// toggle-select. Non-file, non-directory rows (dangling symlinks and
  /// anything else) cannot start a drag — the drop target has nowhere
  /// sensible to put them.
  List<RemoteEntry> _dragEntriesFor(RemoteEntry entry) {
    bool draggable(RemoteEntry e) =>
        e.isDownloadable || e.kind == RemoteEntryKind.directory;
    if (_selecting) {
      if (!_selected.contains(entry.path)) return const [];
      return _visible
          .where((e) => _selected.contains(e.path) && draggable(e))
          .toList(growable: false);
    }
    if (!draggable(entry)) return const [];
    return [entry];
  }

  Widget _buildEntryTile(RemoteEntry entry) {
    final tile = _EntryTile(
      entry: entry,
      selected: _selected.contains(entry.path),
      selecting: _selecting,
      onTap: () {
        if (_selecting) {
          _toggleSelection(entry);
        } else if (entry.isNavigable) {
          unawaited(_navigate(entry.path));
        } else if (entry.isDownloadable) {
          // A tap on something that reads as text and is small enough to
          // arrive quickly opens it for editing; everything else keeps the
          // download it has always had. The action sheet still offers both
          // either way, so neither choice is a dead end.
          if (tapShouldEdit(name: entry.name, size: entry.size)) {
            unawaited(_edit(entry));
          } else {
            unawaited(_download([entry]));
          }
        }
      },
      onLongPress: () {
        if (_selecting) {
          _toggleSelection(entry);
        } else {
          unawaited(_showEntryActions(entry));
        }
      },
    );

    // Drag-to-tab only offers itself when there is somewhere to drag *to* — no
    // other open session means no drop target. And on Android the long-press
    // on a row is what opens the action sheet, which is the only path into
    // multi-select on a touch device; a LongPressDraggable would swallow that
    // gesture and leave Android users with no way in. Desktop platforms get
    // drag; Android/iOS keep the old behaviour, and the same "Copy to another
    // server…" row on the action sheet still works for them.
    if (widget.sessionId == null || _destinations.isEmpty) return tile;
    if (!_isDesktop(context)) return tile;

    final dragEntries = _dragEntriesFor(entry);
    if (dragEntries.isEmpty) return tile;

    final payload = TabDropPayload(
      sourceSessionId: widget.sessionId!,
      entries: dragEntries,
      sourceDirectory: _path,
    );
    return LongPressDraggable<TabDropPayload>(
      data: payload,
      hapticFeedbackOnStart: true,
      // A single row keeps its height under the finger; a wider ghost during
      // a multi-select drag would obscure the tab strip the user is aiming at.
      feedback: _DragFeedback(entries: dragEntries),
      // Fade the source row rather than remove it: pulling a row out from
      // under the cursor makes the list jump, and the row is coming back the
      // moment the drop lands (or is refused).
      childWhenDragging: Opacity(opacity: 0.35, child: tile),
      onDragCompleted: () {
        // Only on an accepted drop — a cancelled drag leaves the selection
        // where it was, because the user has not committed to anything yet.
        if (_selecting) _clearSelection();
      },
      child: tile,
    );
  }

  /// Whether the platform has a folder picker wired up. Desktop platforms
  /// use `file_selector`'s `getDirectoryPath`; Android's SAF tree picker is
  /// a documented gap (`StorageBridge.kt`), so the entry hides on Android
  /// until the PM lands it — a menu row that silently does nothing is
  /// worse than none.
  bool get _folderPickerAvailable {
    switch (Theme.of(context).platform) {
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        return true;
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.fuchsia:
        return false;
    }
  }

  /// Desktop platforms — Linux, macOS, Windows — where a mouse is the primary
  /// pointer and long-press-to-drag reads as natural. Kept out of the state
  /// so the platform check can be swapped in tests via
  /// [debugDefaultTargetPlatformOverride].
  static bool _isDesktop(BuildContext context) {
    switch (Theme.of(context).platform) {
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        return true;
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.fuchsia:
        return false;
    }
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final failure = _failure;
    final visible = _visible;

    return RefreshIndicator(
      onRefresh: _refresh,
      child: CustomScrollView(
        // Keeps pull-to-refresh working even when the list is empty or the
        // whole view is an error message.
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          if (failure != null)
            SliverToBoxAdapter(child: _FailureBanner(failure: failure)),
          if (visible.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _EmptyDirectory(
                hiddenCount: _entries.length,
                showHidden: _showHidden,
                onShowHidden: () => setState(() => _showHidden = true),
              ),
            )
          else
            SliverPadding(
              // Room for the upload FAB, so the last row in a directory is
              // never the one hiding under it.
              padding: const EdgeInsets.only(bottom: 88),
              sliver: SliverList.separated(
                itemCount: visible.length,
                separatorBuilder: (_, _) =>
                    const Divider(height: 1, indent: 56),
                itemBuilder: (context, index) => _buildEntryTile(visible[index]),
              ),
            ),
        ],
      ),
    );
  }
}

/// The shared "run a server-to-server transfer with a known destination" flow.
///
/// Two entry points call this: the browser pane's per-entry action sheet
/// (which picks the destination first) and the drop handler on the tab strip
/// (which knows the destination already, because that is what the drop chose).
/// The steps in between — route pick, folder pick, collision resolution,
/// queueing on the source session's [TransferQueue], and the snackbar — are
/// the same either way. It runs on [context] so that a source whose pane has
/// scrolled away can still show the dialogs on top of the sessions screen.
///
/// [onQueued] fires once the transfers have been enqueued (not once they
/// finish). The action-sheet caller uses it to clear its selection; the drop
/// caller has no selection to clear and leaves it null.
Future<void> sendEntriesToSession(
  BuildContext context, {
  required SessionController source,
  required ManagedSession destination,
  required List<RemoteEntry> entries,
  required bool move,
  VoidCallback? onQueued,
}) async {
  if (entries.isEmpty) return;
  final messenger = ScaffoldMessenger.of(context);

  // The bytes-bypass-this-device switch lives here rather than on the
  // destination-picker sheet because the eligibility rule needs both
  // ends: a password-auth destination cannot be forwarded via agent
  // (see `direct_remote_copy.dart`), so we grey the switch and note
  // the reason so the user is not left wondering why it is off.
  final directOffer = _directRouteFor(destination.host);
  final chosenRoute = await _pickRoute(
    context,
    target: destination,
    offer: directOffer,
    move: move,
  );
  if (chosenRoute == null || !context.mounted) return;

  final directory = await pickRemoteDirectory(
    context,
    session: destination,
    confirmLabel: move ? 'Move here' : 'Copy here',
    subtitle: entries.length == 1
        ? '${move ? 'Move' : 'Copy'} ${entries.single.name} to…'
        : '${move ? 'Move' : 'Copy'} ${entries.length} files to…',
  );
  if (directory == null || !context.mounted) return;

  final RemoteFileSystem destinationFs;
  try {
    destinationFs = await destination.controller.sftp();
  } on SftpFailure catch (e) {
    if (context.mounted) _showErrorSnack(messenger, e.message);
    return;
  }
  if (!context.mounted) return;

  final RemoteTransferPlan plan;
  try {
    plan = await planRemoteTransfer(
      entries: entries,
      destination: destinationFs,
      destinationDirectory: directory,
      ask: (fileName, {required offerApplyToAll}) =>
          askAboutRemoteCollisionDialog(
        context,
        fileName,
        directory,
        offerApplyToAll: offerApplyToAll,
        hostLabel: destination.host.displayName,
      ),
    );
  } on SftpFailure catch (e) {
    if (context.mounted) _showErrorSnack(messenger, e.message);
    return;
  }
  if (plan.cancelled || !context.mounted) return;

  if (plan.isEmpty) {
    final theme = Theme.of(context);
    messenger.showSnackBar(SnackBar(
      content: Text(_nothingSentMessage(plan)),
      backgroundColor:
          plan.unsupported.isNotEmpty ? theme.colorScheme.error : null,
    ));
    return;
  }

  for (final transfer in plan.transfers) {
    final entry = plan.entryFor(transfer);
    if (entry.kind == RemoteEntryKind.directory) {
      source.queueRemoteCopyDirectory(
        remotePath: entry.path,
        name: entry.name,
        destinationSessionId: destination.id,
        destinationLabel: destination.host.displayName,
        remoteDirectory: directory,
        asName: transfer.remoteName,
        overwrite: transfer.overwrite,
        moveSource: move,
        route: chosenRoute,
      );
    } else {
      source.queueRemoteCopy(
        remotePath: entry.path,
        name: entry.name,
        destinationSessionId: destination.id,
        destinationLabel: destination.host.displayName,
        remoteDirectory: directory,
        asName: transfer.remoteName,
        overwrite: transfer.overwrite,
        moveSource: move,
        totalBytes: entry.size,
        route: chosenRoute,
      );
    }
  }

  onQueued?.call();
  messenger.showSnackBar(SnackBar(
    content: Text(
      _sentMessage(plan, destination, directory, move: move, route: chosenRoute),
    ),
  ));
}

void _showErrorSnack(ScaffoldMessengerState messenger, String message) {
  final theme = Theme.of(messenger.context);
  messenger.showSnackBar(SnackBar(
    content: Text(message),
    backgroundColor: theme.colorScheme.error,
  ));
}

/// Whether the direct path is eligible for [destination], and — when it
/// is not — a short reason to show under the disabled toggle.
_DirectRouteOffer _directRouteFor(Host destination) {
  if (destination.authMethod != SshAuthMethod.privateKey) {
    return const _DirectRouteOffer(
      eligible: false,
      reason: 'Password-auth destinations cannot be forwarded via agent.',
    );
  }
  return const _DirectRouteOffer(eligible: true);
}

/// Ask the user which route to take. The direct-transfer toggle is
/// shown either way — when ineligible it is greyed out and captioned
/// with why, so a password-auth destination does not silently pick
/// relay under a name the user never saw.
Future<TransferRoute?> _pickRoute(
  BuildContext context, {
  required ManagedSession target,
  required _DirectRouteOffer offer,
  required bool move,
}) async {
  var useDirect = offer.eligible;
  final go = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: Text(move ? 'Move to server' : 'Copy to server'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Destination: ${target.host.displayName}',
              style: const TextStyle(height: 1.4),
            ),
            const SizedBox(height: 12),
            CheckboxListTile(
              value: useDirect,
              onChanged: offer.eligible
                  ? (v) => setDialogState(() => useDirect = v ?? false)
                  : null,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text(
                'Use direct transfer',
                style: TextStyle(fontSize: 14),
              ),
              subtitle: Text(
                offer.eligible
                    ? 'Bytes go from source server to destination server '
                        'on the network between them, bypassing this '
                        'device. Falls back to the relay path if the '
                        'servers cannot reach each other.'
                    : offer.reason ??
                        'Direct transfer is not available for this '
                            'destination.',
                style: const TextStyle(fontSize: 12, height: 1.35),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(move ? 'Move' : 'Copy'),
          ),
        ],
      ),
    ),
  );
  if (go != true) return null;
  return useDirect ? TransferRoute.direct : TransferRoute.relay;
}

/// Shared "this file already exists on the destination" prompt.
///
/// Used both by uploads (where the destination is this session) and by
/// server-to-server transfers (where the destination is another session and
/// [hostLabel] names it).
Future<UploadCollisionResponse?> askAboutRemoteCollisionDialog(
  BuildContext context,
  String fileName,
  String directory, {
  required bool offerApplyToAll,
  String? hostLabel,
}) async {
  var applyToAll = false;
  final action = await showDialog<UploadCollisionAction>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: const Text('Already on the server'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              hostLabel == null
                  ? '"$fileName" already exists in $directory.'
                  : '"$fileName" already exists in $directory on '
                      '$hostLabel.',
              style: const TextStyle(height: 1.35),
            ),
            if (offerApplyToAll)
              CheckboxListTile(
                value: applyToAll,
                onChanged: (v) =>
                    setDialogState(() => applyToAll = v ?? false),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text(
                  'Do this for the rest of this batch',
                  style: TextStyle(fontSize: 13),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(UploadCollisionAction.skip),
            child: const Text('Skip'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(UploadCollisionAction.overwrite),
            child: const Text('Replace'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(UploadCollisionAction.keepBoth),
            child: const Text('Keep both'),
          ),
        ],
      ),
    ),
  );
  // A dismissed dialog is not consent to overwrite someone's file: null
  // cancels the whole batch.
  if (action == null) return null;
  return UploadCollisionResponse(action, applyToAll: applyToAll);
}

String _nothingSentMessage(RemoteTransferPlan plan) {
  if (plan.unsupported.isNotEmpty && plan.entries.isEmpty) {
    return plan.unsupported.length == 1
        ? '"${plan.unsupported.single}" is a symbolic link. Only files and '
            'folders can go straight between servers.'
        : 'Symbolic links cannot go straight between servers — only files '
            'and folders.';
  }
  return 'Nothing sent — every item was skipped.';
}

String _sentMessage(
  RemoteTransferPlan plan,
  ManagedSession target,
  String directory, {
  required bool move,
  required TransferRoute route,
}) {
  final verb = move ? 'Moving' : 'Copying';
  final count = plan.transfers.length;
  final head = count == 1
      ? '$verb ${plan.transfers.single.remoteName} to '
          '${target.host.displayName}:$directory'
      : '$verb $count items to ${target.host.displayName}:$directory';
  final notes = <String>[
    if (route == TransferRoute.direct) 'direct',
    if (plan.skipped.isNotEmpty) '${plan.skipped.length} skipped',
    if (plan.unsupported.isNotEmpty)
      '${plan.unsupported.length} link'
          '${plan.unsupported.length == 1 ? '' : 's'} left out',
  ];
  return notes.isEmpty ? head : '$head · ${notes.join(' · ')}';
}

/// What [_ScanningDialog] hands back: a plan, a failure, or a cancellation.
class _ScanOutcome {
  const _ScanOutcome({this.plan, this.error, this.cancelled = false});

  final DirectoryDownloadPlan? plan;
  final Object? error;
  final bool cancelled;
}

/// Walks a remote directory while showing what it has found so far.
///
/// A dialog rather than a spinner in the corner because the walk is many
/// round trips over a phone's connection — the user needs to see it moving,
/// and needs to be able to stop it.
class _ScanningDialog extends StatefulWidget {
  const _ScanningDialog({
    required this.filesystem,
    required this.directory,
    required this.name,
  });

  final RemoteFileSystem filesystem;
  final String directory;
  final String name;

  @override
  State<_ScanningDialog> createState() => _ScanningDialogState();
}

class _ScanningDialogState extends State<_ScanningDialog> {
  var _cancelled = false;

  @override
  void initState() {
    super.initState();
    unawaited(_scan());
  }

  Future<void> _scan() async {
    _ScanOutcome outcome;
    try {
      final plan = await planDirectoryDownload(
        widget.filesystem,
        widget.directory,
        isCancelled: () => _cancelled,
      );
      outcome = _ScanOutcome(plan: plan);
    } on DirectoryWalkCancelled {
      outcome = const _ScanOutcome(cancelled: true);
    } catch (e) {
      outcome = _ScanOutcome(error: e);
    }
    if (!mounted) return;
    Navigator.of(context).pop(outcome);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Scanning ${widget.name}…'),
      content: const Row(
        children: [
          SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 16),
          Expanded(
            child: Text(
              'Counting the files and folders inside.',
              style: TextStyle(fontSize: 13, height: 1.35),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          // The walk notices between listings, so the dialog stays up for one
          // more round trip rather than popping on a scan that is still
          // running.
          onPressed: () => setState(() => _cancelled = true),
          child: Text(_cancelled ? 'Stopping…' : 'Cancel'),
        ),
      ],
    );
  }
}

/// The bar that appears when files arrive from another app's Share menu.
class _SharedFilesBanner extends StatelessWidget {
  const _SharedFilesBanner({
    required this.pending,
    required this.directory,
    required this.onUpload,
    required this.onDismiss,
  });

  final PendingUpload pending;
  final String directory;
  final VoidCallback onUpload;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final one = pending.count == 1;
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.primary.withValues(alpha: 0.14),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
        child: Row(
          children: [
            Icon(Icons.ios_share, size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    one
                        ? 'Shared: ${pending.files.single.name}'
                        : '${pending.count} shared files '
                            '(${RemotePath.formatBytes(pending.totalBytes)})',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Browse to a folder, then upload into it.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: onUpload,
              child: const Text('Upload here'),
            ),
            IconButton(
              tooltip: 'Dismiss',
              icon: const Icon(Icons.close, size: 18),
              onPressed: onDismiss,
            ),
          ],
        ),
      ),
    );
  }
}

class _PathBar extends StatelessWidget {
  const _PathBar({
    required this.path,
    required this.onNavigate,
    required this.onUp,
    required this.isBookmarked,
    required this.onToggleBookmark,
    required this.onOpenBookmarks,
  });

  final String path;
  final void Function(String path) onNavigate;
  final VoidCallback onUp;

  /// Whether [path] itself — the directory on screen right now — is
  /// bookmarked, for the star's filled/outline state.
  final bool isBookmarked;
  final VoidCallback onToggleBookmark;
  final VoidCallback onOpenBookmarks;

  @override
  Widget build(BuildContext context) {
    final crumbs = RemotePath.breadcrumbs(path);
    final theme = Theme.of(context);

    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      child: Row(
        children: [
          IconButton(
            tooltip: 'Up one level',
            icon: const Icon(Icons.arrow_upward, size: 20),
            onPressed: path == RemotePath.root ? null : onUp,
          ),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              child: Row(
                children: [
                  for (var i = 0; i < crumbs.length; i++) ...[
                    if (i > 0)
                      Text(
                        '/',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    TextButton(
                      onPressed: i == crumbs.length - 1
                          ? null
                          : () => onNavigate(crumbs[i].path),
                      style: TextButton.styleFrom(
                        minimumSize: Size.zero,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        disabledForegroundColor: theme.colorScheme.onSurface,
                      ),
                      child: Text(
                        crumbs[i].label == RemotePath.root
                            ? '/'
                            : crumbs[i].label,
                        style: TextStyle(
                          fontFamily: AppTheme.monoFontFamily,
                          fontFamilyFallback: AppTheme.monoFontFamilyFallback,
                          fontSize: 13,
                          fontWeight: i == crumbs.length - 1
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: isBookmarked
                ? 'Remove bookmark for this folder'
                : 'Bookmark this folder',
            icon: Icon(
              isBookmarked ? Icons.star : Icons.star_border,
              size: 20,
              color: isBookmarked ? theme.colorScheme.primary : null,
            ),
            onPressed: onToggleBookmark,
          ),
          IconButton(
            tooltip: 'Bookmarks',
            icon: const Icon(Icons.bookmarks_outlined, size: 20),
            onPressed: onOpenBookmarks,
          ),
        ],
      ),
    );
  }
}

class _BrowserActions extends StatelessWidget {
  const _BrowserActions({
    required this.showHidden,
    required this.onToggleHidden,
    required this.onRefresh,
    required this.onUpload,
    this.onUploadFolder,
  });

  final bool showHidden;
  final VoidCallback onToggleHidden;
  final VoidCallback onRefresh;
  final VoidCallback onUpload;

  /// The folder picker's entry, or null on a platform where no picker is
  /// wired up yet (Android). On desktop we surface it as a separate icon
  /// alongside the file picker so a user who knows they want a whole folder
  /// does not have to open a menu — the FAB below still handles the common
  /// files case.
  final VoidCallback? onUploadFolder;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          const SizedBox(width: 4),
          TextButton.icon(
            onPressed: onToggleHidden,
            icon: Icon(
              showHidden ? Icons.visibility : Icons.visibility_off_outlined,
              size: 18,
            ),
            label: Text(
              showHidden ? 'Hidden shown' : 'Hidden files',
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
          const Spacer(),
          if (onUploadFolder != null)
            IconButton(
              tooltip: 'Upload a folder here',
              icon: const Icon(Icons.drive_folder_upload, size: 20),
              onPressed: onUploadFolder,
            ),
          IconButton(
            tooltip: 'Upload a file here',
            icon: const Icon(Icons.upload_file, size: 20),
            onPressed: onUpload,
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: onRefresh,
          ),
        ],
      ),
    );
  }
}

class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.count,
    required this.onSelectAll,
    required this.onClear,
    required this.onDownload,
    this.onSendToServer,
  });

  final int count;
  final VoidCallback onSelectAll;
  final VoidCallback onClear;
  final VoidCallback onDownload;

  /// Sends the selection to another open session — `true` for a move. Null
  /// when nothing else is connected, which is the only reason the button is
  /// not there at all rather than there and disabled: "copy to another server"
  /// with no other server is not a state worth explaining in a tooltip on a
  /// bar this narrow.
  final void Function(bool move)? onSendToServer;

  @override
  Widget build(BuildContext context) {
    final sendTo = onSendToServer;
    final theme = Theme.of(context);

    return Material(
      color: theme.colorScheme.primary.withValues(alpha: 0.12),
      child: SizedBox(
        height: 48,
        child: Row(
          children: [
            IconButton(
              tooltip: 'Clear selection',
              icon: const Icon(Icons.close, size: 20),
              onPressed: onClear,
            ),
            Text('$count selected', style: const TextStyle(fontSize: 13)),
            const Spacer(),
            TextButton(onPressed: onSelectAll, child: const Text('All')),
            if (sendTo != null)
              PopupMenuButton<bool>(
                tooltip: 'Send to another server',
                icon: const Icon(Icons.drive_file_move_outlined, size: 20),
                onSelected: sendTo,
                itemBuilder: (context) => const [
                  PopupMenuItem<bool>(
                    value: false,
                    child: Text('Copy to another server…'),
                  ),
                  PopupMenuItem<bool>(
                    value: true,
                    child: Text('Move to another server…'),
                  ),
                ],
              ),
            FilledButton.icon(
              onPressed: onDownload,
              icon: const Icon(Icons.download, size: 18),
              label: const Text('Download'),
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 40),
                padding: const EdgeInsets.symmetric(horizontal: 14),
              ),
            ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}

/// The small chip that floats under the cursor while dragging a file (or
/// several) toward another session's tab.
///
/// Deliberately compact: the whole point of the drag is to see which tab is
/// about to accept the drop, and a ghost the size of a row would cover the
/// tab strip. Named for the batch when the drag carries a selection, so a
/// user dragging fifteen files sees "15 files" rather than the name of
/// whichever one happened to be under the finger.
class _DragFeedback extends StatelessWidget {
  const _DragFeedback({required this.entries});

  final List<RemoteEntry> entries;

  @override
  Widget build(BuildContext context) {
    final label = entries.length == 1
        ? entries.single.name
        : '${entries.length} files';
    final theme = Theme.of(context);
    return Material(
      // A raised container tone reads as "a card lifted off the list"
      // against both the terminal background and the file browser's own
      // surface.
      color: theme.colorScheme.surfaceContainerHigh,
      elevation: 6,
      borderRadius: BorderRadius.circular(6),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 220),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                entries.length == 1
                    ? Icons.insert_drive_file_outlined
                    : Icons.file_copy_outlined,
                size: 16,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, height: 1.2),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({
    required this.entry,
    required this.selected,
    required this.selecting,
    required this.onTap,
    required this.onLongPress,
  });

  final RemoteEntry entry;
  final bool selected;
  final bool selecting;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitle = entry.kind.isDirectory
        ? _formatTime(entry.modified)
        : '${RemotePath.formatBytes(entry.size)}  ·  '
            '${_formatTime(entry.modified)}';

    // ListTile has no onSecondaryTap of its own, so wrap it: on desktop
    // right-click opens the same action sheet long-press opens on touch
    // devices. Behind the tile so the ink and hover effects still come
    // from the tile itself, not a bare GestureDetector.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTap: onLongPress,
      child: ListTile(
        // Not dense: fat-finger comfort for a list of remote files matters
        // more here than screen density.
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        selected: selected,
        selectedTileColor: theme.colorScheme.primary.withValues(alpha: 0.1),
        leading: selecting && entry.isDownloadable
            ? Icon(
                selected ? Icons.check_circle : Icons.circle_outlined,
                color: selected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              )
            : Icon(_iconFor(entry), color: _colourFor(entry, theme)),
        title: Text(
          entry.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 14,
            color: entry.isHidden
                ? theme.colorScheme.onSurfaceVariant
                : theme.colorScheme.onSurface,
          ),
        ),
        subtitle: Text(subtitle, style: theme.textTheme.bodySmall),
        trailing: entry.isNavigable
            ? const Icon(Icons.chevron_right, size: 18)
            : null,
        onTap: onTap,
        onLongPress: onLongPress,
      ),
    );
  }

  static IconData _iconFor(RemoteEntry entry) => switch (entry.kind) {
        RemoteEntryKind.directory => Icons.folder,
        RemoteEntryKind.symlink => Icons.link,
        RemoteEntryKind.file => Icons.insert_drive_file_outlined,
        RemoteEntryKind.other => Icons.help_outline,
      };

  static Color? _colourFor(RemoteEntry entry, ThemeData theme) =>
      switch (entry.kind) {
        RemoteEntryKind.directory => theme.colorScheme.primary,
        RemoteEntryKind.symlink => theme.colorScheme.primary,
        _ => theme.colorScheme.onSurfaceVariant,
      };
}

class _FailureBanner extends StatelessWidget {
  const _FailureBanner({required this.failure});

  final SftpFailure failure;

  @override
  Widget build(BuildContext context) {
    final denied = failure.isPermissionDenied;
    final theme = Theme.of(context);
    final color = denied
        ? theme.colorScheme.surfaceContainerHigh
        : theme.colorScheme.error.withValues(alpha: 0.15);

    return Material(
      color: color,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              denied ? Icons.lock_outline : Icons.error_outline,
              size: 20,
              color: denied ? null : theme.colorScheme.error,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                failure.message,
                style: const TextStyle(fontSize: 13, height: 1.35),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyDirectory extends StatelessWidget {
  const _EmptyDirectory({
    required this.hiddenCount,
    required this.showHidden,
    required this.onShowHidden,
  });

  final int hiddenCount;
  final bool showHidden;
  final VoidCallback onShowHidden;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onlyHidden = !showHidden && hiddenCount > 0;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              onlyHidden ? Icons.visibility_off_outlined : Icons.folder_open,
              size: 56,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 16),
            Text(
              onlyHidden
                  ? 'Only hidden files here'
                  : 'This folder is empty',
              style: theme.textTheme.titleMedium,
            ),
            if (onlyHidden) ...[
              const SizedBox(height: 12),
              TextButton(
                onPressed: onShowHidden,
                child: Text('Show $hiddenCount hidden item'
                    '${hiddenCount == 1 ? '' : 's'}'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// `14:32` today, `26 Jul 14:32` this year, `26 Jul 2024` before that — the
/// same progressive-detail rule `ls -l` uses, and for the same reason: the
/// year is noise until it is not.
String _formatTime(DateTime? time) {
  if (time == null) return '—';
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final now = DateTime.now();
  final hh = time.hour.toString().padLeft(2, '0');
  final mm = time.minute.toString().padLeft(2, '0');

  if (time.year == now.year && time.month == now.month && time.day == now.day) {
    return '$hh:$mm';
  }
  if (time.year == now.year) {
    return '${time.day} ${months[time.month - 1]} $hh:$mm';
  }
  return '${time.day} ${months[time.month - 1]} ${time.year}';
}
