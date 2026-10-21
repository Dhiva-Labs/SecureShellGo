import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/mosh/ocb.dart';

/// RFC 7253 Appendix A, verbatim.
void main() {
  Uint8List hex(String s) {
    final clean = s.replaceAll(RegExp(r'\s'), '');
    return Uint8List.fromList([
      for (var i = 0; i < clean.length; i += 2)
        int.parse(clean.substring(i, i + 2), radix: 16),
    ]);
  }

  String toHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();

  // (N, A, P, C) with K = 000102...0F and a 128-bit tag.
  const vectors = [
    ['BBAA99887766554433221100', '', '', '785407BFFFC8AD9EDCC5520AC9111EE6'],
    [
      'BBAA99887766554433221101', '0001020304050607', '0001020304050607',
      '6820B3657B6F615A5725BDA0D3B4EB3A257C9AF1F8F03009',
    ],
    [
      'BBAA99887766554433221102', '0001020304050607', '',
      '81017F8203F081277152FADE694A0A00',
    ],
    [
      'BBAA99887766554433221103', '', '0001020304050607',
      '45DD69F8F5AAE72414054CD1F35D82760B2CD00D2F99BFA9',
    ],
    [
      'BBAA99887766554433221104', '000102030405060708090A0B0C0D0E0F',
      '000102030405060708090A0B0C0D0E0F',
      '571D535B60B277188BE5147170A9A22C3AD7A4FF3835B8C5701C1CCEC8FC3358',
    ],
    [
      'BBAA99887766554433221105', '000102030405060708090A0B0C0D0E0F', '',
      '8CF761B6902EF764462AD86498CA6B97',
    ],
    [
      'BBAA99887766554433221106', '', '000102030405060708090A0B0C0D0E0F',
      '5CE88EC2E0692706A915C00AEB8B2396F40E1C743F52436BDF06D8FA1ECA343D',
    ],
    [
      'BBAA99887766554433221107',
      '000102030405060708090A0B0C0D0E0F1011121314151617',
      '000102030405060708090A0B0C0D0E0F1011121314151617',
      '1CA2207308C87C010756104D8840CE1952F09673A448A122'
          'C92C62241051F57356D7F3C90BB0E07F',
    ],
    [
      'BBAA99887766554433221108',
      '000102030405060708090A0B0C0D0E0F1011121314151617', '',
      '6DC225A071FC1B9F7C69F93B0F1E10DE',
    ],
    [
      'BBAA99887766554433221109', '',
      '000102030405060708090A0B0C0D0E0F1011121314151617',
      '221BD0DE7FA6FE993ECCD769460A0AF2D6CDED0C395B1C3C'
          'E725F32494B9F914D85C0B1EB38357FF',
    ],
    [
      'BBAA9988776655443322110A',
      '000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F',
      '000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F',
      'BD6F6C496201C69296C11EFD138A467ABD3C707924B964DE'
          'AFFC40319AF5A48540FBBA186C5553C68AD9F592A79A4240',
    ],
    [
      'BBAA9988776655443322110B',
      '000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F', '',
      'FE80690BEE8A485D11F32965BC9D2A32',
    ],
    [
      'BBAA9988776655443322110C', '',
      '000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F',
      '2942BFC773BDA23CABC6ACFD9BFD5835BD300F0973792EF4'
          '6040C53F1432BCDFB5E1DDE3BC18A5F840B52E653444D5DF',
    ],
    [
      'BBAA9988776655443322110D',
      '000102030405060708090A0B0C0D0E0F1011121314151617'
          '18191A1B1C1D1E1F2021222324252627',
      '000102030405060708090A0B0C0D0E0F1011121314151617'
          '18191A1B1C1D1E1F2021222324252627',
      'D5CA91748410C1751FF8A2F618255B68A0A12E093FF45460'
          '6E59F9C1D0DDC54B65E8628E568BAD7AED07BA06A4A69483'
          'A7035490C5769E60',
    ],
    [
      'BBAA9988776655443322110E',
      '000102030405060708090A0B0C0D0E0F1011121314151617'
          '18191A1B1C1D1E1F2021222324252627',
      '',
      'C5CD9D1850C141E358649994EE701B68',
    ],
    [
      'BBAA9988776655443322110F', '',
      '000102030405060708090A0B0C0D0E0F1011121314151617'
          '18191A1B1C1D1E1F2021222324252627',
      '4412923493C57D5DE0D700F753CCE0D1D2D95060122E9F15'
          'A5DDBFC5787E50B5CC55EE507BCB084E479AD363AC366B95'
          'A98CA5F3000B1479',
    ],
  ];

  final key = hex('000102030405060708090A0B0C0D0E0F');

  group('RFC 7253 sample results', () {
    for (final v in vectors) {
      final nonce = hex(v[0]);
      final associated = hex(v[1]);
      final plain = hex(v[2]);
      final expected = v[3];

      test('N=${v[0]} encrypts', () {
        final ocb = AesOcb(key);
        expect(toHex(ocb.encrypt(nonce, plain, associatedData: associated)),
            expected);
      });

      test('N=${v[0]} decrypts, and refuses any flipped bit', () {
        final ocb = AesOcb(key);
        final sealed = hex(expected);
        expect(ocb.decrypt(nonce, sealed, associatedData: associated), plain);
        for (var i = 0; i < sealed.length; i++) {
          final forged = Uint8List.fromList(sealed)..[i] ^= 0x01;
          expect(ocb.decrypt(nonce, forged, associatedData: associated),
              isNull,
              reason: 'byte $i flipped');
        }
      });
    }
  });

  test('a 96-bit tag under a different key', () {
    final ocb = AesOcb(hex('0F0E0D0C0B0A09080706050403020100'), tagLength: 12);
    final data = hex('000102030405060708090A0B0C0D0E0F1011121314151617'
        '18191A1B1C1D1E1F2021222324252627');
    final sealed = ocb.encrypt(hex('BBAA9988776655443322110D'), data,
        associatedData: data);
    expect(
      toHex(sealed),
      '1792A4E31E0755FB03E31B22116E6C2DDF9EFD6E33D536F1'
      'A0124B0A55BAE884ED93481529C76B6AD0C515F4D1CDD4FD'
      'AC4F02AA',
    );
    expect(
      ocb.decrypt(hex('BBAA9988776655443322110D'), sealed,
          associatedData: data),
      data,
    );
  });

  group('the iterative test over 0..127-byte inputs', () {
    Uint8List num2str(int value, int bytes) {
      final out = Uint8List(bytes);
      for (var i = bytes - 1; i >= 0 && value > 0; i--) {
        out[i] = value & 0xff;
        value >>= 8;
      }
      return out;
    }

    String run(int keyBytes, int tagBits) {
      final k = Uint8List(keyBytes)..[keyBytes - 1] = tagBits;
      final ocb = AesOcb(k, tagLength: tagBits ~/ 8);
      final c = BytesBuilder();
      for (var i = 0; i < 128; i++) {
        final s = Uint8List(i);
        c.add(ocb.encrypt(num2str(3 * i + 1, 12), s, associatedData: s));
        c.add(ocb.encrypt(num2str(3 * i + 2, 12), s));
        c.add(ocb.encrypt(num2str(3 * i + 3, 12), Uint8List(0),
            associatedData: s));
      }
      return toHex(ocb.encrypt(num2str(385, 12), Uint8List(0),
          associatedData: c.toBytes()));
    }

    test('AES-128, 128-bit tag', () {
      expect(run(16, 128), '67E944D23256C5E0B6C61FA22FDF1EA2');
    });
    test('AES-192, 128-bit tag', () {
      expect(run(24, 128), 'F673F2C3E7174AAE7BAE986CA9F29E17');
    });
    test('AES-256, 128-bit tag', () {
      expect(run(32, 128), 'D90EB8E9C977C88B79DD793D7FFA161C');
    });
    test('AES-128, 96-bit tag', () {
      expect(run(16, 96), '77A3D8E73589158D25D01209');
    });
    test('AES-192, 96-bit tag', () {
      expect(run(24, 96), '05D56EAD2752C86BE6932C5E');
    });
    test('AES-256, 96-bit tag', () {
      expect(run(32, 96), '5458359AC23B0CBA9E6330DD');
    });
    test('AES-128, 64-bit tag', () {
      expect(run(16, 64), '192C9B7BD90BA06A');
    });
  });
}
