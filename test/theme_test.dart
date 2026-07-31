import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/app_settings.dart';
import 'package:secure_shell_go/theme.dart';

void main() {
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
