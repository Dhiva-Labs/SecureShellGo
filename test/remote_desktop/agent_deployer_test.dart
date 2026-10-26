import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/remote_desktop/agent_deployer.dart';
import 'package:secure_shell_go/services/remote_desktop/agent_failure.dart';
import 'package:secure_shell_go/services/remote_desktop/agent_manifest.dart';
import 'package:secure_shell_go/services/remote_desktop/agent_probe.dart';
import 'package:secure_shell_go/services/remote_desktop/agent_shell.dart';
import 'package:secure_shell_go/services/sftp_service.dart';

import '../fake_exec_session.dart';
import 'agent_test_support.dart';

final _x11Bytes = bytesOf('#!/bin/sh\necho x11 agent\n');
final _fullBytes = bytesOf('#!/bin/sh\necho full agent\n');
final _winBytes = bytesOf('MZ windows agent');
final _x11 = binaryFor(_x11Bytes);
final _full = binaryFor(_fullBytes, flavour: AgentFlavour.full, minGlibc: '2.30');
final _armX11 = binaryFor(bytesOf('arm x11'), arch: AgentArch.aarch64);
final _win = binaryFor(_winBytes, os: AgentOs.windows, flavour: AgentFlavour.full);

AgentBundle _bundle() => bundleOf({
      _x11: _x11Bytes,
      _full: _fullBytes,
      _armX11: bytesOf('arm x11'),
      _win: _winBytes,
    });

RemoteDesktopProbe _linuxProbe({
  String machine = 'x86_64',
  String home = '/home/me',
  List<LoginSession> sessions = const [],
  bool pipewire = true,
  String? glibc = '2.39',
}) =>
    RemoteDesktopProbe(
      guess: const RemoteOsGuess(RemoteOsFamily.linux, evidence: 'test'),
      linux: LinuxProbe(
        system: 'Linux',
        machine: machine,
        uid: 1000,
        home: home,
        sessions: sessions,
        hasLibPipewire: pipewire,
        glibcVersion: glibc,
      ),
    );

LoginSession _graphical(String type, {String desktop = 'GNOME', int uid = 1000}) =>
    LoginSession(
      id: '2',
      uid: uid,
      user: uid == 1000 ? 'me' : 'alice',
      type: type,
      sessionClass: 'user',
      active: true,
      state: 'active',
      desktop: desktop,
      seat: 'seat0',
    );

RemoteDesktopProbe _windowsProbe({String arch = 'X64'}) => RemoteDesktopProbe(
      guess: const RemoteOsGuess(RemoteOsFamily.windows, evidence: 'test'),
      windows: WindowsProbe(
        architecture: arch,
        user: 'me',
        localAppData: r'C:\Users\me\AppData\Local',
      ),
    );

Matcher _fails(AgentFailureKind kind) =>
    throwsA(isA<AgentFailure>().having((f) => f.kind, 'kind', kind));

/// The script inside a `powershell -EncodedCommand` line.
String _decodePowershell(String command) {
  final b64 = command.substring(command.indexOf('-EncodedCommand ') + 16);
  final bytes = base64.decode(b64);
  return String.fromCharCodes([
    for (var i = 0; i < bytes.length; i += 2) bytes[i] | (bytes[i + 1] << 8),
  ]);
}

void main() {
  group('choose', () {
    final deployer = AgentDeployer(_bundle());

    test('a build without agents', () {
      expect(() => AgentDeployer(bundleOf({})).choose(_linuxProbe(), AgentPurpose.desktop),
          _fails(AgentFailureKind.unavailableInBuild));
    });

    test('macOS and other systems', () {
      const mac = RemoteDesktopProbe(
          guess: RemoteOsGuess(RemoteOsFamily.macos, evidence: 'uname says Darwin'));
      expect(
          () => deployer.choose(mac, AgentPurpose.desktop),
          throwsA(isA<AgentFailure>()
              .having((f) => f.kind, 'kind', AgentFailureKind.unsupportedRemote)
              .having((f) => f.message, 'message', contains('Mac'))));
    });

    test('a 32-bit CPU', () {
      expect(() => deployer.choose(_linuxProbe(machine: 'armv7l'), AgentPurpose.virtualDesktop),
          _fails(AgentFailureKind.unsupportedRemote));
    });

    test('virtual desktops are always the x11 build', () {
      expect(deployer.choose(_linuxProbe(), AgentPurpose.virtualDesktop), _x11);
      expect(deployer.choose(_linuxProbe(machine: 'aarch64'), AgentPurpose.virtualDesktop),
          _armX11);
    });

    test('a GNOME Wayland desktop with PipeWire gets the full build', () {
      expect(
          deployer.choose(
              _linuxProbe(sessions: [_graphical('wayland')]), AgentPurpose.desktop),
          _full);
    });

    test('an X11 desktop falls back to the x11 build when full cannot load', () {
      expect(
          deployer.choose(_linuxProbe(sessions: [_graphical('x11')], pipewire: false),
              AgentPurpose.desktop),
          _x11);
      expect(
          deployer.choose(_linuxProbe(sessions: [_graphical('x11')], glibc: '2.28'),
              AgentPurpose.desktop),
          _x11);
      // And when this build has no full one for the CPU, as for ARM64 today.
      expect(
          deployer.choose(_linuxProbe(machine: 'aarch64', sessions: [_graphical('x11')]),
              AgentPurpose.desktop),
          _armX11);
    });

    test('a Wayland desktop has no fallback', () {
      expect(
          () => deployer.choose(
              _linuxProbe(sessions: [_graphical('wayland')], pipewire: false),
              AgentPurpose.desktop),
          _fails(AgentFailureKind.missingTool));
      expect(
          () => deployer.choose(
              _linuxProbe(sessions: [_graphical('wayland')], glibc: '2.28'),
              AgentPurpose.desktop),
          throwsA(isA<AgentFailure>()
              .having((f) => f.kind, 'kind', AgentFailureKind.unsupportedRemote)
              .having((f) => f.details, 'details', 'glibc 2.28')));
      expect(
          () => deployer.choose(
              _linuxProbe(machine: 'aarch64', sessions: [_graphical('wayland')]),
              AgentPurpose.desktop),
          _fails(AgentFailureKind.unavailableInBuild));
    });

    test('no desktop, or somebody else\'s', () {
      expect(() => deployer.choose(_linuxProbe(), AgentPurpose.desktop),
          _fails(AgentFailureKind.noDesktop));
      expect(
          () => deployer.choose(
              _linuxProbe(sessions: [_graphical('x11', uid: 1001)]), AgentPurpose.desktop),
          throwsA(isA<AgentFailure>()
              .having((f) => f.kind, 'kind', AgentFailureKind.desktopOfAnotherUser)
              .having((f) => f.message, 'message', contains('alice'))));
    });

    test('Windows: desktop only, per architecture', () {
      expect(deployer.choose(_windowsProbe(), AgentPurpose.desktop), _win);
      expect(() => deployer.choose(_windowsProbe(), AgentPurpose.virtualDesktop),
          _fails(AgentFailureKind.unsupportedRemote));
      expect(() => deployer.choose(_windowsProbe(arch: 'Arm64'), AgentPurpose.desktop),
          _fails(AgentFailureKind.unavailableInBuild));
    });
  });

  group('deploy on Linux, through a real sh', () {
    late Directory home;
    setUp(() => home = Directory.systemTemp.createTempSync('ssgo-deploy-'));
    tearDown(() => home.deleteSync(recursive: true));

    String agentDir() => '${home.path}/.cache/secureshellgo/agent/${_x11.sha256}';

    test('uploads once into a 0700, content-addressed folder; then skips',
        () async {
      final shell = LocalShellTransport();
      final files = LocalFiles();
      final deployer = AgentDeployer(_bundle());
      final probe = _linuxProbe(home: home.path);
      final progress = <int>[];

      final first = await deployer.deploy(shell, probe,
          purpose: AgentPurpose.virtualDesktop,
          files: files,
          onProgress: (sent, total) {
            expect(total, _x11Bytes.length);
            progress.add(sent);
          });
      expect(first.uploaded, isTrue);
      expect(first.path, '${agentDir()}/crossshell-host');
      expect(File(first.path).readAsBytesSync(), _x11Bytes);
      expect(progress.last, _x11Bytes.length);
      for (final path in [
        first.path,
        agentDir(),
        '${home.path}/.cache/secureshellgo',
        '${home.path}/.cache/secureshellgo/agent',
      ]) {
        expect(FileStat.statSync(path).mode & 0x1ff, 0x1c0, reason: path); // 0700
      }
      // The upload went to a part file, never to the installed name.
      expect(files.opened.single, startsWith('${agentDir()}/crossshell-host.part-'));
      expect(Directory(agentDir()).listSync(), hasLength(1));

      final second = await deployer.deploy(shell, probe,
          purpose: AgentPurpose.virtualDesktop, files: files);
      expect(second.uploaded, isFalse);
      expect(files.opened, hasLength(1));
    });

    test('a damaged installed copy is replaced', () async {
      final shell = LocalShellTransport();
      final deployer = AgentDeployer(_bundle());
      final probe = _linuxProbe(home: home.path);
      final first = await deployer.deploy(shell, probe,
          purpose: AgentPurpose.virtualDesktop, files: LocalFiles());
      File(first.path).writeAsStringSync('tampered', mode: FileMode.append);
      final again = await deployer.deploy(shell, probe,
          purpose: AgentPurpose.virtualDesktop, files: LocalFiles());
      expect(again.uploaded, isTrue);
      expect(File(first.path).readAsBytesSync(), _x11Bytes);
    });

    test('a transfer that arrives corrupted is deleted, not installed', () async {
      final shell = LocalShellTransport();
      final deployer = AgentDeployer(_bundle());
      await expectLater(
        deployer.deploy(shell, _linuxProbe(home: home.path),
            purpose: AgentPurpose.virtualDesktop, files: _CorruptingFiles()),
        _fails(AgentFailureKind.hashMismatch),
      );
      expect(Directory(agentDir()).listSync(), isEmpty);
    });

    test('an upload the server refuses', () async {
      await expectLater(
        AgentDeployer(_bundle()).deploy(LocalShellTransport(), _linuxProbe(home: home.path),
            purpose: AgentPurpose.virtualDesktop, files: FailingFiles()),
        _fails(AgentFailureKind.uploadFailed),
      );
    });

    test('a path with a quote in it survives the trip', () async {
      final odd = Directory('${home.path}/it\'s "home"')..createSync();
      final shell = LocalShellTransport();
      final first = await AgentDeployer(_bundle()).deploy(
          shell, _linuxProbe(home: odd.path),
          purpose: AgentPurpose.virtualDesktop, files: LocalFiles());
      expect(File(first.path).readAsBytesSync(), _x11Bytes);
    });
  });

  group('deploy, scripted', () {
    test('a server with no hash tool', () async {
      final transport = FakeExecTransport(stdout: 'SSG-NO-HASH-TOOL\n');
      await expectLater(
        AgentDeployer(_bundle()).deploy(transport, _linuxProbe(),
            purpose: AgentPurpose.virtualDesktop, files: LocalFiles()),
        _fails(AgentFailureKind.missingTool),
      );
    });

    test('Windows: the folder comes from the server, SFTP gets /C:/ paths',
        () async {
      final opened = <String>[];
      final transport = FakeExecTransport(respond: (command) {
        final script = _decodePowershell(command);
        if (script.contains("'SSG-OK'")) {
          return FakeExecSession(
              stdout: '\uFEFFSSG-DIR C:\\Users\\me\\AppData\\Local\\SecureShellGo\\agent\\'
                  '${_win.sha256}\r\nSSG-OK\r\n');
        }
        return FakeExecSession(stdout: 'SSG-INSTALLED\r\n');
      });
      final agent = await AgentDeployer(_bundle()).deploy(transport, _windowsProbe(),
          purpose: AgentPurpose.desktop, files: _RecordingFiles(opened));
      expect(agent.uploaded, isTrue);
      expect(agent.path,
          'C:\\Users\\me\\AppData\\Local\\SecureShellGo\\agent\\${_win.sha256}\\crossshell-host.exe');
      expect(opened.single,
          startsWith('/C:/Users/me/AppData/Local/SecureShellGo/agent/${_win.sha256}/crossshell-host.exe.part-'));
      for (final command in transport.commands) {
        expect(command.length, lessThan(AgentShell.maxWindowsCommandLength));
      }
      final install = _decodePowershell(transport.commands.last);
      expect(install, contains("-ne '${_win.sha256}'"));
      expect(install, contains('Move-Item'));
    });

    test('Windows: an agent already there is not sent again', () async {
      final transport = FakeExecTransport(
          stdout: 'SSG-HAVE ${_win.sha256}\r\nSSG-DIR C:\\x\r\nSSG-OK\r\n');
      final agent = await AgentDeployer(_bundle()).deploy(transport, _windowsProbe(),
          purpose: AgentPurpose.desktop, files: FailingFiles());
      expect(agent.uploaded, isFalse);
      expect(transport.commands, hasLength(1));
    });

    test('the PowerShell helper is not shadowed by a built-in alias', () {
      // Aliases win over functions; `H` is Get-History, `r` Invoke-History,
      // `h`/`gi`/`gc`/`ls`… — every short name is a risk.
      final name = RegExp(r'function (\w+)').firstMatch(AgentShell.psHashFunction)!.group(1)!;
      expect(name.length, greaterThan(4));
      expect(name.toLowerCase(), startsWith('ssg'));
    });

    test('windowsPathToSftp', () {
      expect(windowsPathToSftp(r'c:\Users\me\x y'), '/C:/Users/me/x y');
      expect(windowsPathToSftp('D:/data'), '/D:/data');
      expect(() => windowsPathToSftp(r'\\server\share\me'),
          _fails(AgentFailureKind.uploadFailed));
    });
  });
}

/// Flips a byte on the way, like a transfer that went wrong.
class _CorruptingFiles extends LocalFiles {
  @override
  Future<RemoteFileWriter> openWrite(String remotePath) async {
    final inner = await super.openWrite(remotePath);
    return _Flip(inner);
  }
}

class _Flip implements RemoteFileWriter {
  _Flip(this._inner);
  final RemoteFileWriter _inner;

  @override
  Future<void> add(Uint8List chunk) =>
      _inner.add(Uint8List.fromList(chunk)..[0] ^= 0xff);

  @override
  Future<void> close() => _inner.close();

  @override
  Future<void> abort() => _inner.abort();
}

class _RecordingFiles implements RemoteFileSystem {
  _RecordingFiles(this.opened);
  final List<String> opened;

  @override
  Future<RemoteFileWriter> openWrite(String remotePath) async {
    opened.add(remotePath);
    return _NullWriter();
  }

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _NullWriter implements RemoteFileWriter {
  @override
  Future<void> add(Uint8List chunk) async {}
  @override
  Future<void> close() async {}
  @override
  Future<void> abort() async {}
}
