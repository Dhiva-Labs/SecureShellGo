import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../services/backup_crypto.dart';
import '../services/backup_passphrase.dart';
import '../services/backup_payload.dart';
import '../services/backup_service.dart';
import '../services/device_storage.dart';
import '../services/diagnostics_log.dart';
import '../theme.dart';

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

  /// The storage's "save as", when it has one. See [DocumentSaver].
  DocumentSaver? get _saver {
    final storage = _storage;
    return storage is DocumentSaver ? storage as DocumentSaver : null;
  }

  /// [chooseLocation] picks between the system's "save as" UI — any folder,
  /// or a cloud provider — and Downloads.
  Future<void> _export({required bool chooseLocation}) async {
    final l10n = context.l10n;
    final choice = await showDialog<_ExportChoice>(
      context: context,
      builder: (_) => _ExportDialog(
        canIncludeKnownHosts: widget.service.knownHosts != null,
      ),
    );
    if (choice == null || !mounted) return;
    DiagnosticsLog.instance.learnSecret(choice.passphrase);

    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final bytes = await widget.service.export(
        passphrase: choice.passphrase,
        includeCredentials: choice.includeCredentials,
        includeKnownHosts: choice.includeKnownHosts,
      );
      final name = _fileName();
      final saver = _saver;
      if (chooseLocation && saver != null) {
        final saved = await saver.saveDocument(
          suggestedName: name,
          bytes: bytes,
          mimeType: 'application/octet-stream',
        );
        if (!mounted) return;
        setState(
          () => _status = saved == null
              ? l10n.backupNotSaved
              : l10n.backupSaved(saved.displayName),
        );
        return;
      }
      final writer = await _storage.beginDownload(
        name,
        mimeType: 'application/octet-stream',
      );
      try {
        await writer.add(bytes);
        final saved = await writer.finish();
        if (!mounted) return;
        setState(
          () => _status = l10n.backupSavedToDownloads(saved.displayName),
        );
      } catch (e) {
        await writer.abort();
        rethrow;
      }
    } on DeviceStorageException catch (e) {
      if (!mounted) return;
      setState(() => _status = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = l10n.backupWriteFailed('$e'));
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
    final l10n = context.l10n;
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
      setState(() => _status = l10n.backupReadFileFailed);
      return;
    }
    if (!mounted) return;

    final passphrase = await showDialog<String>(
      context: context,
      builder: (_) => _ImportPassphraseDialog(fileName: picked!.name),
    );
    if (passphrase == null || !mounted) return;
    DiagnosticsLog.instance.learnSecret(passphrase);

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
        _status = l10n.backupReadFailed;
      });
      return;
    }
    KnownHostsImport hostKeys;
    try {
      hostKeys = await widget.service.knownHostsToImport(payload);
    } catch (_) {
      // Unreadable known-hosts store: offer nothing to trust.
      hostKeys = const KnownHostsImport(toAdd: [], serversKept: 0);
    }
    if (!mounted) return;
    setState(() => _busy = false);

    final choice = await showDialog<ImportChoice>(
      context: context,
      builder: (_) => ImportPreviewDialog(
        contents: payload.contents,
        hostKeys: hostKeys,
      ),
    );
    if (choice == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final result = await widget.service.apply(
        payload: payload,
        mode: choice.mode,
        trustKnownHosts: choice.trustKnownHosts,
      );
      if (!mounted) return;
      setState(() => _status = _describe(l10n, result));
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = l10n.backupImportFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _describe(AppLocalizations l10n, ImportResult result) {
    return [
      l10n.backupImported(
        l10n.backupCountHosts(result.hosts),
        l10n.backupCountSnippets(result.snippets),
        l10n.backupCountTunnels(result.tunnels),
        l10n.backupCountBookmarks(result.bookmarks),
      ),
      if (result.hostsNeedingCredentials > 0)
        l10n.backupImportedNeedCredentials(result.hostsNeedingCredentials),
      if (result.knownHostsAdded > 0)
        l10n.backupImportedKeysAdded(result.knownHostsAdded),
      if (result.knownHostsKept > 0)
        l10n.backupImportedKeysKept(result.knownHostsKept),
      if (result.knownHostsNotTrusted > 0)
        l10n.backupImportedKeysNotTrusted(result.knownHostsNotTrusted),
      if (result.knownHostsNotSaved) l10n.backupImportedKeyringLocked,
    ].join(' ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.backupTitle)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              if (_busy) const LinearProgressIndicator(minHeight: 2),
              _SectionHeader(l10n.backupExport),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  l10n.backupExportIntro,
                  style: const TextStyle(height: 1.35),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: _NoteCard(
                  icon: Icons.vpn_key_outlined,
                  // Called out here rather than buried in a release note: a
                  // user restoring on a new device will see host-key warnings
                  // and should know now that it is by design.
                  text: l10n.backupHostKeysNote,
                ),
              ),
              if (_saver != null) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: FilledButton.icon(
                    onPressed: _busy
                        ? null
                        : () => unawaited(_export(chooseLocation: true)),
                    icon: const Icon(Icons.save_as_outlined),
                    label: Text(l10n.backupSaveTo),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
                  child: Text(
                    l10n.backupSaveToHelp,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _saver != null
                    ? OutlinedButton.icon(
                        onPressed: _busy
                            ? null
                            : () => unawaited(_export(chooseLocation: false)),
                        icon: const Icon(Icons.download_for_offline_outlined),
                        label: Text(l10n.backupSaveToDownloads),
                      )
                    : FilledButton.icon(
                        onPressed: _busy
                            ? null
                            : () => unawaited(_export(chooseLocation: false)),
                        icon: const Icon(Icons.upload_file_outlined),
                        label: Text(l10n.backupExportToFile),
                      ),
              ),
              const Divider(height: 40),
              _SectionHeader(l10n.backupImport),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(
                  l10n.backupImportIntro('.${BackupService.fileExtension}'),
                  style: const TextStyle(height: 1.35),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : () => unawaited(_import()),
                  icon: const Icon(Icons.download_outlined),
                  label: Text(l10n.backupImportFromFile),
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
    required this.includeKnownHosts,
  });

  final String passphrase;
  final bool includeCredentials;
  final bool includeKnownHosts;
}

class _ExportDialog extends StatefulWidget {
  const _ExportDialog({required this.canIncludeKnownHosts});

  final bool canIncludeKnownHosts;

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  final _passphrase = TextEditingController();
  final _confirm = TextEditingController();
  bool _includeCredentials = false;
  bool _includeKnownHosts = false;
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
    final l10n = context.l10n;
    final strength = BackupPassphrase.strengthOf(_passphrase.text);
    return AlertDialog(
      title: Text(l10n.backupExportTitle),
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
                labelText: l10n.backupPassphrase,
                helperText: strength.hintIn(l10n),
                helperMaxLines: 4,
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscure ? Icons.visibility_off : Icons.visibility,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                  tooltip: _obscure ? l10n.backupShow : l10n.backupHide,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 4,
              children: [
                Text(
                  l10n.backupStrength,
                  style: theme.textTheme.bodySmall,
                ),
                Text(
                  strength.labelIn(l10n),
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
                labelText: l10n.backupConfirmPassphrase,
                errorText: _confirm.text.isNotEmpty && !_matches
                    ? l10n.backupMismatch
                    : null,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.backupNoRecovery,
              style: const TextStyle(height: 1.3, fontSize: 12),
            ),
            const SizedBox(height: 12),
            CheckboxListTile(
              value: _includeCredentials,
              onChanged: (v) =>
                  setState(() => _includeCredentials = v ?? false),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(l10n.backupIncludeCredentials),
              subtitle: Text(
                l10n.backupIncludeCredentialsHelp,
                style: const TextStyle(height: 1.3),
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
                  l10n.backupCredentialsWarning,
                  style: theme.textTheme.bodySmall?.copyWith(height: 1.3),
                ),
              ),
            if (widget.canIncludeKnownHosts)
              CheckboxListTile(
                value: _includeKnownHosts,
                onChanged: (v) =>
                    setState(() => _includeKnownHosts = v ?? false),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(l10n.backupIncludeHostKeys),
                subtitle: Text(
                  l10n.backupIncludeHostKeysHelp,
                  style: const TextStyle(height: 1.3),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: _OneLine(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          onPressed: _canExport
              ? () => Navigator.of(context).pop(
                    _ExportChoice(
                      passphrase: _passphrase.text,
                      includeCredentials: _includeCredentials,
                      includeKnownHosts: _includeKnownHosts,
                    ),
                  )
              : null,
          child: _OneLine(l10n.backupExportAction),
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
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.backupOpenTitle),
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
            decoration: InputDecoration(labelText: l10n.backupPassphrase),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: _OneLine(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_passphrase.text),
          child: _OneLine(l10n.backupOpenAction),
        ),
      ],
    );
  }
}

/// What the import preview collected.
class ImportChoice {
  const ImportChoice({required this.mode, required this.trustKnownHosts});

  final ImportMode mode;

  /// "Trust these keys" was ticked.
  final bool trustKnownHosts;
}

/// What is inside the file, the host keys it would have this device trust,
/// and the merge/replace choice. Shown *after* a successful decrypt and
/// *before* anything is written.
///
/// The host keys are listed one by one — server and fingerprint — behind a
/// "Trust these keys" box that starts off: a trusted key is accepted
/// without a question the next time, so a backup from anyone but yourself
/// must not get that by default. Public for its test.
class ImportPreviewDialog extends StatefulWidget {
  const ImportPreviewDialog({
    super.key,
    required this.contents,
    this.hostKeys = const KnownHostsImport(toAdd: [], serversKept: 0),
  });

  final BackupContents contents;
  final KnownHostsImport hostKeys;

  @override
  State<ImportPreviewDialog> createState() => _ImportPreviewDialogState();
}

class _ImportPreviewDialogState extends State<ImportPreviewDialog> {
  bool _trust = false;

  void _choose(ImportMode mode) => Navigator.of(context).pop(
        ImportChoice(mode: mode, trustKnownHosts: _trust),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final contents = widget.contents;
    final hostKeys = widget.hostKeys;
    final small = theme.textTheme.bodySmall?.copyWith(height: 1.3);
    final mono = small?.copyWith(
      fontFamily: AppTheme.monoFontFamily,
      fontFamilyFallback: AppTheme.monoFontFamilyFallback,
    );
    final kept = hostKeys.serversKept;
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.backupContainsTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _CountRow(l10n.backupRowHosts, contents.hosts),
            _CountRow(l10n.backupRowGroups, contents.groups),
            _CountRow(l10n.backupRowSnippets, contents.snippets),
            _CountRow(l10n.backupRowTunnels, contents.tunnels),
            _CountRow(l10n.backupRowBookmarks, contents.bookmarks),
            if (contents.includesKnownHosts)
              _CountRow(l10n.backupRowHostKeys, contents.knownHosts),
            const Divider(height: 20),
            Text(
              contents.includesCredentials
                  ? l10n.backupIncludesCredentials(contents.credentials)
                  : l10n.backupNoCredentials(contents.hostsNeedingCredentials),
              style: small,
            ),
            const SizedBox(height: 10),
            Text(l10n.backupSettingsReplaced, style: small),
            if (contents.includesKnownHosts) ...[
              const SizedBox(height: 10),
              if (hostKeys.toAdd.isEmpty)
                Text(l10n.backupNoNewServers, style: small)
              else ...[
                Text(l10n.backupNewServerKeys, style: small),
                const SizedBox(height: 4),
                for (final key in hostKeys.toAdd)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '${key.port == 22 ? key.hostname : '${key.hostname}:${key.port}'}'
                      '  ${key.keyType}\n${key.fingerprint}',
                      style: mono,
                    ),
                  ),
                CheckboxListTile(
                  value: _trust,
                  onChanged: (v) => setState(() => _trust = v ?? false),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(l10n.backupTrustKeys),
                  subtitle: Text(
                    l10n.backupTrustKeysHelp,
                    style: const TextStyle(height: 1.3),
                  ),
                ),
              ],
              if (kept > 0)
                Text(l10n.backupOtherKeysKept(kept), style: small),
            ],
            if (contents.isEmpty) ...[
              const SizedBox(height: 10),
              Text(
                l10n.backupEmptyWarning,
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
          child: _OneLine(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        TextButton(
          onPressed: () => _choose(ImportMode.replace),
          child: _OneLine(l10n.backupReplace),
        ),
        FilledButton(
          onPressed: () => _choose(ImportMode.merge),
          child: _OneLine(l10n.backupMerge),
        ),
      ],
    );
  }
}

/// A dialog button label that shrinks rather than breaks: one long word,
/// like German's „Zusammenführen“ or Russian's «Экспортировать», split
/// mid-word on a narrow phone with large text.
class _OneLine extends StatelessWidget {
  const _OneLine(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(label, maxLines: 1, softWrap: false),
      );
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
          Expanded(child: Text(label)),
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

/// The export dialog's words for a passphrase's strength. Public for its
/// test.
extension PassphraseStrengthText on PassphraseStrength {
  String labelIn(AppLocalizations l10n) => switch (this) {
        PassphraseStrength.tooShort => l10n.backupStrengthTooShort,
        PassphraseStrength.weak => l10n.backupStrengthWeak,
        PassphraseStrength.fair => l10n.backupStrengthFair,
        PassphraseStrength.strong => l10n.backupStrengthStrong,
      };

  /// The line under the field. Says what would actually help rather than
  /// just naming the bucket.
  String hintIn(AppLocalizations l10n) => switch (this) {
        PassphraseStrength.tooShort =>
          l10n.backupHintTooShort(BackupPassphrase.minLength),
        PassphraseStrength.weak => l10n.backupHintWeak,
        PassphraseStrength.fair => l10n.backupHintFair,
        PassphraseStrength.strong => l10n.backupHintStrong,
      };
}
