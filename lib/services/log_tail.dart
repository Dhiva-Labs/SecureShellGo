import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

import 'remote_exec.dart';
import 'shell_quote.dart';
import 'ssh_service.dart';

/// The command the viewer runs, kept separate from execution so the quoting
/// can be asserted character-for-character against a hostile path.
class LogTailCommands {
  const LogTailCommands._();

  /// How much history is pulled before following. Enough to give a failure
  /// some context, small enough to render instantly on a phone.
  static const int defaultHistoryLines = 200;

  /// `tail -n <lines> -F <path>`, wrapped in a watchdog that guarantees the
  /// remote process dies when this app lets go of the channel.
  ///
  /// **The quoting is the security-critical part.** [path] comes from a
  /// directory listing on a machine we do not control, so it is attacker-
  /// controlled text: a file genuinely named `; rm -rf ~ #` is a legal
  /// filename on every unix. It reaches the command only through
  /// [posixSingleQuote] — never string interpolation — which is the same
  /// treatment `public_key_push.dart` gives a public-key comment, and for the
  /// same reason. `log_tail_test.dart` runs a hostile path through a real
  /// `sh` and proves nothing inside it executes.
  ///
  /// **Why the watchdog.** `-F` never exits: it follows the file forever, and
  /// through a rename or a logrotate. Closing the channel *ought* to be
  /// enough to reap it, but the guarantee is weaker than it looks — with no
  /// PTY on the channel there is no process group to hang up, and a `tail` on
  /// a quiet file never writes, so it never gets the `SIGPIPE` that would
  /// otherwise tell it the reader is gone. It would sit on the server
  /// indefinitely, holding an inode against a logrotate.
  ///
  /// So the command carries its own reaper: `tail` runs in the background,
  /// `cat >/dev/null` blocks on stdin, and when this app closes stdin — which
  /// [LogTailSession.dispose] does explicitly, before closing the channel —
  /// `cat` reaches EOF and the `kill` runs. That turns "no orphan" from a
  /// property of the server's sshd into a property of this command.
  ///
  /// Everything in it is POSIX: `$!`, `$()`-free, `kill` is a shell builtin,
  /// and `cat` is on every system that has a shell at all.
  static String tail(String path, {int lines = defaultHistoryLines}) {
    final quoted = posixSingleQuote(path);
    // `lines` is an int, so it cannot carry shell metacharacters; it is still
    // clamped, because a negative or absurd value would be passed to `tail`
    // as a flag-shaped argument.
    final history = lines < 1 ? 1 : (lines > 10000 ? 10000 : lines);
    return 'tail -n $history -F $quoted & '
        'p=\$!; cat >/dev/null; kill \$p 2>/dev/null';
  }

  /// Checks a path is a readable regular file before the viewer opens on it.
  ///
  /// Worth a round trip: `tail -F` on a directory or a missing file prints
  /// one line to stderr and then follows nothing at all, which on screen is
  /// indistinguishable from a log file that happens to be quiet. Asking first
  /// means the viewer can refuse with a reason instead of showing an empty
  /// pane forever.
  static String probeReadable(String path) {
    final quoted = posixSingleQuote(path);
    return 'test -f $quoted && test -r $quoted';
  }
}

/// How a line should be coloured. Deliberately coarse — three buckets, not a
/// log-level taxonomy — because the rules have to hold across every log
/// format at once and a rule that is wrong is worse than no colour.
enum LogSeverity {
  /// ERROR, FATAL, CRIT, PANIC, SEVERE, EMERG, ALERT.
  error,

  /// WARN / WARNING.
  warning,

  /// INFO, DEBUG, TRACE, NOTICE — dimmed, because they are the background
  /// noise the eye should skip past on the way to the two above.
  info,

  /// Anything unclassified. Rendered in the theme's plain foreground.
  plain,
}

/// Word-boundary matches only, and case-insensitive.
///
/// The boundary is what stops `/var/log/terrorlog` or a hostname like
/// `warnier` from painting a line red. Matching anywhere in the line — rather
/// than only in a leading level field — is the deliberate trade: log formats
/// put the level in too many different places to pin down, and a missed
/// highlight is a worse failure here than an occasional generous one.
final RegExp _errorPattern = RegExp(
  r'\b(ERROR|ERR|FATAL|CRIT|CRITICAL|PANIC|SEVERE|EMERG|EMERGENCY|ALERT)\b',
  caseSensitive: false,
);
final RegExp _warnPattern = RegExp(
  r'\b(WARN|WARNING)\b',
  caseSensitive: false,
);
final RegExp _infoPattern = RegExp(
  r'\b(INFO|DEBUG|TRACE|NOTICE)\b',
  caseSensitive: false,
);

/// Classifies one line. Pure, total, and checked in severity order so a line
/// carrying both "INFO" and "ERROR" reads as the more serious of the two.
LogSeverity classifyLogLine(String line) {
  if (_errorPattern.hasMatch(line)) return LogSeverity.error;
  if (_warnPattern.hasMatch(line)) return LogSeverity.warning;
  if (_infoPattern.hasMatch(line)) return LogSeverity.info;
  return LogSeverity.plain;
}

/// One line of scrollback, with its severity resolved once at ingest rather
/// than on every rebuild — the buffer is redrawn far more often than it is
/// appended to.
class LogLine {
  LogLine(this.text) : severity = classifyLogLine(text);

  final String text;
  final LogSeverity severity;
}

/// Reassembles lines from arbitrary byte chunks.
///
/// A channel hands over whatever happened to arrive in a packet, which splits
/// mid-line and mid-character. Decoding is done by the caller through a
/// chunked UTF-8 converter (see [LogTailSession]) so multi-byte characters
/// survive the split; this handles the other half — holding a partial last
/// line back until its newline arrives, so a timestamp never appears cut in
/// two and then repaired on the next frame.
class LineAssembler {
  final StringBuffer _partial = StringBuffer();

  /// Splits [chunk] into whole lines, keeping any trailing fragment for next
  /// time. `\r\n` and a bare `\r` both count as line ends — a log written by
  /// a Windows-side process, or one with a progress bar in it, otherwise
  /// arrives as one enormous line.
  List<String> add(String chunk) {
    _partial.write(chunk);
    final text = _partial.toString();
    _partial.clear();

    final parts = text.split(RegExp(r'\r\n|\r|\n'));
    // The last element is either a fragment awaiting its newline, or the
    // empty string left behind when the chunk ended exactly on one.
    final tail = parts.removeLast();
    _partial.write(tail);
    return parts;
  }

  /// Whatever is left when the stream ends — a final line with no trailing
  /// newline, which is common when a process is killed mid-write.
  List<String> flush() {
    final rest = _partial.toString();
    _partial.clear();
    return rest.isEmpty ? const [] : [rest];
  }
}

/// The scrollback: capped, pausable, filterable.
///
/// Pure Dart and free of any channel, so every rule below is unit-testable by
/// calling [add] in a loop.
class LogBuffer {
  LogBuffer({this.capacity = defaultCapacity});

  /// 5000 lines. A log doing 100 lines a second fills this in under a minute,
  /// which is the point: the cap is what stops a busy server from turning the
  /// viewer into an out-of-memory crash.
  static const int defaultCapacity = 5000;

  final int capacity;

  final List<LogLine> _lines = [];
  final List<LogLine> _pending = [];

  var _paused = false;
  var _filter = '';

  /// Every line held, ignoring the filter. The filter is a lens, never a
  /// deletion — clearing it brings the hidden lines straight back, which is
  /// what makes it safe to type into while output is streaming.
  List<LogLine> get lines => List.unmodifiable(_lines);

  /// The lines the view should draw: everything when the filter is empty,
  /// otherwise those containing it.
  List<LogLine> get visible {
    if (_filter.isEmpty) return List.unmodifiable(_lines);
    final needle = _filter.toLowerCase();
    return List.unmodifiable(
      _lines.where((line) => line.text.toLowerCase().contains(needle)),
    );
  }

  /// Plain text, case-insensitive, no regex.
  ///
  /// A regex box would be a nicer toy and a worse tool: a half-typed pattern
  /// is a syntax error, and the box is typed into *while* lines are arriving.
  /// Plain substring matching has no invalid states.
  String get filter => _filter;

  set filter(String value) => _filter = value.trim();

  bool get isPaused => _paused;

  /// How many lines have arrived since the pause. What the "N new lines"
  /// indicator shows.
  int get pendingCount => _pending.length;

  int get length => _lines.length;

  bool get isEmpty => _lines.isEmpty;

  /// Holds new lines back without dropping them. They keep accumulating —
  /// against the same [capacity], so a pause left on overnight cannot grow
  /// without bound either.
  void pause() => _paused = true;

  /// Releases everything buffered during the pause, in arrival order.
  void resume() {
    _paused = false;
    if (_pending.isEmpty) return;
    for (final line in _pending) {
      _append(line);
    }
    _pending.clear();
  }

  void add(String text) {
    final line = LogLine(text);
    if (_paused) {
      _pending.add(line);
      // The paused queue is capped too, and drops from the head like the main
      // buffer: the alternative is a viewer that was paused and forgotten
      // taking the app down.
      while (_pending.length > capacity) {
        _pending.removeAt(0);
      }
      return;
    }
    _append(line);
  }

  void addAll(Iterable<String> texts) {
    for (final text in texts) {
      add(text);
    }
  }

  void _append(LogLine line) {
    _lines.add(line);
    // Drop from the head: the newest lines are the ones being watched, and
    // the oldest are the ones already scrolled past.
    while (_lines.length > capacity) {
      _lines.removeAt(0);
    }
  }

  /// Empties everything, including anything held by a pause. Does not touch
  /// the filter — clearing is about the content, and retyping a filter the
  /// user did not ask to lose would be its own small annoyance.
  void clear() {
    _lines.clear();
    _pending.clear();
  }
}

/// A live `tail -F` on one remote file.
///
/// Owns exactly one exec channel and guarantees it does not outlive this
/// object — see [dispose] and the watchdog described on
/// [LogTailCommands.tail].
class LogTailSession {
  LogTailSession._(this._session, this.path);

  /// Opens the tail. Verifies the path is a readable regular file first, so
  /// a typo or a directory fails with a sentence rather than an empty pane.
  static Future<LogTailSession> open(
    SessionTransport transport,
    String path, {
    int historyLines = LogTailCommands.defaultHistoryLines,
  }) async {
    final ExecResult check;
    try {
      check = await RemoteExec.run(
        transport,
        LogTailCommands.probeReadable(path),
      );
    } catch (e) {
      throw MonitorFailure(
        'Could not reach the server to open that file.',
        details: e.toString(),
      );
    }
    if (!check.succeeded) {
      throw MonitorFailure(
        'Cannot read $path — it is not a readable file on this server.',
        needsPrivilege: check.looksLikePermissionDenied,
      );
    }

    final SSHSession session;
    try {
      session = await transport.execute(
        LogTailCommands.tail(path, lines: historyLines),
      );
    } catch (e) {
      throw MonitorFailure(
        'Could not start tail on the server.',
        details: e.toString(),
      );
    }
    return LogTailSession._(session, path);
  }

  final SSHSession _session;
  final String path;

  final LineAssembler _stdout = LineAssembler();
  final LineAssembler _stderr = LineAssembler();
  final _lines = StreamController<String>.broadcast();
  final List<StreamSubscription<void>> _subscriptions = [];

  var _disposed = false;
  var _started = false;

  /// Whole lines, as they arrive. stderr is folded in — `tail -F` announces a
  /// truncation or a logrotate there, and those belong in the scrollback
  /// beside the lines they explain rather than being silently dropped.
  Stream<String> get lines => _lines.stream;

  /// Completes when the remote command ends on its own — the file's
  /// filesystem going away, or somebody killing the process server-side.
  Future<void> get done => _session.done;

  /// Begins pumping. Separate from [open] so a caller can subscribe to
  /// [lines] before the first chunk arrives and cannot miss the history that
  /// `-n 200` delivers immediately.
  void start() {
    if (_started || _disposed) return;
    _started = true;

    // Chunked UTF-8, not `utf8.decode` per chunk: a multi-byte character
    // straddling a packet boundary would otherwise come out as replacement
    // characters. Same reasoning as `SessionController._openShell`.
    const decoder = Utf8Decoder(allowMalformed: true);

    _subscriptions.add(
      _session.stdout.cast<List<int>>().transform(decoder).listen(
            (chunk) => _emit(_stdout.add(chunk)),
            onError: (Object _) {},
            onDone: () => _emit(_stdout.flush()),
            cancelOnError: false,
          ),
    );
    _subscriptions.add(
      _session.stderr.cast<List<int>>().transform(decoder).listen(
            (chunk) => _emit(_stderr.add(chunk)),
            onError: (Object _) {},
            onDone: () => _emit(_stderr.flush()),
            cancelOnError: false,
          ),
    );
  }

  void _emit(List<String> lines) {
    if (_disposed || _lines.isClosed) return;
    for (final line in lines) {
      _lines.add(line);
    }
  }

  /// Kills the remote `tail` and releases the channel. Idempotent.
  ///
  /// The order matters and is the whole no-orphan guarantee: closing **stdin
  /// first** is what lets the watchdog's `cat` reach EOF and run its `kill`,
  /// and only then is the channel closed. Closing the channel alone would
  /// leave a `tail -F` on a quiet file running on the server with nothing
  /// left to notice.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    try {
      await _session.stdin.close();
    } catch (_) {
      // Channel already gone — the server has reaped it for us.
    }

    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();

    try {
      _session.close();
    } catch (_) {
      // Already closed.
    }

    await _lines.close();
  }
}
