import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

// The one file in this app that imports pointycastle, and deliberately so:
// everything else talks to `BackupCrypto`, so there is exactly one place to
// audit when a primitive or a parameter changes.
//
import 'package:pointycastle/export.dart';

/// Encryption for `.ssgbackup` files: AES-256-GCM under a key derived from
/// the user's passphrase with Argon2id.
///
/// ## Why these primitives
///
/// Both are taken from pointycastle rather than hand-written. Nothing in this
/// file implements a cipher, a hash or a KDF — it composes vetted ones and
/// owns only the container format. The choices, and what was checked before
/// making them:
///
///  * **Argon2id** (`m` = 64 MiB, `t` = 3, `p` = 1, version 0x13) for the
///    KDF. Memory-hard, so a GPU or ASIC attacker gains far less per pound
///    than against PBKDF2, and it is the KDF OWASP names first. It is
///    genuinely available here — `pointycastle/key_derivators/argon2.dart` —
///    and this project's test suite pins it against the RFC 9106 test vector
///    rather than trusting the package's own tests. The parameters are the
///    OWASP baseline configuration; measured at roughly 0.8 s on a desktop,
///    which is a fair price for an operation the user performs deliberately
///    and rarely.
///  * **AES-256-GCM** with a 96-bit nonce and a 128-bit tag for the cipher.
///    An AEAD, so the tag check *is* the "wrong passphrase" check and there
///    is no separate MAC to get the composition order wrong. The
///    encrypt-then-MAC CBC fallback the brief allows for is not needed:
///    `GCMBlockCipher` is present and verified, so the simpler and stronger
///    construction wins.
///  * **PBKDF2-HMAC-SHA256** is *readable* but never written — see
///    [kdfPbkdf2Sha256]. It exists so a file produced by a build that could
///    not reach Argon2id would still import.
///
/// Every random byte here comes from [Random.secure].
///
/// ## What this is not
///
/// A backup file is protected by its passphrase and nothing else. There is no
/// device binding, no keystore involvement, and no recovery path: forget the
/// passphrase and the file is scrap. That is the intended trade — a backup
/// that only the originating device could read would not be a backup.
///
/// ## File format (`.ssgbackup`, format version 1)
///
/// All integers big-endian. Offsets in bytes.
///
/// ```text
///   off  len  field
///     0    6  magic            'SSGBAK', ASCII
///     6    2  formatVersion    uint16, currently 1
///     8    1  kdfId            uint8, 1 = Argon2id, 2 = PBKDF2-HMAC-SHA256
///     9    4  kdfMemoryKiB     uint32, Argon2 m in KiB (0 for PBKDF2)
///    13    4  kdfIterations    uint32, Argon2 t / PBKDF2 c
///    17    1  kdfLanes         uint8, Argon2 p (0 for PBKDF2)
///    18    1  cipherId         uint8, 1 = AES-256-GCM
///    19    1  saltLength       uint8, 16
///    20   16  salt             from Random.secure()
///    36    1  nonceLength      uint8, 12
///    37   12  nonce            from Random.secure()
///    49    n  ciphertext
///  49+n   16  tag              GCM tag, 128-bit
/// ```
///
/// The header is bytes `0..48` inclusive — [headerLength] of them — and is
/// passed to GCM as additional authenticated data. So flipping a bit anywhere
/// in it (a KDF parameter, the salt, the nonce, the declared version) fails
/// the tag check exactly like flipping a bit in the ciphertext does. Nothing
/// in this container is unauthenticated.
///
/// pointycastle's GCM emits ciphertext and tag as one buffer, which is why
/// the last two rows are written and read together rather than separately.
class BackupCrypto {
  const BackupCrypto._();

  /// Identifies the container before anything else is believed about it.
  /// Six bytes rather than four so a truncated or mistyped file is rejected
  /// on sight instead of being parsed into nonsense.
  static const List<int> magic = <int>[0x53, 0x53, 0x47, 0x42, 0x41, 0x4b];

  /// What [encrypt] writes. [decrypt] refuses anything higher — see
  /// [BackupFormatException.versionTooNew] for why that is a hard refusal
  /// rather than a best-effort parse.
  static const int formatVersion = 1;

  static const int kdfArgon2id = 1;

  /// Readable, never written. Kept so a file from a build that had no
  /// memory-hard KDF available still imports here; [encrypt] always uses
  /// [kdfArgon2id].
  static const int kdfPbkdf2Sha256 = 2;

  static const int cipherAes256Gcm = 1;

  static const int headerLength = 49;

  static const int saltLength = 16;

  /// 96 bits, the only nonce size GCM takes without an extra derivation step,
  /// and the only one this format accepts. A fresh one is drawn per export;
  /// the salt is fresh per export too, so the *key* differs per file as well
  /// and a nonce repeat across two files would still not be a key/nonce
  /// reuse. See the nonce-uniqueness test.
  static const int nonceLength = 12;

  static const int keyLength = 32;

  static const int tagLength = 16;

  /// OWASP's baseline Argon2id configuration: 64 MiB, 3 passes, 1 lane.
  static const int argon2MemoryKiB = 65536;
  static const int argon2Iterations = 3;
  static const int argon2Lanes = 1;

  /// The OWASP 2023 floor, enforced on *read* — a file claiming fewer
  /// iterations than this is refused rather than honoured, so a tampered
  /// header cannot talk this app into a cheap derivation.
  static const int pbkdf2MinIterations = 600000;

  static final Random _random = Random.secure();

  /// Encrypts [plaintext] under [passphrase] and returns the whole file.
  ///
  /// [useIsolate] moves the KDF off the calling thread, which is what keeps
  /// the UI from freezing for the second or so Argon2id takes. Tests pass
  /// false to stay on one thread.
  static Future<Uint8List> encrypt({
    required Uint8List plaintext,
    required String passphrase,
    bool useIsolate = true,
  }) async {
    final header = BackupHeader(
      formatVersion: formatVersion,
      kdf: const BackupKdfParams.argon2id(),
      cipherId: cipherAes256Gcm,
      salt: randomBytes(saltLength),
      nonce: randomBytes(nonceLength),
    );
    final key = await _deriveKey(header, passphrase, useIsolate: useIsolate);
    final encoded = header.encode();
    final sealed = GCMBlockCipher(AESEngine())
      ..init(
        true,
        AEADParameters(
          KeyParameter(key),
          tagLength * 8,
          header.nonce,
          encoded,
        ),
      );
    final body = sealed.process(plaintext);

    final out = BytesBuilder(copy: false)
      ..add(encoded)
      ..add(body);
    return out.toBytes();
  }

  /// Reverses [encrypt].
  ///
  /// Throws [BackupFormatException] when [file] is not a backup this build
  /// can read at all, and [BackupAuthException] when it is but the tag does
  /// not verify. Those two cases are kept apart on purpose: the first is
  /// something the user can act on ("this is not a backup file", "this file
  /// is from a newer version"), the second deliberately is not — a wrong
  /// passphrase and a corrupted file are indistinguishable to GCM, and this
  /// does not pretend otherwise.
  static Future<Uint8List> decrypt({
    required Uint8List file,
    required String passphrase,
    bool useIsolate = true,
  }) async {
    final header = BackupHeader.parse(file);
    // Ciphertext may legitimately be empty, but the tag never is.
    if (file.length < headerLength + tagLength) {
      throw const BackupFormatException(
        'This file is not a SecureShell Go backup, or it is damaged.',
      );
    }
    final key = await _deriveKey(header, passphrase, useIsolate: useIsolate);
    final opened = GCMBlockCipher(AESEngine())
      ..init(
        false,
        AEADParameters(
          KeyParameter(key),
          tagLength * 8,
          header.nonce,
          file.sublist(0, headerLength),
        ),
      );
    try {
      return opened.process(file.sublist(headerLength));
    } on InvalidCipherTextException {
      throw const BackupAuthException();
    } on ArgumentError {
      // A mangled length that GCM rejects before it gets as far as the tag.
      // Same user-visible outcome; nothing has been decrypted either way.
      throw const BackupAuthException();
    }
  }

  /// [count] bytes from [Random.secure].
  static Uint8List randomBytes(int count) {
    final bytes = Uint8List(count);
    for (var i = 0; i < count; i++) {
      bytes[i] = _random.nextInt(256);
    }
    return bytes;
  }

  static Future<Uint8List> _deriveKey(
    BackupHeader header,
    String passphrase, {
    required bool useIsolate,
  }) {
    final request = _KdfRequest(
      kdfId: header.kdf.kdfId,
      memoryKiB: header.kdf.memoryKiB,
      iterations: header.kdf.iterations,
      lanes: header.kdf.lanes,
      salt: header.salt,
      passphrase: passphrase,
    );
    if (!useIsolate) return Future<Uint8List>.value(_runKdf(request));
    return Isolate.run(() => _runKdf(request));
  }
}

/// Everything needed to re-derive the key, as stored in the header.
///
/// Carried as data rather than baked into [BackupCrypto] so that a file
/// written with different costs — an older export, or a future one that
/// raises them — still opens with the numbers it was actually written with.
class BackupKdfParams {
  const BackupKdfParams({
    required this.kdfId,
    required this.memoryKiB,
    required this.iterations,
    required this.lanes,
  });

  const BackupKdfParams.argon2id({
    this.memoryKiB = BackupCrypto.argon2MemoryKiB,
    this.iterations = BackupCrypto.argon2Iterations,
    this.lanes = BackupCrypto.argon2Lanes,
  }) : kdfId = BackupCrypto.kdfArgon2id;

  const BackupKdfParams.pbkdf2({
    this.iterations = BackupCrypto.pbkdf2MinIterations,
  })  : kdfId = BackupCrypto.kdfPbkdf2Sha256,
        memoryKiB = 0,
        lanes = 0;

  final int kdfId;

  /// Argon2's `m`, in KiB. Zero for PBKDF2, which has no memory parameter.
  final int memoryKiB;

  /// Argon2's `t`, or PBKDF2's iteration count.
  final int iterations;

  /// Argon2's `p`. Zero for PBKDF2.
  final int lanes;

  /// A one-line description for the import preview, so the user can see what
  /// a file was actually written with rather than assuming today's defaults.
  String get label => switch (kdfId) {
        BackupCrypto.kdfArgon2id =>
          'Argon2id (${memoryKiB ~/ 1024} MiB, $iterations passes, '
              '$lanes lane${lanes == 1 ? '' : 's'})',
        BackupCrypto.kdfPbkdf2Sha256 =>
          'PBKDF2-HMAC-SHA256 ($iterations iterations)',
        _ => 'Unknown key derivation',
      };

  /// Rejects a header whose costs are too low to be worth anything, which is
  /// the shape a downgrade attack would take: hand the user a file whose
  /// header says "one Argon2 pass over 8 KiB" and the passphrase stops
  /// mattering. Nothing here can be weaker than what this build would write.
  void validate() {
    switch (kdfId) {
      case BackupCrypto.kdfArgon2id:
        final tooCheap = memoryKiB < BackupCrypto.argon2MemoryKiB ||
            iterations < BackupCrypto.argon2Iterations ||
            lanes < 1;
        if (tooCheap) {
          throw const BackupFormatException(
            'This backup declares weaker protection than SecureShell Go '
            'accepts, so it will not be opened.',
          );
        }
      case BackupCrypto.kdfPbkdf2Sha256:
        if (iterations < BackupCrypto.pbkdf2MinIterations) {
          throw const BackupFormatException(
            'This backup declares weaker protection than SecureShell Go '
            'accepts, so it will not be opened.',
          );
        }
      default:
        throw const BackupFormatException(
          'This backup uses a key derivation this version does not know.',
        );
    }
  }
}

/// The parsed, authenticated-by-GCM header of a `.ssgbackup` file.
class BackupHeader {
  const BackupHeader({
    required this.formatVersion,
    required this.kdf,
    required this.cipherId,
    required this.salt,
    required this.nonce,
  });

  final int formatVersion;
  final BackupKdfParams kdf;
  final int cipherId;
  final Uint8List salt;
  final Uint8List nonce;

  /// Serialises exactly the [BackupCrypto.headerLength] bytes that are then
  /// fed to GCM as AAD.
  Uint8List encode() {
    final bytes = Uint8List(BackupCrypto.headerLength);
    final view = ByteData.view(bytes.buffer);
    bytes.setRange(0, 6, BackupCrypto.magic);
    view.setUint16(6, formatVersion);
    bytes[8] = kdf.kdfId;
    view.setUint32(9, kdf.memoryKiB);
    view.setUint32(13, kdf.iterations);
    bytes[17] = kdf.lanes;
    bytes[18] = cipherId;
    bytes[19] = salt.length;
    bytes.setRange(20, 20 + BackupCrypto.saltLength, salt);
    bytes[36] = nonce.length;
    bytes.setRange(37, 37 + BackupCrypto.nonceLength, nonce);
    return bytes;
  }

  /// Reads the header off the front of [file].
  ///
  /// Every field is range-checked here rather than trusted, because this runs
  /// *before* the tag has authenticated anything — at this point the bytes
  /// are still entirely attacker-controlled, and a length taken on faith is
  /// how a parser turns into a crash.
  static BackupHeader parse(Uint8List file) {
    if (file.length < BackupCrypto.headerLength) {
      throw const BackupFormatException(
        'This file is not a SecureShell Go backup, or it is damaged.',
      );
    }
    for (var i = 0; i < BackupCrypto.magic.length; i++) {
      if (file[i] != BackupCrypto.magic[i]) {
        throw const BackupFormatException(
          'This file is not a SecureShell Go backup.',
        );
      }
    }
    final view = ByteData.view(file.buffer, file.offsetInBytes);
    final version = view.getUint16(6);
    if (version > BackupCrypto.formatVersion) {
      throw BackupFormatException.versionTooNew(version);
    }
    final kdf = BackupKdfParams(
      kdfId: file[8],
      memoryKiB: view.getUint32(9),
      iterations: view.getUint32(13),
      lanes: file[17],
    );
    kdf.validate();

    if (file[18] != BackupCrypto.cipherAes256Gcm) {
      throw const BackupFormatException(
        'This backup uses a cipher this version does not know.',
      );
    }
    // Both lengths are fixed in format 1. They are still written into the
    // file so a later format can grow them without a new version number, but
    // until one does, anything else is a damaged or forged header.
    if (file[19] != BackupCrypto.saltLength ||
        file[36] != BackupCrypto.nonceLength) {
      throw const BackupFormatException(
        'This file is not a SecureShell Go backup, or it is damaged.',
      );
    }
    return BackupHeader(
      formatVersion: version,
      kdf: kdf,
      cipherId: file[18],
      salt: file.sublist(20, 20 + BackupCrypto.saltLength),
      nonce: file.sublist(37, 37 + BackupCrypto.nonceLength),
    );
  }
}

/// Base for the two ways opening a backup can fail.
sealed class BackupException implements Exception {
  const BackupException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The file is not something this build can read: wrong magic, truncated,
/// a newer format version, or an unknown KDF/cipher id.
class BackupFormatException extends BackupException {
  const BackupFormatException(super.message) : isVersionTooNew = false;

  /// A file from a newer SecureShell Go. Refused outright rather than parsed
  /// as far as it goes: a format bump exists precisely because the meaning of
  /// some field changed, so a partial read is how a backup silently restores
  /// the wrong thing.
  const BackupFormatException.versionTooNew(int version)
      : isVersionTooNew = true,
        super(
          'This backup was written by a newer version of SecureShell Go '
          '(format $version). Update the app, then import it again.',
        );

  final bool isVersionTooNew;
}

/// The tag did not verify. Wrong passphrase, or the file has been altered —
/// which one is not knowable, and the message says so.
class BackupAuthException extends BackupException {
  const BackupAuthException()
      : super('Wrong passphrase, or the file is corrupt.');
}

/// A KDF job, shaped so it can cross an isolate boundary: plain numbers, one
/// [Uint8List] and one [String], no closures and nothing platform-bound.
class _KdfRequest {
  const _KdfRequest({
    required this.kdfId,
    required this.memoryKiB,
    required this.iterations,
    required this.lanes,
    required this.salt,
    required this.passphrase,
  });

  final int kdfId;
  final int memoryKiB;
  final int iterations;
  final int lanes;
  final Uint8List salt;
  final String passphrase;
}

/// Top-level so [Isolate.run] can reach it without capturing anything.
Uint8List _runKdf(_KdfRequest request) {
  final secret = Uint8List.fromList(utf8.encode(request.passphrase));
  final out = Uint8List(BackupCrypto.keyLength);
  switch (request.kdfId) {
    case BackupCrypto.kdfArgon2id:
      Argon2BytesGenerator()
        ..init(
          Argon2Parameters(
            Argon2Parameters.ARGON2_id,
            request.salt,
            desiredKeyLength: BackupCrypto.keyLength,
            iterations: request.iterations,
            memory: request.memoryKiB,
            lanes: request.lanes,
            version: Argon2Parameters.ARGON2_VERSION_13,
          ),
        )
        ..deriveKey(secret, 0, out, 0);
    case BackupCrypto.kdfPbkdf2Sha256:
      PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
        ..init(
          Pbkdf2Parameters(
            request.salt,
            request.iterations,
            BackupCrypto.keyLength,
          ),
        )
        ..deriveKey(secret, 0, out, 0);
    default:
      // Unreachable: BackupKdfParams.validate rejects unknown ids before any
      // key is derived. Kept as a throw rather than a fallback so a future id
      // added to the parser but not here fails loudly instead of quietly
      // deriving with the wrong function.
      throw const BackupFormatException(
        'This backup uses a key derivation this version does not know.',
      );
  }
  return out;
}
