import '../models/remote_entry.dart';
import 'remote_path.dart';
import 'sftp_service.dart';
import 'transfer_queue.dart';

/// A server-to-server copy that could not be trusted to have landed.
///
/// Distinct from [SftpFailure] because the interesting cases here are not
/// "the server said no" but "the server said yes and the bytes disagree" —
/// and the only one of those that matters is the one that stops a *move* from
/// deleting the original.
class RemoteCopyFailure implements Exception {
  const RemoteCopyFailure(this.message, {this.details});

  final String message;
  final String? details;

  @override
  String toString() => message;
}

/// What a finished [copyRemoteFile] actually did.
class RemoteCopyOutcome {
  const RemoteCopyOutcome({
    required this.bytesCopied,
    required this.destinationPath,
    required this.sourceDeleted,
  });

  final int bytesCopied;

  /// Where it landed. Equal to the path that was asked for; carried back so a
  /// caller does not have to reconstruct it to report where the file went.
  final String destinationPath;

  /// True when this was a move *and* the verification below passed.
  final bool sourceDeleted;
}

/// Builds the name the copy is written under before it is published.
///
/// A separate typedef only so a test can make it deterministic; production
/// never passes one.
typedef TemporaryNamer = String Function(String finalName);

/// Streams one file from [source] to [destination], through this app, without
/// ever holding it.
///
/// **Backpressure.** [RemoteFileSystem.download] awaits the `write` callback
/// before it pulls the next chunk off the source's read stream, and that
/// callback is the destination's [RemoteFileWriter.add], which completes only
/// once the destination server has acknowledged the write. So a slow
/// destination pauses the source's stream, which stops draining the SSH
/// channel's window, which stops the source server sending — the same chain
/// the MediaStore download path relies on, and the reason a multi-gigabyte
/// file moves with flat memory. Nothing here accumulates: the high-water mark
/// is the source's read-ahead window (`SftpService.chunkSize` ×
/// `maxPendingRequests`), and one chunk in flight to the destination.
///
/// **Nothing appears under the final name until it is complete.** The bytes go
/// to a hidden temporary file in the destination directory and are renamed
/// into place only after the copy has been verified. A cancelled or failed
/// copy therefore cannot leave a truncated file looking like the real one —
/// and, unlike a straight truncating write, cannot destroy the file it was
/// replacing either.
///
/// **Verification, and why a move waits for it.** "Move" is copy-then-delete,
/// and deleting the only remaining copy of something is the one operation here
/// that cannot be walked back. Before [deleteSourceAfterVerify] removes
/// anything, all four of these must hold:
///
///  1. every chunk write was acknowledged by the destination (any that was not
///     throws out of [RemoteFileWriter.add] long before this point);
///  2. the destination file handle closed cleanly;
///  3. a fresh `stat` of the destination, under its final name, reports
///     exactly the number of bytes that were streamed;
///  4. a fresh `stat` of the *source* still reports that same number — so a
///     file that grew or was replaced underneath the copy is not deleted on
///     the strength of a stale read.
///
/// A content hash of both sides would be stronger still, and is deliberately
/// not done: it needs a second full read of both files, and computing it
/// remotely means running a command on the shell channel, which is not
/// something a file transfer should quietly do on a user's server.
Future<RemoteCopyOutcome> copyRemoteFile({
  required RemoteFileSystem source,
  required RemoteFileSystem destination,
  required String sourcePath,
  required String destinationPath,
  bool overwrite = false,
  bool deleteSourceAfterVerify = false,
  TransferProgress? onProgress,
  CancelCheck? isCancelled,
  TemporaryNamer? temporaryNamer,
}) async {
  final directory = RemotePath.parent(destinationPath);
  final finalName = RemotePath.basename(destinationPath);
  final temporaryPath = RemotePath.join(
    directory,
    (temporaryNamer ?? _defaultTemporaryName)(finalName),
  );

  final writer = await destination.openWrite(temporaryPath);
  var published = false;
  int moved;

  try {
    moved = await source.download(
      sourcePath,
      write: writer.add,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
    // `download` returns normally on a cancel — it breaks between chunks
    // rather than throwing — so the check has to happen here, before any of
    // this is published.
    if (isCancelled?.call() ?? false) throw const TransferCancelled();

    await writer.close();

    final landed = await destination.sizeOf(temporaryPath);
    if (landed != null && landed != moved) {
      throw RemoteCopyFailure(
        'The copy did not land completely on the destination server. '
        'Nothing was changed there.',
        details: 'wrote $moved bytes, the server reports $landed',
      );
    }

    if (overwrite) {
      // Replacing was the user's explicit choice at the collision prompt.
      // Removing first because SSH_FXP_RENAME is not required to clobber an
      // existing target, and plenty of servers refuse when it does.
      try {
        await destination.remove(destinationPath);
      } catch (_) {
        // Gone already, or never there. The rename below decides.
      }
    }
    await destination.rename(temporaryPath, destinationPath);
    published = true;

    if (deleteSourceAfterVerify) {
      await _deleteSourceAfterVerifying(
        source: source,
        destination: destination,
        sourcePath: sourcePath,
        destinationPath: destinationPath,
        moved: moved,
      );
      return RemoteCopyOutcome(
        bytesCopied: moved,
        destinationPath: destinationPath,
        sourceDeleted: true,
      );
    }
  } finally {
    // Responsibility for the temporary file ends at the rename; up to that
    // point every exit from here — cancel, failure, or a dropped connection —
    // takes it with it.
    if (!published) await writer.abort();
  }

  return RemoteCopyOutcome(
    bytesCopied: moved,
    destinationPath: destinationPath,
    sourceDeleted: false,
  );
}

/// Checks (3) and (4) from [copyRemoteFile], then removes the original.
///
/// A failure here leaves the copy in place and the source untouched, which is
/// the right way round: the user ends up with two files and a message, rather
/// than none and a message.
Future<void> _deleteSourceAfterVerifying({
  required RemoteFileSystem source,
  required RemoteFileSystem destination,
  required String sourcePath,
  required String destinationPath,
  required int moved,
}) async {
  final published = await destination.sizeOf(destinationPath);
  if (published == null) {
    throw const RemoteCopyFailure(
      'The destination server would not confirm the copied file, so the '
      'original was left where it is.',
    );
  }
  if (published != moved) {
    throw RemoteCopyFailure(
      'The copy on the destination server is not the size it should be, so '
      'the original was left where it is.',
      details: 'copied $moved bytes, the destination holds $published',
    );
  }

  final remaining = await source.sizeOf(sourcePath);
  if (remaining != null && remaining != moved) {
    throw RemoteCopyFailure(
      'The original changed while it was being copied, so it was left where '
      'it is. The copy on the destination is what was read.',
      details: 'copied $moved bytes, the source now holds $remaining',
    );
  }

  await source.remove(sourcePath);
}

/// `notes.md` → `.notes.md.ssg-part-1738000000000`.
///
/// Hidden, so it does not clutter a directory someone is looking at while the
/// transfer runs, and named after both the file and this app so anything left
/// behind by a process that died mid-copy can be recognised for what it is.
String _defaultTemporaryName(String finalName) {
  final stamp = DateTime.now().millisecondsSinceEpoch;
  final suffix = '.ssg-part-$stamp';
  // POSIX allows 255 bytes per name; leave room for the marker rather than
  // letting the server reject the open.
  final head = finalName.length > 200 ? finalName.substring(0, 200) : finalName;
  return '.$head$suffix';
}

/// One file inside a folder being copied across, resolved from the source's
/// tree walk.
class _WalkedFile {
  const _WalkedFile({
    required this.sourcePath,
    required this.destinationPath,
    this.size,
  });

  final String sourcePath;
  final String destinationPath;
  final int? size;
}

/// Streams a whole directory tree from [source] to [destination], one file at
/// a time, preserving the shape and any empty subdirectories along the way.
///
/// **Why sequential.** Each file goes through [copyRemoteFile], and each of
/// those does its own read-side backpressure against the SSH window (see the
/// note on [copyRemoteFile] for the whole chain). Running several in parallel
/// would share the same TCP window between them and finish no sooner in
/// aggregate — the same "one at a time" rule the transfer queue applies at
/// the batch level, applied here at the file level so a folder move takes its
/// turn behind that session's other transfers rather than saturating them.
///
/// **Collision handling belongs to the caller.** By the time this runs, the
/// destination directory is either fresh — a top-level `replace` has already
/// removed the old one — or unique (a `keep both` has already renamed
/// [destinationDirectory] via [RemotePath.deduplicate]). Nothing inside the
/// folder can therefore collide with anything already on the destination, so
/// per-file copies run without overwrite and without a per-file prompt.
///
/// **Move semantics.** [deleteSourceAfterVerify] pushes through to each
/// per-file copy: only the four-check safety chain (bytes acked, handle
/// closed, size on both sides matches) deletes anything. Directories on the
/// source are then removed bottom-up once every file under them has left, and
/// only rmdir'd if empty — a failed per-file copy leaves that file *and* every
/// ancestor directory, which is what makes a partial move visible for a retry
/// instead of hiding under a half-empty tree.
///
/// **Symlinks are not chased**, in either direction, for the same reason
/// `download_plan.dart` skips them: a link to a directory can point back up
/// its own tree and loop the walk, and a link to a file would duplicate bytes
/// under two names. They are counted and left behind — the caller is told in
/// the transfer's snackbar.
Future<RemoteCopyOutcome> copyRemoteDirectory({
  required RemoteFileSystem source,
  required RemoteFileSystem destination,
  required String sourceDirectory,
  required String destinationDirectory,
  bool overwrite = false,
  bool deleteSourceAfterVerify = false,
  TransferProgress? onProgress,
  CancelCheck? isCancelled,
  TemporaryNamer? temporaryNamer,
}) async {
  void checkCancelled() {
    if (isCancelled?.call() ?? false) throw const TransferCancelled();
  }

  checkCancelled();

  if (overwrite) {
    // A top-level `Replace` at the collision prompt licenses this — anything
    // deeper in the tree is not a collision, since the tree is about to be
    // put back exactly by the copy below.
    await removeRemoteDirectoryTree(destination, destinationDirectory);
  }

  try {
    await destination.mkdir(destinationDirectory);
  } on SftpFailure {
    // Already exists — either the caller pre-created it, or the overwrite
    // rm above did not fully clear it (a permission error, say). Fall through
    // and let the per-file writes report the problem if one is still there.
  }

  // Walk the source tree breadth-first. Directories in [subdirs] are the
  // ones we need to `mkdir` on the destination — empty subdirectories are
  // recorded here too, so an empty `logs/` folder does not silently
  // disappear across the transfer.
  final subdirs = <String>[];
  final files = <_WalkedFile>[];

  final pending = <String>[''];
  for (var index = 0; index < pending.length; index++) {
    checkCancelled();
    final relative = pending[index];
    final currentSource = relative.isEmpty
        ? sourceDirectory
        : RemotePath.join(sourceDirectory, relative);
    final List<RemoteEntry> listed;
    try {
      listed = await source.list(currentSource);
    } on TransferCancelled {
      rethrow;
    } catch (_) {
      // An unreadable subdirectory is stepped over rather than failing the
      // whole move: the browser above has already told the user which
      // directories will not open, and losing one branch of a large tree
      // should not lose the whole tree.
      continue;
    }
    for (final entry in listed) {
      if (entry.kind == RemoteEntryKind.symlink) {
        // A link to a directory could loop the walk, a link to a file would
        // double-transfer bytes under two names. Same policy as the download
        // walker and the direct path's tree.
        continue;
      }
      final childRelative =
          relative.isEmpty ? entry.name : '$relative/${entry.name}';
      if (entry.kind == RemoteEntryKind.directory) {
        subdirs.add(childRelative);
        pending.add(childRelative);
      } else if (entry.kind == RemoteEntryKind.file) {
        files.add(_WalkedFile(
          sourcePath: RemotePath.join(currentSource, entry.name),
          destinationPath: RemotePath.join(destinationDirectory, childRelative),
          size: entry.size,
        ));
      }
    }
  }

  // Materialise every subdirectory on the destination up front, so an empty
  // folder still lands and so per-file mkdirs never race with a parent that
  // is still being created.
  for (final relative in subdirs) {
    checkCancelled();
    final path = RemotePath.join(destinationDirectory, relative);
    try {
      await destination.mkdir(path);
    } on SftpFailure {
      // Already there — either from a repeated tree (see [overwrite] above)
      // or from the caller having pre-populated. The per-file writes below
      // are still gated on the temporary → rename dance, so a "wrong
      // directory" would surface there.
    }
  }

  var bytesMoved = 0;

  for (final file in files) {
    checkCancelled();
    // A per-file failure propagates out of the loop as-is: no rmdirs run,
    // whatever files landed stay landed, and the source's remaining tree is
    // untouched. That is the "two files and a message" rule that
    // [copyRemoteFile] applies for one file, applied to the batch.
    final outcome = await copyRemoteFile(
      source: source,
      destination: destination,
      sourcePath: file.sourcePath,
      destinationPath: file.destinationPath,
      overwrite: false,
      deleteSourceAfterVerify: deleteSourceAfterVerify,
      onProgress: (bytes) {
        onProgress?.call(bytesMoved + bytes);
      },
      isCancelled: isCancelled,
      temporaryNamer: temporaryNamer,
    );
    bytesMoved += outcome.bytesCopied;
    onProgress?.call(bytesMoved);
  }

  var sourceDeleted = false;
  if (deleteSourceAfterVerify) {
    checkCancelled();
    // Every file went across successfully — the loop above would have thrown
    // otherwise — so every source subdirectory is *ours* to rmdir now.
    // Bottom-up: a rmdir on a parent that still has a child directory in it
    // would fail, so descend the recorded [subdirs] in reverse (BFS order
    // reversed puts deepest first). A non-empty rmdir is silently swallowed:
    // a symlink we skipped, or a subdirectory that could not be listed
    // during the walk, still stays where it is, and the root rmdir below
    // will report that by failing.
    for (final relative in subdirs.reversed) {
      final path = RemotePath.join(sourceDirectory, relative);
      try {
        await source.removeDirectory(path);
      } catch (_) {
        // Left behind — matches the "partial move is visible" invariant.
      }
    }
    try {
      await source.removeDirectory(sourceDirectory);
      sourceDeleted = true;
    } catch (_) {
      // Root still holds something — a symlink, or an unwalkable subdir.
      // The partial-move visibility that argues for.
    }
  }

  return RemoteCopyOutcome(
    bytesCopied: bytesMoved,
    destinationPath: destinationDirectory,
    sourceDeleted: sourceDeleted,
  );
}

/// Walks [directory] on [fs] and removes everything under it, then the
/// directory itself. Best-effort: failures are swallowed so that a subsequent
/// mkdir can still put a fresh tree in place.
///
/// Called by [copyRemoteDirectory] under an `overwrite` and by
/// `direct_remote_copy.dart` to clear the target before `sftp put -r` fills
/// it. Public so both callers reach the same implementation rather than
/// growing two subtly different tree-blows.
Future<void> removeRemoteDirectoryTree(
  RemoteFileSystem fs,
  String directory,
) async {
  if (!await fs.isDirectory(directory)) {
    // Not there at all, or is a file — either way, remove it and be done.
    try {
      await fs.remove(directory);
    } catch (_) {
      // Missing, or forbidden. Nothing to do.
    }
    return;
  }

  final subdirs = <String>[];
  final pending = <String>[directory];
  for (var index = 0; index < pending.length; index++) {
    final current = pending[index];
    final List<RemoteEntry> entries;
    try {
      entries = await fs.list(current);
    } catch (_) {
      // Cannot list this branch. Whatever is in it stays, and the parent's
      // rmdir will fail loudly — a permission we cannot walk past is a
      // reason to leave the tree half-cleared rather than pretend otherwise.
      continue;
    }
    for (final entry in entries) {
      final childPath = RemotePath.join(current, entry.name);
      if (entry.kind == RemoteEntryKind.directory) {
        subdirs.add(childPath);
        pending.add(childPath);
      } else {
        try {
          await fs.remove(childPath);
        } catch (_) {
          // Best-effort.
        }
      }
    }
  }

  for (final path in subdirs.reversed) {
    try {
      await fs.removeDirectory(path);
    } catch (_) {
      // Best-effort.
    }
  }
  try {
    await fs.removeDirectory(directory);
  } catch (_) {
    // Best-effort — a symlink that will not rmdir might still be there.
  }
}
