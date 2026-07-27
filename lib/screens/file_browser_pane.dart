import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/remote_entry.dart';
import '../services/device_storage.dart';
import '../services/download_plan.dart';
import '../services/remote_path.dart';
import '../services/session_controller.dart';
import '../services/sftp_service.dart';
import '../services/transfer_queue.dart';
import '../services/upload_plan.dart';
import '../theme.dart';
import '../widgets/transfer_panel.dart';

/// What to do when a download would land on an existing file name.
enum _CollisionChoice { keepBoth, overwrite, cancel }

/// The remote file browser: the other view on a live session.
///
/// Reuses the session's authenticated connection through
/// [SessionController.sftp], so opening it costs one extra SSH channel and no
/// extra credentials.
class FileBrowserPane extends StatefulWidget {
  const FileBrowserPane({
    super.key,
    required this.session,
    this.initialShowHidden = false,
  });

  final SessionController session;

  /// Seeds the per-session "show hidden files" toggle from Settings. The
  /// toggle itself stays per-session after that — this only sets where it
  /// starts.
  final bool initialShowHidden;

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

  /// Uploads already counted, so each finishing is noticed exactly once.
  final Set<String> _refreshedFor = {};

  /// Set when an upload landed in the directory on screen, cleared by the
  /// refresh it triggers once the queue is quiet.
  bool _uploadLanded = false;

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
    unawaited(_openHome());
  }

  @override
  void dispose() {
    _sessionChanges?.cancel();
    _transferChanges?.cancel();
    super.dispose();
  }

  /// Shows an upload in the listing the moment it lands.
  ///
  /// The file went into the directory on screen, so leaving the user looking
  /// at a listing that does not contain it — until they think to pull to
  /// refresh — makes a successful upload look like a failed one.
  void _handleTransfers(List<TransferTask> tasks) {
    for (final task in tasks) {
      if (task.direction != TransferDirection.upload) continue;
      if (task.status != TransferStatus.completed) continue;
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
      final existing = await _existingNames(sftp, directory, files);
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

  /// The names already in [directory], for the collision plan.
  ///
  /// One listing rather than a `stat` per file, because "keep both" needs to
  /// know what `name (1).ext` would hit as well. A directory that will not
  /// list — writable but not readable is a real Unix permission — falls back
  /// to probing exactly the names about to be created.
  Future<Set<String>> _existingNames(
    RemoteFileSystem sftp,
    String directory,
    List<PickedLocalFile> files,
  ) async {
    try {
      final entries = await sftp.list(directory);
      return entries.map((e) => e.name).toSet();
    } catch (_) {
      final names = <String>{};
      for (final file in files) {
        if (await sftp.exists(RemotePath.join(directory, file.name))) {
          names.add(file.name);
        }
      }
      return names;
    }
  }

  Future<UploadCollisionResponse?> _askAboutRemoteCollision(
    String fileName,
    String directory, {
    required bool offerApplyToAll,
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
                '"$fileName" already exists in $directory.',
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

  /// Takes the files a share handed to this session and uploads them here.
  Future<void> _uploadShared(PendingUpload pending) async {
    widget.session.clearPendingUpload();
    await _uploadFiles(pending.files);
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

  /// Puts the remote path on the clipboard, so it can be pasted straight into
  /// the terminal pane next door.
  Future<void> _copyPath(RemoteEntry entry) async {
    await Clipboard.setData(ClipboardData(text: entry.path));
    if (mounted) _snack('Copied ${entry.path}');
  }

  void _snack(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? AppTheme.danger : null,
      ),
    );
  }

  Future<void> _showEntryActions(RemoteEntry entry) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.surface,
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
                leading: const Icon(Icons.download),
                title: const Text('Download'),
                subtitle: const Text('Saves to this device\'s Downloads'),
                onTap: () {
                  Navigator.of(context).pop();
                  unawaited(_download([entry]));
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
            )
          else
            _BrowserActions(
              showHidden: _showHidden,
              onToggleHidden: () => setState(() => _showHidden = !_showHidden),
              onRefresh: () => unawaited(_refresh()),
              onUpload: () => unawaited(_pickAndUpload()),
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
                itemBuilder: (context, index) {
                  final entry = visible[index];
                  return _EntryTile(
                    entry: entry,
                    selected: _selected.contains(entry.path),
                    selecting: _selecting,
                    onTap: () {
                      if (_selecting) {
                        _toggleSelection(entry);
                      } else if (entry.isNavigable) {
                        unawaited(_navigate(entry.path));
                      } else if (entry.isDownloadable) {
                        unawaited(_download([entry]));
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
                },
              ),
            ),
        ],
      ),
    );
  }
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
    return Material(
      color: AppTheme.accent.withValues(alpha: 0.14),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
        child: Row(
          children: [
            const Icon(Icons.ios_share, size: 18, color: AppTheme.accent),
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
  });

  final String path;
  final void Function(String path) onNavigate;
  final VoidCallback onUp;

  @override
  Widget build(BuildContext context) {
    final crumbs = RemotePath.breadcrumbs(path);
    final theme = Theme.of(context);

    return Material(
      color: AppTheme.surface,
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
  });

  final bool showHidden;
  final VoidCallback onToggleHidden;
  final VoidCallback onRefresh;
  final VoidCallback onUpload;

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
  });

  final int count;
  final VoidCallback onSelectAll;
  final VoidCallback onClear;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.accent.withValues(alpha: 0.12),
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

    return ListTile(
      // Not dense: fat-finger comfort for a list of remote files matters
      // more here than screen density.
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      selected: selected,
      selectedTileColor: AppTheme.accent.withValues(alpha: 0.1),
      leading: selecting && entry.isDownloadable
          ? Icon(
              selected ? Icons.check_circle : Icons.circle_outlined,
              color: selected ? AppTheme.accent : theme.colorScheme.onSurfaceVariant,
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
        RemoteEntryKind.directory => AppTheme.accent,
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
    final color = denied ? AppTheme.surface : AppTheme.danger.withValues(alpha: 0.15);

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
              color: denied ? null : AppTheme.danger,
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
