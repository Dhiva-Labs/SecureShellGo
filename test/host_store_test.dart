import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/services/host_store.dart';

void main() {
  late Directory tempDir;
  late File storeFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('host_store_test');
    storeFile = File('${tempDir.path}/hosts.json');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Host host({
    String? id,
    String label = 'Home server',
    String hostname = 'example.com',
    int port = 22,
    String username = 'dev',
    SshAuthMethod authMethod = SshAuthMethod.password,
  }) {
    return Host(
      id: id ?? 'fixed-id',
      label: label,
      hostname: hostname,
      port: port,
      username: username,
      authMethod: authMethod,
    );
  }

  test('a fresh store has no saved hosts', () async {
    final store = HostStore(file: storeFile);
    expect(await store.all(), isEmpty);
    expect(await store.get('missing'), isNull);
  });

  test('newId returns a different id on every call', () {
    final store = HostStore(file: storeFile);
    final ids = {for (var i = 0; i < 20; i++) store.newId()};
    expect(ids, hasLength(20));
  });

  test('added hosts survive a reload from disk', () async {
    await HostStore(file: storeFile).add(host());

    final reloaded = HostStore(file: storeFile);
    final all = await reloaded.all();
    expect(all, hasLength(1));
    expect(all.single.hostname, 'example.com');
    expect(await reloaded.get('fixed-id'), isNotNull);
  });

  test('hosts come back in the order they were added', () async {
    final store = HostStore(file: storeFile);
    await store.add(host(id: 'a', label: 'First'));
    await store.add(host(id: 'b', label: 'Second'));
    await store.add(host(id: 'c', label: 'Third'));

    final all = await store.all();
    expect(all.map((h) => h.id), ['a', 'b', 'c']);
  });

  test('updating a host keeps its position in the list', () async {
    final store = HostStore(file: storeFile);
    await store.add(host(id: 'a', label: 'First'));
    await store.add(host(id: 'b', label: 'Second'));
    await store.add(host(id: 'c', label: 'Third'));

    await store.update(host(id: 'b', label: 'Second (renamed)'));

    final all = await store.all();
    expect(all.map((h) => h.id), ['a', 'b', 'c']);
    expect(all[1].label, 'Second (renamed)');
  });

  test('update replaces the stored copy and persists it', () async {
    final store = HostStore(file: storeFile);
    await store.add(host(port: 22));
    await store.update(host(port: 2222));

    final reloaded = HostStore(file: storeFile);
    expect((await reloaded.get('fixed-id'))?.port, 2222);
  });

  test('delete removes a host and persists the removal', () async {
    final store = HostStore(file: storeFile);
    await store.add(host());
    expect(await store.all(), hasLength(1));

    await store.delete('fixed-id');
    expect(await store.all(), isEmpty);

    final reloaded = HostStore(file: storeFile);
    expect(await reloaded.all(), isEmpty);
  });

  test('deleting a host that was never added is a no-op', () async {
    final store = HostStore(file: storeFile);
    await store.delete('does-not-exist');
    expect(await store.all(), isEmpty);
  });

  test('a corrupt store fails closed: the host list reads as empty',
      () async {
    await storeFile.writeAsString('{ not json');
    final store = HostStore(file: storeFile);
    expect(await store.all(), isEmpty);
  });

  test('a malformed entry is skipped without losing the rest of the store',
      () async {
    await storeFile.writeAsString('''
    {
      "version": 1,
      "hosts": [
        {"id": "good", "label": "", "hostname": "example.com", "port": 22, "username": "dev", "authMethod": "password"},
        {"id": "bad"}
      ]
    }
    ''');
    final store = HostStore(file: storeFile);
    final all = await store.all();
    expect(all, hasLength(1));
    expect(all.single.id, 'good');
  });

  test('a host with no lastConnectedAt reads as never connected', () async {
    final store = HostStore(file: storeFile);
    await store.add(host());
    expect((await store.get('fixed-id'))?.lastConnectedAt, isNull);
  });

  test('lastConnectedAt survives a reload from disk', () async {
    final connectedAt = DateTime.utc(2026, 7, 26, 9, 30);
    final store = HostStore(file: storeFile);
    await store.add(host().copyWith(lastConnectedAt: connectedAt));

    final reloaded = HostStore(file: storeFile);
    final saved = await reloaded.get('fixed-id');
    expect(saved?.lastConnectedAt, connectedAt);
  });

  test('hosts.json written before Phase 4 (no lastConnectedAt key) still '
      'loads', () async {
    await storeFile.writeAsString('''
    {
      "version": 1,
      "hosts": [
        {"id": "legacy", "label": "", "hostname": "example.com", "port": 22, "username": "dev", "authMethod": "password"}
      ]
    }
    ''');
    final store = HostStore(file: storeFile);
    final saved = await store.get('legacy');
    expect(saved, isNotNull);
    expect(saved!.lastConnectedAt, isNull);
  });

  test('editing a host through copyWith keeps its lastConnectedAt', () async {
    final connectedAt = DateTime.utc(2026, 7, 26, 9, 30);
    final store = HostStore(file: storeFile);
    await store.add(host().copyWith(lastConnectedAt: connectedAt));

    final edited =
        (await store.get('fixed-id'))!.copyWith(label: 'Renamed');
    await store.update(edited);

    final saved = await store.get('fixed-id');
    expect(saved?.label, 'Renamed');
    expect(saved?.lastConnectedAt, connectedAt);
  });
}
