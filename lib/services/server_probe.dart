import 'dart:async';
import 'dart:convert';

import 'remote_exec.dart';
import 'session_keepalive.dart' show PeriodicScheduler;
import 'ssh_service.dart';

/// The three load averages, as `uptime` reports them.
class LoadAverage {
  const LoadAverage(this.one, this.five, this.fifteen);

  final double one;
  final double five;
  final double fifteen;

  @override
  String toString() => '$one $five $fifteen';
}

/// Memory, in bytes, reduced to the only three numbers worth showing.
///
/// [used] is deliberately derived as `total - available` rather than taken
/// from any column called "used". On Linux, memory held by the page cache is
/// *available* to the next program that wants it, and a panel that counts it
/// as used tells every user of a healthy server that they are nearly out of
/// memory. `free`'s own modern output makes the same correction; older
/// `free` does not, which is why the parser below prefers `/proc/meminfo`.
class MemoryUsage {
  const MemoryUsage({required this.total, required this.available});

  final int total;
  final int available;

  int get used => total - available;

  /// 0.0–1.0, or null when [total] is zero or nonsensical — a bar cannot be
  /// drawn from a division by zero, and guessing one would be a wrong number.
  double? get usedFraction {
    if (total <= 0) return null;
    final fraction = used / total;
    if (fraction.isNaN || fraction < 0) return null;
    return fraction > 1 ? 1 : fraction;
  }
}

/// One filesystem's usage, in bytes.
///
/// [used] and [available] do not add up to [total] and that is not a bug:
/// every unix filesystem reserves a slice for root, which `df` counts in the
/// total but in neither of the other two. The bar is drawn from [used] over
/// [total] so it matches what `df` itself calls the capacity percentage.
class DiskUsage {
  const DiskUsage({
    required this.mountPoint,
    required this.total,
    required this.used,
    required this.available,
  });

  final String mountPoint;
  final int total;
  final int used;
  final int available;

  double? get usedFraction {
    if (total <= 0) return null;
    final fraction = used / total;
    if (fraction.isNaN || fraction < 0) return null;
    return fraction > 1 ? 1 : fraction;
  }
}

/// Everything one probe pass managed to read. Every field is nullable, and
/// null means exactly one thing: this server did not give us an answer we
/// could trust. The view renders those as "could not read …" per metric
/// rather than failing the panel — a BSD box with no `/proc` still shows its
/// disk, its load and its kernel.
class ServerStats {
  const ServerStats({
    this.uptime,
    this.load,
    this.memory,
    this.disk,
    this.cpuCount,
    this.kernel,
    this.hostname,
  });

  final Duration? uptime;
  final LoadAverage? load;
  final MemoryUsage? memory;
  final DiskUsage? disk;
  final int? cpuCount;
  final String? kernel;
  final String? hostname;

  /// True when nothing at all could be read — the one case the view treats as
  /// a whole-panel failure, because six independent "unknown"s in a row means
  /// the command did not run rather than that the server is unusual.
  bool get isEmpty =>
      uptime == null &&
      load == null &&
      memory == null &&
      disk == null &&
      cpuCount == null &&
      kernel == null &&
      hostname == null;
}

/// The exact shell the probe runs, kept separate from execution so a test can
/// assert it character-for-character without a server.
///
/// **Why one command and not six.** Every section below could be its own exec
/// channel, and that would read more nicely. It would also open six channels
/// every five seconds, on a phone, over a link that may be a train's. One
/// channel per poll, with the sections separated by markers, is the difference
/// between a panel that is free to leave open and one that is not.
///
/// **Why these commands.** Each line is the most portable thing that answers
/// its question, with fallbacks chained by `||` so the first one that works
/// wins:
///
///  * `uname -sr` / `uname -n` — POSIX. `hostname` is not in POSIX and is
///    missing on some minimal images; `uname -n` is the same answer from a
///    utility that is always there.
///  * `/proc/uptime` then `uptime` — the first is two floats and exact; the
///    second is prose and has to be parsed, but it is all a BSD or macOS
///    server has.
///  * `/proc/loadavg` then `uptime` — same trade. Both are emitted rather
///    than one being derived from the other so a kernel-less server still
///    gets its load averages out of the prose form.
///  * `/proc/meminfo` *before* `free -b` — the reverse of the obvious order,
///    on purpose. Old procps `free` prints a "used" that includes the page
///    cache and a header that does not say so, which is a wrong number
///    presented confidently; `MemAvailable` in meminfo is unambiguous on
///    every kernel since 3.14. `free -b` remains the fallback for anything
///    with no `/proc`, and busybox's `free` is fine.
///  * `df -Pk /` — `-P` is the POSIX output format, which guarantees one
///    line per filesystem (without it, a long device name wraps onto a
///    second line and the columns shift); `-k` pins the block size to 1024
///    so the numbers do not silently change meaning under a `BLOCKSIZE`
///    environment variable or BSD's 512-byte default.
///  * `nproc`, then `getconf _NPROCESSORS_ONLN`, then counting
///    `/proc/cpuinfo` — coreutils and busybox have the first, macOS and the
///    BSDs have the second, and the third is the last resort on a Linux box
///    with neither.
///
/// Every fallback chain ends in something that may fail, so the combined
/// command's own exit code is meaningless and the probe ignores it — see
/// [ServerProbe.read].
class ServerProbeCommands {
  const ServerProbeCommands._();

  /// Section marker. Chosen to be something no `df` or `uname` would ever
  /// emit, and matched only at the start of a line.
  static const String marker = '#=ssg=';

  static const String kernelSection = 'kernel';
  static const String hostnameSection = 'host';
  static const String uptimeSection = 'uptime';
  static const String loadSection = 'load';
  static const String memorySection = 'mem';
  static const String diskSection = 'disk';
  static const String cpuSection = 'cpu';

  /// The whole probe, as one POSIX `sh` command line.
  ///
  /// `2>/dev/null` on every member of every chain: a server missing `nproc`
  /// should fall through quietly, not mix "command not found" into output
  /// that is about to be parsed.
  static const String probe = 'echo $marker$kernelSection; '
      'uname -sr 2>/dev/null; '
      'echo $marker$hostnameSection; '
      'uname -n 2>/dev/null; '
      'echo $marker$uptimeSection; '
      'cat /proc/uptime 2>/dev/null || uptime 2>/dev/null; '
      'echo $marker$loadSection; '
      'cat /proc/loadavg 2>/dev/null || uptime 2>/dev/null; '
      'echo $marker$memorySection; '
      'cat /proc/meminfo 2>/dev/null || free -b 2>/dev/null; '
      'echo $marker$diskSection; '
      'df -Pk / 2>/dev/null; '
      'echo $marker$cpuSection; '
      'nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || '
      'grep -c ^processor /proc/cpuinfo 2>/dev/null';
}

/// Splits probe output into its sections.
///
/// Anything before the first marker is discarded — a server with a chatty
/// `.profile` that prints a banner on every non-interactive command is not
/// unusual, and its banner must not end up being parsed as a kernel version.
Map<String, String> splitProbeSections(String output) {
  final sections = <String, String>{};
  String? current;
  final buffer = StringBuffer();

  void flush() {
    final name = current;
    if (name != null) sections[name] = buffer.toString();
    buffer.clear();
  }

  for (final line in const LineSplitter().convert(output)) {
    if (line.startsWith(ServerProbeCommands.marker)) {
      flush();
      current = line.substring(ServerProbeCommands.marker.length).trim();
    } else if (current != null) {
      buffer.writeln(line);
    }
  }
  flush();
  return sections;
}

// ---------------------------------------------------------------- parsers
//
// Every parser below is a pure function from one section's text to a value or
// null, and none of them throws. Null is a first-class answer meaning "this
// server did not tell us"; the callers render it as "could not read …". A
// parser that guesses when it is unsure would be worse than one that admits
// it, because the number would be believed.

/// Uptime from either `/proc/uptime` ("350735.47 234388.90") or the prose
/// `uptime` command prints.
Duration? parseUptime(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;

  // /proc/uptime: seconds since boot as a float, first field. Exact, so it is
  // tried first and its shape is unmistakable — a leading float on a line
  // with at most one other float and nothing alphabetic.
  final proc = RegExp(r'^(\d+(?:\.\d+)?)\s+(\d+(?:\.\d+)?)\s*$')
      .firstMatch(trimmed);
  if (proc != null) {
    final seconds = double.tryParse(proc.group(1)!);
    if (seconds == null || seconds.isNaN || seconds < 0) return null;
    return Duration(seconds: seconds.floor());
  }

  return _parseUptimeProse(trimmed);
}

/// The `uptime`/`w` header line, across the shapes it actually takes:
///
///   Linux    ` 14:23:01 up 3 days,  4:05,  2 users,  load average: 0.0, …`
///   Linux    ` 14:23:01 up 15 min,  1 user,  load average: …`
///   Linux    ` 14:23:01 up 1 day, 23:45,  0 users,  load average: …`
///   busybox  ` 14:23:01 up 0:05, load average: 0.00, 0.00, 0.00`
///   macOS    `14:23  up 10 days,  3:14, 2 users, load averages: 1.2 1.1 1.0`
///   macOS    `14:23  up 3 mins, 1 user, load averages: …`
///
/// So: everything after ` up `, with the users clause and the load clause
/// cut off, is a comma-separated list of `N day(s)`, `N hour(s)`, `N min(s)`
/// and bare `H:MM` pieces.
Duration? _parseUptimeProse(String text) {
  final up = RegExp(r'\bup\s+(.*)$', dotAll: false).firstMatch(text);
  if (up == null) return null;

  var spec = up.group(1)!;
  // Cut the trailing clauses. Both spellings ("load average" on Linux,
  // "load averages" on BSD) are covered by the shorter prefix.
  final loadAt = spec.indexOf('load average');
  if (loadAt >= 0) spec = spec.substring(0, loadAt);
  spec = spec.replaceAll(RegExp(r',?\s*\d+\s+users?\b.*$'), '');

  var days = 0;
  var hours = 0;
  var minutes = 0;
  var matched = false;

  for (final rawPiece in spec.split(',')) {
    final piece = rawPiece.trim();
    if (piece.isEmpty) continue;

    final hhmm = RegExp(r'^(\d+):(\d{1,2})$').firstMatch(piece);
    if (hhmm != null) {
      hours += int.tryParse(hhmm.group(1)!) ?? 0;
      minutes += int.tryParse(hhmm.group(2)!) ?? 0;
      matched = true;
      continue;
    }

    final unit = RegExp(r'^(\d+)\s*(days?|hours?|hrs?|mins?|minutes?)$')
        .firstMatch(piece);
    if (unit != null) {
      final value = int.tryParse(unit.group(1)!) ?? 0;
      final name = unit.group(2)!;
      if (name.startsWith('day')) {
        days += value;
      } else if (name.startsWith('h')) {
        hours += value;
      } else {
        minutes += value;
      }
      matched = true;
    }
  }

  if (!matched) return null;
  return Duration(days: days, hours: hours, minutes: minutes);
}

/// Load averages from `/proc/loadavg` ("0.00 0.01 0.05 1/123 4567") or from
/// the `uptime` prose, which spells the separator differently on BSD (spaces)
/// than on Linux (commas).
LoadAverage? parseLoadAverage(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;

  // /proc/loadavg: three floats at the very start of the content.
  final proc = RegExp(r'^(\d+\.\d+)\s+(\d+\.\d+)\s+(\d+\.\d+)\b')
      .firstMatch(trimmed);
  if (proc != null) return _load(proc.group(1), proc.group(2), proc.group(3));

  // Each number is matched as digits with *at most one* optional decimal
  // separator, rather than as a run of `[\d.,]`. A greedy character class
  // would swallow the comma that separates Linux's own fields — "1.11, 1.32"
  // would parse its first value as "1.11," and then fail to be a number at
  // all, which on a Linux server is every reading.
  final labelled = RegExp(
    r'load averages?:\s*(\d+(?:[.,]\d+)?)[\s,]+'
    r'(\d+(?:[.,]\d+)?)[\s,]+(\d+(?:[.,]\d+)?)',
  ).firstMatch(trimmed);
  if (labelled == null) return null;
  // A locale that writes decimals with commas ("load average: 0,05, 0,03")
  // would otherwise parse as nonsense; the separator has already done its job
  // by the time we get here, so any comma left inside a number is a decimal
  // point.
  return _load(
    labelled.group(1)?.replaceAll(',', '.'),
    labelled.group(2)?.replaceAll(',', '.'),
    labelled.group(3)?.replaceAll(',', '.'),
  );
}

LoadAverage? _load(String? one, String? five, String? fifteen) {
  final a = double.tryParse(one ?? '');
  final b = double.tryParse(five ?? '');
  final c = double.tryParse(fifteen ?? '');
  if (a == null || b == null || c == null) return null;
  if (a.isNaN || b.isNaN || c.isNaN) return null;
  if (a < 0 || b < 0 || c < 0) return null;
  return LoadAverage(a, b, c);
}

/// Memory from `/proc/meminfo` (preferred) or `free -b`.
MemoryUsage? parseMemory(String text) {
  if (text.trim().isEmpty) return null;
  return _parseMemInfo(text) ?? _parseFree(text);
}

/// `/proc/meminfo`, whose lines are `Name:<spaces><value> kB`.
///
/// The unit really is always kB — the kernel hard-codes it, including on
/// architectures with a different page size — but it is checked anyway
/// rather than assumed, because a unit misread by a factor of 1024 is the
/// exact class of wrong number this file exists to avoid.
MemoryUsage? _parseMemInfo(String text) {
  final values = <String, int>{};
  for (final line in const LineSplitter().convert(text)) {
    final match =
        RegExp(r'^(\w+):\s+(\d+)(?:\s+(\w+))?\s*$').firstMatch(line.trim());
    if (match == null) continue;
    final raw = int.tryParse(match.group(2)!);
    if (raw == null) continue;
    final unit = match.group(3)?.toLowerCase();
    final bytes = switch (unit) {
      'kb' => raw * 1024,
      'mb' => raw * 1024 * 1024,
      null => raw,
      _ => null,
    };
    if (bytes != null) values[match.group(1)!] = bytes;
  }

  final total = values['MemTotal'];
  if (total == null || total <= 0) return null;

  // MemAvailable is the kernel's own estimate of what a new program could
  // get without swapping, and is the right number. Kernels before 3.14 do not
  // have it, so free+buffers+cached stands in — the approximation `free`
  // itself used for years.
  final available = values['MemAvailable'] ??
      _sumOrNull([values['MemFree'], values['Buffers'], values['Cached']]);
  if (available == null || available < 0 || available > total) return null;

  return MemoryUsage(total: total, available: available);
}

int? _sumOrNull(List<int?> parts) {
  var total = 0;
  for (final part in parts) {
    if (part == null) return null;
    total += part;
  }
  return total;
}

/// `free -b`, in both the modern layout and the pre-3.3 procps one.
///
///   modern header: `total used free shared buff/cache available`
///   modern row:    `Mem: 16766509056 4123456789 … 11934567890`
///   old header:    `total used free shared buffers cached`
///   old row:       `Mem: 16766509056 8123456789 … 3456789012`
///
/// The header is what tells them apart, and it is read rather than guessed:
/// with an `available` column we use it, and without one we reconstruct the
/// same quantity as free + buffers + cached. Falling back to the `used`
/// column is deliberately *not* an option — that is the number that counts
/// the page cache against the user.
MemoryUsage? _parseFree(String text) {
  final lines = const LineSplitter().convert(text);
  List<String>? header;
  for (final line in lines) {
    final fields = line.trim().split(RegExp(r'\s+'));
    if (fields.isEmpty) continue;

    if (header == null && !fields.first.endsWith(':')) {
      if (fields.any((f) => f.toLowerCase() == 'total')) {
        header = fields.map((f) => f.toLowerCase()).toList();
      }
      continue;
    }

    if (!fields.first.toLowerCase().startsWith('mem')) continue;

    // Column n of the header describes field n+1 of the row, the row having
    // an extra leading "Mem:" label.
    final numbers = fields
        .skip(1)
        .map((f) => int.tryParse(f))
        .toList(growable: false);
    if (header == null || numbers.isEmpty) return null;

    int? column(String name) {
      final index = header!.indexOf(name);
      if (index < 0 || index >= numbers.length) return null;
      return numbers[index];
    }

    final total = column('total');
    if (total == null || total <= 0) return null;

    final available = column('available') ??
        _sumOrNull([
          column('free'),
          column('buffers'),
          column('cached'),
        ]);
    if (available == null || available < 0 || available > total) return null;
    return MemoryUsage(total: total, available: available);
  }
  return null;
}

/// `df -Pk /`. The `-P` format is one line per filesystem with six fields:
/// device, 1024-blocks, used, available, capacity%, mount point.
///
/// The device name is skipped rather than parsed — it can be anything from
/// `/dev/sda1` to `map auto_home` (with a space, on macOS) — and the three
/// numbers are taken as the first three integers on the line, which pins the
/// parse to the columns that matter regardless of what the device is called.
DiskUsage? parseDisk(String text) {
  for (final line in const LineSplitter().convert(text)) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    // The header carries "1024-blocks" (or "1K-blocks"), which contains
    // digits; skipping it by name is more reliable than by position, since a
    // server with no `df` produces no header at all.
    final lower = trimmed.toLowerCase();
    if (lower.startsWith('filesystem') || lower.contains('blocks')) continue;

    final fields = trimmed.split(RegExp(r'\s+'));
    if (fields.length < 5) continue;

    final numbers = <int>[];
    var mountPoint = '/';
    for (final field in fields.skip(1)) {
      final value = int.tryParse(field);
      if (value != null && numbers.length < 3) {
        numbers.add(value);
      } else if (numbers.length == 3 && field.startsWith('/')) {
        mountPoint = field;
        break;
      }
    }
    if (numbers.length < 3) continue;

    final total = numbers[0] * 1024;
    final used = numbers[1] * 1024;
    final available = numbers[2] * 1024;
    if (total <= 0 || used < 0 || available < 0) continue;
    // `used` may legitimately exceed the sum with the root reserve, but it
    // can never exceed the total; a line where it does is not a df row we
    // understand.
    if (used > total) continue;

    return DiskUsage(
      mountPoint: mountPoint,
      total: total,
      used: used,
      available: available,
    );
  }
  return null;
}

/// A bare processor count from `nproc`, `getconf` or `grep -c`.
int? parseCpuCount(String text) {
  for (final line in const LineSplitter().convert(text)) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    final value = int.tryParse(trimmed);
    // `grep -c` prints 0 when /proc/cpuinfo exists but has no `processor`
    // lines, which is not a server with no CPUs — it is a failed probe.
    if (value != null && value > 0 && value < 100000) return value;
  }
  return null;
}

/// A single line of text, or null when the command printed nothing usable.
/// Used for the kernel and hostname, where anything non-empty is the answer.
String? parseSingleLine(String text) {
  for (final line in const LineSplitter().convert(text)) {
    final trimmed = line.trim();
    if (trimmed.isNotEmpty) return trimmed;
  }
  return null;
}

/// Assembles a [ServerStats] from already-split sections. Pure, so the whole
/// probe can be tested against a captured transcript from a real distro
/// without a server anywhere in sight.
ServerStats parseServerStats(String output) {
  final sections = splitProbeSections(output);
  String section(String name) => sections[name] ?? '';

  return ServerStats(
    kernel: parseSingleLine(section(ServerProbeCommands.kernelSection)),
    hostname: parseSingleLine(section(ServerProbeCommands.hostnameSection)),
    uptime: parseUptime(section(ServerProbeCommands.uptimeSection)),
    load: parseLoadAverage(section(ServerProbeCommands.loadSection)),
    memory: parseMemory(section(ServerProbeCommands.memorySection)),
    disk: parseDisk(section(ServerProbeCommands.diskSection)),
    cpuCount: parseCpuCount(section(ServerProbeCommands.cpuSection)),
  );
}

/// Reads a server's vital signs over an exec channel on a session's existing
/// transport.
class ServerProbe {
  const ServerProbe();

  /// Runs the probe once.
  ///
  /// The combined command's exit code is ignored on purpose: it is the status
  /// of the *last* fallback in the CPU chain, which fails routinely on a
  /// server that answered every other section perfectly. What came back on
  /// stdout is the whole result, and [parseServerStats] is responsible for
  /// deciding how much of it was usable.
  ///
  /// Throws [MonitorFailure] only when the channel itself could not be run —
  /// there is a difference between "this server is unusual" and "we could not
  /// ask it anything", and only the second is a panel-level error.
  Future<ServerStats> read(
    SessionTransport transport, {
    Duration timeout = RemoteExec.defaultTimeout,
  }) async {
    final ExecResult result;
    try {
      result = await RemoteExec.run(
        transport,
        ServerProbeCommands.probe,
        timeout: timeout,
      );
    } on MonitorFailure {
      rethrow;
    } catch (e) {
      throw MonitorFailure(
        'Could not run the status commands on this server.',
        details: e.toString(),
      );
    }

    final stats = parseServerStats(result.stdout);
    if (stats.isEmpty) {
      throw MonitorFailure(
        'This server did not answer any of the status commands.',
        details: result.stderr.trim().isEmpty ? null : result.stderr.trim(),
      );
    }
    return stats;
  }
}

/// One reading, plus whatever went wrong getting it.
class StatsSnapshot {
  const StatsSnapshot({this.stats, this.error, this.at});

  /// The last reading that succeeded, kept across a failed refresh so a
  /// momentary blip does not blank a panel the user is reading.
  final ServerStats? stats;

  /// What the most recent attempt failed with, or null when it worked.
  final String? error;

  /// When [stats] was read, so the view can say how stale it is.
  final DateTime? at;

  bool get hasStats => stats != null;
}

/// Polls [ServerProbe] on an interval, for exactly as long as somebody is
/// looking at the result.
///
/// The lifecycle is the whole point of this class, and it is why the polling
/// does not simply live in the view's `State`. The rule from the brief is that
/// nothing polls a server the user is not currently watching: there is no
/// background poller for saved hosts, and the schedule here starts on
/// [start] and stops on [stop], which the view drives from its own
/// visibility. Keeping it out of the widget means the rule is testable —
/// `server_probe_test.dart` starts it, stops it, and asserts the timer is
/// gone and that no further probe runs.
///
/// A tick that lands while the previous probe is still in flight is skipped
/// rather than queued. A server slow enough to take longer than the interval
/// would otherwise accumulate an unbounded backlog of exec channels, which is
/// the failure mode most likely to be blamed on the app rather than the
/// server.
class ServerStatsPoller {
  ServerStatsPoller({
    required SessionTransport Function() transport,
    ServerProbe probe = const ServerProbe(),
    this.interval = defaultInterval,
    PeriodicScheduler scheduler = Timer.periodic,
    this.historyLimit = 60,
  })  : _transport = transport, // ignore: prefer_initializing_formals
        // ignore: prefer_initializing_formals
        _probe = probe,
        // ignore: prefer_initializing_formals
        _scheduler = scheduler;

  /// Five seconds: often enough that load and memory feel live, rare enough
  /// that a phone on mobile data is not paying for it. Not a setting —
  /// see [SessionKeepalive.interval] for the same reasoning about numbers
  /// the user cannot meaningfully choose between.
  static const Duration defaultInterval = Duration(seconds: 5);

  /// Read through a callback rather than held, because a session that
  /// reconnects replaces its transport and a poller holding the old one would
  /// keep probing a dead socket. See `SessionController.adoptTransport`.
  final SessionTransport Function() _transport;
  final ServerProbe _probe;
  final Duration interval;
  final PeriodicScheduler _scheduler;

  /// How many readings the sparkline keeps. In memory, for this session's
  /// open view only — dropped entirely when the poller is disposed.
  final int historyLimit;

  final _changes = StreamController<void>.broadcast();
  final List<double> _loadHistory = [];

  Timer? _timer;
  var _inFlight = false;
  var _disposed = false;

  StatsSnapshot _snapshot = const StatsSnapshot();

  /// The latest reading and/or error.
  StatsSnapshot get snapshot => _snapshot;

  /// One-minute load averages, oldest first, for the sparkline. Capped at
  /// [historyLimit] and never persisted anywhere.
  List<double> get loadHistory => List.unmodifiable(_loadHistory);

  Stream<void> get changes => _changes.stream;

  bool get isRunning => _timer != null;

  /// True while a probe is in flight, so the view can show a spinner on a
  /// manual refresh without inventing its own flag.
  bool get isRefreshing => _inFlight;

  /// Begins polling, and takes a reading immediately rather than waiting out
  /// the first interval — a panel that is blank for five seconds after it
  /// opens reads as broken.
  void start() {
    if (_disposed || _timer != null) return;
    _timer = _scheduler(interval, (_) => unawaited(refresh()));
    unawaited(refresh());
  }

  /// Ends polling. Idempotent, and — unlike [SessionKeepalive.stop] — not
  /// permanent: the view stops this when it is hidden and starts it again
  /// when it comes back, which is the whole lifecycle.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Takes one reading now, whether or not the schedule is running. The
  /// manual refresh button, and the immediate read [start] does.
  Future<void> refresh() async {
    if (_disposed || _inFlight) return;
    _inFlight = true;
    _notify();
    try {
      final stats = await _probe.read(_transport());
      if (_disposed) return;
      _snapshot = StatsSnapshot(stats: stats, error: null, at: DateTime.now());
      _record(stats);
    } on MonitorFailure catch (e) {
      if (_disposed) return;
      // The previous reading is kept deliberately: "load 0.4, as of 20s ago,
      // and the last refresh failed" is more use than an empty panel.
      _snapshot = StatsSnapshot(
        stats: _snapshot.stats,
        error: e.message,
        at: _snapshot.at,
      );
    } catch (e) {
      if (_disposed) return;
      _snapshot = StatsSnapshot(
        stats: _snapshot.stats,
        error: 'Could not read this server: $e',
        at: _snapshot.at,
      );
    } finally {
      _inFlight = false;
      _notify();
    }
  }

  void _record(ServerStats stats) {
    final load = stats.load;
    if (load == null) return;
    _loadHistory.add(load.one);
    // Drop from the head, so the sparkline is always the most recent window
    // and the list cannot grow without bound on a panel left open all day.
    while (_loadHistory.length > historyLimit) {
      _loadHistory.removeAt(0);
    }
  }

  void _notify() {
    if (_disposed || _changes.isClosed) return;
    _changes.add(null);
  }

  /// Stops for good and releases the stream. After this the poller is inert:
  /// an in-flight probe that comes back later finds [_disposed] set and
  /// writes nothing.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    stop();
    _loadHistory.clear();
    await _changes.close();
  }
}
