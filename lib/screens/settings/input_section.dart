import 'package:flutter/material.dart';

import '../../models/app_settings.dart';
import 'settings_section.dart';

/// Keyboard and touch input: when the terminal's and the editor's rows of
/// extra keys show. What "a hardware keyboard is in use" means is worked out
/// in `services/input_profile.dart`.
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
                'keyboard, in the terminal and the editor. Hidden while a '
                'hardware keyboard is in use, and back when the on-screen '
                'one opens.',
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
