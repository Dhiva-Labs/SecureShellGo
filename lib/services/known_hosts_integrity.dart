import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'secure_storage_backend.dart';

/// Result of verifying an on-disk known-hosts envelope.
enum IntegrityVerdict {
  /// The envelope carried a MAC and it matched.
  verified,

  /// A pre-integrity (version 1) file, and this device has never written a
  /// protected one — a genuine first-run upgrade, so the contents are adopted
  /// and re-written under a MAC.
  legacyMigrated,

  /// The MAC was missing, malformed or wrong. Callers must fail closed.
  tampered,
}

/// The outcome of reading an envelope: the payload, and why it was accepted.
class IntegrityCheck {
  const IntegrityCheck(this.verdict, [this.payload]);

  final IntegrityVerdict verdict;

  /// The decoded body, or null when [verdict] is [IntegrityVerdict.tampered].
  final Map<String, dynamic>? payload;

  bool get isTrustworthy => verdict != IntegrityVerdict.tampered;
}

/// Supplies (and lazily creates) the key that authenticates known_hosts.json.
///
/// The key lives in the Keystore-backed secure store; the MAC it produces
/// travels inside the JSON file itself. Fingerprints are public data, so
/// confidentiality was never the concern — *integrity* is. Anyone who can
/// rewrite the file inside the app sandbox can otherwise silence the MITM
/// warning; without the key they cannot produce an envelope this app accepts.
class KnownHostsIntegrityKey {
  KnownHostsIntegrityKey(this._backend, {Random? random})
      : _random = random ?? Random.secure();

  static const String storageKey = 'known_hosts:hmac_key_v1';
  static const int keyLengthBytes = 32;

  final SecureStorageBackend _backend;
  final Random _random;

  Uint8List? _cached;

  /// Whether a key has ever been established on this device.
  ///
  /// A version-1 (unauthenticated) file is only trusted when this is false.
  /// Once a key exists, an unauthenticated file can only mean the envelope was
  /// stripped, which is a downgrade attack and must fail closed.
  Future<bool> exists() async {
    if (_cached != null) return true;
    final raw = await _backend.read(storageKey);
    return raw != null && raw.isNotEmpty;
  }

  /// The device key, creating and persisting one on first use.
  Future<Uint8List> obtain() async {
    final cached = _cached;
    if (cached != null) return cached;

    final raw = await _backend.read(storageKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = base64Decode(raw);
        if (decoded.length == keyLengthBytes) {
          return _cached = Uint8List.fromList(decoded);
        }
      } catch (_) {
        // Fall through and mint a fresh key. A key we cannot decode is no key
        // at all; the file it authenticated will fail verification and the
        // store will fail closed, which is the safe direction.
      }
    }

    final fresh = Uint8List.fromList(
      List<int>.generate(keyLengthBytes, (_) => _random.nextInt(256)),
    );
    await _backend.write(storageKey, base64Encode(fresh));
    return _cached = fresh;
  }

  /// Drops the key. Any existing file stops verifying, so the store fails
  /// closed and every host is re-prompted.
  Future<void> reset() async {
    _cached = null;
    await _backend.delete(storageKey);
  }
}

/// Wraps/unwraps the authenticated envelope written to known_hosts.json.
///
/// ```json
/// {"version":2,"algorithm":"HmacSHA256","mac":"<base64>","payload":"<json>"}
/// ```
///
/// The body is embedded as an opaque *string*, not a nested object, so the
/// bytes that were signed are exactly the bytes that are verified. Re-encoding
/// a decoded map would make the MAC depend on key ordering and number
/// formatting, which is precisely the kind of ambiguity that turns an
/// integrity check into a coin flip.
class KnownHostsEnvelope {
  const KnownHostsEnvelope._();

  static const int version = 2;
  static const String algorithm = 'HmacSHA256';

  static String macOf(Uint8List key, String payload) {
    final mac = Hmac(sha256, key).convert(utf8.encode(payload));
    return base64Encode(mac.bytes);
  }

  /// Serialises [payload] under [key].
  static String seal(Uint8List key, Map<String, dynamic> payload) {
    final body = jsonEncode(payload);
    return jsonEncode(<String, dynamic>{
      'version': version,
      'algorithm': algorithm,
      'mac': macOf(key, body),
      'payload': body,
    });
  }

  /// Verifies and decodes [raw].
  ///
  /// [key] is null when integrity protection is switched off (tests, and the
  /// Phase 1/2 constructor shape), in which case a plain version-1 document is
  /// simply decoded.
  ///
  /// [keyEverEstablished] gates the legacy path: a version-1 document is only
  /// adopted on a device that has never written a protected one.
  static IntegrityCheck open(
    String raw, {
    Uint8List? key,
    bool keyEverEstablished = false,
  }) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return const IntegrityCheck(IntegrityVerdict.tampered);
    }
    if (decoded is! Map<String, dynamic>) {
      return const IntegrityCheck(IntegrityVerdict.tampered);
    }

    final payloadText = decoded['payload'];
    final mac = decoded['mac'];

    if (payloadText is! String || mac is! String) {
      // No envelope. Either integrity is off, or this is a pre-Phase-3 file.
      if (key == null || !keyEverEstablished) {
        return IntegrityCheck(
          key == null ? IntegrityVerdict.verified : IntegrityVerdict.legacyMigrated,
          decoded,
        );
      }
      return const IntegrityCheck(IntegrityVerdict.tampered);
    }

    if (key == null) {
      // Integrity was switched off but the file is sealed; decode the body
      // without checking, rather than losing the user's trusted keys.
      return IntegrityCheck(IntegrityVerdict.verified, _decodeBody(payloadText));
    }

    if (!_constantTimeEquals(macOf(key, payloadText), mac)) {
      return const IntegrityCheck(IntegrityVerdict.tampered);
    }

    final body = _decodeBody(payloadText);
    if (body == null) return const IntegrityCheck(IntegrityVerdict.tampered);
    return IntegrityCheck(IntegrityVerdict.verified, body);
  }

  static Map<String, dynamic>? _decodeBody(String payload) {
    try {
      final body = jsonDecode(payload);
      return body is Map<String, dynamic> ? body : null;
    } catch (_) {
      return null;
    }
  }

  /// Compares without an early exit, so a wrong MAC leaks no timing signal
  /// about how much of it was right.
  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
