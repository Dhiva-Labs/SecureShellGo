import '../../models/host.dart';
import '../../models/host_ai_access.dart';

/// One host as an assistant sees it in `list_hosts`.
///
/// [hostname], [port] and [username] are null unless the user chose "Show
/// address and username": by default an assistant knows a server by the name
/// the user gave it and nothing else.
class BridgeHostEntry {
  const BridgeHostEntry({
    required this.name,
    this.group,
    this.hostname,
    this.port,
    this.username,
  });

  final String name;
  final String? group;
  final String? hostname;
  final int? port;
  final String? username;

  /// Absent fields are left out rather than sent as null, so an assistant is
  /// not told that there is an address it is not being shown.
  Map<String, Object?> toJson() => {
    'name': name,
    if (group != null) 'group': group,
    if (hostname != null) 'hostname': hostname,
    if (port != null) 'port': port,
    if (username != null) 'username': username,
  };

  @override
  bool operator ==(Object other) =>
      other is BridgeHostEntry &&
      other.name == name &&
      other.group == group &&
      other.hostname == hostname &&
      other.port == port &&
      other.username == username;

  @override
  int get hashCode => Object.hash(name, group, hostname, port, username);

  @override
  String toString() => 'BridgeHostEntry(${toJson()})';
}

/// The names an assistant knows the user's servers by, and the way back from
/// a name to a [Host].
///
/// Only hosts with AI access switched on take part at all, in naming as well
/// as in listing: a hidden host never causes a visible one to be renamed, or
/// a duplicate label would give away that a second server of that name
/// exists.
class BridgeHostDirectory {
  const BridgeHostDirectory();

  /// Shortest id prefix used to tell two hosts of one label apart.
  static const int idPrefixLength = 4;

  /// The hosts an assistant may see, in the order given, each with its name.
  ///
  /// A host's name is its label when no other visible host has that label,
  /// else `label#` and the first [idPrefixLength] characters of its id. Ids
  /// that share those characters get a longer prefix, and so does any name
  /// that would land on a label someone already typed (a host literally
  /// labelled `web#ab12`), so every name resolves to exactly one host.
  List<({String name, Host host})> named(Iterable<Host> hosts) {
    final visible = [
      for (final host in hosts)
        if (host.aiAccess != HostAiAccess.off) host,
    ];
    final labelCounts = <String, int>{};
    for (final host in visible) {
      final label = _labelOf(host);
      labelCounts[label] = (labelCounts[label] ?? 0) + 1;
    }

    final names = List<String?>.filled(visible.length, null);
    final taken = <String>{};
    for (var i = 0; i < visible.length; i++) {
      final label = _labelOf(visible[i]);
      if (labelCounts[label] == 1) {
        names[i] = label;
        taken.add(label);
      }
    }
    for (var i = 0; i < visible.length; i++) {
      if (names[i] != null) continue;
      final host = visible[i];
      final label = _labelOf(host);
      final siblings = [
        for (final other in visible)
          if (!identical(other, host) && _labelOf(other) == label) other.id,
      ];
      String? name;
      for (var length = idPrefixLength; length <= host.id.length; length++) {
        final prefix = host.id.substring(0, length);
        final candidate = '$label#$prefix';
        final clashes =
            siblings.any(
              (id) => id.length >= length && id.substring(0, length) == prefix,
            ) ||
            taken.contains(candidate);
        if (!clashes) {
          name = candidate;
          break;
        }
      }
      // Two hosts with one label and one id are a corrupt hosts file; give
      // the position as well rather than two names that cannot be told
      // apart. [resolve] still refuses anything ambiguous.
      name ??= '$label#${host.id}#$i';
      names[i] = name;
      taken.add(name);
    }

    return [
      for (var i = 0; i < visible.length; i++)
        (name: names[i]!, host: visible[i]),
    ];
  }

  /// What `list_hosts` returns.
  List<BridgeHostEntry> list(
    Iterable<Host> hosts, {
    required bool showAddress,
  }) {
    return [
      for (final entry in named(hosts))
        BridgeHostEntry(
          name: entry.name,
          group: _groupOf(entry.host),
          hostname: showAddress ? entry.host.hostname : null,
          port: showAddress ? entry.host.port : null,
          username: showAddress ? entry.host.username : null,
        ),
    ];
  }

  /// The host [name] stands for, or null when it stands for none — including
  /// when it is the label of a host the user has not opened to the bridge.
  ///
  /// The match is exact (case and all): a near miss resolving to a server is
  /// worse than the assistant asking `list_hosts` again.
  Host? resolve(Iterable<Host> hosts, String name) {
    Host? found;
    for (final entry in named(hosts)) {
      if (entry.name != name) continue;
      if (found != null) return null;
      found = entry.host;
    }
    return found;
  }

  static String _labelOf(Host host) {
    final label = host.label.trim();
    return label.isEmpty ? 'host' : label;
  }

  static String? _groupOf(Host host) {
    final group = host.group?.trim();
    return group == null || group.isEmpty ? null : group;
  }
}
