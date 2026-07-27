/// Named terminal colour presets the user can pick between in Settings.
///
/// The actual [TerminalTheme] values these resolve to live in `theme.dart`,
/// next to the app's own default palette — this enum only names the choice,
/// so `models/` stays free of the `xterm` import.
enum TerminalColorScheme {
  classic,
  solarizedDark,
  monokai,
  blackOnWhite,
  retroGreen;

  String get label => switch (this) {
        TerminalColorScheme.classic => 'SecureShell Go (default)',
        TerminalColorScheme.solarizedDark => 'Solarized Dark',
        TerminalColorScheme.monokai => 'Monokai',
        TerminalColorScheme.blackOnWhite => 'Black on white',
        TerminalColorScheme.retroGreen => 'Retro green',
      };

  static TerminalColorScheme fromName(String? name) =>
      TerminalColorScheme.values.firstWhere(
        (scheme) => scheme.name == name,
        orElse: () => TerminalColorScheme.classic,
      );
}

/// User-editable preferences, persisted by [SettingsStore].
///
/// Deliberately free of secrets — passwords and keys stay in
/// `CredentialStore`, so this is plain JSON on disk, same reasoning as
/// `Host` in `models/host.dart`.
class AppSettings {
  const AppSettings({
    this.terminalFontSize = defaultFontSize,
    this.colorScheme = TerminalColorScheme.classic,
    this.keepScreenAwake = false,
    this.showHiddenFilesByDefault = false,
  });

  static const double defaultFontSize = 13;
  static const double minFontSize = 10;
  static const double maxFontSize = 24;

  final double terminalFontSize;
  final TerminalColorScheme colorScheme;
  final bool keepScreenAwake;
  final bool showHiddenFilesByDefault;

  /// Keeps a font size inside the range the settings slider and pinch-zoom
  /// both respect. `num.clamp` returns `num`, not `double`, which is the kind
  /// of thing that quietly turns into an analyzer complaint at the call site
  /// — doing it once here avoids that everywhere else.
  static double clampFontSize(double size) {
    if (size < minFontSize) return minFontSize;
    if (size > maxFontSize) return maxFontSize;
    return size;
  }

  AppSettings copyWith({
    double? terminalFontSize,
    TerminalColorScheme? colorScheme,
    bool? keepScreenAwake,
    bool? showHiddenFilesByDefault,
  }) {
    return AppSettings(
      terminalFontSize: clampFontSize(terminalFontSize ?? this.terminalFontSize),
      colorScheme: colorScheme ?? this.colorScheme,
      keepScreenAwake: keepScreenAwake ?? this.keepScreenAwake,
      showHiddenFilesByDefault:
          showHiddenFilesByDefault ?? this.showHiddenFilesByDefault,
    );
  }

  Map<String, dynamic> toJson() => {
        'version': 1,
        'terminalFontSize': terminalFontSize,
        'colorScheme': colorScheme.name,
        'keepScreenAwake': keepScreenAwake,
        'showHiddenFilesByDefault': showHiddenFilesByDefault,
      };

  factory AppSettings.fromJson(Map<String, dynamic> json) => AppSettings(
        terminalFontSize: clampFontSize(
          (json['terminalFontSize'] as num?)?.toDouble() ?? defaultFontSize,
        ),
        colorScheme: TerminalColorScheme.fromName(
          json['colorScheme'] as String?,
        ),
        keepScreenAwake: json['keepScreenAwake'] as bool? ?? false,
        showHiddenFilesByDefault:
            json['showHiddenFilesByDefault'] as bool? ?? false,
      );
}
