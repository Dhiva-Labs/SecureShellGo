import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart' show SSHSession, SftpStatusError;

import '../../models/app_settings.dart';
import '../../models/host.dart';
import '../../models/remote_entry.dart';
import '../editor_document.dart';
import '../log_tail.dart';
import '../remote_exec.dart';
import '../server_probe.dart';
import '../sftp_service.dart';
import '../shell_quote.dart';
import '../systemd_units.dart';
import 'bridge_audit.dart';
import 'bridge_client_store.dart';
import 'bridge_connections.dart';
import 'bridge_host_directory.dart';
import 'bridge_paths.dart';
import 'bridge_policy.dart';
import 'bridge_redactor.dart';
import 'bridge_tool_types.dart';

/// The commands the read tools run, separate from execution so the quoting
/// can be asserted character for character. Every value that comes from an
/// assistant reaches a shell only through a quoting function: values inside
/// a template (parsed by `/bin/sh`) through [posixSingleQuote], and the
/// whole template on the login shell's command line through
/// [BridgeCommands.loginShellQuote]; numbers are validated ints before they
/// get here.
class BridgeCommands {
  const BridgeCommands._();

  static const String journalProbe = 'command -v journalctl >/dev/null 2>&1';

  /// The last [lines] of a unit's journal, once — no `-f`.
  static String journal(String unit, int lines) =>
      'journalctl --no-pager -q -o short-iso -n $lines -u '
      '${posixSingleQuote(unit)}';

  /// The most a file's tail is read as before it is cut to lines: a log
  /// that is one enormous line must not stream whole over the connection.
  static const int tailWindowBytes = 256 * 1024;

  /// The last [lines] of a file, once — `tail`, never `-F`. `--` because the
  /// path is an argument, not an option, whatever it starts with. The first
  /// `tail` takes only the last [tailWindowBytes] (a seek, not a read of the
  /// whole file); the second cuts that to lines.
  static String tailFile(String path, int lines) =>
      'tail -c $tailWindowBytes -- ${posixSingleQuote(path)} '
      '| tail -n $lines';

  /// [command] run so that the app can end it, and everything it started,
  /// by closing the channel's stdin — the approach `FleetExecService.wrap`
  /// takes for a fleet run, with the fixed command run by `/bin/sh` rather
  /// than the account's shell, since every template here is POSIX sh.
  ///
  /// The command runs in the background under `setsid` where there is one,
  /// so it and its children are a process group of their own. Beside it a
  /// `cat` waits on the channel's stdin (saved on fd 3); when a call is
  /// stopped — past its deadline, or abandoned because its assistant was
  /// revoked or the bridge switched off — the app closes stdin, `cat`
  /// returns, and the group is sent TERM. Closing an exec channel alone
  /// does not reliably stop a remote process that has no terminal. A TERM
  /// or HUP sent to the wrapper itself is passed on in the same way.
  ///
  /// Two layers, two parsers. The OUTER command line returned here is parsed
  /// by the account's LOGIN shell (sh, bash, zsh, fish, ...), so the template
  /// reaches it through [loginShellQuote]. The wrapper script is fixed text
  /// with no backslash, and runs under `sh -c`. The template itself (built
  /// by [journal], [tailFile], [findByName] and the other command classes)
  /// reaches `/bin/sh -c "$1"` as plain data and is parsed by `/bin/sh`
  /// alone, so the values quoted INSIDE a template use [posixSingleQuote],
  /// which is exact for `/bin/sh`. Never let a login shell parse a
  /// [posixSingleQuote]d value: under fish a backslash is special there.
  static String supervised(String command) {
    const wrapper = r'''exec 3<&0
t=
w=
ssg_pass() { if [ -n "$t" ]; then kill -s "$1" -- "$t" 2>/dev/null; fi; if [ -n "$w" ]; then kill "$w" 2>/dev/null; fi; exit "$2"; }
trap 'ssg_pass TERM 143' TERM
trap 'ssg_pass HUP 129' HUP
if command -v setsid >/dev/null 2>&1; then
  setsid /bin/sh -c "$1" 3<&- &
  p=$!
  t="-$p"
else
  /bin/sh -c "$1" 3<&- &
  p=$!
  t="$p"
fi
( cat <&3 >/dev/null 2>&1; kill -s TERM -- "$t" 2>/dev/null ) >/dev/null 2>&1 &
w=$!
exec 3<&-
wait $p
s=$?
kill $w 2>/dev/null
exit $s''';
    return 'sh -c ${posixSingleQuote(wrapper)} ssg-bridge '
        '${loginShellQuote(command)}';
  }

  /// [value] as one word for any login shell's command line, not only the
  /// POSIX ones. [posixSingleQuote] is exact for sh, bash and zsh, but fish
  /// reads `\\` and `\'` inside single quotes as escapes, so a value with a
  /// backslash comes out changed, and one ending in a backslash escapes its
  /// closing quote. Here no backslash is ever inside single quotes: a quote
  /// is `'\''` (a backslash outside any quotes) and a backslash is `'"\\"'`
  /// (double quotes, where `\\` is one backslash in sh, bash, zsh and fish
  /// alike). For a value with no backslash the result is exactly
  /// [posixSingleQuote]'s.
  static String loginShellQuote(String value) {
    final out = StringBuffer("'");
    for (final unit in value.runes) {
      final c = String.fromCharCode(unit);
      if (c == "'") {
        out.write(r"'\''");
      } else if (c == r'\') {
        out.write(r"""'"\\"'""");
      } else {
        out.write(c);
      }
    }
    out.write("'");
    return out.toString();
  }

  /// Seconds `search_files` gives `find` when the server has `timeout`.
  static const int findSeconds = 20;

  /// File *names* under [dir] matching [pattern], at most [depth] levels
  /// down. `find` prints paths and nothing else: no file is opened, so no
  /// content can come back. `timeout` bounds the walk where it exists, and
  /// `head` stops it once enough has been found.
  static String findByName(
    String dir,
    String pattern, {
    required int depth,
    required int limit,
  }) {
    final find =
        'find ${posixSingleQuote(dir)} -maxdepth $depth '
        '-name ${posixSingleQuote(pattern)} -print 2>/dev/null';
    return 'if command -v timeout >/dev/null 2>&1; '
        'then timeout $findSeconds $find; else $find; fi | head -n $limit';
  }
}

/// How one call ended, before redaction and audit.
class _Outcome {
  const _Outcome.ok(this.text, {this.keepTail = false})
    : outcome = BridgeAuditOutcome.ok,
      detail = '';

  _Outcome.refused(BridgeRefuse refusal)
    : text = refusal.message,
      outcome = BridgeAuditOutcome.refused,
      detail = refusal.code,
      keepTail = false;

  const _Outcome.error(this.text)
    : outcome = BridgeAuditOutcome.error,
      detail = text,
      keepTail = false;

  final String text;
  final BridgeAuditOutcome outcome;
  final String detail;
  final bool keepTail;
}

/// Thrown by argument validation and by the path guard; becomes a refusal.
class _Refused implements Exception {
  const _Refused(this.refusal);

  final BridgeRefuse refusal;
}

/// Refusals the tools give beyond the policy's own.
class BridgeToolRefusals {
  const BridgeToolRefusals._();

  /// Given for a path the guard blocks *and* for one the server will not
  /// resolve, so a refusal never says whether a blocked file exists.
  static const BridgeRefuse pathNotAvailable = BridgeRefuse(
    'path_not_available',
    'That path is not available to the AI Bridge: it is blocked by the '
        "user's settings or cannot be opened. Do not retry it.",
  );

  static const BridgeRefuse busy = BridgeRefuse(
    'busy',
    'SecureShell Go is already answering as many AI Bridge calls as it '
        'takes at once. Try again in a moment.',
  );

  static const BridgeRefuse unknownTool = BridgeRefuse(
    'unknown_tool',
    'There is no tool by that name. Call tools/list to see the tools.',
  );

  static BridgeRefuse invalid(String why) =>
      BridgeRefuse('invalid_arguments', 'Invalid arguments: $why');
}

/// One allowed call's context: the host the policy allowed, the settings it
/// was allowed under, and the only way to the server. Built by the
/// dispatcher after [decideBridgeCall] said yes, and by nothing else — a
/// tool body has no other route to a connection.
class _Call {
  _Call._({
    required this.host,
    required this.settings,
    required this.connections,
    required this.deadline,
  }) : guard = BridgePathGuard(
         readSensitivePaths: settings.bridgeReadSensitivePaths,
         extraPatterns: settings.bridgeExtraBlockedPaths,
       ) {
    // At the deadline everything this call has open on the server is ended,
    // whether or not the tool body has noticed yet.
    _deadlineTimer = Timer(remaining, () => unawaited(halt()));
  }

  final Host? host;
  final AppSettings settings;
  final BridgePathGuard guard;
  final BridgeConnections connections;
  final DateTime deadline;
  BridgeLease? _lease;
  late final Timer _deadlineTimer;
  final Set<SSHSession> _sessions = {};
  var _halted = false;

  /// Completes when the call is [halt]ed, so whatever it is waiting on —
  /// a command, an SFTP reply — is given up at once rather than when the
  /// server gets round to answering.
  final Completer<void> _haltSignal = Completer<void>();

  Duration get remaining {
    final left = deadline.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  /// Out of time, or abandoned: nothing new is started on the server.
  void _checkLive() {
    if (_halted || remaining == Duration.zero) {
      throw TimeoutException('deadline');
    }
  }

  /// The host's connection, dialling it if need be — within the call's
  /// time. A dial that lands after the deadline still takes a lease on the
  /// cached connection, so it is given straight back rather than left to
  /// hold the connection open for good.
  Future<BridgeLease> _leaseNow() async {
    final held = _lease;
    if (held != null) return held;
    _checkLive();
    final pending = connections.acquire(host!);
    try {
      // Bounded by a halt too, so an abandoned call gives its slot back at
      // once instead of when a slow dial gets round to answering.
      final lease = await bounded(pending);
      if (_halted) {
        unawaited(lease.release());
        throw TimeoutException('halted');
      }
      return _lease = lease;
    } on TimeoutException {
      unawaited(pending.then((late) => late.release(), onError: (Object _) {}));
      rethrow;
    }
  }

  /// [work] within the call's time, and given up the moment it is halted.
  Future<T> bounded<T>(Future<T> work) => Future.any<T>([
    work,
    _haltSignal.future.then<T>((_) => throw TimeoutException('halted')),
  ]).timeout(remaining);

  /// Runs one fixed command under [BridgeCommands.supervised], within the
  /// call's time. Opening the channel is bounded too, and a channel that
  /// opens after the deadline is ended as soon as it arrives. However the
  /// command ends — finished, out of time, or [halt]ed — its stdin is
  /// closed (which ends the remote process group) and the channel with it.
  Future<ExecResult> exec(String command) async {
    final lease = await _leaseNow();
    _checkLive();
    final pending = lease.transport.execute(BridgeCommands.supervised(command));
    final SSHSession session;
    try {
      session = await pending.timeout(remaining);
    } on TimeoutException {
      unawaited(pending.then(_stopSession, onError: (Object _) {}));
      rethrow;
    }
    if (_halted) {
      await _stopSession(session);
      throw TimeoutException('halted');
    }
    _sessions.add(session);
    try {
      return await bounded(_collect(session));
    } finally {
      _sessions.remove(session);
      await _stopSession(session);
    }
  }

  static Future<ExecResult> _collect(SSHSession session) async {
    final out = BytesBuilder();
    final err = BytesBuilder();
    final outDone = Completer<void>();
    final errDone = Completer<void>();
    void complete(Completer<void> c) {
      if (!c.isCompleted) c.complete();
    }

    session.stdout.listen(
      out.add,
      onDone: () => complete(outDone),
      onError: (Object _) => complete(outDone),
      cancelOnError: false,
    );
    session.stderr.listen(
      err.add,
      onDone: () => complete(errDone),
      onError: (Object _) => complete(errDone),
      cancelOnError: false,
    );
    final exitCode = await session.waitForExit();
    // As `RemoteExec.run`: the exit status can arrive before the last of
    // the output, so the pipes get a short, bounded wait.
    await Future.wait([
      outDone.future,
      errDone.future,
    ]).timeout(const Duration(seconds: 2), onTimeout: () => const []);
    return ExecResult(
      stdout: utf8.decode(out.toBytes(), allowMalformed: true),
      stderr: utf8.decode(err.toBytes(), allowMalformed: true),
      exitCode: exitCode,
    );
  }

  static Future<void> _stopSession(SSHSession session) async {
    try {
      await session.stdin.close().timeout(const Duration(seconds: 1));
    } catch (_) {
      // Already closed, or the channel is gone.
    }
    try {
      session.close();
    } catch (_) {
      // Already gone.
    }
  }

  Future<BridgeFiles> files() async {
    final lease = await _leaseNow();
    _checkLive();
    return bounded(lease.files());
  }

  /// [raw] resolved on the server, symlinks and all, then put to the guard.
  /// The one way a path argument becomes a path a tool may use: a refusal
  /// for a blocked path and for one the server cannot resolve read the same.
  Future<String> guardedPath(String raw) async {
    final fs = await files();
    // The path as asked is checked too, so a server whose realpath does not
    // follow links still cannot be asked for `~/.ssh/...` by name.
    if (raw.startsWith('/') && guard.isBlocked(raw)) {
      throw const _Refused(BridgeToolRefusals.pathNotAvailable);
    }
    final String canonical;
    try {
      canonical = await bounded(fs.realpath(raw));
    } on TimeoutException {
      rethrow;
    } catch (_) {
      throw const _Refused(BridgeToolRefusals.pathNotAvailable);
    }
    if (!canonical.startsWith('/') || guard.isBlocked(canonical)) {
      throw const _Refused(BridgeToolRefusals.pathNotAvailable);
    }
    final segments = BridgePathGuard.canonicalSegments(canonical)!;
    return '/${segments.join('/')}';
  }

  /// Ends everything this call has open on the server now: every running
  /// command (stdin closed, then the channel) and the call's SFTP channel.
  /// Called at the deadline and when the call is abandoned; the tool body
  /// then fails on its next step, and nothing new is started.
  Future<void> halt() async {
    if (_halted) return;
    _halted = true;
    _haltSignal.complete();
    for (final session in _sessions.toList()) {
      await _stopSession(session);
    }
    await close();
  }

  Future<void> close() async {
    _deadlineTimer.cancel();
    final lease = _lease;
    _lease = null;
    await lease?.release();
  }
}

/// One call from its arrival to its answer, so it can be abandoned while it
/// waits for a slot or runs: [abandon] stops its work on the server and
/// answers it at once.
class _Ticket {
  _Ticket(this.clientId);

  final String clientId;
  final Completer<String> _abandoned = Completer<String>();
  _Call? call;

  bool get isAbandoned => _abandoned.isCompleted;

  /// Completes with the reason when the call is abandoned; never errors.
  Future<String> get abandoned => _abandoned.future;

  void abandon(String reason) {
    if (_abandoned.isCompleted) return;
    _abandoned.complete(reason);
    final running = call;
    if (running != null) unawaited(running.halt());
  }
}

/// Validates one call's arguments against what its tool accepts.
class _Args {
  _Args(this._raw, Set<String> allowed) {
    for (final key in _raw.keys) {
      if (!allowed.contains(key)) {
        throw _Refused(
          BridgeToolRefusals.invalid('unknown argument "${_clip(key)}".'),
        );
      }
    }
  }

  final Map<String, Object?> _raw;

  static String _clip(String text) {
    final printable = text.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '?');
    return printable.length <= 40
        ? printable
        : '${printable.substring(0, 40)}…';
  }

  static Never _bad(String why) =>
      throw _Refused(BridgeToolRefusals.invalid(why));

  static final RegExp _controls = RegExp(r'[\x00\n\r]');

  String? string(String key, {required int maxBytes, bool required = true}) {
    final value = _raw[key];
    if (value == null) {
      if (required) _bad('$key is required.');
      return null;
    }
    if (value is! String) _bad('$key must be a string.');
    if (value.isEmpty) _bad('$key must not be empty.');
    if (utf8.encode(value).length > maxBytes) {
      _bad('$key is longer than $maxBytes bytes.');
    }
    if (_controls.hasMatch(value)) {
      _bad('$key must not contain a NUL or a line break.');
    }
    return value;
  }

  int integer(
    String key, {
    required int min,
    required int max,
    required int fallback,
  }) {
    final value = _raw[key];
    if (value == null) return fallback;
    final int? whole = switch (value) {
      int v => v,
      double v when v.isFinite && v == v.truncateToDouble() => v.toInt(),
      _ => null,
    };
    if (whole == null || whole < min || whole > max) {
      _bad('$key must be a whole number from $min to $max.');
    }
    return whole;
  }

  /// A remote path as an assistant may give it: absolute, or relative to
  /// the account's home directory (`~/x` meaning the same as `x`).
  String path(String key) {
    final value = string(key, maxBytes: BridgePathGuard.maxPathBytes)!;
    if (value == '~') return '.';
    if (value.startsWith('~/')) {
      return value.substring(2).isEmpty ? '.' : value.substring(2);
    }
    if (value.startsWith('~')) _bad('$key: "~user" paths are not supported.');
    return value;
  }
}

class _Tool {
  const _Tool({
    required this.spec,
    required this.takesHost,
    required this.arguments,
    required this.run,
  });

  final BridgeToolSpec spec;
  final bool takesHost;
  final Set<String> arguments;
  final Future<_Outcome> Function(_Call call, _Args args) run;
}

/// Lets at most [maxRunning] calls run at once and [maxWaiting] wait.
class _Gate {
  _Gate({required this.maxRunning, required this.maxWaiting});

  final int maxRunning;
  final int maxWaiting;
  var _running = 0;
  final Queue<Completer<void>> _waiting = Queue();

  int get running => _running;
  int get waiting => _waiting.length;

  /// Runs [work] once a slot is free, within [timeout] of being asked,
  /// waiting included. Throws [_Refused] (busy) when the queue is full and
  /// [TimeoutException] past the deadline. The slot is given back when the
  /// deadline passes even if [work] has not finished, so a server that hangs
  /// cannot hold the bridge shut; every step inside is bounded as well.
  Future<T> run<T>(
    Future<T> Function() work, {
    required Duration timeout,
  }) async {
    final watch = Stopwatch()..start();
    if (_running >= maxRunning) {
      if (_waiting.length >= maxWaiting) {
        throw const _Refused(BridgeToolRefusals.busy);
      }
      final turn = Completer<void>();
      _waiting.add(turn);
      try {
        await turn.future.timeout(timeout);
      } on TimeoutException {
        _waiting.remove(turn);
        rethrow;
      }
      // The slot was handed over by [_release]; [_running] already counts it.
    } else {
      _running++;
    }
    try {
      final left = timeout - watch.elapsed;
      return await Future.sync(
        work,
      ).timeout(left.isNegative ? Duration.zero : left);
    } finally {
      _release();
    }
  }

  void _release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete();
    } else {
      _running--;
    }
  }
}

/// The AI Bridge's read tools.
///
/// **One way in.** [call] is the only entry, and it does the same five
/// things for every tool in the same order: resolve the host name, ask
/// [decideBridgeCall], run, redact, audit. A tool body is handed a [_Call]
/// that the dispatcher builds only after the policy allowed it, and that
/// object is the only thing in this file holding a route to a server. There
/// is no per-tool policy check to forget.
///
/// **No command text from the assistant.** Every command is a fixed template
/// ([BridgeCommands], [SystemdCommands], [ServerProbeCommands],
/// [LogTailCommands]); assistant values are validated, then quoted.
class BridgeTools implements BridgeToolHost {
  BridgeTools({
    required this.loadHosts,
    required this.settings,
    required this.isAppLocked,
    required this.connections,
    required this.redactor,
    required this.audit,
    this.directory = const BridgeHostDirectory(),
    this.callTimeout = const Duration(seconds: 30),
    int maxRunning = 4,
    int maxWaiting = 32,
  }) : _gate = _Gate(maxRunning: maxRunning, maxWaiting: maxWaiting) {
    _tools = {for (final t in _buildTools()) t.spec.name: t};
  }

  final Future<List<Host>> Function() loadHosts;

  /// Read at the start of every call, so a settings change applies to the
  /// next call without restarting anything.
  final AppSettings Function() settings;
  final bool Function() isAppLocked;
  final BridgeConnections connections;
  final BridgeRedactor redactor;
  final BridgeAuditLog audit;
  final BridgeHostDirectory directory;
  final Duration callTimeout;
  final _Gate _gate;
  late final Map<String, _Tool> _tools;

  static const int defaultTailLines = 100;
  static const int maxTailLines = 500;
  static const int maxReadBytes = 64 * 1024;
  static const int defaultSearchResults = 50;
  static const int maxSearchResults = 200;
  static const int defaultSearchDepth = 4;
  static const int maxSearchDepth = 8;
  static const int maxListEntries = 1000;
  static const int maxHostNameBytes = 256;

  /// Calls running now and waiting, for tests.
  int get running => _gate.running;
  int get waiting => _gate.waiting;

  final Set<_Ticket> _tickets = {};

  /// Calls not yet answered, waiting or running.
  int get inFlight => _tickets.length;

  static const String revokedMessage =
      'This assistant was disconnected from SecureShell Go; the call was '
      'stopped.';
  static const String switchedOffMessage =
      'The AI Bridge was switched off; the call was stopped.';

  /// Stops every call of the paired client [clientId] — it was revoked —
  /// ending its work on the server. Each still gets its one audit entry.
  void abandonClient(String clientId, {String reason = revokedMessage}) {
    for (final t in _tickets.toList()) {
      if (t.clientId == clientId) t.abandon(reason);
    }
  }

  /// Stops every call — the bridge was switched off.
  void abandonAll({String reason = switchedOffMessage}) {
    for (final t in _tickets.toList()) {
      t.abandon(reason);
    }
  }

  @override
  List<BridgeToolSpec> get tools => [for (final t in _tools.values) t.spec];

  static final RegExp _unitName = RegExp(
    r'^[A-Za-z0-9_.@:\\][A-Za-z0-9_.@:\\-]*$',
  );

  @override
  Future<BridgeToolResult> call(
    BridgeClient client,
    String name,
    Map<String, Object?> args,
  ) async {
    final watch = Stopwatch()..start();
    final hostArg = args['host'];
    final ticket = _Ticket(client.id);
    _tickets.add(ticket);
    _Outcome outcome;
    try {
      // Whichever comes first: the answer, or the call being abandoned. An
      // abandoned call's work has been halted; if it was still waiting for
      // a slot it returns at once when it gets one.
      outcome = await Future.any([
        _gate.run(() => _dispatch(name, args, ticket), timeout: callTimeout),
        ticket.abandoned.then(_Outcome.error),
      ]);
    } on _Refused catch (e) {
      outcome = _Outcome.refused(e.refusal);
    } on TimeoutException {
      outcome = _Outcome.error(
        'The call took longer than ${callTimeout.inSeconds} seconds and was '
        'stopped.',
      );
    } catch (_) {
      outcome = _Outcome.error('$name failed unexpectedly.');
    } finally {
      _tickets.remove(ticket);
    }
    if (ticket.isAbandoned &&
        outcome.outcome != BridgeAuditOutcome.error) {
      // Abandoned as it finished: what it found is not sent anywhere.
      outcome = _Outcome.error(await ticket.abandoned);
    }

    String text;
    try {
      text = redactor.redact(outcome.text, keepTail: outcome.keepTail);
    } catch (_) {
      // Never the raw output: if it cannot be cleaned, it does not leave.
      outcome = const _Outcome.error(
        'The output could not be made safe to return.',
      );
      text = outcome.text;
    }

    // Never throws; a failed write is reported on the bridge screen instead.
    await audit.record(
      client: client.name,
      host: hostArg is String ? hostArg : null,
      tool: name,
      args: args,
      outcome: outcome.outcome,
      detail: outcome.detail,
      ms: watch.elapsedMilliseconds,
    );
    return BridgeToolResult(
      text,
      isError: outcome.outcome != BridgeAuditOutcome.ok,
    );
  }

  /// Resolve → decide → validate → run. The only place a [_Call] is made.
  Future<_Outcome> _dispatch(
    String name,
    Map<String, Object?> args,
    _Ticket ticket,
  ) async {
    if (ticket.isAbandoned) return _Outcome.error(await ticket.abandoned);
    final tool = _tools[name];
    if (tool == null) return _Outcome.refused(BridgeToolRefusals.unknownTool);

    final current = settings();
    Host? host;
    if (tool.takesHost) {
      final requested = args['host'];
      if (requested is String &&
          requested.isNotEmpty &&
          requested.length <= maxHostNameBytes) {
        host = directory.resolve(await loadHosts(), requested);
      }
    }
    final decision = decideBridgeCall(
      bridgeEnabled: current.bridgeEnabled,
      appLocked: isAppLocked(),
      host: host,
      hostRequired: tool.takesHost,
      kind: tool.spec.kind,
    );
    if (decision is BridgeRefuse) return _Outcome.refused(decision);

    final checked = _Args(args, tool.arguments);
    final call = _Call._(
      host: host,
      settings: current,
      connections: connections,
      deadline: DateTime.now().add(callTimeout),
    );
    ticket.call = call;
    if (ticket.isAbandoned) await call.halt();
    try {
      final outcome = await _run(tool, call, checked);
      if (outcome.outcome == BridgeAuditOutcome.error &&
          host != null &&
          !current.bridgeShowAddress) {
        return _Outcome.error(await _withoutAddress(outcome.text, host));
      }
      return outcome;
    } finally {
      await call.close();
    }
  }

  Future<_Outcome> _run(_Tool tool, _Call call, _Args checked) async {
    try {
      return await tool.run(call, checked);
    } on _Refused catch (e) {
      return _Outcome.refused(e.refusal);
    } on TimeoutException {
      rethrow;
    } on BridgeConnectFailure catch (e) {
      return _Outcome.error(e.message);
    } on SystemdUnavailable {
      return const _Outcome.error(SystemdUnavailable.message);
    } on MonitorFailure catch (e) {
      final details = e.details;
      return _Outcome.error(
        details == null ? e.message : '${e.message}\n$details',
      );
    } on SftpFailure catch (e) {
      return _Outcome.error(e.message);
    } on SftpStatusError catch (e) {
      return _Outcome.error('The server refused: ${e.message}');
    } catch (_) {
      // Never the exception's own text: it may carry an address.
      return _Outcome.error('${tool.spec.name} failed unexpectedly.');
    }
  }

  /// [text] with the host's address, port and user name taken out, and those
  /// of the jump hosts it goes through. Used on error text only, when "show
  /// address" is off: connection errors name `host:port` and the user, and
  /// a jump host can be one the user has not shared at all.
  Future<String> _withoutAddress(String text, Host host) async {
    final chain = <Host>[host];
    try {
      final all = await loadHosts();
      var next = host.jumpHostId;
      while (next != null && chain.length < 8) {
        final hop = all.where((h) => h.id == next).firstOrNull;
        if (hop == null || chain.contains(hop)) break;
        chain.add(hop);
        next = hop.jumpHostId;
      }
    } catch (_) {
      // The target's own details are still removed.
    }
    final hidden = <String, String>{};
    for (var i = 0; i < chain.length; i++) {
      final h = chain[i];
      hidden[h.target] = '[host]';
      hidden['${h.hostname}:${h.port}'] = '[host]';
      hidden[h.hostname] = '[host]';
      hidden[h.username] = '[user]';
      // The target's label is its name to the assistant; a hop's is not.
      if (i > 0) hidden[h.displayName] = '[host]';
    }
    var out = text;
    final needles = [
      for (final k in hidden.keys)
        if (k.trim().isNotEmpty) k,
    ]..sort((a, b) => b.length.compareTo(a.length));
    for (final needle in needles) {
      out = out.replaceAllMapped(
        RegExp(
          '(?<![A-Za-z0-9_])${RegExp.escape(needle)}(?![A-Za-z0-9_])',
          caseSensitive: false,
        ),
        (_) => hidden[needle]!,
      );
    }
    return out
        .replaceAll(RegExp(r'\b\d{1,3}(?:\.\d{1,3}){3}\b'), '[address]')
        .replaceAll(
          RegExp(r'\bport\s+\d+', caseSensitive: false),
          'port [port]',
        );
  }

  static Map<String, Object?> _schema(
    Map<String, Object?> properties, {
    List<String> required = const [],
  }) => {
    'type': 'object',
    'properties': properties,
    if (required.isNotEmpty) 'required': required,
    'additionalProperties': false,
  };

  static const Map<String, Object?> _hostProperty = {
    'type': 'string',
    'description': 'A host name exactly as list_hosts returns it.',
  };

  static const Map<String, Object?> _pathProperty = {
    'type': 'string',
    'description':
        'An absolute path on the server, or one relative to the home '
        'directory.',
  };

  List<_Tool> _buildTools() => [
    _Tool(
      spec: BridgeToolSpec(
        name: 'list_hosts',
        description:
            'Lists the servers the user has shared with the AI Bridge. '
            'Pass a returned name as "host" to the other tools.',
        inputSchema: _schema(const {}),
        kind: BridgeToolKind.read,
      ),
      takesHost: false,
      arguments: const {},
      run: _listHosts,
    ),
    _Tool(
      spec: BridgeToolSpec(
        name: 'server_stats',
        description:
            'Uptime, load, memory, root disk use, CPU count, kernel and '
            'hostname of a server.',
        inputSchema: _schema(const {'host': _hostProperty}, required: ['host']),
        kind: BridgeToolKind.read,
      ),
      takesHost: true,
      arguments: const {'host'},
      run: _serverStats,
    ),
    _Tool(
      spec: BridgeToolSpec(
        name: 'list_services',
        description: 'Lists the systemd services on a server with their state.',
        inputSchema: _schema(const {'host': _hostProperty}, required: ['host']),
        kind: BridgeToolKind.read,
      ),
      takesHost: true,
      arguments: const {'host'},
      run: _listServices,
    ),
    _Tool(
      spec: BridgeToolSpec(
        name: 'tail_log',
        description:
            'The last lines of a systemd unit\'s journal ("unit") or of a log '
            'file ("path"), once. Give exactly one of the two.',
        inputSchema: _schema(
          const {
            'host': _hostProperty,
            'unit': {
              'type': 'string',
              'description': 'A systemd unit name, e.g. nginx.service.',
            },
            'path': _pathProperty,
            'lines': {
              'type': 'integer',
              'minimum': 1,
              'maximum': maxTailLines,
              'default': defaultTailLines,
            },
          },
          required: ['host'],
        ),
        kind: BridgeToolKind.read,
      ),
      takesHost: true,
      arguments: const {'host', 'unit', 'path', 'lines'},
      run: _tailLog,
    ),
    _Tool(
      spec: BridgeToolSpec(
        name: 'list_dir',
        description: 'Lists one directory on a server.',
        inputSchema: _schema(
          const {'host': _hostProperty, 'path': _pathProperty},
          required: ['host', 'path'],
        ),
        kind: BridgeToolKind.read,
      ),
      takesHost: true,
      arguments: const {'host', 'path'},
      run: _listDir,
    ),
    _Tool(
      spec: BridgeToolSpec(
        name: 'read_file',
        description:
            'Reads part of a text file on a server: up to max_bytes from '
            'offset (default and most 65536 bytes). Binary files are refused.',
        inputSchema: _schema(
          const {
            'host': _hostProperty,
            'path': _pathProperty,
            'offset': {'type': 'integer', 'minimum': 0, 'default': 0},
            'max_bytes': {
              'type': 'integer',
              'minimum': 1,
              'maximum': maxReadBytes,
              'default': maxReadBytes,
            },
          },
          required: ['host', 'path'],
        ),
        kind: BridgeToolKind.read,
      ),
      takesHost: true,
      arguments: const {'host', 'path', 'offset', 'max_bytes'},
      run: _readFile,
    ),
    _Tool(
      spec: BridgeToolSpec(
        name: 'search_files',
        description:
            'Finds files by name (a shell pattern such as "*.conf") under a '
            'directory. Matches names only; never reads file contents.',
        inputSchema: _schema(
          const {
            'host': _hostProperty,
            'dir': _pathProperty,
            'name': {
              'type': 'string',
              'description': 'A file name pattern: * ? and [...] are allowed.',
            },
            'max_results': {
              'type': 'integer',
              'minimum': 1,
              'maximum': maxSearchResults,
              'default': defaultSearchResults,
            },
            'max_depth': {
              'type': 'integer',
              'minimum': 1,
              'maximum': maxSearchDepth,
              'default': defaultSearchDepth,
            },
          },
          required: ['host', 'dir', 'name'],
        ),
        kind: BridgeToolKind.read,
      ),
      takesHost: true,
      arguments: const {'host', 'dir', 'name', 'max_results', 'max_depth'},
      run: _searchFiles,
    ),
  ];

  Future<_Outcome> _listHosts(_Call call, _Args args) async {
    final entries = directory.list(
      await loadHosts(),
      showAddress: call.settings.bridgeShowAddress,
    );
    if (entries.isEmpty) {
      return const _Outcome.ok(
        'No hosts are shared with the AI Bridge. The user can switch on AI '
        'access for a host in SecureShell Go.',
      );
    }
    return _Outcome.ok(
      jsonEncode({
        'hosts': [for (final e in entries) e.toJson()],
      }),
    );
  }

  Future<_Outcome> _serverStats(_Call call, _Args args) async {
    final result = await call.exec(ServerProbeCommands.probe);
    final stats = parseServerStats(result.stdout);
    if (stats.isEmpty) {
      return const _Outcome.error(
        'This server did not answer any of the status commands.',
      );
    }
    final memory = stats.memory;
    final disk = stats.disk;
    final load = stats.load;
    return _Outcome.ok(
      jsonEncode({
        // The server's own name is very often the address it is dialled by.
        if (stats.hostname != null && call.settings.bridgeShowAddress)
          'hostname': stats.hostname,
        if (stats.kernel != null) 'kernel': stats.kernel,
        if (stats.uptime != null) 'uptime_seconds': stats.uptime!.inSeconds,
        if (load != null) 'load': [load.one, load.five, load.fifteen],
        if (stats.cpuCount != null) 'cpus': stats.cpuCount,
        if (memory != null)
          'memory': {
            'total_bytes': memory.total,
            'available_bytes': memory.available,
            'used_bytes': memory.used,
          },
        if (disk != null)
          'disk': {
            'mount': disk.mountPoint,
            'total_bytes': disk.total,
            'used_bytes': disk.used,
            'available_bytes': disk.available,
          },
      }),
    );
  }

  Future<_Outcome> _listServices(_Call call, _Args args) async {
    final probe = await call.exec(SystemdCommands.probe);
    if (!probe.succeeded) throw const SystemdUnavailable();
    final result = await call.exec(SystemdCommands.listUnits);
    if (!result.succeeded) {
      final stderr = result.stderr.toLowerCase();
      if (stderr.contains('has not been booted with systemd') ||
          stderr.contains('failed to connect to bus')) {
        throw const SystemdUnavailable();
      }
      throw monitorFailureFrom(result, 'Could not list services');
    }
    final units = parseServiceUnits(result.stdout);
    if (units.isEmpty) return const _Outcome.ok('No services are loaded.');
    final out = StringBuffer('unit\tactive\tsub\tdescription\n');
    for (final u in units) {
      out.writeln('${u.name}\t${u.active}\t${u.sub}\t${u.description}');
    }
    return _Outcome.ok(out.toString());
  }

  Future<_Outcome> _tailLog(_Call call, _Args args) async {
    final unit = args.string('unit', maxBytes: 256, required: false);
    final hasPath = args._raw['path'] != null;
    final lines = args.integer(
      'lines',
      min: 1,
      max: maxTailLines,
      fallback: defaultTailLines,
    );
    if ((unit == null) == !hasPath) {
      _Args._bad('give exactly one of unit or path.');
    }
    if (unit != null) {
      if (!_unitName.hasMatch(unit)) {
        _Args._bad('unit is not a systemd unit name.');
      }
      final probe = await call.exec(BridgeCommands.journalProbe);
      if (!probe.succeeded) {
        return const _Outcome.error(
          'journalctl is not available on this server.',
        );
      }
      final result = await call.exec(BridgeCommands.journal(unit, lines));
      if (!result.succeeded && result.stdout.trim().isEmpty) {
        throw monitorFailureFrom(result, 'Could not read the journal of $unit');
      }
      return _Outcome.ok(result.stdout, keepTail: true);
    }
    final path = await call.guardedPath(args.path('path'));
    final readable = await call.exec(LogTailCommands.probeReadable(path));
    if (!readable.succeeded) {
      return _Outcome.error('$path is not a readable file.');
    }
    final result = await call.exec(BridgeCommands.tailFile(path, lines));
    // The pipeline's status is the last `tail`'s, so the first one failing
    // shows only as stderr with nothing on stdout.
    if (!result.succeeded ||
        (result.stdout.isEmpty && result.stderr.trim().isNotEmpty)) {
      throw monitorFailureFrom(result, 'Could not read $path');
    }
    return _Outcome.ok(result.stdout, keepTail: true);
  }

  Future<_Outcome> _listDir(_Call call, _Args args) async {
    final path = await call.guardedPath(args.path('path'));
    final fs = await call.files();
    final entries = await call.bounded(fs.list(path));
    final out = StringBuffer('$path\n');
    // Each entry is judged by its own full path: a directory that may be
    // listed can still hold `.env` or `id_ed25519`. A blocked entry is
    // simply absent — no count, no note — so the listing does not say that
    // something blocked is there.
    final visible = [
      for (final entry in entries)
        if (!call.guard.isBlocked(_childPath(path, entry.name))) entry,
    ];
    for (final entry in visible.take(maxListEntries)) {
      out.writeln(_entryLine(entry));
    }
    final more = visible.length - maxListEntries;
    if (more > 0) out.writeln('[$more more entries not shown]');
    if (visible.isEmpty) out.writeln('[empty]');
    return _Outcome.ok(out.toString());
  }

  static String _childPath(String dir, String name) =>
      dir == '/' ? '/$name' : '$dir/$name';

  static String _entryLine(RemoteEntry entry) {
    final type = switch (entry.kind) {
      RemoteEntryKind.directory => 'dir ',
      RemoteEntryKind.symlink =>
        entry.linkTargetIsDirectory == true ? 'link/dir' : 'link',
      RemoteEntryKind.file => 'file',
      _ => 'other',
    };
    final size = entry.kind == RemoteEntryKind.file && entry.size != null
        ? '\t${entry.size}'
        : '\t-';
    final modified = entry.modified == null
        ? ''
        : '\t${entry.modified!.toUtc().toIso8601String()}';
    final name = entry.name.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '?');
    return '$type$size$modified\t$name';
  }

  Future<_Outcome> _readFile(_Call call, _Args args) async {
    final offset = args.integer('offset', min: 0, max: 1 << 52, fallback: 0);
    final maxBytes = args.integer(
      'max_bytes',
      min: 1,
      max: maxReadBytes,
      fallback: maxReadBytes,
    );
    final path = await call.guardedPath(args.path('path'));
    final fs = await call.files();
    final stat = await call.bounded(fs.stat(path));
    switch (stat.type) {
      case BridgeFileType.directory:
        return _Outcome.error('$path is a directory; use list_dir.');
      case BridgeFileType.other:
        return _Outcome.error('$path is not a regular file.');
      case BridgeFileType.file:
        break;
    }
    final size = stat.size;
    if (size != null && offset >= size && size > 0) {
      return _Outcome.ok(
        'path: $path\nsize: $size\n\n[offset is past the end]',
      );
    }
    final window = await call.bounded(
      fs.read(path, offset: offset, length: maxBytes),
    );
    // The sniff looks at the start of the file, as the editor's does, and at
    // the window itself: either holding a NUL means it is not text.
    var binary = looksBinary(window);
    if (!binary && offset > 0) {
      final head = await call.bounded(
        fs.read(path, offset: 0, length: editorBinarySniffBytes),
      );
      binary = looksBinary(head);
    }
    if (binary) {
      return _Outcome.error('$path looks like a binary file; it is not read.');
    }
    final end = offset + window.length;
    // /proc files report a size of 0 and still have content.
    final total = size == null || size < end ? end : size;
    final header = StringBuffer('path: $path\n')
      ..writeln('bytes: $offset-$end of $total');
    if (end < total) header.writeln('next_offset: $end');
    header.writeln();
    return _Outcome.ok('$header${utf8.decode(window, allowMalformed: true)}');
  }

  Future<_Outcome> _searchFiles(_Call call, _Args args) async {
    final pattern = args.string('name', maxBytes: 255)!;
    if (pattern.contains('/')) _Args._bad('name is a file name, not a path.');
    final maxResults = args.integer(
      'max_results',
      min: 1,
      max: maxSearchResults,
      fallback: defaultSearchResults,
    );
    final depth = args.integer(
      'max_depth',
      min: 1,
      max: maxSearchDepth,
      fallback: defaultSearchDepth,
    );
    final dir = await call.guardedPath(args.path('dir'));
    // Asked for more than will be shown, since blocked paths are dropped
    // after the fact.
    final limit = maxResults * 4 + 50;
    final result = await call.exec(
      BridgeCommands.findByName(dir, pattern, depth: depth, limit: limit),
    );
    final prefix = dir == '/' ? '/' : '$dir/';
    final found = <String>[];
    for (final line in const LineSplitter().convert(result.stdout)) {
      // Anything not under [dir] is a fragment of a name with a line break
      // in it, or not find's output at all. Blocked paths are dropped
      // without a trace, as in list_dir.
      if (!line.startsWith(prefix)) continue;
      if (call.guard.isBlocked(line)) continue;
      if (found.length < maxResults) found.add(line);
    }
    if (found.isEmpty) return const _Outcome.ok('No files found.');
    final out = StringBuffer();
    for (final p in found) {
      out.writeln(p);
    }
    if (found.length >= maxResults) {
      out.writeln('[stopped at $maxResults results]');
    }
    return _Outcome.ok(out.toString());
  }
}
