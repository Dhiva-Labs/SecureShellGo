/// A host key the user has explicitly trusted.
///
/// Mirrors one line of an OpenSSH `known_hosts` file: trust is scoped to the
/// (hostname, port, key type) triple, so a server that offers both an ed25519
/// and an RSA key gets one entry per key type — exactly like OpenSSH. That
/// matters: without the key type in the identity, ordinary algorithm
/// negotiation would look like a key change and raise a false MITM alarm.
///
/// "Key type" means the type of the *key*, not the signature algorithm the
/// handshake happened to negotiate — see [canonicalKeyType].
class KnownHostKey {
  KnownHostKey({
    required this.hostname,
    required this.port,
    required String keyType,
    required this.fingerprint,
    required this.addedAt,
  }) : keyType = canonicalKeyType(keyType);

  /// Hostname or IP as typed by the user, lowercased.
  final String hostname;

  final int port;

  /// SSH host key type, e.g. `ssh-ed25519`, `ssh-rsa`. Always canonical.
  final String keyType;

  /// OpenSSH-style fingerprint, e.g. `SHA256:47DEQpj8HBS...`.
  final String fingerprint;

  final DateTime addedAt;

  /// Identity of the host itself, ignoring key type.
  static String hostId(String hostname, int port) =>
      '${hostname.trim().toLowerCase()}:$port';

  /// Identity of a single trusted key. Used as the JSON map key.
  static String entryId(String hostname, int port, String keyType) =>
      '${hostId(hostname, port)}|${canonicalKeyType(keyType)}';

  /// Folds the three signature algorithms one RSA key can be used with onto
  /// the key's own type, `ssh-rsa`, the way OpenSSH's `known_hosts` does.
  ///
  /// dartssh2 reports the *negotiated algorithm*, so one RSA host key reaches
  /// the policy as `rsa-sha2-512`, `rsa-sha2-256` or `ssh-rsa` depending on
  /// what the two sides agreed. Keyed on that, a machine-in-the-middle with
  /// its own RSA key only had to offer a different RSA algorithm to be shown
  /// the mild first-use prompt instead of the blocking changed-key warning.
  static String canonicalKeyType(String keyType) => switch (keyType) {
        'rsa-sha2-256' || 'rsa-sha2-512' => 'ssh-rsa',
        _ => keyType,
      };

  String get id => entryId(hostname, port, keyType);

  Map<String, dynamic> toJson() => {
        'hostname': hostname,
        'port': port,
        'keyType': keyType,
        'fingerprint': fingerprint,
        'addedAt': addedAt.toIso8601String(),
      };

  factory KnownHostKey.fromJson(Map<String, dynamic> json) => KnownHostKey(
        hostname: (json['hostname'] as String).toLowerCase(),
        port: (json['port'] as num?)?.toInt() ?? 22,
        keyType: json['keyType'] as String,
        fingerprint: json['fingerprint'] as String,
        addedAt: DateTime.tryParse(json['addedAt'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );
}
