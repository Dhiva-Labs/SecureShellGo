import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// AES in OCB mode, version 3 (RFC 7253) — the authenticated cipher every
/// Mosh datagram is sealed with.
///
/// Mosh uses it as AES-128 with a 96-bit nonce and a 128-bit tag and no
/// associated data, but this follows the RFC in full (any AES key size, any
/// nonce up to 120 bits, tags of 64 to 128 bits, associated data) so that it
/// can be checked against every vector in RFC 7253's Appendix A rather than
/// only the subset Mosh happens to exercise.
///
/// pointycastle supplies the block cipher; nothing here allocates per block
/// beyond the output, which matters because a busy screen means hundreds of
/// datagrams a second.
class AesOcb {
  AesOcb(Uint8List key, {this.tagLength = 16})
      : _encipher = AESEngine()..init(true, KeyParameter(key)),
        _decipher = AESEngine()..init(false, KeyParameter(key)) {
    if (key.length != 16 && key.length != 24 && key.length != 32) {
      throw ArgumentError.value(key.length, 'key', 'must be 16, 24 or 32 bytes');
    }
    if (tagLength < 8 || tagLength > 16) {
      throw ArgumentError.value(tagLength, 'tagLength', 'must be 8..16 bytes');
    }
    _lStar = Uint8List(16);
    _encipher.processBlock(Uint8List(16), 0, _lStar, 0);
    _lDollar = _double(_lStar);
    _l.add(_double(_lDollar));
  }

  /// Bytes of tag appended to every ciphertext.
  final int tagLength;

  final AESEngine _encipher;
  final AESEngine _decipher;
  late final Uint8List _lStar;
  late final Uint8List _lDollar;
  final List<Uint8List> _l = [];

  /// The ciphertext of [plaintext] with its tag appended.
  Uint8List encrypt(Uint8List nonce, Uint8List plaintext,
      {Uint8List? associatedData}) {
    final out = Uint8List(plaintext.length + tagLength);
    final tag = _crypt(
      nonce,
      plaintext,
      out,
      associatedData: associatedData,
      encrypting: true,
    );
    out.setRange(plaintext.length, out.length, tag);
    return out;
  }

  /// The plaintext inside [ciphertext], or null when its tag does not verify —
  /// a forged, corrupted or replayed-under-another-key datagram.
  Uint8List? decrypt(Uint8List nonce, Uint8List ciphertext,
      {Uint8List? associatedData}) {
    if (ciphertext.length < tagLength) return null;
    final bodyLength = ciphertext.length - tagLength;
    final out = Uint8List(bodyLength);
    final tag = _crypt(
      nonce,
      Uint8List.sublistView(ciphertext, 0, bodyLength),
      out,
      associatedData: associatedData,
      encrypting: false,
    );
    // Constant time, so the comparison says nothing about how close a forgery
    // came.
    var difference = 0;
    for (var i = 0; i < tagLength; i++) {
      difference |= tag[i] ^ ciphertext[bodyLength + i];
    }
    return difference == 0 ? out : null;
  }

  /// Runs OCB over [input] into [output] and returns the full 16-byte tag
  /// (the caller keeps the first [tagLength] bytes of it).
  Uint8List _crypt(
    Uint8List nonce,
    Uint8List input,
    Uint8List output, {
    required bool encrypting,
    Uint8List? associatedData,
  }) {
    if (nonce.isEmpty || nonce.length > 15) {
      throw ArgumentError.value(nonce.length, 'nonce', 'must be 1..15 bytes');
    }
    final offset = _initialOffset(nonce);
    final checksum = Uint8List(16);
    final block = Uint8List(16);
    final full = input.length ~/ 16;

    for (var i = 1; i <= full; i++) {
      _xorInto(offset, _lAt(_ntz(i)));
      final start = (i - 1) * 16;
      for (var j = 0; j < 16; j++) {
        block[j] = input[start + j] ^ offset[j];
      }
      if (encrypting) {
        for (var j = 0; j < 16; j++) {
          checksum[j] ^= input[start + j];
        }
        _encipher.processBlock(block, 0, block, 0);
      } else {
        _decipher.processBlock(block, 0, block, 0);
      }
      for (var j = 0; j < 16; j++) {
        output[start + j] = block[j] ^ offset[j];
      }
      if (!encrypting) {
        for (var j = 0; j < 16; j++) {
          checksum[j] ^= output[start + j];
        }
      }
    }

    final rest = input.length - full * 16;
    if (rest > 0) {
      _xorInto(offset, _lStar);
      final pad = Uint8List(16);
      _encipher.processBlock(offset, 0, pad, 0);
      final start = full * 16;
      for (var j = 0; j < rest; j++) {
        output[start + j] = input[start + j] ^ pad[j];
      }
      final plain = encrypting ? input : output;
      for (var j = 0; j < rest; j++) {
        checksum[j] ^= plain[start + j];
      }
      checksum[rest] ^= 0x80;
    }

    for (var j = 0; j < 16; j++) {
      block[j] = checksum[j] ^ offset[j] ^ _lDollar[j];
    }
    final tag = Uint8List(16);
    _encipher.processBlock(block, 0, tag, 0);
    _xorInto(tag, _hash(associatedData));
    return tag;
  }

  /// Offset_0 for [nonce]: the stretch-then-shift of RFC 7253 §4.2.
  Uint8List _initialOffset(Uint8List nonce) {
    final full = Uint8List(16);
    full[0] = ((tagLength * 8) % 128) << 1;
    full[15 - nonce.length] |= 0x01;
    full.setRange(16 - nonce.length, 16, nonce);
    final bottom = full[15] & 0x3f;
    full[15] &= 0xc0;
    final ktop = Uint8List(16);
    _encipher.processBlock(full, 0, ktop, 0);
    final stretch = Uint8List(24)..setRange(0, 16, ktop);
    for (var i = 0; i < 8; i++) {
      stretch[16 + i] = ktop[i] ^ ktop[i + 1];
    }
    // Offset_0 = Stretch[1+bottom .. 128+bottom], a bit-granular window.
    final byteShift = bottom ~/ 8;
    final bitShift = bottom % 8;
    final offset = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      final high = stretch[i + byteShift];
      final low = stretch[i + byteShift + 1];
      offset[i] = bitShift == 0
          ? high
          : ((high << bitShift) | (low >> (8 - bitShift))) & 0xff;
    }
    return offset;
  }

  /// HASH(K, A) of RFC 7253 §4.1; zeros for absent or empty data.
  Uint8List _hash(Uint8List? data) {
    final sum = Uint8List(16);
    if (data == null || data.isEmpty) return sum;
    final offset = Uint8List(16);
    final block = Uint8List(16);
    final full = data.length ~/ 16;
    for (var i = 1; i <= full; i++) {
      _xorInto(offset, _lAt(_ntz(i)));
      final start = (i - 1) * 16;
      for (var j = 0; j < 16; j++) {
        block[j] = data[start + j] ^ offset[j];
      }
      _encipher.processBlock(block, 0, block, 0);
      _xorInto(sum, block);
    }
    final rest = data.length - full * 16;
    if (rest > 0) {
      _xorInto(offset, _lStar);
      block.fillRange(0, 16, 0);
      block.setRange(0, rest, data, full * 16);
      block[rest] = 0x80;
      _xorInto(block, offset);
      _encipher.processBlock(block, 0, block, 0);
      _xorInto(sum, block);
    }
    return sum;
  }

  Uint8List _lAt(int i) {
    while (_l.length <= i) {
      _l.add(_double(_l.last));
    }
    return _l[i];
  }

  /// Multiplication by x in GF(2^128), as RFC 7253 §2 defines `double`.
  static Uint8List _double(Uint8List s) {
    final out = Uint8List(16);
    for (var i = 0; i < 15; i++) {
      out[i] = ((s[i] << 1) | (s[i + 1] >> 7)) & 0xff;
    }
    out[15] = (s[15] << 1) & 0xff;
    if (s[0] & 0x80 != 0) out[15] ^= 0x87;
    return out;
  }

  static int _ntz(int i) {
    var n = 0;
    while (i & 1 == 0) {
      i >>= 1;
      n++;
    }
    return n;
  }

  static void _xorInto(Uint8List target, Uint8List other) {
    for (var j = 0; j < 16; j++) {
      target[j] ^= other[j];
    }
  }
}
