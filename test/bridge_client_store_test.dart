import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/bridge/bridge_client_store.dart';

void main() {
  late Directory tempDir;
  late File file;
  var clock = DateTime.utc(2026, 1, 1);

  BridgeClientStore newStore({Random? random}) => BridgeClientStore(
    file: file,
    random: random,
    now: () => clock = clock.add(const Duration(minutes: 1)),
  );

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('bridge_client_store');
    file = File('${tempDir.path}/bridge_clients.json');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('starts empty when there is no file', () async {
    expect(await newStore().load(), isEmpty);
  });

  test(
    'create returns a 32-byte base64url token and stores only its hash',
    () async {
      final store = newStore();
      final created = await store.create('Desktop assistant');

      expect(created.client.name, 'Desktop assistant');
      expect(created.token, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
      expect(
        base64Url.decode(base64Url.normalize(created.token)),
        hasLength(32),
      );
      expect(
        created.client.tokenHash,
        BridgeClientStore.hashToken(created.token),
      );
      expect(created.client.tokenHash, matches(RegExp(r'^[0-9a-f]{64}$')));

      final onDisk = await file.readAsString();
      expect(onDisk, isNot(contains(created.token)));
      expect(onDisk, contains(created.client.tokenHash));
    },
  );

  test('tokens are different every time, and names are tidied', () async {
    final store = newStore();
    final a = await store.create('  A  ');
    final b = await store.create('');
    expect(a.token, isNot(b.token));
    expect(a.client.id, isNot(b.client.id));
    expect(a.client.name, 'A');
    expect(b.client.name, 'AI assistant');
  });

  test('verify accepts the token, stamps lastSeenAt and persists it', () async {
    final store = newStore();
    final created = await store.create('A');
    expect(created.client.lastSeenAt, isNull);

    final seen = await store.verify(created.token);
    expect(seen, isNotNull);
    expect(seen!.id, created.client.id);
    expect(seen.lastSeenAt, isNotNull);
    expect(seen.lastSeenAt!.isAfter(created.client.createdAt), isTrue);

    final reloaded = await newStore().load();
    expect(reloaded.single.lastSeenAt, seen.lastSeenAt);
  });

  test('verify writes lastSeenAt to disk at most once a minute', () async {
    var t = DateTime.utc(2026, 3, 1);
    final store = BridgeClientStore(file: file, now: () => t);
    final created = await store.create('A');

    t = t.add(const Duration(seconds: 10));
    final first = await store.verify(created.token);
    final firstSeen = first!.lastSeenAt;
    t = t.add(const Duration(seconds: 20));
    final second = await store.verify(created.token);
    expect(second!.lastSeenAt, t, reason: 'memory stays current');
    expect(
      (await BridgeClientStore(file: file).load()).single.lastSeenAt,
      firstSeen,
      reason: 'the second verify was inside the minute: no write',
    );

    t = t.add(const Duration(seconds: 45));
    final third = await store.verify(created.token);
    expect(
      (await BridgeClientStore(file: file).load()).single.lastSeenAt,
      third!.lastSeenAt,
    );
  });

  test('verify refuses wrong, empty and near-miss tokens', () async {
    final store = newStore();
    final created = await store.create('A');
    expect(await store.verify('nope'), isNull);
    expect(await store.verify(''), isNull);
    expect(await store.verify('${created.token}x'), isNull);
    expect(await store.verify(created.token.substring(1)), isNull);
    expect(
      await store.verify(created.client.tokenHash),
      isNull,
      reason: 'the stored hash must not work as a token',
    );
    expect((await store.load()).single.lastSeenAt, isNull);
  });

  test('verify picks the right client among several', () async {
    final store = newStore();
    await store.create('A');
    final b = await store.create('B');
    await store.create('C');
    expect((await store.verify(b.token))!.name, 'B');
  });

  test('revoke removes the client and its token stops working', () async {
    final store = newStore();
    final a = await store.create('A');
    final b = await store.create('B');
    await store.revoke(a.client.id);

    expect(await store.verify(a.token), isNull);
    expect(await store.verify(b.token), isNotNull);
    expect((await newStore().load()).map((c) => c.name), ['B']);

    // Revoking something already gone is harmless.
    await store.revoke(a.client.id);
    await store.revoke('missing');
  });

  test('clients survive a reload, in order', () async {
    final store = newStore();
    final a = await store.create('A');
    await store.create('B');
    final reloaded = newStore();
    expect((await reloaded.load()).map((c) => c.name), ['A', 'B']);
    expect(await reloaded.verify(a.token), isNotNull);
  });

  test('changes emits the list after create, verify and revoke', () async {
    final store = newStore();
    final lists = <List<BridgeClient>>[];
    final sub = store.changes.listen(lists.add);

    final a = await store.create('A');
    await store.verify(a.token);
    await store.verify('wrong');
    await store.revoke(a.client.id);
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();

    expect(lists.map((l) => l.length), [1, 1, 0]);
    expect(lists[1].single.lastSeenAt, isNotNull);
  });

  test(
    'a corrupt file starts empty and is set aside, not overwritten',
    () async {
      await file.writeAsString('{not json');
      final store = newStore();
      expect(await store.load(), isEmpty);
      final aside = tempDir.listSync().whereType<File>().where(
        (f) => f.path.contains('.corrupt-'),
      );
      expect(aside, hasLength(1));
      expect(await aside.single.readAsString(), '{not json');
    },
  );

  test('a top-level value that is not an object is set aside', () async {
    await file.writeAsString('[1, 2]');
    expect(await newStore().load(), isEmpty);
    final aside = tempDir.listSync().whereType<File>().where(
      (f) => f.path.contains('.corrupt-'),
    );
    expect(aside, hasLength(1));
    expect(await file.exists(), isFalse);
  });

  test('one malformed row is skipped, the rest load', () async {
    final good = (await newStore().create('Good')).client;
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    (json['clients'] as List).insert(0, {'id': 'x'});
    await file.writeAsString(jsonEncode(json));
    expect((await newStore().load()).map((c) => c.id), [good.id]);
  });

  test('concurrent creates all land on disk', () async {
    final store = newStore();
    await Future.wait([for (var i = 0; i < 8; i++) store.create('c$i')]);
    expect(await newStore().load(), hasLength(8));
  });

  test('the file is not readable by other accounts on POSIX', () async {
    await newStore().create('A');
    if (Platform.isWindows) return;
    final mode = file.statSync().mode & 0x1ff;
    expect(mode, 0x180, reason: '0600');
  });

  /// Makes the store's folder unwritable (POSIX), so the next save fails.
  Future<void> lockFolder(bool locked) async {
    await Process.run('chmod', [locked ? '555' : '755', tempDir.path]);
  }

  group('a save that fails changes nothing', () {
    test('create: nothing is kept, in memory or on disk', () async {
      if (Platform.isWindows) return;
      final store = newStore();
      final a = await store.create('A');
      final lists = <List<BridgeClient>>[];
      final sub = store.changes.listen(lists.add);
      await lockFolder(true);
      addTearDown(() => lockFolder(false));
      await expectLater(store.create('B'), throwsA(isA<FileSystemException>()));
      await lockFolder(false);
      await sub.cancel();
      expect((await store.load()).map((c) => c.name), ['A']);
      expect((await newStore().load()).map((c) => c.name), ['A']);
      expect(lists, isEmpty);
      expect(await store.verify(a.token), isNotNull);
    });

    test('revoke: the pairing is still there and still works', () async {
      if (Platform.isWindows) return;
      final store = newStore();
      final a = await store.create('A');
      final b = await store.create('B');
      await store.create('C');
      await lockFolder(true);
      addTearDown(() => lockFolder(false));
      await expectLater(
        store.revoke(b.client.id),
        throwsA(isA<FileSystemException>()),
      );
      await lockFolder(false);
      expect((await store.load()).map((c) => c.name), ['A', 'B', 'C']);
      expect(await store.verify(b.token), isNotNull);
      expect(await store.verify(a.token), isNotNull);
      expect((await newStore().load()).map((c) => c.name), ['A', 'B', 'C']);
    });

    test('confirm: the pairing stays pending', () async {
      if (Platform.isWindows) return;
      final store = newStore();
      final p = await store.create('P', pending: true);
      await lockFolder(true);
      addTearDown(() => lockFolder(false));
      await expectLater(
        store.confirm(p.client.id),
        throwsA(isA<FileSystemException>()),
      );
      await lockFolder(false);
      expect((await store.load()).single.pending, isTrue);
      expect(await store.verify(p.token), isNull);
    });
  });

  test('a pairing whose confirmation is still being written does not sign in',
      () async {
    final store = newStore();
    final p = await store.create('P', pending: true);
    final confirming = store.confirm(p.client.id);
    expect(await store.verify(p.token), isNull);
    await confirming;
    expect(await store.verify(p.token), isNotNull);
  });

  group('pending pairings', () {
    test('never sign in until confirmed', () async {
      final store = newStore();
      final p = await store.create('One-click', pending: true);
      expect(p.client.pending, isTrue);
      expect(await store.verify(p.token), isNull);

      await store.confirm(p.client.id);
      expect((await store.load()).single.pending, isFalse);
      expect(await store.verify(p.token), isNotNull);

      // Confirmed on disk too: a fresh start keeps it, and it signs in.
      final reloaded = newStore();
      expect((await reloaded.load()).single.pending, isFalse);
      expect(await reloaded.verify(p.token), isNotNull);

      // Confirming again, or something gone, is harmless.
      await store.confirm(p.client.id);
      await store.confirm('missing');
    });

    test('one still pending at the next start is removed, on disk too', () async {
      final store = newStore();
      final kept = await store.create('Kept');
      final p = await store.create('Abandoned', pending: true);
      expect(await file.readAsString(), contains(p.client.id));

      final reloaded = newStore();
      expect((await reloaded.load()).map((c) => c.name), ['Kept']);
      expect(await reloaded.verify(p.token), isNull);
      expect(await reloaded.verify(kept.token), isNotNull);
      expect(await file.readAsString(), isNot(contains(p.client.id)));
    });

    test('a file without the field reads as not pending', () async {
      final a = await newStore().create('A');
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final row = (json['clients'] as List).single as Map<String, dynamic>;
      expect(row.containsKey('pending'), isFalse);
      final reloaded = newStore();
      expect((await reloaded.load()).single.pending, isFalse);
      expect(await reloaded.verify(a.token), isNotNull);
    });
  });
}
