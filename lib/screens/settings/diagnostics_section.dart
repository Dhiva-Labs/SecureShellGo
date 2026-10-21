import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
    final text = await _log.read();
    if (text.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('The diagnostics log is empty.')),
      );
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          'Copied ${_describeSize(text.length)} of diagnostics. Paste them '
          'into your bug report.',
        ),
      ),
    );
  }

  Future<void> _clear(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    await _log.clear();
    messenger.showSnackBar(
      const SnackBar(content: Text('Diagnostics log cleared.')),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSectionHeader('Diagnostics', style: settings.uiStyle),
        SwitchListTile(
          secondary: const Icon(Icons.bug_report_outlined),
          title: const Text('Keep a diagnostics log'),
          subtitle: const Text(
            'Records errors and crashes on this device, with passwords and '
            'keys removed, for you to copy into a bug report. Nothing is '
            'sent anywhere.',
          ),
          value: settings.diagnosticsLog,
          onChanged: (on) => apply((s) => s.copyWith(diagnosticsLog: on)),
        ),
        // Turning the log off deletes it, so these only make sense while it
        // is on.
        if (settings.diagnosticsLog) ...[
          ListTile(
            leading: const Icon(Icons.copy_all_outlined),
            title: const Text('Copy diagnostics'),
            subtitle: const Text('Puts the log on the clipboard'),
            onTap: () => unawaited(_copy(context)),
          ),
          ListTile(
            leading: const Icon(Icons.article_outlined),
            title: const Text('View diagnostics'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _view(context),
          ),
          ListTile(
            leading: const Icon(Icons.delete_sweep_outlined),
            title: const Text('Clear diagnostics'),
            onTap: () => unawaited(_clear(context)),
          ),
        ],
      ],
    );
  }
}

String _describeSize(int characters) {
  if (characters < 1024) return '$characters characters';
  return '${(characters / 1024).toStringAsFixed(characters < 10240 ? 1 : 0)} KB';
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
    final text = await _text;
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    messenger.showSnackBar(
      const SnackBar(content: Text('Diagnostics copied.')),
    );
  }

  void _clear() {
    setState(() {
      _text = widget.log.clear().then((_) => '');
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnostics log'),
        actions: [
          IconButton(
            tooltip: 'Copy',
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: () => unawaited(_copy()),
          ),
          IconButton(
            tooltip: 'Clear',
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
                  'Nothing has been recorded.',
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
