import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// The second file in this app to reach for pointycastle, and only for the
// half `BackupCrypto` cannot do: sealing a payload under a key that is
// already in hand. Everything expensive and everything easy to get wrong —
// Argon2id, its parameters, the salt, the isolate, the authenticated
// header — still happens inside `BackupCrypto`, on the wrapped key below.
import 'package:pointycastle/export.dart';

import 'app_data_paths.dart';
import 'atomic_file.dart';
import 'backup_crypto.dart';

/// An encrypted store for secrets, used when the operating system has no
/// keyring to protect them with.
///
/// Every secret lives in one file as a single encrypted blob — a JSON map of
/// key to value — inside the app's private data directory ([AppDataPaths]),
/// never in the user's visible Documents folder. There is no plaintext
/// fallback anywhere: this is a *different* protection, not a weaker one, and
/// a vault that cannot be unlocked reads as empty rather than as plaintext.
///
/// ## The two ways the payload key is held
///
/// The payload is always sealed the same way — AES-256-GCM under a 256-bit
/// vault key, fresh 96-bit nonce per write, whole file prefix as additional
/// authenticated data. Only how that key is *kept* differs, and the file says
/// which in its own header:
///
///  * **Mode 1, a device key.** The key is the 32 bytes in
///    `device_vault.key` (see `device_vault_key.dart`), used directly. This
///    is what the app writes. There is deliberately no key derivation here:
///    a memory-hard KDF protects low-entropy human input, and there is none —
///    stretching `Random.secure()` output buys nothing and would cost ~0.8 s
///    on first save and once per app start, on exactly the installs that have
///    no keyring.
///  * **Mode 0, a passphrase.** The vault key is wrapped in an ordinary
///    `BackupCrypto` container under a passphrase the user types, so Argon2id
///    runs once per unlock and never per read or write. 1.4.1 wrote these and
///    nothing writes them now; [unlock] exists so those vaults keep opening.
///
/// Nothing about the passphrase, the wrapped key or the vault key is ever
/// logged, and none of them is ever written to disk in the clear. The vault
/// key is held in memory for the session and dropped by [lock].
///
/// ## File format (`secrets.ssgvault`, format version 2)
///
/// All integers big-endian. Offsets in bytes; `n` is the wrapped key's
/// length, which is 0 in mode 1.
///
/// ```text
///     off  len  field
///       0    6  magic            'SSGVLT', ASCII
///       6    2  formatVersion    uint16, currently 2
///       8    1  keyWrapMode      uint8, 0 = passphrase, 1 = device key
///       9    4  wrappedKeyLength uint32, 0 in mode 1
///      13    n  wrappedKey       mode 0 only: a complete .ssgbackup
///                                container over the 32-byte vault key
///    13+n    1  nonceLength      uint8, 12
///    14+n   12  nonce            from Random.secure(), fresh per write
///    26+n    m  payload          AES-256-GCM ciphertext followed by its
///                                128-bit tag
/// ```
///
/// Bytes `0` to `26+n` — everything before the payload, the wrap-mode byte
/// included — are passed to GCM as additional authenticated data, so
/// swapping in a different wrapped key, claiming a different mode, editing
/// the version or moving the nonce all fail the tag check.
///
/// Format version 1 is still accepted and read as mode 0: it had no wrap-mode
/// byte, so its length field and everything after it sit one byte earlier.
///
/// ## What this is not
///
/// It is not an OS keyring. A vault file sits in the user's own data
/// directory readable by any process running as that user, and in mode 1 so
/// does the key that opens it. A working keyring is better and the composite
/// backend prefers it — see `composite_secure_storage.dart`. This exists so
/// that "no keyring" stops being a dead end, not so that it stops mattering.
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

  static const int formatVersion = 2;

  /// The vault key is wrapped in a `BackupCrypto` container under a typed
  /// passphrase. Written by 1.4.1; still read, never written.
  static const int wrapModePassphrase = 0;

  /// The vault key *is* the device key file's contents. No wrapped key, and
  /// no key derivation.
  static const int wrapModeDeviceKey = 1;

  /// 96 bits: the only nonce size GCM takes without an extra derivation
  /// step. A fresh one is drawn from `Random.secure()` on every write, which
  /// is what makes reusing one vault key across writes safe.
  static const int nonceLength = 12;

  static const int tagLength = 16;

  static const int keyLength = 32;

  static final Uint8List _noWrappedKey = Uint8List(0);

  final bool _useIsolate;

  File? _file;

  /// Cached once true. A vault is never deleted by anything in this app, so
  /// "it exists" cannot become false — and [resolve] on the composite backend
  /// asks on every single read, write and delete.
  bool _exists = false;

  /// The vault key, for this session only. Null when locked.
  Uint8List? _key;

  /// How the file on disk holds [_key], so a write re-seals it the same way.
  int? _wrapMode;

  /// The wrapped key exactly as it sits in the file, kept so a write can
  /// re-seal the payload without re-running Argon2id. Empty in mode 1.
  Uint8List? _wrappedKey;

  /// The decrypted secrets. Null when locked — deliberately distinct from an
  /// empty map, which is a legitimately empty *unlocked* vault.
  Map<String, String>? _secrets;

  int _keyDerivations = 0;

  /// How many times a passphrase has been put through Argon2id by this
  /// instance. Exists for two tests: that a passphrase vault derives once per
  /// unlock rather than per operation, and that the device path — the only
  /// one the app still writes — never derives at all.
  int get keyDerivations => _keyDerivations;

  bool get isUnlocked => _key != null;

  /// Whether a vault file exists on disk.
  Future<bool> exists() async {
    if (_exists) return true;
    final file = await _resolveFile();
    return _exists = await file.exists();
  }

  /// Whether the vault on disk is sealed with a device key rather than a
  /// passphrase, read straight off the wrap-mode byte without opening
  /// anything. Null when there is no vault, or none this build can parse.
  ///
  /// This is the whole of how the app knows which mode it is in. Nothing
  /// records it anywhere else, on purpose: a file's own header cannot drift
  /// out of step with the file the way a second copy of the fact can.
  Future<bool?> isDeviceWrapped() async {
    try {
      return (await _readFile()).wrapMode == wrapModeDeviceKey;
    } on SecretVaultException {
      return null;
    }
  }

  /// Creates a vault sealed directly under [key] and leaves it unlocked.
  ///
  /// [key] must be [keyLength] bytes with a full 256 bits of entropy in
  /// them; `DeviceVaultKey` is the only thing that produces one.
  ///
  /// Refuses if a vault already exists: overwriting one destroys every
  /// credential in it, and no caller here ever means that.
  Future<void> createWithKey(Uint8List key) async {
    _requireKeyLength(key);
    final file = await _resolveFile();
    if (await file.exists()) {
      throw const SecretVaultStateException(
        'A credential vault already exists on this device.',
      );
    }
    final vaultKey = Uint8List.fromList(key);
    await _persist(
      wrapMode: wrapModeDeviceKey,
      wrappedKey: _noWrappedKey,
      key: vaultKey,
      secrets: const <String, String>{},
    );
    _wrapMode = wrapModeDeviceKey;
    _wrappedKey = _noWrappedKey;
    _key = vaultKey;
    _secrets = <String, String>{};
  }

  /// Opens a device-sealed vault with [key].
  ///
  /// Refuses a passphrase vault outright rather than trying [key] against
  /// it: a device key sitting next to a mode-0 vault is a leftover, and
  /// saying so is more useful than the tag failure it would otherwise become.
  Future<void> unlockWithKey(Uint8List key) async {
    _requireKeyLength(key);
    final parsed = await _readFile();
    if (parsed.wrapMode != wrapModeDeviceKey) {
      throw const SecretVaultAuthException();
    }
    final vaultKey = Uint8List.fromList(key);
    final secrets = _decodeSecrets(_open(parsed, vaultKey));
    _wrapMode = parsed.wrapMode;
    _wrappedKey = parsed.wrappedKey;
    _key = vaultKey;
    _secrets = secrets;
  }

  /// Opens a passphrase vault — in practice, one written by 1.4.1.
  ///
  /// Throws [SecretVaultAuthException] for a wrong passphrase or a damaged
  /// file, and [SecretVaultFormatException] for something that is not a vault
  /// at all. Nothing here writes: a failed unlock leaves the file byte for
  /// byte as it was, which is the whole reason the wrong-passphrase path is
  /// worth testing.
  Future<void> unlock(String passphrase) async {
    final parsed = await _readFile();
    if (parsed.wrapMode != wrapModePassphrase) {
      throw const SecretVaultAuthException();
    }

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

    final secrets = _decodeSecrets(_open(parsed, key));
    _wrapMode = parsed.wrapMode;
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
    _wrapMode = null;
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
    final wrapMode = _wrapMode;
    final wrapped = _wrappedKey;
    if (current == null ||
        vaultKey == null ||
        wrapMode == null ||
        wrapped == null) {
      throw const SecretVaultLockedException();
    }
    final next = Map<String, String>.from(current)..[key] = value;
    await _persist(
      wrapMode: wrapMode,
      wrappedKey: wrapped,
      key: vaultKey,
      secrets: next,
    );
    _secrets = next;
  }

  Future<void> delete(String key) async {
    final current = _secrets;
    final vaultKey = _key;
    final wrapMode = _wrapMode;
    final wrapped = _wrappedKey;
    if (current == null ||
        vaultKey == null ||
        wrapMode == null ||
        wrapped == null) {
      throw const SecretVaultLockedException();
    }
    if (!current.containsKey(key)) return;
    final next = Map<String, String>.from(current)..remove(key);
    await _persist(
      wrapMode: wrapMode,
      wrappedKey: wrapped,
      key: vaultKey,
      secrets: next,
    );
    _secrets = next;
  }

  static void _requireKeyLength(Uint8List key) {
    if (key.length != keyLength) {
      throw const SecretVaultFormatException(
        'A credential vault key must be 32 bytes.',
      );
    }
  }

  Future<File> _resolveFile() async {
    final existing = _file;
    if (existing != null) return existing;
    final dir = await AppDataPaths.resolveDirectory();
    return _file = File('${dir.path}/$fileName');
  }

  Future<_VaultFile> _readFile() async {
    final file = await _resolveFile();
    final Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } on FileSystemException {
      throw const SecretVaultFormatException(
        'There is no credential vault on this device yet.',
      );
    }
    return _VaultFile.parse(bytes);
  }

  /// Seals [secrets] and puts the result in place atomically — see
  /// [atomicWrite] for why a half-finished write must lose the new
  /// credential rather than every old one.
  Future<void> _persist({
    required int wrapMode,
    required Uint8List wrappedKey,
    required Uint8List key,
    required Map<String, String> secrets,
  }) async {
    final file = await _resolveFile();
    final bytes = _seal(
      wrapMode: wrapMode,
      wrappedKey: wrappedKey,
      key: key,
      secrets: secrets,
    );
    await atomicWrite(file, (temp) => temp.writeAsBytes(bytes, flush: true));
    _exists = true;
  }

  Uint8List _seal({
    required int wrapMode,
    required Uint8List wrappedKey,
    required Uint8List key,
    required Map<String, String> secrets,
  }) {
    final nonce = BackupCrypto.randomBytes(nonceLength);
    final prefix = _encodePrefix(
      wrapMode: wrapMode,
      wrappedKey: wrappedKey,
      nonce: nonce,
    );
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
    required int wrapMode,
    required Uint8List wrappedKey,
    required Uint8List nonce,
  }) {
    final bytes = Uint8List(13 + wrappedKey.length + 1 + nonceLength);
    final view = ByteData.view(bytes.buffer);
    bytes.setRange(0, 6, magic);
    view.setUint16(6, formatVersion);
    bytes[8] = wrapMode;
    view.setUint32(9, wrappedKey.length);
    bytes.setRange(13, 13 + wrappedKey.length, wrappedKey);
    bytes[13 + wrappedKey.length] = nonceLength;
    bytes.setRange(
      14 + wrappedKey.length,
      14 + wrappedKey.length + nonceLength,
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
    required this.wrapMode,
    required this.wrappedKey,
    required this.nonce,
    required this.payload,
  });

  /// Everything before the payload, verbatim — the GCM additional
  /// authenticated data.
  final Uint8List prefix;
  final int wrapMode;
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

    // Format 1 had no wrap-mode byte and only ever wrote the passphrase
    // container, so it reads as mode 0 with every later field one byte
    // earlier. Everything past this point is common to both.
    final int wrapMode;
    final int lengthOffset;
    if (version < 2) {
      wrapMode = SecretVault.wrapModePassphrase;
      lengthOffset = 8;
    } else {
      if (file.length < 13) throw damaged;
      wrapMode = file[8];
      lengthOffset = 9;
    }
    if (wrapMode != SecretVault.wrapModePassphrase &&
        wrapMode != SecretVault.wrapModeDeviceKey) {
      throw damaged;
    }

    final wrappedLength = view.getUint32(lengthOffset);
    final wrappedStart = lengthOffset + 4;
    // An absurd declared length must not become an allocation. The wrapped
    // key is a fixed-size backup container in mode 0 and absent in mode 1;
    // a file claiming otherwise is junk either way.
    final expectedEmpty = wrapMode == SecretVault.wrapModeDeviceKey;
    if (wrappedLength > 4096 ||
        (wrappedLength == 0) != expectedEmpty ||
        file.length < wrappedStart + wrappedLength + 1) {
      throw damaged;
    }
    final wrappedKey = file.sublist(wrappedStart, wrappedStart + wrappedLength);
    final nonceStart = wrappedStart + wrappedLength + 1;
    if (file[wrappedStart + wrappedLength] != SecretVault.nonceLength) {
      throw damaged;
    }
    // The payload may legitimately be an empty map's worth of ciphertext,
    // but the tag is never absent.
    if (file.length <
        nonceStart + SecretVault.nonceLength + SecretVault.tagLength) {
      throw damaged;
    }
    final payloadStart = nonceStart + SecretVault.nonceLength;
    return _VaultFile(
      prefix: file.sublist(0, payloadStart),
      wrapMode: wrapMode,
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

/// The key did not open the vault. Which of the two reasons it was is not
/// knowable — GCM cannot tell a wrong key from an altered file — and the
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
