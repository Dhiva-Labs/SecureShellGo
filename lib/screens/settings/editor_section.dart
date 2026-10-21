import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/app_settings.dart';
import 'settings_section.dart';

/// The remote file editor's text size — also what zooming the editor sets.
class EditorSettingsSection extends StatefulWidget {
  const EditorSettingsSection({
    super.key,
    required this.settings,
    required this.apply,
  });

  final AppSettings settings;
  final SettingsChange apply;

  @override
  State<EditorSettingsSection> createState() => _EditorSettingsSectionState();
}

class _EditorSettingsSectionState extends State<EditorSettingsSection> {
  /// The size under the thumb while it is dragged; saved only on release, so
  /// dragging does not write to disk on every frame.
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final size = _dragging ?? widget.settings.editorFontSize;
    final points = l10n.settingsPointSize(size.round());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSectionHeader(
          l10n.settingsEditor,
          style: widget.settings.uiStyle,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  l10n.settingsTextSize,
                  style: theme.textTheme.bodyLarge,
                ),
              ),
              Text(
                points,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Slider(
            value: size,
            min: AppSettings.minEditorFontSize,
            max: AppSettings.maxEditorFontSize,
            divisions: (AppSettings.maxEditorFontSize -
                    AppSettings.minEditorFontSize)
                .round(),
            label: points,
            onChanged: (value) => setState(() => _dragging = value),
            onChangeEnd: (value) {
              setState(() => _dragging = null);
              widget.apply((s) => s.copyWith(editorFontSize: value));
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text(
            l10n.settingsEditorZoomHint('Ctrl +', 'Ctrl −'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}
