import 'package:flutter/widgets.dart';

import 'app_localizations.dart';

export 'app_languages.dart';
export 'app_localizations.dart';

extension AppLocalizationsOf on BuildContext {
  /// This app's strings in the current language — `context.l10n.someKey`.
  ///
  /// English when no translations are installed above, as in a widget
  /// test's bare MaterialApp, so a screen renders the same with or without
  /// each test wiring up the delegates.
  AppLocalizations get l10n =>
      AppLocalizations.of(this) ?? lookupAppLocalizations(const Locale('en'));
}
