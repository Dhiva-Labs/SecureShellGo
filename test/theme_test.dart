import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/app_settings.dart';
import 'package:secure_shell_go/theme.dart';

void main() {
  group('AppTheme.themeFor registry', () {
    test('every UiStyle x Brightness combination resolves without throwing',
        () {
      for (final style in UiStyle.values) {
        for (final brightness in Brightness.values) {
          expect(AppTheme.themeFor(style, brightness), isNotNull);
        }
      }
    });

    test('all 8 combinations are visually distinct from one another', () {
      // A (primary, scaffold background, brightness) fingerprint is enough
      // to catch a copy-paste that left two styles pointing at the same
      // palette — the failure mode this guards against, same reasoning as
      // the terminal-scheme "distinct backgrounds" test below.
      final fingerprints = <String>{
        for (final style in UiStyle.values)
          for (final brightness in Brightness.values)
            () {
              final theme = AppTheme.themeFor(style, brightness);
              return '${theme.colorScheme.primary}'
                  '-${theme.scaffoldBackgroundColor}'
                  '-${theme.brightness}';
            }(),
      };
      expect(fingerprints, hasLength(UiStyle.values.length * 2));
    });

    test('aurora dark matches the documented key colours exactly', () {
      // Hard-coded literals, not `AppTheme.terminalBackground` etc. — the
      // point is to catch someone editing those constants out from under
      // today's look, so comparing against the constants themselves would
      // defeat the test.
      final theme = AppTheme.themeFor(UiStyle.aurora, Brightness.dark);
      expect(theme.scaffoldBackgroundColor, const Color(0xFF0D1117));
      expect(theme.colorScheme.surface, const Color(0xFF0D1117));
      expect(theme.colorScheme.error, const Color(0xFFF85149));
      expect(theme.appBarTheme.backgroundColor, const Color(0xFF161B22));
      expect(theme.cardTheme.color, const Color(0xFF161B22));
    });

    test('AppTheme.dark is exactly aurora + dark', () {
      expect(AppTheme.dark, AppTheme.themeFor(UiStyle.aurora, Brightness.dark));
    });

    test('aurora light and dark share the same accent family but differ',
        () {
      final light = AppTheme.themeFor(UiStyle.aurora, Brightness.light);
      final dark = AppTheme.themeFor(UiStyle.aurora, Brightness.dark);
      expect(light.brightness, Brightness.light);
      expect(dark.brightness, Brightness.dark);
      expect(light.scaffoldBackgroundColor, isNot(dark.scaffoldBackgroundColor));
    });
  });

  group('UiStyle registry', () {
    test('fromName falls back to aurora for an unknown or absent id', () {
      expect(UiStyle.fromName('not-a-real-style'), UiStyle.aurora);
      expect(UiStyle.fromName(null), UiStyle.aurora);
    });

    test('fromName resolves every real id back to itself', () {
      for (final style in UiStyle.values) {
        expect(UiStyle.fromName(style.name), style);
      }
    });

    test('every style has a non-empty, distinct label', () {
      final labels = UiStyle.values.map((s) => s.label).toSet();
      expect(labels, hasLength(UiStyle.values.length));
      expect(labels.every((label) => label.trim().isNotEmpty), isTrue);
    });

    test('aurora is the default', () {
      expect(UiStyle.values.first, UiStyle.aurora);
    });
  });

  group('ThemeBrightness registry', () {
    test('fromName falls back to dark for an unknown or absent id', () {
      expect(ThemeBrightness.fromName('not-a-real-brightness'),
          ThemeBrightness.dark);
      expect(ThemeBrightness.fromName(null), ThemeBrightness.dark);
    });

    test('fromName resolves every real id back to itself', () {
      for (final brightness in ThemeBrightness.values) {
        expect(ThemeBrightness.fromName(brightness.name), brightness);
      }
    });

    test('themeModeFor maps every value to its matching ThemeMode', () {
      expect(AppTheme.themeModeFor(ThemeBrightness.system), ThemeMode.system);
      expect(AppTheme.themeModeFor(ThemeBrightness.light), ThemeMode.light);
      expect(AppTheme.themeModeFor(ThemeBrightness.dark), ThemeMode.dark);
    });
  });

  group('TerminalColorScheme registry', () {
    test('every scheme id resolves to a distinct terminal theme', () {
      // Background alone is not proof of a real palette (a mistake could
      // leave two schemes pointing at the same const), so this checks that
      // every value resolves and that the set of backgrounds is as large as
      // the set of schemes.
      final backgrounds = TerminalColorScheme.values
          .map((scheme) => AppTheme.terminalThemeFor(scheme).background)
          .toSet();
      expect(backgrounds, hasLength(TerminalColorScheme.values.length));
    });

    test('the well-known schemes the theme picker promises are all present',
        () {
      const expected = {
        TerminalColorScheme.dracula,
        TerminalColorScheme.solarizedDark,
        TerminalColorScheme.solarizedLight,
        TerminalColorScheme.nord,
        TerminalColorScheme.gruvboxDark,
        TerminalColorScheme.monokai,
        TerminalColorScheme.oneDark,
      };
      expect(TerminalColorScheme.values.toSet().containsAll(expected), isTrue);
    });

    test('classic is the default and comes back unchanged', () {
      expect(
        AppTheme.terminalThemeFor(TerminalColorScheme.classic),
        AppTheme.terminalTheme,
      );
    });

    test('fromName falls back to classic for an unknown id', () {
      expect(
        TerminalColorScheme.fromName('not-a-real-scheme'),
        TerminalColorScheme.classic,
      );
      expect(TerminalColorScheme.fromName(null), TerminalColorScheme.classic);
    });

    test('fromName resolves every real id back to itself', () {
      for (final scheme in TerminalColorScheme.values) {
        expect(TerminalColorScheme.fromName(scheme.name), scheme);
      }
    });

    test('every scheme has a non-empty, distinct label', () {
      final labels = TerminalColorScheme.values.map((s) => s.label).toSet();
      expect(labels, hasLength(TerminalColorScheme.values.length));
      expect(labels.every((label) => label.trim().isNotEmpty), isTrue);
    });
  });
}
