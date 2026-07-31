import 'dart:async';
import 'dart:convert';

import 'remote_exec.dart';
import 'ssh_service.dart';

/// One row of `ps`.
class RemoteProcess {
  const RemoteProcess({
    required this.pid,
    required this.user,
    required this.cpuPercent,
    required this.memoryPercent,
    required this.command,
  });

  final int pid;
  final String user;
  final double cpuPercent;
  final double memoryPercent;

  /// The command name. `comm` gives the executable's short name; the `ps aux`
  /// fallback gives the full argv, which is longer but no less true.
  final String command;

  /// PID 1 is init — systemd, or whatever the container's entrypoint is.
  /// Killing it takes the whole machine or container down, so the UI never
  /// offers to, and this is where that fact is stated once.
  bool get isInit => pid == 1;
}

/// What the list is ordered by.
enum ProcessSort { cpu, memory, pid, user, command }

/// The commands, separate from execution so both forms can be asserted.
class ProcessCommands {
  const ProcessCommands._();

  /// The portable form. `-e` is every process, `-o` names exactly the five
  /// fields wanted, and the whole thing is POSIX apart from `--sort`, which
  /// is why there is a fallback.
  ///
  /// `--sort=-pcpu` is a procps extension: busybox and BSD `ps` reject it.
  /// The sort is redone locally anyway (see [sortProcesses]) — asking the
  /// server for it just means the *truncated* view a very long list gets is
  /// the interesting end of it.
  static const String preferred =
      'ps -eo pid,user,pcpu,pmem,comm --sort=-pcpu';

  /// The fallback, for a `ps` that refuses `--sort` or `-o`. BSD-style flags
  /// with no dash, understood by procps, busybox and macOS alike.
  static const String fallback = 'ps aux';

  /// `kill -TERM` / `kill -KILL`.
  ///
  /// [pid] is an `int`, so unlike a path or a unit name it cannot carry shell
  /// metacharacters — there is nothing here for `posixSingleQuote` to do that
  /// the type system has not already done. Guarded against PID 1 and against
  /// non-positive values, which in `kill` are not PIDs at all: `kill -TERM 0`
  /// signals *every process in the group*, and `-1` signals every process the
  /// user can reach. Those are the two ways this feature could take down a
  /// server by accident, and neither is reachable from here.
  static String kill(int pid, {required bool force}) {
    if (pid <= 1) {
      throw ArgumentError.value(pid, 'pid', 'refusing to signal this pid');
    }
    return 'kill -${force ? 'KILL' : 'TERM'} $pid';
  }
}

/// Parses either `ps -eo pid,user,pcpu,pmem,comm` or `ps aux`, deciding which
/// from the header rather than from which command was asked for — a server
/// that silently ignored the `-o` and printed its default format would
/// otherwise be parsed against the wrong columns, which is exactly the class
/// of confidently-wrong number this phase avoids.
///
/// Pure and total. An unparseable row is skipped.
List<RemoteProcess> parseProcessList(String output) {
  final lines = const LineSplitter().convert(output);
  var headerSeen = false;
  var auxFormat = false;
  final processes = <RemoteProcess>[];

  for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty) continue;

    if (!headerSeen) {
      final upper = line.toUpperCase();
      // Both headers start with a recognisable field name. `ps aux` leads
      // with USER, the `-o` form with PID.
      if (upper.startsWith('USER') && upper.contains('PID')) {
        headerSeen = true;
        auxFormat = true;
        continue;
      }
      if (upper.startsWith('PID') && upper.contains('USER')) {
        headerSeen = true;
        auxFormat = false;
        continue;
      }
      // No header at all (some busybox builds with certain flags): fall
      // through and try to parse it as a row in the -o order.
      headerSeen = true;
    }

    final process =
        auxFormat ? _parseAuxRow(line) : _parseColumnRow(line);
    if (process != null) processes.add(process);
  }
  return processes;
}

/// `  PID USER  %CPU %MEM COMMAND` — four fixed fields then the command,
/// which may itself contain spaces.
RemoteProcess? _parseColumnRow(String line) {
  final fields = line.split(RegExp(r'\s+'));
  if (fields.length < 5) return null;

  final pid = int.tryParse(fields[0]);
  final cpu = double.tryParse(fields[2]);
  final memory = double.tryParse(fields[3]);
  if (pid == null || pid < 0 || cpu == null || memory == null) return null;

  return RemoteProcess(
    pid: pid,
    user: fields[1],
    cpuPercent: cpu,
    memoryPercent: memory,
    command: fields.skip(4).join(' '),
  );
}

/// `USER PID %CPU %MEM VSZ RSS TTY STAT START TIME COMMAND` — eleven fields,
/// the last of which is the full command line.
RemoteProcess? _parseAuxRow(String line) {
  final fields = line.split(RegExp(r'\s+'));
  if (fields.length < 11) return null;

  final pid = int.tryParse(fields[1]);
  final cpu = double.tryParse(fields[2]);
  final memory = double.tryParse(fields[3]);
  if (pid == null || pid < 0 || cpu == null || memory == null) return null;

  return RemoteProcess(
    pid: pid,
    user: fields[0],
    cpuPercent: cpu,
    memoryPercent: memory,
    command: fields.skip(10).join(' '),
  );
}

/// Orders processes locally. Pure, so the sortable list is testable without a
/// widget, and stable enough that re-sorting a refreshed list does not make
/// rows jitter between equal values.
List<RemoteProcess> sortProcesses(
  List<RemoteProcess> processes,
  ProcessSort by, {
  bool descending = true,
}) {
  final sorted = List<RemoteProcess>.of(processes);
  int compare(RemoteProcess a, RemoteProcess b) {
    final result = switch (by) {
      ProcessSort.cpu => a.cpuPercent.compareTo(b.cpuPercent),
      ProcessSort.memory => a.memoryPercent.compareTo(b.memoryPercent),
      ProcessSort.pid => a.pid.compareTo(b.pid),
      ProcessSort.user => a.user.toLowerCase().compareTo(b.user.toLowerCase()),
      ProcessSort.command =>
        a.command.toLowerCase().compareTo(b.command.toLowerCase()),
    };
    // Ties broken by pid so the order is total: without this, two idle
    // processes at 0.0% swap places on every refresh and the list shimmers.
    return result != 0 ? result : a.pid.compareTo(b.pid);
  }

  sorted.sort(descending ? (a, b) => compare(b, a) : compare);
  return sorted;
}

/// Lists and signals processes over a session's existing transport.
class ProcessTableService {
  const ProcessTableService();

  /// Reads the process table, preferring the explicit-column form and falling
  /// back to `ps aux` when the server's `ps` will not take it.
  ///
  /// The fallback triggers on an empty parse as well as on a non-zero exit:
  /// a `ps` that accepts the flags and prints nothing useful has failed just
  /// as completely as one that refused them, and the second command costs a
  /// single round trip on a screen that is not on a timer.
  Future<List<RemoteProcess>> list(SessionTransport transport) async {
    final preferred =
        await RemoteExec.run(transport, ProcessCommands.preferred);
    if (preferred.succeeded) {
      final parsed = parseProcessList(preferred.stdout);
      if (parsed.isNotEmpty) return parsed;
    }

    final fallback =
        await RemoteExec.run(transport, ProcessCommands.fallback);
    if (!fallback.succeeded) {
      throw monitorFailureFrom(fallback, 'Could not list processes');
    }
    final parsed = parseProcessList(fallback.stdout);
    if (parsed.isEmpty) {
      throw const MonitorFailure(
        'This server\'s ps produced nothing we could read.',
      );
    }
    return parsed;
  }

  /// Signals [pid]. TERM by default; [force] sends KILL.
  ///
  /// The caller must have confirmed with the user first, naming the process —
  /// see `services_screen.dart`. This refuses PID 1 outright rather than
  /// trusting that every future caller will remember to.
  Future<void> kill(
    SessionTransport transport,
    int pid, {
    bool force = false,
  }) async {
    final command = ProcessCommands.kill(pid, force: force);
    final result = await RemoteExec.run(transport, command);
    if (!result.succeeded) {
      throw monitorFailureFrom(result, 'Could not signal process $pid');
    }
  }
}
