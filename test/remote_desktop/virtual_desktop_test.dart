import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/remote_desktop/agent_deployer.dart';
import 'package:secure_shell_go/services/remote_desktop/agent_failure.dart';
import 'package:secure_shell_go/services/remote_desktop/agent_probe.dart';
import 'package:secure_shell_go/services/remote_desktop/agent_shell.dart';
import 'package:secure_shell_go/services/remote_desktop/virtual_desktop.dart';
import 'package:secure_shell_go/services/x11_forwarding.dart';

import '../fake_exec_session.dart';
import 'agent_test_support.dart';

const _id = '0123456789abcdef';

DeployedAgent _agent(String path) {
  final bytes = File(path).existsSync() ? File(path).readAsBytesSync() : bytesOf('x');
  return DeployedAgent(
    binary: binaryFor(bytes),
    directory: File(path).parent.path,
    path: path,
    uploaded: false,
  );
}

OsRelease _os(String id, [String like = '', String version = '']) =>
    OsRelease(id: id, idLike: like.split(' ').where((s) => s.isNotEmpty).toList(), versionId: version);

void main() {
  group('Xvfb install hints', () {
    test('per distribution, derivatives by ID_LIKE', () {
      String? cmd(OsRelease os) => xvfbInstallHint(os)?.command;
      expect(cmd(_os('ubuntu', 'debian')), 'sudo apt install xvfb');
      expect(cmd(_os('pop', 'ubuntu debian')), 'sudo apt install xvfb');
      expect(cmd(_os('kali', 'debian')), 'sudo apt install xvfb');
      expect(cmd(_os('fedora')), 'sudo dnf install xorg-x11-server-Xvfb');
      expect(cmd(_os('rocky', 'rhel centos fedora')), 'sudo dnf install xorg-x11-server-Xvfb');
      expect(cmd(_os('centos', 'rhel fedora', '7')), 'sudo yum install xorg-x11-server-Xvfb');
      expect(cmd(_os('opensuse-tumbleweed', 'opensuse suse')),
          'sudo zypper install xorg-x11-server-Xvfb');
      expect(cmd(_os('arch')), 'sudo pacman -S --needed xorg-server-xvfb');
      expect(cmd(_os('endeavouros', 'arch')), 'sudo pacman -S --needed xorg-server-xvfb');
      expect(cmd(_os('alpine')), 'sudo apk add xvfb');
      expect(xvfbInstallHint(_os('nixos')), isNull);
      expect(xvfbInstallHint(const OsRelease()), isNull);
    });

    test('support summary from a probe', () {
      final support = VirtualDesktopSupport.of(LinuxProbe(
        system: 'Linux',
        machine: 'x86_64',
        uid: 1000,
        home: '/home/me',
        tools: const {'systemd-run', 'openbox-session'},
        osRelease: _os('debian'),
      ));
      expect(support.hasXvfb, isFalse);
      expect(support.xvfbInstall!.packageManager, 'apt');
      expect(support.sessions, [VirtualSessionKind.openbox]);
      expect(support.keepRunningNeedsLinger, isTrue);
    });
  });

  group('.desktop files', () {
    const output = '''
/home/u/.local/share/applications/firefox.desktop:[Desktop Entry]
/home/u/.local/share/applications/firefox.desktop:Hidden=true
/usr/share/applications/firefox.desktop:[Desktop Entry]
/usr/share/applications/firefox.desktop:Name=Firefox
/usr/share/applications/firefox.desktop:Exec=firefox %u
/usr/share/applications/firefox.desktop:Type=Application
/usr/share/applications/org.gnome.gedit.desktop:[Desktop Entry]
/usr/share/applications/org.gnome.gedit.desktop:Name=Text Editor
/usr/share/applications/org.gnome.gedit.desktop:Exec=gedit %U
/usr/share/applications/org.gnome.gedit.desktop:Type=Application
/usr/share/applications/org.gnome.gedit.desktop:[Desktop Action new-window]
/usr/share/applications/org.gnome.gedit.desktop:Name=New Window
/usr/share/applications/org.gnome.gedit.desktop:Exec=gedit --new-window
/usr/share/applications/htop.desktop:[Desktop Entry]
/usr/share/applications/htop.desktop:Type=Application
/usr/share/applications/htop.desktop:Name=Htop
/usr/share/applications/htop.desktop:Exec=htop
/usr/share/applications/htop.desktop:Terminal=true
/usr/share/applications/nm-applet.desktop:[Desktop Entry]
/usr/share/applications/nm-applet.desktop:Name=Network
/usr/share/applications/nm-applet.desktop:Exec=nm-applet
/usr/share/applications/nm-applet.desktop:NoDisplay=true
/usr/share/applications/nm-applet.desktop:Type=Application
/usr/share/applications/site.desktop:[Desktop Entry]
/usr/share/applications/site.desktop:Type=Link
/usr/share/applications/site.desktop:Name=A link
/usr/share/applications/quoted.desktop:[Desktop Entry]
/usr/share/applications/quoted.desktop:Name=Quoted\\sApp
/usr/share/applications/quoted.desktop:Exec="/opt/My App/bin/app" --title="It's \\\\"here\\\\"" --cost=100%% %i
/usr/share/applications/quoted.desktop:Type=Application
/usr/share/applications/broken.desktop:[Desktop Entry]
/usr/share/applications/broken.desktop:Name=Broken
/usr/share/applications/broken.desktop:Exec="unterminated
/usr/share/applications/broken.desktop:Type=Application
/var/lib/snapd/desktop/applications/code_code.desktop:[Desktop Entry]
/var/lib/snapd/desktop/applications/code_code.desktop:Name=Visual Studio Code
/var/lib/snapd/desktop/applications/code_code.desktop:Exec=env BAMF_DESKTOP_FILE_HINT=/var/lib/snapd/desktop/applications/code_code.desktop /snap/bin/code --force-user-env %F
/var/lib/snapd/desktop/applications/code_code.desktop:Type=Application
''';

    test('what is offered, and what is not', () {
      final apps = parseDesktopEntries(output);
      expect(apps.map((a) => a.name),
          ['Quoted App', 'Text Editor', 'Visual Studio Code']);
      final gedit = apps.firstWhere((a) => a.id == 'org.gnome.gedit.desktop');
      // The action group's Exec did not leak into the entry.
      expect(gedit.argv, ['gedit']);
      expect(gedit.path, '/usr/share/applications/org.gnome.gedit.desktop');
    });

    test('a user copy with Hidden=true removes the system one', () {
      expect(parseDesktopEntries(output).map((a) => a.id), isNot(contains('firefox.desktop')));
    });

    test('terminal apps only when asked for', () {
      expect(parseDesktopEntries(output, includeTerminal: true).map((a) => a.id),
          contains('htop.desktop'));
    });

    test('both layers of escaping, and field codes', () {
      final quoted = parseDesktopEntries(output).firstWhere((a) => a.id == 'quoted.desktop');
      expect(quoted.argv, ['/opt/My App/bin/app', '--title=It\'s "here"', '--cost=100%']);
      expect(quoted.command,
          "'/opt/My App/bin/app' '--title=It'\\''s \"here\"' '--cost=100%'");
    });

    test('Exec parsing on its own', () {
      expect(parseDesktopExec('firefox %u'), ['firefox']);
      expect(parseDesktopExec('vlc --started-from-file %U'), ['vlc', '--started-from-file']);
      expect(parseDesktopExec('app --file=%f'), ['app', '--file=']);
      expect(parseDesktopExec(r'sh -c "echo \$HOME"'), ['sh', '-c', r'echo $HOME']);
      expect(parseDesktopExec('a  "b c"  ""'), ['a', 'b c', '']);
      expect(parseDesktopExec('"open'), isNull);
    });

    test('the listing command parses, and reads only what is needed', () async {
      final check = listDesktopAppsCommand.replaceFirst('sh -c ', 'sh -n -c ');
      expect((await Process.run('sh', ['-c', check])).exitCode, 0);
      expect(listDesktopAppsCommand, contains('grep -H -E'));
    });

    test('listDesktopApps over a transport', () async {
      final apps = await listDesktopApps(FakeExecTransport(stdout: output));
      expect(apps, hasLength(3));
    });
  });

  group('records', () {
    final agent = _agent('/home/me/.cache/secureshellgo/agent/x/crossshell-host');
    const rt = '/run/user/1000/ssgo-vd-$_id';
    final created = DateTime.utc(2026, 10, 27, 1, 2, 3);

    String record(String display, {VirtualDesktopContent? content}) {
      final (head, tail) = VirtualDesktops.recordParts(
        id: _id,
        runtimeDir: rt,
        spec: VirtualDesktopSpec(
          width: 1280,
          height: 720,
          content: content ?? const VirtualAppContent('xterm -e "top"', label: 'Top'),
          keepRunning: true,
        ),
        agent: agent,
        createdAt: created,
      );
      return '$head$display$tail';
    }

    test('round trip, with the display spliced in', () {
      final r = VirtualDesktopRecord.tryParse(record(':23'))!;
      expect(r.id, _id);
      expect(r.unit, 'ssgo-vd-$_id');
      expect(r.display, ':23');
      expect(r.width, 1280);
      expect(r.content, 'app');
      expect(r.command, 'xterm -e "top"');
      expect(r.label, 'Top');
      expect(r.runtimeDir, rt);
      expect(r.createdAt, created);
      expect(r.agentSha256, agent.binary.sha256);
    });

    test('a session record, and one written before Xvfb was up', () {
      final r = VirtualDesktopRecord.tryParse(
          record('', content: const VirtualSessionContent(VirtualSessionKind.xfce)))!;
      expect(r.display, '');
      expect(r.command, 'xfce4-session');
      expect(r.label, 'Xfce');
    });

    test('anything else is not a record', () {
      expect(VirtualDesktopRecord.tryParse('{'), isNull);
      expect(VirtualDesktopRecord.tryParse(record(':1'), expectId: 'ffffffffffffffff'), isNull);
      expect(VirtualDesktopRecord.tryParse(record(':1').replaceFirst(rt, '/tmp')), isNull);
      expect(
          VirtualDesktopRecord.tryParse(
              record(':1').replaceFirst('"ssgo-vd-$_id"', '"other.service"')),
          isNull);
      // A display that is not one is dropped, not trusted.
      expect(VirtualDesktopRecord.tryParse(record(':1; rm -rf ~'))!.display, '');
    });

    test('the list output: alive, dead and junk', () {
      final parsed = VirtualDesktops.parseList([
        '#=ssg=rec $_id unit',
        record(':23'),
        '',
        '#=ssg=rec ffffffffffffffff dead',
        record(':24').replaceAll(_id, 'ffffffffffffffff'),
        '#=ssg=rec aaaaaaaaaaaaaaaa pid',
        'not json',
        '#=ssg=end',
      ].join('\n'));
      expect(parsed.records.map((r) => (r.$1.id, r.$2)), [
        (_id, true),
        ('ffffffffffffffff', false),
      ]);
      expect(parsed.invalid, ['aaaaaaaaaaaaaaaa']);
    });

    test('list() prunes the dead and returns the living, newest first',
        () async {
      final older = record(':23').replaceFirst('2026-10-27T01:02:03', '2026-10-26T01:02:03');
      final newer = record(':25')
          .replaceAll(_id, 'bbbbbbbbbbbbbbbb');
      final transport = FakeExecTransport(respond: (command) {
        if (command == VirtualDesktops.listCommand) {
          return FakeExecSession(stdout: [
            '#=ssg=rec $_id unit',
            older,
            '#=ssg=rec bbbbbbbbbbbbbbbb pid',
            newer,
            '#=ssg=rec ffffffffffffffff dead',
            record(':24').replaceAll(_id, 'ffffffffffffffff'),
            '#=ssg=end',
          ].join('\n'));
        }
        return FakeExecSession(stdout: 'SSG-PRUNED\n');
      });
      final living = await listVirtualDesktops(transport);
      expect(living.map((r) => r.id), ['bbbbbbbbbbbbbbbb', _id]);
      expect(transport.commands.last, VirtualDesktops.pruneCommand(['ffffffffffffffff']));
    });

    test('nothing dead, nothing pruned', () async {
      final transport = FakeExecTransport(stdout: '#=ssg=end\n');
      expect(await listVirtualDesktops(transport), isEmpty);
      expect(transport.commands, [VirtualDesktops.listCommand]);
    });

    test('attach to a desktop that has gone', () async {
      final r = VirtualDesktopRecord.tryParse(record(':23'))!;
      await expectLater(
        const VirtualDesktops().attach(FakeExecTransport(stdout: 'SSG-GONE\n'), r),
        throwsA(isA<AgentFailure>().having((f) => f.kind, 'kind', AgentFailureKind.notFound)),
      );
    });

    test('ids are hex or nothing happens', () {
      expect(() => VirtualDesktops.stopCommand('x; reboot'), throwsArgumentError);
      expect(() => VirtualDesktops.pruneCommand(['../..']), throwsArgumentError);
    });
  });

  group('the X cookie', () {
    test('a FamilyWild MIT-MAGIC-COOKIE-1 for every display, mode 0600', () async {
      final dir = Directory.systemTemp.createTempSync('ssgo-cookie-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final line = VirtualDesktops.supervisorScript
          .split('\n')
          .firstWhere((l) => l.contains('MIT-MAGIC-COOKIE-1'));
      final result = await Process.run(
          'sh', ['-c', 'rt=\$1; umask 077; $line; echo done', 'sh', dir.path]);
      expect(result.stdout, 'done\n', reason: '${result.stderr}');
      final file = File('${dir.path}/xauth');
      expect(FileStat.statSync(file.path).mode & 0x1ff, 0x180); // 0600
      final entries = parseXauthority(file.readAsBytesSync());
      expect(entries, hasLength(1));
      expect(entries.single.family, XauthEntry.familyWild);
      expect(entries.single.address, isEmpty);
      expect(entries.single.number, '', reason: 'empty matches every display');
      expect(entries.single.name, 'MIT-MAGIC-COOKIE-1');
      expect(entries.single.data, hasLength(16));
      expect(entries.single.data.every((b) => b == 0), isFalse);
      // And it is the cookie Xlib would pick for any display number.
      expect(
          pickXauthCookie(entries, X11Display.parse(':57')!, localHostname: 'h'),
          isNotNull);
    });
  });

  group('the supervisor, through a real sh with fakes', () {
    late Directory dir;
    late String rt;
    late String fakeBin;
    late LocalShellTransport shell;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('ssgo-vdesk-');
      // Where production puts it when there is no XDG_RUNTIME_DIR, so the
      // stop script's own search finds the supervisor.
      rt = '${dir.path}/.cache/secureshellgo/rt/ssgo-vd-$_id';
      fakeBin = '${dir.path}/bin';
      Directory(fakeBin).createSync();
      // A fake Xvfb: loses the race for the first display it is given, as if
      // another server took it after the free-display check; then behaves.
      File('$fakeBin/Xvfb').writeAsStringSync('''#!/bin/sh
c="\$FAKE_DIR/xvfb-count"; k=\$(cat "\$c" 2>/dev/null || echo 0); echo \$((k + 1)) > "\$c"
if [ "\$k" = 0 ]; then echo "(EE) Server is already active for display \${1#:}" >&2; exit 1; fi
echo "\$@" > "\$FAKE_DIR/xvfb-args"
echo "\${1#:}" >&3
while :; do sleep 1; done
''');
      File('${dir.path}/crossshell-host').writeAsStringSync(fakeAgentScript());
      Process.runSync('chmod', ['755', '$fakeBin/Xvfb', '${dir.path}/crossshell-host']);
      shell = LocalShellTransport(environment: {
        ...Platform.environment,
        'PATH': '$fakeBin:${Platform.environment['PATH']}',
        'FAKE_DIR': dir.path,
        'HOME': dir.path,
        // Never this machine's own runtime directory.
        'XDG_RUNTIME_DIR': '${dir.path}/xdg',
      });
    });
    tearDown(() async {
      await shell.execute(VirtualDesktops.stopCommand(_id));
      dir.deleteSync(recursive: true);
    });

    int firstFreeDisplay() {
      var n = 20;
      while (File('/tmp/.X11-unix/X$n').existsSync() || File('/tmp/.X$n-lock').existsSync()) {
        n++;
      }
      return n;
    }

    test('retries the display it lost, records it, and stop takes it all down',
        () async {
      final expected = firstFreeDisplay() + 1;
      final command = VirtualDesktops.launchCommand(
        agent: _agent('${dir.path}/crossshell-host'),
        id: _id,
        runtimeDir: rt,
        spec: const VirtualDesktopSpec(
          width: 800,
          height: 600,
          content: VirtualAppContent("echo \"it's\" > \"\$HOME/app-ran\""),
          keepRunning: true,
        ),
        createdAt: DateTime.utc(2026),
        useSystemd: false,
        timeout: const Duration(seconds: 5),
      );
      final session = await shell.execute(command) as FakeExecSession;
      final out = session.stdoutChunks.join();
      expect(out, contains('SSG-MODE pid'));
      expect(out, contains('SSG-DISPLAY :$expected'));
      expect(out, contains('SSG-READY'));
      expect(File('${dir.path}/xvfb-args').readAsStringSync(),
          contains(':$expected -screen 0 800x600x24 -nolisten tcp -auth $rt/xauth -displayfd 3'));
      // The app ran inside, with the virtual display and nothing of ours.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(File('${dir.path}/app-ran').readAsStringSync(), "it's\n");
      final listed = VirtualDesktops.parseList(
          (await shell.execute(VirtualDesktops.listCommand) as FakeExecSession)
              .stdoutChunks
              .join());
      expect(listed.records.single.$2, isTrue, reason: 'the supervisor is alive');
      expect(listed.records.single.$1.display, ':$expected');

      await shell.execute(VirtualDesktops.stopCommand(_id));
      expect(Directory(rt).existsSync(), isFalse);
      expect(File('${dir.path}/.cache/secureshellgo/vdesk/$_id.json').existsSync(), isFalse);
      final left = Process.runSync('pgrep', ['-f', 'ssgo-vd-$_id']);
      expect(left.stdout, '');
    });

    test('a desktop that is not kept writes no record and idles out by the '
        'agent', () async {
      final command = VirtualDesktops.launchCommand(
        agent: _agent('${dir.path}/crossshell-host'),
        id: _id,
        runtimeDir: rt,
        spec: const VirtualDesktopSpec(
            width: 640, height: 480, content: VirtualSessionContent(VirtualSessionKind.openbox)),
        createdAt: DateTime.utc(2026),
        useSystemd: false,
        timeout: const Duration(seconds: 5),
      );
      final out = (await shell.execute(command) as FakeExecSession).stdoutChunks.join();
      expect(out, contains('SSG-READY'));
      expect(Directory('${dir.path}/.cache/secureshellgo/vdesk').listSync(), isEmpty);
      final pid = int.parse(RegExp(r'SSG-MODE pid (\d+)').firstMatch(out)!.group(1)!);
      final args = File('/proc/$pid/cmdline').readAsStringSync().split('\x00');
      expect(args, containsAllInOrder(['session', 'openbox-session', '30']));

      await shell.execute(VirtualDesktops.stopCommand(_id));
      expect(Process.runSync('pgrep', ['-f', 'ssgo-vd-$_id']).stdout, '');
      expect(Directory(rt).existsSync(), isFalse);
    });

    test('a missing Xvfb is reported before anything starts', () async {
      File('$fakeBin/Xvfb').deleteSync();
      final noXvfb = LocalShellTransport(environment: {
        'PATH': '$fakeBin:/usr/bin:/bin',
        'HOME': dir.path,
      });
      // Only if this machine has no Xvfb of its own.
      if (File('/usr/bin/Xvfb').existsSync()) return;
      final command = VirtualDesktops.launchCommand(
        agent: _agent('${dir.path}/crossshell-host'),
        id: _id,
        runtimeDir: rt,
        spec: const VirtualDesktopSpec(
            width: 640, height: 480, content: VirtualAppContent('true')),
        createdAt: DateTime.utc(2026),
        useSystemd: false,
      );
      final out = (await noXvfb.execute(command) as FakeExecSession).stdoutChunks.join();
      expect(out, contains('SSG-NO-XVFB'));
      expect(Directory(rt).existsSync(), isFalse);
    });

    test('start() turns that into an install hint', () async {
      final probe = LinuxProbe(
        system: 'Linux',
        machine: 'x86_64',
        uid: 1000,
        home: dir.path,
        osRelease: _os('fedora'),
      );
      await expectLater(
        const VirtualDesktops().start(FakeExecTransport(), probe,
            _agent('${dir.path}/crossshell-host'),
            const VirtualDesktopSpec(width: 1, height: 1, content: VirtualAppContent('x'))),
        throwsA(isA<AgentFailure>()
            .having((f) => f.kind, 'kind', AgentFailureKind.missingTool)
            .having((f) => f.installCommand, 'install',
                'sudo dnf install xorg-x11-server-Xvfb')),
      );
    });

    test('every script parses in sh and BusyBox sh', () async {
      final agent = _agent('${dir.path}/crossshell-host');
      final scripts = [
        VirtualDesktops.launchCommand(
          agent: agent,
          id: _id,
          runtimeDir: rt,
          spec: const VirtualDesktopSpec(
              width: 640, height: 480, content: VirtualAppContent('x'), keepRunning: true),
          createdAt: DateTime.utc(2026),
        ),
        VirtualDesktops.listCommand,
        VirtualDesktops.pruneCommand([_id]),
        VirtualDesktops.stopCommand(_id),
      ];
      for (final shellName in [
        'sh',
        if (File('/usr/bin/busybox').existsSync()) 'busybox sh',
      ]) {
        for (final command in scripts) {
          final check = command.replaceFirst('sh -c ', '$shellName -n -c ');
          final result = await Process.run('sh', ['-c', check]);
          expect(result.exitCode, 0, reason: '$shellName: ${result.stderr}');
        }
        final supervisor = await Process.run(
            shellName.split(' ').first,
            [...shellName.split(' ').skip(1), '-n', '-c', VirtualDesktops.supervisorScript]);
        expect(supervisor.exitCode, 0, reason: '$shellName: ${supervisor.stderr}');
      }
    });
  });

  group('fish-safe scripts', () {
    // Inside single quotes fish still reads `\\` and `\'`; everything else
    // is literal there as it is in sh. posixSingleQuote's own `'\''` puts
    // its backslash outside the quotes, so once those are taken out, no
    // backslash may stand before another backslash or a quote.
    final agent = _agent('/home/me/a');
    final commands = <String, String>{
      'probe': LinuxProbe.command,
      'apps': listDesktopAppsCommand,
      'vdesk launch': VirtualDesktops.launchCommand(
        agent: agent,
        id: _id,
        runtimeDir: '/run/user/1/ssgo-vd-$_id',
        spec: const VirtualDesktopSpec(
            width: 1, height: 1, content: VirtualAppContent(r"it's a \\ 'test'"), keepRunning: true),
        createdAt: DateTime.utc(2026),
      ),
      'vdesk list': VirtualDesktops.listCommand,
      'vdesk stop': VirtualDesktops.stopCommand(_id),
      'hash': AgentShell.sh(AgentShell.shHashFunction),
    };
    for (final entry in commands.entries) {
      test(entry.key, () {
        // The script itself — before the first argument — must be clean;
        // arguments are quoted once each and are fine by construction.
        final script = entry.value.split(" ssgo '").first.replaceAll(r"'\''", '');
        expect(script, isNot(contains(r'\\')), reason: entry.key);
        expect(script, isNot(contains(r"\'")), reason: entry.key);
      });
    }
  });
}
