import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// The second file in this app to reach for pointycastle, and only for the
// half `BackupCrypto` cannot do: sealing a payload under a key that is
// already in hand. Everything expensive and everything easy to get wrong —
// Argon2id, its parameters, the salt, the isolate, the authenticated
// header — still happens exactly once, inside `BackupCrypto`, on the wrapped
// key below. See [SecretVault]'s "Why not simply a backup file" note.
import 'package:pointycastle/export.dart';

import 'app_data_paths.dart';
import 'backup_crypto.dart';

/// A passphrase-protected store for secrets, used when the operating system
/// has no keyring to protect them with.
///
/// Every secret lives in one file as a single encrypted blob — a JSON map of
/// key to value — inside the app's private data directory ([AppDataPaths]),
/// never in the user's visible Documents folder. There is still no plaintext
/// fallback anywhere: this is a *different* protection, not a weaker one, and
/// a vault that cannot be unlocked reads as empty rather than as plaintext.
///
/// ## Why not simply a backup file
///
/// The obvious implementation is "call `BackupCrypto.encrypt` on the map".
/// It is wrong here for one reason: `BackupCrypto` derives a key with
/// Argon2id on every call, deliberately, at roughly 0.8 s each. A backup is
/// written once by a user who asked for it; this file is rewritten every
/// time a host is saved and read whenever a session needs a password, and
/// paying 0.8 s per operation would make the app feel broken.
///
/// So the passphrase protects a key rather than the payload directly:
///
///  * A 256-bit vault key comes from [BackupCrypto.randomBytes], i.e. from
///    `Random.secure()`.
///  * That key is wrapped in an ordinary `BackupCrypto` container under the
///    user's passphrase. This is the only Argon2id run, and it happens once
///    per unlock, never per read or write.
///  * The payload is sealed under the unwrapped key with AES-256-GCM and a
///    fresh 96-bit nonce per write, with the whole file prefix as additional
///    authenticated data.
///
/// Nothing about the passphrase, the wrapped key or the derived key is ever
/// logged, and neither the passphrase nor the vault key is ever written to
/// disk in the clear. The vault key is held in memory for the session and
/// dropped by [lock]; the passphrase is not held at all past [unlock].
///
/// ## File format (`secrets.ssgvault`, format version 1)
///
/// All integers big-endian. Offsets in bytes; `n` is [wrappedKeyLength].
///
/// ```text
///     off  len  field
///       0    6  magic            'SSGVLT', ASCII
///       6    2  formatVersion    uint16, currently 1
///       8    4  wrappedKeyLength uint32
///      12    n  wrappedKey       a complete .ssgbackup container over the
///                                32-byte vault key
///    12+n    1  nonceLength      uint8, 12
///    13+n   12  nonce            from Random.secure(), fresh per write
///    25+n    m  payload          AES-256-GCM ciphertext followed by its
///                                128-bit tag
/// ```
///
/// Bytes `0` to `25+n` — everything before the payload — are passed to GCM as
/// additional authenticated data, so swapping in a different wrapped key,
/// editing the version or moving the nonce all fail the tag check. The
/// wrapped key carries its own authenticated header from `BackupCrypto` on
/// top of that.
///
/// ## What this is not
///
/// It is not an OS keyring. A vault file sits in the user's own data
/// directory readable by any process running as that user, and its only
/// protection is the passphrase and Argon2id's cost. A working keyring is
/// better and the composite backend prefers it — see
/// `composite_secure_storage.dart`. This exists so that "no keyring" stops
/// being a dead end, not so that it stops mattering.
class SecretVault {
  /// [file] overrides the on-disk location; tests use it so they do not need
  /// the path_provider plugin. [useIsolate] is passed straight through to
  /// [BackupCrypto] — tests set it false to stay on one thread.
  SecretVault({File? file, bool useIsolate = true})
      // ignore: prefer_initializing_formals
      : _file = file,
        // ignore: prefer_initializing_formals
        _useIsolate = useIsolate;

  static const String fileName = 'secrets.ssgvault';

  /// 'SSGVLT'. Six bytes, like the backup container's, so a truncated or
  /// unrelated file is rejected on sight rather than parsed into nonsense.
  static const List<int> magic = <int>[
    0x53,
    0x53,
    0x47,
    0x56,
    0x4c,
    0x54,
  ];

  static const int formatVersion = 1;

  /// 96 bits: the only nonce size GCM takes without an extra derivation
  /// step. A fresh one is drawn from `Random.secure()` on every write, which
  /// is what makes reusing one vault key across writes safe.
  static const int nonceLength = 12;

  static const int tagLength = 16;

  static const int keyLength = 32;

  final bool _useIsolate;

  File? _file;

  /// The vault key, unwrapped, for this session only. Null when locked.
  Uint8List? _key;

  /// The wrapped key exactly as it sits in the file, kept so a write can
  /// re-seal the payload without re-running Argon2id.
  Uint8List? _wrappedKey;

  /// The decrypted secrets. Null when locked — deliberately distinct from an
  /// empty map, which is a legitimately empty *unlocked* vault.
  Map<String, String>? _secrets;

  int _keyDerivations = 0;

  /// How many times a passphrase has been put through Argon2id by this
  /// instance. Exists for the test that guards the session-key reuse: the
  /// whole design above is pointless if a read or a write quietly re-derives.
  int get keyDerivations => _keyDerivations;

  bool get isUnlocked => _key != null;

  /// Whether a vault file exists on disk. Cheap enough to call on every
  /// backend operation, and the composite backend does.
  Future<bool> exists() async {
    final file = await _resolveFile();
    return file.exists();
  }

  /// Creates a vault protected by [passphrase] and leaves it unlocked.
  ///
  /// Refuses if one already exists: overwriting a vault destroys every
  /// credential in it, and no caller here ever means that.
  Future<void> create(String passphrase) async {
    final file = await _resolveFile();
    if (await file.exists()) {
      throw const SecretVaultStateException(
        'A credential vault already exists on this device.',
      );
    }
    final key = BackupCrypto.randomBytes(keyLength);
    final wrapped = await BackupCrypto.encrypt(
      plaintext: key,
      passphrase: passphrase,
      useIsolate: _useIsolate,
    );
    _keyDerivations++;
    await _persist(
      wrappedKey: wrapped,
      key: key,
      secrets: const <String, String>{},
    );
    _wrappedKey = wrapped;
    _key = key;
    _secrets = <String, String>{};
  }

  /// Opens the vault with [passphrase].
  ///
  /// Throws [SecretVaultAuthException] for a wrong passphrase or a damaged
  /// file, and [SecretVaultFormatException] for something that is not a vault
  /// at all. Nothing here writes: a failed unlock leaves the file byte for
  /// byte as it was, which is the whole reason the wrong-passphrase path is
  /// worth testing.
  Future<void> unlock(String passphrase) async {
    final file = await _resolveFile();
    final Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } on FileSystemException {
      throw const SecretVaultFormatException(
        'There is no credential vault on this device yet.',
      );
    }
    final parsed = _VaultFile.parse(bytes);

    final Uint8List key;
    try {
      key = await BackupCrypto.decrypt(
        file: parsed.wrappedKey,
        passphrase: passphrase,
        useIsolate: _useIsolate,
      );
    } on BackupAuthException {
      throw const SecretVaultAuthException();
    } on BackupFormatException catch (e) {
      throw SecretVaultFormatException(e.message);
    } finally {
      // Counted even on failure: a wrong passphrase costs a derivation too,
      // and a counter that only saw the successes would not be measuring the
      // thing it exists to measure.
      _keyDerivations++;
    }
    if (key.length != keyLength) {
      throw const SecretVaultFormatException(
        'This credential vault is damaged.',
      );
    }

    final plaintext = _open(parsed, key);
    final secrets = _decodeSecrets(plaintext);
    _wrappedKey = parsed.wrappedKey;
    _key = key;
    _secrets = secrets;
  }

  /// Drops the session key and the decrypted secrets.
  ///
  /// The key bytes are overwritten before the reference goes, which is worth
  /// doing and worth being honest about: it clears this buffer, and it cannot
  /// promise anything about copies the VM's garbage collector may have made
  /// along the way. Dart offers no stronger guarantee than that.
  void lock() {
    _key?.fillRange(0, _key!.length, 0);
    _key = null;
    _wrappedKey = null;
    _secrets = null;
  }

  Future<String?> read(String key) async {
    final secrets = _secrets;
    if (secrets == null) throw const SecretVaultLockedException();
    return secrets[key];
  }

  /// Writes [key] and re-seals the whole vault.
  ///
  /// The in-memory map is replaced only once the new file is on disk, so a
  /// failed write leaves memory and disk agreeing on the previous contents
  /// rather than drifting apart.
  Future<void> write(String key, String value) async {
    final current = _secrets;
    final vaultKey = _key;
    final wrapped = _wrappedKey;
    if (current == null || vaultKey == null || wrapped == null) {
      throw const SecretVaultLockedException();
    }
    final next = Map<String, String>.from(current)..[key] = value;
    await _persist(wrappedKey: wrapped, key: vaultKey, secrets: next);
    _secrets = next;
  }

  Future<void> delete(String key) async {
    final current = _secrets;
    final vaultKey = _key;
    final wrapped = _wrappedKey;
    if (current == null || vaultKey == null || wrapped == null) {
      throw const SecretVaultLockedException();
    }
    if (!current.containsKey(key)) return;
    final next = Map<String, String>.from(current)..remove(key);
    await _persist(wrappedKey: wrapped, key: vaultKey, secrets: next);
    _secrets = next;
  }

  Future<File> _resolveFile() async {
    final existing = _file;
    if (existing != null) return existing;
    final dir = await AppDataPaths.resolveDirectory();
    return _file = File('${dir.path}/$fileName');
  }

  /// Seals [secrets] and puts the result in place atomically: written to a
  /// temp file beside the vault, flushed, then renamed over it. A crash or a
  /// full disk halfway through therefore loses the *new* write, not every
  /// credential the user ever saved — the failure mode that matters, because
  /// there is no second copy of this file anywhere.
  Future<void> _persist({
    required Uint8List wrappedKey,
    required Uint8List key,
    required Map<String, String> secrets,
  }) async {
    final file = await _resolveFile();
    final bytes = _seal(wrappedKey: wrappedKey, key: key, secrets: secrets);
    final temp = File('${file.path}.tmp');
    try {
      await temp.writeAsBytes(bytes, flush: true);
    } catch (_) {
      // The rename never happened, so the vault on disk is untouched. Clear
      // the debris if we can and let the caller see the failure.
      try {
        if (await temp.exists()) await temp.delete();
      } catch (_) {
        // Nothing further to try; the vault itself is what matters.
      }
      rethrow;
    }
    await temp.rename(file.path);
  }

  Uint8List _seal({
    required Uint8List wrappedKey,
    required Uint8List key,
    required Map<String, String> secrets,
  }) {
    final nonce = BackupCrypto.randomBytes(nonceLength);
    final prefix = _encodePrefix(wrappedKey: wrappedKey, nonce: nonce);
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        true,
        AEADParameters(KeyParameter(key), tagLength * 8, nonce, prefix),
      );
    final body = cipher.process(
      Uint8List.fromList(utf8.encode(jsonEncode(secrets))),
    );
    final out = BytesBuilder(copy: false)
      ..add(prefix)
      ..add(body);
    return out.toBytes();
  }

  static Uint8List _encodePrefix({
    required Uint8List wrappedKey,
    required Uint8List nonce,
  }) {
    final bytes = Uint8List(12 + wrappedKey.length + 1 + nonceLength);
    final view = ByteData.view(bytes.buffer);
    bytes.setRange(0, 6, magic);
    view.setUint16(6, formatVersion);
    view.setUint32(8, wrappedKey.length);
    bytes.setRange(12, 12 + wrappedKey.length, wrappedKey);
    bytes[12 + wrappedKey.length] = nonceLength;
    bytes.setRange(
      13 + wrappedKey.length,
      13 + wrappedKey.length + nonceLength,
      nonce,
    );
    return bytes;
  }

  static Uint8List _open(_VaultFile parsed, Uint8List key) {
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        false,
        AEADParameters(
          KeyParameter(key),
          tagLength * 8,
          parsed.nonce,
          parsed.prefix,
        ),
      );
    try {
      return cipher.process(parsed.payload);
    } on InvalidCipherTextException {
      throw const SecretVaultAuthException();
    } on ArgumentError {
      // A length GCM rejects before it reaches the tag. Same outcome, and
      // nothing has been decrypted either way.
      throw const SecretVaultAuthException();
    }
  }

  static Map<String, String> _decodeSecrets(Uint8List plaintext) {
    try {
      final decoded = jsonDecode(utf8.decode(plaintext));
      if (decoded is! Map) {
        throw const SecretVaultFormatException(
          'This credential vault is damaged.',
        );
      }
      return <String, String>{
        for (final entry in decoded.entries)
          if (entry.key is String && entry.value is String)
            entry.key as String: entry.value as String,
      };
    } on FormatException {
      // The tag already verified, so this is not tampering — it is a vault
      // written by something that got the payload shape wrong. Refuse it
      // rather than silently starting from an empty map, which would look
      // exactly like "all your credentials are gone" on the next write.
      throw const SecretVaultFormatException(
        'This credential vault is damaged.',
      );
    }
  }
}

/// The framing of a vault file, parsed before anything in it is believed.
///
/// Every length is range-checked here rather than trusted: at this point the
/// GCM tag has authenticated nothing, so the bytes are still whatever was on
/// disk, and a length taken on faith is how a parser turns into a crash.
class _VaultFile {
  const _VaultFile({
    required this.prefix,
    required this.wrappedKey,
    required this.nonce,
    required this.payload,
  });

  /// Everything before the payload, verbatim — the GCM additional
  /// authenticated data.
  final Uint8List prefix;
  final Uint8List wrappedKey;
  final Uint8List nonce;
  final Uint8List payload;

  static _VaultFile parse(Uint8List file) {
    const damaged = SecretVaultFormatException(
      'This credential vault is damaged, or it is not a vault file.',
    );
    if (file.length < 12) throw damaged;
    for (var i = 0; i < SecretVault.magic.length; i++) {
      if (file[i] != SecretVault.magic[i]) throw damaged;
    }
    final view = ByteData.sublistView(file);
    final version = view.getUint16(6);
    if (version > SecretVault.formatVersion) {
      throw SecretVaultFormatException(
        'This credential vault was written by a newer version of '
        'SecureShell Go (format $version). Update the app and try again.',
      );
    }
    final wrappedLength = view.getUint32(8);
    // An absurd declared length must not become an allocation. The wrapped
    // key is a fixed-size backup container; anything far off that is junk.
    if (wrappedLength > 4096 || file.length < 12 + wrappedLength + 1) {
      throw damaged;
    }
    final wrappedKey = file.sublist(12, 12 + wrappedLength);
    final nonceStart = 13 + wrappedLength;
    if (file[12 + wrappedLength] != SecretVault.nonceLength) throw damaged;
    // The payload may legitimately be an empty map's worth of ciphertext,
    // but the tag is never absent.
    if (file.length <
        nonceStart + SecretVault.nonceLength + SecretVault.tagLength) {
      throw damaged;
    }
    final payloadStart = nonceStart + SecretVault.nonceLength;
    return _VaultFile(
      prefix: file.sublist(0, payloadStart),
      wrappedKey: wrappedKey,
      nonce: file.sublist(nonceStart, payloadStart),
      payload: file.sublist(payloadStart),
    );
  }
}

/// Base for the ways the vault can refuse.
sealed class SecretVaultException implements Exception {
  const SecretVaultException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The passphrase did not open the vault. Which of the two reasons it was is
/// not knowable — GCM cannot tell a wrong key from an altered file — and the
/// message deliberately does not pretend otherwise.
class SecretVaultAuthException extends SecretVaultException {
  const SecretVaultAuthException()
      : super('Wrong passphrase, or the vault is damaged.');
}

/// The file is not a vault this build can read: wrong magic, truncated, a
/// newer format version, or a payload that is not the expected shape.
class SecretVaultFormatException extends SecretVaultException {
  const SecretVaultFormatException(super.message);
}

/// An operation that needs the vault open was attempted while it was sealed.
class SecretVaultLockedException extends SecretVaultException {
  const SecretVaultLockedException()
      : super('The credential vault is locked.');
}

/// A refusal that is neither: creating a vault over one that already exists.
class SecretVaultStateException extends SecretVaultException {
  const SecretVaultStateException(super.message);
}
