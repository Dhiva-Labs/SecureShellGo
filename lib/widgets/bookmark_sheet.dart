import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../models/path_bookmark.dart';
import '../services/bookmark_store.dart';

/// The bottom sheet listing one host's saved paths. Tapping a row jumps the
/// file browser there; each row also offers rename and remove without
/// leaving the sheet.
///
/// Removing or renaming talks to [store] directly rather than handing the
/// outcome back through a callback per action — the caller (the file
/// browser pane) just reloads its own bookmark list once the sheet closes,
/// which is simpler than keeping two copies of "this host's bookmarks" in
/// sync action by action.
Future<void> showBookmarksSheet(
  BuildContext context, {
  required BookmarkStore store,
  required String hostId,
  required String currentPath,
  required List<PathBookmark> bookmarks,
  required ValueChanged<String> onJump,
}) {
  final theme = Theme.of(context);
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: theme.colorScheme.surfaceContainerHigh,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: _BookmarksSheetBody(
          store: store,
          hostId: hostId,
          currentPath: currentPath,
          initial: bookmarks,
          onJump: onJump,
        ),
      ),
    ),
  );
}

class _BookmarksSheetBody extends StatefulWidget {
  const _BookmarksSheetBody({
    required this.store,
    required this.hostId,
    required this.currentPath,
    required this.initial,
    required this.onJump,
  });

  final BookmarkStore store;
  final String hostId;
  final String currentPath;
  final List<PathBookmark> initial;
  final ValueChanged<String> onJump;

  @override
  State<_BookmarksSheetBody> createState() => _BookmarksSheetBodyState();
}

class _BookmarksSheetBodyState extends State<_BookmarksSheetBody> {
  late List<PathBookmark> _bookmarks = widget.initial;

  Future<void> _reload() async {
    final list = await widget.store.bookmarksForHost(widget.hostId);
    if (mounted) setState(() => _bookmarks = list);
  }

  Future<void> _remove(PathBookmark bookmark) async {
    await widget.store.remove(bookmark.id);
    await _reload();
  }

  Future<void> _rename(PathBookmark bookmark) async {
    final controller = TextEditingController(text: bookmark.label ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.bookmarksRenameTitle),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            hintText: context.l10n.bookmarksRenameHint,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: Text(MaterialLocalizations.of(context).saveButtonLabel),
          ),
        ],
      ),
    );
    if (name == null) return;
    await widget.store.renameLabel(
      bookmark.id,
      name.trim().isEmpty ? null : name.trim(),
    );
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
          child: Row(
            children: [
              Text(
                l10n.bookmarksTitle,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        if (_bookmarks.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Text(l10n.bookmarksEmpty),
          )
        else
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: 12),
              itemCount: _bookmarks.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final bookmark = _bookmarks[index];
                final here = bookmark.path == widget.currentPath;
                final theme = Theme.of(context);
                return ListTile(
                  leading: Icon(Icons.star, color: theme.colorScheme.primary),
                  title: Text(
                    bookmark.displayLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: bookmark.label != null &&
                          bookmark.label!.trim().isNotEmpty
                      ? Text(
                          bookmark.path,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        )
                      : (here
                          ? Text(l10n.bookmarksThisFolder)
                          : null),
                  trailing: PopupMenuButton<String>(
                    tooltip: l10n.bookmarksActionsTooltip,
                    onSelected: (action) {
                      switch (action) {
                        case 'rename':
                          unawaited(_rename(bookmark));
                        case 'remove':
                          unawaited(_remove(bookmark));
                      }
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 'rename',
                        child: Text(context.l10n.bookmarksRename),
                      ),
                      PopupMenuItem(
                        value: 'remove',
                        child: Text(context.l10n.bookmarksRemove),
                      ),
                    ],
                  ),
                  enabled: !here,
                  onTap: here
                      ? null
                      : () {
                          Navigator.of(context).pop();
                          widget.onJump(bookmark.path);
                        },
                );
              },
            ),
          ),
      ],
    );
  }
}
