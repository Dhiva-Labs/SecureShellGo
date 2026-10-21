import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/host.dart';

/// The per-host choices behind the "Advanced" fold of the host form.
///
/// A value of its own, rather than five more fields on the form's state, so
/// the form only has to read one in and write one out. The certificate is
/// not here: it belongs with the key it certifies, in the form's sign-in
/// area.
@immutable
class HostAdvancedOptions {
  const HostAdvancedOptions({
    this.transport = HostTransport.ssh,
    this.persistentSession = PersistentSession.off,
    this.agentForwarding = false,
    this.x11Forwarding = false,
    this.legacyAlgorithms = false,
  });

  HostAdvancedOptions.of(Host host)
      : transport = host.transport,
        persistentSession = host.persistentSession,
        agentForwarding = host.agentForwarding,
        x11Forwarding = host.x11Forwarding,
        legacyAlgorithms = host.legacyAlgorithms;

  final HostTransport transport;
  final PersistentSession persistentSession;
  final bool agentForwarding;
  final bool x11Forwarding;
  final bool legacyAlgorithms;

  /// True when nothing has been changed from a new host's settings.
  bool get isDefault => this == const HostAdvancedOptions();

  /// The non-default choices in a few words, for the folded header.
  String get summary {
    final parts = [
      if (transport != HostTransport.ssh) transport.label,
      if (persistentSession != PersistentSession.off) persistentSession.label,
      if (agentForwarding) 'agent forwarding',
      if (x11Forwarding) 'X11',
      if (legacyAlgorithms) 'legacy algorithms',
    ];
    return parts.isEmpty
        ? 'Connection, session and forwarding'
        : parts.join(' · ');
  }

  HostAdvancedOptions copyWith({
    HostTransport? transport,
    PersistentSession? persistentSession,
    bool? agentForwarding,
    bool? x11Forwarding,
    bool? legacyAlgorithms,
  }) =>
      HostAdvancedOptions(
        transport: transport ?? this.transport,
        persistentSession: persistentSession ?? this.persistentSession,
        agentForwarding: agentForwarding ?? this.agentForwarding,
        x11Forwarding: x11Forwarding ?? this.x11Forwarding,
        legacyAlgorithms: legacyAlgorithms ?? this.legacyAlgorithms,
      );

  @override
  bool operator ==(Object other) =>
      other is HostAdvancedOptions &&
      other.transport == transport &&
      other.persistentSession == persistentSession &&
      other.agentForwarding == agentForwarding &&
      other.x11Forwarding == x11Forwarding &&
      other.legacyAlgorithms == legacyAlgorithms;

  @override
  int get hashCode => Object.hash(
        transport,
        persistentSession,
        agentForwarding,
        x11Forwarding,
        legacyAlgorithms,
      );
}

/// The "Advanced" fold of the host form: how the shell travels, whether it
/// outlives a dropped connection, what is forwarded, and the old-algorithms
/// escape hatch. Folded unless something in it is already changed, so the
/// form a new user sees stays short.
///
/// Each row is one feature's switch; the work behind a row lives elsewhere
/// and only touches its own row here.
class HostAdvancedSection extends StatelessWidget {
  const HostAdvancedSection({
    super.key,
    required this.options,
    required this.onChanged,
  });

  final HostAdvancedOptions options;
  final ValueChanged<HostAdvancedOptions> onChanged;

  /// Where an OS agent and an X server can exist: the desktops, not
  /// Android. Read from [defaultTargetPlatform] so a test can be either.
  static bool get _isDesktop => switch (defaultTargetPlatform) {
        TargetPlatform.linux ||
        TargetPlatform.windows ||
        TargetPlatform.macOS =>
          true,
        _ => false,
      };

  @override
  Widget build(BuildContext context) {
    final desktop = _isDesktop;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 8),
      initiallyExpanded: !options.isDefault,
      leading: const Icon(Icons.tune),
      title: const Text('Advanced'),
      subtitle: Text(options.summary, style: muted),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 4),
        Text('Terminal connection', style: theme.textTheme.bodyLarge),
        const SizedBox(height: 8),
        SegmentedButton<HostTransport>(
          segments: [
            for (final t in HostTransport.values)
              ButtonSegment(value: t, label: Text(t.label)),
          ],
          selected: {options.transport},
          showSelectedIcon: false,
          onSelectionChanged: (picked) =>
              onChanged(options.copyWith(transport: picked.first)),
        ),
        const SizedBox(height: 6),
        Text(
          options.transport == HostTransport.mosh
              ? 'Keeps the terminal alive across network changes and sleep. '
                  'Needs mosh-server on the host and UDP ports 60000–61000 '
                  'open. Files and tunnels still use SSH.'
              : 'The standard connection, used for everything.',
          style: muted,
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<PersistentSession>(
          initialValue: options.persistentSession,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Keep the shell running on the server',
            prefixIcon: Icon(Icons.layers_outlined),
            helperText: 'A reconnect returns to the same shell. Needs tmux '
                'or screen on the host.',
            helperMaxLines: 5,
          ),
          items: [
            for (final p in PersistentSession.values)
              DropdownMenuItem(value: p, child: Text(p.label)),
          ],
          onChanged: (value) {
            if (value != null) {
              onChanged(options.copyWith(persistentSession: value));
            }
          },
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: options.agentForwarding,
          onChanged: (value) =>
              onChanged(options.copyWith(agentForwarding: value)),
          secondary: const Icon(Icons.key_outlined),
          title: const Text('Forward SSH agent'),
          // Android has no OS agent, so there the one key to forward is the
          // one this host signs in with.
          subtitle: Text(
            desktop
                ? 'Lets git and ssh in the shell use the keys in this '
                    'computer\'s SSH agent and this host\'s own key. Only '
                    'for servers you trust: while you are connected, anyone '
                    'with root there can use them.'
                : 'Lets git and ssh in the shell use this host\'s own key, '
                    'which stays on this device. Only for servers you trust: '
                    'while you are connected, anyone with root there can use '
                    'it.',
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          // Off and disabled where there is no X server to draw on. A host
          // carried over from a desktop keeps its setting for when it goes
          // back; it is simply not used here.
          value: desktop && options.x11Forwarding,
          onChanged: desktop
              ? (value) => onChanged(options.copyWith(x11Forwarding: value))
              : null,
          secondary: const Icon(Icons.picture_in_picture_alt_outlined),
          title: const Text('Forward X11'),
          subtitle: Text(
            !desktop
                ? 'Not available on this device: it has no X server to draw '
                    'the windows on.'
                // Windows X servers have no untrusted mode, so there it is
                // always ssh -Y's full access, and the row says so.
                : defaultTargetPlatform == TargetPlatform.windows
                    ? 'Shows the windows of graphical programs started on '
                        'the server. Needs an X server running here, such as '
                        'VcXsrv or X410. Only for servers you trust: while '
                        'you are connected, the server can see and control '
                        'every window on this display.'
                    : 'Shows the windows of graphical programs started on '
                        'the server. Needs an X server on this device. They '
                        'get limited access, as with ssh -X; if this display '
                        'cannot do that, they can see and control every '
                        'window on it, and the terminal says so.',
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: options.legacyAlgorithms,
          onChanged: (value) =>
              onChanged(options.copyWith(legacyAlgorithms: value)),
          secondary: const Icon(Icons.history_toggle_off),
          title: const Text('Allow legacy algorithms'),
          subtitle: const Text(
            'Only for an old router or NAS that cannot connect otherwise. '
            'Adds SHA-1 key exchange and host-key signatures and CBC '
            'ciphers, which are weaker, for this host only.',
          ),
        ),
      ],
    );
  }
}
