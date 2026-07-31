/// Which way a saved tunnel moves connections.
///
/// The three cases are OpenSSH's `-L`, `-R` and `-D`, and they are told apart
/// here rather than by looking at which fields happen to be filled in: a
/// dynamic forward and a local forward with no destination yet would
/// otherwise be the same record.
enum TunnelType {
  /// `ssh -L`: this device listens, and every connection it accepts is
  /// carried over the SSH connection and opened from the *server* to
  /// [TunnelProfile.remoteHost]:[TunnelProfile.remotePort].
  local,

  /// `ssh -R`: the *server* listens on
  /// [TunnelProfile.remoteHost]:[TunnelProfile.remotePort], and every
  /// connection it accepts comes back here and is opened to
  /// [TunnelProfile.localHost]:[TunnelProfile.localPort].
  remote,

  /// `ssh -D`: this device listens as a SOCKS5 proxy, and the destination is
  /// chosen per connection by whatever is using the proxy — so
  /// [TunnelProfile.remoteHost] and [TunnelProfile.remotePort] are unused.
  dynamic;

  String get label => switch (this) {
        TunnelType.local => 'Local forward',
        TunnelType.remote => 'Remote forward',
        TunnelType.dynamic => 'Dynamic (SOCKS5)',
      };

  /// The equivalent OpenSSH flag, shown next to [label] in the type picker —
  /// anyone who has typed `ssh -L` before knows instantly which one they
  /// want, and nobody has to guess what "local" is local *to*.
  String get sshFlag => switch (this) {
        TunnelType.local => '-L',
        TunnelType.remote => '-R',
        TunnelType.dynamic => '-D',
      };

  /// One letter for the list's type badge.
  String get badge => switch (this) {
        TunnelType.local => 'L',
        TunnelType.remote => 'R',
        TunnelType.dynamic => 'D',
      };

  /// Parses a stored id. An unrecognised one reads as [local] rather than
  /// failing the whole entry — same reasoning as [SshAuthMethod.fromName] in
  /// `models/host.dart`, and a local forward is the type that cannot listen
  /// anywhere the user did not ask it to.
  static TunnelType fromName(String? name) => TunnelType.values.firstWhere(
        (t) => t.name == name,
        orElse: () => TunnelType.local,
      );
}

/// A saved port-forwarding tunnel.
///
/// Persistable and deliberately free of secrets, exactly like [Host]: a
/// tunnel names the saved host whose SSH connection carries it ([hostId]) and
/// nothing else — no credentials, and no live socket state.
///
/// [hostId] is a reference rather than an embedded copy for the same reason
/// [Host.jumpHostId] is: the address and credentials are edited in one place.
/// It can therefore dangle when that host is deleted, which is resolved (and
/// rendered as a broken row) in `tunnel_store.dart`, not here — a model that
/// only sees itself cannot see the other records.
class TunnelProfile {
  const TunnelProfile({
    required this.id,
    required this.name,
    required this.hostId,
    required this.type,
    required this.localPort,
    this.localHost = loopback,
    this.remoteHost = '',
    this.remotePort = 0,
  });

  /// What this device binds unless the user explicitly opts out. Everything
  /// else on the machine can reach a loopback listener; nothing on the
  /// network can.
  static const String loopback = '127.0.0.1';

  /// Every IPv4 interface — the opt-out. See the warning the edit form puts
  /// next to it, and `TunnelRuntime`, which never substitutes this for
  /// [loopback] on its own.
  static const String anyInterface = '0.0.0.0';

  /// Ports below this need root/Administrator on every platform this app
  /// runs on. Not refused — a user who has the privilege is entitled to use
  /// it — but warned about, because the bind failure it usually produces is
  /// otherwise a mystery.
  static const int privilegedPortCeiling = 1024;

  final String id;

  /// What the list calls this tunnel. May be blank; [displayName] falls back
  /// to the port summary, which is what the user actually recognises it by.
  final String name;

  /// The saved [Host] whose SSH connection carries this tunnel.
  final String hostId;

  final TunnelType type;

  /// The address on *this* device: what [TunnelType.local] and
  /// [TunnelType.dynamic] listen on, and what [TunnelType.remote] connects
  /// out to when the server hands a connection back.
  final String localHost;

  final int localPort;

  /// The address on the *far* side: what [TunnelType.local] asks the server
  /// to open, and what [TunnelType.remote] asks the server to listen on.
  /// Unused for [TunnelType.dynamic].
  final String remoteHost;

  final int remotePort;

  /// True when this profile listens on something other than loopback, and so
  /// exposes the tunnel to the local network.
  bool get bindsAllInterfaces =>
      type != TunnelType.remote && localHost.trim() != loopback;

  /// Whether either end of this profile needs a privileged port.
  bool get usesPrivilegedPort =>
      (type == TunnelType.remote ? remotePort : localPort) > 0 &&
      (type == TunnelType.remote ? remotePort : localPort) <
          privilegedPortCeiling;

  String get displayName => name.trim().isEmpty ? portSummary : name.trim();

  /// The one line that says what this tunnel actually does, in the direction
  /// the bytes travel.
  String get portSummary => switch (type) {
        TunnelType.local => '$localHost:$localPort → $remoteHost:$remotePort',
        TunnelType.remote =>
          '${remoteHost.isEmpty ? '*' : remoteHost}:$remotePort → '
              '$localHost:$localPort',
        TunnelType.dynamic => 'SOCKS5 on $localHost:$localPort',
      };

  TunnelProfile copyWith({
    String? id,
    String? name,
    String? hostId,
    TunnelType? type,
    String? localHost,
    int? localPort,
    String? remoteHost,
    int? remotePort,
  }) {
    return TunnelProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      hostId: hostId ?? this.hostId,
      type: type ?? this.type,
      localHost: localHost ?? this.localHost,
      localPort: localPort ?? this.localPort,
      remoteHost: remoteHost ?? this.remoteHost,
      remotePort: remotePort ?? this.remotePort,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'hostId': hostId,
        'type': type.name,
        'localHost': localHost,
        'localPort': localPort,
        // Written even when unused (a dynamic forward), so that switching a
        // profile's type in the editor and switching it back does not lose
        // the destination the user had already typed.
        'remoteHost': remoteHost,
        'remotePort': remotePort,
      };

  factory TunnelProfile.fromJson(Map<String, dynamic> json) {
    final localHost = (json['localHost'] as String?)?.trim();
    return TunnelProfile(
      id: json['id'] as String,
      name: (json['name'] as String?) ?? '',
      hostId: (json['hostId'] as String?) ?? '',
      type: TunnelType.fromName(json['type'] as String?),
      // A blank bind address means "every interface" to `ServerSocket.bind`,
      // which is precisely the thing this app never does by accident.
      localHost:
          (localHost == null || localHost.isEmpty) ? loopback : localHost,
      localPort: (json['localPort'] as num?)?.toInt() ?? 0,
      remoteHost: (json['remoteHost'] as String?) ?? '',
      remotePort: (json['remotePort'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Validates a typed port, returning the message to show under the field or
/// null when it is fine.
///
/// A free function rather than a method on the form so the rule is one thing
/// in one place: three fields on the edit screen use it, and port 0 means
/// two different things (a legitimate "pick one for me" on a remote forward,
/// nonsense on a listener) that a widget-local check kept getting wrong.
String? validateTunnelPort(String? raw, {bool allowEphemeral = false}) {
  final trimmed = raw?.trim() ?? '';
  if (trimmed.isEmpty) return 'Enter a port.';
  final value = int.tryParse(trimmed);
  if (value == null) return 'Ports are numbers.';
  if (value == 0) {
    return allowEphemeral ? null : 'Port 0 is not a port to listen on.';
  }
  if (value < 0 || value > 65535) return 'Ports run from 1 to 65535.';
  return null;
}
