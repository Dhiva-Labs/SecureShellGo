/// What a directory entry is, as far as the browser cares.
enum RemoteEntryKind {
  directory,
  file,
  symlink,
  other;

  bool get isDirectory => this == RemoteEntryKind.directory;
}

/// One row in the remote file browser.
///
/// A plain value object: the SFTP layer maps `SftpName`/`SftpFileAttrs` onto
/// this so the browser never touches dartssh2 types, and so sorting,
/// filtering and formatting can be unit-tested without a server.
class RemoteEntry {
  const RemoteEntry({
    required this.name,
    required this.path,
    required this.kind,
    this.size,
    this.modified,
    this.permissions,
    this.linkTargetIsDirectory,
  });

  final String name;

  /// Absolute path on the remote host.
  final String path;

  final RemoteEntryKind kind;

  /// Bytes, when the server reported a size.
  final int? size;

  final DateTime? modified;

  /// Octal permission bits (`0644`), when reported.
  final int? permissions;

  /// For symlinks, whether the target resolved to a directory. Null when it
  /// could not be resolved (dangling link, or permission denied on the target).
  final bool? linkTargetIsDirectory;

  bool get isHidden => name.startsWith('.');

  /// Whether tapping this row should navigate rather than download.
  bool get isNavigable =>
      kind.isDirectory ||
      (kind == RemoteEntryKind.symlink && linkTargetIsDirectory == true);

  /// Whether this row can be downloaded.
  bool get isDownloadable =>
      kind == RemoteEntryKind.file ||
      (kind == RemoteEntryKind.symlink && linkTargetIsDirectory != true);

  RemoteEntry copyWith({bool? linkTargetIsDirectory}) => RemoteEntry(
        name: name,
        path: path,
        kind: kind,
        size: size,
        modified: modified,
        permissions: permissions,
        linkTargetIsDirectory:
            linkTargetIsDirectory ?? this.linkTargetIsDirectory,
      );

  /// Directories first, then case-insensitive by name — the ordering every
  /// file manager uses, and the one that makes a deep tree navigable with a
  /// thumb.
  static int compare(RemoteEntry a, RemoteEntry b) {
    final aDir = a.isNavigable;
    final bDir = b.isNavigable;
    if (aDir != bDir) return aDir ? -1 : 1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }
}
