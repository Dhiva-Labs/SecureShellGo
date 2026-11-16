import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../models/host.dart';
import '../app_data_paths.dart';
import '../atomic_file.dart';
import '../remote_exec.dart';
import '../shell_quote.dart';
import 'bridge_approvals.dart';
import 'bridge_change_tools.dart';
import 'bridge_policy.dart';
import 'bridge_redactor.dart';
import 'bridge_tool_module.dart';
import 'bridge_tool_types.dart';
import 'bridge_tools.dart';

/// The shell text the job tools run on a server, apart from execution so it
/// can be read and tested as it is.
///
/// Every script is POSIX `/bin/sh` and runs as the fixed command inside
/// `BridgeCommands.supervised`. Nothing from the assistant is spliced into
/// a script: the values (the job id, the command, the folder, a line count)
/// arrive as positional parameters set by one `set --` line whose words are
/// each quoted with [posixSingleQuote], which is exact for the `/bin/sh`
/// the supervised wrapper hands this text to. The job id is one the app
/// made ([BridgeJobs.isJobId]), and the folder is only ever used as
/// `cd -- "$5"`.
///
/// A job lives in `~/.cache/secureshellgo/jobs/<id>/` (mode 700):
///
/// - `cmd`: the command, as it was run;
/// - `pid`: the process id of the job's runner, which, where the server has
///   `setsid`, leads a session and process group of its own;
/// - `group`: `1` when that is so, `0` when it is not (see below);
/// - `log`: the command's stdout and stderr together;
/// - `started`: when it started (seconds since the epoch, the server's
///   clock);
/// - `boot`: the server's boot id at start, where Linux has one, so a pid
///   seen after a reboot is never taken for the job;
/// - `exit`: `<status> <ended>`, written by the runner when the command
///   ends (or by `stop_job` when it had to KILL the runner);
/// - `stopped`: present when `stop_job` stopped it.
///
/// The runner is a small `/bin/sh` that starts the command with the
/// account's own shell (`"${SHELL:-/bin/sh}" -c`, as `run_command` does),
/// waits for it, and writes `exit`. A TERM or HUP sent to the runner is
/// passed on to the command. It is started in the background with stdin
/// from `/dev/null` and every output to `log`, so the SSH channel that
/// started it holds nothing of it and closes at once; under `setsid` it is
/// also outside the supervised call's process group, so the end of that
/// call (or a stop of it) never reaches the job.
///
/// Without `setsid` the runner is started under `nohup` in the starting
/// shell's process group: it still outlives the connection, but `stop_job`
/// can only signal the runner (which passes the TERM on to the command),
/// not a whole process group, so what the command started in the
/// background is not reached. That is a documented limit, like the
/// supervised wrapper's.
class BridgeJobCommands {
  const BridgeJobCommands._();

  /// The functions every script shares: where the jobs live, which process
  /// (group) a job's files name, whether it is still there, and one job's
  /// state as `key value` lines.
  ///
  /// `ssg_target` reads `pid` and `group` back from the job folder, which
  /// anything running as the account can rewrite, so it accepts only what
  /// `start` itself writes: a plain decimal pid above 1 and a group of `0`
  /// or `1`. Anything else (`0`, `1`, a minus sign, a leading zero, empty
  /// text) names no job: `kill -- -1` would signal every process the
  /// account may signal, and `kill -- 0` the script's own group.
  static const String _prelude = r'''ssg_root() {
  if [ -n "$1" ]; then r=$1
  elif [ -n "${HOME:-}" ]; then r="$HOME/.cache/secureshellgo/jobs"
  else echo 'ssg-job: HOME is not set on the server' >&2; exit 70
  fi
}
boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
ssg_target() {
  p=$(cat "$d/pid" 2>/dev/null)
  case $p in ''|0*|1|*[!0-9]*) return 1 ;; esac
  case $(cat "$d/group" 2>/dev/null) in
    1) t="-$p" ;;
    0) t=$p ;;
    *) return 1 ;;
  esac
}
ssg_alive() {
  ssg_target || return 1
  b=$(cat "$d/boot" 2>/dev/null)
  [ "$b" = "$boot" ] || return 1
  kill -s 0 -- "$t" 2>/dev/null
}
ssg_exited() {
  echo "exit $(head -n 1 "$d/exit")"
  echo 'state exited'
}
ssg_show() {
  d="$r/$1"
  echo "job $1"
  if [ ! -d "$d" ]; then echo 'state missing'; return 0; fi
  echo "started $(cat "$d/started" 2>/dev/null)"
  if [ -f "$d/stopped" ]; then echo 'stopped 1'; fi
  echo "log $(wc -c < "$d/log" 2>/dev/null | tr -d ' ')"
  if [ -s "$d/exit" ]; then ssg_exited
  elif ssg_alive; then echo 'state running'
  elif [ -s "$d/exit" ]; then ssg_exited
  else echo 'state unknown'; fi
}
''';

  /// What the runner runs: the command with the account's shell, a TERM or
  /// HUP passed on to it, and its status written to `exit` (through a
  /// rename, so a reader never sees half of it). The wait is repeated
  /// while the command is still there after a trapped signal cut it short,
  /// as in `BridgeCommands.supervised`.
  static const String _runner = r'''"${SHELL:-/bin/sh}" -c "$1" &
c=$!
trap 'kill -s TERM -- "$c" 2>/dev/null' TERM
trap 'kill -s HUP -- "$c" 2>/dev/null' HUP
wait "$c"
s=$?
while [ "$s" -gt 128 ] && kill -s 0 -- "$c" 2>/dev/null; do wait "$c"; s=$?; done
if [ "$s" -gt 128 ]; then wait "$c" 2>/dev/null; q=$?; if [ "$q" -ne 127 ]; then s=$q; fi; fi
printf '%s %s\n' "$s" "$(date +%s)" > "$2/exit.tmp"
mv -f -- "$2/exit.tmp" "$2/exit"''';

  /// Exit statuses of [start] when it did not start the job (and left
  /// nothing behind).
  static const int noJobsFolder = 70;
  static const int folderExists = 71;
  static const int noSuchDirectory = 72;

  /// The line [stop] prints when the job's files name no process it may
  /// signal.
  static const String stopRefusedMarker = 'ssg-stop refused';

  /// The marker [start] prints once the job is running.
  static String startedMarker(String id) => 'ssg-job-started $id';

  static String _set(List<String> values) =>
      'set -- ${values.map(posixSingleQuote).join(' ')}\n';

  /// Starts [command] as job [id]. The runner's own text arrives as `$6`,
  /// like every other value. [cwd] null runs it in the home
  /// directory; otherwise the job's folder is entered with `cd -- "$5"`
  /// first, and a folder that cannot be entered starts nothing. [root] is
  /// a test seam: empty means `$HOME/.cache/secureshellgo/jobs`.
  ///
  /// The folders are made owner-only (umask 077); the command itself runs
  /// with the account's own umask, put back before it starts.
  static String start({
    required String id,
    required String command,
    String? cwd,
    String root = '',
  }) =>
      _set([root, id, command, cwd == null ? '0' : '1', cwd ?? '', _runner]) +
      _prelude +
      r'''ssg_root "$1"
id=$2
cmd=$3
m=$(umask)
umask 077
mkdir -p -- "$r" || { echo 'ssg-job: cannot create the jobs folder' >&2; exit 70; }
chmod 700 -- "$r" 2>/dev/null
d="$r/$id"
mkdir -- "$d" || { echo 'ssg-job: a job folder of that id already exists' >&2; exit 71; }
chmod 700 -- "$d"
if [ "$4" = 1 ]; then
  cd -- "$5" 2>/dev/null || { rm -rf -- "$d"; echo 'ssg-job: cannot enter that folder' >&2; exit 72; }
fi
printf '%s\n' "$cmd" > "$d/cmd"
date +%s > "$d/started"
printf '%s\n' "$boot" > "$d/boot"
: > "$d/log"
run=$6
umask "$m"
if command -v setsid >/dev/null 2>&1; then
  echo 1 > "$d/group"
  setsid /bin/sh -c "$run" ssg-job "$cmd" "$d" < /dev/null >> "$d/log" 2>&1 &
else
  echo 0 > "$d/group"
  nohup /bin/sh -c "$run" ssg-job "$cmd" "$d" < /dev/null >> "$d/log" 2>&1 &
fi
echo $! > "$d/pid"
echo "ssg-job-started $id"''';

  /// The server's clock (`now <epoch>`), then one `job <id>` block per id
  /// with its state.
  static String status(List<String> ids, {String root = ''}) =>
      _set([root, ...ids]) +
      _prelude +
      r'''ssg_root "$1"
shift
echo "now $(date +%s)"
for id in "$@"; do ssg_show "$id"; done''';

  /// The log's size (`log <bytes>`), a `--` line, then the last [lines]
  /// lines of the newest [BridgeJobs.outputWindowBytes] of the log; or
  /// `state missing` when the job folder is gone.
  static String output(String id, int lines, {String root = ''}) =>
      _set([root, id, '$lines']) +
      _prelude +
      r'''ssg_root "$1"
d="$r/$2"
if [ ! -d "$d" ]; then echo 'state missing'; exit 0; fi
echo "log $(wc -c < "$d/log" 2>/dev/null | tr -d ' ')"
echo '--'
tail -c ''' +
      '${BridgeJobs.outputWindowBytes}' +
      r''' -- "$d/log" 2>/dev/null | tail -n "$3"''';

  /// TERM to the job's process group (or, without `setsid`, its runner),
  /// KILL after [BridgeCommands.stopGraceSeconds] seconds if anything is
  /// left, then its state as [status] gives it. A job that already ended,
  /// or whose processes are gone, is left as it is. A job whose `pid` or
  /// `group` file holds anything `ssg_target` refuses is not signalled at
  /// all, and [stopRefusedMarker] says so.
  static String stop(String id, {String root = ''}) =>
      _set([root, id]) +
      _prelude +
      r'''ssg_root "$1"
d="$r/$2"
if [ -d "$d" ] && [ ! -s "$d/exit" ] && ! ssg_target; then echo 'ssg-stop refused'; fi
if [ -d "$d" ] && [ ! -s "$d/exit" ] && ssg_alive; then
  date +%s > "$d/stopped"
  kill -s TERM -- "$t" 2>/dev/null
  i=0
  while [ "$i" -lt ''' +
      '${BridgeCommands.stopGraceSeconds}' +
      r''' ] && kill -s 0 -- "$t" 2>/dev/null; do sleep 1; i=$((i+1)); done
  if kill -s 0 -- "$t" 2>/dev/null; then kill -s KILL -- "$t" 2>/dev/null; sleep 1; fi
  if [ ! -s "$d/exit" ]; then printf '%s %s\n' 137 "$(date +%s)" > "$d/exit"; fi
fi
echo "now $(date +%s)"
ssg_show "$2"''';

  /// Deletes the job's folder, only when the job has ended (or its
  /// processes are gone): `removed yes`, `removed no` (still running) or
  /// `removed missing`.
  static String remove(String id, {String root = ''}) =>
      _set([root, id]) +
      _prelude +
      r'''ssg_root "$1"
d="$r/$2"
if [ ! -d "$d" ]; then echo 'removed missing'; exit 0; fi
if [ ! -s "$d/exit" ] && ssg_alive; then echo 'removed no'; exit 0; fi
rm -rf -- "$d" && echo "removed yes"''';
}

/// One job a client started, as the app remembers it: who started it, on
/// which server, when, and under which name. The server's files are the
/// truth about its state; this only says whose it is.
class BridgeJobRecord {
  const BridgeJobRecord({
    required this.id,
    required this.clientId,
    required this.hostId,
    required this.hostname,
    required this.port,
    required this.username,
    required this.transport,
    required this.jumpHostId,
    required this.hostName,
    required this.startedAt,
    this.name,
    this.command = '',
    this.clientName,
  });

  /// The record for a job started now on [host].
  factory BridgeJobRecord.on(
    Host host, {
    required String id,
    required String clientId,
    required String hostName,
    required DateTime startedAt,
    String? name,
    String command = '',
    String? clientName,
  }) => BridgeJobRecord(
    id: id,
    clientId: clientId,
    hostId: host.id,
    hostname: host.hostname,
    port: host.port,
    username: host.username,
    transport: host.transport,
    jumpHostId: host.jumpHostId,
    hostName: hostName,
    startedAt: startedAt,
    name: name,
    command: command,
    clientName: clientName,
  );

  final String id;
  final String clientId;

  /// What `bridgeSameServer` compares, as it was when the job started.
  final String hostId;
  final String hostname;
  final int port;
  final String username;
  final HostTransport transport;
  final String? jumpHostId;

  /// The host's name as the assistant gave it, for the audit entry.
  final String hostName;
  final DateTime startedAt;
  final String? name;

  /// The start of the command (at most [BridgeJobs.recordCommandChars]),
  /// so `list_jobs` can say what a job is.
  final String command;

  /// The assistant's name when it started the job, so the phone and the
  /// approvals screen can say whose it is. Null for a job recorded before
  /// the name was kept.
  final String? clientName;

  /// The server the job runs on, as a [Host] `bridgeSameServer` can
  /// compare with the hosts as they are now.
  Host get server => Host(
    id: hostId,
    label: hostName,
    hostname: hostname,
    port: port,
    username: username,
    authMethod: SshAuthMethod.password,
    transport: transport,
    jumpHostId: jumpHostId,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'client': clientId,
    'hostId': hostId,
    'hostname': hostname,
    'port': port,
    'username': username,
    if (transport != HostTransport.ssh) 'transport': transport.name,
    if (jumpHostId != null) 'jumpHostId': jumpHostId,
    'hostName': hostName,
    'startedAt': startedAt.toUtc().toIso8601String(),
    if (name != null) 'name': name,
    if (command.isNotEmpty) 'command': command,
    if (clientName != null) 'clientName': clientName,
  };

  static BridgeJobRecord? fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final client = json['client'];
    final hostId = json['hostId'];
    final hostname = json['hostname'];
    final port = json['port'];
    final username = json['username'];
    final hostName = json['hostName'];
    final started = json['startedAt'];
    if (id is! String ||
        !BridgeJobs.isJobId(id) ||
        client is! String ||
        hostId is! String ||
        hostname is! String ||
        port is! int ||
        username is! String ||
        hostName is! String ||
        started is! String) {
      return null;
    }
    final at = DateTime.tryParse(started);
    if (at == null) return null;
    final jump = json['jumpHostId'];
    final name = json['name'];
    final command = json['command'];
    final clientName = json['clientName'];
    return BridgeJobRecord(
      id: id,
      clientId: client,
      hostId: hostId,
      hostname: hostname,
      port: port,
      username: username,
      transport: HostTransport.fromName(json['transport'] as String?),
      jumpHostId: jump is String ? jump : null,
      hostName: hostName,
      startedAt: at,
      name: name is String ? name : null,
      command: command is String ? command : '',
      clientName: clientName is String ? clientName : null,
    );
  }
}

/// Which client started which job on which server: `bridge_jobs.json` in
/// the bridge folder (`<appdata>/bridge`), beside the activity log. Plain
/// JSON, owner-only, atomic writes in order, like the other bridge stores;
/// never part of a backup (a job id means nothing to another install).
class BridgeJobRegistry {
  /// [file] overrides the location; tests use it.
  BridgeJobRegistry({File? file})
    // ignore: prefer_initializing_formals
    : _file = file;

  static const String fileName = 'bridge_jobs.json';

  File? _file;
  final SerialFileWriter _writer = SerialFileWriter();
  final Map<String, BridgeJobRecord> _jobs = {};
  final _changes = StreamController<void>.broadcast();
  Future<void>? _loading;
  var _loaded = false;

  /// Every job remembered, oldest first, as of now: what [all] returns
  /// without the wait. Empty until [load] has finished.
  List<BridgeJobRecord> get known => List.unmodifiable(_jobs.values);

  /// Fires after every change of [known]: the file loaded, a job added,
  /// forgotten or pruned.
  Stream<void> get changes => _changes.stream;

  void _changed() {
    if (!_changes.isClosed) _changes.add(null);
  }

  /// Reads the file now if that has not happened yet, so [known] is
  /// complete. Safe to call again.
  Future<void> load() => _ensureLoaded();

  Future<File> _resolveFile() async {
    final known = _file;
    if (known != null) return known;
    final root = await AppDataPaths.resolveDirectory();
    return _file = File('${root.path}/bridge/$fileName');
  }

  Future<void> _ensureLoaded() {
    if (_loaded) return Future<void>.value();
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<void> _load() async {
    try {
      final file = await _resolveFile();
      if (await file.exists()) {
        final raw = await file.readAsString();
        if (raw.trim().isNotEmpty) {
          final decoded = jsonDecode(raw);
          if (decoded is! Map<String, Object?>) {
            throw const FormatException('not an object');
          }
          final jobs = decoded['jobs'];
          if (jobs is List) {
            for (final entry in jobs) {
              if (entry is Map<String, Object?>) {
                final job = BridgeJobRecord.fromJson(entry);
                if (job != null) _jobs[job.id] = job;
              }
            }
          }
        }
      }
    } catch (_) {
      // An unreadable file starts empty: the jobs keep running on their
      // servers, only the assistant can no longer reach them. The bytes are
      // kept aside for recovery by hand.
      _jobs.clear();
      await setAsideUnreadable(_file);
    } finally {
      _loaded = true;
      if (_jobs.isNotEmpty) _changed();
    }
  }

  Future<void> _persist() => _writer.run(() async {
    final file = await _resolveFile();
    await file.parent.create(recursive: true);
    final payload = {
      'version': 1,
      'jobs': [for (final j in _jobs.values) j.toJson()],
    };
    await atomicWrite(file, (temp) async {
      await temp.writeAsString(jsonEncode(payload), flush: true);
      if (!Platform.isWindows) {
        try {
          await Process.run('chmod', ['600', temp.path]);
        } catch (_) {}
      }
    });
  });

  /// Every job remembered, oldest first.
  Future<List<BridgeJobRecord>> all() async {
    await _ensureLoaded();
    return List.unmodifiable(_jobs.values);
  }

  /// The job [id] if [clientId] started it; null otherwise, the same for an
  /// unknown id and another client's.
  Future<BridgeJobRecord?> find(String clientId, String id) async {
    await _ensureLoaded();
    final job = _jobs[id];
    return job != null && job.clientId == clientId ? job : null;
  }

  /// [clientId]'s jobs on the server [host] reaches now.
  Future<List<BridgeJobRecord>> onServer(String clientId, Host host) async {
    await _ensureLoaded();
    return [
      for (final j in _jobs.values)
        if (j.clientId == clientId && bridgeSameServer(host, j.server)) j,
    ];
  }

  Future<bool> contains(String id) async {
    await _ensureLoaded();
    return _jobs.containsKey(id);
  }

  /// Remembers [job]. When the file cannot be written, it is not kept in
  /// memory either, and the error is rethrown.
  Future<void> add(BridgeJobRecord job) async {
    await _ensureLoaded();
    _jobs[job.id] = job;
    try {
      await _persist();
    } catch (_) {
      _jobs.remove(job.id);
      rethrow;
    }
    _changed();
  }

  /// Remembers [job] only if [clientId] has fewer than [max] jobs on the
  /// server [host] reaches, counted and added with no wait in between, so
  /// two starts at once cannot both take the last place. False when full.
  Future<bool> addIfRoom(BridgeJobRecord job, Host host, int max) async {
    await _ensureLoaded();
    final mine = _jobs.values.where(
      (j) => j.clientId == job.clientId && bridgeSameServer(host, j.server),
    );
    if (mine.length >= max) return false;
    _jobs[job.id] = job;
    try {
      await _persist();
    } catch (_) {
      _jobs.remove(job.id);
      rethrow;
    }
    _changed();
    return true;
  }

  /// Forgets [id]. A failed write is not undone: forgetting fails safe.
  Future<void> remove(String id) async {
    await _ensureLoaded();
    if (_jobs.remove(id) == null) return;
    _changed();
    try {
      await _persist();
    } catch (_) {}
  }

  Future<void> _removeWhere(bool Function(BridgeJobRecord job) test) async {
    await _ensureLoaded();
    final gone = [
      for (final j in _jobs.values)
        if (test(j)) j.id,
    ];
    if (gone.isEmpty) return;
    gone.forEach(_jobs.remove);
    _changed();
    try {
      await _persist();
    } catch (_) {}
  }

  /// Forgets the jobs of clients not in [clientIds] (revoked).
  Future<void> retainClients(Set<String> clientIds) =>
      _removeWhere((j) => !clientIds.contains(j.clientId));

  /// Forgets the jobs of hosts that are gone or now reach another server.
  /// A host only stepped down keeps its jobs (see [BridgeJobs]).
  Future<void> retainHosts(List<Host> hosts) =>
      _removeWhere((j) => !hosts.any((h) => bridgeSameServer(h, j.server)));
}

/// What `start_job` will start: the command exactly as the card shows it.
class BridgeJobPlan extends BridgeChangePlan {
  BridgeJobPlan({
    required this.command,
    required this.cwd,
    required this.shownCwd,
    required this.name,
    required this.hostName,
    required this.clientId,
    this.clientName,
  }) : super(
         summary: JobStartSummary(command: command, cwd: shownCwd, name: name),
       );

  final String command;

  /// The folder as `cd` gets it (`~/` taken off: the job starts in the home
  /// directory), or null for the home directory.
  final String? cwd;

  /// The folder as the assistant gave it, for the card.
  final String? shownCwd;
  final String? name;
  final String hostName;

  /// Who asked: the job is recorded as theirs.
  final String clientId;
  final String? clientName;
}

/// Long-running jobs: `start_job` (a change, with the card), `list_jobs`,
/// `job_status`, `job_output` (reads), and `stop_job`, `remove_job` (only
/// the client that started the job).
///
/// A job is a server process the user's account owns: it runs detached
/// (see [BridgeJobCommands]) and outlives the call, the connection and the
/// app. So nothing here ends a job when the app locks, the bridge goes off
/// or the app closes ([ended] does nothing), and a client revoked or a host
/// deleted or re-pointed only makes the app forget the job (the assistant
/// can no longer reach it; the user still can, on the server).
///
/// A host stepped below "ask before each change" keeps its jobs running:
/// they are the user's server processes, and stopping them on the user's
/// behalf because a setting changed would be a surprise. The assistant can
/// no longer stop or remove them (the policy refuses `jobUse` there), while
/// `list_jobs`, `job_status` and `job_output` follow read access like any
/// other read.
class BridgeJobs extends BridgeToolModule {
  BridgeJobs({
    required this.registry,
    required this.redactor,
    this.remoteRoot = '',
    Random? random,
    DateTime Function()? clock,
  }) : _random = random ?? Random.secure(),
       _clock = clock ?? DateTime.now;

  final BridgeJobRegistry registry;

  /// Output is redacted here before it is cut, so a cut never lands inside
  /// a key; the tool host redacts the whole answer again.
  final BridgeRedactor redactor;

  /// Test seam: the jobs folder on the server, empty for
  /// `$HOME/.cache/secureshellgo/jobs`.
  final String remoteRoot;
  final Random _random;
  final DateTime Function() _clock;

  /// Jobs one client may have on one server, ended ones included, until it
  /// removes some.
  static const int maxJobsPerHost = 20;
  static const int maxNameChars = 64;
  static const int defaultOutputLines = 200;
  static const int maxOutputLines = 5000;

  /// The most of a log one `job_output` call returns.
  static const int outputWindowBytes = 64 * 1024;
  static const int recordCommandChars = 500;

  /// What `stop_job` adds when the job's files name no process it may
  /// signal (see [BridgeJobCommands.stop]).
  static const String stopRefusedText =
      'Not stopped: the process id or group recorded in the job\'s folder on '
      'the server is not one SecureShell Go started, so nothing was '
      'signalled. Its state is unknown; check the server by hand.';
  static const int idLength = 16;

  static final RegExp _idPattern = RegExp(r'^[a-z0-9]{16}$');

  /// Whether [id] is shaped like an id this app makes: 16 lower-case
  /// letters and digits. Nothing else ever reaches a server.
  static bool isJobId(String id) => _idPattern.hasMatch(id);

  static const String _alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';

  static const BridgeRefuse jobLimit = BridgeRefuse(
    'job_limit',
    'You already have $maxJobsPerHost jobs on this host. Remove ended ones '
        'with remove_job (stop_job first if one still runs), then try again.',
  );

  // ------------------------------------------------------- for the user

  BridgeModuleServices? _services;

  @override
  void attach(BridgeModuleServices services) {
    _services = services;
    // Loaded once at start so the phone's list is complete from the first
    // snapshot; a read failure leaves it empty (the registry sets the bytes
    // aside itself).
    unawaited(registry.load());
  }

  /// Every job the app remembers, oldest first; see [BridgeJobRegistry.known].
  List<BridgeJobRecord> get known => registry.known;

  /// Fires after every change of [known].
  Stream<void> get changes => registry.changes;

  /// The person stops job [jobId] (the Stop of "AI approvals", on the app
  /// or from a paired phone): TERM to its process group, KILL after the
  /// grace, by exactly the script `stop_job` runs.
  ///
  /// This is the user's own action, so the assistant policy does not apply
  /// (a host stepped down to read-only still lets the person stop a job they
  /// can see), and any assistant's job can be stopped, not only one a given
  /// client owns. It still does nothing while the app is locked, and the
  /// job must be on a host the app still has and that still reaches the same
  /// server. No activity entry is written, as for the Stop of an assistant
  /// terminal or desktop.
  ///
  /// True when the stop script ran against the server. False for an unknown
  /// job, a locked app, a host that is gone or re-pointed, or a server that
  /// could not be reached or that refused to signal what the job's files
  /// name. The job stays in the list either way: it is forgotten only by
  /// `remove_job` or when its host or assistant goes.
  Future<bool> stopByUser(String jobId) async {
    final services = _services;
    if (services == null || services.isAppLocked || !isJobId(jobId)) {
      return false;
    }
    await registry.load();
    BridgeJobRecord? job;
    for (final j in registry.known) {
      if (j.id == jobId) job = j;
    }
    if (job == null) return false;
    final record = job;
    Host? host;
    for (final h in await services.hosts()) {
      if (bridgeSameServer(h, record.server)) host = h;
    }
    if (host == null || services.isAppLocked) return false;
    try {
      final result = await services.withServerAsUser(
        host,
        (c) => c.exec(BridgeJobCommands.stop(record.id, root: remoteRoot)),
      );
      if (result.exitCode != 0) return false;
      return !const LineSplitter()
          .convert(result.stdout)
          .contains(BridgeJobCommands.stopRefusedMarker);
    } catch (_) {
      return false;
    }
  }

  String _newId() =>
      List.generate(idLength, (_) => _alphabet[_random.nextInt(36)]).join();

  static const Map<String, Object?> _jobIdProperty = {
    'type': 'string',
    'minLength': idLength,
    'maxLength': idLength,
    'pattern': r'^[a-z0-9]{16}$',
    'description': 'A job id as start_job or list_jobs returned it.',
  };

  static const Map<String, Object?> _hostProperty = {
    'type': 'string',
    'minLength': 1,
    'maxLength': BridgeTools.maxHostNameBytes,
    'description': 'A host name exactly as list_hosts returns it.',
  };

  // ---------------------------------------------------------------- specs

  static const BridgeToolSpec listJobsSpec = BridgeToolSpec(
    name: 'list_jobs',
    description:
        'Lists the jobs you started on a server with start_job, as JSON: '
        '{"jobs": [{"job_id", "name", "command", "state" (running, exited, '
        'unknown when its processes are gone without an exit code, or '
        'missing when its folder was deleted), "exit_code", "stopped", '
        '"age_seconds"}]}. Only your own jobs are listed.',
    inputSchema: {
      'type': 'object',
      'properties': {'host': _hostProperty},
      'required': ['host'],
      'additionalProperties': false,
    },
    kind: BridgeToolKind.read,
  );

  static const BridgeToolSpec jobStatusSpec = BridgeToolSpec(
    name: 'job_status',
    description:
        'The state of one job you started, as JSON: {"job_id", "host", '
        '"name", "command", "state" (running, exited, unknown or missing), '
        '"exit_code", "stopped", "started" (UTC), "runtime_seconds", '
        '"log_bytes"}.',
    inputSchema: {
      'type': 'object',
      'properties': {'job_id': _jobIdProperty},
      'required': ['job_id'],
      'additionalProperties': false,
    },
    kind: BridgeToolKind.read,
  );

  static const BridgeToolSpec jobOutputSpec = BridgeToolSpec(
    name: 'job_output',
    description:
        'The newest output (stdout and stderr together) of one job you '
        'started: the last `lines` lines (default 200, at most 5000) of the '
        'newest 64 KB of its log, redacted. Call it again to follow a job.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'job_id': _jobIdProperty,
        'lines': {
          'type': 'integer',
          'minimum': 1,
          'maximum': maxOutputLines,
          'default': defaultOutputLines,
        },
      },
      'required': ['job_id'],
      'additionalProperties': false,
    },
    kind: BridgeToolKind.read,
  );

  static const BridgeToolSpec stopJobSpec = BridgeToolSpec(
    name: 'stop_job',
    description:
        'Stops a job you started: TERM to its process group, KILL 3 seconds '
        'later if anything is left. Returns its final state as job_status '
        'does. Only on a host where you may still request changes.',
    inputSchema: {
      'type': 'object',
      'properties': {'job_id': _jobIdProperty},
      'required': ['job_id'],
      'additionalProperties': false,
    },
    kind: BridgeToolKind.jobUse,
  );

  static const BridgeToolSpec removeJobSpec = BridgeToolSpec(
    name: 'remove_job',
    description:
        'Deletes the folder and log of a job you started that has ended, and '
        'forgets it, making room for new jobs (at most 20 per host). A job '
        'that still runs is not removed: stop_job it first.',
    inputSchema: {
      'type': 'object',
      'properties': {'job_id': _jobIdProperty},
      'required': ['job_id'],
      'additionalProperties': false,
    },
    kind: BridgeToolKind.jobUse,
  );

  @override
  List<BridgeToolSpec> get specs => const [
    listJobsSpec,
    jobStatusSpec,
    jobOutputSpec,
    stopJobSpec,
    removeJobSpec,
  ];

  @override
  List<BridgeChangeTool> get changeTools => [startJob];

  // ---------------------------------------------------------------- start_job

  late final BridgeChangeTool startJob = BridgeChangeTool(
    spec: const BridgeToolSpec(
      name: 'start_job',
      description:
          'Starts a long-running command on a server as a job that keeps '
          'running after this call, the connection and the app have ended: '
          'a dev server, a build, a watcher, a long script, anything that '
          'takes more than a minute or must outlive the call (use '
          'run_command for a quick command whose output you want now). It '
          'runs with the account\'s login shell, no stdin and no terminal, '
          'its stdout and stderr going to a log. Returns JSON with the '
          '"job_id"; follow it with job_status and job_output, stop it with '
          'stop_job, and remove_job it once it has ended. At most 20 jobs '
          'per host. The user is asked to approve it in SecureShell Go '
          'first, unless they have allowed changes beforehand; say what you '
          'want to run and why before calling. If the user denies it, do '
          'not retry it or ask for it another way.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'host': _hostProperty,
          'command': {
            'type': 'string',
            'minLength': 1,
            'maxLength': BridgeChangeTools.maxCommandChars,
            'description':
                'The command, run by the account\'s login shell exactly as '
                'given (up to 4096 characters; leading and trailing white '
                'space is dropped; no NUL). It must not wait for input.',
          },
          'name': {
            'type': 'string',
            'minLength': 1,
            'maxLength': maxNameChars,
            'description': 'A short label for the job, e.g. "dev server".',
          },
          'cwd': {
            'type': 'string',
            'minLength': 1,
            'maxLength': 4096,
            'description':
                'The folder to run it in: absolute, or relative to the home '
                'directory. The home directory when left out.',
          },
        },
        'required': ['host', 'command'],
        'additionalProperties': false,
      },
      kind: BridgeToolKind.change,
    ),
    arguments: const {'host', 'command', 'name', 'cwd'},
    plan: _planStart,
    run: _runStart,
    auditArgs: (args) => {
      'host': args['host'],
      'command': _auditText(args['command'], recordCommandChars),
      if (args['name'] != null) 'name': _auditText(args['name'], maxNameChars),
      if (args['cwd'] != null) 'cwd': _auditText(args['cwd'], 500),
    },
  );

  static Object? _auditText(Object? value, int max) {
    if (value is! String) return value == null ? null : '[not a string]';
    return value.length <= max ? value : '${value.substring(0, max)}…';
  }

  static final RegExp _nameControls = RegExp(r'[\x00-\x1f\x7f]');

  static String? _nameArgument(BridgeToolArgs args) {
    final value = args['name'];
    if (value == null) return null;
    if (value is! String) BridgeToolArgs.reject('name must be a string.');
    final name = value.trim();
    if (name.isEmpty) BridgeToolArgs.reject('name must not be empty.');
    if (name.length > maxNameChars) {
      BridgeToolArgs.reject('name is longer than $maxNameChars characters.');
    }
    if (_nameControls.hasMatch(name)) {
      BridgeToolArgs.reject('name must not contain control characters.');
    }
    return name;
  }

  Future<BridgeChangePlan> _planStart(
    BridgeToolArgs args,
    BridgePlanContext context,
  ) async {
    final command = BridgeChangeTools.commandArgument(args);
    final name = _nameArgument(args);
    String? cwd;
    String? shownCwd;
    if (args['cwd'] != null) {
      shownCwd = args.string('cwd', maxBytes: 4096);
      final path = args.path('cwd');
      cwd = path == '.' ? null : path;
    }
    final mine = await registry.onServer(context.client.id, context.host);
    if (mine.length >= maxJobsPerHost) BridgeToolArgs.refuse(jobLimit);
    return BridgeJobPlan(
      command: command,
      cwd: cwd,
      shownCwd: shownCwd,
      name: name,
      hostName: context.hostName,
      clientId: context.client.id,
      clientName: context.client.name,
    );
  }

  Future<BridgeToolResult> _runStart(
    BridgeCallContext call,
    BridgeChangePlan plan,
  ) async {
    final p = plan as BridgeJobPlan;
    final host = call.host!;
    // The tool host runs a change only after a decision for this client,
    // but the plan's count may be minutes old (the card waited) and other
    // starts may have landed meanwhile.
    final clientId = p.clientId;
    final mine = await registry.onServer(clientId, host);
    if (mine.length >= maxJobsPerHost) {
      return BridgeToolResult.error(jobLimit.message);
    }
    var id = _newId();
    while (await registry.contains(id)) {
      id = _newId();
    }
    // Remembered before it starts, so a start cut short (a stop, a lost
    // connection) can never leave a job nobody knows about: list_jobs then
    // shows what became of it.
    final bool room;
    try {
      room = await registry.addIfRoom(
        BridgeJobRecord.on(
          host,
          id: id,
          clientId: clientId,
          hostName: p.hostName,
          startedAt: _clock().toUtc(),
          name: p.name,
          command: _recordedCommand(p.command),
          clientName: p.clientName,
        ),
        host,
        maxJobsPerHost,
      );
    } catch (_) {
      return const BridgeToolResult.error(
        'The job was not started: SecureShell Go could not record it.',
      );
    }
    if (!room) return BridgeToolResult.error(jobLimit.message);
    final result = await call.exec(
      BridgeJobCommands.start(
        id: id,
        command: p.command,
        cwd: p.cwd,
        root: remoteRoot,
      ),
    );
    if (result.stdout.contains(BridgeJobCommands.startedMarker(id))) {
      return BridgeToolResult(
        jsonEncode({
          'job_id': id,
          if (p.name != null) 'name': p.name,
          'state': 'running',
          'log': remoteRoot.isEmpty
              ? '~/.cache/secureshellgo/jobs/$id/log'
              : '$remoteRoot/$id/log',
          'next':
              'Follow it with job_status and job_output (job_id "$id"); '
              'stop it with stop_job; remove_job it once it has ended.',
        }),
      );
    }
    final why = switch (result.exitCode) {
      BridgeJobCommands.noSuchDirectory =>
        'The job was not started: the folder "${p.shownCwd}" cannot be '
            'entered on the server.',
      BridgeJobCommands.noJobsFolder =>
        'The job was not started: the server has no usable home folder for '
            'jobs (~/.cache/secureshellgo/jobs).',
      BridgeJobCommands.folderExists =>
        'The job was not started: its folder already exists on the server.',
      _ => null,
    };
    if (why != null) {
      await registry.remove(id);
      throw MonitorFailure(why);
    }
    throw MonitorFailure(
      'It is not known whether job $id started (exit status '
      '${result.exitCode ?? 'none'}). Call job_status with job_id "$id".',
      details: result.stderr.trim().isEmpty ? null : result.stderr.trim(),
    );
  }

  /// The start of [command] as the registry keeps it on disk and the read
  /// tools return it: scrubbed like the activity log's copy, since a
  /// password typed into a command must not sit in bridge_jobs.json. The
  /// whole command is scrubbed before the cut, so the scrubber sees each
  /// secret whole. The command sent to the server is not touched.
  String _recordedCommand(String command) {
    final clean = redactor.redact(command);
    return clean.length <= recordCommandChars
        ? clean
        : '${clean.substring(0, recordCommandChars)}…';
  }

  // ---------------------------------------------------------------- calls

  @override
  Map<String, Object?> auditArgs(String tool, Map<String, Object?> args) => {
    for (final e in args.entries)
      e.key: e.value is String ? _auditText(e.value, 100) : e.value,
  };

  @override
  Future<BridgeModuleOutcome> call(BridgeModuleCall call) async {
    switch (call.spec.name) {
      case 'list_jobs':
        return _listJobs(call);
      case 'job_status':
      case 'job_output':
      case 'stop_job':
      case 'remove_job':
        return _onJob(call);
    }
    return BridgeModuleOutcome.refused(BridgeToolRefusals.unknownTool);
  }

  Future<BridgeModuleOutcome> _listJobs(BridgeModuleCall call) async {
    final host = await call.resolveHost(call.rawArgs['host']);
    final decision = call.decide(host: host);
    if (decision is BridgeRefuse) return BridgeModuleOutcome.refused(decision);
    call.args(const {'host'});
    final jobs = await registry.onServer(call.client.id, host!);
    if (jobs.isEmpty) {
      return BridgeModuleOutcome.ok(jsonEncode({'jobs': <Object?>[]}));
    }
    final result = await call.withServer(
      host,
      (c) => c.exec(
        BridgeJobCommands.status([
          for (final j in jobs) j.id,
        ], root: remoteRoot),
      ),
    );
    _checkRan(result);
    final parsed = BridgeJobState.parseAll(result.stdout);
    return BridgeModuleOutcome.ok(
      jsonEncode({
        'jobs': [
          for (final j in jobs)
            _describe(j, parsed.states[j.id], parsed.now, full: false),
        ],
      }),
    );
  }

  /// Resolves the job id among the CALLING client's jobs only, then the
  /// decision: an unknown id and another client's read alike.
  Future<BridgeModuleOutcome> _onJob(BridgeModuleCall call) async {
    final raw = call.rawArgs['job_id'];
    final job = raw is String && isJobId(raw)
        ? await registry.find(call.client.id, raw)
        : null;
    Host? host;
    if (job != null) {
      call.auditHost = job.hostName;
      for (final h in await call.hosts()) {
        if (bridgeSameServer(h, job.server)) host = h;
      }
    }
    final use = call.spec.kind == BridgeToolKind.jobUse;
    final decision = use
        ? call.decide(host: host, ownsJob: job != null)
        : call.decide(host: host);
    if (decision is BridgeRefuse) {
      // A read names a job, not a host: past the bridge's own switches, an
      // id that is not the caller's is "not available", as for jobUse.
      if (job == null &&
          decision != BridgeRefusals.bridgeOff &&
          decision != BridgeRefusals.appLocked) {
        return BridgeModuleOutcome.refused(BridgeRefusals.jobNotAvailable);
      }
      return BridgeModuleOutcome.refused(decision);
    }
    final allowedHost = host!;
    final theJob = job!;
    switch (call.spec.name) {
      case 'job_status':
        call.args(const {'job_id'});
        final result = await call.withServer(
          allowedHost,
          (c) =>
              c.exec(BridgeJobCommands.status([theJob.id], root: remoteRoot)),
        );
        _checkRan(result);
        final parsed = BridgeJobState.parseAll(result.stdout);
        return BridgeModuleOutcome.ok(
          jsonEncode(
            _describe(theJob, parsed.states[theJob.id], parsed.now, full: true),
          ),
        );
      case 'job_output':
        final args = call.args(const {'job_id', 'lines'});
        final lines = args.integer(
          'lines',
          min: 1,
          max: maxOutputLines,
          fallback: defaultOutputLines,
        );
        final result = await call.withServer(
          allowedHost,
          (c) => c.exec(
            BridgeJobCommands.output(theJob.id, lines, root: remoteRoot),
          ),
        );
        _checkRan(result);
        return BridgeModuleOutcome.ok(_formatOutput(theJob, result.stdout));
      case 'stop_job':
        call.args(const {'job_id'});
        final result = await call.withServer(
          allowedHost,
          (c) => c.exec(BridgeJobCommands.stop(theJob.id, root: remoteRoot)),
        );
        _checkRan(result);
        final parsed = BridgeJobState.parseAll(result.stdout);
        final refused = const LineSplitter()
            .convert(result.stdout)
            .contains(BridgeJobCommands.stopRefusedMarker);
        return BridgeModuleOutcome.ok(
          jsonEncode({
            ..._describe(
              theJob,
              parsed.states[theJob.id],
              parsed.now,
              full: true,
            ),
            if (refused) 'stop': stopRefusedText,
          }),
        );
      case 'remove_job':
        call.args(const {'job_id'});
        final result = await call.withServer(
          allowedHost,
          (c) => c.exec(BridgeJobCommands.remove(theJob.id, root: remoteRoot)),
        );
        _checkRan(result);
        final said = result.stdout.trim();
        if (said.endsWith('removed no')) {
          return BridgeModuleOutcome.error(
            'Job ${theJob.id} is still running, so it was not removed. Stop '
            'it with stop_job first.',
          );
        }
        if (!said.endsWith('removed yes') &&
            !said.endsWith('removed missing')) {
          return BridgeModuleOutcome.error(
            'Job ${theJob.id} could not be removed.',
          );
        }
        await registry.remove(theJob.id);
        return BridgeModuleOutcome.ok(
          said.endsWith('removed missing')
              ? 'Job ${theJob.id} was already gone from the server; it is '
                    'forgotten.'
              : 'Job ${theJob.id} and its log were removed.',
        );
    }
    return BridgeModuleOutcome.refused(BridgeToolRefusals.unknownTool);
  }

  static void _checkRan(ExecResult result) {
    if (result.exitCode == BridgeJobCommands.noJobsFolder) {
      throw const MonitorFailure(
        'The server has no home folder set, so its jobs cannot be found.',
      );
    }
    if (result.exitCode != 0) {
      throw MonitorFailure(
        'The job command failed on the server (exit status '
        '${result.exitCode ?? 'none'}).',
        details: result.stderr.trim().isEmpty ? null : result.stderr.trim(),
      );
    }
  }

  Map<String, Object?> _describe(
    BridgeJobRecord job,
    BridgeJobState? state,
    int? now, {
    required bool full,
  }) {
    final s = state ?? const BridgeJobState(state: 'unknown');
    final started = s.started;
    final serverNow = now;
    final age = started != null && serverNow != null
        ? serverNow - started
        : _clock().toUtc().difference(job.startedAt).inSeconds;
    final ended = s.ended;
    return {
      'job_id': job.id,
      if (full) 'host': job.hostName,
      'name': job.name,
      'command': job.command,
      'state': s.state,
      'exit_code': s.exitCode,
      'stopped': s.stopped,
      if (!full) 'age_seconds': age < 0 ? 0 : age,
      if (full)
        'started': started == null
            ? job.startedAt.toUtc().toIso8601String()
            : DateTime.fromMillisecondsSinceEpoch(
                started * 1000,
                isUtc: true,
              ).toIso8601String(),
      if (full && started != null && (ended != null || serverNow != null))
        'runtime_seconds': max(0, (ended ?? serverNow!) - started),
      if (full) 'log_bytes': s.logBytes,
    };
  }

  String _formatOutput(BridgeJobRecord job, String stdout) {
    final marker = stdout.indexOf('\n--\n');
    if (stdout.trim() == 'state missing' || marker < 0) {
      if (stdout.trim() == 'state missing') {
        return 'Job ${job.id} has no folder on the server any more (it was '
            'deleted); there is no output to show.';
      }
      throw const MonitorFailure('The job output could not be read.');
    }
    final header = stdout.substring(0, marker);
    final logBytes = int.tryParse(header.replaceFirst('log ', '').trim());
    final body = stdout.substring(marker + 4);
    final head =
        'job ${job.id}${job.name == null ? '' : ' (${job.name})'}, log '
        '${logBytes ?? 'unknown'} bytes'
        '${logBytes != null && logBytes > outputWindowBytes ? '; only its newest part is read' : ''}:\n';
    // The cut's own note comes on top of what is kept; the whole answer
    // must stay within the tool host's cap, or its cut (which keeps the
    // start) would take the newest lines away.
    final room = outputWindowBytes - utf8.encode(head).length - 100;
    final shown = BridgeRedactor.capUtf8(
      redactor.redact(body, keepTail: true),
      room,
      keepTail: true,
    );
    return '$head$shown';
  }

  // ---------------------------------------------------------------- lifecycle

  @override
  Future<void> clientsChanged(Set<String> clientIds) =>
      registry.retainClients(clientIds);

  @override
  Future<void> hostsChanged(List<Host> hosts) => registry.retainHosts(hosts);

  /// Jobs are the user's server processes and are not interactive: a lock,
  /// the bridge going off or the app closing leaves them running.
  @override
  Future<void> ended(BridgeModuleEnd reason) async {}
}

/// One job's state as the server reported it.
class BridgeJobState {
  const BridgeJobState({
    required this.state,
    this.started,
    this.ended,
    this.exitCode,
    this.logBytes,
    this.stopped = false,
  });

  /// `running`, `exited`, `unknown` (no exit code, and its processes are
  /// gone) or `missing` (its folder is gone).
  final String state;
  final int? started;
  final int? ended;
  final int? exitCode;
  final int? logBytes;
  final bool stopped;

  /// The `now` line and each `job` block of [BridgeJobCommands.status].
  static ({int? now, Map<String, BridgeJobState> states}) parseAll(
    String stdout,
  ) {
    int? now;
    final states = <String, BridgeJobState>{};
    String? id;
    var fields = <String, String>{};
    void flush() {
      final current = id;
      if (current == null) return;
      final exit = (fields['exit'] ?? '').split(' ');
      states[current] = BridgeJobState(
        state: switch (fields['state']) {
          'running' => 'running',
          'exited' => 'exited',
          'missing' => 'missing',
          _ => 'unknown',
        },
        started: int.tryParse(fields['started'] ?? ''),
        exitCode: int.tryParse(exit.first),
        ended: exit.length > 1 ? int.tryParse(exit[1]) : null,
        logBytes: int.tryParse(fields['log'] ?? ''),
        stopped: fields['stopped'] == '1',
      );
    }

    for (final line in const LineSplitter().convert(stdout)) {
      final space = line.indexOf(' ');
      final key = space < 0 ? line : line.substring(0, space);
      final value = space < 0 ? '' : line.substring(space + 1).trim();
      if (key == 'now') {
        now = int.tryParse(value);
      } else if (key == 'job') {
        flush();
        id = value;
        fields = {};
      } else if (id != null) {
        fields[key] = value;
      }
    }
    flush();
    return (now: now, states: states);
  }
}
