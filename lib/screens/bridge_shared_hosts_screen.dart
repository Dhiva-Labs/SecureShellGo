import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../models/host.dart';
import '../models/host_ai_access.dart';
import '../models/host_ai_edit.dart';
import '../services/host_store.dart';
import '../widgets/host_ai_controls.dart';

/// Which saved hosts an AI assistant may read: a checkbox per host, started
/// from what each host already has and applied only on Save.
///
/// A body, not a screen, so the one-click flow can show it in its own page
/// and Settings can open it on its own ([BridgeSharedHostsScreen]).
class SharedHostsChecklist extends StatefulWidget {
  const SharedHostsChecklist({
    super.key,
    required this.hostStore,
    required this.onSaved,
    this.onSkip,
  });

  final HostStore hostStore;

  /// Called after Save has written every change.
  final VoidCallback onSaved;

  /// When given, a "Skip for now" button leaves without changing anything.
  final VoidCallback? onSkip;

  @override
  State<SharedHostsChecklist> createState() => _SharedHostsChecklistState();
}

class _SharedHostsChecklistState extends State<SharedHostsChecklist> {
  List<Host>? _hosts;
  final Set<String> _ticked = {};

  /// The ticks as they were when the list was loaded: Save writes only the
  /// hosts whose tick differs, so a checklist left open cannot re-share a
  /// host that was un-shared elsewhere meanwhile.
  final Set<String> _initial = {};
  bool _saving = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final hosts = await widget.hostStore.all();
    if (!mounted) return;
    setState(() {
      _hosts = hosts;
      _ticked
        ..clear()
        ..addAll([
          for (final h in hosts)
            if (h.aiAccess != HostAiAccess.off) h.id,
        ]);
      _initial
        ..clear()
        ..addAll(_ticked);
    });
  }

  /// Writes the hosts whose tick the user changed: newly ticked read-only
  /// (a host that has more by now keeps it), newly unticked off. A host is
  /// read again just before it is written, so nothing else about it (an edit
  /// made meanwhile included) is touched, and a host whose tick did not
  /// change is not written at all.
  Future<void> _save() async {
    final hosts = _hosts;
    if (hosts == null) return;
    setState(() {
      _saving = true;
      _failed = false;
    });
    try {
      for (final listed in hosts) {
        final now = _ticked.contains(listed.id);
        if (now == _initial.contains(listed.id)) continue;
        final current = await widget.hostStore.get(listed.id);
        if (current == null) continue;
        // Un-sharing leaves the allowed commands and terminal setting stored,
        // inert, so ticking the host again does not lose them.
        final wanted = !now
            ? HostAiAccess.off
            : current.aiAccess == HostAiAccess.off
                ? HostAiAccess.readOnly
                : current.aiAccess;
        if (current.aiAccess != wanted) {
          await widget.hostStore.update(current.copyWith(aiAccess: wanted));
        }
      }
    } catch (_) {
      // Some hosts may have been written before the one that failed: show
      // what the store holds now rather than the ticks that were asked for,
      // so the list never claims a state that is not the real one.
      try {
        await _load();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _saving = false;
        _failed = true;
      });
      return;
    }
    if (!mounted) return;
    setState(() => _saving = false);
    widget.onSaved();
  }

  /// The group, and what an assistant may do on the host now.
  Widget? _subtitle(BuildContext context, Host host) {
    final l10n = context.l10n;
    final level = switch (host.aiAccess) {
      HostAiAccess.off => null,
      HostAiAccess.readOnly => l10n.bridgeHostLevelRead,
      HostAiAccess.askToChange =>
        host.aiTerminal
            ? l10n.bridgeHostLevelTerminal
            : l10n.bridgeHostLevelChanges,
      HostAiAccess.fullControl => l10n.bridgeHostLevelFullControl,
    };
    final lines = [
      if ((host.group ?? '').isNotEmpty) host.group!,
      ?level,
    ];
    if (lines.isEmpty) return null;
    return Text(lines.join(' · '));
  }

  /// The per-host sheet: request changes, allowed commands, terminal. Writes
  /// only what was touched there, against the host as stored now.
  Future<void> _openSheet(Host listed) async {
    final stored = await widget.hostStore.get(listed.id);
    if (stored == null || !mounted) return;
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) =>
          _HostAiSheet(host: stored, hostStore: widget.hostStore),
    );
    if (saved != true || !mounted) return;
    final fresh = await widget.hostStore.get(listed.id);
    if (fresh == null || !mounted) return;
    // Only this host is refreshed: the ticks on the others stay as set.
    setState(() {
      final i = _hosts!.indexWhere((h) => h.id == fresh.id);
      if (i >= 0) _hosts = [..._hosts!]..[i] = fresh;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final hosts = _hosts;
    if (hosts == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (hosts.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Icon(
            Icons.dns_outlined,
            size: 40,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(
            l10n.bridgeHostsEmptyTitle,
            style: theme.textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(l10n.bridgeHostsEmptyBody, textAlign: TextAlign.center),
          if (widget.onSkip != null) ...[
            const SizedBox(height: 24),
            FilledButton(
              onPressed: widget.onSkip,
              child: Text(l10n.bridgeConnectDone),
            ),
          ],
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Text(l10n.bridgeHostsIntro),
              ),
              for (final host in hosts)
                CheckboxListTile(
                  value: _ticked.contains(host.id),
                  onChanged: _saving
                      ? null
                      : (on) => setState(() {
                          if (on == true) {
                            _ticked.add(host.id);
                          } else {
                            _ticked.remove(host.id);
                          }
                        }),
                  title: Text(host.label),
                  subtitle: _subtitle(context, host),
                  secondary: _initial.contains(host.id) &&
                          host.aiAccess != HostAiAccess.off
                      ? IconButton(
                          tooltip: l10n.hostAiSheetOpen,
                          icon: const Icon(Icons.tune),
                          onPressed: _saving
                              ? null
                              : () => unawaited(_openSheet(host)),
                        )
                      : null,
                ),
            ],
          ),
        ),
        if (_failed)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              l10n.bridgeHostsSaveFailed,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                if (widget.onSkip != null)
                  TextButton(
                    onPressed: _saving ? null : widget.onSkip,
                    child: Text(l10n.bridgeHostsSkip),
                  ),
                FilledButton(
                  onPressed: _saving ? null : () => unawaited(_save()),
                  child: Text(l10n.bridgeHostsSave),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// The checklist as its own screen, opened from Settings → AI Bridge.
/// Pops with true once saved.
class BridgeSharedHostsScreen extends StatelessWidget {
  const BridgeSharedHostsScreen({super.key, required this.hostStore});

  final HostStore hostStore;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.bridgeHostsTitle)),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: SharedHostsChecklist(
              hostStore: hostStore,
              onSaved: () => Navigator.of(context).pop(true),
            ),
          ),
        ),
      ),
    );
  }
}

/// The controls of one shared host in a bottom sheet, with its own Save.
class _HostAiSheet extends StatefulWidget {
  const _HostAiSheet({required this.host, required this.hostStore});

  final Host host;
  final HostStore hostStore;

  @override
  State<_HostAiSheet> createState() => _HostAiSheetState();
}

class _HostAiSheetState extends State<_HostAiSheet> {
  late final HostAiEdit _edit = HostAiEdit.of(widget.host);
  bool _saving = false;
  bool _failed = false;

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _failed = false;
    });
    try {
      final stored = await widget.hostStore.get(widget.host.id);
      if (stored != null && _edit.touched) {
        final next = _edit.applyTo(stored);
        // Never raises a host the list shows as shared past what is stored:
        // only what was touched here is written.
        await widget.hostStore.update(next);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _failed = true;
      });
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.hostAiSheetTitle(widget.host.label),
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          HostAiControls(
            edit: _edit,
            showShare: false,
            onChanged: () => setState(() {}),
            loadStored: () => widget.hostStore.get(widget.host.id),
          ),
          if (_failed)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                l10n.bridgeHostsSaveFailed,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              TextButton(
                onPressed: _saving
                    ? null
                    : () => Navigator.of(context).pop(false),
                child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
              ),
              FilledButton(
                onPressed: _saving ? null : () => unawaited(_save()),
                child: Text(l10n.bridgeHostsSave),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
