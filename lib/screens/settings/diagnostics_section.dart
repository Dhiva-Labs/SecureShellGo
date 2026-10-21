import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../l10n/l10n.dart';
import '../../models/app_settings.dart';
import '../../services/diagnostics_log.dart';
import '../../theme.dart';
import 'settings_section.dart';

/// The local diagnostics log a bug report can be built from.
class DiagnosticsSettingsSection extends StatelessWidget {
  const DiagnosticsSettingsSection({
    super.key,
    required this.settings,
    required this.apply,
    this.log,
  });

  final AppSettings settings;
  final SettingsChange apply;

  /// The log the buttons act on. [DiagnosticsLog.instance] unless a test
  /// hands in its own.
  final DiagnosticsLog? log;

  DiagnosticsLog get _log => log ?? DiagnosticsLog.instance;

  Future<void> _copy(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.l10n;
    final text = await _log.read();
    if (text.isEmpty) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.settingsDiagnosticsEmpty)),
      );
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          l10n.settingsDiagnosticsCopied(_describeSize(l10n, text.length)),
        ),
      ),
    );
  }

  Future<void> _clear(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.l10n;
    await _log.clear();
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.settingsDiagnosticsCleared)),
    );
  }

  void _view(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DiagnosticsLogScreen(log: _log),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSectionHeader(
          l10n.settingsDiagnostics,
          style: settings.uiStyle,
        ),
        SwitchListTile(
          secondary: const Icon(Icons.bug_report_outlined),
          title: Text(l10n.settingsDiagnosticsKeep),
          subtitle: Text(l10n.settingsDiagnosticsKeepHelp),
          value: settings.diagnosticsLog,
          onChanged: (on) => apply((s) => s.copyWith(diagnosticsLog: on)),
        ),
        // Turning the log off deletes it, so these only make sense while it
        // is on.
        if (settings.diagnosticsLog) ...[
          ListTile(
            leading: const Icon(Icons.copy_all_outlined),
            title: Text(l10n.settingsDiagnosticsCopy),
            subtitle: Text(l10n.settingsDiagnosticsCopyHelp),
            onTap: () => unawaited(_copy(context)),
          ),
          ListTile(
            leading: const Icon(Icons.article_outlined),
            title: Text(l10n.settingsDiagnosticsView),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _view(context),
          ),
          ListTile(
            leading: const Icon(Icons.delete_sweep_outlined),
            title: Text(l10n.settingsDiagnosticsClear),
            onTap: () => unawaited(_clear(context)),
          ),
        ],
      ],
    );
  }
}

String _describeSize(AppLocalizations l10n, int characters) {
  if (characters < 1024) return l10n.settingsDiagnosticsCharacters(characters);
  final kilobytes = NumberFormat.decimalPatternDigits(
    locale: l10n.localeName,
    decimalDigits: characters < 10240 ? 1 : 0,
  ).format(characters / 1024);
  return l10n.settingsDiagnosticsKilobytes(kilobytes);
}

/// The diagnostics log, read-only, with Copy and Clear.
class DiagnosticsLogScreen extends StatefulWidget {
  const DiagnosticsLogScreen({super.key, required this.log});

  final DiagnosticsLog log;

  @override
  State<DiagnosticsLogScreen> createState() => _DiagnosticsLogScreenState();
}

class _DiagnosticsLogScreenState extends State<DiagnosticsLogScreen> {
  late Future<String> _text = widget.log.read();

  Future<void> _copy() async {
    final messenger = ScaffoldMessenger.of(context);
    final copied = context.l10n.settingsDiagnosticsCopiedShort;
    final text = await _text;
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    messenger.showSnackBar(SnackBar(content: Text(copied)));
  }

  void _clear() {
    setState(() {
      _text = widget.log.clear().then((_) => '');
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.settingsDiagnosticsLogTitle),
        actions: [
          IconButton(
            tooltip: MaterialLocalizations.of(context).copyButtonLabel,
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: () => unawaited(_copy()),
          ),
          IconButton(
            tooltip: l10n.settingsDiagnosticsClearShort,
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: _clear,
          ),
        ],
      ),
      body: FutureBuilder<String>(
        future: _text,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final text = snapshot.data ?? '';
          if (text.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  l10n.settingsDiagnosticsNothing,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            );
          }
          return Scrollbar(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: SelectableText(
                text,
                style: TextStyle(
                  fontFamily: AppTheme.monoFontFamily,
                  fontFamilyFallback: AppTheme.monoFontFamilyFallback,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
