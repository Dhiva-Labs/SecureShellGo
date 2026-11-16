import '../secure_storage_backend.dart';

/// The controller tokens this phone holds, one per saved host that is the
/// user's computer running SecureShell Go ("Remote approvals").
///
/// In secure storage, keyed by the host's id, beside (not inside) the
/// host's SSH credentials: never in `hosts.json`, never in a backup (a
/// backup carries only what `CredentialStore` holds for a host), and a host
/// counts as "my computer" exactly while a token is saved for it.
class RemoteControllerTokenStore {
  RemoteControllerTokenStore(this._backend);

  final SecureStorageBackend _backend;

  static String _keyFor(String hostId) => 'bridge_controller_token:$hostId';

  /// The longest token accepted; a real one is 43 characters.
  static const int maxTokenChars = 256;

  /// Saves [token] for [hostId], replacing any. Throws [ArgumentError] for
  /// something that cannot be a token (empty, too long, or spanning lines,
  /// which would split the first line the launcher reads).
  Future<void> save(String hostId, String token) async {
    final t = token.trim();
    if (t.isEmpty ||
        t.length > maxTokenChars ||
        t.contains('\n') ||
        t.contains('\r')) {
      throw ArgumentError.value('(hidden)', 'token', 'not a pairing token');
    }
    await _backend.write(_keyFor(hostId), t);
  }

  /// The token for [hostId], or null when none is saved.
  Future<String?> load(String hostId) => _backend.read(_keyFor(hostId));

  /// Whether [hostId] is set up as a computer to control.
  Future<bool> has(String hostId) async => await load(hostId) != null;

  /// Forgets the token (the host is no longer controlled, or was deleted).
  Future<void> delete(String hostId) => _backend.delete(_keyFor(hostId));

  /// [delete] for clean-up after the host itself is gone (deleted, or
  /// dropped by a backup import): never throws. The host is already gone by
  /// then, so a locked or missing secure store must not make that fail; the
  /// token is left behind, unreachable through any host, and nothing else.
  Future<void> deleteQuietly(String hostId) async {
    try {
      await delete(hostId);
    } catch (_) {}
  }
}
