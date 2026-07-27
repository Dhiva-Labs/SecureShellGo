import 'package:dartssh2/dartssh2.dart';

/// Mirrors the cap enforced on the native side (`StorageBridge.kt`'s
/// `pickFileContent`) — a private key is at most a couple of KB, so 64 KB is
/// generous headroom while still refusing to fill the form with something
/// that plainly is not a key file. Checked again here, independent of the
/// platform channel, so a huge string can never reach the parser below.
const int kMaxPrivateKeyImportBytes = 64 * 1024;

/// What inspecting a private key without connecting anywhere told us.
enum PrivateKeyImportStatus {
  /// Parses cleanly and needs no passphrase.
  valid,

  /// Parses, but is encrypted — a passphrase is needed before it can be used.
  passphraseProtected,

  /// Not a key this app can use: empty input, oversize input, garbage text,
  /// a non-key PEM block, or a format dartssh2 does not implement (PKCS#8).
  invalid,
}

/// The outcome of [classifyPrivateKeyPem].
///
/// Exists so the "Import key file" flow in `host_edit_screen.dart` can
/// decide what to do with a picked file — fill the PEM field and say what it
/// found, fill it and point at the passphrase field, or leave it alone and
/// explain why — without ever building a socket.
class PrivateKeyImportResult {
  const PrivateKeyImportResult._(this.status, {this.keyType, this.message});

  final PrivateKeyImportStatus status;

  /// A human label such as "RSA", "ed25519" or "ECDSA (nistp256)". Set for
  /// [PrivateKeyImportStatus.valid] and
  /// [PrivateKeyImportStatus.passphraseProtected].
  final String? keyType;

  /// Why the key was rejected, fit to show in a dialog. Set only for
  /// [PrivateKeyImportStatus.invalid].
  final String? message;

  factory PrivateKeyImportResult.valid(String keyType) =>
      PrivateKeyImportResult._(PrivateKeyImportStatus.valid, keyType: keyType);

  factory PrivateKeyImportResult.passphraseProtected(String keyType) =>
      PrivateKeyImportResult._(
        PrivateKeyImportStatus.passphraseProtected,
        keyType: keyType,
      );

  factory PrivateKeyImportResult.invalid(String message) =>
      PrivateKeyImportResult._(
        PrivateKeyImportStatus.invalid,
        message: message,
      );
}

/// Classifies private-key text without ever touching the network.
///
/// This is deliberately the same check `SshService.connect` runs on
/// `credentials.privateKeyPem` before it will even open a socket
/// (`SSHKeyPair.isEncryptedPem` / `SSHKeyPair.fromPem` — see
/// `ssh_service.dart`'s `_parseIdentities`), pulled out so a file picked from
/// disk can be validated before the user has typed a host to connect to, and
/// worded for "does this file look right" rather than "can I connect".
///
/// Supports everything dartssh2 parses: OpenSSH ("BEGIN OPENSSH PRIVATE
/// KEY"), PKCS#1 RSA ("BEGIN RSA PRIVATE KEY" — what `ssh-keygen -m PEM` and
/// AWS EC2 both produce), and EC ("BEGIN EC PRIVATE KEY"), each plain or
/// encrypted. One gap inherited from dartssh2: an OpenSSL-encrypted EC key is
/// still reported as passphrase-protected here (the format supports it) even
/// though dartssh2 cannot actually decrypt one yet — that failure surfaces
/// later, at connect time, the same as it does for a pasted key today.
/// PKCS#8 ("BEGIN PRIVATE KEY" / "BEGIN ENCRYPTED PRIVATE KEY") is not
/// implemented by dartssh2 at all and is reported as an unsupported format.
PrivateKeyImportResult classifyPrivateKeyPem(String pem) {
  if (pem.length > kMaxPrivateKeyImportBytes) {
    return PrivateKeyImportResult.invalid(
      'That file is ${pem.length} bytes, over the '
      '$kMaxPrivateKeyImportBytes byte limit for a private key.',
    );
  }

  final text = pem.trim();
  if (text.isEmpty) {
    return PrivateKeyImportResult.invalid('The file is empty.');
  }

  final SSHPem parsed;
  try {
    parsed = SSHPem.decode(text);
  } catch (_) {
    return PrivateKeyImportResult.invalid(
      'That does not look like a private key file — no '
      '"-----BEGIN ... PRIVATE KEY-----" block was found.',
    );
  }

  const supportedTypes = {
    'OPENSSH PRIVATE KEY',
    'RSA PRIVATE KEY',
    'EC PRIVATE KEY',
  };
  if (!supportedTypes.contains(parsed.type)) {
    final isPkcs8 = parsed.type == 'PRIVATE KEY' ||
        parsed.type == 'ENCRYPTED PRIVATE KEY';
    return PrivateKeyImportResult.invalid(
      isPkcs8
          ? 'Unsupported private key format: PKCS#8 ("${parsed.type}"). '
              'Re-export it as OpenSSH or PEM (ssh-keygen -p -m PEM -f '
              '<file>), or use an OpenSSH, PKCS#1 RSA or EC key instead.'
          : 'Unsupported private key format: "${parsed.type}".',
    );
  }

  bool encrypted;
  try {
    encrypted = SSHKeyPair.isEncryptedPem(text);
  } catch (_) {
    return PrivateKeyImportResult.invalid(
      'The private key could not be read.',
    );
  }

  if (encrypted) {
    return PrivateKeyImportResult.passphraseProtected(
      _friendlyFormatName(parsed.type),
    );
  }

  try {
    final pairs = SSHKeyPair.fromPem(text);
    if (pairs.isEmpty) {
      return PrivateKeyImportResult.invalid(
        'No usable key was found in that file.',
      );
    }
    return PrivateKeyImportResult.valid(_friendlyKeyName(pairs.first.name));
  } catch (_) {
    return PrivateKeyImportResult.invalid(
      'The private key could not be decoded.',
    );
  }
}

/// Used when the key is encrypted, so decoding stops at the PEM header
/// (decrypting to find the exact algorithm would need the passphrase we
/// don't have yet).
String _friendlyFormatName(String pemType) {
  switch (pemType) {
    case 'OPENSSH PRIVATE KEY':
      return 'OpenSSH key';
    case 'RSA PRIVATE KEY':
      return 'RSA';
    case 'EC PRIVATE KEY':
      return 'ECDSA';
    default:
      return pemType;
  }
}

/// Used when the key decoded cleanly, so the exact algorithm name
/// (`SSHKeyPair.name`) is known: 'ssh-rsa', 'ssh-ed25519' or
/// `ecdsa-sha2-{curve}`.
String _friendlyKeyName(String name) {
  if (name == 'ssh-rsa') return 'RSA';
  if (name == 'ssh-ed25519') return 'ed25519';
  if (name.startsWith('ecdsa-sha2-')) {
    return 'ECDSA (${name.substring('ecdsa-sha2-'.length)})';
  }
  return name;
}
