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
import 'bridge_approvals.dart';
import 'bridge_audit.dart';
import 'bridge_client_store.dart';
import 'bridge_connections.dart';
import 'bridge_grants.dart';
import 'bridge_host_directory.dart';
import 'bridge_paths.dart';
import 'bridge_policy.dart';
import 'bridge_redactor.dart';
import 'bridge_tool_module.dart';
import 'bridge_tool_types.dart';

/// The commands the read tools run, separate from execution so the quoting
/// can be asserted character for character. Every value that comes from an
/// assistant reaches the shell only through [posixSingleQuote]; numbers are
/// validated ints before they get here.
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
  /// returns, and the group is sent TERM, then, [stopGraceSeconds] later,
  /// KILL, so a command that ignores TERM is ended too. Closing an exec
  /// channel alone does not reliably stop a remote process that has no
  /// terminal. A TERM or HUP sent to the wrapper itself is passed on.
  ///
  /// The watcher ignores TERM and HUP, and tells the wrapper (USR1) that a
  /// stop has begun, so the wrapper no longer ends the watcher when the
  /// command's main process dies of the TERM: whatever is left in the group
  /// still gets the KILL. The app does not wait for that grace: it closes
  /// the channel at once, and the watcher, writing nowhere, carries on. A
  /// command that finishes on its own ends the watcher (KILL, since it
  /// ignores TERM), so what it left running in the background is left
  /// alone, as before. A process that leaves the group (`setsid`) is not
  /// reached; that is a documented limit.
  ///
  /// The exit status is the command's own whenever it ended by itself: a
  /// `wait` cut short by the watcher's USR1 (it returns above 128 at once
  /// when a trapped signal arrives) is repeated while the command's process
  /// is still there. A command that died of a signal has been reaped by
  /// then, so its status is kept; a zombie `kill -0` still sees is reaped
  /// by the next `wait`, so the loop cannot spin. Some shells have already
  /// collected the command by the time the cut-short `wait` returns, so
  /// `kill -0` finds nothing; one more `wait` then gives the status the
  /// shell kept. When the shell kept none (127), the first status stands
  /// for a command that ended by itself, and a stop that had begun counts
  /// as the stop's TERM. A stopped command's
  /// status is the stop's (143 for the TERM, 137 for the KILL).
  ///
  /// The app holds the channel's stdin open for the whole run and closes it
  /// only to stop the call: end-of-file on stdin *is* the stop signal, so a
  /// wrapper started with stdin already at end-of-file ends its command at
  /// once.
  ///
  /// The outer command is one `sh -c` with single-quoted arguments, which
  /// every login shell parses the same way; the template reaches the inner
  /// shell as `$1`, quoted once.
  static String supervised(String command) {
    const wrapper = r'''exec 3<&0
t=
w=
s=
ssg_pass() { if [ -n "$t" ]; then kill -s "$1" -- "$t" 2>/dev/null; fi; exit "$2"; }
trap 'ssg_pass TERM 143' TERM
trap 'ssg_pass HUP 129' HUP
trap 's=1' USR1
if command -v setsid >/dev/null 2>&1; then
  setsid /bin/sh -c "$1" 3<&- &
  p=$!
  t="-$p"
else
  /bin/sh -c "$1" 3<&- &
  p=$!
  t="$p"
fi
( trap '' TERM HUP; cat <&3 >/dev/null 2>&1; kill -s USR1 $$ 2>/dev/null; kill -s TERM -- "$t" 2>/dev/null; sleep 3; kill -s KILL -- "$t" 2>/dev/null ) >/dev/null 2>&1 &
w=$!
exec 3<&-
wait $p
r=$?
while [ "$r" -gt 128 ] && kill -0 $p 2>/dev/null; do wait $p; r=$?; done
if [ "$r" -gt 128 ]; then wait $p 2>/dev/null; q=$?; if [ "$q" -ne 127 ]; then r=$q; elif [ -n "$s" ]; then r=143; fi; fi
if [ -z "$s" ]; then kill -s KILL $w 2>/dev/null; fi
exit $r''';
    return 'sh -c ${posixSingleQuote(wrapper)} ssg-bridge '
        '${loginShellQuote(command)}';
  }

  /// [value] as one word for any login shell's command line, not only the
  /// POSIX ones. [posixSingleQuote] is exact for sh, bash and zsh, but fish
  /// reads `\\` and `\'` inside single quotes as escapes, so a command
  /// with a backslash — worst, one ending in a backslash — would come out
  /// changed, or end its quotes early. Here no backslash is ever inside
  /// single quotes: a quote is `'\''` (a backslash outside any quotes) and a
  /// backslash is `'"\\"'` (double quotes, where `\\` is a backslash in
  /// sh, bash, zsh and fish alike). For a value with no backslash the result
  /// is exactly [posixSingleQuote]'s.
  static String loginShellQuote(String value) =>
      "'${value.replaceAllMapped(RegExp(r"['\\]"), (m) => m[0] == "'" ? "'\\''" : "'\"\\\\\"'")}'";

  /// Seconds between the TERM and the KILL a stopped command's process
  /// group gets (the `sleep` in [supervised]).
  static const int stopGraceSeconds = 3;

  /// The most of each output stream of one command the app keeps (the
  /// newest part); see `_Call.exec`.
  static const int maxExecOutputBytes = 1024 * 1024;

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
      detail = '',
      image = null,
      imageMimeType = null;

  const _Outcome.image(
    Uint8List this.image,
    String this.imageMimeType,
    this.text,
  ) : outcome = BridgeAuditOutcome.ok,
      detail = '',
      keepTail = false;

  /// A tool's own result: ok (with its image, if any) or an error.
  factory _Outcome.fromResult(BridgeToolResult result) {
    final image = result.image;
    if (result.isError) return _Outcome.error(result.text);
    if (image != null) {
      return _Outcome.image(image, result.imageMimeType!, result.text);
    }
    return _Outcome.ok(result.text);
  }

  _Outcome.refused(BridgeRefuse refusal)
    : text = refusal.message,
      outcome = BridgeAuditOutcome.refused,
      detail = refusal.code,
      keepTail = false,
      image = null,
      imageMimeType = null;

  /// [stopped] ended a call the user had approved before it ran: refused,
  /// with the reason after a fixed prefix the activity screen can rely on.
  _Outcome.refusedAfterApproval(_Outcome stopped)
    : text = stopped.text,
      outcome = BridgeAuditOutcome.refused,
      detail = '${BridgeTools.refusedAfterApprovalPrefix}${stopped.detail}',
      keepTail = false,
      image = null,
      imageMimeType = null;

  const _Outcome.error(this.text)
    : outcome = BridgeAuditOutcome.error,
      detail = text,
      keepTail = false,
      image = null,
      imageMimeType = null;

  final String text;
  final BridgeAuditOutcome outcome;
  final String detail;
  final bool keepTail;

  /// A screenshot, say; sent as it is (text is redacted, an image cannot
  /// be).
  final Uint8List? image;
  final String? imageMimeType;
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

  /// [BridgeApprovals.maxPending] changes are already waiting for the user.
  static const BridgeRefuse approvalsBusy = BridgeRefuse(
    'approvals_busy',
    'Too many changes are already waiting for the user to answer. Wait for '
        'those to be answered, then try again.',
  );

  /// The user said no on the card. Not to be rephrased and retried.
  static const BridgeRefuse denied = BridgeRefuse(
    'approval_denied',
    'The user denied this change. Do not retry it or ask for it another '
        'way unless the user asks you to.',
  );

  /// Nobody answered the card in time; silence is a no.
  static const BridgeRefuse approvalTimedOut = BridgeRefuse(
    'approval_timed_out',
    'The user did not answer in time, so the change was not made. Do not '
        'retry it unless the user asks you to.',
  );

  /// The card was taken away by the app (the app was locked, say) and
  /// nothing more specific applies by the time the call is answered.
  static const BridgeRefuse approvalWithdrawn = BridgeRefuse(
    'approval_withdrawn',
    'The request was withdrawn before the user answered, so the change was '
        'not made.',
  );

  static BridgeRefuse invalid(String why) =>
      BridgeRefuse('invalid_arguments', 'Invalid arguments: $why');

  /// A client paired as a phone controller tried to call a tool. Its
  /// pairing can answer approval cards; it can never run anything itself.
  static const BridgeRefuse notAnAssistant = BridgeRefuse(
    'not_an_assistant',
    'This pairing is a remote control, not an assistant: it cannot call '
        'tools.',
  );

  /// A module tool returned a result without a policy allow (a bug in the
  /// module); nothing it produced is sent.
  static const BridgeRefuse notDecided = BridgeRefuse(
    'not_decided',
    'The call was stopped because it was not checked against the user\'s '
        'settings. This is a bug in SecureShell Go.',
  );
}

/// One allowed call's context: the host the policy allowed, the settings it
/// was allowed under, and the only way to the server. Built by the
/// dispatcher after [decideBridgeCall] said yes, and by nothing else — a
/// tool body has no other route to a connection.
class _Call implements BridgeCallContext {
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

  @override
  final Host? host;
  @override
  final AppSettings settings;
  @override
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
  @override
  Future<T> bounded<T>(Future<T> work) => Future.any<T>([
    work,
    _haltSignal.future.then<T>((_) => throw TimeoutException('halted')),
  ]).timeout(remaining);

  /// Runs one fixed command under [BridgeCommands.supervised], within the
  /// call's time. Opening the channel is bounded too, and a channel that
  /// opens after the deadline is ended as soon as it arrives. However the
  /// command ends — finished, out of time, or [halt]ed — its stdin is
  /// closed (which ends the remote process group) and the channel with it.
  @override
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

  /// The most of each stream a command keeps in memory: the newest
  /// [BridgeCommands.maxExecOutputBytes]. A command the assistant typed can
  /// print without end, and must not fill the app's memory; the rest of the
  /// output is still read (and dropped) so the command is never blocked on
  /// a full pipe.
  static void _keepTail(BytesBuilder into, List<int> chunk) {
    into.add(chunk);
    const cap = BridgeCommands.maxExecOutputBytes;
    if (into.length > 2 * cap) {
      final all = into.takeBytes();
      into.add(Uint8List.sublistView(all, all.length - cap));
    }
  }

  static Uint8List _tailOf(BytesBuilder from) {
    final all = from.takeBytes();
    const cap = BridgeCommands.maxExecOutputBytes;
    return all.length <= cap
        ? all
        : Uint8List.sublistView(all, all.length - cap);
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
      (chunk) => _keepTail(out, chunk),
      onDone: () => complete(outDone),
      onError: (Object _) => complete(outDone),
      cancelOnError: false,
    );
    session.stderr.listen(
      (chunk) => _keepTail(err, chunk),
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
      stdout: utf8.decode(_tailOf(out), allowMalformed: true),
      stderr: utf8.decode(_tailOf(err), allowMalformed: true),
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

  @override
  Future<BridgeFiles> files() async {
    final lease = await _leaseNow();
    _checkLive();
    return bounded(lease.files());
  }

  /// [raw] resolved on the server, symlinks and all, then put to the guard.
  /// The one way a path argument becomes a path a tool may use: a refusal
  /// for a blocked path and for one the server cannot resolve read the same.
  @override
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

  @override
  bool get isStopped => _halted || remaining == Duration.zero;

  /// Set by the dispatcher: told of each [commit] as it starts.
  void Function(Future<_CommitEnd> end)? onCommit;

  /// [commit]s not yet finished; [close] waits for them (up to
  /// [BridgeTools.commitGrace]) before it closes the call's channels.
  final Set<Future<void>> _commits = {};

  @override
  Future<BridgeToolResult> commit(
    Future<BridgeToolResult> Function() work, {
    required String ifStopped,
  }) async {
    final end = Completer<_CommitEnd>();
    onCommit?.call(end.future);
    if (isStopped) {
      end.complete(_CommitEnd(notDone: ifStopped));
      throw TimeoutException('halted');
    }
    final running = Future.sync(work);
    final settled = running.then<void>((_) {}, onError: (Object _) {});
    _commits.add(settled);
    try {
      final result = await running;
      end.complete(_CommitEnd(done: result));
      return result;
    } on BridgeStoppedBeforeChange {
      end.complete(_CommitEnd(notDone: ifStopped));
      rethrow;
    } catch (_) {
      if (!end.isCompleted) end.complete(const _CommitEnd());
      rethrow;
    } finally {
      _commits.remove(settled);
    }
  }

  Future<void> close() async {
    _deadlineTimer.cancel();
    if (_commits.isNotEmpty) {
      // A change that has begun to take effect is let finish, on its open
      // channel, rather than cut in half.
      await Future.wait(
        _commits.toList(),
      ).timeout(BridgeTools.commitGrace, onTimeout: () => const []);
    }
    final lease = _lease;
    _lease = null;
    await lease?.release();
  }
}

/// How a [BridgeCallContext.commit] ended: with the call's result (the
/// change took effect), with what was not done (stopped before it took
/// effect), or with neither (it failed; the tool's own error stands).
class _CommitEnd {
  const _CommitEnd({this.done, this.notDone});

  final BridgeToolResult? done;
  final String? notDone;
}

/// Thrown from inside a [BridgeCallContext.commit] when the call was
/// stopped before the change took effect; the commit's `ifStopped` text is
/// then added to the stopped call's answer.
class BridgeStoppedBeforeChange implements Exception {
  const BridgeStoppedBeforeChange();

  @override
  String toString() => 'stopped before the change took effect';
}

/// One call from its arrival to its answer, so it can be abandoned while it
/// waits for a slot or runs: [abandon] stops its work on the server and
/// answers it at once.
class _Ticket {
  _Ticket(this.clientId);

  final String clientId;
  final Completer<String> _abandoned = Completer<String>();
  _Call? call;

  /// The host the audit entry names when the call has no `host` argument
  /// (a terminal-use call names its terminal; this is that terminal's host,
  /// set only for a terminal of the calling client).
  String? auditHost;

  /// How a change was allowed, or why not, for the audit entry. Set to
  /// `withdrawn` while a card waits, so a call abandoned then is recorded
  /// as withdrawn.
  BridgeAuditApproval approval = BridgeAuditApproval.none;

  /// Where the card's answer came from when not this computer (a paired
  /// phone, `controller:<name>`), for the audit entry.
  String? via;

  /// True from the user's yes until the change starts running. A call that
  /// ends in between (refused by the re-check, revoked, cancelled, the bridge
  /// switched off, no run slot) is audited as refused after approval, so the
  /// activity list never reads as if it ran.
  bool awaitingRun = false;

  /// The per-host calls of a multi-host change running now, halted with
  /// [call] when the call is abandoned.
  final Set<_Call> hostCalls = {};

  /// The run's own time limit when a change asked for one
  /// ([BridgeChangePlan.runTimeout]); the timeout message names it.
  Duration? runTimeout;

  /// The change's [BridgeCallContext.commit], once one has begun: when it
  /// took effect, that is the call's answer whatever else happened.
  Future<_CommitEnd>? commit;

  bool get isAbandoned => _abandoned.isCompleted;

  /// Completes with the reason when the call is abandoned; never errors.
  Future<String> get abandoned => _abandoned.future;

  void abandon(String reason) {
    if (_abandoned.isCompleted) return;
    _abandoned.complete(reason);
    final running = call;
    if (running != null) unawaited(running.halt());
    for (final c in hostCalls.toList()) {
      unawaited(c.halt());
    }
  }
}

/// What a tool body may do with one allowed call: the host and settings it
/// was allowed under, and the only route to the server (every step bounded
/// by the call's deadline and given up when the call is halted). Built by
/// the dispatcher and by nothing else.
abstract interface class BridgeCallContext {
  Host? get host;
  AppSettings get settings;
  BridgePathGuard get guard;

  /// One fixed command under [BridgeCommands.supervised].
  Future<ExecResult> exec(String command);
  Future<BridgeFiles> files();

  /// [raw] resolved on the server and put to the path guard; a blocked path
  /// and one that cannot be resolved are refused the same way.
  Future<String> guardedPath(String raw);
  Future<T> bounded<T>(Future<T> work);

  /// Whether the call has been stopped (past its deadline, cancelled,
  /// revoked, the bridge switched off).
  bool get isStopped;

  /// Runs [work], the step that makes a change take effect, so that a stop
  /// cannot cut it in half: it is not given up when the call is stopped,
  /// and the call's channels stay open until it ends (at most
  /// [BridgeTools.commitGrace] after the stop). [work] checks [isStopped]
  /// up to its point of no return and throws [BridgeStoppedBeforeChange]
  /// if stopped by then (cleaning up after itself on the open channel);
  /// once past it, it finishes. When [work] returns, its result is the
  /// call's answer and audit outcome, even if the call was stopped
  /// meanwhile. [ifStopped] says what was left untouched, and is added to
  /// the answer of a call stopped before [work] took effect (also when it
  /// was stopped before [work] began). At most one per call.
  Future<BridgeToolResult> commit(
    Future<BridgeToolResult> Function() work, {
    required String ifStopped,
  });
}

/// What a change tool's [BridgeChangeTool.plan] is handed: the host the
/// policy has not refused, and a way to look at the server before the card
/// is shown (to say whether a file would be replaced, say).
abstract interface class BridgePlanContext {
  BridgeClient get client;
  Host get host;

  /// The host's name as the assistant gave it (its bridge name).
  String get hostName;

  /// Every host name the call named, in the order given: `[hostName]` for
  /// a single-host tool, the whole `hosts` list for a multi-host one (whose
  /// [host] and [hostName] are then the first).
  List<String> get hostNames;
  AppSettings get settings;

  /// Runs [body] as a read: in one of the run slots, within the call's
  /// deadline, halted if the call is abandoned. Nothing it does may change
  /// the server; the change itself runs only after the decision.
  Future<T> withServer<T>(Future<T> Function(BridgeCallContext call) body);
}

/// What a change tool worked out about one call before anyone is asked:
/// the card's [summary], built from the validated arguments, and whether the
/// call is on the host's allowed list. Subclass it to carry validated values
/// on to [BridgeChangeTool.run].
class BridgeChangePlan {
  const BridgeChangePlan({
    required this.summary,
    this.matchesAllowedCommand = false,
    this.runTimeout,
  });

  final BridgeChangeSummary summary;

  /// Only `run_command` on a single host may set this, and only from
  /// [bridgeCommandIsAllowed]. Ignored for a terminal.
  final bool matchesAllowedCommand;

  /// How long the run may take, connecting included, when it is not the
  /// dispatcher's usual call timeout (`run_command`'s `timeout_seconds`).
  /// For a multi-host tool it is each host's limit. Capped at
  /// [BridgeTools.maxRunTimeout].
  final Duration? runTimeout;
}

/// How one host's part of a multi-host change ended, for
/// [BridgeChangeTool.combine]. [text] is the host run's result, or the
/// error (connection failure, timeout) that stopped it.
class BridgeHostOutcome {
  const BridgeHostOutcome({
    required this.hostName,
    required this.text,
    required this.isError,
  });

  final String hostName;
  final String text;
  final bool isError;
}

/// A tool of kind [BridgeToolKind.change], [BridgeToolKind.terminal] or
/// [BridgeToolKind.desktop], as the dispatcher runs it. It takes `host`, or, when [combine] is set, a
/// list `hosts` instead (a multi-host change: see `_changeOnHosts`).
///
/// The dispatcher does, in order: resolve the host → policy (no card for a
/// refusal) → [plan] (argument validation and the summary; no card when it
/// fails) → policy again with the grant and [BridgeChangePlan.
/// matchesAllowedCommand] → the card when needed → policy again after a yes
/// → [run] in a run slot under the call deadline → redact → audit.
class BridgeChangeTool {
  BridgeChangeTool({
    required this.spec,
    required this.arguments,
    required this.plan,
    required this.run,
    this.auditArgs,
    this.combine,
    this.hostsAtOnce = 3,
  }) {
    if (spec.kind != BridgeToolKind.change &&
        spec.kind != BridgeToolKind.terminal &&
        spec.kind != BridgeToolKind.desktop) {
      throw ArgumentError.value(spec.kind, 'spec.kind', 'not a change tool');
    }
    if (combine == null) {
      if (!arguments.contains('host')) {
        throw ArgumentError.value(arguments, 'arguments', 'must take "host"');
      }
    } else {
      if (spec.kind != BridgeToolKind.change ||
          !arguments.contains('hosts') ||
          arguments.contains('host') ||
          hostsAtOnce < 1) {
        throw ArgumentError.value(
          arguments,
          'arguments',
          'a multi-host change takes "hosts" and not "host"',
        );
      }
    }
  }

  /// Set for a multi-host change: [run] is called once per host (with that
  /// host's context, at most [hostsAtOnce] at a time) and this turns the
  /// per-host outcomes, in the order the hosts were named, into the result.
  final BridgeToolResult Function(
    List<BridgeHostOutcome> outcomes,
    BridgeChangePlan plan,
  )?
  combine;

  /// For a multi-host change: how many hosts run at once.
  final int hostsAtOnce;

  bool get isMultiHost => combine != null;

  final BridgeToolSpec spec;

  /// The argument names it accepts; anything else is refused.
  final Set<String> arguments;

  /// Validates [args] (throwing through [BridgeToolArgs] on bad input) and
  /// builds the plan. Must not change the server.
  final Future<BridgeChangePlan> Function(
    BridgeToolArgs args,
    BridgePlanContext context,
  )
  plan;

  /// Makes the change. Only called after the call was allowed.
  final Future<BridgeToolResult> Function(
    BridgeCallContext call,
    BridgeChangePlan plan,
  )
  run;

  /// The arguments as the audit log should record them (`write_file`
  /// records the path and the byte count, never the content). The raw
  /// arguments when null.
  final Map<String, Object?> Function(Map<String, Object?> args)? auditArgs;
}

/// What a [BridgeTerminalUseTool] call's `terminal_id` names, found only
/// among the CALLING client's terminals.
class BridgeTerminalTarget {
  const BridgeTerminalTarget({
    required this.host,
    required this.hostName,
    required this.live,
  });

  /// The host as it was when the terminal was opened: the dispatcher hands
  /// the policy the host as it is now only while it is still the same
  /// server.
  final Host host;

  /// The host's name as the assistant gave it when it opened the terminal,
  /// for the audit entry.
  final String hostName;

  /// Still the assistant's to use: open, not taken over by the user, not
  /// stopped or closed.
  final bool live;
}

/// A tool of kind [BridgeToolKind.terminalUse]: it types into, reads or
/// closes a terminal an approved `open_terminal` opened. It takes
/// `terminal_id`, never `host`.
///
/// The dispatcher does, in order: [find] the terminal among the calling
/// client's own → read the hosts → [decideBridgeCall] with
/// `ownsLiveTerminal` (no argument is looked at before this, and an unknown
/// id and another client's id are refused alike) → validate the arguments
/// → [run] in a run slot under the call deadline → redact → audit.
class BridgeTerminalUseTool {
  BridgeTerminalUseTool({
    required this.spec,
    required this.arguments,
    required this.find,
    required this.run,
    this.refused,
    this.auditArgs,
  }) {
    if (spec.kind != BridgeToolKind.terminalUse) {
      throw ArgumentError.value(spec.kind, 'spec.kind', 'not terminal use');
    }
    if (!arguments.contains('terminal_id') || arguments.contains('host')) {
      throw ArgumentError.value(
        arguments,
        'arguments',
        'must take "terminal_id" and not "host"',
      );
    }
  }

  final BridgeToolSpec spec;

  /// The argument names it accepts; anything else is refused.
  final Set<String> arguments;

  /// The terminal [terminalId] names, or null unless it is one [clientId]
  /// opened. Must not reveal another client's terminal in any way.
  final BridgeTerminalTarget? Function(String clientId, String terminalId)
  find;

  /// Does the work, only after the policy allowed it. [host] is the
  /// terminal's host as it is now.
  final Future<BridgeToolResult> Function(
    String clientId,
    String terminalId,
    Host host,
    BridgeToolArgs args,
  )
  run;

  /// Told when the policy refused a call naming one of the caller's OWN
  /// terminals (never for an unknown or another client's id); returns the
  /// refusal to give, which may say more (the user took it over, say), and
  /// closes the terminal when the refusal means it may not go on.
  final BridgeRefuse Function(
    String clientId,
    String terminalId,
    BridgeRefuse refusal,
  )?
  refused;

  /// The arguments as the audit log should record them; the raw arguments
  /// when null.
  final Map<String, Object?> Function(Map<String, Object?> args)? auditArgs;
}

class _PlanContext implements BridgePlanContext {
  _PlanContext(
    this._withServer, {
    required this.client,
    required this.host,
    required this.hostName,
    required this.settings,
    List<String>? hostNames,
  }) : hostNames = List.unmodifiable(hostNames ?? [hostName]);

  @override
  final BridgeClient client;
  @override
  final Host host;
  @override
  final String hostName;
  @override
  final List<String> hostNames;
  @override
  final AppSettings settings;
  final Future<T> Function<T>(Future<T> Function(BridgeCallContext))
  _withServer;

  @override
  Future<T> withServer<T>(Future<T> Function(BridgeCallContext call) body) =>
      _withServer<T>(body);
}

/// Validates one call's arguments against what its tool accepts.
class BridgeToolArgs {
  BridgeToolArgs(this._raw, Set<String> allowed) {
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

  /// The raw value of [key], for a tool whose argument needs a check of its
  /// own (a command or file content may hold line breaks, which [string]
  /// refuses). The key is already known to be one the tool accepts.
  Object? operator [](String key) => _raw[key];

  /// Refuses the call as `invalid_arguments` with [why].
  static Never reject(String why) => _bad(why);

  /// Refuses the call with [refusal] (for a tool's own path checks, so a
  /// refusal reads exactly as the read tools' do).
  static Never refuse(BridgeRefuse refusal) => throw _Refused(refusal);

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
  final Future<_Outcome> Function(_Call call, BridgeToolArgs args) run;
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
///
/// **Changes wait for a person.** A [BridgeChangeTool] goes through the same
/// entry, with the order of checks documented on [_change]: the policy
/// first (no card for a refused or hidden host), then the tool's own
/// validation and summary (no card for bad arguments), then, when the
/// policy says so, a card through [approvals], outside the run gate and the
/// run deadline. A cancelled call ([BridgeCallToken]) is abandoned like a
/// revoked one.
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
    int maxChangeRunning = 2,
    int? maxChangeWaiting,
    BridgeApprovals? approvals,
    BridgeGrants? grants,
    List<BridgeChangeTool> changeTools = const [],
    List<BridgeTerminalUseTool> terminalUseTools = const [],
    List<BridgeToolModule> modules = const [],
    bool Function()? builtinAssistantEnabled,
  }) : builtinAssistantEnabled = builtinAssistantEnabled ?? _off,
       modules = List.unmodifiable(modules),
       _gate = _Gate(maxRunning: maxRunning, maxWaiting: maxWaiting),
       _changeGate = _Gate(
         maxRunning: maxChangeRunning,
         maxWaiting: maxChangeWaiting ?? maxWaiting,
       ),
       approvals =
           approvals ??
           BridgeApprovals(
             timedApprovalMinutes: () => settings().bridgeTimedApprovalMinutes,
           ),
       grants = grants ?? BridgeGrants() {
    _tools = {for (final t in _buildTools()) t.spec.name: t};
    for (final t in changeTools) {
      final name = t.spec.name;
      if (_tools.containsKey(name) || _changeTools.containsKey(name)) {
        throw ArgumentError.value(name, 'changeTools', 'duplicate tool name');
      }
      _changeTools[name] = t;
    }
    for (final t in terminalUseTools) {
      final name = t.spec.name;
      if (_tools.containsKey(name) ||
          _changeTools.containsKey(name) ||
          _terminalUseTools.containsKey(name)) {
        throw ArgumentError.value(
          name,
          'terminalUseTools',
          'duplicate tool name',
        );
      }
      _terminalUseTools[name] = t;
    }
    bool taken(String name) =>
        _tools.containsKey(name) ||
        _changeTools.containsKey(name) ||
        _terminalUseTools.containsKey(name) ||
        _moduleTools.containsKey(name);
    for (final module in modules) {
      for (final t in module.changeTools) {
        final name = t.spec.name;
        if (taken(name)) {
          throw ArgumentError.value(name, 'modules', 'duplicate tool name');
        }
        _changeTools[name] = t;
      }
      for (final spec in module.specs) {
        final name = spec.name;
        if (taken(name)) {
          throw ArgumentError.value(name, 'modules', 'duplicate tool name');
        }
        // A card is only ever asked through the change path, so a module
        // may serve directly only what never needs one.
        if (!_moduleKinds.contains(spec.kind)) {
          throw ArgumentError.value(
            spec.kind,
            'modules',
            '"$name": a ${spec.kind.name} tool must be a BridgeChangeTool',
          );
        }
        _moduleTools[name] = (module, spec);
      }
    }
    final services = _ModuleServices(this);
    for (final module in modules) {
      module.attach(services);
    }
  }

  static bool _off() => false;

  /// The kinds a [BridgeToolModule] may serve through its own `call`.
  static const Set<BridgeToolKind> _moduleKinds = {
    BridgeToolKind.read,
    BridgeToolKind.terminalUse,
    BridgeToolKind.desktopUse,
    BridgeToolKind.jobUse,
  };

  /// The tool groups registered from their own files; the bridge service
  /// tells each of them about host, client and on/off changes.
  final List<BridgeToolModule> modules;

  /// The built-in assistant's own on/off switch. It stands in for
  /// `AppSettings.bridgeEnabled` in every decision on a call from
  /// [BridgeClient.builtin], and only there: the channel switch never lets
  /// the built-in assistant in, and this never lets a paired one in. Off
  /// unless given.
  final bool Function() builtinAssistantEnabled;

  /// The on/off switch that applies to [client]'s calls.
  bool _enabledFor(BridgeClient client, AppSettings current) =>
      client.isBuiltin ? builtinAssistantEnabled() : current.bridgeEnabled;

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

  /// The run slots of changes, apart from [_gate] so that long changes
  /// (a command may run for 300 s) never hold up reads. A `run_on_hosts`
  /// run takes one. A change's look at the server before its card
  /// (`BridgePlanContext.withServer`) is a read and uses [_gate].
  final _Gate _changeGate;
  late final Map<String, _Tool> _tools;
  final Map<String, BridgeChangeTool> _changeTools = {};
  final Map<String, BridgeTerminalUseTool> _terminalUseTools = {};
  final Map<String, (BridgeToolModule, BridgeToolSpec)> _moduleTools = {};

  /// The questions waiting for the user. The bridge service clears them and
  /// exposes them to the UI.
  final BridgeApprovals approvals;

  /// Time-limited approvals. The bridge service clears them and exposes
  /// them to the UI; the dispatcher creates them and drops those of hosts
  /// that no longer allow changes.
  final BridgeGrants grants;

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

  /// Change runs running now and waiting for a change slot, for tests.
  int get changeRunning => _changeGate.running;
  int get changeWaiting => _changeGate.waiting;

  final Set<_Ticket> _tickets = {};

  /// Calls not yet answered, waiting or running.
  int get inFlight => _tickets.length;

  static const String revokedMessage =
      'This assistant was disconnected from SecureShell Go; the call was '
      'stopped.';
  static const String switchedOffMessage =
      'The AI Bridge was switched off; the call was stopped.';
  /// Starts the audit `detail` of a call the user approved that was then
  /// refused or stopped before it ran; the reason follows.
  static const String refusedAfterApprovalPrefix = 'refused_after_approval: ';
  static const String cancelledMessage =
      'The call was cancelled by the client; it was stopped.';

  /// Stops every call of the paired client [clientId] — it was revoked —
  /// ending its work on the server. Each still gets its one audit entry.
  void abandonClient(String clientId, {String reason = revokedMessage}) {
    for (final t in _tickets.toList()) {
      if (t.clientId == clientId) t.abandon(reason);
    }
  }

  /// Stops every call — the bridge was switched off — except those of the
  /// clients in [except] (the built-in assistant, which has its own switch).
  void abandonAll({
    String reason = switchedOffMessage,
    Set<String> except = const {},
  }) {
    for (final t in _tickets.toList()) {
      if (!except.contains(t.clientId)) t.abandon(reason);
    }
  }

  @override
  List<BridgeToolSpec> get tools => [
    for (final t in _tools.values) t.spec,
    for (final t in _changeTools.values) t.spec,
    for (final t in _terminalUseTools.values) t.spec,
    for (final t in _moduleTools.values) t.$2,
  ];

  static final RegExp _unitName = RegExp(
    r'^[A-Za-z0-9_.@:\\][A-Za-z0-9_.@:\\-]*$',
  );

  /// Whether [unit] is accepted as a systemd unit name: the one rule the
  /// read tools and `service_action` share.
  static bool isUnitName(String unit) => _unitName.hasMatch(unit);

  /// The longest a change may ask to run for ([BridgeChangePlan.runTimeout]).
  static const Duration maxRunTimeout = Duration(seconds: 300);

  /// How long a stopped call's [BridgeCallContext.commit] is let finish on
  /// its open channels before they are closed regardless.
  static const Duration commitGrace = Duration(seconds: 10);

  @override
  Future<BridgeToolResult> call(
    BridgeClient client,
    String name,
    Map<String, Object?> args, {
    BridgeCallToken? cancel,
  }) async {
    final watch = Stopwatch()..start();
    final hostArg = args['host'];
    final ticket = _Ticket(client.id);
    _tickets.add(ticket);
    if (cancel != null) {
      unawaited(
        cancel.whenCancelled.then((_) {
          if (_tickets.contains(ticket)) ticket.abandon(cancelledMessage);
        }),
      );
    }
    final change = _changeTools[name];
    final use = _terminalUseTools[name];
    final module = _moduleTools[name];
    _Outcome outcome;
    try {
      // Whichever comes first: the answer, or the call being abandoned. An
      // abandoned call's work has been halted; if it was still waiting for
      // a slot it returns at once when it gets one. A change waits for a
      // person outside the gate, and takes a run slot only once allowed.
      outcome = await Future.any([
        // A controller's token can answer cards, never run a tool: refused
        // before anything is looked up.
        if (!bridgeClientMayCallTools(client))
          Future.value(_Outcome.refused(BridgeToolRefusals.notAnAssistant))
        else if (module != null)
          _gate.run(
            () => _moduleCall(module.$1, module.$2, client, args, ticket),
            timeout: callTimeout,
          )
        else if (use != null)
          _gate.run(
            () => _terminalUse(use, client, args, ticket),
            timeout: callTimeout,
          )
        else if (change == null)
          _gate.run(
            () => _dispatch(client, name, args, ticket),
            timeout: callTimeout,
          )
        else
          _change(change, client, args, ticket),
        ticket.abandoned.then(_Outcome.error),
      ]);
    } on _Refused catch (e) {
      outcome = _Outcome.refused(e.refusal);
    } on TimeoutException {
      outcome = _Outcome.error(
        'The call took longer than '
        '${(ticket.runTimeout ?? callTimeout).inSeconds} seconds and was '
        'stopped.',
      );
    } catch (_) {
      outcome = _Outcome.error('$name failed unexpectedly.');
    } finally {
      _tickets.remove(ticket);
    }
    // A change that took effect is reported as done, whatever happened to
    // the call meanwhile; one stopped before it did says what was left.
    final commit = ticket.commit;
    final committed = commit == null
        ? null
        : await commit.timeout(
            commitGrace + const Duration(seconds: 1),
            onTimeout: () => const _CommitEnd(),
          );
    final done = committed?.done;
    if (done != null) {
      outcome = done.isError ? _Outcome.error(done.text) : _Outcome.ok(done.text);
    } else {
      if (ticket.isAbandoned &&
          outcome.outcome != BridgeAuditOutcome.error) {
        // Abandoned as it finished: what it found is not sent anywhere.
        outcome = _Outcome.error(await ticket.abandoned);
      }
      final notDone = committed?.notDone;
      if (notDone != null && outcome.outcome != BridgeAuditOutcome.ok) {
        outcome = _Outcome.error('${outcome.text} $notDone');
      }
      if (ticket.awaitingRun && outcome.outcome != BridgeAuditOutcome.ok) {
        // The user said yes, but it never ran: say so, and why.
        outcome = _Outcome.refusedAfterApproval(outcome);
      }
    }

    String text;
    try {
      text = _redactOutput(outcome);
    } catch (_) {
      // Never the raw output: if it cannot be cleaned, it does not leave.
      outcome = const _Outcome.error(
        'The output could not be made safe to return.',
      );
      text = outcome.text;
    }

    // Never throws; a failed write is reported on the bridge screen instead.
    var recorded = args;
    final auditArgs =
        change?.auditArgs ??
        use?.auditArgs ??
        (module == null ? null : (a) => module.$1.auditArgs(name, a));
    if (auditArgs != null) {
      try {
        recorded = auditArgs(args);
      } catch (_) {
        recorded = {for (final k in args.keys) k: '[not recorded]'};
      }
    }
    await audit.record(
      client: client.name,
      // A terminal-use call names no host: the entry's host is the
      // terminal's own, only when it is the caller's (never what the
      // caller put in an argument it is not allowed to send). The same for
      // a module tool that names a desktop or a job instead of a host.
      host: use != null || (module != null && !args.containsKey('host'))
          ? ticket.auditHost
          : (hostArg is String ? hostArg : ticket.auditHost),
      tool: name,
      args: recorded,
      outcome: outcome.outcome,
      detail: outcome.detail,
      ms: watch.elapsedMilliseconds,
      approval: ticket.approval,
      via: ticket.via,
    );
    final image = outcome.image;
    if (image != null && outcome.outcome == BridgeAuditOutcome.ok) {
      return BridgeToolResult.image(
        image,
        mimeType: outcome.imageMimeType!,
        text: text,
      );
    }
    return BridgeToolResult(
      text,
      isError: outcome.outcome != BridgeAuditOutcome.ok,
    );
  }

  /// A [BridgeToolModule] tool: the module resolves and decides through
  /// [_ModuleCall]; its outcome counts only when its last decision allowed
  /// the call (see [BridgeToolModule]).
  Future<_Outcome> _moduleCall(
    BridgeToolModule module,
    BridgeToolSpec spec,
    BridgeClient client,
    Map<String, Object?> args,
    _Ticket ticket,
  ) async {
    if (ticket.isAbandoned) return _Outcome.error(await ticket.abandoned);
    final context = _ModuleCall(this, client, spec, args, ticket);
    try {
      final outcome = await _run(spec.name, () async {
        final result = await module.call(context);
        final refusal = result.refusal;
        if (refusal != null) return _Outcome.refused(refusal);
        // A backstop for a module that forgot the policy: nothing it made
        // leaves unless its last decision was an allow.
        if (context._last is! BridgeAllow) {
          return _Outcome.refused(BridgeToolRefusals.notDecided);
        }
        final image = result.image;
        if (image != null) {
          return _Outcome.image(image, result.imageMimeType!, result.text);
        }
        return result.isError
            ? _Outcome.error(result.text)
            : _Outcome.ok(result.text);
      });
      final host = context._allowedHost;
      return host == null
          ? outcome
          : await _scrubbed(outcome, host, settings());
    } finally {
      await context._close();
    }
  }

  /// Resolve → decide → validate → run. The only place a [_Call] is made.
  Future<_Outcome> _dispatch(
    BridgeClient client,
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
        final hosts = await loadHosts();
        _dropStaleGrants(hosts);
        host = directory.resolve(hosts, requested);
      }
    }
    final decision = decideBridgeCall(
      bridgeEnabled: _enabledFor(client, current),
      appLocked: isAppLocked(),
      host: host,
      hostRequired: tool.takesHost,
      kind: tool.spec.kind,
      hasLiveGrant: false,
      matchesAllowedCommand: false,
      ownsLiveTerminal: false,
    );
    // Read tools only live in [_tools]; anything else here is a bug, and
    // is refused rather than run.
    if (decision is! BridgeAllow) {
      return _Outcome.refused(
        decision is BridgeRefuse ? decision : BridgeToolRefusals.unknownTool,
      );
    }

    final checked = BridgeToolArgs(args, tool.arguments);
    return _runAllowed(
      tool.spec.name,
      host,
      current,
      ticket,
      (call) => tool.run(call, checked),
    );
  }

  /// Makes the one [_Call] for an allowed call and runs [body] with it,
  /// error text scrubbed of addresses when "show address" is off.
  Future<_Outcome> _runAllowed(
    String toolName,
    Host? host,
    AppSettings current,
    _Ticket ticket,
    Future<_Outcome> Function(_Call call) body, {
    Duration? timeout,
  }) async {
    if (ticket.isAbandoned) return _Outcome.error(await ticket.abandoned);
    final call = _Call._(
      host: host,
      settings: current,
      connections: connections,
      deadline: DateTime.now().add(timeout ?? callTimeout),
    );
    ticket.call = call;
    call.onCommit = (end) => ticket.commit ??= end;
    if (ticket.isAbandoned) await call.halt();
    try {
      final outcome = await _run(toolName, () => body(call));
      return await _scrubbed(outcome, host, current);
    } finally {
      await call.close();
    }
  }

  Future<_Outcome> _scrubbed(
    _Outcome outcome,
    Host? host,
    AppSettings current,
  ) async {
    if (outcome.outcome == BridgeAuditOutcome.error &&
        host != null &&
        !current.bridgeShowAddress) {
      return _Outcome.error(await _withoutAddress(outcome.text, host));
    }
    return outcome;
  }

  /// Time-limited approvals of hosts that no longer allow changes are
  /// dropped whenever the host list is read for a call: the app has no
  /// signal for a host being un-shared or stepped down, and the policy
  /// checks the host's current level at every decision regardless.
  void _dropStaleGrants(List<Host> hosts) {
    grants.retainHosts({
      for (final h in hosts)
        if (h.aiMayRequestChanges) h.id,
    });
  }

  /// Whether [a] and [b] are the same host reaching the same server: a yes
  /// given for one is not a yes for a host edited to point elsewhere.
  static bool _sameServer(Host a, Host b) => bridgeSameServer(a, b);

  /// Whether [summary] is one command on one host that is on [host]'s
  /// allowed list. Nothing else is ever "on the list".
  static bool _isListedCommand(Host host, BridgeChangeSummary summary) =>
      summary is CommandSummary &&
      summary.hostNames.length == 1 &&
      bridgeCommandIsAllowed(host, summary.command);

  /// A call to a change or terminal tool. The order of checks is the
  /// contract, and is chosen so that nothing leaks:
  ///
  /// 1. The host name is resolved as for a read.
  /// 2. [decideBridgeCall] with no grant and no allowed command. Bridge
  ///    off, app locked, an unknown or hidden host (the same
  ///    `host_not_available` as 1.6.0), a read-only host and a terminal not
  ///    switched on are all refused here: before the arguments are looked
  ///    at, so an invalid call to a hidden host reads exactly like a valid
  ///    one, and before any card, so the assistant cannot use the user's
  ///    screen to probe for hosts. (A refusal never depends on the two
  ///    flags, which the policy test proves.)
  /// 3. The tool's [BridgeChangeTool.plan]: arguments validated, summary
  ///    built. A failure is refused (or an error) with no card.
  /// 4. [decideBridgeCall] again with the live grant (change only) and the
  ///    plan's allowed-command match: allowed outright, or a card.
  /// 5. The card, outside the run gate and the 30 s deadline. Busy, denied,
  ///    timed out and withdrawn end the call there.
  /// 6. After a yes, the hosts are read again and [decideBridgeCall] runs
  ///    again: the host must still be the same one and still allow this,
  ///    and the bridge must still be on and the app unlocked. Only then is
  ///    a time-limited approval created.
  /// 7. The change runs in a run slot, under the call deadline.
  Future<_Outcome> _change(
    BridgeChangeTool tool,
    BridgeClient client,
    Map<String, Object?> args,
    _Ticket ticket,
  ) async {
    if (ticket.isAbandoned) return _Outcome.error(await ticket.abandoned);
    if (tool.isMultiHost) return _changeOnHosts(tool, client, args, ticket);
    final kind = tool.spec.kind;
    final requested = args['host'];
    final hostName =
        requested is String &&
            requested.isNotEmpty &&
            requested.length <= maxHostNameBytes
        ? requested
        : null;

    var hosts = await loadHosts();
    _dropStaleGrants(hosts);
    var host = hostName == null ? null : directory.resolve(hosts, hostName);
    var current = settings();

    BridgeDecision decide(
      Host? h,
      AppSettings s, {
      bool grant = false,
      bool listed = false,
    }) => decideBridgeCall(
      bridgeEnabled: _enabledFor(client, s),
      appLocked: isAppLocked(),
      host: h,
      hostRequired: true,
      kind: kind,
      hasLiveGrant: grant,
      matchesAllowedCommand: listed,
      ownsLiveTerminal: false,
    );

    // 2. Refused before anything else is looked at.
    final first = decide(host, current);
    if (first is BridgeRefuse) return _Outcome.refused(first);
    final allowedHost = host!;

    // 3. Validate and summarise; no card on failure.
    BridgeChangePlan? plan;
    final context = _PlanContext(
      <T>(body) => _gate.run<T>(() async {
        if (ticket.isAbandoned) throw TimeoutException('abandoned');
        final call = _Call._(
          host: allowedHost,
          settings: current,
          connections: connections,
          deadline: DateTime.now().add(callTimeout),
        );
        ticket.call = call;
        if (ticket.isAbandoned) await call.halt();
        try {
          return await body(call);
        } finally {
          if (identical(ticket.call, call)) ticket.call = null;
          await call.close();
        }
      }, timeout: callTimeout),
      client: client,
      host: allowedHost,
      hostName: hostName!,
      settings: current,
    );
    final planned = await _run(tool.spec.name, () async {
      plan = await tool.plan(BridgeToolArgs(args, tool.arguments), context);
      return const _Outcome.ok('');
    });
    final thePlan = plan;
    if (thePlan == null) return _scrubbed(planned, allowedHost, current);
    if (ticket.isAbandoned) return _Outcome.error(await ticket.abandoned);

    // 4. With the facts that can allow it, looked at again: planning may
    // have taken seconds, and the user may have changed the host, switched
    // the bridge off or taken the command off the list meanwhile.
    hosts = await loadHosts();
    _dropStaleGrants(hosts);
    final fresh = directory.resolve(hosts, hostName);
    current = settings();
    if (ticket.isAbandoned) return _Outcome.error(await ticket.abandoned);
    if (fresh == null || !_sameServer(fresh, allowedHost)) {
      return _Outcome.refused(BridgeRefusals.hostNotAvailable);
    }
    host = fresh;
    // The dispatcher judges the list itself, from what the card will show:
    // a plan can only claim a match for one command on one host, whatever
    // its flag says.
    final listed =
        kind == BridgeToolKind.change &&
        thePlan.matchesAllowedCommand &&
        _isListedCommand(fresh, thePlan.summary);
    final granted =
        kind == BridgeToolKind.change && grants.hasLive(client.id, fresh.id);
    final decision = decide(fresh, current, grant: granted, listed: listed);
    switch (decision) {
      case BridgeRefuse():
        return _Outcome.refused(decision);
      case BridgeAllow():
        ticket.approval = decision.byFullControl
            ? BridgeAuditApproval.fullControl
            : listed
            ? BridgeAuditApproval.allowedCommand
            : BridgeAuditApproval.grant;
      case BridgeNeedsApproval():
        // 5. Ask a person.
        final request = approvals.request(
          client: client,
          hostId: allowedHost.id,
          hostName: hostName,
          tool: tool.spec.name,
          summary: thePlan.summary,
        );
        ticket.approval = BridgeAuditApproval.withdrawn;
        unawaited(ticket.abandoned.then((_) => approvals.withdraw(request.id)));
        final answer = await approvals.ask(request);
        ticket.via = answer.via;
        switch (answer.kind) {
          case BridgeApprovalOutcomeKind.busy:
            ticket.approval = BridgeAuditApproval.none;
            return _Outcome.refused(BridgeToolRefusals.approvalsBusy);
          case BridgeApprovalOutcomeKind.denied:
            ticket.approval = BridgeAuditApproval.denied;
            return _Outcome.refused(BridgeToolRefusals.denied);
          case BridgeApprovalOutcomeKind.timedOut:
            ticket.approval = BridgeAuditApproval.timedOut;
            return _Outcome.refused(BridgeToolRefusals.approvalTimedOut);
          case BridgeApprovalOutcomeKind.withdrawn:
            ticket.approval = BridgeAuditApproval.withdrawn;
            if (ticket.isAbandoned) {
              return _Outcome.error(await ticket.abandoned);
            }
            // Taken away by the app (locked, say): say why if the policy
            // now refuses, else that it was withdrawn.
            final now = decide(allowedHost, settings());
            return _Outcome.refused(
              now is BridgeRefuse ? now : BridgeToolRefusals.approvalWithdrawn,
            );
          case BridgeApprovalOutcomeKind.allowedOnce:
            ticket.approval = BridgeAuditApproval.once;
          case BridgeApprovalOutcomeKind.allowedForAWhile:
            ticket.approval = kind == BridgeToolKind.change
                ? BridgeAuditApproval.forAWhile
                : BridgeAuditApproval.once;
        }
        ticket.awaitingRun = true;
        if (ticket.isAbandoned) return _Outcome.error(await ticket.abandoned);

        // 6. The card may have waited minutes: look again.
        hosts = await loadHosts();
        _dropStaleGrants(hosts);
        host = directory.resolve(hosts, hostName);
        current = settings();
        // Revoked or stopped while the hosts were read: no grant for it.
        if (ticket.isAbandoned) return _Outcome.error(await ticket.abandoned);
        // The yes was for this server: the same host, at the same address.
        if (host == null || !_sameServer(host, allowedHost)) {
          return _Outcome.refused(BridgeRefusals.hostNotAvailable);
        }
        final again = decide(host, current);
        if (again is BridgeRefuse) return _Outcome.refused(again);
        final grantFor = answer.grantFor;
        // The setting is read again: if it was switched off (or shortened)
        // while the card waited, the yes counts as once (or for less).
        final allowedMinutes = current.bridgeTimedApprovalMinutes;
        if (kind == BridgeToolKind.change &&
            answer.kind == BridgeApprovalOutcomeKind.allowedForAWhile &&
            grantFor != null &&
            allowedMinutes > 0) {
          final cap = Duration(minutes: allowedMinutes);
          grants.grant(
            client.id,
            host.id,
            grantFor < cap ? grantFor : cap,
            clientName: client.name,
            hostName: hostName,
          );
        } else if (answer.kind == BridgeApprovalOutcomeKind.allowedForAWhile) {
          ticket.approval = BridgeAuditApproval.once;
        }
    }

    // 7. Run, in a slot, under the deadline (the plan's own, if it asked
    // for one).
    final runHost = host;
    final runSettings = current;
    final runTimeout = _runTimeoutOf(thePlan);
    ticket.runTimeout = runTimeout;
    return _changeGate.run(
      () {
        ticket.awaitingRun = false;
        return _runAllowed(
        tool.spec.name,
        runHost,
        runSettings,
        ticket,
        (call) async {
          final result = await tool.run(call, thePlan);
          return _Outcome.fromResult(result);
        },
        timeout: runTimeout,
      );
      },
      timeout: runTimeout,
    );
  }

  /// The longest `terminal_id` looked up; anything longer names nothing.
  static const int maxTerminalIdChars = 128;

  /// A call to a terminal-use tool. The order is the contract:
  ///
  /// 1. The terminal is looked up among the calling client's own, from the
  ///    raw `terminal_id` (anything not a short string names nothing).
  /// 2. For the caller's own terminal, the hosts are read and its host is
  ///    passed on only while it is still the same server.
  /// 3. [decideBridgeCall] with `ownsLiveTerminal`. An unknown id and
  ///    another client's id get the one `terminal_not_available`, before
  ///    any argument is looked at; a refusal for the caller's own terminal
  ///    goes through [BridgeTerminalUseTool.refused].
  /// 4. The arguments are validated, then [BridgeTerminalUseTool.run].
  Future<_Outcome> _terminalUse(
    BridgeTerminalUseTool tool,
    BridgeClient client,
    Map<String, Object?> args,
    _Ticket ticket,
  ) async {
    if (ticket.isAbandoned) return _Outcome.error(await ticket.abandoned);
    final raw = args['terminal_id'];
    final id = raw is String && raw.isNotEmpty && raw.length <= maxTerminalIdChars
        ? raw
        : null;
    final target = id == null ? null : tool.find(client.id, id);
    Host? host;
    if (target != null) {
      ticket.auditHost = target.hostName;
      final hosts = await loadHosts();
      _dropStaleGrants(hosts);
      for (final h in hosts) {
        if (_sameServer(h, target.host)) host = h;
      }
    }
    if (ticket.isAbandoned) return _Outcome.error(await ticket.abandoned);
    final current = settings();
    final decision = decideBridgeCall(
      bridgeEnabled: _enabledFor(client, current),
      appLocked: isAppLocked(),
      host: host,
      hostRequired: true,
      kind: BridgeToolKind.terminalUse,
      hasLiveGrant: false,
      matchesAllowedCommand: false,
      ownsLiveTerminal: target != null && target.live,
    );
    if (decision is BridgeRefuse) {
      final refine = tool.refused;
      if (target == null || refine == null) return _Outcome.refused(decision);
      return _Outcome.refused(refine(client.id, id!, decision));
    }
    if (decision is! BridgeAllow) {
      return _Outcome.refused(BridgeToolRefusals.unknownTool);
    }
    final checked = BridgeToolArgs(args, tool.arguments);
    final allowedHost = host!;
    final outcome = await _run(tool.spec.name, () async {
      final result = await tool.run(client.id, id!, allowedHost, checked);
      return result.isError
          ? _Outcome.error(result.text)
          : _Outcome.ok(result.text);
    });
    return _scrubbed(outcome, allowedHost, current);
  }

  Duration _runTimeoutOf(BridgeChangePlan plan) {
    final asked = plan.runTimeout;
    if (asked == null || asked <= Duration.zero) return callTimeout;
    return asked > maxRunTimeout ? maxRunTimeout : asked;
  }

  /// The names in a multi-host call's `hosts`, each null when it is not a
  /// usable name; empty when `hosts` is not a list (or is far too long to
  /// be one the tool would accept, so a huge list costs nothing).
  static List<String?> _hostNamesOf(Object? value) {
    if (value is! List || value.length > 64) return const [];
    return [
      for (final v in value)
        v is String && v.isNotEmpty && v.length <= maxHostNameBytes ? v : null,
    ];
  }

  /// A change on several hosts at once (`run_on_hosts`): the order of
  /// [_change], for every host.
  ///
  /// 1. Every name is resolved.
  /// 2. [decideBridgeCall] for each, before the arguments are looked at. A
  ///    hidden or unknown name anywhere fails the whole call with the one
  ///    `host_not_available` (which name is not said); otherwise a
  ///    read-only host fails it with `changes_not_allowed`. A `hosts` that
  ///    is not a list of names is treated as naming no host.
  /// 3. The tool's plan (count, duplicates, the command; the card's
  ///    summary). No card on failure.
  /// 4. Hosts and settings read again; every host must still be the same
  ///    server. The allowed-command lists never apply; the call is allowed
  ///    without a card only when a live grant exists for EVERY host.
  /// 5. One card for all of them.
  /// 6. After a yes, every host read again, the same server, and the
  ///    policy again for each. Only when all pass, and the timed-approval
  ///    setting (read again) is above 0, is a grant made, for each host.
  /// 7. One run slot for the whole run; [BridgeChangeTool.run] once per
  ///    host, at most [BridgeChangeTool.hostsAtOnce] at a time, each under
  ///    its own deadline ([BridgeChangePlan.runTimeout]); then
  ///    [BridgeChangeTool.combine].
  Future<_Outcome> _changeOnHosts(
    BridgeChangeTool tool,
    BridgeClient client,
    Map<String, Object?> args,
    _Ticket ticket,
  ) async {
    const kind = BridgeToolKind.change;
    final names = _hostNamesOf(args['hosts']);

    BridgeDecision decide(Host? h, AppSettings s, {bool grant = false}) =>
        decideBridgeCall(
          bridgeEnabled: _enabledFor(client, s),
          appLocked: isAppLocked(),
          host: h,
          hostRequired: true,
          kind: kind,
          hasLiveGrant: grant,
          matchesAllowedCommand: false,
          ownsLiveTerminal: false,
        );

    /// One decision for all: a hidden host outranks a read-only one, and
    /// anything refused outranks a card. Allowed by full control only when
    /// every host is set to full control (for the audit entry).
    BridgeDecision decideAll(
      List<Host?> resolved,
      AppSettings s, {
      bool Function(Host h)? grant,
    }) {
      if (resolved.isEmpty) return decide(null, s);
      BridgeRefuse? refusal;
      var allAllowed = true;
      var allFull = true;
      for (final h in resolved) {
        final d = decide(h, s, grant: h != null && (grant?.call(h) ?? false));
        if (d is BridgeRefuse) {
          if (refusal == null || d == BridgeRefusals.hostNotAvailable) {
            refusal = d;
          }
        } else if (d is! BridgeAllow) {
          allAllowed = false;
        } else if (!d.byFullControl) {
          allFull = false;
        }
      }
      if (refusal != null) return refusal;
      if (!allAllowed) return const BridgeNeedsApproval();
      return allFull ? const BridgeAllow.fullControl() : const BridgeAllow();
    }

    List<Host?> resolve(List<Host> hosts) => [
      for (final n in names) n == null ? null : directory.resolve(hosts, n),
    ];

    var hosts = await loadHosts();
    _dropStaleGrants(hosts);
    var current = settings();
    final firstHosts = resolve(hosts);

    // 2. Refused before anything else is looked at.
    final first = decideAll(firstHosts, current);
    if (first is BridgeRefuse) return _Outcome.refused(first);
    final allowedHosts = [for (final h in firstHosts) h!];
    final allowedNames = [for (final n in names) n!];
    // Two names for one host (a hosts file with a repeated id) would run the
    // command twice there under one yes.
    if ({for (final h in allowedHosts) h.id}.length != allowedHosts.length) {
      return _Outcome.refused(
        BridgeToolRefusals.invalid('hosts must not name a host twice.'),
      );
    }

    // 3. Validate and summarise; no card on failure. There is no look at a
    // server before the card for a multi-host change.
    BridgeChangePlan? plan;
    final context = _PlanContext(
      <T>(body) => throw StateError('no server look for a multi-host plan'),
      client: client,
      host: allowedHosts.first,
      hostName: allowedNames.first,
      hostNames: allowedNames,
      settings: current,
    );
    final planned = await _run(tool.spec.name, () async {
      plan = await tool.plan(BridgeToolArgs(args, tool.arguments), context);
      return const _Outcome.ok('');
    });
    final thePlan = plan;
    if (thePlan == null) return planned;
    if (ticket.isAbandoned) return _Outcome.error(await ticket.abandoned);

    /// Every host read again and still the same server, or null.
    Future<List<Host>?> reread() async {
      hosts = await loadHosts();
      _dropStaleGrants(hosts);
      current = settings();
      final again = resolve(hosts);
      for (var i = 0; i < again.length; i++) {
        final h = again[i];
        if (h == null || !_sameServer(h, allowedHosts[i])) return null;
      }
      return [for (final h in again) h!];
    }

    // 4. Looked at again, with the grants.
    var fresh = await reread();
    if (ticket.isAbandoned) return _Outcome.error(await ticket.abandoned);
    if (fresh == null) return _Outcome.refused(BridgeRefusals.hostNotAvailable);
    final decision = decideAll(
      fresh,
      current,
      grant: (h) => grants.hasLive(client.id, h.id),
    );
    switch (decision) {
      case BridgeRefuse():
        return _Outcome.refused(decision);
      case BridgeAllow():
        ticket.approval = decision.byFullControl
            ? BridgeAuditApproval.fullControl
            : BridgeAuditApproval.grant;
      case BridgeNeedsApproval():
        // 5. One card, naming every host.
        final request = approvals.request(
          client: client,
          hostId: allowedHosts.first.id,
          hostName: allowedNames.join(', '),
          tool: tool.spec.name,
          summary: thePlan.summary,
        );
        ticket.approval = BridgeAuditApproval.withdrawn;
        unawaited(ticket.abandoned.then((_) => approvals.withdraw(request.id)));
        final answer = await approvals.ask(request);
        ticket.via = answer.via;
        switch (answer.kind) {
          case BridgeApprovalOutcomeKind.busy:
            ticket.approval = BridgeAuditApproval.none;
            return _Outcome.refused(BridgeToolRefusals.approvalsBusy);
          case BridgeApprovalOutcomeKind.denied:
            ticket.approval = BridgeAuditApproval.denied;
            return _Outcome.refused(BridgeToolRefusals.denied);
          case BridgeApprovalOutcomeKind.timedOut:
            ticket.approval = BridgeAuditApproval.timedOut;
            return _Outcome.refused(BridgeToolRefusals.approvalTimedOut);
          case BridgeApprovalOutcomeKind.withdrawn:
            ticket.approval = BridgeAuditApproval.withdrawn;
            if (ticket.isAbandoned) {
              return _Outcome.error(await ticket.abandoned);
            }
            final now = decideAll(fresh, settings());
            return _Outcome.refused(
              now is BridgeRefuse ? now : BridgeToolRefusals.approvalWithdrawn,
            );
          case BridgeApprovalOutcomeKind.allowedOnce:
            ticket.approval = BridgeAuditApproval.once;
          case BridgeApprovalOutcomeKind.allowedForAWhile:
            ticket.approval = BridgeAuditApproval.forAWhile;
        }
        ticket.awaitingRun = true;
        if (ticket.isAbandoned) return _Outcome.error(await ticket.abandoned);

        // 6. Every host again, then (only if all pass) the grants.
        fresh = await reread();
        if (ticket.isAbandoned) return _Outcome.error(await ticket.abandoned);
        if (fresh == null) {
          return _Outcome.refused(BridgeRefusals.hostNotAvailable);
        }
        final again = decideAll(fresh, current);
        if (again is BridgeRefuse) return _Outcome.refused(again);
        final grantFor = answer.grantFor;
        final allowedMinutes = current.bridgeTimedApprovalMinutes;
        if (answer.kind == BridgeApprovalOutcomeKind.allowedForAWhile &&
            grantFor != null &&
            allowedMinutes > 0) {
          final cap = Duration(minutes: allowedMinutes);
          for (var i = 0; i < fresh.length; i++) {
            grants.grant(
              client.id,
              fresh[i].id,
              grantFor < cap ? grantFor : cap,
              clientName: client.name,
              hostName: allowedNames[i],
            );
          }
        } else if (answer.kind == BridgeApprovalOutcomeKind.allowedForAWhile) {
          ticket.approval = BridgeAuditApproval.once;
        }
    }

    // 7. One slot; each host under its own deadline.
    final runHosts = fresh;
    final runSettings = current;
    final perHost = _runTimeoutOf(thePlan);
    final atOnce = tool.hostsAtOnce;
    final rounds = (runHosts.length + atOnce - 1) ~/ atOnce;
    final total = perHost * rounds + const Duration(seconds: 5);
    ticket.runTimeout = total;
    final outcomes = List<BridgeHostOutcome?>.filled(runHosts.length, null);

    Future<void> runOne(int i) async {
      final host = runHosts[i];
      final name = allowedNames[i];
      if (ticket.isAbandoned) return;
      final call = _Call._(
        host: host,
        settings: runSettings,
        connections: connections,
        deadline: DateTime.now().add(perHost),
      );
      ticket.hostCalls.add(call);
      if (ticket.isAbandoned) await call.halt();
      _Outcome outcome;
      try {
        outcome = await _run(tool.spec.name, () async {
          final result = await tool.run(call, thePlan);
          return result.isError
              ? _Outcome.error(result.text)
              : _Outcome.ok(result.text);
        });
      } on TimeoutException {
        outcome = _Outcome.error(
          'Took longer than ${perHost.inSeconds} seconds and was stopped.',
        );
      } finally {
        ticket.hostCalls.remove(call);
        await call.close();
      }
      outcome = await _scrubbed(outcome, host, runSettings);
      outcomes[i] = BridgeHostOutcome(
        hostName: name,
        text: outcome.text,
        isError: outcome.outcome != BridgeAuditOutcome.ok,
      );
    }

    return _changeGate.run(() async {
      ticket.awaitingRun = false;
      var next = 0;
      Future<void> worker() async {
        while (next < runHosts.length && !ticket.isAbandoned) {
          await runOne(next++);
        }
      }

      await Future.wait([
        for (var w = 0; w < atOnce && w < runHosts.length; w++) worker(),
      ]);
      if (ticket.isAbandoned) return _Outcome.error(await ticket.abandoned);
      final result = tool.combine!([
        for (var i = 0; i < outcomes.length; i++)
          outcomes[i] ??
              BridgeHostOutcome(
                hostName: allowedNames[i],
                text: 'Not run.',
                isError: true,
              ),
      ], thePlan);
      return result.isError
          ? _Outcome.error(result.text)
          : _Outcome.ok(result.text);
    }, timeout: total);
  }

  /// [outcome]'s text made safe to return. A JSON object answer is redacted
  /// value by value, so redaction can never break its structure (a secret
  /// pattern matched across a quote would); anything else, or a JSON answer
  /// that would come out over the cap, as text.
  String _redactOutput(_Outcome outcome) {
    final text = outcome.text;
    if (outcome.outcome == BridgeAuditOutcome.ok && text.startsWith('{')) {
      Object? decoded;
      try {
        decoded = jsonDecode(text);
      } on FormatException {
        decoded = null;
      }
      if (decoded is Map) {
        final clean = jsonEncode(_redactJson(decoded));
        if (utf8.encode(clean).length <= redactor.maxBytes) return clean;
      }
    }
    return redactor.redact(text, keepTail: outcome.keepTail);
  }

  Object? _redactJson(Object? value) => switch (value) {
    String s => redactor.redact(s),
    List l => [for (final v in l) _redactJson(v)],
    Map m => {for (final e in m.entries) '${e.key}': _redactJson(e.value)},
    _ => value,
  };

  Future<_Outcome> _run(
    String toolName,
    Future<_Outcome> Function() body,
  ) async {
    try {
      return await body();
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
      return _Outcome.error('$toolName failed unexpectedly.');
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

  Future<_Outcome> _listHosts(_Call call, BridgeToolArgs args) async {
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

  Future<_Outcome> _serverStats(_Call call, BridgeToolArgs args) async {
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

  Future<_Outcome> _listServices(_Call call, BridgeToolArgs args) async {
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

  Future<_Outcome> _tailLog(_Call call, BridgeToolArgs args) async {
    final unit = args.string('unit', maxBytes: 256, required: false);
    final hasPath = args._raw['path'] != null;
    final lines = args.integer(
      'lines',
      min: 1,
      max: maxTailLines,
      fallback: defaultTailLines,
    );
    if ((unit == null) == !hasPath) {
      BridgeToolArgs._bad('give exactly one of unit or path.');
    }
    if (unit != null) {
      if (!_unitName.hasMatch(unit)) {
        BridgeToolArgs._bad('unit is not a systemd unit name.');
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

  Future<_Outcome> _listDir(_Call call, BridgeToolArgs args) async {
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

  Future<_Outcome> _readFile(_Call call, BridgeToolArgs args) async {
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

  Future<_Outcome> _searchFiles(_Call call, BridgeToolArgs args) async {
    final pattern = args.string('name', maxBytes: 255)!;
    if (pattern.contains('/')) BridgeToolArgs._bad('name is a file name, not a path.');
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

/// What a module may do for the user's own actions: the same server access
/// a tool call gets, without a policy decision (see [BridgeModuleServices]).
class _ModuleServices implements BridgeModuleServices {
  _ModuleServices(this._tools);

  final BridgeTools _tools;

  @override
  bool get isAppLocked => _tools.isAppLocked();

  @override
  Future<List<Host>> hosts() => _tools.loadHosts();

  @override
  Future<T> withServerAsUser<T>(
    Host host,
    Future<T> Function(BridgeCallContext call) body, {
    Duration? timeout,
  }) async {
    final call = _Call._(
      host: host,
      settings: _tools.settings(),
      connections: _tools.connections,
      deadline: DateTime.now().add(timeout ?? _tools.callTimeout),
    );
    try {
      return await body(call);
    } finally {
      await call.close();
    }
  }
}

/// What a [BridgeToolModule] call is handed: [BridgeModuleCall], backed by
/// the tool host's own resolver, policy inputs and [_Call].
class _ModuleCall implements BridgeModuleCall {
  _ModuleCall(this._tools, this.client, this.spec, this.rawArgs, this._ticket);

  final BridgeTools _tools;
  final _Ticket _ticket;

  @override
  final BridgeClient client;
  @override
  final BridgeToolSpec spec;
  @override
  final Map<String, Object?> rawArgs;

  /// The last decision, and the host it allowed (null unless an allow).
  BridgeDecision? _last;
  Host? _allowedHost;
  final Set<_Call> _calls = {};

  @override
  BridgeToolArgs args(Set<String> allowed) => BridgeToolArgs(rawArgs, allowed);

  @override
  Future<List<Host>> hosts() async {
    final hosts = await _tools.loadHosts();
    _tools._dropStaleGrants(hosts);
    return hosts;
  }

  @override
  Future<Host?> resolveHost(Object? name) async {
    if (name is! String ||
        name.isEmpty ||
        name.length > BridgeTools.maxHostNameBytes) {
      return null;
    }
    return _tools.directory.resolve(await hosts(), name);
  }

  @override
  BridgeDecision decide({
    required Host? host,
    bool hostRequired = true,
    bool ownsLiveTerminal = false,
    bool ownsLiveDesktop = false,
    bool ownsJob = false,
  }) {
    final decision = decideBridgeCall(
      bridgeEnabled: _tools._enabledFor(client, _tools.settings()),
      appLocked: _tools.isAppLocked(),
      host: host,
      hostRequired: hostRequired,
      kind: spec.kind,
      hasLiveGrant: false,
      matchesAllowedCommand: false,
      ownsLiveTerminal: ownsLiveTerminal,
      ownsLiveDesktop: ownsLiveDesktop,
      ownsJob: ownsJob,
    );
    _last = decision;
    _allowedHost = decision is BridgeAllow ? host : null;
    if (decision is BridgeAllow && decision.byFullControl) {
      _ticket.approval = BridgeAuditApproval.fullControl;
    }
    return decision;
  }

  @override
  Future<T> withServer<T>(
    Host host,
    Future<T> Function(BridgeCallContext call) body, {
    Duration? timeout,
  }) async {
    final allowed = _allowedHost;
    if (_last is! BridgeAllow ||
        allowed == null ||
        !bridgeSameServer(allowed, host)) {
      throw StateError('withServer before an allow for this host');
    }
    if (_ticket.isAbandoned) throw TimeoutException('abandoned');
    final call = _Call._(
      host: host,
      settings: _tools.settings(),
      connections: _tools.connections,
      deadline: DateTime.now().add(timeout ?? _tools.callTimeout),
    );
    _calls.add(call);
    _ticket.hostCalls.add(call);
    if (_ticket.isAbandoned) await call.halt();
    try {
      return await body(call);
    } finally {
      _ticket.hostCalls.remove(call);
      _calls.remove(call);
      await call.close();
    }
  }

  @override
  set auditHost(String? name) => _ticket.auditHost = name;

  @override
  bool get isAbandoned => _ticket.isAbandoned;

  @override
  Future<String> get abandoned => _ticket.abandoned;

  Future<void> _close() async {
    for (final call in _calls.toList()) {
      await call.close();
    }
  }
}
