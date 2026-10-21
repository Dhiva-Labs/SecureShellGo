import 'package:flutter/material.dart';

import '../services/session_manager.dart';

/// What the strip above a session's terminal says about its connection:
/// reconnecting, or gone.
///
/// Reconnecting takes precedence over disconnected: both describe the same
/// dead transport, but only one is still a live story. Neither blocks
/// anything — the scrollback stays on screen, and scrollable, underneath.
///
/// Built from the session itself rather than from flags the screen picks
/// out, so a new state (a shell that exited, a network that came back) is a
/// change to this file alone.
class SessionBanners extends StatelessWidget {
  const SessionBanners({
    super.key,
    required this.session,
    required this.onCloseTab,
  });

  final ManagedSession session;

  /// Closes this session's tab — the one useful thing left to do with a
  /// session that is gone for good.
  final VoidCallback onCloseTab;

  @override
  Widget build(BuildContext context) {
    final controller = session.controller;
    if (controller.isReconnecting) {
      return _ReconnectingBanner(
        message: controller.reconnectMessage,
        // Notifies, and the screen rebuilds on the session's changes.
        onStop: controller.stopReconnecting,
      );
    }
    if (session.isClosed) {
      return _DisconnectedBanner(
        message: controller.closeReason,
        onClose: onCloseTab,
      );
    }
    return const SizedBox.shrink();
  }
}

/// "Reconnecting…", above the terminal whose transport has just died.
///
/// Deliberately not a dialog, not a modal barrier and not a full-screen
/// placeholder: the session may well be back in two seconds, and having thrown
/// a modal over the user's scrollback for a Wi-Fi handover would be a worse
/// experience than the drop it is reporting. The old buffer stays on screen
/// and stays readable throughout.
class _ReconnectingBanner extends StatelessWidget {
  const _ReconnectingBanner({this.message, required this.onStop});

  final String? message;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.primary.withValues(alpha: 0.13),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message ?? 'Reconnecting…',
                style: const TextStyle(fontSize: 13, height: 1.3),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              // Reconnecting is a guess about what the user wants; this is how
              // they say otherwise, without having to close the tab to do it.
              onPressed: onStop,
              child: const Text('Stop'),
            ),
          ],
        ),
      ),
    );
  }
}

class _DisconnectedBanner extends StatelessWidget {
  const _DisconnectedBanner({this.message, required this.onClose});

  final String? message;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.error.withValues(alpha: 0.15),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Row(
          children: [
            Icon(Icons.link_off, color: theme.colorScheme.error, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message ?? 'Connection closed.',
                style: const TextStyle(fontSize: 13, height: 1.3),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              // A dead session's tab is the one thing left to do something
              // about, and closing it is the only useful thing — the others
              // are unaffected either way.
              onPressed: onClose,
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }
}
