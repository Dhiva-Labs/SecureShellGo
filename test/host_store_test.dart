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
    String? group,
    HostColorLabel? colorLabel,
  }) {
    return Host(
      id: id ?? 'fixed-id',
      label: label,
      hostname: hostname,
      port: port,
      username: username,
      authMethod: authMethod,
      group: group,
      colorLabel: colorLabel,
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

  test('group and colorLabel survive a reload from disk', () async {
    final store = HostStore(file: storeFile);
    await store.add(host(group: 'Work', colorLabel: HostColorLabel.teal));

    final reloaded = HostStore(file: storeFile);
    final saved = await reloaded.get('fixed-id');
    expect(saved?.group, 'Work');
    expect(saved?.colorLabel, HostColorLabel.teal);
  });

  test('a host with no startupCommand reads as none', () async {
    final store = HostStore(file: storeFile);
    await store.add(host());
    expect((await store.get('fixed-id'))?.startupCommand, isNull);
  });

  test('startupCommand survives a reload from disk', () async {
    final store = HostStore(file: storeFile);
    await store.add(
      host().copyWith(startupCommand: 'cd /var/www && ls'),
    );

    final reloaded = HostStore(file: storeFile);
    final saved = await reloaded.get('fixed-id');
    expect(saved?.startupCommand, 'cd /var/www && ls');
  });

  test('hosts.json written before v1.3.0 (no group, colorLabel or '
      'startupCommand keys) still '
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
    expect(saved!.group, isNull);
    expect(saved.colorLabel, isNull);
    expect(saved.startupCommand, isNull);
  });

  test('an unrecognised colorLabel id reads as no colour rather than failing '
      'the entry', () async {
    await storeFile.writeAsString('''
    {
      "version": 1,
      "hosts": [
        {"id": "a", "label": "", "hostname": "example.com", "port": 22, "username": "dev", "authMethod": "password", "colorLabel": "chartreuse"}
      ]
    }
    ''');
    final store = HostStore(file: storeFile);
    final saved = await store.get('a');
    expect(saved, isNotNull);
    expect(saved!.colorLabel, isNull);
  });

  test('withGroup reassigns without disturbing any other field', () {
    final original = host(group: 'Work', colorLabel: HostColorLabel.pink);
    final moved = original.withGroup('Home');
    expect(moved.group, 'Home');
    expect(moved.colorLabel, HostColorLabel.pink);
    expect(moved.id, original.id);
  });

  test('withGroup(null) clears the group back to Ungrouped', () {
    final grouped = host(group: 'Work');
    expect(grouped.withGroup(null).group, isNull);
  });

  group('HostStore group operations', () {
    test('groupNames returns every distinct group, sorted, case-insensitive '
        'and ungrouped hosts excluded', () async {
      final store = HostStore(file: storeFile);
      await store.add(host(id: 'a', group: 'zebra'));
      await store.add(host(id: 'b', group: 'Apple'));
      await store.add(host(id: 'c'));
      await store.add(host(id: 'd', group: 'apple'));

      expect(await store.groupNames(), ['Apple', 'apple', 'zebra']);
    });

    test('renameGroup moves every host in the old name to the new one',
        () async {
      final store = HostStore(file: storeFile);
      await store.add(host(id: 'a', group: 'Work'));
      await store.add(host(id: 'b', group: 'Work'));
      await store.add(host(id: 'c', group: 'Home'));

      await store.renameGroup('Work', 'Office');

      final all = await store.all();
      expect(all.firstWhere((h) => h.id == 'a').group, 'Office');
      expect(all.firstWhere((h) => h.id == 'b').group, 'Office');
      expect(all.firstWhere((h) => h.id == 'c').group, 'Home');
    });

    test('renameGroup persists across a reload', () async {
      final store = HostStore(file: storeFile);
      await store.add(host(id: 'a', group: 'Work'));
      await store.renameGroup('Work', 'Office');

      final reloaded = HostStore(file: storeFile);
      expect((await reloaded.get('a'))?.group, 'Office');
    });

    test('renameGroup with a blank new name is a no-op', () async {
      final store = HostStore(file: storeFile);
      await store.add(host(id: 'a', group: 'Work'));
      await store.renameGroup('Work', '   ');
      expect((await store.get('a'))?.group, 'Work');
    });

    test('renameGroup ignores a name nothing currently uses', () async {
      final store = HostStore(file: storeFile);
      await store.add(host(id: 'a', group: 'Work'));
      await store.renameGroup('DoesNotExist', 'Office');
      expect((await store.get('a'))?.group, 'Work');
    });

    test('deleteGroup moves its hosts to Ungrouped without deleting them',
        () async {
      final store = HostStore(file: storeFile);
      await store.add(host(id: 'a', group: 'Work'));
      await store.add(host(id: 'b', group: 'Work'));
      await store.add(host(id: 'c', group: 'Home'));

      await store.deleteGroup('Work');

      final all = await store.all();
      expect(all, hasLength(3));
      expect(all.firstWhere((h) => h.id == 'a').group, isNull);
      expect(all.firstWhere((h) => h.id == 'b').group, isNull);
      expect(all.firstWhere((h) => h.id == 'c').group, 'Home');
      expect(await store.groupNames(), ['Home']);
    });

    test('deleteGroup persists the Ungrouped move across a reload', () async {
      final store = HostStore(file: storeFile);
      await store.add(host(id: 'a', group: 'Work'));
      await store.deleteGroup('Work');

      final reloaded = HostStore(file: storeFile);
      expect((await reloaded.get('a'))?.group, isNull);
    });

    test('deleteGroup for a name nothing uses is a harmless no-op', () async {
      final store = HostStore(file: storeFile);
      await store.add(host(id: 'a', group: 'Work'));
      await store.deleteGroup('DoesNotExist');
      expect((await store.get('a'))?.group, 'Work');
    });
  });
}
