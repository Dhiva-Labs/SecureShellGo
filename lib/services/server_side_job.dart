import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../models/host.dart';
import 'app_data_paths.dart';
import 'atomic_file.dart';

/// A direct server-to-server copy running as a background job on the source
/// server, so it finishes whether or not this app is still there.
///
/// **Why a job.** The direct path's `sftp` used to run inside an exec channel
/// this app held open, so closing the app — or Android reclaiming it, or the
/// phone losing signal — killed a copy whose bytes never touched the phone in
/// the first place. Now the source runs `sftp` detached (`setsid`, or
/// `nohup` where there is none), in a job folder of its own:
///
///   `~/.cache/secureshellgo/jobs/<id>/`
///     `batch` — the sftp batch, written from the exec's stdin
///     `kh`    — the one pinned host key (see `direct_remote_copy.dart`)
///     `log`   — sftp's stdout and stderr
///     `pid`   — the detached runner, for Cancel
///     `exit`  — sftp's exit code, written (via a rename) when it finishes
///
/// The app holds the agent-forwarded connection only until `sftp` has signed
/// in to the destination, which is the one moment it needs the forwarded
/// key, and then hangs up. From there the source does the work alone; the
/// app asks for `exit` over its ordinary session while it is around, and,
/// when it is not, picks the job up again from a [ServerJobRecord] the next
/// time the source is opened.
class ServerSideJob {
  const ServerSideJob._();

  /// A fresh job id: 128 random bits as hex, safe to put in a path unquoted.
  static String newId([Random? random]) {
    final r = random ?? Random.secure();
    return List<String>.generate(
      16,
      (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  /// Printed by [launchCommand] once `sftp` is past sign-in (or finished).
  static const String startedMarker = 'SSG-JOB-STARTED';
  static const String doneMarker = 'SSG-JOB-DONE';
  static const String timeoutMarker = 'SSG-JOB-TIMEOUT';

  static final RegExp _idPattern = RegExp(r'^[0-9a-f]{32}$');

  static String _dir(String jobId) {
    // The id goes into shell text unquoted inside a double-quoted string;
    // refusing anything but hex is what makes that safe.
    if (!_idPattern.hasMatch(jobId)) {
      throw ArgumentError.value(jobId, 'jobId', 'not a job id');
    }
    return r'$HOME/.cache/secureshellgo/jobs/' + jobId;
  }

  /// The command the agent-forwarded exec runs: set up the job folder, read
  /// the batch from stdin, start `sftp` detached, and wait — at most about a
  /// minute — for it to get past sign-in.
  ///
  /// `sftp` echoes each batch command as `sftp> …` once it is connected,
  /// which is the "past sign-in" signal here. The app also watches its own
  /// agent for the sign request and may hang up as soon as that has been
  /// answered; either way the detached job is unaffected.
  static String launchCommand({
    required String jobId,
    required Host destHost,
    required List<String> pinnedKnownHosts,
  }) {
    final d = _dir(jobId);
    final lines = pinnedKnownHosts.map(shellQuote).join(' ');
    final target = shellQuote('${destHost.username}@${destHost.hostname}');
    final script = '''
d="$d"
umask 077
mkdir -p "\$d" || exit 70
cat > "\$d/batch" || exit 70
printf '%s\\n' $lines > "\$d/kh" || exit 70
if command -v setsid >/dev/null 2>&1; then detach=setsid; else detach=nohup; fi
\$detach sh -c 'd="\$1"; shift; sftp -b "\$d/batch" "\$@" > "\$d/log" 2>&1; echo \$? > "\$d/exit.tmp"; mv "\$d/exit.tmp" "\$d/exit"' ssg-job "\$d" -P ${destHost.port} -o BatchMode=yes -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o StrictHostKeyChecking=yes -o UserKnownHostsFile="\$d/kh" -o GlobalKnownHostsFile=/dev/null -o ServerAliveInterval=30 -o ServerAliveCountMax=4 $target < /dev/null > /dev/null 2>&1 &
echo \$! > "\$d/pid"
n=0
while [ \$n -lt 300 ]; do
  if [ -f "\$d/exit" ]; then echo $doneMarker; exit 0; fi
  if grep -q '^sftp> ' "\$d/log" 2>/dev/null; then echo $startedMarker; exit 0; fi
  sleep 0.2 2>/dev/null || sleep 1
  n=\$((n + 1))
done
echo $timeoutMarker''';
    return 'sh -c ${shellQuote(script)}';
  }

  /// Prints `EXIT <code>` once the job has finished, `RUNNING` while its
  /// runner is alive, `GONE` when neither (the source rebooted, or something
  /// killed it), then `---` and the last lines of the log.
  static String statusCommand(String jobId) {
    final d = _dir(jobId);
    final script = '''
d="$d"
if [ -f "\$d/exit" ]; then echo "EXIT \$(cat "\$d/exit")"
elif [ -f "\$d/pid" ] && kill -0 "\$(cat "\$d/pid")" 2>/dev/null; then echo RUNNING
else echo GONE; fi
echo ---
tail -n 20 "\$d/log" 2>/dev/null''';
    return 'sh -c ${shellQuote(script)}';
  }

  /// Stops the job — its whole process group where `setsid` made one — and
  /// removes its folder.
  static String cancelCommand(String jobId) {
    final d = _dir(jobId);
    final script = '''
d="$d"
if [ -f "\$d/pid" ]; then
  p="\$(cat "\$d/pid")"
  if ! kill -s TERM -- "-\$p" 2>/dev/null; then
    pkill -TERM -P "\$p" 2>/dev/null
    kill -TERM "\$p" 2>/dev/null
  fi
fi
rm -rf "\$d"''';
    return 'sh -c ${shellQuote(script)}';
  }

  /// Removes a finished job's folder.
  static String cleanupCommand(String jobId) =>
      'sh -c ${shellQuote('rm -rf "${_dir(jobId)}"')}';

  /// Reads [statusCommand]'s output.
  static ServerJobStatus parseStatus(String output) {
    final split = output.indexOf('\n---');
    final head = (split < 0 ? output : output.substring(0, split)).trim();
    final log = split < 0
        ? ''
        : output.substring(split + 4).replaceFirst(RegExp(r'^\n'), '').trim();
    if (head.startsWith('EXIT ')) {
      final code = int.tryParse(head.substring(5).trim());
      return ServerJobStatus(
        state: ServerJobState.finished,
        exitCode: code ?? -1,
        log: log,
      );
    }
    if (head == 'RUNNING') {
      return ServerJobStatus(state: ServerJobState.running, log: log);
    }
    return ServerJobStatus(state: ServerJobState.gone, log: log);
  }

  static String shellQuote(String s) => "'${s.replaceAll("'", "'\"'\"'")}'";
}

enum ServerJobState { running, finished, gone }

class ServerJobStatus {
  const ServerJobStatus({required this.state, this.exitCode, this.log = ''});

  final ServerJobState state;

  /// `sftp`'s exit code; set only when [state] is [ServerJobState.finished].
  final int? exitCode;

  /// The tail of the job's log, for an error message.
  final String log;
}

/// What this device remembers about a server-side copy it started, so the
/// copy can be followed — and finished — after the app has been closed.
///
/// "Finished" matters: the bytes are the source server's business, but the
/// steps after them stay with the app, because each needs a check only it
/// can make. It confirms the copy over its own trusted connection to the
/// destination, swaps a replaced folder in, and deletes the source of a
/// move — never before the copy is verified. Until then the original is
/// left exactly where it was.
class ServerJobRecord {
  const ServerJobRecord({
    required this.jobId,
    required this.stamp,
    required this.sourceHostId,
    required this.sourceLabel,
    required this.destinationHostId,
    required this.destinationLabel,
    required this.sourcePath,
    required this.destinationPath,
    required this.name,
    required this.isDirectory,
    required this.moveSource,
    required this.overwrite,
    required this.startedAt,
    this.totalBytes,
  });

  final String jobId;

  /// Names the destination temp file or staging folder, so a resumed run
  /// finds what the job wrote. See `direct_remote_copy.dart`.
  final int stamp;
  final String sourceHostId;
  final String sourceLabel;
  final String destinationHostId;
  final String destinationLabel;
  final String sourcePath;
  final String destinationPath;
  final String name;
  final bool isDirectory;
  final bool moveSource;
  final bool overwrite;
  final DateTime startedAt;
  final int? totalBytes;

  Map<String, dynamic> toJson() => {
        'jobId': jobId,
        'stamp': stamp,
        'sourceHostId': sourceHostId,
        'sourceLabel': sourceLabel,
        'destinationHostId': destinationHostId,
        'destinationLabel': destinationLabel,
        'sourcePath': sourcePath,
        'destinationPath': destinationPath,
        'name': name,
        'isDirectory': isDirectory,
        'moveSource': moveSource,
        'overwrite': overwrite,
        'startedAt': startedAt.toIso8601String(),
        if (totalBytes != null) 'totalBytes': totalBytes,
      };

  static ServerJobRecord? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    try {
      return ServerJobRecord(
        jobId: json['jobId'] as String,
        stamp: (json['stamp'] as num).toInt(),
        sourceHostId: json['sourceHostId'] as String,
        sourceLabel: json['sourceLabel'] as String? ?? '',
        destinationHostId: json['destinationHostId'] as String,
        destinationLabel: json['destinationLabel'] as String? ?? '',
        sourcePath: json['sourcePath'] as String,
        destinationPath: json['destinationPath'] as String,
        name: json['name'] as String,
        isDirectory: json['isDirectory'] as bool? ?? false,
        moveSource: json['moveSource'] as bool? ?? false,
        overwrite: json['overwrite'] as bool? ?? false,
        startedAt: DateTime.tryParse(json['startedAt'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        totalBytes: (json['totalBytes'] as num?)?.toInt(),
      );
    } catch (_) {
      return null;
    }
  }
}

/// The server-side copies this device started and has not yet seen through:
/// a small JSON file beside the host store.
class ServerJobStore {
  /// [file] overrides the on-disk location, for tests.
  // ignore: prefer_initializing_formals
  ServerJobStore({File? file}) : _file = file;

  static const String fileName = 'server_jobs.json';

  File? _file;
  final Map<String, ServerJobRecord> _records = {};
  final SerialFileWriter _writer = SerialFileWriter();
  Future<void>? _loading;
  bool _loaded = false;

  Future<File> _resolveFile() async {
    final existing = _file;
    if (existing != null) return existing;
    final dir = await AppDataPaths.resolveDirectory();
    return _file = File('${dir.path}/$fileName');
  }

  Future<void> _ensureLoaded() {
    if (_loaded) return Future<void>.value();
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<void> _load() async {
    try {
      final file = await _resolveFile();
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        final jobs = decoded is Map<String, dynamic> ? decoded['jobs'] : null;
        if (jobs is List) {
          for (final entry in jobs) {
            final record = ServerJobRecord.fromJson(entry);
            if (record != null) _records[record.jobId] = record;
          }
        }
      }
    } catch (_) {
      _records.clear();
      await setAsideUnreadable(_file);
    } finally {
      _loaded = true;
    }
  }

  Future<void> _persist() => _writer.run(() async {
        final file = await _resolveFile();
        await file.parent.create(recursive: true);
        final payload = jsonEncode({
          'version': 1,
          'jobs': [for (final r in _records.values) r.toJson()],
        });
        await atomicWrite(
          file,
          (temp) => temp.writeAsString(payload, flush: true),
        );
      });

  Future<List<ServerJobRecord>> all() async {
    await _ensureLoaded();
    return _records.values.toList(growable: false);
  }

  Future<void> save(ServerJobRecord record) async {
    await _ensureLoaded();
    _records[record.jobId] = record;
    await _persist();
  }

  Future<void> remove(String jobId) async {
    await _ensureLoaded();
    if (_records.remove(jobId) == null) return;
    await _persist();
  }
}
