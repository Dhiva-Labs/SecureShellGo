import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart' show SSHKeyPair, SSHSession, SSHSignal;

import '../models/host.dart';
import 'shell_quote.dart';
import 'ssh_service.dart';

/// Where one host stands in a fleet run.
enum FleetExecStatus {
  queued,
  connecting,
  running,

  /// Exited 0.
  succeeded,

  /// Ran, and exited non-zero or was killed by a signal.
  failed,

  /// Never got to run: the connection or the exec channel failed.
  error,

  /// Not attempted, because signing in needs a person — a one-time code,
  /// a password that is not saved, a host key nobody has checked yet.
  skipped,

  cancelled;

  bool get isFinished =>
      this != queued && this != connecting && this != running;

  /// What "re-run on failed hosts" picks up.
  bool get isFailure => this == failed || this == error;
}

/// A piece of a host's output, as it arrived.
class FleetExecChunk {
  const FleetExecChunk(this.text, {this.isError = false});

  final String text;

  /// From stderr.
  final bool isError;
}

/// One host's part in a fleet run: its state, its output so far, and how it
/// ended.
///
/// Mutable and owned by the [FleetExecService] that made it, the same shape
/// as `FleetHostProgress`: the service publishes the whole list on
/// [FleetExecService.changes] after a change, rather than the screen
/// reconciling deltas.
class FleetExecHostRun {
  FleetExecHostRun(this.host);

  final Host host;

  String get hostId => host.id;
  String get label => host.displayName;

  FleetExecStatus status = FleetExecStatus.queued;

  /// The command's exit status, when it reported one.
  int? exitCode;

  /// The signal that ended it, when one did — `TERM`, `KILL`.
  String? exitSignal;

  /// Why it was skipped, or what went wrong before it could run.
  String? message;

  /// True when it ran over a session that was already open, rather than a
  /// connection this run dialled itself.
  bool usedOpenSession = false;

  DateTime? startedAt;
  DateTime? finishedAt;

  /// From the exec starting to its exit; connecting is not counted.
  Duration? get duration {
    final start = startedAt;
    final end = finishedAt;
    if (start == null || end == null) return null;
    return end.difference(start);
  }

  final List<FleetExecChunk> _chunks = [];
  var _length = 0;

  /// True once the earliest output was let go to stay under
  /// [FleetExecService.maxOutputChars].
  bool truncated = false;

  List<FleetExecChunk> get chunks => List.unmodifiable(_chunks);

  /// Everything kept, stdout and stderr interleaved as they arrived.
  String get output => _chunks.map((c) => c.text).join();

  bool get hasOutput => _chunks.isNotEmpty;

  void _append(String text, {required bool isError, required int cap}) {
    if (text.isEmpty) return;
    final last = _chunks.isEmpty ? null : _chunks.last;
    if (last != null && last.isError == isError) {
      _chunks[_chunks.length - 1] =
          FleetExecChunk(last.text + text, isError: isError);
    } else {
      _chunks.add(FleetExecChunk(text, isError: isError));
    }
    _length += text.length;
    // The newest output is what tells the user how it ended, so it is the
    // oldest that goes.
    while (_length > cap && _chunks.isNotEmpty) {
      truncated = true;
      final first = _chunks.first;
      final excess = _length - cap;
      if (first.text.length <= excess) {
        _chunks.removeAt(0);
        _length -= first.text.length;
      } else {
        _chunks[0] = FleetExecChunk(
          first.text.substring(excess),
          isError: first.isError,
        );
        _length -= excess;
      }
    }
  }

  void _reset() {
    status = FleetExecStatus.queued;
    exitCode = null;
    exitSignal = null;
    message = null;
    usedOpenSession = false;
    startedAt = null;
    finishedAt = null;
    _chunks.clear();
    _length = 0;
    truncated = false;
  }
}

/// Thrown by a [FleetExecDialer] when the host cannot be signed in to
/// without a person: it asked a question nobody saved an answer to, or its
/// host key has not been checked yet. The host is reported as skipped, with
/// [reason], rather than failed.
class FleetSignInNeedsPerson implements Exception {
  const FleetSignInNeedsPerson(this.reason);

  final String reason;

  @override
  String toString() => reason;
}

/// The live session's transport for a host, or null when none is open —
/// in which case the run dials its own.
typedef FleetExecOpenTransport = SessionTransport? Function(String hostId);

/// Loads what is saved for a host; `CredentialStore.load` fits.
typedef FleetExecCredentialLookup = Future<SshCredentials?> Function(
  String hostId,
);

/// Dials and signs in to [host] with nobody there to answer anything.
/// Throws [FleetSignInNeedsPerson] when that is why it could not.
typedef FleetExecDialer = Future<SessionTransport> Function(
  Host host,
  SshCredentials credentials,
);

/// Runs one command on many servers, a few at a time, and keeps every
/// host's output, exit status and running time.
///
/// **Connections.** A host with a session already open runs the command
/// over that session's connection, as one more exec channel. Any other host
/// gets a connection of its own, through [dialer], closed again once its
/// command has ended. At most [maxConcurrentHosts] hosts are connecting or
/// running at any moment: a pool that pulls the next host as soon as a slot
/// is free, the same as `FleetPushService`.
///
/// **Nobody is asked anything.** A host whose sign-in needs a person — no
/// saved password, a key whose passphrase is not saved, a one-time code, a
/// host key not yet trusted — is [FleetExecStatus.skipped] with the reason,
/// never left waiting on a prompt. The rest carry on.
///
/// **The command** runs through the account's own shell, as `ssh host cmd`
/// would, inside a small POSIX wrapper (see [wrap]) that gives it no stdin
/// and kills it, children and all, when this app stops it.
class FleetExecService {
  FleetExecService({
    required List<Host> hosts,
    required this.command,
    required this.openTransport,
    required this.credentialLookup,
    required this.dialer,
    this.maxConcurrentHosts = defaultMaxConcurrentHosts,
    this.maxOutputChars = defaultMaxOutputChars,
    this.stopGrace = const Duration(seconds: 3),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    for (final host in hosts) {
      _runs.putIfAbsent(host.id, () => FleetExecHostRun(host));
    }
  }

  static const int defaultMaxConcurrentHosts = 3;

  /// Per host. Past it the earliest output goes, and the run says so.
  static const int defaultMaxOutputChars = 256 * 1024;

  final String command;
  final FleetExecOpenTransport openTransport;
  final FleetExecCredentialLookup credentialLookup;
  final FleetExecDialer dialer;
  final int maxConcurrentHosts;
  final int maxOutputChars;

  /// How long a stopped command gets to go before its channel is closed
  /// under it.
  final Duration stopGrace;

  final DateTime Function() _clock;

  final Map<String, FleetExecHostRun> _runs = {};
  final Queue<String> _pending = Queue<String>();
  final Set<String> _cancelled = {};
  final Map<String, SSHSession> _sessions = {};
  final Map<String, Completer<void>> _stopped = {};

  var _started = false;
  var _workers = 0;
  Completer<void>? _idle;

  final _controller = StreamController<List<FleetExecHostRun>>.broadcast();
  Timer? _publishTimer;

  /// Every host's run, whenever any of it changes — at most every 80 ms
  /// while output is streaming in.
  Stream<List<FleetExecHostRun>> get changes => _controller.stream;

  /// In the order the hosts were given.
  List<FleetExecHostRun> get hosts => List.unmodifiable(_runs.values);

  FleetExecHostRun? runFor(String hostId) => _runs[hostId];

  bool get isRunning => _workers > 0 || _pending.isNotEmpty;

  /// Completes when nothing is queued or running any more.
  Future<void> get done {
    if (!isRunning) return Future<void>.value();
    return (_idle ??= Completer<void>()).future;
  }

  List<FleetExecHostRun> get failedHosts =>
      _runs.values.where((r) => r.status.isFailure).toList(growable: false);

  int countOf(FleetExecStatus status) =>
      _runs.values.where((r) => r.status == status).length;

  /// "5 succeeded · 2 failed · 1 skipped" — only the parts that are not
  /// zero.
  String get summary {
    final parts = <String>[
      for (final (status, word) in const [
        (FleetExecStatus.succeeded, 'succeeded'),
        (FleetExecStatus.failed, 'failed'),
        (FleetExecStatus.error, 'could not run'),
        (FleetExecStatus.skipped, 'skipped'),
        (FleetExecStatus.cancelled, 'stopped'),
      ])
        if (countOf(status) > 0) '${countOf(status)} $word',
    ];
    return parts.isEmpty ? 'Nothing ran' : parts.join(' · ');
  }

  /// Starts every host. A second call does nothing.
  void start() {
    if (_started) return;
    _started = true;
    _pending.addAll(_runs.keys);
    _publish();
    _fill();
  }

  /// Runs the command again on [hostIds] — only those that have finished;
  /// one still going is left alone.
  void rerun(Iterable<String> hostIds) {
    var any = false;
    for (final id in hostIds) {
      final run = _runs[id];
      if (run == null || !run.status.isFinished || _pending.contains(id)) {
        continue;
      }
      run._reset();
      _cancelled.remove(id);
      _pending.add(id);
      any = true;
    }
    if (!any) return;
    _started = true;
    _publish();
    _fill();
  }

  /// Stops everything: queued hosts never start, running commands are
  /// killed.
  void cancel() {
    for (final id in _runs.keys) {
      cancelHost(id);
    }
  }

  /// Stops one host, queued or running.
  void cancelHost(String hostId) {
    final run = _runs[hostId];
    if (run == null || run.status.isFinished) return;
    _cancelled.add(hostId);
    if (_pending.remove(hostId)) {
      run
        ..status = FleetExecStatus.cancelled
        ..message = 'Stopped before it started.';
      _publish();
      _checkIdle();
      return;
    }
    final session = _sessions[hostId];
    if (session != null) unawaited(_stop(hostId, session));
  }

  void _fill() {
    while (_workers < maxConcurrentHosts && _pending.isNotEmpty) {
      _workers++;
      unawaited(_worker());
    }
  }

  Future<void> _worker() async {
    try {
      while (_pending.isNotEmpty) {
        final id = _pending.removeFirst();
        await _runHost(_runs[id]!);
      }
    } finally {
      _workers--;
      _publish();
      _checkIdle();
    }
  }

  void _checkIdle() {
    if (isRunning) return;
    final idle = _idle;
    _idle = null;
    if (idle != null && !idle.isCompleted) idle.complete();
  }

  bool _wantsStop(FleetExecHostRun run) => _cancelled.contains(run.hostId);

  void _finish(
    FleetExecHostRun run,
    FleetExecStatus status, {
    String? message,
  }) {
    run.status = status;
    if (message != null) run.message = message;
    run.finishedAt ??= run.startedAt == null ? null : _clock();
    _publish(now: true);
  }

  Future<void> _runHost(FleetExecHostRun run) async {
    if (_wantsStop(run)) {
      _finish(run, FleetExecStatus.cancelled, message: 'Stopped before it started.');
      return;
    }
    run.status = FleetExecStatus.connecting;
    _publish(now: true);

    SessionTransport? transport;
    void Function()? hangUp;
    final open = openTransport(run.hostId);
    if (open != null && !open.isClosed) {
      transport = open;
      run.usedOpenSession = true;
    } else {
      final SshCredentials? saved;
      try {
        saved = await credentialLookup(run.hostId);
      } catch (e) {
        _finish(run, FleetExecStatus.error, message: _messageOf(e));
        return;
      }
      final problem = signInProblem(run.host, saved);
      if (problem != null) {
        _finish(run, FleetExecStatus.skipped, message: problem);
        return;
      }
      if (_wantsStop(run)) {
        _finish(run, FleetExecStatus.cancelled, message: 'Stopped before it started.');
        return;
      }
      try {
        final dialled = await dialer(run.host, saved ?? const SshCredentials());
        transport = dialled;
        hangUp = dialled.close;
      } on FleetSignInNeedsPerson catch (e) {
        _finish(run, FleetExecStatus.skipped, message: e.reason);
        return;
      } catch (e) {
        _finish(run, FleetExecStatus.error, message: _messageOf(e));
        return;
      }
    }

    try {
      if (_wantsStop(run)) {
        _finish(run, FleetExecStatus.cancelled, message: 'Stopped before it started.');
        return;
      }
      await _execute(run, transport);
    } finally {
      try {
        hangUp?.call();
      } catch (_) {
        // Already gone.
      }
    }
  }

  Future<void> _execute(FleetExecHostRun run, SessionTransport transport) async {
    final SSHSession session;
    try {
      session = await transport.execute(wrap(command));
    } catch (e) {
      _finish(
        run,
        FleetExecStatus.error,
        message: 'Could not start the command: ${_messageOf(e)}',
      );
      return;
    }
    run
      ..status = FleetExecStatus.running
      ..startedAt = _clock();
    _sessions[run.hostId] = session;
    _publish(now: true);

    if (_wantsStop(run)) unawaited(_stop(run.hostId, session));

    final outDone = Completer<void>();
    final errDone = Completer<void>();
    void done(Completer<void> c) {
      if (!c.isCompleted) c.complete();
    }

    const Utf8Decoder(allowMalformed: true).bind(session.stdout).listen(
          (text) {
            run._append(text, isError: false, cap: maxOutputChars);
            _publish();
          },
          onDone: () => done(outDone),
          onError: (Object _) => done(outDone),
          cancelOnError: false,
        );
    const Utf8Decoder(allowMalformed: true).bind(session.stderr).listen(
          (text) {
            run._append(text, isError: true, cap: maxOutputChars);
            _publish();
          },
          onDone: () => done(errDone),
          onError: (Object _) => done(errDone),
          cancelOnError: false,
        );

    int? code;
    try {
      code = await session.waitForExit();
    } catch (_) {
      code = null;
    }
    // The status can come in ahead of the last of the output.
    await Future.wait([outDone.future, errDone.future])
        .timeout(const Duration(seconds: 2), onTimeout: () => const []);
    run
      ..finishedAt = _clock()
      ..exitCode = code
      ..exitSignal = session.exitSignal?.signalName;
    _sessions.remove(run.hostId);
    final stopped = _stopped.remove(run.hostId);
    if (stopped != null && !stopped.isCompleted) stopped.complete();
    try {
      session.close();
    } catch (_) {
      // Already closed.
    }

    if (_wantsStop(run)) {
      _finish(run, FleetExecStatus.cancelled, message: 'Stopped.');
    } else if (code == 0) {
      _finish(run, FleetExecStatus.succeeded);
    } else if (code != null) {
      _finish(run, FleetExecStatus.failed);
    } else {
      final signal = run.exitSignal;
      _finish(
        run,
        FleetExecStatus.failed,
        message: signal == null
            ? 'It ended without reporting an exit status.'
            : 'Ended by signal $signal.',
      );
    }
  }

  /// Closes the command's stdin — which the wrapper turns into a kill of
  /// its whole process group — asks the server to TERM it as well, and
  /// closes the channel if neither has ended it within [stopGrace].
  Future<void> _stop(String hostId, SSHSession session) async {
    final stopped = _stopped.putIfAbsent(hostId, Completer<void>.new);
    try {
      await session.stdin.close().timeout(const Duration(seconds: 1));
    } catch (_) {
      // Closing the channel below covers it.
    }
    try {
      session.kill(SSHSignal.TERM);
    } catch (_) {
      // Not every server takes signal requests.
    }
    await stopped.future.timeout(stopGrace, onTimeout: () {
      try {
        session.close();
      } catch (_) {
        // Already gone.
      }
    });
  }

  /// Why [host] cannot be signed in to without a person, from what is
  /// saved for it — or null when it can be tried.
  ///
  /// Only what can be told before dialling: a one-time code or an
  /// untrusted host key turns up during the sign-in, and the dialer reports
  /// those as [FleetSignInNeedsPerson].
  static String? signInProblem(Host host, SshCredentials? saved) {
    switch (host.authMethod) {
      case SshAuthMethod.agent:
        return null;
      case SshAuthMethod.password:
        if (saved?.password?.isNotEmpty ?? false) return null;
        return 'No saved password. Connect once from the host list and '
            'save it to include this host.';
      case SshAuthMethod.privateKey:
        final pem = saved?.privateKeyPem?.trim() ?? '';
        if (pem.isEmpty) {
          return 'No saved private key. Edit the host to add one.';
        }
        final passphrase = saved?.passphrase ?? '';
        if (passphrase.isEmpty) {
          try {
            if (SSHKeyPair.isEncryptedPem(pem)) {
              return 'The key\'s passphrase is not saved, and nobody is asked '
                  'for it here.';
            }
          } catch (_) {
            // Unreadable: the dial says so properly.
          }
        }
        return null;
    }
  }

  /// [command] as the exec request carries it.
  ///
  /// The command runs as `"$SHELL" -c command` — the account's own shell,
  /// the way `ssh host 'command'` runs it — in the background, with no
  /// stdin, under `setsid` where there is one so that it and everything it
  /// starts form a process group of their own. Beside it a `cat` waits on
  /// the channel's stdin, saved on fd 3 (a background job's own stdin is
  /// `/dev/null`). When this app stops the run it closes stdin, `cat`
  /// returns, and that group is sent TERM: the command and its children,
  /// never the SSH server's own processes, whatever group the server put
  /// the exec in. Without `setsid` only the command's shell is signalled.
  /// A command that finishes on its own takes the waiting `cat` down with
  /// it instead, so a daemon it started with `&` is left running.
  ///
  /// The command reaches the server as the wrapper's `$1`, quoted once.
  static String wrap(String command) {
    const wrapper = r'''exec 3<&0
if command -v setsid >/dev/null 2>&1; then
  setsid "${SHELL:-/bin/sh}" -c "$1" 3<&- &
  p=$!
  t="-$p"
else
  "${SHELL:-/bin/sh}" -c "$1" 3<&- &
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
    return 'sh -c ${posixSingleQuote(wrapper)} ssg-fleet '
        '${posixSingleQuote(command)}';
  }

  void _publish({bool now = false}) {
    if (_controller.isClosed) return;
    if (now) {
      _publishTimer?.cancel();
      _publishTimer = null;
      _controller.add(hosts);
      return;
    }
    _publishTimer ??= Timer(const Duration(milliseconds: 80), () {
      _publishTimer = null;
      if (!_controller.isClosed) _controller.add(hosts);
    });
  }

  static String _messageOf(Object e) =>
      e is SshConnectionException ? e.message : e.toString();

  /// Releases [changes]. Stops nothing — call [cancel] first for that.
  void dispose() {
    _publishTimer?.cancel();
    if (!_controller.isClosed) unawaited(_controller.close());
  }
}
