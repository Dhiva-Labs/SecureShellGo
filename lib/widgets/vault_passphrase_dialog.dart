import 'package:flutter/material.dart';

import '../services/backup_passphrase.dart';

/// Asks for a new app passphrase to protect the credential vault, or null if
/// the user backed out.
///
/// Shares [BackupPassphrase]'s rules rather than inventing a second set: a
/// twelve-character floor, a coarse strength hint, and no character-class
/// mandate. The two passphrases protect the same class of thing — every
/// server password the user owns — so a different bar for each would only be
/// confusing.
Future<String?> showSetVaultPassphraseDialog(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (_) => const _SetVaultPassphraseDialog(),
  );
}

/// Asks for the existing vault passphrase, or null if the user backed out.
///
/// [error] is the previous attempt's message, shown inline so a wrong
/// passphrase does not cost the user the dialog.
Future<String?> showUnlockVaultDialog(
  BuildContext context, {
  String? error,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _UnlockVaultDialog(error: error),
  );
}

class _SetVaultPassphraseDialog extends StatefulWidget {
  const _SetVaultPassphraseDialog();

  @override
  State<_SetVaultPassphraseDialog> createState() =>
      _SetVaultPassphraseDialogState();
}

class _SetVaultPassphraseDialogState extends State<_SetVaultPassphraseDialog> {
  final _passphrase = TextEditingController();
  final _confirm = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _passphrase.dispose();
    _confirm.dispose();
    super.dispose();
  }

  bool get _matches =>
      _passphrase.text.isNotEmpty && _passphrase.text == _confirm.text;

  bool get _canSet =>
      BackupPassphrase.isAcceptable(_passphrase.text) && _matches;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strength = BackupPassphrase.strengthOf(_passphrase.text);
    return AlertDialog(
      title: const Text('Protect credentials with a passphrase'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'SecureShell Go could not reach a system keyring on this '
              'device, so saved passwords and keys will be encrypted with a '
              'passphrase you choose instead. You will be asked for it once '
              'each time the app starts.',
              style: TextStyle(height: 1.35),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _passphrase,
              obscureText: _obscure,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'App passphrase',
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
                Text('Strength: ', style: theme.textTheme.bodySmall),
                Text(
                  strength.label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: switch (strength) {
                      PassphraseStrength.tooShort ||
                      PassphraseStrength.weak =>
                        theme.colorScheme.error,
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
            const SizedBox(height: 10),
            const Text(
              'There is no way to recover the saved credentials without this '
              'passphrase. It is not stored anywhere.',
              style: TextStyle(height: 1.3, fontSize: 12),
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
          onPressed:
              _canSet ? () => Navigator.of(context).pop(_passphrase.text) : null,
          child: const Text('Protect and save'),
        ),
      ],
    );
  }
}

class _UnlockVaultDialog extends StatefulWidget {
  const _UnlockVaultDialog({this.error});

  final String? error;

  @override
  State<_UnlockVaultDialog> createState() => _UnlockVaultDialogState();
}

class _UnlockVaultDialogState extends State<_UnlockVaultDialog> {
  final _passphrase = TextEditingController();

  @override
  void dispose() {
    _passphrase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Unlock saved credentials'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Enter the app passphrase protecting your saved passwords and '
            'keys.',
            style: TextStyle(height: 1.35),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _passphrase,
            obscureText: true,
            autofocus: true,
            onSubmitted: (value) => Navigator.of(context).pop(value),
            decoration: InputDecoration(
              labelText: 'App passphrase',
              errorText: widget.error,
              errorMaxLines: 2,
            ),
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
          child: const Text('Unlock'),
        ),
      ],
    );
  }
}
