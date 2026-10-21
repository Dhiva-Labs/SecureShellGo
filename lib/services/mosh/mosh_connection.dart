import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'ocb.dart';

/// Milliseconds on a clock that only goes forward. Mosh's timers, RTT samples
/// and 16-bit timestamps all read it.
typedef MoshClock = int Function();

final Stopwatch _uptime = Stopwatch()..start();

/// The default [MoshClock]. Starts far from zero, as Mosh's (the system's
/// monotonic clock) does, because Mosh initialises "when did this last
/// happen" fields to 0 and relies on 0 meaning "long ago".
int moshMonotonicNow() => (1 << 32) + _uptime.elapsedMilliseconds;

/// The 16-byte session key `mosh-server` prints, as its 22-character base64
/// form (no padding).
Uint8List parseMoshKey(String printable) {
  if (!RegExp(r'^[A-Za-z0-9+/]{22}$').hasMatch(printable)) {
    throw const FormatException('A Mosh key is 22 base64 characters.');
  }
  final key = base64.decode('$printable==');
  if (key.length != 16 || base64.encode(key) != '$printable==') {
    throw const FormatException('A Mosh key encodes exactly 128 bits.');
  }
  return Uint8List.fromList(key);
}

/// One datagram's contents once decrypted (`Network::Packet`).
class MoshPacket {
  const MoshPacket({
    required this.seq,
    required this.toClient,
    required this.timestamp,
    required this.timestampReply,
    required this.payload,
  });

  final int seq;

  /// Which way it travels; a client only accepts packets bound for clients,
  /// so a server's own packets cannot be reflected back at it.
  final bool toClient;

  /// The sender's clock, mod 65536, or 0xffff for none.
  final int timestamp;

  /// The last timestamp the sender heard from us, advanced by how long it
  /// held it; what the round-trip time is measured from. 0xffff for none.
  final int timestampReply;
  final Uint8List payload;
}

/// Seals and opens Mosh datagrams: an 8-byte direction-and-sequence number
/// in the clear, then AES-128-OCB over two 16-bit timestamps and the payload.
/// The sequence number doubles as the nonce, so the key never sees one
/// twice.
class MoshPacketCodec {
  MoshPacketCodec(Uint8List key) : _ocb = AesOcb(key);

  final AesOcb _ocb;

  static const _directionBit = -9223372036854775807 - 1; // 1 << 63

  /// Bytes a datagram adds around its payload: sequence number, timestamps
  /// and the OCB tag.
  static const overhead = 8 + 4 + 16;

  Uint8List seal(MoshPacket packet) {
    final directionSeq =
        (packet.toClient ? _directionBit : 0) | (packet.seq & ~_directionBit);
    final plain = Uint8List(4 + packet.payload.length);
    ByteData.sublistView(plain)
      ..setUint16(0, packet.timestamp & 0xffff)
      ..setUint16(2, packet.timestampReply & 0xffff);
    plain.setRange(4, plain.length, packet.payload);
    final nonce = _nonce(directionSeq);
    final sealed = _ocb.encrypt(nonce, plain);
    return Uint8List(8 + sealed.length)
      ..setRange(0, 8, nonce, 4)
      ..setRange(8, 8 + sealed.length, sealed);
  }

  /// Null for anything that is not an authentic Mosh datagram under this key.
  MoshPacket? open(Uint8List datagram) {
    if (datagram.length < 8 + 16 + 4) return null;
    final directionSeq = ByteData.sublistView(datagram).getInt64(0);
    final plain = _ocb.decrypt(
        _nonce(directionSeq), Uint8List.sublistView(datagram, 8));
    if (plain == null || plain.length < 4) return null;
    final view = ByteData.sublistView(plain);
    return MoshPacket(
      seq: directionSeq & ~_directionBit,
      toClient: directionSeq & _directionBit != 0,
      timestamp: view.getUint16(0),
      timestampReply: view.getUint16(2),
      payload: Uint8List.sublistView(plain, 4),
    );
  }

  static Uint8List _nonce(int directionSeq) {
    final nonce = Uint8List(12);
    ByteData.sublistView(nonce).setInt64(4, directionSeq);
    return nonce;
  }
}

/// A datagram as it arrived, before any checking.
class MoshDatagram {
  const MoshDatagram(this.data, this.address, this.port);
  final Uint8List data;
  final InternetAddress address;
  final int port;
}

/// A UDP socket, behind a seam so the protocol can be tested without one.
abstract class MoshUdpSocket {
  /// Local port, for diagnostics and tests.
  int get port;

  /// Sends, or throws [SocketException]. Returns the bytes accepted (0 when
  /// the socket would have blocked).
  int send(Uint8List data, InternetAddress address, int port);

  void close();
}

/// Opens a UDP socket of [family] on a fresh local port and delivers
/// whatever arrives on it to [onDatagram].
typedef MoshUdpBinder = Future<MoshUdpSocket> Function(
  InternetAddressType family,
  void Function(MoshDatagram datagram) onDatagram,
);

/// The real thing: a [RawDatagramSocket] on every interface.
Future<MoshUdpSocket> bindRawMoshSocket(
  InternetAddressType family,
  void Function(MoshDatagram datagram) onDatagram,
) async {
  final socket = await RawDatagramSocket.bind(
    family == InternetAddressType.IPv6
        ? InternetAddress.anyIPv6
        : InternetAddress.anyIPv4,
    0,
  );
  return _RawMoshSocket(socket, onDatagram);
}

class _RawMoshSocket implements MoshUdpSocket {
  _RawMoshSocket(this._socket, void Function(MoshDatagram) onDatagram) {
    _socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      // Drain everything queued: one read event can stand for many datagrams.
      while (true) {
        final datagram = _socket.receive();
        if (datagram == null) return;
        onDatagram(MoshDatagram(datagram.data, datagram.address, datagram.port));
      }
    }, onError: (Object _) {
      // ICMP "port unreachable" and friends surface here on some platforms.
      // Mosh ignores them, since the network may well come back.
    });
  }

  final RawDatagramSocket _socket;

  @override
  int get port => _socket.port;

  @override
  int send(Uint8List data, InternetAddress address, int port) =>
      _socket.send(data, address, port);

  @override
  void close() => _socket.close();
}

/// The client end of Mosh's datagram layer (`Network::Connection`): sealing,
/// timestamps and round-trip estimation, and roaming.
///
/// **Roaming.** A client can change address at any time — Wi-Fi to LTE, a
/// new NAT mapping after sleep — and the server simply answers whatever
/// address its newest authentic packet came from. So all the client has to do
/// is keep sending. When nothing has made a round trip for ten seconds it
/// also moves to a fresh local port (a new NAT mapping), keeping the old
/// sockets open for a minute in case replies are still on their way to them.
/// [hopPort] does that at once, for when the app knows the network changed.
class MoshConnection {
  MoshConnection({
    required Uint8List key,
    required this.serverAddress,
    required this.serverPort,
    MoshUdpBinder bind = bindRawMoshSocket,
    MoshClock clock = moshMonotonicNow,
  })  : _codec = MoshPacketCodec(key),
        // ignore: prefer_initializing_formals
        _bind = bind,
        // ignore: prefer_initializing_formals
        _clock = clock,
        mtu = serverAddress.type == InternetAddressType.IPv6
            ? _ipv6Mtu - _ipv6HeaderLength
            : _ipv4Mtu - _ipv4HeaderLength;

  static const _ipv4Mtu = 1280;
  static const _ipv6Mtu = 1280;
  static const _ipv4HeaderLength = 20 + 8;
  static const _ipv6HeaderLength = 40 + 16 + 8;
  static const _fallbackMtu = 500;
  static const minRto = 50;
  static const maxRto = 1000;
  static const portHopInterval = 10000;
  static const maxPortsOpen = 10;
  static const maxOldSocketAge = 60000;

  final MoshPacketCodec _codec;
  final MoshUdpBinder _bind;
  final MoshClock _clock;

  final InternetAddress serverAddress;
  final int serverPort;

  /// Datagram payload size the sender fragments to.
  int mtu;

  /// Called with each authentic payload, in arrival order.
  void Function(Uint8List payload)? onPayload;

  final List<MoshUdpSocket> _sockets = [];
  var _binding = false;
  var _closed = false;
  var _nextSeq = 0;

  int _savedTimestamp = -1;
  int _savedTimestampReceivedAt = 0;
  int _expectedReceiverSeq = 0;
  int _lastPortChoice = -1;
  int _lastRoundtripSuccess = -1;
  bool _rttHit = false;
  double _srtt = 1000;
  double _rttvar = 500;

  /// When an authentic datagram last arrived, or null before any has.
  int? lastHeard;

  /// The last error sending raised, cleared by the next send that works.
  String? sendError;

  /// Datagrams dropped for failing authentication — someone else's traffic
  /// on the port, or tampering.
  int rejected = 0;

  double get srtt => _srtt;

  /// The retransmission timeout, RFC 6298-style from the smoothed RTT.
  int get timeout {
    final rto = (_srtt + 4 * _rttvar).ceil();
    if (rto < minRto) return minRto;
    if (rto > maxRto) return maxRto;
    return rto;
  }

  /// The local port datagrams currently go out from.
  int? get localPort => _sockets.isEmpty ? null : _sockets.last.port;

  /// Opens the first socket.
  Future<void> open() async {
    _lastPortChoice = _clock();
    _sockets.add(await _bind(serverAddress.type, _receive));
  }

  /// Told by the transport whenever an acknowledgement shows a full round
  /// trip, which is what keeps [send] from hopping ports.
  set lastRoundtripSuccess(int timestamp) => _lastRoundtripSuccess = timestamp;

  int _timestamp16() {
    var ts = _clock() % 65536;
    if (ts == 0xffff) ts = 0;
    return ts;
  }

  void send(Uint8List payload) {
    if (_closed || _sockets.isEmpty) return;
    final now = _clock();
    var timestampReply = 0xffff;
    if (now - _savedTimestampReceivedAt < 1000) {
      // Echo the server's timestamp, corrected for how long it was held.
      timestampReply =
          (_savedTimestamp + (now - _savedTimestampReceivedAt)) & 0xffff;
      _savedTimestamp = -1;
      _savedTimestampReceivedAt = 0;
    }
    final datagram = _codec.seal(MoshPacket(
      seq: _nextSeq++,
      toClient: false,
      timestamp: _timestamp16(),
      timestampReply: timestampReply,
      payload: payload,
    ));
    try {
      final sent = _sockets.last.send(datagram, serverAddress, serverPort);
      sendError = sent == datagram.length ? null : 'sendto: would block';
    } on SocketException catch (e) {
      sendError = 'sendto: ${e.osError?.message ?? e.message}';
      // EMSGSIZE, as Linux, macOS and Windows number it.
      if (const {90, 40, 10040}.contains(e.osError?.errorCode)) {
        mtu = _fallbackMtu;
      }
    }
    if (now - _lastPortChoice > portHopInterval &&
        now - _lastRoundtripSuccess > portHopInterval) {
      hopPort();
    }
  }

  /// Moves to a fresh local port, keeping the old ones listening for a while.
  void hopPort() {
    if (_closed || _binding) return;
    _lastPortChoice = _clock();
    _binding = true;
    _bind(serverAddress.type, _receive).then((socket) {
      _binding = false;
      if (_closed) {
        socket.close();
        return;
      }
      _sockets.add(socket);
      _pruneSockets();
    }, onError: (Object error) {
      _binding = false;
      sendError = 'bind: $error';
    });
  }

  /// Closes every socket but the newest, as if the network the older ones
  /// were on had gone away; whatever the server still sends to them is lost.
  void closeOldSockets() {
    while (_sockets.length > 1) {
      _sockets.removeAt(0).close();
    }
  }

  void _pruneSockets() {
    if (_sockets.length <= 1) return;
    if (_clock() - _lastPortChoice > maxOldSocketAge) {
      while (_sockets.length > 1) {
        _sockets.removeAt(0).close();
      }
    }
    while (_sockets.length > maxPortsOpen) {
      _sockets.removeAt(0).close();
    }
  }

  void _receive(MoshDatagram datagram) {
    if (_closed) return;
    final packet = _codec.open(datagram.data);
    if (packet == null || !packet.toClient) {
      rejected++;
      return;
    }
    _pruneSockets();
    if (packet.seq < _expectedReceiverSeq) {
      // Out of order: still delivered, but not used for timing.
      onPayload?.call(packet.payload);
      return;
    }
    _expectedReceiverSeq = packet.seq + 1;
    final now = _clock();
    if (packet.timestamp != 0xffff) {
      _savedTimestamp = packet.timestamp;
      _savedTimestampReceivedAt = now;
    }
    if (packet.timestampReply != 0xffff) {
      final sample = (_timestamp16() - packet.timestampReply) % 65536;
      if (sample < 5000) {
        // Larger means the far end was suspended; ignore it.
        if (!_rttHit) {
          _srtt = sample.toDouble();
          _rttvar = sample / 2;
          _rttHit = true;
        } else {
          const alpha = 1.0 / 8.0;
          const beta = 1.0 / 4.0;
          _rttvar = (1 - beta) * _rttvar + beta * (_srtt - sample).abs();
          _srtt = (1 - alpha) * _srtt + alpha * sample;
        }
      }
    }
    lastHeard = now;
    onPayload?.call(packet.payload);
  }

  void close() {
    _closed = true;
    for (final socket in _sockets) {
      socket.close();
    }
    _sockets.clear();
  }
}
