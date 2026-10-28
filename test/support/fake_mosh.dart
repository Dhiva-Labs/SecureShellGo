import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:secure_shell_go/services/mosh/mosh_connection.dart';
import 'package:secure_shell_go/services/mosh/mosh_fragment.dart';
import 'package:secure_shell_go/services/mosh/mosh_protobuf.dart';

/// A clock a test moves by hand, starting where a real monotonic clock
/// would — far from zero (see [moshMonotonicNow]).
class ManualClock {
  int now = 1 << 32;
  int call() => now;
  void advance(int ms) => now += ms;
}

/// A datagram one of [FakeUdpNetwork]'s sockets sent.
class SentDatagram {
  SentDatagram(this.data, this.fromPort, this.address, this.port);
  final Uint8List data;
  final int fromPort;
  final InternetAddress address;
  final int port;
}

/// UDP without the network: every socket a [MoshConnection] binds is
/// recorded, and datagrams are handed to it by the test.
class FakeUdpNetwork {
  final List<FakeUdpSocket> sockets = [];
  final List<SentDatagram> sent = [];
  var _nextPort = 40000;

  Future<MoshUdpSocket> bind(
    InternetAddressType family,
    void Function(MoshDatagram datagram) onDatagram,
  ) async {
    final socket = FakeUdpSocket(this, _nextPort++, onDatagram);
    sockets.add(socket);
    return socket;
  }

  /// Takes everything sent since the last call.
  List<SentDatagram> takeSent() {
    final out = List<SentDatagram>.of(sent);
    sent.clear();
    return out;
  }
}

class FakeUdpSocket implements MoshUdpSocket {
  FakeUdpSocket(this._network, this.port, this._onDatagram);

  final FakeUdpNetwork _network;
  final void Function(MoshDatagram datagram) _onDatagram;
  var closed = false;

  @override
  final int port;

  @override
  int send(Uint8List data, InternetAddress address, int port) {
    if (closed) throw const SocketException('closed');
    _network.sent.add(SentDatagram(data, this.port, address, port));
    return data.length;
  }

  void deliver(Uint8List data) {
    if (closed) return;
    _onDatagram(MoshDatagram(data, InternetAddress.loopbackIPv4, 60001));
  }

  @override
  void close() => closed = true;
}

/// The server side of Mosh's datagram layer, built from the same codecs, for
/// tests that need a server to talk to.
class FakeMoshServer {
  FakeMoshServer(this.key, this.network) : _codec = MoshPacketCodec(key);

  final Uint8List key;
  final FakeUdpNetwork network;
  final MoshPacketCodec _codec;
  final MoshFragmenter _fragmenter = MoshFragmenter();
  final MoshFragmentAssembly _assembly = MoshFragmentAssembly();
  var _seq = 0;

  /// Every instruction the client sent, in order.
  final List<TransportInstruction> received = [];

  /// The packets they arrived in.
  final List<MoshPacket> packets = [];

  /// Opens and reassembles whatever the client has sent.
  List<TransportInstruction> receive() {
    final out = <TransportInstruction>[];
    for (final datagram in network.takeSent()) {
      final packet = _codec.open(datagram.data);
      if (packet == null) throw StateError('client sent an unreadable packet');
      packets.add(packet);
      final instruction = _assembly.add(MoshFragment.decode(packet.payload)!);
      if (instruction != null) out.add(instruction);
    }
    received.addAll(out);
    return out;
  }

  /// Sends one state transition to the client's newest socket.
  void send({
    required int oldNum,
    required int newNum,
    int ackNum = 0,
    int throwawayNum = 0,
    Uint8List? diff,
    int protocolVersion = 2,
    int timestamp = 0xffff,
    int? timestampReply,
    int mtu = 1200,
  }) {
    final instruction = TransportInstruction(
      protocolVersion: protocolVersion,
      oldNum: oldNum,
      newNum: newNum,
      ackNum: ackNum,
      throwawayNum: throwawayNum,
      diff: diff ?? Uint8List(0),
      chaff: Uint8List(0),
    );
    for (final fragment in _fragmenter.fragment(instruction, mtu)) {
      network.sockets.last.deliver(
        _codec.seal(
          MoshPacket(
            seq: _seq++,
            toClient: true,
            timestamp: timestamp,
            // Echo the client's last timestamp, as a server does, so it can
            // measure the round trip.
            timestampReply:
                timestampReply ??
                (packets.isEmpty ? 0xffff : packets.last.timestamp),
            payload: fragment.encode(),
          ),
        ),
      );
    }
  }

  /// A `HostMessage` drawing [text].
  static Uint8List screen(String text) => HostMessageCodec.encode([
    HostInstruction(hostBytes: Uint8List.fromList(utf8.encode(text))),
  ]);
}
