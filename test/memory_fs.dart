import 'dart:io';
import 'dart:typed_data';

import 'package:secure_shell_go/models/remote_entry.dart';
import 'package:secure_shell_go/services/sftp_service.dart';

/// A remote filesystem held in memory: paths to byte counts, plus a record of
/// everything that was done to it.
///
/// The seam being exercised is [RemoteFileSystem] itself, which is why a copy
/// between two servers can be tested at all without either one existing. The
/// read side deliberately mirrors `SftpService.download`: chunked, cancel
/// checked *between* chunks, and — the part that matters here — awaiting the
/// write callback before it produces the next chunk.
///
/// Shared by the relay, direct and upload folder tests, which is why it also
/// renames whole folders the way a server does and takes uploads.
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

  /// Symlinks here, link path → target. As over SFTP: listing a link lists
  /// its target and [isDirectory] follows it (`opendir`, `stat`), while the
  /// link's parent lists it as a symlink (`readdir` attributes are lstat's).
  final Map<String, String> symlinks = {};

  @override
  Future<List<RemoteEntry>> list(String path) async {
    if (throwOnList) {
      throw SftpFailure('Permission denied.', isPermissionDenied: true);
    }
    final linkTarget = symlinks[path];
    if (linkTarget != null) {
      return [
        for (final e in await list(linkTarget))
          RemoteEntry(
            name: e.name,
            path: '$path/${e.name}',
            kind: e.kind,
            size: e.size,
          ),
      ];
    }
    final entries = <RemoteEntry>[];
    for (final link in symlinks.keys) {
      if (_parentOf(link) == path) {
        entries.add(RemoteEntry(
          name: _basename(link),
          path: link,
          kind: RemoteEntryKind.symlink,
        ));
      }
    }
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

  /// Lands the local file as its size, in [chunkSize] pieces, with a
  /// copy's hooks: [onChunkRead] after each piece, and [failWriteAfter] to
  /// drop the connection part way. As in `SftpService.upload`, nothing is
  /// published until the whole file has gone, a cancel returns early, and a
  /// folder that is not there refuses the file.
  @override
  Future<int> upload(
    String localPath,
    String remotePath, {
    TransferProgress? onProgress,
    CancelCheck? isCancelled,
  }) async {
    final parent = _parentOf(remotePath);
    if (parent != '/' && !directories.contains(parent)) {
      throw SftpFailure('"${_basename(parent)}" is not there any more.');
    }
    final size = await File(localPath).length();
    var moved = 0;
    while (moved < size) {
      if (isCancelled?.call() ?? false) return moved;
      final chunk = (size - moved).clamp(0, chunkSize);
      await Future<void>.delayed(Duration.zero);
      final limit = failWriteAfter;
      if (limit != null && moved + chunk > limit) {
        throw const SftpFailure('The connection dropped during the transfer.');
      }
      moved += chunk;
      onProgress?.call(moved);
      onChunkRead?.call(moved);
    }
    files[remotePath] = moved;
    return moved;
  }

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
    symlinks.remove(path);
  }

  /// Asked before every rename; true makes the server refuse that one.
  bool Function(String from, String to)? refuseRename;

  /// As OpenSSH's `posix-rename`: a folder moves with everything in it, a
  /// link moves as the link, a file may replace a file, and a folder may
  /// replace only an empty folder.
  @override
  Future<void> rename(String from, String to) async {
    if (refuseRename?.call(from, to) ?? false) {
      throw const SftpFailure('The server refused: rename');
    }
    final isDirectory = directories.contains(from);
    if (!isDirectory &&
        !files.containsKey(from) &&
        !symlinks.containsKey(from)) {
      throw SftpFailure('"${_basename(from)}" is not there any more.');
    }
    if (directories.contains(to)) {
      if (!isDirectory || _hasChildren(to)) {
        throw const SftpFailure('The server refused: rename onto a folder');
      }
    } else if (isDirectory &&
        (files.containsKey(to) || symlinks.containsKey(to))) {
      throw const SftpFailure('The server refused: not a directory');
    }

    renamed.add('$from -> $to');
    files.remove(to);
    symlinks.remove(to);
    directories.remove(to);
    bool under(String path) => path == from || path.startsWith('$from/');
    String moved(String path) => '$to${path.substring(from.length)}';
    for (final path in files.keys.where(under).toList()) {
      files[moved(path)] = files.remove(path)!;
    }
    for (final path in symlinks.keys.where(under).toList()) {
      symlinks[moved(path)] = symlinks.remove(path)!;
    }
    for (final path in directories.where(under).toList()) {
      directories
        ..remove(path)
        ..add(moved(path));
    }
  }

  bool _hasChildren(String directory) =>
      files.keys.any((k) => _parentOf(k) == directory) ||
      directories.any((d) => _parentOf(d) == directory) ||
      symlinks.keys.any((l) => _parentOf(l) == directory);

  /// Everything here, under [root], relative to it: `file:<path>=<size>`,
  /// `dir:<path>` and `link:<path>`. What a test compares a folder against.
  Set<String> treeUnder(String root) {
    String? relative(String path) =>
        path.startsWith('$root/') ? path.substring(root.length + 1) : null;
    return {
      for (final e in files.entries)
        if (relative(e.key) case final r?) 'file:$r=${e.value}',
      for (final d in directories)
        if (relative(d) case final r?) 'dir:$r',
      for (final l in symlinks.keys)
        if (relative(l) case final r?) 'link:$r',
    };
  }

  /// Every path here that a staging name left behind: a `.ssg-` folder or
  /// file, or a test's deterministic `.part` one.
  List<String> get leftovers => [
        ...files.keys,
        ...directories,
        ...symlinks.keys,
      ].where((p) => p.contains('.ssg-') || p.endsWith('.part')).toList();

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
    if (_hasChildren(path)) {
      throw const SftpFailure('rmdir: not empty');
    }
    directories.remove(path);
    removed.add(path);
  }

  @override
  Future<bool> isDirectory(String path) async =>
      directories.contains(symlinks[path] ?? path);

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
