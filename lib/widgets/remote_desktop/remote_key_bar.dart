import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../services/remote_desktop/csrd_keymap.dart';
import '../../theme.dart';
import 'remote_input_controller.dart';

/// The row of keys a phone's keyboard does not have, for the remote desktop:
/// Esc and Tab, Ctrl, Alt, Super and Shift that wait for the next key, the
/// arrows and paging keys, F1 to F12, and Ctrl+Alt+Del.
///
/// The idea is `TerminalKeyBar`'s, sent as key presses rather than terminal
/// escape sequences. Ctrl, Alt, Super and Shift are *sticky*: tapping one arms
/// it, and the next key sent, from this bar or the soft keyboard, goes with
/// it and uses it up (see `RemoteInputController.armed`). The keycaps are
/// labelled as keycaps are, the same in every language, as the terminal's
/// are. Holding an arrow, a paging key or Delete holds the key down and the
/// remote repeats it.
class RemoteKeyBar extends StatelessWidget {
  const RemoteKeyBar({
    super.key,
    required this.input,
    required this.keyboardOpen,
    required this.onToggleKeyboard,
  });

  final RemoteInputController input;

  /// Whether the soft keyboard is up, for the icon of its button.
  final bool keyboardOpen;
  final VoidCallback onToggleKeyboard;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      // Tapping a key must leave the viewer where it is: its focus is what
      // sends the hardware keyboard, and a button that took it would drop it.
      child: ExcludeFocus(
        child: SizedBox(
          height: 56,
          child: ListenableBuilder(
            listenable: input,
            builder: (context, _) {
              final armed = input.armed;
              final keys = <Widget>[
                _tap('Esc', CsrdEvdev.keyEsc),
                _tap('Tab', CsrdEvdev.keyTab),
                for (final (label, modifier) in const [
                  ('Ctrl', RemoteModifier.ctrl),
                  ('Alt', RemoteModifier.alt),
                  ('Super', RemoteModifier.meta),
                  ('Shift', RemoteModifier.shift),
                ])
                  _KeyButton(
                    label: label,
                    active: armed.contains(modifier),
                    onPressed: () => input.toggleModifier(modifier),
                  ),
                _tap('◀', CsrdEvdev.keyLeft, hold: true),
                _tap('▼', CsrdEvdev.keyDown, hold: true),
                _tap('▲', CsrdEvdev.keyUp, hold: true),
                _tap('▶', CsrdEvdev.keyRight, hold: true),
                _tap('Home', CsrdEvdev.keyHome),
                _tap('End', CsrdEvdev.keyEnd),
                _tap('PgUp', CsrdEvdev.keyPageUp, hold: true),
                _tap('PgDn', CsrdEvdev.keyPageDown, hold: true),
                _tap('Del', CsrdEvdev.keyDelete, hold: true),
                _FunctionKeys(
                  tooltip: l10n.remoteDesktopFunctionKeys,
                  onPressed: (code) => input.tapKey(code),
                ),
                _KeyButton(
                  label: 'Ctrl+Alt+Del',
                  onPressed: () => input.tapKey(
                    CsrdEvdev.keyDelete,
                    modifiers: const [RemoteModifier.ctrl, RemoteModifier.alt],
                  ),
                ),
              ];
              return Row(
                children: [
                  Expanded(
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      itemCount: keys.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 6),
                      itemBuilder: (_, i) => keys[i],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: IconButton(
                      constraints: const BoxConstraints(
                        minWidth: 48,
                        minHeight: 48,
                      ),
                      tooltip: keyboardOpen
                          ? l10n.remoteDesktopHideKeyboard
                          : l10n.remoteDesktopShowKeyboard,
                      icon: Icon(
                        keyboardOpen ? Icons.keyboard_hide : Icons.keyboard,
                      ),
                      onPressed: () {
                        _haptic();
                        onToggleKeyboard();
                      },
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _tap(String label, int code, {bool hold = false}) => _KeyButton(
    label: label,
    onPressed: () => input.tapKey(code),
    onHoldStart: hold ? () => input.holdKey(code) : null,
    onHoldEnd: hold ? () => input.releaseKey(code) : null,
  );
}

void _haptic() {
  unawaited(HapticFeedback.lightImpact().catchError((Object _) {}));
}

class _FunctionKeys extends StatelessWidget {
  const _FunctionKeys({required this.tooltip, required this.onPressed});

  final String tooltip;
  final void Function(int evdev) onPressed;

  static const _codes = [
    CsrdEvdev.keyF1,
    CsrdEvdev.keyF2,
    CsrdEvdev.keyF3,
    CsrdEvdev.keyF4,
    CsrdEvdev.keyF5,
    CsrdEvdev.keyF6,
    CsrdEvdev.keyF7,
    CsrdEvdev.keyF8,
    CsrdEvdev.keyF9,
    CsrdEvdev.keyF10,
    CsrdEvdev.keyF11,
    CsrdEvdev.keyF12,
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopupMenuButton<int>(
      tooltip: tooltip,
      onOpened: _haptic,
      onSelected: onPressed,
      itemBuilder: (_) => [
        for (var i = 0; i < _codes.length; i++)
          PopupMenuItem<int>(value: _codes[i], child: Text('F${i + 1}')),
      ],
      child: _KeyFace(label: 'F1–12', active: false, theme: theme),
    );
  }
}

class _KeyButton extends StatelessWidget {
  const _KeyButton({
    required this.label,
    required this.onPressed,
    this.active = false,
    this.onHoldStart,
    this.onHoldEnd,
  });

  final String label;
  final bool active;
  final VoidCallback onPressed;

  /// Holding the key: pressed on a long press and let go when the finger
  /// is. Set for the keys worth repeating.
  final VoidCallback? onHoldStart;
  final VoidCallback? onHoldEnd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget button = InkWell(
      onTap: () {
        _haptic();
        onPressed();
      },
      borderRadius: BorderRadius.circular(6),
      child: _KeyFace(label: label, active: active, theme: theme),
    );
    if (onHoldStart != null) {
      // A long press needs the finger to stay put, so it cannot fight the
      // bar's own horizontal scroll.
      button = GestureDetector(
        onLongPressStart: (_) {
          _haptic();
          onHoldStart!();
        },
        onLongPressEnd: (_) => onHoldEnd?.call(),
        onLongPressCancel: () => onHoldEnd?.call(),
        child: button,
      );
    }
    return Semantics(button: true, selected: active, child: button);
  }
}

class _KeyFace extends StatelessWidget {
  const _KeyFace({
    required this.label,
    required this.active,
    required this.theme,
  });

  final String label;
  final bool active;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Container(
      // 48dp is the least a thumb can be asked to hit.
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: active
            ? theme.colorScheme.primary.withValues(alpha: 0.25)
            : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: active
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurface.withValues(alpha: 0.12),
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: TextStyle(
          fontFamily: AppTheme.monoFontFamily,
          fontFamilyFallback: AppTheme.monoFontFamilyFallback,
          fontSize: 13,
          height: 1,
          color: active ? theme.colorScheme.primary : null,
          fontWeight: active ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
    );
  }
}
