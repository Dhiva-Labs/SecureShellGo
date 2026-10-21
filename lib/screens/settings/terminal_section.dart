import 'package:flutter/material.dart';

import '../../models/app_settings.dart';
import 'settings_section.dart';

/// The terminal's options beyond size and colours: history length, cursor,
/// bell and typeface. Sits under Settings' Terminal heading.
class TerminalOptionsSection extends StatelessWidget {
  const TerminalOptionsSection({
    super.key,
    required this.settings,
    required this.apply,
  });

  final AppSettings settings;
  final SettingsChange apply;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsChoice<TerminalFont>(
          label: 'Font',
          icon: Icons.font_download_outlined,
          value: settings.terminalFont,
          values: TerminalFont.values,
          labelOf: (f) => f.label,
          onChanged: (f) => apply((s) => s.copyWith(terminalFont: f)),
        ),
        SettingsChoice<TerminalCursorStyle>(
          label: 'Cursor',
          icon: Icons.text_fields,
          value: settings.cursorStyle,
          values: TerminalCursorStyle.values,
          labelOf: (c) => c.label,
          onChanged: (c) => apply((s) => s.copyWith(cursorStyle: c)),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.flare_outlined),
          title: const Text('Blinking cursor'),
          subtitle: const Text('Blinks while the terminal has the keyboard'),
          value: settings.cursorBlink,
          onChanged: (on) => apply((s) => s.copyWith(cursorBlink: on)),
        ),
        SettingsChoice<TerminalBell>(
          label: 'Bell',
          icon: Icons.notifications_none,
          value: settings.bell,
          values: TerminalBell.values,
          labelOf: (b) => b.label,
          onChanged: (b) => apply((s) => s.copyWith(bell: b)),
        ),
        SettingsChoice<int>(
          label: 'Scrollback',
          icon: Icons.history,
          value: settings.scrollbackLines,
          values: AppSettings.scrollbackChoices,
          labelOf: _lines,
          helper: 'Lines of history kept for each session, from the next '
              'session you open. More uses more memory per open session.',
          onChanged: (n) => apply((s) => s.copyWith(scrollbackLines: n)),
        ),
      ],
    );
  }

  static String _lines(int n) {
    final text = n.toString().replaceAllMapped(
          RegExp(r'\B(?=(\d{3})+$)'),
          (_) => ',',
        );
    return '$text lines';
  }
}
