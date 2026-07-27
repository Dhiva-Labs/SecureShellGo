import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/known_host.dart';
import '../services/known_hosts_service.dart';
import '../theme.dart';

/// Lists every trusted host key and lets the user forget one.
///
/// Backed entirely by [KnownHostsService.all] / [KnownHostsService.forgetHost]
/// — both already existed for Phase 1's trust-on-first-use flow (see
/// ARCHITECTURE.md). Forgetting removes every key type stored for that
/// host:port, matching what `ssh-keygen -R` does and what "forget host keys"
/// on the host list screen also does.
class KnownHostsScreen extends StatefulWidget {
  const KnownHostsScreen({super.key, required this.knownHosts});

  final KnownHostsService knownHosts;

  @override
  State<KnownHostsScreen> createState() => _KnownHostsScreenState();
}

class _KnownHostsScreenState extends State<KnownHostsScreen> {
  late Future<List<KnownHostKey>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.knownHosts.all();
  }

  void _refresh() {
    setState(() => _future = widget.knownHosts.all());
  }

  Future<void> _forget(KnownHostKey key) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Forget this host key?'),
        content: Text(
          'The next connection to ${key.hostname}:${key.port} will be '
          'treated as first-use again and ask you to verify its key.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    await widget.knownHosts.forgetHost(key.hostname, key.port);
    if (!mounted) return;
    _refresh();
  }

  /// Puts the fingerprint on the clipboard, for comparing it against one
  /// obtained out-of-band (the server console, an admin over a trusted
  /// channel) without having to retype a `SHA256:` string by hand.
  Future<void> _copyFingerprint(KnownHostKey key) async {
    await Clipboard.setData(ClipboardData(text: key.fingerprint));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Fingerprint copied')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Known hosts')),
      body: FutureBuilder<List<KnownHostKey>>(
        future: _future,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final keys = snapshot.data!;
          if (keys.isEmpty) {
            return _EmptyKnownHosts();
          }
          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: keys.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final key = keys[index];
              return Dismissible(
                key: ValueKey(key.id),
                direction: DismissDirection.endToStart,
                confirmDismiss: (_) async {
                  await _forget(key);
                  return false; // _forget already refreshes the list.
                },
                background: Container(
                  color: AppTheme.danger.withValues(alpha: 0.2),
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: const Icon(Icons.delete_outline, color: AppTheme.danger),
                ),
                child: ListTile(
                  leading: const Icon(Icons.vpn_key_outlined),
                  title: Text(
                    key.port == 22 ? key.hostname : '${key.hostname}:${key.port}',
                  ),
                  subtitle: _KnownHostSubtitle(
                    hostKey: key,
                    addedLabel: _formatDate(key.addedAt),
                    onCopyFingerprint: () =>
                        unawaited(_copyFingerprint(key)),
                  ),
                  isThreeLine: true,
                  trailing: IconButton(
                    tooltip: 'Forget',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _forget(key),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  static String _formatDate(DateTime date) {
    final local = date.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)}';
  }
}

/// Key type, fingerprint and added-date, as the [ListTile.subtitle] of one
/// known-host row. The fingerprint line is the only part that responds to a
/// tap — comparing it against one obtained out-of-band is the whole point of
/// this screen, and one tap to copy it beats a long-press-then-select.
class _KnownHostSubtitle extends StatelessWidget {
  const _KnownHostSubtitle({
    required this.hostKey,
    required this.addedLabel,
    required this.onCopyFingerprint,
  });

  final KnownHostKey hostKey;
  final String addedLabel;
  final VoidCallback onCopyFingerprint;

  static const _baseStyle = TextStyle(
    fontFamily: AppTheme.monoFontFamily,
    fontFamilyFallback: AppTheme.monoFontFamilyFallback,
    fontSize: 11.5,
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mutedStyle = _baseStyle.copyWith(color: scheme.onSurfaceVariant);

    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(hostKey.keyType, style: mutedStyle),
          InkWell(
            onTap: onCopyFingerprint,
            child: Text(
              hostKey.fingerprint,
              style: _baseStyle.copyWith(
                color: scheme.primary,
                decoration: TextDecoration.underline,
                decorationColor: scheme.primary.withValues(alpha: 0.4),
              ),
            ),
          ),
          Text('Added $addedLabel', style: mutedStyle),
        ],
      ),
    );
  }
}

class _EmptyKnownHosts extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.shield_outlined,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              'No trusted host keys yet',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Keys are added automatically the first time you connect to a '
              'new server and accept its fingerprint.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
