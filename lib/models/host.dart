/// How the user authenticates against a remote host.
enum SshAuthMethod {
  password,
  privateKey;

  String get label => switch (this) {
        SshAuthMethod.password => 'Password',
        SshAuthMethod.privateKey => 'Private key',
      };

  static SshAuthMethod fromName(String? name) => SshAuthMethod.values.firstWhere(
        (m) => m.name == name,
        orElse: () => SshAuthMethod.password,
      );
}

/// A fixed palette of colour tags a saved host can be labelled with, purely
/// for telling servers apart at a glance in the list. Persisted as [name] (a
/// stable string id) rather than a raw ARGB value — same reasoning as
/// [SshAuthMethod] — so the actual swatch (see `theme.dart`'s
/// `AppTheme.hostColorFor`) can be re-tuned later without touching
/// `hosts.json`. `models/` stays free of `Color`, matching the dependency
/// rule that keeps this file Flutter-free.
enum HostColorLabel {
  red,
  orange,
  yellow,
  green,
  teal,
  blue,
  purple,
  pink;

  String get label => switch (this) {
        HostColorLabel.red => 'Red',
        HostColorLabel.orange => 'Orange',
        HostColorLabel.yellow => 'Yellow',
        HostColorLabel.green => 'Green',
        HostColorLabel.teal => 'Teal',
        HostColorLabel.blue => 'Blue',
        HostColorLabel.purple => 'Purple',
        HostColorLabel.pink => 'Pink',
      };

  /// Parses a stored id back into a value. Unlike [SshAuthMethod.fromName],
  /// an unrecognised or absent id reads as "no colour label" rather than
  /// falling back to a default swatch — a host with no tag is a legitimate,
  /// common case here, not a migration gap.
  static HostColorLabel? fromId(String? id) {
    if (id == null) return null;
    for (final value in HostColorLabel.values) {
      if (value.name == id) return value;
    }
    return null;
  }
}

/// A remote machine the user connects to.
///
/// This is the persistable half of a connection: it deliberately contains no
/// secrets. Passwords, private keys and passphrases live in [SshCredentials],
/// which is held in memory only for the duration of a connect attempt.
class Host {
  const Host({
    required this.id,
    required this.label,
    required this.hostname,
    required this.port,
    required this.username,
    required this.authMethod,
    this.lastConnectedAt,
    this.group,
    this.colorLabel,
  });

  final String id;
  final String label;
  final String hostname;
  final int port;
  final String username;
  final SshAuthMethod authMethod;

  /// When this host was last successfully connected to, or null if never.
  /// Purely informational — nothing reads it to make a trust or security
  /// decision, so a missing or unparsable value just means "unknown".
  final DateTime? lastConnectedAt;

  /// The saved-hosts list section this host sits in, or null for the
  /// trailing Ungrouped section. There is no separate group table — a group
  /// exists only as long as some host names it — so this string *is* the
  /// group, and renaming/deleting one is a bulk edit across every host that
  /// shares it (see `HostStore.renameGroup`/`deleteGroup`).
  final String? group;

  /// This host's colour tag, or null for none.
  final HostColorLabel? colorLabel;

  /// `user@host` or `user@host:port` when the port is non-standard.
  String get target =>
      port == 22 ? '$username@$hostname' : '$username@$hostname:$port';

  /// What to show in an app bar: the user-given label, falling back to target.
  String get displayName => label.trim().isEmpty ? target : label.trim();

  Host copyWith({
    String? id,
    String? label,
    String? hostname,
    int? port,
    String? username,
    SshAuthMethod? authMethod,
    DateTime? lastConnectedAt,
    String? group,
    HostColorLabel? colorLabel,
  }) {
    return Host(
      id: id ?? this.id,
      label: label ?? this.label,
      hostname: hostname ?? this.hostname,
      port: port ?? this.port,
      username: username ?? this.username,
      authMethod: authMethod ?? this.authMethod,
      lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt,
      group: group ?? this.group,
      colorLabel: colorLabel ?? this.colorLabel,
    );
  }

  /// Reassigns this host's group, [group] null meaning Ungrouped.
  ///
  /// Not folded into [copyWith]: that helper's `??` merge can only ever move
  /// a field away from null, never back to it, which is exactly what moving
  /// a host to Ungrouped (or the group-delete bulk edit in
  /// `HostStore.deleteGroup`) needs to do.
  Host withGroup(String? group) => Host(
        id: id,
        label: label,
        hostname: hostname,
        port: port,
        username: username,
        authMethod: authMethod,
        lastConnectedAt: lastConnectedAt,
        group: group,
        colorLabel: colorLabel,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'hostname': hostname,
        'port': port,
        'username': username,
        'authMethod': authMethod.name,
        if (lastConnectedAt != null)
          'lastConnectedAt': lastConnectedAt!.toIso8601String(),
        if (group != null) 'group': group,
        if (colorLabel != null) 'colorLabel': colorLabel!.name,
      };

  factory Host.fromJson(Map<String, dynamic> json) {
    final rawGroup = json['group'] as String?;
    return Host(
      id: json['id'] as String,
      label: (json['label'] as String?) ?? '',
      hostname: json['hostname'] as String,
      port: (json['port'] as num?)?.toInt() ?? 22,
      username: json['username'] as String,
      authMethod: SshAuthMethod.fromName(json['authMethod'] as String?),
      // Absent on every host saved before Phase 4 — that just reads as
      // "never" rather than failing the whole entry.
      lastConnectedAt: switch (json['lastConnectedAt']) {
        final String iso => DateTime.tryParse(iso),
        _ => null,
      },
      // Absent on every host saved before v1.3.0 — reads as Ungrouped/no
      // colour rather than failing the entry, same as lastConnectedAt above.
      group: (rawGroup == null || rawGroup.trim().isEmpty) ? null : rawGroup,
      colorLabel: HostColorLabel.fromId(json['colorLabel'] as String?),
    );
  }
}

/// Secrets used for a single connect attempt. Never persisted in Phase 1.
class SshCredentials {
  const SshCredentials({
    this.password,
    this.privateKeyPem,
    this.passphrase,
  });

  final String? password;
  final String? privateKeyPem;
  final String? passphrase;
}
