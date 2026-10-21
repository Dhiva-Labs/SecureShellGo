import '../../l10n/l10n.dart';
import '../../models/app_settings.dart';
import '../../services/app_lock.dart';

// What Settings calls each choice, in the app's language. Here rather than on
// the enums themselves because `models/` and `services/` stay free of Flutter,
// and the strings come from `context.l10n`.

extension TerminalColorSchemeLabel on TerminalColorScheme {
  /// The palettes named after their makers keep their names in every
  /// language; only the app's own and the two descriptive ones translate.
  String labelIn(AppLocalizations l10n) => switch (this) {
        TerminalColorScheme.classic =>
          l10n.settingsSchemeClassic(l10n.appTitle),
        TerminalColorScheme.dracula => 'Dracula',
        TerminalColorScheme.solarizedDark => 'Solarized Dark',
        TerminalColorScheme.solarizedLight => 'Solarized Light',
        TerminalColorScheme.nord => 'Nord',
        TerminalColorScheme.gruvboxDark => 'Gruvbox Dark',
        TerminalColorScheme.monokai => 'Monokai',
        TerminalColorScheme.oneDark => 'One Dark',
        TerminalColorScheme.blackOnWhite => l10n.settingsSchemeBlackOnWhite,
        TerminalColorScheme.retroGreen => l10n.settingsSchemeRetroGreen,
      };
}

extension UiStyleLabel on UiStyle {
  /// `aws`/`gcp`/`azure` evoke those consoles with an original palette, hence
  /// "-inspired" rather than a claim of affiliation.
  String labelIn(AppLocalizations l10n) => switch (this) {
        UiStyle.aurora => l10n.settingsStyleAurora,
        UiStyle.aws => l10n.settingsStyleAws,
        UiStyle.gcp => l10n.settingsStyleGcp,
        UiStyle.azure => l10n.settingsStyleAzure,
      };
}

extension ThemeBrightnessLabel on ThemeBrightness {
  String labelIn(AppLocalizations l10n) => switch (this) {
        ThemeBrightness.system => l10n.settingsBrightnessSystem,
        ThemeBrightness.light => l10n.settingsBrightnessLight,
        ThemeBrightness.dark => l10n.settingsBrightnessDark,
      };
}

extension AppLockTimeoutLabel on AppLockTimeout {
  String labelIn(AppLocalizations l10n) => this == AppLockTimeout.immediately
      ? l10n.settingsLockImmediately
      : l10n.settingsLockAfterMinutes(duration.inMinutes);
}

extension TerminalCursorStyleLabel on TerminalCursorStyle {
  String labelIn(AppLocalizations l10n) => switch (this) {
        TerminalCursorStyle.block => l10n.settingsCursorBlock,
        TerminalCursorStyle.underline => l10n.settingsCursorUnderline,
        TerminalCursorStyle.bar => l10n.settingsCursorBar,
      };
}

extension TerminalBellLabel on TerminalBell {
  String labelIn(AppLocalizations l10n) => switch (this) {
        TerminalBell.vibrate => l10n.settingsBellVibrate,
        TerminalBell.visual => l10n.settingsBellVisual,
        TerminalBell.off => l10n.settingsBellOff,
      };
}

extension TerminalFontLabel on TerminalFont {
  String labelIn(AppLocalizations l10n) => switch (this) {
        TerminalFont.system => l10n.settingsFontSystem,
        TerminalFont.jetBrainsMono => 'JetBrains Mono',
      };
}

extension KeyBarModeLabel on KeyBarMode {
  String labelIn(AppLocalizations l10n) => switch (this) {
        KeyBarMode.auto => l10n.settingsKeyBarAuto,
        KeyBarMode.always => l10n.settingsKeyBarAlways,
        KeyBarMode.never => l10n.settingsKeyBarNever,
      };
}

extension AppLockUnavailableText on AppLockUnavailable {
  /// The sentence under a disabled App lock toggle. Phrased as a fact about
  /// the platform, not an apology, and never implies the user has done
  /// something wrong.
  String textIn(AppLocalizations l10n) => switch (this) {
        AppLockUnavailable.linux => l10n.settingsAppLockLinux(l10n.appTitle),
        AppLockUnavailable.windowsHelloOff => l10n.settingsAppLockWindowsOff,
        AppLockUnavailable.macOS => l10n.settingsAppLockMacos,
        AppLockUnavailable.otherPlatform => l10n.settingsAppLockOtherPlatform,
      };
}

extension AppLockSetupText on AppLockSetup {
  String textIn(AppLocalizations l10n) => switch (this) {
        AppLockSetup.windowsHello => l10n.settingsAppLockSetupWindows,
        AppLockSetup.screenLock => l10n.settingsAppLockSetupDevice,
      };
}
