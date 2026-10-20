import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/services/server_side_job.dart';

/// The job scripts are shell that runs on the user's server, so they are
/// tested by running them: under a real `sh`, with HOME pointed at a temp
/// folder and a stand-in `sftp` on PATH that records its arguments and
/// sleeps or exits as told.
void main() {
  late Directory home;
  late Directory bin;

  const destHost = Host(
    id: 'b',
    label: 'B',
    hostname: "o'brien.example",
    port: 2222,
    username: 'deploy',
    authMethod: SshAuthMethod.privateKey,
  );

  setUp(() async {
    home = await Directory.systemTemp.createTemp('ssg_job_home');
    bin = await Directory.systemTemp.createTemp('ssg_job_bin');
  });

  tearDown(() async {
    for (final d in [home, bin]) {
      if (await d.exists()) await d.delete(recursive: true);
    }
  });

  /// A stand-in `sftp`: echoes the first batch line as real sftp does once
  /// connected, records its arguments, then sleeps [seconds] and exits [code].
  Future<void> fakeSftp({int seconds = 0, int code = 0}) async {
    final script = File('${bin.path}/sftp');
    await script.writeAsString('''#!/bin/sh
for a in "\$@"; do echo "\$a"; done > "\$HOME/sftp-args"
batch=""
while [ \$# -gt 0 ]; do [ "\$1" = "-b" ] && batch="\$2"; shift; done
echo "sftp> \$(head -n 1 "\$batch")"
sleep $seconds
echo "Uploading done"
exit $code
''');
    await Process.run('chmod', ['+x', script.path]);
  }

  Future<ProcessResult> run(String command, {String stdin = ''}) async {
    final process = await Process.start(
      'sh',
      ['-c', command],
      environment: {
        'HOME': home.path,
        'PATH': '${bin.path}:${Platform.environment['PATH']}',
      },
    );
    process.stdin.write(stdin);
    await process.stdin.close();
    final out = await process.stdout.transform(const SystemEncoding().decoder).join();
    final err = await process.stderr.transform(const SystemEncoding().decoder).join();
    return ProcessResult(process.pid, await process.exitCode, out, err);
  }

  Future<ServerJobStatus> status(String id) async =>
      ServerSideJob.parseStatus((await run(ServerSideJob.statusCommand(id))).stdout as String);

  Future<ServerJobStatus> waitFinished(String id) async {
    for (var i = 0; i < 100; i++) {
      final s = await status(id);
      if (s.state != ServerJobState.running) return s;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    fail('job $id never finished');
  }

  final skip = Platform.isWindows ? 'POSIX shell only' : null;

  test('launch writes the job folder, starts sftp detached and reports it',
      () async {
    await fakeSftp(seconds: 1);
    final id = ServerSideJob.newId(Random(7));
    final launched = await run(
      ServerSideJob.launchCommand(
        jobId: id,
        destHost: destHost,
        pinnedKnownHosts: const ["[o'brien.example]:2222 ssh-ed25519 AAAA"],
      ),
      stdin: 'progress\nput "a" "b"\nbye\n',
    );
    expect(launched.exitCode, 0, reason: launched.stderr as String);
    expect(
      (launched.stdout as String).trim(),
      ServerSideJob.startedMarker,
    );

    final dir = Directory('${home.path}/.cache/secureshellgo/jobs/$id');
    expect(File('${dir.path}/batch').readAsStringSync(),
        'progress\nput "a" "b"\nbye\n');
    expect(File('${dir.path}/kh').readAsStringSync(),
        "[o'brien.example]:2222 ssh-ed25519 AAAA\n");
    expect(dir.statSync().mode & 0x1ff, 0x1c0, reason: 'job folder is 0700');

    // The launch has returned — the exec that started it is gone — and the
    // job is still running on its own.
    expect((await status(id)).state, ServerJobState.running);

    final done = await waitFinished(id);
    expect(done.state, ServerJobState.finished);
    expect(done.exitCode, 0);
    expect(done.log, contains('Uploading done'));

    final args = File('${home.path}/sftp-args').readAsLinesSync();
    expect(args, containsAllInOrder(['-P', '2222']));
    expect(args, contains('StrictHostKeyChecking=yes'));
    expect(args, contains('UserKnownHostsFile=${dir.path}/kh'));
    expect(args, contains('GlobalKnownHostsFile=/dev/null'));
    expect(args.last, "deploy@o'brien.example");
  }, skip: skip);

  test('a failing sftp is reported with its exit code and log', () async {
    await fakeSftp(code: 1);
    final id = ServerSideJob.newId(Random(8));
    await run(
      ServerSideJob.launchCommand(
        jobId: id,
        destHost: destHost,
        pinnedKnownHosts: const ['h ssh-ed25519 AAAA'],
      ),
      stdin: 'bye\n',
    );
    final done = await waitFinished(id);
    expect(done.exitCode, 1);
    expect(done.log, contains('sftp> bye'));
  }, skip: skip);

  test('cancel stops a running job and removes its folder', () async {
    await fakeSftp(seconds: 53);
    final id = ServerSideJob.newId(Random(9));
    await run(
      ServerSideJob.launchCommand(
        jobId: id,
        destHost: destHost,
        pinnedKnownHosts: const ['h ssh-ed25519 AAAA'],
      ),
      stdin: 'bye\n',
    );
    expect((await status(id)).state, ServerJobState.running);
    final pid = File('${home.path}/.cache/secureshellgo/jobs/$id/pid')
        .readAsStringSync()
        .trim();

    await run(ServerSideJob.cancelCommand(id));

    expect(
      Directory('${home.path}/.cache/secureshellgo/jobs/$id').existsSync(),
      isFalse,
    );
    // Neither the runner nor its sftp survives.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final alive = await Process.run('sh', ['-c', 'kill -0 $pid']);
    expect(alive.exitCode, isNot(0));
    final sleeper = await Process.run('pgrep', ['-f', 'sleep 5[3]']);
    expect((sleeper.stdout as String).trim(), isEmpty);
  }, skip: skip);

  test('a job whose runner is gone without an exit reads as gone', () async {
    final id = ServerSideJob.newId(Random(10));
    final dir = Directory('${home.path}/.cache/secureshellgo/jobs/$id')
      ..createSync(recursive: true);
    File('${dir.path}/pid').writeAsStringSync('999999\n');
    expect((await status(id)).state, ServerJobState.gone);
  }, skip: skip);

  test('only hex job ids reach the shell', () {
    expect(
      () => ServerSideJob.statusCommand(r'x"; rm -rf ~; "'),
      throwsArgumentError,
    );
    expect(ServerSideJob.newId(), matches(RegExp(r'^[0-9a-f]{32}$')));
  });

  group('ServerJobStore', () {
    test('records survive a reload and can be removed', () async {
      final file = File('${home.path}/server_jobs.json');
      final record = ServerJobRecord(
        jobId: ServerSideJob.newId(Random(1)),
        stamp: 1738000000000,
        sourceHostId: 'a',
        sourceLabel: 'A',
        destinationHostId: 'b',
        destinationLabel: 'B',
        sourcePath: '/data/big.iso',
        destinationPath: '/srv/big.iso',
        name: 'big.iso',
        isDirectory: false,
        moveSource: true,
        overwrite: false,
        startedAt: DateTime(2026, 10, 21, 9),
        totalBytes: 42,
      );
      await ServerJobStore(file: file).save(record);

      final reloaded = await ServerJobStore(file: file).all();
      expect(reloaded.single.jobId, record.jobId);
      expect(reloaded.single.moveSource, isTrue);
      expect(reloaded.single.totalBytes, 42);

      final store = ServerJobStore(file: file);
      await store.remove(record.jobId);
      expect(await ServerJobStore(file: file).all(), isEmpty);
    });
  });
}
