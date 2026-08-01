import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import 'models/app_settings.dart';
import 'models/host.dart';
import 'models/syntax_token.dart';

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

  /// Pre-1.4.0 call sites (and `theme_test.dart`'s exact-constant assertions)
  /// go through here; it is [UiStyle.aurora] + dark, unchanged.
  static ThemeData get dark => _auroraDark();

  /// Resolves a [UiStyle] + [Brightness] pair to the [ThemeData] for it — the
  /// one entry point `main.dart` and the settings previews use, so all 8
  /// combinations are built in exactly one place each.
  static ThemeData themeFor(UiStyle style, Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    return switch (style) {
      UiStyle.aurora => isDark ? _auroraDark() : _auroraLight(),
      UiStyle.aws => isDark ? _awsDark() : _awsLight(),
      UiStyle.gcp => isDark ? _gcpDark() : _gcpLight(),
      UiStyle.azure => isDark ? _azureDark() : _azureLight(),
    };
  }

  /// The [ThemeMode] a [ThemeBrightness] setting maps to.
  static ThemeMode themeModeFor(ThemeBrightness brightness) =>
      switch (brightness) {
        ThemeBrightness.system => ThemeMode.system,
        ThemeBrightness.light => ThemeMode.light,
        ThemeBrightness.dark => ThemeMode.dark,
      };

  /// [UiStyle.aurora], dark — today's only look, byte-for-byte. Kept as its
  /// own method (not folded into [_consoleStyle] below) precisely so nothing
  /// here can move: `theme_test.dart` asserts the exact key colours a future
  /// palette edit could otherwise change without anyone noticing.
  static ThemeData _auroraDark() {
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

  /// Aurora's light half. Aurora has no console to evoke — it is the app's
  /// own look — so this just carries the dark variant's green accent and
  /// shape language onto light-neutral surfaces rather than inventing a
  /// second identity.
  static const Color _auroraLightBackground = Color(0xFFF6F8FA);
  static const Color _auroraLightSurface = Color(0xFFFFFFFF);

  static ThemeData _auroraLight() {
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.light,
    ).copyWith(
      surface: _auroraLightSurface,
      error: danger,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: scheme,
      scaffoldBackgroundColor: _auroraLightBackground,
      appBarTheme: const AppBarTheme(
        backgroundColor: _auroraLightSurface,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
        filled: true,
        fillColor: _auroraLightSurface,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
        ),
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: _auroraLightSurface,
        constraints: BoxConstraints(minWidth: 280, maxWidth: 560),
      ),
      cardTheme: const CardThemeData(color: _auroraLightSurface),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ---- AWS-inspired: warm orange on dark navy/slate, square-ish corners,
  // hairline borders, dense. An original palette evoking that console's
  // visual language, not its brand hex values. ----
  static const Color _awsAccent = Color(0xFFE8890C);
  static const Color _awsDarkBackground = Color(0xFF121A2B);
  static const Color _awsDarkSurface = Color(0xFF1B2436);
  static const Color _awsLightBackground = Color(0xFFF2F3F3);
  static const Color _awsLightSurface = Color(0xFFFFFFFF);

  static ThemeData _awsDark() => _consoleStyle(
        brightness: Brightness.dark,
        seed: _awsAccent,
        background: _awsDarkBackground,
        surfaceColor: _awsDarkSurface,
        radius: 4,
        hairlineBorder: true,
        cardElevation: 0,
        density: VisualDensity.compact,
        dense: true,
        titleWeight: FontWeight.w600,
        crispDividers: true,
      );

  static ThemeData _awsLight() => _consoleStyle(
        brightness: Brightness.light,
        seed: _awsAccent,
        background: _awsLightBackground,
        surfaceColor: _awsLightSurface,
        radius: 4,
        hairlineBorder: true,
        cardElevation: 0,
        density: VisualDensity.compact,
        dense: true,
        titleWeight: FontWeight.w600,
        crispDividers: true,
      );

  // ---- GCP-inspired: light-first, blue accent, generous whitespace, soft
  // rounded cards with a subtle shadow instead of a border. ----
  static const Color _gcpAccent = Color(0xFF2C6CE0);
  static const Color _gcpLightBackground = Color(0xFFF7F9FC);
  static const Color _gcpLightSurface = Color(0xFFFFFFFF);
  static const Color _gcpDarkBackground = Color(0xFF14181F);
  static const Color _gcpDarkSurface = Color(0xFF1E2430);

  static ThemeData _gcpLight() => _consoleStyle(
        brightness: Brightness.light,
        seed: _gcpAccent,
        background: _gcpLightBackground,
        surfaceColor: _gcpLightSurface,
        radius: 12,
        hairlineBorder: false,
        cardElevation: 2,
        density: VisualDensity.standard,
        dense: false,
        titleWeight: FontWeight.w500,
        crispDividers: false,
      );

  static ThemeData _gcpDark() => _consoleStyle(
        brightness: Brightness.dark,
        seed: _gcpAccent,
        background: _gcpDarkBackground,
        surfaceColor: _gcpDarkSurface,
        radius: 12,
        hairlineBorder: false,
        cardElevation: 2,
        density: VisualDensity.standard,
        dense: false,
        titleWeight: FontWeight.w500,
        crispDividers: false,
      );

  // ---- Azure-inspired: cooler teal-blue accent, flat surfaces, medium
  // corners, crisp dividers instead of shadow or hairline borders. ----
  static const Color _azureAccent = Color(0xFF1AA3C9);
  static const Color _azureLightBackground = Color(0xFFF5F8FA);
  static const Color _azureLightSurface = Color(0xFFFFFFFF);
  static const Color _azureDarkBackground = Color(0xFF10161F);
  static const Color _azureDarkSurface = Color(0xFF1A222E);

  static ThemeData _azureLight() => _consoleStyle(
        brightness: Brightness.light,
        seed: _azureAccent,
        background: _azureLightBackground,
        surfaceColor: _azureLightSurface,
        radius: 8,
        hairlineBorder: false,
        cardElevation: 0,
        density: VisualDensity.standard,
        dense: false,
        titleWeight: FontWeight.w500,
        crispDividers: true,
      );

  static ThemeData _azureDark() => _consoleStyle(
        brightness: Brightness.dark,
        seed: _azureAccent,
        background: _azureDarkBackground,
        surfaceColor: _azureDarkSurface,
        radius: 8,
        hairlineBorder: false,
        cardElevation: 0,
        density: VisualDensity.standard,
        dense: false,
        titleWeight: FontWeight.w500,
        crispDividers: true,
      );

  /// Shared builder behind the three console-inspired styles. Aurora is not
  /// built through this — see [_auroraDark]'s doc comment for why — but the
  /// three below all vary the same knobs: seed colour, surface tones, corner
  /// radius, elevation/border treatment, app-bar weight, button shape and
  /// density, which is exactly the set wave 1 promises to differ on.
  static ThemeData _consoleStyle({
    required Brightness brightness,
    required Color seed,
    required Color background,
    required Color surfaceColor,
    required double radius,
    required bool hairlineBorder,
    required double cardElevation,
    required VisualDensity density,
    required bool dense,
    required FontWeight titleWeight,
    required bool crispDividers,
  }) {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    ).copyWith(surface: surfaceColor);

    final cardShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
      side: hairlineBorder
          ? BorderSide(color: scheme.outlineVariant)
          : BorderSide.none,
    );
    final buttonShape =
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius));

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      visualDensity: density,
      scaffoldBackgroundColor: background,
      appBarTheme: AppBarTheme(
        backgroundColor: surfaceColor,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        // Flat-with-border styles get a zero-elevation bar (the hairline
        // divider below does the separating); the shadow styles get a hint
        // of elevation instead so the bar reads as sitting above the page.
        elevation: hairlineBorder ? 0 : 1,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 20,
          fontWeight: titleWeight,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(radius)),
        filled: true,
        fillColor: surfaceColor,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          shape: buttonShape,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(shape: buttonShape),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(shape: buttonShape),
      ),
      // Same dialog-width reasoning as `_auroraDark` above — every style
      // shares that constraint regardless of its own shape language.
      dialogTheme: DialogThemeData(
        backgroundColor: surfaceColor,
        shape: cardShape,
        constraints: const BoxConstraints(minWidth: 280, maxWidth: 560),
      ),
      cardTheme: CardThemeData(
        color: surfaceColor,
        elevation: cardElevation,
        shape: cardShape,
      ),
      dividerTheme: DividerThemeData(
        color: crispDividers ? scheme.outline : scheme.outlineVariant,
        thickness: crispDividers ? 1 : 0.5,
        space: dense ? 24 : 32,
      ),
      listTileTheme: ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: dense ? 12 : 16),
        dense: dense,
      ),
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
      TerminalColorScheme.dracula => _dracula,
      TerminalColorScheme.solarizedDark => _solarizedDark,
      TerminalColorScheme.solarizedLight => _solarizedLight,
      TerminalColorScheme.nord => _nord,
      TerminalColorScheme.gruvboxDark => _gruvboxDark,
      TerminalColorScheme.monokai => _monokai,
      TerminalColorScheme.oneDark => _oneDark,
      TerminalColorScheme.blackOnWhite => _blackOnWhite,
      TerminalColorScheme.retroGreen => _retroGreen,
    };
  }

  /// The editor's syntax colour for [kind], out of the user's own terminal
  /// palette.
  ///
  /// The point of routing this through [TerminalTheme] rather than a fixed
  /// set of editor colours is that the two views sit side by side: a user on
  /// Solarized Light who opens a file from the browser should not get a
  /// near-black editor next to their cream terminal. Every mode in
  /// `syntax_highlighter.dart` reduces to these ten kinds, so a scheme only
  /// has to answer ten questions to theme all thirteen languages.
  ///
  /// The ANSI slots are picked for contrast against the scheme's own
  /// background, not for what they are called: `brightBlack` is every
  /// palette's "dimmed" tone, which is what a comment wants, and the
  /// foreground is left alone for unclassified text so that the base style
  /// and [TokenKind.plain] can never disagree.
  static TextStyle syntaxStyleFor(TokenKind kind, TerminalTheme theme) {
    return switch (kind) {
      TokenKind.plain => TextStyle(color: theme.foreground),
      TokenKind.keyword => TextStyle(color: theme.magenta),
      TokenKind.builtin => TextStyle(color: theme.blue),
      TokenKind.string => TextStyle(color: theme.green),
      TokenKind.number => TextStyle(color: theme.cyan),
      TokenKind.comment => TextStyle(
          color: theme.brightBlack,
          fontStyle: FontStyle.italic,
        ),
      TokenKind.meta => TextStyle(color: theme.yellow),
      TokenKind.attribute => TextStyle(color: theme.brightCyan),
      TokenKind.heading => TextStyle(
          color: theme.brightMagenta,
          fontWeight: FontWeight.w700,
        ),
      TokenKind.operator => TextStyle(color: theme.white),
    };
  }

  /// The band behind the line the caret is on.
  ///
  /// Derived from the scheme's foreground rather than hard-coded so it lands
  /// on the right side of the background in both a dark scheme and a light
  /// one — `selection` would be the obvious choice but is tuned to be seen
  /// under a deliberate drag, which is far too loud to sit under the caret
  /// permanently.
  static Color editorCurrentLine(TerminalTheme theme) =>
      theme.foreground.withValues(alpha: 0.07);

  /// Line numbers: dimmed, except the one the caret is on.
  static Color editorGutterText(TerminalTheme theme) => theme.brightBlack;

  static Color editorGutterActiveText(TerminalTheme theme) => theme.foreground;

  /// Find hits, and the one the caret is sitting on. These two are already in
  /// every [TerminalTheme] — the terminal's own search uses them — so the
  /// editor's find bar highlights in exactly the colours the user's terminal
  /// search does.
  static Color editorMatch(TerminalTheme theme) => theme.searchHitBackground;

  static Color editorCurrentMatch(TerminalTheme theme) =>
      theme.searchHitBackgroundCurrent;

  static Color editorMatchText(TerminalTheme theme) =>
      theme.searchHitForeground;

  /// Resolves a saved host's colour-tag id (`Host.colorLabel?.name`, the
  /// persisted shape) to the swatch it names, or null for no tag. Public —
  /// not just used by the host list and edit screen — so a later phase's
  /// terminal tabs can tint themselves to match without duplicating this
  /// palette; kept here rather than on the enum in `models/host.dart` for
  /// the same reason [terminalThemeFor] is not on [TerminalColorScheme].
  static Color? hostColorFor(String? colorId) {
    final label = HostColorLabel.fromId(colorId);
    if (label == null) return null;
    return switch (label) {
      HostColorLabel.red => const Color(0xFFF85149),
      HostColorLabel.orange => const Color(0xFFDB6D28),
      HostColorLabel.yellow => const Color(0xFFD29922),
      HostColorLabel.green => const Color(0xFF3FB950),
      HostColorLabel.teal => const Color(0xFF39C5CF),
      HostColorLabel.blue => const Color(0xFF58A6FF),
      HostColorLabel.purple => const Color(0xFFBC8CFF),
      HostColorLabel.pink => const Color(0xFFF778BA),
    };
  }

  /// Published Dracula palette (draculatheme.com/terminal).
  static const TerminalTheme _dracula = TerminalTheme(
    cursor: Color(0xFFF8F8F2),
    selection: Color(0x5544475A),
    foreground: Color(0xFFF8F8F2),
    background: Color(0xFF282A36),
    black: Color(0xFF21222C),
    red: Color(0xFFFF5555),
    green: Color(0xFF50FA7B),
    yellow: Color(0xFFF1FA8C),
    blue: Color(0xFFBD93F9),
    magenta: Color(0xFFFF79C6),
    cyan: Color(0xFF8BE9FD),
    white: Color(0xFFF8F8F2),
    brightBlack: Color(0xFF6272A4),
    brightRed: Color(0xFFFF6E6E),
    brightGreen: Color(0xFF69FF94),
    brightYellow: Color(0xFFFFFFA5),
    brightBlue: Color(0xFFD6ACFF),
    brightMagenta: Color(0xFFFF92DF),
    brightCyan: Color(0xFFA4FFFF),
    brightWhite: Color(0xFFFFFFFF),
    searchHitBackground: Color(0xFFF1FA8C),
    searchHitBackgroundCurrent: Color(0xFFFFB86C),
    searchHitForeground: Color(0xFF282A36),
  );

  /// Solarized Light — same 16 base tones as [_solarizedDark], background
  /// and foreground swapped (Ethan Schoonover's published value table).
  static const TerminalTheme _solarizedLight = TerminalTheme(
    cursor: Color(0xFF657B83),
    selection: Color(0x55EEE8D5),
    foreground: Color(0xFF657B83),
    background: Color(0xFFFDF6E3),
    black: Color(0xFF073642),
    red: Color(0xFFDC322F),
    green: Color(0xFF859900),
    yellow: Color(0xFFB58900),
    blue: Color(0xFF268BD2),
    magenta: Color(0xFFD33682),
    cyan: Color(0xFF2AA198),
    white: Color(0xFFEEE8D5),
    brightBlack: Color(0xFF002B36),
    brightRed: Color(0xFFCB4B16),
    brightGreen: Color(0xFF586E75),
    brightYellow: Color(0xFF657B83),
    brightBlue: Color(0xFF839496),
    brightMagenta: Color(0xFF6C71C4),
    brightCyan: Color(0xFF93A1A1),
    brightWhite: Color(0xFFFDF6E3),
    searchHitBackground: Color(0xFFB58900),
    searchHitBackgroundCurrent: Color(0xFFCB4B16),
    searchHitForeground: Color(0xFFFDF6E3),
  );

  /// Published Nord palette (nordtheme.com), 16-colour terminal mapping.
  static const TerminalTheme _nord = TerminalTheme(
    cursor: Color(0xFFD8DEE9),
    selection: Color(0x554C566A),
    foreground: Color(0xFFD8DEE9),
    background: Color(0xFF2E3440),
    black: Color(0xFF3B4252),
    red: Color(0xFFBF616A),
    green: Color(0xFFA3BE8C),
    yellow: Color(0xFFEBCB8B),
    blue: Color(0xFF81A1C1),
    magenta: Color(0xFFB48EAD),
    cyan: Color(0xFF88C0D0),
    white: Color(0xFFE5E9F0),
    brightBlack: Color(0xFF4C566A),
    brightRed: Color(0xFFBF616A),
    brightGreen: Color(0xFFA3BE8C),
    brightYellow: Color(0xFFEBCB8B),
    brightBlue: Color(0xFF81A1C1),
    brightMagenta: Color(0xFFB48EAD),
    brightCyan: Color(0xFF8FBCBB),
    brightWhite: Color(0xFFECEFF4),
    searchHitBackground: Color(0xFFEBCB8B),
    searchHitBackgroundCurrent: Color(0xFFD08770),
    searchHitForeground: Color(0xFF2E3440),
  );

  /// Published Gruvbox Dark (medium contrast) terminal mapping
  /// (morhetz/gruvbox).
  static const TerminalTheme _gruvboxDark = TerminalTheme(
    cursor: Color(0xFFEBDBB2),
    selection: Color(0x55504945),
    foreground: Color(0xFFEBDBB2),
    background: Color(0xFF282828),
    black: Color(0xFF282828),
    red: Color(0xFFCC241D),
    green: Color(0xFF98971A),
    yellow: Color(0xFFD79921),
    blue: Color(0xFF458588),
    magenta: Color(0xFFB16286),
    cyan: Color(0xFF689D6A),
    white: Color(0xFFA89984),
    brightBlack: Color(0xFF928374),
    brightRed: Color(0xFFFB4934),
    brightGreen: Color(0xFFB8BB26),
    brightYellow: Color(0xFFFABD2F),
    brightBlue: Color(0xFF83A598),
    brightMagenta: Color(0xFFD3869B),
    brightCyan: Color(0xFF8EC07C),
    brightWhite: Color(0xFFEBDBB2),
    searchHitBackground: Color(0xFFD79921),
    searchHitBackgroundCurrent: Color(0xFFFE8019),
    searchHitForeground: Color(0xFF282828),
  );

  /// Published Atom One Dark terminal mapping.
  static const TerminalTheme _oneDark = TerminalTheme(
    cursor: Color(0xFF528BFF),
    selection: Color(0x553E4451),
    foreground: Color(0xFFABB2BF),
    background: Color(0xFF282C34),
    black: Color(0xFF282C34),
    red: Color(0xFFE06C75),
    green: Color(0xFF98C379),
    yellow: Color(0xFFE5C07B),
    blue: Color(0xFF61AFEF),
    magenta: Color(0xFFC678DD),
    cyan: Color(0xFF56B6C2),
    white: Color(0xFFABB2BF),
    brightBlack: Color(0xFF5C6370),
    brightRed: Color(0xFFE06C75),
    brightGreen: Color(0xFF98C379),
    brightYellow: Color(0xFFE5C07B),
    brightBlue: Color(0xFF61AFEF),
    brightMagenta: Color(0xFFC678DD),
    brightCyan: Color(0xFF56B6C2),
    brightWhite: Color(0xFFFFFFFF),
    searchHitBackground: Color(0xFFE5C07B),
    searchHitBackgroundCurrent: Color(0xFFD19A66),
    searchHitForeground: Color(0xFF282C34),
  );

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
