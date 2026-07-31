import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/bookmark_store.dart';

void main() {
  late Directory tempDir;
  late File storeFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('bookmark_store_test');
    storeFile = File('${tempDir.path}/bookmarks.json');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('a fresh store has no bookmarks for any host', () async {
    final store = BookmarkStore(file: storeFile);
    expect(await store.bookmarksForHost('host-1'), isEmpty);
    expect(await store.forPath('host-1', '/var/log'), isNull);
  });

  test('added bookmarks survive a reload from disk', () async {
    final store = BookmarkStore(file: storeFile);
    final added = await store.add('host-1', '/var/log', label: 'Logs');

    final reloaded = BookmarkStore(file: storeFile);
    final all = await reloaded.bookmarksForHost('host-1');
    expect(all, hasLength(1));
    expect(all.single.id, added.id);
    expect(all.single.path, '/var/log');
    expect(all.single.label, 'Logs');
  });

  test('bookmarksForHost only returns that host\'s rows', () async {
    final store = BookmarkStore(file: storeFile);
    await store.add('host-1', '/var/log');
    await store.add('host-1', '/etc');
    await store.add('host-2', '/home/dev');

    final hostOne = await store.bookmarksForHost('host-1');
    final hostTwo = await store.bookmarksForHost('host-2');

    expect(hostOne.map((b) => b.path), unorderedEquals(['/var/log', '/etc']));
    expect(hostTwo.map((b) => b.path), ['/home/dev']);
  });

  test('adding the same host/path twice does not create a duplicate',
      () async {
    final store = BookmarkStore(file: storeFile);
    final first = await store.add('host-1', '/var/log');
    final second = await store.add('host-1', '/var/log');

    expect(second.id, first.id);
    expect(await store.bookmarksForHost('host-1'), hasLength(1));
  });

  test('the same path on two different hosts are independent bookmarks',
      () async {
    final store = BookmarkStore(file: storeFile);
    final onHostOne = await store.add('host-1', '/home/dev');
    final onHostTwo = await store.add('host-2', '/home/dev');

    expect(onHostOne.id, isNot(onHostTwo.id));
    expect(await store.forPath('host-1', '/home/dev'), isNotNull);
    expect(await store.forPath('host-2', '/home/dev'), isNotNull);
  });

  test('remove deletes by id and persists the removal', () async {
    final store = BookmarkStore(file: storeFile);
    final bookmark = await store.add('host-1', '/var/log');
    await store.remove(bookmark.id);

    expect(await store.bookmarksForHost('host-1'), isEmpty);

    final reloaded = BookmarkStore(file: storeFile);
    expect(await reloaded.bookmarksForHost('host-1'), isEmpty);
  });

  test('removing an id that was never added is a no-op', () async {
    final store = BookmarkStore(file: storeFile);
    await store.remove('does-not-exist');
    expect(await store.bookmarksForHost('host-1'), isEmpty);
  });

  test('removeForPath removes the matching host/path pair only', () async {
    final store = BookmarkStore(file: storeFile);
    await store.add('host-1', '/var/log');
    await store.add('host-1', '/etc');

    await store.removeForPath('host-1', '/var/log');

    final remaining = await store.bookmarksForHost('host-1');
    expect(remaining.map((b) => b.path), ['/etc']);
  });

  test('removeForPath does not touch another host\'s bookmark at the same '
      'path', () async {
    final store = BookmarkStore(file: storeFile);
    await store.add('host-1', '/home/dev');
    await store.add('host-2', '/home/dev');

    await store.removeForPath('host-1', '/home/dev');

    expect(await store.forPath('host-1', '/home/dev'), isNull);
    expect(await store.forPath('host-2', '/home/dev'), isNotNull);
  });

  test('renameLabel changes the label and persists it', () async {
    final store = BookmarkStore(file: storeFile);
    final bookmark = await store.add('host-1', '/var/log', label: 'Old');
    await store.renameLabel(bookmark.id, 'New name');

    final reloaded = BookmarkStore(file: storeFile);
    final all = await reloaded.bookmarksForHost('host-1');
    expect(all.single.label, 'New name');
  });

  test('renameLabel with null clears the label back to the path', () async {
    final store = BookmarkStore(file: storeFile);
    final bookmark = await store.add('host-1', '/var/log', label: 'Old');
    await store.renameLabel(bookmark.id, null);

    final all = await store.bookmarksForHost('host-1');
    expect(all.single.label, isNull);
    expect(all.single.displayLabel, '/var/log');
  });

  test('displayLabel falls back to the path when there is no label',
      () async {
    final store = BookmarkStore(file: storeFile);
    await store.add('host-1', '/var/log');

    final all = await store.bookmarksForHost('host-1');
    expect(all.single.displayLabel, '/var/log');
  });

  test('a corrupt store fails closed: bookmarks read as empty', () async {
    await storeFile.writeAsString('{ not json');
    final store = BookmarkStore(file: storeFile);
    expect(await store.bookmarksForHost('host-1'), isEmpty);
  });

  test('a malformed entry is skipped without losing the rest of the store',
      () async {
    await storeFile.writeAsString('''
    {
      "version": 1,
      "bookmarks": [
        {"id": "good", "hostId": "host-1", "path": "/etc"},
        {"id": "bad"}
      ]
    }
    ''');
    final store = BookmarkStore(file: storeFile);
    final all = await store.bookmarksForHost('host-1');
    expect(all, hasLength(1));
    expect(all.single.id, 'good');
  });

  test('bookmarks.json with no label key still loads with a null label',
      () async {
    await storeFile.writeAsString('''
    {
      "version": 1,
      "bookmarks": [
        {"id": "legacy", "hostId": "host-1", "path": "/srv"}
      ]
    }
    ''');
    final store = BookmarkStore(file: storeFile);
    final saved = await store.forPath('host-1', '/srv');
    expect(saved, isNotNull);
    expect(saved!.label, isNull);
  });
}
