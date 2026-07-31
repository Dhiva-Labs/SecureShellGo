/// A saved remote path on one host, for quick return via the file browser's
/// bookmarks sheet.
///
/// Deliberately free of anything about the host itself beyond [hostId] —
/// this model does not depend on `models/host.dart`, so a host being edited
/// or removed elsewhere never has to touch this file at the same time.
/// [BookmarkStore] is the one place that has to know both exist.
class PathBookmark {
  const PathBookmark({
    required this.id,
    required this.hostId,
    required this.path,
    this.label,
  });

  final String id;
  final String hostId;
  final String path;

  /// User-given name for the row in the bookmarks sheet. Null or blank falls
  /// back to showing [path] itself — see [displayLabel].
  final String? label;

  /// What the bookmarks sheet shows as the row's title.
  String get displayLabel {
    final trimmed = label?.trim();
    return (trimmed == null || trimmed.isEmpty) ? path : trimmed;
  }

  PathBookmark copyWith({String? label}) => PathBookmark(
        id: id,
        hostId: hostId,
        path: path,
        label: label ?? this.label,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'hostId': hostId,
        'path': path,
        if (label != null && label!.trim().isNotEmpty) 'label': label,
      };

  factory PathBookmark.fromJson(Map<String, dynamic> json) => PathBookmark(
        id: json['id'] as String,
        hostId: json['hostId'] as String,
        path: json['path'] as String,
        label: json['label'] as String?,
      );
}
