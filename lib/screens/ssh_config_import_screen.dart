import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../models/host.dart';
import '../services/host_store.dart';
import '../services/quick_connect_parser.dart' show defaultQuickConnectUsername;
import '../services/ssh_config_parser.dart';

/// Reads `~/.ssh/config`, previews every concrete `Host` block it (and one
/// level of `Include`) contains, and adds the checked ones to [hostStore].
///
/// Desktop only — reachable from the host list's overflow menu, which is
/// gated on the same platform check `file_browser_pane.dart` uses elsewhere.
/// `IdentityFile` contents are never read; a matching entry only earns a
/// "uses key file" badge here, and the key itself has to be added by
/// editing the host afterwards.
class SshConfigImportScreen extends StatefulWidget {
  const SshConfigImportScreen({super.key, required this.hostStore});

  final HostStore hostStore;

  @override
  State<SshConfigImportScreen> createState() => _SshConfigImportScreenState();
}

class _SshConfigImportScreenState extends State<SshConfigImportScreen> {
  bool _loading = true;
  String? _loadError;
  String? _configPath;
  List<String> _warnings = const [];
  List<_ImportCandidate> _candidates = const [];
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final home =
          Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';
      final sshDir = '$home/.ssh';
      final configFile = File('$sshDir/config');

      if (!await configFile.exists()) {
        if (!mounted) return;
        setState(() => _loading = false);
        return;
      }

      final contents = await configFile.readAsString();

      String? readInclude(String path) {
        try {
          final resolved = path.startsWith('~')
              ? '$home${path.substring(1)}'
              : path.startsWith('/')
                  ? path
                  : '$sshDir/$path';
          final file = File(resolved);
          if (!file.existsSync()) return null;
          return file.readAsStringSync();
        } catch (_) {
          return null;
        }
      }

      final result = SshConfigParser.parse(contents, readInclude: readInclude);
      final existingHosts = await widget.hostStore.all();

      bool alreadySaved(SshConfigHostEntry entry, String user) {
        return existingHosts.any(
          (h) =>
              h.hostname == entry.hostname &&
              h.port == entry.port &&
              h.username == user,
        );
      }

      final candidates = [
        for (final entry in result.entries)
          _ImportCandidate(
            entry: entry,
            resolvedUser: entry.user ?? defaultQuickConnectUsername(),
            alreadySaved: alreadySaved(
              entry,
              entry.user ?? defaultQuickConnectUsername(),
            ),
          ),
      ];

      if (!mounted) return;
      setState(() {
        _configPath = configFile.path;
        _warnings = result.warnings;
        _candidates = candidates;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _import() async {
    final chosen = _candidates.where((c) => c.selected).toList();
    if (chosen.isEmpty || _importing) return;

    setState(() => _importing = true);
    for (final candidate in chosen) {
      final entry = candidate.entry;
      await widget.hostStore.add(
        Host(
          id: widget.hostStore.newId(),
          label: entry.alias,
          hostname: entry.hostname,
          port: entry.port,
          username: candidate.resolvedUser,
          authMethod: entry.identityFile != null
              ? SshAuthMethod.privateKey
              : SshAuthMethod.password,
        ),
      );
    }
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Import from ~/.ssh/config')),
      body: _buildBody(),
      bottomNavigationBar: _buildImportBar(),
    );
  }

  Widget? _buildImportBar() {
    if (_loading || _loadError != null || _configPath == null) return null;
    final selectedCount = _candidates.where((c) => c.selected).length;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: FilledButton(
          onPressed: selectedCount == 0 || _importing ? null : _import,
          child: Text(
            _importing
                ? 'Importing…'
                : selectedCount == 0
                    ? 'Select servers to import'
                    : 'Import $selectedCount server'
                        '${selectedCount == 1 ? '' : 's'}',
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('Could not read ~/.ssh/config: $_loadError'),
        ),
      );
    }
    if (_configPath == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('No ~/.ssh/config file found on this machine.'),
        ),
      );
    }
    if (_candidates.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('No importable servers found in ~/.ssh/config.'),
        ),
      );
    }

    return Column(
      children: [
        if (_warnings.isNotEmpty) _WarningsBanner(warnings: _warnings),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => setState(() {
                  for (final c in _candidates) {
                    c.selected = true;
                  }
                }),
                child: const Text('Select all'),
              ),
              TextButton(
                onPressed: () => setState(() {
                  for (final c in _candidates) {
                    c.selected = false;
                  }
                }),
                child: const Text('Select none'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            itemCount: _candidates.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final candidate = _candidates[index];
              final entry = candidate.entry;
              return CheckboxListTile(
                value: candidate.selected,
                onChanged: (value) =>
                    setState(() => candidate.selected = value ?? false),
                title: Text(entry.alias),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${candidate.resolvedUser}@${entry.hostname}:${entry.port}',
                    ),
                    if (candidate.alreadySaved || entry.identityFile != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Wrap(
                          spacing: 6,
                          children: [
                            if (candidate.alreadySaved)
                              const _Badge('already saved'),
                            if (entry.identityFile != null)
                              const _Badge('uses key file'),
                          ],
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ImportCandidate {
  _ImportCandidate({
    required this.entry,
    required this.resolvedUser,
    required this.alreadySaved,
  }) : selected = !alreadySaved;

  final SshConfigHostEntry entry;
  final String resolvedUser;
  final bool alreadySaved;
  bool selected;
}

class _Badge extends StatelessWidget {
  const _Badge(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label, style: const TextStyle(fontSize: 11)),
    );
  }
}

class _WarningsBanner extends StatelessWidget {
  const _WarningsBanner({required this.warnings});

  final List<String> warnings;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final warning in warnings)
              Text(warning, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
