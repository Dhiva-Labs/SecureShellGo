import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/remote_copy.dart';
import 'package:secure_shell_go/services/sftp_service.dart';
import 'package:secure_shell_go/services/transfer_queue.dart';

import 'memory_fs.dart';

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

    group('replace', () {
      /// The folder a `Replace` is aimed at: a stale tree that shares one
      /// name with the incoming one and has its own file and subfolder.
      const oldTree = {
        'file:a.txt=4242',
        'dir:old',
        'file:old/stale.txt=7',
      };

      void seedOldFolder() {
        destination
          ..directories.addAll(['/srv/b/pm-folder', '/srv/b/pm-folder/old'])
          ..files['/srv/b/pm-folder/a.txt'] = 4242
          ..files['/srv/b/pm-folder/old/stale.txt'] = 7;
      }

      /// What [seedPmFolder] puts on the source, and so what a replace
      /// should leave on the destination.
      const pmTree = {
        'file:a.txt=100',
        'file:b.txt=200',
        'dir:sub',
        'file:sub/c.txt=300',
        'dir:sub2',
      };

      test('yields exactly the new contents, swapped in once all landed',
          () async {
        seedPmFolder();
        seedOldFolder();

        final outcome = await copyDir(
          from: '/srv/a/pm-folder',
          to: '/srv/b/pm-folder',
          overwrite: true,
        );

        expect(outcome.destinationPath, '/srv/b/pm-folder');
        expect(outcome.bytesCopied, 600);
        // Nothing of the old folder survives inside the new one: not the
        // stale subfolder, and not the old a.txt's size.
        expect(destination.treeUnder('/srv/b/pm-folder'), pmTree);
        expect(destination.leftovers, isEmpty);
        // The old folder was moved aside and the staged one renamed into its
        // place — the only folder renames, in that order.
        final swaps =
            destination.renamed.where((r) => !r.contains('.part ->')).toList();
        expect(swaps, hasLength(2));
        expect(
          swaps[0],
          matches(RegExp(
              r'^/srv/b/pm-folder -> /srv/b/\.pm-folder\.ssg-old-\d+$')),
        );
        expect(
          swaps[1],
          matches(RegExp(
              r'^/srv/b/\.pm-folder\.ssg-part-\d+ -> /srv/b/pm-folder$')),
        );
      });

      test('mid-copy, the folder being replaced is untouched', () async {
        seedPmFolder();
        seedOldFolder();
        final seen = <Set<String>>[];
        source.onChunkRead =
            (_) => seen.add(destination.treeUnder('/srv/b/pm-folder'));

        await copyDir(
          from: '/srv/a/pm-folder',
          to: '/srv/b/pm-folder',
          overwrite: true,
        );

        expect(seen, isNotEmpty);
        for (final snapshot in seen) {
          expect(snapshot, oldTree);
        }
      });

      test('a failure mid-copy leaves the original folder and no staging '
          'folder', () async {
        seedPmFolder();
        seedOldFolder();
        // a.txt (100 bytes) lands; b.txt is refused part way through.
        destination.failWriteAfter = 150;

        await expectLater(
          copyDir(
            from: '/srv/a/pm-folder',
            to: '/srv/b/pm-folder',
            overwrite: true,
          ),
          throwsA(isA<SftpFailure>()),
        );

        expect(destination.treeUnder('/srv/b/pm-folder'), oldTree);
        expect(destination.leftovers, isEmpty);
        expect(destination.directories,
            {'/srv/b', '/srv/b/pm-folder', '/srv/b/pm-folder/old'});
      });

      test('a cancel mid-copy leaves the original folder, no staging folder, '
          'and the whole source of a move', () async {
        seedPmFolder();
        seedOldFolder();
        var cancelled = false;
        source.onChunkRead = (moved) {
          // Into the second file: the first has landed in the staging
          // folder by now, and on a move would already have been deleted
          // from the source if that were not held back until the swap.
          if (moved >= 128) cancelled = true;
        };

        await expectLater(
          copyDir(
            from: '/srv/a/pm-folder',
            to: '/srv/b/pm-folder',
            overwrite: true,
            move: true,
            isCancelled: () => cancelled,
          ),
          throwsA(isA<TransferCancelled>()),
        );

        expect(destination.treeUnder('/srv/b/pm-folder'), oldTree);
        expect(destination.leftovers, isEmpty);
        expect(source.treeUnder('/srv/a/pm-folder'), pmTree);
        expect(source.removed, isEmpty);
      });

      test('a staged copy that does not count up is not swapped in',
          () async {
        seedPmFolder();
        seedOldFolder();
        // Every write is acknowledged and every file passes its own size
        // check, but a.txt is gone from the staging folder by the time the
        // last file lands — the whole-tree count is what notices.
        source.onChunkRead = (moved) {
          if (moved == 300) {
            destination.files.removeWhere(
              (path, _) =>
                  path.contains('.ssg-part-') && path.endsWith('/a.txt'),
            );
          }
        };

        await expectLater(
          copyDir(
            from: '/srv/a/pm-folder',
            to: '/srv/b/pm-folder',
            overwrite: true,
            move: true,
          ),
          throwsA(isA<RemoteCopyFailure>()),
        );

        expect(destination.treeUnder('/srv/b/pm-folder'), oldTree);
        expect(destination.leftovers, isEmpty);
        expect(source.treeUnder('/srv/a/pm-folder'), pmTree);
      });

      test('if the new copy cannot take the name, the old folder is put back',
          () async {
        seedPmFolder();
        seedOldFolder();
        destination.refuseRename = (from, to) =>
            from.contains('.pm-folder.ssg-part-') && to == '/srv/b/pm-folder';

        await expectLater(
          copyDir(
            from: '/srv/a/pm-folder',
            to: '/srv/b/pm-folder',
            overwrite: true,
            move: true,
          ),
          throwsA(isA<RemoteCopyFailure>()),
        );

        expect(destination.treeUnder('/srv/b/pm-folder'), oldTree);
        expect(destination.leftovers, isEmpty);
        expect(
          destination.renamed.last,
          matches(RegExp(
              r'^/srv/b/\.pm-folder\.ssg-old-\d+ -> /srv/b/pm-folder$')),
        );
        // A move deletes nothing until the swap has happened.
        expect(source.treeUnder('/srv/a/pm-folder'), pmTree);
        expect(source.removed, isEmpty);
      });

      test('if the old folder will not go back either, both are kept and '
          'named', () async {
        seedPmFolder();
        seedOldFolder();
        destination.refuseRename = (from, to) => to == '/srv/b/pm-folder';

        await expectLater(
          copyDir(
            from: '/srv/a/pm-folder',
            to: '/srv/b/pm-folder',
            overwrite: true,
          ),
          throwsA(isA<RemoteCopyFailure>().having(
            (e) => e.message,
            'message',
            allOf(contains('.pm-folder.ssg-old-'),
                contains('.pm-folder.ssg-part-')),
          )),
        );

        final aside = destination.directories.singleWhere(
            (d) => RegExp(r'^/srv/b/\.pm-folder\.ssg-old-\d+$').hasMatch(d));
        final staged = destination.directories.singleWhere(
            (d) => RegExp(r'^/srv/b/\.pm-folder\.ssg-part-\d+$').hasMatch(d));
        expect(destination.treeUnder(aside), oldTree);
        expect(destination.treeUnder(staged), pmTree);
      });

      test('a move deletes the source once the new folder is in place',
          () async {
        seedPmFolder();
        seedOldFolder();

        final outcome = await copyDir(
          from: '/srv/a/pm-folder',
          to: '/srv/b/pm-folder',
          overwrite: true,
          move: true,
        );

        expect(outcome.sourceDeleted, isTrue);
        expect(source.files, isEmpty);
        expect(source.directories, isEmpty);
        expect(destination.treeUnder('/srv/b/pm-folder'), pmTree);
      });

      test('a move keeps a source file that changed while it was copied',
          () async {
        seedPmFolder();
        seedOldFolder();
        source.reportedSizes['/srv/a/pm-folder/b.txt'] = 999;

        await expectLater(
          copyDir(
            from: '/srv/a/pm-folder',
            to: '/srv/b/pm-folder',
            overwrite: true,
            move: true,
          ),
          throwsA(isA<RemoteCopyFailure>()),
        );

        // The replace itself went through; the move stopped at b.txt.
        expect(destination.treeUnder('/srv/b/pm-folder'), pmTree);
        expect(source.files.keys, contains('/srv/a/pm-folder/b.txt'));
        expect(source.directories, contains('/srv/a/pm-folder'));
      });

      test('a target that has gone since the prompt is simply filled',
          () async {
        seedPmFolder();

        await copyDir(
          from: '/srv/a/pm-folder',
          to: '/srv/b/pm-folder',
          overwrite: true,
        );

        expect(destination.treeUnder('/srv/b/pm-folder'), pmTree);
        expect(destination.leftovers, isEmpty);
      });

      test('a target that is a link is replaced as the link, never walked',
          () async {
        seedPmFolder();
        destination
          ..directories.addAll(['/var/www', '/var/www/assets'])
          ..files['/var/www/index.html'] = 10
          ..symlinks['/srv/b/pm-folder'] = '/var/www';

        await copyDir(
          from: '/srv/a/pm-folder',
          to: '/srv/b/pm-folder',
          overwrite: true,
        );

        expect(destination.symlinks, isEmpty);
        expect(destination.treeUnder('/srv/b/pm-folder'), pmTree);
        expect(destination.treeUnder('/var/www'),
            {'dir:assets', 'file:index.html=10'});
        expect(destination.leftovers, isEmpty);
      });
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
  group('removeRemoteDirectoryTree', () {
    test('a symlink to a folder is removed as the link, never walked', () {
      // A "replace" whose target name is `www -> /var/www`. Following the
      // link, the walk listed /var/www and deleted everything in it.
      final fs = MemoryFs();
      fs.directories.addAll({'/home/dev', '/var/www', '/var/www/assets'});
      fs.files['/var/www/index.html'] = 10;
      fs.files['/var/www/assets/app.js'] = 20;
      fs.symlinks['/home/dev/www'] = '/var/www';

      return removeRemoteDirectoryTree(fs, '/home/dev/www').then((_) {
        expect(fs.removed, ['/home/dev/www']);
        expect(fs.symlinks, isEmpty);
        expect(fs.files.keys,
            containsAll(['/var/www/index.html', '/var/www/assets/app.js']));
        expect(fs.directories, containsAll(['/var/www', '/var/www/assets']));
      });
    });

    test('a real folder is still cleared, links inside it unlinked', () async {
      final fs = MemoryFs();
      fs.directories.addAll({'/srv', '/srv/site', '/srv/shared'});
      fs.files['/srv/site/a.txt'] = 1;
      fs.files['/srv/shared/keep.txt'] = 1;
      fs.symlinks['/srv/site/shared'] = '/srv/shared';

      await removeRemoteDirectoryTree(fs, '/srv/site');

      expect(fs.directories, isNot(contains('/srv/site')));
      expect(fs.files.keys, ['/srv/shared/keep.txt']);
      expect(fs.symlinks, isEmpty);
    });
  });
}
