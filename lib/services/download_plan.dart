import '../models/remote_entry.dart';
import 'remote_path.dart';
import 'sftp_service.dart';

/// One file a recursive download will fetch, and where it lands on the device.
class PlannedDownload {
  const PlannedDownload({
    required this.remotePath,
    required this.fileName,
    required this.relativeDirectory,
    this.size,
  });

  /// Absolute path on the server.
  final String remotePath;

  /// Device-side file name, already sanitised.
  final String fileName;

  /// Device-side directory under `Download/`, already sanitised — e.g.
  /// `project/src` for `project/src/main.dart`. Never empty for a directory
  /// download: the top level is `Download/<dirname>/`.
  final String relativeDirectory;

  /// Bytes, when the listing reported a size.
  final int? size;

  /// What the transfer panel shows as the destination.
  String get destination => relativeDirectory.isEmpty
      ? 'Downloads/$fileName'
      : 'Downloads/$relativeDirectory/$fileName';
}

/// What walking a remote directory found, before a byte is moved.
///
/// Produced up front rather than streamed into the queue so the user can be
/// told "412 files, 1.8 GB" and say no — a directory download is the one
/// transfer in this app whose size is not obvious from the thing that was
/// tapped.
class DirectoryDownloadPlan {
  const DirectoryDownloadPlan({
    required this.root,
    required this.rootName,
    required this.files,
    required this.totalBytes,
    required this.skippedLinks,
    required this.unreadable,
    required this.truncated,
  });

  /// The directory that was walked.
  final String root;

  /// Its sanitised name — the folder created under `Download/`.
  final String rootName;

  final List<PlannedDownload> files;

  /// Sum of the sizes the listings reported. Files with no reported size
  /// contribute nothing, so this is a floor, not a promise.
  final int totalBytes;

  /// Symlinks passed over. Not an error: see [planDirectoryDownload].
  final int skippedLinks;

  /// Directories the server would not list (permission denied, usually).
  final List<String> unreadable;

  /// True when a cap stopped the walk early, so the plan is a prefix of the
  /// tree rather than all of it.
  final bool truncated;

  int get fileCount => files.length;

  bool get isEmpty => files.isEmpty;
}

/// Thrown by [planDirectoryDownload] when the caller's cancel check fires.
///
/// A walk of a deep tree is many round trips, so it needs to be abandonable
/// mid-flight; throwing rather than returning a partial plan means a
/// cancelled scan can never be mistaken for a complete one.
class DirectoryWalkCancelled implements Exception {
  const DirectoryWalkCancelled();

  @override
  String toString() => 'Directory scan cancelled';
}

/// Walks [directory] and plans a download of every file under it, preserving
/// the subdirectory structure beneath `Download/<dirname>/`.
///
/// Symlinks are **not followed**, in either direction: a link to a directory
/// can point back up its own tree and turn the walk into an infinite loop
/// (`/proc/self`, or a plain `ln -s .. loop`), and a link to a file would
/// download the same bytes twice under two names. They are counted so the
/// confirm dialog can say what was left out rather than quietly under-copying.
///
/// A directory that will not list is recorded and stepped over — one
/// unreadable subdirectory in a large tree should not fail the whole
/// download, and the user can see which ones were missed.
Future<DirectoryDownloadPlan> planDirectoryDownload(
  RemoteFileSystem fs,
  String directory, {
  CancelCheck? isCancelled,
  int maxFiles = 5000,
  int maxDepth = 24,
}) async {
  void checkCancelled() {
    if (isCancelled?.call() ?? false) throw const DirectoryWalkCancelled();
  }

  final root = RemotePath.normalize(directory);
  var rootName = RemotePath.sanitiseRelativeDirectory(
    RemotePath.basename(root),
  );
  if (rootName.isEmpty) rootName = 'download';

  final files = <PlannedDownload>[];
  final unreadable = <String>[];
  var totalBytes = 0;
  var skippedLinks = 0;
  var truncated = false;

  final pending = <({String path, String relative, int depth})>[
    (path: root, relative: rootName, depth: 0),
  ];

  for (var index = 0; index < pending.length; index++) {
    checkCancelled();
    final current = pending[index];

    final List<RemoteEntry> entries;
    try {
      entries = await fs.list(current.path);
    } on DirectoryWalkCancelled {
      rethrow;
    } catch (_) {
      unreadable.add(current.path);
      continue;
    }
    checkCancelled();

    for (final entry in entries) {
      if (entry.kind == RemoteEntryKind.symlink) {
        skippedLinks++;
        continue;
      }
      if (entry.kind == RemoteEntryKind.directory) {
        if (current.depth + 1 > maxDepth) {
          truncated = true;
          continue;
        }
        final segment = RemotePath.sanitiseRelativeDirectory(entry.name);
        pending.add(
          (
            path: entry.path,
            relative: segment.isEmpty
                ? current.relative
                : '${current.relative}/$segment',
            depth: current.depth + 1,
          ),
        );
        continue;
      }
      if (entry.kind != RemoteEntryKind.file) continue;

      if (files.length >= maxFiles) {
        truncated = true;
        break;
      }
      files.add(
        PlannedDownload(
          remotePath: entry.path,
          fileName: RemotePath.sanitiseFileName(entry.name),
          relativeDirectory: RemotePath.sanitiseRelativeDirectory(
            current.relative,
          ),
          size: entry.size,
        ),
      );
      totalBytes += entry.size ?? 0;
    }

    if (truncated && files.length >= maxFiles) break;
  }

  return DirectoryDownloadPlan(
    root: root,
    rootName: rootName,
    files: files,
    totalBytes: totalBytes,
    skippedLinks: skippedLinks,
    unreadable: unreadable,
    truncated: truncated,
  );
}
