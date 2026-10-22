import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/services/known_hosts_service.dart';
import 'package:secure_shell_go/services/remote_exec.dart';
import 'package:secure_shell_go/services/ssh_agent_client.dart';
import 'package:secure_shell_go/services/ssh_service.dart';
import 'package:secure_shell_go/services/x11_forwarding.dart';

/// Sign-in and forwarding against a real OpenSSH server.
///
/// The fakes elsewhere pin the shapes — which channel asks for what, what
/// bytes the agent sees — but only a real `sshd` can say the shapes are
/// right: that the certificate is accepted, the agent's signature verifies,
/// the shell really gets `SSH_AUTH_SOCK` while later execs keep working, and
/// an X client's cookie arrives swapped. So this starts one, as the current
/// user on a loopback port, with its own host key, CA and `ssh-agent`, in a
/// temporary directory — nothing of the developer's own keys, agent or X
/// display is touched.
///
/// Opt-in, because it needs `sshd`, `ssh-agent`, `ssh-keygen`, `xauth` and
/// `python3` on a Linux machine:
///
/// ```sh
/// SSGO_SSHD=1 flutter test test/local_sshd_test.dart
/// ```
void main() {
  final skip = Platform.environment['SSGO_SSHD'] != '1'
      ? 'set SSGO_SSHD=1 to run against a local OpenSSH sshd'
      : !Platform.isLinux || !File('/usr/sbin/sshd').existsSync()
          ? 'needs /usr/sbin/sshd on Linux'
          : null;

  late _Lab lab;

  setUpAll(() async {
    if (skip != null) return;
    lab = await _Lab.start();
  });

  tearDownAll(() async {
    if (skip != null) return;
    await lab.stop();
  });

  const timeout = Timeout(Duration(seconds: 90));

  group('OS agent login', () {
    test('signs in with an ed25519 key the agent holds', () async {
      final connection = await lab.connect(
        lab.host(authMethod: SshAuthMethod.agent),
        const SshCredentials(),
        agent: lab.agent,
      );
      addTearDown(connection.close);
      final result = await RemoteExec.run(connection, 'echo agent-ok');
      expect(result.stdout.trim(), 'agent-ok');
    }, skip: skip, timeout: timeout);

    test('signs in with an RSA key, as rsa-sha2-256', () async {
      final connection = await lab.connect(
        lab.host(authMethod: SshAuthMethod.agent),
        const SshCredentials(),
        agent: lab.rsaAgent,
      );
      addTearDown(connection.close);
      final result = await RemoteExec.run(connection, 'echo rsa-ok');
      expect(result.stdout.trim(), 'rsa-ok');
    }, skip: skip, timeout: timeout);
  });

  group('certificates', () {
    test('a key the server does not list signs in with its certificate',
        () async {
      final certified = lab.host(
        authMethod: SshAuthMethod.privateKey,
        certificate: lab.read('certkey-cert.pub'),
      );
      final connection = await lab.connect(
        certified,
        SshCredentials(privateKeyPem: lab.read('certkey')),
      );
      addTearDown(connection.close);
      final result = await RemoteExec.run(connection, 'echo cert-ok');
      expect(result.stdout.trim(), 'cert-ok');
    }, skip: skip, timeout: timeout);

    test('one without permit-agent-forwarding is named when the agent is '
        'refused', () async {
      final connection = await lab.connect(
        lab.host(
          authMethod: SshAuthMethod.privateKey,
          certificate: lab.read('ptyonly-cert.pub'),
          agentForwarding: true,
        ),
        SshCredentials(privateKeyPem: lab.read('certkey')),
        agent: lab.agent,
      );
      addTearDown(connection.close);
      final shell = await _Shell.open(connection);
      expect(await shell.run('echo still-here'), contains('still-here'));
      expect(shell.errors, contains('no permit-agent-forwarding'));
      shell.close();
    }, skip: skip, timeout: timeout);

    test('and without the certificate the same key is refused', () async {
      await expectLater(
        lab.connect(
          lab.host(authMethod: SshAuthMethod.privateKey),
          SshCredentials(privateKeyPem: lab.read('certkey')),
        ),
        throwsA(isA<SshAuthenticationException>()),
      );
    }, skip: skip, timeout: timeout);

    test('an RSA certificate is presented as rsa-sha2-256-cert', () async {
      final connection = await lab.connect(
        lab.host(
          authMethod: SshAuthMethod.privateKey,
          certificate: lab.read('rsacert-cert.pub'),
        ),
        SshCredentials(privateKeyPem: lab.read('rsacert')),
      );
      addTearDown(connection.close);
      expect((await RemoteExec.run(connection, 'echo ok')).exitCode, 0);
    }, skip: skip, timeout: timeout);

    test('a certificate for a key held in the agent', () async {
      final connection = await lab.connect(
        lab.host(
          authMethod: SshAuthMethod.agent,
          certificate: lab.read('agentcert-copy-cert.pub'),
        ),
        const SshCredentials(),
        agent: lab.agent,
      );
      addTearDown(connection.close);
      expect((await RemoteExec.run(connection, 'echo ok')).exitCode, 0);
    }, skip: skip, timeout: timeout);

    test('an expired one is not offered, and the failure says so', () async {
      await expectLater(
        lab.connect(
          lab.host(
            authMethod: SshAuthMethod.privateKey,
            certificate: lab.read('expired-cert.pub'),
          ),
          SshCredentials(privateKeyPem: lab.read('certkey')),
        ),
        throwsA(isA<SshAuthenticationException>()
            .having((e) => e.message, 'message', contains('expired'))),
      );
    }, skip: skip, timeout: timeout);
  });

  group('agent forwarding', () {
    test('the shell gets the agent, and execs after it still run', () async {
      final connection = await lab.connect(
        lab.host(authMethod: SshAuthMethod.privateKey, agentForwarding: true),
        SshCredentials(privateKeyPem: lab.read('userkey')),
        agent: lab.agent,
      );
      addTearDown(connection.close);

      final shell = await _Shell.open(connection);
      final listed = await shell.run('ssh-add -l');
      // The lab agent's key, and the host's own key from the app.
      expect(listed, contains('agent-only'));
      expect(listed, contains('ssgo:'));

      for (var i = 1; i <= 5; i++) {
        final result = await RemoteExec.run(connection, 'echo exec-$i');
        expect(result.exitCode, 0, reason: 'exec #$i');
        expect(result.stdout.trim(), 'exec-$i');
      }
      shell.close();
    }, skip: skip, timeout: timeout);

    test('a server that refuses still opens the shell, and says so',
        () async {
      final connection = await lab.connect(
        lab.host(
          authMethod: SshAuthMethod.privateKey,
          agentForwarding: true,
          x11Forwarding: true,
        ),
        SshCredentials(privateKeyPem: lab.read('restricted')),
        agent: lab.agent,
        // A display to forward to, so it is the server's refusal that is
        // being tested rather than this device having none.
        x11: () => X11Forwarder(
          display: const X11Display(host: '127.0.0.1', number: 99),
          untrustedCookie: _trustedOnly,
        ),
      );
      addTearDown(connection.close);

      final shell = await _Shell.open(connection);
      expect(await shell.run('echo still-here'), contains('still-here'));
      expect(shell.errors, contains('refused agent forwarding'));
      expect(shell.errors, contains('refused X11 forwarding'));
      expect((await RemoteExec.run(connection, 'echo ok')).exitCode, 0);
      shell.close();
    }, skip: skip, timeout: timeout);
  });

  test('X11 refused but agent allowed: the shell still has the agent',
      () async {
    final connection = await lab.connect(
      lab.host(
        authMethod: SshAuthMethod.privateKey,
        agentForwarding: true,
        x11Forwarding: true,
      ),
      SshCredentials(privateKeyPem: lab.read('nox11')),
      agent: lab.agent,
      x11: () => X11Forwarder(
        display: const X11Display(host: '127.0.0.1', number: 99),
        untrustedCookie: _trustedOnly,
      ),
    );
    addTearDown(connection.close);

    final shell = await _Shell.open(connection);
    expect(await shell.run('ssh-add -l'), contains('agent-only'));
    expect(shell.errors, contains('refused X11 forwarding'));
    expect(shell.errors, isNot(contains('agent')));
    shell.close();
  }, skip: skip, timeout: timeout);

  group('X11 forwarding', () {
    test('an X client reaches the local X server with the real cookie',
        () async {
      final xServer = await _FakeXServer.start();
      addTearDown(xServer.close);
      final realCookie = Uint8List.fromList(List.generate(16, (i) => 0xa0 + i));

      final connection = await lab.connect(
        lab.host(authMethod: SshAuthMethod.privateKey, x11Forwarding: true),
        SshCredentials(privateKeyPem: lab.read('userkey')),
        x11: () => X11Forwarder(
          display: X11Display(host: '127.0.0.1', number: xServer.display),
          realCookie: () async => XauthEntry(
            family: XauthEntry.familyWild,
            address: Uint8List(0),
            number: '',
            name: x11CookieProtocol,
            data: realCookie,
          ),
          untrustedCookie: _trustedOnly,
        ),
      );
      addTearDown(connection.close);

      final shell = await _Shell.open(connection);
      expect(await shell.run('echo "DISPLAY=\$DISPLAY"'),
          matches(RegExp(r'DISPLAY=localhost:\d+\.0')));
      final reply = await shell.run('python3 ${lab.path('x11client.py')}');
      expect(reply, contains('X11-REPLY hello-from-x'));

      final setup = await xServer.firstSetup;
      expect(setup.name, x11CookieProtocol);
      expect(setup.data, realCookie);
      expect(setup.after, 'EXTRA');
      expect((await RemoteExec.run(connection, 'echo ok')).exitCode, 0);
      shell.close();
    }, skip: skip, timeout: timeout);

    test('where the display can, it gets an untrusted cookie, not the real '
        'one', () async {
      final xServer = await _FakeXServer.start();
      addTearDown(xServer.close);
      final untrusted = Uint8List.fromList(List.generate(16, (i) => 0x30 + i));

      final connection = await lab.connect(
        lab.host(authMethod: SshAuthMethod.privateKey, x11Forwarding: true),
        SshCredentials(privateKeyPem: lab.read('userkey')),
        x11: () => X11Forwarder(
          display: X11Display(host: '127.0.0.1', number: xServer.display),
          realCookie: () async => throw StateError('must not be read'),
          untrustedCookie: () async => XauthEntry(
            family: XauthEntry.familyWild,
            address: Uint8List(0),
            number: '',
            name: x11CookieProtocol,
            data: untrusted,
          ),
        ),
      );
      addTearDown(connection.close);

      final shell = await _Shell.open(connection);
      final reply = await shell.run('python3 ${lab.path('x11client.py')}');
      expect(reply, contains('X11-REPLY hello-from-x'));
      expect((await xServer.firstSetup).data, untrusted);
      shell.close();
    }, skip: skip, timeout: timeout);
  });
}

Future<XauthEntry> _trustedOnly() async =>
    throw const X11UntrustedUnavailable(null);

/// A temporary sshd, CA and agents.
class _Lab {
  _Lab._(this.dir, this.port, this._sshd, this._agents);

  final Directory dir;
  final int port;
  final Process _sshd;
  final List<int> _agents;

  late final SshAgentClient agent = _agentAt(path('agent.sock'));
  late final SshAgentClient rsaAgent = _agentAt(path('rsa-agent.sock'));

  String path(String name) => '${dir.path}/$name';
  String read(String name) => File(path(name)).readAsStringSync();

  static Future<_Lab> start() async {
    final dir = await Directory.systemTemp.createTemp('ssgo-sshd');
    String at(String name) => '${dir.path}/$name';
    String slurp(String name) => File(at(name)).readAsStringSync();
    Future<void> run(String exe, List<String> args) async {
      final result = await Process.run(exe, args);
      if (result.exitCode != 0) {
        throw StateError('$exe ${args.join(' ')}: ${result.stderr}');
      }
    }

    Future<void> keygen(String name, {String type = 'ed25519'}) => run(
        'ssh-keygen',
        ['-q', '-t', type, if (type == 'rsa') ...['-b', '2048'], '-N', '',
          '-C', name, '-f', at(name)]);
    Future<void> sign(String pub, String id,
            {String validity = '-5m:+1d', List<String> options = const []}) =>
        run('ssh-keygen', ['-q', '-s', at('ca'), '-I', id, '-n',
          Platform.environment['USER']!, '-V', validity,
          for (final o in options) ...['-O', o], at(pub)]);

    for (final name in [
      'hostkey', 'ca', 'userkey', 'agent-only', 'certkey', 'agentcert',
      'restricted', 'nox11',
    ]) {
      await keygen(name);
    }
    await keygen('rsakey', type: 'rsa');
    await keygen('rsacert', type: 'rsa');
    File(at('expired.pub')).writeAsStringSync(slurp('certkey.pub'));
    // Not next to the key, so ssh-add does not load it into the agent too.
    File(at('agentcert-copy.pub')).writeAsStringSync(slurp('agentcert.pub'));
    File(at('ptyonly.pub')).writeAsStringSync(slurp('certkey.pub'));
    await sign('certkey.pub', 'cert-id');
    await sign('ptyonly.pub', 'pty-only-id',
        options: ['clear', 'permit-pty']);
    await sign('rsacert.pub', 'rsa-cert-id');
    await sign('agentcert-copy.pub', 'agent-cert-id');
    await sign('expired.pub', 'expired-id', validity: '20200101:20200102');

    File(at('authorized_keys')).writeAsStringSync([
      slurp('userkey.pub'),
      slurp('agent-only.pub'),
      slurp('rsakey.pub'),
      'no-agent-forwarding,no-X11-forwarding ${slurp('restricted.pub')}',
      'no-X11-forwarding ${slurp('nox11.pub')}',
    ].join());
    File(at('trusted_ca')).writeAsStringSync(slurp('ca.pub'));
    File(at('x11client.py')).writeAsStringSync(_x11Client);

    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    File(at('sshd_config')).writeAsStringSync('''
Port $port
ListenAddress 127.0.0.1
HostKey ${at('hostkey')}
PidFile ${at('sshd.pid')}
AuthorizedKeysFile ${at('authorized_keys')}
TrustedUserCAKeys ${at('trusted_ca')}
UsePAM no
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
AllowAgentForwarding yes
X11Forwarding yes
X11UseLocalhost yes
X11DisplayOffset 60
XAuthLocation /usr/bin/xauth
SetEnv XAUTHORITY=${at('Xauthority')}
''');
    final sshd = await Process.start(
      '/usr/sbin/sshd',
      ['-D', '-e', '-f', at('sshd_config')],
    );
    sshd.stdout.drain<void>();
    sshd.stderr.drain<void>();

    final agents = <int>[];
    Future<void> agentWith(String socket, List<String> keys) async {
      final result = await Process.run('ssh-agent', ['-a', at(socket)]);
      final pid = RegExp(r'SSH_AGENT_PID=(\d+)').firstMatch('${result.stdout}');
      agents.add(int.parse(pid!.group(1)!));
      for (final key in keys) {
        final added = await Process.run(
          'ssh-add',
          [at(key)],
          environment: {'SSH_AUTH_SOCK': at(socket)},
        );
        if (added.exitCode != 0) throw StateError('ssh-add: ${added.stderr}');
      }
    }

    await agentWith('agent.sock', ['agent-only', 'agentcert']);
    await agentWith('rsa-agent.sock', ['rsakey']);

    for (var i = 0; i < 50; i++) {
      try {
        final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
        socket.destroy();
        break;
      } on SocketException {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    return _Lab._(dir, port, sshd, agents);
  }

  Host host({
    required SshAuthMethod authMethod,
    bool agentForwarding = false,
    bool x11Forwarding = false,
    String? certificate,
  }) =>
      Host(
        id: 'lab',
        label: 'lab',
        hostname: '127.0.0.1',
        port: port,
        username: Platform.environment['USER']!,
        authMethod: authMethod,
        agentForwarding: agentForwarding,
        x11Forwarding: x11Forwarding,
        certificate: certificate,
      );

  Future<SshConnection> connect(
    Host host,
    SshCredentials credentials, {
    SshAgentClient? agent,
    X11Forwarder? Function()? x11,
  }) {
    return SshService(
      knownHosts: KnownHostsService(file: File(path('known_hosts.json'))),
      agent: agent ?? _agentAt(path('no-agent.sock')),
      x11: x11 ?? () => null,
    ).connect(
      host: host,
      credentials: credentials,
      verifyHostKey: (_) async => true,
      timeout: const Duration(seconds: 20),
    );
  }

  static SshAgentClient _agentAt(String socketPath) => SshAgentClient(
        connector: () async {
          final socket = await Socket.connect(
            InternetAddress(socketPath, type: InternetAddressType.unix),
            0,
          );
          return StreamAgentConnection(socket, socket);
        },
      );

  Future<void> stop() async {
    _sshd.kill();
    for (final pid in _agents) {
      Process.killPid(pid);
    }
    await _sshd.exitCode.timeout(const Duration(seconds: 5), onTimeout: () => 0);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }
}

/// An interactive shell driven like a person would: a command, then a
/// marker, and everything printed in between.
class _Shell {
  _Shell._(this._session) {
    _session.stdout.listen((data) => _out.write(utf8.decode(data, allowMalformed: true)));
    _session.stderr.listen((data) => _err.write(utf8.decode(data, allowMalformed: true)));
  }

  final SSHSession _session;
  final _out = StringBuffer();
  final _err = StringBuffer();
  var _count = 0;

  String get errors => _err.toString();

  static Future<_Shell> open(SshConnection connection) async =>
      _Shell._(await connection.startShell(columns: 200, rows: 40));

  Future<String> run(String command) async {
    final marker = '__done_${_count++}__';
    final start = _out.length;
    _session.write(utf8.encode('$command; echo $marker\n'));
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      final text = _out.toString().substring(start);
      // The echoed command line carries the marker too; the printed one is
      // on a line of its own.
      if (RegExp('^$marker', multiLine: true).hasMatch(text)) return text;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw TimeoutException('no "$marker" in: ${_out.toString().substring(start)}');
  }

  void close() => _session.close();
}

/// A listener on 6000 + n that records the first X11 setup it is sent and
/// answers it.
class _FakeXServer {
  _FakeXServer._(this._server, this.display);

  final ServerSocket _server;
  final int display;
  final _setup = Completer<({String name, List<int> data, String after})>();

  Future<({String name, List<int> data, String after})> get firstSetup =>
      _setup.future;

  static Future<_FakeXServer> start() async {
    for (var n = 40; n < 100; n++) {
      try {
        final server =
            await ServerSocket.bind(InternetAddress.loopbackIPv4, 6000 + n);
        final fake = _FakeXServer._(server, n);
        server.listen(fake._serve);
        return fake;
      } on SocketException {
        // Taken; try the next display.
      }
    }
    throw StateError('no free X display port');
  }

  void _serve(Socket socket) {
    final buffer = BytesBuilder();
    socket.listen((chunk) {
      buffer.add(chunk);
      final bytes = buffer.toBytes();
      if (bytes.length < 12 || _setup.isCompleted) return;
      final view = ByteData.sublistView(bytes);
      final n = view.getUint16(6, Endian.little);
      final d = view.getUint16(8, Endian.little);
      int pad(int x) => (4 - x % 4) % 4;
      final dataStart = 12 + n + pad(n);
      final end = dataStart + d + pad(d);
      if (bytes.length < end + 5) return;
      _setup.complete((
        name: String.fromCharCodes(bytes.sublist(12, 12 + n)),
        data: bytes.sublist(dataStart, dataStart + d),
        after: String.fromCharCodes(bytes.sublist(end, end + 5)),
      ));
      socket.add(utf8.encode('hello-from-x'));
    });
  }

  Future<void> close() => _server.close();
}

/// An X client in miniature: reads the cookie sshd stored for `DISPLAY`,
/// sends a connection setup carrying it (and five bytes after), and prints
/// what the X server answers.
const _x11Client = r'''
import os, socket, struct, subprocess
display = os.environ["DISPLAY"]
number = int(display.rsplit(":", 1)[1].split(".")[0])
cookie = bytes.fromhex(subprocess.check_output(["xauth", "list", display]).split()[-1].decode())
name = b"MIT-MAGIC-COOKIE-1"
pad = lambda n: b"\0" * ((4 - n % 4) % 4)
setup = b"l\0" + struct.pack("<HHHH", 11, 0, len(name), len(cookie)) + b"\0\0"
setup += name + pad(len(name)) + cookie + pad(len(cookie)) + b"EXTRA"
s = socket.create_connection(("127.0.0.1", 6000 + number))
s.sendall(setup)
print("X11-REPLY " + s.recv(64).decode())
''';
