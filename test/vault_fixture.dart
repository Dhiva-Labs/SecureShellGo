import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';
import 'package:secure_shell_go/services/backup_crypto.dart';
import 'package:secure_shell_go/services/secret_vault.dart';

/// The 32 bytes a device key file would hold. Fixed rather than random so a
/// failure names one file rather than one run.
final Uint8List deviceKey =
    Uint8List.fromList(List<int>.generate(32, (i) => i + 1));

/// Builds a vault file byte for byte, so a test can produce shapes the app
/// itself will never write: format version 1, a wrap-mode byte that disagrees
/// with the tag, or a wrapped-key slot where there should be none.
///
/// Deliberately not a call into [SecretVault]. A compatibility test that
/// builds its fixture with the code under test proves only that the code
/// agrees with itself.
Uint8List buildVaultFile({
  required int version,
  required int wrapMode,
  required Uint8List wrappedKey,
  required Uint8List key,
  required Uint8List nonce,
  Map<String, String> secrets = const {},
}) {
  final builder = BytesBuilder()..add(SecretVault.magic);
  // Format 1 has no wrap-mode byte: the length follows the version directly.
  final header = ByteData(version < 2 ? 6 : 7);
  header.setUint16(0, version);
  var lengthOffset = 2;
  if (version >= 2) {
    header.setUint8(2, wrapMode);
    lengthOffset = 3;
  }
  header.setUint32(lengthOffset, wrappedKey.length);
  builder
    ..add(header.buffer.asUint8List())
    ..add(wrappedKey)
    ..addByte(SecretVault.nonceLength)
    ..add(nonce);
  final prefix = builder.toBytes();
  final cipher = GCMBlockCipher(AESEngine())
    ..init(
      true,
      AEADParameters(
        KeyParameter(key),
        SecretVault.tagLength * 8,
        nonce,
        prefix,
      ),
    );
  final body =
      cipher.process(Uint8List.fromList(utf8.encode(jsonEncode(secrets))));
  return Uint8List.fromList(<int>[...prefix, ...body]);
}

/// A vault exactly as 1.4.1 wrote them: format version 1, no wrap-mode byte,
/// the vault key inside a `BackupCrypto` container under [passphrase].
Future<Uint8List> buildLegacyVaultFile({
  required String passphrase,
  Map<String, String> secrets = const {},
}) async {
  final wrapped = await BackupCrypto.encrypt(
    plaintext: deviceKey,
    passphrase: passphrase,
    useIsolate: false,
  );
  return buildVaultFile(
    version: 1,
    wrapMode: SecretVault.wrapModePassphrase,
    wrappedKey: wrapped,
    key: deviceKey,
    nonce: BackupCrypto.randomBytes(SecretVault.nonceLength),
    secrets: secrets,
  );
}
