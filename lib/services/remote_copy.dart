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
String _defaultTemporaryName(String finalName) =>
    _stampedName(finalName, 'part', DateTime.now().millisecondsSinceEpoch);

/// `notes.md` → `.notes.md.ssg-<marker>-<stamp>`.
String _stampedName(String finalName, String marker, int stamp) {
  final suffix = '.ssg-$marker-$stamp';
  // POSIX allows 255 bytes per name; leave room for the marker rather than
  // letting the server reject the open.
  final head = finalName.length > 200 ? finalName.substring(0, 200) : finalName;
  return '.$head$suffix';
}

/// A folder "Replace" that does not destroy the folder it replaces until the
/// new copy is safely beside it.
///
/// Every folder path used to clear the destination first and fill it after,
/// so a dropped connection, a cancel or a failure part way through left the
/// old folder gone and only some of the new one in its place. Instead:
///
///  1. the new tree is written into [staging], `.<name>.ssg-part-<stamp>`
///     beside [target] — the convention a single file's copy already uses;
///  2. the caller verifies it there ([verifyStaged], or its own check);
///  3. [swapIn] moves the old folder aside to [retired],
///     `.<name>.ssg-old-<stamp>`, renames [staging] to [target], and only
///     then removes the old one. If the second rename fails, the old folder
///     is renamed back.
///
/// Until the swap, [discard] is the whole of the cleanup: it removes
/// [staging] and nothing else, so a cancel or a failure leaves the original
/// exactly as it was.
///
/// Renames rather than copies because SFTP moves a folder with everything in
/// it in one request, and because a rename never follows a symlink: a target
/// named `www -> /var/www` is moved aside, and removed, as the link.
class StagedDirectoryReplace {
  /// [stamp] names the staging and retired folders; pass the one a
  /// server-side job was started with to find what it wrote. Defaults to now.
  factory StagedDirectoryReplace(
    RemoteFileSystem fs,
    String target, {
    int? stamp,
  }) {
    final directory = RemotePath.parent(target);
    final name = RemotePath.basename(target);
    stamp ??= DateTime.now().millisecondsSinceEpoch;
    return StagedDirectoryReplace._(
      fs,
      target,
      staging: RemotePath.join(directory, _stampedName(name, 'part', stamp)),
      retired: RemotePath.join(directory, _stampedName(name, 'old', stamp)),
    );
  }

  StagedDirectoryReplace._(
    this.fs,
    this.target, {
    required this.staging,
    required this.retired,
  });

  final RemoteFileSystem fs;

  /// The folder being replaced, and where the new one ends up.
  final String target;

  /// Where the new tree is written. Does not exist yet: the caller creates
  /// it, or has `sftp put -r` create it.
  final String staging;

  /// Where [target] waits while [staging] takes its name.
  final String retired;

  String get _name => RemotePath.basename(target);

  /// Checks that [staging] holds the [files] files and [bytes] bytes written
  /// into it, before [swapIn] trusts it with the folder it replaces.
  ///
  /// Each file was size-checked as it landed; this is the count that says
  /// none went missing on the way, and the total that says none changed
  /// since. A server that lists some files without a size can only be held
  /// to the count.
  Future<void> verifyStaged({required int files, required int bytes}) async {
    final landed = await measureRemoteTree(fs, staging);
    if (landed.files != files ||
        (landed.unsized == 0 && landed.bytes != bytes)) {
      throw RemoteCopyFailure(
        'The new copy of "$_name" did not land completely on the server, so '
        'the folder there was left exactly as it was.',
        details: 'wrote $files files ($bytes bytes), the server lists '
            '${landed.files} (${landed.bytes} bytes)',
      );
    }
  }

  /// Puts [staging] in [target]'s place. See the class note for the order.
  ///
  /// Throws with [target] as it was, and the staged copy removed, when the
  /// server will not make the swap. The one failure that cannot put things
  /// back — the old folder moved aside, the new one refused its place, and
  /// the old one then refused its own name back — keeps both and says where
  /// they are.
  Future<void> swapIn() async {
    var setAside = false;
    try {
      await fs.rename(target, retired);
      setAside = true;
    } catch (_) {
      // Nothing there to move: the folder went away after the collision
      // prompt. Or something there that the server will not move, in which
      // case the rename below is refused too — a folder cannot be renamed
      // onto a name still taken by anything but an empty folder — and
      // nothing is lost.
    }

    try {
      await fs.rename(staging, target);
    } catch (e) {
      if (setAside) {
        try {
          await fs.rename(retired, target);
        } catch (restore) {
          throw RemoteCopyFailure(
            'The server moved the old "$_name" aside but would neither put '
            'the new copy in its place nor the old one back. The old folder '
            'is in "$retired" and the new copy in "$staging".',
            details: '$e; restoring: $restore',
          );
        }
      }
      await discard();
      throw RemoteCopyFailure(
        'The server would not put the new "$_name" in place, so the folder '
        'there was left exactly as it was.',
        details: e.toString(),
      );
    }

    // The new folder is in place. Best-effort, like every tree removal: a
    // part that will not go stays behind under its `.ssg-old-` name.
    if (setAside) await removeRemoteDirectoryTree(fs, retired);
  }

  /// Removes the staged copy, and nothing else.
  Future<void> discard() => removeRemoteDirectoryTree(fs, staging);
}

/// What a walk of [root] on [fs] finds: how many plain files, and the sum of
/// the sizes the server listed for them. [unsized] counts the files listed
/// without a size, which add nothing to [bytes].
///
/// Symlinks are neither counted nor followed, matching what the folder copies
/// move. A subfolder that cannot be listed is stepped over, so it counts as
/// empty.
Future<({int files, int bytes, int unsized})> measureRemoteTree(
  RemoteFileSystem fs,
  String root,
) async {
  var files = 0;
  var bytes = 0;
  var unsized = 0;
  final pending = <String>[root];
  for (var index = 0; index < pending.length; index++) {
    final List<RemoteEntry> entries;
    try {
      entries = await fs.list(pending[index]);
    } catch (_) {
      continue;
    }
    for (final entry in entries) {
      if (entry.kind == RemoteEntryKind.file) {
        files++;
        final size = entry.size;
        if (size == null) {
          unsized++;
        } else {
          bytes += size;
        }
      } else if (entry.kind == RemoteEntryKind.directory) {
        pending.add(RemotePath.join(pending[index], entry.name));
      }
    }
  }
  return (files: files, bytes: bytes, unsized: unsized);
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
/// **Collision handling belongs to the caller.** By the time this runs,
/// [destinationDirectory] is either free — a `keep both` has already renamed
/// it via [RemotePath.deduplicate] — or the folder a top-level `replace` is to
/// take the place of. A replace is written into a fresh hidden sibling and
/// swapped in only once all of it has landed (see [StagedDirectoryReplace]),
/// so the folder it replaces comes through a cancel or a failure untouched.
/// Either way nothing inside the folder can collide with anything already on
/// the destination, so per-file copies run without overwrite and without a
/// per-file prompt.
///
/// **Move semantics.** Only the four-check safety chain (bytes acked, handle
/// closed, size on both sides matches) deletes anything. Into a free name,
/// [deleteSourceAfterVerify] pushes through to each per-file copy. A replace
/// holds every deletion until after the swap instead: until then each file it
/// has copied lives in a staging folder that any failure throws away, and a
/// source deleted beside it would go too. Directories on the source are then
/// removed bottom-up once every file under them has left, and only rmdir'd if
/// empty — a failed per-file copy leaves that file *and* every ancestor
/// directory, which is what makes a partial move visible for a retry instead
/// of hiding under a half-empty tree.
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

  final replace = overwrite
      ? StagedDirectoryReplace(destination, destinationDirectory)
      : null;
  // Where the tree is written: beside the folder a replace is for, or
  // straight into a free name.
  final root = replace?.staging ?? destinationDirectory;

  if (replace != null) {
    // A fresh name, so a refusal is a real one — nothing can be written
    // beside the folder being replaced — and arrives before anything has
    // been touched.
    await destination.mkdir(root);
  } else {
    try {
      await destination.mkdir(root);
    } on SftpFailure {
      // Already exists — the caller pre-created it. Fall through and let the
      // per-file writes report the problem if it cannot be used.
    }
  }

  // Walk the source tree breadth-first. Directories in [subdirs] are the
  // ones we need to `mkdir` on the destination — empty subdirectories are
  // recorded here too, so an empty `logs/` folder does not silently
  // disappear across the transfer.
  final subdirs = <String>[];
  final files = <_WalkedFile>[];
  final copied = <({String sourcePath, int bytes})>[];
  var bytesMoved = 0;

  // Up to the swap, every exit from here — cancel, failure, a dropped
  // connection — takes the staging folder with it. The swap cleans up after
  // itself.
  var discardStaging = replace != null;
  try {
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
          // A link to a directory could loop the walk, a link to a file
          // would double-transfer bytes under two names. Same policy as the
          // download walker and the direct path's tree.
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
            destinationPath: RemotePath.join(root, childRelative),
            size: entry.size,
          ));
        }
      }
    }

    // Materialise every subdirectory on the destination up front, so an
    // empty folder still lands and so per-file mkdirs never race with a
    // parent that is still being created.
    for (final relative in subdirs) {
      checkCancelled();
      final path = RemotePath.join(root, relative);
      try {
        await destination.mkdir(path);
      } on SftpFailure {
        // Already there — from the caller having pre-populated. The per-file
        // writes below are still gated on the temporary → rename dance, so a
        // "wrong directory" would surface there.
      }
    }

    for (final file in files) {
      checkCancelled();
      // A per-file failure propagates out of the loop as-is: no rmdirs run,
      // and the source's remaining tree is untouched. Into a free name,
      // whatever files landed stay landed — the "two files and a message"
      // rule that [copyRemoteFile] applies for one file, applied to the
      // batch. A replace's staging folder goes, and the folder it was to
      // replace is still there.
      final outcome = await copyRemoteFile(
        source: source,
        destination: destination,
        sourcePath: file.sourcePath,
        destinationPath: file.destinationPath,
        overwrite: false,
        deleteSourceAfterVerify: deleteSourceAfterVerify && replace == null,
        onProgress: (bytes) {
          onProgress?.call(bytesMoved + bytes);
        },
        isCancelled: isCancelled,
        temporaryNamer: temporaryNamer,
      );
      bytesMoved += outcome.bytesCopied;
      copied.add((sourcePath: file.sourcePath, bytes: outcome.bytesCopied));
      onProgress?.call(bytesMoved);
    }

    if (replace != null) {
      checkCancelled();
      await replace.verifyStaged(files: copied.length, bytes: bytesMoved);
      // The last point a cancel can stop the replace.
      checkCancelled();
      discardStaging = false;
      await replace.swapIn();
    }
  } finally {
    if (discardStaging) await replace!.discard();
  }

  var sourceDeleted = false;
  if (deleteSourceAfterVerify) {
    checkCancelled();
    if (replace != null) {
      // The swap has happened, so the copies are where they belong. Each
      // source file goes on check (4) from [copyRemoteFile]: the source must
      // still hold exactly what was read from it.
      for (final file in copied) {
        final remaining = await source.sizeOf(file.sourcePath);
        if (remaining != null && remaining != file.bytes) {
          throw RemoteCopyFailure(
            'The new folder is in place, but '
            '"${RemotePath.basename(file.sourcePath)}" changed on the source '
            'while it was being copied, so the move stopped there and the '
            'rest of the original was left as it is.',
            details: 'copied ${file.bytes} bytes, the source now holds '
                '$remaining',
          );
        }
        await source.remove(file.sourcePath);
      }
    }
    // Every file went across successfully — the loops above would have
    // thrown otherwise — so every source subdirectory is *ours* to rmdir now.
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
/// directory itself. Best-effort: failures are swallowed, and whatever will
/// not go stays where it is.
///
/// What [StagedDirectoryReplace] clears away — the folder a replace has moved
/// aside, or a staged copy that will not be used — and what a direct folder
/// copy uses on its partial tree and on a moved source. Public so every
/// caller reaches the same implementation rather than growing subtly
/// different tree-blows.
Future<void> removeRemoteDirectoryTree(
  RemoteFileSystem fs,
  String directory,
) async {
  // [RemoteFileSystem.isDirectory] follows symlinks, and so would the walk
  // below: handed a link to a folder — a "replace" whose target name is
  // `www -> /var/www` — it listed the folder the link points at and deleted
  // everything in it. A link is removed as the link, never walked.
  if (await _isSymlink(fs, directory)) {
    try {
      await fs.remove(directory);
    } catch (_) {
      // Forbidden. The link and its target both stay, which is the safe way
      // for this to fail.
    }
    return;
  }

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

/// Whether [path] is itself a symlink, without following it.
///
/// Asked of the parent's listing, which reports a link as a link
/// (`readdir` attributes are `lstat`'s). If the parent cannot be listed the
/// answer is not known, and a link must still not be walked, so SFTP's
/// `remove` settles it: it unlinks a file or a link as itself and refuses a
/// real directory. Succeeding there means there is nothing left to walk.
Future<bool> _isSymlink(RemoteFileSystem fs, String path) async {
  final name = RemotePath.basename(path);
  try {
    final siblings = await fs.list(RemotePath.parent(path));
    return siblings.any(
      (e) => e.name == name && e.kind == RemoteEntryKind.symlink,
    );
  } catch (_) {
    try {
      await fs.remove(path);
      return true;
    } catch (_) {
      return false;
    }
  }
}
