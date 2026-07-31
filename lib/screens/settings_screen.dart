import 'dart:async';

import 'package:flutter/material.dart';

import '../models/app_settings.dart';
import '../services/known_hosts_service.dart';
import '../services/settings_store.dart';
import '../services/snippet_store.dart';
import '../theme.dart';
import 'known_hosts_screen.dart';
import 'snippets_screen.dart';

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
  });

  final SettingsStore settingsStore;
  final KnownHostsService knownHosts;

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

  @override
  void initState() {
    super.initState();
    _settings = widget.settingsStore.current;
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
              const Divider(height: 32),
              const _SectionHeader('Security'),
              ListTile(
                leading: const Icon(Icons.vpn_key_outlined),
                title: const Text('Known hosts'),
                subtitle: const Text('Manage trusted host keys'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _openKnownHosts,
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
              color: AppTheme.accent,
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
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
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
        border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
      ),
      child: Row(
        children: [
          for (final color in strip) Expanded(child: ColoredBox(color: color)),
        ],
      ),
    );
  }
}
