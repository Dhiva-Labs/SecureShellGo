import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../services/session_manager.dart';

/// What the strip above a session's terminal says about its connection:
/// reconnecting, gone, or connected with a shell that has ended.
///
/// Reconnecting takes precedence over disconnected: both describe the same
/// dead transport, but only one is still a live story. None of them blocks
/// anything — the scrollback stays on screen, and scrollable, underneath —
/// and none is a dead end: each offers the way back that fits it.
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
    if (controller.isSshLostUnderMosh) {
      // The terminal is fine, so nothing here is an error or a dead end;
      // only what needs SSH is waiting.
      return _SshLostUnderMoshBanner(
        message: controller.reconnectGaveUp
            ? controller.reconnectMessage
            : null,
        onReconnect:
            controller.canReconnect ? controller.reconnectNow : null,
      );
    }
    if (session.isClosed) {
      return _DisconnectedBanner(
        message: controller.reconnectGaveUp
            ? controller.reconnectMessage ?? controller.closeReason
            : controller.closeReason,
        onReconnect:
            controller.canReconnect ? controller.reconnectNow : null,
        onClose: onCloseTab,
      );
    }
    if (controller.hasShellEnded) {
      return _ShellEndedBanner(
        message: controller.shellEndedReason,
        onRestart: () => controller.restartShell(),
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
                message ?? context.l10n.sessionBannerReconnecting,
                style: const TextStyle(fontSize: 13, height: 1.3),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              // Reconnecting is a guess about what the user wants; this is how
              // they say otherwise, without having to close the tab to do it.
              onPressed: onStop,
              child: Text(context.l10n.sessionBannerStop),
            ),
          ],
        ),
      ),
    );
  }
}

class _DisconnectedBanner extends StatelessWidget {
  const _DisconnectedBanner({
    this.message,
    this.onReconnect,
    required this.onClose,
  });

  final String? message;

  /// Null when the session has no way to reconnect (nothing saved to log in
  /// with was ever wired in), which leaves Close as the only way on.
  final VoidCallback? onReconnect;
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
                message ?? context.l10n.sessionBannerClosed,
                style: const TextStyle(fontSize: 13, height: 1.3),
              ),
            ),
            const SizedBox(width: 8),
            if (onReconnect != null)
              TextButton(
                // However it ended — a schedule that gave up, a Stop, the
                // server going away — the same tab, scrollback and transfers
                // are one tap from coming back.
                onPressed: onReconnect,
                child: Text(context.l10n.sessionBannerReconnect),
              ),
            TextButton(
              // Closing the tab is the other useful thing to do with a dead
              // session — the others are unaffected either way.
              onPressed: onClose,
              child: Text(context.l10n.sessionBannerClose),
            ),
          ],
        ),
      ),
    );
  }
}

/// SSH is gone but the terminal is not: it runs over Mosh, and carries on.
/// Shown once reconnecting SSH has stopped — given up, or stopped by the
/// user — while files, tunnels and commands wait for it.
class _SshLostUnderMoshBanner extends StatelessWidget {
  const _SshLostUnderMoshBanner({this.message, this.onReconnect});

  final String? message;
  final VoidCallback? onReconnect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.tertiary.withValues(alpha: 0.13),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Row(
          children: [
            Icon(Icons.link_off, color: theme.colorScheme.tertiary, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message ?? context.l10n.sessionBannerSshLostUnderMosh,
                style: const TextStyle(fontSize: 13, height: 1.3),
              ),
            ),
            const SizedBox(width: 8),
            if (onReconnect != null)
              TextButton(onPressed: onReconnect, child: Text(context.l10n.sessionBannerReconnect)),
          ],
        ),
      ),
    );
  }
}

/// "Shell ended — Restart": the shell has exited (or detached, or never
/// opened) while the connection under it is fine. A new shell is one tap on
/// the same connection — no login, no host-key prompt — and on a host with a
/// persistent session it is the same tmux or screen session again.
class _ShellEndedBanner extends StatelessWidget {
  const _ShellEndedBanner({
    this.message,
    required this.onRestart,
    required this.onClose,
  });

  final String? message;
  final VoidCallback onRestart;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detail = message;
    return Material(
      color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.5),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Row(
          children: [
            Icon(
              Icons.terminal,
              color: theme.colorScheme.onSecondaryContainer,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                detail == null
                    ? context.l10n.sessionBannerShellEnded
                    : context.l10n.sessionBannerShellEndedWith(detail),
                style: const TextStyle(fontSize: 13, height: 1.3),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(onPressed: onRestart, child: Text(context.l10n.sessionBannerRestart)),
            TextButton(onPressed: onClose, child: Text(context.l10n.sessionBannerClose)),
          ],
        ),
      ),
    );
  }
}
