import 'dart:async';

import 'package:flutter/material.dart';

import '../app_version.dart';
import '../l10n/l10n.dart';
import '../models/app_settings.dart';
import '../services/app_lock.dart';
import '../services/app_lock_controller.dart';
import '../services/backup_service.dart';
import '../services/host_store.dart';
import '../services/known_hosts_service.dart';
import '../services/settings_store.dart';
import '../services/snippet_store.dart';
import '../services/tunnel_runtime.dart';
import '../theme.dart';
import '../widgets/terminal_fonts.dart';
import 'backup_screen.dart';
import 'known_hosts_screen.dart';
import 'settings/diagnostics_section.dart';
import 'settings/editor_section.dart';
import 'settings/input_section.dart';
import 'settings/language_section.dart';
import 'settings/setting_labels.dart';
import 'settings/settings_section.dart';
import 'settings/terminal_section.dart';
import 'snippets_screen.dart';
import 'tunnels_screen.dart';

/// Terminal look-and-feel, session behaviour, and the about box.
///
/// Backed by [SettingsStore] — plain JSON, not secure storage, since nothing
/// here is a secret. Reached from the settings icon on the host list's app
/// bar; the previous separate "Known hosts" and "About" app-bar icons live
/// here now too, so there is one place for everything that is not a saved
/// host or a live session.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.settingsStore,
    required this.knownHosts,
    this.snippetStore,
    this.tunnels,
    this.hostStore,
    this.appLock,
    this.backupService,
  });

  final SettingsStore settingsStore;
  final KnownHostsService knownHosts;

  /// Backs the "App lock" rows. Optional, like [snippetStore] below — a
  /// caller that has not built one still gets a working settings screen,
  /// just without that section.
  final AppLockController? appLock;

  /// Backs the "Backup" row.
  final BackupService? backupService;

  /// Backs the "Tunnels" row. Both this and [hostStore] are needed to open
  /// that screen at all — a tunnel is a profile plus the host that carries
  /// it — so the row appears only when both were handed down.
  final TunnelRuntime? tunnels;
  final HostStore? hostStore;

  /// Backs the "Snippets" row below. Optional so a caller that does not
  /// care about snippets still gets a working screen, same reasoning as
  /// `HostListScreen.shareIntake`.
  final SnippetStore? snippetStore;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late AppSettings _settings;
  late final SnippetStore _snippetStore =
      widget.snippetStore ?? SnippetStore();

  /// Null until the platform has been asked. The toggle stays disabled in
  /// the meantime rather than flicking from on to off once the answer lands.
  AppLockSupport? _lockSupport;

  @override
  void initState() {
    super.initState();
    _settings = widget.settingsStore.current;
    final lock = widget.appLock;
    if (lock != null) {
      unawaited(
        lock.support().then((support) {
          if (mounted) setState(() => _lockSupport = support);
        }),
      );
    }
  }

  /// Updates the live preview immediately and persists in the background —
  /// switches and the colour-scheme picker want both; the font slider calls
  /// [_previewFontSize] + [_persist] separately so dragging does not write to
  /// disk on every frame.
  Future<void> _apply(AppSettings Function(AppSettings current) change) async {
    final next = change(_settings);
    setState(() => _settings = next);
    await widget.settingsStore.save(next);
  }

  /// Which of a [UiStyle]'s two variants the style previews below — and the
  /// running app, once [ThemeBrightness.system] is chosen — should render
  /// right now.
  /// Whether the UI-style list has width for its previews beside the names:
  /// always, except on a phone narrower than 360dp with text scaled past
  /// 120%.
  bool _roomForStylePreviews(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= 360 ||
      MediaQuery.textScalerOf(context).scale(14) / 14 <= 1.2;

  Brightness _effectiveBrightness(BuildContext context) {
    return switch (_settings.themeBrightness) {
      ThemeBrightness.light => Brightness.light,
      ThemeBrightness.dark => Brightness.dark,
      ThemeBrightness.system => MediaQuery.platformBrightnessOf(context),
    };
  }

  void _previewFontSize(double size) {
    setState(
      () => _settings = _settings.copyWith(terminalFontSize: size),
    );
  }

  Future<void> _persistFontSize(double size) {
    return widget.settingsStore.update(
      (s) => s.copyWith(terminalFontSize: size),
    );
  }

  void _openKnownHosts() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => KnownHostsScreen(knownHosts: widget.knownHosts),
      ),
    );
  }

  void _openSnippets() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SnippetsScreen(snippetStore: _snippetStore),
      ),
    );
  }

  void _openTunnels() {
    final tunnels = widget.tunnels;
    final hostStore = widget.hostStore;
    if (tunnels == null || hostStore == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TunnelsScreen(
          tunnels: tunnels,
          hostStore: hostStore,
          uiStyle: _settings.uiStyle,
        ),
      ),
    );
  }

  void _openBackup() {
    final service = widget.backupService;
    if (service == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BackupScreen(service: service),
      ),
    );
  }

  void _showAbout() {
    final l10n = context.l10n;
    showAboutDialog(
      context: context,
      applicationName: l10n.appTitle,
      applicationVersion: appDisplayVersion,
      applicationIcon: const Icon(Icons.terminal, size: 40),
      children: [Text(l10n.settingsAboutText)],
    );
  }

  /// The app-lock block: the toggle, the honest description of what it does,
  /// and the idle timeout once it is on.
  List<Widget> _appLockRows(ThemeData theme, AppLocalizations l10n) {
    final support = _lockSupport;
    final available = support == AppLockSupport.available;
    final enabled = _settings.appLockEnabled && available;

    final String explanation;
    if (support == null) {
      explanation = l10n.settingsAppLockChecking;
    } else if (support == AppLockSupport.noDeviceCredential) {
      explanation = AppLockPlatform.currentSetupHint.textIn(l10n);
    } else if (!available) {
      explanation = AppLockPlatform.currentReason.textIn(l10n);
    } else {
      // The one sentence this feature must not overstate. A UI gate is not
      // encryption, and implying otherwise would let someone conclude their
      // data is safer than it is.
      explanation = l10n.settingsAppLockExplanation;
    }

    return [
      SwitchListTile(
        secondary: const Icon(Icons.lock_outline),
        title: Text(l10n.settingsAppLock),
        subtitle: Text(
          available
              ? l10n.settingsAppLockAsk
              : l10n.settingsAppLockUnavailable,
        ),
        value: enabled,
        onChanged: available
            ? (value) => unawaited(
                  _apply((s) => s.copyWith(appLockEnabled: value)),
                )
            : null,
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(72, 0, 16, 12),
        child: Text(
          explanation,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.35,
          ),
        ),
      ),
      if (enabled) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Text(
            l10n.settingsAppLockAfter,
            style: theme.textTheme.bodyLarge,
          ),
        ),
        RadioGroup<AppLockTimeout>(
          groupValue: _settings.appLockTimeout,
          onChanged: (value) {
            if (value != null) {
              unawaited(_apply((s) => s.copyWith(appLockTimeout: value)));
            }
          },
          child: Column(
            children: [
              for (final timeout in AppLockTimeout.values)
                RadioListTile<AppLockTimeout>(
                  value: timeout,
                  title: Text(timeout.labelIn(l10n)),
                  dense: true,
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Text(
            l10n.settingsAppLockKeepsRunning,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final divisions =
        (AppSettings.maxFontSize - AppSettings.minFontSize).round();
    final fontSize = l10n.settingsPointSize(_settings.terminalFontSize.round());

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitle)),
      // A no-op on a phone; on a tablet or DeX window this keeps the
      // preference rows from stretching edge to edge.
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: ListView(
            children: [
              SettingsSectionHeader(
                l10n.settingsAppearance,
                style: _settings.uiStyle,
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Text(
                  l10n.settingsUiStyle,
                  style: theme.textTheme.bodyLarge,
                ),
              ),
              RadioGroup<UiStyle>(
                groupValue: _settings.uiStyle,
                onChanged: (value) {
                  if (value != null) {
                    unawaited(_apply((s) => s.copyWith(uiStyle: value)));
                  }
                },
                child: Column(
                  children: [
                    for (final style in UiStyle.values)
                      RadioListTile<UiStyle>(
                        value: style,
                        title: Text(style.labelIn(l10n)),
                        // On a narrow phone with large text the preview
                        // squeezed each name into three lines; the name is
                        // the part that has to stay readable.
                        secondary: _roomForStylePreviews(context)
                            ? _UiStylePreview(
                                style: style,
                                brightness: _effectiveBrightness(context),
                              )
                            : null,
                        dense: true,
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text(
                  l10n.settingsBrightness,
                  style: theme.textTheme.bodyLarge,
                ),
              ),
              RadioGroup<ThemeBrightness>(
                groupValue: _settings.themeBrightness,
                onChanged: (value) {
                  if (value != null) {
                    unawaited(
                      _apply((s) => s.copyWith(themeBrightness: value)),
                    );
                  }
                },
                child: Column(
                  children: [
                    for (final brightness in ThemeBrightness.values)
                      RadioListTile<ThemeBrightness>(
                        value: brightness,
                        title: Text(brightness.labelIn(l10n)),
                        dense: true,
                      ),
                  ],
                ),
              ),
              LanguageSettingsSection(settings: _settings, apply: _apply),
              const Divider(height: 32),
              SettingsSectionHeader(
                l10n.settingsTerminal,
                style: _settings.uiStyle,
              ),
              _TerminalPreview(settings: _settings),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.settingsFontSize,
                        style: theme.textTheme.bodyLarge,
                      ),
                    ),
                    Text(
                      fontSize,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Slider(
                  value: _settings.terminalFontSize,
                  min: AppSettings.minFontSize,
                  max: AppSettings.maxFontSize,
                  divisions: divisions,
                  label: fontSize,
                  onChanged: _previewFontSize,
                  onChangeEnd: _persistFontSize,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text(
                  l10n.settingsColourScheme,
                  style: theme.textTheme.bodyLarge,
                ),
              ),
              RadioGroup<TerminalColorScheme>(
                groupValue: _settings.colorScheme,
                onChanged: (value) {
                  if (value != null) {
                    unawaited(_apply((s) => s.copyWith(colorScheme: value)));
                  }
                },
                child: Column(
                  children: [
                    for (final scheme in TerminalColorScheme.values)
                      RadioListTile<TerminalColorScheme>(
                        value: scheme,
                        title: Text(scheme.labelIn(l10n)),
                        secondary: _SchemeSwatch(scheme: scheme),
                        dense: true,
                      ),
                  ],
                ),
              ),
              TerminalOptionsSection(settings: _settings, apply: _apply),
              const Divider(height: 32),
              EditorSettingsSection(settings: _settings, apply: _apply),
              const Divider(height: 32),
              InputSettingsSection(settings: _settings, apply: _apply),
              const Divider(height: 32),
              SettingsSectionHeader(
                l10n.settingsSession,
                style: _settings.uiStyle,
              ),
              SwitchListTile(
                title: Text(l10n.settingsKeepScreenAwake),
                subtitle: Text(l10n.settingsKeepScreenAwakeHelp),
                value: _settings.keepScreenAwake,
                onChanged: (value) => unawaited(
                  _apply((s) => s.copyWith(keepScreenAwake: value)),
                ),
              ),
              SwitchListTile(
                title: Text(l10n.settingsShowHiddenFiles),
                subtitle: Text(l10n.settingsShowHiddenFilesHelp),
                value: _settings.showHiddenFilesByDefault,
                onChanged: (value) => unawaited(
                  _apply((s) => s.copyWith(showHiddenFilesByDefault: value)),
                ),
              ),
              const Divider(height: 32),
              SettingsSectionHeader(
                l10n.settingsCommands,
                style: _settings.uiStyle,
              ),
              ListTile(
                leading: const Icon(Icons.bolt_outlined),
                title: Text(l10n.settingsSnippets),
                subtitle: Text(l10n.settingsSnippetsHelp),
                trailing: const Icon(Icons.chevron_right),
                onTap: _openSnippets,
              ),
              if (widget.tunnels != null && widget.hostStore != null) ...[
                const Divider(height: 32),
                SettingsSectionHeader(
                  l10n.settingsNetworking,
                  style: _settings.uiStyle,
                ),
                ListTile(
                  leading: const Icon(Icons.swap_horiz),
                  title: Text(l10n.settingsTunnels),
                  subtitle: Text(l10n.settingsTunnelsHelp),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _openTunnels,
                ),
              ],
              const Divider(height: 32),
              SettingsSectionHeader(
                l10n.settingsSecurity,
                style: _settings.uiStyle,
              ),
              if (widget.appLock != null) ..._appLockRows(theme, l10n),
              ListTile(
                leading: const Icon(Icons.vpn_key_outlined),
                title: Text(l10n.settingsKnownHosts),
                subtitle: Text(l10n.settingsKnownHostsHelp),
                trailing: const Icon(Icons.chevron_right),
                onTap: _openKnownHosts,
              ),
              if (widget.backupService != null)
                ListTile(
                  leading: const Icon(Icons.archive_outlined),
                  title: Text(l10n.settingsBackup),
                  subtitle: Text(l10n.settingsBackupHelp),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _openBackup,
                ),
              const Divider(height: 32),
              DiagnosticsSettingsSection(settings: _settings, apply: _apply),
              const Divider(height: 32),
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: Text(l10n.settingsAbout(l10n.appTitle)),
                trailing: const Icon(Icons.chevron_right),
                onTap: _showAbout,
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

/// A tiny live sample of the chosen font, size, colour scheme and cursor, so
/// the slider and radio list have something to preview against instead of
/// the user having to imagine it.
class _TerminalPreview extends StatelessWidget {
  const _TerminalPreview({required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final palette = AppTheme.terminalThemeFor(settings.colorScheme);
    final size = settings.terminalFontSize;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
        decoration: BoxDecoration(
          color: palette.background,
          borderRadius: BorderRadius.circular(10),
          // The palette's own foreground, not a fixed white — a light
          // scheme like Solarized Light needs a dark hairline here, not an
          // invisible one.
          border: Border.all(
            color: palette.foreground.withValues(alpha: 0.18),
          ),
        ),
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(text: 'user@host', style: TextStyle(color: palette.green)),
              TextSpan(text: ':', style: TextStyle(color: palette.foreground)),
              TextSpan(text: '~', style: TextStyle(color: palette.blue)),
              TextSpan(
                text: r'$ ls -la',
                style: TextStyle(color: palette.foreground),
              ),
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: _PreviewCursor(
                  shape: settings.cursorStyle,
                  color: palette.cursor,
                  // A monospace cell is a little over half as wide as it is
                  // high; near enough for a sample.
                  width: size * 0.6,
                  height: size * 1.25,
                ),
              ),
            ],
          ),
          style: TextStyle(
            fontFamily: TerminalFonts.familyFor(settings.terminalFont),
            fontFamilyFallback: TerminalFonts.fallbackFor(settings.terminalFont),
            fontSize: size,
          ),
        ),
      ),
    );
  }
}

/// The cursor at the end of the preview's prompt, in the chosen shape. Not
/// blinking: a preview that moved would pull the eye from the rest of the
/// page.
class _PreviewCursor extends StatelessWidget {
  const _PreviewCursor({
    required this.shape,
    required this.color,
    required this.width,
    required this.height,
  });

  final TerminalCursorStyle shape;
  final Color color;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final line = (height / 10).clamp(1.0, 3.0);
    return Padding(
      padding: EdgeInsets.only(left: width * 0.3),
      child: SizedBox(
        width: width,
        height: height,
        child: Align(
          alignment: switch (shape) {
            TerminalCursorStyle.block => Alignment.center,
            TerminalCursorStyle.underline => Alignment.bottomCenter,
            TerminalCursorStyle.bar => Alignment.centerLeft,
          },
          child: SizedBox(
            width: shape == TerminalCursorStyle.bar ? line : width,
            height: shape == TerminalCursorStyle.underline ? line : height,
            child: ColoredBox(color: color),
          ),
        ),
      ),
    );
  }
}

/// A strip of the scheme's background plus its core ANSI colours, so the
/// radio list reads as a palette preview rather than a single swatch — the
/// background alone cannot tell Dracula and One Dark apart at a glance, but
/// the strip can.
class _SchemeSwatch extends StatelessWidget {
  const _SchemeSwatch({required this.scheme});

  final TerminalColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final palette = AppTheme.terminalThemeFor(scheme);
    final strip = [
      palette.background,
      palette.red,
      palette.green,
      palette.yellow,
      palette.blue,
      palette.magenta,
    ];
    return Container(
      width: 64,
      height: 30,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        // Same reasoning as `_TerminalPreview` above — the swatch strip's
        // own background varies per scheme, so its frame has to too.
        border: Border.all(
          color: palette.foreground.withValues(alpha: 0.2),
        ),
      ),
      child: Row(
        // Without this the bands vanish: a childless ColoredBox has no
        // intrinsic height, and the default centre alignment hands it loose
        // cross-axis constraints, so each band lays out zero pixels tall and
        // the swatch renders as an empty outline.
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final color in strip) Expanded(child: ColoredBox(color: color)),
        ],
      ),
    );
  }
}

/// A miniature mock-up of one [UiStyle] + [Brightness] combination: an
/// app-bar strip, a tiny group header and two rows/cards laid out in that
/// style's own structural idiom — the same four idioms
/// `widgets/host_list_presentation.dart` renders full-size on the host list —
/// so the radio list previews the actual shape of the difference, not just a
/// colour swatch that leaves it a surprise until the host list is reopened.
///
/// Colours, corner radius and border-vs-shadow treatment are built straight
/// from the real [ThemeData] `AppTheme.themeFor` returns (not a second
/// hand-copied palette), so only those can never drift from what choosing
/// the option actually applies; the header/row/card *arrangement* below is
/// necessarily this widget's own miniature of that layout logic, the same
/// way the layout logic itself cannot be colour data.
class _UiStylePreview extends StatelessWidget {
  const _UiStylePreview({required this.style, required this.brightness});

  final UiStyle style;
  final Brightness brightness;

  @override
  Widget build(BuildContext context) {
    final previewTheme = AppTheme.themeFor(style, brightness);
    final scheme = previewTheme.colorScheme;
    final cardShape = previewTheme.cardTheme.shape;
    final cardRadius = cardShape is RoundedRectangleBorder
        ? cardShape.borderRadius
        : const BorderRadius.all(Radius.circular(4));
    final cardBorder = cardShape is RoundedRectangleBorder &&
            cardShape.side != BorderSide.none
        ? Border.fromBorderSide(cardShape.side)
        : null;
    final cardElevated = (previewTheme.cardTheme.elevation ?? 0) > 0;
    final cardColor = previewTheme.cardTheme.color ?? scheme.surface;
    final dividerColor =
        previewTheme.dividerTheme.color ?? scheme.outlineVariant;

    final Widget header;
    final Widget body;
    switch (style) {
      case UiStyle.aurora:
        header = _headerBar(
          scheme,
          background: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        );
        body = _cardGrid(scheme, cardColor, cardRadius, cardBorder, cardElevated);
      case UiStyle.aws:
        header = _headerBar(
          scheme,
          background: scheme.surfaceContainerHigh,
          dense: true,
        );
        body = _tableRows(scheme, dividerColor);
      case UiStyle.gcp:
        header = _headerBar(scheme, background: null, airy: true);
        body = _cardGrid(
          scheme,
          cardColor,
          cardRadius,
          cardBorder,
          cardElevated,
          gap: 6,
        );
      case UiStyle.azure:
        header = _headerBar(scheme, background: null, stripe: scheme.primary);
        body = _flatRows(scheme, dividerColor);
    }

    return Container(
      width: 88,
      height: 66,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: previewTheme.scaffoldBackgroundColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 9,
            color: previewTheme.appBarTheme.backgroundColor ?? scheme.surface,
          ),
          header,
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 3, 4, 4),
              child: body,
            ),
          ),
        ],
      ),
    );
  }

  /// A miniature of `_StyledGroupHeader` (`host_list_presentation.dart`):
  /// chevron dot, a bar standing in for the group name, a smaller one for
  /// the count. [stripe] draws azure's left accent; [dense] tightens the bar
  /// the way aws's tight bar does; [airy] (gcp) adds top breathing room
  /// instead of a background tint.
  Widget _headerBar(
    ColorScheme scheme, {
    required Color? background,
    bool dense = false,
    bool airy = false,
    Color? stripe,
  }) {
    return Container(
      color: background,
      padding: EdgeInsets.fromLTRB(4, airy ? 5 : 2, 4, dense ? 2 : 3),
      child: Row(
        children: [
          if (stripe != null) ...[
            Container(width: 2, height: 7, color: stripe),
            const SizedBox(width: 3),
          ],
          Container(
            width: 4,
            height: 4,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 3),
          Expanded(
            child: Container(
              height: 3,
              color: scheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(width: 3),
          Container(width: 6, height: 3, color: scheme.onSurfaceVariant),
        ],
      ),
    );
  }

  /// Two cards side by side, in the style's own corner radius and
  /// border-vs-shadow treatment — aurora's tight grid and gcp's airier one
  /// (wider [gap], gcp's own larger radius already does the rest).
  Widget _cardGrid(
    ColorScheme scheme,
    Color cardColor,
    BorderRadiusGeometry cardRadius,
    BoxBorder? cardBorder,
    bool cardElevated, {
    double gap = 3,
  }) {
    Widget card() => Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: cardColor,
              borderRadius: cardRadius,
              border: cardBorder,
              boxShadow: cardElevated
                  ? const [
                      BoxShadow(
                        color: Color(0x40000000),
                        blurRadius: 3,
                        offset: Offset(0, 1),
                      ),
                    ]
                  : null,
            ),
          ),
        );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [card(), SizedBox(width: gap), card()],
    );
  }

  /// aws's dense table: two single-line rows, each split into three aligned
  /// blocks standing in for name/target/last-connected, with a hairline
  /// separator — the one idiom with actual columns to preview.
  Widget _tableRows(ColorScheme scheme, Color dividerColor) {
    Widget row() => Row(
          children: [
            Expanded(
              flex: 3,
              child: Container(
                height: 3,
                color: scheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(width: 3),
            Expanded(
              flex: 3,
              child: Container(height: 3, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(width: 3),
            Expanded(
              flex: 2,
              child: Container(height: 3, color: scheme.onSurfaceVariant),
            ),
          ],
        );
    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        row(),
        Container(height: 1, color: dividerColor),
        row(),
      ],
    );
  }

  /// azure's flat list: two plain single-block rows with a divider between —
  /// no columns (that is aws's trait) and no card (no elevation, per azure's
  /// own description).
  Widget _flatRows(ColorScheme scheme, Color dividerColor) {
    // Two rows plus the divider have to fit the preview's 10px inner height;
    // at 5 apiece they came to 11 and overflowed by exactly one pixel.
    Widget row() => Container(
          height: 4,
          color: scheme.onSurface.withValues(alpha: 0.55),
        );
    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        row(),
        Container(height: 1, color: dividerColor),
        row(),
      ],
    );
  }
}
