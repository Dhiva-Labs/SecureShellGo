import '../ssh_service.dart';
import 'agent_deployer.dart';
import 'agent_endpoint.dart';
import 'agent_failure.dart';
import 'agent_manifest.dart';
import 'agent_probe.dart';
import 'agent_shell.dart';

/// How to start the agent.
class AgentLaunchOptions {
  const AgentLaunchOptions({
    this.idleExit = const Duration(seconds: 30),
    this.notify = true,
    this.clipboard = true,
    this.synthetic = false,
    this.linuxBackend,
    this.runtimeDir,
    this.useSystemd = true,
    this.timeout = const Duration(seconds: 15),
  });

  /// `--exit-when-idle`: the agent exits this long after start with no
  /// viewer, or after its last viewer leaves (the agent itself waits 15 s
  /// after a dropped link before counting the viewer as gone). Null means
  /// never — only for a virtual desktop the user asked to keep.
  final Duration? idleExit;

  /// Show "your screen is being viewed" on the remote desktop. Off only for
  /// automated tests and virtual desktops, where nobody is at that screen.
  final bool notify;

  /// Sync the clipboard with the viewer.
  final bool clipboard;

  /// `--synthetic`: an animated test pattern, no capture and no input.
  /// The only mode any test may run against a machine with a real desktop.
  final bool synthetic;

  /// `CROSSSHELL_LINUX_BACKEND` — `mutter`, `portal` or `x11` — or null to
  /// let the agent choose. Forced to `x11` for the x11 build regardless.
  final String? linuxBackend;

  /// The runtime directory to use instead of a fresh one under
  /// `$XDG_RUNTIME_DIR` (or `%LOCALAPPDATA%`). Tests point it into a
  /// scratch folder; it is created 0700 and removed by [AgentEndpoint.stop],
  /// and its last component must be `ssgo-rd-<16 hex>` — see
  /// [AgentLauncher.checkRuntimeDir].
  final String? runtimeDir;

  /// Start Linux agents in a `systemd-run --user` unit when the server has
  /// a user manager. False forces the `setsid` fallback — for testing it.
  final bool useSystemd;

  /// How long to wait for `host.json`.
  final Duration timeout;

  List<String> agentArguments(String runtimeDir) => [
        '--runtime-dir',
        runtimeDir,
        if (idleExit != null) ...[
          '--exit-when-idle',
          '${idleExit!.inSeconds < 1 ? 1 : idleExit!.inSeconds}',
        ],
        if (!notify) '--no-notify',
        if (!clipboard) '--no-clipboard',
        if (synthetic) '--synthetic',
      ];
}

/// Starts deployed agents in desktop mode and stops them.
class AgentLauncher {
  const AgentLauncher();

  /// Starts the agent into this account's desktop on the server.
  ///
  /// Refuses a server without one unless [AgentLaunchOptions.synthetic] —
  /// the test pattern needs no desktop.
  Future<AgentEndpoint> launchDesktop(
    SessionTransport transport,
    RemoteDesktopProbe probe,
    DeployedAgent agent, {
    AgentLaunchOptions options = const AgentLaunchOptions(),
  }) {
    final desktop = probe.desktop;
    if (desktop is! DesktopAvailable && !options.synthetic) {
      throw AgentFailure(
        desktop is DesktopOfAnotherUser
            ? AgentFailureKind.desktopOfAnotherUser
            : AgentFailureKind.noDesktop,
        'This account has no desktop on the server to show.',
      );
    }
    final environment =
        desktop is DesktopAvailable ? desktop.environment : const <String, String>{};
    return switch (agent.os) {
      AgentOs.linux => launchLinux(transport, agent,
          environment: environment, options: options),
      AgentOs.windows => launchWindows(transport, agent, options: options),
    };
  }

  // ---------------------------------------------------------------- Linux

  /// Starts a Linux agent with [environment] layered over the user
  /// manager's (systemd) or the login's (fallback).
  Future<AgentEndpoint> launchLinux(
    SessionTransport transport,
    DeployedAgent agent, {
    Map<String, String> environment = const {},
    AgentLaunchOptions options = const AgentLaunchOptions(),
  }) async {
    final id = AgentShell.newId();
    final command = linuxLaunchCommand(
      agent: agent,
      id: id,
      environment: environment,
      options: options,
    );
    final result = await AgentShell.run(transport, command,
        what: 'start the remote-desktop agent',
        timeout: options.timeout + const Duration(seconds: 15));
    final lines = AgentShell.lines(result.stdout);
    _checkIntegrity(lines);

    final runtimeDir = AgentShell.valueAfter(lines, 'SSG-RT ');
    final mode = AgentShell.valueAfter(lines, 'SSG-MODE ');
    final json = AgentShell.between(lines, 'SSG-READY', 'SSG-END');
    if (json == null || runtimeDir == null || mode == null) {
      throw _launchFailure(lines, result.stderr);
    }
    final unit = mode.startsWith('systemd ') ? mode.substring(8).trim() : null;
    final AgentHostInfo info;
    try {
      info = AgentHostInfo.parse(json);
    } on AgentFailure {
      // Whatever it published, the agent is running; it does not stay so.
      final pid = unit == null ? int.tryParse(mode.substring(4).trim()) ?? 0 : 0;
      await _quietly(() => _stopLinux(transport, runtimeDir, unit, pid));
      rethrow;
    }
    return AgentEndpoint(
      info: info,
      os: AgentOs.linux,
      runtimeDir: runtimeDir,
      unitName: unit,
      stop: () => _stopLinux(transport, runtimeDir, unit, info.pid),
    );
  }

  /// The Linux launch script. Public so the exact text can be asserted and
  /// run through a real `sh`.
  ///
  /// In order: re-hash the binary and refuse a mismatch; make the runtime
  /// directory; start the agent in a transient user unit (or, without a
  /// user manager, detached with `setsid`); then wait — on the server, so a
  /// phone pays one round trip and not one per poll — for `host.json`,
  /// printing it between `SSG-READY` and `SSG-END`. If the agent exits or
  /// the wait runs out, the log tail is printed instead and everything
  /// started is cleaned up, so a failed launch leaves nothing behind.
  ///
  /// **The environment.** A transient unit inherits the user manager's
  /// environment, not this login's, and on a desktop where the manager
  /// knows a stale or foreign display the agent would attach to the wrong
  /// one; so `DISPLAY`, `WAYLAND_DISPLAY` and `XDG_SESSION_TYPE` are always
  /// set explicitly — empty when the desktop has none, which the agent reads
  /// as unset. `XAUTHORITY` is only ever set to a real path: an empty one is
  /// a path, and X clients then send no cookie at all.
  static String linuxLaunchCommand({
    required DeployedAgent agent,
    required String id,
    Map<String, String> environment = const {},
    AgentLaunchOptions options = const AgentLaunchOptions(),
  }) {
    if (!AgentShell.idPattern.hasMatch(id)) {
      throw ArgumentError.value(id, 'id', 'not a launch id');
    }
    final env = linuxEnvironment(agent, environment, options);
    final explicit = options.runtimeDir;
    if (explicit != null) checkRuntimeDir(explicit, windows: false);
    final args = options
        .agentArguments('@RT@')
        .map((a) => a == '@RT@' ? '"\$rt"' : a)
        .join(' ');
    final polls = (options.timeout.inMilliseconds / 200).ceil();
    // `$1` the agent, `$2` an explicit runtime directory or empty, then the
    // environment as NAME=value words: data, never spliced into the script
    // (see [AgentShell.sh]).
    return AgentShell.sh('''
${AgentShell.shHashFunction}
${AgentShell.shRuntimeDir}
a=\$1
rt=\$2
shift 2
[ -f "\$a" ] || { echo SSG-MISSING; exit 3; }
h=\$(ssg_hash "\$a")
[ -n "\$h" ] || { echo SSG-NO-HASH-TOOL; exit 3; }
[ "\$h" = ${agent.binary.sha256} ] || { echo "SSG-HASH-MISMATCH \$h"; exit 3; }
unit=ssgo-rd-$id
[ -n "\$rt" ] || rt="\${XDG_RUNTIME_DIR:-\$HOME/.cache/secureshellgo/rt}/\$unit"
umask 077
mkdir -p "\$rt" && chmod 700 "\$rt" || { echo SSG-LAUNCH-FAILED; exit 4; }
echo "SSG-RT \$rt"
p=
if ${options.useSystemd ? '{ ${AgentShell.shHasUserSystemd}; }' : 'false'}; then
  n=\$#
  for kv do set -- "\$@" "--setenv=\$kv"; done
  shift \$n
  if ! systemd-run --user --collect --quiet --unit="\$unit" "\$@" "\$a" $args > "\$rt/launch.log" 2>&1; then
    echo SSG-LAUNCH-FAILED; echo SSG-LOG; tail -n 20 "\$rt/launch.log"; rm -rf "\$rt"; exit 4
  fi
  echo "SSG-MODE systemd \$unit"
else
  if command -v setsid >/dev/null 2>&1; then d=setsid; else d=; fi
  \$d nohup env "\$@" "\$a" $args < /dev/null > "\$rt/launch.log" 2>&1 &
  p=\$!
  echo "SSG-MODE pid \$p"
  unit=
fi
alive() { if [ -n "\$unit" ]; then systemctl --user is-active --quiet "\$unit"; else kill -0 "\$p" 2>/dev/null; fi; }
n=0
while [ \$n -lt $polls ]; do
  if [ -s "\$rt/host.json" ]; then echo SSG-READY; cat "\$rt/host.json"; echo; echo SSG-END; exit 0; fi
  alive || { [ -s "\$rt/host.json" ] && continue; echo SSG-EXITED; break; }
  ${AgentShell.shShortSleep}
  n=\$((n + 1))
done
[ \$n -lt $polls ] || echo SSG-TIMEOUT
echo SSG-LOG
tail -n 30 "\$rt/host.log" 2>/dev/null
tail -n 10 "\$rt/launch.log" 2>/dev/null
[ -n "\$unit" ] && journalctl --user -u "\$unit" -n 15 --no-pager -o cat 2>/dev/null
if [ -n "\$unit" ]; then systemctl --user stop "\$unit" 2>/dev/null; else kill "\$p" 2>/dev/null; fi
rm -rf "\$rt"
exit 5''', [
      agent.path,
      explicit ?? '',
      for (final e in env.entries) '${e.key}=${e.value}',
    ]);
  }

  /// The variables a Linux agent is started with. See [linuxLaunchCommand].
  static Map<String, String> linuxEnvironment(
    DeployedAgent agent,
    Map<String, String> desktop,
    AgentLaunchOptions options,
  ) {
    String value(String key) => desktop[key] ?? '';
    final backend = agent.binary.flavour == AgentFlavour.x11
        ? 'x11'
        : options.linuxBackend;
    return {
      'DISPLAY': value('DISPLAY'),
      'WAYLAND_DISPLAY': value('WAYLAND_DISPLAY'),
      'XDG_SESSION_TYPE': value('XDG_SESSION_TYPE'),
      for (final key in const [
        'XAUTHORITY',
        'DBUS_SESSION_BUS_ADDRESS',
        'XDG_CURRENT_DESKTOP',
      ])
        if (value(key).isNotEmpty) key: value(key),
      'CROSSSHELL_LINUX_BACKEND': ?backend,
    };
  }

  Future<void> _stopLinux(
    SessionTransport transport,
    String runtimeDir,
    String? unit,
    int pid,
  ) async {
    await AgentShell.run(
      transport,
      linuxStopCommand(runtimeDir: runtimeDir, unit: unit, pid: pid),
      what: 'stop the remote-desktop agent',
    );
  }

  /// Stops a Linux agent and removes its runtime directory.
  ///
  /// A bare process is only killed after `/proc/<pid>/cmdline` shows it is
  /// the agent started for [runtimeDir] — by the time a stop runs, the agent
  /// may long since have exited on its own and its pid been reused by
  /// something of the user's. The directory is only removed when its name
  /// is one this app makes.
  static String linuxStopCommand({
    required String runtimeDir,
    String? unit,
    required int pid,
  }) {
    checkRuntimeDir(runtimeDir, windows: false);
    if (unit != null && !RegExp(r'^ssgo-[rv]d-[0-9a-f]{16}$').hasMatch(unit)) {
      throw ArgumentError.value(unit, 'unit', 'not a unit this app made');
    }
    return AgentShell.sh('''
${AgentShell.shRuntimeDir}
rt=\$1
${unit == null ? '' : 'systemctl --user stop $unit 2>/dev/null'}
p=$pid
if [ -r "/proc/\$p/cmdline" ] && tr '\\000' ' ' < "/proc/\$p/cmdline" | grep -qF -- "\$rt"; then
  kill "\$p" 2>/dev/null
  i=0
  while kill -0 "\$p" 2>/dev/null && [ \$i -lt 25 ]; do ${AgentShell.shShortSleep}; i=\$((i + 1)); done
  kill -9 "\$p" 2>/dev/null
fi
rm -rf "\$rt"
echo SSG-STOPPED''', [runtimeDir]);
  }

  // ---------------------------------------------------------------- Windows

  /// Starts a Windows agent into the interactive session of the account
  /// SSH logged in as.
  Future<AgentEndpoint> launchWindows(
    SessionTransport transport,
    DeployedAgent agent, {
    AgentLaunchOptions options = const AgentLaunchOptions(),
  }) async {
    final id = AgentShell.newId();
    final command = windowsLaunchCommand(agent: agent, id: id, options: options);
    final result = await AgentShell.run(transport, command,
        what: 'start the remote-desktop agent',
        timeout: options.timeout + const Duration(seconds: 30));
    final lines = AgentShell.lines(result.stdout);
    _checkIntegrity(lines);
    final runtimeDir = AgentShell.valueAfter(lines, 'SSG-RT ');
    final json = AgentShell.between(lines, 'SSG-READY', 'SSG-END');
    if (runtimeDir == null) throw _launchFailure(lines, result.stderr, windows: true);
    final task = windowsTaskName(id);
    Future<void> stop(int pid) async {
      await AgentShell.run(
        transport,
        windowsStopCommand(
          runtimeDir: runtimeDir,
          agentPath: agent.path,
          pid: pid,
          taskName: task,
        ),
        what: 'stop the remote-desktop agent',
        timeout: const Duration(seconds: 30),
      );
    }

    // The launch script leaves the clean-up to the stop script — finding the
    // agent by its command line when there is no pid, deleting the task,
    // removing the folder — which keeps it inside cmd.exe's 8191 characters.
    if (json == null) {
      await _quietly(() => stop(0));
      throw _launchFailure(lines, result.stderr, windows: true);
    }
    final AgentHostInfo info;
    try {
      info = AgentHostInfo.parse(json.trim());
    } on AgentFailure {
      await _quietly(() => stop(0));
      rethrow;
    }
    return AgentEndpoint(
      info: info,
      os: AgentOs.windows,
      runtimeDir: runtimeDir,
      stop: () => stop(info.pid),
    );
  }

  static String windowsTaskName(String id) => 'SSGo-RD-$id';

  /// The Windows launch script.
  ///
  /// An SSH login on Windows runs in a non-interactive session that cannot
  /// see the desktop, so the agent goes in through a run-once scheduled task
  /// with an interactive-token principal — what `schtasks /it` makes — which
  /// Task Scheduler starts inside the user's logged-on session.
  ///
  /// The task is registered from XML (`schtasks /create /xml`) rather than
  /// with `/tr`, for three reasons found the hard way:
  ///  * `/tr` is limited to 261 characters, and two quoted paths under
  ///    `%LOCALAPPDATA%` with a 64-character hash in one already come close
  ///    — a longer user name goes over.
  ///  * A task made with `/create /sc once` gets Task Scheduler's defaults,
  ///    which include "start only on AC power" and "stop on battery": on a
  ///    laptop running on battery the agent silently never starts.
  ///  * The default priority is below normal, which shows in a screen
  ///    capture's frame rate.
  /// The command and its arguments go into separate XML elements, escaped
  /// as XML, so no command-line quoting is involved beyond the agent's own
  /// argument parsing of `--runtime-dir "<path>"` (paths cannot contain `"`
  /// on Windows).
  ///
  /// The task is deleted as soon as `host.json` appears — deleting a task
  /// does not end a running instance — and the agent is stopped later by
  /// pid.
  ///
  /// While it waits, the script watches the task's `LastTaskResult`, so an
  /// agent that never started — Smart App Control blocks unsigned programs
  /// unpredictably — or that exited at once fails in a second rather than at
  /// the deadline; and it looks in the Code Integrity log for a block that
  /// names the agent, which is what tells "blocked" from "crashed".
  static String windowsLaunchCommand({
    required DeployedAgent agent,
    required String id,
    AgentLaunchOptions options = const AgentLaunchOptions(),
  }) {
    if (!AgentShell.idPattern.hasMatch(id)) {
      throw ArgumentError.value(id, 'id', 'not a launch id');
    }
    final explicit = options.runtimeDir;
    if (explicit != null) checkRuntimeDir(explicit, windows: true);
    final rt = explicit != null
        ? AgentShell.psQuote(explicit)
        : "(Join-Path \$env:LOCALAPPDATA 'SecureShellGo\\rt\\ssgo-rd-$id')";
    // The arguments as one Windows command line, with the runtime directory
    // spliced in on the server, where its value is known.
    final rest = options
        .agentArguments('@RT@')
        .skip(2)
        .map((a) => a.contains(' ') ? '"$a"' : a)
        .join(' ');
    final polls = (options.timeout.inMilliseconds / 200).ceil();
    final script = '''
${AgentShell.psHashFunction}
\$e=${AgentShell.psQuote(agent.path)}
if(-not(Test-Path -LiteralPath \$e)){'SSG-MISSING';exit 3}
\$h=SsgHash \$e
if(-not \$h){'SSG-NO-HASH-TOOL';exit 3}
if(\$h -ne '${agent.binary.sha256}'){"SSG-HASH-MISMATCH \$h";exit 3}
\$r=$rt
New-Item -ItemType Directory -Force -Path \$r|Out-Null
'SSG-RT '+\$r
\$a='--runtime-dir "'+\$r+'" $rest'
\$x=[Security.SecurityElement]
\$u=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
\$t='${windowsTaskName(id)}'
\$f=Join-Path \$r 'task.xml'
[IO.File]::WriteAllText(\$f,'<?xml version="1.0" encoding="UTF-16"?><Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Principals><Principal id="A"><UserId>'+\$u+'</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals><Settings><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><ExecutionTimeLimit>PT0S</ExecutionTimeLimit><Priority>4</Priority></Settings><Actions Context="A"><Exec><Command>'+\$x::Escape(\$e)+'</Command><Arguments>'+\$x::Escape(\$a)+'</Arguments></Exec></Actions></Task>',[Text.Encoding]::Unicode)
\$o=schtasks /create /tn \$t /xml \$f /f 2>&1
if(\$LASTEXITCODE){'SSG-LAUNCH-FAILED';'SSG-LOG';"\$o";exit 4}
\$t0=Get-Date
\$o=schtasks /run /tn \$t 2>&1
if(\$LASTEXITCODE){'SSG-LAUNCH-FAILED';'SSG-LOG';"\$o";exit 4}
\$j=Join-Path \$r 'host.json'
\$n=0;\$s=\$null;\$w=267009,267011,267045
while(-not(Test-Path -LiteralPath \$j) -and \$n -lt $polls){Start-Sleep -Milliseconds 200;\$n++
if(\$n%5 -eq 0){try{\$s=(Get-ScheduledTaskInfo -TaskName \$t -ErrorAction Stop).LastTaskResult}catch{\$s=\$null}
if(\$null -ne \$s -and \$w -notcontains \$s){break}}}
schtasks /delete /tn \$t /f 2>&1|Out-Null
if(Test-Path -LiteralPath \$j){'SSG-READY';(Get-Content -Raw -LiteralPath \$j).Trim();'SSG-END';exit 0}
if(\$null -ne \$s -and \$w -notcontains \$s){'SSG-EXITED';'SSG-TASK-RESULT '+\$s}else{'SSG-TIMEOUT'}
Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-CodeIntegrity/Operational';Id=3033,3034,3077,3118;StartTime=\$t0} -ErrorAction SilentlyContinue|?{\$_.Message -like '*crossshell-host*'}|Select-Object -First 1|%{'SSG-BLOCKED '+\$_.Id}
'SSG-LOG'
\$l=Join-Path \$r 'host.log'
if(Test-Path -LiteralPath \$l){Get-Content -Tail 30 -LiteralPath \$l}
exit 5''';
    final command = AgentShell.powershell(script);
    if (command.length > AgentShell.maxWindowsCommandLength) {
      throw StateError('Windows launch command is ${command.length} characters');
    }
    return command;
  }

  /// Stops a Windows agent by pid — after checking the pid is still that
  /// agent, by its command line or its executable — and any other agent
  /// whose command line names [runtimeDir], deletes the task if a launch
  /// left it behind, and removes the runtime directory.
  static String windowsStopCommand({
    required String runtimeDir,
    required String agentPath,
    required int pid,
    required String taskName,
  }) {
    checkRuntimeDir(runtimeDir, windows: true);
    return AgentShell.powershell('''
\$r=${AgentShell.psQuote(runtimeDir)}
\$e=${AgentShell.psQuote(agentPath)}
\$p=$pid
\$c=Get-CimInstance Win32_Process -Filter "ProcessId=\$p" -ErrorAction SilentlyContinue
if(\$c -and ((\$c.CommandLine -and \$c.CommandLine.Contains(\$r)) -or \$c.ExecutablePath -eq \$e)){taskkill /PID \$p /F 2>&1|Out-Null}
Get-CimInstance Win32_Process -Filter "Name='crossshell-host.exe'" -ErrorAction SilentlyContinue|?{\$_.CommandLine -and \$_.CommandLine.Contains(\$r)}|%{taskkill /PID \$_.ProcessId /F 2>&1|Out-Null}
schtasks /delete /tn ${AgentShell.psQuote(taskName)} /f 2>&1|Out-Null
\$n=0
while((Get-Process -Id \$p -ErrorAction SilentlyContinue) -and \$n -lt 25){Start-Sleep -Milliseconds 200;\$n++}
Remove-Item -LiteralPath \$r -Recurse -Force -ErrorAction SilentlyContinue
'SSG-STOPPED\'''');
  }

  // ---------------------------------------------------------------- shared

  static Future<void> _quietly(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      // Best effort: the failure being reported is the one that matters,
      // and --exit-when-idle ends the agent anyway.
    }
  }

  static void _checkIntegrity(List<String> lines) {
    if (lines.contains('SSG-MISSING')) {
      throw const AgentFailure(
        AgentFailureKind.launchFailed,
        'The remote-desktop agent is no longer on the server. It may have '
        'been removed by antivirus or a cache clean-up; connecting again '
        'will put it back.',
      );
    }
    if (lines.contains('SSG-NO-HASH-TOOL')) {
      throw const AgentFailure(
        AgentFailureKind.missingTool,
        'This server has no way to check the remote-desktop agent before it '
        'runs (sha256sum, shasum or openssl), so it was not started.',
      );
    }
    final mismatch = AgentShell.valueAfter(lines, 'SSG-HASH-MISMATCH');
    if (mismatch != null) {
      throw AgentFailure(
        AgentFailureKind.hashMismatch,
        'The remote-desktop agent on the server has been changed since it '
        'was installed, so it was not run. Connecting again replaces it.',
        details: 'the server\'s copy hashes to $mismatch',
      );
    }
  }

  /// What a Windows task's `LastTaskResult` is when application control
  /// refused the executable: `ERROR_SYSTEM_INTEGRITY_POLICY_VIOLATION`
  /// (Smart App Control, WDAC) and `ERROR_ACCESS_DISABLED_BY_POLICY`
  /// (AppLocker, software restriction policies), as HRESULTs.
  static const Set<int> windowsBlockedResults = {0x800711C7, 0x800704EC};

  static AgentFailure _launchFailure(
    List<String> lines,
    String stderr, {
    bool windows = false,
  }) {
    final log = AgentShell.after(lines, 'SSG-LOG');
    final details = [log, stderr.trim()].where((s) => s.isNotEmpty).join('\n');
    if (windows) {
      // UInt32 from the CIM class, but a signed HRESULT from some hosts.
      final result = int.tryParse(
              AgentShell.valueAfter(lines, 'SSG-TASK-RESULT ') ?? '')
          ?.toUnsigned(32);
      final event = AgentShell.valueAfter(lines, 'SSG-BLOCKED ');
      if (event != null || windowsBlockedResults.contains(result)) {
        return AgentFailure(
          AgentFailureKind.blockedByPolicy,
          'Windows blocked the remote-desktop agent from running. Smart App '
          'Control (or another application-control policy) on that machine '
          'refuses unsigned programs, and the agent is not signed yet.',
          details: [
            if (result != null) 'task result 0x${result.toRadixString(16).toUpperCase()}',
            if (event != null) 'Code Integrity event $event',
            if (details.isNotEmpty) details,
          ].join('\n'),
        );
      }
      if (result != null) {
        return AgentFailure(
          AgentFailureKind.launchFailed,
          'The remote-desktop agent stopped as soon as it started.',
          details: [
            'task result 0x${result.toRadixString(16).toUpperCase()}',
            if (details.isNotEmpty) details,
          ].join('\n'),
        );
      }
    }
    if (lines.contains('SSG-TIMEOUT')) {
      return AgentFailure(
        AgentFailureKind.launchTimedOut,
        windows
            ? 'The remote-desktop agent did not start. Is someone signed in '
                'to Windows on that machine?'
            : 'The remote-desktop agent did not start in time.',
        details: details.isEmpty ? null : details,
      );
    }
    return AgentFailure(
      AgentFailureKind.launchFailed,
      'The remote-desktop agent could not be started on the server.',
      details: details.isEmpty ? null : details,
    );
  }

  /// Refuses to build a recursive delete for a path this app did not make:
  /// it must be absolute, free of `..`, and end in `ssgo-rd-<id>` or
  /// `ssgo-vd-<id>`. Applied to an explicit [AgentLaunchOptions.runtimeDir]
  /// at launch too, so a test cannot hand in a directory that stop would
  /// then refuse to clean up.
  static void checkRuntimeDir(String path, {required bool windows}) {
    final separator = windows ? '\\' : '/';
    final absolute = windows
        ? RegExp(r'^[A-Za-z]:\\').hasMatch(path)
        : path.startsWith('/');
    final parts = path.split(separator);
    final ours = RegExp(r'^ssgo-(rd|vd)-[0-9a-f]{16}$').hasMatch(parts.last);
    if (!absolute || parts.contains('..') || !ours) {
      throw ArgumentError.value(
          path, 'runtimeDir', 'not a runtime directory this app made');
    }
  }
}
