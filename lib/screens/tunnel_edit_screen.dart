import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
        _error = 'Could not save this tunnel: $e';
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
    final port = _listeningPort;
    final privileged =
        port != null && port > 0 && port < TunnelProfile.privilegedPortCeiling;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isEditing ? 'Edit tunnel' : 'New tunnel'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: const Text('Save'),
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
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'Postgres on the app box',
                ),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: _hostId,
                decoration: const InputDecoration(
                  labelText: 'Carried by',
                  helperText: 'The saved host whose SSH connection carries it',
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
              Text('Type', style: theme.textTheme.labelLarge),
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
                        title: Text('${type.label}  (ssh ${type.sshFlag})'),
                        subtitle: Text(
                          _describe(type),
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                  ],
                ),
              ),
              const Divider(height: 32),
              ..._addressFields(theme),
              if (privileged) ...[
                const SizedBox(height: 12),
                _Warning(
                  icon: Icons.shield_outlined,
                  message: 'Ports below '
                      '${TunnelProfile.privilegedPortCeiling} are privileged. '
                      'Unless this app is running with administrator rights, '
                      'binding port $port will be refused by the system.',
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

  String _describe(TunnelType type) => switch (type) {
        TunnelType.local =>
          'Listen here, and open each connection from the server.',
        TunnelType.remote =>
          'The server listens, and each connection comes back to this device.',
        TunnelType.dynamic =>
          'A SOCKS5 proxy here; the client picks the destination.',
      };

  List<Widget> _addressFields(ThemeData theme) {
    switch (_type) {
      case TunnelType.local:
        return [
          _SectionLabel('Listen on this device', theme: theme),
          _portField(
            controller: _localPortController,
            label: 'Local port',
          ),
          const SizedBox(height: 8),
          ..._bindToggle(theme),
          const SizedBox(height: 20),
          _SectionLabel('Forward to, from the server', theme: theme),
          _hostField(
            controller: _remoteHostController,
            label: 'Destination host',
            hint: 'db.internal or 10.0.0.5',
          ),
          const SizedBox(height: 12),
          _portField(
            controller: _remotePortController,
            label: 'Destination port',
          ),
        ];

      case TunnelType.dynamic:
        return [
          _SectionLabel('SOCKS5 proxy on this device', theme: theme),
          _portField(
            controller: _localPortController,
            label: 'Local port',
          ),
          const SizedBox(height: 8),
          ..._bindToggle(theme),
          const SizedBox(height: 12),
          Text(
            'Point a browser or a command at this port and every connection '
            'it makes is opened by the server instead. No destination to fill '
            'in — the client names one each time.',
            style: theme.textTheme.bodySmall?.copyWith(height: 1.35),
          ),
        ];

      case TunnelType.remote:
        return [
          _SectionLabel('The server listens on', theme: theme),
          _hostField(
            controller: _remoteHostController,
            label: 'Bind address on the server',
            hint: '127.0.0.1, or blank for every interface',
            optional: true,
          ),
          const SizedBox(height: 12),
          _portField(
            controller: _remotePortController,
            label: 'Port on the server',
          ),
          const SizedBox(height: 12),
          Text(
            'A blank bind address asks the server to listen on every '
            'interface, which most servers refuse unless GatewayPorts is on.',
            style: theme.textTheme.bodySmall?.copyWith(height: 1.35),
          ),
          const SizedBox(height: 20),
          _SectionLabel('Connections are handed to', theme: theme),
          _hostField(
            controller: _localHostController,
            label: 'Address on this device',
            hint: TunnelProfile.loopback,
            optional: true,
          ),
          const SizedBox(height: 12),
          _portField(
            controller: _localPortController,
            label: 'Port on this device',
          ),
        ];
    }
  }

  List<Widget> _bindToggle(ThemeData theme) => [
        SwitchListTile(
          value: _exposeToNetwork,
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('Allow other devices to use it'),
          subtitle: Text(
            _exposeToNetwork
                ? 'Binding ${TunnelProfile.anyInterface}'
                : 'Binding ${TunnelProfile.loopback} — this device only',
            style: theme.textTheme.bodySmall,
          ),
          onChanged: (value) => setState(() => _exposeToNetwork = value),
        ),
        if (_exposeToNetwork)
          const _Warning(
            icon: Icons.warning_amber_outlined,
            message: 'This exposes the tunnel to your network: anything that '
                'can reach this device can use it to reach the other end, '
                'with no authentication of its own.',
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
      validator: validateTunnelPort,
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
              ? 'Enter the address to forward to.'
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
