import 'dart:async';

import 'package:flutter/material.dart';

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
import 'backup_screen.dart';
import 'known_hosts_screen.dart';
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
        builder: (_) => TunnelsScreen(tunnels: tunnels, hostStore: hostStore),
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
    showAboutDialog(
      context: context,
      applicationName: 'SecureShell Go',
      applicationVersion: '1.0.0',
      applicationIcon: const Icon(Icons.terminal, size: 40),
      children: const [
        Text(
          'An SSH terminal client with an SFTP file browser. Host keys are '
          'checked against a local known-hosts store using trust-on-first-use, '
          'a changed key blocks the connection until you explicitly approve '
          'it, and that store is sealed with a key held in the device '
          'keystore. Saved passwords and keys are encrypted on-device.',
        ),
      ],
    );
  }

  /// The app-lock block: the toggle, the honest description of what it does,
  /// and the idle timeout once it is on.
  List<Widget> _appLockRows(ThemeData theme) {
    final support = _lockSupport;
    final available = support == AppLockSupport.available;
    final enabled = _settings.appLockEnabled && available;

    final String explanation;
    if (support == null) {
      explanation = 'Checking whether this device can lock the app…';
    } else if (support == AppLockSupport.noDeviceCredential) {
      explanation = 'Set a screen lock (PIN, pattern, password or biometric) '
          'on this device first, then this can be turned on.';
    } else if (!available) {
      explanation = AppLockPlatform.currentReason;
    } else {
      // The one sentence this feature must not overstate. A UI gate is not
      // encryption, and implying otherwise would let someone conclude their
      // data is safer than it is.
      explanation = "Locks the app's screen. Your saved passwords are always "
          "encrypted by your system's secure storage, with or without this.";
    }

    return [
      SwitchListTile(
        secondary: const Icon(Icons.lock_outline),
        title: const Text('App lock'),
        subtitle: Text(
          available
              ? 'Ask for this device\'s unlock method before showing the app'
              : 'Unavailable on this device',
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
          child: Text('Lock when away for', style: theme.textTheme.bodyLarge),
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
                  title: Text(timeout.label),
                  dense: true,
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Text(
            'Sessions and tunnels keep running while the app is locked.',
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
    final divisions =
        (AppSettings.maxFontSize - AppSettings.minFontSize).round();

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      // A no-op on a phone; on a tablet or DeX window this keeps the
      // preference rows from stretching edge to edge.
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: ListView(
            children: [
              const _SectionHeader('Appearance'),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Text('UI style', style: theme.textTheme.bodyLarge),
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
                        title: Text(style.label),
                        secondary: _UiStylePreview(
                          style: style,
                          brightness: _effectiveBrightness(context),
                        ),
                        dense: true,
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text('Brightness', style: theme.textTheme.bodyLarge),
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
                        title: Text(brightness.label),
                        dense: true,
                      ),
                  ],
                ),
              ),
              const Divider(height: 32),
              const _SectionHeader('Terminal'),
              _TerminalPreview(settings: _settings),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                child: Row(
                  children: [
                    Text('Font size', style: theme.textTheme.bodyLarge),
                    const Spacer(),
                    Text(
                      '${_settings.terminalFontSize.round()} pt',
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
                  label: '${_settings.terminalFontSize.round()} pt',
                  onChanged: _previewFontSize,
                  onChangeEnd: _persistFontSize,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text('Colour scheme', style: theme.textTheme.bodyLarge),
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
                        title: Text(scheme.label),
                        secondary: _SchemeSwatch(scheme: scheme),
                        dense: true,
                      ),
                  ],
                ),
              ),
              const Divider(height: 32),
              const _SectionHeader('Session'),
              SwitchListTile(
                title: const Text('Keep screen awake'),
                subtitle: const Text(
                  'Prevents the screen from sleeping while a session is open',
                ),
                value: _settings.keepScreenAwake,
                onChanged: (value) => unawaited(
                  _apply((s) => s.copyWith(keepScreenAwake: value)),
                ),
              ),
              SwitchListTile(
                title: const Text('Show hidden files by default'),
                subtitle: const Text(
                  'Applies the next time you open the file browser',
                ),
                value: _settings.showHiddenFilesByDefault,
                onChanged: (value) => unawaited(
                  _apply((s) => s.copyWith(showHiddenFilesByDefault: value)),
                ),
              ),
              const Divider(height: 32),
              const _SectionHeader('Commands'),
              ListTile(
                leading: const Icon(Icons.bolt_outlined),
                title: const Text('Snippets'),
                subtitle: const Text('Saved commands you can send to any session'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _openSnippets,
              ),
              if (widget.tunnels != null && widget.hostStore != null) ...[
                const Divider(height: 32),
                const _SectionHeader('Networking'),
                ListTile(
                  leading: const Icon(Icons.swap_horiz),
                  title: const Text('Tunnels'),
                  subtitle: const Text(
                    'Forward ports over a saved host, or run a SOCKS5 proxy',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _openTunnels,
                ),
              ],
              const Divider(height: 32),
              const _SectionHeader('Security'),
              if (widget.appLock != null) ..._appLockRows(theme),
              ListTile(
                leading: const Icon(Icons.vpn_key_outlined),
                title: const Text('Known hosts'),
                subtitle: const Text('Manage trusted host keys'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _openKnownHosts,
              ),
              if (widget.backupService != null)
                ListTile(
                  leading: const Icon(Icons.archive_outlined),
                  title: const Text('Backup'),
                  subtitle: const Text(
                    'Export or restore an encrypted copy of your setup',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _openBackup,
                ),
              const Divider(height: 32),
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('About SecureShell Go'),
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

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

/// A tiny live sample of the chosen font size and colour scheme, so the
/// slider and radio list have something to preview against instead of the
/// user having to imagine it.
class _TerminalPreview extends StatelessWidget {
  const _TerminalPreview({required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final palette = AppTheme.terminalThemeFor(settings.colorScheme);
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
            ],
          ),
          style: TextStyle(
            fontFamily: AppTheme.monoFontFamily,
            fontFamilyFallback: AppTheme.monoFontFamilyFallback,
            fontSize: settings.terminalFontSize,
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
        children: [
          for (final color in strip) Expanded(child: ColoredBox(color: color)),
        ],
      ),
    );
  }
}

/// A miniature mock-up of one [UiStyle] + [Brightness] combination — an
/// app-bar strip, a card in that style's own corner radius and
/// border/shadow treatment, and the style's accent as a dot — so the radio
/// list previews the actual look rather than naming it and hoping.
///
/// Built straight from the real [ThemeData] `AppTheme.themeFor` returns
/// (not a second hand-copied palette), so this can never drift from what
/// choosing the option actually applies.
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

    return Container(
      width: 72,
      height: 52,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: previewTheme.scaffoldBackgroundColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Mock app bar.
          Container(
            height: 14,
            color: previewTheme.appBarTheme.backgroundColor ?? scheme.surface,
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Mock card, in the style's own corner radius and
                  // border-vs-shadow treatment.
                  Expanded(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: previewTheme.cardTheme.color ?? scheme.surface,
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
                  ),
                  const SizedBox(width: 5),
                  // The style's accent.
                  Container(
                    width: 10,
                    height: 10,
                    margin: const EdgeInsets.only(top: 2),
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
