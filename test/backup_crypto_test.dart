import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
// Same reasoning as `backup_crypto.dart`'s own import: pointycastle is in the
// tree via dartssh2 and pubspec.yaml is frozen. The known-answer test below
// is the reason this file needs it directly — it pins the *dependency*, not
// our wrapper around it.
// ignore: depend_on_referenced_packages
import 'package:pointycastle/export.dart';
import 'package:secure_shell_go/services/backup_crypto.dart';

/// Every test here runs the KDF inline. Argon2id at the shipped cost is
/// roughly a second a go, and spawning an isolate per derivation would add to
/// that without testing anything the one dedicated isolate test does not.
Future<Uint8List> _seal(String text, String passphrase) => BackupCrypto.encrypt(
      plaintext: Uint8List.fromList(utf8.encode(text)),
      passphrase: passphrase,
      useIsolate: false,
    );

Future<String> _open(Uint8List file, String passphrase) async {
  final plain = await BackupCrypto.decrypt(
    file: file,
    passphrase: passphrase,
    useIsolate: false,
  );
  return utf8.decode(plain);
}

/// A copy of [file] with one bit flipped at [index].
Uint8List _flip(Uint8List file, int index) {
  final copy = Uint8List.fromList(file);
  copy[index] ^= 0x01;
  return copy;
}

void main() {
  const passphrase = 'correct horse battery staple';
  const secret = '{"hosts":[{"id":"a","hostname":"example.com"}]}';

  group('primitive known-answer tests', () {
    // These do not test our code at all — they test that the pointycastle in
    // this tree computes what the RFCs say it should. If a dependency bump
    // ever silently changes a primitive, every backup ever written by this
    // app becomes unreadable, and this is the test that catches it on the
    // way in rather than in a bug report.
    test('Argon2id matches the RFC 9106 test vector', () {
      final out = Uint8List(32);
      Argon2BytesGenerator()
        ..init(
          Argon2Parameters(
            Argon2Parameters.ARGON2_id,
            Uint8List.fromList(List.filled(16, 2)),
            secret: Uint8List.fromList(List.filled(8, 3)),
            additional: Uint8List.fromList(List.filled(12, 4)),
            desiredKeyLength: 32,
            iterations: 3,
            memory: 32,
            lanes: 4,
            version: Argon2Parameters.ARGON2_VERSION_13,
          ),
        )
        ..deriveKey(Uint8List.fromList(List.filled(32, 1)), 0, out, 0);
      expect(
        out.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        '0d640df58d78766c08c037a34a8b53c9'
        'd01ef0452d75b65eb52520e96b01e659',
      );
    });

    test('AES-256-GCM rejects a tampered tag', () {
      final key = Uint8List.fromList(List.generate(32, (i) => i));
      final nonce = Uint8List.fromList(List.generate(12, (i) => i));
      final plain = Uint8List.fromList(utf8.encode('hello'));
      final sealed = GCMBlockCipher(AESEngine())
        ..init(true, AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)))
        ;
      final ct = sealed.process(plain);
      expect(ct.length, plain.length + 16);

      final bad = Uint8List.fromList(ct)..[ct.length - 1] ^= 0x01;
      expect(
        () => (GCMBlockCipher(AESEngine())
              ..init(
                false,
                AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)),
              ))
            .process(bad),
        throwsA(isA<InvalidCipherTextException>()),
      );
    });
  });

  group('round trip', () {
    test('decrypts back to the exact plaintext', () async {
      final file = await _seal(secret, passphrase);
      expect(await _open(file, passphrase), secret);
    });

    test('handles an empty payload', () async {
      final file = await _seal('', passphrase);
      expect(await _open(file, passphrase), '');
    });

    test('handles a payload larger than one AES block', () async {
      final big = List.generate(5000, (i) => 'line $i').join('\n');
      final file = await _seal(big, passphrase);
      expect(await _open(file, passphrase), big);
    });

    test('handles a non-ASCII passphrase', () async {
      const unicode = 'pässwörd-日本語-🔐';
      final file = await _seal(secret, unicode);
      expect(await _open(file, unicode), secret);
    });

    test('works across an isolate hop', () async {
      // The path the app actually takes, so the KDF request really is
      // sendable and the UI-thread hop is not just theory.
      final file = await BackupCrypto.encrypt(
        plaintext: Uint8List.fromList(utf8.encode(secret)),
        passphrase: passphrase,
      );
      final plain = await BackupCrypto.decrypt(
        file: file,
        passphrase: passphrase,
      );
      expect(utf8.decode(plain), secret);
    });
  });

  group('header', () {
    test('starts with the magic and the format version', () async {
      final file = await _seal(secret, passphrase);
      expect(file.sublist(0, 6), BackupCrypto.magic);
      expect(file[7], BackupCrypto.formatVersion);
    });

    test('round-trips the KDF parameters it was written with', () async {
      final file = await _seal(secret, passphrase);
      final header = BackupHeader.parse(file);
      expect(header.formatVersion, BackupCrypto.formatVersion);
      expect(header.kdf.kdfId, BackupCrypto.kdfArgon2id);
      expect(header.kdf.memoryKiB, BackupCrypto.argon2MemoryKiB);
      expect(header.kdf.iterations, BackupCrypto.argon2Iterations);
      expect(header.kdf.lanes, BackupCrypto.argon2Lanes);
      expect(header.cipherId, BackupCrypto.cipherAes256Gcm);
      expect(header.salt.length, BackupCrypto.saltLength);
      expect(header.nonce.length, BackupCrypto.nonceLength);
    });

    test('describes the KDF for the import preview', () async {
      final header = BackupHeader.parse(await _seal(secret, passphrase));
      expect(header.kdf.label, 'Argon2id (64 MiB, 3 passes, 1 lane)');
    });

    test('is exactly headerLength bytes ahead of the ciphertext', () async {
      final file = await _seal('', passphrase);
      // Empty plaintext, so everything after the header is the tag.
      expect(file.length, BackupCrypto.headerLength + BackupCrypto.tagLength);
    });
  });

  group('randomness', () {
    test('salt and nonce are fresh on every export', () async {
      // Same passphrase and same plaintext every time: if anything here were
      // derived from those rather than drawn fresh, these sets would collapse
      // to one element and a nonce would be reused under a repeated key.
      final salts = <String>{};
      final nonces = <String>{};
      final ciphertexts = <String>{};
      for (var i = 0; i < 12; i++) {
        final file = await _seal(secret, passphrase);
        final header = BackupHeader.parse(file);
        salts.add(base64Encode(header.salt));
        nonces.add(base64Encode(header.nonce));
        ciphertexts.add(base64Encode(file.sublist(BackupCrypto.headerLength)));
      }
      expect(salts.length, 12);
      expect(nonces.length, 12);
      // A fresh salt means a fresh key, so identical plaintext must still
      // encrypt to something different every time.
      expect(ciphertexts.length, 12);
    });
  });

  group('rejection', () {
    late Uint8List good;

    setUpAll(() async {
      good = await _seal(secret, passphrase);
    });

    test('wrong passphrase fails as passphrase-or-corrupt', () async {
      await expectLater(
        _open(good, 'not the passphrase'),
        throwsA(isA<BackupAuthException>()),
      );
    });

    test('an empty passphrase is not a skeleton key', () async {
      await expectLater(
        _open(good, ''),
        throwsA(isA<BackupAuthException>()),
      );
    });

    test('a bit flipped in the ciphertext is rejected', () async {
      // First byte past the header: payload, not tag.
      await expectLater(
        _open(_flip(good, BackupCrypto.headerLength), passphrase),
        throwsA(isA<BackupAuthException>()),
      );
    });

    test('a bit flipped in the tag is rejected', () async {
      await expectLater(
        _open(_flip(good, good.length - 1), passphrase),
        throwsA(isA<BackupAuthException>()),
      );
    });

    test('a bit flipped in the salt is rejected', () async {
      // Offset 20 is the first salt byte. This one fails because the derived
      // key changes, which is still the tag check doing the work.
      await expectLater(
        _open(_flip(good, 20), passphrase),
        throwsA(isA<BackupAuthException>()),
      );
    });

    test('a bit flipped in the nonce is rejected', () async {
      await expectLater(
        _open(_flip(good, 37), passphrase),
        throwsA(isA<BackupAuthException>()),
      );
    });

    test('a truncated file is rejected', () async {
      await expectLater(
        _open(good.sublist(0, good.length - 4), passphrase),
        throwsA(isA<BackupAuthException>()),
      );
    });

    test('a file shorter than the header is rejected', () async {
      await expectLater(
        _open(good.sublist(0, 10), passphrase),
        throwsA(isA<BackupFormatException>()),
      );
    });

    test('a header with no ciphertext or tag is rejected', () async {
      await expectLater(
        _open(good.sublist(0, BackupCrypto.headerLength), passphrase),
        throwsA(isA<BackupFormatException>()),
      );
    });

    test('a file with the wrong magic is rejected', () async {
      final wrong = Uint8List.fromList(good)..[0] = 0x00;
      await expectLater(
        _open(wrong, passphrase),
        throwsA(isA<BackupFormatException>()),
      );
    });

    test('a newer format version is refused cleanly', () async {
      final newer = Uint8List.fromList(good);
      ByteData.view(newer.buffer).setUint16(6, BackupCrypto.formatVersion + 1);
      await expectLater(
        _open(newer, passphrase),
        throwsA(
          isA<BackupFormatException>()
              .having((e) => e.isVersionTooNew, 'isVersionTooNew', isTrue)
              .having((e) => e.message, 'message', contains('newer version')),
        ),
      );
    });

    test('an unknown cipher id is refused', () async {
      final odd = Uint8List.fromList(good)..[18] = 99;
      await expectLater(
        _open(odd, passphrase),
        throwsA(isA<BackupFormatException>()),
      );
    });

    test('an unknown KDF id is refused', () async {
      final odd = Uint8List.fromList(good)..[8] = 99;
      await expectLater(
        _open(odd, passphrase),
        throwsA(isA<BackupFormatException>()),
      );
    });

    test('a header claiming a cheaper Argon2 cost is refused', () async {
      // The downgrade attack this guards: rewrite the header to one pass over
      // 8 KiB and the passphrase stops being worth brute-forcing against.
      // Refused before a single byte is derived.
      final weak = Uint8List.fromList(good);
      ByteData.view(weak.buffer)
        ..setUint32(9, 8)
        ..setUint32(13, 1);
      await expectLater(
        _open(weak, passphrase),
        throwsA(
          isA<BackupFormatException>().having(
            (e) => e.message,
            'message',
            contains('weaker protection'),
          ),
        ),
      );
    });

    test('a bogus salt length is refused', () async {
      final odd = Uint8List.fromList(good)..[19] = 200;
      await expectLater(
        _open(odd, passphrase),
        throwsA(isA<BackupFormatException>()),
      );
    });
  });
}
