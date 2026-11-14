import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'bridge_launcher_locator.dart';
import 'bridge_redactor.dart';

/// What one run of a program gave back.
class BridgeProcessResult {
  const BridgeProcessResult({
    required this.exitCode,
    this.stdout = '',
    this.stderr = '',
    this.timedOut = false,
    this.startError,
  });

  /// The program could not be started at all (missing, not executable).
  const BridgeProcessResult.notStarted(String message)
    : this(exitCode: null, startError: message);

  /// Null when it never started or was killed for taking too long.
  final int? exitCode;

  /// At most [bridgeProcessOutputCap] bytes of each, decoded as UTF-8.
  final String stdout;
  final String stderr;

  final bool timedOut;

  /// Why it could not be started, when it could not.
  final String? startError;

  bool get succeeded => exitCode == 0 && !timedOut && startError == null;
}

/// How processes are run, so the connector can be tested without the real
/// CLI. [stdin] is written and the pipe closed straight away, so a program
/// that asks a question gets end-of-file instead of waiting forever.
/// [runInShell] is only ever true for a Windows `.cmd`/`.bat` shim.
typedef BridgeProcessRunner =
    Future<BridgeProcessResult> Function(
      String executable,
      List<String> arguments, {
      String? stdin,
      Duration timeout,
      Map<String, String>? environment,
      bool runInShell,
    });

/// The most of each output stream that is kept. A CLI that prints more than
/// this is not printing anything the connector reads.
const int bridgeProcessOutputCap = 256 * 1024;

/// The default [BridgeProcessRunner]: [Process.start] directly, not through
/// a shell (unless [runInShell]), so no argument is ever interpreted.
Future<BridgeProcessResult> runBridgeProcess(
  String executable,
  List<String> arguments, {
  String? stdin,
  Duration timeout = const Duration(seconds: 90),
  Map<String, String>? environment,
  bool runInShell = false,
}) async {
  // A NUL ends a C string: the operating system would run whatever came
  // before it, and an empty name is looked up on the PATH.
  if (executable.isEmpty ||
      executable.contains('\u0000') ||
      arguments.any((a) => a.contains('\u0000'))) {
    return const BridgeProcessResult.notStarted('Not a program path.');
  }
  final Process process;
  try {
    process = await Process.start(
      executable,
      arguments,
      environment: environment,
      runInShell: runInShell,
    );
  } on ProcessException catch (e) {
    return BridgeProcessResult.notStarted(e.message);
  } catch (e) {
    // Only the type: nothing in an arbitrary error is known to be safe.
    return BridgeProcessResult.notStarted('Start failed (${e.runtimeType}).');
  }

  final out = _CappedBytes(bridgeProcessOutputCap);
  final err = _CappedBytes(bridgeProcessOutputCap);
  // The streams are read to the end even past the cap: a child whose pipe
  // fills up blocks on its next write and would never exit.
  final outSub = process.stdout.listen(out.add, onError: (Object _) {});
  final errSub = process.stderr.listen(err.add, onError: (Object _) {});
  final outDone = outSub.asFuture<void>().catchError((Object _) {});
  final errDone = errSub.asFuture<void>().catchError((Object _) {});

  // A child that exits without reading stdin makes the write fail with a
  // broken pipe; that is its business, not an error here.
  final sink = process.stdin;
  unawaited(sink.done.then((_) {}, onError: (Object _) {}));
  try {
    if (stdin != null) sink.add(utf8.encode(stdin));
  } catch (_) {}
  unawaited(sink.close().then((_) {}, onError: (Object _) {}));

  var timedOut = false;
  final int exitCode = await process.exitCode.timeout(
    timeout,
    onTimeout: () {
      timedOut = true;
      process.kill(ProcessSignal.sigkill);
      return process.exitCode;
    },
  );
  // Something the child started may still hold the pipes open after the
  // child itself is gone; do not wait on it for long.
  await Future.wait([
    outDone,
    errDone,
  ]).timeout(const Duration(seconds: 2), onTimeout: () => const []);
  unawaited(outSub.cancel());
  unawaited(errSub.cancel());

  return BridgeProcessResult(
    exitCode: timedOut ? null : exitCode,
    stdout: out.text,
    stderr: err.text,
    timedOut: timedOut,
  );
}

class _CappedBytes {
  _CappedBytes(this.cap);

  final int cap;
  final BytesBuilder _bytes = BytesBuilder(copy: false);

  void add(List<int> chunk) {
    final room = cap - _bytes.length;
    if (room <= 0) return;
    _bytes.add(chunk.length <= room ? chunk : chunk.sublist(0, room));
  }

  String get text => utf8.decode(_bytes.toBytes(), allowMalformed: true);
}

/// Whether the `claude` command can be run from this app, and which one.
sealed class ClaudeCliAvailability {
  const ClaudeCliAvailability();
}

/// Found and answered `--version`.
final class ClaudeCliAvailable extends ClaudeCliAvailability {
  const ClaudeCliAvailable({
    required this.executablePath,
    required this.version,
    this.pluginSource = const ClaudePluginSourceUnknown(),
  });

  /// Always absolute, so the screen can show exactly what will be run.
  final String executablePath;

  /// The first line of `claude --version`, e.g. `2.1.322 (Claude Code)`.
  final String version;

  /// Where the plugin, and with it the token, would come from and go to.
  /// Shown before the user agrees, and passed back to
  /// [ClaudeCliConnector.connect] as `expectedSource`.
  final ClaudePluginSource pluginSource;
}

/// Where `secureshellgo@dhiva-labs` would be installed from.
///
/// Claude Code finds a plugin by the name of its marketplace, and anything
/// can be added under the name `dhiva-labs`. Whatever that marketplace
/// serves is the program that receives the token, so the user is shown
/// which one it is before the token is handed over.
sealed class ClaudePluginSource {
  const ClaudePluginSource();
}

/// The project's own GitHub repository: either no `dhiva-labs` marketplace
/// is configured yet (it will be added from
/// [ClaudeCliConnector.marketplaceSource]) or the configured one is that
/// repository.
final class ClaudePluginSourceOfficial extends ClaudePluginSource {
  const ClaudePluginSourceOfficial();

  @override
  bool operator ==(Object other) => other is ClaudePluginSourceOfficial;

  @override
  int get hashCode => (ClaudePluginSourceOfficial).hashCode;
}

/// A `dhiva-labs` marketplace from somewhere else: a folder (a developer's
/// checkout), another repository, a URL.
final class ClaudePluginSourceOther extends ClaudePluginSource {
  const ClaudePluginSourceOther(this.description);

  /// The kind and where, e.g. `Folder: /home/u/dev/secure_shell_go` or
  /// `GitHub: someone/fork`. The kind words are English and not
  /// translated; the rest is as the CLI reported it.
  final String description;

  @override
  bool operator ==(Object other) =>
      other is ClaudePluginSourceOther && other.description == description;

  @override
  int get hashCode => description.hashCode;
}

/// The marketplace list could not be read or understood, so it is not
/// known whether a `dhiva-labs` marketplace exists or where it points.
final class ClaudePluginSourceUnknown extends ClaudePluginSource {
  const ClaudePluginSourceUnknown();

  @override
  bool operator ==(Object other) => other is ClaudePluginSourceUnknown;

  @override
  int get hashCode => (ClaudePluginSourceUnknown).hashCode;
}

/// Not on the PATH and not in any of the usual per-user places.
final class ClaudeCliNotFound extends ClaudeCliAvailability {
  const ClaudeCliNotFound();
}

/// The app is the strictly confined snap or the Flatpak, neither of which
/// may start programs on the host; nothing was tried.
final class ClaudeCliSandboxed extends ClaudeCliAvailability {
  const ClaudeCliSandboxed();
}

/// Something called `claude` was found but did not answer `--version`.
final class ClaudeCliFailed extends ClaudeCliAvailability {
  const ClaudeCliFailed(this.message);

  /// Short and in English; for the screen to show under its own sentence.
  final String message;
}

/// What [ClaudeCliConnector.find] saw without running anything.
sealed class ClaudeCliPresence {
  const ClaudeCliPresence();
}

/// At least one file that could be `claude` exists. Nothing has been run,
/// so whether it works is not known yet.
final class ClaudeCliPresent extends ClaudeCliPresence {
  const ClaudeCliPresent(this.candidates);

  /// Absolute paths, most likely first, as [ClaudeCliConnector.findCandidates]
  /// lists them.
  final List<String> candidates;
}

/// No file that could be `claude` was found.
final class ClaudeCliAbsent extends ClaudeCliPresence {
  const ClaudeCliAbsent();
}

/// The app is the strictly confined snap or the Flatpak, neither of which
/// may start programs on the host; nothing was looked for.
final class ClaudeCliPresenceSandboxed extends ClaudeCliPresence {
  const ClaudeCliPresenceSandboxed();
}

/// The commands `connect` runs, in order. Each one's [arguments] are
/// compile-time constants: nothing a caller passes, and above all not the
/// token, can reach a command line, which other users can read in the
/// process list (and which a Windows shell would interpret).
enum ClaudeConnectStep {
  marketplaceList(['plugin', 'marketplace', 'list', '--json']),
  marketplaceAdd([
    'plugin',
    'marketplace',
    'add',
    ClaudeCliConnector.marketplaceSource,
  ]),
  install(['plugin', 'install', ClaudeCliConnector.pluginId]),
  configure([
    'plugin',
    'configure',
    ClaudeCliConnector.pluginId,
    '--values-stdin',
  ]),
  verify(['plugin', 'configure', ClaudeCliConnector.pluginId, '--json']);

  const ClaudeConnectStep(this.arguments);

  final List<String> arguments;
}

/// One command `connect` ran, for the screen to show when it went wrong.
class ClaudeConnectStepResult {
  const ClaudeConnectStepResult({
    required this.step,
    required this.command,
    required this.exitCode,
    required this.timedOut,
    required this.output,
  });

  final ClaudeConnectStep step;

  /// The executable and its arguments, as run. Never holds a secret.
  final List<String> command;

  /// Null when it did not start or was killed for taking too long.
  final int? exitCode;

  final bool timedOut;

  /// At most 2 KiB of what it printed (stderr first, then a one-line note
  /// if it was cut), with the token replaced by `[token]` wherever the CLI
  /// echoed it.
  final String output;
}

/// How `connect` ended.
sealed class ClaudeConnectOutcome {
  const ClaudeConnectOutcome(this.steps);

  /// Every command that ran, in order.
  final List<ClaudeConnectStepResult> steps;
}

/// The plugin is installed and Claude Code reports the token as set.
final class ClaudeConnected extends ClaudeConnectOutcome {
  const ClaudeConnected(super.steps);
}

/// It stopped at [step]. The caller revokes the pairing, so this is only
/// returned when it really failed, and is never softened into a success.
final class ClaudeConnectFailed extends ClaudeConnectOutcome {
  const ClaudeConnectFailed({
    required this.step,
    required this.message,
    required List<ClaudeConnectStepResult> steps,
  }) : super(steps);

  final ClaudeConnectStep step;

  /// Short, in English, scrubbed of the token.
  final String message;
}

/// Finds the `claude` command and runs the plugin commands the connect
/// screen otherwise asks the user to paste into a terminal.
///
/// The token travels only on the stdin of `plugin configure --values-stdin`:
/// never in an argument, an environment variable, an exception or a returned
/// text. Constructed once and passed down; it keeps no state between calls.
class ClaudeCliConnector {
  ClaudeCliConnector({
    BridgeProcessRunner? runner,
    Map<String, String>? environment,
    bool? isWindows,
    String? resolvedExecutable,
    bool Function(String path)? fileExists,
    bool Function(String path)? pathExists,
  }) : _runner = runner ?? runBridgeProcess,
       _environment = environment ?? Platform.environment,
       _windows = isWindows ?? Platform.isWindows,
       _executable = resolvedExecutable ?? Platform.resolvedExecutable,
       _fileExists = fileExists ?? _isExecutableFile,
       _pathExists = pathExists ?? _pathIsThere;

  final BridgeProcessRunner _runner;
  final Map<String, String> _environment;
  final bool _windows;
  final String _executable;
  final bool Function(String path) _fileExists;

  /// Any file at all, not only an executable one: the Flatpak test
  /// ([runsInFlatpak]) looks for `/.flatpak-info`.
  final bool Function(String path) _pathExists;

  static bool _pathIsThere(String path) =>
      FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound;

  /// The snap and the Flatpak may not start programs on the host, so
  /// nothing is looked for there.
  bool get _sandboxed =>
      runsFromSnap(
        environment: _environment,
        resolvedExecutable: _executable,
      ) ||
      (!_windows &&
          runsInFlatpak(
            environment: _environment,
            resolvedExecutable: _executable,
            pathExists: _pathExists,
          ));

  static const String marketplaceName = 'dhiva-labs';
  static const String marketplaceSource = 'Dhiva-Labs/SecureShellGo';
  static const String pluginId = 'secureshellgo@dhiva-labs';

  static const Duration versionTimeout = Duration(seconds: 10);

  /// Installing clones the marketplace from GitHub, which can be slow.
  static const Duration stepTimeout = Duration(seconds: 90);

  static const List<String> _versionArguments = ['--version'];

  static const int _excerptBytes = 2 * 1024;

  // Colour codes would only clutter the excerpts the screen shows.
  static const Map<String, String> _childEnvironment = {'NO_COLOR': '1'};

  // Characters cmd.exe treats specially outside quotes. A `.cmd` shim is
  // started through it, and its path is the one string there that is not a
  // constant, so a path holding any of these is not run at all.
  // Quotes, the operators, `%`/`!` expansion, the argument separators
  // (`,;=`) and the characters that make cmd.exe drop the quotes Dart puts
  // round a path holding a space (`()@`). A `Program Files (x86)` shim is
  // therefore not run; it fails closed rather than be mis-parsed.
  static final RegExp _shellUnsafe = RegExp(r'[&|<>^%!"\r\n\x00(),;=@]');

  /// Looks for `claude` and asks it for its version.
  Future<ClaudeCliAvailability> detect() async {
    if (_sandboxed) return const ClaudeCliSandboxed();
    final candidates = findCandidates();
    if (candidates.isEmpty) return const ClaudeCliNotFound();

    String? firstFailure;
    for (final path in candidates) {
      final result = await _start(path, _versionArguments, versionTimeout);
      if (result.succeeded) {
        final version = result.stdout
            .split('\n')
            .map((l) => l.trim())
            .firstWhere((l) => l.isNotEmpty, orElse: () => '');
        // One read-only look at the marketplaces, so the screen can say
        // where the plugin would come from. Its failure is "unknown", not a
        // failed detection: the CLI itself works.
        final list = await _start(
          path,
          ClaudeConnectStep.marketplaceList.arguments,
          versionTimeout,
        );
        return ClaudeCliAvailable(
          executablePath: path,
          version: version,
          pluginSource: pluginSourceOf(list),
        );
      }
      firstFailure ??= '$path: ${_describe(result, (s) => s)}';
    }
    return ClaudeCliFailed(firstFailure!);
  }

  /// Whether a `claude` could be here, from file-system checks alone: the
  /// sandbox check (snap, Flatpak) and [findCandidates]. Starts no process,
  /// so it is what a screen may call on its own; [detect], which runs the
  /// program, waits until the user asks for it.
  ClaudeCliPresence find() {
    if (_sandboxed) return const ClaudeCliPresenceSandboxed();
    final candidates = findCandidates();
    if (candidates.isEmpty) return const ClaudeCliAbsent();
    return ClaudeCliPresent(List.unmodifiable(candidates));
  }

  /// Every existing file that could be `claude`, most likely first, each
  /// an absolute path. The PATH is read here rather than by asking `which`
  /// so nothing is run before the one program the user will see named.
  List<String> findCandidates() {
    final found = <String>[];
    void consider(String path) {
      if (!found.contains(path) && _fileExists(path)) found.add(path);
    }

    final separator = _windows ? r'\' : '/';
    final names = _windows ? _windowsNames() : const ['claude'];
    for (var dir in (_env('PATH') ?? '').split(_windows ? ';' : ':')) {
      dir = dir.trim();
      if (_windows && dir.length >= 2 && dir.startsWith('"')) {
        dir = dir.replaceAll('"', '');
      }
      // An empty or relative entry means "the current directory", which for
      // an app is wherever it happened to be started; never run from there.
      // A network share is never run from either (_isAbsolute refuses it).
      if (!_isAbsolute(dir) || dir.contains('%')) continue;
      final base = dir.endsWith(separator) ? dir : '$dir$separator';
      for (final name in names) {
        consider('$base$name');
      }
    }

    final home = _env(_windows ? 'USERPROFILE' : 'HOME') ?? '';
    if (_isAbsolute(home)) {
      final base = home.endsWith(separator) ? home : '$home$separator';
      if (_windows) {
        consider('$base.local\\bin\\claude.exe');
      } else {
        // The native installer's place, then the older "local" install.
        consider('$base.local/bin/claude');
        consider('$base.claude/local/claude');
      }
    }
    return found;
  }

  /// Installs the plugin and gives it [token] (and [launcherCommand], when
  /// it is not the plugin's default), using the `claude` at
  /// [executablePath], normally the one [detect] found.
  ///
  /// [expectedSource] is the [ClaudeCliAvailable.pluginSource] the user was
  /// shown. When given, the marketplace list is read again and a source
  /// that no longer matches stops it at [ClaudeConnectStep.marketplaceList],
  /// before anything is installed and before the token is sent.
  ///
  /// [onStep], when given, is called just before each command starts, for a
  /// screen to show which one is running. A step that is not needed (the
  /// marketplace add, when the marketplace is already there) is never
  /// reported. It is told only the step, never the token, and an exception
  /// it throws is ignored: showing progress must not stop a setup half way.
  Future<ClaudeConnectOutcome> connect({
    required String executablePath,
    required String token,
    required String launcherCommand,
    ClaudePluginSource? expectedSource,
    void Function(ClaudeConnectStep step)? onStep,
  }) async {
    // The CLI takes single-line strings, and an empty token cannot pair.
    // The message says what is wrong without repeating the value.
    if (token.isEmpty || token.contains('\n') || token.contains('\r')) {
      throw ArgumentError('The token must be one non-empty line.');
    }
    if (launcherCommand.contains('\n') || launcherCommand.contains('\r')) {
      throw ArgumentError('The launcher command must be one line.');
    }
    String scrub(String text) => _scrub(text, token);

    // Checked here as well as in _start so a bad path is one clear failure
    // with no process started, not a chain of steps that each fail to start.
    final refusal = _refuseExecutable(executablePath);
    if (refusal != null) {
      return ClaudeConnectFailed(
        step: ClaudeConnectStep.marketplaceList,
        message: refusal,
        steps: const [],
      );
    }

    final steps = <ClaudeConnectStepResult>[];
    Future<BridgeProcessResult> run(
      ClaudeConnectStep step, {
      String? stdin,
    }) async {
      if (onStep != null) {
        try {
          onStep(step);
        } catch (_) {}
      }
      final result = await _start(
        executablePath,
        step.arguments,
        stepTimeout,
        stdin: stdin,
      );
      steps.add(
        ClaudeConnectStepResult(
          step: step,
          command: [executablePath, ...step.arguments],
          exitCode: result.exitCode,
          timedOut: result.timedOut,
          output: _excerpt(result, scrub),
        ),
      );
      return result;
    }

    ClaudeConnectFailed fail(
      ClaudeConnectStep step,
      BridgeProcessResult result,
    ) => ClaudeConnectFailed(
      step: step,
      message: _describe(result, scrub),
      steps: List.unmodifiable(steps),
    );

    // 1 and 2: the marketplace. Already there means nothing to add; an add
    // that fails is not the end, because install says whether the plugin
    // can be had (before a release reaches GitHub's default branch the add
    // fails, and a marketplace added under another source still serves it).
    final list = await run(ClaudeConnectStep.marketplaceList);
    if (expectedSource != null) {
      final now = pluginSourceOf(list);
      if (now != expectedSource) {
        return ClaudeConnectFailed(
          step: ClaudeConnectStep.marketplaceList,
          message: now is ClaudePluginSourceOther
              ? 'The dhiva-labs marketplace has changed: ${now.description}'
              : now is ClaudePluginSourceOfficial
              ? 'The dhiva-labs marketplace has changed since it was shown.'
              : 'The dhiva-labs marketplace could not be checked again.',
          steps: List.unmodifiable(steps),
        );
      }
    }
    if (!(list.succeeded && _hasMarketplace(list.stdout))) {
      await run(ClaudeConnectStep.marketplaceAdd);
    }

    // 3: install. Already installed counts; the CLI's wording is matched
    // loosely, since only the exit code is a contract.
    final install = await run(ClaudeConnectStep.install);
    if (!install.succeeded && !_saysAlready(install)) {
      return fail(ClaudeConnectStep.install, install);
    }

    // 4: the options, as JSON on stdin and nowhere else.
    // `launcher` is always sent: options left out keep their old values, so
    // a launcher saved by an earlier install kind would otherwise survive.
    final values = jsonEncode({
      'bridge_token': token,
      'launcher': launcherCommand.isEmpty
          ? BridgeLauncherCommand.defaultCommand
          : launcherCommand,
    });
    final configure = await run(ClaudeConnectStep.configure, stdin: values);
    if (!configure.succeeded) {
      return fail(ClaudeConnectStep.configure, configure);
    }

    // 5: read it back. The caller revokes the pairing only on a failure, so
    // "connected" must mean Claude Code said the token is set: a timeout, an
    // error or an answer of another shape is a failure, and a revoked pairing
    // is safe where a live token nobody holds is not.
    final verify = await run(ClaudeConnectStep.verify);
    if (!verify.succeeded) return fail(ClaudeConnectStep.verify, verify);
    if (_tokenSet(verify.stdout) != true) {
      return ClaudeConnectFailed(
        step: ClaudeConnectStep.verify,
        message: _tokenSet(verify.stdout) == false
            ? 'Claude Code reports the pairing token as not set.'
            : 'Claude Code did not confirm that the pairing token is set.',
        steps: List.unmodifiable(steps),
      );
    }
    return ClaudeConnected(List.unmodifiable(steps));
  }

  bool needsShell(String path) {
    if (!_windows) return false;
    // Windows ignores trailing dots and spaces, so `claude.cmd.` is the
    // same batch file and must be treated as one.
    final lower = path.toLowerCase().replaceAll(RegExp(r'[. ]+$'), '');
    return lower.endsWith('.cmd') || lower.endsWith('.bat');
  }

  /// The one way a process is started here. [arguments] must be one of the
  /// constant lists above: a Windows shim runs through `cmd.exe`, which
  /// interprets its command line, and the process list is readable by other
  /// users, so no caller-supplied string may ever get into it. Checked at
  /// run time, not only by assert, because it is a security property.
  Future<BridgeProcessResult> _start(
    String executable,
    List<String> arguments,
    Duration timeout, {
    String? stdin,
  }) async {
    final fixed =
        identical(arguments, _versionArguments) ||
        ClaudeConnectStep.values.any((s) => identical(s.arguments, arguments));
    if (!fixed) {
      throw StateError('Only the fixed claude arguments may be run.');
    }
    final refusal = _refuseExecutable(executable);
    if (refusal != null) return BridgeProcessResult.notStarted(refusal);
    final shell = needsShell(executable);
    return _runner(
      executable,
      arguments,
      stdin: stdin,
      timeout: timeout,
      environment: _childEnvironment,
      runInShell: shell,
    );
  }

  /// Why [executable] may not be run, or null when it may. Whatever the
  /// caller passed is checked again here: only an absolute, local path to an
  /// existing file named `claude` is run, never a name looked up on the
  /// PATH or in the current directory, a program on a network share, or
  /// some other program the caller was handed.
  String? _refuseExecutable(String executable) {
    if (executable.contains('\u0000') ||
        !_isAbsolute(executable) ||
        !_fileExists(executable)) {
      return 'The program is not an absolute path to an existing file.';
    }
    if (!isClaudeFileName(executable)) {
      return 'The program is not named claude.';
    }
    if (needsShell(executable) && _shellUnsafe.hasMatch(executable)) {
      return 'The path holds a character the Windows shell would interpret.';
    }
    return null;
  }

  static const Set<String> _claudeNames = {
    'claude',
    'claude.exe',
    'claude.cmd',
    'claude.bat',
  };

  /// Whether the last part of [path] is `claude`, `claude.exe`,
  /// `claude.cmd` or `claude.bat`: exactly on POSIX; on Windows in any case
  /// and with the trailing dots and spaces Windows ignores taken off.
  bool isClaudeFileName(String path) {
    final cut = _windows
        ? path.lastIndexOf(RegExp(r'[\\/]'))
        : path.lastIndexOf('/');
    final name = path.substring(cut + 1);
    if (!_windows) return _claudeNames.contains(name);
    return _claudeNames.contains(
      name.toLowerCase().replaceAll(RegExp(r'[. ]+$'), ''),
    );
  }

  /// Where the plugin would come from, read from the output of
  /// `plugin marketplace list --json`: an array of objects such as
  /// `{"name":"dhiva-labs","source":"directory","path":...}` or
  /// `{"name":...,"source":"github","repo":...}`. "Official" for no
  /// `dhiva-labs` entry only when every entry could be read, since an entry
  /// that could not might be it.
  static ClaudePluginSource pluginSourceOf(BridgeProcessResult list) {
    if (!list.succeeded) return const ClaudePluginSourceUnknown();
    final json = _json(list.stdout, '[');
    if (json is! List) return const ClaudePluginSourceUnknown();
    Map<Object?, Object?>? ours;
    for (final entry in json) {
      if (entry is! Map || entry['name'] is! String) {
        return const ClaudePluginSourceUnknown();
      }
      if (entry['name'] == marketplaceName) ours ??= entry;
    }
    if (ours == null) return const ClaudePluginSourceOfficial();

    final source = ours['source'];
    final repo = ours['repo'];
    if (source == 'github' &&
        repo is String &&
        repo.toLowerCase() == marketplaceSource.toLowerCase()) {
      return const ClaudePluginSourceOfficial();
    }
    const kinds = {
      'directory': 'Folder',
      'file': 'File',
      'github': 'GitHub',
      'git': 'Git',
      'url': 'URL',
      'npm': 'npm',
    };
    final kind = source is String
        ? (kinds[source] ?? source)
        : 'Unknown source';
    final where = [
      ours['repo'],
      ours['url'],
      ours['path'],
      ours['package'],
      ours['installLocation'],
    ].whereType<String>().firstWhere((w) => w.isNotEmpty, orElse: () => '');
    // Text from the CLI, shown on a screen: one line, and not a page of it.
    final text = (where.isEmpty ? kind : '$kind: $where').replaceAll(
      RegExp(r'[\x00-\x1f\x7f]'),
      ' ',
    );
    return ClaudePluginSourceOther(
      text.length > 300 ? '${text.substring(0, 300)}...' : text,
    );
  }

  List<String> _windowsNames() {
    // PATHEXT order decides which of claude.exe and claude.cmd wins in a
    // folder that has both, as it does at a prompt. Only the kinds the CLI
    // actually ships as are looked for.
    final exts = (_env('PATHEXT') ?? '.COM;.EXE;.BAT;.CMD')
        .split(';')
        .map((e) => e.trim().toLowerCase())
        .where((e) => const {'.exe', '.cmd', '.bat'}.contains(e));
    return [for (final e in exts) 'claude$e'];
  }

  String? _env(String name) {
    final direct = _environment[name];
    if (direct != null || !_windows) return direct;
    // Windows variable names are case-insensitive (`Path` is common).
    final upper = name.toUpperCase();
    for (final entry in _environment.entries) {
      if (entry.key.toUpperCase() == upper) return entry.value;
    }
    return null;
  }

  /// A local absolute path. On Windows only a drive path (`C:\...`): a UNC
  /// path (`\\server\share`, `//server/share`, and the `\\?\` and `\\.\`
  /// forms) is refused, because a program on a network share is whatever
  /// the share's owner put there, and it would be handed the token.
  bool _isAbsolute(String path) {
    if (!_windows) return path.startsWith('/');
    return RegExp(r'^[A-Za-z]:\\').hasMatch(path);
  }

  static bool _isExecutableFile(String path) {
    try {
      final stat = File(path).statSync();
      if (stat.type != FileSystemEntityType.file) return false;
      if (Platform.isWindows) return true;
      return stat.mode & 0x49 != 0; // any of the three execute bits
    } catch (_) {
      return false;
    }
  }

  /// The JSON out of [stdout], also when the CLI printed a warning first.
  static Object? _json(String stdout, String opener) {
    final text = stdout.trim();
    try {
      return jsonDecode(text);
    } on FormatException {
      final at = text.indexOf(opener);
      if (at <= 0) return null;
      try {
        return jsonDecode(text.substring(at));
      } on FormatException {
        return null;
      }
    }
  }

  // `marketplace list --json` is an array of objects with a `name`.
  static bool _hasMarketplace(String stdout) {
    final json = _json(stdout, '[');
    if (json is! List) return false;
    return json.any((m) => m is Map && m['name'] == marketplaceName);
  }

  // `configure --json` has `configured` and `unconfigured` arrays of option
  // names. Null when neither says anything about the token.
  static bool? _tokenSet(String stdout) {
    final json = _json(stdout, '{');
    if (json is! Map) return null;
    final configured = json['configured'];
    if (configured is List && configured.contains('bridge_token')) return true;
    final unconfigured = json['unconfigured'];
    if (unconfigured is List && unconfigured.contains('bridge_token')) {
      return false;
    }
    return null;
  }

  // The CLI prints `Plugin "secureshellgo@dhiva-labs" is already installed
  // (scope: user) ...`. Matched per line and only with this plugin's id on
  // it, so another plugin's message cannot excuse a failed install.
  static final RegExp _already = RegExp(
    r'already\s+installed',
    caseSensitive: false,
  );

  static bool _saysAlready(BridgeProcessResult r) =>
      !r.timedOut &&
      r.startError == null &&
      '${r.stdout}\n${r.stderr}'
          .split('\n')
          .any((l) => l.contains(pluginId) && _already.hasMatch(l));

  static const int _partialMin = 8;

  /// The token whole, as JSON escapes it (also with `/` escaped, as some
  /// encoders do), and any run of 8 or more of its characters from either
  /// end, for a CLI that echoes it cut short or masked.
  static String _scrub(String text, String token) {
    final forms = <String>{token};
    final escaped = jsonEncode(token);
    final inner = escaped.substring(1, escaped.length - 1);
    forms.add(inner);
    forms.add(inner.replaceAll('/', r'\/'));
    // Longest first, so a whole token is not left as a shorter echo's tail.
    final byLength = forms.toList()..sort((a, b) => b.length - a.length);
    var out = text;
    for (final form in byLength) {
      out = out.replaceAll(form, '[token]');
    }
    if (token.length >= 2 * _partialMin) {
      for (var n = token.length - 1; n >= _partialMin; n--) {
        out = out.replaceAll(token.substring(0, n), '[token]');
        out = out.replaceAll(token.substring(token.length - n), '[token]');
      }
    }
    return out;
  }

  /// Scrubbed whole, then cut, so a cut never leaves half a token behind.
  /// The head is kept: the capture itself keeps the head, so the excerpt
  /// never reaches the point where a long output was cut.
  static String _excerpt(BridgeProcessResult r, String Function(String) scrub) {
    final parts = [
      if (r.startError != null) r.startError!,
      if (r.stderr.trim().isNotEmpty) r.stderr.trim(),
      if (r.stdout.trim().isNotEmpty) r.stdout.trim(),
    ];
    return BridgeRedactor.capUtf8(scrub(parts.join('\n')), _excerptBytes);
  }

  static String _describe(
    BridgeProcessResult r,
    String Function(String) scrub,
  ) {
    if (r.timedOut) return 'It did not finish in time and was stopped.';
    if (r.startError != null) {
      return BridgeRedactor.capUtf8(
        scrub('It could not be started: ${r.startError}'),
        _excerptBytes,
      );
    }
    final first = scrub('${r.stderr}\n${r.stdout}')
        .split('\n')
        .map((l) => l.trim())
        .firstWhere((l) => l.isNotEmpty, orElse: () => '');
    final line = BridgeRedactor.capUtf8(first, 512);
    return line.isEmpty
        ? 'It exited with code ${r.exitCode}.'
        : 'It exited with code ${r.exitCode}: $line';
  }
}
