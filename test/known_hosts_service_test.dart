import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/known_host.dart';
import 'package:secure_shell_go/services/known_hosts_service.dart';

void main() {
  late Directory tempDir;
  late File storeFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('known_hosts_test');
    storeFile = File('${tempDir.path}/known_hosts.json');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  KnownHostKey key({
    String hostname = 'example.com',
    int port = 22,
    String keyType = 'ssh-ed25519',
    String fingerprint = 'SHA256:AAAA',
  }) {
    return KnownHostKey(
      hostname: hostname,
      port: port,
      keyType: keyType,
      fingerprint: fingerprint,
      addedAt: DateTime(2026, 1, 1),
    );
  }

  test('unknown host has no trusted key', () async {
    final service = KnownHostsService(file: storeFile);
    expect(await service.lookup('example.com', 22, 'ssh-ed25519'), isNull);
    expect(await service.isHostKnown('example.com', 22), isFalse);
  });

  test('trusted key survives a reload from disk', () async {
    await KnownHostsService(file: storeFile).trust(key());

    final reloaded = KnownHostsService(file: storeFile);
    final found = await reloaded.lookup('example.com', 22, 'ssh-ed25519');
    expect(found, isNotNull);
    expect(found!.fingerprint, 'SHA256:AAAA');
    expect(await reloaded.isHostKnown('example.com', 22), isTrue);
  });

  test('hostname matching is case insensitive', () async {
    final service = KnownHostsService(file: storeFile);
    await service.trust(key(hostname: 'Example.COM'));
    expect(
      await service.lookup('example.com', 22, 'ssh-ed25519'),
      isNotNull,
    );
  });

  test('trust is scoped per key type, so a second algorithm is unknown',
      () async {
    final service = KnownHostsService(file: storeFile);
    await service.trust(key(keyType: 'ssh-ed25519'));

    // The host is known overall...
    expect(await service.isHostKnown('example.com', 22), isTrue);
    // ...but its RSA key has never been trusted, so it must not be accepted
    // silently — this is what stops algorithm negotiation from looking like a
    // key change.
    expect(await service.lookup('example.com', 22, 'rsa-sha2-512'), isNull);
  });

  test('trust is scoped per port', () async {
    final service = KnownHostsService(file: storeFile);
    await service.trust(key(port: 22));
    expect(await service.lookup('example.com', 2222, 'ssh-ed25519'), isNull);
  });

  test('re-trusting the same host and key type replaces the fingerprint',
      () async {
    final service = KnownHostsService(file: storeFile);
    await service.trust(key(fingerprint: 'SHA256:OLD'));
    await service.trust(key(fingerprint: 'SHA256:NEW'));

    final found = await service.lookup('example.com', 22, 'ssh-ed25519');
    expect(found!.fingerprint, 'SHA256:NEW');
    expect((await service.all()).length, 1);
  });

  test('forgetHost drops every key type for that host', () async {
    final service = KnownHostsService(file: storeFile);
    await service.trust(key(keyType: 'ssh-ed25519'));
    await service.trust(key(keyType: 'rsa-sha2-512'));
    expect((await service.all()).length, 2);

    await service.forgetHost('example.com', 22);
    expect(await service.isHostKnown('example.com', 22), isFalse);
    expect(await service.all(), isEmpty);
  });

  test('a corrupt store fails closed: everything reads as unknown', () async {
    await storeFile.writeAsString('{ this is not json');
    final service = KnownHostsService(file: storeFile);
    expect(await service.lookup('example.com', 22, 'ssh-ed25519'), isNull);
    expect(await service.isHostKnown('example.com', 22), isFalse);
  });
}
