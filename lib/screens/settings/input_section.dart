import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/app_settings.dart';
import 'setting_labels.dart';
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
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSectionHeader(l10n.settingsKeyboard, style: settings.uiStyle),
        SettingsChoice<KeyBarMode>(
          label: l10n.settingsExtraKeys,
          icon: Icons.keyboard_alt_outlined,
          value: settings.keyBarMode,
          values: KeyBarMode.values,
          labelOf: (m) => m.labelIn(l10n),
          helper: switch (settings.keyBarMode) {
            KeyBarMode.auto => l10n.settingsExtraKeysAutoHelp,
            KeyBarMode.always => l10n.settingsExtraKeysAlwaysHelp,
            KeyBarMode.never => l10n.settingsExtraKeysNeverHelp,
          },
          onChanged: (m) => apply((s) => s.copyWith(keyBarMode: m)),
        ),
      ],
    );
  }
}
