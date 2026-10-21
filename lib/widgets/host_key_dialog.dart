import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';
import '../services/host_key_policy.dart';
import '../theme.dart';

/// Shows the host key decision and returns true only on explicit acceptance.
///
/// Two visually distinct modes, because they are two very different questions:
///
///  * [HostKeyPromptKind.unknown] — trust on first use. Neutral tone; the user
///    is asked to compare the fingerprint against one they obtained elsewhere.
///  * [HostKeyPromptKind.changed] — the key for a host we already trust has
///    changed. Red, blocking, and the confirm button is deliberately awkward.
///
/// Dismissing by any means other than the accept button is treated as reject.
Future<bool> showHostKeyDialog(
  BuildContext context,
  HostKeyPrompt prompt,
) async {
  final accepted = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _HostKeyDialog(prompt: prompt),
  );
  return accepted ?? false;
}

class _HostKeyDialog extends StatefulWidget {
  const _HostKeyDialog({required this.prompt});

  final HostKeyPrompt prompt;

  @override
  State<_HostKeyDialog> createState() => _HostKeyDialogState();
}

class _HostKeyDialogState extends State<_HostKeyDialog> {
  /// For the "key changed" case only: the user must tick this before the
  /// "Trust new key" button becomes usable. Friction is the point.
  bool _acknowledgedRisk = false;

  bool get _isChanged => widget.prompt.kind == HostKeyPromptKind.changed;

  @override
  Widget build(BuildContext context) {
    final prompt = widget.prompt;
    final theme = Theme.of(context);
    final l10n = context.l10n;

    return AlertDialog(
      icon: Icon(
        _isChanged ? Icons.gpp_maybe : Icons.vpn_key_outlined,
        color: _isChanged ? theme.colorScheme.error : theme.colorScheme.primary,
        size: 32,
      ),
      title: Text(
        _isChanged ? l10n.hostKeyChangedTitle : l10n.hostKeyUnknownTitle,
        style: TextStyle(color: _isChanged ? theme.colorScheme.error : null),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_isChanged) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.error.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: theme.colorScheme.error.withValues(alpha: 0.5),
                  ),
                ),
                child: Text(
                  l10n.hostKeyChangedWarning,
                  style: const TextStyle(height: 1.35),
                ),
              ),
              const SizedBox(height: 16),
            ] else ...[
              Text(
                prompt.hostHasOtherKeys
                    ? l10n.hostKeyUnknownBodyNewType(
                        prompt.hostLabel,
                        prompt.keyType,
                      )
                    : l10n.hostKeyUnknownBody(prompt.hostLabel),
                style: const TextStyle(height: 1.35),
              ),
              const SizedBox(height: 8),
              Text(
                l10n.hostKeyCompareHint(
                  'ssh-keygen -lf '
                  '/etc/ssh/ssh_host_${_shortType(prompt.keyType)}_key.pub',
                ),
                style: theme.textTheme.bodySmall?.copyWith(height: 1.35),
              ),
              const SizedBox(height: 16),
            ],
            _FieldRow(label: l10n.hostKeyFieldHost, value: prompt.hostLabel),
            _FieldRow(label: l10n.hostKeyFieldKeyType, value: prompt.keyType),
            if (_isChanged && prompt.previous != null) ...[
              const SizedBox(height: 12),
              _FingerprintBlock(
                label: l10n.hostKeyPreviouslyTrusted,
                fingerprint: prompt.previous!.fingerprint,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 8),
              _FingerprintBlock(
                label: l10n.hostKeyOfferedNow,
                fingerprint: prompt.fingerprint,
                color: theme.colorScheme.error,
              ),
            ] else ...[
              const SizedBox(height: 12),
              _FingerprintBlock(
                label: l10n.hostKeyFingerprint,
                fingerprint: prompt.fingerprint,
                color: theme.colorScheme.primary,
              ),
            ],
            if (_isChanged) ...[
              const SizedBox(height: 8),
              CheckboxListTile(
                value: _acknowledgedRisk,
                onChanged: (value) =>
                    setState(() => _acknowledgedRisk = value ?? false),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(
                  l10n.hostKeyVerifiedNewKey,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(_isChanged ? l10n.hostKeyAbort : l10n.hostKeyReject),
        ),
        if (_isChanged)
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
              minimumSize: const Size(0, 48),
            ),
            onPressed: _acknowledgedRisk
                ? () => Navigator.of(context).pop(true)
                : null,
            child: Text(l10n.hostKeyTrustNewKey),
          )
        else
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.hostKeyAcceptAndSave),
          ),
      ],
    );
  }

  /// `ssh-ed25519` -> `ed25519`, `rsa-sha2-512` -> `rsa`. Used only to build a
  /// helpful example command, so a rough mapping is fine.
  static String _shortType(String keyType) {
    if (keyType.contains('ed25519')) return 'ed25519';
    if (keyType.contains('rsa')) return 'rsa';
    if (keyType.contains('ecdsa')) return 'ecdsa';
    return keyType;
  }
}

class _FieldRow extends StatelessWidget {
  const _FieldRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontFamily: AppTheme.monoFontFamily,
                fontFamilyFallback: AppTheme.monoFontFamilyFallback,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FingerprintBlock extends StatelessWidget {
  const _FingerprintBlock({
    required this.label,
    required this.fingerprint,
    required this.color,
  });

  final String label;
  final String fingerprint;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 4),
        InkWell(
          onTap: () {
            Clipboard.setData(ClipboardData(text: fingerprint));
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(context.l10n.hostKeyFingerprintCopied)),
            );
          },
          borderRadius: BorderRadius.circular(6),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: color.withValues(alpha: 0.4)),
            ),
            child: SelectableText(
              fingerprint,
              style: TextStyle(
                fontFamily: AppTheme.monoFontFamily,
                fontFamilyFallback: AppTheme.monoFontFamilyFallback,
                fontSize: 12.5,
                color: color,
                height: 1.3,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
