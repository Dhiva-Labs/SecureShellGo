import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../models/host.dart';
import 'app_data_paths.dart';

/// Persistent store of saved hosts.
///
/// Mirrors [KnownHostsService]'s approach: a plain JSON file in the app's
/// private data directory ([AppDataPaths]), next to `known_hosts.json`. That
/// is fine for [Host] specifically, because it is deliberately free of
/// secrets — see `models/host.dart`. Passwords, keys and passphrases live in
/// [CredentialStore] instead.
class HostStore {
  /// [file] overrides the on-disk location; tests use it so they do not need
  /// the path_provider plugin.
  // ignore: prefer_initializing_formals
  HostStore({File? file}) : _file = file;

  static const String fileName = 'hosts.json';

  File? _file;

  /// Insertion order doubles as display order: a plain [Map] in Dart is a
  /// [LinkedHashMap], so updating an existing key in place does not move it.
  final Map<String, Host> _hosts = {};

  final Random _random = Random.secure();

  Future<void>? _loading;
  bool _loaded = false;

  /// Loads the store from disk once; concurrent callers share one future.
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
            final hosts = decoded['hosts'];
            if (hosts is List) {
              for (final entry in hosts) {
                if (entry is Map<String, dynamic>) {
                  try {
                    final host = Host.fromJson(entry);
                    _hosts[host.id] = host;
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
      // KnownHostsService for the same reasoning. Starting empty just means
      // the host list looks empty; nothing is trusted or connected silently.
      _hosts.clear();
    } finally {
      _loaded = true;
    }
  }

  Future<void> _persist() async {
    final file = await _resolveFile();
    final payload = <String, dynamic>{
      'version': 1,
      'hosts': [for (final host in _hosts.values) host.toJson()],
    };
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(payload), flush: true);
  }

  /// A fresh id for a new saved host: timestamp plus a random suffix, unique
  /// enough for one on-device store. Callers build the [Host] to add with
  /// this as its id (so the credential store can be keyed the same way
  /// before the host is even persisted).
  String newId() {
    final millis = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final salt = _random.nextInt(1 << 32).toRadixString(36);
    return '$millis-$salt';
  }

  /// All saved hosts, in the order they were added (edits keep their spot).
  Future<List<Host>> all() async {
    await ensureLoaded();
    return List.unmodifiable(_hosts.values);
  }

  Future<Host?> get(String id) async {
    await ensureLoaded();
    return _hosts[id];
  }

  /// Adds a new saved host. [host.id] should come from [newId()].
  Future<void> add(Host host) async {
    await ensureLoaded();
    _hosts[host.id] = host;
    await _persist();
  }

  /// Replaces an existing saved host, keeping its position in the list.
  Future<void> update(Host host) async {
    await ensureLoaded();
    _hosts[host.id] = host;
    await _persist();
  }

  /// Removes a saved host. A no-op if it is already gone.
  ///
  /// Only removes the [Host] entry itself — callers are responsible for also
  /// deleting its credentials ([CredentialStore]) and, if wanted, its trusted
  /// host keys ([KnownHostsService.forgetHost]); see `host_list_screen.dart`.
  Future<void> delete(String id) async {
    await ensureLoaded();
    _hosts.remove(id);
    await _persist();
  }
}
