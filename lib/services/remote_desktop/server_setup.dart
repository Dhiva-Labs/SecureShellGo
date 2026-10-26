import 'dart:async';
import 'dart:convert';

import '../shell_quote.dart';
import '../ssh_service.dart';
import 'agent_probe.dart';
import 'agent_shell.dart';

/// Installing what a virtual desktop needs, on the server, for the person
/// who asked: "Install" in the app instead of a command to copy into a
/// terminal and a package name to look up.
///
/// It only ever runs because someone pressed a button that said what it
/// would install, and it installs exactly that: fixed package names from
/// [SetupPackages], or the one package the server's own command-not-found
/// names for a program the person typed. A sudo password, when one is
/// needed, is asked for at that moment, goes to `sudo -S` on the channel's
/// stdin — never on a command line, where `ps` would show it — and is not
/// kept anywhere.

/// The package manager on the server.
enum PackageManager { apt, dnf, yum, zypper, pacman, apk }

/// Which package manager [os] uses, by its `ID` and then each `ID_LIKE`, or
/// null for a distribution this does not know.
PackageManager? packageManagerFor(OsRelease os) {
  for (final family in os.families) {
    switch (family) {
      case 'debian' || 'ubuntu' || 'linuxmint' || 'raspbian' || 'pop':
        return PackageManager.apt;
      case 'fedora' || 'rhel' || 'centos' || 'rocky' || 'almalinux' || 'ol' ||
          'amzn':
        // RHEL and CentOS 7 predate dnf.
        if ((family == 'rhel' || family == 'centos') &&
            os.versionId.startsWith('7')) {
          return PackageManager.yum;
        }
        return PackageManager.dnf;
      case 'opensuse' ||
            'opensuse-leap' ||
            'opensuse-tumbleweed' ||
            'suse' ||
            'sles':
        return PackageManager.zypper;
      case 'arch' || 'manjaro' || 'endeavouros':
        return PackageManager.pacman;
      case 'alpine':
        return PackageManager.apk;
    }
  }
  return null;
}

/// What a virtual desktop can need, by package manager.
abstract final class SetupPackages {
  /// The X server a virtual desktop runs in.
  static List<String> xvfb(PackageManager pm) => switch (pm) {
        PackageManager.apt => ['xvfb'],
        PackageManager.dnf || PackageManager.yum => ['xorg-x11-server-Xvfb'],
        PackageManager.zypper => ['xorg-x11-server-Xvfb'],
        PackageManager.pacman => ['xorg-server-xvfb'],
        PackageManager.apk => ['xvfb'],
      };

  /// A light desktop to run in it: Xfce, its terminal and file manager, and
  /// no more. Recommended packages are left out where the manager allows
  /// ([installScript]); with them, apt would also bring a full X server and
  /// its drivers, which a virtual desktop has no use for.
  static List<String> desktop(PackageManager pm) => switch (pm) {
        PackageManager.apt => [
            'xfce4',
            'xfce4-terminal',
            'dbus-x11',
            'adwaita-icon-theme',
          ],
        PackageManager.dnf || PackageManager.yum => [
            'xfce4-session',
            'xfwm4',
            'xfce4-panel',
            'xfdesktop',
            'xfce4-terminal',
            'Thunar',
            'dbus-x11',
          ],
        PackageManager.zypper => [
            'xfce4-session',
            'xfwm4',
            'xfce4-panel',
            'xfdesktop',
            'xfce4-terminal',
            'thunar',
          ],
        PackageManager.pacman => ['xfce4'],
        PackageManager.apk => ['xfce4', 'xfce4-terminal', 'dbus-x11'],
      };
}

/// A package name as the managers above spell them: nothing a shell could
/// read as anything else. Every name that reaches [installScript] is checked
/// against this, the ones command-not-found suggests included.
final RegExp _packageName = RegExp(r'^[A-Za-z0-9][A-Za-z0-9.+_-]{0,127}$');

/// The install as a non-interactive script for [pm]: it answers no
/// questions, waits for another install holding the package lock instead
/// of failing, and on apt refreshes the package lists once if a package is
/// not known (a fresh cloud image ships with none).
String installScript(PackageManager pm, List<String> packages) {
  if (packages.isEmpty) throw ArgumentError.value(packages, 'packages', 'empty');
  for (final p in packages) {
    if (!_packageName.hasMatch(p)) {
      throw ArgumentError.value(p, 'packages', 'not a package name');
    }
  }
  final names = packages.join(' ');
  return switch (pm) {
    PackageManager.apt => '''
export DEBIAN_FRONTEND=noninteractive
i() { apt-get -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install -y --no-install-recommends $names; }
i || { echo "Refreshing the package lists, then trying again."; apt-get -o DPkg::Lock::Timeout=600 update && i; }''',
    PackageManager.dnf =>
      'dnf install -y --setopt=install_weak_deps=False $names',
    PackageManager.yum => 'yum install -y $names',
    PackageManager.zypper =>
      'zypper --non-interactive install --no-recommends $names',
    PackageManager.pacman => 'pacman -S --needed --noconfirm $names',
    PackageManager.apk => 'apk add $names',
  };
}

/// The same install as a person would type it, for when the app cannot run
/// it for them: shown with a copy button.
String installCommandLine(PackageManager pm, List<String> packages) {
  final names = packages.join(' ');
  return switch (pm) {
    PackageManager.apt => 'sudo apt install $names',
    PackageManager.dnf => 'sudo dnf install $names',
    PackageManager.yum => 'sudo yum install $names',
    PackageManager.zypper => 'sudo zypper install $names',
    PackageManager.pacman => 'sudo pacman -S --needed $names',
    PackageManager.apk => 'sudo apk add $names',
  };
}

/// Something other than a package that needs root: fixed scripts from this
/// file only, never text from the server or the person.
enum SetupStep {
  /// Lets this account's programs run on after its last login ends, which
  /// a virtual desktop kept running needs (`loginctl enable-linger`). Under
  /// sudo it is the account that ran sudo, not root, that it is for.
  keepRunning(r'loginctl enable-linger "${SUDO_USER:-$(id -un)}"');

  const SetupStep(this.script);

  final String script;
}

/// How an install gets the root it needs.
enum Privilege {
  /// Signed in as root.
  root,

  /// `sudo` without a password.
  sudo,

  /// `sudo` that asks for this account's password.
  sudoPassword,

  /// No `sudo` this account may use: someone else has to install.
  none,
}

/// Finds out how this account can install software, in one exec.
Future<Privilege> probePrivilege(SessionTransport transport) async {
  final result = await AgentShell.run(
    transport,
    AgentShell.sh('''
if [ "\$(id -u)" = 0 ]; then echo SSG-ROOT; exit 0; fi
command -v sudo >/dev/null 2>&1 || { echo SSG-NO-SUDO; exit 0; }
if sudo -n true 2>/dev/null; then echo SSG-SUDO; else echo SSG-SUDO-PASSWORD; fi'''),
    what: 'check how software can be installed',
  );
  return parsePrivilege(result.stdout);
}

/// [probePrivilege]'s output. Public for its tests.
Privilege parsePrivilege(String output) {
  final lines = AgentShell.lines(output);
  if (lines.contains('SSG-ROOT')) return Privilege.root;
  if (lines.contains('SSG-SUDO')) return Privilege.sudo;
  if (lines.contains('SSG-SUDO-PASSWORD')) return Privilege.sudoPassword;
  return Privilege.none;
}

/// Why an install did not happen, worded for the person who pressed Install.
class SetupFailure implements Exception {
  const SetupFailure(this.kind, this.message, {this.output});

  final SetupFailureKind kind;
  final String message;

  /// The end of what the install printed, for the details.
  final String? output;

  @override
  String toString() => output == null ? message : '$message\n$output';
}

enum SetupFailureKind { wrongPassword, noSudo, failed }

/// A running install: its output as it comes, and how it ended.
class SetupRun {
  SetupRun({required this.lines, required this.done, void Function()? cancel})
      : _cancel = cancel; // ignore: prefer_initializing_formals

  /// Each line the install prints, stdout and stderr together.
  final Stream<String> lines;

  /// Completes when the install has ended, with a [SetupFailure] if it did
  /// not succeed.
  final Future<void> done;

  final void Function()? _cancel;

  /// Hangs up on the install. Package managers finish or roll back what
  /// they were doing on their own; this only stops waiting for them.
  void cancel() => _cancel?.call();
}

/// Starts installing [packages] with [pm], as [privilege] allows.
///
/// [password] is this account's own password, for [Privilege.sudoPassword]
/// only; it is written once to sudo's stdin.
Future<SetupRun> runInstall(
  SessionTransport transport, {
  required PackageManager pm,
  required List<String> packages,
  required Privilege privilege,
  String? password,
  List<SetupStep> steps = const [],
}) async {
  if (packages.isEmpty && steps.isEmpty) {
    throw ArgumentError('nothing to do');
  }
  final script = [
    if (packages.isNotEmpty) installScript(pm, packages),
    for (final step in steps) step.script,
  ].join('\n');
  final command = switch (privilege) {
    Privilege.root => 'sh -c ${posixSingleQuote(script)}',
    Privilege.sudo => 'sudo -n sh -c ${posixSingleQuote(script)}',
    // -S reads the password from stdin, -p '' keeps sudo's prompt out of
    // the output, and -k forgets any earlier sudo so a wrong password is
    // found out now rather than passing on a cached one.
    Privilege.sudoPassword =>
      "sudo -k -S -p '' sh -c ${posixSingleQuote(script)}",
    Privilege.none => throw const SetupFailure(
        SetupFailureKind.noSudo,
        'This account cannot install software on the server: it has no '
        'sudo. Someone with an administrator account needs to install it.',
      ),
  };
  if (privilege == Privilege.sudoPassword && (password == null || password.isEmpty)) {
    throw ArgumentError.value(password, 'password', 'needed for sudo');
  }

  final session = await transport.execute(command);
  // sudo that refuses this account outright exits without reading stdin, so
  // the write can meet a closed channel. That is not the failure to report:
  // sudo's own words, below, are.
  try {
    if (privilege == Privilege.sudoPassword) {
      session.stdin.add(utf8.encode('$password\n'));
    }
  } catch (_) {}
  // Nothing else will ever be typed; a package manager that asks anyway
  // reads end-of-file and gives up instead of hanging.
  unawaited(session.stdin.close().then<void>((_) {}, onError: (_) {}));

  final controller = StreamController<String>.broadcast();
  final tail = <String>[];
  var wrongPassword = false;
  void take(String chunk) {
    for (final line in const LineSplitter().convert(chunk)) {
      final text = line.trimRight();
      if (text.isEmpty) continue;
      if (text.contains('incorrect password') ||
          text.contains('Sorry, try again')) {
        wrongPassword = true;
      }
      tail.add(text);
      if (tail.length > 40) tail.removeAt(0);
      if (!controller.isClosed) controller.add(text);
    }
  }

  final out = utf8.decoder.bind(session.stdout).listen(take);
  final err = utf8.decoder.bind(session.stderr).listen(take);

  final done = () async {
    await session.done;
    await Future.wait([out.asFuture<void>(), err.asFuture<void>()])
        .timeout(const Duration(seconds: 2), onTimeout: () => const []);
    await controller.close();
    final code = session.exitCode;
    if (code == 0) return;
    final output = tail.join('\n');
    if (wrongPassword) {
      throw SetupFailure(
        SetupFailureKind.wrongPassword,
        'That password was not accepted. It is your own password on the '
        'server, the one sudo asks for.',
        output: output,
      );
    }
    if (output.contains('is not in the sudoers file') ||
        output.contains('not allowed to run sudo')) {
      throw SetupFailure(
        SetupFailureKind.noSudo,
        'This account is not allowed to use sudo on the server, so it cannot '
        'install software. Someone with an administrator account needs to '
        'install it.',
        output: output,
      );
    }
    throw SetupFailure(
      SetupFailureKind.failed,
      code == null
          ? 'The install stopped before it finished.'
          : 'The install failed (exit code $code).',
      output: output,
    );
  }();

  return SetupRun(lines: controller.stream, done: done, cancel: session.close);
}

/// Whether [program] can be run on the server: the first word of a command
/// as a person typed it.
Future<bool> programExists(SessionTransport transport, String program) async {
  final result = await AgentShell.run(
    transport,
    AgentShell.sh(r'command -v -- "$1" >/dev/null 2>&1 && echo SSG-YES || echo SSG-NO',
        [program]),
    what: 'check for the program',
  );
  return AgentShell.lines(result.stdout).contains('SSG-YES');
}

/// The package that provides [program], from the server's own
/// command-not-found (Debian and Ubuntu have it), or null when it does not
/// know or is not there.
Future<String?> packageForProgram(SessionTransport transport, String program) async {
  final result = await AgentShell.run(
    transport,
    AgentShell.sh(r'''
for c in /usr/lib/command-not-found /usr/share/command-not-found/command-not-found; do
  [ -x "$c" ] && { "$c" -- "$1" 2>&1; exit 0; }
done''', [program]),
    what: 'look up the package for the program',
  );
  return parseCommandNotFound(result.stdout + result.stderr);
}

/// The one package command-not-found's output names, or null when it names
/// none or several. Public for its tests.
String? parseCommandNotFound(String output) {
  final names = <String>{
    for (final m in RegExp(r'(?:apt|apt-get) install ([A-Za-z0-9][A-Za-z0-9.+_-]*)')
        .allMatches(output))
      m.group(1)!,
  };
  if (names.length != 1) return null;
  final name = names.single;
  return _packageName.hasMatch(name) ? name : null;
}

/// The program in a command as a person typed it, or as an installed app's
/// entry gives it (each word single-quoted): its first word, unquoted. Null
/// for one that starts with something other than a plain program name (a
/// variable, an assignment, a subshell): those are run as typed.
String? programOf(String command) {
  final text = command.trimLeft();
  if (text.isEmpty) return null;
  String word;
  if (text.startsWith("'")) {
    final end = text.indexOf("'", 1);
    if (end < 0) return null;
    word = text.substring(1, end);
  } else if (text.startsWith('"')) {
    final end = text.indexOf('"', 1);
    if (end < 0) return null;
    word = text.substring(1, end);
    if (RegExp(r'[$`\\]').hasMatch(word)) return null;
  } else {
    word = text.split(RegExp(r'\s+')).first;
  }
  if (word.isEmpty || word.contains('=')) return null;
  if (!RegExp(r'^[A-Za-z0-9_./+ -]+$').hasMatch(word)) return null;
  return word;
}
