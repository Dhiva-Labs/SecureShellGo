import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/remote_app_runner.dart';
import 'package:secure_shell_go/services/session_controller.dart';
import 'package:secure_shell_go/services/ssh_forwarding_client.dart';
import 'package:secure_shell_go/services/ssh_service.dart';
import 'package:secure_shell_go/services/x11_forwarding.dart';

import 'support/link_transport.dart';
import 'support/remote_app_fakes.dart';
import 'support/scripted_ssh_peer.dart';

/// A session that is up, with the runner over it and the programs it started
/// laid out for the test to drive.
class _Rig {
  _Rig({
    X11Forwarder? forwarder,
    bool hasForwarder = true,
    bool hostX11 = true,
    bool certificateWithoutX11 = false,
    bool supported = true,
    bool windows = false,
    Future<void> Function(X11Display)? reachDisplay,
    Future<SSHSession> Function(
      SessionTransport,
      String,
      SSHX11Config,
    )? open,
  }) {
    transport = FakeX11Transport(
      host: remoteAppHost(
        x11: hostX11,
        certificateWithoutX11: certificateWithoutX11,
      ),
      forwarder: hasForwarder ? (forwarder ?? remoteAppForwarder()) : null,
    );
    session = remoteAppSession(transport);
    runner = RemoteAppRunner(
      session,
      isSupportedPlatform: supported,
      isWindows: windows,
      reachDisplay: reachDisplay ?? (_) async {},
      stopTimeout: const Duration(seconds: 1),
      openChannel: open ??
          (t, command, x11) async {
            opened.add((command: command, x11: x11));
            final app = ScriptedApp();
            programs.add(app);
            return app;
          },
    );
    addTearDown(() async {
      runner.dispose();
      await session.dispose();
    });
  }

  late final FakeX11Transport transport;
  late final SessionController session;
  late final RemoteAppRunner runner;
  final List<({String command, SSHX11Config x11})> opened = [];
  final List<ScriptedApp> programs = [];
}

class _SshLostUnderMosh extends SessionController {
  _SshLostUnderMosh(SessionTransport connection)
      : super(
          connection: connection,
          storage: RemoteAppUnusedStorage(),
          keepaliveScheduler: (_, tick) => CrankTimer(tick),
        );

  @override
  bool get isSshLostUnderMosh => true;
}

void main() {
  group('availability', () {
    test('a connection with forwarding, on a desktop, is available', () {
      final rig = _Rig();
      expect(checkRemoteAppAvailability(rig.session, supportedPlatform: true),
          RemoteAppAvailability.available);
      expect(rig.runner.availability, RemoteAppAvailability.available);
    });

    test('Android and iOS cannot, whatever the connection', () {
      final rig = _Rig(supported: false);
      expect(rig.runner.availability, RemoteAppAvailability.unsupportedDevice);
    });

    test('a host with X11 off still can: each app asks on its own channel',
        () {
      final rig = _Rig(hostX11: false);
      expect(rig.runner.availability, RemoteAppAvailability.available);
    });

    test('no display on this device is its own reason, switch on or off', () {
      expect(_Rig(hostX11: true, hasForwarder: false).runner.availability,
          RemoteAppAvailability.noLocalDisplay);
      expect(_Rig(hostX11: false, hasForwarder: false).runner.availability,
          RemoteAppAvailability.noLocalDisplay);
    });

    test('a closed connection is unavailable, not blamed on X11', () {
      final rig = _Rig();
      rig.transport.close();
      expect(rig.runner.availability, RemoteAppAvailability.sshUnavailable);
    });

    test('so is SSH lost under a Mosh terminal', () {
      final transport = FakeX11Transport(forwarder: remoteAppForwarder());
      final session = _SshLostUnderMosh(transport);
      addTearDown(session.dispose);
      expect(session.isClosed, isFalse);
      expect(checkRemoteAppAvailability(session, supportedPlatform: true),
          RemoteAppAvailability.sshUnavailable);
    });

    test('a device that cannot do it is told so before anything else', () {
      final rig = _Rig(supported: false, hostX11: false, hasForwarder: false);
      rig.transport.close();
      expect(rig.runner.availability, RemoteAppAvailability.unsupportedDevice);
    });

    test('an X server that does not answer is found by probing', () async {
      var up = false;
      final rig = _Rig(reachDisplay: (_) async {
        if (!up) throw const SocketException('Connection refused');
      });
      expect(rig.runner.availability, RemoteAppAvailability.available);

      expect(await rig.runner.probe(), RemoteAppAvailability.noLocalDisplay);
      expect(rig.runner.availability, RemoteAppAvailability.noLocalDisplay);
      await expectLater(
        rig.runner.launch('xeyes'),
        throwsA(isA<RemoteAppUnavailable>()),
      );

      // VcXsrv started since: Check again.
      up = true;
      expect(await rig.runner.probe(), RemoteAppAvailability.available);
      expect(rig.runner.availability, RemoteAppAvailability.available);
    });

    test('probing also learns whether programs get limited access', () async {
      final limited = _Rig(forwarder: remoteAppForwarder());
      expect(limited.runner.trusted, isNull);
      await limited.runner.probe();
      expect(limited.runner.trusted, isFalse);

      final full = _Rig(forwarder: remoteAppForwarder(untrusted: false));
      await full.runner.probe();
      expect(full.runner.trusted, isTrue);
    });

    test('a certificate without permit-X11-forwarding is noticed', () {
      expect(_Rig().runner.certificateBlocksX11, isFalse);
      expect(_Rig(certificateWithoutX11: true).runner.certificateBlocksX11,
          isTrue);
    });
  });

  group('the command on the server', () {
    test('prints its pid, then becomes the command', () {
      expect(
        RemoteAppRunner.wrapCommand('xeyes'),
        r"""sh -c 'echo $$; exec sh -c "$1"' sh 'xeyes'""",
      );
    });

    test('quotes a command with quotes in it once, for any login shell', () {
      expect(
        RemoteAppRunner.wrapCommand("xmessage 'it''s'"),
        r"""sh -c 'echo $$; exec sh -c "$1"' sh 'xmessage '\''it'\'''\''s'\'''""",
      );
    });

    test('run by a real sh: the pid printed is the one the command runs in',
        () async {
      const command = r'''printf "%s\n" "$$" "a b" 'it'"'"'s'; echo $HOME | wc -c''';
      final result = await Process.run(
        'sh',
        ['-c', RemoteAppRunner.wrapCommand(command)],
      );
      final lines = (result.stdout as String).trim().split('\n');
      // The wrapper's pid, then the command's own $$ — the same shell,
      // since the wrapper exec'd.
      expect(lines[0], matches(RegExp(r'^\d+$')));
      expect(lines[1], lines[0]);
      expect(lines[2], 'a b');
      expect(lines[3], "it's");
      expect(int.parse(lines[4].trim()), greaterThan(1));
    }, skip: Platform.isWindows ? 'needs a POSIX sh' : false);

    test('reaches the program exactly as typed, quotes and all', () async {
      const command = r"""printf '%s\n' 'a"b' "c'd" '$HOME' 'e\f' """;
      final result = await Process.run(
        'sh',
        ['-c', RemoteAppRunner.wrapCommand(command)],
      );
      final lines = (result.stdout as String).split('\n');
      expect(lines.skip(1).take(4).toList(), [
        'a"b',
        "c'd",
        r'$HOME',
        r'e\f',
      ]);
    }, skip: Platform.isWindows ? 'needs a POSIX sh' : false);

    test('the kill ends the program whether its shell ran it in place or not',
        () async {
      final process = await Process.start(
        'sh',
        ['-c', RemoteAppRunner.wrapCommand('sleep 60')],
      );
      final lines = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      final pid = int.parse(await lines.first);
      var running = true;
      unawaited(process.exitCode.then((_) => running = false));

      // What the shell with that pid is running for it (dash forks it; bash
      // would have been the sleep itself).
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final children = [
        for (final line in (await Process.run('pgrep', ['-P', '$pid']))
            .stdout
            .toString()
            .split('\n'))
          if (line.trim().isNotEmpty) int.parse(line.trim()),
      ];
      bool alive(int p) => Directory('/proc/$p').existsSync();

      await Process.run('sh', ['-c', RemoteAppRunner.killCommand(pid)]);
      await process.exitCode.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(running, isFalse);
      expect(alive(pid), isFalse);
      expect(children.where(alive), isEmpty,
          reason: 'nothing of it is left behind');
    }, skip: Platform.isWindows ? 'needs a POSIX sh' : false);

    test('stop kills the children, then the process', () {
      expect(RemoteAppRunner.killCommand(4242),
          'pkill -P 4242 2>/dev/null; kill 4242 2>/dev/null');
    });
  });

  group('launching', () {
    test('asks for x11 with the connection\'s fake cookie, and runs the wrapped command',
        () async {
      final rig = _Rig();
      final app = await rig.runner.launch('  xeyes -geometry 200x200  ');

      expect(app.command, 'xeyes -geometry 200x200');
      expect(app.state, isA<RemoteAppRunning>());
      expect(rig.opened, hasLength(1));
      expect(rig.opened.single.command,
          RemoteAppRunner.wrapCommand('xeyes -geometry 200x200'));
      final forwarder = rig.transport.forwarder!;
      expect(rig.opened.single.x11.authenticationCookie,
          forwarder.config.authenticationCookie);
      expect(rig.opened.single.x11.authenticationCookie,
          '0102030405060708090a0b0c0d0e0f10');
      expect(rig.runner.apps, [app]);
      expect(rig.runner.activeCount, 1);
    });

    test('decides limited or full access before the program uses the display',
        () async {
      final rig = _Rig(forwarder: remoteAppForwarder(untrusted: false));
      final app = await rig.runner.launch('xeyes');
      expect(app.trusted, isTrue);
      expect(rig.runner.trusted, isTrue);
    });

    test('an empty command is not launched', () {
      final rig = _Rig();
      expect(() => rig.runner.launch('   '), throwsArgumentError);
    });

    test('launching where it cannot work says why', () async {
      final rig = _Rig(hasForwarder: false);
      await expectLater(
        rig.runner.launch('xeyes'),
        throwsA(isA<RemoteAppUnavailable>().having(
            (e) => e.reason, 'reason', RemoteAppAvailability.noLocalDisplay)),
      );
      expect(rig.runner.apps, isEmpty);
    });

    test('the channel is told there is nothing to read on stdin', () async {
      final rig = _Rig();
      await rig.runner.launch('xeyes');
      expect(rig.programs.single.stdinClosed, isTrue);
    });

    test('notifies as apps are added and change', () async {
      final rig = _Rig();
      var notified = 0;
      rig.runner.addListener(() => notified++);
      final app = await rig.runner.launch('xeyes');
      final afterLaunch = notified;
      expect(afterLaunch, greaterThanOrEqualTo(2));

      rig.programs.single.say('77\n');
      await pumpEventQueue();
      expect(app.pid, 77);
      expect(notified, greaterThan(afterLaunch));
    });
  });

  group('the process id', () {
    test('is the first line of stdout', () async {
      final rig = _Rig();
      final app = await rig.runner.launch('xeyes');
      expect(app.pid, isNull);
      rig.programs.single.say('4242\n');
      await pumpEventQueue();
      expect(app.pid, 4242);
    });

    test('is put together from pieces', () async {
      final rig = _Rig();
      final app = await rig.runner.launch('xeyes');
      rig.programs.single.say('42');
      await pumpEventQueue();
      expect(app.pid, isNull);
      rig.programs.single.say('42\nhello from the program\n');
      await pumpEventQueue();
      expect(app.pid, 4242);
    });

    test('is found after a banner some shells print first', () async {
      final rig = _Rig();
      final app = await rig.runner.launch('xeyes');
      rig.programs.single.say('Welcome back\n4242\n');
      await pumpEventQueue();
      expect(app.pid, 4242);
    });

    test('is not taken from the program\'s own output', () async {
      final rig = _Rig();
      final app = await rig.runner.launch('seq 1 9');
      // Four lines that are not a pid, then numbers from the program.
      rig.programs.single.say('a\nb\nc\nd\n123\n');
      await pumpEventQueue();
      expect(app.pid, isNull);
    });
  });

  group('stderr', () {
    test('keeps the last 8 KB and says it dropped the rest', () async {
      final rig = _Rig();
      final app = await rig.runner.launch('noisy');
      final program = rig.programs.single;
      for (var i = 0; i < 40; i++) {
        program.complain(utf8.encode('${'x' * 511}\n'));
      }
      program.complain(utf8.encode('the last word\n'));
      await pumpEventQueue();

      expect(utf8.encode(app.stderrTail).length, lessThanOrEqualTo(8192));
      expect(app.stderrTail, endsWith('the last word\n'));
      expect(app.stderrTruncated, isTrue);
      expect(rig.runner.apps.single.stderrTail, app.stderrTail);
    });

    test('a short message is kept whole', () async {
      final rig = _Rig();
      final app = await rig.runner.launch('nope');
      rig.programs.single.complain(utf8.encode('sh: 1: nope: not found\n'));
      await pumpEventQueue();
      expect(app.stderrTail, 'sh: 1: nope: not found\n');
      expect(app.stderrTruncated, isFalse);
    });

    test('a cut through a character leaves no half of it', () {
      final tail = StderrTail(capacity: 8);
      // Each euro sign is three bytes; 8 bytes cut the third one.
      tail.add(utf8.encode('€€€'));
      expect(tail.text, isNot(contains('�')));
      expect(tail.text, '€€');
      expect(tail.truncated, isTrue);
    });

    test('one write bigger than the cap keeps its end', () {
      final tail = StderrTail(capacity: 4);
      tail.add(utf8.encode('abcdefgh'));
      expect(tail.text, 'efgh');
      expect(tail.truncated, isTrue);
    });

    test('bytes that are not UTF-8 do not break it', () {
      final tail = StderrTail()..add([0x68, 0xff, 0x69]);
      expect(tail.text, 'h�i');
    });

    test("sshd's note about a new .Xauthority is not the app's", () {
      expect(
          withoutSshdNotes('/usr/bin/xauth:  file /home/demo/.Xauthority does '
              'not exist\nError: Can\'t open display\n'),
          "Error: Can't open display\n");
      expect(withoutSshdNotes('xauth:  file /root/.Xauthority does not exist'),
          isEmpty);
      expect(withoutSshdNotes('my app: file x does not exist\n'),
          'my app: file x does not exist\n');
    });
  });

  group('how it ends', () {
    test('an exit code', () async {
      final rig = _Rig();
      final app = await rig.runner.launch('false');
      rig.programs.single.say('9\n');
      rig.programs.single.complain(utf8.encode('boom\n'));
      rig.programs.single.end(code: 3);
      await pumpEventQueue();

      expect(app.state, isA<RemoteAppExited>()
          .having((s) => s.code, 'code', 3)
          .having((s) => s.stopped, 'stopped', isFalse));
      expect(app.isActive, isFalse);
      expect(app.stderrTail, 'boom\n');
      expect(rig.runner.activeCount, 0);
    });

    test('a signal', () async {
      final rig = _Rig();
      final app = await rig.runner.launch('crashy');
      rig.programs.single.end(signal: 'SEGV');
      await pumpEventQueue();
      expect(app.state, isA<RemoteAppExited>()
          .having((s) => s.signal, 'signal', 'SEGV')
          .having((s) => s.code, 'code', isNull));
    });

    test('a connection that goes away mid-run is lost, not exited', () async {
      final rig = _Rig();
      final app = await rig.runner.launch('xeyes');
      final program = rig.programs.single;

      rig.transport.drop();
      program.end();
      await pumpEventQueue();

      expect(app.state, isA<RemoteAppFailed>().having(
          (s) => s.failure, 'failure', RemoteAppFailure.connectionLost));
      expect(rig.runner.availability, RemoteAppAvailability.sshUnavailable);
    });

    test('a channel the server just closes is an exit with no status',
        () async {
      final rig = _Rig();
      final app = await rig.runner.launch('xeyes');
      rig.programs.single.end();
      await pumpEventQueue();
      expect(app.state, isA<RemoteAppExited>()
          .having((s) => s.code, 'code', isNull)
          .having((s) => s.signal, 'signal', isNull));
    });

    test('ended apps can be cleared away; running ones cannot', () async {
      final rig = _Rig();
      final done = await rig.runner.launch('a');
      final running = await rig.runner.launch('b');
      rig.programs.first.end(code: 0);
      await pumpEventQueue();

      rig.runner.remove(running);
      expect(rig.runner.apps, [done, running]);
      rig.runner.remove(done);
      expect(rig.runner.apps, [running]);

      rig.programs.last.end(code: 0);
      await pumpEventQueue();
      rig.runner.clearFinished();
      expect(rig.runner.apps, isEmpty);
    });
  });

  group('stop', () {
    test('kills the process in a separate exec, then closes the channel',
        () async {
      final rig = _Rig();
      final app = await rig.runner.launch('xeyes');
      rig.programs.single.say('4242\n');
      await pumpEventQueue();

      await rig.runner.stop(app);

      expect(rig.transport.commands,
          [RemoteAppRunner.killCommand(4242)]);
      expect(rig.transport.commands.single, contains('kill 4242'));
      expect(rig.programs.single.wasClosed, isTrue);
      expect(app.state, isA<RemoteAppExited>()
          .having((s) => s.stopped, 'stopped', isTrue));
      expect(app.isStopping, isFalse);
    });

    test('before the server has said the pid it only closes the channel',
        () async {
      final rig = _Rig();
      final app = await rig.runner.launch('xeyes');

      await rig.runner.stop(app);

      expect(rig.transport.commands, isEmpty);
      expect(rig.programs.single.wasClosed, isTrue);
      expect(app.state, isA<RemoteAppExited>()
          .having((s) => s.stopped, 'stopped', isTrue));
    });

    test('says Stopping while the kill is on its way', () async {
      final rig = _Rig();
      final app = await rig.runner.launch('xeyes');
      rig.programs.single.say('4242\n');
      await pumpEventQueue();

      final stopping = rig.runner.stop(app);
      expect(app.isStopping, isTrue);
      await stopping;
    });

    test('is still closed when the kill cannot be sent', () async {
      final rig = _Rig();
      final app = await rig.runner.launch('xeyes');
      rig.programs.single.say('4242\n');
      await pumpEventQueue();
      // A connection already gone has nothing to kill with.
      rig.transport.close();

      await rig.runner.stop(app);

      expect(rig.transport.commands, isEmpty);
      expect(rig.programs.single.wasClosed, isTrue);
      expect(app.isActive, isFalse);
    });

    test('twice, or on an app that has ended, does nothing more', () async {
      final rig = _Rig();
      final app = await rig.runner.launch('xeyes');
      rig.programs.single.say('4242\n');
      await pumpEventQueue();

      await Future.wait([rig.runner.stop(app), rig.runner.stop(app)]);
      await rig.runner.stop(app);
      expect(rig.transport.commands, hasLength(1));
    });

    test('stopAll stops everything that is running', () async {
      final rig = _Rig();
      await rig.runner.launch('a');
      await rig.runner.launch('b');
      await rig.runner.stopAll();
      expect(rig.runner.activeCount, 0);
      expect(rig.programs.every((p) => p.wasClosed), isTrue);
    });
  });

  group('when the server says no', () {
    test('an x11 refusal is reported as such, and remembered', () async {
      final rig = _Rig(
        open: (_, _, _) async =>
            throw SSHChannelRequestError('Failed to request x11 forwarding'),
      );

      final app = await rig.runner.launch('xeyes');

      expect(app.state, isA<RemoteAppFailed>().having(
          (s) => s.failure, 'failure', RemoteAppFailure.serverRefused));
      expect(app.isActive, isFalse);
      expect(rig.runner.availability, RemoteAppAvailability.serverRefused);
      // Its settings do not change for this connection: not asked again.
      await expectLater(
        rig.runner.launch('xeyes'),
        throwsA(isA<RemoteAppUnavailable>().having(
            (e) => e.reason, 'reason', RemoteAppAvailability.serverRefused)),
      );
    });

    test('once something is fixed there, the refusal is forgotten', () async {
      var refuse = true;
      final rig = _Rig(open: (_, _, _) async {
        if (refuse) {
          throw SSHChannelRequestError('Failed to request x11 forwarding');
        }
        return ScriptedApp();
      });
      await rig.runner.launch('xeyes');
      expect(rig.runner.availability, RemoteAppAvailability.serverRefused);

      var told = 0;
      rig.runner.addListener(() => told++);
      refuse = false;
      rig.runner.forgetRefusal();
      expect(told, 1);
      expect(rig.runner.availability, RemoteAppAvailability.available);
      rig.runner.forgetRefusal();
      expect(told, 1, reason: 'nothing left to forget');

      final app = await rig.runner.launch('xeyes');
      expect(app.isActive, isTrue);
    });

    test('another refusal is the server\'s own words, not an X11 problem',
        () async {
      final rig = _Rig(
        open: (_, _, _) async =>
            throw SSHChannelRequestError('Failed to execute command'),
      );
      final app = await rig.runner.launch('xeyes');
      expect(app.state, isA<RemoteAppFailed>()
          .having((s) => s.failure, 'failure', RemoteAppFailure.couldNotStart)
          .having((s) => s.detail, 'detail', 'Failed to execute command'));
      expect(rig.runner.availability, RemoteAppAvailability.available);
    });

    test('any other failure to open is shown against the app', () async {
      final rig = _Rig(open: (_, _, _) async => throw StateError('closed'));
      final app = await rig.runner.launch('xeyes');
      expect(app.state, isA<RemoteAppFailed>()
          .having((s) => s.failure, 'failure', RemoteAppFailure.couldNotStart)
          .having((s) => s.detail, 'detail', contains('closed')));
    });

    test('a reconnect starts again: the new connection is asked afresh',
        () async {
      final rig = _Rig(
        open: (_, _, _) async =>
            throw SSHChannelRequestError('Failed to request x11 forwarding'),
      );
      await rig.runner.launch('xeyes');
      expect(rig.runner.availability, RemoteAppAvailability.serverRefused);

      await rig.session.adoptTransport(
        FakeX11Transport(forwarder: remoteAppForwarder()),
      );
      await pumpEventQueue();

      expect(rig.runner.availability, RemoteAppAvailability.available);
    });
  });

  group('against a real client and a scripted server', () {
    late ScriptedSshPeer peer;
    late ForwardingSSHClient client;
    late X11Forwarder forwarder;

    setUp(() {
      forwarder = remoteAppForwarder();
      peer = ScriptedSshPeer();
      client = ForwardingSSHClient(
        peer.socket,
        username: 'dev',
        forwarding: ShellForwarding(x11: forwarder),
        keepAliveInterval: null,
        printTrace: peer.trace,
      );
      peer.client = client;
      addTearDown(() => closeQuietly(client.close));
      peer.authenticate();
    });

    RemoteAppRunner runnerOver(SshConnection connection) {
      final session = remoteAppSession(connection);
      final runner = RemoteAppRunner(
        session,
        isSupportedPlatform: true,
        isWindows: false,
        reachDisplay: (_) async {},
      );
      addTearDown(() async {
        runner.dispose();
        await session.dispose();
      });
      return runner;
    }

    SshConnection connection() => SshConnection(
          client: client,
          host: remoteAppHost(),
          socket: peer.socket,
        );

    test('a connection exposes the forwarder its client was built with', () {
      expect(connection().x11Forwarder, same(forwarder));
    });

    test('a connection without forwarding exposes none', () {
      final other = ScriptedSshPeer();
      final plain = SSHClient(other.socket, username: 'dev');
      addTearDown(() => closeQuietly(plain.close));
      final connection = SshConnection(
        client: plain,
        host: remoteAppHost(),
        socket: other.socket,
      );
      expect(connection.x11Forwarder, isNull);
    });

    test('one exec carries the x11 request, and no terminal', () async {
      final runner = runnerOver(connection());
      final app = await runner.launch('xeyes');

      expect(app.state, isA<RemoteAppRunning>());
      expect(peer.sessionRequests, [
        ['x11-req', 'exec'],
      ]);
      expect(peer.sent.where((l) => l.contains('x11-req')), isNotEmpty);
      expect(
        peer.sentContaining(forwarder.config.authenticationCookie),
        isNotEmpty,
        reason: 'the connection\'s fake cookie is what goes out',
      );
      await runner.stop(app);
    });

    test('a refused x11-req is read off the real client as a refusal',
        () async {
      final runner = runnerOver(connection());
      peer.refuseX11 = true;

      final app = await runner.launch('xeyes');

      expect(app.state, isA<RemoteAppFailed>().having(
          (s) => s.failure, 'failure', RemoteAppFailure.serverRefused));
      // The channel was refused before the command was ever sent.
      expect(peer.sessionRequests, [
        ['x11-req'],
      ]);
      expect(runner.availability, RemoteAppAvailability.serverRefused);
    });

    test('execs for other things still carry no x11 request', () async {
      final runner = runnerOver(connection());
      final app = await runner.launch('xeyes');
      await client.execute('uptime');
      expect(peer.sessionRequests, [
        ['x11-req', 'exec'],
        ['exec'],
      ]);
      await runner.stop(app);
    });
  });

  group('forwarder problems', () {
    Future<void> poke(X11Forwarder forwarder) async {
      // Not an X client: the forwarder reports it and hangs up.
      final channel = FakeX11Channel();
      final handled = forwarder.handle(channel);
      channel.incoming.add(Uint8List.fromList([0x00]));
      await handled;
    }

    test('show against the running app', () async {
      final forwarder = remoteAppForwarder();
      final rig = _Rig(forwarder: forwarder);
      final app = await rig.runner.launch('xeyes');
      expect(app.problems, isEmpty);

      await poke(forwarder);
      await pumpEventQueue();

      expect(app.problems, hasLength(1));
      expect(app.problems.single, contains('Something other than an X11'));
    });

    test('stop showing once the app has ended', () async {
      final forwarder = remoteAppForwarder();
      final rig = _Rig(forwarder: forwarder);
      final app = await rig.runner.launch('xeyes');
      rig.programs.single.end(code: 0);
      await pumpEventQueue();

      await poke(forwarder);
      await pumpEventQueue();

      expect(app.problems, isEmpty);
    });
  });

  group('the session', () {
    test('closing it ends its apps and closes their channels', () async {
      final rig = _Rig();
      final a = await rig.runner.launch('a');
      final b = await rig.runner.launch('b');

      await rig.session.dispose();
      await pumpEventQueue();

      for (final app in [a, b]) {
        expect(app.state, isA<RemoteAppFailed>().having(
            (s) => s.failure, 'failure', RemoteAppFailure.connectionLost));
      }
      expect(rig.programs.every((p) => p.wasClosed), isTrue);
      expect(rig.runner.activeCount, 0);
    });

    test('a reconnect ends the apps of the connection that died', () async {
      final rig = _Rig();
      final app = await rig.runner.launch('xeyes');

      await rig.session.adoptTransport(
        FakeX11Transport(forwarder: remoteAppForwarder()),
      );
      await pumpEventQueue();

      expect(app.state, isA<RemoteAppFailed>().having(
          (s) => s.failure, 'failure', RemoteAppFailure.connectionLost));
      expect(rig.programs.single.wasClosed, isTrue);
    });

    test('an app that was still opening when the session ended is closed',
        () async {
      final opening = Completer<SSHSession>();
      final rig = _Rig(open: (_, _, _) => opening.future);
      final launched = rig.runner.launch('xeyes');
      await pumpEventQueue();

      await rig.session.dispose();
      final late = ScriptedApp();
      opening.complete(late);
      final app = await launched;

      expect(late.wasClosed, isTrue);
      expect(app.isActive, isFalse);
    });

    test('one runner per session', () {
      final rig = _Rig();
      expect(identical(RemoteAppRunner.of(rig.session),
          RemoteAppRunner.of(rig.session)), isTrue);
      expect(identical(RemoteAppRunner.of(rig.session), rig.runner), isFalse);
    });
  });
}
