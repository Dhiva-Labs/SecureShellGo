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
  }) {
    return Host(
      id: id ?? this.id,
      label: label ?? this.label,
      hostname: hostname ?? this.hostname,
      port: port ?? this.port,
      username: username ?? this.username,
      authMethod: authMethod ?? this.authMethod,
      lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'hostname': hostname,
        'port': port,
        'username': username,
        'authMethod': authMethod.name,
        if (lastConnectedAt != null)
          'lastConnectedAt': lastConnectedAt!.toIso8601String(),
      };

  factory Host.fromJson(Map<String, dynamic> json) => Host(
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
      );
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
