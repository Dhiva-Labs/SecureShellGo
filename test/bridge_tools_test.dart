import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/app_settings.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/models/host_ai_access.dart';
import 'package:secure_shell_go/services/bridge/bridge_audit.dart';
import 'package:secure_shell_go/services/bridge/bridge_policy.dart';
import 'package:secure_shell_go/services/bridge/bridge_tool_types.dart';
import 'package:secure_shell_go/services/bridge/bridge_tools.dart';
import 'package:secure_shell_go/services/log_tail.dart';
import 'package:secure_shell_go/services/server_probe.dart';
import 'package:secure_shell_go/services/ssh_service.dart';
import 'package:secure_shell_go/services/systemd_units.dart';

import 'fake_exec_session.dart';
import 'support/bridge_fakes.dart';

const String _probeOutput =
    '#=ssg=kernel\nLinux 6.1.0\n'
    '#=ssg=host\nweb1\n'
    '#=ssg=uptime\n12345.6 1000.0\n'
    '#=ssg=load\n0.10 0.20 0.30 1/100 123\n'
    '#=ssg=cpu\n4\n';

/// Hostile values for every argument that could reach a shell.
const List<String> _hostile = [
  '; rm -rf /',
  r'$(touch pwned)',
  '`touch pwned`',
  "'; touch pwned; '",
  '-rf',
];

void main() {
  late Directory temp;
  late BridgeToolsRig rig;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('bridge_tools');
    rig = BridgeToolsRig(temp);
  });

  tearDown(() async {
    await rig.connections.closeAll();
    await temp.delete(recursive: true);
  });

  FakeExecTransport serveWeb(FakeExecSession Function(String c) respond) =>
      rig.serve('web1', respond);

  test('offers the seven read tools, all read-only, none taking a command', () {
    final names = rig.tools.tools.map((t) => t.name).toList();
    expect(names, [
      'list_hosts',
      'server_stats',
      'list_services',
      'tail_log',
      'list_dir',
      'read_file',
      'search_files',
    ]);
    for (final t in rig.tools.tools) {
      expect(t.kind, BridgeToolKind.read);
      final props = (t.inputSchema['properties'] as Map).keys;
      expect(props, isNot(contains('command')));
      expect(t.inputSchema['additionalProperties'], false);
    }
  });

  group('list_hosts', () {
    test('names only the shared hosts, without addresses by default', () async {
      final r = await rig.call('list_hosts');
      expect(r.isError, false);
      final hosts = (jsonDecode(r.text) as Map)['hosts'] as List;
      expect(hosts, [
        {'name': 'web'},
        {'name': 'db'},
      ]);
      expect(r.text, isNot(contains('secret')));
      expect(r.text, isNot(contains('example.test')));
    });

    test('shows address and username when the setting is on', () async {
      rig.settings = const AppSettings(
        bridgeEnabled: true,
        bridgeShowAddress: true,
      );
      final r = await rig.call('list_hosts');
      final hosts = (jsonDecode(r.text) as Map)['hosts'] as List;
      expect(hosts.first, {
        'name': 'web',
        'hostname': 'web1.example.test',
        'port': 22,
        'username': 'dev',
      });
    });
  });

  group('policy', () {
    test('a hidden host reads exactly like an unknown one, and is never '
        'contacted', () async {
      final hidden = rig.serve('sec1', (_) => FakeExecSession(stdout: 'x'));
      for (final tool in [
        'server_stats',
        'list_services',
        'list_dir',
        'read_file',
        'search_files',
        'tail_log',
      ]) {
        final a = await rig.call(tool, {'host': 'secret', 'path': '/etc'});
        final b = await rig.call(tool, {'host': 'nosuch', 'path': '/etc'});
        expect(a, b, reason: tool);
        expect(a.isError, true);
        expect(a.text, BridgeRefusals.hostNotAvailable.message);
      }
      // Not by its label, not by its id either.
      final byId = await rig.call('server_stats', {'host': 'sec1'});
      expect(byId.text, BridgeRefusals.hostNotAvailable.message);
      expect(hidden.commands, isEmpty);
      expect(rig.fs.realpaths, isEmpty);
    });

    test('a missing or non-string host is refused the same way', () async {
      for (final host in [null, 42, '', 'x' * 1000]) {
        final r = await rig.call('server_stats', {'host': ?host});
        expect(r.text, BridgeRefusals.hostNotAvailable.message);
      }
    });

    test('bridge off refuses everything, list_hosts included', () async {
      final web = serveWeb((_) => FakeExecSession(stdout: _probeOutput));
      rig.settings = const AppSettings();
      for (final tool in ['list_hosts', 'server_stats']) {
        final r = await rig.call(tool, {
          if (tool != 'list_hosts') 'host': 'web',
        });
        expect(r.isError, true);
        expect(r.text, BridgeRefusals.bridgeOff.message);
      }
      expect(web.commands, isEmpty);
      expect(rig.entries.map((e) => e.outcome).toSet(), {
        BridgeAuditOutcome.refused,
      });
      expect(rig.entries.first.detail, 'bridge_off');
    });

    test('a locked app refuses every call', () async {
      final web = serveWeb((_) => FakeExecSession(stdout: _probeOutput));
      rig.locked = true;
      for (final tool in ['list_hosts', 'server_stats', 'list_dir']) {
        final r = await rig.call(tool, {
          if (tool != 'list_hosts') 'host': 'web',
          if (tool == 'list_dir') 'path': '/',
        });
        expect(r.text, BridgeRefusals.appLocked.message, reason: tool);
      }
      expect(web.commands, isEmpty);
      rig.locked = false;
      expect((await rig.call('server_stats', {'host': 'web'})).isError, false);
    });

    test('unknown arguments are refused before anything runs', () async {
      final web = serveWeb((_) => FakeExecSession(stdout: _probeOutput));
      final r = await rig.call('server_stats', {
        'host': 'web',
        'command': 'id',
      });
      expect(r.isError, true);
      expect(r.text, contains('unknown argument "command"'));
      expect(web.commands, isEmpty);
      expect(rig.entries.single.detail, 'invalid_arguments');
    });
  });

  test('server_stats runs the fixed probe and reports what it read', () async {
    final web = serveWeb((_) => FakeExecSession(stdout: _probeOutput));
    final r = await rig.call('server_stats', {'host': 'web'});
    expect(r.isError, false);
    expect(web.commands, [ServerProbeCommands.probe]);
    final json = jsonDecode(r.text) as Map;
    // The server's own name is withheld while addresses are hidden.
    expect(json.containsKey('hostname'), false);
    expect(json['kernel'], 'Linux 6.1.0');
    expect(json['cpus'], 4);
    expect(json['uptime_seconds'], 12345);
    expect(json['load'], [0.1, 0.2, 0.3]);
  });

  group('list_services', () {
    test('lists units', () async {
      final web = serveWeb(
        (c) => c == SystemdCommands.probe
            ? FakeExecSession()
            : FakeExecSession(
                stdout:
                    'nginx.service loaded active running A web server\n'
                    'cron.service loaded failed failed Cron\n',
              ),
      );
      final r = await rig.call('list_services', {'host': 'web'});
      expect(r.isError, false);
      expect(web.commands, [SystemdCommands.probe, SystemdCommands.listUnits]);
      expect(r.text, contains('nginx.service\tactive\trunning\tA web server'));
      expect(r.text, contains('cron.service\tfailed\tfailed\tCron'));
    });

    test('says so when there is no systemd', () async {
      serveWeb((_) => FakeExecSession(exitCode: 1));
      final r = await rig.call('list_services', {'host': 'web'});
      expect(r.isError, true);
      expect(r.text, SystemdUnavailable.message);
    });
  });

  group('tail_log', () {
    test('a unit reads its journal once', () async {
      final web = serveWeb(
        (c) => FakeExecSession(
          stdout: c.startsWith('journalctl') ? 'l1\nl2\n' : '',
        ),
      );
      final r = await rig.call('tail_log', {
        'host': 'web',
        'unit': 'nginx.service',
        'lines': 50,
      });
      expect(r.isError, false);
      expect(r.text, 'l1\nl2\n');
      expect(web.commands.last, BridgeCommands.journal('nginx.service', 50));
      expect(
        web.commands.last,
        "journalctl --no-pager -q -o short-iso -n 50 -u 'nginx.service'",
      );
      expect(web.commands.last, isNot(contains(' -f')));
    });

    test('a path is resolved, guarded, then tailed once', () async {
      rig.fs.addFile('/var/log/app/current.log', 'x');
      rig.fs.links['/var/log/app.log'] = '/var/log/app/current.log';
      final web = serveWeb((c) => FakeExecSession(stdout: 'tail out'));
      final r = await rig.call('tail_log', {
        'host': 'web',
        'path': '/var/log/app.log',
      });
      expect(r.isError, false);
      expect(web.commands, [
        LogTailCommands.probeReadable('/var/log/app/current.log'),
        BridgeCommands.tailFile('/var/log/app/current.log', 100),
      ]);
    });

    test('a link into ~/.ssh is refused, and nothing runs', () async {
      rig.fs.addFile('/home/dev/.ssh/id_ed25519', 'KEY');
      rig.fs.links['/var/log/innocent.log'] = '/home/dev/.ssh/id_ed25519';
      final web = serveWeb((_) => FakeExecSession(stdout: 'KEY'));
      final r = await rig.call('tail_log', {
        'host': 'web',
        'path': '/var/log/innocent.log',
      });
      expect(r.isError, true);
      expect(r.text, BridgeToolRefusals.pathNotAvailable.message);
      expect(web.commands, isEmpty);
    });

    test('argument validation', () async {
      final web = serveWeb((_) => FakeExecSession());
      final bad = <Map<String, Object?>>[
        {'host': 'web'},
        {'host': 'web', 'unit': 'a.service', 'path': '/var/log/x'},
        {'host': 'web', 'unit': 'a.service', 'lines': 0},
        {'host': 'web', 'unit': 'a.service', 'lines': 501},
        {'host': 'web', 'unit': 'a.service', 'lines': 2.5},
        {'host': 'web', 'unit': 'a.service', 'lines': '10'},
        {'host': 'web', 'unit': 7},
        {'host': 'web', 'unit': 'a\nb.service'},
        {'host': 'web', 'unit': 'a\u0000b'},
        {'host': 'web', 'unit': 'x' * 300},
        for (final h in _hostile) {'host': 'web', 'unit': h},
      ];
      for (final args in bad) {
        final r = await rig.call('tail_log', args);
        expect(r.isError, true, reason: '$args');
        expect(r.text, startsWith('Invalid arguments'), reason: '$args');
      }
      expect(web.commands, isEmpty);
      final ok = await rig.call('tail_log', {
        'host': 'web',
        'unit': 'getty@tty1.service',
        'lines': 500,
      });
      expect(ok.isError, false);
    });

    test('a hostile file name reaches the shell single-quoted', () async {
      const path = r'/var/log/x; rm -rf / $(id) `id`';
      rig.fs.addFile(path, '');
      final web = serveWeb((_) => FakeExecSession());
      await rig.call('tail_log', {'host': 'web', 'path': path});
      expect(web.commands.last, BridgeCommands.tailFile(path, 100));
      expect(web.commands.last, contains("-- '$path'"));
    });
  });

  group('list_dir', () {
    test('lists, dropping blocked entries', () async {
      rig.fs.addDir('/home/dev', ['notes.txt', '.env', 'id_rsa', 'app']);
      serveWeb((_) => FakeExecSession());
      final r = await rig.call('list_dir', {'host': 'web', 'path': '~'});
      expect(r.isError, false);
      expect(r.text, startsWith('/home/dev\n'));
      expect(r.text, contains('notes.txt'));
      expect(r.text, contains('app'));
      expect(r.text, isNot(contains('.env')));
      expect(r.text, isNot(contains('id_rsa')));
      // Blocked entries leave no trace: no note, no count.
      expect(r.text, isNot(contains('hidden')));
      expect(r.text.trim().split('\n'), hasLength(3));
      // A directory holding only blocked entries reads as an empty one.
      rig.fs.addDir('/srv/keys', ['a.pem', 'b.key']);
      rig.fs.addDir('/srv/none', []);
      final onlyBlocked = await rig.call('list_dir', {
        'host': 'web',
        'path': '/srv/keys',
      });
      final empty = await rig.call('list_dir', {
        'host': 'web',
        'path': '/srv/none',
      });
      expect(
        onlyBlocked.text.replaceFirst('/srv/keys', ''),
        empty.text.replaceFirst('/srv/none', ''),
      );
    });

    test(
      'the guard judges the canonical path, not the one asked for',
      () async {
        rig.fs.addDir('/home/dev/.ssh', ['id_ed25519', 'config']);
        rig.fs.links['/home/dev/keys'] = '/home/dev/.ssh';
        serveWeb((_) => FakeExecSession());
        final viaLink = await rig.call('list_dir', {
          'host': 'web',
          'path': '/home/dev/keys',
        });
        final direct = await rig.call('list_dir', {
          'host': 'web',
          'path': '/home/dev/.ssh',
        });
        final missing = await rig.call('list_dir', {
          'host': 'web',
          'path': '/home/dev/nope',
        });
        for (final r in [viaLink, direct, missing]) {
          expect(r.isError, true);
          expect(r.text, BridgeToolRefusals.pathNotAvailable.message);
        }
        expect(rig.fs.reads, isEmpty);
      },
    );

    test('settings are read per call', () async {
      rig.fs.addDir('/srv/app', ['a']);
      serveWeb((_) => FakeExecSession());
      expect(
        (await rig.call('list_dir', {
          'host': 'web',
          'path': '/srv/app',
        })).isError,
        false,
      );
      rig.settings = const AppSettings(
        bridgeEnabled: true,
        bridgeExtraBlockedPaths: ['/srv/app'],
      );
      final r = await rig.call('list_dir', {'host': 'web', 'path': '/srv/app'});
      expect(r.text, BridgeToolRefusals.pathNotAvailable.message);
    });

    test('readSensitivePaths opens the built-in list', () async {
      rig.fs.addDir('/home/dev/.ssh', ['config']);
      serveWeb((_) => FakeExecSession());
      rig.settings = const AppSettings(
        bridgeEnabled: true,
        bridgeReadSensitivePaths: true,
      );
      final r = await rig.call('list_dir', {
        'host': 'web',
        'path': '/home/dev/.ssh',
      });
      expect(r.isError, false);
      expect(r.text, contains('config'));
    });

    test('paths with a NUL or line break are refused', () async {
      serveWeb((_) => FakeExecSession());
      for (final p in ['/etc\n/passwd', '/etc\u0000x', '/a\rb', '']) {
        final r = await rig.call('list_dir', {'host': 'web', 'path': p});
        expect(r.text, startsWith('Invalid arguments'), reason: p);
      }
      expect(rig.fs.realpaths, isEmpty);
    });
  });

  group('read_file', () {
    test('reads only the window asked for', () async {
      rig.fs.addFile('/etc/hosts', '0123456789abcdef');
      serveWeb((_) => FakeExecSession());
      final r = await rig.call('read_file', {
        'host': 'web',
        'path': '/etc/hosts',
        'offset': 4,
        'max_bytes': 5,
      });
      expect(r.isError, false);
      expect(r.text, contains('bytes: 4-9 of 16'));
      expect(r.text, contains('next_offset: 9'));
      expect(r.text, endsWith('45678'));
      expect(rig.fs.reads, ['/etc/hosts@4+5', '/etc/hosts@0+8192']);
    });

    test('defaults to, and is capped at, 64 KiB', () async {
      rig.fs.files['/var/big.txt'] = Uint8List.fromList(
        List.filled(200 * 1024, 0x61),
      );
      serveWeb((_) => FakeExecSession());
      final r = await rig.call('read_file', {
        'host': 'web',
        'path': '/var/big.txt',
      });
      expect(r.isError, false);
      expect(rig.fs.reads, ['/var/big.txt@0+65536']);
      final over = await rig.call('read_file', {
        'host': 'web',
        'path': '/var/big.txt',
        'max_bytes': 65537,
      });
      expect(over.text, startsWith('Invalid arguments'));
      final negative = await rig.call('read_file', {
        'host': 'web',
        'path': '/var/big.txt',
        'offset': -1,
      });
      expect(negative.text, startsWith('Invalid arguments'));
    });

    test('refuses binary files and directories', () async {
      rig.fs.files['/bin/ls'] = Uint8List.fromList([0x7f, 0x45, 0, 1]);
      rig.fs.addDir('/etc', []);
      serveWeb((_) => FakeExecSession());
      final bin = await rig.call('read_file', {
        'host': 'web',
        'path': '/bin/ls',
      });
      expect(bin.isError, true);
      expect(bin.text, contains('binary'));
      final dir = await rig.call('read_file', {'host': 'web', 'path': '/etc'});
      expect(dir.isError, true);
      expect(dir.text, contains('list_dir'));
    });

    test('a blocked file is refused like a missing one', () async {
      rig.fs.addFile('/srv/app/.env', 'SECRET=1');
      rig.fs.links['/srv/app/config.txt'] = '/srv/app/.env';
      serveWeb((_) => FakeExecSession());
      final blocked = await rig.call('read_file', {
        'host': 'web',
        'path': '/srv/app/config.txt',
      });
      final missing = await rig.call('read_file', {
        'host': 'web',
        'path': '/srv/app/missing.txt',
      });
      expect(blocked, missing);
      expect(blocked.text, isNot(contains('SECRET')));
      expect(rig.fs.reads, isEmpty);
    });

    test(
      'private keys in a file the user opened up are still redacted',
      () async {
        rig.fs.addFile(
          '/srv/notes.txt',
          'before\n-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n'
              '-----END OPENSSH PRIVATE KEY-----\nafter',
        );
        serveWeb((_) => FakeExecSession());
        final r = await rig.call('read_file', {
          'host': 'web',
          'path': '/srv/notes.txt',
        });
        expect(r.text, contains('[private key redacted]'));
        expect(r.text, isNot(contains('AAAA')));
      },
    );
  });

  group('search_files', () {
    test('finds names, drops blocked results and stray lines', () async {
      rig.fs.addDir('/srv', []);
      final web = serveWeb(
        (_) => FakeExecSession(
          stdout:
              '/srv/a.conf\n/srv/app/.env\n/srv/u/.ssh/x.conf\n'
              'fragment of a name\n/srv/b.conf\n',
        ),
      );
      final r = await rig.call('search_files', {
        'host': 'web',
        'dir': '/srv',
        'name': '*.conf',
        'max_results': 10,
      });
      expect(r.isError, false);
      expect(r.text, '/srv/a.conf\n/srv/b.conf\n');
      expect(web.commands, [
        BridgeCommands.findByName('/srv', '*.conf', depth: 4, limit: 90),
      ]);
      expect(
        web.commands.single,
        contains("find '/srv' -maxdepth 4 -name '*.conf'"),
      );
      expect(web.commands.single, isNot(contains('cat')));
      expect(web.commands.single, isNot(contains('grep')));
    });

    test('argument validation', () async {
      rig.fs.addDir('/srv', []);
      final web = serveWeb((_) => FakeExecSession());
      final bad = <Map<String, Object?>>[
        {'host': 'web', 'dir': '/srv'},
        {'host': 'web', 'dir': '/srv', 'name': 'a/b'},
        {'host': 'web', 'dir': '/srv', 'name': 'a', 'max_results': 0},
        {'host': 'web', 'dir': '/srv', 'name': 'a', 'max_results': 201},
        {'host': 'web', 'dir': '/srv', 'name': 'a', 'max_depth': 9},
        {'host': 'web', 'dir': '/srv', 'name': 'a\nb'},
        {'host': 'web', 'dir': '/srv', 'name': 'x' * 300},
      ];
      for (final args in bad) {
        final r = await rig.call('search_files', args);
        expect(r.text, startsWith('Invalid arguments'), reason: '$args');
      }
      expect(web.commands, isEmpty);
    });

    test('hostile patterns are quoted', () async {
      rig.fs.addDir('/srv', []);
      final web = serveWeb((_) => FakeExecSession());
      // A name with a slash is refused outright; the rest reach the shell.
      final names = [
        for (final h in _hostile)
          if (!h.contains('/')) h,
      ];
      for (final h in names) {
        await rig.call('search_files', {
          'host': 'web',
          'dir': '/srv',
          'name': h,
        });
      }
      expect(web.commands, hasLength(names.length));
      for (var i = 0; i < names.length; i++) {
        final quoted = "'${names[i].replaceAll("'", r"'\''")}'";
        expect(web.commands[i], contains('-name $quoted -print'));
      }
    });
  });

  group('shell quoting against a real sh', () {
    final hasSh = File('/bin/sh').existsSync();

    Future<void> runIn(Directory dir, String command) async {
      await Process.run('/bin/sh', ['-c', command], workingDirectory: dir.path);
    }

    test(
      'find and tail run nothing from their arguments',
      () async {
        final dir = await temp.createTemp('sh');
        for (final h in [..._hostile, 'a\nb', r'$(touch pwned)\n']) {
          await runIn(
            dir,
            BridgeCommands.findByName(dir.path, h, depth: 1, limit: 5),
          );
          await runIn(dir, BridgeCommands.tailFile('${dir.path}/$h', 5));
          await runIn(dir, BridgeCommands.journal(h, 5));
        }
        expect(File('${dir.path}/pwned').existsSync(), false);
        expect(dir.listSync(), isEmpty);
      },
      skip: hasSh ? null : 'needs /bin/sh',
    );

    test(
      'find really matches the pattern by name',
      () async {
        final dir = await temp.createTemp('find');
        File('${dir.path}/a.conf').writeAsStringSync('secret contents');
        File('${dir.path}/b.txt').writeAsStringSync('');
        final out = await Process.run('/bin/sh', [
          '-c',
          BridgeCommands.findByName(dir.path, '*.conf', depth: 2, limit: 5),
        ]);
        expect((out.stdout as String).trim(), '${dir.path}/a.conf');
        expect(out.stdout, isNot(contains('secret contents')));
      },
      skip: hasSh ? null : 'needs /bin/sh',
    );
  });

  group('limits', () {
    test('at most four calls run at once; the rest wait their turn', () async {
      rig.serve(
        'web1',
        (_) => FakeExecSession(stdout: _probeOutput),
        delay: const Duration(milliseconds: 150),
      );
      final calls = [
        for (var i = 0; i < 6; i++) rig.call('server_stats', {'host': 'web'}),
      ];
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(rig.tools.running, 4);
      expect(rig.tools.waiting, 2);
      final results = await Future.wait(calls);
      expect(results.every((r) => !r.isError), true);
      expect(rig.tools.running, 0);
    });

    test('a full queue refuses instead of growing', () async {
      final tight = BridgeToolsRig(
        await temp.createTemp('tight'),
        maxRunning: 1,
        maxWaiting: 1,
      );
      tight.serve(
        'web1',
        (_) => FakeExecSession(stdout: _probeOutput),
        delay: const Duration(milliseconds: 100),
      );
      final a = tight.call('server_stats', {'host': 'web'});
      final b = tight.call('server_stats', {'host': 'web'});
      final c = await tight.call('server_stats', {'host': 'web'});
      expect(c.isError, true);
      expect(c.text, BridgeToolRefusals.busy.message);
      expect((await a).isError, false);
      expect((await b).isError, false);
      expect(tight.entries.map((e) => e.detail), contains('busy'));
    });

    test('a call that runs past its time is stopped and says so', () async {
      final slow = BridgeToolsRig(
        await temp.createTemp('slow'),
        callTimeout: const Duration(milliseconds: 100),
      );
      slow.serve(
        'web1',
        (_) => FakeExecSession(stdout: _probeOutput),
        delay: const Duration(seconds: 2),
      );
      final watch = Stopwatch()..start();
      final r = await slow.call('server_stats', {'host': 'web'});
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
      expect(r.isError, true);
      expect(r.text, contains('took longer than'));
      expect(slow.entries.single.outcome, BridgeAuditOutcome.error);
      expect(slow.tools.running, 0);
    });
  });

  test('a scrubber that throws never lets the raw output out', () async {
    final broken = BridgeToolsRig(
      await temp.createTemp('broken'),
      scrub: (_) => throw StateError('boom'),
    );
    broken.fs.addFile('/srv/notes.txt', 'PRECIOUS');
    broken.serve('web1', (_) => FakeExecSession());
    final r = await broken.call('read_file', {
      'host': 'web',
      'path': '/srv/notes.txt',
    });
    expect(r.isError, true);
    expect(r.text, 'The output could not be made safe to return.');
    expect(r.text, isNot(contains('PRECIOUS')));
    expect(broken.entries.single.outcome, BridgeAuditOutcome.error);
  });

  test('every call leaves exactly one audit entry', () async {
    rig.fs.addFile('/srv/a.txt', 'a');
    rig.fs.addDir('/srv', []);
    serveWeb((_) => FakeExecSession(stdout: _probeOutput));
    final calls = <(String, Map<String, Object?>)>[
      ('list_hosts', {}),
      ('server_stats', {'host': 'web'}),
      ('server_stats', {'host': 'secret'}),
      ('read_file', {'host': 'web', 'path': '/srv/a.txt'}),
      ('read_file', {'host': 'web', 'path': '/home/dev/.ssh/id_rsa'}),
      ('list_dir', {'host': 'web', 'path': '/srv', 'extra': 1}),
      ('no_such_tool', {}),
      ('tail_log', {'host': 'web', 'unit': '; rm -rf /'}),
    ];
    for (final (name, args) in calls) {
      await rig.call(name, args);
    }
    await pumpEventQueue();
    expect(rig.entries, hasLength(calls.length));
    expect(rig.entries.map((e) => e.tool), calls.map((c) => c.$1));
    expect(rig.entries.map((e) => e.outcome), [
      BridgeAuditOutcome.ok,
      BridgeAuditOutcome.ok,
      BridgeAuditOutcome.refused,
      BridgeAuditOutcome.ok,
      BridgeAuditOutcome.refused,
      BridgeAuditOutcome.refused,
      BridgeAuditOutcome.refused,
      BridgeAuditOutcome.refused,
    ]);
    expect(rig.entries[1].host, 'web');
    expect(rig.entries[1].client, 'Test assistant');
    // The output itself is never in the log.
    final onDisk = await rig.audit.recent(limit: 50);
    expect(onDisk, hasLength(calls.length));
    expect(
      jsonEncode(onDisk.map((e) => e.toJson()).toList()),
      isNot(contains('Linux 6.1.0')),
    );
  });

  test('a failed audit write does not fail the call', () async {
    final file = File('${temp.path}/not-a-dir')..writeAsStringSync('x');
    final rig2 = BridgeToolsRig(Directory(file.path));
    final r = await rig2.call('list_hosts');
    expect(r.isError, false);
    expect(rig2.audit.lastWriteError, isNotNull);
  });

  test('a session that cannot run anything is an error, not a crash', () async {
    serveWeb((_) => FakeExecSession()).failWith = StateError('channel refused');
    final r = await rig.call('server_stats', {'host': 'web'});
    expect(r.isError, true);
    expect(rig.entries.single.outcome, BridgeAuditOutcome.error);
  });

  test('timeouts never escape as exceptions', () async {
    await expectLater(
      rig
          .call('server_stats', {'host': 'web'})
          .timeout(const Duration(seconds: 5)),
      completion(isA<({String text, bool isError})>()),
    );
  });

  group('adversarial review', () {
    Future<BridgeToolsRig> rigWith(
      Future<SessionTransport> Function(Host, SshCredentials) dialer, {
      Duration callTimeout = const Duration(seconds: 30),
      Duration idle = const Duration(seconds: 60),
      bool showAddress = false,
    }) async {
      final r = BridgeToolsRig(
        await temp.createTemp('adv'),
        dialer: dialer,
        callTimeout: callTimeout,
        idleTimeout: idle,
      );
      r.settings = AppSettings(
        bridgeEnabled: true,
        bridgeShowAddress: showAddress,
      );
      addTearDown(r.connections.closeAll);
      return r;
    }

    test('connect errors never carry the address, port or user while '
        'addresses are hidden', () async {
      final errors = <Object>[
        const SshConnectionException(
          'Timed out connecting to web1.example.test:22. A firewall may be '
          'dropping the connection.',
        ),
        const SshConnectionException(
          'Connection refused by WEB1.example.test on port 2222. Is dev@web1 ok?',
        ),
        SocketException(
          'Connection refused',
          address: InternetAddress('10.1.2.3'),
          port: 22,
        ),
        Exception('failed for dev@web1.example.test:22 via 192.168.7.9'),
      ];
      for (final e in errors) {
        final r = await rigWith((_, _) async => throw e);
        final out = await r.call('server_stats', {'host': 'web'});
        expect(out.isError, true);
        for (final secret in [
          'web1.example.test',
          '10.1.2.3',
          '192.168.7.9',
          '2222',
          ':22',
        ]) {
          expect(
            out.text.toLowerCase(),
            isNot(contains(secret.toLowerCase())),
            reason: '${out.text} (from $e)',
          );
        }
        expect(r.entries.single.detail, isNot(contains('web1.example.test')));
      }
    });

    test(
      'with addresses shown a connect error is passed on as it is',
      () async {
        final r = await rigWith(
          (_, _) async => throw const SshConnectionException(
            'Timed out connecting to web1.example.test:22.',
          ),
          showAddress: true,
        );
        final out = await r.call('server_stats', {'host': 'web'});
        expect(out.text, contains('web1.example.test:22'));
      },
    );

    test('a hidden jump host is not named in an error either', () async {
      final r = await rigWith(
        (_, _) async => throw const SshConnectionException(
          'Could not reach the jump host "secret" (sec1.example.test:22). '
          'Timed out.',
        ),
      );
      r.hosts = [
        bridgeHost('web1', 'web').copyWith(jumpHostId: 'sec1'),
        bridgeHost('sec1', 'secret', access: HostAiAccess.off),
      ];
      final out = await r.call('server_stats', {'host': 'web'});
      expect(out.isError, true);
      expect(out.text, isNot(contains('secret')));
      expect(out.text, isNot(contains('sec1.example.test')));
    });

    test(
      'a hidden and an unknown host answer alike whatever the arguments',
      () async {
        for (final args in <Map<String, Object?>>[
          {'bogus': 1},
          {'path': 42},
          {'path': '/x\u0000y', 'lines': -5},
          {'name': 'a/b', 'dir': ''},
          {'unit': '--file=/etc/passwd', 'path': '/x'},
        ]) {
          for (final tool in [
            'tail_log',
            'read_file',
            'list_dir',
            'search_files',
            'server_stats',
          ]) {
            final a = await rig.call(tool, {'host': 'secret', ...args});
            final b = await rig.call(tool, {'host': 'nosuch', ...args});
            expect(a, b, reason: '$tool $args');
          }
        }
        expect(rig.fs.realpaths, isEmpty);
      },
    );

    test('a dial that outlasts the call is stopped, and its lease is given '
        'back so the connection can go idle', () async {
      final gate = Completer<void>();
      final dialled = <FakeExecTransport>[];
      final r = await rigWith(
        (host, _) async {
          await gate.future;
          final t = FakeExecTransport(host: host);
          dialled.add(t);
          return t;
        },
        callTimeout: const Duration(milliseconds: 100),
        idle: const Duration(milliseconds: 50),
      );
      final out = await r.call('server_stats', {'host': 'web'});
      expect(out.isError, true);
      expect(out.text, contains('took longer than'));
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      // Nothing was run on the server after the deadline, and the dialled
      // connection was not left leased: it idled out and hung up.
      expect(dialled.single.commands, isEmpty);
      expect(dialled.single.closed, true);
      expect(r.connections.cachedCount, 0);
    });

    test(
      'a symlink entry from list_dir is judged again when it is read',
      () async {
        serveWeb((_) => FakeExecSession(stdout: 'PRIVATE'));
        rig.fs.addDir('/srv/app', ['notes']);
        rig.fs.addFile('/home/dev/.ssh/id_x', 'PRIVATE');
        rig.fs.links['/srv/app/notes'] = '/home/dev/.ssh/id_x';
        final listing = await rig.call('list_dir', {
          'host': 'web',
          'path': '/srv/app',
        });
        expect(listing.text, contains('notes'));
        for (final tool in ['read_file', 'tail_log']) {
          serveWeb((_) => FakeExecSession(stdout: 'PRIVATE'));
          final r = await rig.call(tool, {
            'host': 'web',
            'path': '/srv/app/notes',
          });
          expect(r.isError, true, reason: tool);
          expect(r.text, isNot(contains('PRIVATE')), reason: tool);
        }
        expect(rig.commands, isEmpty);
      },
    );

    test('option-looking values never become options', () async {
      final web = serveWeb((_) => FakeExecSession());
      rig.fs.addDir('/home/dev', []);
      for (final unit in ['-n', '--file=/etc/passwd', '-D/x', '', ' -x']) {
        final r = await rig.call('tail_log', {'host': 'web', 'unit': unit});
        expect(r.isError, true, reason: unit);
      }
      expect(web.commands, isEmpty);
      await rig.call('search_files', {
        'host': 'web',
        'dir': '.',
        'name': '-delete',
      });
      final find = web.commands.single;
      expect(find, startsWith("if command -v timeout"));
      expect(find, contains("find '/home/dev' -maxdepth"));
      expect(find, contains("-name '-delete' -print"));
    });

    group('real sh', () {
      final hasSh = File('/bin/sh').existsSync();

      test(
        'find treats -delete / -exec / ! / ( as plain name patterns',
        () async {
          final dir = await temp.createTemp('opts');
          for (final n in ['keep.txt', '-delete', '-exec', '!', '(']) {
            File('${dir.path}/$n').writeAsStringSync('x');
          }
          for (final pattern in ['-delete', '-exec', '!', '(', '-o', '*']) {
            await Process.run('/bin/sh', [
              '-c',
              BridgeCommands.findByName(dir.path, pattern, depth: 1, limit: 50),
            ]);
          }
          expect(dir.listSync().length, 5);
        },
        skip: hasSh ? null : 'needs /bin/sh',
      );

      test(
        'tail of a file with one enormous line stays bounded',
        () async {
          final dir = await temp.createTemp('big');
          File(
            '${dir.path}/one-line.log',
          ).writeAsStringSync('x' * (2 * 1024 * 1024));
          File('${dir.path}/lines.log').writeAsStringSync(
            [for (var i = 1; i <= 10; i++) 'line $i'].join('\n'),
          );
          final big = await Process.run('/bin/sh', [
            '-c',
            BridgeCommands.tailFile('${dir.path}/one-line.log', 5),
          ]);
          expect(
            (big.stdout as String).length,
            lessThanOrEqualTo(BridgeCommands.tailWindowBytes),
          );
          final small = await Process.run('/bin/sh', [
            '-c',
            BridgeCommands.tailFile('${dir.path}/lines.log', 2),
          ]);
          expect((small.stdout as String).trim(), 'line 9\nline 10');
        },
        skip: hasSh ? null : 'needs /bin/sh',
      );
    });

    test(
      'tail_log reports a failing first tail instead of an empty log',
      () async {
        rig.fs.addFile('/var/log/a.log', 'x');
        serveWeb(
          (c) => c.startsWith('tail -c')
              ? FakeExecSession(stderrText: 'tail: error reading')
              : FakeExecSession(),
        );
        final r = await rig.call('tail_log', {
          'host': 'web',
          'path': '/var/log/a.log',
        });
        expect(r.isError, true);
      },
    );
  });
}
