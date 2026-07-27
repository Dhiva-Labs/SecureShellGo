import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Thin seam over the secure-storage backend.
///
/// Everything that needs the Keystore talks to this instead of
/// `FlutterSecureStorage` directly, so tests can substitute an in-memory fake
/// instead of the real Keystore-backed plugin (which needs a platform channel
/// and does not run under plain `flutter test`) — the same reason
/// `KnownHostsService` and `HostStore` take an injectable `File` instead of
/// resolving one themselves.
abstract class SecureStorageBackend {
  Future<void> write(String key, String value);
  Future<String?> read(String key);
  Future<void> delete(String key);
}

/// Production backend: Android Keystore via EncryptedSharedPreferences.
class FlutterSecureStorageBackend implements SecureStorageBackend {
  FlutterSecureStorageBackend() : _storage = const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}
