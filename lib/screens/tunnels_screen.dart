import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../models/app_settings.dart';
import '../models/tunnel_profile.dart';
import '../services/host_store.dart';
import '../services/remote_path.dart';
import '../services/tunnel_runtime.dart';
import '../services/tunnel_store.dart';
import '../theme.dart';
import '../widgets/host_key_dialog.dart';
import 'tunnel_edit_screen.dart';

/// Every saved port-forwarding tunnel, grouped by the host that carries it.
///
/// Reached from Settings and from the host list's app bar. The switch on each
/// row is the whole of the interface: a tunnel is either listening or it is
/// not, and everything else on the row — the live connection count, the byte
/// counters, the error — is the runtime reporting what happened to it.
class TunnelsScreen extends StatefulWidget {
  const TunnelsScreen({
    super.key,
    required this.tunnels,
    required this.hostStore,
    this.uiStyle = UiStyle.aurora,
  });

  /// Owns the running tunnels *and* the saved profiles. Built in `main.dart`,
  /// because a tunnel has to outlive this route: leaving this screen is not
  /// the user saying they are finished forwarding a port.
  final TunnelRuntime tunnels;

  final HostStore hostStore;

  /// Chrome only — see `theme.dart`'s `AppTheme.sectionHeaderChromeFor`,
  /// applied to this screen's own [_GroupHeader]. Defaults to aurora (today's
  /// look, unchanged) so a caller that has not been updated — this screen's
  /// own tests included — still gets exactly what it got before.
  final UiStyle uiStyle;

  @override
  State<TunnelsScreen> createState() => _TunnelsScreenState();
}

class _TunnelsScreenState extends State<TunnelsScreen> {
  late Future<List<TunnelGroup>> _future;
  StreamSubscription<TunnelStatus>? _statusChanges;

  @override
  void initState() {
    super.initState();
    _future = _load();
    // One subscription for every row: the runtime folds each tunnel's status
    // into one stream, so a tunnel that fails while the user is looking at
    // another one still repaints its own row.
    _statusChanges = widget.tunnels.changes.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _statusChanges?.cancel();
    super.dispose();
  }

  Future<List<TunnelGroup>> _load() async {
    final profiles = await widget.tunnels.profiles.all();
    final hosts = await widget.hostStore.all();
    return groupTunnelsByHost(profiles, hosts);
  }

  void _refresh() {
    // Block-bodied on purpose — see the same note on
    // `_HostListScreenState._refresh`: an arrow closure would hand setState a
    // Future and the rebuild would never be scheduled.
    setState(() {
      _future = _load();
    });
  }

  Future<void> _addTunnel() => _editTunnel(null);

  Future<void> _editTunnel(TunnelProfile? profile) async {
    final hosts = await widget.hostStore.all();
    if (!mounted) return;

    if (hosts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.tunnelsNeedHost)),
      );
      return;
    }

    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => TunnelEditScreen(
          tunnelStore: widget.tunnels.profiles,
          hosts: hosts,
          profile: profile,
        ),
      ),
    );
    if (!mounted || saved != true) return;
    // An edit only takes effect on the next start, so a running tunnel is
    // stopped rather than left listening on what the user just changed.
    if (profile != null && widget.tunnels.isRunning(profile.id)) {
      await widget.tunnels.stop(profile.id);
    }
    if (!mounted) return;
    _refresh();
  }

  Future<void> _deleteTunnel(TunnelProfile profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        final l10n = context.l10n;
        final material = MaterialLocalizations.of(context);
        return AlertDialog(
          title: Text(l10n.tunnelsDeleteTitle),
          content: Text(
            l10n.tunnelsDeleteBody(profile.displayNameIn(l10n)),
            style: const TextStyle(height: 1.35),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(material.cancelButtonLabel),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: theme.colorScheme.error,
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(material.deleteButtonTooltip),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;

    await widget.tunnels.stop(profile.id);
    await widget.tunnels.profiles.delete(profile.id);
    if (!mounted) return;
    _refresh();
  }

  Future<void> _toggle(TunnelProfile profile, bool start) async {
    if (!start) {
      await widget.tunnels.stop(profile.id);
      return;
    }
    // The host-key prompt goes through the same dialog a hand-made connect
    // uses. A tunnel that has to open its own connection is a connection like
    // any other, and gets asked about like one.
    await widget.tunnels.start(
      profile.id,
      verifyHostKey: (prompt) async {
        if (!mounted) return false;
        return showHostKeyDialog(context, prompt);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.tunnelsTitle),
        actions: [
          IconButton(
            tooltip: l10n.tunnelsStopAll,
            icon: const Icon(Icons.stop_circle_outlined),
            onPressed: widget.tunnels.activeCount == 0
                ? null
                : () => unawaited(widget.tunnels.stopAll()),
          ),
        ],
      ),
      body: SafeArea(
        child: FutureBuilder<List<TunnelGroup>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final groups = snapshot.data ?? const <TunnelGroup>[];
            if (groups.isEmpty) return const _EmptyTunnels();
            return ListView(
              padding: const EdgeInsets.only(bottom: 88),
              children: [
                for (final group in groups) ...[
                  _GroupHeader(group: group, uiStyle: widget.uiStyle),
                  for (final binding in group.bindings)
                    _TunnelTile(
                      binding: binding,
                      status: widget.tunnels.statusFor(binding.profile.id),
                      onToggle: (start) =>
                          unawaited(_toggle(binding.profile, start)),
                      onEdit: () => unawaited(_editTunnel(binding.profile)),
                      onDelete: () => unawaited(_deleteTunnel(binding.profile)),
                    ),
                ],
              ],
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addTunnel,
        tooltip: l10n.tunnelsAdd,
        child: const Icon(Icons.add),
      ),
    );
  }
}

class _EmptyTunnels extends StatelessWidget {
  const _EmptyTunnels();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.swap_horiz,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              l10n.tunnelsEmptyTitle,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              l10n.tunnelsEmptyBody,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.group, this.uiStyle = UiStyle.aurora});

  final TunnelGroup group;
  final UiStyle uiStyle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chrome = AppTheme.sectionHeaderChromeFor(uiStyle, theme.colorScheme);
    final color = group.isBroken
        ? theme.colorScheme.error
        : theme.colorScheme.onSurfaceVariant;

    final row = Row(
      children: [
        if (chrome.leftAccent != null) ...[
          Container(width: 3, height: 14, color: chrome.leftAccent),
          const SizedBox(width: 8),
        ],
        Icon(
          group.isBroken ? Icons.error_outline : Icons.dns_outlined,
          size: 16,
          color: color,
        ),
        const SizedBox(width: 8),
        // A host label is the user's to make as long as they like; on a
        // narrow phone with large text it ran off the edge.
        Flexible(
          child: Text(
            (group.isBroken ? context.l10n.tunnelsMissingHost : group.hostLabel)
                .toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              letterSpacing: 1.1,
              color: color,
            ),
          ),
        ),
      ],
    );

    final content = Padding(
      padding: EdgeInsets.fromLTRB(
        chrome.leftAccent != null ? 13 : 16,
        chrome.tight
            ? 10
            : chrome.airy
                ? 26
                : 20,
        16,
        4,
      ),
      child: row,
    );

    if (chrome.background == null) return content;
    return ColoredBox(color: chrome.background!, child: content);
  }
}

class _TunnelTile extends StatelessWidget {
  const _TunnelTile({
    required this.binding,
    required this.status,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
  });

  final TunnelBinding binding;
  final TunnelStatus status;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  TunnelProfile get profile => binding.profile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final material = MaterialLocalizations.of(context);
    final broken = binding.isBroken;

    return ListTile(
      isThreeLine: true,
      leading: _TypeBadge(type: profile.type, running: status.isRunning),
      title: Row(
        children: [
          Flexible(
            child: Text(
              profile.displayNameIn(l10n),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (profile.bindsAllInterfaces) ...[
            const SizedBox(width: 6),
            Tooltip(
              message: l10n.tunnelsAllInterfaces,
              child: Icon(
                Icons.public,
                size: 15,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 2),
          Text(
            profile.summaryIn(l10n),
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: AppTheme.monoFontFamily,
              fontFamilyFallback: AppTheme.monoFontFamilyFallback,
            ),
          ),
          const SizedBox(height: 4),
          if (broken)
            Text(
              l10n.tunnelsHostDeleted,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
                height: 1.3,
              ),
            )
          else
            _StatusLine(status: status),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (status.state == TunnelState.starting)
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Switch(
              // A broken profile has nothing to ride on, so there is nothing
              // for the switch to do but mislead.
              value: status.isRunning,
              onChanged: broken ? null : onToggle,
            ),
          PopupMenuButton<_TunnelMenuAction>(
            tooltip: material.moreButtonTooltip,
            onSelected: (action) {
              switch (action) {
                case _TunnelMenuAction.edit:
                  onEdit();
                case _TunnelMenuAction.delete:
                  onDelete();
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: _TunnelMenuAction.edit,
                child: Text(l10n.tunnelsEdit),
              ),
              PopupMenuItem(
                value: _TunnelMenuAction.delete,
                child: Text(material.deleteButtonTooltip),
              ),
            ],
          ),
        ],
      ),
      onTap: onEdit,
    );
  }
}

enum _TunnelMenuAction { edit, delete }

/// The one line under a tunnel that says what it is doing right now.
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.status});

  final TunnelStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final message = status.message;

    if (status.state == TunnelState.error) {
      return Text(
        message ?? l10n.tunnelsStoppedAfterError,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.error,
          height: 1.3,
        ),
      );
    }

    if (!status.isRunning) {
      return Text(
        l10n.tunnelsStopped,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }

    final parts = <String>[
      if (status.state == TunnelState.starting)
        l10n.tunnelsStarting
      else ...[
        l10n.tunnelsConnections(status.connections),
        '↑ ${RemotePath.formatBytes(status.bytesUp)}',
        '↓ ${RemotePath.formatBytes(status.bytesDown)}',
      ],
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          parts.join(' · '),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
        // A note about one failed connection, on a tunnel that is otherwise
        // perfectly alive.
        if (message != null)
          Text(
            message,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.3,
            ),
          ),
      ],
    );
  }
}

/// `L`, `R` or `D`, the way `ssh` spells them.
class _TypeBadge extends StatelessWidget {
  const _TypeBadge({required this.type, required this.running});

  final TunnelType type;
  final bool running;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = running
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    return Tooltip(
      message: '${type.labelIn(context.l10n)} (ssh ${type.sshFlag})',
      child: Container(
        width: 34,
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.6)),
        ),
        child: Text(
          type.badge,
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.w600,
            fontFamily: AppTheme.monoFontFamily,
            fontFamilyFallback: AppTheme.monoFontFamilyFallback,
          ),
        ),
      ),
    );
  }
}
