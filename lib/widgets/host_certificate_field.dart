import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../services/device_storage.dart';
import '../services/ssh_certificate.dart';
import '../theme.dart';
import 'import_key_file_button.dart' show showKeyFileErrorDialog;

/// A `-cert.pub` is one line; anything near this is not one.
const int _maxCertificateBytes = 16 * 1024;

/// The host form's certificate row, in the sign-in area under the key it
/// goes with: load a `-cert.pub` or paste one, see its key ID, principals,
/// validity and restrictions, and remove it.
///
/// A [FormField], so a certificate issued for a different key than the one
/// in the form stops the form from saving with the reason under the row —
/// it could never sign in, and would only fail later with a bare
/// "permission denied". An expired one is shown, in red, but saves: a
/// renewed certificate is often on its way, and the rest of the host is
/// still worth keeping.
class HostCertificateField extends StatelessWidget {
  const HostCertificateField({
    super.key,
    required this.certificate,
    required this.onChanged,
    required this.deviceStorage,
    required this.username,
    this.keyBlob,
    this.signsWithAgent = false,
    this.now = DateTime.now,
  });

  /// The certificate line, or null for none.
  final String? certificate;
  final ValueChanged<String?> onChanged;
  final DeviceStorage deviceStorage;

  /// The account being signed in as, to warn when the certificate does not
  /// name it.
  final String username;

  /// The public half of the key in the form, when it can be read — not for
  /// an agent host, and not for an encrypted PEM key before its passphrase
  /// is typed. When null the key match is checked at connect time instead.
  final Uint8List? keyBlob;

  /// Whether the key lives in the OS agent rather than in the form.
  final bool signsWithAgent;

  final DateTime Function() now;

  String? _validate(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final SshCertificate parsed;
    try {
      parsed = SshCertificate.parse(value);
    } on SshCertificateException catch (e) {
      return e.message;
    }
    final blob = keyBlob;
    return blob == null ? null : parsed.mismatchWith(blob);
  }

  @override
  Widget build(BuildContext context) {
    return FormField<String?>(
      // Remounted whenever the certificate changes, so the field's own copy
      // of the value never lags the form's.
      key: ValueKey(certificate),
      initialValue: certificate,
      validator: _validate,
      // Checked as soon as it is shown, not only on save: a mismatch is
      // worth seeing the moment the certificate is loaded.
      autovalidateMode: AutovalidateMode.always,
      builder: (state) => _CertificateBody(
        field: this,
        errorText: state.errorText,
      ),
    );
  }
}

class _CertificateBody extends StatelessWidget {
  const _CertificateBody({required this.field, required this.errorText});

  final HostCertificateField field;
  final String? errorText;

  Future<void> _load(BuildContext context) async {
    try {
      final picked = await field.deviceStorage.pickTextFile(
        maxBytes: _maxCertificateBytes,
      );
      if (picked == null || !context.mounted) return;
      try {
        final parsed = SshCertificate.parse(picked.content);
        field.onChanged(parsed.line);
      } on SshCertificateException catch (e) {
        await showKeyFileErrorDialog(context, picked.name, e.message);
      }
    } on DeviceStorageException catch (e) {
      if (!context.mounted) return;
      await showKeyFileErrorDialog(context, null, e.message);
    } catch (_) {
      if (!context.mounted) return;
      await showKeyFileErrorDialog(
        context,
        null,
        context.l10n.importKeyFileUnreadable,
      );
    }
  }

  Future<void> _paste(BuildContext context) async {
    final line = await showDialog<String>(
      context: context,
      builder: (context) => const _PasteCertificateDialog(),
    );
    if (line != null) field.onChanged(line);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final text = field.certificate;
    final parsed = text == null ? null : SshCertificate.tryParse(text);

    final actions = Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        OutlinedButton.icon(
          onPressed: () => _load(context),
          icon: const Icon(Icons.file_open_outlined, size: 18),
          label: Text(text == null ? l10n.hostCertLoad : l10n.hostCertReplace),
        ),
        TextButton.icon(
          onPressed: () => _paste(context),
          icon: const Icon(Icons.content_paste, size: 18),
          label: Text(
            text == null ? l10n.hostCertPaste : l10n.hostCertPasteAnother,
          ),
        ),
        if (text != null)
          TextButton.icon(
            onPressed: () => field.onChanged(null),
            icon: const Icon(Icons.delete_outline, size: 18),
            label: Text(l10n.hostCertRemove),
          ),
      ],
    );

    final children = <Widget>[];
    if (text == null) {
      children.add(Text(
        field.signsWithAgent ? l10n.hostCertHintAgent : l10n.hostCertHintKey,
        style: muted,
      ));
    } else if (parsed == null) {
      children.add(Text(
        l10n.hostCertUnreadable,
        style: muted?.copyWith(color: theme.colorScheme.error),
      ));
    } else {
      children.add(_CertificateSummary(
        certificate: parsed,
        username: field.username,
        now: field.now(),
      ));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.verified_user_outlined,
              size: 20,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                parsed == null
                    ? l10n.hostCertTitle
                    : l10n.hostCertTitleWithType(parsed.keyTypeLabel),
                style: theme.textTheme.bodyLarge,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ...children,
        if (errorText != null) ...[
          const SizedBox(height: 6),
          Text(
            errorText!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
        const SizedBox(height: 8),
        actions,
      ],
    );
  }
}

/// Key ID, principals, validity, critical options and extensions, as
/// `ssh-keygen -L` would show them, in a few lines — with a warning under
/// anything that changes what signing in with it does.
class _CertificateSummary extends StatelessWidget {
  const _CertificateSummary({
    required this.certificate,
    required this.username,
    required this.now,
  });

  final SshCertificate certificate;
  final String username;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final warning = muted?.copyWith(color: theme.colorScheme.error);
    final mono = muted?.copyWith(
      fontFamily: AppTheme.monoFontFamily,
      fontFamilyFallback: AppTheme.monoFontFamilyFallback,
    );
    final principals = certificate.principals;
    final user = username.trim();
    final unlisted =
        principals.isNotEmpty && user.isNotEmpty && !principals.contains(user);

    final validity = certificate.validityAt(now);
    final statusColor = validity == SshCertificateValidity.valid
        ? theme.colorScheme.onSurfaceVariant
        : theme.colorScheme.error;

    Widget row(String label, String value, {TextStyle? style}) => Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Text.rich(
            TextSpan(children: [
              TextSpan(text: '$label  ', style: muted),
              TextSpan(text: value, style: style ?? muted),
            ]),
          ),
        );
    Widget note(String text, {TextStyle? style}) => Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(text, style: style ?? muted),
        );

    final options = certificate.criticalOptions;
    final forced = certificate.forceCommand;
    final from = certificate.sourceAddresses;
    final unknown = certificate.unknownCriticalOptions;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        row(
          l10n.hostCertKeyId,
          certificate.keyId.isEmpty ? l10n.hostCertNone : certificate.keyId,
          style: mono,
        ),
        row(
          l10n.hostCertPrincipals,
          principals.isEmpty ? l10n.hostCertNone : principals.join(', '),
          style: principals.isEmpty ? warning : mono,
        ),
        row(l10n.hostCertValidity, describeCertificateValidity(certificate, l10n)),
        if (options.isNotEmpty)
          row(
            l10n.hostCertCriticalOptions,
            [
              for (final MapEntry(:key, :value) in options.entries)
                value.isEmpty ? key : '$key=$value',
            ].join(', '),
            style: mono,
          ),
        row(
          l10n.hostCertPermits,
          certificate.extensions.isEmpty
              ? l10n.hostCertNothing
              : certificate.extensions.join(', '),
          style: mono,
        ),
        Text(
          describeCertificateStatus(certificate, now, l10n),
          style: muted?.copyWith(color: statusColor),
        ),
        if (principals.isEmpty)
          note(l10n.hostCertNoPrincipals, style: warning),
        if (unlisted) note(l10n.hostCertUserNotListed(user)),
        if (forced != null)
          note(l10n.hostCertForcedCommand(forced), style: warning),
        if (from != null)
          note(l10n.hostCertSourceAddresses(from.join(', ')), style: warning),
        if (unknown.isNotEmpty)
          note(
            l10n.hostCertUnknownCriticalOptions(unknown.join(', ')),
            style: warning,
          ),
      ],
    );
  }
}

/// "2026-10-21 15:04 UTC → 2027-10-20 15:09 UTC", with "always" and
/// "forever" for the open ends.
String describeCertificateValidity(
  SshCertificate certificate,
  AppLocalizations l10n,
) {
  final after = certificate.validAfter;
  final before = certificate.validBefore;
  if (after == null && before == null) return l10n.hostCertValidForever;
  final from =
      after == null ? l10n.hostCertValidAlways : formatCertificateTime(after);
  final to =
      before == null ? l10n.hostCertValidForever : formatCertificateTime(before);
  return l10n.hostCertValidRange(from, to);
}

/// One line on whether the certificate can be used now: "Valid, expires in
/// 3 days", "Expired on …", "Not valid until …".
String describeCertificateStatus(
  SshCertificate certificate,
  DateTime now,
  AppLocalizations l10n,
) {
  switch (certificate.validityAt(now)) {
    case SshCertificateValidity.expired:
      return l10n.hostCertExpired(
        formatCertificateTime(certificate.validBefore!),
      );
    case SshCertificateValidity.notYetValid:
      return l10n.hostCertNotYetValid(
        formatCertificateTime(certificate.validAfter!),
      );
    case SshCertificateValidity.valid:
      final before = certificate.validBefore;
      if (before == null) return l10n.hostCertValidNoExpiry;
      final left = before.difference(now);
      if (left.inDays >= 2) return l10n.hostCertExpiresInDays(left.inDays);
      if (left.inHours >= 2) return l10n.hostCertExpiresInHours(left.inHours);
      if (left.inMinutes >= 2) {
        return l10n.hostCertExpiresInMinutes(left.inMinutes);
      }
      return l10n.hostCertExpiresInAMinute;
  }
}

/// Asks for a certificate line, and only closes on one that reads.
class _PasteCertificateDialog extends StatefulWidget {
  const _PasteCertificateDialog();

  @override
  State<_PasteCertificateDialog> createState() =>
      _PasteCertificateDialogState();
}

class _PasteCertificateDialogState extends State<_PasteCertificateDialog> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    try {
      final parsed = SshCertificate.parse(_controller.text);
      Navigator.of(context).pop(parsed.line);
    } on SshCertificateException catch (e) {
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.l10n.hostCertPaste),
      content: TextField(
        controller: _controller,
        autofocus: true,
        minLines: 3,
        maxLines: 6,
        autocorrect: false,
        enableSuggestions: false,
        style: const TextStyle(
          fontFamily: AppTheme.monoFontFamily,
          fontFamilyFallback: AppTheme.monoFontFamilyFallback,
          fontSize: 12,
        ),
        decoration: InputDecoration(
          hintText: 'ssh-ed25519-cert-v01@openssh.com AAAA…',
          errorText: _error,
          errorMaxLines: 4,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(onPressed: _submit, child: Text(context.l10n.hostCertUse)),
      ],
    );
  }
}
