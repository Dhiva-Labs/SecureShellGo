import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../services/remote_desktop/csrd_messages.dart';

/// A message from the remote side, such as "capture is slow" or "the
/// virtual desktop is out of memory", shown above the screen until it is
/// dismissed or the remote withdraws it.
class RemoteNoticeBanner extends StatelessWidget {
  const RemoteNoticeBanner({
    super.key,
    required this.level,
    required this.text,
    required this.onDismiss,
  });

  /// A `CsrdNoticeLevel`.
  final int level;
  final String text;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (background, foreground, icon) = switch (level) {
      CsrdNoticeLevel.error => (
        scheme.errorContainer,
        scheme.onErrorContainer,
        Icons.error_outline,
      ),
      CsrdNoticeLevel.warn => (
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
        Icons.warning_amber_outlined,
      ),
      _ => (
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
        Icons.info_outline,
      ),
    };
    return Material(
      color: background,
      child: Padding(
        padding: const EdgeInsets.only(left: 12),
        child: Row(
          children: [
            Icon(icon, size: 20, color: foreground),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: TextStyle(color: foreground, height: 1.3),
              ),
            ),
            IconButton(
              tooltip: context.l10n.remoteDesktopDismissNotice,
              icon: Icon(Icons.close, color: foreground),
              onPressed: onDismiss,
            ),
          ],
        ),
      ),
    );
  }
}
