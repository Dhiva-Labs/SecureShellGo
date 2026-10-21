import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/services/mosh/mosh_client.dart';
import 'package:secure_shell_go/services/mosh/mosh_connection.dart';
import 'package:secure_shell_go/services/mosh/mosh_protobuf.dart';
import 'package:secure_shell_go/services/mosh/mosh_shell.dart';
import 'package:secure_shell_go/services/persistent_shell.dart';
import 'package:secure_shell_go/services/session_controller.dart';
import 'package:secure_shell_go/services/sftp_service.dart';

import 'support/fake_mosh.dart';
import 'support/link_transport.dart';

/// A session whose host has its terminal on Mosh: the terminal goes over
/// Mosh while SSH carries everything else, and an SSH drop leaves the
/// terminal alone.
void main() {
  final key = parseMoshKey('r9psjw/tvBdRXWy9Y7w9sw');

  Host moshHost({PersistentSession persistent = PersistentSession.off}) => Host(
    id: 'h1',
    label: 'Test box',
    hostname: 'example.com',
    port: 22,
    username: 'dev',
    authMethod: SshAuthMethod.password,
    transport: HostTransport.mosh,
    persistentSession: persistent,
  );

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 60));

  late FakeUdpNetwork network;
  late FakeMoshServer server;
  late LinkTransport first;
  late Dialer dialer;
  late ManualScheduler reconnects;
  late SessionController controller;
  late List<String?> moshCommands;
  Object? moshFails;

  void build(Host host) {
    network = FakeUdpNetwork();
    server = FakeMoshServer(key, network);
    first = LinkTransport(host: host);
    dialer = Dialer(LinkTransport(name: 'second', host: host));
    reconnects = ManualScheduler();
    moshCommands = [];
    moshFails = null;
    controller = SessionController(
      connection: first,
      keepaliveScheduler: (_, tick) => CrankTimer(tick),
      reconnect: ReconnectSupport(
        loadCredentials: (_) async => testCredentials,
        connect: dialer.connect,
      ),
      reconnectScheduler: reconnects.schedule,
      startMosh: (ssh, {required columns, required rows, command}) async {
        moshCommands.add(command);
        final failure = moshFails;
        if (failure != null) throw failure;
        final client = MoshClient(
          key: key,
          address: InternetAddress.loopbackIPv4,
          port: 60001,
          columns: columns,
          rows: rows,
          bind: network.bind,
        );
        final connecting = client.connect(timeout: const Duration(seconds: 2));
        await settle();
        server.receive();
        server.send(
          oldNum: 0,
          newNum: 1,
          ackNum: 1,
          diff: FakeMoshServer.screen(r'mosh$ '),
        );
        await connecting;
        return MoshShell.attach(
          client,
          const MoshServerInfo(port: 60001, key: 'r9psjw/tvBdRXWy9Y7w9sw'),
        );
      },
    );
    controller.terminal.resize(80, 24);
    addTearDown(controller.dispose);
  }

  String screen() => controller.terminal.buffer.getText();

  Iterable<int> typedAtServer() => server
      .receive()
      .where((i) => i.diff.isNotEmpty)
      .expand((i) => UserMessageCodec.decode(i.diff))
      .whereType<UserKeystroke>()
      .expand((k) => k.bytes);

  test('the terminal runs over Mosh, and SSH opens no shell', () async {
    build(moshHost());
    await controller.ensureShell();
    await settle();

    expect(first.shells, isEmpty);
    expect(controller.hasShell, isTrue);
    expect(controller.isShellReady, isTrue);
    expect(screen(), contains(r'mosh$'));
    expect(screen(), isNot(contains('Starting Mosh')));

    controller.terminal.textInput('ls');
    await settle();
    expect(String.fromCharCodes(typedAtServer()), 'ls');
  });

  test(
    'when Mosh cannot start, an SSH shell opens with one line saying why',
    () async {
      build(moshHost());
      moshFails = const MoshStartException(
        MoshStartFailure.notInstalled,
        'mosh-server is not installed on this host.',
      );
      await controller.ensureShell();

      expect(first.shells, hasLength(1));
      final lines = screen().split('\n').where((l) => l.trim().isNotEmpty);
      expect(lines, [
        'mosh-server is not installed on this host. Using SSH for this '
            'terminal.',
      ]);

      controller.terminal.textInput('ls');
      expect(first.shells.single.writes, ['ls']);
    },
  );

  test('an SSH drop leaves the Mosh terminal working, and the reconnect '
      'keeps it', () async {
    build(moshHost());
    await controller.ensureShell();
    await settle();

    first.drop(const SocketException('Connection reset'));
    await pump();

    expect(controller.isClosed, isFalse, reason: 'the terminal is fine');
    expect(controller.isReconnecting, isTrue);
    expect(controller.reconnectMessage, contains('carries on over Mosh'));
    await expectLater(
      controller.sftp(),
      throwsA(
        isA<SftpFailure>().having(
          (e) => e.message,
          'message',
          contains('reconnecting'),
        ),
      ),
    );

    controller.terminal.textInput('still here');
    await settle();
    expect(String.fromCharCodes(typedAtServer()), 'still here');

    await reconnects.fire();
    expect(controller.isReconnecting, isFalse);
    expect(controller.connection, dialer.next);
    expect((dialer.next as LinkTransport).shells, isEmpty);
    expect(moshCommands, hasLength(1), reason: 'the same Mosh session');
    expect(screen(), isNot(contains('reconnected')));

    controller.terminal.textInput('!');
    await settle();
    // Nothing was acknowledged, so the earlier keystrokes go again with it.
    expect(String.fromCharCodes(typedAtServer()), endsWith('still here!'));
  });

  test(
    'the Mosh session ending offers a restart, which starts a new one',
    () async {
      build(moshHost());
      await controller.ensureShell();
      await settle();

      server.send(oldNum: 1, newNum: moshShutdownNum, ackNum: 1);
      await settle();
      await settle();

      expect(controller.isClosed, isFalse);
      expect(controller.hasShellEnded, isTrue);
      expect(controller.shellEndedReason, 'Mosh session ended.');
      expect(reconnects.delays, isEmpty);

      await controller.restartShell();
      expect(moshCommands, hasLength(2));
      expect(controller.hasShellEnded, isFalse);
    },
  );

  test('a resize reaches mosh-server', () async {
    build(moshHost());
    await controller.ensureShell();
    await settle();
    server.receive();

    controller.terminal.resize(100, 30);
    await settle();
    final resize = server
        .receive()
        .where((i) => i.diff.isNotEmpty)
        .expand((i) => UserMessageCodec.decode(i.diff))
        .whereType<UserResize>()
        .last;
    expect((resize.width, resize.height), (100, 30));
  });

  test('a persistent session runs its tmux under mosh-server', () async {
    build(moshHost(persistent: PersistentSession.tmux));
    controller.persistentSlot = 3;
    await controller.ensureShell();
    expect(moshCommands, [
      persistentShellCommand(PersistentSession.tmux, 'ssg-test-box-3'),
    ]);
  });

  test('closing the tab says goodbye to mosh-server', () async {
    build(moshHost());
    await controller.ensureShell();
    await settle();
    server.receive();

    await controller.dispose();
    await settle();
    expect(server.receive().map((i) => i.newNum), contains(moshShutdownNum));
  });
}
