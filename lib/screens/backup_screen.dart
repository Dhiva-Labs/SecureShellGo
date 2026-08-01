import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/backup_crypto.dart';
import '../services/backup_passphrase.dart';
import '../services/backup_payload.dart';
import '../services/backup_service.dart';
import '../services/device_storage.dart';

/// Export the app's configuration to an encrypted file, and import one back.
///
/// Reached from Settings. The two halves are deliberately on one screen: a
/// user who is here at all is thinking about "my configuration as a file",
/// and splitting that across two routes would mostly serve to hide the import
/// side from the people most likely to need it.
class BackupScreen extends StatefulWidget {
  const BackupScreen({
    super.key,
    required this.service,
    this.deviceStorage,
  });

  final BackupService service;

  /// Overridable so a test does not need the platform channel, same
  /// convention as the stores' injectable [File].
  final DeviceStorage? deviceStorage;

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  late final DeviceStorage _storage =
      widget.deviceStorage ?? createDefaultDeviceStorage();

  /// Set while a KDF is running. Argon2id takes about a second, and both
  /// buttons have to be inert for that long or a double tap turns into two
  /// exports.
  bool _busy = false;
  String? _status;

  Future<void> _export() async {
    final choice = await showDialog<_ExportChoice>(
      context: context,
      builder: (_) => const _ExportDialog(),
    );
    if (choice == null || !mounted) return;

    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final bytes = await widget.service.export(
        passphrase: choice.passphrase,
        includeCredentials: choice.includeCredentials,
      );
      final name = _fileName();
      final writer = await _storage.beginDownload(
        name,
        mimeType: 'application/octet-stream',
      );
      try {
        await writer.add(bytes);
        final saved = await writer.finish();
        if (!mounted) return;
        setState(() => _status = 'Saved ${saved.displayName} to Downloads.');
      } catch (e) {
        await writer.abort();
        rethrow;
      }
    } on DeviceStorageException catch (e) {
      if (!mounted) return;
      setState(() => _status = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Could not write the backup: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _fileName() {
    final now = DateTime.now();
    final month = now.month.toString().padLeft(2, '0');
    final day = now.day.toString().padLeft(2, '0');
    return 'secureshellgo-${now.year}-$month-$day.'
        '${BackupService.fileExtension}';
  }

  Future<void> _import() async {
    final PickedLocalFile? picked;
    try {
      picked = await _storage.pickFile();
    } on DeviceStorageException catch (e) {
      if (!mounted) return;
      setState(() => _status = e.message);
      return;
    }
    if (picked == null || !mounted) return;

    final Uint8List bytes;
    try {
      bytes = await File(picked.path).readAsBytes();
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Could not read that file.');
      return;
    }
    if (!mounted) return;

    final passphrase = await showDialog<String>(
      context: context,
      builder: (_) => _ImportPassphraseDialog(fileName: picked!.name),
    );
    if (passphrase == null || !mounted) return;

    setState(() {
      _busy = true;
      _status = null;
    });
    final BackupPayload payload;
    try {
      payload = await widget.service.readBackup(
        file: bytes,
        passphrase: passphrase,
      );
    } on BackupException catch (e) {
      // The one place the two failure kinds are told apart for the user: a
      // format problem is actionable ("update the app"), a tag failure
      // deliberately is not ("wrong passphrase, or corrupt").
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = e.message;
      });
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = 'Could not read that backup.';
      });
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);

    final mode = await showDialog<ImportMode>(
      context: context,
      builder: (_) => _ImportPreviewDialog(contents: payload.contents),
    );
    if (mode == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final result = await widget.service.apply(payload: payload, mode: mode);
      if (!mounted) return;
      setState(() => _status = _describe(result));
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'The import did not finish: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _describe(ImportResult result) {
    final parts = <String>[
      '${result.hosts} host${result.hosts == 1 ? '' : 's'}',
      '${result.snippets} snippet${result.snippets == 1 ? '' : 's'}',
      '${result.tunnels} tunnel${result.tunnels == 1 ? '' : 's'}',
      '${result.bookmarks} bookmark${result.bookmarks == 1 ? '' : 's'}',
    ];
    final buffer = StringBuffer('Imported. You now have ')
      ..write(parts.join(', '))
      ..write('.');
    if (result.hostsNeedingCredentials > 0) {
      buffer.write(
        ' ${result.hostsNeedingCredentials} host'
        '${result.hostsNeedingCredentials == 1 ? '' : 's'} will ask for a '
        'password or key on first connect.',
      );
    }
    return buffer.toString();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Backup')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              if (_busy) const LinearProgressIndicator(minHeight: 2),
              const _SectionHeader('Export'),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  'Writes your hosts, groups, snippets, tunnels, bookmarks '
                  'and settings to a single encrypted file, protected by a '
                  'passphrase you choose.',
                  style: TextStyle(height: 1.35),
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: _NoteCard(
                  icon: Icons.vpn_key_outlined,
                  // Called out here rather than buried in a release note: a
                  // user restoring on a new device will see host-key warnings
                  // and should know now that it is by design.
                  text: 'Known hosts are not included. Host-key trust is a '
                      'decision you make per device, so a restored install '
                      'verifies each server again on first connect.',
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: FilledButton.icon(
                  onPressed: _busy ? null : () => unawaited(_export()),
                  icon: const Icon(Icons.upload_file_outlined),
                  label: const Text('Export to a file'),
                ),
              ),
              const Divider(height: 40),
              const _SectionHeader('Import'),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(
                  'Reads a .ssgbackup file. You will see what is inside it '
                  'and choose whether to merge or replace before anything '
                  'changes.',
                  style: TextStyle(height: 1.35),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : () => unawaited(_import()),
                  icon: const Icon(Icons.download_outlined),
                  label: const Text('Import from a file'),
                ),
              ),
              if (_status != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
                  child: Text(
                    _status!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.35,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What the export dialog collected.
class _ExportChoice {
  const _ExportChoice({
    required this.passphrase,
    required this.includeCredentials,
  });

  final String passphrase;
  final bool includeCredentials;
}

class _ExportDialog extends StatefulWidget {
  const _ExportDialog();

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  final _passphrase = TextEditingController();
  final _confirm = TextEditingController();
  bool _includeCredentials = false;
  bool _obscure = true;

  @override
  void dispose() {
    _passphrase.dispose();
    _confirm.dispose();
    super.dispose();
  }

  bool get _matches =>
      _passphrase.text.isNotEmpty && _passphrase.text == _confirm.text;

  bool get _canExport =>
      BackupPassphrase.isAcceptable(_passphrase.text) && _matches;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strength = BackupPassphrase.strengthOf(_passphrase.text);
    return AlertDialog(
      title: const Text('Export backup'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _passphrase,
              obscureText: _obscure,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'Passphrase',
                helperText: BackupPassphrase.hintFor(_passphrase.text),
                helperMaxLines: 2,
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscure ? Icons.visibility_off : Icons.visibility,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                  tooltip: _obscure ? 'Show' : 'Hide',
                ),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Text(
                  'Strength: ',
                  style: theme.textTheme.bodySmall,
                ),
                Text(
                  strength.label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: switch (strength) {
                      PassphraseStrength.tooShort ||
                      PassphraseStrength.weak =>
                        theme.colorScheme.error,
                      // Tertiary/primary rather than a literal amber/green:
                      // this meter needs three visually distinct steps up
                      // from `error`, not specific hues, so it stays
                      // coherent under every UI style's own palette.
                      PassphraseStrength.fair => theme.colorScheme.tertiary,
                      PassphraseStrength.strong => theme.colorScheme.primary,
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _confirm,
              obscureText: _obscure,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'Confirm passphrase',
                errorText: _confirm.text.isNotEmpty && !_matches
                    ? 'These do not match.'
                    : null,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'There is no way to recover this file without the passphrase. '
              'It is not stored anywhere.',
              style: TextStyle(height: 1.3, fontSize: 12),
            ),
            const SizedBox(height: 12),
            CheckboxListTile(
              value: _includeCredentials,
              onChanged: (v) =>
                  setState(() => _includeCredentials = v ?? false),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Include saved passwords and keys'),
              subtitle: const Text(
                'Off by default. With this on, the file contains your server '
                'passwords and private keys, and its safety is only as good '
                'as the passphrase above.',
                style: TextStyle(height: 1.3),
              ),
            ),
            if (_includeCredentials)
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer.withValues(
                    alpha: 0.35,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Treat this file like the passwords themselves: anyone who '
                  'gets both it and the passphrase gets your servers.',
                  style: theme.textTheme.bodySmall?.copyWith(height: 1.3),
                ),
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
          onPressed: _canExport
              ? () => Navigator.of(context).pop(
                    _ExportChoice(
                      passphrase: _passphrase.text,
                      includeCredentials: _includeCredentials,
                    ),
                  )
              : null,
          child: const Text('Export'),
        ),
      ],
    );
  }
}

class _ImportPassphraseDialog extends StatefulWidget {
  const _ImportPassphraseDialog({required this.fileName});

  final String fileName;

  @override
  State<_ImportPassphraseDialog> createState() =>
      _ImportPassphraseDialogState();
}

class _ImportPassphraseDialogState extends State<_ImportPassphraseDialog> {
  final _passphrase = TextEditingController();

  @override
  void dispose() {
    _passphrase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Open backup'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.fileName, style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 14),
          TextField(
            controller: _passphrase,
            obscureText: true,
            autofocus: true,
            onSubmitted: (v) => Navigator.of(context).pop(v),
            decoration: const InputDecoration(labelText: 'Passphrase'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_passphrase.text),
          child: const Text('Open'),
        ),
      ],
    );
  }
}

/// What is inside the file, and the merge/replace choice. Shown *after* a
/// successful decrypt and *before* anything is written.
class _ImportPreviewDialog extends StatelessWidget {
  const _ImportPreviewDialog({required this.contents});

  final BackupContents contents;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('This backup contains'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _CountRow('Hosts', contents.hosts),
            _CountRow('Groups', contents.groups),
            _CountRow('Snippets', contents.snippets),
            _CountRow('Tunnels', contents.tunnels),
            _CountRow('Bookmarks', contents.bookmarks),
            const Divider(height: 20),
            Text(
              contents.includesCredentials
                  ? 'Includes ${contents.credentials} saved '
                      'password${contents.credentials == 1 ? '' : 's'} or key'
                      '${contents.credentials == 1 ? '' : 's'}.'
                  : 'No saved passwords or keys. '
                      '${contents.hostsNeedingCredentials} host'
                      '${contents.hostsNeedingCredentials == 1 ? '' : 's'} '
                      'will ask on first connect.',
              style: theme.textTheme.bodySmall?.copyWith(height: 1.3),
            ),
            const SizedBox(height: 10),
            Text(
              'Settings in the file will replace your current settings in '
              'both modes. Known hosts are never touched.',
              style: theme.textTheme.bodySmall?.copyWith(height: 1.3),
            ),
            if (contents.isEmpty) ...[
              const SizedBox(height: 10),
              Text(
                'This backup is empty. Replacing with it would remove '
                'everything you have.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                  height: 1.3,
                ),
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
        TextButton(
          onPressed: () => Navigator.of(context).pop(ImportMode.replace),
          child: const Text('Replace'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(ImportMode.merge),
          child: const Text('Merge'),
        ),
      ],
    );
  }
}

class _CountRow extends StatelessWidget {
  const _CountRow(this.label, this.count);

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Text(label),
          const Spacer(),
          Text('$count', style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _NoteCard extends StatelessWidget {
  const _NoteCard({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.4,
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}
