import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../services/process_table.dart';
import '../services/remote_exec.dart';
import '../services/session_controller.dart';
import '../services/systemd_units.dart';
import '../widgets/inline_hint.dart';

/// systemd services and the process table, on one screen with two tabs.
///
/// Neither tab polls. Both load on arrival and on a pull-to-refresh, because
/// unlike the stats panel these are lists the user acts on — a row that moves
/// under a finger about to tap "Stop" is a genuine hazard, not a nicety.
class ServicesScreen extends StatefulWidget {
  const ServicesScreen({super.key, required this.session});

  final SessionController session;

  @override
  State<ServicesScreen> createState() => _ServicesScreenState();
}

class _ServicesScreenState extends State<ServicesScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.servicesTitle, style: const TextStyle(fontSize: 16)),
            Text(
              widget.session.host.displayName,
              style: TextStyle(
                fontSize: 11.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        bottom: TabBar(
          controller: _tabs,
          tabs: [
            Tab(text: l10n.servicesTabServices),
            Tab(text: l10n.servicesTabProcesses),
          ],
        ),
      ),
      body: SafeArea(
        child: TabBarView(
          controller: _tabs,
          children: [
            _ServicesTab(session: widget.session),
            _ProcessesTab(session: widget.session),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ services

class _ServicesTab extends StatefulWidget {
  const _ServicesTab({required this.session});

  final SessionController session;

  @override
  State<_ServicesTab> createState() => _ServicesTabState();
}

class _ServicesTabState extends State<_ServicesTab>
    with AutomaticKeepAliveClientMixin {
  static const _service = SystemdService();

  List<ServiceUnit> _units = const [];
  String? _error;
  var _unavailable = false;
  var _loading = true;
  var _busy = false;
  String _search = '';

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final units = await _service.list(widget.session.connection);
      if (!mounted) return;
      setState(() {
        _units = units;
        _loading = false;
        _unavailable = false;
      });
    } on SystemdUnavailable {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _unavailable = true;
      });
    } on MonitorFailure catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = context.l10n.servicesListFailed('$e');
      });
    }
  }

  /// Every action is confirmed first, by name, with the sudo warning — there
  /// is no path from a tap to a running `systemctl` that skips this.
  Future<void> _act(ServiceAction action, ServiceUnit unit) async {
    final theme = Theme.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_confirmTitle(context.l10n, action, unit.shortName)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.servicesConfirmBody(
                // The command itself, never translated.
                'systemctl ${action.command} ${unit.name}',
                widget.session.host.displayName,
              ),
            ),
            const SizedBox(height: 12),
            InlineHint(
              icon: Icons.info_outline,
              text: context.l10n.servicesSudoHint,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          FilledButton(
            style: action == ServiceAction.stop
                ? FilledButton.styleFrom(
                    backgroundColor: theme.colorScheme.error,
                  )
                : null,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(_actionLabel(context.l10n, action)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      await _service.run(widget.session.connection, action, unit.name);
      if (!mounted) return;
      _snack(context.l10n.servicesActionSent(unit.shortName, action.command));
    } on MonitorFailure catch (e) {
      if (!mounted) return;
      _snack(e.message, isError: true);
    } catch (e) {
      if (!mounted) return;
      _snack(
        _actionFailed(context.l10n, action, unit.shortName, '$e'),
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    // Whatever happened, the unit's state on screen is now a guess; ask.
    if (mounted) await _load();
  }

  void _snack(String message, {bool isError = false}) {
    final theme = Theme.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? theme.colorScheme.error : null,
        duration: Duration(seconds: isError ? 6 : 3),
      ),
    );
  }

  static String _confirmTitle(
    AppLocalizations l10n,
    ServiceAction action,
    String unit,
  ) {
    return switch (action) {
      ServiceAction.start => l10n.servicesConfirmStartTitle(unit),
      ServiceAction.stop => l10n.servicesConfirmStopTitle(unit),
      ServiceAction.restart => l10n.servicesConfirmRestartTitle(unit),
    };
  }

  static String _actionFailed(
    AppLocalizations l10n,
    ServiceAction action,
    String unit,
    String error,
  ) {
    return switch (action) {
      ServiceAction.start => l10n.servicesStartFailed(unit, error),
      ServiceAction.stop => l10n.servicesStopFailed(unit, error),
      ServiceAction.restart => l10n.servicesRestartFailed(unit, error),
    };
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l10n = context.l10n;

    if (_loading && _units.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_unavailable) {
      return _EmptyState(
        icon: Icons.settings_ethernet,
        // Stated plainly, as a property of the server rather than a fault.
        // No init.d fallback is attempted — see SystemdService.list.
        message: l10n.servicesNoSystemd,
        detail: l10n.servicesNoSystemdDetail,
      );
    }
    final error = _error;
    if (error != null && _units.isEmpty) {
      return _EmptyState(
        icon: Icons.error_outline,
        message: error,
        onRetry: () => unawaited(_load()),
      );
    }

    final needle = _search.toLowerCase();
    final visible = needle.isEmpty
        ? _units
        : _units
            .where((unit) =>
                unit.name.toLowerCase().contains(needle) ||
                unit.description.toLowerCase().contains(needle))
            .toList(growable: false);

    return Column(
      children: [
        if (_busy) const LinearProgressIndicator(minHeight: 2),
        _SearchBar(
          hint: l10n.servicesFilterHint,
          count: l10n.servicesFilterCount(visible.length, _units.length),
          onChanged: (value) => setState(() => _search = value.trim()),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: visible.isEmpty
                ? ListView(
                    children: [
                      const SizedBox(height: 80),
                      Center(child: Text(l10n.servicesNoMatch)),
                    ],
                  )
                : ListView.separated(
                    itemCount: visible.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) => _ServiceRow(
                      unit: visible[index],
                      enabled: !_busy,
                      onAction: _act,
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}

class _ServiceRow extends StatelessWidget {
  const _ServiceRow({
    required this.unit,
    required this.enabled,
    required this.onAction,
  });

  final ServiceUnit unit;
  final bool enabled;
  final Future<void> Function(ServiceAction, ServiceUnit) onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final colour = unit.isFailed
        ? theme.colorScheme.error
        : unit.isRunning
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurfaceVariant;

    return ListTile(
      dense: true,
      leading: Icon(Icons.circle, size: 10, color: colour),
      title: Text(
        unit.shortName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14),
      ),
      subtitle: Text(
        unit.description.isEmpty
            ? '${unit.active} · ${unit.sub}'
            : '${unit.active} · ${unit.sub} — ${unit.description}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11.5),
      ),
      trailing: PopupMenuButton<ServiceAction>(
        enabled: enabled,
        tooltip: l10n.servicesActionsTooltip(unit.shortName),
        icon: const Icon(Icons.more_vert, size: 20),
        onSelected: (action) => unawaited(onAction(action, unit)),
        itemBuilder: (context) => [
          for (final action in const [
            ServiceAction.start,
            ServiceAction.restart,
            ServiceAction.stop,
          ])
            PopupMenuItem<ServiceAction>(
              value: action,
              child: Text(_actionLabel(context.l10n, action)),
            ),
        ],
      ),
    );
  }
}

// ----------------------------------------------------------------- processes

class _ProcessesTab extends StatefulWidget {
  const _ProcessesTab({required this.session});

  final SessionController session;

  @override
  State<_ProcessesTab> createState() => _ProcessesTabState();
}

class _ProcessesTabState extends State<_ProcessesTab>
    with AutomaticKeepAliveClientMixin {
  static const _service = ProcessTableService();

  List<RemoteProcess> _processes = const [];
  String? _error;
  var _loading = true;
  var _busy = false;
  var _sort = ProcessSort.cpu;
  var _descending = true;
  String _search = '';

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final processes = await _service.list(widget.session.connection);
      if (!mounted) return;
      setState(() {
        _processes = processes;
        _loading = false;
      });
    } on MonitorFailure catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = context.l10n.servicesProcessListFailed('$e');
      });
    }
  }

  /// Confirmation naming the process, with TERM as the default and KILL as a
  /// deliberate second choice. PID 1 never reaches here — the row does not
  /// offer the action.
  Future<void> _kill(RemoteProcess process) async {
    final theme = Theme.of(context);
    final force = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.servicesKillTitle(process.command)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.servicesKillBody(
                '${process.pid}',
                process.user,
                widget.session.host.displayName,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              context.l10n.servicesKillExplain,
              style: TextStyle(
                fontSize: 12.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              context.l10n.servicesKillSudoHint,
              style: TextStyle(
                fontSize: 12.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: theme.colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.l10n.servicesForceKill),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.l10n.servicesTerminate),
          ),
        ],
      ),
    );
    if (force == null || !mounted) return;

    setState(() => _busy = true);
    try {
      await _service.kill(widget.session.connection, process.pid, force: force);
      if (!mounted) return;
      _snack(
        context.l10n.servicesSignalSent(
          // Signal names, never translated.
          force ? 'KILL' : 'TERM',
          '${process.pid}',
        ),
      );
    } on MonitorFailure catch (e) {
      if (!mounted) return;
      _snack(e.message, isError: true);
    } catch (e) {
      if (!mounted) return;
      _snack(
        context.l10n.servicesSignalFailed('${process.pid}', '$e'),
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted) await _load();
  }

  void _snack(String message, {bool isError = false}) {
    final theme = Theme.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? theme.colorScheme.error : null,
        duration: Duration(seconds: isError ? 6 : 3),
      ),
    );
  }

  void _sortBy(ProcessSort column) {
    setState(() {
      if (_sort == column) {
        _descending = !_descending;
      } else {
        _sort = column;
        // A newly picked column starts on the end people care about: the
        // biggest CPU and memory numbers, but the lowest pid.
        _descending = column != ProcessSort.pid;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l10n = context.l10n;

    if (_loading && _processes.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = _error;
    if (error != null && _processes.isEmpty) {
      return _EmptyState(
        icon: Icons.error_outline,
        message: error,
        onRetry: () => unawaited(_load()),
      );
    }

    final needle = _search.toLowerCase();
    final matching = needle.isEmpty
        ? _processes
        : _processes
            .where((process) =>
                process.command.toLowerCase().contains(needle) ||
                process.user.toLowerCase().contains(needle) ||
                '${process.pid}'.contains(needle))
            .toList(growable: false);
    final visible = sortProcesses(matching, _sort, descending: _descending);

    return Column(
      children: [
        if (_busy) const LinearProgressIndicator(minHeight: 2),
        _SearchBar(
          hint: l10n.servicesProcessFilterHint,
          count: l10n.servicesFilterCount(visible.length, _processes.length),
          onChanged: (value) => setState(() => _search = value.trim()),
        ),
        _ProcessHeader(sort: _sort, descending: _descending, onSort: _sortBy),
        const Divider(height: 1),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: visible.isEmpty
                ? ListView(
                    children: [
                      const SizedBox(height: 80),
                      Center(child: Text(l10n.servicesNoProcessMatch)),
                    ],
                  )
                : ListView.separated(
                    itemCount: visible.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) => _ProcessRow(
                      process: visible[index],
                      enabled: !_busy,
                      onKill: _kill,
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}

class _ProcessHeader extends StatelessWidget {
  const _ProcessHeader({
    required this.sort,
    required this.descending,
    required this.onSort,
  });

  final ProcessSort sort;
  final bool descending;
  final ValueChanged<ProcessSort> onSort;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    Widget cell(
      String label,
      ProcessSort column, {
      int flex = 1,
      double? width,
    }) {
      final active = sort == column;
      final child = InkWell(
        onTap: () => onSort(column),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                    color: active
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (active)
                Icon(
                  descending ? Icons.arrow_drop_down : Icons.arrow_drop_up,
                  size: 16,
                  color: theme.colorScheme.primary,
                ),
            ],
          ),
        ),
      );
      return width != null
          ? SizedBox(width: width, child: child)
          : Expanded(flex: flex, child: child);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          // PID and CPU are the same abbreviations in every language.
          cell('PID', ProcessSort.pid, width: 64),
          cell(l10n.servicesColumnCommand, ProcessSort.command, flex: 3),
          cell(l10n.servicesColumnUser, ProcessSort.user, flex: 2),
          cell('CPU', ProcessSort.cpu, width: 52),
          cell(l10n.servicesColumnMemory, ProcessSort.memory, width: 52),
          const SizedBox(width: 40),
        ],
      ),
    );
  }
}

class _ProcessRow extends StatelessWidget {
  const _ProcessRow({
    required this.process,
    required this.enabled,
    required this.onKill,
  });

  final RemoteProcess process;
  final bool enabled;
  final Future<void> Function(RemoteProcess) onKill;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dim = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          SizedBox(
            width: 64,
            child: Text(
              '${process.pid}',
              style: TextStyle(fontSize: 12, color: dim),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              process.command,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              process.user,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: dim),
            ),
          ),
          SizedBox(
            width: 52,
            child: Text(
              process.cpuPercent.toStringAsFixed(1),
              style: TextStyle(
                fontSize: 12,
                color:
                    process.cpuPercent >= 50 ? theme.colorScheme.error : null,
              ),
            ),
          ),
          SizedBox(
            width: 52,
            child: Text(
              process.memoryPercent.toStringAsFixed(1),
              style: const TextStyle(fontSize: 12),
            ),
          ),
          SizedBox(
            width: 40,
            child: process.isInit
                // PID 1 is never offered a kill: signalling init takes the
                // whole machine or container down with it.
                ? Tooltip(
                    message: context.l10n.servicesInitTooltip,
                    child: Icon(Icons.lock_outline, size: 16, color: dim),
                  )
                : IconButton(
                    tooltip: context.l10n.servicesKillTooltip,
                    icon: const Icon(Icons.cancel_outlined, size: 18),
                    onPressed:
                        enabled ? () => unawaited(onKill(process)) : null,
                  ),
          ),
        ],
      ),
    );
  }
}

// -------------------------------------------------------------------- shared

class _SearchBar extends StatelessWidget {
  const _SearchBar({
    required this.hint,
    required this.count,
    required this.onChanged,
  });

  final String hint;
  final String count;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: TextField(
        onChanged: onChanged,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          isDense: true,
          prefixIcon: const Icon(Icons.search, size: 18),
          prefixIconConstraints:
              const BoxConstraints(minWidth: 38, minHeight: 32),
          hintText: hint,
          hintStyle: const TextStyle(fontSize: 13),
          suffixText: count,
          suffixStyle: TextStyle(
            fontSize: 11.5,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.message,
    this.detail,
    this.onRetry,
  });

  final IconData icon;
  final String message;
  final String? detail;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final detail = this.detail;
    final onRetry = this.onRetry;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            if (detail != null) ...[
              const SizedBox(height: 8),
              Text(
                detail,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12.5,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(context.l10n.servicesTryAgain),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The menu item and confirm-button label for [action].
String _actionLabel(AppLocalizations l10n, ServiceAction action) {
  return switch (action) {
    ServiceAction.start => l10n.servicesActionStart,
    ServiceAction.stop => l10n.servicesActionStop,
    ServiceAction.restart => l10n.servicesActionRestart,
  };
}

/// Pushes the services/processes screen for [session].
Future<void> openServicesScreen(
  BuildContext context, {
  required SessionController session,
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (context) => ServicesScreen(session: session),
    ),
  );
}
