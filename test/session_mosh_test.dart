import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/services/mosh/mosh_bootstrap.dart';
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
  late List<MoshShell> moshShells;
  Object? moshFails;

  /// Starts a Mosh session against [server], as `MoshShell.start` would.
  Future<MoshShell> connectMosh({
    required int columns,
    required int rows,
    MoshClock? clock,
    int? pid,
  }) async {
    final client = MoshClient(
      key: key,
      address: InternetAddress.loopbackIPv4,
      port: 60001,
      columns: columns,
      rows: rows,
      bind: network.bind,
      clock: clock ?? moshMonotonicNow,
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
    final shell = MoshShell.attach(
      client,
      MoshServerInfo(port: 60001, key: 'r9psjw/tvBdRXWy9Y7w9sw', pid: pid),
    );
    moshShells.add(shell);
    return shell;
  }

  void build(
    Host host, {
    MoshClock? clock,
    int? pid,
    Future<MoshShell> Function(int start)? starting,
  }) {
    network = FakeUdpNetwork();
    server = FakeMoshServer(key, network);
    first = LinkTransport(host: host);
    dialer = Dialer(LinkTransport(name: 'second', host: host));
    reconnects = ManualScheduler();
    moshCommands = [];
    moshShells = [];
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
        final custom = starting;
        if (custom != null) return custom(moshCommands.length);
        return connectMosh(
          columns: columns,
          rows: rows,
          clock: clock,
          pid: pid,
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
      persistentShellCommand(PersistentSession.tmux, 'ssg-test-box-3_'),
    ]);
  });

  test('closing the tab says goodbye, and once mosh-server agrees the '
      'session is over and SSH closes', () async {
    build(moshHost(), pid: 4242);
    await controller.ensureShell();
    await settle();
    server.receive();

    await controller.dispose();
    await settle();
    expect(server.receive().map((i) => i.newNum), contains(moshShutdownNum));
    server.send(oldNum: 1, newNum: 2, ackNum: moshShutdownNum);
    final exit = await moshShells.single.done.timeout(
      const Duration(seconds: 2),
    );
    expect(exit.clean, isTrue, reason: 'mosh-server acknowledged the goodbye');
    await settle();
    expect(first.closeCount, greaterThan(0));
    expect(first.executed, isEmpty, reason: 'nothing left to stop');
  });

  test('a goodbye mosh-server never answers stops it over SSH', () async {
    final clock = ManualClock();
    build(moshHost(), clock: clock.call, pid: 4242);
    await controller.ensureShell();
    await settle();

    await controller.dispose();
    await settle();
    expect(first.closeCount, 0, reason: 'SSH is still needed');

    // UDP gets nowhere; Mosh gives up on the goodbye after ten seconds.
    clock.advance(11000);
    moshShells.single.repaint();
    await settle();

    expect((await moshShells.single.done).clean, isFalse);
    expect(first.executed, [stopMoshServerCommand(4242)]);
    expect(first.closeCount, greaterThan(0));
  });

  test('exiting Mosh while SSH is down ends the session, and starts no new '
      'one', () async {
    build(moshHost());
    await controller.ensureShell();
    await settle();
    first.drop(const SocketException('Connection reset'));
    await pump();
    expect(controller.isReconnecting, isTrue);

    // `exit` in the Mosh terminal.
    server.send(oldNum: 1, newNum: moshShutdownNum, ackNum: 1);
    await settle();
    await settle();

    expect(controller.isClosed, isTrue);
    expect(controller.isReconnecting, isFalse);
    expect(controller.closeReason, 'Mosh session ended.');
    expect(dialer.calls, 0);
    expect(moshCommands, hasLength(1));

    // Reconnect by hand still works, and brings a new terminal.
    controller.reconnectNow();
    await pump();
    await settle();
    expect(dialer.calls, 1);
    expect(moshCommands, hasLength(2));
  });

  test('a reconnect stopped while SSH is down under Mosh says so, and '
      'Reconnect brings SSH back', () async {
    build(moshHost());
    await controller.ensureShell();
    await settle();
    first.drop(const SocketException('Connection reset'));
    await pump();

    controller.stopReconnecting();
    expect(controller.isReconnecting, isFalse);
    expect(controller.isClosed, isFalse);
    expect(controller.isSshLostUnderMosh, isTrue);
    await expectLater(
      controller.sftp(),
      throwsA(
        isA<SftpFailure>().having(
          (e) => e.message,
          'message',
          allOf(contains('Reconnect'), isNot(contains('is reconnecting'))),
        ),
      ),
    );

    controller.reconnectNow();
    await pump();
    expect(dialer.calls, 1);
    expect(controller.connection, dialer.next);
    expect(controller.isSshLostUnderMosh, isFalse);
    expect(moshCommands, hasLength(1), reason: 'the same Mosh session');
  });

  test('the network coming back retries SSH that gave up under Mosh',
      () async {
    build(moshHost());
    final second = dialer.next;
    dialer.next = const SocketException('Network is unreachable');
    await controller.ensureShell();
    await settle();
    first.drop(const SocketException('Connection reset'));
    await pump();
    for (var i = 0; i < 20 && !controller.reconnectGaveUp; i++) {
      await reconnects.fire();
    }
    expect(controller.reconnectGaveUp, isTrue);
    expect(controller.isSshLostUnderMosh, isTrue);

    dialer.next = second;
    await controller.networkCameBack();
    await pump();
    expect(controller.connection, second);
    expect(controller.isSshLostUnderMosh, isFalse);
  });

  test('an SSH drop while Mosh starts leaves one Mosh session, not two',
      () async {
    final firstStart = Completer<MoshShell>();
    late MoshClient stale;
    build(
      moshHost(),
      starting: (start) {
        if (start > 1) return connectMosh(columns: 80, rows: 24);
        return firstStart.future;
      },
    );
    unawaited(controller.ensureShell());
    await settle();

    // SSH goes while the first mosh-server is still being reached, and the
    // reconnect lands first, starting a Mosh session of its own.
    first.drop(const SocketException('Connection reset'));
    await pump();
    await reconnects.fire();
    await settle();
    await settle();
    expect(moshCommands, hasLength(2));

    // Then the first one gets through after all.
    stale = MoshClient(
      key: key,
      address: InternetAddress.loopbackIPv4,
      port: 60001,
      columns: 80,
      rows: 24,
      bind: network.bind,
    );
    firstStart.complete(
      MoshShell.attach(
        stale,
        const MoshServerInfo(port: 60001, key: 'r9psjw/tvBdRXWy9Y7w9sw'),
      ),
    );
    await settle();

    expect(stale.transport.shutdownInProgress || stale.isClosed, isTrue,
        reason: 'the late one is told goodbye');
    controller.terminal.textInput('x');
    await settle();
    expect(String.fromCharCodes(typedAtServer()), 'x');
  });

  test('a persistent shell that ends as it starts under Mosh gives way to '
      'the login shell', () async {
    build(moshHost(persistent: PersistentSession.tmux));
    await controller.ensureShell();
    await settle();

    // What mosh-server does when its command cannot run at all.
    server.send(oldNum: 1, newNum: moshShutdownNum, ackNum: 1);
    await settle();
    await settle();

    expect(moshCommands, [
      persistentShellCommand(PersistentSession.tmux, controller.persistentName),
      null,
    ]);
    expect(controller.hasShellEnded, isFalse);
    expect(screen(), contains('tmux could not be started'));
  });
}
