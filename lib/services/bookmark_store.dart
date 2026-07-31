import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../models/path_bookmark.dart';
import 'app_data_paths.dart';

/// Persistent store of per-host path bookmarks.
///
/// Mirrors [HostStore]'s approach (see `host_store.dart`): a plain JSON file
/// in the app's private data directory ([AppDataPaths]), next to
/// `hosts.json`.
class BookmarkStore {
  /// [file] overrides the on-disk location; tests use it so they do not need
  /// the path_provider plugin.
  // ignore: prefer_initializing_formals
  BookmarkStore({File? file}) : _file = file;

  static const String fileName = 'bookmarks.json';

  /// Shared instance for callers that have no store threaded down to them.
  /// `main.dart` builds `HostStore` and friends once and passes them down
  /// through the widget tree; reaching the file browser pane that way would
  /// mean touching several screens this change is meant to leave alone. Every
  /// real instance resolves to the same on-disk file regardless (see
  /// [AppDataPaths.resolveDirectory]), so this only avoids two in-memory
  /// copies drifting apart within one process — the same reasoning
  /// `SessionForegroundController.instance` uses.
  static final BookmarkStore instance = BookmarkStore();

  File? _file;

  final Map<String, PathBookmark> _bookmarks = {};

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
            final bookmarks = decoded['bookmarks'];
            if (bookmarks is List) {
              for (final entry in bookmarks) {
                if (entry is Map<String, dynamic>) {
                  try {
                    final bookmark = PathBookmark.fromJson(entry);
                    _bookmarks[bookmark.id] = bookmark;
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
      // HostStore for the same reasoning. Starting empty just means the
      // bookmarks sheet looks empty; nothing else depends on this file.
      _bookmarks.clear();
    } finally {
      _loaded = true;
    }
  }

  Future<void> _persist() async {
    final file = await _resolveFile();
    final payload = <String, dynamic>{
      'version': 1,
      'bookmarks': [for (final bookmark in _bookmarks.values) bookmark.toJson()],
    };
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(payload), flush: true);
  }

  String _newId() {
    final millis = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final salt = _random.nextInt(1 << 32).toRadixString(36);
    return '$millis-$salt';
  }

  /// Every bookmark on [hostId], in the order they were added. Other hosts'
  /// bookmarks never appear — the sheet is opened from one session on one
  /// host, and has no business showing another host's saved paths.
  Future<List<PathBookmark>> bookmarksForHost(String hostId) async {
    await ensureLoaded();
    return _bookmarks.values
        .where((b) => b.hostId == hostId)
        .toList(growable: false);
  }

  /// The bookmark for this exact host/path pair, if any.
  Future<PathBookmark?> forPath(String hostId, String path) async {
    await ensureLoaded();
    for (final bookmark in _bookmarks.values) {
      if (bookmark.hostId == hostId && bookmark.path == path) return bookmark;
    }
    return null;
  }

  /// Bookmarks [path] on [hostId]. Returns the existing row unchanged when
  /// that host/path pair is already bookmarked, so the star toggle in the
  /// file browser cannot create a duplicate by being tapped twice.
  Future<PathBookmark> add(
    String hostId,
    String path, {
    String? label,
  }) async {
    await ensureLoaded();
    final existing = await forPath(hostId, path);
    if (existing != null) return existing;
    final bookmark = PathBookmark(
      id: _newId(),
      hostId: hostId,
      path: path,
      label: label,
    );
    _bookmarks[bookmark.id] = bookmark;
    await _persist();
    return bookmark;
  }

  /// Removes a bookmark by id. A no-op if it is already gone.
  Future<void> remove(String id) async {
    await ensureLoaded();
    _bookmarks.remove(id);
    await _persist();
  }

  /// Removes whatever bookmark exists for [hostId] at [path], if any — the
  /// star toggle's "un-star" path, which knows the path on screen but not
  /// the bookmark's id.
  Future<void> removeForPath(String hostId, String path) async {
    await ensureLoaded();
    final existing = await forPath(hostId, path);
    if (existing == null) return;
    _bookmarks.remove(existing.id);
    await _persist();
  }

  /// Renames a bookmark's label. Null or blank clears it, which falls back
  /// to showing the path itself (see [PathBookmark.displayLabel]).
  ///
  /// Built directly rather than through [PathBookmark.copyWith]: that helper
  /// treats a null argument as "leave it alone" (the usual `copyWith`
  /// contract), which is exactly wrong here — clearing the label back to
  /// "no label" is the one thing this method exists to allow.
  Future<void> renameLabel(String id, String? label) async {
    await ensureLoaded();
    final existing = _bookmarks[id];
    if (existing == null) return;
    _bookmarks[id] = PathBookmark(
      id: existing.id,
      hostId: existing.hostId,
      path: existing.path,
      label: label,
    );
    await _persist();
  }
}
