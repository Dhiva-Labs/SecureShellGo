import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/remote_desktop/agent_deployer.dart';
import 'package:secure_shell_go/services/remote_desktop/agent_endpoint.dart';
import 'package:secure_shell_go/services/remote_desktop/agent_failure.dart';
import 'package:secure_shell_go/services/remote_desktop/agent_launcher.dart';
import 'package:secure_shell_go/services/remote_desktop/agent_manifest.dart';
import 'package:secure_shell_go/services/remote_desktop/agent_probe.dart';
import 'package:secure_shell_go/services/remote_desktop/agent_shell.dart';
import 'package:secure_shell_go/services/tunnel_carrier.dart';

import '../fake_exec_session.dart';
import 'agent_test_support.dart';

const _token = 'ab';
final _hostJson =
    '{"v":1,"port":47999,"token":"${_token * 32}","pid":4242,"ver":"0.2.0"}';

DeployedAgent _agent(String path, List<int> bytes,
        {AgentFlavour flavour = AgentFlavour.x11, AgentOs os = AgentOs.linux}) =>
    DeployedAgent(
      binary: binaryFor(bytesOf(utf8.decode(bytes)), flavour: flavour, os: os),
      directory: File(path).parent.path,
      path: path,
      uploaded: false,
    );

Matcher _fails(AgentFailureKind kind) =>
    throwsA(isA<AgentFailure>().having((f) => f.kind, 'kind', kind));

String _decodePowershell(String command) {
  final bytes = base64.decode(command.substring(command.indexOf('-EncodedCommand ') + 16));
  return String.fromCharCodes(
      [for (var i = 0; i < bytes.length; i += 2) bytes[i] | (bytes[i + 1] << 8)]);
}

void main() {
  group('the Linux environment', () {
    final full = _agent('/a', utf8.encode('x'), flavour: AgentFlavour.full);
    final x11 = _agent('/a', utf8.encode('x'));

    test('the display variables are always set, empty when there are none', () {
      final env = AgentLauncher.linuxEnvironment(full, const {'DISPLAY': ':0'},
          const AgentLaunchOptions());
      expect(env['DISPLAY'], ':0');
      expect(env['WAYLAND_DISPLAY'], '');
      expect(env['XDG_SESSION_TYPE'], '');
    });

    test('XAUTHORITY and the bus only when known: an empty one is a path', () {
      final env = AgentLauncher.linuxEnvironment(
          full, const {'XAUTHORITY': '', 'DBUS_SESSION_BUS_ADDRESS': ''},
          const AgentLaunchOptions());
      expect(env.containsKey('XAUTHORITY'), isFalse);
      expect(env.containsKey('DBUS_SESSION_BUS_ADDRESS'), isFalse);
    });

    test('the backend: chosen by the agent, forced for the x11 build', () {
      expect(
          AgentLauncher.linuxEnvironment(full, const {}, const AgentLaunchOptions())
              .containsKey('CROSSSHELL_LINUX_BACKEND'),
          isFalse);
      expect(
          AgentLauncher.linuxEnvironment(
                  full, const {}, const AgentLaunchOptions(linuxBackend: 'portal'))
              ['CROSSSHELL_LINUX_BACKEND'],
          'portal');
      expect(
          AgentLauncher.linuxEnvironment(
                  x11, const {}, const AgentLaunchOptions(linuxBackend: 'mutter'))
              ['CROSSSHELL_LINUX_BACKEND'],
          'x11');
    });

    test('agent arguments', () {
      expect(const AgentLaunchOptions().agentArguments('/rt'),
          ['--runtime-dir', '/rt', '--exit-when-idle', '30']);
      expect(
          const AgentLaunchOptions(
                  idleExit: null, notify: false, clipboard: false, synthetic: true)
              .agentArguments('/rt'),
          ['--runtime-dir', '/rt', '--no-notify', '--no-clipboard', '--synthetic']);
    });
  });

  group('Linux launch, through a real sh with a fake agent', () {
    late Directory dir;
    late String runtimeDir;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('ssgo-launch-');
      runtimeDir = '${dir.path}/ssgo-rd-${AgentShell.newId()}';
    });
    tearDown(() => dir.deleteSync(recursive: true));

    DeployedAgent fake(String script) {
      final file = File('${dir.path}/crossshell-host')..writeAsStringSync(script);
      Process.runSync('chmod', ['700', file.path]);
      return _agent(file.path, file.readAsBytesSync());
    }

    AgentLaunchOptions options({Duration timeout = const Duration(seconds: 5)}) =>
        AgentLaunchOptions(
          synthetic: true,
          notify: false,
          useSystemd: false,
          runtimeDir: runtimeDir,
          timeout: timeout,
        );

    bool alive(int pid) => Process.runSync('kill', ['-0', '$pid']).exitCode == 0;

    test('reads host.json, and stop kills the agent and removes the folder',
        () async {
      final agent = fake(fakeAgentScript(token: _token));
      final shell = LocalShellTransport();
      final endpoint = await const AgentLauncher().launchLinux(shell, agent,
          environment: const {'DISPLAY': ':5'}, options: options());
      expect(endpoint.port, 47999);
      expect(endpoint.token, _token * 32);
      expect(endpoint.unitName, isNull);
      expect(endpoint.runtimeDir, runtimeDir);
      expect(alive(endpoint.pid), isTrue);
      // The agent got the session's display and the flags it was meant to.
      final cmdline = File('/proc/${endpoint.pid}/cmdline').readAsStringSync();
      expect(cmdline.split('\x00'),
          containsAllInOrder(['--runtime-dir', runtimeDir, '--exit-when-idle', '30']));
      final environ = File('/proc/${endpoint.pid}/environ').readAsStringSync().split('\x00');
      expect(environ, contains('DISPLAY=:5'));
      expect(environ, contains('CROSSSHELL_LINUX_BACKEND=x11'));
      expect(FileStat.statSync(runtimeDir).mode & 0x1ff, 0x1c0);

      await endpoint.stop();
      await endpoint.stop();
      expect(shell.commands.where((c) => c.contains('SSG-STOPPED')), hasLength(1));
      expect(alive(endpoint.pid), isFalse);
      expect(Directory(runtimeDir).existsSync(), isFalse);
    });

    test('an agent that dies at once: its log, and nothing left', () async {
      final agent = fake('#!/bin/sh\necho "capture backend exploded" >&2\nexit 1\n');
      await expectLater(
        const AgentLauncher().launchLinux(LocalShellTransport(), agent, options: options()),
        throwsA(isA<AgentFailure>()
            .having((f) => f.kind, 'kind', AgentFailureKind.launchFailed)
            .having((f) => f.details, 'details', contains('capture backend exploded'))),
      );
      expect(Directory(runtimeDir).existsSync(), isFalse);
    });

    test('an agent that never publishes host.json is stopped at the deadline',
        () async {
      final agent = fake('#!/bin/sh\necho "waiting forever" > "\$2/host.log"\n'
          'while :; do sleep 1; done\n');
      await expectLater(
        const AgentLauncher().launchLinux(LocalShellTransport(), agent,
            options: options(timeout: const Duration(seconds: 1))),
        throwsA(isA<AgentFailure>()
            .having((f) => f.kind, 'kind', AgentFailureKind.launchTimedOut)
            .having((f) => f.details, 'details', contains('waiting forever'))),
      );
      expect(Directory(runtimeDir).existsSync(), isFalse);
      final left = Process.runSync('pgrep', ['-f', runtimeDir]);
      expect(left.stdout, '');
    });

    test('a binary that changed since it was installed is never run', () async {
      final agent = fake(fakeAgentScript());
      File(agent.path).writeAsStringSync('\necho pwned > "${dir.path}/ran"\n',
          mode: FileMode.append);
      await expectLater(
        const AgentLauncher().launchLinux(LocalShellTransport(), agent, options: options()),
        _fails(AgentFailureKind.hashMismatch),
      );
      expect(File('${dir.path}/ran').existsSync(), isFalse);
      expect(Directory(runtimeDir).existsSync(), isFalse);
    });

    test('a binary that is gone', () async {
      final agent = fake(fakeAgentScript());
      File(agent.path).deleteSync();
      await expectLater(
        const AgentLauncher().launchLinux(LocalShellTransport(), agent, options: options()),
        _fails(AgentFailureKind.launchFailed),
      );
    });

    test('stop does not kill a pid that is no longer the agent', () async {
      final bystander = await Process.start('sleep', ['30']);
      addTearDown(bystander.kill);
      Directory(runtimeDir).createSync();
      await LocalShellTransport().execute(AgentLauncher.linuxStopCommand(
          runtimeDir: runtimeDir, pid: bystander.pid));
      expect(alive(bystander.pid), isTrue);
      expect(Directory(runtimeDir).existsSync(), isFalse);
    });

    test('the scripts parse in BusyBox sh too', () async {
      if (!File('/usr/bin/busybox').existsSync()) return;
      final agent = fake(fakeAgentScript());
      for (final command in [
        AgentLauncher.linuxLaunchCommand(agent: agent, id: AgentShell.newId()),
        AgentLauncher.linuxStopCommand(
            runtimeDir: runtimeDir, unit: 'ssgo-rd-0123456789abcdef', pid: 1),
      ]) {
        final check = command.replaceFirst('sh -c ', 'busybox sh -n -c ');
        final result = await Process.run('sh', ['-c', check]);
        expect(result.exitCode, 0, reason: '${result.stderr}');
      }
    });
  });

  group('Linux launch, scripted', () {
    final agent = _agent('/home/me/a', utf8.encode('x'));

    Future<AgentEndpoint> launch(String stdout) => const AgentLauncher()
        .launchLinux(FakeExecTransport(stdout: stdout), agent);

    test('systemd mode: the unit name comes back', () async {
      final endpoint = await launch('SSG-RT /run/user/1000/ssgo-rd-0123456789abcdef\n'
          'SSG-MODE systemd ssgo-rd-0123456789abcdef\nSSG-READY\n$_hostJson\n\nSSG-END\n');
      expect(endpoint.unitName, 'ssgo-rd-0123456789abcdef');
      expect(endpoint.pid, 4242);
    });

    test('failures are worded, and never quote the token', () async {
      await expectLater(launch('SSG-HASH-MISMATCH deadbeef\n'),
          _fails(AgentFailureKind.hashMismatch));
      await expectLater(launch('SSG-NO-HASH-TOOL\n'), _fails(AgentFailureKind.missingTool));
      await expectLater(launch('SSG-RT /r/ssgo-rd-0123456789abcdef\nSSG-LAUNCH-FAILED\n'
          'SSG-LOG\nFailed to connect to bus\n'),
          throwsA(isA<AgentFailure>()
              .having((f) => f.kind, 'kind', AgentFailureKind.launchFailed)
              .having((f) => f.details, 'details', contains('Failed to connect to bus'))));
      final bad = '{"v":1,"port":0,"token":"${_token * 32}","pid":1,"ver":"x"}';
      await expectLater(
        launch('SSG-RT /r/ssgo-rd-0123456789abcdef\nSSG-MODE pid 9\nSSG-READY\n$bad\nSSG-END\n'),
        throwsA(isA<AgentFailure>()
            .having((f) => f.kind, 'kind', AgentFailureKind.badHostInfo)
            .having((f) => f.toString(), 'text', isNot(contains(_token * 32)))),
      );
    });

    test('an agent that published nonsense is stopped, not left running',
        () async {
      final bad = '{"v":1,"port":1,"token":"short","pid":77,"ver":"x"}';
      final transport = FakeExecTransport(respond: (command) => FakeExecSession(
          stdout: command.contains('SSG-STOPPED')
              ? 'SSG-STOPPED\n'
              : 'SSG-RT /r/ssgo-rd-0123456789abcdef\nSSG-MODE pid 77\n'
                  'SSG-READY\n$bad\nSSG-END\n'));
      await expectLater(const AgentLauncher().launchLinux(transport, agent),
          _fails(AgentFailureKind.badHostInfo));
      expect(transport.commands, hasLength(2));
      expect(transport.commands.last, contains('SSG-STOPPED'));
      expect(transport.commands.last, contains('p=77'));
    });

    test('a desktop is required unless the test pattern was asked for', () {
      final probe = RemoteDesktopProbe(
        guess: const RemoteOsGuess(RemoteOsFamily.linux, evidence: ''),
        linux: const LinuxProbe(system: 'Linux', machine: 'x86_64', uid: 1, home: '/h'),
      );
      expect(
          () => const AgentLauncher().launchDesktop(
              FakeExecTransport(), probe, agent),
          _fails(AgentFailureKind.noDesktop));
    });
  });

  group('runtime directories', () {
    test('only ones this app makes are ever removed', () {
      for (final ok in [
        '/run/user/1000/ssgo-rd-0123456789abcdef',
        '/home/me/.cache/secureshellgo/rt/ssgo-vd-0123456789abcdef',
      ]) {
        AgentLauncher.checkRuntimeDir(ok, windows: false);
      }
      AgentLauncher.checkRuntimeDir(
          r'C:\Users\me\AppData\Local\SecureShellGo\rt\ssgo-rd-0123456789abcdef',
          windows: true);
      for (final bad in [
        '/',
        '/home/me',
        'relative/ssgo-rd-0123456789abcdef',
        '/x/../ssgo-rd-0123456789abcdef',
        '/x/ssgo-rd-0123',
        '/x/ssgo-rd-0123456789abcdef/..',
      ]) {
        expect(() => AgentLauncher.checkRuntimeDir(bad, windows: false), throwsArgumentError,
            reason: bad);
      }
      expect(() => AgentLauncher.checkRuntimeDir(r'C:\Users\me', windows: true),
          throwsArgumentError);
      expect(
          () => const AgentLauncher().launchLinux(FakeExecTransport(),
              _agent('/a', utf8.encode('x')),
              options: const AgentLaunchOptions(runtimeDir: '/tmp')),
          throwsArgumentError);
    });
  });

  group('Windows', () {
    final agent = DeployedAgent(
      binary: binaryFor(bytesOf('MZ'), os: AgentOs.windows, flavour: AgentFlavour.full),
      directory: r"C:\Users\Jo O'Neil\AppData\Local\SecureShellGo\agent\x",
      path: r"C:\Users\Jo O'Neil\AppData\Local\SecureShellGo\agent\x\crossshell-host.exe",
      uploaded: false,
    );

    test('the launch script: hash first, then a run-once interactive task', () {
      final command = AgentLauncher.windowsLaunchCommand(
          agent: agent, id: '0123456789abcdef',
          options: const AgentLaunchOptions(synthetic: true, notify: false));
      expect(command.length, lessThan(AgentShell.maxWindowsCommandLength));
      expect(command, isNot(matches(RegExp(r'[<>|&"%^]'))));
      final script = _decodePowershell(command);
      expect(script.indexOf('SSG-HASH-MISMATCH'), lessThan(script.indexOf('schtasks /create')));
      expect(script, contains(r"$e='C:\Users\Jo O''Neil\AppData"));
      expect(script, contains('SSGo-RD-0123456789abcdef'));
      expect(script, contains(r"'SecureShellGo\rt\ssgo-rd-0123456789abcdef'"));
      expect(script, contains('<LogonType>InteractiveToken</LogonType>'));
      expect(script, contains('<DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>'));
      expect(script, contains('<StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>'));
      expect(script, contains('<ExecutionTimeLimit>PT0S</ExecutionTimeLimit>'));
      expect(script, contains('/xml'));
      expect(script, contains(r"""$a='--runtime-dir "'+$r+'" --exit-when-idle 30 --no-notify --synthetic'"""));
      expect(script, contains('schtasks /delete'));
      expect(script, contains('Get-ScheduledTaskInfo'));
      expect(script, contains('Microsoft-Windows-CodeIntegrity/Operational'));
      // ignore: avoid_print
      print('Windows launch command: ${command.length} characters');
    });

    test('a ready launch, as PowerShell prints it', () async {
      final transport = FakeExecTransport(
          stdout: '\uFEFFSSG-RT C:\\Users\\me\\AppData\\Local\\SecureShellGo\\rt\\'
              'ssgo-rd-0123456789abcdef\r\nSSG-READY\r\n$_hostJson\r\nSSG-END\r\n');
      final endpoint = await const AgentLauncher().launchWindows(transport, agent);
      expect(endpoint.os, AgentOs.windows);
      expect(endpoint.pid, 4242);
      expect(endpoint.runtimeDir, endsWith(r'\ssgo-rd-0123456789abcdef'));

      await endpoint.stop();
      expect(transport.commands.last.length, lessThan(AgentShell.maxWindowsCommandLength));
      final stop = _decodePowershell(transport.commands.last);
      expect(stop, contains(r'taskkill /PID $p /F'));
      // And any agent started for this runtime directory, whatever its pid.
      expect(stop, contains(r'$_.CommandLine.Contains($r)'));
      expect(stop, contains(r'$p=4242'));
      expect(stop, contains(r'$c.CommandLine.Contains($r)'));
      expect(stop, contains("schtasks /delete /tn 'SSGo-RD-"));
    });

    test('Smart App Control blocked it: a failure of its own', () async {
      for (final stdout in [
        'SSG-RT C:\\r\\ssgo-rd-0123456789abcdef\r\nSSG-EXITED\r\n'
            'SSG-TASK-RESULT 2147946951\r\nSSG-LOG\r\n',
        'SSG-RT C:\\r\\ssgo-rd-0123456789abcdef\r\nSSG-EXITED\r\n'
            'SSG-TASK-RESULT -2147020345\r\nSSG-LOG\r\n',
        'SSG-RT C:\\r\\ssgo-rd-0123456789abcdef\r\nSSG-TIMEOUT\r\n'
            'SSG-BLOCKED 3077\r\nSSG-LOG\r\n',
      ]) {
        await expectLater(
          const AgentLauncher().launchWindows(FakeExecTransport(stdout: stdout), agent),
          throwsA(isA<AgentFailure>()
              .having((f) => f.kind, 'kind', AgentFailureKind.blockedByPolicy)
              .having((f) => f.message, 'message', contains('Smart App Control'))),
          reason: stdout,
        );
      }
    });

    test('an agent that exits at once: its exit status', () async {
      await expectLater(
        const AgentLauncher().launchWindows(
            FakeExecTransport(
                stdout: 'SSG-RT C:\\r\\ssgo-rd-0123456789abcdef\r\nSSG-EXITED\r\n'
                    'SSG-TASK-RESULT 1\r\nSSG-LOG\r\nno capture\r\n'),
            agent),
        throwsA(isA<AgentFailure>()
            .having((f) => f.kind, 'kind', AgentFailureKind.launchFailed)
            .having((f) => f.details, 'details', allOf(contains('0x1'), contains('no capture')))),
      );
    });

    test('nobody signed in: the task never starts, and the message says why',
        () async {
      final transport = FakeExecTransport(
          stdout: 'SSG-RT C:\\r\\ssgo-rd-0123456789abcdef\r\nSSG-TIMEOUT\r\nSSG-LOG\r\n');
      await expectLater(
        const AgentLauncher().launchWindows(transport, agent),
        throwsA(isA<AgentFailure>()
            .having((f) => f.kind, 'kind', AgentFailureKind.launchTimedOut)
            .having((f) => f.message, 'message', contains('signed in'))),
      );
    });
  });

  group('host.json', () {
    test('the shape the agent writes', () {
      final info = AgentHostInfo.parse(_hostJson);
      expect(info.port, 47999);
      expect(info.pid, 4242);
      expect(info.version, '0.2.0');
      expect(info.tokenBytes, hasLength(32));
      expect(info.tokenBytes.first, 0xab);
    });

    test('fields it does not use are tolerated', () {
      expect(AgentHostInfo.parse(_hostJson.replaceFirst('{', '{"later":true,')).port, 47999);
    });

    test('anything else is refused', () {
      for (final bad in [
        'not json',
        '[]',
        _hostJson.replaceFirst('"v":1', '"v":2'),
        _hostJson.replaceFirst('47999', '70000'),
        _hostJson.replaceFirst('47999', '"47999"'),
        _hostJson.replaceFirst(_token * 32, _token * 31),
        _hostJson.replaceFirst(_token * 32, (_token * 32).toUpperCase()),
        _hostJson.replaceFirst('4242', '0'),
        _hostJson.replaceFirst('"0.2.0"', '"0.2 0"'),
        _hostJson.replaceFirst('"ver":"0.2.0"', '"ver":3'),
        ' ' * 5000,
      ]) {
        expect(() => AgentHostInfo.parse(bad), _fails(AgentFailureKind.badHostInfo),
            reason: bad);
      }
    });
  });

  group('channel', () {
    final endpoint = AgentEndpoint(
      info: AgentHostInfo.parse(_hostJson),
      os: AgentOs.linux,
      runtimeDir: '/r',
      stop: () async {},
    );

    test('a forward to the agent\'s port on the server\'s loopback', () async {
      final carrier = _Carrier();
      await openAgentChannel(carrier, endpoint);
      expect(carrier.forwards, ['127.0.0.1:47999']);
    });

    test('a refused forward says why it might be', () async {
      await expectLater(
        openAgentChannel(_Carrier(refuse: true), endpoint),
        throwsA(isA<AgentFailure>()
            .having((f) => f.kind, 'kind', AgentFailureKind.channelFailed)
            .having((f) => f.message, 'message', contains('AllowTcpForwarding'))),
      );
    });
  });
}

class _Carrier implements TunnelCarrier {
  _Carrier({this.refuse = false});
  final bool refuse;
  final forwards = <String>[];

  @override
  Future<SSHSocket> forwardLocal(String host, int port) async {
    forwards.add('$host:$port');
    if (refuse) throw SSHChannelOpenError(1, 'administratively prohibited');
    return _Socket();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _Socket implements SSHSocket {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
