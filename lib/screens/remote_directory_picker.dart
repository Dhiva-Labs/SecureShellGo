import 'dart:async';

import 'package:flutter/material.dart';

import '../models/remote_entry.dart';
import '../services/remote_path.dart';
import '../services/session_manager.dart';
import '../services/sftp_service.dart';
import '../theme.dart';

/// Browses [session]'s server for a directory to put files in.
///
/// Returns the chosen absolute path, or null if the user backed out. Pushed as
/// an ordinary route rather than shown as a sheet because choosing a
/// destination is real navigation — several levels of it on a strange machine
/// — and a half-height sheet with a file list in it is a worse version of the
/// browser the user already knows.
Future<String?> pickRemoteDirectory(
  BuildContext context, {
  required ManagedSession session,
  required String confirmLabel,
  String? subtitle,
}) {
  return Navigator.of(context).push<String>(
    MaterialPageRoute<String>(
      builder: (_) => RemoteDirectoryPicker(
        session: session,
        confirmLabel: confirmLabel,
        subtitle: subtitle,
      ),
    ),
  );
}

/// The destination half of a server-to-server transfer.
class RemoteDirectoryPicker extends StatefulWidget {
  const RemoteDirectoryPicker({
    super.key,
    required this.session,
    required this.confirmLabel,
    this.subtitle,
  });

  final ManagedSession session;

  /// What the confirm button says — "Copy here" or "Move here", so the button
  /// carries the consequence rather than a neutral "Select".
  final String confirmLabel;

  /// What is being sent, for the bar above the listing.
  final String? subtitle;

  @override
  State<RemoteDirectoryPicker> createState() => _RemoteDirectoryPickerState();
}

class _RemoteDirectoryPickerState extends State<RemoteDirectoryPicker> {
  RemoteFileSystem? _sftp;

  String _path = RemotePath.root;
  List<RemoteEntry> _directories = const [];
  bool _loading = true;
  bool _showHidden = false;
  SftpFailure? _failure;

  @override
  void initState() {
    super.initState();
    unawaited(_openHome());
  }

  Future<RemoteFileSystem> _client() async {
    final existing = _sftp;
    if (existing != null) return existing;
    // The destination session's own SFTP channel, opened once and shared with
    // its file browser — picking a directory here costs no extra channel and
    // no extra credentials.
    final service = await widget.session.controller.sftp();
    _sftp = service;
    return service;
  }

  Future<void> _openHome() async {
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
          'Could not open a file session on '
          '${widget.session.host.displayName}.',
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
        _directories =
            entries.where((e) => e.isNavigable).toList(growable: false);
        _loading = false;
        _failure = null;
      });
    } on SftpFailure catch (e) {
      if (!mounted) return;
      // Staying put on a failed navigation: an unreadable directory should
      // leave the user where they were, with an explanation.
      setState(() {
        _loading = false;
        _failure = e;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failure = SftpFailure('Could not open $path.', details: e.toString());
      });
    }
  }

  List<RemoteEntry> get _visible => _showHidden
      ? _directories
      : _directories.where((e) => !e.isHidden).toList(growable: false);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final failure = _failure;
    final visible = _visible;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.session.host.displayName,
              style: const TextStyle(fontSize: 16),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              widget.subtitle ?? 'Choose a folder',
              style: TextStyle(
                fontSize: 11.5,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: _showHidden ? 'Hidden shown' : 'Show hidden folders',
            icon: Icon(
              _showHidden ? Icons.visibility : Icons.visibility_off_outlined,
              size: 20,
            ),
            onPressed: () => setState(() => _showHidden = !_showHidden),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _PickerPathBar(
              path: _path,
              onUp: () {
                final parent = RemotePath.parent(_path);
                if (parent != _path) unawaited(_navigate(parent));
              },
              onHome: () => unawaited(_openHome()),
            ),
            if (failure != null)
              Material(
                color: failure.isPermissionDenied
                    ? AppTheme.surface
                    : AppTheme.danger.withValues(alpha: 0.15),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                  child: Row(
                    children: [
                      Icon(
                        failure.isPermissionDenied
                            ? Icons.lock_outline
                            : Icons.error_outline,
                        size: 18,
                        color:
                            failure.isPermissionDenied ? null : AppTheme.danger,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          failure.message,
                          style: const TextStyle(fontSize: 13, height: 1.3),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            const Divider(height: 1),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : visible.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(32),
                            child: Text(
                              'No folders here. The files still land in this '
                              'one if you choose it.',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        )
                      : ListView.separated(
                          itemCount: visible.length,
                          separatorBuilder: (_, _) =>
                              const Divider(height: 1, indent: 56),
                          itemBuilder: (context, index) {
                            final entry = visible[index];
                            return ListTile(
                              leading: const Icon(
                                Icons.folder,
                                color: AppTheme.accent,
                              ),
                              title: Text(
                                entry.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 14),
                              ),
                              trailing: const Icon(
                                Icons.chevron_right,
                                size: 18,
                              ),
                              onTap: () => unawaited(_navigate(entry.path)),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: AppTheme.monoFontFamily,
                    fontFamilyFallback: AppTheme.monoFontFamilyFallback,
                    fontSize: 12.5,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                // `minimumSize` is not decoration. The app theme gives every
                // FilledButton `Size.fromHeight(48)` — infinite minimum width
                // — so that buttons stacked in a column fill it. Inside a Row
                // that is an infinite width constraint, which fails layout for
                // the whole `bottomNavigationBar` and takes the rest of the
                // screen's body down with it: an app bar over a blank page,
                // no error visible on the device. Every FilledButton this app
                // puts in a Row overrides it (see `_SelectionBar` in
                // `file_browser_pane.dart`, which learned the same lesson).
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 44),
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                ),
                // Disabled while the listing is still coming: confirming a
                // path that has not been shown to exist is how files end up
                // somewhere nobody chose.
                onPressed: _loading
                    ? null
                    : () => Navigator.of(context).pop(_path),
                child: Text(widget.confirmLabel),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PickerPathBar extends StatelessWidget {
  const _PickerPathBar({
    required this.path,
    required this.onUp,
    required this.onHome,
  });

  final String path;
  final VoidCallback onUp;
  final VoidCallback onHome;

  @override
  Widget build(BuildContext context) {
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
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  path,
                  style: const TextStyle(
                    fontFamily: AppTheme.monoFontFamily,
                    fontFamilyFallback: AppTheme.monoFontFamilyFallback,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Home',
            icon: const Icon(Icons.home_outlined, size: 20),
            onPressed: onHome,
          ),
        ],
      ),
    );
  }
}
