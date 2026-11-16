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

  static TerminalColorScheme fromName(String? name) =>
      TerminalColorScheme.values.firstWhere(
        (scheme) => scheme.name == name,
        orElse: () => TerminalColorScheme.classic,
      );
}

/// The overall chrome look the user can pick in Settings > Appearance:
/// palette family, corner radius, elevation and app-bar treatment. Separate
/// from [ThemeBrightness] — every style has both a light and a dark variant,
/// see `theme.dart`'s `AppTheme.themeFor`.
///
/// `aws`/`gcp`/`azure` evoke those consoles' visual language with an
/// original palette; they are not the vendors' own colours or marks, hence
/// "-inspired" in the label rather than a claim of affiliation.
enum UiStyle {
  aurora,
  aws,
  gcp,
  azure;

  /// Unrecognised or absent reads as [aurora] — today's only look, and the
  /// safe fallback for a settings file written before this field existed.
  static UiStyle fromName(String? name) => UiStyle.values.firstWhere(
        (s) => s.name == name,
        orElse: () => UiStyle.aurora,
      );
}

/// Which of [UiStyle]'s two variants to render, or [system] to follow the
/// OS setting.
enum ThemeBrightness {
  system,
  light,
  dark;

  /// Unrecognised or absent reads as [dark] — the app has only ever rendered
  /// dark, so a settings file written before this field existed must not
  /// suddenly flip a user into light mode.
  static ThemeBrightness fromName(String? name) =>
      ThemeBrightness.values.firstWhere(
        (b) => b.name == name,
        orElse: () => ThemeBrightness.dark,
      );
}

/// How long the app may sit in the background before the app lock asks for
/// the device credential again.
///
/// The clock runs from the moment the app is backgrounded, not from the last
/// touch: a grace period is there so that switching out to a password manager
/// or an authenticator app and straight back does not cost an unlock, and
/// that round trip is exactly what the timer should be measuring.
enum AppLockTimeout {
  immediately,
  oneMinute,
  fiveMinutes,
  fifteenMinutes;

  Duration get duration => switch (this) {
        AppLockTimeout.immediately => Duration.zero,
        AppLockTimeout.oneMinute => const Duration(minutes: 1),
        AppLockTimeout.fiveMinutes => const Duration(minutes: 5),
        AppLockTimeout.fifteenMinutes => const Duration(minutes: 15),
      };

  /// Unrecognised or absent reads as [oneMinute] — the default — rather than
  /// as the most permissive option, same fail-safe direction as
  /// [SshAuthMethod.fromName] in `models/host.dart`.
  static AppLockTimeout fromName(String? name) =>
      AppLockTimeout.values.firstWhere(
        (t) => t.name == name,
        orElse: () => AppLockTimeout.oneMinute,
      );
}

/// The terminal cursor's shape.
enum TerminalCursorStyle {
  block,
  underline,
  bar;

  /// Unrecognised or absent reads as [block], the only shape there was.
  static TerminalCursorStyle fromName(String? name) =>
      TerminalCursorStyle.values.firstWhere(
        (c) => c.name == name,
        orElse: () => TerminalCursorStyle.block,
      );
}

/// What a terminal bell (`\a`) does.
enum TerminalBell {
  /// A short vibration — what the bell has always done. Nothing on a device
  /// that cannot vibrate.
  vibrate,

  /// A brief flash over the terminal.
  visual,

  off;

  /// Unrecognised or absent reads as [vibrate], the behaviour before this
  /// was a choice.
  static TerminalBell fromName(String? name) => TerminalBell.values.firstWhere(
        (b) => b.name == name,
        orElse: () => TerminalBell.vibrate,
      );
}

/// The terminal's typeface.
enum TerminalFont {
  /// The platform's monospace font — see `AppTheme.monoFontFamily`.
  system,

  /// Bundled with the app (SIL Open Font License), so the terminal looks the
  /// same on every device and has the box-drawing and symbol glyphs that
  /// some phones' monospace fonts lack.
  jetBrainsMono;

  /// Unrecognised or absent reads as [system], the font used before.
  static TerminalFont fromName(String? name) => TerminalFont.values.firstWhere(
        (f) => f.name == name,
        orElse: () => TerminalFont.system,
      );
}

/// When the on-screen row of extra keys (Esc, Tab, Ctrl, arrows) shows.
enum KeyBarMode {
  /// Shown on touch screens, hidden once a hardware keyboard is in use.
  auto,
  always,
  never;

  /// Unrecognised or absent reads as [auto].
  static KeyBarMode fromName(String? name) => KeyBarMode.values.firstWhere(
        (m) => m.name == name,
        orElse: () => KeyBarMode.auto,
      );
}

/// User-editable preferences, persisted by [SettingsStore].
///
/// Deliberately free of secrets — passwords and keys stay in
/// `CredentialStore`, so this is plain JSON on disk, same reasoning as
/// `Host` in `models/host.dart`.
/// Which kind of AI service the built-in assistant talks to.
enum AssistantProviderKind {
  /// Anthropic's Messages API.
  anthropic,

  /// Any service that speaks the OpenAI chat completions format (a base URL
  /// is required), including a model server on this computer.
  openAiCompatible;

  /// Absent or unknown reads as [anthropic], the default.
  static AssistantProviderKind fromJson(Object? value) =>
      value == openAiCompatible.name ? openAiCompatible : anthropic;
}

class AppSettings {
  const AppSettings({
    this.terminalFontSize = defaultFontSize,
    this.colorScheme = TerminalColorScheme.classic,
    this.uiStyle = UiStyle.aurora,
    this.themeBrightness = ThemeBrightness.dark,
    this.keepScreenAwake = false,
    this.showHiddenFilesByDefault = false,
    this.collapsedGroups = const <String>{},
    this.appLockEnabled = false,
    this.appLockTimeout = AppLockTimeout.oneMinute,
    this.scrollbackLines = defaultScrollbackLines,
    this.cursorStyle = TerminalCursorStyle.block,
    this.cursorBlink = false,
    this.copyOnSelect = false,
    this.bell = TerminalBell.vibrate,
    this.terminalFont = TerminalFont.system,
    this.keyBarMode = KeyBarMode.auto,
    this.editorFontSize = defaultFontSize,
    this.diagnosticsLog = false,
    this.localeOverride,
    this.bridgeEnabled = false,
    this.bridgeShowAddress = false,
    this.bridgeReadSensitivePaths = false,
    this.bridgeExtraBlockedPaths = const <String>[],
    this.bridgeTimedApprovalMinutes = 0,
    this.bridgePhoneControl = false,
    this.assistantEnabled = false,
    this.assistantProvider = AssistantProviderKind.anthropic,
    this.assistantBaseUrl = '',
    this.assistantModel = '',
  });

  static const double defaultFontSize = 13;
  static const double minFontSize = 10;
  static const double maxFontSize = 24;

  /// The editor zooms further both ways than the terminal: a phone held at
  /// arm's length one moment, a whole function on screen the next.
  static const double minEditorFontSize = 8;
  static const double maxEditorFontSize = 32;

  /// What the terminal kept before this was a setting.
  static const int defaultScrollbackLines = 10000;

  /// The choices Settings offers. Anything else read from disk — a hand
  /// edit, a value from a later version — falls back to the default.
  static const List<int> scrollbackChoices = [1000, 5000, 10000, 50000];

  final double terminalFontSize;
  final TerminalColorScheme colorScheme;

  /// The UI chrome style; see [UiStyle]. Independent of [colorScheme], which
  /// only names the *terminal's* palette.
  final UiStyle uiStyle;
  final ThemeBrightness themeBrightness;
  final bool keepScreenAwake;
  final bool showHiddenFilesByDefault;

  /// Names of saved-hosts-list group sections the user has collapsed —
  /// see `services/host_grouping.dart` for the sentinel key the Ungrouped
  /// section uses here. Absent, not collapsed, is the default for every
  /// group: a newly created one, or one nobody has touched yet, starts open.
  final Set<String> collapsedGroups;

  /// Whether the app demands the device credential before showing anything.
  /// Off unless the user turns it on, and off is also what a settings file
  /// from before v1.3.0 reads as.
  ///
  /// This is a screen gate, not encryption — see `app_lock_controller.dart`
  /// and the help text in Settings. Saved passwords are encrypted by the
  /// platform keystore whether this is on or off, and turning it on does not
  /// make them any more encrypted.
  final bool appLockEnabled;

  final AppLockTimeout appLockTimeout;

  /// Lines of terminal history kept per session; see [scrollbackChoices].
  final int scrollbackLines;

  final TerminalCursorStyle cursorStyle;

  /// Off by default, as the cursor has always been steady.
  final bool cursorBlink;

  /// Text selected in the terminal with a mouse goes straight to the
  /// clipboard, as in PuTTY. Off by default: a stray drag would otherwise
  /// replace whatever was on the clipboard.
  final bool copyOnSelect;

  final TerminalBell bell;
  final TerminalFont terminalFont;
  final KeyBarMode keyBarMode;

  /// The remote editor's text size, set in Settings or by zooming the editor.
  /// Separate from [terminalFontSize]: code and a shell are read differently.
  final double editorFontSize;

  /// Whether errors and crashes are written to a log on this device, for the
  /// user to copy into a bug report. Secrets are scrubbed before anything is
  /// written, the file is capped in size, and nothing is ever sent anywhere.
  ///
  /// Off unless the user turns it on — and off for a settings file that
  /// does not say, or cannot be read: a log of what went wrong is still a
  /// record of what the user did, and keeping one is their choice.
  final bool diagnosticsLog;

  /// A language tag such as `pt-BR` the app uses instead of the device's
  /// language, or null to follow the device.
  final String? localeOverride;

  /// Whether the AI Bridge (the local MCP server) is running. Off unless the
  /// user turns it on, and off for a settings file that does not say.
  final bool bridgeEnabled;

  /// Whether the host list an assistant sees includes address, port and user
  /// name. Off: it sees labels and groups only.
  final bool bridgeShowAddress;

  /// Lifts the built-in blocklist of credential-like paths (`~/.ssh`, `.env`,
  /// key files...). Off by default; [bridgeExtraBlockedPaths] applies either way.
  final bool bridgeReadSensitivePaths;

  /// The user's own blocked path patterns, on top of the built-in ones.
  final List<String> bridgeExtraBlockedPaths;

  /// How long "Allow for a while" on an approval card lasts, in minutes. 0 is
  /// off; the other choices are in [bridgeTimedApprovalChoices]. Only
  /// [copyWith] and [fromJson] validate it; anything else is built by hand.
  final int bridgeTimedApprovalMinutes;

  /// Whether a paired phone may act as remote control of this computer's
  /// AI Bridge (see and answer approval cards, stop grants and terminals).
  /// Off unless the user turns it on; off refuses every phone at the door.
  final bool bridgePhoneControl;

  /// Whether the built-in assistant (the chat inside the app) may be used.
  /// Off unless the user turns it on. Its API key is not here: it lives in
  /// secure storage and is never in settings.json or a backup.
  final bool assistantEnabled;

  /// Which kind of service the built-in assistant talks to.
  final AssistantProviderKind assistantProvider;

  /// The service's base URL; empty uses the provider's own address (only
  /// Anthropic has one).
  final String assistantBaseUrl;

  /// The model name to ask for.
  final String assistantModel;

  static const List<int> bridgeTimedApprovalChoices = [0, 5, 15, 60];

  static int _validTimedApproval(int minutes) =>
      bridgeTimedApprovalChoices.contains(minutes) ? minutes : 0;

  /// These settings with the five bridge fields taken from [other]. An
  /// import uses it so a backup's settings land without touching what this
  /// device allows an assistant to do.
  AppSettings withBridgeFrom(AppSettings other) => copyWith(
        bridgeEnabled: other.bridgeEnabled,
        bridgeShowAddress: other.bridgeShowAddress,
        bridgeReadSensitivePaths: other.bridgeReadSensitivePaths,
        bridgeExtraBlockedPaths: other.bridgeExtraBlockedPaths,
        bridgeTimedApprovalMinutes: other.bridgeTimedApprovalMinutes,
        bridgePhoneControl: other.bridgePhoneControl,
        assistantEnabled: other.assistantEnabled,
        assistantProvider: other.assistantProvider,
        assistantBaseUrl: other.assistantBaseUrl,
        assistantModel: other.assistantModel,
      );

  /// These settings with the five bridge fields back at their defaults.
  /// Used on backup export and decode: what an assistant may reach is a
  /// decision about this device, not something a file should carry in or out.
  ///
  /// Built on [copyWith], so a field added to the class later is carried
  /// along by default instead of silently reset.
  AppSettings withBridgeDefaults() => copyWith(
        bridgeEnabled: false,
        bridgeShowAddress: false,
        bridgeReadSensitivePaths: false,
        bridgeExtraBlockedPaths: const <String>[],
        bridgeTimedApprovalMinutes: 0,
        bridgePhoneControl: false,
        assistantEnabled: false,
        assistantProvider: AssistantProviderKind.anthropic,
        assistantBaseUrl: '',
        assistantModel: '',
      );

  /// Keeps a font size inside the range the settings slider and pinch-zoom
  /// both respect. `num.clamp` returns `num`, not `double`, which is the kind
  /// of thing that quietly turns into an analyzer complaint at the call site
  /// — doing it once here avoids that everywhere else.
  static double clampFontSize(double size) {
    if (size < minFontSize) return minFontSize;
    if (size > maxFontSize) return maxFontSize;
    return size;
  }

  /// [clampFontSize] for the editor's wider range.
  static double clampEditorFontSize(double size) {
    if (size < minEditorFontSize) return minEditorFontSize;
    if (size > maxEditorFontSize) return maxEditorFontSize;
    return size;
  }

  AppSettings copyWith({
    double? terminalFontSize,
    TerminalColorScheme? colorScheme,
    UiStyle? uiStyle,
    ThemeBrightness? themeBrightness,
    bool? keepScreenAwake,
    bool? showHiddenFilesByDefault,
    Set<String>? collapsedGroups,
    bool? appLockEnabled,
    AppLockTimeout? appLockTimeout,
    int? scrollbackLines,
    TerminalCursorStyle? cursorStyle,
    bool? cursorBlink,
    bool? copyOnSelect,
    TerminalBell? bell,
    TerminalFont? terminalFont,
    KeyBarMode? keyBarMode,
    double? editorFontSize,
    bool? diagnosticsLog,
    bool? bridgeEnabled,
    bool? bridgeShowAddress,
    bool? bridgeReadSensitivePaths,
    List<String>? bridgeExtraBlockedPaths,
    int? bridgeTimedApprovalMinutes,
    bool? bridgePhoneControl,
    bool? assistantEnabled,
    AssistantProviderKind? assistantProvider,
    String? assistantBaseUrl,
    String? assistantModel,
    String? localeOverride,
    bool clearLocaleOverride = false,
  }) {
    return AppSettings(
      terminalFontSize: clampFontSize(terminalFontSize ?? this.terminalFontSize),
      colorScheme: colorScheme ?? this.colorScheme,
      uiStyle: uiStyle ?? this.uiStyle,
      themeBrightness: themeBrightness ?? this.themeBrightness,
      keepScreenAwake: keepScreenAwake ?? this.keepScreenAwake,
      showHiddenFilesByDefault:
          showHiddenFilesByDefault ?? this.showHiddenFilesByDefault,
      collapsedGroups: collapsedGroups ?? this.collapsedGroups,
      appLockEnabled: appLockEnabled ?? this.appLockEnabled,
      appLockTimeout: appLockTimeout ?? this.appLockTimeout,
      scrollbackLines: _validScrollback(scrollbackLines ?? this.scrollbackLines),
      cursorStyle: cursorStyle ?? this.cursorStyle,
      cursorBlink: cursorBlink ?? this.cursorBlink,
      copyOnSelect: copyOnSelect ?? this.copyOnSelect,
      bell: bell ?? this.bell,
      terminalFont: terminalFont ?? this.terminalFont,
      keyBarMode: keyBarMode ?? this.keyBarMode,
      editorFontSize:
          clampEditorFontSize(editorFontSize ?? this.editorFontSize),
      diagnosticsLog: diagnosticsLog ?? this.diagnosticsLog,
      localeOverride:
          clearLocaleOverride ? null : (localeOverride ?? this.localeOverride),
      bridgeEnabled: bridgeEnabled ?? this.bridgeEnabled,
      bridgeShowAddress: bridgeShowAddress ?? this.bridgeShowAddress,
      bridgeReadSensitivePaths:
          bridgeReadSensitivePaths ?? this.bridgeReadSensitivePaths,
      bridgeExtraBlockedPaths:
          bridgeExtraBlockedPaths ?? this.bridgeExtraBlockedPaths,
      bridgeTimedApprovalMinutes: _validTimedApproval(
        bridgeTimedApprovalMinutes ?? this.bridgeTimedApprovalMinutes,
      ),
      bridgePhoneControl: bridgePhoneControl ?? this.bridgePhoneControl,
      assistantEnabled: assistantEnabled ?? this.assistantEnabled,
      assistantProvider: assistantProvider ?? this.assistantProvider,
      assistantBaseUrl: assistantBaseUrl ?? this.assistantBaseUrl,
      assistantModel: assistantModel ?? this.assistantModel,
    );
  }

  /// Sets the language, or with null goes back to following the device.
  /// Not in [copyWith], whose `??` cannot set a field back to null.
  AppSettings withLocaleOverride(String? tag) {
    final clean = (tag == null || tag.trim().isEmpty) ? null : tag;
    return copyWith(localeOverride: clean, clearLocaleOverride: clean == null);
  }

  static int _validScrollback(int lines) =>
      scrollbackChoices.contains(lines) ? lines : defaultScrollbackLines;

  Map<String, dynamic> toJson() => {
        'version': 1,
        'terminalFontSize': terminalFontSize,
        'colorScheme': colorScheme.name,
        'uiStyle': uiStyle.name,
        'themeBrightness': themeBrightness.name,
        'keepScreenAwake': keepScreenAwake,
        'showHiddenFilesByDefault': showHiddenFilesByDefault,
        'collapsedGroups': collapsedGroups.toList(),
        'appLockEnabled': appLockEnabled,
        'appLockTimeout': appLockTimeout.name,
        'scrollbackLines': scrollbackLines,
        'cursorStyle': cursorStyle.name,
        'cursorBlink': cursorBlink,
        'copyOnSelect': copyOnSelect,
        'bell': bell.name,
        'terminalFont': terminalFont.name,
        'keyBarMode': keyBarMode.name,
        'editorFontSize': editorFontSize,
        'diagnosticsLog': diagnosticsLog,
        if (localeOverride != null) 'localeOverride': localeOverride,
        // Each written only when it differs from the default, so a settings
        // file that never used the bridge saves exactly as it did before.
        if (bridgeEnabled) 'bridgeEnabled': true,
        if (bridgeShowAddress) 'bridgeShowAddress': true,
        if (bridgeReadSensitivePaths) 'bridgeReadSensitivePaths': true,
        if (bridgeExtraBlockedPaths.isNotEmpty)
          'bridgeExtraBlockedPaths': bridgeExtraBlockedPaths,
        if (bridgeTimedApprovalMinutes != 0)
          'bridgeTimedApprovalMinutes': bridgeTimedApprovalMinutes,
        if (bridgePhoneControl) 'bridgePhoneControl': true,
        if (assistantEnabled) 'assistantEnabled': true,
        if (assistantProvider != AssistantProviderKind.anthropic)
          'assistantProvider': assistantProvider.name,
        if (assistantBaseUrl.isNotEmpty) 'assistantBaseUrl': assistantBaseUrl,
        if (assistantModel.isNotEmpty) 'assistantModel': assistantModel,
      };

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final terminalFontSize = clampFontSize(
      (json['terminalFontSize'] as num?)?.toDouble() ?? defaultFontSize,
    );
    return AppSettings(
      terminalFontSize: terminalFontSize,
      colorScheme: TerminalColorScheme.fromName(
        json['colorScheme'] as String?,
      ),
      // Absent on every settings.json written before v1.4.0 — reads as
      // aurora + dark, exactly today's look, so an upgrade never changes
      // anyone's UI out from under them.
      uiStyle: UiStyle.fromName(json['uiStyle'] as String?),
      themeBrightness: ThemeBrightness.fromName(
        json['themeBrightness'] as String?,
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
      // Absent on every settings.json written before v1.3.0, which reads as
      // "app lock off" — the same answer a fresh install gives, and the
      // safe direction: an upgrade must never silently start demanding a
      // credential the user has not set up.
      appLockEnabled: json['appLockEnabled'] as bool? ?? false,
      appLockTimeout: AppLockTimeout.fromName(
        json['appLockTimeout'] as String?,
      ),
      // Everything below is absent from a settings.json written before
      // 1.5, and reads as what the app did then.
      scrollbackLines: _validScrollback(
        (json['scrollbackLines'] as num?)?.toInt() ?? defaultScrollbackLines,
      ),
      cursorStyle: TerminalCursorStyle.fromName(
        json['cursorStyle'] as String?,
      ),
      cursorBlink: json['cursorBlink'] as bool? ?? false,
      copyOnSelect: json['copyOnSelect'] as bool? ?? false,
      bell: TerminalBell.fromName(json['bell'] as String?),
      terminalFont: TerminalFont.fromName(json['terminalFont'] as String?),
      keyBarMode: KeyBarMode.fromName(json['keyBarMode'] as String?),
      // The editor used the terminal's size until it had its own.
      editorFontSize: clampEditorFontSize(
        (json['editorFontSize'] as num?)?.toDouble() ?? terminalFontSize,
      ),
      diagnosticsLog: json['diagnosticsLog'] as bool? ?? false,
      localeOverride: switch (json['localeOverride']) {
        final String tag when tag.trim().isNotEmpty => tag,
        _ => null,
      },
      // Absent before 1.6: the bridge is off and nothing is widened. Only a
      // real `true` counts, so a mangled value cannot switch anything on.
      bridgeEnabled: json['bridgeEnabled'] == true,
      bridgeShowAddress: json['bridgeShowAddress'] == true,
      bridgeReadSensitivePaths: json['bridgeReadSensitivePaths'] == true,
      bridgeExtraBlockedPaths: switch (json['bridgeExtraBlockedPaths']) {
        final List<dynamic> patterns => [
            for (final pattern in patterns)
              if (pattern is String && pattern.trim().isNotEmpty)
                pattern.trim(),
          ],
        _ => const <String>[],
      },
      // Absent before 1.7, and anything not a listed choice: off. Only a
      // whole JSON integer counts; this app never writes a double here, and
      // 15.7 must not round its way into a choice.
      bridgeTimedApprovalMinutes: _validTimedApproval(
        switch (json['bridgeTimedApprovalMinutes']) {
          final int minutes => minutes,
          _ => 0,
        },
      ),
      // Absent before 1.8: no phone may control. Only a real `true` counts.
      bridgePhoneControl: json['bridgePhoneControl'] == true,
      // Absent before 1.8: the built-in assistant is off. Only a real
      // `true` switches it on.
      assistantEnabled: json['assistantEnabled'] == true,
      assistantProvider: AssistantProviderKind.fromJson(
        json['assistantProvider'],
      ),
      assistantBaseUrl: switch (json['assistantBaseUrl']) {
        final String url => url.trim(),
        _ => '',
      },
      assistantModel: switch (json['assistantModel']) {
        final String model => model.trim(),
        _ => '',
      },
    );
  }
}
