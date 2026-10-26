import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/atomic_file.dart';
import 'package:secure_shell_go/services/remote_app_history.dart';

import 'support/temp_dir.dart';

void main() {
  late Directory tempDir;
  late File file;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('remote_app_history_test');
    file = File('${tempDir.path}/${RemoteAppHistory.fileName}');
  });

  tearDown(() => deleteTempDir(tempDir));

  RemoteAppHistory open() => RemoteAppHistory(file: file);

  test('a host with no history has no recent commands', () async {
    expect(await open().recent('h1'), isEmpty);
    expect(file.existsSync(), isFalse, reason: 'reading writes nothing');
  });

  test('the command used last comes first', () async {
    final history = open();
    await history.record('h1', 'gedit');
    await history.record('h1', 'xeyes');
    await history.record('h1', 'firefox');
    expect(await history.recent('h1'), ['firefox', 'xeyes', 'gedit']);
  });

  test('a command used again moves up instead of appearing twice', () async {
    final history = open();
    await history.record('h1', 'gedit');
    await history.record('h1', 'xeyes');
    await history.record('h1', 'gedit');
    expect(await history.recent('h1'), ['gedit', 'xeyes']);
  });

  test('spaces around a command do not make a second one', () async {
    final history = open();
    await history.record('h1', 'gedit');
    await history.record('h1', '  gedit \n');
    expect(await history.recent('h1'), ['gedit']);
  });

  test('keeps the last 10', () async {
    final history = open();
    for (var i = 1; i <= 13; i++) {
      await history.record('h1', 'app$i');
    }
    final recent = await history.recent('h1');
    expect(recent, hasLength(10));
    expect(recent.first, 'app13');
    expect(recent.last, 'app4');
  });

  test('every host has a list of its own', () async {
    final history = open();
    await history.record('laptop', 'gedit');
    await history.record('nas', 'xeyes');
    expect(await history.recent('laptop'), ['gedit']);
    expect(await history.recent('nas'), ['xeyes']);
    expect(await history.recent('other'), isEmpty);
  });

  test('nothing worth keeping is not kept', () async {
    final history = open();
    await history.record('h1', '');
    await history.record('h1', '   ');
    await history.record('h1', 'x' * (RemoteAppHistory.maxCommandLength + 1));
    expect(await history.recent('h1'), isEmpty);
    expect(file.existsSync(), isFalse);

    final longest = 'y' * RemoteAppHistory.maxCommandLength;
    await history.record('h1', longest);
    expect(await history.recent('h1'), [longest]);
  });

  test('forgetting one command leaves the rest', () async {
    final history = open();
    await history.record('h1', 'gedit');
    await history.record('h1', 'xeyes');
    await history.remove('h1', 'gedit');
    expect(await history.recent('h1'), ['xeyes']);
    // Not there any more, or never was: nothing happens.
    await history.remove('h1', 'gedit');
    await history.remove('nobody', 'xeyes');
    expect(await history.recent('h1'), ['xeyes']);
  });

  test('survives a restart, in order', () async {
    final first = open();
    await first.record('h1', 'gedit');
    await first.record('h1', 'xeyes');
    await first.record('h2', 'firefox');
    await first.remove('h1', 'gedit');

    final second = open();
    expect(await second.recent('h1'), ['xeyes']);
    expect(await second.recent('h2'), ['firefox']);
  });

  test('saves made without waiting land in the order they were asked',
      () async {
    final history = open();
    await Future.wait([
      history.record('h1', 'a'),
      history.record('h1', 'b'),
      history.record('h1', 'c'),
    ]);
    expect(await open().recent('h1'), ['c', 'b', 'a']);
  });

  test('is written in one piece, and leaves no temp files behind', () async {
    final history = open();
    await history.record('h1', 'gedit');
    await history.record('h1', 'xeyes');

    final decoded = jsonDecode(await file.readAsString());
    expect(decoded['hosts']['h1'], ['xeyes', 'gedit']);
    expect(
      tempDir.listSync().map((e) => e.path.split(Platform.pathSeparator).last),
      [RemoteAppHistory.fileName],
    );
  });

  test('a save that cannot finish leaves the file as it was', () async {
    final history = open();
    await history.record('h1', 'gedit');

    // The temp file the atomic write needs is a directory, so writing it
    // fails before the rename can happen.
    debugAtomicTempPath = (target) => '${target.path}.tmp';
    addTearDown(() => debugAtomicTempPath = null);
    final blocker = Directory('${file.path}.tmp')..createSync();

    // Never throws: the person's app starts regardless.
    await history.record('h1', 'xeyes');
    // The list in memory is right; the file is the last good one.
    expect(await history.recent('h1'), ['xeyes', 'gedit']);
    blocker.deleteSync();
    expect(await open().recent('h1'), ['gedit']);

    // And the next save, once the disk lets it, writes all of it.
    await history.record('h1', 'firefox');
    expect(await open().recent('h1'), ['firefox', 'xeyes', 'gedit']);
  });

  test('a file that cannot be read starts empty and is kept aside', () async {
    file.writeAsStringSync('{ this is not json');
    final history = open();
    expect(await history.recent('h1'), isEmpty);

    final aside = tempDir
        .listSync()
        .map((e) => e.path.split(Platform.pathSeparator).last)
        .where((name) => name.contains('.corrupt-'));
    expect(aside, hasLength(1));

    await history.record('h1', 'gedit');
    expect(await open().recent('h1'), ['gedit']);
  });

  test('a hand-edited file is held to the same rules as a saved one', () async {
    file.writeAsStringSync(jsonEncode({
      'version': 1,
      'hosts': {
        'h1': [
          for (var i = 0; i < 15; i++) 'app$i',
          'app0',
          '',
          42,
          '  app3  ',
        ],
        'h2': 'not a list',
        'h3': <String>[],
      },
    }));
    final history = open();
    final recent = await history.recent('h1');
    expect(recent, hasLength(10));
    expect(recent.first, 'app0');
    expect(recent.toSet(), hasLength(10));
    expect(await history.recent('h2'), isEmpty);
    expect(await history.recent('h3'), isEmpty);
  });
}
