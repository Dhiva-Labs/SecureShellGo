/// POSIX path arithmetic for remote (SFTP) paths.
///
/// `package:path` is deliberately not used here: on a Windows host it would
/// switch to backslash semantics and silently produce paths no SSH server
/// understands. Remote paths are always POSIX regardless of what the phone is.
class RemotePath {
  const RemotePath._();

  static const String separator = '/';
  static const String root = '/';

  /// Collapses `.`/`..`/duplicate separators. Absolute inputs stay absolute
  /// and can never escape above `/`.
  static String normalize(String path) {
    if (path.isEmpty) return root;
    final absolute = path.startsWith(separator);
    final segments = <String>[];

    for (final part in path.split(separator)) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (segments.isNotEmpty && segments.last != '..') {
          segments.removeLast();
        } else if (!absolute) {
          segments.add('..');
        }
        continue;
      }
      segments.add(part);
    }

    if (absolute) return '$separator${segments.join(separator)}';
    return segments.isEmpty ? '.' : segments.join(separator);
  }

  /// Appends [name] to [dir]. [name] may itself be absolute, in which case it
  /// wins — the same rule a shell uses.
  static String join(String dir, String name) {
    if (name.startsWith(separator)) return normalize(name);
    if (dir.isEmpty) return normalize(name);
    final base = dir.endsWith(separator)
        ? dir.substring(0, dir.length - 1)
        : dir;
    return normalize('$base$separator$name');
  }

  /// The containing directory. `/` is its own parent, so an over-eager "up"
  /// button cannot walk off the top.
  static String parent(String path) {
    final normalized = normalize(path);
    if (normalized == root) return root;
    final index = normalized.lastIndexOf(separator);
    if (index <= 0) return root;
    return normalized.substring(0, index);
  }

  /// The final segment. `/` has none, so it reports as `/`.
  static String basename(String path) {
    final normalized = normalize(path);
    if (normalized == root) return root;
    final index = normalized.lastIndexOf(separator);
    return index < 0 ? normalized : normalized.substring(index + 1);
  }

  /// `.tar.gz`-aware only in the sense that it is not: the extension is
  /// everything after the last dot of a name that has one, leading dot
  /// excluded so `.bashrc` is not treated as an extension.
  static String extension(String name) {
    final index = name.lastIndexOf('.');
    if (index <= 0 || index == name.length - 1) return '';
    return name.substring(index);
  }

  /// The name without its [extension].
  static String stem(String name) {
    final ext = extension(name);
    return ext.isEmpty ? name : name.substring(0, name.length - ext.length);
  }

  /// Crumbs for a breadcrumb bar: `(label, path)` from root down to [path].
  static List<({String label, String path})> breadcrumbs(String path) {
    final normalized = normalize(path);
    final crumbs = <({String label, String path})>[
      (label: root, path: root),
    ];
    if (normalized == root) return crumbs;

    var accumulated = '';
    for (final part in normalized.split(separator)) {
      if (part.isEmpty) continue;
      accumulated = '$accumulated$separator$part';
      crumbs.add((label: part, path: accumulated));
    }
    return crumbs;
  }

  /// A filename that is safe to hand to Android's Downloads collection.
  ///
  /// MediaStore rejects (or mangles) separators, and a remote name is fully
  /// attacker-controlled — a server that returns `../../evil` must not be able
  /// to steer where the file lands.
  static String sanitiseFileName(String name) {
    // Take the last real segment first, so `../../evil.sh` saves as
    // `evil.sh` rather than as a mangled `.._.._evil.sh`.
    var cleaned = '';
    for (final segment in name.split(separator).reversed) {
      if (segment.trim().isNotEmpty) {
        cleaned = segment;
        break;
      }
    }
    cleaned = cleaned.replaceAll(RegExp(r'[\\\x00-\x1f]'), '_').trim();
    while (cleaned.startsWith('.')) {
      cleaned = cleaned.substring(1);
    }
    if (cleaned.isEmpty) return 'download';
    // Android's file names cap at 255 bytes; keep the extension when trimming.
    if (cleaned.length > 200) {
      final ext = extension(cleaned);
      cleaned = cleaned.substring(0, 200 - ext.length) + ext;
    }
    return cleaned;
  }

  /// `report.pdf` → `report (1).pdf` → `report (2).pdf`, skipping anything
  /// [taken] already reports.
  ///
  /// Matches how Android and every desktop file manager de-duplicate, so a
  /// user who downloads the same file twice gets two files rather than a
  /// surprise overwrite.
  static String deduplicate(String name, bool Function(String) taken) {
    if (!taken(name)) return name;
    final base = stem(name);
    final ext = extension(name);
    for (var n = 1; n < 10000; n++) {
      final candidate = '$base ($n)$ext';
      if (!taken(candidate)) return candidate;
    }
    return '$base (${DateTime.now().millisecondsSinceEpoch})$ext';
  }

  /// Human-readable byte count. Binary units, one decimal above KB, because a
  /// 1.4 GB download that reads as "1503238553 bytes" tells the user nothing.
  static String formatBytes(int? bytes) {
    if (bytes == null) return '—';
    if (bytes < 1024) return '$bytes B';
    const units = ['KB', 'MB', 'GB', 'TB', 'PB'];
    var value = bytes / 1024;
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    final digits = value >= 100 ? 0 : 1;
    return '${value.toStringAsFixed(digits)} ${units[unit]}';
  }
}
