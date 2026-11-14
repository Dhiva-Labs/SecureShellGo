/// The two password schemes RFB servers ask for: classic VNC
/// authentication (DES) and Apple Remote Desktop's (Diffie-Hellman, then
/// AES-128), which is what a Mac's Screen Sharing offers for its macOS
/// accounts.
///
/// Both are weak by today's standards: VNC authentication uses 8 bytes of
/// password and single DES, and Apple's has no protection against a man in
/// the middle. That is acceptable here only because the connection runs
/// inside the SSH channel, which is what actually protects it; neither is
/// ever used over a bare network by this app.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/api.dart' show KeyParameter;
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/des_base.dart';
import 'package:pointycastle/digests/md5.dart';

import 'rfb_protocol.dart';

/// Which credentials the server asked for.
enum RfbAuthKind {
  /// A VNC password only. At most 8 bytes of it count.
  vncPassword,

  /// A macOS account's user name and password, for Apple Remote Desktop
  /// authentication (Screen Sharing's usual login).
  appleAccount,
}

/// Asks the person for credentials; null means they cancelled.
typedef RfbCredentialsCallback =
    Future<({String? username, String password})?> Function(RfbAuthKind kind);

/// The 16-byte answer to a VNC authentication [challenge].
///
/// The key is the password's first 8 bytes (UTF-8, zero-padded), each with
/// its bits reversed: the original VNC code fed DES a key in the opposite
/// bit order to the standard's, and every server since expects the same.
Uint8List rfbVncAuthResponse(String password, Uint8List challenge) {
  if (challenge.length != 16) {
    throw ArgumentError.value(challenge.length, 'challenge', 'must be 16');
  }
  final pw = utf8.encode(password);
  final key = Uint8List(8);
  for (var i = 0; i < 8 && i < pw.length; i++) {
    key[i] = _reverseBits(pw[i]);
  }
  final des = DesBase();
  final working = des.generateWorkingKey(true, key);
  final out = Uint8List(16);
  des.desFunc(working, challenge, 0, out, 0);
  des.desFunc(working, challenge, 8, out, 8);
  return out;
}

int _reverseBits(int b) {
  var r = 0;
  for (var i = 0; i < 8; i++) {
    r = (r << 1) | ((b >> i) & 1);
  }
  return r;
}

/// What the client sends for Apple Remote Desktop authentication.
class RfbArdResponse {
  const RfbArdResponse(this.ciphertext, this.publicKey);

  /// 128 bytes: the encrypted user name and password.
  final Uint8List ciphertext;

  /// This side's Diffie-Hellman public key, as long as the server's.
  final Uint8List publicKey;

  /// Both, in the order they go on the wire.
  Uint8List get wire => Uint8List(ciphertext.length + publicKey.length)
    ..setRange(0, ciphertext.length, ciphertext)
    ..setRange(
      ciphertext.length,
      ciphertext.length + publicKey.length,
      publicKey,
    );
}

/// Answers Apple Remote Desktop (security type 30) authentication.
///
/// The server sends a Diffie-Hellman [generator], [prime] and its public
/// key; this side makes its own key pair, takes the MD5 of the shared
/// secret as an AES-128 key, and encrypts 128 bytes under it in ECB mode:
/// the user name in the first 64 and the password in the last 64, each
/// NUL-terminated (so at most 63 UTF-8 bytes of each) and the rest random.
///
/// [privateKey] and [padding] are for tests, which need fixed values to
/// compare against a reference; leave them out otherwise.
///
/// Throws [RfbProtocolException] for parameters no honest server sends: a
/// key length out of range, a prime too small, a public key outside
/// 2 … p − 2 (which would make the shared secret guessable).
RfbArdResponse rfbArdResponse({
  required int generator,
  required Uint8List prime,
  required Uint8List serverPublicKey,
  required String username,
  required String password,
  Random? random,
  BigInt? privateKey,
  Uint8List? padding,
}) {
  final keyLength = prime.length;
  if (keyLength == 0 || keyLength > rfbMaxDhKeyBytes) {
    throw RfbProtocolException('Diffie-Hellman key length $keyLength');
  }
  if (serverPublicKey.length != keyLength) {
    throw const RfbProtocolException(
      'Diffie-Hellman public key is not the prime’s length',
    );
  }
  final p = _bigFromBytes(prime);
  final g = BigInt.from(generator);
  final y = _bigFromBytes(serverPublicKey);
  if (p.bitLength < 64 || p.isEven) {
    throw const RfbProtocolException('Diffie-Hellman prime is not usable');
  }
  if (g < BigInt.two || g >= p - BigInt.one) {
    throw const RfbProtocolException('Diffie-Hellman generator is not usable');
  }
  if (y < BigInt.two || y > p - BigInt.two) {
    throw const RfbProtocolException(
      'Diffie-Hellman public key is out of range',
    );
  }
  final rng = random ?? Random.secure();
  // 512 bits of exponent is past the strength of any group Apple uses, and
  // keeps a 4096-bit modPow from taking a second on a phone.
  final x = privateKey ?? _randomExponent(p, rng, min(p.bitLength - 2, 512));
  final ours = g.modPow(x, p);
  final shared = y.modPow(x, p);
  final aesKey = MD5Digest().process(_bigToBytes(shared, keyLength));

  final plain = padding != null && padding.length == 128
      ? Uint8List.fromList(padding)
      : Uint8List.fromList(List.generate(128, (_) => rng.nextInt(256)));
  _putCString(plain, 0, username);
  _putCString(plain, 64, password);

  final aes = AESEngine()..init(true, KeyParameter(aesKey));
  final cipher = Uint8List(128);
  for (var off = 0; off < 128; off += 16) {
    aes.processBlock(plain, off, cipher, off);
  }
  return RfbArdResponse(cipher, _bigToBytes(ours, keyLength));
}

/// [text] as UTF-8 at [at], cut on a character boundary to leave room for
/// its NUL inside the 64-byte field.
void _putCString(Uint8List out, int at, String text) {
  final bytes = utf8.encode(text);
  var n = bytes.length < 63 ? bytes.length : 63;
  while (n > 0 && n < bytes.length && (bytes[n] & 0xc0) == 0x80) {
    n--;
  }
  out.setRange(at, at + n, bytes);
  out[at + n] = 0;
}

BigInt _randomExponent(BigInt p, Random rng, int bits) {
  final bytes = Uint8List((bits + 7) ~/ 8);
  BigInt x;
  do {
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = rng.nextInt(256);
    }
    x = _bigFromBytes(bytes) % (p - BigInt.two);
  } while (x < BigInt.two);
  return x;
}

BigInt _bigFromBytes(Uint8List bytes) {
  var v = BigInt.zero;
  for (final b in bytes) {
    v = (v << 8) | BigInt.from(b);
  }
  return v;
}

/// Big-endian, left-padded with zeros to [length] bytes, as Apple's server
/// and libvncclient both lay the numbers out.
Uint8List _bigToBytes(BigInt v, int length) {
  final out = Uint8List(length);
  var x = v;
  final mask = BigInt.from(0xff);
  for (var i = length - 1; i >= 0 && x > BigInt.zero; i--) {
    out[i] = (x & mask).toInt();
    x >>= 8;
  }
  return out;
}
