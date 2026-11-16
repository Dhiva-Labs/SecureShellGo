import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../models/host_ai_access.dart';

/// A host's AI access level as a small chip: Off, Read only, Asks first, Full
/// control. Full control is drawn in the error colours so it never reads like
/// the others.
class HostAiLevelChip extends StatelessWidget {
  const HostAiLevelChip({super.key, required this.level});

  final HostAiAccess level;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final (label, background, foreground) = switch (level) {
      HostAiAccess.off => (
        l10n.hostAiChipOff,
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
      ),
      HostAiAccess.readOnly => (
        l10n.hostAiChipRead,
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
      ),
      HostAiAccess.askToChange => (
        l10n.hostAiChipAsk,
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
      ),
      HostAiAccess.fullControl => (
        l10n.hostAiChipFull,
        scheme.errorContainer,
        scheme.onErrorContainer,
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (level == HostAiAccess.fullControl) ...[
            Icon(Icons.warning_amber_rounded, size: 14, color: foreground),
            const SizedBox(width: 4),
          ],
          // Flexible: with large text on a narrow screen the label wraps
          // rather than running off the row.
          Flexible(
            child: Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(color: foreground),
            ),
          ),
        ],
      ),
    );
  }
}
