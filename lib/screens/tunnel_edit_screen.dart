import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';
import '../models/host.dart';
import '../models/tunnel_profile.dart';
import '../services/tunnel_store.dart';

/// Add or edit a saved tunnel. [profile] null means "add".
///
/// The form changes shape with the type, because the three types genuinely
/// have different fields: a dynamic forward has no destination to type (the
/// SOCKS client chooses one per connection), and a remote forward's "local"
/// address is somewhere to dial rather than somewhere to listen.
class TunnelEditScreen extends StatefulWidget {
  const TunnelEditScreen({
    super.key,
    required this.tunnelStore,
    required this.hosts,
    this.profile,
  });

  final TunnelStore tunnelStore;

  /// The saved hosts to choose between. Passed in rather than loaded here so
  /// this screen has no opinion about where hosts come from, and so the
  /// caller has already dealt with the "no hosts saved yet" case.
  final List<Host> hosts;

  final TunnelProfile? profile;

  bool get isEditing => profile != null;

  @override
  State<TunnelEditScreen> createState() => _TunnelEditScreenState();
}

class _TunnelEditScreenState extends State<TunnelEditScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _localPortController = TextEditingController();
  final _remoteHostController = TextEditingController();
  final _remotePortController = TextEditingController();
  final _localHostController = TextEditingController();

  late TunnelType _type;
  late String _hostId;

  /// Whether the listener binds every interface instead of loopback. Held as
  /// a flag rather than read back out of [_localHostController] so that
  /// turning it off returns to 127.0.0.1 rather than to whatever the user
  /// last typed.
  var _exposeToNetwork = false;

  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final profile = widget.profile;
    _type = profile?.type ?? TunnelType.local;
    _hostId = profile?.hostId ?? widget.hosts.first.id;
    // A tunnel pointed at a host that has since been deleted opens on the
    // first saved host instead of on a dangling id, so that saving the form
    // repairs it rather than writing the dangling reference straight back.
    if (!widget.hosts.any((host) => host.id == _hostId)) {
      _hostId = widget.hosts.first.id;
    }

    _nameController.text = profile?.name ?? '';
    _localPortController.text =
        profile == null || profile.localPort == 0 ? '' : '${profile.localPort}';
    _remoteHostController.text = profile?.remoteHost ?? '';
    _remotePortController.text = profile == null || profile.remotePort == 0
        ? ''
        : '${profile.remotePort}';
    _exposeToNetwork = profile?.bindsAllInterfaces ?? false;
    _localHostController.text = profile?.localHost ?? TunnelProfile.loopback;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _localPortController.dispose();
    _remoteHostController.dispose();
    _remotePortController.dispose();
    _localHostController.dispose();
    super.dispose();
  }

  /// What the local address ends up as: the typed one for a remote forward
  /// (where it is a destination), and loopback-or-everything for the two
  /// types that listen.
  String get _localHost {
    if (_type == TunnelType.remote) {
      final typed = _localHostController.text.trim();
      return typed.isEmpty ? TunnelProfile.loopback : typed;
    }
    return _exposeToNetwork
        ? TunnelProfile.anyInterface
        : TunnelProfile.loopback;
  }

  Future<void> _save() async {
    if (_saving) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    FocusScope.of(context).unfocus();
    setState(() {
      _saving = true;
      _error = null;
    });

    final l10n = context.l10n;
    final existing = widget.profile;
    final profile = TunnelProfile(
      id: existing?.id ?? widget.tunnelStore.newId(),
      name: _nameController.text.trim(),
      hostId: _hostId,
      type: _type,
      localHost: _localHost,
      localPort: int.tryParse(_localPortController.text.trim()) ?? 0,
      remoteHost: _remoteHostController.text.trim(),
      remotePort: int.tryParse(_remotePortController.text.trim()) ?? 0,
    );

    try {
      if (existing == null) {
        await widget.tunnelStore.add(profile);
      } else {
        await widget.tunnelStore.update(profile);
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = l10n.tunnelsSaveFailed('$e');
      });
    }
  }

  /// The port the listener will actually bind — the only one worth warning
  /// about, and it lives on a different field for a remote forward.
  int? get _listeningPort => int.tryParse(
        (_type == TunnelType.remote
                ? _remotePortController.text
                : _localPortController.text)
            .trim(),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final port = _listeningPort;
    final privileged =
        port != null && port > 0 && port < TunnelProfile.privilegedPortCeiling;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.isEditing ? l10n.tunnelsEditTitle : l10n.tunnelsNewTitle,
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: Text(MaterialLocalizations.of(context).saveButtonLabel),
          ),
        ],
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              TextFormField(
                controller: _nameController,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: l10n.tunnelsName,
                  hintText: l10n.tunnelsNameHint,
                ),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: _hostId,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: l10n.tunnelsCarriedBy,
                  helperText: l10n.tunnelsCarriedByHelp,
                  helperMaxLines: 3,
                ),
                items: [
                  for (final host in widget.hosts)
                    DropdownMenuItem(
                      value: host.id,
                      child: Text(
                        host.displayName,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _hostId = value);
                },
              ),
              const SizedBox(height: 20),
              Text(l10n.tunnelsType, style: theme.textTheme.labelLarge),
              const SizedBox(height: 8),
              RadioGroup<TunnelType>(
                groupValue: _type,
                onChanged: (value) {
                  if (value != null) setState(() => _type = value);
                },
                child: Column(
                  children: [
                    for (final type in TunnelType.values)
                      RadioListTile<TunnelType>(
                        value: type,
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(
                          '${type.labelIn(l10n)}  (ssh ${type.sshFlag})',
                        ),
                        subtitle: Text(
                          _describe(l10n, type),
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                  ],
                ),
              ),
              const Divider(height: 32),
              ..._addressFields(theme, l10n),
              if (privileged) ...[
                const SizedBox(height: 12),
                _Warning(
                  icon: Icons.shield_outlined,
                  message: l10n.tunnelsPrivilegedPort(
                    TunnelProfile.privilegedPortCeiling,
                    port,
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(
                  _error!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _describe(AppLocalizations l10n, TunnelType type) => switch (type) {
        TunnelType.local => l10n.tunnelsDescribeLocal,
        TunnelType.remote => l10n.tunnelsDescribeRemote,
        TunnelType.dynamic => l10n.tunnelsDescribeDynamic,
      };

  List<Widget> _addressFields(ThemeData theme, AppLocalizations l10n) {
    switch (_type) {
      case TunnelType.local:
        return [
          _SectionLabel(l10n.tunnelsListenHere, theme: theme),
          _portField(
            controller: _localPortController,
            label: l10n.tunnelsLocalPort,
          ),
          const SizedBox(height: 8),
          ..._bindToggle(theme, l10n),
          const SizedBox(height: 20),
          _SectionLabel(l10n.tunnelsForwardTo, theme: theme),
          _hostField(
            controller: _remoteHostController,
            label: l10n.tunnelsDestinationHost,
            hint: l10n.tunnelsDestinationHostHint('db.internal', '10.0.0.5'),
          ),
          const SizedBox(height: 12),
          _portField(
            controller: _remotePortController,
            label: l10n.tunnelsDestinationPort,
          ),
        ];

      case TunnelType.dynamic:
        return [
          _SectionLabel(l10n.tunnelsSocksHere, theme: theme),
          _portField(
            controller: _localPortController,
            label: l10n.tunnelsLocalPort,
          ),
          const SizedBox(height: 8),
          ..._bindToggle(theme, l10n),
          const SizedBox(height: 12),
          Text(
            l10n.tunnelsSocksExplain,
            style: theme.textTheme.bodySmall?.copyWith(height: 1.35),
          ),
        ];

      case TunnelType.remote:
        return [
          _SectionLabel(l10n.tunnelsServerListens, theme: theme),
          _hostField(
            controller: _remoteHostController,
            label: l10n.tunnelsServerBind,
            hint: l10n.tunnelsServerBindHint(TunnelProfile.loopback),
            optional: true,
          ),
          const SizedBox(height: 12),
          _portField(
            controller: _remotePortController,
            label: l10n.tunnelsServerPort,
          ),
          const SizedBox(height: 12),
          Text(
            l10n.tunnelsGatewayPorts,
            style: theme.textTheme.bodySmall?.copyWith(height: 1.35),
          ),
          const SizedBox(height: 20),
          _SectionLabel(l10n.tunnelsHandedTo, theme: theme),
          _hostField(
            controller: _localHostController,
            label: l10n.tunnelsDeviceAddress,
            hint: TunnelProfile.loopback,
            optional: true,
          ),
          const SizedBox(height: 12),
          _portField(
            controller: _localPortController,
            label: l10n.tunnelsDevicePort,
          ),
        ];
    }
  }

  List<Widget> _bindToggle(ThemeData theme, AppLocalizations l10n) => [
        SwitchListTile(
          value: _exposeToNetwork,
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(l10n.tunnelsAllowOthers),
          subtitle: Text(
            _exposeToNetwork
                ? l10n.tunnelsBindingAll(TunnelProfile.anyInterface)
                : l10n.tunnelsBindingLoopback(TunnelProfile.loopback),
            style: theme.textTheme.bodySmall,
          ),
          onChanged: (value) => setState(() => _exposeToNetwork = value),
        ),
        if (_exposeToNetwork)
          _Warning(
            icon: Icons.warning_amber_outlined,
            message: l10n.tunnelsExposeWarning,
          ),
      ];

  Widget _portField({
    required TextEditingController controller,
    required String label,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      textInputAction: TextInputAction.next,
      decoration: InputDecoration(labelText: label),
      validator: (value) => validateTunnelPort(value)?.textIn(context.l10n),
      // Repaints the privileged-port warning as the number is typed.
      onChanged: (_) => setState(() {}),
    );
  }

  Widget _hostField({
    required TextEditingController controller,
    required String label,
    String? hint,
    bool optional = false,
  }) {
    return TextFormField(
      controller: controller,
      textInputAction: TextInputAction.next,
      autocorrect: false,
      decoration: InputDecoration(labelText: label, hintText: hint),
      validator: optional
          ? null
          : (value) => (value?.trim().isEmpty ?? true)
              ? context.l10n.tunnelsEnterAddress
              : null,
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label, {required this.theme});

  final String label;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        label.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          letterSpacing: 1.1,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _Warning extends StatelessWidget {
  const _Warning({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: theme.colorScheme.error.withValues(alpha: 0.12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.error),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

/// The tunnel screens' words for a tunnel type, in the app's language.
extension TunnelTypeText on TunnelType {
  String labelIn(AppLocalizations l10n) => switch (this) {
        TunnelType.local => l10n.tunnelsTypeLocal,
        TunnelType.remote => l10n.tunnelsTypeRemote,
        TunnelType.dynamic => l10n.tunnelsTypeDynamic,
      };
}

extension TunnelPortProblemText on TunnelPortProblem {
  String textIn(AppLocalizations l10n) => switch (this) {
        TunnelPortProblem.empty => l10n.tunnelsPortEmpty,
        TunnelPortProblem.notANumber => l10n.tunnelsPortNotNumber,
        TunnelPortProblem.zero => l10n.tunnelsPortZero,
        TunnelPortProblem.outOfRange => l10n.tunnelsPortRange(1, 65535),
      };
}

/// [TunnelProfile.displayName] and [TunnelProfile.portSummary], with the one
/// word in either ("SOCKS5 on …") in the app's language.
extension TunnelProfileText on TunnelProfile {
  String summaryIn(AppLocalizations l10n) => type == TunnelType.dynamic
      ? l10n.tunnelsSocksSummary('$localHost:$localPort')
      : portSummary;

  String displayNameIn(AppLocalizations l10n) =>
      name.trim().isEmpty ? summaryIn(l10n) : name.trim();
}
