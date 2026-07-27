import 'dart:convert';

import '../models/host.dart';
import 'secure_storage_backend.dart';

export 'secure_storage_backend.dart'
    show SecureStorageBackend, FlutterSecureStorageBackend;

/// Saves and loads [SshCredentials] for a saved host, keyed by [Host.id].
///
/// Secrets never touch [HostStore]'s plain JSON file — `Host` is
/// deliberately secret-free (see `models/host.dart`) and this is the only
/// place a password, private key or passphrase is written to disk. Each host
/// gets exactly one secure-storage entry, holding whichever of the three
/// fields the user chose to save, as a small JSON blob.
class CredentialStore {
  CredentialStore({SecureStorageBackend? backend})
      : _backend = backend ?? FlutterSecureStorageBackend();

  final SecureStorageBackend _backend;

  static String _keyFor(String hostId) => 'credentials:$hostId';

  /// Saves [credentials] for [hostId], replacing whatever was there. Only
  /// non-null fields are written, so saving a password-auth host never
  /// leaves a stale key/passphrase pair behind and vice versa.
  Future<void> save(String hostId, SshCredentials credentials) async {
    final payload = <String, dynamic>{
      if (credentials.password != null) 'password': credentials.password,
      if (credentials.privateKeyPem != null)
        'privateKeyPem': credentials.privateKeyPem,
      if (credentials.passphrase != null)
        'passphrase': credentials.passphrase,
    };
    await _backend.write(_keyFor(hostId), jsonEncode(payload));
  }

  /// The saved credentials for [hostId], or null if nothing was ever saved
  /// (or the entry could not be read/decoded — fails closed like the other
  /// stores: the caller ends up asking the user to re-enter, not connecting
  /// with something unexpected).
  Future<SshCredentials?> load(String hostId) async {
    final raw = await _backend.read(_keyFor(hostId));
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return SshCredentials(
        password: decoded['password'] as String?,
        privateKeyPem: decoded['privateKeyPem'] as String?,
        passphrase: decoded['passphrase'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  /// Whether any credentials are saved for [hostId].
  Future<bool> has(String hostId) async {
    final raw = await _backend.read(_keyFor(hostId));
    return raw != null;
  }

  /// Deletes the saved credentials for [hostId]. A no-op if there were none.
  Future<void> delete(String hostId) => _backend.delete(_keyFor(hostId));
}
