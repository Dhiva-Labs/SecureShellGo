import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../services/remote_desktop/csrd_client.dart';
import '../../services/remote_desktop/csrd_messages.dart';
import '../../services/remote_desktop/remote_input_touch.dart';
import '../../services/remote_desktop/remote_input_view.dart';

/// The least a thumb can be asked to hit, whatever the app's density.
const BoxConstraints _target = BoxConstraints(minWidth: 48, minHeight: 48);

/// The strip of controls under the remote desktop's title bar.
///
/// It scrolls sideways when it does not fit, which on a phone it does not:
/// every control is a 48dp target, and there are nine. What shows depends
/// on the session: the display picker only with more than one display, the
/// quality picker only for a protocol that has quality to pick, the input
/// mode only where fingers are the pointer.
class RemoteToolbar extends StatelessWidget {
  const RemoteToolbar({
    super.key,
    required this.displays,
    required this.display,
    required this.onSelectDisplay,
    required this.supportsQuality,
    required this.quality,
    required this.onSelectQuality,
    required this.viewOnly,
    required this.viewOnlyLocked,
    required this.onToggleViewOnly,
    required this.clipboardSync,
    required this.onToggleClipboardSync,
    required this.onPasteToRemote,
    required this.viewMode,
    required this.onToggleViewMode,
    required this.keyBarVisible,
    required this.onToggleKeyBar,
    required this.showTouchMode,
    required this.touchMode,
    required this.onToggleTouchMode,
    required this.showReleaseKeyboard,
    required this.keyboardCaptured,
    required this.onReleaseKeyboard,
  });

  final List<CsrdDisplayInfo> displays;
  final int? display;
  final void Function(int display) onSelectDisplay;

  final bool supportsQuality;
  final CsrdQuality quality;
  final void Function(CsrdQuality quality) onSelectQuality;

  final bool viewOnly;
  final bool viewOnlyLocked;
  final VoidCallback onToggleViewOnly;

  final bool clipboardSync;
  final VoidCallback onToggleClipboardSync;
  final VoidCallback onPasteToRemote;

  final RemoteViewMode viewMode;
  final VoidCallback onToggleViewMode;

  final bool keyBarVisible;
  final VoidCallback onToggleKeyBar;

  final bool showTouchMode;
  final RemoteTouchMode touchMode;
  final VoidCallback onToggleTouchMode;

  final bool showReleaseKeyboard;

  /// Whether the viewer has the keyboard, so keys are going to the remote.
  final bool keyboardCaptured;
  final VoidCallback onReleaseKeyboard;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: SizedBox(
        height: 52,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          children: [
            if (displays.length > 1)
              PopupMenuButton<int>(
                padding: const EdgeInsets.all(12),
                tooltip: l10n.remoteDesktopDisplay,
                icon: const Icon(Icons.desktop_windows_outlined),
                initialValue: display,
                onSelected: onSelectDisplay,
                itemBuilder: (_) => [
                  for (final d in displays)
                    CheckedPopupMenuItem<int>(
                      value: d.index,
                      checked: d.index == display,
                      child: Text(_displayLabel(context, d)),
                    ),
                ],
              ),
            if (supportsQuality)
              PopupMenuButton<CsrdQuality>(
                padding: const EdgeInsets.all(12),
                tooltip: l10n.remoteDesktopQuality,
                icon: const Icon(Icons.high_quality_outlined),
                initialValue: quality,
                onSelected: onSelectQuality,
                itemBuilder: (_) => [
                  for (final q in CsrdQuality.values)
                    CheckedPopupMenuItem<CsrdQuality>(
                      value: q,
                      checked: q == quality,
                      child: Text(switch (q) {
                        CsrdQuality.lossless =>
                          l10n.remoteDesktopQualityLossless,
                        CsrdQuality.balanced =>
                          l10n.remoteDesktopQualityBalanced,
                        CsrdQuality.speed => l10n.remoteDesktopQualitySpeed,
                      }),
                    ),
                ],
              ),
            IconButton(
              constraints: _target,
              tooltip: viewOnlyLocked
                  ? l10n.remoteDesktopViewOnlyLocked
                  : l10n.remoteDesktopViewOnly,
              isSelected: viewOnly,
              icon: const Icon(Icons.visibility_off_outlined),
              selectedIcon: const Icon(Icons.visibility),
              // A session started view-only has no input channel at all, so
              // the button is left in view with a reason rather than removed.
              onPressed: viewOnlyLocked ? null : onToggleViewOnly,
            ),
            IconButton(
              constraints: _target,
              tooltip: l10n.remoteDesktopClipboardSync,
              isSelected: clipboardSync,
              icon: const Icon(Icons.content_paste_off_outlined),
              selectedIcon: const Icon(Icons.sync_alt),
              onPressed: onToggleClipboardSync,
            ),
            IconButton(
              constraints: _target,
              tooltip: l10n.remoteDesktopPasteToRemote,
              icon: const Icon(Icons.content_paste_go),
              onPressed: viewOnly ? null : onPasteToRemote,
            ),
            IconButton(
              constraints: _target,
              tooltip: viewMode == RemoteViewMode.fit
                  ? l10n.remoteDesktopActualSize
                  : l10n.remoteDesktopFitToWindow,
              icon: Icon(
                viewMode == RemoteViewMode.fit
                    ? Icons.looks_one_outlined
                    : Icons.fit_screen_outlined,
              ),
              onPressed: onToggleViewMode,
            ),
            IconButton(
              constraints: _target,
              tooltip: keyBarVisible
                  ? l10n.remoteDesktopHideKeyBar
                  : l10n.remoteDesktopShowKeyBar,
              isSelected: keyBarVisible,
              icon: const Icon(Icons.keyboard_alt_outlined),
              selectedIcon: const Icon(Icons.keyboard_alt),
              onPressed: onToggleKeyBar,
            ),
            if (showTouchMode)
              IconButton(
                constraints: _target,
                tooltip: touchMode == RemoteTouchMode.trackpad
                    ? l10n.remoteDesktopSwitchToDirect
                    : l10n.remoteDesktopSwitchToTrackpad,
                icon: Icon(
                  touchMode == RemoteTouchMode.trackpad
                      ? Icons.mouse_outlined
                      : Icons.touch_app_outlined,
                ),
                onPressed: onToggleTouchMode,
              ),
            if (showReleaseKeyboard)
              IconButton(
                constraints: _target,
                tooltip: l10n.remoteDesktopReleaseKeyboard,
                isSelected: keyboardCaptured,
                icon: const Icon(Icons.pan_tool_outlined),
                selectedIcon: const Icon(Icons.pan_tool),
                // Nothing to release once the viewer has let go.
                onPressed: keyboardCaptured ? onReleaseKeyboard : null,
              ),
          ],
        ),
      ),
    );
  }

  static String _displayLabel(BuildContext context, CsrdDisplayInfo d) {
    final l10n = context.l10n;
    final name = d.name.trim().isEmpty
        ? l10n.remoteDesktopDisplayNumbered(d.index + 1)
        : d.name;
    return l10n.remoteDesktopDisplayItem(name, d.width, d.height);
  }
}
