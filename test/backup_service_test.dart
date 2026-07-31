import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/app_settings.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/models/snippet.dart';
import 'package:secure_shell_go/models/tunnel_profile.dart';
import 'package:secure_shell_go/services/backup_crypto.dart';
import 'package:secure_shell_go/services/backup_payload.dart';
import 'package:secure_shell_go/services/backup_service.dart';
import 'package:secure_shell_go/services/bookmark_store.dart';
import 'package:secure_shell_go/services/credential_store.dart';
import 'package:secure_shell_go/services/host_store.dart';
import 'package:secure_shell_go/services/settings_store.dart';
import 'package:secure_shell_go/services/snippet_store.dart';
import 'package:secure_shell_go/services/tunnel_store.dart';

/// In-memory stand-in for the Keystore-backed backend, same as the one in
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

/// One device's worth of stores, all pointed at a temp directory.
class Fixture {
  Fixture(this.dir)
      : hostStore = HostStore(file: File('${dir.path}/hosts.json')),
        snippetStore = SnippetStore(file: File('${dir.path}/snippets.json')),
        tunnelStore = TunnelStore(file: File('${dir.path}/tunnels.json')),
        bookmarkStore =
            BookmarkStore(file: File('${dir.path}/bookmarks.json')),
        settingsStore = SettingsStore(file: File('${dir.path}/settings.json')),
        backend = FakeSecureStorageBackend() {
    credentialStore = CredentialStore(backend: backend);
    service = BackupService(
      hostStore: hostStore,
      snippetStore: snippetStore,
      tunnelStore: tunnelStore,
      bookmarkStore: bookmarkStore,
      settingsStore: settingsStore,
      credentialStore: credentialStore,
    );
  }

  final Directory dir;
  final HostStore hostStore;
  final SnippetStore snippetStore;
  final TunnelStore tunnelStore;
  final BookmarkStore bookmarkStore;
  final SettingsStore settingsStore;
  final FakeSecureStorageBackend backend;
  late final CredentialStore credentialStore;
  late final BackupService service;
}

Host buildHost(
  String id, {
  String label = 'Server',
  String? group,
  SshAuthMethod authMethod = SshAuthMethod.password,
  String? jumpHostId,
}) =>
    Host(
      id: id,
      label: label,
      hostname: '$id.example.com',
      port: 2222,
      username: 'dev',
      authMethod: authMethod,
      group: group,
      colorLabel: HostColorLabel.teal,
      startupCommand: 'tmux attach',
      jumpHostId: jumpHostId,
    );

void main() {
  late Directory tempDir;
  late Fixture source;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('backup_service_test');
    source = Fixture(await Directory('${tempDir.path}/a').create());
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<Fixture> emptyTarget() async =>
      Fixture(await Directory('${tempDir.path}/b').create());

  /// Fills [f] with one of everything so a round trip has something to prove.
  Future<void> populate(Fixture f) async {
    await f.hostStore.add(buildHost('h1', label: 'Web', group: 'Prod'));
    await f.hostStore.add(
      buildHost('h2', label: 'DB', group: 'Prod', jumpHostId: 'h1'),
    );
    await f.hostStore.add(
      buildHost('h3', label: 'Laptop', authMethod: SshAuthMethod.agent),
    );
    await f.snippetStore.add(
      const Snippet(id: 's1', name: 'Disk', command: 'df -h', description: 'd'),
    );
    await f.tunnelStore.add(
      const TunnelProfile(
        id: 't1',
        name: 'Postgres',
        hostId: 'h2',
        type: TunnelType.local,
        localPort: 5433,
        remoteHost: '127.0.0.1',
        remotePort: 5432,
      ),
    );
    await f.bookmarkStore.add('h1', '/var/log', label: 'Logs');
    await f.bookmarkStore.add('h2', '/srv');
    await f.settingsStore.save(
      const AppSettings(
        terminalFontSize: 17,
        colorScheme: TerminalColorScheme.nord,
        keepScreenAwake: true,
        collapsedGroups: {'Prod'},
      ),
    );
    await f.credentialStore.save(
      'h1',
      const SshCredentials(password: 'hunter2'),
    );
    await f.credentialStore.save(
      'h2',
      const SshCredentials(privateKeyPem: '-----KEY-----', passphrase: 'pp'),
    );
  }

  group('round trip', () {
    test('every category survives export and import', () async {
      await populate(source);
      final file = await source.service.export(
        passphrase: 'a very good passphrase',
        includeCredentials: true,
        useIsolate: false,
      );

      final target = await emptyTarget();
      final payload = await target.service.readBackup(
        file: file,
        passphrase: 'a very good passphrase',
        useIsolate: false,
      );
      await target.service.apply(payload: payload, mode: ImportMode.replace);

      final hosts = await target.hostStore.all();
      expect(
        hosts.map((h) => h.toJson()),
        (await source.hostStore.all()).map((h) => h.toJson()),
      );
      expect(
        (await target.snippetStore.all()).map((s) => s.toJson()),
        (await source.snippetStore.all()).map((s) => s.toJson()),
      );
      expect(
        (await target.tunnelStore.all()).map((t) => t.toJson()),
        (await source.tunnelStore.all()).map((t) => t.toJson()),
      );
      expect(
        (await target.bookmarkStore.bookmarksForHost('h1'))
            .map((b) => '${b.hostId}:${b.path}:${b.label}'),
        ['h1:/var/log:Logs'],
      );
      expect(
        (await target.bookmarkStore.bookmarksForHost('h2'))
            .map((b) => '${b.hostId}:${b.path}:${b.label}'),
        ['h2:/srv:null'],
      );
      await target.settingsStore.ensureLoaded();
      expect(
        target.settingsStore.current.toJson(),
        source.settingsStore.current.toJson(),
      );
    });

    test('preserves host detail, including jump host and group', () async {
      await populate(source);
      final file = await source.service.export(
        passphrase: 'a very good passphrase',
        includeCredentials: false,
        useIsolate: false,
      );
      final target = await emptyTarget();
      final payload = await target.service.readBackup(
        file: file,
        passphrase: 'a very good passphrase',
        useIsolate: false,
      );
      await target.service.apply(payload: payload, mode: ImportMode.replace);

      final db = await target.hostStore.get('h2');
      expect(db, isNotNull);
      expect(db!.jumpHostId, 'h1');
      expect(db.group, 'Prod');
      expect(db.port, 2222);
      expect(db.colorLabel, HostColorLabel.teal);
      expect(db.startupCommand, 'tmux attach');
      expect(await target.hostStore.groupNames(), ['Prod']);
    });
  });

  group('credential opt-in', () {
    test('off by default: no secrets in the file at all', () async {
      await populate(source);
      final payload =
          await source.service.buildPayload(includeCredentials: false);
      expect(payload.includesCredentials, isFalse);
      expect(payload.credentials, isEmpty);

      // The strongest form of this check: the passwords must not appear
      // anywhere in the serialised bytes, however they got there.
      final json = utf8.decode(payload.encode());
      expect(json, isNot(contains('hunter2')));
      expect(json, isNot(contains('-----KEY-----')));
      // ...while the host itself, and its auth method, are still exported.
      expect(json, contains('"authMethod":"password"'));
      expect(json, contains('h1.example.com'));
    });

    test('on: secrets are included for hosts that store them', () async {
      await populate(source);
      final payload =
          await source.service.buildPayload(includeCredentials: true);
      expect(payload.includesCredentials, isTrue);
      expect(payload.credentials.keys, unorderedEquals(['h1', 'h2']));
      expect(payload.credentials['h1']!.password, 'hunter2');
      expect(payload.credentials['h2']!.privateKeyPem, '-----KEY-----');
      expect(payload.credentials['h2']!.passphrase, 'pp');
      // h3 authenticates through the OS agent and stores no secret, so there
      // is nothing to include even with the opt-in on.
      expect(payload.credentials.containsKey('h3'), isFalse);
    });

    test('a credential-free import leaves hosts needing credentials',
        () async {
      await populate(source);
      final file = await source.service.export(
        passphrase: 'a very good passphrase',
        includeCredentials: false,
        useIsolate: false,
      );
      final target = await emptyTarget();
      final payload = await target.service.readBackup(
        file: file,
        passphrase: 'a very good passphrase',
        useIsolate: false,
      );
      // h1 and h2 store secrets and have none; h3 is agent auth, so it does
      // not count as needing anything.
      expect(payload.hostsNeedingCredentials, 2);

      final result =
          await target.service.apply(payload: payload, mode: ImportMode.merge);
      expect(result.hostsNeedingCredentials, 2);
      expect(result.credentialsRestored, 0);
      expect(await target.credentialStore.has('h1'), isFalse);
    });

    test('credentials restore when the opt-in was on', () async {
      await populate(source);
      final file = await source.service.export(
        passphrase: 'a very good passphrase',
        includeCredentials: true,
        useIsolate: false,
      );
      final target = await emptyTarget();
      final payload = await target.service.readBackup(
        file: file,
        passphrase: 'a very good passphrase',
        useIsolate: false,
      );
      final result = await target.service
          .apply(payload: payload, mode: ImportMode.replace);
      expect(result.credentialsRestored, 2);
      expect(result.hostsNeedingCredentials, 0);
      final restored = await target.credentialStore.load('h2');
      expect(restored!.privateKeyPem, '-----KEY-----');
      expect(restored.passphrase, 'pp');
    });
  });

  group('nothing is applied on failure', () {
    late Uint8List file;

    setUp(() async {
      await populate(source);
      file = await source.service.export(
        passphrase: 'a very good passphrase',
        includeCredentials: true,
        useIsolate: false,
      );
    });

    Future<void> expectUntouched(Fixture target) async {
      expect(await target.hostStore.all(), isEmpty);
      expect(await target.snippetStore.all(), isEmpty);
      expect(await target.tunnelStore.all(), isEmpty);
      expect(target.backend.data, isEmpty);
      await target.settingsStore.ensureLoaded();
      expect(
        target.settingsStore.current.toJson(),
        const AppSettings().toJson(),
      );
    }

    test('a wrong passphrase writes nothing', () async {
      final target = await emptyTarget();
      await expectLater(
        target.service.readBackup(
          file: file,
          passphrase: 'the wrong passphrase',
          useIsolate: false,
        ),
        throwsA(isA<BackupAuthException>()),
      );
      await expectUntouched(target);
    });

    test('a corrupted file writes nothing', () async {
      final target = await emptyTarget();
      final damaged = Uint8List.fromList(file)
        ..[BackupCrypto.headerLength + 2] ^= 0xff;
      await expectLater(
        target.service.readBackup(
          file: damaged,
          passphrase: 'a very good passphrase',
          useIsolate: false,
        ),
        throwsA(isA<BackupAuthException>()),
      );
      await expectUntouched(target);
    });

    test('a newer payload version writes nothing', () async {
      // Re-seal a payload whose *inner* version is from the future, so this
      // exercises the JSON version gate rather than the container one.
      final json = jsonDecode(utf8.decode(await BackupCrypto.decrypt(
        file: file,
        passphrase: 'a very good passphrase',
        useIsolate: false,
      ))) as Map<String, dynamic>;
      json['payloadVersion'] = BackupPayload.payloadVersion + 1;
      final future = await BackupCrypto.encrypt(
        plaintext: Uint8List.fromList(utf8.encode(jsonEncode(json))),
        passphrase: 'a very good passphrase',
        useIsolate: false,
      );

      final target = await emptyTarget();
      await expectLater(
        target.service.readBackup(
          file: future,
          passphrase: 'a very good passphrase',
          useIsolate: false,
        ),
        throwsA(
          isA<BackupFormatException>()
              .having((e) => e.isVersionTooNew, 'isVersionTooNew', isTrue),
        ),
      );
      await expectUntouched(target);
    });

    test('an unreadable entry refuses the whole import', () async {
      final json = jsonDecode(utf8.decode(await BackupCrypto.decrypt(
        file: file,
        passphrase: 'a very good passphrase',
        useIsolate: false,
      ))) as Map<String, dynamic>;
      // A host row with no id at all: not something a bit-flip could produce
      // (the tag would catch that), but something a hand-edited or
      // wrongly-generated file could.
      (json['hosts'] as List).add(<String, dynamic>{'label': 'broken'});
      final broken = await BackupCrypto.encrypt(
        plaintext: Uint8List.fromList(utf8.encode(jsonEncode(json))),
        passphrase: 'a very good passphrase',
        useIsolate: false,
      );

      final target = await emptyTarget();
      await expectLater(
        target.service.readBackup(
          file: broken,
          passphrase: 'a very good passphrase',
          useIsolate: false,
        ),
        throwsA(
          isA<BackupFormatException>().having(
            (e) => e.message,
            'message',
            contains('nothing has been imported'),
          ),
        ),
      );
      await expectUntouched(target);
    });
  });

  group('merge vs replace', () {
    late BackupPayload payload;
    late Fixture target;

    setUp(() async {
      await populate(source);
      final file = await source.service.export(
        passphrase: 'a very good passphrase',
        includeCredentials: false,
        useIsolate: false,
      );
      target = await emptyTarget();
      // The device being imported onto already has a life of its own: one
      // host the backup does not know about, and one that collides by id.
      await target.hostStore.add(buildHost('local1', label: 'Only here'));
      await target.hostStore.add(buildHost('h1', label: 'Stale name'));
      await target.snippetStore.add(
        const Snippet(id: 'localS', name: 'Mine', command: 'whoami'),
      );
      await target.credentialStore.save(
        'h1',
        const SshCredentials(password: 'still-mine'),
      );
      payload = await target.service.readBackup(
        file: file,
        passphrase: 'a very good passphrase',
        useIsolate: false,
      );
    });

    test('merge keeps local-only records and lets the file win on id',
        () async {
      await target.service.apply(payload: payload, mode: ImportMode.merge);
      final hosts = await target.hostStore.all();
      expect(hosts.map((h) => h.id), containsAll(['local1', 'h1', 'h2', 'h3']));
      expect(hosts.length, 4);
      // The backup's version of h1 wins over the stale local one.
      expect((await target.hostStore.get('h1'))!.label, 'Web');
      // ...and the host the backup never mentioned is untouched.
      expect((await target.hostStore.get('local1'))!.label, 'Only here');
      expect(
        (await target.snippetStore.all()).map((s) => s.id),
        containsAll(['localS', 's1']),
      );
    });

    test('replace drops everything the file does not mention', () async {
      await target.service.apply(payload: payload, mode: ImportMode.replace);
      final hosts = await target.hostStore.all();
      expect(hosts.map((h) => h.id), ['h1', 'h2', 'h3']);
      expect(await target.hostStore.get('local1'), isNull);
      expect(
        (await target.snippetStore.all()).map((s) => s.id),
        ['s1'],
      );
    });

    test('merge never clears a credential the file did not carry', () async {
      // The backup was taken without credentials. Importing it must not be a
      // way to lose the password this device already had saved.
      await target.service.apply(payload: payload, mode: ImportMode.merge);
      final kept = await target.credentialStore.load('h1');
      expect(kept, isNotNull);
      expect(kept!.password, 'still-mine');
    });

    test('replace keeps credentials for hosts that survive it', () async {
      await target.service.apply(payload: payload, mode: ImportMode.replace);
      // h1 is still in the configuration, so its saved password stays even
      // though the backup carried no credentials.
      expect((await target.credentialStore.load('h1'))!.password, 'still-mine');
    });

    test('replace drops credentials only for hosts it removed', () async {
      await target.credentialStore.save(
        'local1',
        const SshCredentials(password: 'goes-away'),
      );
      final result = await target.service
          .apply(payload: payload, mode: ImportMode.replace);
      expect(await target.credentialStore.has('local1'), isFalse);
      expect(result.credentialsDropped, 1);
    });

    test('replace clears bookmarks belonging to removed hosts', () async {
      await target.bookmarkStore.add('local1', '/home/me', label: 'Mine');
      await target.service.apply(payload: payload, mode: ImportMode.replace);
      expect(await target.bookmarkStore.bookmarksForHost('local1'), isEmpty);
      expect(
        (await target.bookmarkStore.bookmarksForHost('h1')).single.path,
        '/var/log',
      );
    });

    test('importing twice is idempotent, not duplicating', () async {
      await target.service.apply(payload: payload, mode: ImportMode.replace);
      await target.service.apply(payload: payload, mode: ImportMode.replace);
      expect((await target.hostStore.all()).length, 3);
      expect((await target.tunnelStore.all()).length, 1);
      expect(
        (await target.bookmarkStore.bookmarksForHost('h1')).length,
        1,
      );
    });
  });

  group('preview', () {
    test('counts every category, including derived groups', () async {
      await populate(source);
      final payload =
          await source.service.buildPayload(includeCredentials: true);
      final contents = payload.contents;
      expect(contents.hosts, 3);
      expect(contents.groups, 1);
      expect(contents.snippets, 1);
      expect(contents.tunnels, 1);
      expect(contents.bookmarks, 2);
      expect(contents.credentials, 2);
      expect(contents.includesCredentials, isTrue);
      expect(contents.isEmpty, isFalse);
      expect(contents.exportedAt, isNotNull);
    });

    test('an empty configuration reports itself as empty', () async {
      final payload =
          await source.service.buildPayload(includeCredentials: false);
      expect(payload.contents.isEmpty, isTrue);
      expect(payload.contents.hosts, 0);
    });

    test('known_hosts is never in the payload', () async {
      await populate(source);
      final json = utf8.decode(
        (await source.service.buildPayload(includeCredentials: true)).encode(),
      );
      expect(json, isNot(contains('known_hosts')));
      expect(json, isNot(contains('knownHosts')));
      expect(json, isNot(contains('fingerprint')));
    });
  });
}
