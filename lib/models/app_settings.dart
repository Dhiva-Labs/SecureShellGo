/// Named terminal colour presets the user can pick between in Settings.
///
/// The actual [TerminalTheme] values these resolve to live in `theme.dart`,
/// next to the app's own default palette — this enum only names the choice,
/// so `models/` stays free of the `xterm` import.
enum TerminalColorScheme {
  classic,
  dracula,
  solarizedDark,
  solarizedLight,
  nord,
  gruvboxDark,
  monokai,
  oneDark,
  blackOnWhite,
  retroGreen;

  String get label => switch (this) {
        TerminalColorScheme.classic => 'SecureShell Go (default)',
        TerminalColorScheme.dracula => 'Dracula',
        TerminalColorScheme.solarizedDark => 'Solarized Dark',
        TerminalColorScheme.solarizedLight => 'Solarized Light',
        TerminalColorScheme.nord => 'Nord',
        TerminalColorScheme.gruvboxDark => 'Gruvbox Dark',
        TerminalColorScheme.monokai => 'Monokai',
        TerminalColorScheme.oneDark => 'One Dark',
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
    this.collapsedGroups = const <String>{},
  });

  static const double defaultFontSize = 13;
  static const double minFontSize = 10;
  static const double maxFontSize = 24;

  final double terminalFontSize;
  final TerminalColorScheme colorScheme;
  final bool keepScreenAwake;
  final bool showHiddenFilesByDefault;

  /// Names of saved-hosts-list group sections the user has collapsed —
  /// see `services/host_grouping.dart` for the sentinel key the Ungrouped
  /// section uses here. Absent, not collapsed, is the default for every
  /// group: a newly created one, or one nobody has touched yet, starts open.
  final Set<String> collapsedGroups;

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
    Set<String>? collapsedGroups,
  }) {
    return AppSettings(
      terminalFontSize: clampFontSize(terminalFontSize ?? this.terminalFontSize),
      colorScheme: colorScheme ?? this.colorScheme,
      keepScreenAwake: keepScreenAwake ?? this.keepScreenAwake,
      showHiddenFilesByDefault:
          showHiddenFilesByDefault ?? this.showHiddenFilesByDefault,
      collapsedGroups: collapsedGroups ?? this.collapsedGroups,
    );
  }

  Map<String, dynamic> toJson() => {
        'version': 1,
        'terminalFontSize': terminalFontSize,
        'colorScheme': colorScheme.name,
        'keepScreenAwake': keepScreenAwake,
        'showHiddenFilesByDefault': showHiddenFilesByDefault,
        'collapsedGroups': collapsedGroups.toList(),
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
        // Absent on every settings.json written before v1.3.0 — reads as
        // "nothing collapsed" rather than failing the whole file.
        collapsedGroups: switch (json['collapsedGroups']) {
          final List<dynamic> names => {for (final name in names) '$name'},
          _ => const <String>{},
        },
      );
}
