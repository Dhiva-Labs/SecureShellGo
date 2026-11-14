import 'dart:convert';

/// Decides which remote paths the AI Bridge refuses to read, list or name.
///
/// Patterns are a deliberately small glob: `*` matches any run of characters
/// inside one path segment (never a `/`), `**` as a whole segment matches any
/// number of segments, zero included, and every other character is literal.
/// Matching is case-sensitive, because POSIX file names are: `/etc/Shadow` is
/// a different file from `/etc/shadow`, and folding case would only ever
/// block the wrong thing.
///
/// A path is blocked when it, *or any directory above it*, matches a
/// pattern. That one rule is what makes listing `/home/u/.ssh` as off-limits
/// as reading `/home/u/.ssh/id_ed25519`, and means a user who adds
/// `/srv/secrets` gets the folder and everything in it rather than just the
/// folder entry. The cost is that a directory whose name happens to match a
/// file pattern (a folder called `backup.key`) is closed with its contents;
/// erring that way is the right way round here.
///
/// The guard is the last check, not the only one: callers resolve a path on
/// the server first (symlinks included) and hand the result here, so a link
/// named `notes.txt` that points into `~/.ssh` is judged by where it points.
class BridgePathGuard {
  BridgePathGuard({
    required this.readSensitivePaths,
    Iterable<String> extraPatterns = const [],
  }) : _builtIn = [
         for (final p in builtInPatterns) _Pattern.parse(normalizePattern(p))!,
       ],
       _extra = [
         for (final raw in extraPatterns)
           ?_Pattern.parse(normalizePattern(raw)),
       ];

  /// True when the user chose "Read sensitive paths": the built-in list is
  /// set aside. Their own extra patterns still apply, since they are the
  /// user saying "never this one" in so many words.
  final bool readSensitivePaths;

  final List<_Pattern> _builtIn;
  final List<_Pattern> _extra;

  /// The longest path accepted, in UTF-8 bytes. Linux will not open a path
  /// longer than `PATH_MAX` (4096) anyway, so anything past it is either an
  /// attempt to make matching expensive or a mistake; neither should be read.
  static const int maxPathBytes = 4096;

  /// Paths no assistant reads unless the user opts out of this list. Keys,
  /// credentials and password databases, plus the few system files that hold
  /// password hashes or other users' secrets.
  static const List<String> builtInPatterns = [
    '**/.ssh/**',
    '**/.gnupg/**',
    '**/.env',
    '**/.env.*',
    '/etc/shadow',
    '/etc/shadow-',
    '/etc/gshadow',
    '/etc/gshadow-',
    '/etc/master.passwd',
    '/etc/sudoers',
    '/etc/sudoers.d/**',
    '/etc/ssh/ssh_host_*_key',
    '**/id_rsa*',
    '**/id_ed25519*',
    '**/id_ecdsa*',
    '**/id_dsa*',
    '**/*.pem',
    '**/*.key',
    '**/*.p12',
    '**/*.pfx',
    '**/*.kdbx',
    '**/.aws/credentials',
    '**/.kube/config',
    '**/.netrc',
    '**/.pgpass',
    '**/.docker/config.json',
    '**/.git-credentials',
    '**/.vault-token',
    '/proc/*/environ',
    '/proc/*/task/*/environ',
    '/proc/*/mem',
    '/proc/kcore',
    // Shell and client histories: a password typed on a command line, or
    // into a database prompt, lives on in these.
    '**/.bash_history',
    '**/.zsh_history',
    '**/.sh_history',
    '**/.python_history',
    '**/.mysql_history',
    '**/.psql_history',
    '**/.rediscli_history',
    // Package registry and cloud CLI tokens.
    '**/.npmrc',
    '**/.pypirc',
    '**/.config/gh/**',
    '**/.config/gcloud/**',
    '**/.azure/**',
    '/etc/security/opasswd',
    '**/*.ppk',
    // Remote URLs here can carry a token (`https://user:token@host/...`).
    '**/.git/config',
    '**/.htpasswd',
    '**/.my.cnf',
  ];

  /// Whether [path] is off-limits.
  ///
  /// Anything that is not a usable absolute POSIX path is blocked rather than
  /// guessed at: a relative path, an empty one, one with a NUL in it (SFTP
  /// paths are C strings, so the server would read a different, shorter
  /// path from the one checked here), or one longer than [maxPathBytes].
  bool isBlocked(String path) {
    final segments = canonicalSegments(path);
    if (segments == null) return true;
    if (_extra.any((p) => p.matchesPathOrAncestor(segments))) return true;
    if (readSensitivePaths) return false;
    return _builtIn.any((p) => p.matchesPathOrAncestor(segments));
  }

  /// [path]'s segments after collapsing `.`, `..` and repeated or trailing
  /// separators, or null when [isBlocked] would refuse it outright. `..` at
  /// the top stays at `/`, as on the server.
  static List<String>? canonicalSegments(String path) {
    if (path.isEmpty || !path.startsWith('/')) return null;
    if (path.contains('\u0000')) return null;
    if (utf8.encode(path).length > maxPathBytes) return null;
    final segments = <String>[];
    for (final part in path.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (segments.isNotEmpty) segments.removeLast();
        continue;
      }
      segments.add(part);
    }
    return segments;
  }

  /// The form a pattern is matched in. One that is not absolute (`*.sql`,
  /// `secrets/**`, the built-in `**/.env`) applies anywhere, as if it began
  /// with `/**/`. A user's `~/` means the same, because the guard does not
  /// know whose home directory a server path is in, and the broader reading
  /// is the safe one. Blank input gives an empty string, which matches
  /// nothing.
  static String normalizePattern(String raw) {
    var pattern = raw.trim();
    if (pattern.isEmpty) return '';
    if (pattern.startsWith('~/')) pattern = pattern.substring(2);
    if (!pattern.startsWith('/')) pattern = '/**/$pattern';
    return pattern;
  }
}

/// One parsed pattern: its segments, each `**` or a single-segment glob.
class _Pattern {
  _Pattern(this.segments);

  final List<String> segments;

  /// Null for a pattern that matches nothing: empty, or not absolute after
  /// [BridgePathGuard.normalizePattern].
  static _Pattern? parse(String pattern) {
    if (pattern.isEmpty || !pattern.startsWith('/')) return null;
    final segments = <String>[];
    for (final part in pattern.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (segments.isNotEmpty) segments.removeLast();
        continue;
      }
      // `**/**` is the same as `**`; folding them keeps matching linear.
      if (part == '**' && segments.isNotEmpty && segments.last == '**') {
        continue;
      }
      segments.add(part);
    }
    // A pattern of `/` alone would block everything by accident.
    if (segments.isEmpty) return null;
    return _Pattern(segments);
  }

  /// Whether this pattern matches [path] or any leading part of it, i.e. the
  /// path itself or one of the directories above it.
  ///
  /// A table over (pattern position, path position) rather than recursion:
  /// a `**` can otherwise retry every split of a long path, and the path
  /// comes from a server that need not be friendly. O(path × pattern).
  bool matchesPathOrAncestor(List<String> path) {
    final m = segments.length;
    // reach[j]: the first j pattern segments can match the path so far.
    var reach = List<bool>.filled(m + 1, false);
    reach[0] = true;
    for (var j = 0; j < m && segments[j] == '**'; j++) {
      reach[j + 1] = true;
    }
    if (reach[m]) return true;
    for (final segment in path) {
      final next = List<bool>.filled(m + 1, false);
      for (var j = 1; j <= m; j++) {
        final pattern = segments[j - 1];
        if (pattern == '**') {
          // Takes this segment as one more of its own, or the previous
          // pattern step just took it and `**` takes none.
          next[j] = reach[j] || reach[j - 1] || next[j - 1];
        } else {
          next[j] = reach[j - 1] && _globSegment(pattern, segment);
        }
      }
      reach = next;
      if (reach[m]) return true;
    }
    return false;
  }

  /// `*` within one segment. The usual greedy-with-one-backtrack walk:
  /// linear in practice and never exponential however many stars.
  static bool _globSegment(String pattern, String text) {
    if (!pattern.contains('*')) return pattern == text;
    var p = 0, t = 0, star = -1, mark = 0;
    while (t < text.length) {
      if (p < pattern.length && pattern[p] != '*' && pattern[p] == text[t]) {
        p++;
        t++;
      } else if (p < pattern.length && pattern[p] == '*') {
        star = p++;
        mark = t;
      } else if (star >= 0) {
        p = star + 1;
        t = ++mark;
      } else {
        return false;
      }
    }
    while (p < pattern.length && pattern[p] == '*') {
      p++;
    }
    return p == pattern.length;
  }
}
