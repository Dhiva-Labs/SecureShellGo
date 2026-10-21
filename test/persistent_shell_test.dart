import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/services/persistent_shell.dart';

Host hostNamed(String label) => Host(
      id: 'h1',
      label: label,
      hostname: 'example.com',
      port: 22,
      username: 'dev',
      authMethod: SshAuthMethod.password,
    );

/// A directory standing in for a server's PATH: `sh`, and whichever of
/// tmux and screen the test says is installed, each a stub that prints the
/// arguments it was given (one per `|`) instead of taking over a terminal,
/// then exits with [tmuxExit] or [screenExit].
///
/// With [tmuxSessions], the tmux stub answers `has-session -t` the way tmux
/// does: `=name` is that session and no other, while a bare name is also
/// any session whose name starts with it.
class FakeServer {
  FakeServer._(this.dir);

  final Directory dir;

  static Future<FakeServer> create({
    bool tmux = false,
    bool screen = false,
    int tmuxHasSession = 1,
    int screenHasSession = 1,
    List<String>? tmuxSessions,
    int tmuxExit = 0,
    int screenExit = 0,
  }) async {
    final dir = await Directory.systemTemp.createTemp('ssg_persistent_');
    final server = FakeServer._(dir);
    await Link('${dir.path}/sh').create('/bin/sh');
    if (tmux) {
      final hasSession = tmuxSessions == null
          ? 'exit $tmuxHasSession'
          : '''
  t="\$3"
  for s in ${tmuxSessions.join(' ')}; do
    case "\$t" in
      =*) [ "\$s" = "\${t#=}" ] && exit 0 ;;
      *) case "\$s" in "\$t"*) exit 0 ;; esac ;;
    esac
  done
  exit 1''';
      await server._stub('tmux', '''
if [ "\$1" = has-session ]; then
$hasSession
fi
printf 'tmux|'; printf '%s|' "\$@"
exit $tmuxExit''');
    }
    if (screen) {
      await server._stub('screen', '''
if [ "\$3" = -X ]; then exit $screenHasSession; fi
printf 'screen|'; printf '%s|' "\$@"
exit $screenExit''');
    }
    await server._stub('loginsh', r'''printf 'login|'; printf '%s|' "$@"''');
    return server;
  }

  Future<void> _stub(String name, String body) async {
    final file = File('${dir.path}/$name');
    await file.writeAsString('#!/bin/sh\n$body\n');
    await Process.run('chmod', ['+x', file.path]);
  }

  /// Runs [command] the way sshd runs an exec request: through the login
  /// shell's `-c`, here a POSIX one, with nothing on the PATH but the stubs.
  Future<String> run(String command) async {
    final result = await Process.run(
      '/bin/sh',
      ['-c', command],
      environment: {'PATH': dir.path, 'SHELL': '${dir.path}/loginsh'},
      includeParentEnvironment: false,
    );
    expect(result.stderr, isEmpty);
    return result.stdout as String;
  }

  Future<void> dispose() => dir.delete(recursive: true);
}

void main() {
  group('session names', () {
    test('are the host and the tab slot, in characters tmux keeps', () {
      expect(persistentSessionName(hostNamed('Test box'), 1), 'ssg-test-box-1_');
      expect(
        persistentSessionName(hostNamed('prod.db:5432'), 2),
        'ssg-prod-db-5432-2_',
      );
    });

    test('fall back to the address when the host has no label', () {
      expect(persistentSessionName(hostNamed(''), 1), 'ssg-dev-example-com-1_');
    });

    test('stay short, and never empty', () {
      final long = persistentSessionName(
        hostNamed('a very long label for a very long server name indeed'),
        3,
      );
      expect(long, 'ssg-a-very-long-label-for-a-3_');
      expect(persistentSessionName(hostNamed('???'), 1), 'ssg-host-1_');
    });

    test('are never the start of one another', () {
      // GNU screen looks names up by how they start, so tab 1 of `box`
      // must not be the start of tab 10's name, nor of any tab of `box-1`.
      final names = [
        for (final label in ['box', 'box-1', 'box-10', 'box 1 2'])
          for (var slot = 1; slot <= 25; slot++)
            persistentSessionName(hostNamed(label), slot),
      ];
      for (final a in names) {
        for (final b in names) {
          if (a != b) expect(b.startsWith(a), isFalse, reason: '$a / $b');
        }
      }
    });

    test('differ by tab and repeat for the same tab', () {
      final host = hostNamed('box');
      expect(persistentSessionName(host, 1), persistentSessionName(host, 1));
      expect(
        persistentSessionName(host, 1),
        isNot(persistentSessionName(host, 2)),
      );
    });
  });

  group('the shell command', () {
    test('is nothing at all when the host keeps no session', () {
      expect(persistentShellCommand(PersistentSession.off, 'x'), isNull);
      expect(persistentProbeCommand(PersistentSession.off, 'x'), isNull);
    });

    test('is one line any login shell can pass to sh', () {
      for (final kind in [PersistentSession.tmux, PersistentSession.screen]) {
        final command = persistentShellCommand(kind, 'ssg-box-1')!;
        expect(command, startsWith('exec sh -c '));
        expect(command, isNot(contains('\n')));
        expect(command, isNot(contains('!')),
            reason: 'csh expands history even inside single quotes');
      }
    });

    test('attaches to or starts tmux', () async {
      final server = await FakeServer.create(tmux: true, screen: true);
      addTearDown(server.dispose);

      final out = await server.run(
        persistentShellCommand(PersistentSession.tmux, 'ssg-box-1')!,
      );

      expect(out, 'tmux|new|-A|-s|ssg-box-1|');
    });

    test('falls back to screen, saying so, when tmux is missing', () async {
      final server = await FakeServer.create(screen: true);
      addTearDown(server.dispose);

      final out = await server.run(
        persistentShellCommand(PersistentSession.tmux, 'ssg-box-1')!,
      );

      expect(out, '$persistentScreenFallbackNotice\nscreen|-dRR|ssg-box-1|');
    });

    test('falls back to the login shell when neither is there', () async {
      final server = await FakeServer.create();
      addTearDown(server.dispose);

      final out = await server.run(
        persistentShellCommand(PersistentSession.tmux, 'ssg-box-1')!,
      );

      expect(out, '$persistentPlainFallbackNotice\nlogin|-l|');
    });

    test('reattaches screen here, detaching it elsewhere', () async {
      final server = await FakeServer.create(tmux: true, screen: true);
      addTearDown(server.dispose);

      final out = await server.run(
        persistentShellCommand(PersistentSession.screen, 'ssg-box-1')!,
      );

      expect(out, 'screen|-dRR|ssg-box-1|');
    });

    test('falls back from screen to the login shell', () async {
      final server = await FakeServer.create(tmux: true);
      addTearDown(server.dispose);

      final out = await server.run(
        persistentShellCommand(PersistentSession.screen, 'ssg-box-1')!,
      );

      expect(out, '$persistentScreenMissingNotice\nlogin|-l|');
    });

    test('falls back to the login shell, saying so, when tmux fails',
        () async {
      // Installed, but it will not run here: a server of another protocol
      // version, a terminal it cannot open.
      final server = await FakeServer.create(tmux: true, tmuxExit: 1);
      addTearDown(server.dispose);

      final out = await server.run(
        persistentShellCommand(PersistentSession.tmux, 'ssg-box-1')!,
      );

      expect(out, 'tmux|new|-A|-s|ssg-box-1|$persistentTmuxFailedNotice\n'
          'login|-l|');
    });

    test('falls back to the login shell when screen fails', () async {
      final server = await FakeServer.create(screen: true, screenExit: 1);
      addTearDown(server.dispose);

      expect(
        await server.run(
          persistentShellCommand(PersistentSession.screen, 'ssg-box-1')!,
        ),
        'screen|-dRR|ssg-box-1|$persistentScreenFailedNotice\nlogin|-l|',
      );
      expect(
        await server.run(
          persistentShellCommand(PersistentSession.tmux, 'ssg-box-1')!,
        ),
        '$persistentScreenFallbackNotice\n'
        'screen|-dRR|ssg-box-1|$persistentScreenFailedNotice\nlogin|-l|',
      );
    });

    test('passes any name as one argument, whatever it holds', () async {
      final server = await FakeServer.create(tmux: true);
      addTearDown(server.dispose);
      const hostile = r"o'brien; touch /tmp/ssg_nope $(id) `id`";

      final out = await server.run(
        persistentShellCommand(PersistentSession.tmux, hostile)!,
      );

      expect(out, 'tmux|new|-A|-s|$hostile|');
    });
  });

  group('the probe', () {
    Future<bool?> probe(
      PersistentSession kind, {
      bool tmux = false,
      bool screen = false,
      int tmuxHasSession = 1,
      int screenHasSession = 1,
      List<String>? tmuxSessions,
    }) async {
      final server = await FakeServer.create(
        tmux: tmux,
        screen: screen,
        tmuxHasSession: tmuxHasSession,
        screenHasSession: screenHasSession,
        tmuxSessions: tmuxSessions,
      );
      addTearDown(server.dispose);
      final out =
          await server.run(persistentProbeCommand(kind, 'ssg-box-1')!);
      return persistentProbeSaysNew(out);
    }

    test('says attach when tmux has the session', () async {
      expect(
        await probe(PersistentSession.tmux, tmux: true, tmuxHasSession: 0),
        isFalse,
      );
    });

    test('says new when tmux does not', () async {
      expect(await probe(PersistentSession.tmux, tmux: true), isTrue);
    });

    test('does not take another tab\'s tmux session for this one', () async {
      // tmux would match `ssg-box-1` to tab 10's `ssg-box-10`.
      expect(
        await probe(
          PersistentSession.tmux,
          tmux: true,
          tmuxSessions: ['ssg-box-10', 'ssg-box-12'],
        ),
        isTrue,
      );
      expect(
        await probe(
          PersistentSession.tmux,
          tmux: true,
          tmuxSessions: ['ssg-box-10', 'ssg-box-1'],
        ),
        isFalse,
      );
    });

    test('asks screen when tmux is missing', () async {
      expect(
        await probe(PersistentSession.tmux, screen: true, screenHasSession: 0),
        isFalse,
      );
      expect(await probe(PersistentSession.tmux, screen: true), isTrue);
    });

    test('says new when there is nothing to attach to', () async {
      expect(await probe(PersistentSession.tmux), isTrue);
      expect(await probe(PersistentSession.screen), isTrue);
      expect(
        await probe(PersistentSession.screen, screen: true, screenHasSession: 0),
        isFalse,
      );
    });

    test('an answer it cannot read counts as not new', () {
      expect(persistentProbeSaysNew(''), isNull);
      expect(persistentProbeSaysNew('Welcome!\nnew\n'), isTrue);
      expect(persistentProbeSaysNew('sh: tmux: not found'), isNull);
    });
  });

  group('with real GNU screen', () {
    final noScreen =
        Process.runSync('sh', ['-c', 'command -v screen']).exitCode != 0;

    test("a tab's probe does not find another tab's session", () async {
      // A socket directory of its own, so the developer's sessions are
      // neither seen nor touched.
      final dir = await Directory.systemTemp.createTemp('ssg_screen_');
      await Process.run('chmod', ['700', dir.path]);
      final env = {'SCREENDIR': dir.path};
      final host = hostNamed('box');
      final tenth = persistentSessionName(host, 10);
      addTearDown(() async {
        await Process.run('screen', ['-S', tenth, '-X', 'quit'],
            environment: env);
        await dir.delete(recursive: true);
      });
      await Process.run('screen', ['-dmS', tenth, 'sleep', '60'],
          environment: env);

      Future<bool?> probe(int slot) async {
        final result = await Process.run(
          '/bin/sh',
          [
            '-c',
            persistentProbeCommand(
              PersistentSession.screen,
              persistentSessionName(host, slot),
            )!,
          ],
          environment: env,
        );
        return persistentProbeSaysNew(result.stdout as String);
      }

      // Tab 10 finds its own, once screen has it running...
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (await probe(10) != false) {
        if (DateTime.now().isAfter(deadline)) fail('screen never started');
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      // ...and tab 1, whose name tab 10's used to start with, does not.
      expect(await probe(1), isTrue);
    }, skip: noScreen ? 'needs GNU screen' : null);
  });
}
