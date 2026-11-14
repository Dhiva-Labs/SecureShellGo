import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart' show SSHChannelOpenError, SSHSocket;
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/remote_desktop/csrd_client.dart';
import 'package:secure_shell_go/services/remote_desktop/remote_screen_session.dart';
import 'package:secure_shell_go/services/remote_desktop/rfb_mac_opener.dart';
import 'package:secure_shell_go/services/remote_exec.dart';

import 'rfb_test_support.dart';

/// A forwarded channel whose far end is a [FakeRfbServer].
class FakeChannel implements SSHSocket {
  FakeChannel(this.server);
  final FakeRfbServer server;
  var destroyed = false;
  late final StreamSink<List<int>> _sink = server.clientOutput;

  @override
  Stream<Uint8List> get stream => server.clientInput;
  @override
  StreamSink<List<int>> get sink => _sink;
  @override
  Future<void> get done => server.clientClosed;
  @override
  Future<void> close() => _sink.close();
  @override
  void destroy() => destroyed = true;
  @override
  Future<void> flush() async {}
}

ExecResult out(String stdout, {int exitCode = 0}) =>
    ExecResult(stdout: stdout, stderr: '', exitCode: exitCode);

/// Answers `uname -s` with [system] and the port check with [check].
RfbCommandRunner runner(String system, String check, {List<String>? log}) =>
    (command) async {
      log?.add(command);
      if (command == 'uname -s') return out('$system\n');
      if (command.contains('ssg-listening')) return out('$check\n');
      throw StateError('unexpected command $command');
    };

void main() {
  test(
    'a host that is not a Mac is refused before anything is opened',
    () async {
      var opened = false;
      final open = rfbMacOpener(
        run: runner('Linux', 'ssg-listening'),
        forwardLocal: (host, port) async {
          opened = true;
          throw StateError('no');
        },
        credentials: (_) async => null,
      );
      await expectLater(
        open(progress: (_) {}, attach: (_) {}),
        throwsA(
          isA<RfbOpenException>()
              .having((e) => e.kind, 'kind', RfbOpenFailure.notMac)
              .having((e) => e.message, 'message', contains('"Linux"')),
        ),
      );
      expect(opened, isFalse);
    },
  );

  test('Screen Sharing turned off says where to turn it on', () async {
    final open = rfbMacOpener(
      run: runner('Darwin', 'ssg-closed'),
      forwardLocal: (host, port) async => throw StateError('no'),
      credentials: (_) async => null,
    );
    await expectLater(
      open(progress: (_) {}, attach: (_) {}),
      throwsA(
        isA<RfbOpenException>()
            .having((e) => e.kind, 'kind', RfbOpenFailure.screenSharingOff)
            .having(
              (e) => e.message,
              'message',
              allOf(
                contains('System Settings → General → Sharing'),
                contains('Screen Sharing (or Remote Management)'),
              ),
            ),
      ),
    );
  });

  test(
    'a Mac with Screen Sharing on: channel, attach, connect, release',
    () async {
      final server = FakeRfbServer();
      final channel = FakeChannel(server);
      final commands = <String>[];
      final progress = <String>[];
      final forwards = <(String, int)>[];
      RemoteScreenSession? attached;
      CsrdClientState? stateAtAttach;
      final open = rfbMacOpener(
        run: runner('Darwin', 'ssg-listening', log: commands),
        forwardLocal: (host, port) async {
          forwards.add((host, port));
          return channel;
        },
        credentials: (_) async => (username: 'me', password: 'pw'),
      );
      final opening = open(
        progress: progress.add,
        attach: (session) {
          attached = session;
          stateAtAttach = session.state;
        },
      );
      await server.handshakeNone(width: 1440, height: 900, name: 'Mac');
      final handle = await opening;

      expect(forwards, [('127.0.0.1', 5900)]);
      expect(commands.first, 'uname -s');
      expect(commands[1], startsWith('sh -c '));
      expect(identical(attached, handle.session), isTrue);
      expect(stateAtAttach, CsrdClientState.idle);
      expect(handle.session.state, CsrdClientState.connected);
      expect(handle.keepsRunning, isFalse);
      expect(progress, hasLength(3));

      // Command goes out as Meta for a Mac.
      handle.session.key(125, down: true);
      expect(await server.next<KeyMsg>(), const KeyMsg(0xffe7, down: true));

      await handle.release();
      await handle.release(); // safe twice
      expect(channel.destroyed, isTrue);
      expect(handle.session.state, CsrdClientState.closed);
      // The held Command key was let go of on the way out.
      await server.settle();
      expect(server.received.last, isA<KeyMsg>());
      expect((server.received.last as KeyMsg).down, isFalse);
      await server.hangUp();
    },
  );

  test('when the check cannot tell, it tries to connect anyway', () async {
    final open = rfbMacOpener(
      run: runner('Darwin', 'ssg-unknown'),
      forwardLocal: (host, port) async =>
          throw SSHChannelOpenError(2, 'Connection refused'),
      credentials: (_) async => null,
    );
    // …and a refused connect over there is Screen Sharing being off.
    await expectLater(
      open(progress: (_) {}, attach: (_) {}),
      throwsA(
        isA<RfbOpenException>().having(
          (e) => e.kind,
          'kind',
          RfbOpenFailure.screenSharingOff,
        ),
      ),
    );
  });

  test('a forward the SSH server forbids is said to be that', () async {
    final open = rfbOpener(
      forwardLocal: (host, port) async =>
          throw SSHChannelOpenError(1, 'administratively prohibited'),
      credentials: (_) async => null,
    );
    await expectLater(
      open(progress: (_) {}, attach: (_) {}),
      throwsA(
        isA<RfbOpenException>()
            .having((e) => e.kind, 'kind', RfbOpenFailure.sshRefused)
            .having((e) => e.message, 'message', contains('127.0.0.1:5900')),
      ),
    );
  });

  test('a failed connect closes the channel and says why', () async {
    final server = FakeRfbServer();
    final channel = FakeChannel(server);
    final open = rfbMacOpener(
      run: runner('Darwin', 'ssg-listening'),
      forwardLocal: (host, port) async => channel,
      credentials: (_) async => null, // cancelled
    );
    final opening = open(progress: (_) {}, attach: (_) {});
    await server.exchangeVersion();
    server.send([1, 2]);
    await server.read(1);
    server.send(List.filled(16, 0));
    await expectLater(
      opening,
      throwsA(
        isA<CsrdConnectException>().having(
          (e) => e.reason.kind,
          'kind',
          CsrdCloseKind.local,
        ),
      ),
    );
    expect(channel.destroyed, isTrue);
  });

  test('the generic opener checks a loopback port when it can', () async {
    final open = rfbOpener(
      run: runner('Linux', 'ssg-closed'),
      port: 5901,
      forwardLocal: (host, port) async => throw StateError('no'),
      credentials: (_) async => null,
    );
    await expectLater(
      open(progress: (_) {}, attach: (_) {}),
      throwsA(
        isA<RfbOpenException>()
            .having((e) => e.kind, 'kind', RfbOpenFailure.noServer)
            .having((e) => e.message, 'message', contains('127.0.0.1:5901')),
      ),
    );

    final server = FakeRfbServer();
    final forwards = <(String, int)>[];
    final direct = rfbOpener(
      port: 5902,
      forwardLocal: (host, port) async {
        forwards.add((host, port));
        return FakeChannel(server);
      },
      credentials: (_) async => null,
    );
    final opening = direct(progress: (_) {}, attach: (_) {});
    await server.handshakeNone();
    final handle = await opening;
    expect(forwards, [('127.0.0.1', 5902)]);
    // Not a Mac: the Windows key is Super.
    handle.session.key(125, down: true);
    expect(await server.next<KeyMsg>(), const KeyMsg(0xffeb, down: true));
    await handle.release();
    await server.hangUp();
  });

  group('the port check, through a real sh', () {
    Future<String> check(int port) async {
      final r = await Process.run('sh', ['-c', rfbPortCheckCommand(port)]);
      return (r.stdout as String).trim();
    }

    test('sees a listening port, and a closed one', () async {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      try {
        expect(await check(port), 'ssg-listening');
      } finally {
        await socket.close();
      }
      expect(await check(port), anyOf('ssg-closed', 'ssg-unknown'));
    });

    test('rfbPortListening reads the answer', () async {
      Future<ExecResult> run(String c) async {
        final r = await Process.run('sh', ['-c', c]);
        return ExecResult(
          stdout: r.stdout as String,
          stderr: r.stderr as String,
          exitCode: r.exitCode,
        );
      }

      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      try {
        expect(await rfbPortListening(run, socket.port), isTrue);
      } finally {
        await socket.close();
      }
      expect(
        await rfbPortListening((_) async => throw StateError('x'), 1),
        isNull,
      );
    });
  });
}
