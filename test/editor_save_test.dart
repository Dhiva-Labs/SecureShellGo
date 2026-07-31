import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/remote_entry.dart';
import 'package:secure_shell_go/services/editor_document.dart';
import 'package:secure_shell_go/services/editor_save.dart';
import 'package:secure_shell_go/services/sftp_service.dart';

/// One file on the fake server: contents, and the two fields the conflict
/// guard compares.
class FakeFile {
  FakeFile(this.bytes, {this.modified, this.permissions});

  Uint8List bytes;
  DateTime? modified;
  int? permissions;
}

/// A remote filesystem that holds real bytes.
///
/// The seam being exercised is [RemoteFileSystem] plus [RemoteFileMetadata],
/// which is the whole reason a save-back can be tested at all without a
/// server. Unlike `remote_copy_test.dart`'s `MemoryFs` — which only tracks
/// sizes, because a transfer only has to get the byte *count* right — this
/// one keeps contents, because the entire question here is whether the file
/// on the server still says what it said before a failed save.
class EditorFs implements RemoteFileSystem, RemoteFileMetadata {
  final Map<String, FakeFile> files = {};

  /// Every path ever opened for writing, in order. A conflict must leave this
  /// empty: "nothing was written" is only true if nothing was even opened.
  final List<String> opened = [];
  final List<String> removed = [];
  final List<(String, String)> renamed = [];
  final List<String> chmodded = [];
  final List<String> read = [];

  /// Thrown out of the next [openWrite].
  Object? failOpenWrite;

  /// Thrown out of the writer's `add`.
  Object? failWrite;

  /// Reported by [sizeOf] instead of the truth, to simulate a server whose
  /// idea of what landed disagrees with ours.
  final Map<String, int?> reportedSizes = {};

  /// Renaming *onto* one of these fails, the way a strict SFTP server
  /// refuses to clobber an existing name.
  final Set<String> refuseRenameOnto = {};

  /// Every rename fails, including the retry after the remove.
  bool failAllRenames = false;

  bool refuseChmod = false;

  /// Runs before each stat, so a test can change the world underneath a save
  /// exactly the way another editor would.
  void Function()? beforeStat;

  @override
  Future<RemoteFileStat?> statFile(String path) async {
    beforeStat?.call();
    final file = files[path];
    if (file == null) return null;
    return RemoteFileStat(
      size: file.bytes.length,
      modified: file.modified,
      permissions: file.permissions,
    );
  }

  @override
  Future<bool> setPermissions(String path, int permissions) async {
    chmodded.add(path);
    if (refuseChmod) return false;
    files[path]?.permissions = permissions;
    return true;
  }

  @override
  Future<int?> sizeOf(String path) async {
    if (reportedSizes.containsKey(path)) return reportedSizes[path];
    return files[path]?.bytes.length;
  }

  @override
  Future<bool> exists(String path) async => files.containsKey(path);

  @override
  Future<int> download(
    String remotePath, {
    required Future<void> Function(Uint8List chunk) write,
    TransferProgress? onProgress,
    CancelCheck? isCancelled,
  }) async {
    read.add(remotePath);
    final file = files[remotePath];
    if (file == null) {
      throw SftpFailure('"$remotePath" is not there any more.');
    }
    // Chunked, like the real one, so a cap check inside the write callback is
    // exercised the way it will be in production.
    const chunk = 64;
    var moved = 0;
    while (moved < file.bytes.length) {
      final end = (moved + chunk).clamp(0, file.bytes.length);
      await write(Uint8List.sublistView(file.bytes, moved, end));
      moved = end;
      onProgress?.call(moved);
    }
    return moved;
  }

  @override
  Future<RemoteFileWriter> openWrite(String remotePath) async {
    final failure = failOpenWrite;
    if (failure != null) throw failure;
    opened.add(remotePath);
    return FakeWriter(this, remotePath);
  }

  @override
  Future<void> remove(String path) async {
    removed.add(path);
    files.remove(path);
  }

  @override
  Future<void> rename(String from, String to) async {
    if (failAllRenames || refuseRenameOnto.contains(to)) {
      throw SftpFailure('The server refused: rename');
    }
    renamed.add((from, to));
    final file = files.remove(from);
    if (file != null) files[to] = file;
  }

  @override
  Future<String> home() async => '/home/dev';

  @override
  Future<String> resolve(String path) async => path;

  @override
  Future<List<RemoteEntry>> list(String path) async => const [];

  @override
  Future<int> upload(
    String localPath,
    String remotePath, {
    TransferProgress? onProgress,
    CancelCheck? isCancelled,
  }) async =>
      throw UnimplementedError('the editor never uploads a local file');

  @override
  Future<void> mkdir(String path) async => throw UnimplementedError();

  @override
  Future<void> removeDirectory(String path) async =>
      throw UnimplementedError();

  @override
  Future<bool> isDirectory(String path) async => false;

  @override
  Future<void> close() async {}
}

class FakeWriter implements RemoteFileWriter {
  FakeWriter(this._fs, this._path);

  final EditorFs _fs;
  final String _path;
  final BytesBuilder _buffer = BytesBuilder();
  bool closed = false;

  @override
  Future<void> add(Uint8List chunk) async {
    final failure = _fs.failWrite;
    if (failure != null) throw failure;
    _buffer.add(chunk);
    // Visible under its temporary name as it grows, like the real thing.
    _fs.files[_path] = FakeFile(
      Uint8List.fromList(_buffer.toBytes()),
      modified: DateTime.utc(2030),
      permissions: 0x1A4,
    );
  }

  @override
  Future<void> close() async {
    closed = true;
  }

  @override
  Future<void> abort() async {
    closed = true;
    _fs.files.remove(_path);
  }
}

Uint8List bytesOf(String text) => Uint8List.fromList(utf8.encode(text));

String textOf(EditorFs fs, String path) => utf8.decode(fs.files[path]!.bytes);

const String original = 'server {\n  listen 80;\n}\n';

/// A filesystem holding `/etc/nginx.conf`, plus the fingerprint an open would
/// have recorded for it.
(EditorFs, RemoteFingerprint) withNginxConf({int permissions = 0x1ED}) {
  final fs = EditorFs();
  fs.files['/etc/nginx.conf'] = FakeFile(
    bytesOf(original),
    modified: DateTime.utc(2026, 7, 31, 12),
    permissions: permissions,
  );
  return (
    fs,
    RemoteFingerprint(
      size: original.length,
      modified: DateTime.utc(2026, 7, 31, 12),
    ),
  );
}

void main() {
  group('opening', () {
    test('reads the file and records what it looked like', () async {
      final (fs, _) = withNginxConf();
      final opened = await openRemoteText(
        fs: fs,
        metadata: fs,
        path: '/etc/nginx.conf',
      );
      expect(opened.text, original);
      expect(opened.lineEndings, LineEndingStyle.lf);
      expect(opened.hadInvalidUtf8, isFalse);
      expect(opened.permissions, 0x1ED);
      expect(opened.fingerprint.size, original.length);
      expect(opened.fingerprint.modified, DateTime.utc(2026, 7, 31, 12));
    });

    test('refuses an oversized file without reading a byte of it', () async {
      final fs = EditorFs();
      fs.files['/var/log/huge.log'] =
          FakeFile(Uint8List(editorMaxFileBytes + 1));
      await expectLater(
        openRemoteText(fs: fs, metadata: fs, path: '/var/log/huge.log'),
        throwsA(isA<EditorOpenRefused>()
            .having((e) => e.reason, 'reason', EditorRefusal.tooLarge)),
      );
      // The point of stat-before-read: nothing came over the wire.
      expect(fs.read, isEmpty);
    });

    test('refuses a binary file, after reading it to find out', () async {
      final fs = EditorFs();
      fs.files['/bin/thing'] =
          FakeFile(Uint8List.fromList([0x7F, 0x45, 0x4C, 0x46, 0, 1, 2]));
      await expectLater(
        openRemoteText(fs: fs, metadata: fs, path: '/bin/thing'),
        throwsA(isA<EditorOpenRefused>()
            .having((e) => e.reason, 'reason', EditorRefusal.binary)),
      );
    });

    test('carries CRLF through so a save can put it back', () async {
      final fs = EditorFs();
      fs.files['/etc/a.conf'] = FakeFile(bytesOf('a\r\nb\r\n'));
      final opened =
          await openRemoteText(fs: fs, metadata: fs, path: '/etc/a.conf');
      expect(opened.lineEndings, LineEndingStyle.crlf);
      expect(opened.text, 'a\nb\n');
    });

    test('flags a file that was not valid UTF-8', () async {
      final fs = EditorFs();
      fs.files['/etc/latin.txt'] =
          FakeFile(Uint8List.fromList([0x61, 0xFF, 0x62]));
      final opened =
          await openRemoteText(fs: fs, metadata: fs, path: '/etc/latin.txt');
      expect(opened.hadInvalidUtf8, isTrue);
    });

    test('works without a metadata seam, on size alone', () async {
      final (fs, _) = withNginxConf();
      final opened =
          await openRemoteText(fs: fs, path: '/etc/nginx.conf');
      expect(opened.text, original);
      expect(opened.fingerprint.size, original.length);
      expect(opened.fingerprint.modified, isNull);
      expect(opened.permissions, isNull);
    });
  });

  group('the conflict guard', () {
    test('a changed mtime stops the save before anything is written',
        () async {
      final (fs, fingerprint) = withNginxConf();
      // Someone else saved the file while it sat open on screen.
      fs.files['/etc/nginx.conf'] = FakeFile(
        bytesOf('server {\n  listen 8080;\n}\n'),
        modified: DateTime.utc(2026, 7, 31, 13),
        permissions: 0x1ED,
      );

      await expectLater(
        saveRemoteText(
          fs: fs,
          metadata: fs,
          path: '/etc/nginx.conf',
          text: 'mine\n',
          lineEndings: LineEndingStyle.lf,
          expected: fingerprint,
        ),
        throwsA(isA<EditorSaveConflict>()
            .having((e) => e.reason, 'reason', SaveConflictReason.changed)),
      );

      // The three ways this could have gone wrong, each checked separately.
      expect(fs.opened, isEmpty, reason: 'nothing was opened for writing');
      expect(fs.renamed, isEmpty, reason: 'nothing was published');
      expect(fs.removed, isEmpty, reason: 'nothing was deleted');
      expect(textOf(fs, '/etc/nginx.conf'), 'server {\n  listen 8080;\n}\n',
          reason: 'their edit survived intact');
      expect(fs.files.keys, hasLength(1), reason: 'no temp file left behind');
    });

    test('a changed size stops the save even when the mtime did not move',
        () async {
      final (fs, fingerprint) = withNginxConf();
      fs.files['/etc/nginx.conf'] = FakeFile(
        bytesOf('$original# appended\n'),
        modified: DateTime.utc(2026, 7, 31, 12),
        permissions: 0x1ED,
      );

      await expectLater(
        saveRemoteText(
          fs: fs,
          metadata: fs,
          path: '/etc/nginx.conf',
          text: 'mine\n',
          lineEndings: LineEndingStyle.lf,
          expected: fingerprint,
        ),
        throwsA(isA<EditorSaveConflict>()
            .having((e) => e.reason, 'reason', SaveConflictReason.changed)),
      );
      expect(fs.opened, isEmpty);
      expect(textOf(fs, '/etc/nginx.conf'), contains('# appended'));
    });

    test('a file that vanished is its own kind of conflict', () async {
      final (fs, fingerprint) = withNginxConf();
      fs.files.remove('/etc/nginx.conf');

      await expectLater(
        saveRemoteText(
          fs: fs,
          metadata: fs,
          path: '/etc/nginx.conf',
          text: 'mine\n',
          lineEndings: LineEndingStyle.lf,
          expected: fingerprint,
        ),
        throwsA(isA<EditorSaveConflict>()
            .having((e) => e.reason, 'reason', SaveConflictReason.vanished)),
      );
      expect(fs.opened, isEmpty);
    });

    test('the conflict carries what the file looks like now', () async {
      final (fs, fingerprint) = withNginxConf();
      fs.files['/etc/nginx.conf'] = FakeFile(
        bytesOf('theirs\n'),
        modified: DateTime.utc(2026, 7, 31, 14),
        permissions: 0x1ED,
      );
      try {
        await saveRemoteText(
          fs: fs,
          metadata: fs,
          path: '/etc/nginx.conf',
          text: 'mine\n',
          lineEndings: LineEndingStyle.lf,
          expected: fingerprint,
        );
        fail('expected a conflict');
      } on EditorSaveConflict catch (e) {
        expect(e.current?.size, 'theirs\n'.length);
        expect(e.current?.modified, DateTime.utc(2026, 7, 31, 14));
      }
    });

    test('force is what "keep mine" spends to get past the guard', () async {
      final (fs, fingerprint) = withNginxConf();
      fs.files['/etc/nginx.conf'] = FakeFile(
        bytesOf('theirs\n'),
        modified: DateTime.utc(2026, 7, 31, 14),
        permissions: 0x1ED,
      );

      final outcome = await saveRemoteText(
        fs: fs,
        metadata: fs,
        path: '/etc/nginx.conf',
        text: 'mine\n',
        lineEndings: LineEndingStyle.lf,
        expected: fingerprint,
        force: true,
      );
      expect(outcome.bytesWritten, 'mine\n'.length);
      expect(textOf(fs, '/etc/nginx.conf'), 'mine\n');
    });

    test('an unchanged file saves without complaint', () async {
      final (fs, fingerprint) = withNginxConf();
      final outcome = await saveRemoteText(
        fs: fs,
        metadata: fs,
        path: '/etc/nginx.conf',
        text: 'server {\n  listen 443;\n}\n',
        lineEndings: LineEndingStyle.lf,
        expected: fingerprint,
      );
      expect(textOf(fs, '/etc/nginx.conf'), 'server {\n  listen 443;\n}\n');
      expect(outcome.fingerprint.size, 'server {\n  listen 443;\n}\n'.length);
    });

    test('a size-only fingerprint still guards, without a metadata seam',
        () async {
      final (fs, _) = withNginxConf();
      final expected = RemoteFingerprint(size: original.length);
      fs.files['/etc/nginx.conf'] = FakeFile(bytesOf('much longer now\n\n\n'));

      await expectLater(
        saveRemoteText(
          fs: fs,
          path: '/etc/nginx.conf',
          text: 'mine\n',
          lineEndings: LineEndingStyle.lf,
          expected: expected,
        ),
        throwsA(isA<EditorSaveConflict>()),
      );
      expect(fs.opened, isEmpty);
    });
  });

  group('the temp-then-rename write path', () {
    test('writes to a hidden temp beside the file, then renames over it',
        () async {
      final (fs, fingerprint) = withNginxConf();
      await saveRemoteText(
        fs: fs,
        metadata: fs,
        path: '/etc/nginx.conf',
        text: 'new\n',
        lineEndings: LineEndingStyle.lf,
        expected: fingerprint,
        temporaryNamer: (name) => '.$name.ssg-edit-fixed',
      );

      expect(fs.opened, ['/etc/.nginx.conf.ssg-edit-fixed'],
          reason: 'the temp lands in the same directory, hidden');
      expect(fs.renamed,
          [('/etc/.nginx.conf.ssg-edit-fixed', '/etc/nginx.conf')]);
      expect(textOf(fs, '/etc/nginx.conf'), 'new\n');
      expect(fs.files.keys, hasLength(1), reason: 'no temp left behind');
    });

    test('the default temp name is hidden and stamped for this app', () async {
      final (fs, fingerprint) = withNginxConf();
      await saveRemoteText(
        fs: fs,
        metadata: fs,
        path: '/etc/nginx.conf',
        text: 'new\n',
        lineEndings: LineEndingStyle.lf,
        expected: fingerprint,
      );
      final temp = fs.opened.single;
      expect(temp, startsWith('/etc/.nginx.conf.ssg-edit-'));
    });

    test('applies the line-ending style the file came with', () async {
      final fs = EditorFs();
      fs.files['/etc/a.conf'] = FakeFile(bytesOf('a\r\nb\r\n'));
      await saveRemoteText(
        fs: fs,
        metadata: fs,
        path: '/etc/a.conf',
        text: 'a\nb\nc\n',
        lineEndings: LineEndingStyle.crlf,
        expected: RemoteFingerprint(size: 6),
      );
      expect(textOf(fs, '/etc/a.conf'), 'a\r\nb\r\nc\r\n');
    });

    test('a failed write leaves the original untouched and cleans up',
        () async {
      final (fs, fingerprint) = withNginxConf();
      fs.failWrite = const SftpFailure('disk full');

      await expectLater(
        saveRemoteText(
          fs: fs,
          metadata: fs,
          path: '/etc/nginx.conf',
          text: 'new\n',
          lineEndings: LineEndingStyle.lf,
          expected: fingerprint,
          temporaryNamer: (name) => '.$name.ssg-edit-fixed',
        ),
        throwsA(isA<SftpFailure>()),
      );
      expect(textOf(fs, '/etc/nginx.conf'), original,
          reason: 'the original is exactly as it was');
      expect(fs.files.containsKey('/etc/.nginx.conf.ssg-edit-fixed'), isFalse,
          reason: 'the temp was aborted away');
      expect(fs.renamed, isEmpty);
    });

    test('a short write is caught by the size check, before the rename',
        () async {
      final (fs, fingerprint) = withNginxConf();
      // The server acknowledges the write but reports fewer bytes than were
      // sent — the case the verification exists for.
      fs.reportedSizes['/etc/.nginx.conf.ssg-edit-fixed'] = 2;

      await expectLater(
        saveRemoteText(
          fs: fs,
          metadata: fs,
          path: '/etc/nginx.conf',
          text: 'a much longer body than two bytes\n',
          lineEndings: LineEndingStyle.lf,
          expected: fingerprint,
          temporaryNamer: (name) => '.$name.ssg-edit-fixed',
        ),
        throwsA(isA<EditorSaveFailure>()
            .having((e) => e.originalIntact, 'originalIntact', isTrue)),
      );
      expect(textOf(fs, '/etc/nginx.conf'), original);
      expect(fs.renamed, isEmpty);
      expect(fs.files.containsKey('/etc/.nginx.conf.ssg-edit-fixed'), isFalse);
    });

    test('a failure to open the temp never touches the original', () async {
      final (fs, fingerprint) = withNginxConf();
      fs.failOpenWrite = const SftpFailure('permission denied');

      await expectLater(
        saveRemoteText(
          fs: fs,
          metadata: fs,
          path: '/etc/nginx.conf',
          text: 'new\n',
          lineEndings: LineEndingStyle.lf,
          expected: fingerprint,
        ),
        throwsA(isA<SftpFailure>()),
      );
      expect(textOf(fs, '/etc/nginx.conf'), original);
      expect(fs.removed, isEmpty);
    });

    test('a strict server is retried after the original is removed', () async {
      final fs = _StrictRenameFs();
      fs.files['/etc/nginx.conf'] = FakeFile(
        bytesOf(original),
        modified: DateTime.utc(2026, 7, 31, 12),
        permissions: 0x1ED,
      );
      final outcome = await saveRemoteText(
        fs: fs,
        metadata: fs,
        path: '/etc/nginx.conf',
        text: 'new\n',
        lineEndings: LineEndingStyle.lf,
        expected: RemoteFingerprint(
          size: original.length,
          modified: DateTime.utc(2026, 7, 31, 12),
        ),
        temporaryNamer: (name) => '.$name.ssg-edit-fixed',
      );
      expect(outcome.bytesWritten, 'new\n'.length);
      expect(fs.removed, ['/etc/nginx.conf'],
          reason: 'the original had to go first');
      expect(textOf(fs, '/etc/nginx.conf'), 'new\n');
      expect(fs.files.keys, hasLength(1));
    });

    test('a rename that fails after the remove names the stranded file',
        () async {
      final (fs, fingerprint) = withNginxConf();
      fs.failAllRenames = true;

      try {
        await saveRemoteText(
          fs: fs,
          metadata: fs,
          path: '/etc/nginx.conf',
          text: 'new\n',
          lineEndings: LineEndingStyle.lf,
          expected: fingerprint,
          temporaryNamer: (name) => '.$name.ssg-edit-fixed',
        );
        fail('expected a save failure');
      } on EditorSaveFailure catch (e) {
        // The one case where the original is gone. What matters is that the
        // user is told exactly where their text is.
        expect(e.originalIntact, isFalse);
        expect(e.strandedTemporaryPath, '/etc/.nginx.conf.ssg-edit-fixed');
        expect(e.message, contains('/etc/.nginx.conf.ssg-edit-fixed'));
      }
      // And that it really is there, with the complete new contents.
      expect(textOf(fs, '/etc/.nginx.conf.ssg-edit-fixed'), 'new\n');
    });
  });

  group('permissions', () {
    test('an executable script keeps its mode across a save', () async {
      final fs = EditorFs();
      fs.files['/usr/local/bin/deploy'] = FakeFile(
        bytesOf('#!/bin/sh\necho hi\n'),
        modified: DateTime.utc(2026, 7, 31, 12),
        permissions: 0x1ED, // 0755
      );
      final outcome = await saveRemoteText(
        fs: fs,
        metadata: fs,
        path: '/usr/local/bin/deploy',
        text: '#!/bin/sh\necho bye\n',
        lineEndings: LineEndingStyle.lf,
        expected: RemoteFingerprint(
          size: '#!/bin/sh\necho hi\n'.length,
          modified: DateTime.utc(2026, 7, 31, 12),
        ),
        permissions: 0x1ED,
      );
      // The temp landed 0644 (see FakeWriter); the save had to put 0755 back
      // or the script would no longer run.
      expect(outcome.permissionsRestored, isTrue);
      expect(outcome.permissionsLost, isFalse);
      expect(fs.files['/usr/local/bin/deploy']!.permissions, 0x1ED);
    });

    test('a mode that already survived the rename is left alone', () async {
      final (fs, fingerprint) = withNginxConf(permissions: 0x1A4);
      final outcome = await saveRemoteText(
        fs: fs,
        metadata: fs,
        path: '/etc/nginx.conf',
        text: 'new\n',
        lineEndings: LineEndingStyle.lf,
        expected: fingerprint,
        permissions: 0x1A4, // the same 0644 the temp is created with
      );
      expect(fs.chmodded, isEmpty);
      expect(outcome.permissionsRestored, isFalse);
      expect(outcome.permissionsLost, isFalse);
    });

    test('a server that refuses chmod is reported, not treated as a failure',
        () async {
      final fs = EditorFs()..refuseChmod = true;
      fs.files['/srv/run.sh'] = FakeFile(
        bytesOf('old\n'),
        modified: DateTime.utc(2026, 7, 31, 12),
        permissions: 0x1ED,
      );
      final outcome = await saveRemoteText(
        fs: fs,
        metadata: fs,
        path: '/srv/run.sh',
        text: 'new\n',
        lineEndings: LineEndingStyle.lf,
        expected: RemoteFingerprint(
          size: 4,
          modified: DateTime.utc(2026, 7, 31, 12),
        ),
        permissions: 0x1ED,
      );
      // The bytes are in place either way — that is why this is a note on a
      // successful save rather than an exception.
      expect(textOf(fs, '/srv/run.sh'), 'new\n');
      expect(outcome.permissionsLost, isTrue);
      expect(outcome.permissionsRestored, isFalse);
    });

    test('no metadata seam means no chmod attempt at all', () async {
      final (fs, _) = withNginxConf();
      await saveRemoteText(
        fs: fs,
        path: '/etc/nginx.conf',
        text: 'new\n',
        lineEndings: LineEndingStyle.lf,
        expected: RemoteFingerprint(size: original.length),
        permissions: 0x1ED,
      );
      expect(fs.chmodded, isEmpty);
      expect(textOf(fs, '/etc/nginx.conf'), 'new\n');
    });
  });

  group('fingerprints', () {
    test('compares only the fields both sides reported', () {
      const blind = RemoteFingerprint();
      const sized = RemoteFingerprint(size: 10);
      expect(blind.matches(sized), isTrue,
          reason: 'a server that says nothing cannot be caught out');
      expect(sized.matches(const RemoteFingerprint(size: 11)), isFalse);

      final a = RemoteFingerprint(size: 10, modified: DateTime.utc(2026));
      final b = RemoteFingerprint(size: 10, modified: DateTime.utc(2027));
      expect(a.matches(b), isFalse);
      expect(a.matches(const RemoteFingerprint(size: 10)), isTrue);
    });

    test('knows when it has nothing to compare', () {
      expect(const RemoteFingerprint().isBlind, isTrue);
      expect(const RemoteFingerprint(size: 0).isBlind, isFalse);
    });

    test('a save hands back the baseline for the next one', () async {
      final (fs, fingerprint) = withNginxConf();
      final first = await saveRemoteText(
        fs: fs,
        metadata: fs,
        path: '/etc/nginx.conf',
        text: 'one\n',
        lineEndings: LineEndingStyle.lf,
        expected: fingerprint,
      );
      // Saving again with the carried-forward fingerprint must not conflict
      // with the save that produced it.
      final second = await saveRemoteText(
        fs: fs,
        metadata: fs,
        path: '/etc/nginx.conf',
        text: 'two\n',
        lineEndings: LineEndingStyle.lf,
        expected: first.fingerprint,
      );
      expect(second.bytesWritten, 4);
      expect(textOf(fs, '/etc/nginx.conf'), 'two\n');
    });
  });
}

/// A server that implements SSH_FXP_RENAME to the letter: it refuses to
/// rename onto a name that already exists, which is what forces the
/// remove-then-rename fallback.
class _StrictRenameFs extends EditorFs {
  @override
  Future<void> rename(String from, String to) async {
    if (files.containsKey(to)) {
      throw const SftpFailure('The server refused: destination exists');
    }
    return super.rename(from, to);
  }
}
