import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/mosh/mosh_connection.dart';
import 'package:secure_shell_go/services/mosh/mosh_fragment.dart';
import 'package:secure_shell_go/services/mosh/mosh_protobuf.dart';

import 'support/fake_mosh.dart';

/// Mosh's wire formats: the protobuf messages, fragments, sealed datagrams,
/// and the timing the datagram layer derives from them.
void main() {
  Uint8List bytes(List<int> b) => Uint8List.fromList(b);

  group('protobuf', () {
    test(
      'a transport instruction is encoded field by field, as protoc does',
      () {
        final encoded = TransportInstruction(
          protocolVersion: 2,
          oldNum: 0,
          newNum: 1,
          ackNum: 300,
          throwawayNum: 0,
          diff: bytes([0xaa]),
          chaff: Uint8List(0),
        ).encode();
        expect(encoded, [
          0x08, 0x02, // protocol_version
          0x10, 0x00, // old_num
          0x18, 0x01, // new_num
          0x20, 0xac, 0x02, // ack_num = 300
          0x28, 0x00, // throwaway_num
          0x32, 0x01, 0xaa, // diff
          0x3a, 0x00, // chaff
        ]);
      },
    );

    test("Mosh's shutdown number is uint64 max, ten bytes on the wire", () {
      final encoded = TransportInstruction(
        protocolVersion: 2,
        oldNum: 7,
        newNum: moshShutdownNum,
        ackNum: moshShutdownNum,
        throwawayNum: 7,
        diff: Uint8List(0),
        chaff: Uint8List(0),
      ).encode();
      expect(encoded.sublist(4, 15), [
        0x18, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01, //
      ]);
      final decoded = TransportInstruction.decode(encoded);
      expect(decoded.newNum, moshShutdownNum);
      expect(decoded.ackNum, moshShutdownNum);
      expect(compareUint64(decoded.newNum, 7), greaterThan(0));
      expect(compareUint64(7, decoded.newNum), lessThan(0));
    });

    test('decoding skips fields it does not know', () {
      final decoded = TransportInstruction.decode(
        bytes([
          0x08, 0x02, //
          0x98, 0x06, 0x05, // field 99, varint
          0x18, 0x03, //
          0xa2, 0x06, 0x02, 0x01, 0x02, // field 100, bytes
          0x45, 1, 2, 3, 4, // field 8, fixed32
          0x49, 1, 2, 3, 4, 5, 6, 7, 8, // field 9, fixed64
          0x32, 0x01, 0x7a, //
        ]),
      );
      expect(decoded.protocolVersion, 2);
      expect(decoded.newNum, 3);
      expect(decoded.diff, [0x7a]);
    });

    test('truncated input is an error, not a crash', () {
      expect(
        () => TransportInstruction.decode(bytes([0x32, 0x05, 0x01])),
        throwsA(isA<ProtobufFormatException>()),
      );
      expect(
        () => TransportInstruction.decode(bytes([0x10, 0xff])),
        throwsA(isA<ProtobufFormatException>()),
      );
    });

    test('user input: adjacent keystrokes share an instruction, a resize '
        'splits them', () {
      final encoded = UserMessageCodec.encode([
        UserKeystroke(bytes([0x61])),
        UserKeystroke(bytes([0x62])),
        const UserResize(80, 24),
        UserKeystroke(bytes([0x63])),
      ]);
      expect(encoded, [
        0x0a, 0x06, 0x12, 0x04, 0x22, 0x02, 0x61, 0x62, //
        0x0a, 0x06, 0x1a, 0x04, 0x28, 0x50, 0x30, 0x18, //
        0x0a, 0x05, 0x12, 0x03, 0x22, 0x01, 0x63, //
      ]);
      final decoded = UserMessageCodec.decode(encoded);
      expect(decoded, hasLength(3));
      expect((decoded[0] as UserKeystroke).bytes, [0x61, 0x62]);
      expect((decoded[1] as UserResize).width, 80);
      expect((decoded[1] as UserResize).height, 24);
      expect((decoded[2] as UserKeystroke).bytes, [0x63]);
    });

    test('host messages: bytes, resize and echo ack, as mosh-server sends '
        'them', () {
      final decoded = HostMessageCodec.decode(
        bytes([
          0x0a, 0x04, 0x3a, 0x02, 0x40, 0x05, // echoack 5
          0x0a, 0x06, 0x1a, 0x04, 0x28, 0x64, 0x30, 0x1e, // resize 100x30
          0x0a, 0x06, 0x12, 0x04, 0x22, 0x02, 0x68, 0x69, // hostbytes "hi"
        ]),
      );
      expect(decoded, hasLength(3));
      expect(decoded[0].echoAck, 5);
      expect(decoded[1].resize, (width: 100, height: 30));
      expect(decoded[2].hostBytes, [0x68, 0x69]);
      expect(HostMessageCodec.encode(decoded), [
        0x0a, 0x04, 0x3a, 0x02, 0x40, 0x05, //
        0x0a, 0x06, 0x1a, 0x04, 0x28, 0x64, 0x30, 0x1e, //
        0x0a, 0x06, 0x12, 0x04, 0x22, 0x02, 0x68, 0x69, //
      ]);
    });

    test('a negative int32 is sign-extended to ten bytes', () {
      final encoded = UserMessageCodec.encode([const UserResize(-1, 2)]);
      final decoded = UserMessageCodec.decode(encoded).single as UserResize;
      expect(decoded.width, -1);
      expect(decoded.height, 2);
    });
  });

  group('fragments', () {
    TransportInstruction instruction(int newNum, int diffLength) {
      final random = Random(newNum);
      return TransportInstruction(
        protocolVersion: 2,
        oldNum: 0,
        newNum: newNum,
        ackNum: 0,
        throwawayNum: 0,
        // Incompressible, so it really takes several datagrams.
        diff: Uint8List.fromList(
          List.generate(diffLength, (_) => random.nextInt(256)),
        ),
        chaff: Uint8List(0),
      );
    }

    test('a 10-byte header: id, then fragment number with the final bit', () {
      final f = MoshFragment(
        id: 0x0102030405060708,
        number: 3,
        isFinal: true,
        contents: _empty,
      ).encode();
      expect(f, [1, 2, 3, 4, 5, 6, 7, 8, 0x80, 0x03]);
      final back = MoshFragment.decode(f)!;
      expect(back.id, 0x0102030405060708);
      expect(back.number, 3);
      expect(back.isFinal, isTrue);
      expect(MoshFragment.decode(bytes([1, 2, 3])), isNull);
    });

    test('a large instruction is split to the MTU and reassembled in any '
        'order, duplicates and all', () {
      final fragmenter = MoshFragmenter();
      final original = instruction(5, 3000);
      final pieces = fragmenter.fragment(original, 500);
      expect(pieces.length, greaterThan(5));
      expect(
        pieces.map((p) => p.encode().length),
        everyElement(lessThanOrEqualTo(500)),
      );
      expect(pieces.where((p) => p.isFinal), [pieces.last]);
      expect(
        pieces.map((p) => p.number),
        List.generate(pieces.length, (i) => i),
      );

      final shuffled = [...pieces.reversed, pieces[1], pieces[2]];
      final assembly = MoshFragmentAssembly();
      TransportInstruction? done;
      for (final piece in shuffled) {
        final result = assembly.add(MoshFragment.decode(piece.encode())!);
        if (result != null) done = result;
      }
      expect(done, isNotNull);
      expect(done!.newNum, 5);
      expect(done.diff, original.diff);
    });

    test(
      'a resend of the same instruction keeps its id; a new one does not',
      () {
        final fragmenter = MoshFragmenter();
        final first = fragmenter.fragment(instruction(1, 10), 500).single.id;
        final again = fragmenter.fragment(instruction(1, 10), 500).single.id;
        final next = fragmenter.fragment(instruction(2, 10), 500).single.id;
        final smaller = fragmenter.fragment(instruction(2, 10), 400).single.id;
        expect(again, first);
        expect(next, first + 1);
        expect(smaller, next + 1);
      },
    );

    test('fragments of a newer instruction abandon a half-assembled one', () {
      final fragmenter = MoshFragmenter();
      final old = fragmenter.fragment(instruction(1, 2000), 400);
      final fresh = fragmenter.fragment(instruction(2, 10), 400).single;
      final assembly = MoshFragmentAssembly();
      expect(assembly.add(old.first), isNull);
      expect(assembly.add(fresh)!.newNum, 2);
      // The rest of the old one can no longer complete it.
      TransportInstruction? late;
      for (final piece in old.skip(1)) {
        late = assembly.add(piece) ?? late;
      }
      expect(late, isNull);
    });

    test('the payload is zlib, as Mosh compresses it', () {
      final piece = MoshFragmenter().fragment(instruction(1, 0), 500).single;
      expect(piece.contents[0], 0x78); // zlib header
      expect(ZLibCodec().decode(piece.contents), instruction(1, 0).encode());
    });
  });

  group('datagrams', () {
    final key = parseMoshKey('r9psjw/tvBdRXWy9Y7w9sw');

    test('the key is 22 base64 characters for 16 bytes', () {
      expect(key, hasLength(16));
      expect(
        () => parseMoshKey('r9psjw/tvBdRXWy9Y7w9s'),
        throwsFormatException,
      );
      expect(
        () => parseMoshKey('r9psjw/tvBdRXWy9Y7w9s!'),
        throwsFormatException,
      );
      // 22 characters whose last one carries bits past the 128th.
      expect(
        () => parseMoshKey('r9psjw/tvBdRXWy9Y7w9sx'),
        throwsFormatException,
      );
    });

    test('the direction and sequence number lead in the clear, and are the '
        'nonce', () {
      final codec = MoshPacketCodec(key);
      final sealed = codec.seal(
        MoshPacket(
          seq: 0x0102,
          toClient: true,
          timestamp: 0x1234,
          timestampReply: 0xffff,
          payload: bytes([9, 9, 9]),
        ),
      );
      expect(sealed.sublist(0, 8), [0x80, 0, 0, 0, 0, 0, 0x01, 0x02]);
      expect(sealed.length, 8 + 4 + 3 + 16);
      final opened = codec.open(sealed)!;
      expect(opened.seq, 0x0102);
      expect(opened.toClient, isTrue);
      expect(opened.timestamp, 0x1234);
      expect(opened.timestampReply, 0xffff);
      expect(opened.payload, [9, 9, 9]);

      final toServer = codec.seal(
        MoshPacket(
          seq: 5,
          toClient: false,
          timestamp: 0,
          timestampReply: 0,
          payload: _empty,
        ),
      );
      expect(toServer[0], 0);
      expect(codec.open(toServer)!.toClient, isFalse);
    });

    test('anything altered, or sealed under another key, is refused', () {
      final codec = MoshPacketCodec(key);
      final sealed = codec.seal(
        MoshPacket(
          seq: 1,
          toClient: true,
          timestamp: 1,
          timestampReply: 2,
          payload: bytes([1, 2, 3]),
        ),
      );
      for (var i = 0; i < sealed.length; i++) {
        final forged = Uint8List.fromList(sealed)..[i] ^= 0x40;
        expect(codec.open(forged), isNull, reason: 'byte $i');
      }
      expect(
        MoshPacketCodec(parseMoshKey('AAAAAAAAAAAAAAAAAAAAAA')).open(sealed),
        isNull,
      );
      expect(codec.open(Uint8List(10)), isNull);
    });
  });

  group('connection', () {
    final key = parseMoshKey('r9psjw/tvBdRXWy9Y7w9sw');
    late ManualClock clock;
    late FakeUdpNetwork network;
    late MoshConnection connection;
    late MoshPacketCodec server;
    final payloads = <Uint8List>[];
    var serverSeq = 0;

    setUp(() async {
      clock = ManualClock();
      network = FakeUdpNetwork();
      connection = MoshConnection(
        key: key,
        serverAddress: InternetAddress.loopbackIPv4,
        serverPort: 60001,
        bind: network.bind,
        clock: clock.call,
      )..onPayload = payloads.add;
      server = MoshPacketCodec(key);
      payloads.clear();
      serverSeq = 0;
      await connection.open();
    });

    MoshPacket lastSent() => server.open(network.sent.last.data)!;

    void reply({
      int timestamp = 0xffff,
      int timestampReply = 0xffff,
      int? seq,
      bool toClient = true,
    }) {
      network.sockets.last.deliver(
        server.seal(
          MoshPacket(
            seq: seq ?? serverSeq++,
            toClient: toClient,
            timestamp: timestamp,
            timestampReply: timestampReply,
            payload: bytes([42]),
          ),
        ),
      );
    }

    test('the MTU leaves room for IP and UDP headers', () {
      expect(connection.mtu, 1280 - 28);
      expect(
        MoshConnection(
          key: key,
          serverAddress: InternetAddress.loopbackIPv6,
          serverPort: 1,
          bind: network.bind,
        ).mtu,
        1280 - 64,
      );
    });

    test(
      'round-trip time comes from echoed timestamps, smoothed as RFC 6298',
      () {
        expect(connection.timeout, 1000, reason: 'nothing measured yet');

        connection.send(bytes([1]));
        final first = lastSent();
        expect(first.toClient, isFalse);
        expect(first.timestamp, clock.now % 65536);
        expect(first.timestampReply, 0xffff);

        clock.advance(40);
        reply(timestampReply: first.timestamp);
        expect(connection.srtt, 40);
        expect(connection.timeout, 40 + 4 * 20);

        connection.send(bytes([2]));
        final second = lastSent();
        clock.advance(60);
        reply(timestampReply: second.timestamp);
        // RTTVAR = 3/4·20 + 1/4·|40−60|, SRTT = 7/8·40 + 1/8·60.
        expect(connection.srtt, 42.5);
        expect(connection.timeout, (42.5 + 4 * 20).ceil());
        expect(payloads, hasLength(2));
      },
    );

    test('the timeout stays between 50 ms and a second', () {
      connection.send(bytes([1]));
      reply(timestampReply: lastSent().timestamp);
      expect(connection.timeout, 50);

      connection.send(bytes([1]));
      final sent = lastSent();
      clock.advance(4000);
      reply(timestampReply: sent.timestamp);
      expect(connection.timeout, 1000);
    });

    test("the server's timestamp is echoed back, advanced by the hold time, "
        'but only within a second', () {
      reply(timestamp: 5000);
      clock.advance(30);
      connection.send(bytes([1]));
      expect(lastSent().timestampReply, 5030);

      // Used once only.
      connection.send(bytes([1]));
      expect(lastSent().timestampReply, 0xffff);

      reply(timestamp: 6000);
      clock.advance(1500);
      connection.send(bytes([1]));
      expect(lastSent().timestampReply, 0xffff);
    });

    test('a late packet is delivered but not used for timing', () {
      reply(seq: 10, timestamp: 100);
      reply(seq: 3, timestamp: 900);
      clock.advance(10);
      connection.send(bytes([1]));
      expect(lastSent().timestampReply, 110);
      expect(payloads, hasLength(2));
    });

    test("forgeries and the client's own direction are dropped", () {
      reply(toClient: false);
      network.sockets.last.deliver(Uint8List(40));
      expect(payloads, isEmpty);
      expect(connection.rejected, 2);
      expect(connection.lastHeard, isNull);
    });

    test('after ten seconds without a round trip it moves to a new port, and '
        'the old one keeps listening', () async {
      connection.send(bytes([1]));
      expect(network.sockets, hasLength(1));
      clock.advance(10001);
      connection.send(bytes([2]));
      await Future<void>.delayed(Duration.zero);
      expect(network.sockets, hasLength(2));
      expect(connection.localPort, network.sockets.last.port);

      network.sent.clear();
      connection.send(bytes([3]));
      expect(network.sent.single.fromPort, network.sockets.last.port);

      network.sockets.first.deliver(
        server.seal(
          MoshPacket(
            seq: 0,
            toClient: true,
            timestamp: 1,
            timestampReply: 0xffff,
            payload: bytes([7]),
          ),
        ),
      );
      expect(payloads.last, [7], reason: 'replies to the old port still count');

      // A recent round trip keeps it where it is.
      clock.advance(5000);
      connection.lastRoundtripSuccess = clock.now;
      clock.advance(5001);
      connection.send(bytes([4]));
      await Future<void>.delayed(Duration.zero);
      expect(network.sockets, hasLength(2));
    });

    test('old sockets are let go a minute after the last move', () async {
      connection.hopPort();
      await Future<void>.delayed(Duration.zero);
      expect(network.sockets.where((s) => !s.closed), hasLength(2));
      clock.advance(60001);
      reply();
      expect(network.sockets.where((s) => !s.closed), hasLength(1));
      expect(network.sockets.last.closed, isFalse);
    });
  });
}

final _empty = Uint8List(0);
