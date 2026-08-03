import 'package:flutter/material.dart';

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
