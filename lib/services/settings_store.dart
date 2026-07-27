import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/app_settings.dart';

/// Persistent store for user-editable preferences.
///
/// Mirrors [HostStore]: plain JSON in the app's documents directory. There is
/// no secret in [AppSettings] — font size, colour scheme, a couple of
/// toggles — so there is no reason to pay for Keystore-backed storage the
/// way `CredentialStore` and `known_hosts.json` do.
///
/// Unlike `HostStore`, callers such as [TerminalPane] need the current value
/// synchronously (to build a frame) and need to know when it changes (pinch
/// zoom persisting back, or a future settings change while a session is
/// open) — [current] and [changes] cover that without turning this into a
/// `ChangeNotifier`, matching how `SessionController.changes` stays a plain
/// broadcast `Stream` so the service layer has no Flutter import.
class SettingsStore {
  /// [file] overrides the on-disk location; tests use it so they do not need
  /// the path_provider plugin.
  // ignore: prefer_initializing_formals
  SettingsStore({File? file}) : _file = file;

  static const String fileName = 'settings.json';

  File? _file;
  AppSettings _settings = const AppSettings();

  final _changes = StreamController<AppSettings>.broadcast();

  Future<void>? _loading;
  bool _loaded = false;

  /// The most recently loaded or saved settings. Reads as [AppSettings]'s
  /// defaults until [ensureLoaded] completes, same convention as reading
  /// `HostStore.all()` before the store has loaded returns nothing yet.
  AppSettings get current => _settings;

  /// Fires whenever settings change — from this store, or a previous load.
  Stream<AppSettings> get changes => _changes.stream;

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
    final dir = await getApplicationDocumentsDirectory();
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
            _settings = AppSettings.fromJson(decoded);
          }
        }
      }
    } catch (_) {
      // A corrupt settings file just falls back to defaults. Nothing here is
      // a secret or a trust decision, so — unlike KnownHostsService — there
      // is no reason to fail closed and surface a banner over it.
      _settings = const AppSettings();
    } finally {
      _loaded = true;
    }
  }

  Future<void> _persist() async {
    final file = await _resolveFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(_settings.toJson()), flush: true);
  }

  /// Replaces the stored settings and persists them.
  Future<void> save(AppSettings settings) async {
    await ensureLoaded();
    _settings = settings;
    await _persist();
    if (!_changes.isClosed) _changes.add(_settings);
  }

  /// Convenience for a partial update, e.g.
  /// `store.update((s) => s.copyWith(terminalFontSize: 16))`.
  Future<void> update(AppSettings Function(AppSettings current) change) async {
    await ensureLoaded();
    await save(change(_settings));
  }

  void dispose() {
    unawaited(_changes.close());
  }
}
