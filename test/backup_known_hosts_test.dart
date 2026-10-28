import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/models/known_host.dart';
import 'package:secure_shell_go/services/backup_crypto.dart';
import 'package:secure_shell_go/services/backup_payload.dart';
import 'package:secure_shell_go/services/backup_service.dart';
import 'package:secure_shell_go/services/bookmark_store.dart';
import 'package:secure_shell_go/services/credential_store.dart';
import 'package:secure_shell_go/services/host_store.dart';
import 'package:secure_shell_go/services/known_hosts_integrity.dart';
import 'package:secure_shell_go/services/known_hosts_service.dart';
import 'package:secure_shell_go/services/settings_store.dart';
import 'package:secure_shell_go/services/snippet_store.dart';
import 'package:secure_shell_go/services/tunnel_store.dart';

import 'backup_service_test.dart' show FakeSecureStorageBackend;

const _passphrase = 'a very good passphrase';

/// A keyring whose reads fail, the way a locked system keyring does.
class _LockedKeyring implements SecureStorageBackend {
  @override
  Future<String?> read(String key) async =>
      throw const SecureStorageUnavailableException('locked');

  @override
  Future<void> write(String key, String value) async =>
      throw const SecureStorageUnavailableException('locked');

  @override
  Future<void> delete(String key) async {}
}

/// One device: its stores, its own keyring, and so its own integrity key.
class Device {
  Device(this.dir, {SecureStorageBackend? keyring})
      : keyring = keyring ?? FakeSecureStorageBackend() {
    knownHostsFile = File('${dir.path}/known_hosts.json');
    knownHosts = KnownHostsService(
      file: knownHostsFile,
      integrityKey: KnownHostsIntegrityKey(
        this.keyring,
        readOrThrow: this.keyring.read,
      ),
    );
    service = BackupService(
      hostStore: HostStore(file: File('${dir.path}/hosts.json')),
      snippetStore: SnippetStore(file: File('${dir.path}/snippets.json')),
      tunnelStore: TunnelStore(file: File('${dir.path}/tunnels.json')),
      bookmarkStore: BookmarkStore(file: File('${dir.path}/bookmarks.json')),
      settingsStore: SettingsStore(file: File('${dir.path}/settings.json')),
      credentialStore: CredentialStore(backend: FakeSecureStorageBackend()),
      knownHosts: knownHosts,
    );
  }

  final Directory dir;
  final SecureStorageBackend keyring;
  late final File knownHostsFile;
  late final KnownHostsService knownHosts;
  late final BackupService service;

  /// A fresh service over this device's file and key, as after a restart.
  KnownHostsService reopen() => KnownHostsService(
        file: knownHostsFile,
        integrityKey: KnownHostsIntegrityKey(keyring, readOrThrow: keyring.read),
      );
}

String _fingerprint(Random random) {
  final digest = base64Encode(
    List<int>.generate(32, (_) => random.nextInt(256)),
  ).replaceAll('=', '');
  return 'SHA256:$digest';
}

KnownHostKey _key(
  String host,
  String fingerprint, {
  int port = 22,
  String type = 'ssh-ed25519',
}) =>
    KnownHostKey(
      hostname: host,
      port: port,
      keyType: type,
      fingerprint: fingerprint,
      addedAt: DateTime.utc(2025, 3, 4),
    );

void main() {
  late Directory tempDir;
  late Device source;
  final random = Random(11);
  late String fpA, fpB, fpC, fpOther;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('backup_known_hosts');
    source = Device(await Directory('${tempDir.path}/a').create());
    fpA = _fingerprint(random);
    fpB = _fingerprint(random);
    fpC = _fingerprint(random);
    fpOther = _fingerprint(random);
    await source.knownHosts.trust(_key('a.example.org', fpA));
    await source.knownHosts.trust(_key('b.example.org', fpB, port: 2222));
    await source.knownHosts.trust(_key('c.example.org', fpC, type: 'ssh-rsa'));
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<Device> target({SecureStorageBackend? keyring}) async => Device(
        await Directory('${tempDir.path}/b').create(),
        keyring: keyring,
      );

  Future<BackupPayload> roundTrip(Device from, Device to,
      {bool includeKnownHosts = true}) async {
    final file = await from.service.export(
      passphrase: _passphrase,
      includeCredentials: false,
      includeKnownHosts: includeKnownHosts,
      useIsolate: false,
    );
    return to.service.readBackup(
      file: file,
      passphrase: _passphrase,
      useIsolate: false,
    );
  }

  group('export', () {
    test('leaves trusted host keys out unless asked', () async {
      final payload =
          await source.service.buildPayload(includeCredentials: false);
      final json = utf8.decode(payload.encode());
      expect(json, isNot(contains('knownHosts')));
      expect(json, isNot(contains('fingerprint')));
      expect(payload.contents.includesKnownHosts, isFalse);
    });

    test('carries the entries, and nothing about the seal, when asked',
        () async {
      final payload = await source.service.buildPayload(
        includeCredentials: false,
        includeKnownHosts: true,
      );
      expect(payload.contents.knownHosts, 3);
      final json = utf8.decode(payload.encode());
      expect(json, contains(fpA));
      expect(json, contains(fpC));
      expect(json, isNot(contains('mac')));
      expect(json, isNot(contains('HmacSHA256')));
      final keyStored =
          (source.keyring as FakeSecureStorageBackend)
              .data[KnownHostsIntegrityKey.storageKey]!;
      expect(json, isNot(contains(keyStored)));
    });
  });

  group('restore', () {
    test('adds the keys, sealed with the new device\'s own key', () async {
      final to = await target();
      final payload = await roundTrip(source, to);
      expect(payload.contents.knownHosts, 3);
      final result = await to.service.apply(
        payload: payload,
        mode: ImportMode.merge,
        trustKnownHosts: true,
      );
      expect(result.knownHostsAdded, 3);
      expect(result.knownHostsKept, 0);
      expect(result.knownHostsNotSaved, isFalse);

      // On disk, a sealed envelope...
      final raw = jsonDecode(await to.knownHostsFile.readAsString()) as Map;
      expect(raw['mac'], isA<String>());
      // ...that this device's key opens after a restart...
      final reopened = to.reopen();
      final a = await reopened.lookup('a.example.org', 22, 'ssh-ed25519');
      expect(a?.fingerprint, fpA);
      expect(
        (await reopened.lookup('b.example.org', 2222, 'ssh-ed25519'))
            ?.fingerprint,
        fpB,
      );
      expect(reopened.integrityFailed, isFalse);
      expect(a!.addedAt, DateTime.utc(2025, 3, 4));

      // ...and the source device's key does not.
      final sourceKey = KnownHostsIntegrityKey(source.keyring);
      final check = KnownHostsEnvelope.open(
        await to.knownHostsFile.readAsString(),
        key: await sourceKey.obtain(),
        keyEverEstablished: true,
      );
      expect(check.verdict, IntegrityVerdict.tampered);
    });

    test('a key this device already trusts is never replaced', () async {
      final to = await target();
      await to.knownHosts.trust(_key('a.example.org', fpA));
      await to.knownHosts.trust(_key('b.example.org', fpOther, port: 2222));
      final payload = await roundTrip(source, to);

      final result = await to.service.apply(
        payload: payload,
        mode: ImportMode.merge,
        trustKnownHosts: true,
      );
      expect(result.knownHostsAdded, 1); // c only
      expect(result.knownHostsKept, 1); // b differs; this device's kept

      final reopened = to.reopen();
      expect(
        (await reopened.lookup('b.example.org', 2222, 'ssh-ed25519'))
            ?.fingerprint,
        fpOther,
      );
      expect(
        (await reopened.lookup('c.example.org', 22, 'ssh-rsa'))?.fingerprint,
        fpC,
      );
    });

    test('replace adds keys too, and removes none', () async {
      final to = await target();
      await to.knownHosts.trust(_key('local.example.org', fpOther));
      final payload = await roundTrip(source, to);
      await to.service.apply(
        payload: payload,
        mode: ImportMode.replace,
        trustKnownHosts: true,
      );
      final all = await to.reopen().all();
      expect(all.map((k) => k.hostname), contains('local.example.org'));
      expect(all, hasLength(4));
    });

    test('a backup made without them touches nothing', () async {
      final to = await target();
      await to.knownHosts.trust(_key('local.example.org', fpOther));
      final payload = await roundTrip(source, to, includeKnownHosts: false);
      final result = await to.service.apply(
        payload: payload,
        mode: ImportMode.replace,
        trustKnownHosts: true,
      );
      expect(result.knownHostsAdded, 0);
      expect(await to.reopen().all(), hasLength(1));
    });

    test('with the keyring locked, the keys are kept for the session only',
        () async {
      final to = await target(keyring: _LockedKeyring());
      final payload = await roundTrip(source, to);
      final result = await to.service.apply(
        payload: payload,
        mode: ImportMode.merge,
        trustKnownHosts: true,
      );
      expect(result.knownHostsAdded, 3);
      expect(result.knownHostsNotSaved, isTrue);
      expect(await to.knownHostsFile.exists(), isFalse);
    });

    test('nothing is trusted unless the person ticks Trust these keys',
        () async {
      final to = await target();
      final payload = await roundTrip(source, to);
      final result =
          await to.service.apply(payload: payload, mode: ImportMode.merge);
      expect(result.knownHostsAdded, 0);
      expect(result.knownHostsNotTrusted, 3);
      expect(await to.reopen().all(), isEmpty);
    });

    test('a backup cannot add another key type for a server already known',
        () async {
      // This device checked a.example.org's ed25519 key itself. A backup
      // that also "trusts" an RSA key for it would let someone in the
      // middle present RSA and get no warning at all.
      final to = await target();
      await to.knownHosts.trust(_key('a.example.org', fpA));
      await source.knownHosts
          .trust(_key('a.example.org', fpOther, type: 'ssh-rsa'));
      final payload = await roundTrip(source, to);

      final preview = await to.service.knownHostsToImport(payload);
      expect(preview.toAdd.map((k) => k.hostname),
          ['b.example.org', 'c.example.org']);
      expect(preview.serversKept, 1);

      final result = await to.service.apply(
        payload: payload,
        mode: ImportMode.merge,
        trustKnownHosts: true,
      );
      expect(result.knownHostsAdded, 2);
      expect(result.knownHostsKept, 1);
      final reopened = to.reopen();
      expect(await reopened.lookup('a.example.org', 22, 'ssh-rsa'), isNull);
      expect(
        (await reopened.lookup('a.example.org', 22, 'ssh-ed25519'))
            ?.fingerprint,
        fpA,
      );
    });

    test('a new server brings every key type the backup has for it',
        () async {
      final to = await target();
      await source.knownHosts
          .trust(_key('c.example.org', fpOther, type: 'ssh-ed25519'));
      final payload = await roundTrip(source, to);
      final preview = await to.service.knownHostsToImport(payload);
      expect(
        preview.toAdd
            .where((k) => k.hostname == 'c.example.org')
            .map((k) => k.keyType)
            .toSet(),
        {'ssh-rsa', 'ssh-ed25519'},
      );
      expect(preview.serversKept, 0);
    });
  });

  group('a tampered backup', () {
    /// Decrypts [file], lets [edit] change the plaintext JSON, and seals it
    /// again with the same passphrase — what someone who knows the
    /// passphrase could do to a backup.
    Future<Uint8List> reseal(
      Uint8List file,
      void Function(Map<String, dynamic> json) edit,
    ) async {
      final json = jsonDecode(utf8.decode(await BackupCrypto.decrypt(
        file: file,
        passphrase: _passphrase,
        useIsolate: false,
      ))) as Map<String, dynamic>;
      edit(json);
      return BackupCrypto.encrypt(
        plaintext: Uint8List.fromList(utf8.encode(jsonEncode(json))),
        passphrase: _passphrase,
        useIsolate: false,
      );
    }

    Future<Uint8List> exported() => source.service.export(
          passphrase: _passphrase,
          includeCredentials: false,
          includeKnownHosts: true,
          useIsolate: false,
        );

    test('a changed byte is refused before anything is written', () async {
      final to = await target();
      final damaged = Uint8List.fromList(await exported());
      damaged[damaged.length - 5] ^= 0x01;
      await expectLater(
        to.service.readBackup(
          file: damaged,
          passphrase: _passphrase,
          useIsolate: false,
        ),
        throwsA(isA<BackupAuthException>()),
      );
      expect(await to.knownHostsFile.exists(), isFalse);
    });

    test('integrity data smuggled into the file is ignored', () async {
      final to = await target();
      // An attacker's own sealed store, MAC and key, placed beside and inside
      // the entries, plus a forged entry for a server of their choosing.
      final attackerKey = Uint8List.fromList(List<int>.filled(32, 7));
      final forgedStore = KnownHostsEnvelope.seal(attackerKey, {
        'version': 1,
        'hosts': {
          'evil.example.org:22|ssh-ed25519':
              _key('evil.example.org', fpOther).toJson(),
        },
      });
      final file = await reseal(await exported(), (json) {
        json['knownHostsEnvelope'] = forgedStore;
        json['mac'] = 'AAAA';
        json['integrityKey'] = base64Encode(attackerKey);
        final entries = json['knownHosts'] as List;
        (entries.first as Map)['mac'] = 'AAAA';
        entries.add({
          ..._key('evil.example.org', fpOther).toJson(),
          'mac': KnownHostsEnvelope.macOf(attackerKey, 'x'),
        });
      });
      final payload = await to.service.readBackup(
        file: file,
        passphrase: _passphrase,
        useIsolate: false,
      );

      // Unasked, nothing is trusted — the forged entry least of all — and
      // nothing is written.
      await to.service.apply(payload: payload, mode: ImportMode.merge);
      expect(await to.reopen().all(), isEmpty);
      expect(await to.knownHostsFile.exists(), isFalse);

      // Asked, the person is shown every server it would trust, the forged
      // one included, as a plain entry: nothing came from the smuggled
      // store, MAC or key.
      final preview = await to.service.knownHostsToImport(payload);
      expect(preview.toAdd.map((k) => k.hostname), [
        'a.example.org',
        'b.example.org',
        'c.example.org',
        'evil.example.org',
      ]);
      expect(preview.toAdd.last.fingerprint, fpOther);
      await to.service.apply(
        payload: payload,
        mode: ImportMode.merge,
        trustKnownHosts: true,
      );

      // What got in is sealed with this device's key, not the attacker's:
      // the attacker's key does not open the store...
      final check = KnownHostsEnvelope.open(
        await to.knownHostsFile.readAsString(),
        key: attackerKey,
        keyEverEstablished: true,
      );
      expect(check.verdict, IntegrityVerdict.tampered);
      // ...this device's does, and the attacker's key was not adopted.
      final reopened = to.reopen();
      expect(reopened.integrityFailed, isFalse);
      expect(await reopened.all(), hasLength(4));
      expect(
        (await to.keyring.read(KnownHostsIntegrityKey.storageKey)),
        isNot(base64Encode(attackerKey)),
      );
    });

    test('an entry that is not a host key refuses the whole import',
        () async {
      final to = await target();
      for (final broken in <Map<String, dynamic>>[
        {'hostname': 'x.org', 'port': 99999, 'keyType': 'ssh-ed25519', 'fingerprint': fpA},
        {'hostname': 'x.org', 'port': 22, 'keyType': 'ssh-ed25519', 'fingerprint': 'MD5:00:11'},
        {'hostname': 'x.org|other', 'port': 22, 'keyType': 'ssh-ed25519', 'fingerprint': fpA},
        {'hostname': '', 'port': 22, 'keyType': 'ssh-ed25519', 'fingerprint': fpA},
        {'hostname': 'x.org', 'port': '22', 'keyType': 'ssh-ed25519', 'fingerprint': fpA},
        {'hostname': 'x.org', 'port': 22, 'keyType': 'ssh ed25519', 'fingerprint': fpA},
      ]) {
        final file = await reseal(await exported(), (json) {
          (json['knownHosts'] as List).add(broken);
        });
        await expectLater(
          to.service.readBackup(
            file: file,
            passphrase: _passphrase,
            useIsolate: false,
          ),
          throwsA(isA<BackupFormatException>()),
          reason: '$broken',
        );
      }
      expect(await to.knownHostsFile.exists(), isFalse);
    });

    test('one server listed twice is added once, first entry winning',
        () async {
      final to = await target();
      final file = await reseal(await exported(), (json) {
        (json['knownHosts'] as List)
            .add(_key('a.example.org', fpOther).toJson());
      });
      final payload = await to.service.readBackup(
        file: file,
        passphrase: _passphrase,
        useIsolate: false,
      );
      final result = await to.service.apply(
        payload: payload,
        mode: ImportMode.merge,
        trustKnownHosts: true,
      );
      expect(result.knownHostsAdded, 3);
      expect(
        (await to.reopen().lookup('a.example.org', 22, 'ssh-ed25519'))
            ?.fingerprint,
        fpA,
      );
    });
  });

  test('a host record restores alongside its key', () async {
    await source.service.hostStore.add(
      const Host(
        id: 'h1',
        label: 'A',
        hostname: 'a.example.org',
        port: 22,
        username: 'root',
        authMethod: SshAuthMethod.password,
      ),
    );
    final to = await target();
    final payload = await roundTrip(source, to);
    await to.service.apply(
      payload: payload,
      mode: ImportMode.merge,
      trustKnownHosts: true,
    );
    expect(await to.service.hostStore.all(), hasLength(1));
    expect(await to.reopen().isHostKnown('a.example.org', 22), isTrue);
  });
}
