import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/app_settings.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/models/host_ai_access.dart';
import 'package:secure_shell_go/services/bridge/bridge_approvals.dart';
import 'package:secure_shell_go/services/bridge/bridge_audit.dart';
import 'package:secure_shell_go/services/bridge/bridge_change_tools.dart';
import 'package:secure_shell_go/services/bridge/bridge_connections.dart';
import 'package:secure_shell_go/services/bridge/bridge_grants.dart';
import 'package:secure_shell_go/services/bridge/bridge_policy.dart';
import 'package:secure_shell_go/services/bridge/bridge_redactor.dart';
import 'package:secure_shell_go/services/bridge/bridge_tool_types.dart';
import 'package:secure_shell_go/services/bridge/bridge_tools.dart';
import 'package:secure_shell_go/services/sftp_service.dart';
import 'package:secure_shell_go/services/shell_quote.dart';

import 'fake_exec_session.dart';
import 'support/bridge_fake_time.dart';
import 'support/bridge_fakes.dart';
import 'support/bridge_temp_dir.dart';

/// [FakeBridgeFiles] that can also be written, through the editor's seams,
/// with modes and modification times, and symlinks `lstat` can see.
class WritableFakeFiles extends FakeBridgeFiles
    implements BridgeFileWrites, RemoteFileSystem, RemoteFileMetadata {
  final Map<String, DateTime> mtimes = {};
  final Map<String, int> modes = {};

  /// Paths that are symlinks themselves (their targets are in [links]).
  final Set<String> symlinks = {};
  final List<String> renames = [];

  /// Every path [openWrite] was asked for (the temporary files).
  final List<String> opened = [];

  /// A server that reports neither a size nor a modification time.
  bool blind = false;

  /// Like the OpenSSH sftp-server the lab test runs against: realpath
  /// follows a link and accepts a missing last part when its directory
  /// exists (so a dangling link resolves to its target). False: a server
  /// that refuses any path that does not exist.
  bool realpathAllowsMissingLast = true;

  /// Called as each chunk of a temporary file is written, and before each
  /// rename: lets a test stop the call at a chosen step.
  Future<void> Function(String path)? onWrite;
  Future<void> Function(String from, String to)? onRename;

  @override
  Future<String> realpath(String path) async {
    if (!realpathAllowsMissingLast) return super.realpath(path);
    realpaths.add(path);
    var abs = path == '.'
        ? FakeBridgeFiles.home
        : path.startsWith('/')
        ? path
        : '${FakeBridgeFiles.home}/$path';
    final segments = <String>[];
    for (final part in abs.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (segments.isNotEmpty) segments.removeLast();
      } else {
        segments.add(part);
      }
    }
    abs = '/${segments.join('/')}';
    abs = links[abs] ?? abs;
    if (files.containsKey(abs) || dirs.containsKey(abs)) return abs;
    final i = abs.lastIndexOf('/');
    final parent = i <= 0 ? '/' : abs.substring(0, i);
    if (dirs.containsKey(parent)) return abs;
    throw Exception('No such file');
  }

  var _tick = 0;

  DateTime _now() => DateTime.utc(2026, 1, 1).add(Duration(seconds: ++_tick));

  void put(String path, String text, {int mode = 420}) {
    addFile(path, text);
    mtimes[path] = _now();
    modes[path] = mode;
  }

  String text(String path) => utf8.decode(files[path]!);

  @override
  Future<BridgeEntryKind> entryKind(String path) async {
    if (symlinks.contains(path)) return BridgeEntryKind.symlink;
    if (dirs.containsKey(path)) return BridgeEntryKind.directory;
    if (files.containsKey(path)) return BridgeEntryKind.file;
    return BridgeEntryKind.missing;
  }

  @override
  RemoteFileSystem get remoteFileSystem => this;

  @override
  RemoteFileMetadata get remoteMetadata => this;

  @override
  Future<RemoteFileStat?> statFile(String path) async {
    final p = links[path] ?? path;
    final bytes = files[p];
    if (bytes == null) return null;
    return RemoteFileStat(
      size: blind ? null : bytes.length,
      modified: blind ? null : mtimes[p],
      permissions: modes[p],
    );
  }

  @override
  Future<bool> setPermissions(String path, int permissions) async {
    modes[path] = permissions;
    return true;
  }

  @override
  Future<RemoteFileWriter> openWrite(String remotePath) async {
    opened.add(remotePath);
    return _Writer(this, remotePath);
  }

  @override
  Future<int?> sizeOf(String path) async => files[path]?.length;

  @override
  Future<bool> exists(String path) async => files.containsKey(path);

  @override
  Future<void> rename(String from, String to) async {
    await onRename?.call(from, to);
    renames.add('$from -> $to');
    files[to] = files.remove(from)!;
    mtimes[to] = mtimes.remove(from) ?? _now();
    modes[to] = modes.remove(from) ?? 384;
    symlinks.remove(to);
  }

  @override
  Future<void> remove(String path) async {
    files.remove(path);
  }

  @override
  Future<String> home() async => FakeBridgeFiles.home;

  @override
  Future<String> resolve(String path) => throw UnimplementedError();

  @override
  Future<int> download(
    String remotePath, {
    required Future<void> Function(Uint8List chunk) write,
    TransferProgress? onProgress,
    CancelCheck? isCancelled,
  }) => throw UnimplementedError();

  @override
  Future<int> upload(
    String localPath,
    String remotePath, {
    TransferProgress? onProgress,
    CancelCheck? isCancelled,
  }) => throw UnimplementedError();

  @override
  Future<void> mkdir(String path) => throw UnimplementedError();

  @override
  Future<void> removeDirectory(String path) => throw UnimplementedError();

  @override
  Future<bool> isDirectory(String path) async => dirs.containsKey(path);
}

class _Writer implements RemoteFileWriter {
  _Writer(this.fs, this.path);

  final WritableFakeFiles fs;
  final String path;
  final BytesBuilder _bytes = BytesBuilder();

  @override
  Future<void> add(Uint8List chunk) async {
    await fs.onWrite?.call(path);
    _bytes.add(chunk);
  }

  @override
  Future<void> close() async {
    fs.files[path] = _bytes.takeBytes();
    fs.mtimes[path] = fs._now();
    // A new file gets the server's default mode.
    fs.modes[path] = 384;
  }

  @override
  Future<void> abort() async => fs.files.remove(path);
}

Host _h(
  String id,
  String label,
  HostAiAccess access, {
  List<String> allowed = const [],
}) =>
    bridgeHost(id, label, access: access).copyWith(aiAllowedCommands: allowed);

const String _pem =
    '-----BEGIN OPENSSH PRIVATE KEY-----\n'
    'b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW\n'
    'QyNTUxOQAAACDZsecretsecretsecretsecretsecretsecretsecretAAAA\n'
    '-----END OPENSSH PRIVATE KEY-----\n';

const String _statsOutput = '#=ssg=host\nweb1\n#=ssg=cpu\n4\n';

void main() {
  late Directory temp;
  late FakeTime time;
  late BridgeToolsRig rig;
  late BridgeApprovals approvals;
  late BridgeGrants grants;
  late WritableFakeFiles fs;
  late List<List<BridgeApprovalRequest>> cards;
  late StreamSubscription<List<BridgeApprovalRequest>> cardWatch;
  final redactor = BridgeRedactor(scrub: (s) => s);
  final changeTools = BridgeChangeTools(redactor: redactor).build();

  setUp(() async {
    temp = await bridgeTempDir('bridge_change_tools');
    time = FakeTime();
    late BridgeToolsRig built;
    approvals = BridgeApprovals(
      timedApprovalMinutes: () => built.settings.bridgeTimedApprovalMinutes,
      clock: time.clock,
      timer: time.timer,
    );
    grants = BridgeGrants(clock: time.clock, timer: time.timer);
    fs = WritableFakeFiles();
    built = BridgeToolsRig(
      temp,
      approvals: approvals,
      grants: grants,
      changeTools: changeTools,
      files: fs,
    );
    built.hosts = [
      _h('web1', 'web', HostAiAccess.askToChange, allowed: ['uptime']),
      _h('app1', 'app', HostAiAccess.askToChange, allowed: ['uptime']),
      _h('api1', 'api', HostAiAccess.askToChange),
      _h('job1', 'jobs', HostAiAccess.askToChange),
      _h('bat1', 'batch', HostAiAccess.askToChange),
      _h('db01', 'db', HostAiAccess.readOnly),
      _h('sec1', 'secret', HostAiAccess.off),
    ];
    for (final id in ['web1', 'app1', 'api1', 'job1', 'bat1', 'db01']) {
      built.serve(id, (cmd) => FakeExecSession(stdout: 'out'));
    }
    rig = built;
    cards = [];
    cardWatch = approvals.pending.listen(cards.add);
  });

  tearDown(() async {
    await cardWatch.cancel();
    await deleteTempDir(temp);
  });

  Future<BridgeApprovalRequest> card() async {
    for (var i = 0; i < 400; i++) {
      if (approvals.current.isNotEmpty) return approvals.current.last;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('no approval card appeared');
  }

  bool anyCard() => cards.any((l) => l.isNotEmpty);
  BridgeAuditEntry last() => rig.entries.last;
  String shell(String c) => BridgeChangeCommands.accountShell(c);

  /// Calls [tool], answers its card with [answer], returns the result.
  Future<({String text, bool isError})> approved(
    String tool,
    Map<String, Object?> args, {
    BridgeApprovalAnswer answer = BridgeApprovalAnswer.allowOnce,
  }) async {
    final r = rig.call(tool, args);
    approvals.answer((await card()).id, answer);
    return r;
  }

  test('the four tools are change tools, and say the user is asked', () {
    final specs = {for (final s in rig.tools.tools) s.name: s};
    for (final name in [
      'run_command',
      'write_file',
      'service_action',
      'run_on_hosts',
    ]) {
      expect(specs[name]!.kind, BridgeToolKind.change, reason: name);
      expect(specs[name]!.description, contains('approve'), reason: name);
    }
  });

  group('run_command', () {
    test('a command on the allowed list runs at once, verbatim, through the '
        'account shell', () async {
      final r = await rig.call('run_command', {
        'host': 'web',
        'command': 'uptime',
      });
      expect(r.isError, false, reason: r.text);
      expect(anyCard(), false);
      expect(rig.commands, [shell('uptime')]);
      expect(r.text, startsWith('exit_code: 0\nstdout:\nout\nstderr:'));
      expect(last().approval, BridgeAuditApproval.allowedCommand);
    });

    test('card, allowed list and shell see the one same string', () async {
      // Leading and trailing space: trimmed once, for all three.
      final listed = await rig.call('run_command', {
        'host': 'web',
        'command': '  uptime \n',
      });
      expect(listed.isError, false);
      expect(anyCard(), false);
      expect(rig.commands.single, shell('uptime'));

      const multi = '  echo a\n  echo "b"; ls -- -x\t ';
      final r = rig.call('run_command', {'host': 'web', 'command': multi});
      final c = await card();
      final summary = c.summary as CommandSummary;
      expect(summary.command, multi.trim());
      expect(summary.hostNames, ['web']);
      approvals.answer(c.id, BridgeApprovalAnswer.allowOnce);
      expect((await r).isError, false);
      expect(rig.commands.last, shell(summary.command));
      expect(last().approval, BridgeAuditApproval.once);
    });

    test('a live grant skips the card', () async {
      rig.settings = const AppSettings(
        bridgeEnabled: true,
        bridgeTimedApprovalMinutes: 15,
      );
      await approved('run_command', {
        'host': 'web',
        'command': 'id',
      }, answer: BridgeApprovalAnswer.allowForAWhile);
      cards.clear();
      final r = await rig.call('run_command', {
        'host': 'web',
        'command': 'whoami',
      });
      expect(r.isError, false);
      expect(anyCard(), false);
      expect(last().approval, BridgeAuditApproval.grant);
      expect(rig.commands.last, shell('whoami'));
    });

    test(
      'denied, timed out and withdrawn run nothing and return nothing',
      () async {
        final denied = await approved('run_command', {
          'host': 'web',
          'command': 'reboot',
        }, answer: BridgeApprovalAnswer.deny);
        expect(denied.isError, true);
        expect(denied.text, BridgeToolRefusals.denied.message);

        final timedOut = rig.call('run_command', {
          'host': 'web',
          'command': 'reboot',
        });
        await card();
        time.advance(const Duration(seconds: 120));
        expect(
          (await timedOut).text,
          BridgeToolRefusals.approvalTimedOut.message,
        );

        final token = BridgeCallToken();
        final withdrawn = rig.call(
          'run_command',
          {'host': 'web', 'command': 'reboot'},
          null,
          token,
        );
        await card();
        token.cancel();
        final w = await withdrawn;
        expect(w.isError, true);
        expect(w.text, isNot(contains('out')));
        expect(last().approval, BridgeAuditApproval.withdrawn);
        expect(rig.commands, isEmpty);
      },
    );

    test('read-only and hidden hosts are refused without a card', () async {
      final ro = await rig.call('run_command', {
        'host': 'db',
        'command': 'uptime',
      });
      expect(ro.text, BridgeRefusals.changesNotAllowed.message);
      for (final name in ['secret', 'nope']) {
        final r = await rig.call('run_command', {
          'host': name,
          'command': 'uptime',
        });
        expect(r.text, BridgeRefusals.hostNotAvailable.message);
      }
      expect(anyCard(), false);
      expect(rig.commands, isEmpty);
    });

    test('invalid arguments are refused before any card', () async {
      final bad = <Map<String, Object?>>[
        {'host': 'web'},
        {'host': 'web', 'command': 7},
        {'host': 'web', 'command': ''},
        {'host': 'web', 'command': '  \n '},
        {'host': 'web', 'command': 'echo a\u0000b'},
        {'host': 'web', 'command': 'x' * 4097},
        {'host': 'web', 'command': 'id', 'timeout_seconds': 0},
        {'host': 'web', 'command': 'id', 'timeout_seconds': 301},
        {'host': 'web', 'command': 'id', 'timeout_seconds': 'ten'},
        {'host': 'web', 'command': 'id', 'stdin': 'yes'},
      ];
      for (final args in bad) {
        final r = await rig.call('run_command', args);
        expect(r.isError, true, reason: '$args');
        expect(last().detail, 'invalid_arguments', reason: '$args');
      }
      expect(anyCard(), false);
      expect(rig.commands, isEmpty);
      // 4096 characters is allowed.
      final r = rig.call('run_command', {'host': 'web', 'command': 'x' * 4096});
      approvals.answer((await card()).id, BridgeApprovalAnswer.deny);
      await r;
    });

    test('a private key printed by the command comes back redacted', () async {
      rig.serve('web1', (_) => FakeExecSession(stdout: 'before\n$_pem after'));
      final r = await approved('run_command', {
        'host': 'web',
        'command': 'cat key',
      });
      expect(r.text, contains(BridgeRedactor.keyMarker));
      expect(r.text, isNot(contains('secretsecret')));
      expect(r.text, contains('before'));
    });

    test('the audit records the command capped, never the output', () async {
      final long = 'echo ${'y' * 900}';
      final args = {'host': 'web', 'command': long};
      final recorded = changeTools
          .firstWhere((t) => t.spec.name == 'run_command')
          .auditArgs!(args);
      expect((recorded['command'] as String).length, 501);
      expect(recorded['command'], startsWith('echo yyy'));
      await approved('run_command', args);
      expect(last().args, contains('echo yyy'));
      expect(last().args, isNot(contains('out')));
    });

    test('a run past timeout_seconds is stopped and returns nothing', () async {
      final web = rig.serve(
        'web1',
        (_) => FakeExecSession(
          stdout: 'partial',
          exitDelay: const Duration(seconds: 10),
        ),
      );
      final r = await approved('run_command', {
        'host': 'web',
        'command': 'sleep 100',
        'timeout_seconds': 1,
      });
      expect(r.isError, true);
      expect(r.text, contains('longer than 1 seconds'));
      expect(r.text, isNot(contains('partial')));
      expect(web.sessions.single.stdinClosed, true);
    });

    test('a cancelled run ends the remote command', () async {
      final web = rig.serve(
        'web1',
        (_) => FakeExecSession(exitDelay: const Duration(seconds: 10)),
      );
      final token = BridgeCallToken();
      final r = rig.call(
        'run_command',
        {'host': 'web', 'command': 'uptime'},
        null,
        token,
      );
      for (var i = 0; i < 200 && web.sessions.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      token.cancel();
      final out = await r;
      expect(out.isError, true);
      expect(out.text, BridgeTools.cancelledMessage);
      expect(web.sessions.single.stdinClosed, true);
    });
  });

  group('service_action', () {
    test('runs the services screen\'s template, after the card', () async {
      final r = rig.call('service_action', {
        'host': 'web',
        'unit': 'nginx.service',
        'action': 'restart',
      });
      final c = await card();
      final s = c.summary as ServiceActionSummary;
      expect((s.unit, s.action), ('nginx.service', 'restart'));
      expect(rig.commands, isEmpty);
      approvals.answer(c.id, BridgeApprovalAnswer.allowOnce);
      expect((await r).isError, false);
      expect(rig.commands, [
        'command -v systemctl >/dev/null 2>&1',
        "systemctl restart 'nginx.service'",
      ]);
      await approved('service_action', {
        'host': 'web',
        'unit': 'nginx',
        'action': 'reload',
      });
      expect(rig.commands.last, "systemctl reload 'nginx'");
    });

    test(
      'hostile units and unknown actions are refused, nothing runs',
      () async {
        for (final unit in [
          'a;reboot',
          r'$(reboot)',
          '`reboot`',
          '-H',
          '--now',
          'a\nb',
          'a b',
          "a'b",
        ]) {
          final r = await rig.call('service_action', {
            'host': 'web',
            'unit': unit,
            'action': 'stop',
          });
          expect(last().detail, 'invalid_arguments', reason: unit);
          expect(r.isError, true);
        }
        for (final action in ['enable', 'mask', 'Stop', '', 3]) {
          await rig.call('service_action', {
            'host': 'web',
            'unit': 'nginx',
            'action': action,
          });
          expect(last().detail, 'invalid_arguments', reason: '$action');
        }
        expect(anyCard(), false);
        expect(rig.commands, isEmpty);
      },
    );

    test('a refusal for lack of privilege is the tool\'s error', () async {
      rig.serve(
        'web1',
        (c) => c.startsWith('systemctl')
            ? FakeExecSession(
                exitCode: 1,
                stderrText: 'Failed to stop x: Access denied',
              )
            : FakeExecSession(),
      );
      final r = await approved('service_action', {
        'host': 'web',
        'unit': 'x',
        'action': 'stop',
      });
      expect(r.isError, true);
      expect(r.text, contains('Could not stop x'));
    });
  });

  group('write_file', () {
    setUp(() {
      fs.addDir('/home/dev', []);
      fs.addDir('/srv/app', []);
      fs.addDir('/home/dev/.ssh', []);
      fs.put('/home/dev/.ssh/authorized_keys', 'ssh-ed25519 AAAA');
    });

    test('a new file: the card names the canonical path; written by temp and '
        'rename', () async {
      final r = rig.call('write_file', {
        'host': 'web',
        'path': '~/notes.txt',
        'content': 'line one\nline two\n',
      });
      final c = await card();
      final s = c.summary as FileWriteSummary;
      expect(s.path, '/home/dev/notes.txt');
      expect(s.bytes, 18);
      expect(s.replacesExisting, false);
      expect(s.preview, contains('line one'));
      expect(fs.files.containsKey('/home/dev/notes.txt'), false);
      approvals.answer(c.id, BridgeApprovalAnswer.allowOnce);
      final out = await r;
      expect(out.isError, false, reason: out.text);
      expect(fs.text('/home/dev/notes.txt'), 'line one\nline two\n');
      expect(fs.renames.single, endsWith(' -> /home/dev/notes.txt'));
      expect(fs.renames.single, contains('/home/dev/.notes.txt.ssg-bridge-'));
      expect(fs.files.keys.where((k) => k.contains('ssg-bridge')), isEmpty);
      expect(rig.commands, isEmpty, reason: 'no shell is involved');
    });

    test('a replacement shows a short diff and keeps the mode', () async {
      fs.put('/srv/app/run.sh', 'a\nb\nc\n', mode: 493);
      final r = rig.call('write_file', {
        'host': 'web',
        'path': '/srv/app/run.sh',
        'content': 'a\nB\nc\n',
        'if_exists': 'replace',
      });
      final c = await card();
      final s = c.summary as FileWriteSummary;
      expect(s.replacesExisting, true);
      expect(s.preview, contains('-b\n'));
      expect(s.preview, contains('+B\n'));
      expect(s.preview.split('\n').length, lessThanOrEqualTo(62));
      approvals.answer(c.id, BridgeApprovalAnswer.allowOnce);
      expect((await r).isError, false);
      expect(fs.text('/srv/app/run.sh'), 'a\nB\nc\n');
      expect(fs.modes['/srv/app/run.sh'], 493);
    });

    test('the diff is bounded', () async {
      fs.put(
        '/srv/app/big.txt',
        [for (var i = 0; i < 500; i++) 'o$i'].join('\n'),
      );
      final r = rig.call('write_file', {
        'host': 'web',
        'path': '/srv/app/big.txt',
        'content': [for (var i = 0; i < 500; i++) 'n$i'].join('\n'),
        'if_exists': 'replace',
      });
      final c = await card();
      final lines = (c.summary as FileWriteSummary).preview.trim().split('\n');
      // 60 diff lines, the count of the rest, and the one line that says the
      // diff is not complete.
      expect(lines.length, lessThanOrEqualTo(62));
      expect(lines[lines.length - 2], contains('more diff lines'));
      expect(lines.last, contains('NOT complete'));
      expect(
        (c.summary as FileWriteSummary).previewKind,
        FileWritePreviewKind.partialDiff,
      );
      approvals.answer(c.id, BridgeApprovalAnswer.deny);
      await r;
    });

    test('if_exists fail on an existing file: an error, no card', () async {
      fs.put('/srv/app/a.conf', 'x');
      final r = await rig.call('write_file', {
        'host': 'web',
        'path': '/srv/app/a.conf',
        'content': 'y',
      });
      expect(r.isError, true);
      expect(r.text, contains('already exists'));
      expect(anyCard(), false);
      expect(fs.text('/srv/app/a.conf'), 'x');
    });

    test('a file changed after the card is not overwritten', () async {
      fs.put('/srv/app/a.conf', 'old\n');
      final r = rig.call('write_file', {
        'host': 'web',
        'path': '/srv/app/a.conf',
        'content': 'new\n',
        'if_exists': 'replace',
      });
      final c = await card();
      fs.put('/srv/app/a.conf', 'someone else\n');
      approvals.answer(c.id, BridgeApprovalAnswer.allowOnce);
      final out = await r;
      expect(out.isError, true);
      expect(
        out.text,
        contains('changed on the server after the user was asked'),
      );
      expect(fs.text('/srv/app/a.conf'), 'someone else\n');
    });

    test('a new file that appears after the card is not overwritten', () async {
      final r = rig.call('write_file', {
        'host': 'web',
        'path': '/srv/app/new.conf',
        'content': 'mine\n',
      });
      final c = await card();
      fs.put('/srv/app/new.conf', 'theirs\n');
      approvals.answer(c.id, BridgeApprovalAnswer.allowOnce);
      expect((await r).isError, true);
      expect(fs.text('/srv/app/new.conf'), 'theirs\n');
    });

    test(
      'blocked paths are refused exactly as a read is, without a card',
      () async {
        final read = await rig.call('read_file', {
          'host': 'web',
          'path': '/home/dev/.ssh/authorized_keys',
        });
        // A link in an open directory pointing into a blocked one.
        fs.links['/srv/app/keys'] = '/home/dev/.ssh/authorized_keys';
        fs.symlinks.add('/srv/app/keys');
        for (final path in [
          '/home/dev/.ssh/authorized_keys',
          '~/.ssh/new_key',
          '/srv/app/keys',
          '/srv/app/.env',
          '/srv/app/../../home/dev/.ssh/x',
        ]) {
          final r = await rig.call('write_file', {
            'host': 'web',
            'path': path,
            'content': 'x',
            'if_exists': 'replace',
          });
          expect(r.text, read.text, reason: path);
          expect(last().detail, 'path_not_available', reason: path);
        }
        expect(anyCard(), false);
        expect(fs.text('/home/dev/.ssh/authorized_keys'), 'ssh-ed25519 AAAA');
      },
    );

    test('a missing parent directory is not created', () async {
      final r = await rig.call('write_file', {
        'host': 'web',
        'path': '/srv/nope/x.txt',
        'content': 'x',
      });
      expect(last().detail, 'path_not_available');
      expect(r.isError, true);
      expect(anyCard(), false);
    });

    test('a dangling symlink to an allowed place: the file is created at '
        'its target, which the card names; the link stays', () async {
      fs.symlinks.add('/srv/app/dangling');
      fs.links['/srv/app/dangling'] = '/srv/app/gone';
      final r = rig.call('write_file', {
        'host': 'web',
        'path': '/srv/app/dangling',
        'content': 'x',
      });
      final c = await card();
      expect((c.summary as FileWriteSummary).path, '/srv/app/gone');
      expect((c.summary as FileWriteSummary).replacesExisting, false);
      approvals.answer(c.id, BridgeApprovalAnswer.allowOnce);
      expect((await r).isError, false);
      expect(fs.text('/srv/app/gone'), 'x');
      expect(fs.symlinks, contains('/srv/app/dangling'));
    });

    test('a dangling symlink, on a server whose realpath refuses it, is '
        'refused rather than replaced', () async {
      fs.realpathAllowsMissingLast = false;
      fs.symlinks.add('/srv/app/dangling');
      fs.links['/srv/app/dangling'] = '/srv/app/gone';
      await rig.call('write_file', {
        'host': 'web',
        'path': '/srv/app/dangling',
        'content': 'x',
      });
      expect(last().detail, 'path_not_available');
      expect(anyCard(), false);
    });

    test('a dangling symlink into a blocked place is refused', () async {
      fs.symlinks.add('/srv/app/k');
      fs.links['/srv/app/k'] = '/home/dev/.ssh/new_key';
      await rig.call('write_file', {
        'host': 'web',
        'path': '/srv/app/k',
        'content': 'x',
      });
      expect(last().detail, 'path_not_available');
      expect(anyCard(), false);
      expect(fs.files.containsKey('/home/dev/.ssh/new_key'), false);
    });

    test(
      'a symlink to an open file writes that file; the link stays',
      () async {
        fs.put('/srv/app/real.conf', 'v1\n', mode: 416);
        fs.links['/srv/app/current.conf'] = '/srv/app/real.conf';
        fs.symlinks.add('/srv/app/current.conf');
        final r = rig.call('write_file', {
          'host': 'web',
          'path': '/srv/app/current.conf',
          'content': 'v2\n',
          'if_exists': 'replace',
        });
        final c = await card();
        expect((c.summary as FileWriteSummary).path, '/srv/app/real.conf');
        approvals.answer(c.id, BridgeApprovalAnswer.allowOnce);
        expect((await r).isError, false);
        expect(fs.text('/srv/app/real.conf'), 'v2\n');
        expect(fs.symlinks, contains('/srv/app/current.conf'));
        expect(fs.modes['/srv/app/real.conf'], 416);
      },
    );

    test('content and option validation', () async {
      final bad = <Map<String, Object?>>[
        {'host': 'web', 'path': '/srv/app/a'},
        {'host': 'web', 'path': '/srv/app/a', 'content': 5},
        {'host': 'web', 'path': '/srv/app/a', 'content': 'bin\u0000ary'},
        {
          'host': 'web',
          'path': '/srv/app/a',
          'content': 'x' * (256 * 1024 + 1),
        },
        {
          'host': 'web',
          'path': '/srv/app/a',
          'content': 'x',
          'if_exists': 'append',
        },
        {
          'host': 'web',
          'path': '/srv/app/a',
          'content': 'x',
          'if_exists': true,
        },
        {'host': 'web', 'path': '/srv/app/a\nb', 'content': 'x'},
        {'host': 'web', 'path': '', 'content': 'x'},
        {'host': 'web', 'path': '/srv/app/', 'content': 'x'},
      ];
      for (final args in bad) {
        final r = await rig.call('write_file', args);
        expect(r.isError, true, reason: '$args');
      }
      expect(anyCard(), false);
      expect(fs.files.keys.where((k) => k.startsWith('/srv/app/')), isEmpty);
    });

    test('hostile file names are names: no shell, written literally', () async {
      const names = [r'$(touch x)', '`id`', 'a;b', '-rf', "it's"];
      for (final n in names) {
        await approved('write_file', {
          'host': 'web',
          'path': '/srv/app/$n',
          'content': 'ok',
        });
        expect(fs.text('/srv/app/$n'), 'ok', reason: n);
      }
      expect(rig.commands, isEmpty);
    });

    test(
      'the preview is redacted; the audit has the size, not the content',
      () async {
        final r = rig.call('write_file', {
          'host': 'web',
          'path': '/srv/app/key',
          'content': _pem,
        });
        final c = await card();
        final preview = (c.summary as FileWriteSummary).preview;
        expect(preview, contains(BridgeRedactor.keyMarker));
        expect(preview, isNot(contains('secretsecret')));
        approvals.answer(c.id, BridgeApprovalAnswer.allowOnce);
        await r;
        final args = jsonDecode(last().args) as Map;
        expect(args, {
          'host': 'web',
          'path': '/srv/app/key',
          'bytes': utf8.encode(_pem).length,
          'if_exists': 'fail',
        });
        expect(last().args, isNot(contains('PRIVATE')));
      },
    );

    test('the plan that was shown is the plan that runs', () async {
      final r = rig.call('write_file', {
        'host': 'web',
        'path': '/srv/app/same.txt',
        'content': 'exact\r\ncontent\n',
      });
      final c = await card();
      approvals.answer(c.id, BridgeApprovalAnswer.allowOnce);
      await r;
      final s = c.summary as FileWriteSummary;
      expect(fs.files[s.path]!.length, s.bytes);
      expect(fs.text(s.path), 'exact\r\ncontent\n');
    });
  });

  group('run_on_hosts', () {
    test('one card names every host; once runs on each', () async {
      final r = rig.call('run_on_hosts', {
        'hosts': ['web', 'app', 'api'],
        'command': ' df -h ',
      });
      final c = await card();
      final s = c.summary as CommandSummary;
      expect(s.command, 'df -h');
      expect(s.hostNames, ['web', 'app', 'api']);
      expect(c.hostName, 'web, app, api');
      expect(approvals.current, hasLength(1));
      approvals.answer(c.id, BridgeApprovalAnswer.allowOnce);
      final out = await r;
      expect(out.isError, false, reason: out.text);
      expect(jsonDecode(out.text), {
        'hosts': [
          for (final h in ['web', 'app', 'api'])
            {'host': h, 'exit_code': 0, 'stdout': 'out', 'stderr': ''},
        ],
      });
      for (final id in ['web1', 'app1', 'api1']) {
        expect(rig.transports[id]!.commands, [shell('df -h')]);
      }
      expect(rig.transports['job1']!.commands, isEmpty);
    });

    test('allowed-command lists never apply', () async {
      final r = rig.call('run_on_hosts', {
        'hosts': ['web', 'app'],
        'command': 'uptime',
      });
      approvals.answer((await card()).id, BridgeApprovalAnswer.deny);
      expect((await r).isError, true);
      expect(rig.commands, isEmpty);
    });

    test('for a while grants every host; the card is skipped only when all '
        'are granted', () async {
      rig.settings = const AppSettings(
        bridgeEnabled: true,
        bridgeTimedApprovalMinutes: 5,
      );
      await approved('run_on_hosts', {
        'hosts': ['web', 'app'],
        'command': 'id',
      }, answer: BridgeApprovalAnswer.allowForAWhile);
      expect(grants.hasLive(testBridgeClient.id, 'web1'), true);
      expect(grants.hasLive(testBridgeClient.id, 'app1'), true);
      expect(last().approval, BridgeAuditApproval.forAWhile);
      cards.clear();
      final skipped = await rig.call('run_on_hosts', {
        'hosts': ['app', 'web'],
        'command': 'id',
      });
      expect(skipped.isError, false);
      expect(anyCard(), false);
      expect(last().approval, BridgeAuditApproval.grant);
      final r = rig.call('run_on_hosts', {
        'hosts': ['web', 'api'],
        'command': 'id',
      });
      approvals.answer((await card()).id, BridgeApprovalAnswer.deny);
      await r;
    });

    test(
      'for a while with the setting off by the answer grants nothing',
      () async {
        rig.settings = const AppSettings(
          bridgeEnabled: true,
          bridgeTimedApprovalMinutes: 5,
        );
        final r = rig.call('run_on_hosts', {
          'hosts': ['web', 'app'],
          'command': 'id',
        });
        final c = await card();
        rig.settings = const AppSettings(bridgeEnabled: true);
        approvals.answer(c.id, BridgeApprovalAnswer.allowForAWhile);
        await r;
        expect(grants.current, isEmpty);
        expect(last().approval, BridgeAuditApproval.once);
      },
    );

    test('a hidden or read-only host fails the whole call, without a card '
        'and without saying which', () async {
      for (final hidden in ['secret', 'nope']) {
        final r = await rig.call('run_on_hosts', {
          'hosts': ['web', hidden, 'db'],
          'command': 'id',
        });
        expect(r.text, BridgeRefusals.hostNotAvailable.message);
      }
      final ro = await rig.call('run_on_hosts', {
        'hosts': ['web', 'db'],
        'command': 'id',
      });
      expect(ro.text, BridgeRefusals.changesNotAllowed.message);
      for (final hosts in [
        null,
        'web',
        [],
        [3, 'web'],
      ]) {
        final r = await rig.call('run_on_hosts', {
          'hosts': hosts,
          'command': 'id',
        });
        expect(r.text, BridgeRefusals.hostNotAvailable.message);
      }
      expect(anyCard(), false);
      expect(rig.commands, isEmpty);
    });

    test('count, duplicates and the command are validated', () async {
      final many = [for (var i = 0; i < 11; i++) 'h$i'];
      rig.hosts = [
        ...rig.hosts,
        for (var i = 0; i < 11; i++) _h('x$i', 'h$i', HostAiAccess.askToChange),
      ];
      final bad = <Map<String, Object?>>[
        {
          'hosts': ['web'],
          'command': 'id',
        },
        {'hosts': many, 'command': 'id'},
        {
          'hosts': ['web', 'web'],
          'command': 'id',
        },
        {
          'hosts': ['web', 'app'],
        },
        {
          'hosts': ['web', 'app'],
          'command': 'a\u0000',
        },
        {
          'hosts': ['web', 'app'],
          'command': 'id',
          'host': 'web',
        },
      ];
      for (final args in bad) {
        await rig.call('run_on_hosts', args);
        expect(last().detail, 'invalid_arguments', reason: '$args');
      }
      expect(anyCard(), false);
    });

    test('a host edited while the card waited stops the whole call', () async {
      final r = rig.call('run_on_hosts', {
        'hosts': ['web', 'app'],
        'command': 'id',
      });
      final c = await card();
      rig.hosts = [
        for (final h in rig.hosts)
          h.id == 'app1' ? h.copyWith(hostname: 'elsewhere.test') : h,
      ];
      approvals.answer(c.id, BridgeApprovalAnswer.allowOnce);
      final out = await r;
      expect(out.text, BridgeRefusals.hostNotAvailable.message);
      expect(rig.commands, isEmpty);
    });

    test('at most three hosts at a time', () async {
      final starts = <DateTime>[];
      for (final id in ['web1', 'app1', 'api1', 'job1', 'bat1']) {
        rig.serve(id, (_) {
          starts.add(DateTime.now());
          return FakeExecSession(exitDelay: const Duration(milliseconds: 300));
        });
      }
      final out = await approved('run_on_hosts', {
        'hosts': ['web', 'app', 'api', 'jobs', 'batch'],
        'command': 'id',
      });
      expect(out.isError, false, reason: out.text);
      starts.sort();
      expect(starts, hasLength(5));
      expect(
        starts[3].difference(starts[0]),
        greaterThanOrEqualTo(const Duration(milliseconds: 250)),
      );
      expect(
        starts[2].difference(starts[0]),
        lessThan(const Duration(milliseconds: 250)),
      );
    });

    test(
      'one host failing is reported for that host; output is redacted',
      () async {
        rig.serve('app1', (_) => FakeExecSession(stdout: _pem, exitCode: 3));
        rig.transports.remove('api1');
        final out = await approved('run_on_hosts', {
          'hosts': ['web', 'app', 'api'],
          'command': 'id',
        });
        expect(out.isError, false);
        final hosts = (jsonDecode(out.text) as Map)['hosts'] as List;
        expect(hosts[1]['host'], 'app');
        expect(hosts[1]['exit_code'], 3);
        expect(hosts[1]['stdout'], contains(BridgeRedactor.keyMarker));
        expect(out.text, isNot(contains('secretsecret')));
        expect(hosts[2].keys, ['host', 'error']);
        expect(hosts[2]['host'], 'api');
      },
    );

    test('a cancelled run ends every host\'s command', () async {
      for (final id in ['web1', 'app1']) {
        rig.serve(
          id,
          (_) => FakeExecSession(exitDelay: const Duration(seconds: 10)),
        );
      }
      final token = BridgeCallToken();
      final r = rig.call(
        'run_on_hosts',
        {
          'hosts': ['web', 'app'],
          'command': 'sleep 60',
        },
        null,
        token,
      );
      approvals.answer((await card()).id, BridgeApprovalAnswer.allowOnce);
      for (var i = 0; i < 400; i++) {
        if (rig.transports['web1']!.sessions.isNotEmpty &&
            rig.transports['app1']!.sessions.isNotEmpty) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      token.cancel();
      expect((await r).text, BridgeTools.cancelledMessage);
      for (final id in ['web1', 'app1']) {
        expect(
          rig.transports[id]!.sessions.single.stdinClosed,
          true,
          reason: id,
        );
      }
    });
  });

  group('the account shell, against a real sh', () {
    final hasSh = !Platform.isWindows && File('/bin/sh').existsSync();
    const skip = 'needs /bin/sh, setsid and kill (POSIX)';

    Future<Process> start(String command, Directory dir) => Process.start(
      '/bin/sh',
      [
        '-c',
        BridgeCommands.supervised(BridgeChangeCommands.accountShell(command)),
      ],
      workingDirectory: dir.path,
      environment: {'SHELL': '/bin/sh'},
    );

    test(
      'the command reaches the shell verbatim, and nothing else runs',
      () async {
        final dir = await temp.createTemp('verbatim');
        const command =
            r'''printf "%s|" "a'b" '$(touch pwned)' "\`x\`" -n'''
            '\n'
            r'echo; echo $((1+2))';
        final p = await start(command, dir);
        final out = await p.stdout.transform(utf8.decoder).join();
        await p.exitCode;
        await p.stdin.close();
        expect(out, "a'b|\$(touch pwned)|`x`|-n|\n3\n");
        expect(File('${dir.path}/pwned').existsSync(), false);
      },
      skip: hasSh ? null : skip,
    );

    test(
      'the command has no stdin and its exit code comes back',
      () async {
        final dir = await temp.createTemp('stdin');
        final p = await start('cat; echo done; exit 7', dir);
        final out = await p.stdout
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(seconds: 10));
        expect(out, 'done\n');
        expect(await p.exitCode, 7);
        await p.stdin.close();
      },
      skip: hasSh ? null : skip,
    );

    test(
      'closing stdin (a stopped call) ends the command and its children',
      () async {
        final dir = await temp.createTemp('stop');
        final p = await start('sleep 30 & echo \$! > child.pid; wait', dir);
        final pidFile = File('${dir.path}/child.pid');
        for (var i = 0; i < 200 && !pidFile.existsSync(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        var pid = '';
        for (var i = 0; i < 100 && pid.isEmpty; i++) {
          pid = pidFile.readAsStringSync().trim();
          if (pid.isEmpty) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        }
        await p.stdin.close();
        await p.exitCode.timeout(const Duration(seconds: 10));
        var alive = true;
        for (var i = 0; i < 100 && alive; i++) {
          alive = (await Process.run('kill', ['-0', pid])).exitCode == 0;
          if (alive) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        }
        expect(alive, false, reason: 'the child $pid is still running');
      },
      skip: hasSh ? null : skip,
    );
  });

  group('review: what the card says about a write', () {
    setUp(() {
      fs.addDir('/home/dev', []);
      fs.addDir('/srv/app', []);
    });

    late FileWriteSummary shown;
    Future<String> previewOf(Map<String, Object?> args) async {
      final r = rig.call('write_file', {'host': 'web', ...args});
      final c = await card();
      shown = c.summary as FileWriteSummary;
      final preview = shown.preview;
      approvals.answer(c.id, BridgeApprovalAnswer.deny);
      await r;
      return preview;
    }

    test('a small new file says it is shown whole', () async {
      final p = await previewOf({
        'path': '/srv/app/a.txt',
        'content': 'a\nb\n',
      });
      expect(p, contains('shows everything that will be written'));
      expect(p, isNot(contains('NOT')));
      expect(shown.previewKind, FileWritePreviewKind.fullContent);
      expect(shown.previewIsPartial, false);
    });

    test('a long file says plainly that only the start is shown', () async {
      final p = await previewOf({
        'path': '/srv/app/a.txt',
        'content': [for (var i = 0; i < 300; i++) 'line $i'].join('\n'),
      });
      expect(p, contains('[280 more lines]'));
      expect(p, contains('NOT the whole file'));
      expect(shown.previewKind, FileWritePreviewKind.partialContent);
      expect(shown.previewIsPartial, true);
      expect(p, isNot(contains('line 25')));
    });

    test('one enormous line is cut and says so', () async {
      final p = await previewOf({
        'path': '/srv/app/a.txt',
        'content': 'x' * (256 * 1024),
      });
      expect(p, contains('Long lines are cut at 200'));
      expect(p, contains('NOT the whole file'));
      expect(shown.previewKind, FileWritePreviewKind.partialContent);
      expect(p.length, lessThan(2000));
    });

    test('a diff that fits says it shows every change', () async {
      fs.put('/srv/app/c.conf', 'a\nb\nc\nd\ne\nf\n');
      final p = await previewOf({
        'path': '/srv/app/c.conf',
        'content': 'a\nb\nX\nd\ne\nf\n',
        'if_exists': 'replace',
      });
      expect(p, contains('-c'));
      expect(p, contains('+X'));
      expect(p, contains('shows every change'));
      expect(shown.previewKind, FileWritePreviewKind.fullDiff);
      expect(shown.previewIsPartial, false);
    });

    test(
      'a file replaced that is too large to diff says it is not shown',
      () async {
        fs.put('/srv/app/huge.bin', 'z' * (70 * 1024));
        final p = await previewOf({
          'path': '/srv/app/huge.bin',
          'content': 'small\n',
          'if_exists': 'replace',
        });
        expect(p, contains('too large'));
        expect(p, contains('file it replaces is not shown'));
        expect(shown.previewKind, FileWritePreviewKind.fullContent);
      },
    );

    test(
      'a change of line breaks only is said, not shown as nothing',
      () async {
        fs.put('/srv/app/crlf.txt', 'a\r\nb\r\n');
        final p = await previewOf({
          'path': '/srv/app/crlf.txt',
          'content': 'a\nb\n',
          'if_exists': 'replace',
        });
        expect(p, contains('Only line breaks differ'));
        expect(shown.previewKind, FileWritePreviewKind.fullDiff);
      },
    );

    test(
      'a secret in the new content is hidden, and the card says so',
      () async {
        final p = await previewOf({
          'path': '/srv/app/notes.txt',
          'content': _pem,
        });
        expect(p, isNot(contains('secretsecret')));
        expect(p, contains('hidden: it looks like a secret'));
        expect(p, contains('NOT the whole file'));
        expect(shown.previewKind, FileWritePreviewKind.partialContent);
        expect(shown.previewIsPartial, true);
      },
    );

    test('a server that reports no size and no time: no replacement', () async {
      fs.put('/srv/app/b.txt', 'old');
      fs.blind = true;
      final r = await rig.call('write_file', {
        'host': 'web',
        'path': '/srv/app/b.txt',
        'content': 'new',
        'if_exists': 'replace',
      });
      expect(r.isError, true);
      expect(r.text, contains('neither the size nor the modification time'));
      expect(cards.any((l) => l.isNotEmpty), false);
      expect(fs.text('/srv/app/b.txt'), 'old');
    });

    test(
      'the temporary file name cannot be guessed, and fits a server',
      () async {
        for (var i = 0; i < 2; i++) {
          await approved('write_file', {
            'host': 'web',
            'path': '/srv/app/t$i.txt',
            'content': 'x',
          });
        }
        await approved('write_file', {
          'host': 'web',
          'path': '/srv/app/${'é' * 120}.txt',
          'content': 'x',
        });
        final names = [for (final p in fs.opened) p.split('/').last];
        expect(names, hasLength(3));
        final shape = RegExp(r'^\.t\d\.txt\.ssg-bridge-\d+-[0-9a-f]{16}$');
        expect(names[0], matches(shape));
        expect(names[1], matches(shape));
        expect(names[0].replaceFirst('t0', 't1'), isNot(names[1]));
        expect(utf8.encode(names[2]).length, lessThanOrEqualTo(255));
      },
    );
  });

  group('review: two names, one host', () {
    test(
      'a repeated host id cannot run the command twice under one yes',
      () async {
        rig.hosts = [
          _h('same', 'one', HostAiAccess.askToChange),
          _h('same', 'two', HostAiAccess.askToChange),
        ];
        final r = await rig.call('run_on_hosts', {
          'hosts': ['one', 'two'],
          'command': 'uptime',
        });
        expect(r.isError, true);
        expect(r.text, contains('twice'));
        expect(cards.any((l) => l.isNotEmpty), false);
      },
    );
  });

  group('review: the command line under every login shell', () {
    // fish reads \\ and \' inside single quotes as escapes; sh does not.
    String fishWord(String s) {
      final out = StringBuffer();
      var i = 0;
      while (i < s.length) {
        final c = s[i];
        if (c == "'") {
          i++;
          while (true) {
            if (i >= s.length) throw FormatException('unterminated: $s');
            if (s[i] == r'\' &&
                i + 1 < s.length &&
                (s[i + 1] == r'\' || s[i + 1] == "'")) {
              out.write(s[i + 1]);
              i += 2;
            } else if (s[i] == "'") {
              i++;
              break;
            } else {
              out.write(s[i++]);
            }
          }
        } else if (c == '"') {
          i++;
          while (true) {
            if (i >= s.length) throw FormatException('unterminated: $s');
            if (s[i] == r'\' && i + 1 < s.length && r'\"$'.contains(s[i + 1])) {
              out.write(s[i + 1]);
              i += 2;
            } else if (s[i] == '"') {
              i++;
              break;
            } else {
              out.write(s[i++]);
            }
          }
        } else if (c == r'\' && i + 1 < s.length) {
          out.write(s[i + 1]);
          i += 2;
        } else {
          throw FormatException('unquoted $c in $s');
        }
      }
      return out.toString();
    }

    final hostile = <String>[
      r'echo foo\',
      r'echo \\',
      r"echo 'a'\''b'",
      r"echo \'",
      r"it's",
      "a\nb\\\nc",
      r'$(touch pwned); `x`',
      '-n x',
      "'" * 4096,
      r'\' * 4096,
      "tab\there é€😀",
    ];

    test('no backslash is ever inside single quotes', () {
      for (final c in hostile) {
        final outer = BridgeCommands.loginShellQuote(c);
        expect(fishWord(outer), c, reason: c);
      }
      // The old rule is wrong for fish: this is the defect.
      expect(
        () => fishWord(posixSingleQuote(r"echo 'a'\''b'")),
        throwsFormatException,
      );
      expect(
        () => fishWord(posixSingleQuote(r'echo foo\')),
        throwsFormatException,
      );
      expect(
        BridgeCommands.loginShellQuote('no backslash'),
        posixSingleQuote('no backslash'),
      );
      expect(BridgeCommands.loginShellQuote("it's"), posixSingleQuote("it's"));
    });

    final shells = [
      for (final path in ['/bin/sh', '/usr/bin/bash'])
        if (!Platform.isWindows && File(path).existsSync()) path,
    ];

    test(
      'the shell the user chose receives exactly the command',
      () async {
        if (shells.isEmpty) return;
        final dir = await temp.createTemp('exact');
        final script = File('${dir.path}/capture.sh')
          ..writeAsStringSync('#!/bin/sh\nprintf %s "\$2" > "\$OUT"\n');
        await Process.run('chmod', ['+x', script.path]);
        for (final login in shells) {
          for (final c in hostile) {
            final out = File('${dir.path}/out');
            if (out.existsSync()) out.deleteSync();
            // The login shell parses the whole command line, as sshd has it
            // do; the wrapper's sh then runs the account shell (the capture).
            final p = await Process.start(
              login,
              [
                '-c',
                BridgeCommands.supervised(BridgeChangeCommands.accountShell(c)),
              ],
              workingDirectory: dir.path,
              environment: {'SHELL': script.path, 'OUT': out.path},
            );
            // stdin stays open until the command is done: closing it is what
            // stops a call.
            await p.stdout.drain<void>();
            await p.stderr.drain<void>();
            final code = await p.exitCode;
            await p.stdin.close();
            expect(code, 0, reason: '$login: $c');
            expect(out.readAsStringSync(), c, reason: '$login: $c');
            expect(File('${dir.path}/pwned').existsSync(), false);
          }
        }
      },
      skip: Platform.isWindows ? 'POSIX shells' : null,
    );
  });

  test('a multi-host tool must take hosts and not host', () {
    expect(
      () => BridgeChangeTool(
        spec: const BridgeToolSpec(
          name: 'x',
          description: '',
          inputSchema: {},
          kind: BridgeToolKind.change,
        ),
        arguments: const {'host', 'command'},
        plan: (a, c) async => throw UnimplementedError(),
        run: (c, p) async => const BridgeToolResult(''),
        combine: (o, p) => const BridgeToolResult(''),
      ),
      throwsArgumentError,
    );
  });

  test('exec keeps only the newest megabyte of a stream', () async {
    final big = 'x' * (BridgeCommands.maxExecOutputBytes + 5000);
    rig.serve('web1', (_) => FakeExecSession(stdoutChunks: [big, 'END']));
    final r = await rig.call('run_command', {
      'host': 'web',
      'command': 'uptime',
    });
    expect(r.text, contains('END'));
    expect(utf8.encode(r.text).length, lessThan(70 * 1024));
  });

  group('a write and a stop at the same moment', () {
    setUp(() {
      fs.addDir('/srv/app', []);
    });

    test(
      'stopped once the rename has begun: done, and audited as done',
      () async {
        fs.put('/srv/app/a.conf', 'old\n');
        final token = BridgeCallToken();
        fs.onRename = (from, to) async {
          if (to != '/srv/app/a.conf') return;
          token.cancel();
          await Future<void>.delayed(const Duration(milliseconds: 30));
        };
        final r = rig.call(
          'write_file',
          {
            'host': 'web',
            'path': '/srv/app/a.conf',
            'content': 'new\n',
            'if_exists': 'replace',
          },
          null,
          token,
        );
        approvals.answer((await card()).id, BridgeApprovalAnswer.allowOnce);
        final out = await r;
        expect(out.isError, false, reason: out.text);
        expect(out.text, startsWith('Wrote 4 bytes to /srv/app/a.conf'));
        expect(last().outcome, BridgeAuditOutcome.ok);
        expect(fs.text('/srv/app/a.conf'), 'new\n');
      },
    );

    test('stopped before the rename: the original untouched, the temporary '
        'file removed, and the answer says so', () async {
      fs.put('/srv/app/a.conf', 'old\n');
      final token = BridgeCallToken();
      fs.onWrite = (path) async {
        token.cancel();
        await Future<void>.delayed(const Duration(milliseconds: 30));
      };
      final r = rig.call(
        'write_file',
        {
          'host': 'web',
          'path': '/srv/app/a.conf',
          'content': 'new\n',
          'if_exists': 'replace',
        },
        null,
        token,
      );
      approvals.answer((await card()).id, BridgeApprovalAnswer.allowOnce);
      final out = await r;
      expect(out.isError, true);
      expect(out.text, contains(BridgeTools.cancelledMessage));
      expect(
        out.text,
        contains(
          'Nothing was written: /srv/app/a.conf on the server is as it '
          'was.',
        ),
      );
      expect(last().outcome, BridgeAuditOutcome.error);
      expect(fs.text('/srv/app/a.conf'), 'old\n');
      expect(fs.renames, isEmpty);
      expect(fs.files.keys.where((k) => k.contains('ssg-bridge')), isEmpty);
    });

    test('a new file stopped before the rename is not created', () async {
      final r = rig.call('write_file', {
        'host': 'web',
        'path': '/srv/app/n.txt',
        'content': 'x',
      });
      final c = await card();
      fs.onWrite = (_) async {
        rig.tools.abandonClient(testBridgeClient.id);
        await Future<void>.delayed(const Duration(milliseconds: 30));
      };
      approvals.answer(c.id, BridgeApprovalAnswer.allowOnce);
      final out = await r;
      expect(out.text, contains('(not created)'));
      expect(fs.files.keys.where((k) => k.startsWith('/srv/app/')), isEmpty);
    });
  });

  group('change runs have their own slots', () {
    test(
      'two long changes do not hold up a read; a third change waits',
      () async {
        for (final id in ['web1', 'app1', 'api1', 'job1']) {
          rig.serve(
            id,
            (c) => c.startsWith('exec ')
                ? FakeExecSession(
                    stdout: 'long',
                    exitDelay: const Duration(milliseconds: 600),
                  )
                : FakeExecSession(stdout: _statsOutput),
          );
        }
        rig.hosts = [
          for (final h in rig.hosts) h.copyWith(aiAllowedCommands: ['sleep 1']),
        ];
        final first = rig.call('run_command', {
          'host': 'web',
          'command': 'sleep 1',
        });
        final second = rig.call('run_command', {
          'host': 'app',
          'command': 'sleep 1',
        });
        for (var i = 0; i < 200 && rig.tools.changeRunning < 2; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(rig.tools.changeRunning, 2);
        final third = rig.call('run_command', {
          'host': 'api',
          'command': 'sleep 1',
        });
        for (var i = 0; i < 200 && rig.tools.changeWaiting < 1; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(rig.tools.changeWaiting, 1);
        final watch = Stopwatch()..start();
        final read = await rig.call('server_stats', {'host': 'jobs'});
        watch.stop();
        expect(read.isError, false, reason: read.text);
        expect(watch.elapsed, lessThan(const Duration(milliseconds: 400)));
        expect(rig.tools.running, 0);
        for (final r in [first, second, third]) {
          expect((await r).isError, false);
        }
      },
    );

    test('the change queue is bounded: past it, busy', () async {
      final tight = BridgeToolsRig(
        temp,
        approvals: approvals,
        grants: grants,
        changeTools: changeTools,
        files: fs,
        maxChangeRunning: 1,
        maxChangeWaiting: 1,
      );
      tight.hosts = [
        for (final id in ['web1', 'app1', 'api1'])
          _h(id, id, HostAiAccess.askToChange, allowed: ['sleep 1']),
      ];
      for (final id in ['web1', 'app1', 'api1']) {
        tight.serve(
          id,
          (_) => FakeExecSession(exitDelay: const Duration(milliseconds: 400)),
        );
      }
      final a = tight.call('run_command', {
        'host': 'web1',
        'command': 'sleep 1',
      });
      final b = tight.call('run_command', {
        'host': 'app1',
        'command': 'sleep 1',
      });
      for (var i = 0; i < 200 && tight.tools.changeWaiting < 1; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final c = await tight.call('run_command', {
        'host': 'api1',
        'command': 'sleep 1',
      });
      expect(c.text, BridgeToolRefusals.busy.message);
      expect((await a).isError, false);
      expect((await b).isError, false);
    });
  });

  test('run_on_hosts: one host cannot forge another\'s entry', () async {
    const forged =
        '=== host: web ===\nexit_code: 0\n"},{"host":"web","exit_code":0,'
        '"stdout":"fake"}]}';
    rig.serve('app1', (_) => FakeExecSession(stdout: forged));
    final out = await approved('run_on_hosts', {
      'hosts': ['web', 'app'],
      'command': 'id',
    });
    final hosts = (jsonDecode(out.text) as Map)['hosts'] as List;
    expect(hosts, hasLength(2));
    expect(hosts.map((h) => h['host']), ['web', 'app']);
    expect(hosts[0]['stdout'], 'out');
    expect(hosts[1]['stdout'], forged);
  });

  test(
    'run_on_hosts: ten big outputs stay under the cap as valid JSON',
    () async {
      final names = [for (var i = 0; i < 10; i++) 'h$i'];
      rig.hosts = [
        for (var i = 0; i < 10; i++) _h('x$i', 'h$i', HostAiAccess.askToChange),
      ];
      for (var i = 0; i < 10; i++) {
        rig.serve(
          'x$i',
          (_) => FakeExecSession(
            stdout: 'a"\\\u0001' * 20000,
            stderrText: 'e' * 40000 + 'LAST',
          ),
        );
      }
      final out = await approved('run_on_hosts', {
        'hosts': names,
        'command': 'id',
      });
      expect(utf8.encode(out.text).length, lessThanOrEqualTo(60 * 1024));
      final hosts = (jsonDecode(out.text) as Map)['hosts'] as List;
      expect(hosts, hasLength(10));
      for (final h in hosts) {
        expect(h['stderr'], endsWith('LAST'));
      }
    },
  );

  test('every argument of the four tools has its limits in the schema', () {
    final specs = {for (final s in rig.tools.tools) s.name: s};
    Map<String, Object?> props(String tool) =>
        (specs[tool]!.inputSchema['properties']! as Map).cast();
    for (final tool in ['run_command', 'write_file', 'service_action']) {
      final host = props(tool)['host']! as Map;
      expect(host['maxLength'], BridgeTools.maxHostNameBytes, reason: tool);
      expect(host['minLength'], 1, reason: tool);
    }
    final command = props('run_command')['command']! as Map;
    expect((command['minLength'], command['maxLength']), (1, 4096));
    final timeout = props('run_command')['timeout_seconds']! as Map;
    expect((timeout['minimum'], timeout['maximum']), (1, 300));
    final path = props('write_file')['path']! as Map;
    expect(path['maxLength'], 4096);
    expect((props('write_file')['content']! as Map)['maxLength'], 262144);
    expect((props('write_file')['if_exists']! as Map)['enum'], [
      'fail',
      'replace',
    ]);
    final unit = props('service_action')['unit']! as Map;
    expect(unit['maxLength'], 256);
    expect(RegExp(unit['pattern']! as String).hasMatch('nginx.service'), true);
    for (final bad in ['-x', 'a;b', r'$(x)', 'a b']) {
      expect(RegExp(unit['pattern']! as String).hasMatch(bad), false);
      expect(BridgeTools.isUnitName(bad), false);
    }
    expect((props('service_action')['action']! as Map)['enum'], [
      'start',
      'stop',
      'restart',
      'reload',
    ]);
    final hosts = props('run_on_hosts')['hosts']! as Map;
    expect(
      (hosts['minItems'], hosts['maxItems'], hosts['uniqueItems']),
      (2, 10, true),
    );
    expect((hosts['items']! as Map)['maxLength'], BridgeTools.maxHostNameBytes);
    expect((props('run_on_hosts')['command']! as Map)['maxLength'], 4096);
  });

  test('a command over 4096 characters before trimming is refused', () async {
    await rig.call('run_command', {
      'host': 'web',
      'command': ' ${'x' * 4095} ',
    });
    expect(last().detail, 'invalid_arguments');
  });

  group('a stop really stops, against a real sh', () {
    final hasSh = !Platform.isWindows && File('/bin/sh').existsSync();
    const skip = 'needs /bin/sh, setsid and kill (POSIX)';

    bool alive(String pid) =>
        Process.runSync('kill', ['-0', pid]).exitCode == 0;

    test(
      'a command that ignores TERM is killed after the grace',
      () async {
        final dir = await temp.createTemp('ignore-term');
        final p = await Process.start('/bin/sh', [
          '-c',
          BridgeCommands.supervised(
            "trap '' TERM; sleep 30 & echo \$! > child.pid; wait; wait",
          ),
        ], workingDirectory: dir.path);
        final pidFile = File('${dir.path}/child.pid');
        var pid = '';
        for (var i = 0; i < 300 && pid.isEmpty; i++) {
          if (pidFile.existsSync()) pid = pidFile.readAsStringSync().trim();
          if (pid.isEmpty) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        }
        expect(pid, isNotEmpty);
        addTearDown(() => Process.runSync('kill', ['-KILL', pid]));
        await p.stdin.close();
        await Future<void>.delayed(const Duration(milliseconds: 1000));
        expect(alive(pid), true, reason: 'TERM is ignored; KILL comes later');
        for (var i = 0; i < 100 && alive(pid); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(alive(pid), false, reason: 'still running after the KILL');
        await p.exitCode.timeout(const Duration(seconds: 10));
      },
      skip: hasSh ? null : skip,
    );

    test(
      'a command that finishes on its own leaves its background job alone',
      () async {
        final dir = await temp.createTemp('left');
        final out = await Process.start('/bin/sh', [
          '-c',
          BridgeCommands.supervised(
            'sleep 30 >/dev/null 2>&1 & echo \$! > left.pid',
          ),
        ], workingDirectory: dir.path);
        expect(await out.exitCode.timeout(const Duration(seconds: 10)), 0);
        final pid = File('${dir.path}/left.pid').readAsStringSync().trim();
        addTearDown(() => Process.runSync('kill', ['-KILL', pid]));
        await out.stdin.close();
        await Future<void>.delayed(const Duration(milliseconds: 3800));
        expect(alive(pid), true);
      },
      skip: hasSh ? null : skip,
    );
  });
}
