import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../models/snippet.dart';
import 'app_data_paths.dart';

/// Persistent store of saved command snippets.
///
/// A near-exact mirror of [HostStore]: a plain JSON file — `snippets.json` —
/// next to `hosts.json` in the app's private data directory
/// ([AppDataPaths]). A snippet is never a secret, so there is no equivalent
/// of `CredentialStore` to keep it apart from.
class SnippetStore {
  /// [file] overrides the on-disk location; tests use it so they do not need
  /// the path_provider plugin.
  // ignore: prefer_initializing_formals
  SnippetStore({File? file}) : _file = file;

  static const String fileName = 'snippets.json';

  File? _file;

  /// Insertion order doubles as display order, same reasoning as
  /// [HostStore]'s own map.
  final Map<String, Snippet> _snippets = {};

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
            final snippets = decoded['snippets'];
            if (snippets is List) {
              for (final entry in snippets) {
                if (entry is Map<String, dynamic>) {
                  try {
                    final snippet = Snippet.fromJson(entry);
                    _snippets[snippet.id] = snippet;
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
      // HostStore for the same reasoning.
      _snippets.clear();
    } finally {
      _loaded = true;
    }
  }

  Future<void> _persist() async {
    final file = await _resolveFile();
    final payload = <String, dynamic>{
      'version': 1,
      'snippets': [for (final snippet in _snippets.values) snippet.toJson()],
    };
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(payload), flush: true);
  }

  /// A fresh id for a new snippet: timestamp plus a random suffix, same
  /// scheme as [HostStore.newId].
  String newId() {
    final millis = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final salt = _random.nextInt(1 << 32).toRadixString(36);
    return '$millis-$salt';
  }

  /// All saved snippets, in the order they were added.
  Future<List<Snippet>> all() async {
    await ensureLoaded();
    return List.unmodifiable(_snippets.values);
  }

  Future<Snippet?> get(String id) async {
    await ensureLoaded();
    return _snippets[id];
  }

  Future<void> add(Snippet snippet) async {
    await ensureLoaded();
    _snippets[snippet.id] = snippet;
    await _persist();
  }

  /// Replaces an existing saved snippet, keeping its position in the list.
  Future<void> update(Snippet snippet) async {
    await ensureLoaded();
    _snippets[snippet.id] = snippet;
    await _persist();
  }

  Future<void> delete(String id) async {
    await ensureLoaded();
    _snippets.remove(id);
    await _persist();
  }

  /// Swaps the entire contents of the store for [snippets], in one write.
  /// Mirrors [HostStore.replaceAll] — see there for why the backup importer
  /// needs this rather than a loop of [add]/[delete].
  Future<void> replaceAll(Iterable<Snippet> snippets) async {
    await ensureLoaded();
    _snippets
      ..clear()
      ..addEntries([for (final s in snippets) MapEntry(s.id, s)]);
    await _persist();
  }
}
