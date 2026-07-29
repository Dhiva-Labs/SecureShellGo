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

  @override
  Future<String> resolve(String path) async => path;

  @override
  Future<List<RemoteEntry>> list(String path) async => const [];

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
  Future<void> close() async {}
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
}
