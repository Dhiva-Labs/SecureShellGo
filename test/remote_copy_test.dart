import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/remote_entry.dart';
import 'package:secure_shell_go/services/remote_copy.dart';
import 'package:secure_shell_go/services/sftp_service.dart';
import 'package:secure_shell_go/services/transfer_queue.dart';

/// A remote filesystem held in memory: paths to byte counts, plus a record of
/// everything that was done to it.
///
/// The seam being exercised is [RemoteFileSystem] itself, which is why a copy
/// between two servers can be tested at all without either one existing. The
/// read side deliberately mirrors `SftpService.download`: chunked, cancel
/// checked *between* chunks, and — the part that matters here — awaiting the
/// write callback before it produces the next chunk.
class MemoryFs implements RemoteFileSystem {
  MemoryFs({this.chunkSize = 64});

  final int chunkSize;

  /// What exists here, by absolute path, with the size the server reports.
  final Map<String, int> files = {};

  final List<String> removed = [];
  final List<String> renamed = [];
  final List<MemoryWriter> writers = [];

  /// Sizes to report instead of the truth, for the cases where a server and
  /// reality disagree — which is the entire point of verifying before a move.
  final Map<String, int?> reportedSizes = {};

  /// Thrown out of the next [openWrite].
  Object? failOpenWrite;

  /// Thrown once this many bytes have been written, to fail a copy in flight.
  int? failWriteAfter;

  /// Called after each chunk is read, with the running total — how a test
  /// cancels or mutates the world half way through a copy.
  void Function(int moved)? onChunkRead;

  /// Shared between the two ends of one copy. Held here rather than counted
  /// per filesystem because the interesting number spans both: bytes this
  /// side has read against bytes the *other* side has acknowledged.
  CopyMeter? meter;

  @override
  Future<String> home() async => '/home/dev';

  /// Directory paths that exist here. Directory folders are tracked
  /// separately from files so `list` can return real entries for the
  /// folder-copy tests, while single-file tests keep working with an empty
  /// listing they never look at.
  final Set<String> directories = {};

  @override
  Future<String> resolve(String path) async => path;

  @override
  Future<List<RemoteEntry>> list(String path) async {
    if (throwOnList) {
      throw SftpFailure('Permission denied.', isPermissionDenied: true);
    }
    final entries = <RemoteEntry>[];
    for (final dir in directories) {
      if (_parentOf(dir) == path) {
        entries.add(RemoteEntry(
          name: _basename(dir),
          path: dir,
          kind: RemoteEntryKind.directory,
        ));
      }
    }
    for (final entry in files.entries) {
      if (_parentOf(entry.key) == path) {
        entries.add(RemoteEntry(
          name: _basename(entry.key),
          path: entry.key,
          kind: RemoteEntryKind.file,
          size: entry.value,
        ));
      }
    }
    return entries;
  }

  /// Toggle to make `list` fail on any call — for the fallback-probe test.
  var throwOnList = false;

  @override
  Future<int?> sizeOf(String path) async {
    if (reportedSizes.containsKey(path)) return reportedSizes[path];
    return files[path];
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
    final size = files[remotePath];
    if (size == null) {
      throw SftpFailure('"$remotePath" is not there any more.');
    }

    var moved = 0;
    while (moved < size) {
      if (isCancelled?.call() ?? false) break;
      final chunk = (size - moved).clamp(0, chunkSize);
      meter?.read(chunk);
      await write(Uint8List(chunk));
      moved += chunk;
      onProgress?.call(moved);
      onChunkRead?.call(moved);
    }
    return moved;
  }

  @override
  Future<int> upload(
    String localPath,
    String remotePath, {
    TransferProgress? onProgress,
    CancelCheck? isCancelled,
  }) async =>
      throw UnimplementedError('not part of a server-to-server copy');

  @override
  Future<RemoteFileWriter> openWrite(String remotePath) async {
    final failure = failOpenWrite;
    if (failure != null) throw failure;
    final writer = MemoryWriter(this, remotePath);
    writers.add(writer);
    return writer;
  }

  @override
  Future<void> remove(String path) async {
    removed.add(path);
    files.remove(path);
  }

  @override
  Future<void> rename(String from, String to) async {
    renamed.add('$from -> $to');
    final size = files.remove(from);
    if (size != null) files[to] = size;
  }

  @override
  Future<void> mkdir(String path) async {
    if (directories.contains(path) || files.containsKey(path)) {
      throw const SftpFailure('mkdir: already exists');
    }
    directories.add(path);
  }

  @override
  Future<void> removeDirectory(String path) async {
    if (!directories.contains(path)) {
      throw const SftpFailure('rmdir: no such directory');
    }
    // Must be empty.
    final hasChild = files.keys.any((k) => _parentOf(k) == path) ||
        directories.any((d) => _parentOf(d) == path);
    if (hasChild) {
      throw const SftpFailure('rmdir: not empty');
    }
    directories.remove(path);
    removed.add(path);
  }

  @override
  Future<bool> isDirectory(String path) async => directories.contains(path);

  @override
  Future<void> close() async {}
}

String _parentOf(String path) {
  final index = path.lastIndexOf('/');
  if (index <= 0) return '/';
  return path.substring(0, index);
}

String _basename(String path) {
  final index = path.lastIndexOf('/');
  return index < 0 ? path : path.substring(index + 1);
}

/// A file being written into a [MemoryFs].
///
/// Nothing appears under [path] until [close]; [abort] takes it away again.
class MemoryWriter implements RemoteFileWriter {
  MemoryWriter(this._fs, this.path);

  final MemoryFs _fs;
  final String path;

  var written = 0;
  var closed = false;
  var aborted = false;

  @override
  Future<void> add(Uint8List chunk) async {
    // A real destination acknowledges over the wire; the yield is what lets a
    // test see whether the read side ran ahead while this was in flight.
    await Future<void>.delayed(Duration.zero);
    final limit = _fs.failWriteAfter;
    if (limit != null && written + chunk.length > limit) {
      throw const SftpFailure('The destination server refused the write.');
    }
    written += chunk.length;
    _fs.meter?.acknowledge(chunk.length);
  }

  @override
  Future<void> close() async {
    closed = true;
    _fs.files[path] = written;
  }

  @override
  Future<void> abort() async {
    aborted = true;
    _fs.files.remove(path);
  }
}

/// Counts bytes read out of the source against bytes the destination has
/// acknowledged, so the gap between the two can be asserted on.
class CopyMeter {
  var bytesRead = 0;
  var bytesAcknowledged = 0;

  /// The high-water mark of bytes read but not yet written through.
  var maxOutstanding = 0;

  void read(int bytes) {
    bytesRead += bytes;
    final outstanding = bytesRead - bytesAcknowledged;
    if (outstanding > maxOutstanding) maxOutstanding = outstanding;
  }

  void acknowledge(int bytes) => bytesAcknowledged += bytes;
}

void main() {
  late MemoryFs source;
  late MemoryFs destination;
  late CopyMeter meter;

  setUp(() {
    meter = CopyMeter();
    source = MemoryFs()..meter = meter;
    destination = MemoryFs()..meter = meter;
  });

  /// Deterministic, so assertions can name the temporary file.
  String tempName(String finalName) => '.$finalName.part';

  Future<RemoteCopyOutcome> copy({
    String from = '/srv/a/report.pdf',
    String to = '/srv/b/report.pdf',
    bool overwrite = false,
    bool move = false,
    TransferProgress? onProgress,
    CancelCheck? isCancelled,
  }) {
    return copyRemoteFile(
      source: source,
      destination: destination,
      sourcePath: from,
      destinationPath: to,
      overwrite: overwrite,
      deleteSourceAfterVerify: move,
      onProgress: onProgress,
      isCancelled: isCancelled,
      temporaryNamer: tempName,
    );
  }

  group('streaming', () {
    test('moves every byte across and reports where it landed', () async {
      source.files['/srv/a/report.pdf'] = 500;

      final outcome = await copy();

      expect(outcome.bytesCopied, 500);
      expect(outcome.destinationPath, '/srv/b/report.pdf');
      expect(outcome.sourceDeleted, isFalse);
      expect(destination.files['/srv/b/report.pdf'], 500);
    });

    test('never runs more than one chunk ahead of the destination', () async {
      // The whole memory story in one assertion: the read side awaits the
      // write callback, so a 10 MB file is carried by one 64 KB chunk in
      // flight rather than accumulating in the heap. Anything that broke the
      // `await` — a fire-and-forget write, a buffered sink — would let the
      // source run to completion and show up here as an outstanding count of
      // the whole file.
      source.files['/srv/a/big.bin'] = 64 * 40;

      await copy(from: '/srv/a/big.bin', to: '/srv/b/big.bin');

      expect(meter.maxOutstanding, 64);
      expect(meter.bytesAcknowledged, 64 * 40);
      expect(destination.writers.single.written, 64 * 40);
    });

    test('reports progress cumulatively', () async {
      source.files['/srv/a/report.pdf'] = 200;
      final progress = <int>[];

      await copy(onProgress: progress.add);

      expect(progress, [64, 128, 192, 200]);
    });

    test('an empty file still lands', () async {
      source.files['/srv/a/empty'] = 0;

      final outcome = await copy(from: '/srv/a/empty', to: '/srv/b/empty');

      expect(outcome.bytesCopied, 0);
      expect(destination.files['/srv/b/empty'], 0);
    });

    test('a source that is not there fails before anything is published',
        () async {
      await expectLater(copy(), throwsA(isA<SftpFailure>()));

      expect(destination.files, isEmpty);
      expect(destination.writers.single.aborted, isTrue);
    });
  });

  group('nothing appears under the final name until it is complete', () {
    test('the bytes go to a temporary name and are renamed into place',
        () async {
      source.files['/srv/a/report.pdf'] = 100;

      await copy();

      expect(
        destination.renamed,
        ['/srv/b/.report.pdf.part -> /srv/b/report.pdf'],
      );
      expect(destination.files.keys, ['/srv/b/report.pdf']);
    });

    test('mid-copy, the destination holds only the temporary file', () async {
      source.files['/srv/a/report.pdf'] = 500;
      final seen = <List<String>>[];
      source.onChunkRead = (_) => seen.add(destination.files.keys.toList());

      await copy();

      // Every observation during the copy, and there are several, saw nothing
      // at the final path.
      expect(seen, isNotEmpty);
      for (final snapshot in seen) {
        expect(snapshot, isNot(contains('/srv/b/report.pdf')));
      }
    });
  });

  group('cancellation', () {
    test('a cancel mid-stream leaves no file claiming to be the copy',
        () async {
      source.files['/srv/a/report.pdf'] = 1000;
      var cancelled = false;
      source.onChunkRead = (moved) {
        if (moved >= 128) cancelled = true;
      };

      await expectLater(
        copy(isCancelled: () => cancelled),
        throwsA(isA<TransferCancelled>()),
      );

      expect(destination.writers.single.aborted, isTrue);
      expect(destination.files, isEmpty);
      expect(destination.renamed, isEmpty);
    });

    test('a cancelled replace does not destroy the file it was replacing',
        () async {
      // The reason the copy is staged rather than written straight over the
      // target: "Replace" plus a cancel must not leave the user with neither
      // file. A truncating write would have.
      source.files['/srv/a/report.pdf'] = 1000;
      destination.files['/srv/b/report.pdf'] = 4242;
      var cancelled = false;
      source.onChunkRead = (moved) {
        if (moved >= 128) cancelled = true;
      };

      await expectLater(
        copy(overwrite: true, isCancelled: () => cancelled),
        throwsA(isA<TransferCancelled>()),
      );

      expect(destination.files['/srv/b/report.pdf'], 4242);
      expect(destination.removed, isEmpty);
    });

    test('a cancel never deletes the source, even on a move', () async {
      source.files['/srv/a/report.pdf'] = 1000;
      var cancelled = false;
      source.onChunkRead = (moved) {
        if (moved >= 128) cancelled = true;
      };

      await expectLater(
        copy(move: true, isCancelled: () => cancelled),
        throwsA(isA<TransferCancelled>()),
      );

      expect(source.files['/srv/a/report.pdf'], 1000);
      expect(source.removed, isEmpty);
    });
  });

  group('failure', () {
    test('a destination that refuses a write takes its partial file with it',
        () async {
      source.files['/srv/a/report.pdf'] = 1000;
      destination.failWriteAfter = 128;

      await expectLater(copy(), throwsA(isA<SftpFailure>()));

      expect(destination.writers.single.aborted, isTrue);
      expect(destination.files, isEmpty);
    });

    test('a destination that will not open the file fails cleanly', () async {
      source.files['/srv/a/report.pdf'] = 100;
      destination.failOpenWrite = const SftpFailure('Permission denied.');

      await expectLater(copy(), throwsA(isA<SftpFailure>()));

      expect(destination.writers, isEmpty);
    });

    test('a short write is caught by the size check, before any rename',
        () async {
      source.files['/srv/a/report.pdf'] = 500;
      // The server accepted every write and then reports a truncated file.
      destination.reportedSizes['/srv/b/.report.pdf.part'] = 12;

      await expectLater(copy(), throwsA(isA<RemoteCopyFailure>()));

      expect(destination.renamed, isEmpty);
      expect(destination.files, isEmpty);
    });
  });

  group('overwrite', () {
    test('replaces only after the copy is complete', () async {
      source.files['/srv/a/report.pdf'] = 300;
      destination.files['/srv/b/report.pdf'] = 4242;

      await copy(overwrite: true);

      expect(destination.removed, ['/srv/b/report.pdf']);
      expect(destination.files['/srv/b/report.pdf'], 300);
    });

    test('without it, the existing file is left for the rename to decide',
        () async {
      // "Keep both" has already renamed the incoming file by this point, so a
      // copy that is not a replace has no business removing anything.
      source.files['/srv/a/report.pdf'] = 300;
      destination.files['/srv/b/report (1).pdf'] = 4242;

      await copy(to: '/srv/b/report.pdf');

      expect(destination.removed, isEmpty);
      expect(destination.files['/srv/b/report (1).pdf'], 4242);
    });
  });

  group('move: delete only after the write is verified', () {
    test('deletes the source once the destination confirms the size',
        () async {
      source.files['/srv/a/report.pdf'] = 900;

      final outcome = await copy(move: true);

      expect(outcome.sourceDeleted, isTrue);
      expect(source.removed, ['/srv/a/report.pdf']);
      expect(source.files, isEmpty);
      expect(destination.files['/srv/b/report.pdf'], 900);
    });

    test('a copy that is not a move never touches the source', () async {
      source.files['/srv/a/report.pdf'] = 900;

      await copy();

      expect(source.removed, isEmpty);
      expect(source.files['/srv/a/report.pdf'], 900);
    });

    test('a destination that reports the wrong size keeps the original',
        () async {
      source.files['/srv/a/report.pdf'] = 900;
      // Verified at the *final* path, after the rename — a server that quietly
      // truncated on close is the case this catches.
      destination.reportedSizes['/srv/b/report.pdf'] = 128;

      await expectLater(copy(move: true), throwsA(isA<RemoteCopyFailure>()));

      expect(source.files['/srv/a/report.pdf'], 900);
      expect(source.removed, isEmpty);
    });

    test('a destination that will not confirm at all keeps the original',
        () async {
      source.files['/srv/a/report.pdf'] = 900;
      destination.reportedSizes['/srv/b/report.pdf'] = null;

      await expectLater(copy(move: true), throwsA(isA<RemoteCopyFailure>()));

      expect(source.removed, isEmpty);
    });

    test('a source that changed underneath the copy is not deleted', () async {
      // Someone appended to the file while it was being read. What landed on
      // the destination is a prefix of what is now here, so deleting this
      // would lose the rest — and the user is told exactly that.
      source.files['/srv/a/report.pdf'] = 900;
      source.reportedSizes['/srv/a/report.pdf'] = 1500;

      await expectLater(copy(move: true), throwsA(isA<RemoteCopyFailure>()));

      expect(source.removed, isEmpty);
      // The copy itself stays: two files and a message beats none and one.
      expect(destination.files['/srv/b/report.pdf'], 900);
    });

    test('a source whose size the server will not report is still moved',
        () async {
      // Not every server reports a size. "Cannot check" is not "wrong", and
      // the destination check above it has already passed.
      source.files['/srv/a/report.pdf'] = 900;
      source.reportedSizes['/srv/a/report.pdf'] = null;

      final outcome = await copy(move: true);

      expect(outcome.sourceDeleted, isTrue);
      expect(source.removed, ['/srv/a/report.pdf']);
    });

    test('a failed copy never reaches the delete', () async {
      source.files['/srv/a/report.pdf'] = 1000;
      destination.failWriteAfter = 128;

      await expectLater(copy(move: true), throwsA(isA<SftpFailure>()));

      expect(source.files['/srv/a/report.pdf'], 1000);
      expect(source.removed, isEmpty);
    });
  });

  group('folder copy', () {
    Future<RemoteCopyOutcome> copyDir({
      required String from,
      required String to,
      bool overwrite = false,
      bool move = false,
      TransferProgress? onProgress,
      CancelCheck? isCancelled,
    }) {
      return copyRemoteDirectory(
        source: source,
        destination: destination,
        sourceDirectory: from,
        destinationDirectory: to,
        overwrite: overwrite,
        deleteSourceAfterVerify: move,
        onProgress: onProgress,
        isCancelled: isCancelled,
        temporaryNamer: tempName,
      );
    }

    /// Seeds `/srv/a/pm-folder/{a.txt, b.txt, sub/c.txt}` and an empty
    /// `pm-folder/sub2/` — the shape the maintainer's test A→B move calls
    /// out by name.
    void seedPmFolder() {
      source
        ..directories.addAll([
          '/srv/a/pm-folder',
          '/srv/a/pm-folder/sub',
          '/srv/a/pm-folder/sub2',
        ])
        ..files['/srv/a/pm-folder/a.txt'] = 100
        ..files['/srv/a/pm-folder/b.txt'] = 200
        ..files['/srv/a/pm-folder/sub/c.txt'] = 300;
      destination.directories.add('/srv/b');
    }

    test('lands every file with the same shape and reports aggregate bytes',
        () async {
      seedPmFolder();

      final progress = <int>[];
      final outcome = await copyDir(
        from: '/srv/a/pm-folder',
        to: '/srv/b/pm-folder',
        onProgress: progress.add,
      );

      expect(outcome.bytesCopied, 100 + 200 + 300);
      expect(outcome.destinationPath, '/srv/b/pm-folder');
      expect(outcome.sourceDeleted, isFalse);
      expect(destination.directories, containsAll([
        '/srv/b/pm-folder',
        '/srv/b/pm-folder/sub',
        '/srv/b/pm-folder/sub2', // empty subdir still lands
      ]));
      expect(destination.files, containsPair('/srv/b/pm-folder/a.txt', 100));
      expect(destination.files, containsPair('/srv/b/pm-folder/b.txt', 200));
      expect(
        destination.files,
        containsPair('/srv/b/pm-folder/sub/c.txt', 300),
      );
      // Progress is cumulative and eventually equals the total.
      expect(progress.last, 600);
    });

    test('a move deletes the source tree bottom-up', () async {
      seedPmFolder();

      final outcome = await copyDir(
        from: '/srv/a/pm-folder',
        to: '/srv/b/pm-folder',
        move: true,
      );

      expect(outcome.sourceDeleted, isTrue);
      expect(source.files, isEmpty);
      expect(source.directories, isNot(contains('/srv/a/pm-folder')));
      expect(source.directories, isNot(contains('/srv/a/pm-folder/sub')));
      // Every removeDirectory call happened after the file removes above it —
      // rmdir on a non-empty directory would have thrown in the fake.
    });

    test('an overwrite wipes the destination tree first', () async {
      seedPmFolder();
      // A stale tree in the way. `Replace` at the collision prompt licenses
      // the wipe; without overwrite this would be left alone.
      destination
        ..directories.addAll(['/srv/b/pm-folder', '/srv/b/pm-folder/old'])
        ..files['/srv/b/pm-folder/old/stale.txt'] = 4242;

      await copyDir(
        from: '/srv/a/pm-folder',
        to: '/srv/b/pm-folder',
        overwrite: true,
      );

      expect(destination.files.containsKey('/srv/b/pm-folder/old/stale.txt'),
          isFalse);
      expect(destination.files['/srv/b/pm-folder/a.txt'], 100);
    });

    test('a cancel mid-batch leaves the source alone', () async {
      seedPmFolder();
      var cancelled = false;
      source.onChunkRead = (moved) {
        // Cancel after the first file finishes: the second file's copy
        // should notice at the next between-chunks check.
        if (moved >= 100) cancelled = true;
      };

      await expectLater(
        copyDir(
          from: '/srv/a/pm-folder',
          to: '/srv/b/pm-folder',
          move: true,
          isCancelled: () => cancelled,
        ),
        throwsA(isA<TransferCancelled>()),
      );

      // The source root is untouched: nothing at all was rmdir'd, since a
      // partial batch never reached the rmdir loop.
      expect(source.directories, contains('/srv/a/pm-folder'));
    });

    test('a per-file failure aborts and leaves the source alone', () async {
      seedPmFolder();
      // The destination refuses writes on every file (limit smaller than one
      // chunk). The first per-file copy fails, which throws up through the
      // folder copy — the rmdir loop is skipped and the whole source tree
      // stays.
      destination.failWriteAfter = 10;

      await expectLater(
        copyDir(
          from: '/srv/a/pm-folder',
          to: '/srv/b/pm-folder',
          move: true,
        ),
        throwsA(isA<SftpFailure>()),
      );

      expect(source.directories, contains('/srv/a/pm-folder/sub'));
      expect(source.files.containsKey('/srv/a/pm-folder/a.txt'), isTrue,
          reason: 'the file whose copy failed stays on the source');
    });

    test('an empty source directory still creates the destination', () async {
      source.directories.addAll(['/srv/a/empty-folder']);
      destination.directories.add('/srv/b');

      final outcome = await copyDir(
        from: '/srv/a/empty-folder',
        to: '/srv/b/empty-folder',
      );

      expect(outcome.bytesCopied, 0);
      expect(destination.directories, contains('/srv/b/empty-folder'));
    });
  });
}
