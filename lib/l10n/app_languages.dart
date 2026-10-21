import 'package:flutter/widgets.dart';

/// The languages the app is translated into, by the tag Settings stores in
/// `AppSettings.localeOverride`, each named the way its own speakers write
/// it — someone who cannot read the current language must still find theirs.
///
/// Simplified Chinese and Brazilian Portuguese are the `zh` and `pt`
/// translations; there is no second variant of either yet.
const List<({String tag, String name})> appLanguages = [
  (tag: 'en', name: 'English'),
  (tag: 'zh', name: '简体中文'),
  (tag: 'ja', name: '日本語'),
  (tag: 'pt', name: 'Português (Brasil)'),
  (tag: 'es', name: 'Español'),
  (tag: 'ru', name: 'Русский'),
  (tag: 'de', name: 'Deutsch'),
  (tag: 'ko', name: '한국어'),
  (tag: 'fr', name: 'Français'),
];

/// The locale for a stored tag, or null to follow the device (no override,
/// or a tag this build has no translation for — say, one a later version
/// wrote).
Locale? localeForTag(String? tag) {
  if (tag == null) return null;
  for (final language in appLanguages) {
    if (language.tag == tag) return Locale(tag);
  }
  return null;
}
