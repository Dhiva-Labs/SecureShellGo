import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/services/fleet_exec_service.dart';
import 'package:secure_shell_go/services/ssh_service.dart';

import 'fake_exec_session.dart';

/// A command that runs until the test says it has exited — or until it is
/// killed or its channel closed, which is what stopping a run does.
class _HeldSession extends FakeExecSession {
  _HeldSession({super.stdout, super.stderrText, super.exitCode});

  final Completer<int?> _exit = Completer<int?>();
  var killed = false;

  void exit() {
    if (!_exit.isCompleted) _exit.complete(exitCode);
  }

  @override
  Future<int?> waitForExit({Duration? timeout}) => _exit.future;

  @override
  void kill(SSHSignal signal) {
    killed = true;
    if (!_exit.isCompleted) _exit.complete(null);
  }

  @override
  void close() {
    super.close();
    if (!_exit.isCompleted) _exit.complete(null);
  }
}

Host _host(
  String id, {
  SshAuthMethod auth = SshAuthMethod.password,
  String? group,
}) =>
    Host(
      id: id,
      label: 'Host $id',
      hostname: '$id.example.test',
      port: 22,
      username: 'ops',
      authMethod: auth,
      group: group,
    );

const _password = SshCredentials(password: 'hunter2');

/// One fake server per host, each recording what it was asked to run.
class _Fleet {
  _Fleet(this.hosts, {this.hold = false});

  final List<Host> hosts;
  final bool hold;
  final Map<String, FakeExecTransport> transports = {};
  final Map<String, _HeldSession> held = {};
  final List<String> dialled = [];

  /// The most hosts ever connecting or running at once.
  var maxInFlight = 0;

  /// Per host: what its command prints and exits with.
  final Map<String, (String, String, int)> script = {};

  /// Per host: the dial throws this.
  final Map<String, Object> dialFails = {};

  final Map<String, SshCredentials?> saved = {};

  Future<SshCredentials?> credentials(String id) async =>
      saved.containsKey(id) ? saved[id] : _password;

  Future<SessionTransport> dial(Host host, SshCredentials creds) async {
    dialled.add(host.id);
    final failure = dialFails[host.id];
    if (failure != null) throw failure;
    await Future<void>.delayed(Duration.zero);
    return transports.putIfAbsent(host.id, () => _transportFor(host));
  }

  FakeExecTransport _transportFor(Host host) => FakeExecTransport(
        host: host,
        respond: (_) {
          final (out, err, code) = script[host.id] ?? ('ok ${host.id}\n', '', 0);
          if (hold) {
            return held[host.id] =
                _HeldSession(stdout: out, stderrText: err, exitCode: code);
          }
          return FakeExecSession(stdout: out, stderrText: err, exitCode: code);
        },
      );

  FleetExecService service(
    String command, {
    FleetExecOpenTransport? open,
    DateTime Function()? clock,
    int maxOutputChars = FleetExecService.defaultMaxOutputChars,
  }) {
    final service = FleetExecService(
      hosts: hosts,
      command: command,
      openTransport: open ?? (_) => null,
      credentialLookup: credentials,
      dialer: dial,
      stopGrace: const Duration(milliseconds: 20),
      clock: clock,
      maxOutputChars: maxOutputChars,
    );
    service.changes.listen((runs) {
      final inFlight = runs
          .where((r) =>
              r.status == FleetExecStatus.connecting ||
              r.status == FleetExecStatus.running)
          .length;
      if (inFlight > maxInFlight) maxInFlight = inFlight;
    });
    return service;
  }
}

void main() {
  group('a run', () {
    test('every host runs the wrapped command; output and exit kept', () async {
      final fleet = _Fleet([_host('a'), _host('b'), _host('c')]);
      fleet.script['b'] = ('half\n', 'boom\n', 2);
      var tick = 0;
      final service = fleet.service(
        'uptime',
        clock: () => DateTime(2026, 1, 1, 0, 0, tick++),
      );
      service.start();
      await service.done;

      final a = service.runFor('a')!;
      expect(a.status, FleetExecStatus.succeeded);
      expect(a.exitCode, 0);
      expect(a.output, 'ok a\n');
      expect(a.duration, isNotNull);
      expect(a.duration! > Duration.zero, isTrue);

      final b = service.runFor('b')!;
      expect(b.status, FleetExecStatus.failed);
      expect(b.exitCode, 2);
      expect(b.chunks.map((c) => (c.text, c.isError)),
          containsAll([('half\n', false), ('boom\n', true)]));

      expect(service.summary, '2 succeeded · 1 failed');
      expect(service.failedHosts.map((r) => r.hostId), ['b']);
      for (final t in fleet.transports.values) {
        expect(t.commands.single, FleetExecService.wrap('uptime'));
        expect(t.closed, isTrue, reason: 'a dialled connection is hung up');
        expect(t.sessions.single.wasClosed, isTrue);
      }
    });

    test('never more than three hosts at once', () async {
      final hosts = [for (var i = 0; i < 8; i++) _host('h$i')];
      final fleet = _Fleet(hosts, hold: true);
      final service = fleet.service('sleep 1');
      service.start();
      for (var round = 0; round < 20 && service.isRunning; round++) {
        await pumpEventQueue();
        final running = fleet.held.values.where((s) => !s.wasClosed).toList();
        expect(running.length, lessThanOrEqualTo(3));
        if (running.isNotEmpty) running.first.exit();
      }
      await service.done;
      expect(fleet.maxInFlight, 3);
      expect(service.countOf(FleetExecStatus.succeeded), 8);
    });

    test('an open session is used, not dialled, and not hung up', () async {
      final fleet = _Fleet([_host('a'), _host('b')]);
      final open = FakeExecTransport(host: _host('a'));
      final service = fleet.service('id', open: (id) => id == 'a' ? open : null);
      service.start();
      await service.done;
      expect(fleet.dialled, ['b']);
      expect(open.commands.single, FleetExecService.wrap('id'));
      expect(open.closed, isFalse);
      expect(service.runFor('a')!.usedOpenSession, isTrue);
      expect(service.runFor('a')!.status, FleetExecStatus.succeeded);
    });

    test('a closed session is passed over for a dial of its own', () async {
      final fleet = _Fleet([_host('a')]);
      final open = FakeExecTransport(host: _host('a'))..closed = true;
      final service = fleet.service('id', open: (_) => open);
      service.start();
      await service.done;
      expect(fleet.dialled, ['a']);
      expect(open.commands, isEmpty);
    });

    test('output past the cap drops the oldest and says so', () async {
      final fleet = _Fleet([_host('a')]);
      fleet.script['a'] = ('${'x' * 50}END', '', 0);
      final service = fleet.service('yes', maxOutputChars: 10);
      service.start();
      await service.done;
      final run = service.runFor('a')!;
      expect(run.output, 'xxxxxxxEND');
      expect(run.truncated, isTrue);
    });

    test('a channel that will not open is an error, not a failure', () async {
      final fleet = _Fleet([_host('a')]);
      fleet.transports['a'] = FakeExecTransport(host: _host('a'))
        ..failWith = const SshConnectionException('channel refused');
      final service = fleet.service('id');
      service.start();
      await service.done;
      final run = service.runFor('a')!;
      expect(run.status, FleetExecStatus.error);
      expect(run.message, contains('channel refused'));
      expect(service.failedHosts, [run]);
    });
  });

  group('sign-in that needs a person is skipped, never waited on', () {
    test('no saved password', () async {
      final fleet = _Fleet([_host('a'), _host('b')]);
      fleet.saved['a'] = null;
      fleet.saved['b'] = const SshCredentials(password: '');
      final service = fleet.service('id');
      service.start();
      await service.done;
      expect(fleet.dialled, isEmpty);
      for (final id in ['a', 'b']) {
        expect(service.runFor(id)!.status, FleetExecStatus.skipped);
        expect(service.runFor(id)!.message, contains('No saved password'));
      }
      expect(service.summary, '2 skipped');
    });

    test('a key with no saved key, or no saved passphrase', () async {
      expect(
        FleetExecService.signInProblem(
          _host('k', auth: SshAuthMethod.privateKey),
          const SshCredentials(),
        ),
        contains('No saved private key'),
      );
      final dir = await Directory.systemTemp.createTemp('ssg_key');
      addTearDown(() => dir.delete(recursive: true));
      final made = await Process.run('ssh-keygen',
          ['-q', '-t', 'ed25519', '-N', 'secret', '-f', '${dir.path}/k']);
      expect(made.exitCode, 0);
      final pem = File('${dir.path}/k').readAsStringSync();
      final host = _host('k', auth: SshAuthMethod.privateKey);
      expect(
        FleetExecService.signInProblem(host, SshCredentials(privateKeyPem: pem)),
        contains('passphrase'),
      );
      expect(
        FleetExecService.signInProblem(
          host,
          SshCredentials(privateKeyPem: pem, passphrase: 'secret'),
        ),
        isNull,
      );
    }, skip: Process.runSync('sh', ['-c', 'command -v ssh-keygen']).exitCode != 0);

    test('agent sign-in needs nothing saved', () {
      expect(
        FleetExecService.signInProblem(_host('g', auth: SshAuthMethod.agent), null),
        isNull,
      );
    });

    test('a one-time code or an unchecked host key, found while dialling',
        () async {
      final fleet = _Fleet([_host('a'), _host('b'), _host('c')]);
      fleet.dialFails['a'] = const FleetSignInNeedsPerson(
        'Asks "Verification code" at login.',
      );
      fleet.dialFails['b'] = const SshConnectionException('No route to host');
      final service = fleet.service('id');
      service.start();
      await service.done;
      expect(service.runFor('a')!.status, FleetExecStatus.skipped);
      expect(service.runFor('a')!.message, contains('Verification code'));
      expect(service.runFor('b')!.status, FleetExecStatus.error);
      expect(service.runFor('b')!.message, 'No route to host');
      expect(service.runFor('c')!.status, FleetExecStatus.succeeded);
    });
  });

  group('stopping', () {
    test('cancel stops what runs and starts nothing more', () async {
      final hosts = [for (var i = 0; i < 5; i++) _host('h$i')];
      final fleet = _Fleet(hosts, hold: true);
      final service = fleet.service('sleep 100');
      service.start();
      await pumpEventQueue();
      expect(fleet.held, hasLength(3));
      service.cancel();
      await service.done.timeout(const Duration(seconds: 2));

      for (final session in fleet.held.values) {
        expect(session.stdinClosed, isTrue,
            reason: 'closing stdin is what the wrapper kills on');
        expect(session.killed, isTrue);
      }
      expect(fleet.dialled, ['h0', 'h1', 'h2']);
      expect(service.countOf(FleetExecStatus.cancelled), 5);
      expect(service.isRunning, isFalse);
    });

    test('one host can be stopped alone', () async {
      final fleet = _Fleet([_host('a'), _host('b')], hold: true);
      final service = fleet.service('sleep 100');
      service.start();
      await pumpEventQueue();
      service.cancelHost('a');
      await pumpEventQueue();
      fleet.held['b']!.exit();
      await service.done.timeout(const Duration(seconds: 2));
      expect(service.runFor('a')!.status, FleetExecStatus.cancelled);
      expect(service.runFor('b')!.status, FleetExecStatus.succeeded);
    });

    test('a channel that ignores both is closed after the grace', () async {
      final fleet = _Fleet([_host('a')], hold: true);
      final service = fleet.service('sleep 100');
      service.start();
      await pumpEventQueue();
      final session = fleet.held['a']!;
      // A server that takes no signal requests: kill does nothing.
      session.killed = false;
      service.cancel();
      await service.done.timeout(const Duration(seconds: 2));
      expect(session.wasClosed, isTrue);
    });
  });

  group('re-run', () {
    test('only the hosts asked for, and only once they have finished', () async {
      final fleet = _Fleet([_host('a'), _host('b'), _host('c')]);
      fleet.script['b'] = ('', 'nope\n', 1);
      fleet.dialFails['c'] = const SshConnectionException('refused');
      final service = fleet.service('deploy');
      service.start();
      await service.done;
      expect(service.failedHosts.map((r) => r.hostId), ['b', 'c']);

      fleet.script['b'] = ('fixed\n', '', 0);
      fleet.dialFails.remove('c');
      service.rerun(service.failedHosts.map((r) => r.hostId));
      expect(service.runFor('b')!.output, isEmpty, reason: 'reset for the re-run');
      await service.done;
      expect(service.runFor('a')!.status, FleetExecStatus.succeeded);
      expect(service.runFor('b')!.status, FleetExecStatus.succeeded);
      expect(service.runFor('b')!.output, 'fixed\n');
      expect(service.runFor('c')!.status, FleetExecStatus.succeeded);
      expect(fleet.transports['a']!.commands, hasLength(1));
      expect(fleet.transports['b']!.commands, hasLength(2));
    });
  });

  group('the wrapper, through a real shell', () {
    Future<Process> start(String command, {Map<String, String>? env}) =>
        Process.start('sh', ['-c', FleetExecService.wrap(command)],
            environment: {'SHELL': '/bin/sh', ...?env});

    test('quoting holds and the exit status comes through', () async {
      final dir = await Directory.systemTemp.createTemp('ssg_fleet');
      addTearDown(() => dir.delete(recursive: true));
      final process = await start(
        "printf '%s\\n' \"it's\" '\$(touch ${dir.path}/PWNED)'; echo err >&2; exit 3",
      );
      final out = StringBuffer();
      final err = StringBuffer();
      final reading = Future.wait([
        process.stdout.transform(const SystemEncoding().decoder).forEach(out.write),
        process.stderr.transform(const SystemEncoding().decoder).forEach(err.write),
      ]);
      final code = await process.exitCode.timeout(const Duration(seconds: 5));
      await reading;
      await process.stdin.close();
      expect(code, 3);
      expect(out.toString(), "it's\n\$(touch ${dir.path}/PWNED)\n");
      expect(err.toString(), 'err\n');
      expect(File('${dir.path}/PWNED').existsSync(), isFalse);
    });

    test('the command gets no stdin', () async {
      final process = await start('cat; echo done');
      final out = process.stdout.transform(const SystemEncoding().decoder).join();
      final code = await process.exitCode.timeout(const Duration(seconds: 5));
      expect(code, 0);
      expect(await out, 'done\n');
      await process.stdin.close();
    });

    test('closing stdin kills the command and what it started', () async {
      final dir = await Directory.systemTemp.createTemp('ssg_fleet');
      addTearDown(() => dir.delete(recursive: true));
      final pidFile = '${dir.path}/child';
      // setsid puts the wrapper in a process group of its own, the way sshd
      // does for each exec — so `kill 0` reaches only what it started.
      final process = await Process.start('setsid', [
        'sh',
        '-c',
        FleetExecService.wrap('sleep 60 & echo \$! > $pidFile; wait'),
      ], environment: {'SHELL': '/bin/sh'});
      unawaited(process.stdout.drain<void>());
      unawaited(process.stderr.drain<void>());
      for (var i = 0; i < 50 && !File(pidFile).existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final child = File(pidFile).readAsStringSync().trim();
      await process.stdin.close();
      await process.exitCode.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(Process.runSync('kill', ['-0', child]).exitCode, isNot(0),
          reason: 'the background sleep survived');
    }, skip: Process.runSync('sh', ['-c', 'command -v setsid']).exitCode != 0);

    test('a command that ends by itself leaves what it daemonised', () async {
      final dir = await Directory.systemTemp.createTemp('ssg_fleet');
      final pidFile = '${dir.path}/daemon';
      final process = await Process.start('setsid', [
        'sh',
        '-c',
        FleetExecService.wrap(
            'nohup sleep 5 >/dev/null 2>&1 & echo \$! > $pidFile'),
      ], environment: {'SHELL': '/bin/sh'});
      unawaited(process.stdout.drain<void>());
      unawaited(process.stderr.drain<void>());
      expect(await process.exitCode.timeout(const Duration(seconds: 5)), 0);
      await process.stdin.close();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final daemon = File(pidFile).readAsStringSync().trim();
      expect(Process.runSync('kill', ['-0', daemon]).exitCode, 0);
      Process.runSync('kill', [daemon]);
      await dir.delete(recursive: true);
    }, skip: Process.runSync('sh', ['-c', 'command -v setsid']).exitCode != 0);
  }, skip: !(Platform.isLinux || Platform.isMacOS));
}
