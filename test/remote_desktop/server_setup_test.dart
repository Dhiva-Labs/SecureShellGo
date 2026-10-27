import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/remote_desktop/agent_probe.dart';
import 'package:secure_shell_go/services/remote_desktop/server_setup.dart';

import '../fake_exec_session.dart';
import '../support/fake_transport.dart';

OsRelease _os(String id, [String like = '', String version = '']) => OsRelease(
      id: id,
      idLike: like.isEmpty ? const [] : like.split(' '),
      versionId: version,
      prettyName: id,
    );

/// A real local process behind the session interface, stdin included: the
/// sudo password really goes down a pipe to a (fake) sudo that reads it.
class _ProcessSession extends FakeExecSession {
  _ProcessSession(this.process) : super(exits: true);

  final Process process;
  int? _code;

  @override
  Stream<Uint8List> get stdout => process.stdout.map(Uint8List.fromList);

  @override
  Stream<Uint8List> get stderr => process.stderr.map(Uint8List.fromList);

  @override
  StreamSink<Uint8List> get stdin => _Sink(process.stdin);

  @override
  Future<void> get done => process.exitCode.then((c) => _code = c);

  @override
  int? get exitCode => _code;

  @override
  void close() => process.kill();
}

class _Sink implements StreamSink<Uint8List> {
  _Sink(this._inner);
  final IOSink _inner;
  @override
  void add(Uint8List data) => _inner.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);
  @override
  Future<void> addStream(Stream<Uint8List> stream) => _inner.addStream(stream);
  @override
  Future<void> close() => _inner.close();
  @override
  Future<void> get done => _inner.done;
}

class _ProcessTransport extends FakeTransportBase {
  _ProcessTransport(this.environment);
  final Map<String, String> environment;
  final List<String> commands = [];

  @override
  Future<SSHSession> execute(String command) async {
    commands.add(command);
    return _ProcessSession(await Process.start('sh', ['-c', command],
        environment: environment, includeParentEnvironment: false));
  }
}

void main() {
  group('which package manager', () {
    test('by ID, then ID_LIKE', () {
      expect(packageManagerFor(_os('ubuntu')), PackageManager.apt);
      expect(packageManagerFor(_os('pop', 'ubuntu debian')), PackageManager.apt);
      expect(packageManagerFor(_os('rocky', 'rhel centos fedora')), PackageManager.dnf);
      expect(packageManagerFor(_os('centos', 'rhel', '7')), PackageManager.yum);
      expect(packageManagerFor(_os('opensuse-leap')), PackageManager.zypper);
      expect(packageManagerFor(_os('endeavouros', 'arch')), PackageManager.pacman);
      expect(packageManagerFor(_os('alpine')), PackageManager.apk);
      expect(packageManagerFor(_os('gentoo')), isNull);
    });
  });

  group('install scripts', () {
    test('every manager, non-interactive, and parses in sh', () async {
      for (final pm in PackageManager.values) {
        final script = installScript(pm, SetupPackages.desktop(pm));
        final parsed = await Process.run('sh', ['-n', '-c', script]);
        expect(parsed.exitCode, 0, reason: '$pm: ${parsed.stderr}');
        expect(
          script,
          anyOf(contains('-y'), contains('--noconfirm'), contains('--non-interactive'),
              startsWith('apk add')),
          reason: '$pm must not ask questions',
        );
      }
    });

    test('apt leaves recommended packages out and waits for the lock', () {
      final script = installScript(PackageManager.apt, ['xvfb']);
      expect(script, contains('--no-install-recommends'));
      expect(script, contains('DPkg::Lock::Timeout'));
      expect(script, contains('DEBIAN_FRONTEND=noninteractive'));
    });

    test('only package names reach a script', () {
      expect(() => installScript(PackageManager.apt, ['xvfb; rm -rf /']),
          throwsArgumentError);
      expect(() => installScript(PackageManager.apt, [r'$(id)']), throwsArgumentError);
      expect(() => installScript(PackageManager.apt, ['-oFoo=bar']), throwsArgumentError);
      expect(() => installScript(PackageManager.apt, []), throwsArgumentError);
      expect(installScript(PackageManager.apt, ['libstdc++6', 'python3.12']),
          contains('libstdc++6 python3.12'));
    });

    test('the command shown when the app cannot install', () {
      expect(installCommandLine(PackageManager.apt, ['xvfb']), 'sudo apt install xvfb');
      expect(installCommandLine(PackageManager.pacman, ['xfce4']),
          'sudo pacman -S --needed xfce4');
    });
  });

  group('privilege', () {
    test('from the probe output', () {
      expect(parsePrivilege('SSG-ROOT\n'), Privilege.root);
      expect(parsePrivilege('SSG-SUDO\n'), Privilege.sudo);
      expect(parsePrivilege('SSG-SUDO-PASSWORD\n'), Privilege.sudoPassword);
      expect(parsePrivilege('SSG-NO-SUDO\n'), Privilege.none);
      expect(parsePrivilege(''), Privilege.none);
    });
  });

  group('why the server refused X11', () {
    const ubuntu = '#=ssg=osrelease\nNAME="Ubuntu"\nID=ubuntu\nID_LIKE=debian\n';

    test('xauth missing, settings readable and on', () {
      final check = parseX11ServerCheck(
          'SSG-XAUTH=no\nSSG-X11FWD=yes\nSSG-SSHD=read\n$ubuntu');
      expect(check.hasXauth, isFalse);
      expect(check.forwardingAllowed, isTrue);
      expect(check.pm, PackageManager.apt);
      expect(SetupPackages.xauth(check.pm!), ['xauth']);
    });

    test('a no in a drop-in still counts the yes after it, for wording only',
        () {
      final check = parseX11ServerCheck(
          'SSG-XAUTH=yes\nSSG-X11FWD=no\nSSG-X11FWD=YES\nSSG-SSHD=read\n$ubuntu');
      expect(check.forwardingAllowed, isTrue);
    });

    test("no line at all is OpenSSH's default: off", () {
      final check =
          parseX11ServerCheck('SSG-XAUTH=yes\nSSG-SSHD=read\n$ubuntu');
      expect(check.hasXauth, isTrue);
      expect(check.forwardingAllowed, isFalse);
    });

    test('settings kept to root are unknown, not off', () {
      final check =
          parseX11ServerCheck('SSG-XAUTH=yes\n#=ssg=osrelease\nID=fedora\n');
      expect(check.forwardingAllowed, isNull);
      expect(check.pm, PackageManager.dnf);
      expect(SetupPackages.xauth(check.pm!), ['xorg-x11-xauth']);
    });

    test('an unknown system has no package manager to offer', () {
      expect(parseX11ServerCheck('SSG-XAUTH=no\n').pm, isNull);
    });

    test('every manager has an xauth package', () {
      for (final pm in PackageManager.values) {
        expect(SetupPackages.xauth(pm), isNotEmpty, reason: '$pm');
      }
    });

    test('the check runs in a real sh and reads this machine', () async {
      final check = await checkX11Server(_ProcessTransport(
          {'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin'}));
      final xauth = await Process.run('sh', ['-c', 'command -v xauth']);
      expect(check.hasXauth,
          File('/usr/bin/xauth').existsSync() || xauth.exitCode == 0);
      if (!File('/etc/ssh/sshd_config').existsSync()) {
        expect(check.forwardingAllowed, isNull);
      }
    }, testOn: 'linux');
  });

  group('finding a missing program', () {
    test("command-not-found's one package", () {
      expect(
        parseCommandNotFound("Command 'xclock' not found, but can be installed "
            'with:\napt install x11-apps\n'),
        'x11-apps',
      );
      expect(
        parseCommandNotFound("Command 'gimp' not found, but can be installed "
            'with:\nsudo apt install gimp\n'),
        'gimp',
      );
    });

    test('several choices, or none, is no answer', () {
      expect(
        parseCommandNotFound("Command 'vim' not found, but can be installed "
            'with:\napt install vim         # version 2:9.1\n'
            'apt install vim-tiny    # version 2:9.1\n'),
        isNull,
      );
      expect(parseCommandNotFound('sh: 1: nope: not found'), isNull);
    });

    test('the program in what was typed', () {
      expect(programOf('gedit notes.txt'), 'gedit');
      expect(programOf('  firefox --private  '), 'firefox');
      expect(programOf('/opt/app/bin/run -x'), '/opt/app/bin/run');
      expect(programOf(r'$EDITOR'), isNull);
      expect(programOf('FOO=1 app'), isNull);
      expect(programOf('(cd /tmp && app)'), isNull);
      // As an installed app's entry gives it.
      expect(programOf("'/snap/bin/code' '--force-user-env'"), '/snap/bin/code');
      expect(programOf('"/opt/My App/run" --x'), '/opt/My App/run');
      expect(programOf('"\$HOME/bin/x"'), isNull);
    });
  });

  group('installing, through a real sh with a fake apt-get and sudo', () {
    late Directory dir;
    late String bin;
    late Map<String, String> env;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('ssgo-setup-');
      bin = '${dir.path}/bin';
      Directory(bin).createSync();
      // A fresh cloud image: the first install finds no package lists.
      File('$bin/apt-get').writeAsStringSync(r'''#!/bin/sh
echo "$*" >> "$FAKE_DIR/apt-calls"
case " $* " in *" update"*) echo "Reading package lists... Done"; : > "$FAKE_DIR/updated"; exit 0 ;; esac
if [ -f "$FAKE_DIR/broken" ]; then echo "E: Sub-process /usr/bin/dpkg returned an error code (1)" >&2; exit 100; fi
if [ -f "$FAKE_DIR/updated" ]; then echo "Setting up xvfb (2:21.1.12)"; exit 0; fi
echo "E: Unable to locate package xvfb" >&2; exit 100
''');
      // sudo: reads the password from stdin (-S), as the real one does.
      File('$bin/sudo').writeAsStringSync(r'''#!/bin/sh
while [ $# -gt 0 ]; do case "$1" in -k|-S|-n) shift ;; -p) shift 2 ;; *) break ;; esac; done
if [ -f "$FAKE_DIR/no-sudoers" ]; then echo "me is not in the sudoers file." >&2; exit 1; fi
IFS= read -r pw
if [ "$pw" != "right horse" ]; then echo "Sorry, try again." >&2; echo "sudo: 1 incorrect password attempt" >&2; exit 1; fi
exec "$@"
''');
      Process.runSync('chmod', ['755', '$bin/apt-get', '$bin/sudo']);
      env = {'PATH': '$bin:/usr/bin:/bin', 'FAKE_DIR': dir.path, 'HOME': dir.path};
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('as root: refreshes the lists once when a package is not known',
        () async {
      final run = await runInstall(_ProcessTransport(env),
          pm: PackageManager.apt, packages: ['xvfb'], privilege: Privilege.root);
      final lines = <String>[];
      run.lines.listen(lines.add);
      await run.done;
      final calls = File('${dir.path}/apt-calls').readAsLinesSync();
      expect(calls, hasLength(3));
      expect(calls[0], contains('install -y --no-install-recommends xvfb'));
      expect(calls[1], contains('update'));
      expect(calls[2], contains('install -y --no-install-recommends xvfb'));
      expect(lines, contains('Refreshing the package lists, then trying again.'));
      expect(lines, contains('Setting up xvfb (2:21.1.12)'));
    });

    test('with sudo: the password goes down stdin, never the command line',
        () async {
      File('${dir.path}/updated').createSync();
      final transport = _ProcessTransport(env);
      final run = await runInstall(transport,
          pm: PackageManager.apt,
          packages: ['xvfb'],
          privilege: Privilege.sudoPassword,
          password: 'right horse');
      await run.done;
      expect(File('${dir.path}/apt-calls').readAsStringSync(), contains('install'));
      expect(transport.commands.single, startsWith("sudo -k -S -p '' sh -c "));
      expect(transport.commands.single, isNot(contains('right horse')));
    });

    test('a wrong password says so', () async {
      final run = await runInstall(_ProcessTransport(env),
          pm: PackageManager.apt,
          packages: ['xvfb'],
          privilege: Privilege.sudoPassword,
          password: 'wrong');
      await expectLater(
        run.done,
        throwsA(isA<SetupFailure>()
            .having((f) => f.kind, 'kind', SetupFailureKind.wrongPassword)),
      );
      expect(File('${dir.path}/apt-calls').existsSync(), isFalse);
    });

    test('an account sudo refuses says so', () async {
      File('${dir.path}/no-sudoers').createSync();
      final run = await runInstall(_ProcessTransport(env),
          pm: PackageManager.apt,
          packages: ['xvfb'],
          privilege: Privilege.sudoPassword,
          password: 'right horse');
      await expectLater(
        run.done,
        throwsA(isA<SetupFailure>().having((f) => f.kind, 'kind', SetupFailureKind.noSudo)),
      );
    });

    test('a failed install keeps its own error', () async {
      File('${dir.path}/updated').createSync();
      File('${dir.path}/broken').createSync();
      final run = await runInstall(_ProcessTransport(env),
          pm: PackageManager.apt, packages: ['xvfb'], privilege: Privilege.root);
      await expectLater(
        run.done,
        throwsA(isA<SetupFailure>()
            .having((f) => f.kind, 'kind', SetupFailureKind.failed)
            .having((f) => f.output, 'output', contains('dpkg returned an error'))),
      );
    });

    test('a fixed step runs as the account that used sudo', () async {
      File('$bin/loginctl').writeAsStringSync('#!/bin/sh\necho "\$*" > "\$FAKE_DIR/loginctl"\n');
      Process.runSync('chmod', ['755', '$bin/loginctl']);
      final run = await runInstall(_ProcessTransport({...env, 'SUDO_USER': 'dhiva'}),
          pm: PackageManager.apt,
          packages: const [],
          privilege: Privilege.root,
          steps: const [SetupStep.keepRunning]);
      await run.done;
      expect(File('${dir.path}/loginctl').readAsStringSync().trim(), 'enable-linger dhiva');
      expect(File('${dir.path}/apt-calls').existsSync(), isFalse, reason: 'no packages');
    });

    test('no sudo at all is refused before anything runs', () async {
      final transport = _ProcessTransport(env);
      await expectLater(
        runInstall(transport,
            pm: PackageManager.apt, packages: ['xvfb'], privilege: Privilege.none),
        throwsA(isA<SetupFailure>().having((f) => f.kind, 'kind', SetupFailureKind.noSudo)),
      );
      expect(transport.commands, isEmpty);
    });
  });
}
