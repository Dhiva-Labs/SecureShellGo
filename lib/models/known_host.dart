/// A host key the user has explicitly trusted.
///
/// Mirrors one line of an OpenSSH `known_hosts` file: trust is scoped to the
/// (hostname, port, key type) triple, so a server that offers both an ed25519
/// and an RSA key gets one entry per key type — exactly like OpenSSH. That
/// matters: without the key type in the identity, ordinary algorithm
/// negotiation would look like a key change and raise a false MITM alarm.
class KnownHostKey {
  const KnownHostKey({
    required this.hostname,
    required this.port,
    required this.keyType,
    required this.fingerprint,
    required this.addedAt,
  });

  /// Hostname or IP as typed by the user, lowercased.
  final String hostname;

  final int port;

  /// SSH host key algorithm, e.g. `ssh-ed25519`, `rsa-sha2-512`.
  final String keyType;

  /// OpenSSH-style fingerprint, e.g. `SHA256:47DEQpj8HBS...`.
  final String fingerprint;

  final DateTime addedAt;

  /// Identity of the host itself, ignoring key type.
  static String hostId(String hostname, int port) =>
      '${hostname.trim().toLowerCase()}:$port';

  /// Identity of a single trusted key. Used as the JSON map key.
  static String entryId(String hostname, int port, String keyType) =>
      '${hostId(hostname, port)}|$keyType';

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
