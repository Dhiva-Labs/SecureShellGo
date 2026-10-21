import 'package:flutter/material.dart';

import '../../models/app_settings.dart';
import '../../theme.dart';

/// How a settings section changes a setting: shown at once, saved behind.
/// See `_SettingsScreenState._apply`.
typedef SettingsChange = Future<void> Function(
  AppSettings Function(AppSettings current) change,
);

/// A settings section title. Picks up [SectionHeaderChrome] for [style] —
/// aws's tinted bar, gcp's extra whitespace, azure's left accent stripe — so
/// Settings reads as the same system as the host list's own group headers,
/// not just a name in the app's stock text colour regardless of style.
class SettingsSectionHeader extends StatelessWidget {
  const SettingsSectionHeader(
    this.label, {
    super.key,
    this.style = UiStyle.aurora,
  });

  final String label;
  final UiStyle style;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chrome = AppTheme.sectionHeaderChromeFor(style, theme.colorScheme);

    final text = Text(
      label,
      style: theme.textTheme.labelLarge?.copyWith(
        color: theme.colorScheme.primary,
        fontWeight: FontWeight.w600,
      ),
    );

    final content = Padding(
      padding: EdgeInsets.fromLTRB(
        chrome.leftAccent != null ? 13 : 16,
        chrome.tight
            ? 10
            : chrome.airy
                ? 26
                : 20,
        16,
        4,
      ),
      child: chrome.leftAccent == null
          ? text
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(width: 3, height: 14, color: chrome.leftAccent),
                const SizedBox(width: 10),
                text,
              ],
            ),
    );

    if (chrome.background == null) return content;
    return ColoredBox(color: chrome.background!, child: content);
  }
}

/// One setting picked from a short list, as a full-width dropdown: unlike a
/// trailing one in a list tile it cannot run out of room for a long label
/// on a narrow phone with large text.
class SettingsChoice<T> extends StatelessWidget {
  const SettingsChoice({
    super.key,
    required this.label,
    required this.value,
    required this.values,
    required this.labelOf,
    required this.onChanged,
    this.icon,
    this.helper,
  });

  final String label;
  final T value;
  final List<T> values;
  final String Function(T value) labelOf;
  final ValueChanged<T> onChanged;
  final IconData? icon;
  final String? helper;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: DropdownButtonFormField<T>(
        // Keyed on the value so a change made elsewhere (a reload, a reset)
        // is shown rather than the field's own remembered pick.
        key: ValueKey(value),
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: icon == null ? null : Icon(icon),
          helperText: helper,
          helperMaxLines: 5,
        ),
        items: [
          for (final v in values)
            DropdownMenuItem(value: v, child: Text(labelOf(v))),
        ],
        onChanged: (picked) {
          if (picked != null && picked != value) onChanged(picked);
        },
      ),
    );
  }
}
