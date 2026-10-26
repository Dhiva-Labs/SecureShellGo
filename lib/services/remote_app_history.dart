import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'app_data_paths.dart';
import 'atomic_file.dart';

/// The commands "Open an app in a window" was last used with, per host.
///
/// What a server has installed differs from one host to the next, so each
/// host keeps a list of its own, keyed by [Host.id]: a command that opens
/// `gedit` on the laptop is noise in the list for the headless box. A plain
/// JSON file in the app's private data directory ([AppDataPaths]), written the
/// way [BookmarkStore] writes its own.
///
/// Only a convenience. Nothing here may stop an app from starting, so a save
/// that fails is dropped after the in-memory list has been updated, and a file
/// that cannot be read is set aside and starts the list empty.
class RemoteAppHistory {
  /// [file] overrides the on-disk location; tests use it so they do not need
  /// the path_provider plugin.
  // ignore: prefer_initializing_formals
  RemoteAppHistory({File? file}) : _file = file;

  static const String fileName = 'remote_app_history.json';

  /// How many commands are kept for each host.
  static const int maxPerHost = 10;

  /// The longest command that is kept. Past this it is a pasted script rather
  /// than something to run again from a chip, and the file stays small.
  static const int maxCommandLength = 2000;

  /// Shared instance for callers that have no store threaded down to them —
  /// the launcher is opened from the session screen, which owns none. Every
  /// real instance resolves to the same file (see
  /// [AppDataPaths.resolveDirectory]), so this only keeps two in-memory copies
  /// from drifting apart inside one process.
  static final RemoteAppHistory instance = RemoteAppHistory();

  File? _file;

  /// Saves land one at a time, in order — see [SerialFileWriter].
  final SerialFileWriter _writer = SerialFileWriter();

  /// Newest first, by host id.
  final Map<String, List<String>> _byHost = {};

  Future<void>? _loading;
  bool _loaded = false;

  /// Loads the file once; concurrent callers share one future.
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
          final hosts = decoded is Map<String, dynamic> ? decoded['hosts'] : null;
          if (hosts is Map<String, dynamic>) {
            for (final MapEntry(key: hostId, value: commands) in hosts.entries) {
              if (commands is! List) continue;
              // Re-run through the same rules a new command meets, so a
              // hand-edited file cannot hold more than the cap, or twice.
              final kept = <String>[];
              for (final command in commands) {
                final text = command is String ? _clean(command) : null;
                if (text != null && !kept.contains(text)) kept.add(text);
              }
              if (kept.isNotEmpty) {
                _byHost[hostId] = kept.take(maxPerHost).toList();
              }
            }
          }
        }
      }
    } catch (_) {
      // An unreadable file must not stop the launcher opening: start empty,
      // and keep the bytes for someone to look at (see HostStore for the
      // same reasoning).
      _byHost.clear();
      await setAsideUnreadable(_file);
    } finally {
      _loaded = true;
    }
  }

  /// [command] as it is kept — surrounding whitespace gone — or null when it
  /// is not worth keeping: empty, or longer than [maxCommandLength].
  static String? _clean(String command) {
    final text = command.trim();
    if (text.isEmpty || text.length > maxCommandLength) return null;
    return text;
  }

  /// [hostId]'s commands, the one used last first. At most [maxPerHost].
  Future<List<String>> recent(String hostId) async {
    await ensureLoaded();
    return List.unmodifiable(_byHost[hostId] ?? const <String>[]);
  }

  /// Puts [command] at the front of [hostId]'s list. One already there moves
  /// up rather than appearing twice; the oldest falls off past [maxPerHost].
  Future<void> record(String hostId, String command) async {
    final text = _clean(command);
    if (text == null) return;
    await ensureLoaded();
    final list = _byHost.putIfAbsent(hostId, () => []);
    list
      ..remove(text)
      ..insert(0, text);
    if (list.length > maxPerHost) list.removeRange(maxPerHost, list.length);
    await _persist();
  }

  /// Forgets one command on [hostId]. A no-op when it is not there.
  Future<void> remove(String hostId, String command) async {
    await ensureLoaded();
    final list = _byHost[hostId];
    if (list == null || !list.remove(command.trim())) return;
    if (list.isEmpty) _byHost.remove(hostId);
    await _persist();
  }

  Future<void> _persist() async {
    try {
      await _writer.run(_writeNow);
    } catch (_) {
      // See the class comment: the list in memory is already right, and the
      // next save writes all of it.
    }
  }

  Future<void> _writeNow() async {
    final file = await _resolveFile();
    final payload = <String, dynamic>{
      'version': 1,
      'hosts': {
        for (final MapEntry(key: hostId, value: commands) in _byHost.entries)
          hostId: commands,
      },
    };
    await file.parent.create(recursive: true);
    await atomicWrite(
      file,
      (temp) => temp.writeAsString(jsonEncode(payload), flush: true),
    );
  }
}
