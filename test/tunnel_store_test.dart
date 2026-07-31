import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/models/tunnel_profile.dart';
import 'package:secure_shell_go/services/tunnel_store.dart';

void main() {
  late Directory tempDir;
  late File storeFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tunnel_store_test');
    storeFile = File('${tempDir.path}/tunnels.json');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  TunnelProfile profile({
    String id = 'tunnel-1',
    String name = 'Postgres',
    String hostId = 'host-1',
    TunnelType type = TunnelType.local,
    int localPort = 5432,
  }) {
    return TunnelProfile(
      id: id,
      name: name,
      hostId: hostId,
      type: type,
      localPort: localPort,
      remoteHost: 'db.internal',
      remotePort: 5432,
    );
  }

  Host host({String id = 'host-1', String label = 'Bastion'}) => Host(
        id: id,
        label: label,
        hostname: 'bastion.example.com',
        port: 22,
        username: 'ops',
        authMethod: SshAuthMethod.password,
      );

  group('TunnelStore', () {
    test('a fresh store has no saved tunnels', () async {
      final store = TunnelStore(file: storeFile);
      expect(await store.all(), isEmpty);
      expect(await store.get('missing'), isNull);
    });

    test('newId returns a different id on every call', () {
      final store = TunnelStore(file: storeFile);
      final ids = {for (var i = 0; i < 20; i++) store.newId()};
      expect(ids, hasLength(20));
    });

    test('a saved tunnel survives a reload, field for field', () async {
      final store = TunnelStore(file: storeFile);
      await store.add(
        profile(type: TunnelType.dynamic, localPort: 1080),
      );

      final reloaded = TunnelStore(file: storeFile);
      final restored = (await reloaded.all()).single;

      expect(restored.id, 'tunnel-1');
      expect(restored.name, 'Postgres');
      expect(restored.hostId, 'host-1');
      expect(restored.type, TunnelType.dynamic);
      expect(restored.localHost, TunnelProfile.loopback);
      expect(restored.localPort, 1080);
      expect(restored.remoteHost, 'db.internal');
      expect(restored.remotePort, 5432);
    });

    test('editing keeps the tunnel where it was in the list', () async {
      final store = TunnelStore(file: storeFile);
      await store.add(profile(id: 'a', name: 'A'));
      await store.add(profile(id: 'b', name: 'B'));
      await store.add(profile(id: 'c', name: 'C'));

      await store.update(profile(id: 'b', name: 'B (edited)'));

      final names = (await store.all()).map((p) => p.name).toList();
      expect(names, ['A', 'B (edited)', 'C']);
    });

    test('deleting removes only that tunnel, and reloads without it',
        () async {
      final store = TunnelStore(file: storeFile);
      await store.add(profile(id: 'a'));
      await store.add(profile(id: 'b'));
      await store.delete('a');
      await store.delete('missing');

      final reloaded = TunnelStore(file: storeFile);
      expect((await reloaded.all()).map((p) => p.id), ['b']);
    });

    test('one malformed entry does not lose the rest of the store', () async {
      await storeFile.writeAsString(
        jsonEncode({
          'version': 1,
          'tunnels': [
            {'name': 'no id at all'},
            profile(id: 'good').toJson(),
          ],
        }),
      );

      final store = TunnelStore(file: storeFile);
      expect((await store.all()).map((p) => p.id), ['good']);
    });

    test('an unreadable store opens empty rather than throwing', () async {
      await storeFile.writeAsString('{ this is not json');
      final store = TunnelStore(file: storeFile);
      expect(await store.all(), isEmpty);
    });
  });

  group('groupTunnelsByHost', () {
    test('groups tunnels under their host, in host order', () {
      final groups = groupTunnelsByHost(
        [
          profile(id: 'a', hostId: 'host-2'),
          profile(id: 'b', hostId: 'host-1'),
          profile(id: 'c', hostId: 'host-2'),
        ],
        [
          host(id: 'host-1', label: 'Bastion'),
          host(id: 'host-2', label: 'Database'),
        ],
      );

      expect(groups.map((g) => g.hostLabel), ['Bastion', 'Database']);
      expect(groups.first.bindings.map((b) => b.profile.id), ['b']);
      expect(groups.last.bindings.map((b) => b.profile.id), ['a', 'c']);
      expect(groups.every((g) => g.isBroken), isFalse);
    });

    test('a tunnel whose host was deleted becomes a broken row, not a crash',
        () {
      final groups = groupTunnelsByHost(
        [
          profile(id: 'a', hostId: 'host-1'),
          profile(id: 'orphan', hostId: 'host-gone'),
        ],
        [host(id: 'host-1')],
      );

      expect(groups, hasLength(2));
      final broken = groups.last;
      expect(broken.isBroken, isTrue);
      expect(broken.hostLabel, 'Missing host');

      final binding = broken.bindings.single;
      expect(binding.profile.id, 'orphan');
      expect(binding.host, isNull);
      expect(binding.brokenMessage, contains('has been deleted'));
    });

    test('broken tunnels are collected last, whatever order they were in', () {
      final groups = groupTunnelsByHost(
        [
          profile(id: 'orphan', hostId: 'host-gone'),
          profile(id: 'a', hostId: 'host-1'),
        ],
        [host(id: 'host-1')],
      );

      expect(groups.first.isBroken, isFalse);
      expect(groups.last.isBroken, isTrue);
    });

    test('a healthy binding has no broken message to show', () {
      final binding = groupTunnelsByHost(
        [profile(id: 'a')],
        [host()],
      ).single.bindings.single;

      expect(binding.isBroken, isFalse);
      expect(binding.brokenMessage, isNull);
      expect(binding.hostLabel, 'Bastion');
    });

    test('no tunnels means no groups at all', () {
      expect(groupTunnelsByHost(const [], [host()]), isEmpty);
    });
  });
}
