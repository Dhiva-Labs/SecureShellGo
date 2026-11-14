import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/remote_desktop/agent_manifest.dart';
import 'package:secure_shell_go/services/remote_desktop/agent_probe.dart';
import 'package:secure_shell_go/services/remote_desktop/agent_shell.dart';
import 'package:secure_shell_go/services/remote_exec.dart';

import '../fake_exec_session.dart';

ExecResult _result(String stdout, {String stderr = '', int exitCode = 0}) =>
    ExecResult(stdout: stdout, stderr: stderr, exitCode: exitCode);

/// Builds a Linux probe transcript from its parts, the way the script
/// prints it.
String _linux({
  String uname = 'Linux x86_64',
  int uid = 1000,
  String home = '/home/dhiva',
  String xdg = '/run/user/1000',
  String sessions = '',
  String? linger = 'Linger=no',
  String userenv = '',
  String procs = '',
  String tools = 'Xvfb\nxauth\nsystemd-run\ndbus-run-session\nsetsid\nsha256sum',
  String pipewire = 'no',
  String glibc = 'glibc 2.39',
  String osrelease = 'ID=ubuntu\nID_LIKE=debian\nVERSION_ID="24.04"',
}) =>
    [
      'a chatty .profile banner',
      '#=ssg=uname', uname,
      '#=ssg=uid', '$uid',
      '#=ssg=home', home,
      '#=ssg=xdg', xdg,
      '#=ssg=sessions', sessions,
      if (linger != null) ...['#=ssg=linger', linger],
      '#=ssg=userenv', userenv,
      '#=ssg=procs', procs,
      '#=ssg=tools', tools,
      '#=ssg=pipewire', pipewire,
      '#=ssg=glibc', glibc,
      '#=ssg=osrelease', osrelease,
      '#=ssg=end',
    ].join('\n');

String _session(String id, Map<String, String> props) =>
    ['session $id', for (final e in props.entries) '${e.key}=${e.value}'].join('\n');

final _sshTty = _session('7', {
  'User': '1000',
  'Name': 'dhiva',
  'Type': 'tty',
  'Class': 'user',
  'Active': 'no',
  'State': 'online',
  'Remote': 'yes',
  'Display': '',
  'Desktop': '',
  'LockedHint': 'no',
  'Seat': '',
});

void main() {
  group('OS family', () {
    test('cmd.exe expands %OS% inside the quotes it does not understand', () {
      final guess = RemoteOsDetector.parse(
          _result("'Windows_NT' ; uname -sm\r\n"));
      expect(guess.family, RemoteOsFamily.windows);
    });

    test('PowerShell echoes %OS% and cannot find uname', () {
      final guess = RemoteOsDetector.parse(_result(
        '%OS%\r\n',
        stderr: "uname : The term 'uname' is not recognized as the name of a "
            'cmdlet, function, script file, or operable program.\r\n'
            '    + CategoryInfo          : ObjectNotFound: (uname:String) [], '
            'CommandNotFoundException',
        exitCode: 1,
      ));
      expect(guess.family, RemoteOsFamily.windows);
    });

    test('PowerShell with Git for Windows on the PATH runs MSYS uname', () {
      final guess = RemoteOsDetector.parse(
          _result('%OS%\r\nMINGW64_NT-10.0-26100 x86_64\r\n'));
      expect(guess.family, RemoteOsFamily.windows);
      expect(guess.machine, 'x86_64');
    });

    test('a unix shell prints %OS% and then uname', () {
      final linux = RemoteOsDetector.parse(_result('%OS%\nLinux aarch64\n'));
      expect(linux.family, RemoteOsFamily.linux);
      expect(linux.machine, 'aarch64');
      expect(RemoteOsDetector.parse(_result('%OS%\nDarwin arm64\n')).family,
          RemoteOsFamily.macos);
      expect(RemoteOsDetector.parse(_result('%OS%\nFreeBSD amd64\n')).family,
          RemoteOsFamily.other);
    });

    test('a banner before the answer does not confuse it', () {
      final guess = RemoteOsDetector.parse(
          _result('Welcome to the build farm\n%OS%\nLinux x86_64\n'));
      expect(guess.family, RemoteOsFamily.linux);
      expect(guess.machine, 'x86_64');
    });

    test('nothing recognisable is "other", with the evidence kept', () {
      final guess = RemoteOsDetector.parse(_result('', stderr: 'nope'));
      expect(guess.family, RemoteOsFamily.other);
      expect(guess.evidence, contains('nope'));
    });

    test('the detection command means nothing harmful to cmd or sh', () {
      // No redirections, pipes or ampersands: cmd.exe would act on them.
      expect(RemoteOsDetector.command, isNot(matches(RegExp(r'[<>|&]'))));
    });
  });

  group('Linux classification', () {
    test('Ubuntu GNOME on Wayland: the manager environment, gnomeWayland', () {
      final probe = LinuxProbe.parse(_linux(
        sessions: [
          _session('2', {
            'User': '1000',
            'Name': 'dhiva',
            'Type': 'wayland',
            'Class': 'user',
            'Active': 'yes',
            'State': 'active',
            'Remote': 'no',
            'Display': '',
            'Desktop': 'ubuntu',
            'LockedHint': 'no',
            'Seat': 'seat0',
          }),
          _sshTty,
        ].join('\n'),
        userenv: 'WAYLAND_DISPLAY=wayland-0\nDISPLAY=:0\n'
            'XAUTHORITY=/run/user/1000/.mutter-Xwaylandauth.ABC123\n'
            'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus\n'
            'XDG_SESSION_TYPE=wayland\nXDG_CURRENT_DESKTOP=ubuntu:GNOME',
        procs: 'own desk 2101 gnome-shell\n'
            'env DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus\n'
            'own desk 2350 Xwayland\n'
            'own child 2400 gsd-color\nenv WAYLAND_DISPLAY=wayland-0',
        pipewire: 'yes',
      ));
      expect(probe.uid, 1000);
      expect(probe.home, '/home/dhiva');
      expect(probe.arch, AgentArch.x86_64);
      expect(probe.hasLibPipewire, isTrue);
      expect(probe.glibcVersion, '2.39');
      expect(probe.sessions, hasLength(2));
      final desktop = probe.desktop as DesktopAvailable;
      expect(desktop.kind, DesktopKind.gnomeWayland);
      expect(desktop.sessionId, '2');
      expect(desktop.active, isTrue);
      expect(desktop.environment['WAYLAND_DISPLAY'], 'wayland-0');
      expect(desktop.environment['XAUTHORITY'],
          '/run/user/1000/.mutter-Xwaylandauth.ABC123');
      expect(desktop.environment['XDG_SESSION_TYPE'], 'wayland');
    });

    test('a headless server with only an SSH session', () {
      final probe = LinuxProbe.parse(_linux(
        home: '/home/ubuntu',
        sessions: _sshTty,
        linger: 'yes',
        userenv: 'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus',
      ));
      expect(probe.desktop, isA<Headless>());
      expect((probe.desktop as Headless).loginScreen, isFalse);
      expect(probe.lingering, isTrue);
      expect(probe.hasXvfb, isTrue);
      expect(probe.hasSystemdRun, isTrue);
      expect(probe.hasLibPipewire, isFalse);
      expect(probe.osRelease.id, 'ubuntu');
      expect(probe.osRelease.idLike, ['debian']);
    });

    test('only a login screen: headless, but says so', () {
      final probe = LinuxProbe.parse(_linux(
        sessions: [
          _session('c1', {
            'User': '120',
            'Name': 'gdm',
            'Type': 'wayland',
            'Class': 'greeter',
            'Active': 'yes',
            'State': 'active',
          }),
          _sshTty,
        ].join('\n'),
      ));
      expect((probe.desktop as Headless).loginScreen, isTrue);
    });

    test('someone else is logged in to the desktop', () {
      final probe = LinuxProbe.parse(_linux(
        sessions: [
          _session('3', {
            'User': '1001',
            'Name': 'alice',
            'Type': 'x11',
            'Class': 'user',
            'Active': 'yes',
            'State': 'active',
            'Display': ':0',
          }),
          _sshTty,
        ].join('\n'),
        procs: 'other desk 900 1001 xfce4-session\nother desk 800 0 Xorg',
      ));
      final desktop = probe.desktop as DesktopOfAnotherUser;
      expect(desktop.users, ['alice']);
    });

    test('KDE on Wayland is otherWayland: the portal, with consent', () {
      final probe = LinuxProbe.parse(_linux(
        sessions: _session('4', {
          'User': '1000',
          'Type': 'wayland',
          'Class': 'user',
          'Active': 'yes',
          'State': 'active',
          'Desktop': 'KDE',
          'Seat': 'seat0',
        }),
        userenv: 'WAYLAND_DISPLAY=wayland-0\nXDG_CURRENT_DESKTOP=KDE',
        procs: 'own desk 1500 kwin_wayland',
      ));
      expect((probe.desktop as DesktopAvailable).kind, DesktopKind.otherWayland);
    });

    test('Xfce on X11 without the display in the manager: a session process',
        () {
      final probe = LinuxProbe.parse(_linux(
        sessions: _session('5', {
          'User': '1000',
          'Type': 'x11',
          'Class': 'user',
          'Active': 'yes',
          'State': 'active',
          'Display': ':0',
          'Desktop': 'xfce',
          'Seat': 'seat0',
        }),
        userenv: 'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus',
        procs: 'own desk 1200 xfce4-session\n'
            'env DISPLAY=:0\nenv XAUTHORITY=/home/dhiva/.Xauthority\n'
            'env DBUS_SESSION_BUS_ADDRESS=unix:abstract=/tmp/dbus-XYZ',
      ));
      final desktop = probe.desktop as DesktopAvailable;
      expect(desktop.kind, DesktopKind.x11);
      expect(desktop.environment['DISPLAY'], ':0');
      expect(desktop.environment['XAUTHORITY'], '/home/dhiva/.Xauthority');
      // The process's own bus, not the manager's: one source, never a mix.
      expect(desktop.environment['DBUS_SESSION_BUS_ADDRESS'],
          'unix:abstract=/tmp/dbus-XYZ');
      expect(desktop.environment['XDG_SESSION_TYPE'], 'x11');
    });

    test('loginctl Display fills in DISPLAY for an X11 session', () {
      final probe = LinuxProbe.parse(_linux(
        sessions: _session('5', {
          'User': '1000',
          'Type': 'x11',
          'Class': 'user',
          'Active': 'yes',
          'State': 'active',
          'Display': ':1',
        }),
      ));
      expect((probe.desktop as DesktopAvailable).environment['DISPLAY'], ':1');
    });

    test('an active session wins over one switched away from', () {
      final probe = LinuxProbe.parse(_linux(
        sessions: [
          _session('8', {
            'User': '1000',
            'Type': 'x11',
            'Class': 'user',
            'Active': 'no',
            'State': 'online',
            'Display': ':1',
            'Seat': 'seat0',
          }),
          _session('9', {
            'User': '1000',
            'Type': 'wayland',
            'Class': 'user',
            'Active': 'yes',
            'State': 'active',
            'Desktop': 'GNOME',
            'LockedHint': 'yes',
            'Seat': 'seat0',
          }),
        ].join('\n'),
      ));
      final desktop = probe.desktop as DesktopAvailable;
      expect(desktop.sessionId, '9');
      expect(desktop.kind, DesktopKind.gnomeWayland);
      expect(desktop.locked, isTrue);
    });

    test('no loginctl: the processes decide', () {
      final probe = LinuxProbe.parse(_linux(
        linger: null,
        procs: 'own desk 300 openbox\nenv DISPLAY=:0',
      ));
      final desktop = probe.desktop as DesktopAvailable;
      expect(desktop.kind, DesktopKind.x11);
      expect(desktop.sessionId, isNull);
    });

    test('our own virtual desktop is never mistaken for a desktop', () {
      final probe = LinuxProbe.parse(_linux(
        linger: null,
        procs: 'own desk 300 openbox\nenv DISPLAY=:20\n'
            'env SSGO_VDESK=0123456789abcdef',
      ));
      expect(probe.desktop, isA<Headless>());
    });

    test('no loginctl, someone else\'s session program: another user', () {
      final probe = LinuxProbe.parse(_linux(
        linger: null,
        procs: 'other desk 800 0 Xorg\nother desk 900 1001 mate-session',
      ));
      expect((probe.desktop as DesktopOfAnotherUser).users, ['uid 1001']);
    });

    test('a root-owned Xorg alone is nobody\'s desktop in particular', () {
      final probe = LinuxProbe.parse(_linux(
        linger: null,
        procs: 'other desk 800 0 Xorg',
      ));
      expect(probe.desktop, isA<Headless>());
    });

    test('an empty transcript parses to nothing rather than throwing', () {
      final probe = LinuxProbe.parse('');
      expect(probe.uid, -1);
      expect(probe.desktop, isA<Headless>());
    });

    test('virtual sessions come from the tools that were found', () {
      final probe = LinuxProbe.parse(
          _linux(tools: 'Xvfb\nopenbox-session\nxfce4-session\nnot-a-tool'));
      expect(probe.virtualSessions,
          [VirtualSessionKind.xfce, VirtualSessionKind.openbox]);
      expect(probe.tools, isNot(contains('not-a-tool')));
    });

    test('glibc comparisons', () {
      final probe = LinuxProbe.parse(_linux(glibc: 'glibc 2.31'));
      expect(probe.glibcAtLeast('2.30'), isTrue);
      expect(probe.glibcAtLeast('2.31'), isTrue);
      expect(probe.glibcAtLeast('2.32'), isFalse);
      expect(probe.glibcAtLeast(null), isTrue);
      expect(LinuxProbe.parse(_linux(glibc: '')).glibcAtLeast('2.17'), isFalse);
    });
  });

  group('systemctl --user show-environment', () {
    test("plain values and systemd's \$'…' quoting", () {
      final env = parseSystemdEnvironment(
          "DISPLAY=:0\nXAUTHORITY=\$'/home/a b/.Xauthority'\n"
          "XDG_CURRENT_DESKTOP=ubuntu:GNOME\nODD=\$'tab\\there'");
      expect(env['DISPLAY'], ':0');
      expect(env['XAUTHORITY'], '/home/a b/.Xauthority');
      expect(env['ODD'], 'tab\there');
    });
  });

  group('os-release', () {
    test('quoted values and a list of families', () {
      final os = OsRelease.parse(
          'NAME="Pop!_OS"\nID=pop\nID_LIKE="ubuntu debian"\nVERSION_ID="22.04"');
      expect(os.families, ['pop', 'ubuntu', 'debian']);
      expect(os.versionId, '22.04');
    });
  });

  group('Windows', () {
    String transcript({
      String arch = 'X64',
      String quser = ' USERNAME              SESSIONNAME        ID  STATE   IDLE TIME  LOGON TIME\r\n'
          ' dhiva                 console             1  Active      none   10/27/2026 9:00 AM',
      String explorer = '',
    }) =>
        '\uFEFF#=ssg=arch\r\n$arch\r\nAMD64\r\n#=ssg=env\r\nUSERNAME=dhiva\r\n'
        'USERDOMAIN=LAPTOP\r\nLOCALAPPDATA=C:\\Users\\dhiva\\AppData\\Local\r\n'
        'OSVERSION=10.0.26100.0\r\n#=ssg=quser\r\n$quser\r\n'
        '${explorer.isEmpty ? '' : '#=ssg=explorer\r\n$explorer\r\n'}#=ssg=end\r\n';

    test('the console session of this user is a desktop', () {
      final probe = WindowsProbe.parse(transcript());
      expect(probe.arch, AgentArch.x86_64);
      expect(probe.user, 'dhiva');
      expect(probe.localAppData, r'C:\Users\dhiva\AppData\Local');
      final desktop = probe.desktop as DesktopAvailable;
      expect(desktop.kind, DesktopKind.windows);
      expect(desktop.sessionId, '1');
      expect(desktop.active, isTrue);
    });

    test('Arm64 from .NET wins over an emulated process\'s AMD64', () {
      expect(WindowsProbe.parse(transcript(arch: 'Arm64')).arch, AgentArch.aarch64);
    });

    test('a 32-bit machine is not supported, and says what it is', () {
      final probe = WindowsProbe.parse(transcript(arch: 'X86').replaceAll('AMD64', 'x86'));
      expect(probe.arch, isNull);
      expect(probe.architecture, 'X86');
    });

    test('quser in German, with the > marker', () {
      final probe = WindowsProbe.parse(transcript(
          quser: ' BENUTZERNAME          SITZUNGSNAME       ID  STATUS  LEERLAUF   ANMELDEZEIT\r\n'
              '>dhiva                 console             1  Aktiv       Kein   27.10.2026 09:00'));
      expect((probe.desktop as DesktopAvailable).active, isTrue);
    });

    test('our session disconnected, someone else at the console', () {
      final sessions = parseQueryUser(
          ' USERNAME              SESSIONNAME        ID  STATE   IDLE TIME  LOGON TIME\n'
          ' dhiva                                     2  Disc         1:05  10/27/2026 9:00 AM\n'
          ' bob                   console             1  Active      none   10/27/2026 8:00 AM');
      expect(sessions, hasLength(2));
      expect(sessions[0].user, 'dhiva');
      expect(sessions[0].id, 2);
      expect(sessions[0].sessionName, '');
      expect(sessions[0].active, isFalse);
      expect(sessions[1].sessionName, 'console');
      expect(sessions[1].active, isTrue);

      final probe = WindowsProbe.parse(transcript(
          quser: ' dhiva                                     2  Disc         1:05  10/27/2026 9:00 AM\r\n'
              ' bob                   console             1  Active      none   10/27/2026 8:00 AM'));
      final desktop = probe.desktop as DesktopAvailable;
      expect(desktop.active, isFalse);
      expect(desktop.sessionId, '2');
    });

    test('only someone else is logged on', () {
      final probe = WindowsProbe.parse(transcript(
          quser: ' bob                   console             1  Active      none   10/27/2026 8:00 AM'));
      expect((probe.desktop as DesktopOfAnotherUser).users, ['bob']);
    });

    test('nobody is logged on: quser complains on stderr', () {
      final probe = WindowsProbe.parse(transcript(quser: 'No User exists for *'));
      expect(probe.desktop, isA<Headless>());
    });

    test('quser cuts names at 20 characters', () {
      final probe = WindowsProbe.parse(transcript(
              quser: ' averyveryverylongnam  console             1  Active      none   10/27/2026 9:00 AM')
          .replaceAll('USERNAME=dhiva', 'USERNAME=averyveryverylongname'));
      expect(probe.desktop, isA<DesktopAvailable>());
    });

    test('Home edition without quser: explorer.exe owned by this user', () {
      final probe = WindowsProbe.parse(
          transcript(quser: 'SSG-NO-QUSER', explorer: '1'));
      expect(probe.queryUserAvailable, isFalse);
      expect((probe.desktop as DesktopAvailable).sessionId, '1');
      expect(
          WindowsProbe.parse(transcript(quser: 'SSG-NO-QUSER')).desktop,
          isA<Headless>());
    });

    test('the probe fits a cmd.exe command line', () {
      expect(WindowsProbe.command.length,
          lessThan(AgentShell.maxWindowsCommandLength));
      expect(WindowsProbe.command, startsWith('powershell '));
      expect(WindowsProbe.command, isNot(matches(RegExp(r'[<>|&"%^]'))));
    });
  });

  group('the probe script', () {
    test('parses in sh and BusyBox sh', () async {
      for (final shell in [
        ['sh'],
        if (File('/usr/bin/busybox').existsSync()) ['busybox', 'sh'],
      ]) {
        final result = await Process.run(
            shell.first, [...shell.skip(1), '-n', '-c', LinuxProbe.script]);
        expect(result.exitCode, 0, reason: '${shell.join(' ')}: ${result.stderr}');
      }
    });

    test('asks for every tool it parses', () {
      for (final tool in LinuxProbe.probedTools) {
        expect(LinuxProbe.script, contains(tool));
      }
    });

    test('RemoteDesktopProbe.run: detect, then the family\'s probe', () async {
      final transport = FakeExecTransport(respond: (command) {
        if (command == RemoteOsDetector.command) {
          return FakeExecSession(stdout: '%OS%\nLinux x86_64\n');
        }
        return FakeExecSession(stdout: _linux(sessions: _sshTty));
      });
      final probe = await RemoteDesktopProbe.run(transport);
      expect(transport.commands, [RemoteOsDetector.command, LinuxProbe.command]);
      expect(probe.os, AgentOs.linux);
      expect(probe.isSupported, isTrue);
      expect(probe.desktop, isA<Headless>());
    });

    test('a Mac gets no probe at all', () async {
      final transport =
          FakeExecTransport(stdout: '%OS%\nDarwin arm64\n');
      final probe = await RemoteDesktopProbe.run(transport);
      expect(transport.commands, hasLength(1));
      expect(probe.family, RemoteOsFamily.macos);
      expect(probe.isSupported, isFalse);
    });
  });
}
