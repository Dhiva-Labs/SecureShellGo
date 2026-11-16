import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/app_settings.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/models/host_ai_access.dart';
import 'package:secure_shell_go/services/bridge/bridge_approvals.dart';
import 'package:secure_shell_go/services/bridge/bridge_audit.dart';
import 'package:secure_shell_go/services/bridge/bridge_change_tools.dart';
import 'package:secure_shell_go/services/bridge/bridge_client_store.dart';
import 'package:secure_shell_go/services/bridge/bridge_connections.dart';
import 'package:secure_shell_go/services/bridge/bridge_paths.dart';
import 'package:secure_shell_go/services/bridge/bridge_redactor.dart';
import 'package:secure_shell_go/services/bridge/bridge_terminals.dart';
import 'package:secure_shell_go/services/bridge/bridge_tools.dart';
import 'package:secure_shell_go/services/device_storage.dart';
import 'package:secure_shell_go/services/known_hosts_service.dart';
import 'package:secure_shell_go/services/session_controller.dart';
import 'package:secure_shell_go/services/session_foreground.dart';
import 'package:secure_shell_go/services/session_manager.dart';
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

  group('the changing tools on a real server', () {
    late BridgeTools tools;
    late BridgeApprovals approvals;
    late String work;
    var caseNo = 0;
    final cards = <BridgeApprovalRequest>[];

    /// What the "user" does with a card: by default allows it once.
    void Function(BridgeApprovalRequest card)? onCard;

    final client = BridgeClient(
      id: 'c',
      name: 'lab assistant',
      tokenHash: 'x',
      createdAt: DateTime.utc(2026),
    );

    Host writable(String id) => lab.host.copyWith(
      id: id,
      label: id,
      aiAccess: HostAiAccess.askToChange,
    );

    setUpAll(() async {
      if (skip != null) return;
      final auditDir = Directory(lab.at('audit-change'))..createSync();
      final connections = BridgeConnections(
        openTransport: (_) => connection,
        credentialLookup: (_) async => null,
        dialer: (_, _) async => throw StateError('not used'),
      );
      final redactor = BridgeRedactor(scrub: (s) => s);
      approvals = BridgeApprovals(timedApprovalMinutes: () => 0);
      tools = BridgeTools(
        loadHosts: () async => [writable('labw'), writable('labx')],
        settings: () => const AppSettings(bridgeEnabled: true),
        isAppLocked: () => false,
        connections: connections,
        redactor: redactor,
        audit: BridgeAuditLog(scrub: (s) => s, directory: auditDir),
        approvals: approvals,
        changeTools: BridgeChangeTools(redactor: redactor).build(),
      );
      final seen = <String>{};
      approvals.pending.listen((list) {
        for (final r in list) {
          if (!seen.add(r.id)) continue;
          cards.add(r);
          scheduleMicrotask(() {
            final handler = onCard;
            if (handler != null) {
              handler(r);
            } else {
              approvals.answer(r.id, BridgeApprovalAnswer.allowOnce);
            }
          });
        }
      });
    });

    setUp(() {
      if (skip != null) return;
      work = '${Directory(data).parent.path}/work-${++caseNo}';
      Directory(work).createSync();
      cards.clear();
      onCard = null;
    });

    Future<({String text, bool isError})> call(
      String tool,
      Map<String, Object?> args,
    ) async {
      final r = await tools.call(client, tool, {'host': 'labw', ...args});
      return (text: r.text, isError: r.isError);
    }

    List<String> ls() =>
        Directory(
          work,
        ).listSync().map((e) => e.path.split('/').last).toList()..sort();

    bool alive(String pid) =>
        Process.runSync('kill', ['-0', pid]).exitCode == 0;

    test(
      'run_command: exit code, stdout and stderr, after one card',
      () async {
        final r = await call('run_command', {
          'command': 'echo out; echo err >&2; exit 3',
        });
        expect(r.isError, false, reason: r.text);
        expect(r.text, contains('exit_code: 3'));
        expect(r.text, contains('stdout:\nout\n'));
        expect(r.text, contains('stderr:\nerr'));
        expect(cards, hasLength(1));
        final summary = cards.single.summary as CommandSummary;
        expect(summary.command, 'echo out; echo err >&2; exit 3');
      },
      skip: skip,
    );

    test(
      'run_command: a hostile quoted command is exactly what runs',
      () async {
        // Quotes, '\'' runs, backticks, $(), backslashes, a newline: all
        // data to printf, and nothing else runs.
        const payload = r'''it's 'q' `x` $(touch PWNED) \\ \ ''';
        final command =
            "cd '$work'\n"
            r"printf %s 'it'\''s '\''q'\'' `x` $(touch PWNED) \\ \ ' "
            '> hostile.txt';
        final r = await call('run_command', {'command': command});
        expect(r.isError, false, reason: r.text);
        expect(r.text, contains('exit_code: 0'));
        expect(File('$work/hostile.txt').readAsStringSync(), payload);
        expect(File('$work/PWNED').existsSync(), false);
        expect(File('PWNED').existsSync(), false);
        expect(
          (cards.single.summary as CommandSummary).command,
          command.trim(),
        );
      },
      skip: skip,
    );

    test(
      'run_command: a command ending in a backslash and 4000 quotes arrive '
      'whole',
      () async {
        // The first line ends in a backslash: the shell's own error about
        // this text, and nothing else runs.
        final r = await call('run_command', {
          'command': "cd '$work'; echo a > one.txt; echo b\\",
        });
        expect(r.isError, false, reason: r.text);
        expect(File('$work/one.txt').readAsStringSync(), 'a\n');
        final quotes = "'" * 4000;
        final r2 = await call('run_command', {
          'command': "cd '$work'; echo $quotes > two.txt",
        });
        expect(r2.isError, false, reason: r2.text);
        expect(File('$work/two.txt').existsSync(), true);
        expect(File('$work/two.txt').readAsStringSync(), '\n');
      },
      skip: skip,
    );

    test('run_command has no stdin: cat ends at once', () async {
      final r = await call('run_command', {
        'command': 'cat; echo done; exit 0',
        'timeout_seconds': 20,
      });
      expect(r.isError, false, reason: r.text);
      expect(r.text, contains('stdout:\ndone'));
    }, skip: skip);

    test(
      'run_command: past timeout_seconds the run ends, returns nothing, and '
      'the sleep is killed',
      () async {
        final watch = Stopwatch()..start();
        final r = await call('run_command', {
          'command':
              "cd '$work'; echo before; sleep 60 & echo \$! > child.pid; wait",
          'timeout_seconds': 3,
        });
        watch.stop();
        expect(r.isError, true);
        expect(r.text, contains('took longer than 3 seconds'));
        expect(r.text, isNot(contains('before')));
        expect(watch.elapsed.inSeconds, lessThan(15));
        final pid = File('$work/child.pid').readAsStringSync().trim();
        for (var i = 0; i < 100 && alive(pid); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(alive(pid), false, reason: 'the sleep $pid still runs');
      },
      skip: skip,
    );

    test(
      'run_command: what a stopped call does and does not end — a nohup '
      'child dies with the group, a setsid child (and one left running by a '
      'finished command) outlives the call',
      () async {
        final started = <String>[];
        addTearDown(() {
          for (final pid in started) {
            Process.runSync('kill', ['-KILL', pid]);
          }
        });
        // Timed out: the group gets TERM. nohup keeps the child in it.
        final r = await call('run_command', {
          'command':
              "cd '$work'; nohup sleep 61 >/dev/null 2>&1 & echo \$! > nohup.pid; "
              "setsid sleep 62 >/dev/null 2>&1 & echo \$! > setsid.pid; "
              'sleep 60',
          'timeout_seconds': 3,
        });
        expect(r.isError, true);
        final nohupPid = File('$work/nohup.pid').readAsStringSync().trim();
        final setsidPid = File('$work/setsid.pid').readAsStringSync().trim();
        started.addAll([nohupPid, setsidPid]);
        for (var i = 0; i < 100 && alive(nohupPid); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(alive(nohupPid), false, reason: 'a nohup child dies with the group');

        // A child that ignores TERM is killed after the grace.
        final stubborn = await call('run_command', {
          'command':
              "cd '$work'; trap '' TERM; sleep 64 & echo \$! > stubborn.pid; "
              'wait; wait',
          'timeout_seconds': 2,
        });
        expect(stubborn.isError, true);
        final stubbornPid =
            File('$work/stubborn.pid').readAsStringSync().trim();
        started.add(stubbornPid);
        for (var i = 0; i < 150 && alive(stubbornPid); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(
          alive(stubbornPid),
          false,
          reason: 'a TERM-ignoring child is killed after the grace',
        );
        // ignore: avoid_print
        print('setsid child after a timed-out call: alive=${alive(setsidPid)}');
        expect(alive(setsidPid), true, reason: 'documented: setsid escapes');

        // A command that finishes normally leaves what it backgrounded.
        final done = await call('run_command', {
          'command':
              "cd '$work'; nohup sleep 63 >/dev/null 2>&1 & echo \$! > left.pid",
        });
        expect(done.isError, false, reason: done.text);
        final left = File('$work/left.pid').readAsStringSync().trim();
        started.add(left);
        expect(alive(left), true, reason: 'documented: a finished call leaves it');
      },
      skip: skip,
    );

    test('run_command: a denied card runs nothing', () async {
      onCard = (c) => approvals.answer(c.id, BridgeApprovalAnswer.deny);
      final r = await call('run_command', {
        'command': "cd '$work' && touch ran",
      });
      expect(r.isError, true);
      expect(r.text, contains('denied'));
      expect(File('$work/ran').existsSync(), false);
    }, skip: skip);

    test('run_command: a private key it prints comes back redacted', () async {
      final r = await call('run_command', {
        'command':
            "printf '%s\\n' '-----BEGIN OPENSSH PRIVATE KEY-----' "
            "'b3BlbnNzaC1rZXktdjEAAAAAsecretsecretsecret' "
            "'-----END OPENSSH PRIVATE KEY-----'",
      });
      expect(r.isError, false, reason: r.text);
      expect(r.text, isNot(contains('secretsecret')));
    }, skip: skip);

    test(
      'write_file: a new file, byte for byte, no temporary file left',
      () async {
        const content = 'café €\r\nsecond\r\n\ttabbed\n﻿bom-ish';
        final r = await call('write_file', {
          'path': '$work/new.txt',
          'content': content,
        });
        expect(r.isError, false, reason: r.text);
        expect(File('$work/new.txt').readAsBytesSync(), utf8.encode(content));
        expect(ls(), ['new.txt']);
        final summary = cards.single.summary as FileWriteSummary;
        expect(summary.path, '$work/new.txt');
        expect(summary.bytes, utf8.encode(content).length);
        expect(summary.replacesExisting, false);
      },
      skip: skip,
    );

    test(
      'write_file: replace keeps the mode; fail leaves a file alone',
      () async {
        final f = File('$work/run.sh')
          ..writeAsStringSync('#!/bin/sh\necho old\n');
        Process.runSync('chmod', ['750', f.path]);
        final denied = await call('write_file', {
          'path': f.path,
          'content': 'x',
        });
        expect(denied.isError, true);
        expect(denied.text, contains('already exists'));
        expect(cards, isEmpty);
        expect(f.readAsStringSync(), contains('old'));

        final r = await call('write_file', {
          'path': f.path,
          'content': '#!/bin/sh\necho new\n',
          'if_exists': 'replace',
        });
        expect(r.isError, false, reason: r.text);
        expect(f.readAsStringSync(), '#!/bin/sh\necho new\n');
        expect(f.statSync().mode & 0x1ff, 488); // 0750
        expect(ls(), ['run.sh']);
        final summary = cards.single.summary as FileWriteSummary;
        expect(summary.replacesExisting, true);
        expect(summary.preview, contains('-echo old'));
        expect(summary.preview, contains('+echo new'));
      },
      skip: skip,
    );

    test(
      'write_file: a symlink to an allowed file writes that file, and the '
      'link stays',
      () async {
        final real = File('$work/real.txt')..writeAsStringSync('old');
        Link('$work/alias.txt').createSync(real.path);
        final r = await call('write_file', {
          'path': '$work/alias.txt',
          'content': 'new',
          'if_exists': 'replace',
        });
        expect(r.isError, false, reason: r.text);
        expect(real.readAsStringSync(), 'new');
        expect(FileSystemEntity.isLinkSync('$work/alias.txt'), true);
        expect((cards.single.summary as FileWriteSummary).path, real.path);
      },
      skip: skip,
    );

    test(
      'write_file: a symlink into a blocked directory is refused as a read '
      'of it is, with no card, and the key is untouched',
      () async {
        final r = await call('write_file', {
          'path': '$data/link.txt',
          'content': 'pwned',
          'if_exists': 'replace',
        });
        expect(r.isError, true);
        expect(r.text, BridgeToolRefusals.pathNotAvailable.message);
        expect(cards, isEmpty);
        expect(File(secretKey).readAsStringSync(), 'NOT A REAL KEY');
        // A dangling link made here, to a new file there.
        final sshDir = File(secretKey).parent.path;
        Link('$work/dangling').createSync('$sshDir/authorized_keys');
        final d = await call('write_file', {
          'path': '$work/dangling',
          'content': 'pwned',
        });
        expect(d.isError, true);
        expect(d.text, BridgeToolRefusals.pathNotAvailable.message);
        expect(File('$sshDir/authorized_keys').existsSync(), false);
        // And a blocked path by name, existing or not, and through "..".
        final base = Directory(data).parent.path;
        for (final path in [
          secretKey,
          '$sshDir/id_new',
          '$work/../home/.ssh/x',
          '$base/work-$caseNo/../home/.ssh/id_ed25519',
        ]) {
          final b = await call('write_file', {'path': path, 'content': 'p'});
          expect(
            b.text,
            BridgeToolRefusals.pathNotAvailable.message,
            reason: path,
          );
        }
        expect(cards, isEmpty);
        expect(ls(), ['dangling']);
        expect(File(secretKey).readAsStringSync(), 'NOT A REAL KEY');
      },
      skip: skip,
    );

    test('write_file: a dangling symlink to an allowed place', () async {
      Link('$work/soon').createSync('$work/target.txt');
      final r = await call('write_file', {
        'path': '$work/soon',
        'content': 'hello',
      });
      // OpenSSH's realpath follows the link to its missing target: the
      // file is created there, the card names it, and the link stays.
      expect(r.isError, false, reason: r.text);
      expect(FileSystemEntity.isLinkSync('$work/soon'), true);
      expect((cards.single.summary as FileWriteSummary).path, '$work/target.txt');
      expect(File('$work/target.txt').readAsStringSync(), 'hello');
    }, skip: skip);

    test('write_file: a missing parent, a directory and a FIFO', () async {
      final missing = await call('write_file', {
        'path': '$work/nodir/f.txt',
        'content': 'x',
      });
      expect(missing.isError, true);
      expect(Directory('$work/nodir').existsSync(), false);
      Directory('$work/dir').createSync();
      final dir = await call('write_file', {
        'path': '$work/dir',
        'content': 'x',
        'if_exists': 'replace',
      });
      expect(dir.isError, true);
      expect(dir.text, contains('is a directory'));
      final fifo = await call('write_file', {
        'path': '$data/pipe',
        'content': 'x',
        'if_exists': 'replace',
      }).timeout(const Duration(seconds: 20));
      expect(fifo.isError, true);
      expect(fifo.text, contains('not a regular file'));
      expect(cards, isEmpty);
    }, skip: skip);

    test('write_file: a file changed after the card is not written', () async {
      final f = File('$work/c.txt')..writeAsStringSync('one');
      onCard = (c) {
        f.writeAsStringSync('changed meanwhile, longer');
        approvals.answer(c.id, BridgeApprovalAnswer.allowOnce);
      };
      final r = await call('write_file', {
        'path': f.path,
        'content': 'mine',
        'if_exists': 'replace',
      });
      expect(r.isError, true);
      expect(r.text, contains('changed on the server'));
      expect(f.readAsStringSync(), 'changed meanwhile, longer');
      expect(ls(), ['c.txt']);
    }, skip: skip);

    test('write_file: a file created after the card is not overwritten',
        () async {
      final f = File('$work/late.txt');
      onCard = (c) {
        f.writeAsStringSync('theirs');
        approvals.answer(c.id, BridgeApprovalAnswer.allowOnce);
      };
      final r = await call('write_file', {'path': f.path, 'content': 'mine'});
      expect(r.isError, true);
      expect(f.readAsStringSync(), 'theirs');
      expect(ls(), ['late.txt']);
    }, skip: skip);

    test(
      'write_file: a symlink planted at the old, guessable temporary name '
      'is not written through',
      () async {
        // The old name was .<name>.ssg-bridge-<ms>: plant links for every
        // millisecond around now, pointing at a file outside the directory.
        final victim = File('${Directory(data).parent.path}/victim-$caseNo')
          ..writeAsStringSync('untouched');
        final now = DateTime.now().millisecondsSinceEpoch;
        for (var ms = now - 200; ms < now + 600; ms++) {
          Link('$work/.p.txt.ssg-bridge-$ms').createSync(victim.path);
        }
        final r = await call('write_file', {
          'path': '$work/p.txt',
          'content': 'x',
        });
        expect(r.isError, false, reason: r.text);
        expect(victim.readAsStringSync(), 'untouched');
        expect(File('$work/p.txt').readAsStringSync(), 'x');
        expect(FileSystemEntity.isLinkSync('$work/p.txt'), false);
      },
      skip: skip,
    );

    test(
      'service_action: the command reaches systemctl (a unit that does not '
      'exist), and a hostile unit never does',
      () async {
        final r = await call('service_action', {
          'unit': 'ssgo-test-no-such-unit.service',
          'action': 'start',
        });
        // ignore: avoid_print
        print(
          'service_action on a missing unit: '
          '${r.text.replaceAll('\n', ' | ')}',
        );
        expect(r.isError, true);
        expect(r.text, isNot(contains('failed unexpectedly')));
        expect(cards, hasLength(1));
        expect((cards.single.summary as ServiceActionSummary).action, 'start');
        for (final unit in [
          '--now',
          '-x.service',
          'a b',
          'a;touch x',
          "a'b",
        ]) {
          final bad = await call('service_action', {
            'unit': unit,
            'action': 'stop',
          });
          expect(bad.isError, true, reason: unit);
          expect(bad.text, contains('not a systemd unit'), reason: unit);
        }
        expect(cards, hasLength(1));
      },
      skip: skip,
    );

    test('run_on_hosts: one card, both hosts run, each its own section',
        () async {
      final r = await tools.call(client, 'run_on_hosts', {
        'hosts': ['labw', 'labx'],
        'command': "cd '$work' && echo hi >> both.txt && echo ran",
      });
      expect(r.isError, false, reason: r.text);
      final hosts = (jsonDecode(r.text) as Map)['hosts'] as List;
      expect(hosts.map((h) => h['host']), ['labw', 'labx']);
      expect(hosts.map((h) => h['exit_code']), [0, 0]);
      expect(hosts.map((h) => h['stdout']), ['ran\n', 'ran\n']);
      expect(cards, hasLength(1));
      expect(File('$work/both.txt').readAsStringSync(), 'hi\nhi\n');
    }, skip: skip);
  });

  group('no bridge connection carries the user\'s SSH agent', () {
    final client = BridgeClient(
      id: 'c',
      name: 'lab assistant',
      tokenHash: 'x',
      createdAt: DateTime.utc(2026),
    );
    final sockLine = RegExp(r'\[sock:([^\]\n]*)\]');

    Host forwardingHost() => lab.host.copyWith(
      aiAccess: HostAiAccess.askToChange,
      agentForwarding: true,
      x11Forwarding: true,
    );

    /// What `$SSH_AUTH_SOCK` is in an exec channel opened on [t].
    Future<String?> sockOnExec(SessionTransport t) async {
      final session = await t.execute('echo "[sock:\$SSH_AUTH_SOCK]"');
      final out = await session.stdout
          .cast<List<int>>()
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 10));
      session.close();
      return sockLine.firstMatch(out)?.group(1);
    }

    /// The user's own session on a host with agent forwarding on, its
    /// shell open (which is what asks the server to forward the agent).
    Future<SshConnection> userSession() async {
      final mine = await lab.connectAs(forwardingHost());
      final shell = await mine.startShell(columns: 80, rows: 24);
      shell.stdout.listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 500));
      return mine;
    }

    /// `run_command` printing `$SSH_AUTH_SOCK`, through the bridge as the
    /// app wires it, with [open] as the user's open session (or none).
    Future<({String? sock, List<Host> dialled, String text})> runCommand(
      SessionTransport? open,
    ) async {
      final host = forwardingHost();
      final dialled = <Host>[];
      final connections = BridgeConnections(
        openTransport: (_) => open,
        credentialLookup: (_) async => SshCredentials(
          privateKeyPem: File(lab.at('userkey')).readAsStringSync(),
        ),
        dialer: (h, _) {
          dialled.add(h);
          return lab.connectAs(h);
        },
      );
      final approvals = BridgeApprovals(timedApprovalMinutes: () => 0);
      approvals.pending.listen((list) {
        for (final r in list) {
          scheduleMicrotask(
            () => approvals.answer(r.id, BridgeApprovalAnswer.allowOnce),
          );
        }
      });
      final redactor = BridgeRedactor(scrub: (s) => s);
      final tools = BridgeTools(
        loadHosts: () async => [host],
        settings: () => const AppSettings(bridgeEnabled: true),
        isAppLocked: () => false,
        connections: connections,
        redactor: redactor,
        audit: BridgeAuditLog(
          scrub: (s) => s,
          directory: Directory(lab.at('audit-agent'))
            ..createSync(recursive: true),
        ),
        approvals: approvals,
        changeTools: BridgeChangeTools(redactor: redactor).build(),
      );
      final r = await tools.call(client, 'run_command', {
        'host': 'lab',
        'command': 'echo "[sock:\$SSH_AUTH_SOCK]"',
      });
      expect(r.isError, false, reason: r.text);
      await connections.closeAll();
      await approvals.dispose();
      return (
        sock: sockLine.firstMatch(r.text)?.group(1),
        dialled: dialled,
        text: r.text,
      );
    }

    test('control: an exec channel on the user\'s forwarding session DOES '
        'get the agent once its shell has asked for it, so borrowing that '
        'transport would leak it', () async {
      final mine = await userSession();
      final sock = await sockOnExec(mine);
      // ignore: avoid_print
      print('exec on the user\'s forwarding session: SSH_AUTH_SOCK="$sock"');
      expect(sock, isNotNull);
      expect(sock, isNotEmpty);
      mine.close();
    }, skip: skip);

    test('run_command with the user\'s forwarding session open: the bridge '
        'does not borrow it, dials its own without forwarding, and gets no '
        'agent', () async {
      final mine = await userSession();
      final r = await runCommand(mine);
      // ignore: avoid_print
      print('bridge run_command beside a forwarding session: '
          'SSH_AUTH_SOCK="${r.sock}"');
      expect(r.sock, '', reason: r.text);
      expect(r.dialled, hasLength(1), reason: 'its own connection');
      expect(r.dialled.single.agentForwarding, false);
      expect(r.dialled.single.x11Forwarding, false);
      // The user's session is untouched and still forwards for the user.
      expect(mine.isClosed, false);
      expect(await sockOnExec(mine), isNotEmpty);
      mine.close();
    }, skip: skip);

    test('run_command with no session open: a bridge-dialled connection to '
        'a forwarding host gets no agent, even after a shell on it', () async {
      final r = await runCommand(null);
      expect(r.sock, '', reason: r.text);
      expect(r.dialled.single.agentForwarding, false);

      // A shell on a connection dialled the way the bridge dials it
      // (dialOwned, the terminal's dial) asks for nothing either.
      final connections = BridgeConnections(
        openTransport: (_) => null,
        credentialLookup: (_) async => SshCredentials(
          privateKeyPem: File(lab.at('userkey')).readAsStringSync(),
        ),
        dialer: (h, _) => lab.connectAs(h),
      );
      final own = await connections.dialOwned(forwardingHost());
      final shell = await own.startShell(columns: 80, rows: 24);
      shell.stdout.listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(await sockOnExec(own), '');
      own.close();
    }, skip: skip);
  });

  group('the assistant terminal on a real server', () {
    late SessionManager sessions;
    late BridgeTerminals terminals;
    late BridgeApprovals approvals;
    late BridgeTools tools;
    final client = BridgeClient(
      id: 'c',
      name: 'lab assistant',
      tokenHash: 'x',
      createdAt: DateTime.utc(2026),
    );

    setUpAll(() async {
      if (skip != null) return;
      final host = lab.host.copyWith(
        aiAccess: HostAiAccess.askToChange,
        aiTerminal: true,
      );
      sessions = SessionManager(
        foreground: SessionForegroundController(channel: _NoForeground()),
        createController: (connection, resolve, credentials) =>
            SessionController(
              connection: connection,
              storage: _NoStorage(),
              resolveRemoteTarget: resolve,
            ),
      );
      // A connection of the terminal's own, as `dialOwned` gives.
      terminals = BridgeTerminals(
        sessions: sessions,
        dial: (_) => lab.connect(),
      );
      approvals = BridgeApprovals(timedApprovalMinutes: () => 0);
      final auditDir = Directory(lab.at('terminal-audit'))..createSync();
      tools = BridgeTools(
        loadHosts: () async => [host],
        settings: () => const AppSettings(bridgeEnabled: true),
        isAppLocked: () => false,
        connections: BridgeConnections(
          openTransport: (_) => null,
          credentialLookup: (_) async => null,
          dialer: (_, _) async => throw StateError('not used'),
        ),
        redactor: BridgeRedactor(scrub: (s) => s),
        audit: BridgeAuditLog(scrub: (s) => s, directory: auditDir),
        approvals: approvals,
        changeTools: [terminals.openTool],
        terminalUseTools: terminals.useTools,
      );
    });

    tearDownAll(() async {
      if (skip != null) return;
      await terminals.dispose();
      await sessions.dispose();
      await approvals.dispose();
    });

    test('open, echo hello, see it on the screen, close', () async {
      final answered = approvals.pending
          .firstWhere((p) => p.isNotEmpty)
          .then(
            (p) => approvals.answer(
              p.single.id,
              BridgeApprovalAnswer.allowOnce,
            ),
          );
      final opened = await tools.call(client, 'open_terminal', {
        'host': 'lab',
      });
      await answered;
      expect(opened.isError, false, reason: opened.text);
      final id = RegExp(
        r'terminal_id: (\S+)',
      ).firstMatch(opened.text)!.group(1)!;
      expect(sessions.length, 1);
      expect(sessions.sessions.single.controller.assistantDrive, isNotNull);

      final sent = await tools.call(client, 'send_input', {
        'terminal_id': id,
        'text': 'echo hello\n',
      });
      expect(sent.isError, false, reason: sent.text);

      var screen = '';
      for (var i = 0; i < 50; i++) {
        final r = await tools.call(client, 'read_screen', {'terminal_id': id});
        expect(r.isError, false, reason: r.text);
        screen = r.text;
        if (screen.split('\n').any((l) => l.trim() == 'hello')) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      // ignore: avoid_print
      print('read_screen:\n$screen');
      expect(screen.split('\n').map((l) => l.trim()), contains('hello'));

      final closed = await tools.call(client, 'close_terminal', {
        'terminal_id': id,
      });
      expect(closed.isError, false, reason: closed.text);
      expect(sessions.length, 0);
      final after = await tools.call(client, 'read_screen', {
        'terminal_id': id,
      });
      expect(after.isError, true);
    }, skip: skip);

    final other = BridgeClient(
      id: 'c-other',
      name: 'second assistant',
      tokenHash: 'y',
      createdAt: DateTime.utc(2026),
    );

    Future<String> openOne() async {
      final answered = approvals.pending
          .firstWhere((p) => p.isNotEmpty)
          .then(
            (p) => approvals.answer(
              p.single.id,
              BridgeApprovalAnswer.allowOnce,
            ),
          );
      final opened = await tools.call(client, 'open_terminal', {
        'host': 'lab',
      });
      await answered;
      expect(opened.isError, false, reason: opened.text);
      return RegExp(r'terminal_id: (\S+)').firstMatch(opened.text)!.group(1)!;
    }

    Future<({String text, bool isError})> send(String id, String text) async {
      final r = await tools.call(client, 'send_input', {
        'terminal_id': id,
        'text': text,
      });
      return (text: r.text, isError: r.isError);
    }

    /// Reads the screen until [done] holds for it (or ~8 s).
    Future<String> screenUntil(
      String id,
      bool Function(String screen) done,
    ) async {
      var screen = '';
      for (var i = 0; i < 80; i++) {
        final r = await tools.call(client, 'read_screen', {'terminal_id': id});
        screen = r.text;
        if (done(screen)) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      return screen;
    }

    bool hasLine(String screen, String line) =>
        screen.split('\n').any((l) => l.trim() == line);

    bool alive(String pid) =>
        Process.runSync('kill', ['-0', pid]).exitCode == 0;

    String everything(SessionController c) => [
      for (var i = 0; i < c.terminal.buffer.lines.length; i++)
        c.terminal.buffer.lines[i].getText(),
    ].join('\n');

    test('a control character arrives byte for byte: Ctrl-C ends a running '
        'command and the prompt comes back', () async {
      final id = await openOne();
      expect((await send(id, 'sleep 4711\n')).isError, false);
      for (var i = 0; i < 50; i++) {
        if (Process.runSync('pgrep', ['-x', 'sleep']).exitCode == 0 &&
            Process.runSync('pgrep', ['-f', '^sleep 4711']).exitCode == 0) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(
        Process.runSync('pgrep', ['-f', '^sleep 4711']).exitCode,
        0,
        reason: 'the command is running on the server',
      );
      expect((await send(id, '\u0003')).isError, false);
      expect((await send(id, 'echo back-done\n')).isError, false);
      final screen = await screenUntil(id, (s) => hasLine(s, 'back-done'));
      expect(hasLine(screen, 'back-done'), true, reason: screen);
      expect(
        Process.runSync('pgrep', ['-f', '^sleep 4711']).exitCode,
        isNot(0),
        reason: 'Ctrl-C reached the server and stopped the command',
      );
      await tools.call(client, 'close_terminal', {'terminal_id': id});
    }, skip: skip);

    test('the user typing takes over: the next send_input and read_screen '
        'are refused, nothing more reaches the shell, and the session '
        'stays open', () async {
      final id = await openOne();
      expect((await send(id, 'echo mine-one\n')).isError, false);
      await screenUntil(id, (s) => hasLine(s, 'mine-one'));
      final controller = sessions.sessions.single.controller;
      // The user's keystrokes, as a pane delivers them.
      controller.terminal.textInput('echo user-one\n');
      final refused = await send(id, 'echo late-one\n');
      expect(refused.isError, true);
      expect(refused.text, BridgeTerminalRefusals.takenOver.message);
      final read = await tools.call(client, 'read_screen', {
        'terminal_id': id,
      });
      expect(read.isError, true);
      expect(sessions.length, 1);
      for (var i = 0; i < 80; i++) {
        if (everything(controller).split('\n').map((l) => l.trim()).contains(
          'user-one',
        )) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      final lines = everything(controller).split('\n').map((l) => l.trim());
      expect(lines, contains('user-one'));
      expect(lines, isNot(contains('late-one')));
      await terminals.stop(id);
      expect(sessions.length, 0);
    }, skip: skip);

    test('stop closes the shell on the server', () async {
      final id = await openOne();
      final file = lab.at('shell-pid');
      expect((await send(id, 'echo \$\$ > $file\n')).isError, false);
      var pid = '';
      for (var i = 0; i < 80; i++) {
        if (File(file).existsSync()) pid = File(file).readAsStringSync().trim();
        if (pid.isNotEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(int.tryParse(pid), isNotNull, reason: 'got "$pid"');
      expect(alive(pid), true);
      await terminals.stop(id);
      for (var i = 0; i < 50 && alive(pid); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(alive(pid), false, reason: 'the shell process is gone');
      expect(sessions.length, 0);
    }, skip: skip);

    test('a second client cannot use, read, close or detect the terminal',
        () async {
      final id = await openOne();
      for (final (tool, args) in [
        ('send_input', {'terminal_id': id, 'text': 'echo stolen\n'}),
        ('read_screen', {'terminal_id': id}),
        ('close_terminal', {'terminal_id': id}),
      ]) {
        final theirs = await tools.call(other, tool, args);
        final unknown = await tools.call(other, tool, {
          ...args,
          'terminal_id': 'term-00000000-00000000-00000000-00000000',
        });
        expect(theirs.isError, true);
        expect(theirs.text.codeUnits, unknown.text.codeUnits);
      }
      expect(sessions.length, 1, reason: "the owner's terminal is untouched");
      expect((await send(id, 'echo ok-two\n')).isError, false);
      final screen = await screenUntil(id, (s) => hasLine(s, 'ok-two'));
      expect(hasLine(screen, 'ok-two'), true, reason: screen);
      expect(hasLine(screen, 'stolen'), false);
      await tools.call(client, 'close_terminal', {'terminal_id': id});
    }, skip: skip);

    test("the host's agent forwarding is not applied to the assistant's "
        'shell (and is to an ordinary session, so this test can fail)',
        () async {
      final forwarding = lab.host.copyWith(
        aiAccess: HostAiAccess.askToChange,
        aiTerminal: true,
        agentForwarding: true,
      );
      // Control: a session the user opens on this host forwards it.
      final mine = sessions.open(await lab.connectAs(forwarding));
      mine.controller.terminal.resize(120, 32);
      await mine.controller.ensureShell();
      mine.controller.terminal.textInput('echo "[sock:\$SSH_AUTH_SOCK]"\n');
      final sockLine = RegExp(r'^\[sock:(.*)\]\s*$', multiLine: true);
      var seen = '';
      for (var i = 0; i < 80; i++) {
        seen = everything(mine.controller);
        if (sockLine.hasMatch(seen)) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      // ignore: avoid_print
      print('control (ordinary session): ${sockLine.firstMatch(seen)?.group(0)}');
      // The assistant's, through BridgeTerminals as the app wires it.
      final own = BridgeTerminals(
        sessions: sessions,
        dial: (h) => lab.connectAs(h),
      );
      final asTools = BridgeTools(
        loadHosts: () async => [forwarding],
        settings: () => const AppSettings(bridgeEnabled: true),
        isAppLocked: () => false,
        connections: BridgeConnections(
          openTransport: (_) => null,
          credentialLookup: (_) async => null,
          dialer: (_, _) async => throw StateError('not used'),
        ),
        redactor: BridgeRedactor(scrub: (s) => s),
        audit: BridgeAuditLog(
          scrub: (s) => s,
          directory: Directory(lab.at('terminal-audit-fwd'))..createSync(),
        ),
        approvals: approvals,
        changeTools: [own.openTool],
        terminalUseTools: own.useTools,
      );
      final answered = approvals.pending
          .firstWhere((p) => p.isNotEmpty)
          .then(
            (p) => approvals.answer(
              p.single.id,
              BridgeApprovalAnswer.allowOnce,
            ),
          );
      final opened = await asTools.call(client, 'open_terminal', {
        'host': 'lab',
      });
      await answered;
      expect(opened.isError, false, reason: opened.text);
      final id = RegExp(
        r'terminal_id: (\S+)',
      ).firstMatch(opened.text)!.group(1)!;
      await asTools.call(client, 'send_input', {
        'terminal_id': id,
        'text': 'echo "[asst:\$SSH_AUTH_SOCK]"\n',
      });
      final asstLine = RegExp(r'^\[asst:(.*)\]\s*$', multiLine: true);
      var screen = '';
      for (var i = 0; i < 80; i++) {
        screen = (await asTools.call(client, 'read_screen', {
          'terminal_id': id,
        })).text;
        if (asstLine.hasMatch(screen)) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(
        asstLine.firstMatch(screen)?.group(1),
        '',
        reason: 'no agent socket in the assistant shell:\n$screen',
      );
      await own.dispose();
      await sessions.close(mine.id);
    }, skip: skip);
  });
}

class _NoForeground implements SessionForegroundChannel {
  @override
  Future<void> start(String label) async {}

  @override
  Future<void> stop() async {}
}

class _NoStorage implements DeviceStorage {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('storage is not used here');
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

  Future<SshConnection> connect() => connectAs(host);

  /// Signs in as [target] (the host's own forwarding settings included).
  Future<SshConnection> connectAs(Host target) =>
      SshService(
        knownHosts: KnownHostsService(file: File(at('known_hosts.json'))),
      ).connect(
        host: target,
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
