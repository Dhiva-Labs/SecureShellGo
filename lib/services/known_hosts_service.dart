import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/known_host.dart';
import 'known_hosts_integrity.dart';

/// Persistent store of host keys the user has trusted.
///
/// The file lives in the app's documents directory. Fingerprints are public
/// data, not secrets, so confidentiality was never the concern — *integrity*
/// is: anyone who can rewrite this file can silence the MITM warning. Phase 3
/// closes that gap by sealing the file with an HMAC whose key lives in
/// Keystore-backed secure storage (see [KnownHostsIntegrityKey]). A file that
/// does not verify **fails closed**: it loads as empty, so every host reads as
/// unknown and the user is prompted again rather than anything being trusted
/// silently.
///
/// Passing no [integrityKey] leaves the store unauthenticated (plain JSON),
/// which is what the unit tests use.
class KnownHostsService {
  /// [file] overrides the on-disk location; tests use it so they do not need
  /// the path_provider plugin.
  KnownHostsService({File? file, KnownHostsIntegrityKey? integrityKey})
      // _file is reassigned once path_provider resolves it, so it cannot be
      // an initializing formal.
      // ignore: prefer_initializing_formals
      : _file = file,
        // ignore: prefer_initializing_formals
        _integrityKey = integrityKey;

  static const String fileName = 'known_hosts.json';

  File? _file;
  final KnownHostsIntegrityKey? _integrityKey;
  final Map<String, KnownHostKey> _entries = {};
  Future<void>? _loading;
  bool _loaded = false;

  /// Set when the last load rejected an existing file because its MAC did not
  /// verify. The UI can surface this — a silent reset of the trust store is
  /// exactly the event a user deserves to hear about.
  bool _integrityFailed = false;
  bool get integrityFailed => _integrityFailed;

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
    var migrateLegacy = false;
    try {
      final file = await _resolveFile();
      if (await file.exists()) {
        final raw = await file.readAsString();
        if (raw.trim().isNotEmpty) {
          // Ask whether a key already exists *before* obtaining one:
          // `obtain()` mints a key on first use, and a freshly minted key must
          // not make the pre-integrity file it is about to adopt look like a
          // downgrade attack.
          final hadKey = await _integrityKey?.exists() ?? false;
          final key = await _integrityKey?.obtain();
          final check = KnownHostsEnvelope.open(
            raw,
            key: key,
            keyEverEstablished: hadKey,
          );

          if (!check.isTrustworthy) {
            // Fail closed: the file was modified by something that does not
            // hold the device key. Treat the whole store as empty so every
            // host is re-verified by a human instead of trusting a forgery.
            _integrityFailed = true;
            _entries.clear();
            return;
          }

          migrateLegacy = check.verdict == IntegrityVerdict.legacyMigrated;

          final hosts = check.payload?['hosts'];
          if (hosts is Map<String, dynamic>) {
            for (final entry in hosts.entries) {
              final value = entry.value;
              if (value is Map<String, dynamic>) {
                final known = KnownHostKey.fromJson(value);
                _entries[known.id] = known;
              }
            }
          }
        }
      }
    } catch (_) {
      // A corrupt or unreadable store must not brick the app. Starting empty
      // means every host is treated as unknown, so the user is prompted again
      // rather than silently trusting anything.
      _entries.clear();
    } finally {
      _loaded = true;
    }

    if (migrateLegacy) {
      // First run after the upgrade: adopt the pre-integrity file once and
      // immediately re-write it sealed. From here on an unsealed file is a
      // downgrade attempt and fails closed.
      try {
        await _persist();
      } catch (_) {
        // Best effort; the in-memory copy is already correct.
      }
    }
  }

  Future<void> _persist() async {
    final file = await _resolveFile();
    final payload = <String, dynamic>{
      'version': 1,
      'hosts': {
        for (final entry in _entries.entries) entry.key: entry.value.toJson(),
      },
    };
    final key = await _integrityKey?.obtain();
    final document =
        key == null ? jsonEncode(payload) : KnownHostsEnvelope.seal(key, payload);
    await file.parent.create(recursive: true);
    await file.writeAsString(document, flush: true);
  }

  /// The trusted key for this host *and key type*, or null if never trusted.
  Future<KnownHostKey?> lookup(String hostname, int port, String keyType) async {
    await ensureLoaded();
    return _entries[KnownHostKey.entryId(hostname, port, keyType)];
  }

  /// Whether any key at all is trusted for this host (any key type).
  Future<bool> isHostKnown(String hostname, int port) async {
    await ensureLoaded();
    final prefix = '${KnownHostKey.hostId(hostname, port)}|';
    return _entries.keys.any((key) => key.startsWith(prefix));
  }

  /// Records (or replaces) trust for one host key.
  Future<void> trust(KnownHostKey key) async {
    await ensureLoaded();
    _entries[key.id] = key;
    await _persist();
  }

  /// Drops every trusted key for a host. Used by "forget host" in later phases.
  Future<void> forgetHost(String hostname, int port) async {
    await ensureLoaded();
    final prefix = '${KnownHostKey.hostId(hostname, port)}|';
    _entries.removeWhere((key, _) => key.startsWith(prefix));
    await _persist();
  }

  /// All trusted keys, newest first. For a "known hosts" screen later.
  Future<List<KnownHostKey>> all() async {
    await ensureLoaded();
    final list = _entries.values.toList()
      ..sort((a, b) => b.addedAt.compareTo(a.addedAt));
    return list;
  }
}
