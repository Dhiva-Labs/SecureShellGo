import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/bridge/bridge_cli_connector.dart';

/// One call the fake runner saw.
class Call {
  Call(
    this.executable,
    this.arguments, {
    this.stdin,
    this.timeout,
    this.environment,
    this.runInShell = false,
  });

  final String executable;
  final List<String> arguments;
  final String? stdin;
  final Duration? timeout;
  final Map<String, String>? environment;
  final bool runInShell;

  String get joined => arguments.join(' ');
}

/// A fake `claude` that answers by its arguments and records every call.
class FakeCli {
  FakeCli([Map<String, BridgeProcessResult>? answers])
    : answers = {...defaults, ...?answers};

  static const ok = BridgeProcessResult(exitCode: 0);

  static final defaults = <String, BridgeProcessResult>{
    '--version': const BridgeProcessResult(
      exitCode: 0,
      stdout: '2.1.322 (Claude Code)\n',
    ),
    'plugin marketplace list --json': BridgeProcessResult(
      exitCode: 0,
      stdout: jsonEncode([
        {'name': 'example-plugins', 'source': 'github'},
      ]),
    ),
    'plugin marketplace add Dhiva-Labs/SecureShellGo': ok,
    'plugin install secureshellgo@dhiva-labs': ok,
    'plugin configure secureshellgo@dhiva-labs --values-stdin': ok,
    'plugin configure secureshellgo@dhiva-labs --json': BridgeProcessResult(
      exitCode: 0,
      stdout: jsonEncode({
        'pluginId': 'secureshellgo@dhiva-labs',
        'inputs': {'bridge_token': '', 'launcher': ''},
        'configured': ['bridge_token'],
        'unconfigured': ['launcher'],
      }),
    ),
  };

  final Map<String, BridgeProcessResult> answers;
  final calls = <Call>[];

  Future<BridgeProcessResult> run(
    String executable,
    List<String> arguments, {
    String? stdin,
    Duration timeout = const Duration(seconds: 90),
    Map<String, String>? environment,
    bool runInShell = false,
  }) async {
    final call = Call(
      executable,
      arguments,
      stdin: stdin,
      timeout: timeout,
      environment: environment,
      runInShell: runInShell,
    );
    calls.add(call);
    return answers[call.joined] ??
        const BridgeProcessResult(exitCode: 99, stderr: 'unexpected');
  }

  List<String> get commands => [for (final c in calls) c.joined];
}

const token = 'ssg_TOKEN-0123456789abcdef';

// What the real CLI printed (2.1.322) in these two cases.
const _realAlreadyInstalled =
    '\u2714 Plugin "secureshellgo@dhiva-labs" is already installed '
    '(scope: user) \u2014 it loads in place from '
    '/home/u/dhiva-labs/secure_shell_go/integrations/plugin';
const _realAddFailure =
    '\u2718 Failed to add marketplace: Marketplace file not found at '
    '/home/u/.claude/plugins/marketplaces/Dhiva-Labs-SecureShellGo/'
    '.claude-plugin/marketplace.json';
const claude = '/home/u/.local/bin/claude';

String allText(ClaudeConnectOutcome o) => [
  if (o is ClaudeConnectFailed) o.message,
  for (final s in o.steps) ...[s.output, ...s.command],
].join('\n');

/// Fails if [token] reached anything but the configure step's stdin.
void expectTokenOnlyOnStdin(FakeCli cli, ClaudeConnectOutcome outcome) {
  for (final c in cli.calls) {
    expect(c.executable, isNot(contains(token)));
    for (final a in c.arguments) {
      expect(a, isNot(contains(token)));
    }
    for (final e in (c.environment ?? const {}).entries) {
      expect(e.key, isNot(contains(token)));
      expect(e.value, isNot(contains(token)));
    }
    if (c.stdin != null) expect(c.joined, endsWith('--values-stdin'));
  }
  expect(allText(outcome), isNot(contains(token)));
}

void main() {
  ClaudeCliConnector connector(
    FakeCli cli, {
    Map<String, String> env = const {'PATH': '/usr/bin:/home/u/.local/bin'},
    bool windows = false,
    String exe = '/opt/secureshellgo/secureshellgo',
    Set<String> files = const {claude},
  }) => ClaudeCliConnector(
    runner: cli.run,
    environment: env,
    isWindows: windows,
    resolvedExecutable: exe,
    fileExists: files.contains,
  );

  Future<ClaudeConnectOutcome> connect(
    FakeCli cli, {
    String launcher = 'secureshellgo-mcp',
    String executable = claude,
    bool windows = false,
  }) => connector(cli, windows: windows, files: {executable}).connect(
    executablePath: executable,
    token: token,
    launcherCommand: launcher,
  );

  group('find', () {
    test('lists what could be claude and runs nothing', () {
      final cli = FakeCli();
      final r = connector(
        cli,
        env: {'PATH': '/usr/bin:/home/u/.local/bin', 'HOME': '/home/u'},
        files: {claude, '/home/u/.claude/local/claude'},
      ).find();
      expect(r, isA<ClaudeCliPresent>());
      expect((r as ClaudeCliPresent).candidates, [
        claude,
        '/home/u/.claude/local/claude',
      ]);
      expect(cli.calls, isEmpty);
    });

    test('nothing there is absent, and runs nothing', () {
      final cli = FakeCli();
      final r = connector(
        cli,
        env: {'PATH': '/usr/bin', 'HOME': '/home/u'},
        files: {},
      ).find();
      expect(r, isA<ClaudeCliAbsent>());
      expect(cli.calls, isEmpty);
    });

    test('the snap is sandboxed, and runs nothing', () {
      final cli = FakeCli();
      final r = connector(
        cli,
        env: {'SNAP': '/snap/secureshellgo/12', 'PATH': '/home/u/.local/bin'},
        exe: '/snap/secureshellgo/12/secureshellgo',
      ).find();
      expect(r, isA<ClaudeCliPresenceSandboxed>());
      expect(cli.calls, isEmpty);
    });
  });

  group('detect', () {
    test('finds claude on the PATH and reports its version', () async {
      final cli = FakeCli();
      final r = await connector(cli).detect();
      expect(r, isA<ClaudeCliAvailable>());
      r as ClaudeCliAvailable;
      expect(r.executablePath, claude);
      expect(r.version, '2.1.322 (Claude Code)');
      expect(cli.commands, ['--version', 'plugin marketplace list --json']);
      for (final c in cli.calls) {
        expect(c.timeout, const Duration(seconds: 10));
        expect(c.runInShell, isFalse);
        expect(c.stdin, isNull);
      }
      // The default list has no dhiva-labs entry: it will come from GitHub.
      expect(r.pluginSource, const ClaudePluginSourceOfficial());
    });

    test('the first PATH entry wins; relative entries are skipped', () async {
      final cli = FakeCli();
      final r = await connector(
        cli,
        env: {'PATH': ':bin:/a:/b/'},
        files: {'bin/claude', 'claude', '/a/claude', '/b/claude'},
      ).detect();
      expect((r as ClaudeCliAvailable).executablePath, '/a/claude');
      final c = connector(
        cli,
        env: {'PATH': ':bin:/a:/b/'},
        files: {'bin/claude', 'claude', '/a/claude', '/b/claude'},
      );
      expect(c.findCandidates(), ['/a/claude', '/b/claude']);
    });

    test('falls back to the per-user locations on Linux', () async {
      final c = connector(
        FakeCli(),
        env: {'PATH': '/usr/bin', 'HOME': '/home/u'},
        files: {'/home/u/.claude/local/claude', '/home/u/.local/bin/claude'},
      );
      expect(c.findCandidates(), [
        '/home/u/.local/bin/claude',
        '/home/u/.claude/local/claude',
      ]);
      final only = connector(
        FakeCli(),
        env: {'PATH': '/usr/bin', 'HOME': '/home/u/'},
        files: {'/home/u/.claude/local/claude'},
      );
      expect(only.findCandidates(), ['/home/u/.claude/local/claude']);
    });

    test('Windows: PATH with PATHEXT order and case-insensitive names', () {
      final c = connector(
        FakeCli(),
        windows: true,
        env: {
          'Path': r'C:\Windows;"C:\Users\u\AppData\Roaming\npm";relative',
          'PATHEXT': '.COM;.CMD;.EXE',
          'USERPROFILE': r'C:\Users\u',
        },
        files: {
          r'C:\Users\u\AppData\Roaming\npm\claude.exe',
          r'C:\Users\u\AppData\Roaming\npm\claude.cmd',
          r'C:\Users\u\AppData\Roaming\npm\claude.com',
          r'relative\claude.exe',
        },
      );
      expect(c.findCandidates(), [
        r'C:\Users\u\AppData\Roaming\npm\claude.cmd',
        r'C:\Users\u\AppData\Roaming\npm\claude.exe',
      ]);
    });

    test('Windows: the native installer location', () async {
      final cli = FakeCli();
      final r = await connector(
        cli,
        windows: true,
        env: {'PATH': r'C:\Windows', 'USERPROFILE': r'C:\Users\u'},
        exe: r'C:\Program Files\SecureShell Go\secureshellgo.exe',
        files: {r'C:\Users\u\.local\bin\claude.exe'},
      ).detect();
      expect(
        (r as ClaudeCliAvailable).executablePath,
        r'C:\Users\u\.local\bin\claude.exe',
      );
      expect(cli.calls.every((c) => !c.runInShell), isTrue);
    });

    test('Windows: a .cmd shim is versioned through the shell', () async {
      final cli = FakeCli();
      await connector(
        cli,
        windows: true,
        env: {'PATH': r'C:\npm'},
        files: {r'C:\npm\claude.cmd'},
      ).detect();
      expect(cli.calls.every((c) => c.runInShell), isTrue);
      expect(cli.calls.first.arguments, ['--version']);
    });

    test('not found runs nothing', () async {
      final cli = FakeCli();
      final r = await connector(
        cli,
        env: {'PATH': '/usr/bin', 'HOME': '/home/u'},
        files: {},
      ).detect();
      expect(r, isA<ClaudeCliNotFound>());
      expect(cli.calls, isEmpty);
    });

    test('the snap is sandboxed and runs nothing', () async {
      final cli = FakeCli();
      final r = await connector(
        cli,
        env: {'SNAP': '/snap/secureshellgo/12', 'PATH': '/home/u/.local/bin'},
        exe: '/snap/secureshellgo/12/secureshellgo',
      ).detect();
      expect(r, isA<ClaudeCliSandboxed>());
      expect(cli.calls, isEmpty);
    });

    test('a SNAP passed on by another snap is not sandboxed', () async {
      final r = await connector(
        FakeCli(),
        env: {'SNAP': '/snap/code/180', 'PATH': '/home/u/.local/bin'},
      ).detect();
      expect(r, isA<ClaudeCliAvailable>());
    });

    test(
      'a failing version check is failed, and the next one is tried',
      () async {
        final cli = FakeCli({
          '--version': const BridgeProcessResult(
            exitCode: 127,
            stderr: 'broken install',
          ),
        });
        final r = await connector(cli).detect();
        expect(r, isA<ClaudeCliFailed>());
        expect((r as ClaudeCliFailed).message, contains('broken install'));

        final timeout = FakeCli({
          '--version': const BridgeProcessResult(
            exitCode: null,
            timedOut: true,
          ),
        });
        final t = await connector(
          timeout,
          env: {'PATH': '/a:/b'},
          files: {'/a/claude', '/b/claude'},
        ).detect();
        expect(t, isA<ClaudeCliFailed>());
        expect(timeout.calls.map((c) => c.executable), [
          '/a/claude',
          '/b/claude',
        ]);
      },
    );
    test('Windows: UNC PATH entries and home folders are never used', () {
      final c = connector(
        FakeCli(),
        windows: true,
        env: {
          'PATH':
              r'\\server\share\bin;//server/share/bin;\\?\C:\bin;'
              r'\\.\C:\dev;C:\ok',
          'USERPROFILE': r'\\server\profiles\u',
        },
        files: {
          r'\\server\share\bin\claude.exe',
          r'//server/share/bin\claude.exe',
          r'\\?\C:\bin\claude.exe',
          r'\\.\C:\dev\claude.exe',
          r'\\server\profiles\u\.local\bin\claude.exe',
          r'C:\ok\claude.exe',
        },
      );
      expect(c.findCandidates(), [r'C:\ok\claude.exe']);
    });

    group('plugin source', () {
      Future<ClaudePluginSource> sourceFor(BridgeProcessResult list) async {
        final r = await connector(
          FakeCli({'plugin marketplace list --json': list}),
        ).detect();
        return (r as ClaudeCliAvailable).pluginSource;
      }

      BridgeProcessResult listing(List<Object?> entries) =>
          BridgeProcessResult(exitCode: 0, stdout: jsonEncode(entries));

      test('the real shape: a folder marketplace is "other"', () async {
        final s = await sourceFor(
          listing([
            {
              'name': 'example-plugins',
              'source': 'github',
              'repo': 'example-org/example-plugins',
              'installLocation': '/home/u/.claude/plugins/marketplaces/x',
            },
            {
              'name': 'dhiva-labs',
              'source': 'directory',
              'path': '/home/u/dev/secure_shell_go',
              'installLocation': '/home/u/dev/secure_shell_go',
            },
          ]),
        );
        expect(
          s,
          const ClaudePluginSourceOther('Folder: /home/u/dev/secure_shell_go'),
        );
      });

      test('the project repository, in any case, is official', () async {
        for (final repo in [
          'Dhiva-Labs/SecureShellGo',
          'dhiva-labs/secureshellgo',
        ]) {
          final s = await sourceFor(
            listing([
              {'name': 'dhiva-labs', 'source': 'github', 'repo': repo},
            ]),
          );
          expect(s, isA<ClaudePluginSourceOfficial>(), reason: repo);
        }
      });

      test('another repository, git URL or kind is "other"', () async {
        expect(
          await sourceFor(
            listing([
              {'name': 'dhiva-labs', 'source': 'github', 'repo': 'evil/fork'},
            ]),
          ),
          const ClaudePluginSourceOther('GitHub: evil/fork'),
        );
        expect(
          await sourceFor(
            listing([
              {
                'name': 'dhiva-labs',
                'source': 'git',
                'url': 'https://github.com/Dhiva-Labs/SecureShellGo.git',
              },
            ]),
          ),
          const ClaudePluginSourceOther(
            'Git: https://github.com/Dhiva-Labs/SecureShellGo.git',
          ),
        );
        expect(
          await sourceFor(
            listing([
              {'name': 'dhiva-labs', 'source': 'mystery'},
            ]),
          ),
          const ClaudePluginSourceOther('mystery'),
        );
        final noKind = await sourceFor(
          listing([
            {'name': 'dhiva-labs', 'path': '/x\n/y'},
          ]),
        );
        expect(noKind, const ClaudePluginSourceOther('Unknown source: /x /y'));
      });

      test('unreadable lists are unknown, never official', () async {
        for (final list in [
          const BridgeProcessResult(exitCode: 1, stdout: '[]'),
          const BridgeProcessResult(exitCode: null, timedOut: true),
          const BridgeProcessResult.notStarted('nope'),
          const BridgeProcessResult(exitCode: 0, stdout: 'not json'),
          const BridgeProcessResult(exitCode: 0, stdout: '{"name":"x"}'),
          listing([
            {'name': 'other'},
            'dhiva-labs',
          ]),
          listing([
            {'name': 'other'},
            {'source': 'directory', 'path': '/x'},
          ]),
        ]) {
          expect(
            await sourceFor(list),
            isA<ClaudePluginSourceUnknown>(),
            reason: list.stdout,
          );
        }
      });

      test('an empty or dhiva-labs-free list is official', () async {
        expect(await sourceFor(listing([])), isA<ClaudePluginSourceOfficial>());
        expect(
          await sourceFor(
            listing([
              {'name': 'example-plugins', 'source': 'github'},
            ]),
          ),
          isA<ClaudePluginSourceOfficial>(),
        );
      });

      test('a failed list does not fail detection', () async {
        final r = await connector(
          FakeCli({
            'plugin marketplace list --json': const BridgeProcessResult(
              exitCode: 2,
              stderr: 'boom',
            ),
          }),
        ).detect();
        expect(r, isA<ClaudeCliAvailable>());
        expect(
          (r as ClaudeCliAvailable).pluginSource,
          isA<ClaudePluginSourceUnknown>(),
        );
      });
    });
  });

  group('connect', () {
    test('the happy path runs the five commands in order', () async {
      final cli = FakeCli();
      final o = await connect(cli);
      expect(o, isA<ClaudeConnected>());
      expect(cli.commands, [
        'plugin marketplace list --json',
        'plugin marketplace add Dhiva-Labs/SecureShellGo',
        'plugin install secureshellgo@dhiva-labs',
        'plugin configure secureshellgo@dhiva-labs --values-stdin',
        'plugin configure secureshellgo@dhiva-labs --json',
      ]);
      for (final c in cli.calls) {
        expect(c.executable, claude);
        expect(c.timeout, const Duration(seconds: 90));
        expect(c.runInShell, isFalse);
      }
      expect(jsonDecode(cli.calls[3].stdin!), {
        'bridge_token': token,
        'launcher': 'secureshellgo-mcp',
      });
      expect(o.steps.map((s) => s.step), [
        ClaudeConnectStep.marketplaceList,
        ClaudeConnectStep.marketplaceAdd,
        ClaudeConnectStep.install,
        ClaudeConnectStep.configure,
        ClaudeConnectStep.verify,
      ]);
      expect(o.steps[2].command, [
        claude,
        'plugin',
        'install',
        'secureshellgo@dhiva-labs',
      ]);
      expectTokenOnlyOnStdin(cli, o);
    });

    test('a marketplace already there is not added again', () async {
      final cli = FakeCli({
        'plugin marketplace list --json': BridgeProcessResult(
          exitCode: 0,
          stdout: jsonEncode([
            {'name': 'example-plugins'},
            {'name': 'dhiva-labs', 'source': 'directory', 'path': '/x'},
          ]),
        ),
      });
      final o = await connect(cli);
      expect(o, isA<ClaudeConnected>());
      expect(
        cli.commands,
        isNot(contains(startsWith('plugin marketplace add'))),
      );
    });

    test('onStep is told each step just before it runs', () async {
      final cli = FakeCli();
      final seen = <(ClaudeConnectStep, int)>[];
      final o = await connector(cli).connect(
        executablePath: claude,
        token: token,
        launcherCommand: 'secureshellgo-mcp',
        // The number of commands already run when the step is reported.
        onStep: (step) => seen.add((step, cli.calls.length)),
      );
      expect(o, isA<ClaudeConnected>());
      expect(seen, [
        (ClaudeConnectStep.marketplaceList, 0),
        (ClaudeConnectStep.marketplaceAdd, 1),
        (ClaudeConnectStep.install, 2),
        (ClaudeConnectStep.configure, 3),
        (ClaudeConnectStep.verify, 4),
      ]);
    });

    test('onStep: a skipped add is not reported, a throw is ignored', () async {
      final cli = FakeCli({
        'plugin marketplace list --json': BridgeProcessResult(
          exitCode: 0,
          stdout: jsonEncode([
            {'name': 'dhiva-labs', 'source': 'directory', 'path': '/x'},
          ]),
        ),
        'plugin install secureshellgo@dhiva-labs': const BridgeProcessResult(
          exitCode: 1,
          stderr: 'no',
        ),
      });
      final seen = <ClaudeConnectStep>[];
      final o = await connector(cli).connect(
        executablePath: claude,
        token: token,
        launcherCommand: 'secureshellgo-mcp',
        onStep: (step) {
          seen.add(step);
          throw StateError('progress display failed');
        },
      );
      expect(o, isA<ClaudeConnectFailed>());
      expect((o as ClaudeConnectFailed).step, ClaudeConnectStep.install);
      expect(seen, [
        ClaudeConnectStep.marketplaceList,
        ClaudeConnectStep.install,
      ]);
    });

    test('a warning before the JSON still finds the marketplace', () async {
      final cli = FakeCli({
        'plugin marketplace list --json': const BridgeProcessResult(
          exitCode: 0,
          stdout: 'Warning: something\n[{"name":"dhiva-labs"}]',
        ),
      });
      await connect(cli);
      expect(
        cli.commands,
        isNot(contains(startsWith('plugin marketplace add'))),
      );
    });

    test('malformed list JSON falls through to add', () async {
      for (final stdout in ['not json', '{"name":"dhiva-labs"}', '[1,2]', '']) {
        final cli = FakeCli({
          'plugin marketplace list --json': BridgeProcessResult(
            exitCode: 0,
            stdout: stdout,
          ),
        });
        expect(await connect(cli), isA<ClaudeConnected>());
        expect(
          cli.commands[1],
          'plugin marketplace add Dhiva-Labs/SecureShellGo',
        );
      }
    });

    test('a failed list falls through to add', () async {
      final cli = FakeCli({
        'plugin marketplace list --json': const BridgeProcessResult(
          exitCode: 1,
          stdout: '[{"name":"dhiva-labs"}]',
        ),
      });
      await connect(cli);
      expect(
        cli.commands[1],
        'plugin marketplace add Dhiva-Labs/SecureShellGo',
      );
    });

    test('add fails but install succeeds: connected', () async {
      final cli = FakeCli({
        'plugin marketplace add Dhiva-Labs/SecureShellGo':
            const BridgeProcessResult(
              exitCode: 1,
              stderr: 'Failed to add marketplace: not found',
            ),
      });
      final o = await connect(cli);
      expect(o, isA<ClaudeConnected>());
      expect(o.steps[1].exitCode, 1);
      expect(o.steps[1].output, contains('not found'));
    });

    test('install fails: failed at install, nothing configured', () async {
      final cli = FakeCli({
        'plugin install secureshellgo@dhiva-labs': const BridgeProcessResult(
          exitCode: 1,
          stderr: 'Plugin "secureshellgo" not found in marketplace',
        ),
      });
      final o = await connect(cli);
      expect(o, isA<ClaudeConnectFailed>());
      o as ClaudeConnectFailed;
      expect(o.step, ClaudeConnectStep.install);
      expect(o.message, contains('code 1'));
      expect(o.message, contains('not found in marketplace'));
      expect(cli.commands.last, 'plugin install secureshellgo@dhiva-labs');
      expect(cli.calls.every((c) => c.stdin == null), isTrue);
    });

    test('already installed counts as installed', () async {
      final cli = FakeCli({
        'plugin install secureshellgo@dhiva-labs': const BridgeProcessResult(
          exitCode: 1,
          stdout: _realAlreadyInstalled,
        ),
      });
      expect(await connect(cli), isA<ClaudeConnected>());
      final onStderr = FakeCli({
        'plugin install secureshellgo@dhiva-labs': const BridgeProcessResult(
          exitCode: 1,
          stderr: _realAlreadyInstalled,
        ),
      });
      expect(await connect(onStderr), isA<ClaudeConnected>());
    });

    test('another plugin being already installed is not this one', () async {
      final cli = FakeCli({
        'plugin install secureshellgo@dhiva-labs': const BridgeProcessResult(
          exitCode: 1,
          stderr:
              'Dependency "other@x" is already installed\n'
              'x Failed to install plugin "secureshellgo@dhiva-labs"',
        ),
      });
      final o = await connect(cli);
      expect((o as ClaudeConnectFailed).step, ClaudeConnectStep.install);
    });

    test(
      'the real failed GitHub add is tolerated, then install decides',
      () async {
        {
          final cli = FakeCli({
            'plugin marketplace add Dhiva-Labs/SecureShellGo':
                const BridgeProcessResult(exitCode: 1, stderr: _realAddFailure),
          });
          final o = await connect(cli);
          expect(o, isA<ClaudeConnected>());
          expect(o.steps[1].output, contains('Marketplace file not found'));

          final noPlugin = FakeCli({
            'plugin marketplace add Dhiva-Labs/SecureShellGo':
                const BridgeProcessResult(exitCode: 1, stderr: _realAddFailure),
            'plugin install secureshellgo@dhiva-labs':
                const BridgeProcessResult(
                  exitCode: 1,
                  stderr:
                      'x Plugin "secureshellgo" not found in any marketplace',
                ),
          });
          final f = await connect(noPlugin);
          expect((f as ClaudeConnectFailed).step, ClaudeConnectStep.install);
          expect(
            noPlugin.commands.any((c) => c.contains('values-stdin')),
            false,
          );
        }
      },
    );

    test('configure fails: failed at configure', () async {
      final cli = FakeCli({
        'plugin configure secureshellgo@dhiva-labs --values-stdin':
            const BridgeProcessResult(exitCode: 2, stderr: 'bad values'),
      });
      final o = await connect(cli);
      expect((o as ClaudeConnectFailed).step, ClaudeConnectStep.configure);
      expect(o.message, contains('bad values'));
      expect(o.steps.length, 4);
    });

    test('verify saying the token is unset fails', () async {
      final cli = FakeCli({
        'plugin configure secureshellgo@dhiva-labs --json': BridgeProcessResult(
          exitCode: 0,
          stdout: jsonEncode({
            'configured': <String>[],
            'unconfigured': ['bridge_token', 'launcher'],
          }),
        ),
      });
      final o = await connect(cli);
      expect((o as ClaudeConnectFailed).step, ClaudeConnectStep.verify);
    });

    test('verify that does not confirm the token is a failure', () async {
      // The pairing is revoked on a failure, so "connected" needs the CLI to
      // have said the token is set.
      for (final r in [
        const BridgeProcessResult(exitCode: 0, stdout: 'garbage {'),
        const BridgeProcessResult(exitCode: 0, stdout: '[]'),
        const BridgeProcessResult(exitCode: 0, stdout: ''),
        const BridgeProcessResult(exitCode: 0, stdout: '{"configured":"x"}'),
        const BridgeProcessResult(
          exitCode: 0,
          stdout: '{"configured":["launcher"],"unconfigured":[]}',
        ),
        const BridgeProcessResult(exitCode: 1, stderr: 'unknown option'),
        const BridgeProcessResult(
          exitCode: 1,
          stdout: '{"configured":["bridge_token"]}',
        ),
        const BridgeProcessResult(exitCode: null, timedOut: true),
        const BridgeProcessResult.notStarted('gone'),
      ]) {
        final cli = FakeCli({
          'plugin configure secureshellgo@dhiva-labs --json': r,
        });
        final o = await connect(cli);
        expect(o, isA<ClaudeConnectFailed>(), reason: '${r.stdout}${r.stderr}');
        expect((o as ClaudeConnectFailed).step, ClaudeConnectStep.verify);
      }
    });

    test(
      'verify that says the token is set, after a warning, connects',
      () async {
        final cli = FakeCli({
          'plugin configure secureshellgo@dhiva-labs --json':
              const BridgeProcessResult(
                exitCode: 0,
                stdout: 'Warning: x\n{"configured":["bridge_token"]}',
              ),
        });
        expect(await connect(cli), isA<ClaudeConnected>());
      },
    );

    test('the launcher is always sent, so an old one is replaced', () async {
      final def = FakeCli();
      await connect(def, launcher: 'secureshellgo-mcp');
      expect(jsonDecode(def.calls[3].stdin!), {
        'bridge_token': token,
        'launcher': 'secureshellgo-mcp',
      });

      final snap = FakeCli();
      await connect(snap, launcher: '/home/u/My Apps/secureshellgo-mcp');
      expect(jsonDecode(snap.calls[3].stdin!), {
        'bridge_token': token,
        'launcher': '/home/u/My Apps/secureshellgo-mcp',
      });
      expectTokenOnlyOnStdin(snap, await connect(snap, launcher: 'x'));
    });

    test('a multi-line launcher is refused', () {
      expect(
        () => connector(FakeCli()).connect(
          executablePath: claude,
          token: token,
          launcherCommand: 'a\nb',
        ),
        throwsArgumentError,
      );
    });

    test('only an absolute path to an existing file is run', () async {
      for (final path in [
        'claude',
        './claude',
        'bin/claude',
        '',
        '/home/u/.local/bin/claude\u0000x',
        '/not/there/claude',
      ]) {
        final cli = FakeCli();
        final o =
            await connector(
              cli,
              files: {claude, 'claude', './claude', 'bin/claude', ''},
            ).connect(
              executablePath: path,
              token: token,
              launcherCommand: 'secureshellgo-mcp',
            );
        expect(o, isA<ClaudeConnectFailed>(), reason: path);
        expect(cli.calls, isEmpty, reason: path);
        expectTokenOnlyOnStdin(cli, o);
      }
    });

    test('a token echoed cut short or masked is scrubbed', () async {
      const long = 'ssg_AbCdEfGhIjKlMnOpQrStUvWx0123456789';
      final cli = FakeCli({
        'plugin configure secureshellgo@dhiva-labs --values-stdin':
            const BridgeProcessResult(
              exitCode: 1,
              stderr:
                  'bad: ssg_AbCdEfGhIjKl... / ...MnOpQrStUvWx0123456789 / '
                  r'"ssg_AbCdEfGhIjKlMnOpQrStUvWx0123456789"',
            ),
      });
      final o = await connector(cli).connect(
        executablePath: claude,
        token: long,
        launcherCommand: 'secureshellgo-mcp',
      );
      final text = allText(o);
      expect(text, isNot(contains('AbCdEfGh')));
      expect(text, isNot(contains('QrStUvWx')));
      expect(text, contains('[token]'));
    });

    test('a timeout fails the step', () async {
      final cli = FakeCli({
        'plugin install secureshellgo@dhiva-labs': const BridgeProcessResult(
          exitCode: null,
          timedOut: true,
          stdout: 'already installed', // half-printed; not to be trusted
        ),
      });
      final o = await connect(cli);
      expect((o as ClaudeConnectFailed).step, ClaudeConnectStep.install);
      expect(o.message, contains('did not finish in time'));
      expect(o.steps.last.timedOut, isTrue);
      expect(o.steps.last.exitCode, isNull);
    });

    test('a CLI that cannot be started fails at install', () async {
      final cli = FakeCli({
        'plugin marketplace list --json': const BridgeProcessResult.notStarted(
          'No such file',
        ),
        'plugin marketplace add Dhiva-Labs/SecureShellGo':
            const BridgeProcessResult.notStarted('No such file'),
        'plugin install secureshellgo@dhiva-labs':
            const BridgeProcessResult.notStarted('No such file'),
      });
      final o = await connect(cli);
      expect((o as ClaudeConnectFailed).step, ClaudeConnectStep.install);
      expect(o.message, contains('could not be started'));
    });

    test('an empty or multi-line token is refused without echoing it', () {
      final c = connector(FakeCli());
      for (final bad in ['', 'a\nb', 'secret\r']) {
        expect(
          () => c.connect(
            executablePath: claude,
            token: bad,
            launcherCommand: 'secureshellgo-mcp',
          ),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.toString(),
              'text',
              isNot(contains('secret')),
            ),
          ),
        );
      }
    });

    test(
      'the token never leaves stdin on any path, even when echoed',
      () async {
        final echo = BridgeProcessResult(
          exitCode: 1,
          stdout: 'got {"bridge_token":"$token"}',
          stderr: 'Error: invalid token $token',
        );
        final echoOk = BridgeProcessResult(
          exitCode: 0,
          stdout: 'saved bridge_token=$token',
          stderr: 'debug: ${jsonEncode({'bridge_token': token})}',
        );
        final scenarios = <Map<String, BridgeProcessResult>>[
          {},
          {'plugin marketplace list --json': echo},
          {'plugin marketplace add Dhiva-Labs/SecureShellGo': echo},
          {'plugin install secureshellgo@dhiva-labs': echo},
          {'plugin configure secureshellgo@dhiva-labs --values-stdin': echo},
          {'plugin configure secureshellgo@dhiva-labs --values-stdin': echoOk},
          {'plugin configure secureshellgo@dhiva-labs --json': echo},
          {'plugin configure secureshellgo@dhiva-labs --json': echoOk},
          {
            'plugin install secureshellgo@dhiva-labs': BridgeProcessResult(
              exitCode: null,
              timedOut: true,
              stderr: token,
            ),
          },
          {
            'plugin configure secureshellgo@dhiva-labs --values-stdin':
                BridgeProcessResult.notStarted('cannot start $token'),
          },
        ];
        for (final answers in scenarios) {
          for (final launcher in ['secureshellgo-mcp', '/opt/x/launcher']) {
            final cli = FakeCli(answers);
            final o = await connect(cli, launcher: launcher);
            expectTokenOnlyOnStdin(cli, o);
            final text = allText(o);
            if (text.contains('Error: invalid token')) {
              expect(text, contains('[token]'));
            }
          }
        }
      },
    );

    test('a token that JSON escapes is scrubbed in both forms', () async {
      const odd = r'abc"def\ghi-0123456789';
      final escaped = jsonEncode(odd);
      final cli = FakeCli({
        'plugin configure secureshellgo@dhiva-labs --values-stdin':
            BridgeProcessResult(exitCode: 1, stderr: 'echo $escaped / $odd'),
      });
      final o = await connector(cli).connect(
        executablePath: claude,
        token: odd,
        launcherCommand: 'secureshellgo-mcp',
      );
      final text = allText(o);
      expect(text, isNot(contains(odd)));
      expect(text, isNot(contains(escaped.substring(1, escaped.length - 1))));
      expect(text, contains('[token]'));
    });

    test('step output is capped at 2 KiB', () async {
      final cli = FakeCli({
        'plugin marketplace add Dhiva-Labs/SecureShellGo': BridgeProcessResult(
          exitCode: 1,
          stderr: 'x' * 10000,
        ),
      });
      final o = await connect(cli);
      // 2 KiB of output, then the redactor's one-line truncation note.
      final output = o.steps[1].output;
      expect(output, endsWith('more bytes]'));
      expect(output.split('\n').first.length, 2048);
      expect(utf8.encode(output).length, lessThan(2048 + 64));
    });
  });

  group('connect: expected plugin source', () {
    BridgeProcessResult folderList(String path) => BridgeProcessResult(
      exitCode: 0,
      stdout: jsonEncode([
        {'name': 'dhiva-labs', 'source': 'directory', 'path': path},
      ]),
    );

    Future<ClaudeConnectOutcome> connectExpecting(
      FakeCli cli,
      ClaudePluginSource expected,
    ) => connector(cli).connect(
      executablePath: claude,
      token: token,
      launcherCommand: 'secureshellgo-mcp',
      expectedSource: expected,
    );

    test('a source that still matches connects', () async {
      expect(
        await connectExpecting(FakeCli(), const ClaudePluginSourceOfficial()),
        isA<ClaudeConnected>(),
      );
      final cli = FakeCli({
        'plugin marketplace list --json': folderList('/home/u/dev/ssg'),
      });
      expect(
        await connectExpecting(
          cli,
          const ClaudePluginSourceOther('Folder: /home/u/dev/ssg'),
        ),
        isA<ClaudeConnected>(),
      );
    });

    test('a source that changed stops before anything is sent', () async {
      for (final (list, expected) in [
        (folderList('/tmp/evil'), const ClaudePluginSourceOfficial()),
        (
          folderList('/tmp/evil'),
          const ClaudePluginSourceOther('Folder: /home/u/dev/ssg'),
        ),
        (
          FakeCli.defaults['plugin marketplace list --json']!,
          const ClaudePluginSourceOther('Folder: /home/u/dev/ssg'),
        ),
        (
          const BridgeProcessResult(exitCode: 1, stderr: 'boom'),
          const ClaudePluginSourceOfficial(),
        ),
      ]) {
        final cli = FakeCli({'plugin marketplace list --json': list});
        final o = await connectExpecting(cli, expected);
        expect(o, isA<ClaudeConnectFailed>());
        expect(
          (o as ClaudeConnectFailed).step,
          ClaudeConnectStep.marketplaceList,
        );
        expect(cli.commands, ['plugin marketplace list --json']);
        expect(cli.calls.every((c) => c.stdin == null), isTrue);
        expectTokenOnlyOnStdin(cli, o);
      }
    });

    test('the changed source is named in the message', () async {
      final cli = FakeCli({
        'plugin marketplace list --json': folderList('/tmp/evil'),
      });
      final o = await connectExpecting(cli, const ClaudePluginSourceOfficial());
      expect((o as ClaudeConnectFailed).message, contains('/tmp/evil'));
    });

    test('without an expected source the old behaviour is kept', () async {
      final cli = FakeCli({
        'plugin marketplace list --json': folderList('/tmp/elsewhere'),
      });
      expect(await connect(cli), isA<ClaudeConnected>());
      expect(
        cli.commands,
        isNot(contains(startsWith('plugin marketplace add'))),
      );
    });
  });

  group('connect: which file is run', () {
    test('only a file named claude is run on POSIX, exactly', () async {
      for (final path in [
        '/usr/bin/sh',
        '/home/u/bin/Claude',
        '/home/u/bin/claude2',
        '/home/u/bin/claude.sh',
        '/home/u/bin/claude.EXE',
        '/home/u/bin/claude.cmd.',
        '/home/u/claude/evil',
      ]) {
        final cli = FakeCli();
        final o = await connector(cli, files: {path}).connect(
          executablePath: path,
          token: token,
          launcherCommand: 'secureshellgo-mcp',
        );
        expect(o, isA<ClaudeConnectFailed>(), reason: path);
        expect(o.steps, isEmpty, reason: path);
        expect(cli.calls, isEmpty, reason: path);
      }
      for (final path in ['/opt/c/claude', '/opt/c/claude.exe']) {
        final cli = FakeCli();
        final o = await connector(cli, files: {path}).connect(
          executablePath: path,
          token: token,
          launcherCommand: 'secureshellgo-mcp',
        );
        expect(o, isA<ClaudeConnected>(), reason: path);
      }
    });

    test('Windows: the four names in any case; nothing else', () async {
      for (final path in [
        r'C:\bin\CLAUDE.EXE',
        r'C:\bin\Claude.Cmd',
        r'C:\bin\claude.bat',
        r'C:\bin\claude',
        r'C:\bin\claude.exe.',
      ]) {
        final cli = FakeCli();
        final o = await connector(cli, windows: true, files: {path}).connect(
          executablePath: path,
          token: token,
          launcherCommand: 'secureshellgo-mcp',
        );
        expect(o, isA<ClaudeConnected>(), reason: path);
      }
      for (final path in [
        r'C:\Windows\System32\cmd.exe',
        r'C:\bin\claude.ps1',
        r'C:\bin\claude.com',
        r'C:\bin\claude-evil.exe',
        r'C:\claude.exe\evil.exe',
        r'C:\bin\claude.exe\x',
        // Forward slashes are not taken as a local drive path.
        r'C:/bin/claude.exe',
      ]) {
        final cli = FakeCli();
        final o = await connector(cli, windows: true, files: {path}).connect(
          executablePath: path,
          token: token,
          launcherCommand: 'secureshellgo-mcp',
        );
        expect(o, isA<ClaudeConnectFailed>(), reason: path);
        expect(cli.calls, isEmpty, reason: path);
      }
    });

    test('Windows: a program on a network share is never run', () async {
      for (final path in [
        r'\\server\share\claude.exe',
        r'\\server\share\npm\claude.cmd',
        r'//server/share/claude.exe',
        r'\\?\C:\bin\claude.exe',
        r'\\?\UNC\server\share\claude.exe',
        r'\\.\C:\bin\claude.exe',
      ]) {
        final cli = FakeCli();
        final o = await connector(cli, windows: true, files: {path}).connect(
          executablePath: path,
          token: token,
          launcherCommand: 'secureshellgo-mcp',
        );
        expect(o, isA<ClaudeConnectFailed>(), reason: path);
        expect(
          (o as ClaudeConnectFailed).step,
          ClaudeConnectStep.marketplaceList,
        );
        expect(o.steps, isEmpty, reason: path);
        expect(cli.calls, isEmpty, reason: path);
      }
    });
  });

  group('Windows .cmd shim', () {
    const shim = r'C:\Users\u\AppData\Roaming\npm\claude.cmd';

    test('runs through the shell with constant arguments only', () async {
      final cli = FakeCli();
      final o = await connect(
        cli,
        executable: shim,
        windows: true,
        launcher: r'C:\Apps\SecureShell Go\secureshellgo-mcp.exe',
      );
      expect(o, isA<ClaudeConnected>());
      final fixed = [
        for (final s in ClaudeConnectStep.values) s.arguments,
        ['--version'],
      ];
      for (final c in cli.calls) {
        expect(c.runInShell, isTrue);
        expect(c.executable, shim);
        expect(
          fixed.any((f) => identical(f, c.arguments)),
          isTrue,
          reason: 'arguments must be the constant lists themselves',
        );
      }
      expect(jsonDecode(cli.calls[3].stdin!), {
        'bridge_token': token,
        'launcher': r'C:\Apps\SecureShell Go\secureshellgo-mcp.exe',
      });
      expectTokenOnlyOnStdin(cli, o);
    });

    test('a shim path cmd.exe would interpret is never run', () async {
      final cli = FakeCli();
      final o = await connect(
        cli,
        executable: r'C:\Users\a&b\npm\claude.cmd',
        windows: true,
      );
      expect(o, isA<ClaudeConnectFailed>());
      expect(cli.calls, isEmpty);
    });

    test('paths cmd.exe could misread are never run', () async {
      for (final bad in [
        r'C:\Users\a b&c\claude.cmd',
        r'C:\Users\a(1)\claude.cmd',
        r'C:\Program Files (x86)\n\claude.cmd',
        r'C:\Users\a,b\claude.cmd',
        r'C:\Users\a;b\claude.cmd',
        r'C:\Users\a=b\claude.cmd',
        r'C:\Users\@a\claude.cmd',
        r'C:\Users\%TEMP%\claude.cmd',
        r'C:\Users\a^b\claude.cmd',
        r'C:\Users\a!b\claude.cmd',
        'C:\\Users\\a"b\\claude.cmd',
        r'C:\Users\a&b\claude.cmd.',
        r'C:\Users\a&b\claude.cmd . ',
        r'C:\Users\a&b\CLAUDE.BAT',
      ]) {
        final cli = FakeCli();
        final o = await connector(cli, windows: true, files: {bad}).connect(
          executablePath: bad,
          token: token,
          launcherCommand: 'secureshellgo-mcp',
        );
        expect(o, isA<ClaudeConnectFailed>(), reason: bad);
        expect(cli.calls, isEmpty, reason: bad);
      }
    });

    test(
      'a path with a space and no operators is run, quoted by Dart',
      () async {
        const spaced = r'C:\Users\Jo Smith\AppData\Roaming\npm\claude.cmd';
        final cli = FakeCli();
        final o = await connector(cli, windows: true, files: {spaced}).connect(
          executablePath: spaced,
          token: token,
          launcherCommand: 'secureshellgo-mcp',
        );
        expect(o, isA<ClaudeConnected>());
        expect(cli.calls.every((c) => c.runInShell), isTrue);
      },
    );

    test('a .exe on Windows does not use the shell', () async {
      final cli = FakeCli();
      await connect(
        cli,
        executable: r'C:\Users\u\.local\bin\claude.exe',
        windows: true,
      );
      expect(cli.calls.every((c) => !c.runInShell), isTrue);
    });
  });

  group('runBridgeProcess (real processes)', () {
    final skip = Platform.isWindows ? 'POSIX only' : null;

    test('delivers stdin and closes it', () async {
      final r = await runBridgeProcess(
        'sh',
        ['-c', 'cat; echo done >&2'],
        stdin: 'hello\nworld',
        timeout: const Duration(seconds: 10),
      );
      expect(r.exitCode, 0);
      expect(r.timedOut, isFalse);
      expect(r.stdout, 'hello\nworld');
      expect(r.stderr.trim(), 'done');
    }, skip: skip);

    test('without stdin, the child still sees end-of-file', () async {
      final r = await runBridgeProcess('sh', [
        '-c',
        'cat',
      ], timeout: const Duration(seconds: 10));
      expect(r.exitCode, 0);
      expect(r.timedOut, isFalse);
    }, skip: skip);

    test('a timeout kills the child', () async {
      final watch = Stopwatch()..start();
      final r = await runBridgeProcess('sh', [
        '-c',
        'sleep 30',
      ], timeout: const Duration(milliseconds: 300));
      expect(r.timedOut, isTrue);
      expect(r.exitCode, isNull);
      expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
    }, skip: skip);

    test('output past the cap is dropped, and the child still exits', () async {
      final r = await runBridgeProcess('sh', [
        '-c',
        'head -c 600000 /dev/zero | tr "\\0" a',
      ], timeout: const Duration(seconds: 10));
      expect(r.exitCode, 0);
      expect(r.stdout.length, bridgeProcessOutputCap);
    }, skip: skip);

    test('a child that closes stdin at once is not an error', () async {
      final big = 'x' * (1024 * 1024); // more than a pipe holds
      for (final script in [
        'exec 0<&-; exit 0',
        'exit 0',
        'exit 3',
        'exec 0<&-; sleep 0.3; exit 3',
      ]) {
        for (final input in ['{"bridge_token":"abc"}', big]) {
          final r = await runBridgeProcess(
            'sh',
            ['-c', script],
            stdin: input,
            timeout: const Duration(seconds: 10),
          );
          expect(r.timedOut, isFalse, reason: script);
          expect(r.exitCode, script.endsWith('3') ? 3 : 0, reason: script);
          // Let any late pipe error surface: it would fail this test as an
          // uncaught asynchronous error.
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    }, skip: skip);

    test('a grandchild holding the pipes does not hold the call', () async {
      final watch = Stopwatch()..start();
      final r = await runBridgeProcess('sh', [
        '-c',
        'sleep 30 & exec sleep 30',
      ], timeout: const Duration(milliseconds: 300));
      expect(r.timedOut, isTrue);
      expect(watch.elapsed, lessThan(const Duration(seconds: 8)));

      // The same when the child exits by itself and leaves one behind.
      watch.reset();
      final s = await runBridgeProcess('sh', [
        '-c',
        'echo hi; sleep 30 & exit 0',
      ], timeout: const Duration(seconds: 10));
      expect(s.exitCode, 0);
      expect(s.stdout.trim(), 'hi');
      expect(watch.elapsed, lessThan(const Duration(seconds: 8)));
    }, skip: skip);

    test('a chatty child on both streams does not deadlock', () async {
      final r = await runBridgeProcess('sh', [
        '-c',
        'head -c 700000 /dev/zero | tr "\\0" a >&2; '
            'head -c 700000 /dev/zero | tr "\\0" b',
      ], timeout: const Duration(seconds: 10));
      expect(r.exitCode, 0);
      expect(r.stdout.length, bridgeProcessOutputCap);
      expect(r.stderr.length, bridgeProcessOutputCap);
    }, skip: skip);

    test('invalid UTF-8 output does not throw', () async {
      final r = await runBridgeProcess('sh', [
        '-c',
        r'printf "ok \377\376 end"',
      ], timeout: const Duration(seconds: 10));
      expect(r.exitCode, 0);
      expect(r.stdout, startsWith('ok '));
      expect(r.stdout, endsWith(' end'));
    }, skip: skip);

    test('anything that cannot be started is reported, not thrown', () async {
      for (final path in ['/nonexistent/claude', '/tmp', 'claude\u0000x', '']) {
        final r = await runBridgeProcess(path, const [
          '--version',
        ], timeout: const Duration(seconds: 5));
        expect(r.startError, isNotNull, reason: path);
        expect(r.succeeded, isFalse);
      }
    }, skip: skip);

    test('a missing program is not started', () async {
      final r = await runBridgeProcess('/nonexistent/claude', const [
        '--version',
      ], timeout: const Duration(seconds: 5));
      expect(r.startError, isNotNull);
      expect(r.succeeded, isFalse);
    }, skip: skip);
  });
}
