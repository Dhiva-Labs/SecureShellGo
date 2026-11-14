import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/app_settings.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/models/host_ai_access.dart';
import 'package:secure_shell_go/services/bridge/bridge_audit.dart';
import 'package:secure_shell_go/services/bridge/bridge_client_store.dart';
import 'package:secure_shell_go/services/bridge/bridge_connections.dart';
import 'package:secure_shell_go/services/bridge/bridge_paths.dart';
import 'package:secure_shell_go/services/bridge/bridge_redactor.dart';
import 'package:secure_shell_go/services/bridge/bridge_tools.dart';
import 'package:secure_shell_go/services/known_hosts_service.dart';
import 'package:secure_shell_go/services/ssh_service.dart';

/// The bridge's SFTP and exec paths against a real OpenSSH server on
/// localhost: what `SftpBridgeFiles` gets back from a real realpath, stat and
/// windowed read, and one `read_file` and one `search_files` end to end,
/// through the supervised wrapper and the account's own login shell.
///
/// Opt-in, like `local_sshd_test.dart`, because it needs `sshd` and
/// `ssh-keygen`:
///
/// SSGO_SSHD=1 flutter test test/bridge_local_sshd_test.dart
void main() {
  final skip = Platform.environment['SSGO_SSHD'] != '1'
      ? 'set SSGO_SSHD=1 to run against a local OpenSSH sshd'
      : !Platform.isLinux || !File('/usr/sbin/sshd').existsSync()
      ? 'needs /usr/sbin/sshd on Linux'
      : null;

  late _Lab lab;
  late SshConnection connection;
  late BridgeFiles files;
  late String data;
  late String secretKey;

  setUpAll(() async {
    if (skip != null) return;
    lab = await _Lab.start();
    // The server is this machine, so the test lays out the remote files
    // directly. Resolved, because the temp directory may itself sit behind
    // a symlink and realpath answers with where things really are.
    final root = Directory(lab.at('tree'))..createSync();
    final base = root.resolveSymbolicLinksSync();
    data = '$base/data';
    Directory(data).createSync();
    Directory('$base/home/.ssh').createSync(recursive: true);
    secretKey = '$base/home/.ssh/id_ed25519';
    File(secretKey).writeAsStringSync('NOT A REAL KEY');
    File('$data/notes.txt').writeAsStringSync('0123456789abcdef\n');
    File('$data/big.txt').writeAsStringSync('x' * (200 * 1024));
    File('$data/deep.conf').writeAsStringSync('');
    Link('$data/link.txt').createSync(secretKey);
    await Process.run('mkfifo', ['$data/pipe']);

    connection = await lab.connect();
    files = await SftpBridgeFiles.open(connection);
  });

  tearDownAll(() async {
    if (skip != null) return;
    await files.close();
    connection.close();
    await lab.stop();
  });

  group('SftpBridgeFiles on a real server', () {
    test('realpath of an existing file is itself', () async {
      expect(await files.realpath('$data/notes.txt'), '$data/notes.txt');
      expect(
        await files.realpath('$data/../data/./notes.txt'),
        '$data/notes.txt',
      );
    }, skip: skip);

    test(
      'realpath follows a link into ~/.ssh, and the guard blocks it',
      () async {
        final resolved = await files.realpath('$data/link.txt');
        expect(resolved, secretKey);
        expect(
          BridgePathGuard(readSensitivePaths: false).isBlocked(resolved),
          true,
        );
      },
      skip: skip,
    );

    test('realpath of a path whose last part is missing', () async {
      // OpenSSH's answer differs between versions: older servers return the
      // path, newer ones refuse. Either way the bridge refuses the same as
      // for a blocked path, so this records which one this server gives.
      String? answer;
      Object? error;
      try {
        answer = await files.realpath('$data/missing.txt');
      } catch (e) {
        error = e;
      }
      // ignore: avoid_print
      print(
        'realpath of a missing last part: '
        '${error == null ? 'returned "$answer"' : 'refused ($error)'}',
      );
      expect(answer ?? error, isNotNull);
      if (answer != null) expect(answer, '$data/missing.txt');
      await expectLater(
        files.realpath('$data/nodir/missing.txt'),
        throwsA(anything),
      );
    }, skip: skip);

    test('stat tells a directory, a file and a FIFO apart', () async {
      expect((await files.stat(data)).type, BridgeFileType.directory);
      final notes = await files.stat('$data/notes.txt');
      expect(notes.type, BridgeFileType.file);
      expect(notes.size, 17);
      expect((await files.stat('$data/pipe')).type, BridgeFileType.other);
    }, skip: skip);

    test('a windowed read returns just the window', () async {
      final bytes = await files.read('$data/notes.txt', offset: 4, length: 5);
      expect(String.fromCharCodes(bytes), '45678');
      final big = await files.read(
        '$data/big.txt',
        offset: 1000,
        length: 65536,
      );
      expect(big.length, 65536);
      final tail = await files.read('$data/notes.txt', offset: 15, length: 100);
      expect(String.fromCharCodes(tail), 'f\n');
    }, skip: skip);
  });

  group('BridgeTools end to end', () {
    late BridgeTools tools;
    late Directory auditDir;
    final client = BridgeClient(
      id: 'c',
      name: 'lab assistant',
      tokenHash: 'x',
      createdAt: DateTime.utc(2026),
    );

    setUpAll(() async {
      if (skip != null) return;
      auditDir = Directory(lab.at('audit'))..createSync();
      final host = lab.host;
      final connections = BridgeConnections(
        openTransport: (_) => connection,
        credentialLookup: (_) async => null,
        dialer: (_, _) async => throw StateError('not used'),
      );
      tools = BridgeTools(
        loadHosts: () async => [host],
        settings: () => const AppSettings(bridgeEnabled: true),
        isAppLocked: () => false,
        connections: connections,
        redactor: BridgeRedactor(scrub: (s) => s),
        audit: BridgeAuditLog(scrub: (s) => s, directory: auditDir),
      );
    });

    test(
      'read_file reads a window, and refuses the link into ~/.ssh',
      () async {
        final ok = await tools.call(client, 'read_file', {
          'host': 'lab',
          'path': '$data/notes.txt',
          'offset': 2,
          'max_bytes': 4,
        });
        expect(ok.isError, false, reason: ok.text);
        expect(ok.text, endsWith('2345'));
        expect(ok.text, contains('bytes: 2-6 of 17'));

        final blocked = await tools.call(client, 'read_file', {
          'host': 'lab',
          'path': '$data/link.txt',
        });
        final missing = await tools.call(client, 'read_file', {
          'host': 'lab',
          'path': '$data/nodir/missing.txt',
        });
        expect(blocked.isError, true);
        expect(blocked.text, BridgeToolRefusals.pathNotAvailable.message);
        expect(missing.text, blocked.text);
        expect(blocked.text, isNot(contains('NOT A REAL KEY')));
      },
      skip: skip,
    );

    test(
      'a blocked path is refused before any existence check: missing and '
      'present answer alike, in every tool that takes a path',
      () async {
        // This server's realpath answers a missing last component with the
        // path itself, so only the guard stands between a probe and a
        // difference in answers.
        final sshDir = File(secretKey).parent.path;
        Future<String> ask(String tool, Map<String, Object?> args) async {
          final r = await tools.call(client, tool, {'host': 'lab', ...args});
          expect(r.isError, true, reason: '$tool $args: ${r.text}');
          return r.text;
        }

        final refused = BridgeToolRefusals.pathNotAvailable.message;
        for (final (tool, key) in [
          ('read_file', 'path'),
          ('tail_log', 'path'),
        ]) {
          expect(await ask(tool, {key: secretKey}), refused, reason: tool);
          expect(await ask(tool, {key: '$sshDir/id_missing'}), refused);
        }
        for (final (tool, key) in [
          ('list_dir', 'path'),
          ('search_files', 'dir'),
        ]) {
          final extra = tool == 'search_files' ? {'name': '*'} : {};
          expect(
            await ask(tool, {key: sshDir, ...extra}),
            refused,
            reason: tool,
          );
          expect(await ask(tool, {key: '$sshDir/nodir', ...extra}), refused);
        }

        // An allowed path that is only missing is an ordinary failure, and
        // not the blocked refusal.
        final missing = await tools.call(client, 'read_file', {
          'host': 'lab',
          'path': '$data/missing.txt',
        });
        expect(missing.isError, true);
        expect(missing.text, isNot(refused));
        final missingLog = await tools.call(client, 'tail_log', {
          'host': 'lab',
          'path': '$data/missing.log',
        });
        expect(missingLog.isError, true);
        expect(missingLog.text, isNot(refused));
        expect(missingLog.text, contains('not a readable file'));
      },
      skip: skip,
    );

    test('search_files finds names through the real login shell', () async {
      final r = await tools.call(client, 'search_files', {
        'host': 'lab',
        'dir': data,
        'name': '*.txt',
      });
      expect(r.isError, false, reason: r.text);
      final found = r.text.trim().split('\n').toSet();
      expect(found, containsAll(['$data/notes.txt', '$data/big.txt']));
      // The link's own name matches; it is listed by name only, never read.
      expect(r.text, isNot(contains('NOT A REAL KEY')));

      final stats = await tools.call(client, 'server_stats', {'host': 'lab'});
      expect(stats.isError, false, reason: stats.text);
      expect(stats.text, contains('"cpus"'));
    }, skip: skip);
  });
}

/// A temporary sshd with one user key and the internal SFTP server.
class _Lab {
  _Lab._(this.dir, this.port, this._sshd);

  final Directory dir;
  final int port;
  final Process _sshd;

  String at(String name) => '${dir.path}/$name';

  static Future<_Lab> start() async {
    final dir = await Directory.systemTemp.createTemp('ssgo-bridge-sshd');
    String at(String name) => '${dir.path}/$name';
    for (final name in ['hostkey', 'userkey']) {
      final r = await Process.run('ssh-keygen', [
        '-q', '-t', 'ed25519', '-N', '', '-C', name, '-f', at(name), //
      ]);
      if (r.exitCode != 0) throw StateError('ssh-keygen: ${r.stderr}');
    }
    File(
      at('authorized_keys'),
    ).writeAsStringSync(File(at('userkey.pub')).readAsStringSync());
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
''');
    final sshd = await Process.start('/usr/sbin/sshd', [
      '-D', '-e', '-f', at('sshd_config'), //
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
    return _Lab._(dir, port, sshd);
  }

  Host get host => Host(
    id: 'lab',
    label: 'lab',
    hostname: '127.0.0.1',
    port: port,
    username: Platform.environment['USER']!,
    authMethod: SshAuthMethod.privateKey,
    aiAccess: HostAiAccess.readOnly,
  );

  Future<SshConnection> connect() =>
      SshService(
        knownHosts: KnownHostsService(file: File(at('known_hosts.json'))),
      ).connect(
        host: host,
        credentials: SshCredentials(
          privateKeyPem: File(at('userkey')).readAsStringSync(),
        ),
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
