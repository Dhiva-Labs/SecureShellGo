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
/// arguments it was given (one per `|`) instead of taking over a terminal.
class FakeServer {
  FakeServer._(this.dir);

  final Directory dir;

  static Future<FakeServer> create({
    bool tmux = false,
    bool screen = false,
    int tmuxHasSession = 1,
    int screenHasSession = 1,
  }) async {
    final dir = await Directory.systemTemp.createTemp('ssg_persistent_');
    final server = FakeServer._(dir);
    await Link('${dir.path}/sh').create('/bin/sh');
    if (tmux) {
      await server._stub('tmux', '''
if [ "\$1" = has-session ]; then exit $tmuxHasSession; fi
printf 'tmux|'; printf '%s|' "\$@"''');
    }
    if (screen) {
      await server._stub('screen', '''
if [ "\$3" = -X ]; then exit $screenHasSession; fi
printf 'screen|'; printf '%s|' "\$@"''');
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
      expect(persistentSessionName(hostNamed('Test box'), 1), 'ssg-test-box-1');
      expect(
        persistentSessionName(hostNamed('prod.db:5432'), 2),
        'ssg-prod-db-5432-2',
      );
    });

    test('fall back to the address when the host has no label', () {
      expect(persistentSessionName(hostNamed(''), 1), 'ssg-dev-example-com-1');
    });

    test('stay short, and never empty', () {
      final long = persistentSessionName(
        hostNamed('a very long label for a very long server name indeed'),
        3,
      );
      expect(long, 'ssg-a-very-long-label-for-a-3');
      expect(persistentSessionName(hostNamed('???'), 1), 'ssg-host-1');
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
    }) async {
      final server = await FakeServer.create(
        tmux: tmux,
        screen: screen,
        tmuxHasSession: tmuxHasSession,
        screenHasSession: screenHasSession,
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
}
