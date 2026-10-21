import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../app_version.dart' as app;
import '../models/app_settings.dart';
import 'app_data_paths.dart';
import 'atomic_file.dart';
import 'secure_storage_backend.dart';
import 'settings_store.dart';

/// Takes passwords, private keys and tokens out of text before it is written
/// anywhere.
///
/// Two kinds of knowledge:
///
///  1. **What it has been told.** Every value the credential store reads or
///     writes is handed to [learn] (see [DiagnosticsLog.watchCredentialStorage]),
///     and so is every secret typed where it is typed — a password used
///     without saving it, the answers to a server's hidden login prompts,
///     the vault and backup passphrases ([DiagnosticsLog.learnSecret]) — so
///     each is removed wherever it turns up, in whatever shape an error
///     message happens to print it, even one no pattern below would
///     recognise. Held in memory only, for the life of the process.
///  2. **What secrets look like.** PEM and PuTTY private keys (whole or cut
///     off), credentials in URLs (`scheme://user:pw@host`, and `user:pw@host`
///     without a scheme), `Authorization` headers, the well-known token
///     formats, `password=`/`"passphrase": "…"`/`pw=`/`SSHPASS=`-style pairs,
///     password prompts answered inline (`Password for root@h: …`), the
///     command-line flags that carry a password (`sshpass -p`, `mysql -p…`,
///     `ssh-keygen -P/-N`, `curl -u`, `echo`/`printf … | sudo -S`,
///     `sudo -S <<< …`), and long random-looking runs of base64 or hex.
///
/// The order matters. Learned secrets are matched first, but only as whole
/// tokens — not inside a longer word — so a password with spaces in it goes
/// whole before a pattern can take only its first word, while a short saved
/// password such as `pass` cannot eat the `pass` out of `password=` and
/// blind the pattern that would have caught the value after it. Then the
/// patterns. Then learned secrets again, anywhere, for one glued to other
/// text (`-pSECRET`) that no pattern knows.
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
  RegExp? _knownAsTokens;
  RegExp? _knownAnywhere;
  bool _knownDirty = false;

  /// How many distinct strings are being matched literally. For tests.
  int get knownCount => _known.length;

  /// Remembers [secret], in memory only, so [scrub] removes it wherever it
  /// appears: as written, JSON-escaped, URL-encoded, and each long line of a
  /// multi-line secret on its own. True when that taught it something new.
  bool learn(String? secret) {
    if (secret == null) return false;
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
    var learned = false;
    for (final variant in variants) {
      if (variant.length < minKnownSecretLength) continue;
      if (_known.add(variant)) learned = true;
    }
    if (learned) _knownDirty = true;
    return learned;
  }

  /// Forgets everything [learn] was told.
  void forgetAll() {
    _known.clear();
    _knownAsTokens = null;
    _knownAnywhere = null;
    _knownDirty = false;
  }

  static String _jsonEscaped(String value) {
    final quoted = jsonEncode(value);
    return quoted.substring(1, quoted.length - 1);
  }

  /// [input] with every secret this can find replaced. See the class doc
  /// for why in this order.
  String scrub(String input) {
    _compileKnown();
    var text = input;
    final asTokens = _knownAsTokens;
    if (asTokens != null) text = text.replaceAll(asTokens, redacted);
    for (final rule in _rules) {
      text = rule.apply(text);
    }
    final anywhere = _knownAnywhere;
    if (anywhere != null) text = text.replaceAll(anywhere, redacted);
    return text;
  }

  void _compileKnown() {
    if (!_knownDirty) return;
    _knownDirty = false;
    if (_known.isEmpty) {
      _knownAsTokens = null;
      _knownAnywhere = null;
      return;
    }
    // Longest first, so a password that happens to be part of a key does
    // not leave the rest of the key behind.
    final sorted = _known.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    final alternatives = sorted.map(RegExp.escape).join('|');
    _knownAsTokens =
        RegExp('(?<![A-Za-z0-9])(?:$alternatives)(?![A-Za-z0-9])');
    _knownAnywhere = RegExp(alternatives);
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
      r'(?:[A-Za-z0-9]+[_.-])*(?:pass|pwd|pw|cookie|sig|signature))';

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
    // scheme://user:password@host — the password taken to the *last* `@`
    // of the address, since one may hold `@` or `/` (ssh://u:p@ss/w0rd@h).
    // A URL with an `@` further along its path loses that much more; better
    // than leaving the end of a password behind.
    _ScrubRule(
      RegExp(
        r'''\b([a-z][a-z0-9+.-]*://)([^\s/:@]*):(?!\[redacted\])([^\s"'<>]+)@''',
        caseSensitive: false,
      ),
      (m) => '${m[1]}${m[2]}:$redacted@',
    ),
    // user:password@host with no scheme, as scp, rsync and many tools print
    // it. Not after `//` (that is the rule above) and not a time or a
    // file:line, which have no `@` after them.
    _ScrubRule(
      RegExp(
        r'''(?<![A-Za-z0-9._%+/:@-])([A-Za-z0-9._-]+):(?!//)(?!\[redacted\])([^\s"'<>]+)@(?=[A-Za-z0-9\[])''',
      ),
      (m) => '${m[1]}:$redacted@',
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
    // echo or printf piped into sudo: everything printed is the password,
    // however many words or format strings it takes.
    _ScrubRule(
      RegExp(r'(\b(?:echo|printf)\s+)([^|\r\n]*?)(\s*\|\s*sudo\b)'),
      (m) => '${m[1]}$redacted${m[3]}',
    ),
    // sudo -S <<< password
    _ScrubRule(
      RegExp(r'(\bsudo\b[^|;\r\n]*?<<<\s*)' '$_value'),
      (m) => '${m[1]}$redacted',
    ),
    // A password prompt with its answer after it on the line, the way a
    // terminal transcript or an expect script shows one: "Password for
    // root@h: …", "[sudo] password for dev: …", "root@h's password: …".
    _ScrubRule(
      RegExp(
        r'''((?:\b(?:password|passphrase|passcode|pin)\s+for\s+[^\r\n:]{1,100}|'s\s+password)\s*:[ \t]*)(?!\[redacted\])(\S[^\r\n]*)''',
        caseSensitive: false,
      ),
      (m) => '${m[1]}$redacted',
    ),
    // An environment variable named for a password with no separator in
    // the name: SSHPASS=…, MYPASS=…, and the `_PWD` ones (MYSQL_PWD) — but
    // not PWD itself, which is only the working directory.
    _ScrubRule(
      RegExp(r'\b([A-Z0-9_]*PASS[A-Z0-9_]*|[A-Z0-9_]+_PWD)=' '$_value'),
      (m) => '${m[1]}=$redacted',
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
    // A value given to a name that was itself a learned secret — a saved
    // password of `password` or `secret` turns `password=x` into
    // `[redacted]=x` before the rules above see it — goes too.
    _ScrubRule(
      RegExp(r'(\[redacted\])(\s*(?:=>|=|:)\s*)' '$_value'),
      (m) => '${m[1]}${m[2]}$redacted',
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
///    is written. When the scrubber learns a secret it did not know — a
///    credential loaded at start-up, a password typed later — the files
///    already on disk are scrubbed again with it, shortly after; so are they
///    when the log is first turned on in a run. And the whole log goes
///    through it once more when it is read back.
///  * **Small.** Two files at most, [maxFileBytes] each. When the current one
///    is full it becomes the previous one, and the oldest goes. One entry's
///    message and context are capped at [maxEntryChars] each as the entry
///    is made — before it waits in memory for the setting — a stack at
///    [maxStackLines] lines, and an error that repeats back to back is
///    written once, with a count.
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
    this.rescrubDelay = const Duration(seconds: 2),
  })  : _directory = directory ?? AppDataPaths.resolveDirectory,
        _now = clock ?? DateTime.now,
        _describePlatform = describePlatform ?? _platformLines,
        scrubber = scrubber ?? SecretScrubber();

  static final DiagnosticsLog instance = DiagnosticsLog();

  /// This build's version, as `pubspec.yaml` has it; see `app_version.dart`.
  static const String appVersion = app.appVersion;

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

  /// How long after a new secret is learned the files on disk are scrubbed
  /// again. Secrets come in bursts — every saved host's as the app starts —
  /// and one pass after the burst does for all of them.
  final Duration rescrubDelay;
  Timer? _rescrubTimer;

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
      // Files from an earlier run were scrubbed with what that run knew;
      // this one may know more already.
      await rescrubFiles();
      return;
    }
    _pending.clear();
    _rescrubTimer?.cancel();
    if (was != false) await clear();
  }

  /// Remembers a secret so it never reaches the log, and takes it out of
  /// what is already there. Memory only. Called wherever a secret is typed
  /// or loaded: the credential store, a password used without saving it,
  /// the answers to hidden login prompts, the vault and backup passphrases.
  void learnSecret(String? secret) {
    if (scrubber.learn(secret)) _learnedSomething();
  }

  void _learnedSomething() {
    // While the setting is unknown or off there is nothing on disk to
    // fix; [setEnabled] scrubs the files when it turns on.
    if (_enabled != true) return;
    _rescrubTimer?.cancel();
    _rescrubTimer = Timer(rescrubDelay, () => unawaited(rescrubFiles()));
  }

  /// Scrubs the files already written again with everything known now,
  /// rewriting each only when that changed it. Never throws.
  Future<void> rescrubFiles() async {
    _rescrubTimer?.cancel();
    _rescrubTimer = null;
    try {
      await _writer.run(() async {
        final dir = await _directory();
        for (final name in [previousFileName, fileName]) {
          final file = File('${dir.path}/$name');
          if (!await file.exists()) continue;
          final before =
              utf8.decode(await file.readAsBytes(), allowMalformed: true);
          final after = scrubber.scrub(before);
          if (after == before) continue;
          await atomicWrite(
            file,
            (temp) => temp.writeAsString(after, flush: true),
          );
        }
      });
    } catch (_) {
      // Best effort, like every write here; the copy is scrubbed on read.
    }
  }

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
          if (value is String) learnSecret(value);
        }
        return;
      }
    } catch (_) {
      // Not JSON; learn it whole.
    }
    learnSecret(raw);
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
      final description = _clip(_describe(error));
      final text = _formatEntry(
        description,
        stack,
        source: source,
        context: context == null ? null : _clip(context),
      );
      final signature =
          '$source\u0000$description\u0000${_firstLine(stack)}';
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

  /// [text] cut to [maxEntryChars], back to the last space before the cut
  /// when there is one nearby, so the end is a whole word rather than half
  /// of something the scrubber would have recognised whole. Done as the
  /// entry is made, so an error the size of a file never waits in memory
  /// whole — twenty of them could, before the setting is known.
  static String _clip(String text) {
    if (text.length <= maxEntryChars) return text;
    var cut = maxEntryChars;
    final space = text.lastIndexOf(RegExp(r'\s'), cut);
    if (space > maxEntryChars - 200) cut = space;
    return '${text.substring(0, cut)}\n(Entry cut short.)';
  }

  /// How long each entry waiting for the setting is, in characters. For
  /// tests.
  @visibleForTesting
  List<int> get pendingEntryLengths => [
        for (final entry in _pending)
          entry.text.length + entry.signature.length,
      ];

  String _formatEntry(
    String description,
    StackTrace? stack, {
    required String source,
    String? context,
  }) {
    final buffer = StringBuffer()
      ..writeln('=== ${_now().toUtc().toIso8601String()}  $source');
    if (context != null && context.trim().isNotEmpty) {
      buffer.writeln(context.trim());
    }
    buffer.writeln(description);
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
    _rescrubTimer?.cancel();
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
