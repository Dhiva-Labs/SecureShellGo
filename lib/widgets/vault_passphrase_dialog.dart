import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../services/diagnostics_log.dart';

/// Asks for the passphrase of an existing credential vault, or null if the
/// user backed out.
///
/// Only 1.4.1 ever created one of these; nothing in the app sets a vault
/// passphrase any more, so there is no dialog for choosing one. This is
/// purely so that a vault made under 1.4.1 keeps opening — see
/// `secret_vault.dart`.
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

  /// Closes with [value], which the diagnostics log learns first: a failed
  /// unlock can end up in an error message.
  void _submit(String value) {
    DiagnosticsLog.instance.learnSecret(value);
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.vaultUnlockTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.vaultUnlockBody, style: const TextStyle(height: 1.35)),
            const SizedBox(height: 14),
            TextField(
              controller: _passphrase,
              obscureText: true,
              autofocus: true,
              onSubmitted: _submit,
              decoration: InputDecoration(
                labelText: l10n.vaultUnlockPassphraseLabel,
                errorText: widget.error,
                errorMaxLines: 2,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          onPressed: () => _submit(_passphrase.text),
          child: Text(l10n.vaultUnlockButton),
        ),
      ],
    );
  }
}
