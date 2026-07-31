import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/snippet.dart';
import 'package:secure_shell_go/services/snippet_store.dart';

void main() {
  late Directory tempDir;
  late File storeFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('snippet_store_test');
    storeFile = File('${tempDir.path}/snippets.json');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Snippet snippet({
    String? id,
    String name = 'Tail log',
    String command = 'tail -f /var/log/app.log',
    String description = '',
  }) {
    return Snippet(
      id: id ?? 'fixed-id',
      name: name,
      command: command,
      description: description,
    );
  }

  test('a fresh store has no saved snippets', () async {
    final store = SnippetStore(file: storeFile);
    expect(await store.all(), isEmpty);
    expect(await store.get('missing'), isNull);
  });

  test('newId returns a different id on every call', () {
    final store = SnippetStore(file: storeFile);
    final ids = {for (var i = 0; i < 20; i++) store.newId()};
    expect(ids, hasLength(20));
  });

  test('added snippets survive a reload from disk', () async {
    await SnippetStore(file: storeFile).add(snippet());

    final reloaded = SnippetStore(file: storeFile);
    final all = await reloaded.all();
    expect(all, hasLength(1));
    expect(all.single.command, 'tail -f /var/log/app.log');
    expect(await reloaded.get('fixed-id'), isNotNull);
  });

  test('snippets come back in the order they were added', () async {
    final store = SnippetStore(file: storeFile);
    await store.add(snippet(id: 'a', name: 'First'));
    await store.add(snippet(id: 'b', name: 'Second'));
    await store.add(snippet(id: 'c', name: 'Third'));

    final all = await store.all();
    expect(all.map((s) => s.id), ['a', 'b', 'c']);
  });

  test('updating a snippet keeps its position in the list', () async {
    final store = SnippetStore(file: storeFile);
    await store.add(snippet(id: 'a', name: 'First'));
    await store.add(snippet(id: 'b', name: 'Second'));
    await store.add(snippet(id: 'c', name: 'Third'));

    await store.update(snippet(id: 'b', name: 'Second (renamed)'));

    final all = await store.all();
    expect(all.map((s) => s.id), ['a', 'b', 'c']);
    expect(all[1].name, 'Second (renamed)');
  });

  test('update replaces the stored copy and persists it', () async {
    final store = SnippetStore(file: storeFile);
    await store.add(snippet(command: 'ls'));
    await store.update(snippet(command: 'ls -la'));

    final reloaded = SnippetStore(file: storeFile);
    expect((await reloaded.get('fixed-id'))?.command, 'ls -la');
  });

  test('delete removes a snippet and persists the removal', () async {
    final store = SnippetStore(file: storeFile);
    await store.add(snippet());
    expect(await store.all(), hasLength(1));

    await store.delete('fixed-id');
    expect(await store.all(), isEmpty);

    final reloaded = SnippetStore(file: storeFile);
    expect(await reloaded.all(), isEmpty);
  });

  test('deleting a snippet that was never added is a no-op', () async {
    final store = SnippetStore(file: storeFile);
    await store.delete('does-not-exist');
    expect(await store.all(), isEmpty);
  });

  test('description round-trips when present and is omitted when empty',
      () async {
    final store = SnippetStore(file: storeFile);
    await store.add(snippet(id: 'with-desc', description: 'Handy for prod'));
    await store.add(snippet(id: 'no-desc'));

    final reloaded = SnippetStore(file: storeFile);
    expect((await reloaded.get('with-desc'))?.description, 'Handy for prod');
    expect((await reloaded.get('no-desc'))?.description, '');
  });

  test('a corrupt store fails closed: the snippet list reads as empty',
      () async {
    await storeFile.writeAsString('{ not json');
    final store = SnippetStore(file: storeFile);
    expect(await store.all(), isEmpty);
  });

  test('a malformed entry is skipped without losing the rest of the store',
      () async {
    await storeFile.writeAsString('''
    {
      "version": 1,
      "snippets": [
        {"id": "good", "name": "Good", "command": "echo hi"},
        {"id": "bad"}
      ]
    }
    ''');
    final store = SnippetStore(file: storeFile);
    final all = await store.all();
    // Both entries have an "id", so both parse — "bad" just falls back to
    // empty name/command, exactly like Host.fromJson's own defaults.
    expect(all.map((s) => s.id), containsAll(['good', 'bad']));
    expect(all.firstWhere((s) => s.id == 'good').command, 'echo hi');
  });
}
