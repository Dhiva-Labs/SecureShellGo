import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../services/bridge/bridge_audit.dart';
import '../services/bridge/bridge_tools.dart';
import '../theme.dart';

/// A date and time the way the device writes them, from the Material
/// localizations that are there with or without the app's own translations
/// (`intl`'s calendar data is not, in a bare test app).
String bridgeDateTime(BuildContext context, DateTime time) {
  final material = MaterialLocalizations.of(context);
  final local = time.toLocal();
  return '${material.formatShortDate(local)} '
      '${material.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
}

/// The AI Bridge's activity log: what each paired assistant asked for, newest
/// first, and whether it was allowed. Never what came back — the log does not
/// hold that (see [BridgeAuditLog]).
class BridgeAuditScreen extends StatefulWidget {
  const BridgeAuditScreen({super.key, required this.audit, this.limit = 500});

  final BridgeAuditLog audit;

  /// How many of the newest entries are listed.
  final int limit;

  @override
  State<BridgeAuditScreen> createState() => _BridgeAuditScreenState();
}

class _BridgeAuditScreenState extends State<BridgeAuditScreen> {
  /// Newest first. Null until the file has been read.
  List<BridgeAuditEntry>? _entries;
  final Set<String> _seen = {};
  final List<BridgeAuditEntry> _early = [];
  StreamSubscription<BridgeAuditEntry>? _live;
  StreamSubscription<String?>? _writeWatch;

  static String _key(BridgeAuditEntry e) => jsonEncode(e.toJson());

  @override
  void initState() {
    super.initState();
    // Listening starts before the read, so an entry recorded while the file
    // is being read is not lost; the set keeps it from being listed twice
    // when the read saw it as well.
    _live = widget.audit.entries.listen(_onEntry);
    _writeWatch = widget.audit.writeErrors.listen((_) {
      if (mounted) setState(() {});
    });
    unawaited(_load());
  }

  Future<void> _load() async {
    final loaded = await widget.audit.recent(limit: widget.limit);
    if (!mounted) return;
    setState(() {
      _entries = [...loaded];
      _seen
        ..clear()
        ..addAll(loaded.map(_key));
      for (final e in _early) {
        if (_seen.add(_key(e))) _entries!.insert(0, e);
      }
      _early.clear();
    });
  }

  void _onEntry(BridgeAuditEntry entry) {
    if (!mounted) return;
    final list = _entries;
    if (list == null) {
      _early.add(entry);
      return;
    }
    if (!_seen.add(_key(entry))) return;
    setState(() {
      list.insert(0, entry);
      if (list.length > widget.limit) list.removeLast();
    });
  }

  @override
  void dispose() {
    unawaited(_live?.cancel());
    unawaited(_writeWatch?.cancel());
    super.dispose();
  }

  Future<void> _clear() async {
    final l10n = context.l10n;
    final material = MaterialLocalizations.of(context);
    final theme = Theme.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.bridgeAuditClearTitle),
        content: Text(l10n.bridgeAuditClearBody),
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
            child: Text(l10n.bridgeAuditClear),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final cleared = await widget.audit.clear();
    if (!mounted) return;
    if (cleared) {
      setState(() {
        _entries = [];
        _seen.clear();
      });
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.bridgeAuditClearFailed)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final entries = _entries;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.bridgeAuditTitle),
        actions: [
          IconButton(
            tooltip: l10n.bridgeAuditClear,
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: entries == null || entries.isEmpty
                ? null
                : () => unawaited(_clear()),
          ),
        ],
      ),
      body: Column(
        children: [
          if (widget.audit.lastWriteError != null)
            ListTile(
              leading: Icon(
                Icons.warning_amber_outlined,
                color: theme.colorScheme.error,
              ),
              title: Text(
                l10n.settingsBridgeActivityWriteError,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          Expanded(child: _list(context, entries)),
        ],
      ),
    );
  }

  Widget _list(BuildContext context, List<BridgeAuditEntry>? entries) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    if (entries == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            l10n.bridgeAuditEmpty,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    return ListView.separated(
      itemCount: entries.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) => _EntryTile(entries[i]),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile(this.entry);

  final BridgeAuditEntry entry;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (label, color, icon) = switch (entry.outcome) {
      BridgeAuditOutcome.ok => (
        l10n.bridgeAuditOk,
        scheme.primary,
        Icons.check_circle_outline,
      ),
      BridgeAuditOutcome.refused => (
        l10n.bridgeAuditRefused,
        scheme.tertiary,
        Icons.block,
      ),
      BridgeAuditOutcome.error => (
        l10n.bridgeAuditError,
        scheme.error,
        Icons.error_outline,
      ),
    };
    final host = entry.host;
    // How a change was allowed; nothing for a read.
    final approval = switch (entry.approval) {
      BridgeAuditApproval.none => null,
      BridgeAuditApproval.allowedCommand =>
        l10n.bridgeAuditApprovalAllowedCommand,
      BridgeAuditApproval.grant => l10n.bridgeAuditApprovalGrant,
      BridgeAuditApproval.once => l10n.bridgeAuditApprovalOnce,
      BridgeAuditApproval.forAWhile => l10n.bridgeAuditApprovalForAWhile,
      BridgeAuditApproval.denied => l10n.bridgeAuditApprovalDenied,
      BridgeAuditApproval.timedOut => l10n.bridgeAuditApprovalTimedOut,
      BridgeAuditApproval.withdrawn => l10n.bridgeAuditApprovalWithdrawn,
    };
    // An approved change that never ran must not read as one that did.
    final notRun = entry.detail.startsWith(
      BridgeTools.refusedAfterApprovalPrefix,
    )
        ? entry.detail
            .substring(BridgeTools.refusedAfterApprovalPrefix.length)
        : null;
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(
        host == null ? entry.tool : '${entry.tool} · $host',
        style: TextStyle(
          fontFamily: AppTheme.monoFontFamily,
          fontFamilyFallback: AppTheme.monoFontFamilyFallback,
          fontSize: 13,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${entry.client} · ${bridgeDateTime(context, entry.ts)}'),
          if (approval != null)
            Text(
              approval,
              key: const ValueKey('audit-approval'),
              style: theme.textTheme.bodySmall,
            ),
          if (notRun != null)
            Text(
              l10n.bridgeAuditApprovedNotRun(notRun),
              key: const ValueKey('audit-not-run'),
              style: TextStyle(
                color: scheme.error,
                fontWeight: FontWeight.w600,
              ),
            )
          else if (entry.detail.isNotEmpty)
            Text(entry.detail),
        ],
      ),
      trailing: Text(
        label,
        style: theme.textTheme.labelMedium?.copyWith(color: color),
      ),
    );
  }
}
