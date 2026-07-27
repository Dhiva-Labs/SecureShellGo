import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/known_host.dart';
import 'package:secure_shell_go/services/known_hosts_integrity.dart';
import 'package:secure_shell_go/services/known_hosts_service.dart';
import 'package:secure_shell_go/services/secure_storage_backend.dart';

/// In-memory stand-in for the Keystore-backed backend, as in
/// `credential_store_test.dart`.
class FakeSecureStorageBackend implements SecureStorageBackend {
  final Map<String, String> data = {};

  @override
  Future<void> write(String key, String value) async {
    data[key] = value;
  }

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> delete(String key) async {
    data.remove(key);
  }
}

void main() {
  late Directory tempDir;
  late File storeFile;
  late FakeSecureStorageBackend backend;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('known_hosts_integrity');
    storeFile = File('${tempDir.path}/known_hosts.json');
    backend = FakeSecureStorageBackend();
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  KnownHostsIntegrityKey newKey() =>
      KnownHostsIntegrityKey(backend, random: Random(1));

  KnownHostKey hostKey({
    String hostname = 'example.com',
    String fingerprint = 'SHA256:AAAA',
  }) =>
      KnownHostKey(
        hostname: hostname,
        port: 22,
        keyType: 'ssh-ed25519',
        fingerprint: fingerprint,
        addedAt: DateTime(2026, 1, 1),
      );

  group('KnownHostsIntegrityKey', () {
    test('mints a key on first use and reuses it after', () async {
      final key = newKey();
      expect(await key.exists(), isFalse);

      final first = await key.obtain();
      expect(first.length, KnownHostsIntegrityKey.keyLengthBytes);
      expect(await key.exists(), isTrue);

      // A fresh instance over the same storage must find the same key,
      // otherwise every app launch would invalidate the store.
      final second = await KnownHostsIntegrityKey(backend).obtain();
      expect(second, first);
    });

    test('an unreadable stored key is replaced rather than crashing', () async {
      backend.data[KnownHostsIntegrityKey.storageKey] = 'not base64 !!!';
      final key = await KnownHostsIntegrityKey(backend).obtain();
      expect(key.length, KnownHostsIntegrityKey.keyLengthBytes);
    });
  });

  group('KnownHostsEnvelope', () {
    test('seals and reopens a payload', () async {
      final key = await newKey().obtain();
      final sealed = KnownHostsEnvelope.seal(key, {'version': 1, 'hosts': {}});

      final check = KnownHostsEnvelope.open(
        sealed,
        key: key,
        keyEverEstablished: true,
      );
      expect(check.verdict, IntegrityVerdict.verified);
      expect(check.payload?['version'], 1);
    });

    test('a doctored payload no longer verifies', () async {
      final key = await newKey().obtain();
      final sealed = KnownHostsEnvelope.seal(key, {
        'version': 1,
        'hosts': {'a': 1},
      });

      final document = jsonDecode(sealed) as Map<String, dynamic>;
      document['payload'] = jsonEncode({'version': 1, 'hosts': <String, int>{}});

      final check = KnownHostsEnvelope.open(
        jsonEncode(document),
        key: key,
        keyEverEstablished: true,
      );
      expect(check.verdict, IntegrityVerdict.tampered);
      expect(check.isTrustworthy, isFalse);
    });

    test('a different device key does not verify', () async {
      final sealed = KnownHostsEnvelope.seal(
        await newKey().obtain(),
        {'version': 1, 'hosts': {}},
      );

      final otherBackend = FakeSecureStorageBackend();
      final otherKey =
          await KnownHostsIntegrityKey(otherBackend, random: Random(9)).obtain();

      final check = KnownHostsEnvelope.open(
        sealed,
        key: otherKey,
        keyEverEstablished: true,
      );
      expect(check.verdict, IntegrityVerdict.tampered);
    });

    test('an unsealed file is adopted once, before a key exists', () {
      final legacy = jsonEncode({'version': 1, 'hosts': <String, dynamic>{}});
      final check = KnownHostsEnvelope.open(
        legacy,
        key: zeroKey(),
        keyEverEstablished: false,
      );
      expect(check.verdict, IntegrityVerdict.legacyMigrated);
      expect(check.isTrustworthy, isTrue);
    });

    test('stripping the envelope after a key exists is a downgrade attack', () {
      final legacy = jsonEncode({'version': 1, 'hosts': <String, dynamic>{}});
      final check = KnownHostsEnvelope.open(
        legacy,
        key: zeroKey(),
        keyEverEstablished: true,
      );
      expect(check.verdict, IntegrityVerdict.tampered);
    });

    test('garbage does not verify', () {
      expect(
        KnownHostsEnvelope.open(
          'not json at all',
          key: zeroKey(),
          keyEverEstablished: true,
        ).verdict,
        IntegrityVerdict.tampered,
      );
    });
  });

  group('KnownHostsService with integrity', () {
    test('a trusted key round-trips through a sealed file', () async {
      final service = KnownHostsService(
        file: storeFile,
        integrityKey: newKey(),
      );
      await service.trust(hostKey());

      final document = jsonDecode(await storeFile.readAsString());
      expect(document, isA<Map<String, dynamic>>());
      expect((document as Map<String, dynamic>)['mac'], isA<String>());
      expect(document['algorithm'], 'HmacSHA256');

      final reloaded = KnownHostsService(
        file: storeFile,
        integrityKey: KnownHostsIntegrityKey(backend),
      );
      final found = await reloaded.lookup('example.com', 22, 'ssh-ed25519');
      expect(found?.fingerprint, 'SHA256:AAAA');
      expect(reloaded.integrityFailed, isFalse);
    });

    test('a tampered store fails closed, so the host is prompted again',
        () async {
      await KnownHostsService(file: storeFile, integrityKey: newKey())
          .trust(hostKey());

      // Swap in a forged fingerprint, the way an attacker silencing the MITM
      // warning would.
      final document =
          jsonDecode(await storeFile.readAsString()) as Map<String, dynamic>;
      final payload =
          jsonDecode(document['payload'] as String) as Map<String, dynamic>;
      final hosts = payload['hosts'] as Map<String, dynamic>;
      final entry = hosts.values.first as Map<String, dynamic>;
      entry['fingerprint'] = 'SHA256:ATTACKER';
      document['payload'] = jsonEncode(payload);
      await storeFile.writeAsString(jsonEncode(document));

      final reloaded = KnownHostsService(
        file: storeFile,
        integrityKey: KnownHostsIntegrityKey(backend),
      );
      expect(await reloaded.lookup('example.com', 22, 'ssh-ed25519'), isNull);
      expect(await reloaded.isHostKnown('example.com', 22), isFalse);
      expect(reloaded.integrityFailed, isTrue);
    });

    test('losing the device key fails closed rather than trusting blindly',
        () async {
      await KnownHostsService(file: storeFile, integrityKey: newKey())
          .trust(hostKey());

      // Secure storage wiped (app data cleared, key rotated): the file can no
      // longer be authenticated, so nothing in it may be believed.
      backend.data.clear();

      final reloaded = KnownHostsService(
        file: storeFile,
        integrityKey: KnownHostsIntegrityKey(backend),
      );
      expect(await reloaded.all(), isEmpty);
      expect(reloaded.integrityFailed, isTrue);
    });

    test('a pre-Phase-3 file is adopted once and re-sealed', () async {
      // Exactly what Phase 1/2 wrote.
      await storeFile.writeAsString(
        jsonEncode({
          'version': 1,
          'hosts': {hostKey().id: hostKey().toJson()},
        }),
      );

      final migrating = KnownHostsService(
        file: storeFile,
        integrityKey: newKey(),
      );
      expect(
        await migrating.lookup('example.com', 22, 'ssh-ed25519'),
        isNotNull,
      );
      expect(migrating.integrityFailed, isFalse);

      // The file on disk is now sealed…
      final document =
          jsonDecode(await storeFile.readAsString()) as Map<String, dynamic>;
      expect(document['mac'], isA<String>());

      // …so an attacker who strips the envelope back off is caught.
      await storeFile.writeAsString(
        jsonEncode({
          'version': 1,
          'hosts': {hostKey(fingerprint: 'SHA256:EVIL').id: hostKey(fingerprint: 'SHA256:EVIL').toJson()},
        }),
      );
      final downgraded = KnownHostsService(
        file: storeFile,
        integrityKey: KnownHostsIntegrityKey(backend),
      );
      expect(await downgraded.all(), isEmpty);
      expect(downgraded.integrityFailed, isTrue);
    });

    test('no integrity key keeps the plain Phase 1 format working', () async {
      final service = KnownHostsService(file: storeFile);
      await service.trust(hostKey());

      final document =
          jsonDecode(await storeFile.readAsString()) as Map<String, dynamic>;
      expect(document['mac'], isNull);
      expect(document['hosts'], isA<Map<String, dynamic>>());

      final reloaded = KnownHostsService(file: storeFile);
      expect(await reloaded.lookup('example.com', 22, 'ssh-ed25519'), isNotNull);
    });
  });
}

/// A fixed key, for cases that only care whether a key is present at all.
Uint8List zeroKey() => Uint8List(32);
