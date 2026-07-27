import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import 'models/app_settings.dart';

/// Terminal-appropriate Material 3 dark theme.
///
/// The palette is deliberately close to a Linux terminal: near-black surfaces,
/// a green accent for "connected" affordances, red reserved for danger (host
/// key changes, disconnect).
class AppTheme {
  const AppTheme._();

  static const Color terminalBackground = Color(0xFF0D1117);
  static const Color surface = Color(0xFF161B22);
  static const Color accent = Color(0xFF3FB950);
  static const Color danger = Color(0xFFF85149);

  static const String monoFontFamily = 'monospace';
  static const List<String> monoFontFamilyFallback = <String>[
    'monospace',
    'Roboto Mono',
    'Droid Sans Mono',
  ];

  static ThemeData get dark {
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.dark,
    ).copyWith(
      surface: terminalBackground,
      error: danger,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: terminalBackground,
      appBarTheme: const AppBarTheme(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
        filled: true,
        fillColor: surface,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
        ),
      ),
      // The default (`BoxConstraints(minWidth: 280)`, no cap) lets a dialog
      // balloon out to nearly the full window width on a tablet or DeX
      // window — visible on the host-key TOFU/MITM dialog and the delete
      // confirms, both of which have full-bleed containers inside that would
      // otherwise stretch with it. One constraint here covers every
      // `AlertDialog`/`SimpleDialog` in the app; a phone's width is already
      // under 560dp so this is a no-op there. Security dialog *semantics* are
      // untouched — this only bounds their width.
      dialogTheme: const DialogThemeData(
        backgroundColor: surface,
        constraints: BoxConstraints(minWidth: 280, maxWidth: 560),
      ),
      cardTheme: const CardThemeData(color: surface),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// Colours used inside the xterm view. Tuned to match [terminalBackground].
  static const TerminalTheme terminalTheme = TerminalTheme(
    cursor: Color(0xFF3FB950),
    selection: Color(0x553FB950),
    foreground: Color(0xFFC9D1D9),
    background: terminalBackground,
    black: Color(0xFF484F58),
    red: Color(0xFFFF7B72),
    green: Color(0xFF3FB950),
    yellow: Color(0xFFD29922),
    blue: Color(0xFF58A6FF),
    magenta: Color(0xFFBC8CFF),
    cyan: Color(0xFF39C5CF),
    white: Color(0xFFB1BAC4),
    brightBlack: Color(0xFF6E7681),
    brightRed: Color(0xFFFFA198),
    brightGreen: Color(0xFF56D364),
    brightYellow: Color(0xFFE3B341),
    brightBlue: Color(0xFF79C0FF),
    brightMagenta: Color(0xFFD2A8FF),
    brightCyan: Color(0xFF56D4DD),
    brightWhite: Color(0xFFF0F6FC),
    searchHitBackground: Color(0xFFD29922),
    searchHitBackgroundCurrent: Color(0xFFE3B341),
    searchHitForeground: Color(0xFF0D1117),
  );

  /// Resolves a user-chosen [TerminalColorScheme] to the xterm palette it
  /// names. Kept here — not on the enum in `models/app_settings.dart` — so
  /// that `models/` stays free of the `xterm` import, matching the
  /// dependency rule in ARCHITECTURE.md.
  static TerminalTheme terminalThemeFor(TerminalColorScheme scheme) {
    return switch (scheme) {
      TerminalColorScheme.classic => terminalTheme,
      TerminalColorScheme.solarizedDark => _solarizedDark,
      TerminalColorScheme.monokai => _monokai,
      TerminalColorScheme.blackOnWhite => _blackOnWhite,
      TerminalColorScheme.retroGreen => _retroGreen,
    };
  }

  static const TerminalTheme _solarizedDark = TerminalTheme(
    cursor: Color(0xFF93A1A1),
    selection: Color(0x55586E75),
    foreground: Color(0xFF839496),
    background: Color(0xFF002B36),
    black: Color(0xFF073642),
    red: Color(0xFFDC322F),
    green: Color(0xFF859900),
    yellow: Color(0xFFB58900),
    blue: Color(0xFF268BD2),
    magenta: Color(0xFFD33682),
    cyan: Color(0xFF2AA198),
    white: Color(0xFFEEE8D5),
    brightBlack: Color(0xFF586E75),
    brightRed: Color(0xFFCB4B16),
    brightGreen: Color(0xFF657B83),
    brightYellow: Color(0xFF839496),
    brightBlue: Color(0xFF6C71C4),
    brightMagenta: Color(0xFF93A1A1),
    brightCyan: Color(0xFFD33682),
    brightWhite: Color(0xFFFDF6E3),
    searchHitBackground: Color(0xFFB58900),
    searchHitBackgroundCurrent: Color(0xFFCB4B16),
    searchHitForeground: Color(0xFF002B36),
  );

  static const TerminalTheme _monokai = TerminalTheme(
    cursor: Color(0xFFF8F8F0),
    selection: Color(0x55494A45),
    foreground: Color(0xFFF8F8F2),
    background: Color(0xFF272822),
    black: Color(0xFF272822),
    red: Color(0xFFF92672),
    green: Color(0xFFA6E22E),
    yellow: Color(0xFFE6DB74),
    blue: Color(0xFF66D9EF),
    magenta: Color(0xFFAE81FF),
    cyan: Color(0xFFA1EFE4),
    white: Color(0xFFF8F8F2),
    brightBlack: Color(0xFF75715E),
    brightRed: Color(0xFFF92672),
    brightGreen: Color(0xFFA6E22E),
    brightYellow: Color(0xFFE6DB74),
    brightBlue: Color(0xFF66D9EF),
    brightMagenta: Color(0xFFAE81FF),
    brightCyan: Color(0xFFA1EFE4),
    brightWhite: Color(0xFFF9F8F5),
    searchHitBackground: Color(0xFFE6DB74),
    searchHitBackgroundCurrent: Color(0xFFF92672),
    searchHitForeground: Color(0xFF272822),
  );

  /// Plain black-on-white, for reading long output in bright light.
  static const TerminalTheme _blackOnWhite = TerminalTheme(
    cursor: Color(0xFF000000),
    selection: Color(0x33000000),
    foreground: Color(0xFF000000),
    background: Color(0xFFFFFFFF),
    black: Color(0xFF000000),
    red: Color(0xFFC91B00),
    green: Color(0xFF00A600),
    yellow: Color(0xFF999900),
    blue: Color(0xFF0225C7),
    magenta: Color(0xFFC930C7),
    cyan: Color(0xFF00A6B2),
    white: Color(0xFFBFBFBF),
    brightBlack: Color(0xFF676767),
    brightRed: Color(0xFFC13900),
    brightGreen: Color(0xFF00CD00),
    brightYellow: Color(0xFF999900),
    brightBlue: Color(0xFF0033D6),
    brightMagenta: Color(0xFFC930C7),
    brightCyan: Color(0xFF00A6B2),
    brightWhite: Color(0xFF4D4D4D),
    searchHitBackground: Color(0xFFFFF3A0),
    searchHitBackgroundCurrent: Color(0xFFFFD966),
    searchHitForeground: Color(0xFF000000),
  );

  /// Classic green-phosphor CRT look. ANSI hues stay distinguishable but are
  /// pulled toward green, in the spirit of a monochrome amber/green terminal
  /// rather than a literally single-colour one (which would make coloured
  /// tool output like `ls`/`git diff` unreadable).
  static const TerminalTheme _retroGreen = TerminalTheme(
    cursor: Color(0xFF33FF33),
    selection: Color(0x5533FF33),
    foreground: Color(0xFF33FF33),
    background: Color(0xFF001100),
    black: Color(0xFF001A00),
    red: Color(0xFF1A661A),
    green: Color(0xFF33FF33),
    yellow: Color(0xFF66FF66),
    blue: Color(0xFF1A8C4D),
    magenta: Color(0xFF33CC66),
    cyan: Color(0xFF66FF99),
    white: Color(0xFF99FF99),
    brightBlack: Color(0xFF226622),
    brightRed: Color(0xFF33CC33),
    brightGreen: Color(0xFF66FF66),
    brightYellow: Color(0xFF99FF99),
    brightBlue: Color(0xFF33FF33),
    brightMagenta: Color(0xFF66FF66),
    brightCyan: Color(0xFF99FFCC),
    brightWhite: Color(0xFFCCFFCC),
    searchHitBackground: Color(0xFF66FF66),
    searchHitBackgroundCurrent: Color(0xFF99FF99),
    searchHitForeground: Color(0xFF001100),
  );
}
