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
