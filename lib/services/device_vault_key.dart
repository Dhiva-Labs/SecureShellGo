import 'dart:io';
import 'dart:typed_data';

import 'app_data_paths.dart';
import 'atomic_file.dart';
import 'backup_crypto.dart';

/// The key that opens a device-encrypted [SecretVault], kept in a file next
/// to the vault that only its owner can read.
///
/// It is 32 bytes from `Random.secure()` and it *is* the vault key — handed
/// to `SecretVault.createWithKey`/`unlockWithKey`, which seal the payload
/// under it directly. There is no passphrase and no key derivation anywhere
/// in this path, deliberately: a memory-hard KDF is what rescues low-entropy
/// human input, and 256 bits of `Random.secure()` is not that.
///
/// ## What it is worth
///
/// Anything running as this user can read this file and therefore the vault.
/// That is a real step down from a keyring, whose contents are sealed under
/// the login password, and it is a large step up from the alternative it
/// replaces — which was refusing to save the credential at all, and leaving
/// the user to type their server password on every connect. It is used only
/// where no keyring is available; a machine that has one keeps it.
///
/// ## Permissions
///
/// The file is created empty, locked to `0600` *before* the key is written
/// into it, and only then renamed into place — so the key is never on disk at
/// the umask's default mode, not even briefly. On POSIX the mode is verified
/// after the fact and creation fails rather than leave a world-readable key
/// lying about. Windows has no mode to set: the per-user application-data
/// directory this lives in is the ACL boundary there, and there is no
/// `chmod` to call.
class DeviceVaultKey {
  /// [file] overrides the on-disk location; tests use it so they do not need
  /// the path_provider plugin.
  // ignore: prefer_initializing_formals
  DeviceVaultKey({File? file}) : _file = file;

  static const String fileName = 'device_vault.key';

  /// 256 bits, the vault key's own size — this is that key, not something
  /// that wraps it.
  static const int keyLength = 32;

  /// `rw-------`. Written as an int because `dart:io` reports [FileStat.mode]
  /// as one and there is nothing to compare it against otherwise.
  static const int ownerOnlyMode = 0x180;

  File? _file;

  /// Generates a new key and writes it, replacing any existing file.
  ///
  /// Replacing is the correct behaviour and not an oversight: this is only
  /// ever called alongside creating a vault, at which point a key left behind
  /// by a vault that no longer exists is stale rather than precious. Nothing
  /// else in the app writes here.
  Future<Uint8List> create() async {
    final file = await _resolveFile();
    await file.parent.create(recursive: true);
    final key = BackupCrypto.randomBytes(keyLength);
    await atomicWrite(file, (temp) async {
      await temp.writeAsBytes(const <int>[], flush: true);
      await _restrictToOwner(temp);
      await temp.writeAsBytes(key, flush: true);
    });
    return key;
  }

  /// The stored key, or null if there is none this process can read.
  ///
  /// Null is the whole of the failure story on purpose. A caller that cannot
  /// get the key leaves the vault sealed and reads come back empty, exactly
  /// as they do for a wrong passphrase — there is no plaintext store to fall
  /// back to and there is not going to be one.
  Future<Uint8List?> read() async {
    try {
      final file = await _resolveFile();
      if (!await file.exists()) return null;
      final key = await file.readAsBytes();
      return key.length == keyLength ? key : null;
    } catch (_) {
      return null;
    }
  }

  Future<File> _resolveFile() async {
    final existing = _file;
    if (existing != null) return existing;
    final dir = await AppDataPaths.resolveDirectory();
    return _file = File('${dir.path}/$fileName');
  }

  /// `chmod 600`, then check it took. `dart:io` has no chmod of its own, so
  /// this shells out — and then verifies, because a chmod that silently did
  /// nothing (a filesystem with no POSIX modes, a sandbox that swallowed it)
  /// must not pass for one that worked.
  static Future<void> _restrictToOwner(File file) async {
    if (Platform.isWindows) return;
    ProcessResult result;
    try {
      result = await Process.run('chmod', <String>['600', file.path]);
    } catch (e) {
      throw DeviceVaultKeyException('Could not restrict access to $file: $e');
    }
    if (result.exitCode != 0) {
      throw DeviceVaultKeyException(
        'Could not restrict access to the credential key file.',
      );
    }
    final mode = file.statSync().mode & 0x1ff;
    if (mode != ownerOnlyMode) {
      throw DeviceVaultKeyException(
        'The credential key file could not be made private to your account.',
      );
    }
  }
}

/// Thrown when a device key cannot be created safely — in practice, when its
/// permissions could not be set. Never thrown for a missing key on read; see
/// [DeviceVaultKey.read].
class DeviceVaultKeyException implements Exception {
  const DeviceVaultKeyException(this.message);

  final String message;

  @override
  String toString() => message;
}
