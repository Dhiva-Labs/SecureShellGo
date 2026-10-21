import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/app_settings.dart';
import '../theme.dart';

/// The typefaces behind Settings > Terminal > Font.
class TerminalFonts {
  const TerminalFonts._();

  /// Declared in `pubspec.yaml`, from `assets/fonts/`.
  static const String jetBrainsMono = 'JetBrains Mono';

  static const String jetBrainsMonoLicence =
      'assets/fonts/JetBrainsMono-OFL.txt';

  /// The family to ask for.
  static String familyFor(TerminalFont font) => switch (font) {
        TerminalFont.system => AppTheme.monoFontFamily,
        TerminalFont.jetBrainsMono => jetBrainsMono,
      };

  /// What to fall back to for a character the family has no glyph for. The
  /// bundled font still falls back to the platform's monospace, so a glyph
  /// it lacks (Braille, most emoji) draws instead of a box.
  static List<String> fallbackFor(TerminalFont font) => switch (font) {
        TerminalFont.system => AppTheme.monoFontFamilyFallback,
        TerminalFont.jetBrainsMono => <String>[
            AppTheme.monoFontFamily,
            ...AppTheme.monoFontFamilyFallback,
          ],
      };

  static bool _registered = false;

  /// Adds the bundled font's licence to the app's licences page (Settings >
  /// About > Licences), which the SIL Open Font License asks for whenever the
  /// font is distributed. Idempotent.
  static void registerLicence({AssetBundle? bundle}) {
    if (_registered) return;
    _registered = true;
    LicenseRegistry.addLicense(() async* {
      final text = await (bundle ?? rootBundle).loadString(
        jetBrainsMonoLicence,
      );
      yield LicenseEntryWithLineBreaks(const [jetBrainsMono], text);
    });
  }
}
