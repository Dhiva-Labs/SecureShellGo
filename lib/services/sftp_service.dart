import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../models/remote_entry.dart';
import 'remote_path.dart';

/// A remote filesystem failure with a message written for a human.
class SftpFailure implements Exception {
  const SftpFailure(this.message, {this.details, this.isPermissionDenied = false});

  final String message;
  final String? details;

  /// Set when the server said "permission denied", which the browser shows as
  /// an explanation rather than an error — an unreadable directory is a normal
  /// thing to walk into on a shared machine, not a malfunction.
  final bool isPermissionDenied;

  @override
  String toString() => message;
}

/// Reports cumulative bytes moved.
typedef TransferProgress = void Function(int bytes);

/// Asked between chunks; returning true aborts the transfer.
typedef CancelCheck = bool Function();

/// A remote file being written, chunk by chunk.
///
/// The mirror image of [DownloadWriter] on the device side, and it exists for
/// the same reason: a server-to-server copy must be able to feed the bytes it
/// is reading straight into a second server without ever holding the file.
/// [add] completes only once the destination has acknowledged the write, which
/// is what lets the read side's `await` on it push backpressure all the way
/// back to the source's SSH channel.
abstract class RemoteFileWriter {
  /// Appends [chunk] at the current offset.
  Future<void> add(Uint8List chunk);

  /// Closes the handle. The bytes are on the server once this returns.
  Future<void> close();

  /// Closes the handle and removes the partial file. A half-written file
  /// looks complete to everything else on that machine, which is worse than
  /// no file at all.
  Future<void> abort();
}

/// A file's identity at one moment, as the server reported it.
///
/// The editor records one of these when it opens a file and compares against
/// a fresh one before it writes: if the size or the modification time moved
/// while the file was open on screen, somebody else got there first and the
/// save has to stop and ask rather than flatten their work.
class RemoteFileStat {
  const RemoteFileStat({this.size, this.modified, this.permissions});

  final int? size;
  final DateTime? modified;

  /// Octal permission bits, without the file-type bits — `0644`, `0755`.
  final int? permissions;
}

/// The stat-and-chmod half of a remote filesystem.
///
/// Split out of [RemoteFileSystem], and asked for separately, because it is
/// the *editor's* requirement and nothing else's: listing, downloading and
/// copying never need a file's mode, and folding these two methods into
/// [RemoteFileSystem] would oblige every fake in the test tree to grow them
/// for a feature none of them exercises. [RemoteFileWriter] is a separate
/// interface for the same reason.
abstract class RemoteFileMetadata {
  /// Stats one path, or null when the server will not say — including
  /// because the file is not there.
  Future<RemoteFileStat?> statFile(String path);

  /// Sets [path]'s permission bits. Returns false when the server declines,
  /// which is a normal outcome on a filesystem mounted without them and is
  /// reported to the user rather than treated as a failed save.
  Future<bool> setPermissions(String path, int permissions);
}

/// What the browser and the transfer queue need from a remote filesystem.
///
/// An interface rather than just [SftpService] so the session's transfer logic
/// — collisions, cancellation, cleanup after a failure — can be tested against
/// a fake instead of a real server.
abstract class RemoteFileSystem {
  /// The user's home directory.
  Future<String> home();

  /// Server-side resolution of [path] (expands `..`, applies the CWD rules).
  Future<String> resolve(String path);

  /// Lists [path], directories first.
  Future<List<RemoteEntry>> list(String path);

  /// Size of a remote file, or null when the server does not report one.
  Future<int?> sizeOf(String path);

  /// Streams [remotePath] into [write], reporting cumulative bytes.
  Future<int> download(
    String remotePath, {
    required Future<void> Function(Uint8List chunk) write,
    TransferProgress? onProgress,
    CancelCheck? isCancelled,
  });

  /// Uploads [localPath] to [remotePath], reporting cumulative bytes.
  Future<int> upload(
    String localPath,
    String remotePath, {
    TransferProgress? onProgress,
    CancelCheck? isCancelled,
  });

  /// Whether [path] already exists on the remote side.
  Future<bool> exists(String path);

  /// Opens [remotePath] for writing, creating or truncating it.
  ///
  /// The write half of a server-to-server copy: the source's [download] feeds
  /// [RemoteFileWriter.add] directly, so the bytes are never all in memory at
  /// once.
  Future<RemoteFileWriter> openWrite(String remotePath);

  /// Deletes a remote **file**. Not directories — a server-to-server "move"
  /// only ever has a file to clean up, and a recursive remote delete is not
  /// something to grow by accident.
  Future<void> remove(String path);

  /// Renames [from] to [to] on the server. Used to publish a completed copy
  /// under its final name, so a cancelled one never appears there at all.
  Future<void> rename(String from, String to);

  /// Creates one directory on the server.
  ///
  /// Fails if [path] already exists or its parent does not — the recursive
  /// folder-transfer code holds those invariants itself (breadth-first over
  /// the parents first, and a preflight rm on an overwrite target) rather
  /// than dressing this up as `mkdir -p`.
  Future<void> mkdir(String path);

  /// Removes an empty directory. Fails if the directory still holds anything,
  /// which is the same protection [remove] has — a recursive rmdir is not a
  /// thing to grow by accident. The recursive copy path removes files first
  /// and then bottom-ups the rmdirs.
  Future<void> removeDirectory(String path);

  /// True when [path] exists **and** is a directory. False for a missing path,
  /// a file, a symlink that does not point at a directory, or any status the
  /// server declines to report.
  Future<bool> isDirectory(String path);

  Future<void> close();
}

/// The remote filesystem, in terms this app understands.
///
/// Wraps dartssh2's [SftpClient] so nothing above this layer sees `SftpName`,
/// `SftpFileAttrs` or `SftpStatusError`. The client itself runs on the same
/// authenticated SSH connection as the shell — `SSHClient.sftp()` opens a
/// second channel, not a second login — which is the whole reason the file
/// browser costs the user no extra password or host-key prompt.
class SftpService implements RemoteFileSystem, RemoteFileMetadata {
  SftpService(this._client);

  final SftpClient _client;

  /// Chunks big enough to keep the SSH window full without making a cancel
  /// feel unresponsive.
  static const int chunkSize = 64 * 1024;
  static const int _maxPendingReads = 32;

  /// How many symlinks in one listing get their target resolved. Each costs a
  /// round trip, and a directory full of them (`/etc/alternatives`) would
  /// otherwise take seconds to open.
  static const int _symlinkResolveLimit = 64;

  /// The user's home directory, via SFTP realpath of ".".
  @override
  Future<String> home() async {
    try {
      return RemotePath.normalize(await _client.absolute('.'));
    } catch (e) {
      // Not fatal: "/" is always listable enough to get started.
      return RemotePath.root;
    }
  }

  /// Resolves [path] against the server (expands `..`, follows the CWD rules).
  @override
  Future<String> resolve(String path) async {
    try {
      return RemotePath.normalize(await _client.absolute(path));
    } catch (_) {
      return RemotePath.normalize(path);
    }
  }

  /// Lists [path], sorted directories-first.
  @override
  Future<List<RemoteEntry>> list(String path) async {
    final directory = RemotePath.normalize(path);
    final List<SftpName> names;
    try {
      names = await _client.listdir(directory);
    } catch (e) {
      throw _describe(e, directory);
    }

    final entries = <RemoteEntry>[];
    for (final name in names) {
      if (name.filename == '.' || name.filename == '..') continue;
      entries.add(
        RemoteEntry(
          name: name.filename,
          path: RemotePath.join(directory, name.filename),
          kind: _kindOf(name.attr),
          size: name.attr.size,
          modified: _timeOf(name.attr.modifyTime),
          permissions: name.attr.mode?.value,
        ),
      );
    }

    await _resolveSymlinks(entries);
    entries.sort(RemoteEntry.compare);
    return entries;
  }

  /// Fills in [RemoteEntry.linkTargetIsDirectory] so a symlink to a directory
  /// navigates instead of trying to download.
  Future<void> _resolveSymlinks(List<RemoteEntry> entries) async {
    final indexes = <int>[];
    for (var i = 0; i < entries.length; i++) {
      if (entries[i].kind == RemoteEntryKind.symlink) indexes.add(i);
      if (indexes.length >= _symlinkResolveLimit) break;
    }
    if (indexes.isEmpty) return;

    await Future.wait(
      indexes.map((i) async {
        try {
          final stat = await _client.stat(entries[i].path);
          entries[i] = entries[i].copyWith(
            linkTargetIsDirectory: stat.isDirectory,
          );
        } catch (_) {
          // Dangling link, or no permission on the target. Leaving it null is
          // right: the row shows as a link and does nothing surprising.
        }
      }),
    );
  }

  /// Size of a remote file, or null when the server does not report one.
  @override
  Future<int?> sizeOf(String path) async {
    try {
      return (await _client.stat(path)).size;
    } catch (_) {
      return null;
    }
  }

  /// Streams [remotePath] into [write], reporting cumulative bytes.
  ///
  /// [write] is awaited per chunk on purpose: that is what propagates
  /// backpressure from the (slow) MediaStore write back through the SFTP read
  /// pipeline, so a large download does not grow the heap.
  @override
  Future<int> download(
    String remotePath, {
    required Future<void> Function(Uint8List chunk) write,
    TransferProgress? onProgress,
    CancelCheck? isCancelled,
  }) async {
    final SftpFile file;
    try {
      file = await _client.open(remotePath, mode: SftpFileOpenMode.read);
    } catch (e) {
      throw _describe(e, remotePath);
    }

    var moved = 0;
    try {
      final stream = file.read(
        chunkSize: chunkSize,
        maxPendingRequests: _maxPendingReads,
      );
      await for (final chunk in stream) {
        if (isCancelled?.call() ?? false) break;
        await write(chunk);
        moved += chunk.length;
        onProgress?.call(moved);
      }
      return moved;
    } catch (e) {
      throw _describe(e, remotePath);
    } finally {
      try {
        await file.close();
      } catch (_) {
        // Channel already gone.
      }
    }
  }

  /// Uploads [localPath] to [remotePath], reporting cumulative bytes.
  @override
  Future<int> upload(
    String localPath,
    String remotePath, {
    TransferProgress? onProgress,
    CancelCheck? isCancelled,
  }) async {
    final source = File(localPath);
    final SftpFile file;
    try {
      file = await _client.open(
        remotePath,
        mode: SftpFileOpenMode.create |
            SftpFileOpenMode.write |
            SftpFileOpenMode.truncate,
      );
    } catch (e) {
      throw _describe(e, remotePath);
    }

    var moved = 0;
    var cancelled = false;
    try {
      await for (final chunk in source.openRead()) {
        if (isCancelled?.call() ?? false) {
          cancelled = true;
          break;
        }
        final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
        await file.writeBytes(bytes, offset: moved);
        moved += bytes.length;
        onProgress?.call(moved);
      }
      return moved;
    } on FileSystemException catch (e) {
      throw SftpFailure(
        'Could not read the file you picked.',
        details: e.toString(),
      );
    } catch (e) {
      throw _describe(e, remotePath);
    } finally {
      try {
        await file.close();
      } catch (_) {
        // Channel already gone.
      }
      if (cancelled) {
        // A half-written upload on the server is worse than no upload: it
        // looks like a complete file to everything else on that machine.
        try {
          await _client.remove(remotePath);
        } catch (_) {
          // Best effort.
        }
      }
    }
  }

  /// Whether [path] already exists on the remote side.
  @override
  Future<bool> exists(String path) async {
    try {
      await _client.stat(path);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<RemoteFileStat?> statFile(String path) async {
    try {
      final attrs = await _client.stat(path);
      return RemoteFileStat(
        size: attrs.size,
        modified: _timeOf(attrs.modifyTime),
        // The low twelve bits: permissions and the setuid/setgid/sticky
        // flags, without the file-type bits above them. Handing the whole
        // mode word back to `setStat` would work, but storing the type in
        // something called "permissions" invites a later caller to write it
        // somewhere it does not belong.
        permissions: attrs.mode == null ? null : attrs.mode!.value & 0xFFF,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> setPermissions(String path, int permissions) async {
    try {
      await _client.setStat(
        path,
        SftpFileAttrs(mode: SftpFileMode.value(permissions & 0xFFF)),
      );
      return true;
    } catch (_) {
      // A server that will not chmod is not a failed save — the bytes are
      // already safely in place by the time this runs. The caller says so in
      // the confirmation instead.
      return false;
    }
  }

  /// Opens [remotePath] for writing. See [RemoteFileWriter].
  @override
  Future<RemoteFileWriter> openWrite(String remotePath) async {
    try {
      final file = await _client.open(
        remotePath,
        mode: SftpFileOpenMode.create |
            SftpFileOpenMode.write |
            SftpFileOpenMode.truncate,
      );
      return _SftpFileWriter(_client, file, remotePath);
    } catch (e) {
      throw _describe(e, remotePath);
    }
  }

  @override
  Future<void> remove(String path) async {
    try {
      await _client.remove(path);
    } catch (e) {
      throw _describe(e, path);
    }
  }

  @override
  Future<void> rename(String from, String to) async {
    try {
      await _client.rename(from, to);
    } catch (e) {
      throw _describe(e, to);
    }
  }

  @override
  Future<void> mkdir(String path) async {
    try {
      await _client.mkdir(path);
    } catch (e) {
      throw _describe(e, path);
    }
  }

  @override
  Future<void> removeDirectory(String path) async {
    try {
      await _client.rmdir(path);
    } catch (e) {
      throw _describe(e, path);
    }
  }

  @override
  Future<bool> isDirectory(String path) async {
    try {
      return (await _client.stat(path)).isDirectory;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> close() async {
    try {
      await _client.close();
    } catch (_) {
      // Already gone.
    }
  }

  /// Turns an SFTP status code into something worth reading. Shared with
  /// [_SftpFileWriter], which is why it is not private to the instance.
  static SftpFailure describeError(Object error, String path) =>
      _describe(error, path);

  static RemoteEntryKind _kindOf(SftpFileAttrs attrs) {
    if (attrs.isDirectory) return RemoteEntryKind.directory;
    if (attrs.isSymbolicLink) return RemoteEntryKind.symlink;
    if (attrs.isFile) return RemoteEntryKind.file;
    if (attrs.mode == null) {
      // Some servers omit permissions in a directory listing. A size but no
      // mode is overwhelmingly a regular file.
      return attrs.size != null ? RemoteEntryKind.file : RemoteEntryKind.other;
    }
    return RemoteEntryKind.other;
  }

  static DateTime? _timeOf(int? epochSeconds) {
    if (epochSeconds == null || epochSeconds <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000);
  }

  /// Turns an SFTP status code into something worth reading.
  static SftpFailure _describe(Object error, String path) {
    if (error is SftpFailure) return error;
    if (error is SftpStatusError) {
      switch (error.code) {
        case 2:
          return SftpFailure(
            '"${RemotePath.basename(path)}" is not there any more.',
            details: error.toString(),
          );
        case 3:
          return SftpFailure(
            'Permission denied. Your account cannot read '
            '"${RemotePath.basename(path)}" on this server.',
            details: error.toString(),
            isPermissionDenied: true,
          );
        case 4:
          return SftpFailure(
            'The server refused: ${error.message}',
            details: error.toString(),
          );
        case 8:
          return SftpFailure(
            'The server does not support that operation.',
            details: error.toString(),
          );
      }
      return SftpFailure(error.message, details: error.toString());
    }
    if (error is SftpAbortError) {
      return SftpFailure(
        'The connection dropped during the transfer.',
        details: error.toString(),
      );
    }
    if (error is SftpError) {
      return SftpFailure(error.message, details: error.toString());
    }
    return SftpFailure(
      'Could not read "${RemotePath.basename(path)}" from the server.',
      details: error.toString(),
    );
  }

  /// Best-effort MIME type from the file name, so Android files the download
  /// under a sensible type instead of `application/octet-stream` for
  /// everything.
  static String mimeTypeFor(String fileName) {
    final ext = RemotePath.extension(fileName).toLowerCase();
    return const <String, String>{
          '.txt': 'text/plain',
          '.log': 'text/plain',
          '.md': 'text/markdown',
          '.csv': 'text/csv',
          '.json': 'application/json',
          '.xml': 'text/xml',
          '.yaml': 'text/yaml',
          '.yml': 'text/yaml',
          '.conf': 'text/plain',
          '.sh': 'text/x-shellscript',
          '.pdf': 'application/pdf',
          '.zip': 'application/zip',
          '.gz': 'application/gzip',
          '.tgz': 'application/gzip',
          '.bz2': 'application/x-bzip2',
          '.xz': 'application/x-xz',
          '.tar': 'application/x-tar',
          '.7z': 'application/x-7z-compressed',
          '.png': 'image/png',
          '.jpg': 'image/jpeg',
          '.jpeg': 'image/jpeg',
          '.gif': 'image/gif',
          '.webp': 'image/webp',
          '.svg': 'image/svg+xml',
          '.mp3': 'audio/mpeg',
          '.wav': 'audio/wav',
          '.flac': 'audio/flac',
          '.mp4': 'video/mp4',
          '.mkv': 'video/x-matroska',
          '.webm': 'video/webm',
          '.apk': 'application/vnd.android.package-archive',
          '.deb': 'application/vnd.debian.binary-package',
          '.html': 'text/html',
          '.htm': 'text/html',
        }[ext] ??
        'application/octet-stream';
  }
}

/// One open [SftpFile] being appended to.
///
/// Tracks the offset itself rather than relying on a server-side file pointer:
/// SFTP writes carry an explicit offset, and the source stream hands over
/// chunks whose sizes we do not choose.
class _SftpFileWriter implements RemoteFileWriter {
  _SftpFileWriter(this._client, this._file, this._path);

  final SftpClient _client;
  final SftpFile _file;
  final String _path;

  var _offset = 0;
  var _closed = false;

  @override
  Future<void> add(Uint8List chunk) async {
    if (chunk.isEmpty) return;
    try {
      await _file.writeBytes(chunk, offset: _offset);
    } catch (e) {
      throw SftpService.describeError(e, _path);
    }
    _offset += chunk.length;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _file.close();
    } catch (e) {
      throw SftpService.describeError(e, _path);
    }
  }

  @override
  Future<void> abort() async {
    if (!_closed) {
      _closed = true;
      try {
        await _file.close();
      } catch (_) {
        // Channel already gone; the remove below is what matters.
      }
    }
    try {
      await _client.remove(_path);
    } catch (_) {
      // Best effort. The file is written under a temporary name (see
      // `remote_copy.dart`), so what is left behind is at worst identifiable
      // clutter, never something masquerading as the user's file.
    }
  }
}
