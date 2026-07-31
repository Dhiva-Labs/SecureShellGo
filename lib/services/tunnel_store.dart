import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../models/host.dart';
import '../models/tunnel_profile.dart';
import 'app_data_paths.dart';

/// Persistent store of saved port-forwarding tunnels.
///
/// A near-exact mirror of [HostStore]: a plain JSON file — `tunnels.json` —
/// next to `hosts.json` in the app's private data directory ([AppDataPaths]).
/// A [TunnelProfile] holds no secret of its own (the credentials belong to
/// the host it names), so there is no equivalent of `CredentialStore` to keep
/// it apart from.
class TunnelStore {
  /// [file] overrides the on-disk location; tests use it so they do not need
  /// the path_provider plugin.
  // ignore: prefer_initializing_formals
  TunnelStore({File? file}) : _file = file;

  static const String fileName = 'tunnels.json';

  File? _file;

  /// Insertion order doubles as display order, same reasoning as [HostStore]'s
  /// own map.
  final Map<String, TunnelProfile> _profiles = {};

  final Random _random = Random.secure();

  Future<void>? _loading;
  bool _loaded = false;

  Future<void> ensureLoaded() {
    if (_loaded) return Future<void>.value();
    return _loading ??= _load().whenComplete(() {
      _loading = null;
    });
  }

  Future<File> _resolveFile() async {
    final existing = _file;
    if (existing != null) return existing;
    final dir = await AppDataPaths.resolveDirectory();
    return _file = File('${dir.path}/$fileName');
  }

  Future<void> _load() async {
    try {
      final file = await _resolveFile();
      if (await file.exists()) {
        final raw = await file.readAsString();
        if (raw.trim().isNotEmpty) {
          final decoded = jsonDecode(raw);
          if (decoded is Map<String, dynamic>) {
            final tunnels = decoded['tunnels'];
            if (tunnels is List) {
              for (final entry in tunnels) {
                if (entry is Map<String, dynamic>) {
                  try {
                    final profile = TunnelProfile.fromJson(entry);
                    _profiles[profile.id] = profile;
                  } catch (_) {
                    // Skip one malformed entry rather than losing the store.
                  }
                }
              }
            }
          }
        }
      }
    } catch (_) {
      // A corrupt or unreadable store must not brick the app — see
      // [HostStore] for the same reasoning. Starting empty means the tunnel
      // list looks empty; nothing is listening that the user cannot see.
      _profiles.clear();
    } finally {
      _loaded = true;
    }
  }

  Future<void> _persist() async {
    final file = await _resolveFile();
    final payload = <String, dynamic>{
      'version': 1,
      'tunnels': [for (final profile in _profiles.values) profile.toJson()],
    };
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(payload), flush: true);
  }

  /// A fresh id for a new tunnel: timestamp plus a random suffix, same scheme
  /// as [HostStore.newId].
  String newId() {
    final millis = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final salt = _random.nextInt(1 << 32).toRadixString(36);
    return '$millis-$salt';
  }

  /// All saved tunnels, in the order they were added.
  Future<List<TunnelProfile>> all() async {
    await ensureLoaded();
    return List.unmodifiable(_profiles.values);
  }

  Future<TunnelProfile?> get(String id) async {
    await ensureLoaded();
    return _profiles[id];
  }

  Future<void> add(TunnelProfile profile) async {
    await ensureLoaded();
    _profiles[profile.id] = profile;
    await _persist();
  }

  /// Replaces an existing saved tunnel, keeping its position in the list.
  Future<void> update(TunnelProfile profile) async {
    await ensureLoaded();
    _profiles[profile.id] = profile;
    await _persist();
  }

  Future<void> delete(String id) async {
    await ensureLoaded();
    _profiles.remove(id);
    await _persist();
  }
}

/// One saved tunnel together with the host it names, [host] null when that
/// host has since been deleted.
///
/// Deleting a host deliberately does not go looking for tunnels to delete
/// with it — silently removing a user's saved forwards as a side effect of
/// tidying up the host list is worse than showing them a row that says what
/// is wrong. So the dangling reference is a rendering state, resolved here.
class TunnelBinding {
  const TunnelBinding({required this.profile, this.host});

  final TunnelProfile profile;
  final Host? host;

  bool get isBroken => host == null;

  /// What the group header, and a broken row's subtitle, should say.
  String get hostLabel => host?.displayName ?? 'Missing host';

  /// The inline explanation for a broken row, or null when the row is fine.
  String? get brokenMessage => isBroken
      ? 'The saved host this tunnel rides on has been deleted, so there is '
          'nothing to carry it. Edit the tunnel to point it at another host.'
      : null;
}

/// Every tunnel that rides on one host, in list order.
class TunnelGroup {
  const TunnelGroup({required this.hostLabel, required this.bindings});

  /// The host's display name, or "Missing host" for the broken group.
  final String hostLabel;

  final List<TunnelBinding> bindings;

  bool get isBroken => bindings.first.isBroken;
}

/// Resolves each profile's [TunnelProfile.hostId] against [hosts] and groups
/// the result by host, hosts in their saved-list order and broken references
/// collected into one trailing group.
///
/// A pure function over both lists rather than a method on either store: it
/// is what the tunnels screen renders, and it is the one piece of this
/// feature where a deleted host has to turn into a message instead of a
/// crash — which makes it worth testing without touching a disk.
List<TunnelGroup> groupTunnelsByHost(
  List<TunnelProfile> profiles,
  List<Host> hosts,
) {
  final byId = {for (final host in hosts) host.id: host};
  final grouped = <String, List<TunnelBinding>>{};
  final broken = <TunnelBinding>[];

  for (final profile in profiles) {
    final host = byId[profile.hostId];
    if (host == null) {
      broken.add(TunnelBinding(profile: profile));
    } else {
      grouped.putIfAbsent(host.id, () => []).add(
            TunnelBinding(profile: profile, host: host),
          );
    }
  }

  return [
    // Host order, not tunnel order: the sections line up with the host list
    // the user already knows the shape of.
    for (final host in hosts)
      if (grouped[host.id] != null)
        TunnelGroup(hostLabel: host.displayName, bindings: grouped[host.id]!),
    if (broken.isNotEmpty)
      TunnelGroup(hostLabel: 'Missing host', bindings: broken),
  ];
}
