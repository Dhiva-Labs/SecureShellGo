import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/app_settings.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/models/host_ai_access.dart';
import 'package:secure_shell_go/services/bridge/bridge_approvals.dart';
import 'package:secure_shell_go/services/bridge/bridge_audit.dart';
import 'package:secure_shell_go/services/bridge/bridge_client_store.dart';
import 'package:secure_shell_go/services/bridge/bridge_control.dart';
import 'package:secure_shell_go/services/bridge/bridge_control_protocol.dart';
import 'package:secure_shell_go/services/bridge/bridge_grants.dart';
import 'package:secure_shell_go/services/bridge/bridge_jobs.dart';
import 'package:secure_shell_go/services/bridge/bridge_policy.dart';
import 'package:secure_shell_go/services/bridge/bridge_redactor.dart';
import 'package:secure_shell_go/services/bridge/bridge_tools.dart';
import 'package:secure_shell_go/widgets/bridge_approval_card.dart';

import 'fake_exec_session.dart';
import 'support/bridge_fakes.dart';
import 'support/bridge_temp_dir.dart';

// The long-running job tools against a fake server that understands the job
// scripts' `set --` line: policy paths, the card, ownership, limits, the
// registry and its pruning, argument checks. The scripts themselves run on a
// real server in bridge_jobs_sshd_test.dart.

/// The words of the `set -- ...` line every job script starts with, as sh
/// reads them (each word single-quoted by `posixSingleQuote`).
List<String> setWords(String script) {
  expect(script, startsWith('set -- '));
  final words = <String>[];
  // A quoted word may hold line breaks (the runner's text does); the line
  // ends at the first line break outside quotes.
  final text = script.substring('set -- '.length);
  var i = 0;
  var word = StringBuffer();
  var inWord = false;
  while (i < text.length) {
    final c = text[i];
    if (c == "'") {
      final end = text.indexOf("'", i + 1);
      word.write(text.substring(i + 1, end));
      inWord = true;
      i = end + 1;
    } else if (c == r'\') {
      word.write(text[i + 1]);
      inWord = true;
      i += 2;
    } else if (c == '\n') {
      break;
    } else if (c == ' ') {
      if (inWord) words.add(word.toString());
      word = StringBuffer();
      inWord = false;
      i++;
    } else {
      fail('unexpected character $c in the set line');
    }
  }
  if (inWord) words.add(word.toString());
  return words;
}

class _FakeJob {
  _FakeJob(this.command, this.cwd);

  final String command;
  final String? cwd;
  String state = 'running';
  int? exit;
  bool stopped = false;
  String log = '';

  /// The job's pid or group file holds something the stop script refuses.
  bool badTarget = false;
}

/// A server that keeps jobs in memory and answers the job scripts.
class _JobServer {
  final Map<String, _FakeJob> jobs = {};
  final List<String> scripts = [];

  FakeExecSession respond(String script) {
    scripts.add(script);
    final w = setWords(script);
    if (script.contains('ssg-job-started')) {
      final id = w[1];
      if (w[3] == '1' && w[4] == '/nope') {
        return FakeExecSession(stderrText: 'cannot enter', exitCode: 72);
      }
      jobs[id] = _FakeJob(w[2], w[3] == '1' ? w[4] : null);
      return FakeExecSession(stdout: 'ssg-job-started $id\n');
    }
    if (script.contains('removed missing')) {
      final job = jobs[w[1]];
      if (job == null) return FakeExecSession(stdout: 'removed missing\n');
      if (job.state == 'running') {
        return FakeExecSession(stdout: 'removed no\n');
      }
      jobs.remove(w[1]);
      return FakeExecSession(stdout: 'removed yes\n');
    }
    if (script.contains('tail -c')) {
      final job = jobs[w[1]];
      if (job == null) return FakeExecSession(stdout: 'state missing\n');
      return FakeExecSession(
        stdout: 'log ${utf8.encode(job.log).length}\n--\n${job.log}',
      );
    }
    if (script.contains('kill -s TERM')) {
      final job = jobs[w[1]];
      if (job != null && job.badTarget) {
        job.state = 'unknown';
        return FakeExecSession(
          stdout: '${BridgeJobCommands.stopRefusedMarker}\nnow 2000\n'
              '${_block(w[1])}',
        );
      }
      if (job != null && job.state == 'running') {
        job
          ..state = 'exited'
          ..exit = 143
          ..stopped = true;
      }
      return FakeExecSession(stdout: 'now 2000\n${_block(w[1])}');
    }
    // status
    final out = StringBuffer('now 2000\n');
    for (final id in w.skip(1)) {
      out.write(_block(id));
    }
    return FakeExecSession(stdout: out.toString());
  }

  String _block(String id) {
    final job = jobs[id];
    if (job == null) return 'job $id\nstate missing\n';
    return 'job $id\nstarted 1000\n'
        '${job.stopped ? 'stopped 1\n' : ''}'
        'log ${job.log.length}\n'
        '${job.exit == null ? '' : 'exit ${job.exit} 1900\n'}'
        'state ${job.state}\n';
  }
}

final BridgeClient _other = BridgeClient(
  id: 'c9',
  name: 'Other assistant',
  tokenHash: 'q',
  createdAt: DateTime.utc(2026),
);

void main() {
  late Directory temp;
  late BridgeToolsRig rig;
  late BridgeApprovals approvals;
  late BridgeGrants grants;
  late BridgeJobRegistry registry;
  late BridgeJobs jobs;
  late _JobServer server;

  Host host(String id, String label, HostAiAccess access) =>
      bridgeHost(id, label, access: access);

  setUp(() async {
    temp = await bridgeTempDir('bridge_jobs');
    approvals = BridgeApprovals(timedApprovalMinutes: () => 10);
    grants = BridgeGrants();
    registry = BridgeJobRegistry(file: File('${temp.path}/bridge_jobs.json'));
    jobs = BridgeJobs(
      registry: registry,
      redactor: BridgeRedactor(
        scrub: (s) => s.replaceAll('SECRET', '[redacted]'),
      ),
    );
    rig = BridgeToolsRig(
      temp,
      scrub: (s) => s.replaceAll('SECRET', '[redacted]'),
      approvals: approvals,
      grants: grants,
      modules: [jobs],
    );
    rig.hosts = [
      host('ro1', 'ro', HostAiAccess.readOnly),
      host('ask1', 'ask', HostAiAccess.askToChange),
      host('full1', 'full', HostAiAccess.fullControl),
      host('off1', 'secret', HostAiAccess.off),
    ];
    server = _JobServer();
    for (final id in ['ro1', 'ask1', 'full1']) {
      rig.serve(id, server.respond);
    }
  });

  tearDown(() async {
    await approvals.dispose();
    await grants.dispose();
    await rig.connections.closeAll();
    await deleteTempDir(temp);
  });

  Future<BridgeApprovalRequest> card() async {
    for (var i = 0; i < 400; i++) {
      if (approvals.current.isNotEmpty) return approvals.current.last;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('no approval card appeared');
  }

  /// Starts a job on the full-control host (no card) and returns its id.
  Future<String> startFull([
    BridgeClient? client,
    Map<String, Object?> extra = const {},
  ]) async {
    final r = await rig.call('start_job', {
      'host': 'full',
      'command': 'npm run dev',
      ...extra,
    }, client);
    expect(r.isError, false, reason: r.text);
    return (jsonDecode(r.text) as Map)['job_id'] as String;
  }

  group('start_job and the policy', () {
    test('a read-only host refuses it, with no card and nothing run', () async {
      final r = await rig.call('start_job', {'host': 'ro', 'command': 'x'});
      expect(r.text, BridgeRefusals.changesNotAllowed.message);
      expect(approvals.current, isEmpty);
      expect(server.scripts, isEmpty);
      expect(await registry.all(), isEmpty);
      final hidden = await rig.call('start_job', {
        'host': 'secret',
        'command': 'x',
      });
      expect(hidden.text, BridgeRefusals.hostNotAvailable.message);
    });

    test('ask before each change: the card shows the command, the folder and '
        'the name; a no runs nothing', () async {
      final asked = rig.call('start_job', {
        'host': 'ask',
        'command': "npm run dev -- --port '8080'",
        'cwd': '~/my app',
        'name': 'dev server',
      });
      final c = await card();
      expect(c.tool, 'start_job');
      final s = c.summary as JobStartSummary;
      expect(s.command, "npm run dev -- --port '8080'");
      expect(s.cwd, '~/my app');
      expect(s.name, 'dev server');
      approvals.answer(c.id, BridgeApprovalAnswer.deny);
      final r = await asked;
      expect(r.text, BridgeToolRefusals.denied.message);
      expect(server.scripts, isEmpty);
      expect(await registry.all(), isEmpty);
      expect(rig.entries.last.approval, BridgeAuditApproval.denied);
    });

    test('a yes starts it, records it, and audits the command', () async {
      final asked = rig.call('start_job', {
        'host': 'ask',
        'command': 'python3 -m http.server password=SECRET',
        'cwd': '~/my app',
        'name': 'web',
      });
      approvals.answer((await card()).id, BridgeApprovalAnswer.allowOnce);
      final r = await asked;
      expect(r.isError, false, reason: r.text);
      final body = jsonDecode(r.text) as Map;
      final id = body['job_id'] as String;
      expect(BridgeJobs.isJobId(id), isTrue);
      expect(body['name'], 'web');
      expect(body['log'], '~/.cache/secureshellgo/jobs/$id/log');
      // The command reached the server as data, exactly, and the folder
      // without its "~/" (the job starts in the home directory).
      final w = setWords(server.scripts.single);
      expect(w[1], id);
      expect(w[2], 'python3 -m http.server password=SECRET');
      expect(w[3], '1');
      expect(w[4], 'my app');
      final job = (await registry.all()).single;
      expect(job.id, id);
      expect(job.clientId, testBridgeClient.id);
      expect(job.hostId, 'ask1');
      expect(job.name, 'web');
      final entry = rig.entries.last;
      expect(entry.tool, 'start_job');
      expect(entry.host, 'ask');
      expect(entry.approval, BridgeAuditApproval.once);
      expect(entry.args, contains('python3 -m http.server'));
      expect(rig.entries, hasLength(1));
    });

    test('the command is kept scrubbed in the registry and in what the read '
        'tools return; the server gets it whole', () async {
      final id = await startFull(null, {
        'command': 'deploy --password=SECRET --verbose',
      });
      expect(
        setWords(server.scripts.single)[2],
        'deploy --password=SECRET --verbose',
      );
      final onDisk = File('${temp.path}/bridge_jobs.json').readAsStringSync();
      expect(onDisk, isNot(contains('SECRET')));
      expect(onDisk, contains('deploy --password=[redacted] --verbose'));
      final status = jsonDecode(
        (await rig.call('job_status', {'job_id': id})).text,
      ) as Map;
      expect(status['command'], 'deploy --password=[redacted] --verbose');
      final listed = jsonDecode(
        (await rig.call('list_jobs', {'host': 'full'})).text,
      ) as Map;
      expect(
        ((listed['jobs'] as List).single as Map)['command'],
        'deploy --password=[redacted] --verbose',
      );
    });

    test('a secret across the 500 character cut is scrubbed whole first',
        () async {
      final command = '${'x' * 495} SECRET';
      final id = await startFull(null, {'command': command});
      final job = (await registry.find(testBridgeClient.id, id))!;
      expect(job.command, isNot(contains('SEC')));
      expect(job.command.length, lessThanOrEqualTo(501));
    });

    test('full control starts it with no card', () async {
      await startFull();
      expect(approvals.current, isEmpty);
      expect(rig.entries.last.approval, BridgeAuditApproval.fullControl);
    });

    test('an allowed command never starts a job without a card', () async {
      rig.hosts = [
        for (final h in rig.hosts)
          h.id == 'ask1' ? h.copyWith(aiAllowedCommands: ['uptime']) : h,
      ];
      final asked = rig.call('start_job', {'host': 'ask', 'command': 'uptime'});
      final c = await card();
      approvals.answer(c.id, BridgeApprovalAnswer.deny);
      await asked;
      expect(server.scripts, isEmpty);
    });

    test('a live time-limited approval starts it with no card', () async {
      grants.grant(
        testBridgeClient.id,
        'ask1',
        const Duration(minutes: 5),
        clientName: testBridgeClient.name,
      );
      final r = await rig.call('start_job', {'host': 'ask', 'command': 'x'});
      expect(r.isError, false, reason: r.text);
      expect(approvals.current, isEmpty);
      expect(rig.entries.last.approval, BridgeAuditApproval.grant);
    });

    test(
      'a folder that cannot be entered starts nothing and is forgotten',
      () async {
        final r = await rig.call('start_job', {
          'host': 'full',
          'command': 'x',
          'cwd': '/nope',
        });
        expect(r.isError, true);
        expect(r.text, contains('cannot be entered'));
        expect(await registry.all(), isEmpty);
      },
    );

    test('bad arguments are refused before any card', () async {
      for (final args in <Map<String, Object?>>[
        {'command': 'x' * 5000},
        {'command': '   '},
        {'command': 'a\u0000b'},
        {'command': 'x', 'name': 'bad\u001bname'},
        {'command': 'x', 'name': 'n' * 65},
        {'command': 'x', 'cwd': 'a\nb'},
        {'command': 'x', 'cwd': '~bob/x'},
        {'command': 'x', 'extra': 1},
      ]) {
        final r = await rig.call('start_job', {'host': 'ask', ...args});
        expect(r.isError, true, reason: '$args');
        expect(rig.entries.last.detail, 'invalid_arguments', reason: '$args');
      }
      expect(approvals.current, isEmpty);
      expect(server.scripts, isEmpty);
    });

    test('at most 20 jobs per host per client; another client is not '
        'counted', () async {
      final h = rig.hosts.firstWhere((h) => h.id == 'full1');
      for (var i = 0; i < BridgeJobs.maxJobsPerHost; i++) {
        await registry.add(
          BridgeJobRecord.on(
            h,
            id: 'job${i.toString().padLeft(13, '0')}',
            clientId: testBridgeClient.id,
            hostName: 'full',
            startedAt: DateTime.utc(2026),
          ),
        );
      }
      final r = await rig.call('start_job', {'host': 'full', 'command': 'x'});
      expect(r.isError, true);
      expect(r.text, BridgeJobs.jobLimit.message);
      expect(rig.entries.last.detail, 'job_limit');
      expect(server.scripts, isEmpty);
      // The other client still may.
      await startFull(_other);
    });
  });

  group('the read tools', () {
    test('list_jobs lists only the caller\'s own jobs on that host', () async {
      final mine = await startFull();
      final theirs = await startFull(_other);
      final r = await rig.call('list_jobs', {'host': 'full'});
      expect(r.isError, false, reason: r.text);
      final listed = (jsonDecode(r.text) as Map)['jobs'] as List;
      expect(listed, hasLength(1));
      expect((listed.single as Map)['job_id'], mine);
      expect((listed.single as Map)['state'], 'running');
      expect((listed.single as Map)['age_seconds'], 1000);
      expect(r.text, isNot(contains(theirs)));
      expect(rig.entries.last.host, 'full');
    });

    test('list_jobs follows read access', () async {
      expect(
        (await rig.call('list_jobs', {'host': 'secret'})).text,
        BridgeRefusals.hostNotAvailable.message,
      );
      final ro = await rig.call('list_jobs', {'host': 'ro'});
      expect(ro.isError, false);
      expect(ro.text, '{"jobs":[]}');
    });

    test('job_status and job_output of the caller\'s job', () async {
      final id = await startFull(null, {'name': 'dev'});
      server.jobs[id]!.log = 'line 1\ntoken: SECRET\n';
      final s = await rig.call('job_status', {'job_id': id});
      expect(s.isError, false, reason: s.text);
      final status = jsonDecode(s.text) as Map;
      expect(status['state'], 'running');
      expect(status['name'], 'dev');
      expect(status['host'], 'full');
      expect(status['runtime_seconds'], 1000);
      expect(status['started'], '1970-01-01T00:16:40.000Z');
      expect(rig.entries.last.host, 'full');

      final o = await rig.call('job_output', {'job_id': id, 'lines': 50});
      expect(o.isError, false, reason: o.text);
      expect(o.text, contains('line 1'));
      expect(o.text, isNot(contains('SECRET')));
      expect(o.text, contains('[redacted]'));
      expect(setWords(server.scripts.last)[2], '50');
    });

    test('job_output is cut to 64 KiB, newest part kept', () async {
      final id = await startFull();
      server.jobs[id]!.log = '${'a' * 100000}THE END';
      final o = await rig.call('job_output', {'job_id': id});
      expect(utf8.encode(o.text).length, lessThanOrEqualTo(64 * 1024 + 200));
      expect(o.text, endsWith('THE END'));
    });

    test('a job stepped down to read-only can be read, not stopped', () async {
      final id = await startFull();
      rig.hosts = [
        for (final h in rig.hosts)
          h.id == 'full1' ? h.copyWith(aiAccess: HostAiAccess.readOnly) : h,
      ];
      await jobs.hostsChanged(rig.hosts);
      expect(await registry.find(testBridgeClient.id, id), isNotNull);
      expect((await rig.call('job_status', {'job_id': id})).isError, false);
      final stop = await rig.call('stop_job', {'job_id': id});
      expect(stop.text, BridgeRefusals.changesNotAllowed.message);
      expect(server.jobs[id]!.state, 'running');
    });
  });

  group('ownership', () {
    test('another client\'s job, an unknown id and a malformed one read '
        'alike, for every job tool', () async {
      final theirs = await startFull(_other);
      for (final tool in [
        'job_status',
        'job_output',
        'stop_job',
        'remove_job',
      ]) {
        for (final id in [theirs, 'zzzzzzzzzzzzzzzz', '../../etc', 42, null]) {
          final r = await rig.call(tool, {'job_id': id});
          expect(r.text, BridgeRefusals.jobNotAvailable.message, reason: tool);
          expect(rig.entries.last.detail, 'job_not_available');
          // The other client's host is never named.
          expect(rig.entries.last.host, isNull);
        }
      }
      expect(server.jobs[theirs]!.state, 'running');
    });

    test('bridge off and a locked app come first', () async {
      final id = await startFull();
      rig.locked = true;
      expect(
        (await rig.call('job_status', {'job_id': 'zzzzzzzzzzzzzzzz'})).text,
        BridgeRefusals.appLocked.message,
      );
      expect(
        (await rig.call('stop_job', {'job_id': id})).text,
        BridgeRefusals.appLocked.message,
      );
      rig.locked = false;
      rig.settings = const AppSettings();
      expect(
        (await rig.call('job_output', {'job_id': id})).text,
        BridgeRefusals.bridgeOff.message,
      );
    });

    test(
      'stop_job stops the caller\'s job and reports the final state',
      () async {
        final id = await startFull();
        final r = await rig.call('stop_job', {'job_id': id});
        expect(r.isError, false, reason: r.text);
        final body = jsonDecode(r.text) as Map;
        expect(body['state'], 'exited');
        expect(body['exit_code'], 143);
        expect(body['stopped'], true);
        expect(rig.entries.last.tool, 'stop_job');
        expect(rig.entries.last.host, 'full');
      },
    );

    test('stop_job of a job whose pid or group file is not usable says '
        'nothing was stopped', () async {
      final id = await startFull();
      server.jobs[id]!.badTarget = true;
      final r = await rig.call('stop_job', {'job_id': id});
      expect(r.isError, false, reason: r.text);
      final body = jsonDecode(r.text) as Map;
      expect(body['state'], 'unknown');
      expect(body['stopped'], false);
      expect(body['stop'], BridgeJobs.stopRefusedText);
      // An ordinary stop carries no such note.
      final other = await startFull();
      final ok = jsonDecode(
        (await rig.call('stop_job', {'job_id': other})).text,
      ) as Map;
      expect(ok.containsKey('stop'), isFalse);
    });

    test('remove_job removes an ended job only', () async {
      final id = await startFull();
      final running = await rig.call('remove_job', {'job_id': id});
      expect(running.isError, true);
      expect(running.text, contains('still running'));
      expect(await registry.find(testBridgeClient.id, id), isNotNull);
      await rig.call('stop_job', {'job_id': id});
      final removed = await rig.call('remove_job', {'job_id': id});
      expect(removed.isError, false, reason: removed.text);
      expect(await registry.find(testBridgeClient.id, id), isNull);
      expect(server.jobs, isEmpty);
      expect(
        (await rig.call('job_status', {'job_id': id})).text,
        BridgeRefusals.jobNotAvailable.message,
      );
    });

    test('invalid arguments are refused after the decision', () async {
      final id = await startFull();
      final r = await rig.call('job_output', {'job_id': id, 'lines': 0});
      expect(rig.entries.last.detail, 'invalid_arguments');
      expect(r.isError, true);
      final extra = await rig.call('stop_job', {'job_id': id, 'force': true});
      expect(extra.isError, true);
      expect(server.jobs[id]!.state, 'running');
    });
  });

  group('the registry', () {
    test('is saved, owner-only, and read back by a new instance', () async {
      final id = await startFull(null, {'name': 'dev'});
      final file = File('${temp.path}/bridge_jobs.json');
      expect(file.existsSync(), isTrue);
      if (!Platform.isWindows) {
        expect(file.statSync().mode & 0x3f, 0);
      }
      final again = BridgeJobRegistry(file: file);
      final job = (await again.all()).single;
      expect(job.id, id);
      expect(job.name, 'dev');
      expect(job.command, 'npm run dev');
      expect(bridgeSameServer(rig.hosts[2], job.server), isTrue);
    });

    test('starts racing for the last place cannot all take it', () async {
      final h = rig.hosts.firstWhere((h) => h.id == 'full1');
      BridgeJobRecord record(int i) => BridgeJobRecord.on(
        h,
        id: 'race${i.toString().padLeft(12, '0')}',
        clientId: testBridgeClient.id,
        hostName: 'full',
        startedAt: DateTime.utc(2026),
      );
      final results = await Future.wait([
        for (var i = 0; i < BridgeJobs.maxJobsPerHost + 5; i++)
          registry.addIfRoom(record(i), h, BridgeJobs.maxJobsPerHost),
      ]);
      expect(results.where((r) => r), hasLength(BridgeJobs.maxJobsPerHost));
      expect(await registry.all(), hasLength(BridgeJobs.maxJobsPerHost));
    });

    test('a revoked client\'s jobs are forgotten', () async {
      final mine = await startFull();
      final theirs = await startFull(_other);
      await jobs.clientsChanged({testBridgeClient.id, BridgeClient.builtinId});
      expect(await registry.find(testBridgeClient.id, mine), isNotNull);
      expect(await registry.find(_other.id, theirs), isNull);
      // ...while the job itself keeps running on the server.
      expect(server.jobs[theirs]!.state, 'running');
    });

    test(
      'a deleted host and a host re-pointed elsewhere forget their jobs',
      () async {
        final onFull = await startFull();
        grants.grant(
          testBridgeClient.id,
          'ask1',
          const Duration(minutes: 5),
          clientName: testBridgeClient.name,
        );
        final r = await rig.call('start_job', {'host': 'ask', 'command': 'x'});
        final onAsk = (jsonDecode(r.text) as Map)['job_id'] as String;
        final hosts = [
          for (final h in rig.hosts)
            if (h.id != 'ask1')
              h.id == 'full1' ? h.copyWith(hostname: 'elsewhere.test') : h,
        ];
        await jobs.hostsChanged(hosts);
        expect(await registry.all(), isEmpty);
        expect(onFull, isNot(onAsk));
      },
    );

    test('an unreadable file starts empty and is set aside', () async {
      final file = File('${temp.path}/bridge_jobs.json')
        ..writeAsStringSync('{not json');
      final r = BridgeJobRegistry(file: file);
      expect(await r.all(), isEmpty);
      expect(
        temp.listSync().whereType<File>().any(
          (f) => f.path.contains('bridge_jobs.json.corrupt-'),
        ),
        isTrue,
      );
    });
  });

  group('the scripts', () {
    test('every value is one quoted word of the set line; nothing is '
        'spliced', () {
      const nasty = r"""a'b "c" $(rm -rf ~) `x` \ end\""";
      final start = BridgeJobCommands.start(
        id: 'abcdefghijklmnop',
        command: nasty,
        cwd: "dir with 'quotes' and spaces",
      );
      final w = setWords(start);
      expect(w.sublist(0, 5), [
        '',
        'abcdefghijklmnop',
        nasty,
        '1',
        "dir with 'quotes' and spaces",
      ]);
      // The rest of the script is the fixed template.
      final body = start.substring(start.indexOf('\n') + 1);
      expect(body, isNot(contains('rm -rf ~')));
      expect(body, contains(r'cd -- "$5"'));
      final status = BridgeJobCommands.status(['abcdefghijklmnop']);
      expect(setWords(status), ['', 'abcdefghijklmnop']);
    });

    test('the stop script signals only inside the checked branch, and says '
        'when it refused', () {
      final stop = BridgeJobCommands.stop('abcdefghijklmnop');
      final body = stop.substring(stop.indexOf('\n') + 1);
      expect(
        body,
        contains(
          '! ssg_target; then echo '
          "'${BridgeJobCommands.stopRefusedMarker}'",
        ),
      );
      // Every TERM or KILL comes after the line that checks the target and
      // that the job is alive; nothing before it signals.
      final checked = body.indexOf('&& ssg_alive; then');
      expect(checked, greaterThan(0));
      for (final signal in ['kill -s TERM', 'kill -s KILL']) {
        expect(body.indexOf(signal), greaterThan(checked), reason: signal);
      }
      expect(body, contains(r"case $p in ''|0*|1|*[!0-9]*) return 1 ;; esac"));
    });

    test(
      'a pid or group file the job did not write names no process',
      () async {
        // The status script, run here with /bin/sh. It only ever sends signal
        // 0 (a check, which signals nothing), so even a broken guard is
        // harmless here: it would show as "running".
        final dir = await bridgeTempDir('jobs_target');
        final sleeper = await Process.start('sleep', ['300']);
        try {
          final boot = File(
            '/proc/sys/kernel/random/boot_id',
          ).readAsStringSync().trim();
          const id = 'abcdefghijklmnop';
          final job = Directory('${dir.path}/$id')..createSync();
          File('${job.path}/boot').writeAsStringSync('$boot\n');
          File('${job.path}/started').writeAsStringSync('1\n');
          File('${job.path}/log').writeAsStringSync('');
          Future<String> state(String pid, String group) async {
            File('${job.path}/pid').writeAsStringSync(pid);
            File('${job.path}/group').writeAsStringSync(group);
            final r = await Process.run('/bin/sh', [
              '-c',
              BridgeJobCommands.status([id], root: dir.path),
            ]);
            expect(r.exitCode, 0, reason: '${r.stderr}');
            return BridgeJobState.parseAll(r.stdout as String).states[id]!.state;
          }

          // The control: a live process, both ways start writes it.
          expect(await state('${sleeper.pid}\n', '0\n'), 'running');
          for (final (pid, group) in [
            ('1\n', '1\n'), // would be kill -- -1: every process
            ('1\n', '0\n'),
            ('0\n', '0\n'), // kill -- 0: the script's own group
            ('0\n', '1\n'),
            ('-1\n', '0\n'),
            ('01\n', '1\n'),
            ('00\n', '0\n'),
            ('\n', '1\n'),
            ('12x\n', '0\n'),
            ('${sleeper.pid}\n', '2\n'),
            ('${sleeper.pid}\n', '-1\n'),
            ('${sleeper.pid}\n', '\n'),
          ]) {
            expect(
              await state(pid, group),
              'unknown',
              reason: 'pid ${pid.trim()} group ${group.trim()}',
            );
          }
        } finally {
          sleeper.kill(ProcessSignal.sigkill);
          await sleeper.exitCode;
          await deleteTempDir(dir);
        }
      },
      skip: Platform.isLinux ? null : 'reads the Linux boot id',
    );

    test('a status answer parses', () {
      final parsed = BridgeJobState.parseAll(
        'now 50\njob aaaaaaaaaaaaaaaa\nstarted 10\nlog 7\nexit 3 40\n'
        'state exited\njob bbbbbbbbbbbbbbbb\nstate missing\n',
      );
      expect(parsed.now, 50);
      final a = parsed.states['aaaaaaaaaaaaaaaa']!;
      expect(a.state, 'exited');
      expect(a.exitCode, 3);
      expect(a.ended, 40);
      expect(a.logBytes, 7);
      expect(parsed.states['bbbbbbbbbbbbbbbb']!.state, 'missing');
    });

    test('ids are 16 lower-case letters and digits, and only those', () {
      expect(BridgeJobs.isJobId('abcdefghij012345'), isTrue);
      for (final bad in [
        'ABCDEFGHIJ012345',
        'abc',
        'abcdefghij01234/',
        '../abcdefghij0123',
        'abcdefghij0123456',
      ]) {
        expect(BridgeJobs.isJobId(bad), isFalse, reason: bad);
      }
    });
  });

  group('the in-memory view and its changes', () {
    test('known follows add, remove_job and pruning, each with a change',
        () async {
      expect(jobs.known, isEmpty);
      var fired = jobs.changes.first;
      final id = await startFull(null, {'name': 'dev'});
      await fired;
      expect(jobs.known.single.id, id);
      expect(jobs.known.single.clientName, testBridgeClient.name);

      // A job that ended is removed through the tool: forgotten at once.
      server.jobs[id]!
        ..state = 'exited'
        ..exit = 0;
      fired = jobs.changes.first;
      expect((await rig.call('remove_job', {'job_id': id})).isError, false);
      await fired;
      expect(jobs.known, isEmpty);

      final theirs = await startFull(_other);
      fired = jobs.changes.first;
      await jobs.clientsChanged({testBridgeClient.id});
      await fired;
      expect(jobs.known.where((j) => j.id == theirs), isEmpty);
    });

    test('a start the server could not begin is taken out again', () async {
      var events = 0;
      final sub = jobs.changes.listen((_) => events++);
      final r = await rig.call('start_job', {
        'host': 'full',
        'command': 'x',
        'cwd': '/nope',
      });
      expect(r.isError, true);
      await sub.cancel();
      // Once for the record before the start, once for taking it back.
      expect(events, 2);
      expect(jobs.known, isEmpty);
    });

    test('the file is read once at start and a change says so', () async {
      final seeded = BridgeJobRegistry(file: File('${temp.path}/seed.json'));
      final h = rig.hosts.firstWhere((h) => h.id == 'full1');
      await seeded.add(
        BridgeJobRecord.on(
          h,
          id: 'seed000000000001',
          clientId: testBridgeClient.id,
          hostName: 'full',
          startedAt: DateTime.utc(2026),
        ),
      );
      final again = BridgeJobRegistry(file: File('${temp.path}/seed.json'));
      final second = BridgeJobs(
        registry: again,
        redactor: BridgeRedactor(scrub: (s) => s),
      );
      expect(second.known, isEmpty);
      final fired = second.changes.first;
      final other = Directory('${temp.path}/two')..createSync();
      final rig2 = BridgeToolsRig(other, modules: [second]);
      await fired;
      expect(second.known.single.id, 'seed000000000001');
      await rig2.connections.closeAll();
    });
  });

  group('stopByUser', () {
    test('stops the job with the stop script, writes no activity entry',
        () async {
      final id = await startFull();
      await Future<void>.delayed(Duration.zero);
      final before = rig.entries.length;
      expect(await jobs.stopByUser(id), isTrue);
      expect(server.jobs[id]!.state, 'exited');
      expect(server.jobs[id]!.stopped, isTrue);
      expect(server.scripts.last, contains('kill -s TERM'));
      expect(setWords(server.scripts.last), ['', id]);
      await Future<void>.delayed(Duration.zero);
      expect(rig.entries.length, before);
      // Still listed: only remove_job forgets it.
      expect(jobs.known.single.id, id);
    });

    test('bypasses the assistant policy: a host stepped down to read-only '
        'refuses stop_job but not the person', () async {
      final id = await startFull();
      rig.hosts = [
        for (final h in rig.hosts)
          h.id == 'full1' ? host('full1', 'full', HostAiAccess.readOnly) : h,
      ];
      expect((await rig.call('stop_job', {'job_id': id})).isError, isTrue);
      expect(server.jobs[id]!.state, 'running');
      expect(await jobs.stopByUser(id), isTrue);
      expect(server.jobs[id]!.state, 'exited');
    });

    test('stops another assistant\'s job too, and works with the bridge '
        'off (it is the person acting)', () async {
      final theirs = await startFull(_other);
      rig.settings = const AppSettings();
      expect(await jobs.stopByUser(theirs), isTrue);
      expect(server.jobs[theirs]!.state, 'exited');
    });

    test('does nothing while the app is locked', () async {
      final id = await startFull();
      final scripts = server.scripts.length;
      rig.locked = true;
      expect(await jobs.stopByUser(id), isFalse);
      expect(server.scripts.length, scripts);
      expect(server.jobs[id]!.state, 'running');
      rig.locked = false;
      expect(await jobs.stopByUser(id), isTrue);
    });

    test('is false for an unknown id, a refused target and a gone host',
        () async {
      final id = await startFull();
      expect(await jobs.stopByUser('zzzzzzzzzzzzzzzz'), isFalse);
      expect(await jobs.stopByUser('../../etc'), isFalse);
      server.jobs[id]!.badTarget = true;
      expect(await jobs.stopByUser(id), isFalse);
      server.jobs[id]!.badTarget = false;
      rig.hosts = [
        for (final h in rig.hosts)
          if (h.id != 'full1') h,
      ];
      final scripts = server.scripts.length;
      expect(await jobs.stopByUser(id), isFalse);
      expect(server.scripts.length, scripts);
    });
  });

  group('the control source', () {
    late BridgeJobsControlSource source;
    setUp(() => source = BridgeJobsControlSource(jobs));

    test('lists each job with its host name, label, assistant and start',
        () async {
      expect(source.kind, ControlItemKind.job);
      final named = await startFull(null, {'name': 'dev server'});
      final bare = await startFull(null, {
        'command': 'make all SECRET\nsecond line',
      });
      final items = {for (final i in source.current) i.id: i};
      expect(items[named]!.label, 'dev server');
      expect(items[named]!.hostName, 'full');
      expect(items[named]!.clientName, testBridgeClient.name);
      expect(items[named]!.state, 'registered');
      expect(items[named]!.startedAt, isNotNull);
      // The command's first line, scrubbed like the registry's copy.
      expect(items[bare]!.label, 'make all [redacted]');
    });

    test('a long command is cut for the label', () async {
      final id = await startFull(null, {'command': 'y' * 200});
      expect(
        source.current.firstWhere((i) => i.id == id).label!.length,
        BridgeJobsControlSource.labelChars + 1,
      );
    });

    test('passes the registry\'s changes on and stop calls stopByUser',
        () async {
      final id = await startFull();
      var fired = source.changes.first;
      await jobs.clientsChanged({BridgeClient.builtinId});
      await fired;
      expect(source.current, isEmpty);
      expect(await source.stop(id), isFalse);

      final again = await startFull();
      expect(await source.stop(again), isTrue);
      expect(server.jobs[again]!.state, 'exited');
      expect(await source.stop('zzzzzzzzzzzzzzzz'), isFalse);
    });
  });

  group('the card', () {
    testWidgets('shows the command verbatim, the folder, the name and that '
        'it keeps running', (tester) async {
      final request = BridgeApprovalRequest(
        id: 'a1',
        client: testBridgeClient,
        hostId: 'ask1',
        hostName: 'ask',
        tool: 'start_job',
        summary: const JobStartSummary(
          command: 'npm run dev\u001b[2J',
          cwd: '~/my app',
          name: 'dev server',
        ),
        createdAt: DateTime.now(),
        expiresAt: DateTime.now().add(const Duration(minutes: 2)),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BridgeApprovalCard(request: request, onAnswer: (_) {}),
          ),
        ),
      );
      expect(find.text('Start this job?'), findsOneWidget);
      expect(find.byKey(const ValueKey('approval-command')), findsOneWidget);
      expect(find.byKey(const ValueKey('approval-job-cwd')), findsOneWidget);
      expect(find.text('Name: dev server'), findsOneWidget);
      expect(find.byKey(const ValueKey('approval-job-note')), findsOneWidget);
      // The escape character is drawn as a marked stand-in, with the legend.
      expect(find.byKey(const ValueKey('approval-legend')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
