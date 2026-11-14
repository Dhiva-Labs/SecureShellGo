import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/app_settings.dart';
import '../../models/host_ai_access.dart';
import '../../services/bridge/bridge_audit.dart';
import '../../services/bridge/bridge_cli_connector.dart';
import '../../services/bridge/bridge_client_store.dart';
import '../../services/bridge/bridge_paths.dart';
import '../../services/bridge/bridge_service.dart';
import '../../services/host_store.dart';
import '../../theme.dart';
import '../bridge_audit_screen.dart';
import '../bridge_connect_screen.dart';
import '../bridge_one_click_screen.dart';
import '../bridge_shared_hosts_screen.dart';
import 'settings_section.dart';

/// The AI Bridge: the switch, what an assistant may see and read, who is
/// paired, and the activity log.
///
/// Built only where the bridge exists (`BridgeService.supported`); the caller
/// holds the three services as null elsewhere and leaves this out, so
/// nothing about it is on screen on a phone.
class AiBridgeSettingsSection extends StatefulWidget {
  const AiBridgeSettingsSection({
    super.key,
    required this.settings,
    required this.apply,
    required this.bridge,
    required this.clients,
    required this.audit,
    this.hostStore,
    this.connector,
  });

  final AppSettings settings;
  final SettingsChange apply;
  final BridgeService bridge;
  final BridgeClientStore clients;
  final BridgeAuditLog audit;

  /// For the "Shared hosts" row and checklist; without it that row is left
  /// out.
  final HostStore? hostStore;

  /// Runs the `claude` command for "Connect Claude Code"; without it the
  /// one-click button is never offered.
  final ClaudeCliConnector? connector;

  @override
  State<AiBridgeSettingsSection> createState() =>
      _AiBridgeSettingsSectionState();
}

class _AiBridgeSettingsSectionState extends State<AiBridgeSettingsSection> {
  List<BridgeClient> _paired = const [];
  int? _sharedHosts;
  int _totalHosts = 0;
  ClaudeCliPresence? _claude;
  StreamSubscription<List<BridgeClient>>? _pairedWatch;
  StreamSubscription<String?>? _auditWatch;

  @override
  void initState() {
    super.initState();
    _pairedWatch = widget.clients.changes.listen((list) {
      if (mounted) setState(() => _paired = list);
    });
    unawaited(
      widget.clients.load().then((list) {
        if (mounted) setState(() => _paired = list);
      }),
    );
    // The warning row follows the log's write status as it changes.
    _auditWatch = widget.audit.writeErrors.listen((_) {
      if (mounted) setState(() {});
    });
    unawaited(_countHosts());
    _claude = widget.connector?.find();
  }

  Future<void> _countHosts() async {
    final hosts = await widget.hostStore?.all();
    if (hosts == null || !mounted) return;
    setState(() {
      _totalHosts = hosts.length;
      _sharedHosts = hosts
          .where((h) => h.aiAccess != HostAiAccess.off)
          .length;
    });
  }

  /// Looks for the `claude` command again, by file-system checks alone: no
  /// program is run until the user presses "Connect Claude Code".
  void _findClaude() {
    final connector = widget.connector;
    if (connector == null) return;
    setState(() => _claude = connector.find());
  }

  @override
  void dispose() {
    unawaited(_pairedWatch?.cancel());
    unawaited(_auditWatch?.cancel());
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

  /// Applies a change to a bridge setting. The settings screen puts the
  /// setting back when it cannot be saved and throws; this says so, so the
  /// switch is not left looking like something the next start will keep.
  Future<void> _save(AppSettings Function(AppSettings current) change) async {
    final messenger = ScaffoldMessenger.of(context);
    final message = context.l10n.settingsBridgeSaveFailed;
    try {
      await widget.apply(change);
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _setEnabled(bool on) async {
    final l10n = context.l10n;
    // Asked every time it goes on, not just while nobody is paired: pairing
    // does not need the bridge on, so "someone is paired" does not mean this
    // was ever read. Switching it on is rare enough that asking again costs
    // little.
    if (on) {
      final ok = await _confirm(
        title: l10n.settingsBridgeEnableTitle,
        body: l10n.settingsBridgeEnableBody,
        confirmLabel: l10n.settingsBridgeEnableConfirm,
      );
      if (!ok || !mounted) return;
    }
    await _save((s) => s.copyWith(bridgeEnabled: on));
  }

  Future<void> _setSensitive(bool on) async {
    final l10n = context.l10n;
    if (on) {
      final ok = await _confirm(
        title: l10n.settingsBridgeSensitiveWarnTitle,
        body: l10n.settingsBridgeSensitiveWarnBody,
        confirmLabel: l10n.settingsBridgeSensitiveWarnConfirm,
        destructive: true,
      );
      if (!ok || !mounted) return;
    }
    await _save((s) => s.copyWith(bridgeReadSensitivePaths: on));
  }

  Future<void> _addPattern() async {
    final pattern = await showDialog<String>(
      context: context,
      builder: (context) => const _PatternDialog(),
    );
    final added = pattern?.trim() ?? '';
    if (added.isEmpty || !mounted) return;
    await _save((s) {
      final current = s.bridgeExtraBlockedPaths;
      if (current.contains(added)) return s;
      return s.copyWith(bridgeExtraBlockedPaths: [...current, added]);
    });
  }

  Future<void> _removePattern(String pattern) {
    return _save(
      (s) => s.copyWith(
        bridgeExtraBlockedPaths: [
          for (final p in s.bridgeExtraBlockedPaths)
            if (p != pattern) p,
        ],
      ),
    );
  }

  Future<void> _revoke(BridgeClient client) async {
    final l10n = context.l10n;
    final ok = await _confirm(
      title: l10n.settingsBridgeRevokeTitle(client.name),
      body: l10n.settingsBridgeRevokeBody,
      confirmLabel: l10n.settingsBridgeRevoke,
      destructive: true,
    );
    if (!ok || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final failed = l10n.settingsBridgeRevokeFailed;
    try {
      await widget.clients.revoke(client.id);
    } catch (_) {
      // The store has kept the pairing (memory and file agree): say so.
      messenger.showSnackBar(SnackBar(content: Text(failed)));
    }
  }

  void _push(Widget screen) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
  }

  /// Opens [screen] and counts the shared hosts again once it is left.
  Future<void> _pushThenCount(Widget screen) async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => screen));
    if (mounted) unawaited(_countHosts());
  }

  /// Whether the one-click screen is open (or opening), so a double tap
  /// opens it once.
  bool _oneClickOpen = false;

  Future<void> _openOneClick(Widget screen) async {
    if (_oneClickOpen) return;
    _oneClickOpen = true;
    try {
      await _pushThenCount(screen);
    } finally {
      _oneClickOpen = false;
    }
  }

  /// The one-click row: the button when `claude` was found, the sandbox note
  /// (snap, Flatpak), and a small "check again" for the times it was not.
  Widget _oneClick(BuildContext context) {
    final l10n = context.l10n;
    final connector = widget.connector;
    final hostStore = widget.hostStore;
    final claude = _claude;
    if (connector == null) return const SizedBox.shrink();
    if (claude is ClaudeCliPresenceSandboxed) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Text(l10n.bridgeOneClickSandboxed(l10n.settingsBridgeConnect)),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
      child: Row(
        children: [
          if (claude is ClaudeCliPresent && hostStore != null)
            Flexible(
              child: FilledButton.icon(
                icon: const Icon(Icons.bolt),
                label: Text(l10n.bridgeOneClickButton),
                onPressed: () => unawaited(
                  _openOneClick(
                    BridgeOneClickScreen(
                      connector: connector,
                      clients: widget.clients,
                      hostStore: hostStore,
                      bridgeEnabled: () => widget.settings.bridgeEnabled,
                      apply: widget.apply,
                    ),
                  ),
                ),
              ),
            ),
          const Spacer(),
          IconButton(
            tooltip: l10n.bridgeOneClickCheckAgain,
            icon: const Icon(Icons.refresh),
            onPressed: _findClaude,
          ),
        ],
      ),
    );
  }

  Widget _subHeading(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.onSurface,
        ),
      ),
    );
  }

  Widget _status(BuildContext context, BridgeStatus status) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final (text, color) = switch (status) {
      BridgeError(:final message) => (
        l10n.settingsBridgeStatusError(message),
        scheme.error,
      ),
      BridgeRunning() => (l10n.settingsBridgeStatusRunning, scheme.primary),
      BridgeRunningElsewhere() => (
        l10n.settingsBridgeStatusElsewhere,
        scheme.primary,
      ),
      BridgeOff() => (l10n.settingsBridgeStatusOff, scheme.onSurfaceVariant),
    };
    return Text(text, style: TextStyle(color: color));
  }

  Widget _clientTile(
    BuildContext context,
    BridgeClient client,
    Set<String> connected,
  ) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final seen = client.lastSeenAt;
    final line = [
      l10n.settingsBridgePairedOn(bridgeDateTime(context, client.createdAt)),
      seen == null
          ? l10n.settingsBridgeNeverSeen
          : l10n.settingsBridgeLastSeen(bridgeDateTime(context, seen)),
    ].join(' · ');
    return ListTile(
      leading: const Icon(Icons.smart_toy_outlined),
      title: Text(client.name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(line),
          if (connected.contains(client.id))
            Text(
              l10n.settingsBridgeConnected,
              style: TextStyle(color: theme.colorScheme.primary),
            ),
        ],
      ),
      trailing: IconButton(
        tooltip: l10n.settingsBridgeRevoke,
        icon: const Icon(Icons.link_off),
        onPressed: () => unawaited(_revoke(client)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final settings = widget.settings;
    final shared = _sharedHosts;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSectionHeader(l10n.settingsBridge, style: settings.uiStyle),
        StreamBuilder<BridgeStatus>(
          initialData: widget.bridge.status,
          stream: widget.bridge.statusChanges,
          builder: (context, snapshot) => SwitchListTile(
            secondary: const Icon(Icons.hub_outlined),
            title: Text(l10n.settingsBridge),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.settingsBridgeHelp),
                const SizedBox(height: 2),
                _status(context, snapshot.data ?? BridgeStatus.off),
              ],
            ),
            value: settings.bridgeEnabled,
            onChanged: (on) => unawaited(_setEnabled(on)),
          ),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.dns_outlined),
          title: Text(l10n.settingsBridgeAddress),
          subtitle: Text(l10n.settingsBridgeAddressHelp),
          value: settings.bridgeShowAddress,
          onChanged: (on) =>
              unawaited(_save((s) => s.copyWith(bridgeShowAddress: on))),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.key_outlined),
          title: Text(l10n.settingsBridgeSensitive),
          subtitle: Text(l10n.settingsBridgeSensitiveHelp),
          value: settings.bridgeReadSensitivePaths,
          onChanged: (on) => unawaited(_setSensitive(on)),
        ),
        _subHeading(context, l10n.settingsBridgeBlocked),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text(
            l10n.settingsBridgeBlockedHelp,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        if (settings.bridgeExtraBlockedPaths.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Text(l10n.settingsBridgeBlockedNone),
          )
        else
          for (final pattern in settings.bridgeExtraBlockedPaths)
            ListTile(
              dense: true,
              title: Text(
                pattern,
                style: TextStyle(
                  fontFamily: AppTheme.monoFontFamily,
                  fontFamilyFallback: AppTheme.monoFontFamilyFallback,
                  fontSize: 13,
                ),
              ),
              trailing: IconButton(
                tooltip: l10n.settingsBridgeBlockedRemove(pattern),
                icon: const Icon(Icons.close),
                onPressed: () => unawaited(_removePattern(pattern)),
              ),
            ),
        ListTile(
          leading: const Icon(Icons.add),
          title: Text(l10n.settingsBridgeBlockedAdd),
          onTap: () => unawaited(_addPattern()),
        ),
        ListTile(
          leading: const Icon(Icons.shield_outlined),
          title: Text(l10n.settingsBridgeBuiltInView),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _push(const BridgeBuiltInPathsScreen()),
        ),
        _subHeading(context, l10n.settingsBridgePaired),
        StreamBuilder<List<BridgeClient>>(
          initialData: widget.bridge.connectedClients,
          stream: widget.bridge.connectedClientsChanges,
          builder: (context, snapshot) {
            final connected = <String>{
              for (final c in snapshot.data ?? <BridgeClient>[]) c.id,
            };
            if (_paired.isEmpty) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Text(l10n.settingsBridgePairedNone),
              );
            }
            return Column(
              children: [
                for (final c in _paired) _clientTile(context, c, connected),
              ],
            );
          },
        ),
        _oneClick(context),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: FilledButton.tonalIcon(
              icon: const Icon(Icons.add_link),
              label: Text(l10n.settingsBridgeConnect),
              onPressed: () =>
                  _push(BridgeConnectScreen(clients: widget.clients)),
            ),
          ),
        ),
        const SizedBox(height: 8),
        ListTile(
          leading: const Icon(Icons.history),
          title: Text(l10n.settingsBridgeActivity),
          subtitle: Text(l10n.settingsBridgeActivityHelp),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _push(BridgeAuditScreen(audit: widget.audit)),
        ),
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
        if (widget.hostStore != null)
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: Text(
              l10n.settingsBridgeSharedHosts(shared ?? 0, _totalHosts),
            ),
            subtitle: Text(l10n.settingsBridgeSharedHostsHelp),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => unawaited(
              _pushThenCount(
                BridgeSharedHostsScreen(hostStore: widget.hostStore!),
              ),
            ),
          ),
      ],
    );
  }
}

/// The patterns an assistant cannot read unless "Read sensitive paths" is on.
class BridgeBuiltInPathsScreen extends StatelessWidget {
  const BridgeBuiltInPathsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsBridgeBuiltInTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(l10n.settingsBridgeBuiltInIntro),
          const SizedBox(height: 12),
          for (final pattern in BridgePathGuard.builtInPatterns)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: SelectableText(
                pattern,
                style: TextStyle(
                  fontFamily: AppTheme.monoFontFamily,
                  fontFamilyFallback: AppTheme.monoFontFamilyFallback,
                  fontSize: 13,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Asks for one path pattern. Owns its field, so the field outlives the
/// dialog's closing animation.
class _PatternDialog extends StatefulWidget {
  const _PatternDialog();

  @override
  State<_PatternDialog> createState() => _PatternDialogState();
}

class _PatternDialogState extends State<_PatternDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final material = MaterialLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.settingsBridgeBlockedAdd),
      content: TextField(
        controller: _controller,
        autofocus: true,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          labelText: l10n.settingsBridgeBlockedField,
          hintText: '/srv/private/**',
        ),
        style: TextStyle(
          fontFamily: AppTheme.monoFontFamily,
          fontFamilyFallback: AppTheme.monoFontFamilyFallback,
        ),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(material.cancelButtonLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(material.okButtonLabel),
        ),
      ],
    );
  }
}
