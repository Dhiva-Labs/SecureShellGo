import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../models/app_settings.dart';
import 'app_data_paths.dart';
import 'atomic_file.dart';
import 'secure_storage_backend.dart';
import 'settings_store.dart';

/// Takes passwords, private keys and tokens out of text before it is written
/// anywhere.
///
/// Two kinds of knowledge, used in this order:
///
///  1. **What it has been told.** Every value the credential store reads or
///     writes is handed to [learn] (see [DiagnosticsLog.watchCredentialStorage]),
///     so a saved password is removed wherever it turns up, in whatever shape
///     an error message happens to print it — even one no pattern below would
///     recognise. Held in memory only, for the life of the process.
///  2. **What secrets look like.** PEM and PuTTY private keys (whole or cut
///     off), credentials in URLs, `Authorization` headers, the well-known
///     token formats, `password=`/`"passphrase": "…"`-style pairs, the
///     command-line flags that carry a password (`sshpass -p`, `mysql -p…`,
///     `ssh-keygen -P/-N`, `curl -u`, `echo … | sudo -S`), and long
///     random-looking runs of base64 or hex.
///
/// It errs towards removing too much. A log that has lost a port number is
/// still a useful bug report; one that carries a server password is a leak.
class SecretScrubber {
  static const String redacted = '[redacted]';
  static const String keyRedacted = '[private key redacted]';

  /// Shorter learned secrets are not matched literally: replacing every `ab`
  /// in the log would destroy it and protect little. The patterns still apply
  /// to them.
  static const int minKnownSecretLength = 4;

  /// A multi-line secret (a private key) is also learned line by line, so a
  /// fragment of it is caught. Lines shorter than this — `-----END …` aside,
  /// mostly the short last line of the base64 body — are left to the
  /// patterns.
  static const int minSecretLineLength = 16;

  final Set<String> _known = <String>{};
  RegExp? _knownPattern;
  bool _knownDirty = false;

  /// How many distinct strings are being matched literally. For tests.
  int get knownCount => _known.length;

  /// Remembers [secret], in memory only, so [scrub] removes it wherever it
  /// appears: as written, JSON-escaped, URL-encoded, and each long line of a
  /// multi-line secret on its own.
  void learn(String? secret) {
    if (secret == null) return;
    final variants = <String>{
      secret,
      _jsonEscaped(secret),
      Uri.encodeComponent(secret),
      if (secret.contains('\n')) ...[
        secret.replaceAll('\r\n', '\n'),
        for (final line in secret.split(RegExp(r'\r?\n')))
          if (line.trim().length >= minSecretLineLength) line.trim(),
      ],
    };
    for (final variant in variants) {
      if (variant.length < minKnownSecretLength) continue;
      if (_known.add(variant)) _knownDirty = true;
    }
  }

  /// Forgets everything [learn] was told.
  void forgetAll() {
    _known.clear();
    _knownPattern = null;
    _knownDirty = false;
  }

  static String _jsonEscaped(String value) {
    final quoted = jsonEncode(value);
    return quoted.substring(1, quoted.length - 1);
  }

  /// [input] with every secret this can find replaced.
  String scrub(String input) {
    var text = input;
    final known = _knownRegExp();
    if (known != null) text = text.replaceAll(known, redacted);
    for (final rule in _rules) {
      text = rule.apply(text);
    }
    return text;
  }

  RegExp? _knownRegExp() {
    if (_knownDirty) {
      _knownDirty = false;
      // Longest first, so a password that happens to be part of a key does
      // not leave the rest of the key behind.
      final sorted = _known.toList()
        ..sort((a, b) => b.length.compareTo(a.length));
      _knownPattern = sorted.isEmpty
          ? null
          : RegExp(sorted.map(RegExp.escape).join('|'));
    }
    return _knownPattern;
  }

  // ---- the patterns -------------------------------------------------------

  /// A quoted value (kept quoted, contents removed) or a bare word.
  static const String _value = r'''("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|(?!\[redacted\])[^\s"']\S*)''';

  /// Names that mark the value after them as secret. The first group may
  /// carry any prefix (`userPassword`, `db_secret`, `aws_secret_access_key`);
  /// the short ones only a separated one (`db_pass`, not `bypass`).
  static const String _secretName =
      r'(?:[A-Za-z0-9_.-]*?(?:password|passwd|passphrase|secret|token|'
      r'api[_-]?key|access[_-]?key|private[_-]?key(?:[_-]?pem)?|'
      r'auth[_-]?token|credentials?)|'
      r'(?:[A-Za-z0-9]+[_.-])*(?:pass|pwd|cookie|sig|signature))';

  static final List<_ScrubRule> _rules = <_ScrubRule>[
    // PEM private keys — OpenSSH, PKCS#1, PKCS#8, encrypted, EC, DSA, SSH2,
    // PGP — through to their END line, or to the end of the text when the
    // message was cut off before it.
    _ScrubRule(
      RegExp(
        r'-{2,}\s*BEGIN [A-Z0-9 ]*PRIVATE KEY[A-Z ]*-*[\s\S]*?'
        r'(?:-{2,}\s*END [A-Z0-9 ]*PRIVATE KEY[A-Z ]*-*|$)',
        caseSensitive: false,
      ),
      (_) => keyRedacted,
    ),
    // The same header with its dashes lost to formatting.
    _ScrubRule(
      RegExp(
        r'\bBEGIN [A-Z0-9 ]*PRIVATE KEY\b[\s\S]*?'
        r'(?:\bEND [A-Z0-9 ]*PRIVATE KEY\b-*|$)',
        caseSensitive: false,
      ),
      (_) => keyRedacted,
    ),
    // PuTTY .ppk files, versions 1 to 3.
    _ScrubRule(
      RegExp(
        r'PuTTY-User-Key-File-\d+\s*:[\s\S]*?'
        r'(?:Private-(?:MAC|Hash)\s*:\s*[0-9a-fA-F]+|$)',
        caseSensitive: false,
      ),
      (_) => keyRedacted,
    ),
    // An OpenSSH key body without its header: "openssh-key-v1" in base64,
    // across real or escaped line breaks.
    _ScrubRule(
      RegExp(r'b3BlbnNzaC1rZXktdjE(?:[A-Za-z0-9+/=]|\\[rn]|\r?\n)*'),
      (_) => keyRedacted,
    ),
    // scheme://user:password@host
    _ScrubRule(
      RegExp(
        r'\b([a-z][a-z0-9+.-]*://)([^\s/:@]*):([^\s/@]+)@',
        caseSensitive: false,
      ),
      (m) => '${m[1]}${m[2]}:$redacted@',
    ),
    // Authorization: Bearer …, and a bare "Bearer …" anywhere.
    _ScrubRule(
      RegExp(
        r'\b((?:proxy-)?authorization\s*[:=]\s*)'
        r'(?:(bearer|basic|digest|token|negotiate)\s+)?'
        r'''("[^"]*"|'[^']*'|[^\s,;]+)''',
        caseSensitive: false,
      ),
      (m) => '${m[1]}${m[2] == null ? '' : '${m[2]} '}$redacted',
    ),
    _ScrubRule(
      RegExp(r'\b(bearer\s+)[A-Za-z0-9._~+/=-]{8,}', caseSensitive: false),
      (m) => '${m[1]}$redacted',
    ),
    // Well-known token formats: JWTs, GitHub, GitLab, Slack, AWS key ids,
    // Google API keys, Stripe-style keys, OpenAI/Anthropic-style keys, npm,
    // Hugging Face, DigitalOcean.
    _ScrubRule(
      RegExp(
        r'\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]*'
        r'|\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})'
        r'|\bglpat-[A-Za-z0-9_-]{20,}'
        r'|\bxox[abposr]-[A-Za-z0-9-]{10,}'
        r'|\b(?:AKIA|ASIA|AGPA|AIDA|AROA)[A-Z0-9]{16}\b'
        r'|\bAIza[0-9A-Za-z_-]{35,}'
        r'|\b(?:sk|rk|pk)_(?:live|test)_[A-Za-z0-9]{10,}'
        r'|\bsk-(?:ant-|proj-)?[A-Za-z0-9_-]{32,}'
        r'|\bnpm_[A-Za-z0-9]{30,}'
        r'|\bhf_[A-Za-z0-9]{30,}'
        r'|\bdop_v1_[a-f0-9]{64}',
      ),
      (_) => redacted,
    ),
    // Command lines that carry a password as an argument.
    _ScrubRule(
      RegExp(r'(\bsshpass\b(?:\s+\S+)*?\s+-p\s*)' '$_value'),
      (m) => '${m[1]}$redacted',
    ),
    _ScrubRule(
      // `-pSECRET`, attached; `-p` on its own makes mysql prompt instead.
      RegExp(
        r'(\bmysql(?:dump|admin|import|check|show)?\b(?:\s+\S+)*?\s+-p)'
        r'''("[^"]*"|'[^']*'|(?!\[redacted\])[^\s"']\S*)''',
      ),
      (m) => '${m[1]}$redacted',
    ),
    _ScrubRule(
      RegExp(r'(\bssh-keygen\b(?:\s+\S+)*?\s+-[PN]\s*)' '$_value'),
      (m) => '${m[1]}$redacted',
      repeat: true,
    ),
    _ScrubRule(
      RegExp(r'(\bcurl\b(?:\s+\S+)*?\s+(?:-u|--user)\s*)([^\s:]+):(\S+)'),
      (m) => '${m[1]}${m[2]}:$redacted',
    ),
    _ScrubRule(
      RegExp(r'(\becho\s+(?:-[neE]+\s+)?)' '$_value' r'(\s*\|\s*sudo\b)'),
      (m) => '${m[1]}$redacted${m[3]}',
    ),
    _ScrubRule(
      RegExp(
        r'(--?(?:password|passwd|passphrase|pass|token|secret|api-?key|'
        r'auth-token)\s+)(?!-)'
        '$_value',
        caseSensitive: false,
      ),
      (m) => '${m[1]}$redacted',
    ),
    // name: value with a bare value, which may run on with spaces — a Dart
    // map's `{password: two words, …}` or a YAML line — so it is taken to
    // the next delimiter. Before the general rule below, which would stop
    // at the first space.
    _ScrubRule(
      RegExp(
        '(?<![A-Za-z0-9])($_secretName)'
        r'''\b(\s*:\s*)(?!\[redacted\])(?!["'\\])([^\s,;)}\]][^,;)}\]\r\n]*)''',
        caseSensitive: false,
      ),
      (m) => '${m[1]}${m[2]}$redacted',
    ),
    // name=value, "name": "value", name => 'value', and JSON escaped inside
    // a string (\"password\":\"…\"). A bare value stops at `&` only where a
    // query string's next `name=` starts, so `Tr0ub4dor&3` goes whole.
    _ScrubRule(
      RegExp(
        '(?<![A-Za-z0-9])($_secretName)'
        r'''\b(\\?["']?)(\s*(?:=>|=|:)\s*)'''
        r'''(?:"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)'|(?!\[redacted\])((?:[^\s,;&)}\]]|&(?![A-Za-z0-9_.-]+=))+))''',
        caseSensitive: false,
      ),
      (m) {
        final head = '${m[1]}${m[2]}${m[3]}';
        if (m[4] != null) return '$head"$redacted"';
        if (m[5] != null) return "$head'$redacted'";
        return '$head$redacted';
      },
    ),
    // Long random-looking runs: base64 or base64url with upper case, lower
    // case and digits all present. Fingerprints and public keys are public,
    // and the first thing a host-key bug report needs, so they stay.
    _ScrubRule(
      RegExp(r'(?<![A-Za-z0-9+/_-])[A-Za-z0-9+/_-]{32,}={0,2}(?![A-Za-z0-9+/=_-])'),
      (m) {
        final run = m[0]!;
        if (!_looksRandom(run) || _looksLikePath(run)) return run;
        final before = m.input.substring(
          m.start < 40 ? 0 : m.start - 40,
          m.start,
        );
        if (_publicPrefix.hasMatch(before)) return run;
        return redacted;
      },
    ),
    // Long hex: raw keys, HMACs, session ids.
    _ScrubRule(
      RegExp(r'(?<![0-9A-Za-z])[0-9a-fA-F]{32,}(?![0-9A-Za-z])'),
      (m) {
        final run = m[0]!;
        final hasDigit = run.contains(RegExp('[0-9]'));
        final hasLetter = run.contains(RegExp('[a-fA-F]'));
        return hasDigit && hasLetter ? redacted : run;
      },
    ),
  ];

  /// What may stand right before a long base64 run that is public.
  static final RegExp _publicPrefix = RegExp(
    r'(?:SHA256:|SHA1:|MD5:|ssh-(?:rsa|dss|ed25519|ed448) |'
    r'ecdsa-sha2-[a-z0-9]+ |sk-(?:ssh-ed25519|ecdsa-sha2-[a-z0-9]+)@openssh\.com )$',
  );

  /// A run with slashes that is really a path: base64 has a slash about
  /// once in 64 characters and never mixes it with `-` or `_` (those are
  /// the URL-safe alphabet's), so many slashes, or slashes beside either,
  /// mean folders rather than key material.
  static bool _looksLikePath(String run) {
    final slashes = '/'.allMatches(run).length;
    if (slashes == 0) return false;
    if (run.contains('-') || run.contains('_')) return true;
    return slashes * 10 > run.length;
  }

  static bool _looksRandom(String run) {
    var upper = 0, lower = 0, digits = 0;
    for (final unit in run.codeUnits) {
      if (unit >= 0x41 && unit <= 0x5a) {
        upper++;
      } else if (unit >= 0x61 && unit <= 0x7a) {
        lower++;
      } else if (unit >= 0x30 && unit <= 0x39) {
        digits++;
      }
    }
    return upper >= 2 && lower >= 2 && digits >= 2;
  }
}

class _ScrubRule {
  const _ScrubRule(this.pattern, this.replace, {this.repeat = false});

  final RegExp pattern;
  final String Function(Match match) replace;

  /// Apply again until nothing changes — for a command line that carries
  /// more than one secret flag (`ssh-keygen -P old -N new`).
  final bool repeat;

  String apply(String text) {
    var current = text.replaceAllMapped(pattern, replace);
    if (!repeat) return current;
    for (var i = 0; i < 8; i++) {
      final next = current.replaceAllMapped(pattern, replace);
      if (next == current) break;
      current = next;
    }
    return current;
  }
}

/// A record of errors and crashes, kept on this device for a bug report.
///
/// What it promises, and how:
///
///  * **Only while the setting is on.** Nothing reaches the disk until the
///    saved settings say [AppSettings.diagnosticsLog] is on: errors from
///    before settings have loaded wait in memory and are dropped if it turns
///    out to be off. Turning it off deletes what was there.
///  * **No secrets.** Every entry goes through a [SecretScrubber] before it
///    is written, and the whole log goes through it again when it is read
///    back, so a password learned after an error was written is still taken
///    out of the copy.
///  * **Small.** Two files at most, [maxFileBytes] each. When the current one
///    is full it becomes the previous one, and the oldest goes. One entry is
///    capped at [maxEntryChars], a stack at [maxStackLines] lines, and an
///    error that repeats back to back is written once, with a count.
///  * **Never sent anywhere.** There is no network code here. The user copies
///    it out by hand from Settings.
///
/// Each file starts with the app version, platform and OS, so a log pasted
/// on its own still says what produced it.
///
/// The one process-wide instance is [instance]: the error hooks are global
/// by nature (`FlutterError.onError` has one slot), and Settings reaches the
/// log without the composition root threading it through every screen in
/// between, the same trade `BookmarkStore.instance` makes.
class DiagnosticsLog {
  /// [directory] overrides where the files live; tests use a temp folder so
  /// they need no path_provider plugin.
  DiagnosticsLog({
    Future<Directory> Function()? directory,
    this.maxFileBytes = defaultMaxFileBytes,
    DateTime Function()? clock,
    String Function()? describePlatform,
    SecretScrubber? scrubber,
  })  : _directory = directory ?? AppDataPaths.resolveDirectory,
        _now = clock ?? DateTime.now,
        _describePlatform = describePlatform ?? _platformLines,
        scrubber = scrubber ?? SecretScrubber();

  static final DiagnosticsLog instance = DiagnosticsLog();

  /// This build's version, as `pubspec.yaml` has it. The app has no plugin
  /// that reads the version at run time, so it is written down here, and
  /// `diagnostics_log_test.dart` fails the build when the two drift apart.
  static const String appVersion = '1.4.5+12';

  static const String fileName = 'diagnostics.log';
  static const String previousFileName = 'diagnostics.1.log';
  static const int defaultMaxFileBytes = 128 * 1024;
  static const int maxEntryChars = 16 * 1024;
  static const int maxStackLines = 60;

  /// Errors kept in memory while the setting is still unknown.
  static const int maxPendingEntries = 20;

  final Future<Directory> Function() _directory;
  final DateTime Function() _now;
  final String Function() _describePlatform;
  final SecretScrubber scrubber;
  final int maxFileBytes;

  final SerialFileWriter _writer = SerialFileWriter();

  /// Null until the saved settings are known.
  bool? _enabled;
  final List<_PendingEntry> _pending = <_PendingEntry>[];

  String? _lastSignature;
  int _repeats = 0;

  /// Whether entries are being written. False while the setting is unknown.
  bool get isEnabled => _enabled ?? false;

  /// Follows the saved setting. Wired to the settings store in `main.dart`.
  void applySettings(AppSettings settings) =>
      unawaited(setEnabled(settings.diagnosticsLog));

  /// Applies [store]'s setting once it has loaded and on every change after.
  /// Until the first load lands, errors wait in memory — see [record].
  StreamSubscription<AppSettings> follow(SettingsStore store) {
    unawaited(store.ensureLoaded().then((_) => applySettings(store.current)));
    return store.changes.listen(applySettings);
  }

  Future<void> setEnabled(bool enabled) async {
    final was = _enabled;
    _enabled = enabled;
    if (enabled) {
      if (was == true) return;
      final waiting = List<_PendingEntry>.of(_pending);
      _pending.clear();
      for (final entry in waiting) {
        await _append(entry.text, entry.signature);
      }
      return;
    }
    _pending.clear();
    if (was != false) await clear();
  }

  /// Remembers a secret so it never reaches the log. Memory only.
  void learnSecret(String? secret) => scrubber.learn(secret);

  /// Wraps the credential store's backend so every secret it reads or writes
  /// is learned by [scrubber] on the way past. Nothing is stored and nothing
  /// is changed: values go through untouched.
  SecureStorageBackend watchCredentialStorage(SecureStorageBackend inner) =>
      _CredentialTap(inner, this);

  /// Learns each string inside a credential-store entry (a small JSON
  /// object of password, key and passphrase), or the entry itself when it
  /// is not JSON.
  void _learnStoredEntry(String? raw) {
    if (raw == null) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        for (final value in decoded.values) {
          if (value is String) scrubber.learn(value);
        }
        return;
      }
    } catch (_) {
      // Not JSON; learn it whole.
    }
    scrubber.learn(raw);
  }

  /// Writes one error. Never throws: it runs inside the error handlers.
  Future<void> record(
    Object error,
    StackTrace? stack, {
    String source = 'Error',
    String? context,
  }) async {
    try {
      if (_enabled == false) return;
      final text = _formatEntry(error, stack, source: source, context: context);
      final signature = '$source\u0000$error\u0000${_firstLine(stack)}';
      if (_enabled == null) {
        if (_pending.length < maxPendingEntries) {
          _pending.add(_PendingEntry(text, signature));
        }
        return;
      }
      await _append(text, signature);
    } catch (_) {
      // A log that cannot be written must not become a second error.
    }
  }

  Future<void> _append(String text, String signature) async {
    if (signature == _lastSignature) {
      _repeats++;
      return;
    }
    final note = _repeatNote();
    _lastSignature = signature;
    try {
      await _writer.run(() => _writeNow('$note$text'));
    } catch (_) {
      // Best effort; see [record].
    }
  }

  String _repeatNote() {
    if (_repeats == 0) return '';
    final note = '(The entry above happened $_repeats more '
        'time${_repeats == 1 ? '' : 's'}.)\n\n';
    _repeats = 0;
    return note;
  }

  Future<void> _writeNow(String raw) async {
    final dir = await _directory();
    final current = File('${dir.path}/$fileName');
    final header = utf8.encode(_header());
    final room = maxFileBytes - header.length;
    if (room <= 0) return;

    var text = scrubber.scrub(_withoutHome(raw));
    if (text.length > maxEntryChars) {
      text = '${text.substring(0, maxEntryChars)}\n(Entry cut short.)\n\n';
    }
    final bytes = _utf8Within(text, room);

    var length = await current.exists() ? await current.length() : 0;
    if (length > 0 && length + bytes.length > maxFileBytes) {
      await _rotate(dir, current);
      length = 0;
    }
    final out = BytesBuilder(copy: false);
    if (length == 0) out.add(header);
    out.add(bytes);
    await dir.create(recursive: true);
    await current.writeAsBytes(
      out.takeBytes(),
      mode: FileMode.append,
      flush: true,
    );
  }

  Future<void> _rotate(Directory dir, File current) async {
    final previous = File('${dir.path}/$previousFileName');
    try {
      if (await previous.exists()) await previous.delete();
      await current.rename(previous.path);
    } catch (_) {
      // If the rename cannot happen, losing the older half beats growing
      // without bound.
      try {
        await current.delete();
      } catch (_) {}
    }
  }

  /// [text] as UTF-8, cut to at most [maxBytes] on a character boundary.
  static List<int> _utf8Within(String text, int maxBytes) {
    var bytes = utf8.encode(text);
    if (bytes.length <= maxBytes) return bytes;
    const marker = '\n(Entry cut short.)\n\n';
    final budget = maxBytes - utf8.encode(marker).length;
    if (budget <= 0) return utf8.encode(marker).take(maxBytes).toList();
    var cut = text.length < budget ? text.length : budget;
    while (cut > 0) {
      bytes = utf8.encode('${text.substring(0, cut)}$marker');
      if (bytes.length <= maxBytes) return bytes;
      cut = (cut * 0.9).floor();
    }
    return utf8.encode(marker);
  }

  String _formatEntry(
    Object error,
    StackTrace? stack, {
    required String source,
    String? context,
  }) {
    final buffer = StringBuffer()
      ..writeln('=== ${_now().toUtc().toIso8601String()}  $source');
    if (context != null && context.trim().isNotEmpty) {
      buffer.writeln(context.trim());
    }
    buffer.writeln(_describe(error));
    if (stack != null) {
      final lines = stack
          .toString()
          .split('\n')
          .where((line) => line.trim().isNotEmpty)
          .toList();
      for (final line in lines.take(maxStackLines)) {
        buffer.writeln(line);
      }
      if (lines.length > maxStackLines) {
        buffer.writeln('(${lines.length - maxStackLines} more frames)');
      }
    }
    buffer.writeln();
    return buffer.toString();
  }

  static String _describe(Object error) {
    try {
      return '${error.runtimeType}: $error';
    } catch (_) {
      return '${error.runtimeType} (could not be described)';
    }
  }

  static String _firstLine(StackTrace? stack) {
    if (stack == null) return '';
    final text = stack.toString();
    final end = text.indexOf('\n');
    return end < 0 ? text : text.substring(0, end);
  }

  /// The user's home folder as `~`, so a pasted log does not carry their
  /// account name in every path.
  static String _withoutHome(String text) {
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home == null || home.length < 5) return text;
    return text.replaceAll(home, '~');
  }

  String _header() {
    final rule = '-' * 60;
    return 'SecureShell Go diagnostics log\n'
        'App version: $appVersion (${_buildMode()} build)\n'
        '${_describePlatform()}\n'
        'Started: ${_now().toUtc().toIso8601String()}\n'
        'Kept on this device only. Passwords, keys and tokens are removed '
        'before anything is written.\n'
        '$rule\n\n';
  }

  static String _buildMode() {
    if (kReleaseMode) return 'release';
    if (kProfileMode) return 'profile';
    return 'debug';
  }

  static String _platformLines() {
    final dart = Platform.version.split(' ').first;
    return 'Platform: ${Platform.operatingSystem}\n'
        'Operating system: ${Platform.operatingSystemVersion}\n'
        'Dart: $dart';
  }

  /// Everything kept, oldest first, scrubbed again with what is known now.
  /// Empty when there is nothing.
  Future<String> read() async {
    final note = _repeatNote();
    if (note.isNotEmpty && isEnabled) {
      try {
        await _writer.run(() => _writeNow(note));
      } catch (_) {}
    }
    var text = '';
    await _writer.run(() async {
      final dir = await _directory();
      final parts = <String>[];
      for (final name in [previousFileName, fileName]) {
        final file = File('${dir.path}/$name');
        if (await file.exists()) {
          parts.add(
            utf8.decode(await file.readAsBytes(), allowMalformed: true),
          );
        }
      }
      text = parts.join('\n');
    });
    return text.isEmpty ? text : scrubber.scrub(text);
  }

  /// Total size of what is kept, in bytes.
  Future<int> sizeInBytes() async {
    var total = 0;
    await _writer.run(() async {
      final dir = await _directory();
      for (final name in [previousFileName, fileName]) {
        final file = File('${dir.path}/$name');
        if (await file.exists()) total += await file.length();
      }
    });
    return total;
  }

  /// Deletes everything kept.
  Future<void> clear() async {
    _lastSignature = null;
    _repeats = 0;
    try {
      await _writer.run(() async {
        final dir = await _directory();
        for (final name in [previousFileName, fileName]) {
          final file = File('${dir.path}/$name');
          if (await file.exists()) await file.delete();
        }
      });
    } catch (_) {
      // Nothing more to try.
    }
  }

  /// Routes framework errors and uncaught errors here, keeping whatever
  /// handled them before — the console still shows them.
  void installErrorHooks() {
    final previousFlutter = FlutterError.onError;
    FlutterError.onError = (details) {
      unawaited(
        record(
          details.exception,
          details.stack,
          source: 'Flutter error'
              '${details.library == null ? '' : ' (${details.library})'}',
          context: _describeContext(details),
        ),
      );
      if (previousFlutter != null) {
        previousFlutter(details);
      } else {
        FlutterError.presentError(details);
      }
    };
    final dispatcher = PlatformDispatcher.instance;
    final previousPlatform = dispatcher.onError;
    dispatcher.onError = (error, stack) {
      unawaited(record(error, stack, source: 'Uncaught error'));
      return previousPlatform?.call(error, stack) ?? false;
    };
  }

  /// Runs [body] — the app's `main` — with its hooks installed and in a zone
  /// whose uncaught asynchronous errors are recorded too.
  void runGuarded(void Function() body) {
    runZonedGuarded(
      () {
        installErrorHooks();
        body();
      },
      (error, stack) {
        unawaited(record(error, stack, source: 'Uncaught async error'));
        // Still on the console, as they would be without this zone.
        FlutterError.dumpErrorToConsole(
          FlutterErrorDetails(exception: error, stack: stack, library: 'zone'),
        );
      },
    );
  }

  static String? _describeContext(FlutterErrorDetails details) {
    try {
      final context = details.context;
      return context == null ? null : '$context';
    } catch (_) {
      return null;
    }
  }
}

class _PendingEntry {
  const _PendingEntry(this.text, this.signature);

  final String text;
  final String signature;
}

/// See [DiagnosticsLog.watchCredentialStorage].
class _CredentialTap implements SecureStorageBackend {
  _CredentialTap(this._inner, this._log);

  final SecureStorageBackend _inner;
  final DiagnosticsLog _log;

  @override
  Future<String?> read(String key) async {
    final value = await _inner.read(key);
    _log._learnStoredEntry(value);
    return value;
  }

  @override
  Future<void> write(String key, String value) {
    _log._learnStoredEntry(value);
    return _inner.write(key, value);
  }

  @override
  Future<void> delete(String key) => _inner.delete(key);
}
