import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../services/host_store.dart';
import '../services/quick_connect_parser.dart' show defaultQuickConnectUsername;
import '../services/ssh_certificate.dart';
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

      // A certificate is public, so unlike the key it is read in: the
      // CertificateFile, or failing that the `-cert.pub` next to the
      // IdentityFile, which is where ssh looks too. Kept only if it reads as
      // a user certificate.
      String? readCertificate(SshConfigHostEntry entry) {
        final certificateFile = entry.certificateFile;
        final identityFile = entry.identityFile;
        final paths = [
          ?certificateFile,
          if (certificateFile == null && identityFile != null)
            '$identityFile-cert.pub',
        ];
        for (final path in paths) {
          try {
            final expanded = path.replaceAll('%d', home);
            final resolved = expanded.startsWith('~')
                ? '$home${expanded.substring(1)}'
                : File(expanded).isAbsolute
                    ? expanded
                    : '$home/$expanded';
            final file = File(resolved);
            if (!file.existsSync()) continue;
            return SshCertificate.parse(file.readAsStringSync()).line;
          } catch (_) {
            // Unreadable, or not a user certificate: imported without one.
          }
        }
        return null;
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
            certificate: readCertificate(entry),
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
        entry.toHost(
          id: widget.hostStore.newId(),
          username: candidate.resolvedUser,
          certificate: candidate.certificate,
        ),
      );
    }
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.sshConfigImportTitle)),
      body: _buildBody(),
      bottomNavigationBar: _buildImportBar(),
    );
  }

  Widget? _buildImportBar() {
    if (_loading || _loadError != null || _configPath == null) return null;
    final selectedCount = _candidates.where((c) => c.selected).length;
    final l10n = context.l10n;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: FilledButton(
          onPressed: selectedCount == 0 || _importing ? null : _import,
          child: Text(
            _importing
                ? l10n.sshConfigImportImporting
                : selectedCount == 0
                    ? l10n.sshConfigImportSelectPrompt
                    : l10n.sshConfigImportCount(selectedCount),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final l10n = context.l10n;
    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(l10n.sshConfigImportReadError(_loadError!)),
        ),
      );
    }
    if (_configPath == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(l10n.sshConfigImportNoFile),
        ),
      );
    }
    if (_candidates.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(l10n.sshConfigImportEmpty),
        ),
      );
    }

    return Column(
      children: [
        if (_warnings.isNotEmpty) _WarningsBanner(warnings: _warnings),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Wrap(
            alignment: WrapAlignment.end,
            children: [
              TextButton(
                onPressed: () => setState(() {
                  for (final c in _candidates) {
                    c.selected = true;
                  }
                }),
                child: Text(l10n.sshConfigImportSelectAll),
              ),
              TextButton(
                onPressed: () => setState(() {
                  for (final c in _candidates) {
                    c.selected = false;
                  }
                }),
                child: Text(l10n.sshConfigImportSelectNone),
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
                    if (candidate.alreadySaved ||
                        entry.identityFile != null ||
                        candidate.certificate != null ||
                        entry.forwardAgent ||
                        entry.forwardX11)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            if (candidate.alreadySaved)
                              _Badge(l10n.sshConfigImportBadgeSaved),
                            if (entry.identityFile != null)
                              _Badge(l10n.sshConfigImportBadgeKeyFile),
                            if (candidate.certificate != null)
                              _Badge(l10n.sshConfigImportBadgeCertificate),
                            if (entry.forwardAgent)
                              _Badge(l10n.sshConfigImportBadgeAgent),
                            if (entry.forwardX11) const _Badge('X11'),
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
    this.certificate,
  }) : selected = !alreadySaved;

  final SshConfigHostEntry entry;
  final String resolvedUser;
  final bool alreadySaved;

  /// The certificate line read for this entry, if one was found.
  final String? certificate;
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
