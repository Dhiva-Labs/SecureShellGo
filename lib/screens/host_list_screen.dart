import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/host.dart';
import '../services/credential_store.dart';
import '../services/host_store.dart';
import '../services/known_hosts_service.dart';
import '../services/layout_breakpoints.dart';
import '../services/settings_store.dart';
import '../services/ssh_service.dart';
import '../theme.dart';
import '../widgets/host_key_dialog.dart';
import 'host_edit_screen.dart';
import 'session_screen.dart';
import 'settings_screen.dart';

/// The app's home screen: the list of saved hosts.
///
/// Replaces the Phase 1 [ConnectScreen] entirely. Tapping a host connects
/// immediately using its saved credentials; the FAB and each host's overflow
/// menu cover add/edit/delete and forgetting trusted host keys.
class HostListScreen extends StatefulWidget {
  const HostListScreen({
    super.key,
    required this.hostStore,
    required this.credentialStore,
    required this.knownHosts,
    required this.sshService,
    required this.settingsStore,
  });

  final HostStore hostStore;
  final CredentialStore credentialStore;
  final KnownHostsService knownHosts;
  final SshService sshService;
  final SettingsStore settingsStore;

  @override
  State<HostListScreen> createState() => _HostListScreenState();
}

class _HostListScreenState extends State<HostListScreen> {
  late Future<List<Host>> _future;

  /// The host currently being connected to, so only its tile shows a
  /// loading state while the rest of the list stays interactive.
  String? _connectingHostId;

  /// Set when the known-hosts store failed its integrity check on load and
  /// was dropped. Re-prompting for every host with no explanation would look
  /// like a bug; this says what actually happened.
  bool _trustStoreReset = false;

  @override
  void initState() {
    super.initState();
    _future = widget.hostStore.all();
    unawaited(_checkTrustStore());
  }

  Future<void> _checkTrustStore() async {
    await widget.knownHosts.ensureLoaded();
    if (!mounted || !widget.knownHosts.integrityFailed) return;
    setState(() => _trustStoreReset = true);
  }

  void _refresh() {
    // Deliberately a block body: with an arrow closure the assignment's value
    // (a Future) becomes the callback's return value, and setState throws
    // "callback argument returned a Future" AFTER running the callback but
    // BEFORE scheduling the rebuild — the field updates, the UI never
    // repaints. Verified live on the emulator via logcat.
    setState(() {
      _future = widget.hostStore.all();
    });
  }

  /// Same gotcha as [_refresh]: the future is created first and only then
  /// assigned inside a block-bodied `setState`, so the assignment itself
  /// never becomes the callback's return value. `RefreshIndicator` needs the
  /// `Future` back so it knows when to stop spinning.
  Future<void> _pullToRefresh() async {
    final future = widget.hostStore.all();
    setState(() {
      _future = future;
    });
    await future;
  }

  Future<void> _addHost() async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => HostEditScreen(
          hostStore: widget.hostStore,
          credentialStore: widget.credentialStore,
          sshService: widget.sshService,
          settingsStore: widget.settingsStore,
        ),
      ),
    );
    // Refresh unconditionally, the same way _connect() does on return from
    // SessionScreen: HostEditScreen already persisted the host itself before
    // popping (see _HostEditScreenState._save), so the list only has to
    // catch up with disk. Gating this on the popped result is what left the
    // list stale — anything that pops the route without echoing `true`
    // (a system back gesture, a future control that calls a bare
    // Navigator.pop()) skipped the refresh even though the host was saved.
    if (mounted) _refresh();
  }

  Future<void> _editHost(Host host) async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => HostEditScreen(
          hostStore: widget.hostStore,
          credentialStore: widget.credentialStore,
          sshService: widget.sshService,
          settingsStore: widget.settingsStore,
          host: host,
        ),
      ),
    );
    // See _addHost: refresh unconditionally rather than gating on the
    // popped result.
    if (mounted) _refresh();
  }

  Future<void> _connect(
    Host host, {
    SessionView view = SessionView.terminal,
  }) async {
    if (_connectingHostId != null) return;

    setState(() => _connectingHostId = host.id);

    final credentials = await widget.credentialStore.load(host.id);
    if (!mounted) return;

    if (credentials == null) {
      setState(() => _connectingHostId = null);
      await _showConnectError(
        'No saved credentials for this host.',
        details: 'Edit the host to enter its password or key again.',
        onEdit: () => _editHost(host),
      );
      return;
    }

    try {
      final connection = await widget.sshService.connect(
        host: host,
        credentials: credentials,
        verifyHostKey: (prompt) async {
          if (!mounted) return false;
          return showHostKeyDialog(context, prompt);
        },
      );

      if (!mounted) {
        connection.close();
        return;
      }

      // The handshake (and any host-key prompt) succeeded, so this is a real
      // connection, not just an attempt — record it for "last connected" on
      // the list. Best-effort: a write failure here should not block the
      // session the user is already in.
      unawaited(
        widget.hostStore.update(host.copyWith(lastConnectedAt: DateTime.now())),
      );

      setState(() => _connectingHostId = null);
      // From here the connection belongs to SessionScreen's SessionController,
      // which closes it when the route is popped.
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SessionScreen(
            connection: connection,
            initialView: view,
            settingsStore: widget.settingsStore,
          ),
        ),
      );
      if (mounted) _refresh();
    } on SshConnectionException catch (e) {
      if (!mounted) return;
      setState(() => _connectingHostId = null);
      await _showConnectError(e.message, details: e.details);
    } catch (e) {
      if (!mounted) return;
      setState(() => _connectingHostId = null);
      await _showConnectError(
        'Something went wrong while connecting.',
        details: e.toString(),
      );
    }
  }

  Future<void> _showConnectError(
    String message, {
    String? details,
    VoidCallback? onEdit,
  }) {
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.error_outline, color: AppTheme.danger),
        title: const Text('Could not connect'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(message, style: const TextStyle(height: 1.35)),
              if (details != null) ...[
                const SizedBox(height: 12),
                Text(
                  details,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontFamily: AppTheme.monoFontFamily,
                        fontFamilyFallback: AppTheme.monoFontFamilyFallback,
                      ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          if (onEdit != null)
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                onEdit();
              },
              child: const Text('Edit host'),
            ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  /// Puts `user@host` (or `user@host:port` for a non-standard port) on the
  /// clipboard — handy for pasting into a different terminal or a chat when
  /// telling someone else how to reach the same box.
  Future<void> _copyTarget(Host host) async {
    await Clipboard.setData(ClipboardData(text: host.target));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Copied ${host.target}')),
    );
  }

  void _showHostActions(Host host) {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: const Text('Browse files'),
              subtitle: const Text('Connects straight into the file browser'),
              onTap: () {
                Navigator.of(context).pop();
                _connect(host, view: SessionView.files);
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit'),
              onTap: () {
                Navigator.of(context).pop();
                _editHost(host);
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy_all_outlined),
              title: const Text('Copy user@host'),
              subtitle: Text(host.target),
              onTap: () {
                Navigator.of(context).pop();
                unawaited(_copyTarget(host));
              },
            ),
            ListTile(
              leading: const Icon(Icons.key_off_outlined),
              title: const Text('Forget host keys'),
              subtitle: const Text('Undoes trust-on-first-use for this server'),
              onTap: () {
                Navigator.of(context).pop();
                _forgetHostKeys(host);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: AppTheme.danger),
              title: const Text('Delete', style: TextStyle(color: AppTheme.danger)),
              onTap: () {
                Navigator.of(context).pop();
                _deleteHost(host);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _forgetHostKeys(Host host) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Forget host keys?'),
        content: Text(
          'The next connection to ${host.hostname}:${host.port} will be '
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
    await widget.knownHosts.forgetHost(host.hostname, host.port);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Forgot host keys for ${host.displayName}')),
    );
  }

  Future<void> _deleteHost(Host host) async {
    var forgetKeys = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Delete host?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'This removes "${host.displayName}" and its saved password '
                'or key. This cannot be undone.',
                style: const TextStyle(height: 1.35),
              ),
              CheckboxListTile(
                value: forgetKeys,
                onChanged: (value) =>
                    setDialogState(() => forgetKeys = value ?? false),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text(
                  'Also forget its trusted host key(s)',
                  style: TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true) return;

    await widget.hostStore.delete(host.id);
    await widget.credentialStore.delete(host.id);
    if (forgetKeys) {
      await widget.knownHosts.forgetHost(host.hostname, host.port);
    }
    if (!mounted) return;
    _refresh();
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsScreen(
          settingsStore: widget.settingsStore,
          knownHosts: widget.knownHosts,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SecureShell Go'),
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (_trustStoreReset)
              _TrustStoreResetBanner(
                onDismiss: () => setState(() => _trustStoreReset = false),
              ),
            Expanded(child: _buildHostList()),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addHost,
        tooltip: 'Add host',
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildHostList() {
    // Only the widest class gets the grid — a phone in split-screen or a
    // narrow tablet window (medium) still reads better as a single column.
    final width = MediaQuery.sizeOf(context).width;
    final expanded =
        WindowSizeClass.forWidth(width) == WindowSizeClass.expanded;

    return FutureBuilder<List<Host>>(
      future: _future,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final hosts = snapshot.data!;
        // A CustomScrollView with AlwaysScrollableScrollPhysics — rather than
        // gating RefreshIndicator's child on hosts.isEmpty — is what lets
        // pull-to-refresh work even from the empty-state illustration, the
        // same trick file_browser_pane.dart uses for its own empty directory.
        return RefreshIndicator(
          onRefresh: _pullToRefresh,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              if (hosts.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _EmptyHostList(onAddHost: _addHost),
                )
              else if (expanded)
                _buildHostGrid(hosts)
              else
                _buildHostListSliver(hosts),
            ],
          ),
        );
      },
    );
  }

  /// Compact and medium: the plain one-column list, unchanged from before
  /// Phase 8.
  Widget _buildHostListSliver(List<Host> hosts) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      sliver: SliverList.separated(
        itemCount: hosts.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final host = hosts[index];
          final connecting = _connectingHostId == host.id;
          return ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 10,
            ),
            leading: CircleAvatar(
              radius: 22,
              backgroundColor: AppTheme.surface,
              child: Icon(
                host.authMethod == SshAuthMethod.password
                    ? Icons.password
                    : Icons.key,
                size: 22,
              ),
            ),
            title: Text(
              host.displayName,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 2),
                Text(host.target),
                if (host.lastConnectedAt != null)
                  Text(
                    'Last connected '
                    '${_formatLastConnected(host.lastConnectedAt!)}',
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            trailing: connecting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : IconButton(
                    tooltip: 'More',
                    icon: const Icon(Icons.more_vert),
                    onPressed: () => _showHostActions(host),
                  ),
            onTap: connecting ? null : () => _connect(host),
            onLongPress: connecting ? null : () => _showHostActions(host),
          );
        },
      ),
    );
  }

  /// Expanded: a 2-column grid of host cards, same actions as the list —
  /// tap to connect, "more" for the same bottom sheet, long-press as a
  /// shortcut to it. A wide window has room to show more hosts at once
  /// without the list stretching into an uncomfortably long single line per
  /// row.
  Widget _buildHostGrid(List<Host> hosts) {
    return SliverPadding(
      padding: const EdgeInsets.all(12),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          mainAxisExtent: 104,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final host = hosts[index];
            return _HostCard(
              host: host,
              connecting: _connectingHostId == host.id,
              onTap: () => _connect(host),
              onMore: () => _showHostActions(host),
            );
          },
          childCount: hosts.length,
        ),
      ),
    );
  }
}

/// One host, as a card in the expanded grid — the same information and
/// actions as a list row, laid out for a fixed-size grid cell instead of a
/// full-width tile.
class _HostCard extends StatelessWidget {
  const _HostCard({
    required this.host,
    required this.connecting,
    required this.onTap,
    required this.onMore,
  });

  final Host host;
  final bool connecting;
  final VoidCallback onTap;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: connecting ? null : onTap,
        onLongPress: connecting ? null : onMore,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: AppTheme.surface,
                child: Icon(
                  host.authMethod == SshAuthMethod.password
                      ? Icons.password
                      : Icons.key,
                  size: 18,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      host.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      host.target,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                    if (host.lastConnectedAt != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          _formatLastConnected(host.lastConnectedAt!),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              connecting
                  ? const Padding(
                      padding: EdgeInsets.all(8),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : IconButton(
                      tooltip: 'More',
                      icon: const Icon(Icons.more_vert, size: 20),
                      onPressed: onMore,
                      visualDensity: VisualDensity.compact,
                    ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shown when known_hosts.json failed its HMAC check and was dropped.
class _TrustStoreResetBanner extends StatelessWidget {
  const _TrustStoreResetBanner({required this.onDismiss});

  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.danger.withValues(alpha: 0.15),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.gpp_maybe, color: AppTheme.danger, size: 20),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'The trusted host-key store failed its integrity check and '
                'was reset. Every server will ask you to verify its key '
                'again — compare each fingerprint against the server itself.',
                style: TextStyle(fontSize: 12.5, height: 1.35),
              ),
            ),
            IconButton(
              tooltip: 'Dismiss',
              icon: const Icon(Icons.close, size: 18),
              onPressed: onDismiss,
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyHostList extends StatelessWidget {
  const _EmptyHostList({required this.onAddHost});

  final VoidCallback onAddHost;

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
              Icons.dns_outlined,
              size: 72,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 20),
            Text('No saved hosts yet', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              'Add a server to connect to it in one tap next time. '
              'Passwords and keys are stored encrypted on this device.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onAddHost,
              icon: const Icon(Icons.add),
              label: const Text('Add host'),
            ),
          ],
        ),
      ),
    );
  }
}

/// `today at 14:32`, `26 Jul at 14:32` this year, `26 Jul 2024` before that —
/// the same progressive-detail rule the file browser's timestamps use.
String _formatLastConnected(DateTime time) {
  final local = time.toLocal();
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final now = DateTime.now();
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');

  if (local.year == now.year && local.month == now.month && local.day == now.day) {
    return 'today at $hh:$mm';
  }
  if (local.year == now.year) {
    return '${local.day} ${months[local.month - 1]} at $hh:$mm';
  }
  return '${local.day} ${months[local.month - 1]} ${local.year}';
}
