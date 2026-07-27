import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/remote_entry.dart';
import '../services/device_storage.dart';
import '../services/remote_path.dart';
import '../services/session_controller.dart';
import '../services/sftp_service.dart';
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

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _showHidden = widget.initialShowHidden;
    unawaited(_openHome());
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

  Future<void> _upload() async {
    try {
      final picked = await widget.session.pickLocalFile();
      if (!mounted || picked == null) return;

      final remotePath = RemotePath.join(_path, picked.name);
      final sftp = await _client();
      if (await sftp.exists(remotePath)) {
        if (!mounted) return;
        final replace = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Replace on the server?'),
            content: Text('"${picked.name}" already exists in $_path.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Replace'),
              ),
            ],
          ),
        );
        if (replace != true) return;
      }
      if (!mounted) return;

      widget.session.queueUpload(picked, _path);
      _snack('Uploading ${picked.name}');
    } on DeviceStorageException catch (e) {
      if (mounted) _snack(e.message, isError: true);
    } on SftpFailure catch (e) {
      if (mounted) _snack(e.message, isError: true);
    }
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

    return Column(
      children: [
        _PathBar(
          path: _path,
          onNavigate: (target) => unawaited(_navigate(target)),
          onUp: _goUp,
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
            onUpload: () => unawaited(_upload()),
          ),
        const Divider(height: 1),
        Expanded(child: _buildBody()),
        TransferSummaryBar(
          queue: widget.session.transfers,
          onTap: () => showTransfersSheet(context, widget.session.transfers),
        ),
      ],
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
            SliverList.separated(
              itemCount: visible.length,
              separatorBuilder: (_, _) => const Divider(height: 1, indent: 56),
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
        ],
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
