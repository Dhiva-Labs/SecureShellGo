import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/api.dart' show KeyParameter;
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/digests/md5.dart';
import 'package:secure_shell_go/services/remote_desktop/rfb_auth.dart';
import 'package:secure_shell_go/services/remote_desktop/rfb_protocol.dart';

Uint8List hex(String s) => Uint8List.fromList([
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
]);

String toHex(List<int> b) =>
    b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();

/// RFC 2409's 1024-bit MODP group (Oakley group 2), generator 2.
final oakley2 = hex(
  'FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA6'
  '3B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245'
  'E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F2411'
  '7C4B1FE649286651ECE65381FFFFFFFFFFFFFFFF',
);

BigInt big(Uint8List b) =>
    b.fold(BigInt.zero, (v, x) => (v << 8) | BigInt.from(x));

Uint8List bytesOf(BigInt v, int n) {
  final out = Uint8List(n);
  for (var i = n - 1; i >= 0; i--) {
    out[i] = (v & BigInt.from(0xff)).toInt();
    v >>= 8;
  }
  return out;
}

void main() {
  group('VNC authentication', () {
    // Known answers from OpenSSL (`openssl enc -des-ecb -nopad` with the
    // bit-reversed key, legacy provider) and Python's cryptography, which
    // agree.
    test('matches the DES answer computed outside Dart', () {
      expect(
        toHex(
          rfbVncAuthResponse(
            'password',
            Uint8List.fromList(List.generate(16, (i) => i)),
          ),
        ),
        'b866924125c8eebb9debc1db61c538e2',
      );
      final challenge = hex('0b30557a9fc4e90e33587da2c7ec1136');
      // Only 8 bytes of a password count…
      expect(
        toHex(rfbVncAuthResponse('secretpass', challenge)),
        '2d8a8dc5c14cf05512b4a178a0e98f45',
      );
      expect(
        toHex(rfbVncAuthResponse('secretpa', challenge)),
        '2d8a8dc5c14cf05512b4a178a0e98f45',
      );
      // …and a short one is padded with zeros.
      expect(
        toHex(rfbVncAuthResponse('abc', challenge)),
        '2de699b7a1b935be72759f4a14a1aefc',
      );
    });

    test('wants a 16-byte challenge', () {
      expect(() => rfbVncAuthResponse('x', Uint8List(8)), throwsArgumentError);
    });
  });

  group('Apple Remote Desktop', () {
    // Server private key and the expected values were computed with
    // Python (pow, hashlib.md5, cryptography's AES-ECB): see the commit
    // that added this test.
    final serverPrivate = big(hex('1234567890abcdef' * 8)) % big(oakley2);
    final clientPrivate = big(hex('fedcba0987654321' * 4));
    final padding = Uint8List.fromList(
      List.generate(128, (i) => (i * 7 + 3) & 0xff),
    );

    test('matches a reference computed outside Dart', () {
      final serverPublic = BigInt.two.modPow(serverPrivate, big(oakley2));
      expect(
        toHex(bytesOf(serverPublic, 128)),
        startsWith('cd76afa624775fd8ebe1764ae8a676fc'),
      );
      final r = rfbArdResponse(
        generator: 2,
        prime: oakley2,
        serverPublicKey: bytesOf(serverPublic, 128),
        username: 'dhiva',
        password: 'pässwörd',
        privateKey: clientPrivate,
        padding: padding,
      );
      expect(
        toHex(r.publicKey),
        '29e55275466077e02c6d3ab9fd4c57dc9da2442566088a70294f92bdd02460c8'
        'c1ec4137800d8bcf9b9a9ec4d048f88804a7523ce92aefe416a396eb16ffcb6d'
        'e0e3904328caf0f8c0b01745dc8ea47f863c9fde3f019e5a0376e1389f642a7f'
        '1d32c03149e40311ccde9274e2e22f72abe32ae557630a17f5ace2a1f1f12b5e',
      );
      expect(
        toHex(r.ciphertext),
        '4dfae4562c0446aee3ab0354d27037c3d137a061aa224b7c3c39b1fefac22124'
        '7b57e4fffdc9ad5de7aed5ace67a17f05900de0b8e1c58a2137b33cc7be20859'
        'ef8d44d1d5999104ce6a28eb3cf072501523ab86b929b141ab9e2b230aef09b4'
        '74dad5f4e71c68641223751988c298f2043d82b56b605875d44d7bf81a1bdb5d',
      );
      // Ciphertext first, then the key.
      expect(r.wire.length, 256);
      expect(toHex(r.wire.sublist(0, 4)), '4dfae456');
      expect(toHex(r.wire.sublist(128, 132)), '29e55275');
    });

    test('a server decrypts what a random key pair sends', () {
      final p = big(oakley2);
      final serverPublic = BigInt.two.modPow(serverPrivate, p);
      final r = rfbArdResponse(
        generator: 2,
        prime: oakley2,
        serverPublicKey: bytesOf(serverPublic, 128),
        username: 'a-very-long-user-name-' * 4,
        password: 'pw',
      );
      final shared = big(r.publicKey).modPow(serverPrivate, p);
      final key = MD5Digest().process(bytesOf(shared, 128));
      final aes = AESEngine()..init(false, KeyParameter(key));
      final plain = Uint8List(128);
      for (var i = 0; i < 128; i += 16) {
        aes.processBlock(r.ciphertext, i, plain, i);
      }
      String field(int at) {
        final end = plain.indexOf(0, at);
        expect(end, lessThan(at + 64));
        return utf8.decode(plain.sublist(at, end));
      }

      // Cut to 63 bytes, so the NUL fits in the field.
      expect(field(0), ('a-very-long-user-name-' * 4).substring(0, 63));
      expect(field(64), 'pw');
    });

    test('a long UTF-8 name is cut on a character boundary', () {
      final p = big(oakley2);
      final serverPublic = BigInt.two.modPow(serverPrivate, p);
      // 80 bytes; the 63rd is the second half of the 32nd é.
      final name = 'é' * 40;
      final r = rfbArdResponse(
        generator: 2,
        prime: oakley2,
        serverPublicKey: bytesOf(serverPublic, 128),
        username: name,
        password: '',
        privateKey: clientPrivate,
        padding: padding,
      );
      final shared = big(r.publicKey).modPow(serverPrivate, p);
      final aes = AESEngine()
        ..init(false, KeyParameter(MD5Digest().process(bytesOf(shared, 128))));
      final plain = Uint8List(128);
      for (var i = 0; i < 128; i += 16) {
        aes.processBlock(r.ciphertext, i, plain, i);
      }
      final end = plain.indexOf(0);
      expect(end, 62);
      expect(utf8.decode(plain.sublist(0, end)), 'é' * 31);
      expect(plain[64], 0);
    });

    test('refuses parameters no honest server sends', () {
      final p = big(oakley2);
      final good = bytesOf(BigInt.two.modPow(serverPrivate, p), 128);
      RfbArdResponse with_({
        int generator = 2,
        Uint8List? prime,
        Uint8List? key,
      }) => rfbArdResponse(
        generator: generator,
        prime: prime ?? oakley2,
        serverPublicKey: key ?? good,
        username: 'u',
        password: 'p',
      );
      final bad = throwsA(isA<RfbProtocolException>());
      expect(() => with_(key: bytesOf(BigInt.one, 128)), bad);
      expect(() => with_(key: bytesOf(BigInt.zero, 128)), bad);
      expect(() => with_(key: bytesOf(p - BigInt.one, 128)), bad);
      expect(() => with_(key: Uint8List(64)), bad);
      expect(() => with_(generator: 1), bad);
      expect(() => with_(generator: 0), bad);
      expect(() => with_(prime: Uint8List(600), key: Uint8List(600)), bad);
      expect(() => with_(prime: Uint8List(0), key: Uint8List(0)), bad);
      // An even "prime".
      final even = Uint8List.fromList(oakley2)..[127] = 0xfe;
      expect(() => with_(prime: even), bad);
    });
  });
}
