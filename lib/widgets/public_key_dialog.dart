import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';
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
      title: Text(context.l10n.publicKeyGeneratedTitle),
      // Scrolls rather than overflowing on a short screen with large text.
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.publicKeyGeneratedBody(
                context.l10n.hostEditInstallKey,
              ),
              style: const TextStyle(height: 1.35),
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
      ),
      actions: [
        TextButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: publicKeyLine));
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(context.l10n.publicKeyCopied)),
            );
          },
          child: Text(MaterialLocalizations.of(context).copyButtonLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.l10n.publicKeyDone),
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
      title: Text(context.l10n.publicKeyInstallTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.l10n.publicKeyInstallPrompt(target)),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              obscureText: true,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: context.l10n.hostPasswordLabel,
              ),
              onSubmitted: (value) => Navigator.of(context).pop(value),
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
          onPressed: () => Navigator.of(context).pop(controller.text),
          child: Text(context.l10n.publicKeyInstall),
        ),
      ],
    ),
  );
}
