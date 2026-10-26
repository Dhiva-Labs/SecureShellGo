import 'dart:convert';

import '../remote_exec.dart';
import '../server_probe.dart' show splitProbeSections;
import '../ssh_service.dart';
import 'agent_failure.dart';
import 'agent_manifest.dart';
import 'agent_shell.dart';

// ------------------------------------------------------------ OS family

/// What the server runs, as far as remote desktop is concerned.
enum RemoteOsFamily { linux, windows, macos, other }

/// The answer to "what is on the other end", and what gave it away.
class RemoteOsGuess {
  const RemoteOsGuess(this.family, {this.machine, required this.evidence});

  final RemoteOsFamily family;

  /// `uname -m` when the server answered it.
  final String? machine;

  /// What the guess rests on, for the details line of an "unsupported"
  /// message.
  final String evidence;
}

/// Tells Linux from Windows before anything shell-specific is sent.
///
/// The one command has to mean something harmless to every shell an SSH
/// login can land in — `sh`, bash, zsh, fish and csh on a unix box; `cmd.exe`
/// or PowerShell on Windows — and come out differently in each family:
///
///  * `cmd.exe` expands `%OS%` even inside the single quotes, which mean
///    nothing to it, and prints `'Windows_NT' ; uname -sm` as one line: `;`
///    is not a separator there.
///  * PowerShell prints `%OS%` and then fails to find `uname`, or — with
///    Git for Windows on the PATH — runs MSYS `uname`, which says
///    `MINGW64_NT-…`.
///  * A unix shell prints `%OS%`, then `Linux x86_64` or `Darwin arm64`.
///
/// Sent before the real probe because a Linux script handed to `cmd.exe`
/// is not inert: cmd honours `>` and `|` anywhere in a line, single quotes
/// or not.
class RemoteOsDetector {
  const RemoteOsDetector._();

  static const String command = "echo '%OS%' ; uname -sm";

  static RemoteOsGuess parse(ExecResult result) {
    final out = AgentShell.lines(result.stdout).map((l) => l.trim()).toList();
    final err = result.stderr.toLowerCase();
    for (final line in out) {
      if (line.contains('Windows_NT')) {
        return const RemoteOsGuess(RemoteOsFamily.windows,
            evidence: 'cmd.exe expanded %OS% to Windows_NT');
      }
    }
    // A known system anywhere in the output, so a login script that prints
    // a banner even on a non-interactive exec does not hide the answer.
    for (final line in out) {
      final fields = line.split(RegExp(r'\s+'));
      final system = fields.first;
      final machine = fields.length > 1 ? fields[1] : null;
      if (RegExp(r'^(MINGW|MSYS|CYGWIN)', caseSensitive: false)
          .hasMatch(system)) {
        return RemoteOsGuess(RemoteOsFamily.windows,
            machine: machine, evidence: 'uname says $system');
      }
      if (system == 'Linux') {
        return RemoteOsGuess(RemoteOsFamily.linux,
            machine: machine, evidence: 'uname says Linux');
      }
      if (system == 'Darwin') {
        return RemoteOsGuess(RemoteOsFamily.macos,
            machine: machine, evidence: 'uname says Darwin');
      }
    }
    // Something else answered uname: the line right after the echo.
    final echoed = out.indexOf('%OS%');
    if (echoed >= 0 && echoed + 1 < out.length && out[echoed + 1].isNotEmpty) {
      final fields = out[echoed + 1].split(RegExp(r'\s+'));
      return RemoteOsGuess(RemoteOsFamily.other,
          machine: fields.length > 1 ? fields[1] : null,
          evidence: 'uname says ${fields.first}');
    }
    // `%OS%` echoed back unexpanded and no `uname` at all: PowerShell's
    // "is not recognized as the name of a cmdlet". A unix box with no
    // `uname` would say "not found" instead, and is not worth guessing at.
    if (out.contains('%OS%') &&
        (err.contains('not recognized') ||
            err.contains('commandnotfoundexception'))) {
      return const RemoteOsGuess(RemoteOsFamily.windows,
          evidence: 'PowerShell could not find uname');
    }
    return RemoteOsGuess(RemoteOsFamily.other,
        evidence: 'unrecognised answer: '
            '${out.join(' | ')}${err.isEmpty ? '' : ' / ${result.stderr.trim()}'}');
  }

  static Future<RemoteOsGuess> detect(SessionTransport transport) async =>
      parse(await AgentShell.run(transport, command,
          what: 'find out what operating system it runs'));
}

// ------------------------------------------------------------ classification

/// What kind of desktop this account has on the server, which decides the
/// agent's capture backend.
enum DesktopKind {
  /// GNOME on Wayland: the Mutter backend, no consent prompt, GNOME's own
  /// screen-share indicator.
  gnomeWayland,

  /// Any X11 desktop, GNOME on Xorg included.
  x11,

  /// KDE, sway and other Wayland compositors: the portal backend, which asks
  /// for consent on the remote screen — someone has to be there.
  otherWayland,

  /// A logged-on Windows session.
  windows,
}

/// Whether desktop mode can reach a desktop for this account.
sealed class DesktopAvailability {
  const DesktopAvailability();
}

/// This account has a desktop on the server.
final class DesktopAvailable extends DesktopAvailability {
  const DesktopAvailable({
    required this.kind,
    this.active = true,
    this.locked = false,
    this.sessionId,
    this.environment = const {},
  });

  final DesktopKind kind;

  /// False for a session that is switched away from or disconnected. The
  /// agent may still start; what it can capture then is up to the desktop.
  final bool active;

  /// The session reports its screen locked. Capture shows the lock screen.
  final bool locked;

  /// loginctl's session id, or the Windows session id.
  final String? sessionId;

  /// The variables the agent needs to find this desktop — `WAYLAND_DISPLAY`,
  /// `DISPLAY`, `XAUTHORITY`, `DBUS_SESSION_BUS_ADDRESS`,
  /// `XDG_SESSION_TYPE`, `XDG_CURRENT_DESKTOP` — from whichever source the
  /// probe trusted. Linux only.
  final Map<String, String> environment;
}

/// Somebody else is logged in to the desktop. Their session belongs to
/// their account, and this one cannot capture it.
final class DesktopOfAnotherUser extends DesktopAvailability {
  const DesktopOfAnotherUser(this.users);

  /// User names (or uids, when that is all the server would say).
  final List<String> users;
}

/// No desktop for anyone: a server. Virtual desktops are the offer here.
final class Headless extends DesktopAvailability {
  const Headless({this.loginScreen = false});

  /// A display manager is showing its login screen — someone could log in
  /// at the machine, but nobody has.
  final bool loginScreen;
}

// ------------------------------------------------------------ Linux

/// One `loginctl` session.
class LoginSession {
  const LoginSession({
    required this.id,
    this.uid,
    this.user = '',
    this.type = '',
    this.sessionClass = '',
    this.active = false,
    this.state = '',
    this.remote = false,
    this.display = '',
    this.desktop = '',
    this.locked = false,
    this.seat = '',
  });

  final String id;
  final int? uid;
  final String user;

  /// `wayland`, `x11`, `tty`, `mir`, `unspecified`.
  final String type;

  /// `user`, `greeter`, `lock-screen`, `background`, `manager`.
  final String sessionClass;
  final bool active;

  /// `active`, `online`, `closing`.
  final String state;
  final bool remote;

  /// The X display of an X11 session, `:0`.
  final String display;

  /// `gnome`, `ubuntu`, `KDE`, `xfce` — whatever the display manager put
  /// there.
  final String desktop;
  final bool locked;
  final String seat;

  bool get isGraphical => type == 'wayland' || type == 'x11' || type == 'mir';
  bool get isGreeter => sessionClass == 'greeter';
}

/// A desktop-ish process found under `/proc`.
class DesktopProcess {
  const DesktopProcess({
    required this.pid,
    required this.name,
    required this.own,
    required this.compositor,
    this.uid,
    this.environment = const {},
  });

  final int pid;

  /// `/proc/<pid>/comm`, cut at 15 characters by the kernel.
  final String name;

  /// Runs as this account.
  final bool own;

  /// A compositor, window manager or session manager, as opposed to a
  /// process merely started inside a session.
  final bool compositor;

  /// For someone else's process, its uid.
  final int? uid;

  /// The display-related part of its environment. Own processes only.
  final Map<String, String> environment;

  /// One of our own virtual desktops' processes, which say so in
  /// `SSGO_VDESK`. They are never somebody's desktop.
  bool get isVirtualDesktop => environment.containsKey('SSGO_VDESK');
}

/// `/etc/os-release`, the part that picks a package manager.
class OsRelease {
  const OsRelease({
    this.id = '',
    this.idLike = const [],
    this.versionId = '',
    this.prettyName = '',
  });

  final String id;
  final List<String> idLike;
  final String versionId;
  final String prettyName;

  /// [id] then [idLike]: the families to try, most specific first.
  List<String> get families => [id, ...idLike].where((f) => f.isNotEmpty).toList();

  static OsRelease parse(String text) {
    final values = <String, String>{};
    for (final raw in const LineSplitter().convert(text)) {
      final line = raw.trim();
      final eq = line.indexOf('=');
      if (eq <= 0) continue;
      var value = line.substring(eq + 1).trim();
      if (value.length >= 2 &&
          (value.startsWith('"') && value.endsWith('"') ||
              value.startsWith("'") && value.endsWith("'"))) {
        value = value.substring(1, value.length - 1);
      }
      values[line.substring(0, eq)] = value;
    }
    return OsRelease(
      id: (values['ID'] ?? '').toLowerCase(),
      idLike: (values['ID_LIKE'] ?? '')
          .toLowerCase()
          .split(RegExp(r'\s+'))
          .where((s) => s.isNotEmpty)
          .toList(),
      versionId: values['VERSION_ID'] ?? '',
      prettyName: values['PRETTY_NAME'] ?? '',
    );
  }
}

/// The desktop-session programs a virtual desktop can run, in the order
/// they are offered.
enum VirtualSessionKind {
  xfce('xfce4-session', 'Xfce'),
  lxqt('startlxqt', 'LXQt'),
  mate('mate-session', 'MATE'),
  openbox('openbox-session', 'Openbox'),
  icewm('icewm-session', 'IceWM');

  const VirtualSessionKind(this.command, this.label);

  /// The program, run with no arguments.
  final String command;
  final String label;
}

/// Everything one Linux probe read. See [LinuxProbe.command].
class LinuxProbe {
  const LinuxProbe({
    required this.system,
    required this.machine,
    required this.uid,
    required this.home,
    this.runtimeDir = '',
    this.sessions = const [],
    this.lingering = false,
    this.managerEnvironment = const {},
    this.processes = const [],
    this.tools = const {},
    this.hasLibPipewire = false,
    this.glibcVersion,
    this.osRelease = const OsRelease(),
  });

  /// `uname -s`, `Linux`.
  final String system;

  /// `uname -m`.
  final String machine;
  final int uid;
  final String home;

  /// `XDG_RUNTIME_DIR`, or `/run/user/<uid>` when the login did not set it
  /// and it exists; empty when neither.
  final String runtimeDir;
  final List<LoginSession> sessions;

  /// `loginctl enable-linger` is on: the user manager outlives this login,
  /// which a virtual desktop that keeps running after disconnect needs.
  final bool lingering;

  /// The display-related part of `systemctl --user show-environment`.
  final Map<String, String> managerEnvironment;
  final List<DesktopProcess> processes;

  /// Which of [probedTools] exist.
  final Set<String> tools;
  final bool hasLibPipewire;

  /// `2.39`, or null on musl and anything else without glibc.
  final String? glibcVersion;
  final OsRelease osRelease;

  AgentArch? get arch => AgentArch.parse(machine);

  bool has(String tool) => tools.contains(tool);
  bool get hasXvfb => has('Xvfb');
  bool get hasSystemdRun => has('systemd-run');

  /// Desktop sessions installed for a virtual desktop to run.
  List<VirtualSessionKind> get virtualSessions =>
      VirtualSessionKind.values.where((s) => has(s.command)).toList();

  /// Whether a dynamically linked build needing glibc [minimum] can load.
  bool glibcAtLeast(String? minimum) {
    if (minimum == null) return true;
    final have = glibcVersion;
    if (have == null) return false;
    List<int> parts(String v) =>
        v.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    final a = parts(have);
    final b = parts(minimum);
    for (var i = 0; i < 2; i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return true;
  }

  /// Can the full (PipeWire) build run here?
  bool canRunFull(AgentBinary full) =>
      hasLibPipewire && glibcAtLeast(full.minGlibc);

  DesktopAvailability get desktop => classifyLinuxDesktop(this);

  static const List<String> environmentKeys = [
    'WAYLAND_DISPLAY',
    'DISPLAY',
    'XAUTHORITY',
    'DBUS_SESSION_BUS_ADDRESS',
    'XDG_SESSION_TYPE',
    'XDG_CURRENT_DESKTOP',
  ];

  static const List<String> probedTools = [
    'Xvfb',
    'xauth',
    'systemd-run',
    'dbus-run-session',
    'dbus-launch',
    'setsid',
    'sha256sum',
    'shasum',
    'openssl',
    'xfce4-session',
    'startlxqt',
    'mate-session',
    'openbox-session',
    'icewm-session',
  ];

  /// Compositors, window managers and session managers — `comm` names, so
  /// cut at 15 characters (`gnome-session-binary` is `gnome-session-b`).
  static const String _compositors =
      'gnome-shell|kwin_wayland|kwin_x11|kwin|plasmashell|Xorg|Xwayland|'
      'xfce4-session|xfwm4|mate-session|marco|cinnamon|cinnamon-sessio|muffin|'
      'lxqt-session|lxsession|openbox|icewm|sway|Hyprland|weston|labwc|'
      'wayfire|niri|cosmic-comp|budgie-wm|gnome-session-b|enlightenment|i3';

  /// Processes started inside a session, which — unlike the compositor that
  /// *creates* `WAYLAND_DISPLAY` — were exec'ed with it in their
  /// environment. `/proc/<pid>/environ` is a process's environment as it was
  /// at exec, so gnome-shell's own never shows the display it serves.
  static const String _sessionChildren =
      'gsd-*|xdg-desktop-por*|ibus-daemon|xfce4-panel|xfdesktop|mate-panel|'
      'lxqt-panel|ksmserver|kded5|kded6|waybar|nautilus|gnome-terminal-*|'
      'xfce4-terminal|konsole|at-spi-bus-laun|evolution-alarm';

  /// The whole probe as one `sh -c`.
  ///
  /// One channel for all of it, as in `server_probe.dart`, because a phone
  /// pays a round trip per exec. `LC_ALL=C` so nothing comes back
  /// translated. Every section is best-effort: a box without loginctl or
  /// systemd simply has those sections empty, and the classification falls
  /// back on the processes.
  static final String command = AgentShell.sh(script);

  static final String script = '''
LC_ALL=C; export LC_ALL
ssg_m() { echo "#=ssg=\$1"; }
${AgentShell.shRuntimeDir}
ssg_m uname; uname -sm 2>/dev/null
ssg_m uid; id -u
ssg_m home; printf '%s\\n' "\$HOME"
ssg_m xdg; printf '%s\\n' "\${XDG_RUNTIME_DIR:-}"
ssg_m sessions
if command -v loginctl >/dev/null 2>&1; then
  for s in \$(loginctl list-sessions --no-legend 2>/dev/null | awk '{print \$1}'); do
    echo "session \$s"
    loginctl show-session "\$s" -p User -p Name -p Type -p Class -p Active -p State -p Remote -p Display -p Desktop -p LockedHint -p Seat 2>/dev/null
  done
  ssg_m linger; loginctl show-user "\$ssg_u" -p Linger 2>/dev/null
fi
ssg_m userenv
systemctl --user show-environment 2>/dev/null | grep -E '^(WAYLAND_DISPLAY|DISPLAY|XAUTHORITY|DBUS_SESSION_BUS_ADDRESS|XDG_SESSION_TYPE|XDG_CURRENT_DESKTOP)='
ssg_m procs
for d in /proc/[0-9]*; do
  c=; read -r c < "\$d/comm" || continue
  case "\$c" in
    $_compositors) k=desk ;;
    $_sessionChildren) k=child ;;
    *) continue ;;
  esac
  if [ -O "\$d" ]; then
    echo "own \$k \${d#/proc/} \$c"
    tr '\\000' '\\n' < "\$d/environ" | grep -E '^(WAYLAND_DISPLAY|DISPLAY|XAUTHORITY|DBUS_SESSION_BUS_ADDRESS|XDG_SESSION_TYPE|XDG_CURRENT_DESKTOP|SSGO_VDESK)=' | sed 's/^/env /'
  elif [ "\$k" = desk ]; then
    echo "other \$k \${d#/proc/} \$(ls -dn "\$d" | awk '{print \$3}') \$c"
  fi
done 2>/dev/null
ssg_m tools
for t in ${probedTools.join(' ')}; do command -v "\$t" >/dev/null 2>&1 && echo "\$t"; done
ssg_m pipewire
p=no
for l in ldconfig /sbin/ldconfig /usr/sbin/ldconfig; do
  if "\$l" -p 2>/dev/null | grep -qF libpipewire-0.3.so.0; then p=yes; break; fi
done
if [ \$p = no ]; then
  for l in /usr/lib /usr/lib64 /lib /lib64 /usr/lib/*-linux-gnu /lib/*-linux-gnu /usr/local/lib; do
    if [ -e "\$l/libpipewire-0.3.so.0" ]; then p=yes; break; fi
  done
fi
echo \$p
ssg_m glibc; getconf GNU_LIBC_VERSION 2>/dev/null
ssg_m osrelease; grep -E '^(ID|ID_LIKE|VERSION_ID|PRETTY_NAME)=' /etc/os-release 2>/dev/null
ssg_m end''';

  /// Parses [command]'s output. Pure; never throws on odd input — a
  /// missing section is an empty one.
  static LinuxProbe parse(String output) {
    final sections = splitProbeSections(output);
    String section(String name) => sections[name] ?? '';
    List<String> lines(String name) => const LineSplitter()
        .convert(section(name))
        .map((l) => l.trimRight())
        .where((l) => l.isNotEmpty)
        .toList();

    final uname = lines('uname').firstOrNull?.split(RegExp(r'\s+')) ?? [];
    final uid = int.tryParse(lines('uid').firstOrNull?.trim() ?? '') ?? -1;

    final sessions = <LoginSession>[];
    String? id;
    var props = <String, String>{};
    void flush() {
      final sessionId = id;
      if (sessionId == null) return;
      sessions.add(LoginSession(
        id: sessionId,
        uid: int.tryParse(props['User'] ?? ''),
        user: props['Name'] ?? '',
        type: props['Type'] ?? '',
        sessionClass: props['Class'] ?? '',
        active: props['Active'] == 'yes',
        state: props['State'] ?? '',
        remote: props['Remote'] == 'yes',
        display: props['Display'] ?? '',
        desktop: props['Desktop'] ?? '',
        locked: props['LockedHint'] == 'yes',
        seat: props['Seat'] ?? '',
      ));
      props = {};
    }

    for (final line in lines('sessions')) {
      if (line.startsWith('session ')) {
        flush();
        id = line.substring(8).trim();
        continue;
      }
      final eq = line.indexOf('=');
      if (eq > 0) props[line.substring(0, eq)] = line.substring(eq + 1);
    }
    flush();

    final processes = <DesktopProcess>[];
    int? pid;
    String? name;
    var own = false;
    var compositor = false;
    int? otherUid;
    var env = <String, String>{};
    void flushProcess() {
      final p = pid;
      final n = name;
      if (p == null || n == null) return;
      processes.add(DesktopProcess(
        pid: p,
        name: n,
        own: own,
        compositor: compositor,
        uid: otherUid,
        environment: env,
      ));
      env = {};
    }

    for (final line in lines('procs')) {
      final fields = line.split(' ');
      if (line.startsWith('env ')) {
        final kv = line.substring(4);
        final eq = kv.indexOf('=');
        if (eq > 0) env[kv.substring(0, eq)] = kv.substring(eq + 1);
        continue;
      }
      if (fields.length >= 4 && fields[0] == 'own') {
        flushProcess();
        own = true;
        compositor = fields[1] == 'desk';
        pid = int.tryParse(fields[2]);
        name = fields.sublist(3).join(' ');
        otherUid = null;
      } else if (fields.length >= 5 && fields[0] == 'other') {
        flushProcess();
        own = false;
        compositor = fields[1] == 'desk';
        pid = int.tryParse(fields[2]);
        otherUid = int.tryParse(fields[3]);
        name = fields.sublist(4).join(' ');
      }
    }
    flushProcess();

    final linger = lines('linger').firstOrNull ?? '';
    final glibc = RegExp(r'glibc\s+(\d+\.\d+)')
        .firstMatch(section('glibc'))
        ?.group(1);

    return LinuxProbe(
      system: uname.isNotEmpty ? uname[0] : '',
      machine: uname.length > 1 ? uname[1] : '',
      uid: uid,
      home: lines('home').firstOrNull ?? '',
      runtimeDir: lines('xdg').firstOrNull ?? '',
      sessions: sessions,
      lingering: linger == 'yes' || linger == 'Linger=yes',
      managerEnvironment: parseSystemdEnvironment(section('userenv')),
      processes: processes,
      tools: lines('tools').where(probedTools.contains).toSet(),
      hasLibPipewire: lines('pipewire').firstOrNull == 'yes',
      glibcVersion: glibc,
      osRelease: OsRelease.parse(section('osrelease')),
    );
  }

  static Future<LinuxProbe> run(SessionTransport transport) async {
    final result = await AgentShell.run(transport, command,
        what: 'look for a desktop', timeout: const Duration(seconds: 20));
    final probe = parse(result.stdout);
    if (probe.uid < 0 || probe.home.isEmpty) {
      throw AgentFailure(
        AgentFailureKind.unsupportedRemote,
        'The server did not answer the remote-desktop probe.',
        details: result.stderr.trim().isEmpty ? null : result.stderr.trim(),
      );
    }
    return probe;
  }
}

/// `systemctl --user show-environment`: `KEY=value` lines, where newer
/// systemd writes a value with spaces or specials as `$'…'` with C escapes.
Map<String, String> parseSystemdEnvironment(String text) {
  final env = <String, String>{};
  for (final line in const LineSplitter().convert(text)) {
    final eq = line.indexOf('=');
    if (eq <= 0) continue;
    var value = line.substring(eq + 1);
    if (value.startsWith(r"$'") && value.endsWith("'") && value.length >= 3) {
      value = _unescapeC(value.substring(2, value.length - 1));
    }
    env[line.substring(0, eq)] = value;
  }
  return env;
}

String _unescapeC(String s) {
  final out = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c != r'\' || i + 1 >= s.length) {
      out.write(c);
      continue;
    }
    final n = s[++i];
    switch (n) {
      case 'n':
        out.write('\n');
      case 't':
        out.write('\t');
      case 'r':
        out.write('\r');
      default:
        out.write(n);
    }
  }
  return out.toString();
}

/// Decides what desktop, if any, this account has — from loginctl when the
/// server has it, from `/proc` when it does not.
///
/// **Which environment.** The systemd user manager's, when it names a
/// display: GNOME and Plasma export theirs into it, and Debian's Xsession
/// does the same for every X11 desktop. Otherwise the first process inside
/// the session that was started with a display in its environment. Never a
/// mix of the two — a `DISPLAY` from one session and a bus from another is
/// how an agent ends up half-attached to the wrong desktop.
DesktopAvailability classifyLinuxDesktop(LinuxProbe probe) {
  final desktopProcesses = probe.processes
      .where((p) => p.compositor && !p.isVirtualDesktop)
      .toList();
  final ownCompositors = desktopProcesses.where((p) => p.own).toList();

  Map<String, String> environment(LoginSession? session) {
    Map<String, String> pick(Map<String, String> from) => {
          for (final key in LinuxProbe.environmentKeys)
            if ((from[key] ?? '').isNotEmpty) key: from[key]!,
        };
    final manager = pick(probe.managerEnvironment);
    final Map<String, String> chosen;
    if (manager.containsKey('WAYLAND_DISPLAY') ||
        manager.containsKey('DISPLAY')) {
      chosen = manager;
    } else {
      final withDisplay = probe.processes.where((p) =>
          p.own &&
          !p.isVirtualDesktop &&
          ((p.environment['WAYLAND_DISPLAY'] ?? '').isNotEmpty ||
              (p.environment['DISPLAY'] ?? '').isNotEmpty));
      chosen = withDisplay.isEmpty ? manager : pick(withDisplay.first.environment);
    }
    if (session != null) {
      if (!chosen.containsKey('DISPLAY') && session.display.isNotEmpty) {
        chosen['DISPLAY'] = session.display;
      }
      if (session.type == 'x11' || session.type == 'wayland') {
        chosen['XDG_SESSION_TYPE'] = session.type;
      }
    }
    return chosen;
  }

  bool gnome(LoginSession? session, Map<String, String> env) {
    final names = [
      session?.desktop ?? '',
      env['XDG_CURRENT_DESKTOP'] ?? '',
    ].join(':').toLowerCase();
    return names.contains('gnome') ||
        names.split(':').contains('ubuntu') ||
        ownCompositors.any((p) => p.name == 'gnome-shell');
  }

  final usable = probe.sessions
      .where((s) =>
          s.uid == probe.uid &&
          s.isGraphical &&
          !s.isGreeter &&
          s.state != 'closing')
      .toList()
    ..sort((a, b) {
      int rank(LoginSession s) => (s.active ? 0 : 2) + (s.seat.isNotEmpty ? 0 : 1);
      return rank(a).compareTo(rank(b));
    });

  if (usable.isNotEmpty) {
    final session = usable.first;
    final env = environment(session);
    final kind = session.type == 'x11'
        ? DesktopKind.x11
        : (gnome(session, env) ? DesktopKind.gnomeWayland : DesktopKind.otherWayland);
    return DesktopAvailable(
      kind: kind,
      active: session.active,
      locked: session.locked,
      sessionId: session.id,
      environment: env,
    );
  }

  // No loginctl, or nothing graphical in it: the processes decide. A
  // session loginctl knows about but did not list as ours is not
  // second-guessed — only a server with no loginctl sessions at all falls
  // through to here.
  final loginctlKnows = probe.sessions.isNotEmpty;
  if (!loginctlKnows && ownCompositors.isNotEmpty) {
    final env = environment(null);
    final wayland = (env['WAYLAND_DISPLAY'] ?? '').isNotEmpty ||
        env['XDG_SESSION_TYPE'] == 'wayland';
    if (wayland || (env['DISPLAY'] ?? '').isNotEmpty) {
      return DesktopAvailable(
        kind: !wayland
            ? DesktopKind.x11
            : (gnome(null, env) ? DesktopKind.gnomeWayland : DesktopKind.otherWayland),
        environment: env,
      );
    }
  }

  final others = probe.sessions
      .where((s) =>
          s.uid != probe.uid && s.isGraphical && !s.isGreeter && s.state != 'closing')
      .map((s) => s.user.isNotEmpty ? s.user : 'uid ${s.uid}')
      .toSet()
      .toList();
  if (others.isEmpty && !loginctlKnows) {
    // Without loginctl, a root-owned Xorg is as likely ours as anyone's, so
    // only a session-level program running as someone else counts.
    others.addAll(desktopProcesses
        .where((p) => !p.own && p.name != 'Xorg' && p.name != 'Xwayland')
        .map((p) => 'uid ${p.uid ?? '?'}')
        .toSet());
  }
  if (others.isNotEmpty) return DesktopOfAnotherUser(others);

  return Headless(loginScreen: probe.sessions.any((s) => s.isGreeter));
}

// ------------------------------------------------------------ Windows

/// One row of `query user`.
class WindowsLogonSession {
  const WindowsLogonSession({
    required this.user,
    required this.id,
    required this.state,
    this.sessionName = '',
  });

  final String user;
  final int id;

  /// As quser printed it — `Active`, `Disc`, or the localised equivalent.
  final String state;
  final String sessionName;

  /// quser's state is localised; "Active" begins with these in every
  /// Windows language that writes it in Latin script.
  bool get active {
    final s = state.toLowerCase();
    return s.startsWith('activ') ||
        s.startsWith('aktiv') ||
        s.startsWith('attiv') ||
        s.startsWith('ativ') ||
        s.startsWith('actie');
  }
}

/// Everything one Windows probe read. See [WindowsProbe.command].
class WindowsProbe {
  const WindowsProbe({
    required this.architecture,
    required this.user,
    required this.localAppData,
    this.domain = '',
    this.osVersion = '',
    this.sessions = const [],
    this.queryUserAvailable = true,
    this.explorerSessions = const [],
  });

  /// .NET's `OSArchitecture` (the machine's, not the process's — an x64
  /// PowerShell under emulation on ARM64 still says Arm64), else
  /// `PROCESSOR_ARCHITEW6432`, else `PROCESSOR_ARCHITECTURE`.
  final String architecture;
  final String user;
  final String domain;

  /// `%LOCALAPPDATA%`, `C:\Users\me\AppData\Local`.
  final String localAppData;
  final String osVersion;
  final List<WindowsLogonSession> sessions;

  /// `quser.exe` exists; Home editions do not have it, and then
  /// [explorerSessions] is what there is.
  final bool queryUserAvailable;

  /// Session ids of `explorer.exe` processes owned by this account, read
  /// only when quser is missing.
  final List<int> explorerSessions;

  AgentArch? get arch => AgentArch.parse(architecture);

  DesktopAvailability get desktop => classifyWindowsDesktop(this);

  static const String script = r'''
'#=ssg=arch'
try{[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()}catch{}
if($env:PROCESSOR_ARCHITEW6432){$env:PROCESSOR_ARCHITEW6432}
$env:PROCESSOR_ARCHITECTURE
'#=ssg=env'
'USERNAME='+$env:USERNAME
'USERDOMAIN='+$env:USERDOMAIN
'LOCALAPPDATA='+$env:LOCALAPPDATA
'OSVERSION='+[Environment]::OSVersion.Version.ToString()
'#=ssg=quser'
if(Get-Command quser.exe -ErrorAction SilentlyContinue){quser.exe 2>&1|%{"$_"}}else{'SSG-NO-QUSER'
'#=ssg=explorer'
Get-CimInstance Win32_Process -Filter "Name='explorer.exe'"|%{$o=Invoke-CimMethod -InputObject $_ -MethodName GetOwner;if($o.User -eq $env:USERNAME){$_.SessionId}}}
'#=ssg=end'
''';

  static final String command = AgentShell.powershell(script);

  static WindowsProbe parse(String output) {
    final text = output.startsWith('\uFEFF') ? output.substring(1) : output;
    final sections = splitProbeSections(text);
    List<String> lines(String name) => const LineSplitter()
        .convert(sections[name] ?? '')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    // The first line that names a CPU the agent knows, else the first line
    // at all, so an unsupported one (`X86`) is still there to report.
    final archLines = lines('arch');
    final arch = archLines.firstWhere(
      (l) => AgentArch.parse(l) != null,
      orElse: () => archLines.firstOrNull ?? '',
    );

    final env = <String, String>{};
    for (final line in lines('env')) {
      final eq = line.indexOf('=');
      if (eq > 0) env[line.substring(0, eq)] = line.substring(eq + 1);
    }

    final quser = lines('quser');
    final noQuser = quser.contains('SSG-NO-QUSER');
    return WindowsProbe(
      architecture: arch,
      user: env['USERNAME'] ?? '',
      domain: env['USERDOMAIN'] ?? '',
      localAppData: env['LOCALAPPDATA'] ?? '',
      osVersion: env['OSVERSION'] ?? '',
      queryUserAvailable: !noQuser,
      sessions: noQuser ? const [] : parseQueryUser(quser.join('\n')),
      explorerSessions:
          lines('explorer').map(int.tryParse).whereType<int>().toList(),
    );
  }

  static Future<WindowsProbe> run(SessionTransport transport) async {
    final result = await AgentShell.run(transport, command,
        what: 'look for a desktop', timeout: const Duration(seconds: 30));
    final probe = parse(result.stdout);
    if (probe.user.isEmpty || probe.localAppData.isEmpty) {
      throw AgentFailure(
        AgentFailureKind.unsupportedRemote,
        'The Windows server did not answer the remote-desktop probe. '
        'PowerShell may be missing or blocked there.',
        details: result.stderr.trim().isEmpty ? null : result.stderr.trim(),
      );
    }
    return probe;
  }
}

/// `query user` (quser) rows:
///
/// ```
///  USERNAME              SESSIONNAME        ID  STATE   IDLE TIME  LOGON TIME
/// >dhiva                 console             1  Active      none   10/27/2026 9:00 AM
///  other                                     2  Disc           5   10/27/2026 8:00 AM
/// ```
///
/// Read by shape rather than by column, because the header, the state and
/// the date are all localised and the columns move with them: the user is
/// the first word (without the `>` that marks the session quser ran in),
/// the id is the first all-digit word after it, and the state is the word
/// after the id. The header has no all-digit word and drops out. A blank
/// session name — a disconnected session has none — is just one word fewer.
List<WindowsLogonSession> parseQueryUser(String text) {
  final sessions = <WindowsLogonSession>[];
  for (final raw in const LineSplitter().convert(text)) {
    var line = raw.trim();
    if (line.startsWith('>')) line = line.substring(1);
    final words = line.split(RegExp(r'\s+'));
    if (words.length < 3) continue;
    var idAt = -1;
    for (var i = 1; i < words.length - 1 && i <= 2; i++) {
      if (RegExp(r'^\d+$').hasMatch(words[i])) {
        idAt = i;
        break;
      }
    }
    if (idAt < 0) continue;
    sessions.add(WindowsLogonSession(
      user: words[0],
      sessionName: idAt == 2 ? words[1] : '',
      id: int.parse(words[idAt]),
      state: words[idAt + 1],
    ));
  }
  return sessions;
}

/// Whether this account has an interactive Windows session for the agent to
/// be started into.
///
/// quser cuts long user names at 20 characters, so a cut name matches as a
/// prefix. Session 0 is where services live and is never a desktop.
DesktopAvailability classifyWindowsDesktop(WindowsProbe probe) {
  final me = probe.user.toLowerCase();
  bool mine(String quserName) {
    final name = quserName.toLowerCase();
    return name == me || (name.length >= 20 && me.startsWith(name));
  }

  if (!probe.queryUserAvailable) {
    final ids = probe.explorerSessions.where((id) => id > 0).toList();
    if (ids.isNotEmpty) {
      return DesktopAvailable(kind: DesktopKind.windows, sessionId: '${ids.first}');
    }
    return const Headless();
  }

  final interactive = probe.sessions.where((s) => s.id > 0).toList();
  final own = interactive.where((s) => mine(s.user)).toList()
    ..sort((a, b) => (a.active ? 0 : 1).compareTo(b.active ? 0 : 1));
  if (own.isNotEmpty) {
    return DesktopAvailable(
      kind: DesktopKind.windows,
      active: own.first.active,
      sessionId: '${own.first.id}',
    );
  }
  final others = interactive.where((s) => s.active).map((s) => s.user).toSet();
  if (others.isNotEmpty) return DesktopOfAnotherUser(others.toList());
  return const Headless();
}

// ------------------------------------------------------------ both

/// What one remote-desktop probe of a server found.
class RemoteDesktopProbe {
  const RemoteDesktopProbe({required this.guess, this.linux, this.windows});

  final RemoteOsGuess guess;
  final LinuxProbe? linux;
  final WindowsProbe? windows;

  RemoteOsFamily get family => guess.family;

  AgentOs? get os => linux != null
      ? AgentOs.linux
      : (windows != null ? AgentOs.windows : null);

  AgentArch? get arch => linux?.arch ?? windows?.arch;

  /// Whether the agent can run there at all — a supported OS on a CPU the
  /// agent is built for.
  bool get isSupported => os != null && arch != null;

  DesktopAvailability get desktop =>
      linux?.desktop ?? windows?.desktop ?? const Headless();

  /// Detects the OS family, then runs that family's probe. Two execs.
  ///
  /// macOS and anything else come back with neither probe filled in and
  /// [isSupported] false, so the UI can say which it was.
  static Future<RemoteDesktopProbe> run(SessionTransport transport) async {
    final guess = await RemoteOsDetector.detect(transport);
    switch (guess.family) {
      case RemoteOsFamily.linux:
        return RemoteDesktopProbe(
            guess: guess, linux: await LinuxProbe.run(transport));
      case RemoteOsFamily.windows:
        return RemoteDesktopProbe(
            guess: guess, windows: await WindowsProbe.run(transport));
      case RemoteOsFamily.macos:
      case RemoteOsFamily.other:
        return RemoteDesktopProbe(guess: guess);
    }
  }
}
