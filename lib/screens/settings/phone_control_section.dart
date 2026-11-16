import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/app_settings.dart';
import '../../services/bridge/bridge_client_store.dart';
import '../../services/bridge/bridge_service.dart';
import '../../services/visible_text.dart';
import '../bridge_audit_screen.dart' show bridgeDateTime;
import '../pair_phone_screen.dart';
import 'settings_section.dart';

/// Settings, AI, "Phone control": the switch that lets a paired phone answer
/// this computer's approval cards, pairing a phone, and the phones paired.
///
/// Only built where the local channel exists (the phone connects through
/// the same listener assistants do).
class PhoneControlSettings extends StatefulWidget {
  const PhoneControlSettings({
    super.key,
    required this.settings,
    required this.apply,
    required this.bridge,
    required this.clients,
  });

  final AppSettings settings;
  final SettingsChange apply;
  final BridgeService bridge;
  final BridgeClientStore clients;

  @override
  State<PhoneControlSettings> createState() => _PhoneControlSettingsState();
}

class _PhoneControlSettingsState extends State<PhoneControlSettings> {
  List<BridgeClient> _phones = const [];
  StreamSubscription<List<BridgeClient>>? _watch;

  static List<BridgeClient> _controllers(List<BridgeClient> all) => [
    for (final c in all)
      if (c.role == BridgeClientRole.controller) c,
  ];

  @override
  void initState() {
    super.initState();
    _watch = widget.clients.changes.listen((list) {
      if (mounted) setState(() => _phones = _controllers(list));
    });
    unawaited(
      widget.clients.load().then((list) {
        if (mounted) setState(() => _phones = _controllers(list));
      }),
    );
  }

  @override
  void dispose() {
    unawaited(_watch?.cancel());
    super.dispose();
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    required String confirmLabel,
    bool destructive = false,
  }) async {
    final theme = Theme.of(context);
    final cancel = MaterialLocalizations.of(context).cancelButtonLabel;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(body)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(cancel),
          ),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: theme.colorScheme.error,
                  )
                : null,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return result == true;
  }

  /// Applies the change. The settings screen puts the setting back when it
  /// cannot be saved and throws; this says so, so the switch is not left
  /// looking like something the next start will keep.
  Future<void> _setEnabled(bool on) async {
    final l10n = context.l10n;
    // Asked every time it goes on: what a paired phone can see and do is
    // worth reading again.
    if (on) {
      final ok = await _confirm(
        title: l10n.phoneControlEnableTitle,
        body: l10n.phoneControlEnableBody,
        confirmLabel: l10n.phoneControlEnableConfirm,
      );
      if (!ok || !mounted) return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final failed = l10n.settingsBridgeSaveFailed;
    try {
      await widget.apply((s) => s.copyWith(bridgePhoneControl: on));
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(failed)));
    }
  }

  Future<void> _remove(BridgeClient phone) async {
    final l10n = context.l10n;
    final ok = await _confirm(
      title: l10n.phoneControlRemoveTitle(phone.name),
      body: l10n.phoneControlRemoveBody,
      confirmLabel: l10n.phoneControlRemove,
      destructive: true,
    );
    if (!ok || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final failed = l10n.settingsBridgeRevokeFailed;
    try {
      await widget.clients.revoke(phone.id);
    } catch (_) {
      // The store has kept the pairing (memory and file agree): say so.
      messenger.showSnackBar(SnackBar(content: Text(failed)));
    }
  }

  Widget _tile(BuildContext context, BridgeClient phone, Set<String> online) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final seen = phone.lastSeenAt;
    final line = [
      l10n.settingsBridgePairedOn(bridgeDateTime(context, phone.createdAt)),
      seen == null
          ? l10n.settingsBridgeNeverSeen
          : l10n.settingsBridgeLastSeen(bridgeDateTime(context, seen)),
    ].join(' · ');
    return ListTile(
      key: ValueKey('phone-${phone.id}'),
      leading: const Icon(Icons.phone_android),
      title: Text(visibleLine(phone.name, maxChars: 60)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(line),
          if (online.contains(phone.id))
            Text(
              l10n.phoneControlConnectedNow,
              key: ValueKey('phone-online-${phone.id}'),
              style: TextStyle(color: theme.colorScheme.primary),
            ),
        ],
      ),
      trailing: IconButton(
        key: ValueKey('phone-remove-${phone.id}'),
        tooltip: l10n.phoneControlRemove,
        icon: const Icon(Icons.link_off),
        onPressed: () => unawaited(_remove(phone)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final settings = widget.settings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          key: const ValueKey('phone-control-switch'),
          secondary: const Icon(Icons.phonelink_ring_outlined),
          title: Text(l10n.phoneControlSwitch),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.phoneControlSwitchHelp),
              if (!settings.bridgeEnabled) ...[
                const SizedBox(height: 4),
                Text(
                  l10n.phoneControlNeedsBridge,
                  key: const ValueKey('phone-control-needs-bridge'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
            ],
          ),
          value: settings.bridgePhoneControl,
          onChanged: (on) => unawaited(_setEnabled(on)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: FilledButton.tonalIcon(
              key: const ValueKey('phone-control-pair'),
              icon: const Icon(Icons.add_link),
              label: Text(l10n.phoneControlPair),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => PairPhoneScreen(clients: widget.clients),
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            l10n.phoneControlPaired,
            style: theme.textTheme.titleSmall,
          ),
        ),
        StreamBuilder<List<BridgeClient>>(
          initialData: widget.bridge.connectedControllers,
          stream: widget.bridge.connectedControllersChanges,
          builder: (context, snapshot) {
            final online = <String>{
              for (final c in snapshot.data ?? const <BridgeClient>[]) c.id,
            };
            if (_phones.isEmpty) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Text(
                  l10n.phoneControlPairedNone,
                  key: const ValueKey('phone-control-none'),
                ),
              );
            }
            return Column(
              children: [for (final p in _phones) _tile(context, p, online)],
            );
          },
        ),
      ],
    );
  }
}
