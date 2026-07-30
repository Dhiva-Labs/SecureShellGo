import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/device_storage.dart';

void main() {
  group('filePathFromUri', () {
    test('a file:// URI becomes a plain path', () {
      expect(filePathFromUri('file:///home/alex/Downloads/report.pdf'),
          '/home/alex/Downloads/report.pdf');
    });

    test('a path with spaces round-trips through percent-encoding', () {
      expect(
        filePathFromUri('file:///home/alex/Downloads/my%20report.pdf'),
        '/home/alex/Downloads/my report.pdf',
      );
    });

    test('a non-file scheme has nothing sensible to open with', () {
      expect(filePathFromUri('content://com.android.providers/1'), isNull);
      expect(filePathFromUri('https://example.com/file.pdf'), isNull);
    });

    test('unparseable text is null, not a thrown exception', () {
      expect(filePathFromUri('not a uri at all: %'), isNull);
    });
  });

  group('createDefaultDeviceStorage', () {
    test('on this (desktop) test host, resolves to DesktopDeviceStorage', () {
      // flutter test always runs on a real desktop OS (never Android), so
      // this exercises the real Platform.isLinux/.isWindows/.isMacOS branch
      // rather than a stand-in for it.
      expect(createDefaultDeviceStorage(), isA<DesktopDeviceStorage>());
    });
  });

  group('DesktopDeviceStorage', () {
    late Directory tempDir;
    late DesktopDeviceStorage storage;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('device_storage_test');
      storage = DesktopDeviceStorage(
        downloadsDirectoryResolver: () async => tempDir,
      );
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test('ensurePermission is always granted — nothing to ask for', () async {
      expect(await storage.ensurePermission(), isTrue);
    });

    test('downloadExists is false until the file is actually written',
        () async {
      expect(await storage.downloadExists('report.pdf'), isFalse);

      final writer = await storage.beginDownload('report.pdf');
      await writer.add(Uint8List.fromList('hi'.codeUnits));
      await writer.finish();

      expect(await storage.downloadExists('report.pdf'), isTrue);
    });

    test('a download writes exactly the bytes it was given', () async {
      final writer = await storage.beginDownload('notes.txt');
      await writer.add(Uint8List.fromList('hello '.codeUnits));
      await writer.add(Uint8List.fromList('world'.codeUnits));
      final saved = await writer.finish();

      expect(saved.displayName, 'notes.txt');
      expect(saved.uri, 'file://${tempDir.path}/notes.txt');
      expect(
        await File('${tempDir.path}/notes.txt').readAsString(),
        'hello world',
      );
    });

    test('overwrite: false de-duplicates instead of replacing', () async {
      await File('${tempDir.path}/notes.txt').writeAsString('original');

      final writer = await storage.beginDownload('notes.txt');
      final saved = await writer.finish();

      expect(saved.displayName, 'notes (1).txt');
      expect(await File('${tempDir.path}/notes.txt').readAsString(),
          'original');
    });

    test('overwrite: true replaces the existing file in place', () async {
      await File('${tempDir.path}/notes.txt').writeAsString('original');

      final writer = await storage.beginDownload('notes.txt', overwrite: true);
      await writer.add(Uint8List.fromList('replaced'.codeUnits));
      final saved = await writer.finish();

      expect(saved.displayName, 'notes.txt');
      expect(await File('${tempDir.path}/notes.txt').readAsString(),
          'replaced');
    });

    test('relativeDirectory nests the file, creating folders as needed',
        () async {
      final writer = await storage.beginDownload(
        'photo.jpg',
        relativeDirectory: 'vacation/day1',
      );
      await writer.finish();

      expect(
        await File('${tempDir.path}/vacation/day1/photo.jpg').exists(),
        isTrue,
      );
    });

    test('a hostile relative directory cannot escape the Downloads root',
        () async {
      final writer = await storage.beginDownload(
        'evil.sh',
        relativeDirectory: '../../etc',
      );
      await writer.finish();

      // Sanitised down to a bare segment nested under tempDir, never a path
      // that climbed out of it.
      expect(await File('${tempDir.path}/etc/evil.sh').exists(), isTrue);
      expect(await File('${tempDir.parent.path}/etc/evil.sh').exists(),
          isFalse);
    });

    test('a remote name carrying its own traversal is reduced to its '
        'basename', () async {
      final writer = await storage.beginDownload('../../evil.sh');
      await writer.finish();

      expect(await File('${tempDir.path}/evil.sh').exists(), isTrue);
    });

    test('abort deletes the partial file rather than leaving it looking '
        'complete', () async {
      final writer = await storage.beginDownload('big-file.bin');
      await writer.add(Uint8List.fromList(List.filled(10, 1)));
      await writer.abort();

      expect(await File('${tempDir.path}/big-file.bin').exists(), isFalse);
    });

    test('add/finish/abort are no-ops once already finished', () async {
      final writer = await storage.beginDownload('idempotent.txt');
      await writer.add(Uint8List.fromList('data'.codeUnits));
      await writer.finish();

      // None of these should throw or touch the file a second time.
      await writer.add(Uint8List.fromList('more'.codeUnits));
      await writer.abort();

      expect(
        await File('${tempDir.path}/idempotent.txt').readAsString(),
        'data',
      );
    });

    test('a missing Downloads directory is a clear error, not a crash',
        () async {
      final storage = DesktopDeviceStorage(
        downloadsDirectoryResolver: () async => null,
      );

      await expectLater(
        storage.beginDownload('report.pdf'),
        throwsA(isA<DeviceStorageException>()),
      );
    });
  });

  group('readLocalDirectoryTree', () {
    late Directory temp;

    setUp(() async {
      temp =
          await Directory.systemTemp.createTemp('local_directory_tree_test');
    });

    tearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    test('finds every file and preserves the relative shape', () async {
      final root = Directory('${temp.path}/pm-folder')..createSync();
      File('${root.path}/a.txt').writeAsStringSync('aaa');
      File('${root.path}/b.txt').writeAsStringSync('bbbb');
      final sub = Directory('${root.path}/sub')..createSync();
      File('${sub.path}/c.txt').writeAsStringSync('ccccc');

      final tree = await readLocalDirectoryTree(root.path);

      expect(tree.rootName, 'pm-folder');
      expect(tree.fileCount, 3);
      expect(tree.totalBytes, 3 + 4 + 5);
      expect(
        tree.files.map((f) => f.relativePath).toList()..sort(),
        ['a.txt', 'b.txt', 'sub/c.txt'],
      );
      expect(tree.directories, contains('sub'));
    });

    test('records empty subdirectories so the upload can recreate them',
        () async {
      final root = Directory('${temp.path}/with-empty')..createSync();
      Directory('${root.path}/logs').createSync();

      final tree = await readLocalDirectoryTree(root.path);

      expect(tree.files, isEmpty);
      expect(tree.directories, ['logs']);
      // isEmpty is *about files* — the directory list still keeps the shape.
      expect(tree.isEmpty, isFalse);
    });

    test('symlinks are not chased (would loop or double-upload)', () async {
      // The whole reason the walk exists as its own thing rather than a
      // straight `Directory.list(recursive: true)`.
      final root = Directory('${temp.path}/with-link')..createSync();
      File('${root.path}/real.txt').writeAsStringSync('hello');
      try {
        Link('${root.path}/loop').createSync('..');
      } on FileSystemException {
        // Windows without dev-mode: skip the symlink half quietly.
      }

      final tree = await readLocalDirectoryTree(root.path);

      // The real file lands; the link is silently skipped rather than
      // crawling out of `with-link/`.
      expect(tree.files.map((f) => f.relativePath), contains('real.txt'));
      expect(
        tree.files.map((f) => f.relativePath),
        isNot(contains('loop')),
      );
    });

    test('a missing root fails loudly, not silently', () async {
      await expectLater(
        readLocalDirectoryTree('${temp.path}/does-not-exist'),
        throwsA(isA<LocalDirectoryWalkFailure>()),
      );
    });
  });
}
