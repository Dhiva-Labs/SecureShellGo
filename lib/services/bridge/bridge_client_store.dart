import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../app_data_paths.dart';
import '../atomic_file.dart';

/// One AI assistant the user has paired with the AI Bridge.
///
/// Holds only the SHA-256 of its token, never the token: the token is shown
/// to the user once when it is created, and a copy of `bridge_clients.json`
/// is not enough to connect as the assistant.
class BridgeClient {
  const BridgeClient({
    required this.id,
    required this.name,
    required this.tokenHash,
    required this.createdAt,
    this.lastSeenAt,
    this.pending = false,
  });

  final String id;

  /// What the user called it, e.g. "Desktop assistant".
  final String name;

  /// Lower-case hex SHA-256 of the token.
  final String tokenHash;

  final DateTime createdAt;

  /// When this client last connected successfully, or null if never.
  /// Informational only: nothing decides anything from it.
  final DateTime? lastSeenAt;

  /// Made by a setup that has not finished yet ("Connect Claude Code"). A
  /// pending pairing never signs in, and one still pending when the app next
  /// starts is removed: a setup cut short by the app closing leaves nothing
  /// behind. Cleared by [BridgeClientStore.confirm].
  final bool pending;

  BridgeClient withLastSeen(DateTime at) => BridgeClient(
    id: id,
    name: name,
    tokenHash: tokenHash,
    createdAt: createdAt,
    lastSeenAt: at,
    pending: pending,
  );

  BridgeClient _confirmed() => BridgeClient(
    id: id,
    name: name,
    tokenHash: tokenHash,
    createdAt: createdAt,
    lastSeenAt: lastSeenAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'tokenHash': tokenHash,
    'createdAt': createdAt.toUtc().toIso8601String(),
    if (lastSeenAt != null) 'lastSeenAt': lastSeenAt!.toUtc().toIso8601String(),
    if (pending) 'pending': true,
  };

  /// Throws on a row without an id, name, hash or readable creation time;
  /// [BridgeClientStore] skips such a row rather than losing the file.
  factory BridgeClient.fromJson(Map<String, dynamic> json) {
    final created = DateTime.parse(json['createdAt'] as String);
    return BridgeClient(
      id: json['id'] as String,
      name: json['name'] as String,
      tokenHash: json['tokenHash'] as String,
      createdAt: created,
      lastSeenAt: switch (json['lastSeenAt']) {
        final String iso => DateTime.tryParse(iso),
        _ => null,
      },
      // Absent (every file before this field) is not pending.
      pending: json['pending'] == true,
    );
  }
}

/// The paired assistants, in `bridge_clients.json` beside `hosts.json`.
///
/// Same shape as [HostStore]: plain JSON, atomic writes, saves in order. It
/// stays out of backups on purpose (see `BackupPayload`): a token only means
/// something to the install that issued it.
class BridgeClientStore {
  /// [file] overrides the on-disk location; tests use it so they do not need
  /// the path_provider plugin. [random] and [now] are test seams.
  BridgeClientStore({File? file, Random? random, DateTime Function()? now})
    // ignore: prefer_initializing_formals
    : _file = file,
      _random = random ?? Random.secure(),
      _now = now ?? DateTime.now;

  static const String fileName = 'bridge_clients.json';

  /// 32 random bytes: 256 bits, beyond guessing.
  static const int tokenBytes = 32;

  File? _file;
  final Random _random;
  final DateTime Function() _now;

  final SerialFileWriter _writer = SerialFileWriter();
  final Map<String, BridgeClient> _clients = {};

  /// When each client's `lastSeenAt` last reached the disk, so a busy
  /// assistant reconnecting does not rewrite the file on every connection.
  final Map<String, DateTime> _lastPersistedSeen = {};

  /// Pairings whose [confirm] is still being written. None of them signs in
  /// yet: a confirmation that then fails to save is undone, and a token that
  /// had worked in between would have been a pairing the file never held.
  final Set<String> _confirming = {};

  static const Duration seenWriteInterval = Duration(minutes: 1);
  final _changes = StreamController<List<BridgeClient>>.broadcast();

  Future<void>? _loading;
  bool _loaded = false;

  /// Fires with the full list after every create, revoke and sign-in stamp.
  Stream<List<BridgeClient>> get changes => _changes.stream;

  Future<void> _ensureLoaded() {
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
          if (decoded is! Map<String, dynamic>) {
            throw const FormatException('not an object');
          }
          final clients = decoded['clients'];
          if (clients is List) {
            for (final entry in clients) {
              if (entry is Map<String, dynamic>) {
                try {
                  final client = BridgeClient.fromJson(entry);
                  _clients[client.id] = client;
                  final seen = client.lastSeenAt;
                  if (seen != null) _lastPersistedSeen[client.id] = seen;
                } catch (_) {
                  // Skip one malformed row rather than losing the file.
                }
              }
            }
          }
        }
      }
    } catch (_) {
      // Unreadable file: start with nobody paired. Failing closed is the
      // safe side here, since an assistant must be paired again, not guessed
      // at. The bytes are kept aside for recovery by hand.
      _clients.clear();
      await setAsideUnreadable(_file);
    } finally {
      _loaded = true;
    }
    // A pairing still pending at start belongs to a setup that never
    // finished (the app closed part way): nobody holds its token, so it goes.
    final abandoned = [
      for (final c in _clients.values)
        if (c.pending) c.id,
    ];
    if (abandoned.isNotEmpty) {
      for (final id in abandoned) {
        _clients.remove(id);
        _lastPersistedSeen.remove(id);
      }
      try {
        await _persist();
      } catch (_) {
        // Still gone from memory, and refused by [verify] in any case; the
        // next start tries again.
      }
    }
  }

  Future<void> _persist() => _writer.run(_writeNow);

  Future<void> _writeNow() async {
    final file = await _resolveFile();
    final payload = <String, dynamic>{
      'version': 1,
      'clients': [for (final c in _clients.values) c.toJson()],
    };
    await file.parent.create(recursive: true);
    await atomicWrite(file, (temp) async {
      await temp.writeAsString(jsonEncode(payload), flush: true);
      // The file holds only hashes, but there is no reason for other
      // accounts to read it. Best effort: not available on Windows.
      if (!Platform.isWindows) {
        try {
          await Process.run('chmod', ['600', temp.path]);
        } catch (_) {}
      }
    });
  }

  void _notify() {
    if (!_changes.isClosed) {
      _changes.add(List.unmodifiable(_clients.values));
    }
  }

  /// All paired assistants, oldest first.
  Future<List<BridgeClient>> load() async {
    await _ensureLoaded();
    return List.unmodifiable(_clients.values);
  }

  /// Pairs a new assistant called [name]. The returned `token` is the only
  /// copy there will ever be: only its hash is stored.
  ///
  /// With [pending], the pairing cannot sign in until [confirm] is called,
  /// and is removed at the next start if it never is.
  ///
  /// When the file cannot be written, nothing is kept (in memory either)
  /// and the error is rethrown: the running bridge, the screens and the file
  /// never disagree about who is paired.
  Future<({BridgeClient client, String token})> create(
    String name, {
    bool pending = false,
  }) async {
    await _ensureLoaded();
    final token = base64UrlEncode([
      for (var i = 0; i < tokenBytes; i++) _random.nextInt(256),
    ]).replaceAll('=', '');
    final client = BridgeClient(
      id: _newId(),
      name: name.trim().isEmpty ? 'AI assistant' : name.trim(),
      tokenHash: hashToken(token),
      createdAt: _now(),
      pending: pending,
    );
    _clients[client.id] = client;
    try {
      await _persist();
    } catch (_) {
      if (identical(_clients[client.id], client)) _clients.remove(client.id);
      rethrow;
    }
    _notify();
    return (client: client, token: token);
  }

  /// Makes a [BridgeClient.pending] pairing usable. A no-op when it is not
  /// pending or is gone. Rolled back and rethrown when the file cannot be
  /// written, so a pairing never works now and vanishes at the next start.
  Future<void> confirm(String id) async {
    await _ensureLoaded();
    final current = _clients[id];
    if (current == null || !current.pending) return;
    final confirmed = current._confirmed();
    _clients[id] = confirmed;
    _confirming.add(id);
    try {
      await _persist();
    } catch (_) {
      if (identical(_clients[id], confirmed)) _clients[id] = current;
      rethrow;
    } finally {
      _confirming.remove(id);
    }
    _notify();
  }

  /// The client [token] belongs to, stamped as seen now, or null.
  ///
  /// Every stored hash is compared, without stopping at the first match, so
  /// the time taken does not say which client (or whether any) matched.
  Future<BridgeClient?> verify(String token) async {
    await _ensureLoaded();
    final presented = hashToken(token);
    BridgeClient? match;
    for (final client in _clients.values) {
      if (_constantTimeEquals(client.tokenHash, presented)) match = client;
    }
    // A setup that has not finished does not sign anybody in.
    if (match == null || match.pending || _confirming.contains(match.id)) {
      return null;
    }
    final now = _now();
    final seen = match.withLastSeen(now);
    _clients[seen.id] = seen;
    // The in-memory value is always current; the disk copy is informational
    // only, so it is refreshed at most once a minute per client.
    final written = _lastPersistedSeen[seen.id];
    if (written == null || now.difference(written) >= seenWriteInterval) {
      _lastPersistedSeen[seen.id] = now;
      await _persist();
    }
    _notify();
    return seen;
  }

  /// Removes a paired assistant; its token stops working at once. A no-op if
  /// it is already gone.
  ///
  /// When the file cannot be written the pairing is put back, in memory as
  /// on disk, and the error rethrown: a removal that held only until the
  /// next start would bring the pairing back silently, which is worse than
  /// saying it is still there.
  Future<void> revoke(String id) async {
    await _ensureLoaded();
    final order = _clients.keys.toList();
    final removed = _clients.remove(id);
    if (removed == null) return;
    final seen = _lastPersistedSeen.remove(id);
    try {
      await _persist();
    } catch (_) {
      if (!_clients.containsKey(id)) {
        // Back in its place, so the list keeps its order.
        final rest = Map.of(_clients);
        _clients.clear();
        for (final key in order) {
          if (key == id) {
            _clients[id] = removed;
          } else if (rest.containsKey(key)) {
            _clients[key] = rest.remove(key)!;
          }
        }
        _clients.addAll(rest);
        if (seen != null) _lastPersistedSeen[id] = seen;
      }
      rethrow;
    }
    _notify();
  }

  /// Lower-case hex SHA-256 of [token]'s UTF-8 bytes.
  static String hashToken(String token) =>
      sha256.convert(utf8.encode(token)).toString();

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  String _newId() {
    final micros = _now().microsecondsSinceEpoch.toRadixString(36);
    final salt = _random.nextInt(1 << 32).toRadixString(36);
    return '$micros-$salt';
  }
}
