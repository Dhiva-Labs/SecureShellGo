import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../models/host.dart';
import '../models/host_ai_access.dart';
import '../services/host_store.dart';

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
            if (h.aiAccess == HostAiAccess.readOnly) h.id,
        ]);
    });
  }

  /// Writes exactly the ticked set: ticked hosts read-only, the rest off. A
  /// host is read again just before it is written, so nothing else about it
  /// (an edit made meanwhile included) is touched.
  Future<void> _save() async {
    final hosts = _hosts;
    if (hosts == null) return;
    setState(() {
      _saving = true;
      _failed = false;
    });
    try {
      for (final listed in hosts) {
        final current = await widget.hostStore.get(listed.id);
        if (current == null) continue;
        final wanted = _ticked.contains(listed.id)
            ? HostAiAccess.readOnly
            : HostAiAccess.off;
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
                  subtitle: (host.group ?? '').isEmpty
                      ? null
                      : Text(host.group!),
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
