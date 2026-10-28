import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/services/known_hosts_service.dart';
import 'package:secure_shell_go/services/mosh/mosh_connection.dart';
import 'package:secure_shell_go/services/mosh/mosh_shell.dart';
import 'package:secure_shell_go/services/persistent_shell.dart';
import 'package:secure_shell_go/services/remote_exec.dart';
import 'package:secure_shell_go/services/session_controller.dart';
import 'package:secure_shell_go/services/ssh_service.dart';
import 'package:xterm/core.dart';

/// Mosh against a real `mosh-server`, started the way the app starts it:
/// over SSH, through a throwaway local OpenSSH `sshd`.
///
/// The unit tests pin the wire format against Mosh's own definitions; only a
/// real server can say the whole thing works — that it accepts this client's
/// datagrams, that its screen diffs apply, and that it follows the client to
/// a new address.
///
/// Opt-in, because it needs `sshd` and `ssh-keygen` on Linux, and a
/// `mosh-server`: `SSGO_MOSH_SERVER` (and `SSGO_MOSH_LIBS` for its library
/// path) when given, else one on the PATH, else the distribution's package
/// unpacked into a temporary directory with `apt-get download` and
/// `dpkg -x` — no root needed:
///
/// ```sh
/// SSGO_MOSH=1 flutter test test/mosh_integration_test.dart
/// ```
void main() {
  final skip = Platform.environment['SSGO_MOSH'] != '1'
      ? 'set SSGO_MOSH=1 to run against a real mosh-server'
      : !Platform.isLinux || !File('/usr/sbin/sshd').existsSync()
      ? 'needs /usr/sbin/sshd on Linux'
      : null;

  late _MoshLab lab;

  setUpAll(() async {
    if (skip != null) return;
    lab = await _MoshLab.start();
  });

  tearDownAll(() async {
    if (skip != null) return;
    await lab.stop();
  });

  const timeout = Timeout(Duration(seconds: 90));

  Future<(SshConnection, MoshShell, _Screen)> open({
    int columns = 80,
    int rows = 24,
    MoshUdpBinder bind = bindRawMoshSocket,
  }) async {
    final ssh = await lab.connect();
    addTearDown(ssh.close);
    final screen = _Screen(columns, rows);
    final mosh = await MoshShell.start(
      ssh,
      columns: columns,
      rows: rows,
      // A plain shell with a fixed prompt, whatever the developer's own
      // login shell does at start-up.
      command: r"PS1='mosh$ ' exec sh -i",
      bind: bind,
    );
    // Ends mosh-server as closing a tab does, rather than leaving one
    // running per test; registered after `ssh.close`, so it runs first.
    addTearDown(
      () => mosh
          .close(ssh: ssh)
          .timeout(
            const Duration(seconds: 20),
            onTimeout: () => const MoshExit(clean: false),
          ),
    );
    mosh.output.listen(screen.terminal.write);
    return (ssh, mosh, screen);
  }

  test(
    'starts over SSH, and keystrokes come back as screen updates',
    () async {
      final (_, mosh, screen) = await open();
      expect(mosh.server.port, inInclusiveRange(60001, 60999));
      expect(mosh.server.pid, isNotNull);
      await screen.waitFor('mosh\$');

      mosh.write('echo typed-\$((6*7))\r');
      await screen.waitFor('typed-42');
      // The command line and its output, as a real terminal shows them.
      expect(screen.text, contains(r'mosh$ echo typed-$((6*7))'));
      expect(mosh.client.connection.srtt, lessThan(1000));
    },
    skip: skip,
    timeout: timeout,
  );

  test(
    'a resize reaches the server, and a full screen scrolls into the '
    'scrollback',
    () async {
      final (_, mosh, screen) = await open();
      await screen.waitFor('mosh\$');

      screen.terminal.resize(100, 30);
      mosh.resize(100, 30);
      mosh.write('stty size\r');
      await screen.waitFor('30 100');

      // Slowly enough that consecutive frames overlap: Mosh sends screens,
      // not output, so a burst that finishes inside one frame never scrolls
      // at all, but this does — and Mosh scrolls with real line feeds.
      mosh.write(
        r'i=0; while [ $i -lt 45 ]; do i=$((i+1)); echo line-$i; '
        r'sleep 0.03; done'
        '\r',
      );
      await screen.waitFor('line-45\nmosh\$');
      final scrolled = [
        for (var i = 0; i < screen.terminal.buffer.scrollBack; i++)
          screen.terminal.buffer.lines[i].toString().trim(),
      ];
      expect(scrolled, contains('line-1'));
    },
    skip: skip,
    timeout: timeout,
  );

  test(
    'on a slow link, typing shows before the server has echoed it',
    () async {
      // 300 ms more on every datagram from the server.
      final (_, mosh, screen) = await open(
        bind: (family, onDatagram) => bindRawMoshSocket(
          family,
          (datagram) => Timer(
            const Duration(milliseconds: 300),
            () => onDatagram(datagram),
          ),
        ),
      );
      await screen.waitFor('mosh\$');
      // The first keystroke is only ever shown once the server confirms it —
      // which is what keeps a password prompt from echoing.
      mosh.write('e');
      await screen.waitFor(r'mosh$ e');

      final typed = DateTime.now();
      mosh.write('cho predicted');
      await screen.waitFor(
        r'mosh$ echo predicted',
        timeout: const Duration(milliseconds: 250),
      );
      expect(
        DateTime.now().difference(typed),
        lessThan(const Duration(milliseconds: 250)),
      );
      // Underlined while unconfirmed, on a link this slow.
      final lines = screen.text.split('\n');
      final y = lines.indexWhere((line) => line.contains('predicted'));
      final row =
          screen.terminal.buffer.lines[screen.terminal.buffer.scrollBack + y];
      expect(
        row.getAttributes(lines[y].indexOf('predicted')) & CellAttr.underline,
        isNot(0),
      );

      mosh.write('\r');
      await screen.waitFor('predicted\nmosh\$');
    },
    skip: skip,
    timeout: timeout,
  );

  test(
    'follows the client to a new address',
    () async {
      final (_, mosh, screen) = await open();
      await screen.waitFor('mosh\$');
      final connection = mosh.client.connection;
      final before = connection.localPort;

      // A network change: a new local port (a new NAT mapping, a new
      // interface), and the old one gone with whatever was in flight to it.
      connection.hopPort();
      await _until(() => connection.localPort != before);
      connection.closeOldSockets();

      mosh.write('echo roamed-\$((40+2))\r');
      await screen.waitFor('roamed-42');
      expect(connection.localPort, isNot(before));
    },
    skip: skip,
    timeout: timeout,
  );

  test(
    'exit ends the session cleanly',
    () async {
      final (_, mosh, screen) = await open();
      await screen.waitFor('mosh\$');
      mosh.write('exit\r');
      final exit = await mosh.done.timeout(const Duration(seconds: 15));
      expect(exit.clean, isTrue);
    },
    skip: skip,
    timeout: timeout,
  );

  test(
    'closing the tab says goodbye, and the server goes',
    () async {
      final (ssh, mosh, screen) = await open();
      await screen.waitFor('mosh\$');
      await mosh.close().timeout(const Duration(seconds: 15));
      final pid = mosh.server.pid!;
      await _until(() async {
        final result = await RemoteExec.run(ssh, 'kill -0 $pid && echo up');
        return !result.stdout.contains('up');
      });
    },
    skip: skip,
    timeout: timeout,
  );

  test(
    'a host without mosh-server says so',
    () async {
      final ssh = await lab.connect();
      addTearDown(ssh.close);
      await expectLater(
        MoshShell.start(
          ssh,
          columns: 80,
          rows: 24,
          server: '/nonexistent/mosh-server',
        ),
        throwsA(
          isA<MoshStartException>().having(
            (e) => e.kind,
            'kind',
            MoshStartFailure.notInstalled,
          ),
        ),
      );
    },
    skip: skip,
    timeout: timeout,
  );

  test(
    'UDP that never gets through is reported, and the server stopped',
    () async {
      final ssh = await lab.connect();
      addTearDown(ssh.close);
      MoshServerInfo? started;
      await expectLater(
        MoshShell.start(
          ssh,
          columns: 80,
          rows: 24,
          connectTimeout: const Duration(seconds: 3),
          // A firewall that drops everything going out.
          bind: (family, onDatagram) async =>
              _BlackHole(await bindRawMoshSocket(family, onDatagram)),
          resolve: (info) async {
            started = info;
            return InternetAddress.loopbackIPv4;
          },
        ),
        throwsA(isA<MoshUnreachableException>()),
      );
      final pid = started!.pid!;
      await _until(() async {
        final result = await RemoteExec.run(ssh, 'kill -0 $pid && echo up');
        return !result.stdout.contains('up');
      });
    },
    skip: skip,
    timeout: timeout,
  );

  group('through a session', () {
    Future<SessionController> session({
      PersistentSession persistent = PersistentSession.off,
      MoshStarter startMosh = MoshShell.start,
    }) async {
      final host = lab.host(
        transport: HostTransport.mosh,
        persistentSession: persistent,
      );
      final controller = SessionController(
        connection: await lab.connect(host: host),
        reconnect: ReconnectSupport(
          loadCredentials: (_) async => lab.credentials,
          connect:
              ({required host, required credentials, required verifyHostKey}) =>
                  lab.connect(host: host),
        ),
        startMosh: startMosh,
      );
      addTearDown(controller.dispose);
      controller.terminal.resize(100, 30);
      return controller;
    }

    Future<void> showsOnScreen(SessionController controller, String text) =>
        _until(
          () => controller.terminal.buffer.getText().contains(text),
          timeout: const Duration(seconds: 15),
        );

    test(
      'a Mosh host gets its terminal over Mosh',
      () async {
        final controller = await session();
        await controller.ensureShell();
        controller.terminal.textInput('echo via-\$((20+22))\r');
        await showsOnScreen(controller, 'via-42');
        expect(
          controller.terminal.buffer.getText(),
          isNot(contains('Using SSH')),
        );
      },
      skip: skip,
      timeout: timeout,
    );

    test(
      'without mosh-server it falls back to SSH, saying so in one line',
      () async {
        final missing = File(lab.path('mosh-missing'))..createSync();
        addTearDown(missing.deleteSync);
        final controller = await session();
        await controller.ensureShell();
        expect(
          controller.terminal.buffer.getText(),
          contains(
            'mosh-server is not installed on this host. Using SSH for '
            'this terminal.',
          ),
        );
        controller.terminal.textInput('echo over-\$((1+1))-ssh\r');
        await showsOnScreen(controller, 'over-2-ssh');
      },
      skip: skip,
      timeout: timeout,
    );

    test(
      'a persistent session runs inside screen under mosh-server',
      () async {
        final controller = await session(persistent: PersistentSession.screen);
        final name = persistentSessionName(controller.host, 1);
        addTearDown(() async {
          final ssh = await lab.connect();
          await RemoteExec.run(ssh, 'screen -S $name -X quit');
          ssh.close();
        });
        await controller.ensureShell();
        controller.terminal.textInput('echo "in:\$STY"\r');
        await showsOnScreen(controller, '.$name');
      },
      skip:
          skip ??
          (Process.runSync('sh', ['-c', 'command -v screen']).exitCode != 0
              ? 'needs GNU screen'
              : null),
      timeout: timeout,
    );

    /// Whether process [pid] is still running on the lab host.
    Future<bool> running(int pid) async {
      final ssh = await lab.connect();
      try {
        final result = await RemoteExec.run(ssh, 'kill -0 $pid && echo up');
        return result.stdout.contains('up');
      } finally {
        ssh.close();
      }
    }

    /// Opens a session's Mosh terminal, and returns the pids of its
    /// mosh-server and of the shell under it.
    Future<({int server, int shell})> openTerminal(
      SessionController controller,
      MoshShell? Function() started,
    ) async {
      await controller.ensureShell();
      controller.terminal.textInput(r'echo "shell-pid:$$:"' '\r');
      final printed = RegExp(r'shell-pid:(\d+):');
      String text() => controller.terminal.buffer.getText();
      await _until(
        () => printed.hasMatch(text()),
        timeout: const Duration(seconds: 15),
      );
      final shell = printed.firstMatch(text())!.group(1)!;
      return (server: started()!.server.pid!, shell: int.parse(shell));
    }

    test(
      'closing the tab ends mosh-server, and the shell under it',
      () async {
        MoshShell? started;
        final controller = await session(
          startMosh: (ssh, {required columns, required rows, command}) async =>
              started = await MoshShell.start(
                ssh,
                columns: columns,
                rows: rows,
                command: command,
              ),
        );
        final pids = await openTerminal(controller, () => started);

        await controller.dispose();
        await _until(
          () async => !await running(pids.server) && !await running(pids.shell),
          timeout: const Duration(seconds: 20),
        );
      },
      skip: skip,
      timeout: timeout,
    );

    test(
      'a goodbye that never gets through still ends mosh-server, over SSH',
      () async {
        var cut = false;
        MoshShell? started;
        final controller = await session(
          startMosh: (ssh, {required columns, required rows, command}) async =>
              started = await MoshShell.start(
                ssh,
                columns: columns,
                rows: rows,
                command: command,
                bind: (family, onDatagram) async => _Cuttable(
                  await bindRawMoshSocket(family, onDatagram),
                  () => cut,
                ),
              ),
        );
        final pids = await openTerminal(controller, () => started);

        // UDP stops getting out, so the goodbye never arrives.
        cut = true;
        await controller.dispose();
        await _until(
          () async => !await running(pids.server) && !await running(pids.shell),
          timeout: const Duration(seconds: 50),
        );
      },
      skip: skip,
      timeout: timeout,
    );

    test(
      'the terminal carries on while SSH drops and comes back',
      () async {
        final controller = await session();
        await controller.ensureShell();
        controller.terminal.textInput('echo first-\$((1+1))\r');
        await showsOnScreen(controller, 'first-2');

        final dropped = controller.connection;
        dropped.close();
        await _until(
          () => controller.isReconnecting || dropped != controller.connection,
        );
        expect(controller.isClosed, isFalse);

        controller.terminal.textInput('echo during-\$((2+2))\r');
        await showsOnScreen(controller, 'during-4');

        await _until(
          () => !controller.isReconnecting && controller.connection != dropped,
          timeout: const Duration(seconds: 30),
        );
        controller.terminal.textInput('echo after-\$((3+3))\r');
        await showsOnScreen(controller, 'after-6');
        // Files are back on the new connection.
        final files = await controller.sftp();
        expect(await files.home(), isNotEmpty);
      },
      skip: skip,
      timeout: timeout,
    );
  });
}

Future<void> _until(
  FutureOr<bool> Function() condition, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition not met', timeout);
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

/// An xterm terminal fed only by Mosh, read back as text.
class _Screen {
  _Screen(int columns, int rows) : terminal = Terminal(maxLines: 1000) {
    terminal.resize(columns, rows);
  }

  final Terminal terminal;

  String get text => [
    for (var i = 0; i < terminal.viewHeight; i++)
      terminal.buffer.lines[terminal.buffer.scrollBack + i]
          .toString()
          .trimRight(),
  ].join('\n');

  Future<void> waitFor(
    String expected, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!text.contains(expected)) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('no "$expected" on screen:\n$text', timeout);
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}

/// A socket whose datagrams stop leaving once [_cut] says so.
class _Cuttable implements MoshUdpSocket {
  _Cuttable(this._inner, this._cut);
  final MoshUdpSocket _inner;
  final bool Function() _cut;
  @override
  int get port => _inner.port;
  @override
  int send(Uint8List data, InternetAddress address, int port) =>
      _cut() ? data.length : _inner.send(data, address, port);
  @override
  void close() => _inner.close();
}

/// A socket whose datagrams never leave.
class _BlackHole implements MoshUdpSocket {
  _BlackHole(this._inner);
  final MoshUdpSocket _inner;
  @override
  int get port => _inner.port;
  @override
  int send(Uint8List data, InternetAddress address, int port) => data.length;
  @override
  void close() => _inner.close();
}

/// A temporary sshd for the current user, with `mosh-server` on the PATH its
/// commands get.
class _MoshLab {
  _MoshLab._(this.dir, this.port, this._sshd);

  final Directory dir;
  final int port;
  final Process _sshd;

  String path(String name) => '${dir.path}/$name';

  static Future<_MoshLab> start() async {
    final dir = await Directory.systemTemp.createTemp('ssgo-mosh');
    String at(String name) => '${dir.path}/$name';
    Future<void> run(String exe, List<String> args, {String? cwd}) async {
      final result = await Process.run(exe, args, workingDirectory: cwd);
      if (result.exitCode != 0) {
        throw StateError('$exe ${args.join(' ')}: ${result.stderr}');
      }
    }

    for (final name in ['hostkey', 'userkey']) {
      await run('ssh-keygen', [
        '-q',
        '-t',
        'ed25519',
        '-N',
        '',
        '-C',
        name,
        '-f',
        at(name),
      ]);
    }
    File(
      at('authorized_keys'),
    ).writeAsStringSync(File(at('userkey.pub')).readAsStringSync());

    final server = await _findMoshServer(dir);
    Directory(at('bin')).createSync();
    final wrapper = File(at('bin/mosh-server'))
      ..writeAsStringSync(
        '#!/bin/sh\n'
        // A test switches mosh-server "off" by creating this file.
        'if [ -e ${at('mosh-missing')} ]; then '
        'echo "mosh-server: not found" >&2; exit 127; fi\n'
        '${server.libs == null ? '' : 'LD_LIBRARY_PATH=${server.libs} '}'
        'exec ${server.exe} "\$@"\n',
      );
    await run('chmod', ['+x', wrapper.path]);

    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    File(at('sshd_config')).writeAsStringSync('''
Port $port
ListenAddress 127.0.0.1
HostKey ${at('hostkey')}
PidFile ${at('sshd.pid')}
AuthorizedKeysFile ${at('authorized_keys')}
UsePAM no
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
Subsystem sftp internal-sftp
SetEnv PATH=${at('bin')}:/usr/local/bin:/usr/bin:/bin
''');
    final sshd = await Process.start('/usr/sbin/sshd', [
      '-D',
      '-e',
      '-f',
      at('sshd_config'),
    ]);
    sshd.stdout.drain<void>();
    sshd.stderr.drain<void>();
    for (var i = 0; i < 50; i++) {
      try {
        final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
        socket.destroy();
        break;
      } on SocketException {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    return _MoshLab._(dir, port, sshd);
  }

  /// A `mosh-server` to run, and the library path it needs.
  static Future<({String exe, String? libs})> _findMoshServer(
    Directory dir,
  ) async {
    final explicit = Platform.environment['SSGO_MOSH_SERVER'];
    if (explicit != null) {
      return (exe: explicit, libs: Platform.environment['SSGO_MOSH_LIBS']);
    }
    final which = await Process.run('sh', ['-c', 'command -v mosh-server']);
    if (which.exitCode == 0) {
      return (exe: '${which.stdout}'.trim(), libs: null);
    }
    // The distribution's package, unpacked without installing it.
    final debs = Directory('${dir.path}/debs')..createSync();
    final download = await Process.run('apt-get', [
      'download',
      'mosh',
      'libutempter0',
    ], workingDirectory: debs.path);
    if (download.exitCode != 0) {
      throw StateError(
        'no mosh-server, and apt-get download failed: '
        '${download.stderr}',
      );
    }
    final root = '${dir.path}/mosh-root';
    for (final deb in debs.listSync().whereType<File>()) {
      final unpacked = await Process.run('dpkg', ['-x', deb.path, root]);
      if (unpacked.exitCode != 0) {
        throw StateError('dpkg -x ${deb.path}: ${unpacked.stderr}');
      }
    }
    // ldconfig would have made the soname link; nobody ran it.
    String? libs;
    for (final entity in Directory('$root/usr/lib').listSync(recursive: true)) {
      final name = entity.uri.pathSegments.last;
      if (entity is File && name.startsWith('libutempter.so.')) {
        libs = entity.parent.path;
        final link = Link('$libs/libutempter.so.0');
        if (!link.existsSync()) link.createSync(name);
      }
    }
    return (exe: '$root/usr/bin/mosh-server', libs: libs);
  }

  Host host({
    HostTransport transport = HostTransport.ssh,
    PersistentSession persistentSession = PersistentSession.off,
  }) => Host(
    id: 'mosh-lab',
    label: 'mosh-lab',
    hostname: '127.0.0.1',
    port: port,
    username: Platform.environment['USER']!,
    authMethod: SshAuthMethod.privateKey,
    transport: transport,
    persistentSession: persistentSession,
  );

  SshCredentials get credentials =>
      SshCredentials(privateKeyPem: File(path('userkey')).readAsStringSync());

  Future<SshConnection> connect({Host? host}) =>
      SshService(
        knownHosts: KnownHostsService(file: File(path('known_hosts.json'))),
        agent: SshAgentClient(connector: () async => throw StateError('none')),
        x11: () => null,
      ).connect(
        host: host ?? this.host(),
        credentials: credentials,
        verifyHostKey: (_) async => true,
        timeout: const Duration(seconds: 20),
      );

  Future<void> stop() async {
    _sshd.kill();
    await _sshd.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () => 0,
    );
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }
}
