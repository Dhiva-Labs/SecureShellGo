import 'dart:typed_data';

import '../models/remote_entry.dart';
import 'remote_copy.dart';
import 'remote_path.dart';
import 'sftp_service.dart';

/// Deletes [entry] from [fs]: a folder with everything in it, anything else
/// as itself. Returns null once it is gone, or the reason it is not.
///
/// Only a real folder is walked. Everything else — a file, and above all a
/// symlink, including one that points at a folder — goes through
/// [RemoteFileSystem.remove], which is SFTP's unlink: it removes a link as
/// the link and never touches what it points to. A folder goes through
/// [removeRemoteDirectoryTree], which makes the same promise again for a
/// link the listing mistook for a folder.
Future<SftpFailure?> deleteRemoteEntry(
  RemoteFileSystem fs,
  RemoteEntry entry,
) async {
  if (entry.kind != RemoteEntryKind.directory) {
    try {
      await fs.remove(entry.path);
      return null;
    } on SftpFailure catch (e) {
      return e;
    } catch (e) {
      return SftpFailure(
        'Could not delete "${entry.name}".',
        details: e.toString(),
      );
    }
  }

  final recorder = _RefusalRecorder(fs);
  await removeRemoteDirectoryTree(recorder, entry.path);
  // The tree removal reports nothing, by design, so whether it worked is
  // asked of the server afterwards.
  if (!await fs.exists(entry.path)) return null;

  final reason = recorder.refusal;
  final head =
      'Some of "${entry.name}" could not be deleted, so the folder is still '
      'there.';
  return SftpFailure(
    reason == null ? head : '$head ${reason.message}',
    details: reason?.details,
    isPermissionDenied: reason?.isPermissionDenied ?? false,
  );
}

/// Whether [name] is already in use in [directory] — by anything, a link
/// that points nowhere included.
///
/// Asked before a rename and before a new folder, because neither may land
/// on a name that is taken: dartssh2 renames with OpenSSH's `posix-rename`,
/// which replaces whatever is at the target without a word, and a rename
/// that silently deletes some other file is the worst thing this browser
/// could do.
///
/// Two questions, because neither answer is complete on its own. The
/// listing reports names as they are (`readdir` attributes are `lstat`'s, so
/// a dangling link still counts) but compares them exactly. A stat of the
/// joined path catches what the server's own disk considers the same name —
/// `Notes.txt` and `notes.txt` on a Windows or macOS server. [renaming] is
/// the entry's current name: changing only its case is not a clash with
/// itself.
Future<bool> remoteNameTaken(
  RemoteFileSystem fs,
  String directory,
  String name, {
  String? renaming,
}) async {
  try {
    final entries = await fs.list(directory);
    if (entries.any((e) => e.name == name)) return true;
  } on SftpFailure {
    // A folder this account can enter but not list can still be asked
    // about one name.
  }
  if (renaming != null && renaming.toLowerCase() == name.toLowerCase()) {
    return false;
  }
  return fs.exists(RemotePath.join(directory, name));
}

/// Passes everything through to [_inner], remembering the refusals.
///
/// [removeRemoteDirectoryTree] swallows every failure — it is also the
/// "clear the way" step of an overwrite, where a leftover is fine. A delete
/// the user asked for has to say why it stopped short, and the server's own
/// words are the useful part; this collects them on the way past without
/// changing a single step of the walk.
class _RefusalRecorder implements RemoteFileSystem {
  _RefusalRecorder(this._inner);

  final RemoteFileSystem _inner;

  SftpFailure? _first;
  SftpFailure? _firstDenied;

  /// A permission refusal over any other: it names the file that is in the
  /// way, where the folder's own rmdir only says it is not empty.
  SftpFailure? get refusal => _firstDenied ?? _first;

  Future<T> _watch<T>(Future<T> operation) async {
    try {
      return await operation;
    } on SftpFailure catch (e) {
      _first ??= e;
      if (e.isPermissionDenied) _firstDenied ??= e;
      rethrow;
    }
  }

  @override
  Future<List<RemoteEntry>> list(String path) => _watch(_inner.list(path));

  @override
  Future<void> remove(String path) => _watch(_inner.remove(path));

  @override
  Future<void> removeDirectory(String path) =>
      _watch(_inner.removeDirectory(path));

  @override
  Future<String> home() => _inner.home();

  @override
  Future<String> resolve(String path) => _inner.resolve(path);

  @override
  Future<int?> sizeOf(String path) => _inner.sizeOf(path);

  @override
  Future<int> download(
    String remotePath, {
    required Future<void> Function(Uint8List chunk) write,
    TransferProgress? onProgress,
    CancelCheck? isCancelled,
  }) =>
      _inner.download(
        remotePath,
        write: write,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );

  @override
  Future<int> upload(
    String localPath,
    String remotePath, {
    TransferProgress? onProgress,
    CancelCheck? isCancelled,
  }) =>
      _inner.upload(
        localPath,
        remotePath,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );

  @override
  Future<bool> exists(String path) => _inner.exists(path);

  @override
  Future<RemoteFileWriter> openWrite(String remotePath) =>
      _inner.openWrite(remotePath);

  @override
  Future<void> rename(String from, String to) => _inner.rename(from, to);

  @override
  Future<void> mkdir(String path) => _inner.mkdir(path);

  @override
  Future<bool> isDirectory(String path) => _inner.isDirectory(path);

  @override
  Future<void> close() async {
    // The channel belongs to the session, not to this view of it.
  }
}
