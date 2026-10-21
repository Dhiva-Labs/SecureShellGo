import 'package:flutter/material.dart';

import '../../models/app_settings.dart';
import 'settings_section.dart';

/// The local diagnostics log a bug report can be built from.
class DiagnosticsSettingsSection extends StatelessWidget {
  const DiagnosticsSettingsSection({
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
        SettingsSectionHeader('Diagnostics', style: settings.uiStyle),
        SwitchListTile(
          secondary: const Icon(Icons.bug_report_outlined),
          title: const Text('Keep a diagnostics log'),
          subtitle: const Text(
            'Records errors and crashes on this device, with passwords and '
            'keys removed, for you to copy into a bug report. Nothing is '
            'sent anywhere.',
          ),
          value: settings.diagnosticsLog,
          onChanged: (on) => apply((s) => s.copyWith(diagnosticsLog: on)),
        ),
      ],
    );
  }
}
