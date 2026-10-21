import 'dart:async';

import 'package:flutter/material.dart';

import '../services/remote_file_ops.dart';
import '../services/remote_path.dart';
import '../services/sftp_service.dart';
import '../theme.dart';

/// Null when [name] is free in the folder, or why it is not.
typedef NameCheck = Future<String?> Function(String name);

const TextStyle _mono = TextStyle(
  fontFamily: AppTheme.monoFontFamily,
  fontFamilyFallback: AppTheme.monoFontFamilyFallback,
  fontSize: 13,
);

/// Asks [check] about [name], turning a refusal from the server itself into
/// one more reason, so a dialog never throws.
Future<String?> _ask(NameCheck check, String name) async {
  try {
    return await check(name);
  } on SftpFailure catch (e) {
    return e.message;
  }
}

/// What to call the archive, and which kind to make.
class CompressChoice {
  const CompressChoice({required this.name, required this.format});

  final String name;
  final ArchiveFormat format;
}

/// Names the archive a Compress makes: the formats the server can make, and
/// a name with the right ending kept on it.
class CompressDialog extends StatefulWidget {
  const CompressDialog({
    super.key,
    required this.itemNames,
    required this.suggestedStem,
    required this.formats,
    required this.check,
  });

  final List<String> itemNames;
  final String suggestedStem;
  final List<ArchiveFormat> formats;
  final NameCheck check;

  @override
  State<CompressDialog> createState() => _CompressDialogState();
}

class _CompressDialogState extends State<CompressDialog> {
  late final TextEditingController _stem =
      TextEditingController(text: widget.suggestedStem);
  late ArchiveFormat _format = widget.formats.first;
  String? _error;
  bool _checking = false;

  String get _name => '${_stem.text.trim()}${_format.extension}';

  @override
  void dispose() {
    _stem.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_checking) return;
    final name = _name;
    final problem = _stem.text.trim().isEmpty
        ? 'Enter a name.'
        : RemotePath.nameProblem(name);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _checking = true;
      _error = null;
    });
    final refusal = await _ask(widget.check, name);
    if (!mounted) return;
    if (refusal != null) {
      setState(() {
        _checking = false;
        _error = refusal;
      });
      return;
    }
    Navigator.of(context).pop(CompressChoice(name: name, format: _format));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = widget.itemNames.length;
    return AlertDialog(
      title: Text(count == 1 ? 'Compress' : 'Compress $count items'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final name in widget.itemNames.take(3))
              Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: _mono),
            if (count > 3)
              Text(
                'and ${count - 3} more',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            const SizedBox(height: 16),
            if (widget.formats.length > 1)
              SegmentedButton<ArchiveFormat>(
                segments: [
                  for (final format in widget.formats)
                    ButtonSegment(value: format, label: Text(format.label)),
                ],
                selected: {_format},
                showSelectedIcon: false,
                onSelectionChanged: (picked) => setState(() {
                  _format = picked.single;
                  _error = null;
                }),
              ),
            const SizedBox(height: 12),
            TextField(
              controller: _stem,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'Archive name',
                suffixText: _format.extension,
                errorText: _error,
                errorMaxLines: 4,
              ),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              onSubmitted: (_) => unawaited(_submit()),
            ),
            const SizedBox(height: 8),
            Text(
              'Made on the server, next to what it packs. It carries on if '
              'this app is closed.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _checking ? null : () => unawaited(_submit()),
          child: const Text('Compress'),
        ),
      ],
    );
  }
}

/// Where an Extract goes, and what it does about a folder already there.
class ExtractChoice {
  const ExtractChoice({required this.folder, required this.mode});

  final String folder;
  final ExtractMode mode;
}

/// Names the folder an archive is extracted into. A name that is free is a
/// new folder; one that is taken is never written into without the person
/// choosing to — keeping what is there, or replacing it.
class ExtractDialog extends StatefulWidget {
  const ExtractDialog({
    super.key,
    required this.archiveName,
    required this.suggestedFolder,
    required this.folderExists,
  });

  final String archiveName;
  final String suggestedFolder;

  /// Whether [name] is already a folder here (true), free (false), or taken
  /// by something that is not a folder (a reason).
  final Future<Object> Function(String name) folderExists;

  @override
  State<ExtractDialog> createState() => _ExtractDialogState();
}

class _ExtractDialogState extends State<ExtractDialog> {
  late final TextEditingController _folder =
      TextEditingController(text: widget.suggestedFolder);
  String? _error;
  bool _checking = false;

  /// Set once the name turned out to be a folder that is already there.
  bool _exists = false;
  ExtractMode _merge = ExtractMode.keepExisting;

  @override
  void dispose() {
    _folder.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_checking) return;
    final name = _folder.text.trim();
    final problem = RemotePath.nameProblem(name);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    if (_exists) {
      Navigator.of(context).pop(ExtractChoice(folder: name, mode: _merge));
      return;
    }
    setState(() {
      _checking = true;
      _error = null;
    });
    Object answer;
    try {
      answer = await widget.folderExists(name);
    } on SftpFailure catch (e) {
      answer = e.message;
    }
    if (!mounted) return;
    setState(() => _checking = false);
    if (answer is String) {
      setState(() => _error = answer as String);
    } else if (answer == true) {
      setState(() => _exists = true);
    } else {
      Navigator.of(context)
          .pop(ExtractChoice(folder: name, mode: ExtractMode.newFolder));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Extract'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.archiveName,
                maxLines: 2, overflow: TextOverflow.ellipsis, style: _mono),
            const SizedBox(height: 12),
            TextField(
              controller: _folder,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'Into the folder',
                errorText: _error,
                errorMaxLines: 4,
              ),
              onChanged: (_) => setState(() {
                _error = null;
                _exists = false;
              }),
              onSubmitted: (_) => unawaited(_submit()),
            ),
            if (_exists) ...[
              const SizedBox(height: 12),
              Text(
                'That folder is already here. Extract into it anyway?',
                style: theme.textTheme.bodyMedium,
              ),
              RadioGroup<ExtractMode>(
                groupValue: _merge,
                onChanged: (mode) {
                  if (mode != null) setState(() => _merge = mode);
                },
                child: const Column(
                  children: [
                    RadioListTile<ExtractMode>(
                      value: ExtractMode.keepExisting,
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text('Keep the files already there'),
                    ),
                    RadioListTile<ExtractMode>(
                      value: ExtractMode.replaceExisting,
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text('Replace them with the archive\'s'),
                    ),
                  ],
                ),
              ),
            ] else ...[
              const SizedBox(height: 8),
              Text(
                'A new folder beside the archive. Entries that would land '
                'outside it are refused.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _checking ? null : () => unawaited(_submit()),
          child: Text(_exists ? 'Extract into it' : 'Extract'),
        ),
      ],
    );
  }
}

/// The owner and group to give, and whether to go all the way down.
class OwnerChoice {
  const OwnerChoice({
    required this.owner,
    required this.group,
    required this.recursive,
  });

  final String owner;
  final String group;
  final bool recursive;
}

/// `chown`, as a form: owner, group, and — for a folder — everything in it.
class ChangeOwnerDialog extends StatefulWidget {
  const ChangeOwnerDialog({
    super.key,
    required this.itemNames,
    required this.anyFolder,
    this.currentOwner,
    this.currentGroup,
  });

  final List<String> itemNames;
  final bool anyFolder;
  final String? currentOwner;
  final String? currentGroup;

  @override
  State<ChangeOwnerDialog> createState() => _ChangeOwnerDialogState();
}

class _ChangeOwnerDialogState extends State<ChangeOwnerDialog> {
  late final TextEditingController _owner =
      TextEditingController(text: widget.currentOwner ?? '');
  late final TextEditingController _group =
      TextEditingController(text: widget.currentGroup ?? '');
  bool _recursive = false;
  String? _ownerError;
  String? _groupError;

  @override
  void dispose() {
    _owner.dispose();
    _group.dispose();
    super.dispose();
  }

  void _submit() {
    final ownerError = RemoteFileCommands.ownerProblem(_owner.text);
    final groupError = RemoteFileCommands.ownerProblem(_group.text);
    final blank = _owner.text.trim().isEmpty && _group.text.trim().isEmpty;
    setState(() {
      _ownerError = ownerError ?? (blank ? 'Enter an owner or a group.' : null);
      _groupError = groupError;
    });
    if (_ownerError != null || _groupError != null) return;
    Navigator.of(context).pop(OwnerChoice(
      owner: _owner.text.trim(),
      group: _group.text.trim(),
      recursive: widget.anyFolder && _recursive,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = widget.itemNames.length;
    final now = widget.currentOwner == null
        ? null
        : '${widget.currentOwner}:${widget.currentGroup ?? '?'}';
    return AlertDialog(
      title: const Text('Change owner'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final name in widget.itemNames.take(3))
              Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: _mono),
            if (count > 3)
              Text('and ${count - 3} more', style: theme.textTheme.bodySmall),
            if (now != null) ...[
              const SizedBox(height: 4),
              Text('Now $now', style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _owner,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'Owner',
                hintText: 'user name or number',
                errorText: _ownerError,
                errorMaxLines: 3,
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _group,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'Group',
                hintText: 'leave blank to keep it',
                errorText: _groupError,
                errorMaxLines: 3,
              ),
              onSubmitted: (_) => _submit(),
            ),
            if (widget.anyFolder)
              CheckboxListTile(
                value: _recursive,
                onChanged: (on) => setState(() => _recursive = on ?? false),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Everything inside too'),
              ),
            const SizedBox(height: 4),
            Text(
              'Giving a file to another user usually needs root; the server '
              'says so if it refuses. Links change themselves, never what '
              'they point to.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Change')),
      ],
    );
  }
}

/// One server-side operation the browser is following.
class ServerOpEntry {
  const ServerOpEntry({required this.label, required this.onStop});

  final String label;
  final VoidCallback onStop;
}

/// A line per operation running on the server, with a way to stop it.
class ServerOpsStrip extends StatelessWidget {
  const ServerOpsStrip({super.key, required this.ops});

  final List<ServerOpEntry> ops;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.5),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final op in ops)
            SizedBox(
              height: 40,
              child: Row(
                children: [
                  const SizedBox(width: 14),
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      op.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  TextButton(onPressed: op.onStop, child: const Text('Stop')),
                  const SizedBox(width: 4),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// A sentence for how a server-side operation ended, in the user's terms.
String describeServerOp(ServerOpOutcome outcome, String what) {
  switch (outcome.state) {
    case ServerOpState.succeeded:
      return '$what: done.';
    case ServerOpState.cancelled:
      return '$what: stopped.';
    case ServerOpState.lost:
      return '$what: ${outcome.message ?? 'lost track of it.'}';
    case ServerOpState.failed:
      break;
  }
  final log = outcome.log.trim();
  final lastLine = log.isEmpty ? '' : log.split('\n').last.trim();
  final lower = log.toLowerCase();
  if (outcome.exitCode == RemoteOpExit.exists ||
      outcome.exitCode == RemoteOpExit.unsafeArchive ||
      outcome.exitCode == RemoteOpExit.unreadableArchive) {
    return '$what: ${lastLine.isEmpty ? 'refused.' : lastLine}';
  }
  if (lower.contains('permission denied') ||
      lower.contains('operation not permitted')) {
    return '$what: the server refused — this needs permissions this account '
        'does not have.${lastLine.isEmpty ? '' : ' ($lastLine)'}';
  }
  if (outcome.message != null) return '$what: ${outcome.message}';
  final code = outcome.exitCode == null ? '' : ' (exit ${outcome.exitCode})';
  return '$what failed$code${lastLine.isEmpty ? '.' : ': $lastLine'}';
}
