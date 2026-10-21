import 'package:flutter/material.dart';

import '../../models/app_settings.dart';
import 'settings_section.dart';

/// Keyboard and touch input: when the terminal's row of extra keys shows.
class InputSettingsSection extends StatelessWidget {
  const InputSettingsSection({
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
        SettingsSectionHeader('Keyboard', style: settings.uiStyle),
        SettingsChoice<KeyBarMode>(
          label: 'Extra keys row',
          icon: Icons.keyboard_alt_outlined,
          value: settings.keyBarMode,
          values: KeyBarMode.values,
          labelOf: (m) => m.label,
          helper: switch (settings.keyBarMode) {
            KeyBarMode.auto => 'Esc, Tab, Ctrl and arrows over the on-screen '
                'keyboard. Hidden while a hardware keyboard is in use.',
            KeyBarMode.always => 'Shown even with a hardware keyboard.',
            KeyBarMode.never => 'Hidden. Ctrl and Esc then need a hardware '
                'keyboard.',
          },
          onChanged: (m) => apply((s) => s.copyWith(keyBarMode: m)),
        ),
      ],
    );
  }
}
