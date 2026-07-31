/// Parses the subset of the OpenSSH client config grammar (`ssh_config(5)`)
/// this app can usefully import: `Host` blocks, `HostName`, `User`, `Port`,
/// `IdentityFile`, `ProxyJump`, and one level of `Include`. Everything else
/// (`ServerAliveInterval`, `Compression`, `Match` blocks, ...) is silently
/// ignored — this is an importer, not a reimplementation of ssh_config(5).
///
/// Pure Dart, no `dart:io`: [SshConfigParser.parse] takes the config text as
/// a plain string and, for `Include`, calls back through [readInclude] for
/// the contents of the named file rather than touching disk itself. The
/// real caller (`ssh_config_import_screen.dart`) wires that callback to the
/// filesystem, expanding `~` and resolving relative paths against
/// `~/.ssh/`; tests hand it a fake map so the parser never needs a real
/// file on disk.
library;

/// One concrete (non-wildcard) `Host` block.
class SshConfigHostEntry {
  const SshConfigHostEntry({
    required this.alias,
    required this.hostname,
    this.user,
    this.port = 22,
    this.identityFile,
    this.proxyJump,
  });

  /// The literal pattern after `Host` — a wildcard pattern (containing `*`
  /// or `?`) never reaches here; see [SshConfigParser.parse].
  final String alias;

  final String hostname;
  final String? user;
  final int port;

  /// Raw path text from `IdentityFile`. Never read — the file's *contents*
  /// are not imported, only its presence, so the import preview can show a
  /// "uses key file" badge and leave the actual key for the user to add.
  final String? identityFile;

  /// Raw `ProxyJump` target, e.g. `bastion` or `user@bastion:22`.
  ///
  /// Deliberately kept here rather than folded into a `Host` — wiring it to
  /// the app's jump-host feature is separate work, and `Host`
  /// (`models/host.dart`) has no field for it. Callers that want to surface
  /// this read it straight off the parse result rather than off any saved
  /// host.
  final String? proxyJump;
}

class SshConfigParseResult {
  const SshConfigParseResult({required this.entries, required this.warnings});

  final List<SshConfigHostEntry> entries;

  /// Human-readable notes about anything skipped: a wildcard `Host`
  /// pattern, a missing `Include` target.
  final List<String> warnings;
}

class SshConfigParser {
  const SshConfigParser._();

  static SshConfigParseResult parse(
    String contents, {
    String? Function(String path)? readInclude,
  }) {
    return _parse(contents, readInclude: readInclude, isIncluded: false);
  }

  static SshConfigParseResult _parse(
    String contents, {
    required String? Function(String path)? readInclude,
    required bool isIncluded,
  }) {
    final entries = <SshConfigHostEntry>[];
    final warnings = <String>[];
    var drafts = <_Draft>[];

    void finalizeDrafts() {
      for (final draft in drafts) {
        entries.add(draft.toEntry());
      }
      drafts = [];
    }

    for (final rawLine in contents.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;

      // Keyword is everything up to the first run of whitespace or `=` —
      // `HostName=example.com`, `HostName example.com` and
      // `HostName = example.com` all split the same way.
      final sepIndex = line.indexOf(RegExp(r'[\s=]'));
      final keyword = sepIndex == -1 ? line : line.substring(0, sepIndex);
      var rest = sepIndex == -1 ? '' : line.substring(sepIndex).trimLeft();
      if (rest.startsWith('=')) rest = rest.substring(1).trimLeft();
      final lowerKeyword = keyword.toLowerCase();

      if (lowerKeyword == 'host') {
        finalizeDrafts();
        for (final pattern in _tokenize(rest)) {
          if (pattern.contains('*') || pattern.contains('?')) {
            warnings.add('Skipped wildcard pattern "$pattern"');
            continue;
          }
          drafts.add(_Draft(alias: pattern));
        }
        continue;
      }

      if (lowerKeyword == 'include') {
        if (isIncluded) {
          // Non-recursive: an Include found inside an included file is
          // ignored rather than followed.
          continue;
        }
        // Finalize whatever Host block is still open first, so the included
        // file's entries land after it in the result rather than before —
        // matching the order the directives actually appear in on disk.
        finalizeDrafts();
        final tokens = _tokenize(rest);
        if (tokens.isEmpty) continue;
        final path = tokens.first;
        final included = readInclude?.call(path);
        if (included == null) {
          warnings.add('Skipped missing include "$path"');
          continue;
        }
        final nested = _parse(
          included,
          readInclude: readInclude,
          isIncluded: true,
        );
        entries.addAll(nested.entries);
        warnings.addAll(nested.warnings);
        continue;
      }

      if (drafts.isEmpty) continue; // A directive before any Host block.

      final tokens = _tokenize(rest);
      final value = tokens.isEmpty ? '' : tokens.first;
      if (value.isEmpty) continue;

      switch (lowerKeyword) {
        case 'hostname':
          for (final draft in drafts) {
            draft.hostname = value;
          }
        case 'user':
          for (final draft in drafts) {
            draft.user = value;
          }
        case 'port':
          final port = int.tryParse(value);
          if (port != null && port >= 1 && port <= 65535) {
            for (final draft in drafts) {
              draft.port = port;
            }
          }
        case 'identityfile':
          for (final draft in drafts) {
            draft.identityFile = value;
          }
        case 'proxyjump':
          for (final draft in drafts) {
            draft.proxyJump = value;
          }
        default:
          break; // Unsupported directive: ignored, not an error.
      }
    }

    finalizeDrafts();
    return SshConfigParseResult(entries: entries, warnings: warnings);
  }

  /// Splits [input] on runs of spaces/tabs, treating a double-quoted span as
  /// one token — `"my host" *.example.com` yields `["my host",
  /// "*.example.com"]`.
  static List<String> _tokenize(String input) {
    final tokens = <String>[];
    final buffer = StringBuffer();
    var inQuotes = false;

    for (var i = 0; i < input.length; i++) {
      final ch = input[i];
      if (ch == '"') {
        inQuotes = !inQuotes;
        continue;
      }
      if (!inQuotes && (ch == ' ' || ch == '\t')) {
        if (buffer.isNotEmpty) {
          tokens.add(buffer.toString());
          buffer.clear();
        }
        continue;
      }
      buffer.write(ch);
    }
    if (buffer.isNotEmpty) tokens.add(buffer.toString());
    return tokens;
  }
}

/// Mutable in-progress `Host` block. One per alias on a `Host` line, so
/// `Host foo bar` (both non-wildcard) tracks `foo` and `bar` separately even
/// though they share every directive that follows until the next `Host`
/// line.
class _Draft {
  _Draft({required this.alias});

  final String alias;
  String? hostname;
  String? user;
  int port = 22;
  String? identityFile;
  String? proxyJump;

  SshConfigHostEntry toEntry() => SshConfigHostEntry(
        alias: alias,
        hostname: hostname ?? alias,
        user: user,
        port: port,
        identityFile: identityFile,
        proxyJump: proxyJump,
      );
}
