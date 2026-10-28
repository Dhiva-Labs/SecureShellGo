import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart'
    show OpenSSHKeyPairs, SSHIdentity, SSHKeyPair, SSHPem, SSHRawHostKey;

/// Raised when text is not a user certificate this app can sign in with.
/// [message] is written for a person, and says what to do instead.
class SshCertificateException implements Exception {
  const SshCertificateException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Whether a certificate is usable at a given moment.
enum SshCertificateValidity { valid, notYetValid, expired }

/// An OpenSSH certificate — the one line of a `…-cert.pub` file that
/// `ssh-keygen -s` writes — read far enough to show what it says and to
/// check it belongs with the key it is going to be presented with.
///
/// Only the parts a person or a sign-in needs are read. The certificate
/// authority's signature is not verified here: whether to trust that CA is
/// the server's decision (`TrustedUserCAKeys`), and it checks the signature
/// itself. What this does catch, before a server is ever asked, is the
/// mistakes that otherwise surface as a bare "permission denied": a
/// certificate for another key, a host certificate where a user one is
/// needed, one that has expired.
///
/// Wire format: `PROTOCOL.certkeys` in the OpenSSH sources.
class SshCertificate {
  const SshCertificate._({
    required this.type,
    required this.blob,
    required this.comment,
    required this.publicKeyBlob,
    required this.serial,
    required this.isUserCertificate,
    required this.keyId,
    required this.principals,
    required this.validAfter,
    required this.validBefore,
    required this.criticalOptions,
    required this.extensions,
    required this.signingKeyType,
    required this.signingKeyBlob,
  });

  /// The certificate's algorithm, e.g. `ssh-ed25519-cert-v01@openssh.com`.
  final String type;

  /// The whole certificate, as the server is shown it.
  final Uint8List blob;

  /// What followed the base64 on the line, if anything.
  final String? comment;

  /// The key the certificate certifies, as an ordinary public key blob.
  final Uint8List publicKeyBlob;

  final BigInt serial;

  /// False for a host certificate, which identifies a server and cannot be
  /// signed in with. [parse] refuses those, so this is always true on a
  /// certificate it returns; it is kept for what [parse] reports.
  final bool isUserCertificate;

  /// The CA's label for this certificate (`ssh-keygen -I`), which is what
  /// the server writes in its log on every login with it.
  final String keyId;

  /// The user names it may sign in as. Empty is not "anyone": a server
  /// that trusts the CA in its sshd_config (`TrustedUserCAKeys`) refuses a
  /// user certificate that names no one ("Certificate lacks principal
  /// list"); only an `authorized_keys` `cert-authority` line takes it as a
  /// wildcard.
  final List<String> principals;

  /// Null for "from the beginning of time". A start past what [DateTime]
  /// can hold is [farFuture]: not valid yet, and not in any lifetime.
  final DateTime? validAfter;

  /// Null for "forever".
  final DateTime? validBefore;

  /// Each critical option and its value, e.g. `force-command` →
  /// `/usr/bin/backup`, `source-address` → `10.0.0.0/8`. A server enforces
  /// these, and refuses a certificate with one it does not know.
  final Map<String, String> criticalOptions;

  /// What the certificate permits, e.g. `permit-pty`,
  /// `permit-agent-forwarding`. Anything not listed is refused.
  final List<String> extensions;

  /// The critical options OpenSSH knows. A certificate carrying any other
  /// is refused by its servers ("unsupported critical option").
  static const knownCriticalOptions = {
    'force-command',
    'source-address',
    'verify-required',
  };

  /// Where a `valid_after` past year 9999 is put: still in the future.
  static final DateTime farFuture = DateTime.utc(9999, 12, 31, 23, 59, 59);

  /// The command the server runs instead of whatever is asked for — the
  /// shell included — or null when it does not force one.
  String? get forceCommand => criticalOptions['force-command'];

  /// The client addresses the server accepts it from, or null for any.
  List<String>? get sourceAddresses => criticalOptions['source-address']
      ?.split(',')
      .map((a) => a.trim())
      .where((a) => a.isNotEmpty)
      .toList();

  /// Critical options no OpenSSH server knows, which make it refuse this.
  List<String> get unknownCriticalOptions => [
        for (final name in criticalOptions.keys)
          if (!knownCriticalOptions.contains(name)) name,
      ];

  /// Whether a session signed in with this may forward the agent.
  bool get permitsAgentForwarding =>
      extensions.contains('permit-agent-forwarding');

  /// Whether a session signed in with this may forward X11.
  bool get permitsX11Forwarding => extensions.contains('permit-X11-forwarding');

  /// The CA key's type, e.g. `ssh-ed25519`.
  final String signingKeyType;
  final Uint8List signingKeyBlob;

  /// The certified key's type, e.g. `ssh-ed25519`, `sk-ssh-ed25519@openssh.com`.
  String get keyType => _certifiedKeyType[type]!;

  /// The `publickey` algorithm to present this with. RSA is offered with
  /// SHA-256 rather than the SHA-1 its name implies, which OpenSSH stopped
  /// accepting by default in 8.8.
  String get publicKeyAlgorithm => type == 'ssh-rsa-cert-v01@openssh.com'
      ? 'rsa-sha2-256-cert-v01@openssh.com'
      : type;

  /// A short name for the certified key's kind, e.g. "ED25519", "RSA".
  String get keyTypeLabel => describeSshKeyType(keyType);

  /// `SHA256:…` of the certified key, as `ssh-keygen -l` prints it.
  String get publicKeyFingerprint => sshKeyFingerprint(publicKeyBlob);

  /// `SHA256:…` of the CA that signed it.
  String get signingKeyFingerprint => sshKeyFingerprint(signingKeyBlob);

  /// The line to keep: type, base64 and comment, as the file had them.
  String get line {
    final text = '$type ${base64.encode(blob)}';
    final note = comment;
    return note == null || note.isEmpty ? text : '$text $note';
  }

  SshCertificateValidity validityAt(DateTime now) {
    final after = validAfter;
    if (after != null && now.isBefore(after)) {
      return SshCertificateValidity.notYetValid;
    }
    final before = validBefore;
    if (before != null && !now.isBefore(before)) {
      return SshCertificateValidity.expired;
    }
    return SshCertificateValidity.valid;
  }

  /// Why this certificate cannot be used at [now], or null when it can.
  String? validityProblemAt(DateTime now) => switch (validityAt(now)) {
        SshCertificateValidity.valid => null,
        SshCertificateValidity.expired =>
          'The certificate expired on ${formatCertificateTime(validBefore!)}. '
              'Load a renewed one.',
        SshCertificateValidity.notYetValid =>
          'The certificate is not valid until '
              '${formatCertificateTime(validAfter!)}.',
      };

  /// Whether this certifies the key whose public blob is [keyBlob].
  bool certifies(Uint8List keyBlob) => samePublicKey(publicKeyBlob, keyBlob);

  /// Why this certificate does not go with the key [keyBlob], or null when
  /// it does.
  String? mismatchWith(Uint8List keyBlob) {
    final String otherType;
    try {
      otherType = _readString(_Reader(keyBlob));
    } on SshCertificateException {
      return 'The key could not be read to compare it with the certificate.';
    }
    if (otherType != keyType) {
      return 'This certificate is for ${_aKeyOf(keyType)}, but this host '
          'signs in with ${_aKeyOf(otherType)}.';
    }
    if (!certifies(keyBlob)) {
      return 'This certificate was issued for a different key '
          '($publicKeyFingerprint), not the one this host signs in with '
          '(${sshKeyFingerprint(keyBlob)}).';
    }
    return null;
  }

  /// Reads a certificate from the text of a `-cert.pub` file, or a line
  /// pasted from one.
  ///
  /// Throws [SshCertificateException] with a message that says what the
  /// text is instead — a public key, a private key, a host certificate — and
  /// what to load.
  static SshCertificate parse(String text) {
    final line = text
        .split(RegExp(r'\r?\n'))
        .map((l) => l.trim())
        .firstWhere((l) => l.isNotEmpty && !l.startsWith('#'), orElse: () => '');
    if (line.isEmpty) {
      throw const SshCertificateException('That is empty. Paste the line from '
          'the -cert.pub file, or load the file.');
    }
    if (line.startsWith('-----BEGIN')) {
      throw const SshCertificateException('That is a private key, not a '
          'certificate. Load the matching -cert.pub file instead.');
    }

    final parts = line.split(RegExp(r'\s+'));
    final declared = parts.first;
    if (parts.length < 2) {
      throw const SshCertificateException('That does not look like a '
          'certificate. Copy the whole line from the -cert.pub file.');
    }
    if (!declared.endsWith('-cert-v01@openssh.com')) {
      if (_plainKeyTypes.contains(declared)) {
        throw const SshCertificateException('That is a public key, not a '
            'certificate. A certificate is made by signing a public key with '
            '`ssh-keygen -s`, and is saved next to it as …-cert.pub.');
      }
      throw const SshCertificateException('That does not look like an SSH '
          'certificate. Load the -cert.pub file.');
    }
    if (declared == 'ssh-dss-cert-v01@openssh.com') {
      throw const SshCertificateException('DSA certificates are not '
          'supported. Use an ed25519, ECDSA or RSA key.');
    }
    if (!_certifiedKeyType.containsKey(declared)) {
      throw SshCertificateException('Certificates of type "$declared" are '
          'not supported.');
    }

    final Uint8List blob;
    try {
      blob = base64.decode(parts[1]);
    } on FormatException {
      throw const SshCertificateException(_damaged);
    }
    final comment = parts.length > 2 ? parts.sublist(2).join(' ') : null;
    return _decode(declared, blob, comment);
  }

  /// Like [parse], for a value saved earlier — null when there is none or
  /// it no longer reads.
  static SshCertificate? tryParse(String? text) {
    if (text == null || text.trim().isEmpty) return null;
    try {
      return parse(text);
    } on SshCertificateException {
      return null;
    }
  }

  static const _damaged = 'The certificate is damaged or incomplete. Copy the '
      'whole line from the -cert.pub file.';

  static SshCertificate _decode(String declared, Uint8List blob, String? comment) {
    try {
      final reader = _Reader(blob);
      final type = _readString(reader);
      if (type != declared) throw const SshCertificateException(_damaged);
      reader.readBytes(); // nonce

      // The certified key's own fields, copied verbatim behind its plain
      // type name, are exactly its ordinary public key blob.
      final fieldsStart = reader.offset;
      for (var i = 0; i < _keyFieldCount[type]!; i++) {
        reader.readBytes();
      }
      final fields = Uint8List.sublistView(blob, fieldsStart, reader.offset);
      final publicKeyBlob = (_Writer()
            ..writeString(utf8.encode(_certifiedKeyType[type]!))
            ..writeRaw(fields))
          .bytes();

      final serial = reader.readUint64();
      final kind = reader.readUint32();
      final keyId = _readString(reader);
      final principals = _readStringList(reader.readBytes());
      final validAfter = _timestamp(reader.readUint64(), forever: false);
      final validBefore = _timestamp(reader.readUint64(), forever: true);
      final criticalOptions = _readOptions(reader.readBytes());
      final extensions = _readOptions(reader.readBytes()).keys.toList();
      reader.readBytes(); // reserved
      final signingKeyBlob = Uint8List.fromList(reader.readBytes());
      reader.readBytes(); // signature
      if (reader.remaining != 0) throw const SshCertificateException(_damaged);

      if (kind == 2) {
        throw const SshCertificateException('That is a host certificate, '
            'which identifies a server. Signing in needs a user certificate '
            '(made with `ssh-keygen -s` without -h).');
      }
      if (kind != 1) throw const SshCertificateException(_damaged);

      return SshCertificate._(
        type: type,
        blob: Uint8List.fromList(blob),
        comment: comment,
        publicKeyBlob: publicKeyBlob,
        serial: serial,
        isUserCertificate: true,
        keyId: keyId,
        principals: principals,
        validAfter: validAfter,
        validBefore: validBefore,
        criticalOptions: criticalOptions,
        extensions: extensions,
        signingKeyType: _readString(_Reader(signingKeyBlob)),
        signingKeyBlob: signingKeyBlob,
      );
    } on SshCertificateException {
      rethrow;
    } on FormatException {
      throw const SshCertificateException(_damaged);
    }
  }

  /// Seconds since the epoch, with the two ends of the range meaning "no
  /// limit": 0 for valid-after, all ones for valid-before.
  static DateTime? _timestamp(BigInt seconds, {required bool forever}) {
    if (!forever && seconds == BigInt.zero) return null;
    // Past the year 9999 is past what DateTime can hold. For valid-before
    // that is "forever" in practice; for valid-after it is "not yet", not
    // "always" — a start that far off must not read as no start at all.
    if (seconds > BigInt.from(253402300799)) return forever ? null : farFuture;
    return DateTime.fromMillisecondsSinceEpoch(
      seconds.toInt() * 1000,
      isUtc: true,
    );
  }

  static String _readString(_Reader reader) {
    final bytes = reader.readBytes();
    try {
      return utf8.decode(bytes);
    } on FormatException {
      throw const SshCertificateException(_damaged);
    }
  }

  static List<String> _readStringList(Uint8List packed) {
    final reader = _Reader(packed);
    return [for (; reader.remaining > 0;) _readString(reader)];
  }

  /// Critical options and extensions are `string name, string data` pairs.
  /// The data of the options that carry a value (`force-command`,
  /// `source-address`) is itself a string; anything else that has data is
  /// shown as base64 rather than guessed at.
  static Map<String, String> _readOptions(Uint8List packed) {
    final reader = _Reader(packed);
    final options = <String, String>{};
    while (reader.remaining > 0) {
      final name = _readString(reader);
      final data = reader.readBytes();
      options[name] = _optionValue(data);
    }
    return options;
  }

  static String _optionValue(Uint8List data) {
    if (data.isEmpty) return '';
    try {
      final inner = _Reader(data);
      final value = inner.readBytes();
      if (inner.remaining == 0) return utf8.decode(value);
    } on FormatException {
      // Not a string inside; shown raw below.
    }
    return base64.encode(data);
  }

  /// The certificate types this reads, and the key each certifies.
  static const _certifiedKeyType = {
    'ssh-ed25519-cert-v01@openssh.com': 'ssh-ed25519',
    'ssh-rsa-cert-v01@openssh.com': 'ssh-rsa',
    'ecdsa-sha2-nistp256-cert-v01@openssh.com': 'ecdsa-sha2-nistp256',
    'ecdsa-sha2-nistp384-cert-v01@openssh.com': 'ecdsa-sha2-nistp384',
    'ecdsa-sha2-nistp521-cert-v01@openssh.com': 'ecdsa-sha2-nistp521',
    'sk-ssh-ed25519-cert-v01@openssh.com': 'sk-ssh-ed25519@openssh.com',
    'sk-ecdsa-sha2-nistp256-cert-v01@openssh.com':
        'sk-ecdsa-sha2-nistp256@openssh.com',
  };

  /// How many `string`/`mpint` fields the certified key has between the
  /// nonce and the serial.
  static const _keyFieldCount = {
    'ssh-ed25519-cert-v01@openssh.com': 1, // pk
    'ssh-rsa-cert-v01@openssh.com': 2, // e, n
    'ecdsa-sha2-nistp256-cert-v01@openssh.com': 2, // curve, Q
    'ecdsa-sha2-nistp384-cert-v01@openssh.com': 2,
    'ecdsa-sha2-nistp521-cert-v01@openssh.com': 2,
    'sk-ssh-ed25519-cert-v01@openssh.com': 2, // pk, application
    'sk-ecdsa-sha2-nistp256-cert-v01@openssh.com': 3, // curve, Q, application
  };

  static const _plainKeyTypes = {
    'ssh-ed25519',
    'ssh-rsa',
    'ssh-dss',
    'ecdsa-sha2-nistp256',
    'ecdsa-sha2-nistp384',
    'ecdsa-sha2-nistp521',
    'sk-ssh-ed25519@openssh.com',
    'sk-ecdsa-sha2-nistp256@openssh.com',
  };
}

/// The identity that presents [certificate] and signs with [key]: the
/// certificate is what the server checks against its CA, and the
/// signature is an ordinary one by the certified key — so a key saved in
/// this app needs nothing more than a different blob and algorithm name in
/// front of the same `sign`.
///
/// The caller checks [SshCertificate.certifies] first.
SSHIdentity certificateIdentity(SshCertificate certificate, SSHKeyPair key) =>
    SSHIdentity.custom(
      type: certificate.publicKeyAlgorithm,
      publicKey: SSHRawHostKey(certificate.blob),
      signer: key.sign,
      comment: certificate.keyId,
    );

/// The public half of the private key in [pem], as a key blob, or null when
/// it cannot be had — an encrypted key without its [passphrase], or text
/// that is not a key at all.
///
/// An OpenSSH-format key keeps its public half outside the encryption, so
/// that is read without decrypting anything: this runs as the host form is
/// edited, and a bcrypt round per rebuild would be felt.
Uint8List? publicKeyBlobOfPem(String pem, {String? passphrase}) {
  final text = pem.trim();
  if (text.isEmpty) return null;
  try {
    final decoded = SSHPem.decode(text);
    if (decoded.type == 'OPENSSH PRIVATE KEY') {
      final keys = OpenSSHKeyPairs.decode(decoded.content).publicKeys;
      return keys.isEmpty ? null : keys.first;
    }
    final pairs = SSHKeyPair.fromPem(
      text,
      passphrase == null || passphrase.isEmpty ? null : passphrase,
    );
    return pairs.isEmpty ? null : pairs.first.toPublicKey().encode();
  } catch (_) {
    return null;
  }
}

/// Whether two public key blobs are the same key.
///
/// Compared field by field with leading zero bytes ignored, so an RSA
/// modulus written once as a minimal mpint and once with a spare zero byte
/// still matches; for every other key type the fields are fixed-length and
/// this is plain equality.
bool samePublicKey(Uint8List a, Uint8List b) {
  try {
    final fieldsA = _fields(a);
    final fieldsB = _fields(b);
    if (fieldsA.length != fieldsB.length) return false;
    for (var i = 0; i < fieldsA.length; i++) {
      if (!_sameIgnoringLeadingZeros(fieldsA[i], fieldsB[i])) return false;
    }
    return true;
  } on FormatException {
    return false;
  }
}

List<Uint8List> _fields(Uint8List blob) {
  final reader = _Reader(blob);
  return [for (; reader.remaining > 0;) reader.readBytes()];
}

bool _sameIgnoringLeadingZeros(Uint8List a, Uint8List b) {
  var i = 0;
  var j = 0;
  while (i < a.length - 1 && a[i] == 0) {
    i++;
  }
  while (j < b.length - 1 && b[j] == 0) {
    j++;
  }
  if (a.length - i != b.length - j) return false;
  for (; i < a.length; i++, j++) {
    if (a[i] != b[j]) return false;
  }
  return true;
}

/// "an ED25519 key", "an ED25519 security key".
String _aKeyOf(String keyType) {
  final label = describeSshKeyType(keyType);
  return label.endsWith('key') ? 'an $label' : 'an $label key';
}

/// `SHA256:…`, as `ssh-keygen -l` prints a key's fingerprint.
String sshKeyFingerprint(Uint8List keyBlob) =>
    'SHA256:${base64.encode(sha256.convert(keyBlob).bytes).replaceAll('=', '')}';

/// A short name for a key type, e.g. "ED25519", "RSA", "ECDSA P-256",
/// "ED25519 security key".
String describeSshKeyType(String keyType) => switch (keyType) {
      'ssh-ed25519' => 'ED25519',
      'ssh-rsa' => 'RSA',
      'ssh-dss' => 'DSA',
      'ecdsa-sha2-nistp256' => 'ECDSA P-256',
      'ecdsa-sha2-nistp384' => 'ECDSA P-384',
      'ecdsa-sha2-nistp521' => 'ECDSA P-521',
      'sk-ssh-ed25519@openssh.com' => 'ED25519 security key',
      'sk-ecdsa-sha2-nistp256@openssh.com' => 'ECDSA security key',
      _ => keyType,
    };

/// `2026-10-21 14:05 UTC` — certificates are issued in UTC, and a CA's
/// "valid until" is clearest read the same way.
String formatCertificateTime(DateTime time) {
  final t = time.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}:${two(t.minute)} UTC';
}

class _Reader {
  _Reader(this._bytes);

  final Uint8List _bytes;
  int offset = 0;

  int get remaining => _bytes.length - offset;

  int readUint32() {
    if (remaining < 4) throw const FormatException('truncated');
    final value = ByteData.sublistView(_bytes, offset, offset + 4).getUint32(0);
    offset += 4;
    return value;
  }

  BigInt readUint64() {
    final high = readUint32();
    final low = readUint32();
    return (BigInt.from(high) << 32) | BigInt.from(low);
  }

  Uint8List readBytes() {
    final length = readUint32();
    if (remaining < length) throw const FormatException('truncated');
    final value = Uint8List.sublistView(_bytes, offset, offset + length);
    offset += length;
    return value;
  }
}

class _Writer {
  final BytesBuilder _builder = BytesBuilder(copy: false);

  void writeString(List<int> value) {
    _builder.add((ByteData(4)..setUint32(0, value.length)).buffer.asUint8List());
    _builder.add(value);
  }

  void writeRaw(List<int> value) => _builder.add(value);

  Uint8List bytes() => _builder.takeBytes();
}
