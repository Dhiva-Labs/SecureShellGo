import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// Shows a freshly generated public key line with a one-tap copy.
///
/// The private half never appears here — it goes straight into the edit
/// screen's own key field, which already runs through the credential store
/// like any pasted key. This dialog exists only to hand the *public* half
/// somewhere else it might be needed (a different account, a git host, a
/// server this app is not about to connect to itself) without retyping it.
Future<void> showGeneratedPublicKeyDialog(
  BuildContext context,
  String publicKeyLine,
) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.vpn_key_outlined),
      title: const Text('New key generated'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'The private key now fills the field below and will be saved '
            'with this host. Add the public line to a server yourself, or '
            'use "Install public key on server…" once you have saved.',
            style: TextStyle(height: 1.35),
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(6),
            ),
            child: SelectableText(
              publicKeyLine,
              style: const TextStyle(
                fontFamily: AppTheme.monoFontFamily,
                fontFamilyFallback: AppTheme.monoFontFamilyFallback,
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: publicKeyLine));
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Public key copied')),
            );
          },
          child: const Text('Copy'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    ),
  );
}

/// Asks for the password to push a public key with, when there is no
/// already-connected session on this host to reuse. Returns null if the user
/// cancelled — distinct from an empty string, which the caller also treats
/// as "did not provide one".
Future<String?> promptForPushPassword(BuildContext context, String target) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Install public key on server'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Enter the password for $target to install the key.'),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            obscureText: true,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: 'Password'),
            onSubmitted: (value) => Navigator.of(context).pop(value),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(controller.text),
          child: const Text('Install'),
        ),
      ],
    ),
  );
}
