import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/mosh/mosh_connection.dart';
import 'package:secure_shell_go/services/mosh/mosh_protobuf.dart';
import 'package:secure_shell_go/services/mosh/mosh_transport.dart';

import 'support/fake_mosh.dart';

/// Mosh's state synchronisation, client side, against a scripted server and
/// a clock moved by hand.
void main() {
  final key = parseMoshKey('r9psjw/tvBdRXWy9Y7w9sw');
  late ManualClock clock;
  late FakeUdpNetwork network;
  late FakeMoshServer server;
  late MoshTransport transport;

  setUp(() async {
    clock = ManualClock();
    network = FakeUdpNetwork();
    server = FakeMoshServer(key, network);
    final connection = MoshConnection(
      key: key,
      serverAddress: InternetAddress.loopbackIPv4,
      serverPort: 60001,
      bind: network.bind,
      clock: clock.call,
    );
    await connection.open();
    transport = MoshTransport(
      connection: connection,
      width: 20,
      height: 5,
      clock: clock.call,
      random: Random(1),
    );
  });

  String row(int y) => transport.latestRemoteState.fb.rows[y].cells
      .map((c) => c.contents.isEmpty ? ' ' : c.contents)
      .join()
      .trimRight();

  List<UserEvent> events(TransportInstruction i) =>
      i.diff.isEmpty ? const [] : UserMessageCodec.decode(i.diff);

  test('the first tick sends the window size at once, then waits', () {
    transport.userStream.push(const UserResize(20, 5));
    transport.tick();
    final sent = server.receive().single;
    expect(sent.protocolVersion, 2);
    expect(sent.oldNum, 0);
    expect(sent.newNum, 1);
    expect(sent.ackNum, 0);
    expect(sent.throwawayNum, 0);
    expect((events(sent).single as UserResize).width, 20);

    clock.advance(10);
    transport.tick();
    expect(server.receive(), isEmpty);
  });

  test('keystrokes follow after the gathering delay, with the unacknowledged '
      'resize sent again alongside', () {
    transport.userStream.push(const UserResize(20, 5));
    transport.tick();
    server.receive();

    clock.advance(300);
    transport.userStream.push(UserKeystroke(Uint8List.fromList([0x61])));
    transport.tick();
    expect(server.receive(), isEmpty, reason: '1 ms to gather input');
    expect(transport.waitTime(), 1);

    clock.advance(1);
    transport.tick();
    final sent = server.receive().single;
    expect(sent.newNum, 2);
    // State 1 was sent recently enough to assume it arrived, but resending
    // it costs a few bytes and saves a round trip if it did not — Mosh's
    // "prospective resend".
    expect(sent.oldNum, 0);
    final sentEvents = events(sent);
    expect(sentEvents.first, isA<UserResize>());
    expect((sentEvents.last as UserKeystroke).bytes, [0x61]);
  });

  test('a screen arrives, is applied and acknowledged within 100 ms', () {
    server.send(
      oldNum: 0,
      newNum: 1,
      ackNum: 0,
      diff: FakeMoshServer.screen('hello'),
    );
    expect(transport.remoteStateNum, 1);
    expect(row(0), 'hello');

    transport.tick();
    server.receive();
    clock.advance(100);
    transport.tick();
    final ack = server.received.last;
    expect(ack.ackNum, 1);
    expect(ack.diff, isEmpty);
  });

  test('a diff against an older state still applies, while the server says '
      'it may use it', () {
    server.send(oldNum: 0, newNum: 1, diff: FakeMoshServer.screen('one'));
    server.send(oldNum: 1, newNum: 2, diff: FakeMoshServer.screen('\r\ntwo'));
    expect(row(1), 'two');

    // The server did not know state 2 had arrived and diffed from 1 again.
    server.send(
      oldNum: 1,
      newNum: 3,
      throwawayNum: 1,
      diff: FakeMoshServer.screen('\r\n\nthree'),
    );
    expect(transport.remoteStateNum, 3);
    expect(row(0), 'one');
    expect(row(1), '', reason: 'computed from state 1, which had no "two"');
    expect(row(2), 'three');

    // Once states below 3 are thrown away, a diff from 1 has nothing to
    // apply to and is ignored.
    server.send(oldNum: 3, newNum: 4, throwawayNum: 3);
    server.send(oldNum: 1, newNum: 5, diff: FakeMoshServer.screen('x'));
    expect(transport.remoteStateNum, 4);
  });

  test('states out of order are kept in order, and only the newest is '
      'acknowledged', () {
    server.send(oldNum: 0, newNum: 1, diff: FakeMoshServer.screen('a'));
    server.send(oldNum: 1, newNum: 3, diff: FakeMoshServer.screen('c'));
    server.send(oldNum: 1, newNum: 2, diff: FakeMoshServer.screen('b'));
    expect(transport.remoteStateNum, 3);
    expect(row(0), 'ac');
    clock.advance(100);
    transport.tick();
    expect(server.receive().last.ackNum, 3);

    // A duplicate changes nothing.
    server.send(oldNum: 1, newNum: 3, diff: FakeMoshServer.screen('zzz'));
    expect(row(0), 'ac');
  });

  test('an acknowledgement retires sent states and the input they held', () {
    transport.userStream.push(UserKeystroke(Uint8List.fromList([0x61])));
    transport.tick();
    final sent = server.receive().single;
    expect(sent.newNum, 1);

    server.send(oldNum: 0, newNum: 1, ackNum: 1);
    expect(transport.sentStateAcked, 1);

    clock.advance(500);
    transport.userStream.push(UserKeystroke(Uint8List.fromList([0x62])));
    transport.tick();
    clock.advance(1);
    transport.tick();
    final next = server.receive().single;
    expect(next.oldNum, 1);
    expect(next.throwawayNum, 1);
    expect((events(next).single as UserKeystroke).bytes, [0x62]);
  });

  test('unacknowledged input is sent again, from the last acknowledged '
      'state, once it may have been lost', () {
    // Heard from the server recently: retries are on.
    server.send(oldNum: 0, newNum: 1, ackNum: 0);
    transport.userStream.push(UserKeystroke(Uint8List.fromList([0x61])));
    clock.advance(1);
    transport.tick();
    final first = server.receive().single;
    expect(first.newNum, 1);

    // Nothing comes back. After the retransmission timeout (1 s before any
    // measurement) plus the ack delay, the same state goes again.
    clock.advance(1099);
    transport.tick();
    expect(server.receive(), isEmpty);
    clock.advance(1);
    transport.tick();
    final again = server.receive().single;
    expect(again.oldNum, 0);
    expect(again.newNum, 1);
    expect((events(again).single as UserKeystroke).bytes, [0x61]);
  });

  test('with nothing to say, an empty ack still goes every three seconds', () {
    transport.tick();
    server.receive();
    clock.advance(2999);
    transport.tick();
    expect(server.receive(), isEmpty);
    clock.advance(1);
    transport.tick();
    expect(server.receive().single.diff, isEmpty);
  });

  test("the server's shutdown is acknowledged, which ends the session", () {
    server.send(oldNum: 0, newNum: 1, diff: FakeMoshServer.screen('bye'));
    server.send(oldNum: 1, newNum: moshShutdownNum);
    expect(transport.counterpartyShutdownAckSent, isFalse);
    clock.advance(transport.waitTime());
    transport.tick();
    expect(server.receive().last.ackNum, moshShutdownNum);
    expect(transport.counterpartyShutdownAckSent, isTrue);
    expect(row(0), 'bye');
  });

  test("the client's goodbye is repeated until acknowledged", () {
    server.send(oldNum: 0, newNum: 1);
    transport.startShutdown();
    clock.advance(transport.waitTime());
    transport.tick();
    expect(server.receive().single.newNum, moshShutdownNum);
    expect(transport.shutdownAcknowledged, isFalse);

    server.send(oldNum: 1, newNum: 2, ackNum: moshShutdownNum);
    expect(transport.shutdownAcknowledged, isTrue);
  });

  test('a goodbye nobody answers gives up after sixteen tries', () {
    transport.startShutdown();
    for (var i = 0; i < 16; i++) {
      expect(transport.shutdownAckTimedOut, isFalse);
      clock.advance(transport.waitTime());
      transport.tick();
    }
    expect(server.receive(), hasLength(16));
    expect(transport.shutdownAckTimedOut, isTrue);
  });

  test('another protocol version is fatal', () {
    String? fatal;
    transport.onFatal = (reason) => fatal = reason;
    server.send(oldNum: 0, newNum: 1, protocolVersion: 3);
    expect(fatal, contains('version 3'));
    expect(transport.remoteStateNum, 0);
  });
}
