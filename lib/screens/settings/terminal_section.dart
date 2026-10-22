import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/app_settings.dart';
import 'setting_labels.dart';
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
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsChoice<TerminalFont>(
          label: l10n.settingsFont,
          icon: Icons.font_download_outlined,
          value: settings.terminalFont,
          values: TerminalFont.values,
          labelOf: (f) => f.labelIn(l10n),
          onChanged: (f) => apply((s) => s.copyWith(terminalFont: f)),
        ),
        SettingsChoice<TerminalCursorStyle>(
          label: l10n.settingsCursor,
          icon: Icons.text_fields,
          value: settings.cursorStyle,
          values: TerminalCursorStyle.values,
          labelOf: (c) => c.labelIn(l10n),
          onChanged: (c) => apply((s) => s.copyWith(cursorStyle: c)),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.flare_outlined),
          title: Text(l10n.settingsCursorBlink),
          subtitle: Text(l10n.settingsCursorBlinkHelp),
          value: settings.cursorBlink,
          onChanged: (on) => apply((s) => s.copyWith(cursorBlink: on)),
        ),
        SettingsChoice<TerminalBell>(
          label: l10n.settingsBell,
          icon: Icons.notifications_none,
          value: settings.bell,
          values: TerminalBell.values,
          labelOf: (b) => b.labelIn(l10n),
          onChanged: (b) => apply((s) => s.copyWith(bell: b)),
        ),
        SettingsChoice<int>(
          label: l10n.settingsScrollback,
          icon: Icons.history,
          value: settings.scrollbackLines,
          values: AppSettings.scrollbackChoices,
          labelOf: l10n.settingsScrollbackLines,
          helper: l10n.settingsScrollbackHelp,
          onChanged: (n) => apply((s) => s.copyWith(scrollbackLines: n)),
        ),
      ],
    );
  }
}
