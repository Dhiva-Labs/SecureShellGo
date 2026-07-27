import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../theme.dart';

/// Sends a key through the terminal's input handler.
///
/// Routing via `Terminal.keyInput` rather than writing raw bytes matters:
/// arrows and Home/End have different encodings in normal vs. application
/// cursor mode, and the handler picks the right one for the current mode.
typedef TerminalKeyCallback = void Function(
  TerminalKey key, {
  bool ctrl,
  bool alt,
});

/// Sends literal text, as if it had been typed — for the punctuation keys
/// that are awkward to reach on some soft keyboard layouts.
typedef TerminalTextCallback = void Function(String text);

/// A row of keys Android soft keyboards do not offer but a shell needs.
///
/// [ctrlActive]/[onToggleCtrl] implement a *sticky* Ctrl: tapping "Ctrl"
/// arms it, and the next character typed on the device's own keyboard is
/// sent as that control code instead of literal text (`TerminalPane`
/// converts it in `_sendToShell`, since that is the one place every
/// keystroke — soft keyboard, hardware keyboard, or this bar — already
/// funnels through). The five `^`-prefixed buttons stay as one-tap
/// shortcuts for the combos used constantly enough to be worth not having
/// to arm-then-type. The arrow keys repeat on a long press, since scrolling
/// shell history a line at a time by re-tapping is the whole reason this bar
/// has arrows at all.
class TerminalKeyBar extends StatelessWidget {
  const TerminalKeyBar({
    super.key,
    required this.onKey,
    required this.onText,
    required this.ctrlActive,
    required this.onToggleCtrl,
    required this.onPaste,
  });

  final TerminalKeyCallback onKey;
  final TerminalTextCallback onText;
  final bool ctrlActive;
  final VoidCallback onToggleCtrl;

  /// Pastes the clipboard into the shell — the same action the selection
  /// toolbar's Paste button performs, offered here too since a selection is
  /// not always active when the user wants to paste.
  final VoidCallback onPaste;

  @override
  Widget build(BuildContext context) {
    final quickCombos = <_KeyEntry>[
      _KeyEntry('esc', TerminalKey.escape),
      _KeyEntry('tab', TerminalKey.tab),
      _KeyEntry('^C', TerminalKey.keyC, ctrl: true),
      _KeyEntry('^D', TerminalKey.keyD, ctrl: true),
      _KeyEntry('^Z', TerminalKey.keyZ, ctrl: true),
      _KeyEntry('^L', TerminalKey.keyL, ctrl: true),
      _KeyEntry('^R', TerminalKey.keyR, ctrl: true),
    ];
    const literalChars = ['|', '/', '-', '~'];
    final navigation = <_KeyEntry>[
      _KeyEntry('◀', TerminalKey.arrowLeft),
      _KeyEntry('▶', TerminalKey.arrowRight),
      _KeyEntry('▲', TerminalKey.arrowUp, repeatable: true),
      _KeyEntry('▼', TerminalKey.arrowDown, repeatable: true),
      _KeyEntry('home', TerminalKey.home),
      _KeyEntry('end', TerminalKey.end),
      _KeyEntry('pgup', TerminalKey.pageUp),
      _KeyEntry('pgdn', TerminalKey.pageDown),
    ];

    final buttons = <Widget>[
      for (final entry in quickCombos)
        _KeyButton(
          label: entry.label,
          onPressed: () => onKey(entry.key, ctrl: entry.ctrl, alt: false),
        ),
      _KeyButton(
        label: 'Ctrl',
        active: ctrlActive,
        onPressed: onToggleCtrl,
      ),
      _KeyButton(
        label: '⎘ Paste',
        onPressed: onPaste,
      ),
      for (final char in literalChars)
        _KeyButton(label: char, onPressed: () => onText(char)),
      for (final entry in navigation)
        _KeyButton(
          label: entry.label,
          repeatable: entry.repeatable,
          onPressed: () => onKey(entry.key, ctrl: entry.ctrl, alt: false),
        ),
    ];

    return Material(
      color: AppTheme.surface,
      child: SizedBox(
        // 48dp minimum touch target for every key, plus a little breathing
        // room above/below so they do not touch the terminal or the keyboard.
        height: 56,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          itemCount: buttons.length,
          separatorBuilder: (_, _) => const SizedBox(width: 6),
          itemBuilder: (context, index) => buttons[index],
        ),
      ),
    );
  }
}

class _KeyEntry {
  const _KeyEntry(this.label, this.key, {this.ctrl = false, this.repeatable = false});

  final String label;
  final TerminalKey key;
  final bool ctrl;

  /// Whether holding this key down repeats it — used for ↑/↓, the two keys
  /// worth holding to walk through shell history.
  final bool repeatable;
}

class _KeyButton extends StatefulWidget {
  const _KeyButton({
    required this.label,
    required this.onPressed,
    this.active = false,
    this.repeatable = false,
  });

  final String label;
  final VoidCallback onPressed;
  final bool active;
  final bool repeatable;

  @override
  State<_KeyButton> createState() => _KeyButtonState();
}

class _KeyButtonState extends State<_KeyButton> {
  Timer? _repeatTimer;

  void _fire() {
    HapticFeedback.lightImpact();
    widget.onPressed();
  }

  void _startRepeat() {
    _repeatTimer?.cancel();
    _repeatTimer = Timer.periodic(const Duration(milliseconds: 110), (_) {
      widget.onPressed();
    });
  }

  void _stopRepeat() {
    _repeatTimer?.cancel();
    _repeatTimer = null;
  }

  @override
  void dispose() {
    _stopRepeat();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget button = InkWell(
      onTap: _fire,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        constraints: const BoxConstraints(minWidth: 48),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: widget.active
              ? AppTheme.accent.withValues(alpha: 0.25)
              : AppTheme.terminalBackground,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: widget.active
                ? AppTheme.accent
                : Colors.white.withValues(alpha: 0.12),
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          widget.label,
          style: TextStyle(
            fontFamily: AppTheme.monoFontFamily,
            fontFamilyFallback: AppTheme.monoFontFamilyFallback,
            fontSize: 13,
            height: 1,
            color: widget.active ? AppTheme.accent : null,
            fontWeight: widget.active ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );

    if (widget.repeatable) {
      // A long press (which, by definition, requires the finger to stay
      // still) starts the repeat; a normal tap or a drag that turns into a
      // horizontal scroll of the bar never triggers it, so this cannot
      // fight the ListView's own gesture.
      button = GestureDetector(
        onLongPressStart: (_) {
          HapticFeedback.lightImpact();
          _startRepeat();
        },
        onLongPressEnd: (_) => _stopRepeat(),
        onLongPressCancel: _stopRepeat,
        child: button,
      );
    }

    return button;
  }
}
