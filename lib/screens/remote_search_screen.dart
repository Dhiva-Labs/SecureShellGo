import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../services/remote_file_ops.dart';
import '../services/remote_path.dart';
import '../services/ssh_service.dart';
import '../theme.dart';

/// Searches the server from one folder down: `find` by name, and — where
/// the server has `grep` — by what the files contain. Hits stream in as
/// they are found; tapping one closes this screen with it, for the browser
/// to open.
class RemoteSearchScreen extends StatefulWidget {
  const RemoteSearchScreen({
    super.key,
    required this.transport,
    required this.directory,
    required this.toolkit,
    this.limit = 1000,
  });

  /// Asked for at each search, so a session that reconnected is used.
  final SessionTransport Function() transport;
  final String directory;
  final RemoteToolkit toolkit;

  /// Hits kept before the search is stopped.
  final int limit;

  @override
  State<RemoteSearchScreen> createState() => _RemoteSearchScreenState();
}

class _RemoteSearchScreenState extends State<RemoteSearchScreen> {
  final _name = TextEditingController();
  final _contains = TextEditingController();
  bool _matchCase = false;

  RemoteSearch? _search;
  final List<RemoteSearchHit> _hits = [];
  RemoteSearchEnd? _end;
  String? _error;
  var _searched = false;

  bool get _running => _search != null && _end == null;

  @override
  void dispose() {
    unawaited(_search?.stop());
    _name.dispose();
    _contains.dispose();
    super.dispose();
  }

  bool get _canSearch =>
      _name.text.trim().isNotEmpty || _contains.text.trim().isNotEmpty;

  Future<void> _start() async {
    if (!_canSearch) return;
    await _search?.stop();
    final contains = widget.toolkit.canSearchContents ? _contains.text : '';
    setState(() {
      _hits.clear();
      _end = null;
      _error = null;
      _searched = true;
      _search = null;
    });
    final command = RemoteFileCommands.search(
      directory: widget.directory,
      pattern: _name.text,
      contains: contains.isEmpty ? null : contains,
      matchCase: _matchCase,
      tools: widget.toolkit,
    );
    final RemoteSearch search;
    try {
      search = await RemoteSearch.start(
        widget.transport(),
        command,
        limit: widget.limit,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e is SshConnectionException
          ? e.message
          : context.l10n.filesSearchCouldNotStart('$e'));
      return;
    }
    if (!mounted) {
      unawaited(search.stop());
      return;
    }
    setState(() => _search = search);
    search.hits.listen((batch) {
      if (mounted && identical(_search, search)) {
        setState(() => _hits.addAll(batch));
      }
    });
    final end = await search.done;
    if (mounted && identical(_search, search)) setState(() => _end = end);
  }

  String _status() {
    final error = _error;
    if (error != null) return error;
    final l10n = context.l10n;
    final end = _end;
    final count = _hits.length;
    if (_running) return l10n.filesSearchSearching(count);
    if (end == null) return '';
    final parts = <String>[
      if (end.limited)
        l10n.filesSearchLimited(widget.limit)
      else if (end.stopped)
        l10n.filesSearchStopped(count)
      else if (count == 0)
        l10n.filesSearchNothingFound
      else
        l10n.filesSearchFound(count),
      if (end.unreadableFolders > 0)
        l10n.filesSearchUnreadable(end.unreadableFolders),
    ];
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final contents = widget.toolkit.canSearchContents;
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.filesSearchTitle),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(24),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                context.l10n.filesSearchIn(widget.directory),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: AppTheme.monoFontFamily,
                  fontFamilyFallback: AppTheme.monoFontFamilyFallback,
                ),
              ),
            ),
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Column(
                children: [
                  TextField(
                    key: const ValueKey('searchName'),
                    controller: _name,
                    autofocus: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      isDense: true,
                      prefixIcon: const Icon(Icons.search, size: 20),
                      labelText: context.l10n.filesSearchNameLabel,
                      hintText: context.l10n.filesSearchNameHint,
                    ),
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => unawaited(_start()),
                  ),
                  if (contents) ...[
                    const SizedBox(height: 8),
                    TextField(
                      key: const ValueKey('searchContains'),
                      controller: _contains,
                      autocorrect: false,
                      enableSuggestions: false,
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        isDense: true,
                        prefixIcon:
                            const Icon(Icons.text_snippet_outlined, size: 20),
                        labelText: context.l10n.filesSearchContainsLabel,
                      ),
                      onChanged: (_) => setState(() {}),
                      onSubmitted: (_) => unawaited(_start()),
                    ),
                  ],
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: CheckboxListTile(
                          value: _matchCase,
                          onChanged: (on) =>
                              setState(() => _matchCase = on ?? false),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: Text(context.l10n.filesSearchMatchCase),
                        ),
                      ),
                      // A width of their own: the app's buttons stretch to
                      // whatever they are given, and a Row gives them all of
                      // it.
                      if (_running)
                        OutlinedButton.icon(
                          onPressed: () => unawaited(_search?.stop()),
                          icon: const Icon(Icons.stop, size: 18),
                          label: Text(context.l10n.filesSearchStop),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(0, 44),
                          ),
                        )
                      else
                        FilledButton.icon(
                          onPressed:
                              _canSearch ? () => unawaited(_start()) : null,
                          icon: const Icon(Icons.search, size: 18),
                          label: Text(context.l10n.filesSearchButton),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(0, 44),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            if (_running) const LinearProgressIndicator(minHeight: 2),
            if (_searched)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    _status(),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: _error != null
                          ? theme.colorScheme.error
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                itemCount: _hits.length,
                itemBuilder: (context, index) {
                  final hit = _hits[index];
                  final relative = _relativeFolder(hit.folder);
                  return ListTile(
                    dense: true,
                    leading: Icon(
                      hit.isDirectory
                          ? Icons.folder
                          : hit.isLink
                              ? Icons.link
                              : Icons.insert_drive_file_outlined,
                      color: hit.isDirectory ? theme.colorScheme.primary : null,
                    ),
                    title: Text(
                      hit.name.replaceAll('\n', '↵'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      relative,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: hit.size == null || hit.isDirectory || hit.isLink
                        ? null
                        : Text(
                            RemotePath.formatBytes(hit.size),
                            style: theme.textTheme.bodySmall,
                          ),
                    onTap: () => Navigator.of(context).pop(hit),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// `./logs/app` for a hit below the folder searched from, the full path
  /// otherwise.
  String _relativeFolder(String folder) {
    final base = widget.directory;
    if (folder == base) return '.';
    final prefix = base.endsWith('/') ? base : '$base/';
    return folder.startsWith(prefix)
        ? './${folder.substring(prefix.length)}'
        : folder;
  }
}
