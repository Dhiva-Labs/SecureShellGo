import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:pinenacl/ed25519.dart' as ed25519;

/// A freshly generated keypair in the two textual forms the rest of the app
/// deals in: an OpenSSH private key PEM (the same shape `SSHKeyPair.fromPem`
/// already parses for an imported key — see `private_key_import.dart`) and
/// the matching `ssh-ed25519 AAAA... comment` public line for
/// `authorized_keys`.
class GeneratedSshKeyPair {
  const GeneratedSshKeyPair({
    required this.privateKeyPem,
    required this.publicKeyLine,
  });

  final String privateKeyPem;
  final String publicKeyLine;
}

/// Generates ed25519 keys for the host edit screen's "Generate new key"
/// action, and derives the public line from a key already sitting in that
/// screen's private-key field.
///
/// dartssh2 has no `SSHKeyPair.generate` — `ssh_key_pair.dart` only parses and
/// signs with keys that already exist. What it does have is
/// `OpenSSHEd25519KeyPair`, which already knows how to encode itself as an
/// openssh-key-v1 PEM (`OpenSSHKeyPair.toPem`, the same mixin the RSA and
/// ECDSA pairs use) — so generation only needs fresh key material, not a
/// second hand-rolled copy of that codec. The material comes from pinenacl's
/// `SigningKey`, the same library `OpenSSHEd25519KeyPair.sign` itself
/// constructs from raw bytes to sign a challenge.
class SshKeygen {
  const SshKeygen._();

  /// Generates a new ed25519 keypair with [comment] as the trailing text on
  /// the public line (and stored inside the private-key block, the way
  /// `ssh-keygen` does).
  static GeneratedSshKeyPair generateEd25519({required String comment}) {
    final signing = ed25519.SigningKey.generate();

    // `asTypedList` on a SigningKey is the 64-byte libsodium secret (32-byte
    // seed followed by the 32-byte public key) — exactly the private-key
    // field `OpenSSHEd25519KeyPair.sign` feeds back into
    // `SigningKey.fromValidBytes`, and what OpenSSH itself stores there.
    final privateKeyBytes = Uint8List.fromList(signing.asTypedList);
    final publicKeyBytes = Uint8List.fromList(signing.verifyKey.asTypedList);

    final pair = OpenSSHEd25519KeyPair(publicKeyBytes, privateKeyBytes, comment);

    return GeneratedSshKeyPair(
      privateKeyPem: pair.toPem(),
      publicKeyLine: _publicLine(pair, comment),
    );
  }

  /// Derives the `<type> <base64> <comment>` public line for a private key
  /// that is already in PEM form — used by "Install public key on server…"
  /// when the field holds an imported or pasted key rather than one this
  /// class generated. Throws whatever `SSHKeyPair.fromPem` throws (the same
  /// exceptions `SshService.connect` already surfaces at connect time) if the
  /// key cannot be read.
  static String publicLineFromPem(
    String pem, {
    String? passphrase,
    required String comment,
  }) {
    final pairs = SSHKeyPair.fromPem(pem, passphrase);
    if (pairs.isEmpty) {
      throw const FormatException(
        'No usable key was found in that private key.',
      );
    }
    return _publicLine(pairs.first, comment);
  }

  static String _publicLine(SSHKeyPair pair, String comment) {
    final blob = base64.encode(pair.toPublicKey().encode());
    return '${pair.name} $blob $comment';
  }
}
