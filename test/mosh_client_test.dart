import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/mosh/mosh_client.dart';
import 'package:secure_shell_go/services/mosh/mosh_connection.dart';
import 'package:secure_shell_go/services/mosh/mosh_protobuf.dart';
import 'package:xterm/core.dart';

import 'support/fake_mosh.dart';

/// The client's event loop against a scripted server: what reaches the
/// terminal, what goes back, and how a session ends.
void main() {
  final key = parseMoshKey('r9psjw/tvBdRXWy9Y7w9sw');
  late FakeUdpNetwork network;
  late FakeMoshServer server;
  late MoshClient client;
  late Terminal terminal;

  setUp(() {
    network = FakeUdpNetwork();
    server = FakeMoshServer(key, network);
    terminal = Terminal()..resize(20, 4);
    client = MoshClient(
      key: key,
      address: InternetAddress.loopbackIPv4,
      port: 60001,
      columns: 20,
      rows: 4,
      bind: network.bind,
    );
    client.output.listen(terminal.write);
  });

  tearDown(() => client.abandon());

  String row(int y) => terminal.buffer.lines[y].toString().trimRight();

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 60));

  Future<void> connect() async {
    final connecting = client.connect(timeout: const Duration(seconds: 2));
    await settle();
    final hello = server.receive().single;
    expect(
      (UserMessageCodec.decode(hello.diff).single as UserResize).width,
      20,
    );
    server.send(
      oldNum: 0,
      newNum: 1,
      ackNum: 1,
      diff: FakeMoshServer.screen(r'$ '),
    );
    await connecting;
    await settle();
  }

  test(
    'connects, draws the server\'s screen, and sends what is typed',
    () async {
      await connect();
      expect(client.isConnected, isTrue);
      expect(row(0), r'$');
      expect(terminal.buffer.cursorX, 2);

      client.sendInput('ls\r'.codeUnits);
      await settle();
      final typed = server.receive().expand(
        (i) => i.diff.isEmpty
            ? const <UserEvent>[]
            : UserMessageCodec.decode(i.diff),
      );
      expect(
        typed.whereType<UserKeystroke>().expand((k) => k.bytes),
        'ls\r'.codeUnits,
      );

      server.send(
        oldNum: 1,
        newNum: 2,
        ackNum: 2,
        diff: FakeMoshServer.screen('ls\r\nfile\r\n\$ '),
      );
      await settle();
      expect([row(0), row(1), row(2)], [r'$ ls', 'file', r'$']);
    },
  );

  test(
    'a resize is sent at once and the screen redrawn at the new size',
    () async {
      await connect();
      terminal.resize(30, 6);
      client.resize(30, 6);
      await settle();
      final sent = server
          .receive()
          .where((i) => i.diff.isNotEmpty)
          .expand((i) => UserMessageCodec.decode(i.diff))
          .whereType<UserResize>()
          .last;
      expect((sent.width, sent.height), (30, 6));
      expect(row(0), r'$');
    },
  );

  test('the server ending the session ends it here, cleanly', () async {
    await connect();
    server.send(
      oldNum: 1,
      newNum: moshShutdownNum,
      ackNum: 1,
      diff: FakeMoshServer.screen('\r\nlogout'),
    );
    final exit = await client.done.timeout(const Duration(seconds: 2));
    expect(exit.clean, isTrue);
    expect(row(1), 'logout');
    expect(server.receive().last.ackNum, moshShutdownNum);
  });

  test('closing says goodbye until the server agrees', () async {
    await connect();
    final closing = client.close();
    await settle();
    final goodbye = server.receive().last;
    expect(goodbye.newNum, moshShutdownNum);
    server.send(oldNum: 1, newNum: 2, ackNum: moshShutdownNum);
    expect((await closing.timeout(const Duration(seconds: 2))).clean, isTrue);
  });

  test('a server that never answers is reported', () async {
    await expectLater(
      client.connect(timeout: const Duration(milliseconds: 200)),
      throwsA(isA<MoshUnreachableException>()),
    );
    expect(client.isClosed, isTrue);
    expect((await client.done).clean, isFalse);
  });
}
