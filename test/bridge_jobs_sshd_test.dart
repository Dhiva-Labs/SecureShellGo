import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/app_settings.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/models/host_ai_access.dart';
import 'package:secure_shell_go/services/bridge/bridge_audit.dart';
import 'package:secure_shell_go/services/bridge/bridge_client_store.dart';
import 'package:secure_shell_go/services/bridge/bridge_connections.dart';
import 'package:secure_shell_go/services/bridge/bridge_jobs.dart';
import 'package:secure_shell_go/services/bridge/bridge_redactor.dart';
import 'package:secure_shell_go/services/bridge/bridge_tools.dart';
import 'package:secure_shell_go/services/known_hosts_service.dart';
import 'package:secure_shell_go/services/ssh_service.dart';

/// The job tools against a real OpenSSH server on localhost: a job started
/// through the supervised wrapper and the account's login shell keeps
/// running after the connection is dropped, its output and exit status are
/// read back, and stop_job ends its whole process group.
///
/// Opt-in, like `bridge_local_sshd_test.dart`, because it needs `sshd` and
/// `ssh-keygen`:
///
/// SSGO_SSHD=1 flutter test test/bridge_jobs_sshd_test.dart
void main() {
  final skip = Platform.environment['SSGO_SSHD'] != '1'
      ? 'set SSGO_SSHD=1 to run against a local OpenSSH sshd'
      : !Platform.isLinux || !File('/usr/sbin/sshd').existsSync()
      ? 'needs /usr/sbin/sshd on Linux'
      : null;

  late _Lab lab;
  late SshConnection connection;
  late BridgeTools tools;
  late BridgeJobRegistry registry;
  late BridgeJobs jobs;
  late String root;
  final started = <String>[];
  final client = BridgeClient(
    id: 'c',
    name: 'lab assistant',
    tokenHash: 'x',
    createdAt: DateTime.utc(2026),
  );

  setUpAll(() async {
    if (skip != null) return;
    lab = await _Lab.start();
    // The jobs live under the lab folder, not the account's home, so the
    // test leaves nothing behind there (one test below uses the default
    // place and cleans up after itself).
    root = Directory(lab.at('jobs')).resolveSymbolicLinksSyncOrCreate();
    connection = await lab.connect();
    registry = BridgeJobRegistry(file: File(lab.at('bridge_jobs.json')));
    jobs = BridgeJobs(
      registry: registry,
      redactor: BridgeRedactor(scrub: (s) => s),
      remoteRoot: root,
    );
    final connections = BridgeConnections(
      // The connection as it is now: a test drops it and dials a new one.
      openTransport: (_) => connection,
      credentialLookup: (_) async => null,
      dialer: (_, _) async => throw StateError('not used'),
    );
    tools = BridgeTools(
      loadHosts: () async => [lab.host],
      settings: () => const AppSettings(bridgeEnabled: true),
      isAppLocked: () => false,
      connections: connections,
      redactor: BridgeRedactor(scrub: (s) => s),
      audit: BridgeAuditLog(
        scrub: (s) => s,
        directory: Directory(lab.at('audit'))..createSync(),
      ),
      modules: [jobs],
    );
  });

  tearDownAll(() async {
    if (skip != null) return;
    // Nothing a failed test started is left running.
    for (final id in started) {
      final pid = File('$root/$id/pid');
      if (pid.existsSync()) {
        await Process.run('sh', [
          '-c',
          'kill -s KILL -- -${pid.readAsStringSync().trim()} 2>/dev/null',
        ]);
      }
    }
    connection.close();
    await lab.stop();
  });

  Future<Map<String, Object?>> call(
    String tool,
    Map<String, Object?> args, {
    bool ok = true,
    BridgeTools? via,
  }) async {
    final r = await (via ?? tools).call(client, tool, args);
    if (ok) expect(r.isError, false, reason: '$tool: ${r.text}');
    if (r.isError || !r.text.startsWith('{')) return {'text': r.text};
    return (jsonDecode(r.text) as Map).cast<String, Object?>();
  }

  Future<String> start(
    String command, {
    String? cwd,
    String? name,
    BridgeTools? via,
  }) async {
    final body = await call('start_job', {
      'host': 'lab',
      'command': command,
      'cwd': ?cwd,
      'name': ?name,
    }, via: via);
    final id = body['job_id']! as String;
    started.add(id);
    return id;
  }

  /// job_status until [state], polled, with a generous bound.
  Future<Map<String, Object?>> waitFor(String id, String state) async {
    Map<String, Object?> last = {};
    for (var i = 0; i < 120; i++) {
      last = await call('job_status', {'job_id': id});
      if (last['state'] == state) return last;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    fail('job $id never reached $state: $last');
  }

  /// job_output until it contains [text], polled.
  Future<String> outputWith(String id, String text) async {
    var last = '';
    for (var i = 0; i < 120; i++) {
      last = (await call('job_output', {'job_id': id}))['text']! as String;
      if (last.contains(text)) return last;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    fail('job $id never printed "$text": $last');
  }

  Future<bool> groupAlive(String id) async {
    final pid = File('$root/$id/pid').readAsStringSync().trim();
    final r = await Process.run('sh', ['-c', 'kill -s 0 -- -$pid 2>/dev/null']);
    return r.exitCode == 0;
  }

  test(
    'a job outlives the connection; its output is read; stop_job ends its '
    'process group',
    () async {
      final id = await start(
        'echo hello from the job; sleep 300 & sleep 301; wait',
        name: 'sleeper',
      );
      final dir = Directory('$root/$id');
      expect(dir.statSync().mode & 0x1ff, 0x1c0); // 700
      expect(File('$root/$id/cmd').readAsStringSync(), contains('sleep 301'));
      await outputWith(id, 'hello from the job');

      // Drop the connection the job was started over; dial a new one.
      connection.close();
      await Future<void>.delayed(const Duration(seconds: 1));
      connection = await lab.connect();
      final status = await call('job_status', {'job_id': id});
      expect(status['state'], 'running');
      expect(status['name'], 'sleeper');
      expect(await groupAlive(id), isTrue);

      final listed = await call('list_jobs', {'host': 'lab'});
      expect(
        (listed['jobs']! as List).map((j) => (j as Map)['job_id']),
        contains(id),
      );

      final stopped = await call('stop_job', {'job_id': id});
      expect(stopped['state'], 'exited');
      expect(stopped['stopped'], true);
      expect(stopped['exit_code'], 143);
      expect(await groupAlive(id), isFalse);

      final removed = await tools.call(client, 'remove_job', {'job_id': id});
      expect(removed.isError, false, reason: removed.text);
      expect(dir.existsSync(), isFalse);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'stopByUser, the person\'s Stop, ends the job\'s whole process group',
    () async {
      final id = await start('sleep 300 & sleep 301; wait', name: 'for stop');
      expect(await groupAlive(id), isTrue);
      expect(jobs.known.any((j) => j.id == id), isTrue);

      expect(await jobs.stopByUser(id), isTrue);
      expect(await groupAlive(id), isFalse);
      final status = await call('job_status', {'job_id': id});
      expect(status['state'], 'exited');
      expect(status['stopped'], true);
      expect(status['exit_code'], 143);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'a job that exits 3 reports exit 3',
    () async {
      final id = await start('echo bye; exit 3');
      final status = await waitFor(id, 'exited');
      expect(status['exit_code'], 3);
      expect(status['stopped'], false);
      expect(status['runtime_seconds'], isA<int>());
      expect(await outputWith(id, 'bye'), contains('bye'));
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'a folder with spaces and quotes is entered as data',
    () async {
      final odd = Directory(lab.at(r'''dir with 'single' "double" $HOME'''))
        ..createSync();
      final real = odd.resolveSymbolicLinksSync();
      final id = await start('pwd', cwd: real);
      await waitFor(id, 'exited');
      final out = await outputWith(id, 'dir with');
      expect(out.trimRight(), endsWith(real));

      final missing = await tools.call(client, 'start_job', {
        'host': 'lab',
        'command': 'pwd',
        'cwd': '$real/missing',
      });
      expect(missing.isError, true);
      expect(missing.text, contains('cannot be entered'));
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'a command with backslashes and quotes runs exactly as given',
    () async {
      final id = await start(
        r'''printf '%s|%s\n' 'a\b' "c\\d"; echo 'it'"'"'s' ''',
      );
      await waitFor(id, 'exited');
      final out = await outputWith(id, "it's");
      expect(out, contains(r'a\b|c\d'));
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'stop_job signals nothing when the job\'s pid or group file was '
    'rewritten to 1 or 0',
    () async {
      final id = await start('echo ready; sleep 300');
      await outputWith(id, 'ready');
      final pidFile = File('$root/$id/pid');
      final groupFile = File('$root/$id/group');
      final realPid = pidFile.readAsStringSync();
      final realGroup = groupFile.readAsStringSync();
      void restore() {
        pidFile.writeAsStringSync(realPid);
        groupFile.writeAsStringSync(realGroup);
      }

      // A process of this account outside the job: `kill -- -1` would end
      // it along with everything else the account runs.
      final marker = await Process.start('sleep', ['300']);
      Future<bool> markerAlive() async =>
          (await Process.run('kill', ['-0', '${marker.pid}'])).exitCode == 0;
      try {
        for (final (pid, group) in [
          ('1', '1'),
          ('1', '0'),
          ('0', '0'),
          ('0', '1'),
        ]) {
          pidFile.writeAsStringSync('$pid\n');
          groupFile.writeAsStringSync('$group\n');
          // The guard first, through job_status, which only ever sends signal
          // 0: if it let these values through, the job would read as running
          // here, and stop_job (whose TERM to -1 would reach every process of
          // this account) is never called.
          final status = await call('job_status', {'job_id': id});
          if (status['state'] != 'unknown') {
            restore();
            fail('pid $pid group $group was taken as a job: $status');
          }
          final stopped = await call('stop_job', {'job_id': id});
          expect(stopped['state'], 'unknown', reason: 'pid $pid group $group');
          expect(stopped['stopped'], false);
          expect(stopped['stop'], BridgeJobs.stopRefusedText);
          expect(await markerAlive(), isTrue, reason: 'pid $pid group $group');
          expect(File('$root/$id/stopped').existsSync(), isFalse);
          expect(File('$root/$id/exit').existsSync(), isFalse);
        }
        restore();
        expect(await groupAlive(id), isTrue);
        final stopped = await call('stop_job', {'job_id': id});
        expect(stopped['state'], 'exited');
        expect(stopped.containsKey('stop'), isFalse);
        expect(await markerAlive(), isTrue);
      } finally {
        restore();
        marker.kill(ProcessSignal.sigkill);
        await marker.exitCode;
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'a job that ignores TERM is killed',
    () async {
      final id = await start("trap '' TERM; echo ready; sleep 300");
      await outputWith(id, 'ready');
      final stopped = await call('stop_job', {'job_id': id});
      expect(stopped['state'], 'exited');
      expect(stopped['exit_code'], 137);
      expect(await groupAlive(id), isFalse);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'output of a log with no trailing newline, binary bytes and a long line; '
    'remove_job then list_jobs',
    () async {
      final id = await start(
        r'''printf 'one\ntwo\377\000bin\n'; head -c 200000 /dev/zero | tr '\0' x; printf '\nlast no newline' ''',
      );
      await waitFor(id, 'exited');
      final out = await outputWith(id, 'last no newline');
      expect(out, endsWith('last no newline'));
      expect(out.length, lessThan(70 * 1024));

      await call('remove_job', {'job_id': id});
      final listed = await call('list_jobs', {'host': 'lab'});
      expect(
        (listed['jobs']! as List).map((j) => (j as Map)['job_id']),
        isNot(contains(id)),
      );
      final after = await tools.call(client, 'job_status', {'job_id': id});
      expect(after.isError, true);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'a job that ends while job_status runs is never reported unknown',
    () async {
      // Jobs ending at about the moment they are looked at: every answer is
      // running or exited, never unknown (the pid check and the exit file are
      // read at slightly different moments).
      final ids = [for (var i = 0; i < 8; i++) await start('sleep 1')];
      for (var round = 0; round < 30; round++) {
        for (final id in ids) {
          final s = await call('job_status', {'job_id': id});
          expect(s['state'], anyOf('running', 'exited'), reason: '$s');
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'a job that forks and exits is exited; stop of an ended job changes '
    'nothing',
    () async {
      final id = await start('sleep 2 & echo forked');
      final status = await waitFor(id, 'exited');
      expect(status['exit_code'], 0);
      final stopped = await call('stop_job', {'job_id': id});
      expect(stopped['state'], 'exited');
      expect(stopped['exit_code'], 0);
      expect(stopped['stopped'], false);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'the default place is ~/.cache/secureshellgo/jobs',
    () async {
      final home = Platform.environment['HOME']!;
      final base = Directory('$home/.cache/secureshellgo');
      final existed = base.existsSync();
      final jobsDir = Directory('${base.path}/jobs');
      final jobsExisted = jobsDir.existsSync();
      final plain = BridgeTools(
        loadHosts: () async => [lab.host],
        settings: () => const AppSettings(bridgeEnabled: true),
        isAppLocked: () => false,
        connections: BridgeConnections(
          openTransport: (_) => connection,
          credentialLookup: (_) async => null,
          dialer: (_, _) async => throw StateError('not used'),
        ),
        redactor: BridgeRedactor(scrub: (s) => s),
        audit: BridgeAuditLog(
          scrub: (s) => s,
          directory: Directory(lab.at('audit')),
        ),
        modules: [
          BridgeJobs(
            registry: BridgeJobRegistry(file: File(lab.at('plain_jobs.json'))),
            redactor: BridgeRedactor(scrub: (s) => s),
          ),
        ],
      );
      final body = await call('start_job', {
        'host': 'lab',
        'command': 'echo at home',
      }, via: plain);
      final id = body['job_id']! as String;
      final dir = Directory('${base.path}/jobs/$id');
      try {
        expect(dir.existsSync(), isTrue);
        expect(dir.statSync().mode & 0x1ff, 0x1c0);
        Map<String, Object?> s = {};
        for (var i = 0; i < 120 && s['state'] != 'exited'; i++) {
          s = await call('job_status', {'job_id': id}, via: plain);
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        expect(s['exit_code'], 0);
        await call('remove_job', {'job_id': id}, via: plain);
        expect(dir.existsSync(), isFalse);
      } finally {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
        if (!existed && base.existsSync()) {
          base.deleteSync(recursive: true);
        } else if (!jobsExisted && jobsDir.existsSync()) {
          jobsDir.deleteSync(recursive: true);
        }
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 1)),
  );
}

extension on Directory {
  String resolveSymbolicLinksSyncOrCreate() {
    createSync(recursive: true);
    return resolveSymbolicLinksSync();
  }
}

/// The same throwaway sshd as `bridge_local_sshd_test.dart`'s.
class _Lab {
  _Lab._(this.dir, this.port, this._sshd);

  final Directory dir;
  final int port;
  final Process _sshd;

  String at(String name) => '${dir.path}/$name';

  static Future<_Lab> start() async {
    final dir = await Directory.systemTemp.createTemp('ssgo-jobs-sshd');
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
    aiAccess: HostAiAccess.fullControl,
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
