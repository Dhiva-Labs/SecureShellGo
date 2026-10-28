import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/app_settings.dart';
import 'settings_section.dart';

/// The app's language: the device's, or one picked here.
class LanguageSettingsSection extends StatelessWidget {
  const LanguageSettingsSection({
    super.key,
    required this.settings,
    required this.apply,
  });

  final AppSettings settings;
  final SettingsChange apply;

  /// "Same as this device", as a value the dropdown can hold.
  static const String _device = '';

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final current = localeForTag(settings.localeOverride) == null
        ? _device
        : settings.localeOverride!;
    return SettingsChoice<String>(
      label: l10n.languageLabel,
      icon: Icons.translate,
      value: current,
      values: [_device, for (final language in appLanguages) language.tag],
      labelOf: (tag) => tag == _device
          ? l10n.languageSystem
          : appLanguages.firstWhere((l) => l.tag == tag).name,
      helper: l10n.languageHelp,
      onChanged: (tag) => apply(
        (s) => s.withLocaleOverride(tag == _device ? null : tag),
      ),
    );
  }
}
