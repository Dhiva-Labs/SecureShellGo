import 'dart:convert';

import '../remote_path.dart';
import '../shell_quote.dart';
import '../ssh_service.dart';
import 'agent_deployer.dart';
import 'agent_endpoint.dart';
import 'agent_failure.dart';
import 'agent_launcher.dart';
import 'agent_manifest.dart';
import 'agent_probe.dart';
import 'agent_shell.dart';

// --------------------------------------------------------- programs as root

/// Programs built on Chromium: VS Code and its forks, and the
/// Chromium-based browsers. A virtual desktop has no graphics hardware, and
/// these try to draw with it, fail, retry, and leave a blank window: they
/// need telling to draw in software. As root they also refuse to start at
/// all unless told to run without their sandbox and with a profile folder
/// of their own (their own message says so). A person should not have to
/// learn either to open one.
const Map<String, String> _chromiumPrograms = {
  'code': 'Code',
  'code-insiders': 'Code - Insiders',
  'codium': 'VSCodium',
  'vscodium': 'VSCodium',
  'cursor': 'Cursor',
  'google-chrome': 'google-chrome',
  'google-chrome-stable': 'google-chrome',
  'chromium': 'chromium',
  'chromium-browser': 'chromium',
  'brave-browser': 'BraveSoftware',
  'microsoft-edge': 'microsoft-edge',
  'microsoft-edge-stable': 'microsoft-edge',
};

/// What [program] (a command's first word, by path or name) needs added to
/// run in a virtual desktop, or null when it needs nothing. With [root] the
/// profile folder is a separate one, so a later run as an ordinary user
/// does not find files root owns in its own.
String? virtualDesktopArgumentsFor(String program, {required bool root}) {
  final name = program.split('/').last;
  final profile = _chromiumPrograms[name];
  if (profile == null) return null;
  return [
    '--disable-gpu',
    if (root) '--no-sandbox --user-data-dir="\$HOME/.config/$profile (root)"',
  ].join(' ');
}

/// Whether [program] is one that needs [virtualDesktopArgumentsFor] as root:
/// what the note under the command field speaks of.
bool needsRootArguments(String program) =>
    _chromiumPrograms.containsKey(program.split('/').last);

// ------------------------------------------------------------ install hints

/// How to install something on the server, for the UI to offer to type into
/// a terminal. Never run by this app: it needs the user's own `sudo`.
class InstallHint {
  const InstallHint({required this.packageManager, required this.command});

  final String packageManager;
  final String command;
}

/// The command that installs a light desktop (Xfce) on [os], or null for a
/// distribution this does not know. Offered when a server has no desktop to
/// run in a virtual desktop: a headless server usually has none, and one
/// program on an empty screen is not what most people are after.
InstallHint? desktopInstallHint(OsRelease os) {
  for (final family in os.families) {
    switch (family) {
      case 'debian' || 'ubuntu' || 'linuxmint' || 'raspbian' || 'pop':
        return const InstallHint(
            packageManager: 'apt',
            command: 'sudo apt install xfce4 xfce4-terminal dbus-x11');
      case 'fedora' || 'rhel' || 'centos' || 'rocky' || 'almalinux' || 'ol' ||
          'amzn':
        return const InstallHint(
            packageManager: 'dnf',
            command: 'sudo dnf install xfce4-session xfwm4 xfce4-panel '
                'xfdesktop xfce4-terminal');
      case 'opensuse' ||
            'opensuse-leap' ||
            'opensuse-tumbleweed' ||
            'suse' ||
            'sles':
        return const InstallHint(
            packageManager: 'zypper',
            command: 'sudo zypper install -t pattern xfce');
      case 'arch' || 'manjaro' || 'endeavouros':
        return const InstallHint(
            packageManager: 'pacman', command: 'sudo pacman -S --needed xfce4');
      case 'alpine':
        return const InstallHint(
            packageManager: 'apk',
            command: 'sudo apk add xfce4 xfce4-terminal dbus-x11');
    }
  }
  return null;
}

/// The command that installs Xvfb on [os], or null for a distribution this
/// does not know — the UI then names the package generically.
///
/// Matched on `ID` first and then each `ID_LIKE`, so a derivative (Pop!_OS,
/// Rocky, EndeavourOS) gets its parent's package manager.
InstallHint? xvfbInstallHint(OsRelease os) {
  for (final family in os.families) {
    switch (family) {
      case 'debian' || 'ubuntu' || 'linuxmint' || 'raspbian' || 'pop':
        return const InstallHint(
            packageManager: 'apt', command: 'sudo apt install xvfb');
      case 'fedora' || 'rhel' || 'centos' || 'rocky' || 'almalinux' || 'ol' ||
          'amzn':
        // RHEL and CentOS 7 predate dnf.
        if ((family == 'rhel' || family == 'centos') &&
            os.versionId.startsWith('7')) {
          return const InstallHint(
              packageManager: 'yum',
              command: 'sudo yum install xorg-x11-server-Xvfb');
        }
        return const InstallHint(
            packageManager: 'dnf',
            command: 'sudo dnf install xorg-x11-server-Xvfb');
      case 'opensuse' ||
            'opensuse-leap' ||
            'opensuse-tumbleweed' ||
            'suse' ||
            'sles':
        return const InstallHint(
            packageManager: 'zypper',
            command: 'sudo zypper install xorg-x11-server-Xvfb');
      case 'arch' || 'manjaro' || 'endeavouros':
        return const InstallHint(
            packageManager: 'pacman',
            command: 'sudo pacman -S --needed xorg-server-xvfb');
      case 'alpine':
        return const InstallHint(
            packageManager: 'apk', command: 'sudo apk add xvfb');
    }
  }
  return null;
}

// ------------------------------------------------------------ apps

/// One application from the server's `.desktop` files.
class DesktopApp {
  const DesktopApp({
    required this.id,
    required this.name,
    required this.argv,
    required this.path,
  });

  /// The desktop-file id, `org.gnome.gedit.desktop`.
  final String id;
  final String name;

  /// `Exec` split into arguments, field codes removed.
  final List<String> argv;

  /// The `.desktop` file it came from.
  final String path;

  /// [argv] as a shell command line, every argument quoted.
  String get command => argv.map(posixSingleQuote).join(' ');
}

/// Where `.desktop` files live, most specific first: a file in the user's
/// own folder shadows a system one with the same id.
const List<String> desktopEntryDirectories = [
  r'$HOME/.local/share/applications',
  '/usr/local/share/applications',
  '/usr/share/applications',
  '/var/lib/flatpak/exports/share/applications',
  '/var/lib/snapd/desktop/applications',
];

/// One `grep -H` over every directory, keeping only the lines the parser
/// reads — group headers and five keys — so a desktop full of translated
/// `Name[xx]=` lines does not cost megabytes of output on a phone.
final String listDesktopAppsCommand = AgentShell.sh('''
for d in ${desktopEntryDirectories.map((d) => d.startsWith(r'$') ? '"$d"' : d).join(' ')}; do
  [ -d "\$d" ] || continue
  grep -H -E '^(\\[|Name=|Exec=|NoDisplay=|Hidden=|Type=|Terminal=)' "\$d"/*.desktop 2>/dev/null
done
true''');

/// Parses [listDesktopAppsCommand]'s output into the apps worth offering:
/// `Type=Application`, not `NoDisplay` or `Hidden`, with an `Exec` that
/// parses. Terminal apps are left out unless [includeTerminal] — inside a
/// bare X display there is no terminal for them to open in.
///
/// Only the `[Desktop Entry]` group counts; `[Desktop Action …]` groups have
/// `Name` and `Exec` keys of their own that must not leak into the entry.
List<DesktopApp> parseDesktopEntries(String output,
    {bool includeTerminal = false}) {
  final byPath = <String, Map<String, String>>{};
  final order = <String>[];
  final group = <String, String>{};
  for (final line in const LineSplitter().convert(output)) {
    final at = line.indexOf('.desktop:');
    if (at < 0) continue;
    final path = line.substring(0, at + 8);
    final content = line.substring(at + 9);
    final entry = byPath.putIfAbsent(path, () {
      order.add(path);
      return <String, String>{};
    });
    if (content.startsWith('[')) {
      group[path] = content.trim();
      continue;
    }
    if (group[path] != '[Desktop Entry]') continue;
    final eq = content.indexOf('=');
    if (eq <= 0) continue;
    entry.putIfAbsent(content.substring(0, eq).trim(), () => content.substring(eq + 1));
  }

  final seen = <String>{};
  final apps = <DesktopApp>[];
  for (final path in order) {
    final id = RemotePath.basename(path);
    // First file with an id wins, whether or not it is offered: a user's
    // own copy with Hidden=true is how a system app is removed from menus.
    if (!seen.add(id)) continue;
    final e = byPath[path]!;
    bool flag(String key) => (e[key] ?? '').trim().toLowerCase() == 'true';
    if ((e['Type'] ?? '').trim() != 'Application') continue;
    if (flag('NoDisplay') || flag('Hidden')) continue;
    if (flag('Terminal') && !includeTerminal) continue;
    final name = _unescapeDesktopString(e['Name'] ?? '').trim();
    final argv = parseDesktopExec(e['Exec'] ?? '');
    if (name.isEmpty || argv == null || argv.isEmpty) continue;
    apps.add(DesktopApp(id: id, name: name, argv: argv, path: path));
  }
  apps.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return apps;
}

/// The Desktop Entry spec's `Exec` key as arguments, or null when it is
/// malformed (an unterminated quote).
///
/// Two layers of escaping, in order: the key file's own string escapes
/// (`\s`, `\n`, `\t`, `\r`, `\\`), then `Exec`'s quoting — arguments may be
/// double-quoted, and inside quotes `\"`, `` \` ``, `\$` and `\\` stand for
/// the character. Field codes are what a launcher substitutes files and
/// URLs into; nothing is being opened here, so they go: an argument that is
/// only a field code is dropped, a code inside one is removed, and `%%` is
/// a percent sign.
List<String>? parseDesktopExec(String exec) {
  final text = _unescapeDesktopString(exec).trim();
  final args = <String>[];
  final current = StringBuffer();
  var inQuotes = false;
  var hasArg = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (inQuotes) {
      if (c == r'\' && i + 1 < text.length && r'"`$\'.contains(text[i + 1])) {
        current.write(text[++i]);
      } else if (c == '"') {
        inQuotes = false;
      } else {
        current.write(c);
      }
      continue;
    }
    if (c == '"') {
      inQuotes = true;
      hasArg = true;
    } else if (c == ' ' || c == '\t') {
      if (hasArg) args.add(current.toString());
      current.clear();
      hasArg = false;
    } else {
      current.write(c);
      hasArg = true;
    }
  }
  if (inQuotes) return null;
  if (hasArg) args.add(current.toString());

  final out = <String>[];
  for (final arg in args) {
    if (RegExp(r'^%[fFuUdDnNickvm]$').hasMatch(arg)) continue;
    final cleaned = arg.replaceAllMapped(RegExp(r'%(.)'), (m) {
      return m[1] == '%' ? '%' : '';
    });
    if (cleaned.isEmpty && arg.isNotEmpty) continue;
    out.add(cleaned);
  }
  return out;
}

String _unescapeDesktopString(String value) {
  final out = StringBuffer();
  for (var i = 0; i < value.length; i++) {
    final c = value[i];
    if (c != r'\' || i + 1 >= value.length) {
      out.write(c);
      continue;
    }
    final n = value[++i];
    out.write(switch (n) {
      's' => ' ',
      'n' => '\n',
      't' => '\t',
      'r' => '\r',
      // One backslash: this layer is applied before Exec's own quoting, so
      // the four backslashes the spec asks for in a quoted argument arrive
      // there as the two that quoting reads as one.
      r'\' => r'\',
      // Not a string escape: left for Exec's quoting (`\"`, `\$`, `\``).
      _ => '\\$n',
    });
  }
  return out.toString();
}

/// The server's applications. Never throws for a server that has none.
Future<List<DesktopApp>> listDesktopApps(SessionTransport transport,
    {bool includeTerminal = false}) async {
  final result = await AgentShell.run(transport, listDesktopAppsCommand,
      what: 'list the applications');
  return parseDesktopEntries(result.stdout, includeTerminal: includeTerminal);
}

// ------------------------------------------------------------ support

/// What the server offers for a virtual desktop, from the probe alone.
class VirtualDesktopSupport {
  const VirtualDesktopSupport({
    required this.hasXvfb,
    required this.xvfbInstall,
    required this.sessions,
    this.desktopInstall,
    required this.keepRunningNeedsLinger,
  });

  factory VirtualDesktopSupport.of(LinuxProbe probe) => VirtualDesktopSupport(
        hasXvfb: probe.hasXvfb,
        xvfbInstall: probe.hasXvfb ? null : xvfbInstallHint(probe.osRelease),
        sessions: probe.virtualSessions,
        desktopInstall: probe.virtualSessions.isEmpty
            ? desktopInstallHint(probe.osRelease)
            : null,
        keepRunningNeedsLinger:
            probe.hasSystemdRun && !probe.lingering,
      );

  final bool hasXvfb;

  /// When Xvfb is missing and the distribution is known.
  final InstallHint? xvfbInstall;

  /// Desktop sessions installed there, for "run a whole desktop".
  final List<VirtualSessionKind> sessions;

  /// How to install a desktop, when the server has none to offer.
  final InstallHint? desktopInstall;

  /// The user manager stops — taking every unit with it, a kept virtual
  /// desktop included — when this account's last login ends, unless
  /// lingering is on. The UI says so next to "Keep running after I
  /// disconnect" and offers [enableLingerCommand].
  final bool keepRunningNeedsLinger;

  static const String enableLingerCommand = 'loginctl enable-linger';
}

// ------------------------------------------------------------ spec, records

/// What runs inside a virtual desktop.
sealed class VirtualDesktopContent {
  const VirtualDesktopContent();
}

/// A whole desktop session.
final class VirtualSessionContent extends VirtualDesktopContent {
  const VirtualSessionContent(this.session);
  final VirtualSessionKind session;
}

/// One application: a shell command line, typed by the user or taken from
/// [DesktopApp.command].
final class VirtualAppContent extends VirtualDesktopContent {
  const VirtualAppContent(this.command, {this.label});
  final String command;
  final String? label;
}

/// A virtual desktop to start.
class VirtualDesktopSpec {
  const VirtualDesktopSpec({
    required this.width,
    required this.height,
    required this.content,
    this.keepRunning = false,
  });

  /// The X screen size — the client's viewport, so 1:1 needs no scaling.
  final int width;
  final int height;
  final VirtualDesktopContent content;

  /// "Keep running after I disconnect". Off: the agent exits 30 s after its
  /// viewer leaves and takes the X server and the apps with it. On: no idle
  /// exit, and a record in `~/.cache/secureshellgo/vdesk/` lets
  /// [VirtualDesktops.list] find it again.
  final bool keepRunning;

  static const int minSize = 64;
  static const int maxSize = 8192;
}

/// A kept virtual desktop, from `~/.cache/secureshellgo/vdesk/<id>.json`.
class VirtualDesktopRecord {
  const VirtualDesktopRecord({
    required this.id,
    required this.unit,
    required this.display,
    required this.width,
    required this.height,
    required this.content,
    required this.command,
    required this.label,
    required this.runtimeDir,
    required this.createdAt,
    required this.agentSha256,
  });

  final String id;

  /// The systemd user unit, `ssgo-vd-<id>`. Recorded whether or not the
  /// server had systemd; without it the desktop is a process group whose
  /// leader's pid sits beside the record.
  final String unit;

  /// `:23`.
  final String display;
  final int width;
  final int height;

  /// `session` or `app`.
  final String content;

  /// The session program, or the app's command line.
  final String command;
  final String label;
  final String runtimeDir;
  final DateTime createdAt;
  final String agentSha256;

  static final RegExp _display = RegExp(r'^:\d{1,4}$');

  /// Parses a record, or returns null for anything that is not one — a
  /// half-written or hand-edited file is pruned, not trusted.
  static VirtualDesktopRecord? tryParse(String text, {String? expectId}) {
    try {
      final json = jsonDecode(text);
      if (json is! Map<String, Object?> || json['v'] != 1) return null;
      final id = json['id'];
      final unit = json['unit'];
      final display = json['display'];
      final width = json['width'];
      final height = json['height'];
      final content = json['content'];
      final command = json['command'];
      final label = json['label'];
      final rt = json['runtimeDir'];
      final created = json['createdAt'];
      final agent = json['agent'];
      if (id is! String || !AgentShell.idPattern.hasMatch(id)) return null;
      if (expectId != null && id != expectId) return null;
      if (unit != 'ssgo-vd-$id') return null;
      if (display is! String) return null;
      if (width is! int || height is! int) return null;
      if (content != 'session' && content != 'app') return null;
      if (command is! String || label is! String) return null;
      if (rt is! String || created is! String || agent is! String) return null;
      if (!rt.startsWith('/') || RemotePath.basename(rt) != 'ssgo-vd-$id') {
        return null;
      }
      return VirtualDesktopRecord(
        id: id,
        unit: unit as String,
        display: _display.hasMatch(display) ? display : '',
        width: width,
        height: height,
        content: content as String,
        command: command,
        label: label,
        runtimeDir: rt,
        createdAt: DateTime.parse(created),
        agentSha256: agent,
      );
    } catch (_) {
      return null;
    }
  }
}

/// A virtual desktop that is up, with its agent reachable.
class VirtualDesktopSession {
  const VirtualDesktopSession({
    required this.id,
    required this.display,
    required this.endpoint,
    this.record,
  });

  final String id;
  final String display;

  /// Its [AgentEndpoint.stop] stops the whole desktop — X server, apps and
  /// agent. A viewer closing a kept desktop must therefore *not* call it;
  /// for one that is not kept, calling it is optional (the idle exit does
  /// the same 30 s later).
  final AgentEndpoint endpoint;

  /// Present for a kept desktop.
  final VirtualDesktopRecord? record;

  bool get keepsRunning => record != null;
}

// ------------------------------------------------------------ launching

/// Starts, finds and stops virtual desktops on a Linux server.
///
/// **One unit.** The X server, what runs in it and the agent are all
/// children of one supervisor script in one `systemd-run --user` unit, so
/// stopping the unit — or the supervisor leaving it when the agent exits —
/// kills the lot. Without a user systemd the supervisor runs under `setsid`
/// and takes its process group down instead.
///
/// **Isolation.** Nothing inside a virtual desktop may reach the account's
/// real desktop, if it has one: the X server, the session and the agent all
/// start from `env -i` with an explicit, short list of variables. No
/// `WAYLAND_DISPLAY`, no session bus — the session gets a private one from
/// `dbus-run-session` — and a private `XDG_RUNTIME_DIR`, because
/// libwayland connects to `$XDG_RUNTIME_DIR/wayland-0` when
/// `WAYLAND_DISPLAY` is merely unset, and a GTK app would otherwise open on
/// the real desktop. `GDK_BACKEND=x11` and `QT_QPA_PLATFORM=xcb` say the
/// same thing to the toolkits, and the agent is pinned to its X11 backend.
///
/// **The X cookie.** A fresh MIT-MAGIC-COOKIE-1 from `/dev/urandom`, written
/// with `printf` and `dd` straight into a 0600 file as a FamilyWild record
/// with no display number — which libXau and x11rb both match against any
/// display, so the file can be written before the display number is known.
/// The cookie never appears on a command line, where any account on the
/// server could read it from `ps`, and nothing needs `xauth`.
///
/// **The display race.** A free `:N` is one with no socket in
/// `/tmp/.X11-unix` and no `/tmp/.XN-lock`, but another X server can take it
/// between that check and Xvfb's start. Xvfb's own lock is created
/// exclusively and it exits if it loses, so the supervisor simply tries the
/// next number; `-displayfd` tells it when the server is actually accepting
/// connections rather than merely running.
class VirtualDesktops {
  const VirtualDesktops();

  static const String recordDirectory = r'$HOME/.cache/secureshellgo/vdesk';

  /// Where a desktop's runtime directory goes: under `XDG_RUNTIME_DIR`
  /// (a tmpfs that logind empties at logout and boot), else in the cache.
  static String runtimeDirFor(LinuxProbe probe, String id) {
    final base = probe.runtimeDir.isNotEmpty
        ? probe.runtimeDir
        : RemotePath.join(probe.home, '.cache/secureshellgo/rt');
    return RemotePath.join(base, 'ssgo-vd-$id');
  }

  Future<VirtualDesktopSession> start(
    SessionTransport transport,
    LinuxProbe probe,
    DeployedAgent agent,
    VirtualDesktopSpec spec, {
    Duration timeout = const Duration(seconds: 20),
    DateTime? now,
  }) async {
    if (agent.os != AgentOs.linux || agent.binary.flavour != AgentFlavour.x11) {
      throw ArgumentError.value(agent.path, 'agent', 'needs the x11 build');
    }
    if (!probe.hasXvfb) {
      final hint = xvfbInstallHint(probe.osRelease);
      throw AgentFailure(
        AgentFailureKind.missingTool,
        'Virtual desktops need Xvfb, which this server does not have.',
        installCommand: hint?.command,
      );
    }
    final id = AgentShell.newId();
    final runtimeDir = runtimeDirFor(probe, id);
    final createdAt = now ?? DateTime.now();
    final command = launchCommand(
      agent: agent,
      id: id,
      runtimeDir: runtimeDir,
      spec: spec,
      createdAt: createdAt,
      useSystemd: true,
      timeout: timeout,
    );
    final result = await AgentShell.run(transport, command,
        what: 'start the virtual desktop',
        timeout: timeout + const Duration(seconds: 15));
    final lines = AgentShell.lines(result.stdout);
    checkLaunch(lines, result.stderr, probe);
    final json = AgentShell.between(lines, 'SSG-READY', 'SSG-END')!;
    final AgentHostInfo info;
    try {
      info = AgentHostInfo.parse(json);
    } on AgentFailure {
      // The desktop is up even if its agent published nonsense; take it down.
      try {
        await stop(transport, id);
      } catch (_) {
        // The failure being reported is the one that matters.
      }
      rethrow;
    }
    final display = AgentShell.valueAfter(lines, 'SSG-DISPLAY ') ?? '';
    final mode = AgentShell.valueAfter(lines, 'SSG-MODE ') ?? '';
    final endpoint = AgentEndpoint(
      info: info,
      os: AgentOs.linux,
      runtimeDir: runtimeDir,
      unitName: mode.startsWith('systemd ') ? 'ssgo-vd-$id' : null,
      stop: () => stop(transport, id),
    );
    VirtualDesktopRecord? record;
    if (spec.keepRunning) {
      final (head, tail) = recordParts(
          id: id, runtimeDir: runtimeDir, spec: spec, agent: agent,
          createdAt: createdAt);
      record = VirtualDesktopRecord.tryParse('$head$display$tail');
    }
    return VirtualDesktopSession(
        id: id, display: display, endpoint: endpoint, record: record);
  }

  /// Waits up to [within] for the program in a virtual desktop to fail.
  ///
  /// The launch already catches a program that fails at once; some take
  /// longer to give up (a snap spends seconds just starting), and by then
  /// the viewer is open on an empty screen. This keeps watching for a while
  /// afterwards, in one exec. Returns the exit code and the end of the
  /// program's output when it failed, or null when it is still running at
  /// the end, ended well, or the desktop has gone.
  Future<({int code, String log})?> watchProgram(
    SessionTransport transport,
    String runtimeDir, {
    Duration within = const Duration(seconds: 30),
  }) async {
    final seconds = within.inSeconds < 1 ? 1 : within.inSeconds;
    final result = await AgentShell.run(
      transport,
      AgentShell.sh('''
rt=\$1
i=0
while [ \$i -lt $seconds ]; do
  [ -d "\$rt" ] || { echo SSG-GONE; exit 0; }
  if [ -s "\$rt/app.exit" ]; then
    echo "SSG-APP-EXITED \$(cat "\$rt/app.exit")"
    echo SSG-LOG
    grep -v 'Could not resolve keysym' "\$rt/session.log" 2>/dev/null | tail -n 15
    exit 0
  fi
  sleep 1
  i=\$((i + 1))
done
echo SSG-RUNNING''', [runtimeDir]),
      what: 'watch the program in the virtual desktop',
      timeout: within + const Duration(seconds: 15),
    );
    return parseWatch(result.stdout);
  }

  /// [watchProgram]'s output. Public for its tests.
  static ({int code, String log})? parseWatch(String output) {
    final lines = AgentShell.lines(output);
    final code = int.tryParse(AgentShell.valueAfter(lines, 'SSG-APP-EXITED ') ?? '');
    if (code == null || code == 0) return null;
    return (code: code, log: AgentShell.after(lines, 'SSG-LOG'));
  }

  /// Turns the launch script's output into an [AgentFailure], or returns
  /// when the desktop is ready. Public for its tests.
  static void checkLaunch(List<String> lines, String stderr, LinuxProbe probe) {
    if (lines.contains('SSG-NO-XVFB')) {
      throw AgentFailure(
        AgentFailureKind.missingTool,
        'Virtual desktops need Xvfb, which this server does not have.',
        installCommand: xvfbInstallHint(probe.osRelease)?.command,
      );
    }
    if (lines.contains('SSG-MISSING') ||
        lines.contains('SSG-NO-HASH-TOOL') ||
        lines.any((l) => l.startsWith('SSG-HASH-MISMATCH'))) {
      // Same wording as desktop mode.
      final mismatch = AgentShell.valueAfter(lines, 'SSG-HASH-MISMATCH');
      throw AgentFailure(
        mismatch != null
            ? AgentFailureKind.hashMismatch
            : (lines.contains('SSG-MISSING')
                ? AgentFailureKind.launchFailed
                : AgentFailureKind.missingTool),
        mismatch != null
            ? 'The remote-desktop agent on the server has been changed since '
                'it was installed, so it was not run. Connecting again '
                'replaces it.'
            : lines.contains('SSG-MISSING')
                ? 'The remote-desktop agent is no longer on the server; '
                    'connecting again will put it back.'
                : 'This server has no way to check the remote-desktop agent '
                    'before it runs (sha256sum, shasum or openssl).',
        details: mismatch == null ? null : 'the server\'s copy hashes to $mismatch',
      );
    }
    if (AgentShell.between(lines, 'SSG-READY', 'SSG-END') != null) return;
    final log = AgentShell.after(lines, 'SSG-LOG');
    final details = [log, stderr.trim()].where((s) => s.isNotEmpty).join('\n');
    final exited = int.tryParse(AgentShell.valueAfter(lines, 'SSG-APP-EXITED ') ?? '');
    if (exited != null) {
      // Without this the viewer opened on an empty black screen, with
      // nothing to say the program never started. Its own error, from the
      // log, is in [details].
      throw AgentFailure(
        AgentFailureKind.launchFailed,
        switch (exited) {
          127 => 'The program is not installed on the server, or is not on '
              'its PATH, so the virtual desktop was not started.',
          126 => 'The program could not be run (it is not executable), so '
              'the virtual desktop was not started.',
          _ => 'The program stopped as soon as it started (exit code '
              '$exited), so the virtual desktop was not started.',
        },
        details: details.isEmpty ? null : details,
      );
    }
    throw AgentFailure(
      lines.contains('SSG-TIMEOUT')
          ? AgentFailureKind.launchTimedOut
          : AgentFailureKind.launchFailed,
      'The virtual desktop could not be started.',
      details: details.isEmpty ? null : details,
    );
  }

  /// The record split around the display, which only the server knows once
  /// Xvfb is up: the launch script prints `<head><display><tail>`. The
  /// display is `:` and digits, so nothing about it needs escaping, and
  /// everything else was encoded here.
  static (String, String) recordParts({
    required String id,
    required String runtimeDir,
    required VirtualDesktopSpec spec,
    required DeployedAgent agent,
    required DateTime createdAt,
  }) {
    final content = spec.content;
    final head = jsonEncode({'v': 1, 'id': id, 'unit': 'ssgo-vd-$id'});
    final tail = jsonEncode({
      'width': spec.width,
      'height': spec.height,
      'content': content is VirtualSessionContent ? 'session' : 'app',
      'command': switch (content) {
        VirtualSessionContent(:final session) => session.command,
        VirtualAppContent(:final command) => command,
      },
      'label': switch (content) {
        VirtualSessionContent(:final session) => session.label,
        VirtualAppContent(:final command, :final label) => label ?? command,
      },
      'runtimeDir': runtimeDir,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'agent': agent.binary.sha256,
    });
    return (
      '${head.substring(0, head.length - 1)},"display":"',
      '",${tail.substring(1)}',
    );
  }

  /// The supervisor: the main process of the unit. Its arguments are
  /// `rt agent width height mode command idle id`. See [VirtualDesktops].
  static const String supervisorScript = r'''
rt=$1; a=$2; w=$3; h=$4; mode=$5; cmd=$6; idle=$7; id=$8
vd="$HOME/.cache/secureshellgo/vdesk"
umask 077
cd "$HOME" 2>/dev/null || cd /
cleanup() { rm -rf "$rt"; rm -f "$vd/$id.json" "$vd/$id.json.tmp" "$vd/$id.pid"; }
trap 'cleanup; exit 0' TERM INT HUP
mkdir -p "$rt/xdg" "$rt/agent" && chmod 700 "$rt/xdg" "$rt/agent" || exit 1
{ printf '\377\377\000\000\000\000\000\022MIT-MAGIC-COOKIE-1\000\020'; dd if=/dev/urandom bs=16 count=1 2>/dev/null; } > "$rt/xauth"
[ "$(($(wc -c < "$rt/xauth")))" -eq 44 ] || { echo "could not make an X cookie" >&2; cleanup; exit 1; }
fd=1
n=20
while :; do
  if [ "$n" -gt 299 ]; then echo "no free X display between :20 and :299" >&2; cleanup; exit 1; fi
  if [ -e "/tmp/.X11-unix/X$n" ] || [ -e "/tmp/.X$n-lock" ]; then n=$((n + 1)); continue; fi
  : > "$rt/xready"
  : > "$rt/xvfb.log"
  if [ "$fd" = 1 ]; then
    Xvfb ":$n" -screen 0 "${w}x${h}x24" -nolisten tcp -auth "$rt/xauth" -displayfd 3 3> "$rt/xready" >> "$rt/xvfb.log" 2>&1 &
  else
    Xvfb ":$n" -screen 0 "${w}x${h}x24" -nolisten tcp -auth "$rt/xauth" >> "$rt/xvfb.log" 2>&1 &
  fi
  x=$!
  i=0
  up=no
  while [ "$i" -lt 100 ] && kill -0 "$x" 2>/dev/null; do
    if [ "$fd" = 1 ]; then [ -s "$rt/xready" ] && { up=yes; break; }; else [ -S "/tmp/.X11-unix/X$n" ] && { up=yes; break; }; fi
    sleep 0.1 2>/dev/null || sleep 1
    i=$((i + 1))
  done
  [ "$up" = yes ] && break
  kill "$x" 2>/dev/null
  if [ "$fd" = 1 ] && grep -q displayfd "$rt/xvfb.log" 2>/dev/null; then fd=0; continue; fi
  if grep -qiE 'already active|server lock|in use' "$rt/xvfb.log" 2>/dev/null; then n=$((n + 1)); continue; fi
  echo "Xvfb did not start:" >&2; tail -n 15 "$rt/xvfb.log" >&2; cleanup; exit 1
done
D=":$n"
echo "$D" > "$rt/display"
if command -v dbus-run-session >/dev/null 2>&1; then bus="dbus-run-session --"; elif command -v dbus-launch >/dev/null 2>&1; then bus=dbus-launch; else bus=; fi
xenv() { env -i HOME="$HOME" USER="${USER:-}" LOGNAME="${LOGNAME:-${USER:-}}" SHELL="${SHELL:-/bin/sh}" PATH="$PATH" LANG="${LANG:-C.UTF-8}" XDG_RUNTIME_DIR="$rt/xdg" DISPLAY="$D" XAUTHORITY="$rt/xauth" XDG_SESSION_TYPE=x11 GDK_BACKEND=x11 QT_QPA_PLATFORM=xcb SSGO_VDESK="$id" "$@"; }
case "$mode" in
  session) ( xenv $bus "$cmd" >> "$rt/session.log" 2>&1; echo $? > "$rt/app.exit" ) & ;;
  app) ( xenv $bus sh -c "$cmd" >> "$rt/session.log" 2>&1; echo $? > "$rt/app.exit" ) & ;;
esac
set -- --runtime-dir "$rt/agent" --no-notify
if [ "$idle" -gt 0 ]; then set -- "$@" --exit-when-idle "$idle"; fi
env -i HOME="$HOME" PATH="$PATH" LANG="${LANG:-C.UTF-8}" XDG_RUNTIME_DIR="$rt/xdg" DISPLAY="$D" XAUTHORITY="$rt/xauth" CROSSSHELL_LINUX_BACKEND=x11 SSGO_VDESK="$id" "$a" "$@" >> "$rt/agent.log" 2>&1 &
g=$!
while kill -0 "$g" 2>/dev/null && kill -0 "$x" 2>/dev/null; do sleep 1; done
cleanup
if [ -z "${SSGO_UNIT:-}" ]; then trap '' TERM; kill -TERM 0 2>/dev/null; fi
exit 0''';

  /// The launch script: check the agent, write the supervisor and (for a
  /// kept desktop) the record, start the unit, wait for `host.json`.
  ///
  /// The record is written *before* the unit starts, with an empty display,
  /// so a client that drops between the two never leaves a kept desktop
  /// that nothing lists; it is rewritten with the display once Xvfb is up.
  static String launchCommand({
    required DeployedAgent agent,
    required String id,
    required String runtimeDir,
    required VirtualDesktopSpec spec,
    required DateTime createdAt,
    bool useSystemd = true,
    Duration timeout = const Duration(seconds: 20),
  }) {
    if (!AgentShell.idPattern.hasMatch(id)) {
      throw ArgumentError.value(id, 'id', 'not a virtual desktop id');
    }
    AgentLauncher.checkRuntimeDir(runtimeDir, windows: false);
    final w = spec.width.clamp(VirtualDesktopSpec.minSize, VirtualDesktopSpec.maxSize);
    final h = spec.height.clamp(VirtualDesktopSpec.minSize, VirtualDesktopSpec.maxSize);
    final content = spec.content;
    final (mode, cmd) = switch (content) {
      VirtualSessionContent(:final session) => ('session', session.command),
      VirtualAppContent(:final command) => ('app', command),
    };
    if (cmd.trim().isEmpty) throw ArgumentError.value(cmd, 'command', 'empty');
    final idle = spec.keepRunning ? 0 : 30;
    final (head, tail) = recordParts(
        id: id, runtimeDir: runtimeDir, spec: spec, agent: agent, createdAt: createdAt);
    final keep = spec.keepRunning;
    final polls = (timeout.inMilliseconds / 200).ceil();
    if (supervisorScript.contains(_heredocEnd)) throw StateError('heredoc');
    // `$1` agent, `$2` runtime directory, `$3` `$4` the record around its
    // display, `$5` what runs inside: data, never spliced into the script
    // (see [AgentShell.sh]). The supervisor goes in through a quoted
    // heredoc for the same reason — it is fixed text, but it has quotes of
    // its own, and quoting it a second time is what fish cannot read.
    return AgentShell.sh('''
${AgentShell.shHashFunction}
${AgentShell.shRuntimeDir}
a=\$1; rt=\$2; rec_head=\$3; rec_tail=\$4; cmd=\$5
[ -f "\$a" ] || { echo SSG-MISSING; exit 3; }
h=\$(ssg_hash "\$a")
[ -n "\$h" ] || { echo SSG-NO-HASH-TOOL; exit 3; }
[ "\$h" = ${agent.binary.sha256} ] || { echo "SSG-HASH-MISMATCH \$h"; exit 3; }
command -v Xvfb >/dev/null 2>&1 || { echo SSG-NO-XVFB; exit 3; }
id=$id
vd="$recordDirectory"
umask 077
mkdir -p "\$rt" "\$vd" && chmod 700 "\$rt" "\$vd" || { echo SSG-LAUNCH-FAILED; exit 4; }
echo "SSG-RT \$rt"
cat > "\$rt/run.sh" <<'$_heredocEnd'
$supervisorScript
$_heredocEnd
record() { ${keep ? 'printf \'%s%s%s\\n\' "\$rec_head" "\$1" "\$rec_tail" > "\$vd/\$id.json.tmp" && mv -f "\$vd/\$id.json.tmp" "\$vd/\$id.json"' : ':'}; }
record ''
unit=ssgo-vd-\$id
p=
set -- "\$rt/run.sh" "\$rt" "\$a" $w $h $mode "\$cmd" $idle "\$id"
if ${useSystemd ? '{ ${AgentShell.shHasUserSystemd}; }' : 'false'}; then
  if ! systemd-run --user --collect --quiet --unit="\$unit" -p TimeoutStopSec=10 --setenv=SSGO_UNIT="\$unit" sh "\$@" > "\$rt/launch.log" 2>&1; then
    echo SSG-LAUNCH-FAILED; echo SSG-LOG; tail -n 20 "\$rt/launch.log"; rm -rf "\$rt"; rm -f "\$vd/\$id.json"; exit 4
  fi
  echo "SSG-MODE systemd \$unit"
else
  if command -v setsid >/dev/null 2>&1; then d=setsid; else d=nohup; fi
  \$d sh "\$@" < /dev/null > "\$rt/launch.log" 2>&1 &
  p=\$!
  echo "\$p" > "\$rt/supervisor.pid"
  ${keep ? 'echo "\$p" > "\$vd/\$id.pid"' : ':'}
  echo "SSG-MODE pid \$p"
  unit=
fi
alive() { if [ -n "\$unit" ]; then systemctl --user is-active --quiet "\$unit"; else kill -0 "\$p" 2>/dev/null; fi; }
n=0
while [ \$n -lt $polls ]; do
  if [ -s "\$rt/agent/host.json" ]; then
    # The program inside starts before the agent, so one that cannot run at
    # all (not installed, no permission) has usually failed by now; a short
    # grace catches the slower failures. Only a failure counts: a launcher
    # that hands its window to another process and exits 0 is fine.
    g=0
    while [ \$g -lt 3 ] && [ ! -s "\$rt/app.exit" ]; do ${AgentShell.shShortSleep}; g=\$((g + 1)); done
    e=\$(cat "\$rt/app.exit" 2>/dev/null)
    if [ -n "\$e" ] && [ "\$e" != 0 ]; then echo "SSG-APP-EXITED \$e"; break; fi
    D=\$(cat "\$rt/display" 2>/dev/null)
    record "\$D"
    echo "SSG-DISPLAY \$D"; echo SSG-READY; cat "\$rt/agent/host.json"; echo; echo SSG-END; exit 0
  fi
  alive || { [ -s "\$rt/agent/host.json" ] && continue; echo SSG-EXITED; break; }
  ${AgentShell.shShortSleep}
  n=\$((n + 1))
done
[ \$n -lt $polls ] || echo SSG-TIMEOUT
echo SSG-LOG
# The program's own output first: when it is what failed, its error is the
# one line that matters. Xvfb's keyboard-map warnings are noise on every start.
for f in session.log launch.log xvfb.log agent.log agent/host.log; do [ -s "\$rt/\$f" ] && { echo "--- \$f"; grep -v 'Could not resolve keysym' "\$rt/\$f" | tail -n 15; }; done
[ -n "\$unit" ] && journalctl --user -u "\$unit" -n 15 --no-pager -o cat 2>/dev/null
if [ -n "\$unit" ]; then systemctl --user stop "\$unit" 2>/dev/null; else kill -TERM "-\$p" 2>/dev/null || kill "\$p" 2>/dev/null; fi
rm -rf "\$rt"; rm -f "\$vd/\$id.json" "\$vd/\$id.json.tmp" "\$vd/\$id.pid"
exit 5''', [agent.path, runtimeDir, head, tail, cmd]);
  }

  static const String _heredocEnd = 'SSGO_RUN_EOF';

  // ---------------------------------------------------------------- list

  /// One `#=ssg=rec <id> <state>` block per record, `state` being `unit`
  /// (its systemd unit is active), `pid` (its supervisor is alive, checked
  /// by command line so a reused pid does not count), or `dead`.
  static final String listCommand = AgentShell.sh('''
${AgentShell.shRuntimeDir}
vd="$recordDirectory"
for f in "\$vd"/*.json; do
  [ -f "\$f" ] || continue
  id=\${f##*/}; id=\${id%.json}
  case "\$id" in *[!0-9a-f]*|'') continue ;; esac
  st=dead
  if systemctl --user is-active --quiet "ssgo-vd-\$id.service" 2>/dev/null; then st=unit
  elif [ -f "\$vd/\$id.pid" ]; then
    p=\$(cat "\$vd/\$id.pid")
    case "\$p" in ''|*[!0-9]*) ;; *) tr '\\000' ' ' < "/proc/\$p/cmdline" 2>/dev/null | grep -qF "ssgo-vd-\$id" && st=pid ;; esac
  fi
  echo "#=ssg=rec \$id \$st"
  cat "\$f"
  echo
done
echo "#=ssg=end"''');

  /// Parses [listCommand]'s output into `(record, alive)` pairs, plus the
  /// ids whose files are not valid records at all.
  static ({List<(VirtualDesktopRecord, bool)> records, List<String> invalid})
      parseList(String output) {
    final records = <(VirtualDesktopRecord, bool)>[];
    final invalid = <String>[];
    String? id;
    var alive = false;
    final body = StringBuffer();
    void flush() {
      final current = id;
      if (current == null) return;
      final record = VirtualDesktopRecord.tryParse(body.toString().trim(),
          expectId: current);
      if (record == null) {
        invalid.add(current);
      } else {
        records.add((record, alive));
      }
      body.clear();
    }

    for (final line in AgentShell.lines(output)) {
      if (line.startsWith('#=ssg=')) {
        flush();
        id = null;
        final parts = line.substring(6).split(' ');
        if (parts.length == 3 &&
            parts[0] == 'rec' &&
            AgentShell.idPattern.hasMatch(parts[1])) {
          id = parts[1];
          alive = parts[2] == 'unit' || parts[2] == 'pid';
        }
        continue;
      }
      if (id != null) body.writeln(line);
    }
    flush();
    return (records: records, invalid: invalid);
  }

  /// The kept virtual desktops still running on the server, newest first.
  /// Records whose desktop is gone — a reboot, an Xvfb crash, a stop from
  /// another client — and files that are not records are removed on the way.
  Future<List<VirtualDesktopRecord>> list(SessionTransport transport) async {
    final result = await AgentShell.run(transport, listCommand,
        what: 'list the virtual desktops');
    final parsed = parseList(result.stdout);
    final dead = [
      for (final (record, alive) in parsed.records)
        if (!alive) record.id,
      ...parsed.invalid,
    ];
    if (dead.isNotEmpty) {
      await AgentShell.run(transport, pruneCommand(dead),
          what: 'tidy up stopped virtual desktops');
    }
    return [
      for (final (record, alive) in parsed.records)
        if (alive) record,
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  /// Removes the records and runtime directories of [ids]. Only ever called
  /// for ids [listCommand] found dead, and it does not stop anything.
  static String pruneCommand(List<String> ids) {
    for (final id in ids) {
      if (!AgentShell.idPattern.hasMatch(id)) {
        throw ArgumentError.value(id, 'id', 'not a virtual desktop id');
      }
    }
    return AgentShell.sh('''
${AgentShell.shRuntimeDir}
vd="$recordDirectory"
for id in ${ids.join(' ')}; do
  rm -f "\$vd/\$id.json" "\$vd/\$id.json.tmp" "\$vd/\$id.pid"
  rm -rf "\${XDG_RUNTIME_DIR:-/nonexistent}/ssgo-vd-\$id" "\$HOME/.cache/secureshellgo/rt/ssgo-vd-\$id"
done
echo SSG-PRUNED''');
  }

  // ---------------------------------------------------------------- attach

  /// Reconnects to a kept desktop: reads its agent's `host.json` again.
  /// Its [AgentEndpoint.stop] stops the desktop — see
  /// [VirtualDesktopSession.endpoint].
  Future<AgentEndpoint> attach(
    SessionTransport transport,
    VirtualDesktopRecord record,
  ) async {
    AgentLauncher.checkRuntimeDir(record.runtimeDir, windows: false);
    final result = await AgentShell.run(
      transport,
      AgentShell.sh('''
rt=\$1
if [ -s "\$rt/agent/host.json" ]; then echo SSG-READY; cat "\$rt/agent/host.json"; echo; echo SSG-END; else echo SSG-GONE; fi''', [record.runtimeDir]),
      what: 'reconnect to the virtual desktop',
    );
    final lines = AgentShell.lines(result.stdout);
    final json = AgentShell.between(lines, 'SSG-READY', 'SSG-END');
    if (json == null) {
      throw const AgentFailure(AgentFailureKind.notFound,
          'That virtual desktop is not running any more.');
    }
    return AgentEndpoint(
      info: AgentHostInfo.parse(json),
      os: AgentOs.linux,
      runtimeDir: record.runtimeDir,
      unitName: record.unit,
      stop: () => stop(transport, record.id),
    );
  }

  // ---------------------------------------------------------------- stop

  /// Stops a virtual desktop — X server, apps, agent — and removes its
  /// record and runtime directory. Idempotent; stopping one that is already
  /// gone just tidies up.
  Future<void> stop(SessionTransport transport, String id) async {
    await AgentShell.run(transport, stopCommand(id),
        what: 'stop the virtual desktop', timeout: const Duration(seconds: 20));
  }

  /// The supervisor of a `setsid` desktop leads its own process group, so a
  /// negative pid reaches everything it started; it is only signalled after
  /// its command line shows it is this desktop's supervisor.
  ///
  /// `kill -TERM "-PGID"`, never `kill -TERM -- -PGID`: dash (Debian's and
  /// Ubuntu's `sh`) and BusyBox reject the `--`, and the group would quietly
  /// outlive its supervisor.
  static String stopCommand(String id) {
    if (!AgentShell.idPattern.hasMatch(id)) {
      throw ArgumentError.value(id, 'id', 'not a virtual desktop id');
    }
    return AgentShell.sh('''
${AgentShell.shRuntimeDir}
id=$id
vd="$recordDirectory"
x="\${XDG_RUNTIME_DIR:-/nonexistent}/ssgo-vd-\$id"
c="\$HOME/.cache/secureshellgo/rt/ssgo-vd-\$id"
systemctl --user stop "ssgo-vd-\$id.service" 2>/dev/null
for f in "\$vd/\$id.pid" "\$x/supervisor.pid" "\$c/supervisor.pid"; do
  [ -f "\$f" ] || continue
  p=\$(cat "\$f")
  case "\$p" in ''|*[!0-9]*) continue ;; esac
  if tr '\\000' ' ' < "/proc/\$p/cmdline" 2>/dev/null | grep -qF "ssgo-vd-\$id"; then
    kill -TERM "-\$p" 2>/dev/null || kill "\$p" 2>/dev/null
    i=0
    while kill -0 "\$p" 2>/dev/null && [ \$i -lt 25 ]; do ${AgentShell.shShortSleep}; i=\$((i + 1)); done
    kill -KILL "-\$p" 2>/dev/null
  fi
done
rm -rf "\$x" "\$c"
rm -f "\$vd/\$id.json" "\$vd/\$id.json.tmp" "\$vd/\$id.pid"
echo SSG-STOPPED''');
  }
}

/// [VirtualDesktops.list], under the name the UI code reaches for.
Future<List<VirtualDesktopRecord>> listVirtualDesktops(
        SessionTransport transport) =>
    const VirtualDesktops().list(transport);

/// [VirtualDesktops.stop], under the name the UI code reaches for.
Future<void> stopVirtualDesktop(SessionTransport transport, String id) =>
    const VirtualDesktops().stop(transport, id);
