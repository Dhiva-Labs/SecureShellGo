import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';
import '../theme.dart';

/// How long a copy control keeps saying "Copied" before it goes back to
/// offering the copy again.
const Duration copiedFeedbackDuration = Duration(seconds: 2);

/// Puts [text] on the clipboard and lets its [builder] show that it happened.
///
/// For a copy control inside a dialog. A snackbar raised from there plays
/// under the dialog's dimmed barrier, where it is hard to see, so the control
/// itself answers: [builder] is handed `copied` (true for
/// [copiedFeedbackDuration] after a copy) and the `copy` callback to wire to
/// its tap. Pick the check icon and `commonCopied` while `copied` is true.
class CopyFeedback extends StatefulWidget {
  const CopyFeedback({super.key, required this.text, required this.builder});

  final String text;
  final Widget Function(BuildContext context, bool copied, VoidCallback copy)
      builder;

  @override
  State<CopyFeedback> createState() => _CopyFeedbackState();
}

class _CopyFeedbackState extends State<CopyFeedback> {
  Timer? _revert;
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) return;
    setState(() => _copied = true);
    // The snackbar this replaces was announced; a label that merely changes
    // is not, so say it once for a screen reader.
    unawaited(SemanticsService.sendAnnouncement(
      View.of(context),
      context.l10n.commonCopied,
      Directionality.of(context),
    ));
    _revert?.cancel();
    _revert = Timer(copiedFeedbackDuration, () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  void dispose() {
    _revert?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, _copied, () => unawaited(_copy()));
}

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
        CopyFeedback(
          text: publicKeyLine,
          builder: (context, copied, copy) => TextButton.icon(
            onPressed: copy,
            icon: Icon(copied ? Icons.check : Icons.copy_outlined, size: 18),
            label: Text(
              copied
                  ? context.l10n.commonCopied
                  : MaterialLocalizations.of(context).copyButtonLabel,
            ),
          ),
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
