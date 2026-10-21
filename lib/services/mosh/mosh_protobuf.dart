import 'dart:convert';
import 'dart:typed_data';

/// The three protobuf messages Mosh puts on the wire, written by hand.
///
/// Mosh's `.proto` files are proto2 and tiny — `TransportBuffers.Instruction`
/// wraps every datagram's payload, `ClientBuffers.UserMessage` carries
/// keystrokes and resizes up, `HostBuffers.HostMessage` carries screen updates
/// down — so a code generator and a protobuf runtime would be a great deal of
/// dependency for about two hundred lines of varints. Field numbers are
/// Mosh's; unknown fields are skipped, as protobuf requires, so a newer server
/// adding a field does not break this client.
///
/// uint64 fields hold Dart ints in two's complement: Mosh's shutdown state
/// number is 2^64-1, which reads back as -1 here. Compare them with
/// [compareUint64], never `<`.

/// Orders two uint64 values held in Dart's signed 64-bit ints.
int compareUint64(int a, int b) => (a ^ _signBit).compareTo(b ^ _signBit);

// 0x8000000000000000: the sign bit, spelled so it also compiles where integer
// literals are limited to 53 bits.
const int _signBit = -9223372036854775807 - 1;

/// Mosh's state number for "shutting down": uint64 max.
const int moshShutdownNum = -1;

/// Thrown for a message that is not valid protobuf.
class ProtobufFormatException implements Exception {
  const ProtobufFormatException(this.message);
  final String message;
  @override
  String toString() => 'ProtobufFormatException: $message';
}

/// Appends protobuf fields.
class ProtoWriter {
  final BytesBuilder _out = BytesBuilder(copy: false);

  Uint8List takeBytes() => _out.takeBytes();

  void _varint(int value) {
    // Unsigned shift so a "negative" uint64 (2^63 and up) terminates.
    var v = value;
    while (true) {
      final low = v & 0x7f;
      v = v >>> 7;
      if (v == 0) {
        _out.addByte(low);
        return;
      }
      _out.addByte(low | 0x80);
    }
  }

  void _key(int field, int wireType) => _varint((field << 3) | wireType);

  /// uint32, uint64 and int32 alike: protobuf sign-extends a negative int32
  /// to ten bytes, which is exactly what a 64-bit varint of it is.
  void varintField(int field, int value) {
    _key(field, 0);
    _varint(value);
  }

  void bytesField(int field, List<int> bytes) {
    _key(field, 2);
    _varint(bytes.length);
    _out.add(bytes);
  }
}

/// Reads protobuf fields one at a time.
class ProtoReader {
  ProtoReader(this._bytes);

  final Uint8List _bytes;
  var _at = 0;

  bool get isAtEnd => _at >= _bytes.length;

  int _varint() {
    var result = 0;
    var shift = 0;
    while (true) {
      if (_at >= _bytes.length) {
        throw const ProtobufFormatException('truncated varint');
      }
      final byte = _bytes[_at++];
      if (shift < 64) result |= (byte & 0x7f) << shift;
      if (byte & 0x80 == 0) return result;
      shift += 7;
      if (shift >= 70) {
        throw const ProtobufFormatException('varint too long');
      }
    }
  }

  /// The next field's number and wire type.
  ({int field, int wireType}) next() {
    final key = _varint();
    return (field: key >>> 3, wireType: key & 7);
  }

  int readVarint() => _varint();

  /// A varint read as int32: the low 32 bits, sign-extended.
  int readInt32() => _varint().toSigned(32);

  Uint8List readBytes() {
    final length = _varint();
    if (length < 0 || _at + length > _bytes.length) {
      throw const ProtobufFormatException('truncated length-delimited field');
    }
    final out = Uint8List.sublistView(_bytes, _at, _at + length);
    _at += length;
    return out;
  }

  void skip(int wireType) {
    switch (wireType) {
      case 0:
        _varint();
      case 1:
        _advance(8);
      case 2:
        readBytes();
      case 5:
        _advance(4);
      default:
        throw ProtobufFormatException('unsupported wire type $wireType');
    }
  }

  void _advance(int n) {
    if (_at + n > _bytes.length) {
      throw const ProtobufFormatException('truncated fixed-width field');
    }
    _at += n;
  }
}

/// `TransportBuffers.Instruction`: one state transition, as sent in each
/// (possibly fragmented) datagram.
class TransportInstruction {
  const TransportInstruction({
    required this.protocolVersion,
    required this.oldNum,
    required this.newNum,
    required this.ackNum,
    required this.throwawayNum,
    required this.diff,
    required this.chaff,
  });

  final int protocolVersion;
  final int oldNum;
  final int newNum;
  final int ackNum;
  final int throwawayNum;
  final Uint8List diff;

  /// Random padding that hides how long the diff is.
  final Uint8List chaff;

  Uint8List encode() {
    final w = ProtoWriter()
      ..varintField(1, protocolVersion)
      ..varintField(2, oldNum)
      ..varintField(3, newNum)
      ..varintField(4, ackNum)
      ..varintField(5, throwawayNum)
      ..bytesField(6, diff)
      ..bytesField(7, chaff);
    return w.takeBytes();
  }

  static TransportInstruction decode(Uint8List bytes) {
    final r = ProtoReader(bytes);
    var protocolVersion = 0;
    var oldNum = 0, newNum = 0, ackNum = 0, throwawayNum = 0;
    var diff = Uint8List(0), chaff = Uint8List(0);
    while (!r.isAtEnd) {
      final key = r.next();
      switch ((key.field, key.wireType)) {
        case (1, 0):
          protocolVersion = r.readVarint() & 0xffffffff;
        case (2, 0):
          oldNum = r.readVarint();
        case (3, 0):
          newNum = r.readVarint();
        case (4, 0):
          ackNum = r.readVarint();
        case (5, 0):
          throwawayNum = r.readVarint();
        case (6, 2):
          diff = r.readBytes();
        case (7, 2):
          chaff = r.readBytes();
        default:
          r.skip(key.wireType);
      }
    }
    return TransportInstruction(
      protocolVersion: protocolVersion,
      oldNum: oldNum,
      newNum: newNum,
      ackNum: ackNum,
      throwawayNum: throwawayNum,
      diff: diff,
      chaff: chaff,
    );
  }
}

/// One thing the user did, as `ClientBuffers.UserMessage` carries it.
sealed class UserEvent {
  const UserEvent();
}

/// Bytes typed (or pasted), in order. Mosh sends keystrokes as raw bytes;
/// the server's own terminal decides what they mean.
final class UserKeystroke extends UserEvent {
  const UserKeystroke(this.bytes);
  final Uint8List bytes;
}

/// The window is now [width] × [height] cells.
final class UserResize extends UserEvent {
  const UserResize(this.width, this.height);
  final int width;
  final int height;
}

/// Encodes and decodes `ClientBuffers.UserMessage`.
abstract final class UserMessageCodec {
  /// Consecutive keystrokes share one instruction, as Mosh's own client
  /// writes them.
  static Uint8List encode(Iterable<UserEvent> events) {
    final message = ProtoWriter();
    final pending = BytesBuilder(copy: false);

    void flushKeys() {
      if (pending.isEmpty) return;
      final keystroke = ProtoWriter()..bytesField(4, pending.takeBytes());
      final instruction = ProtoWriter()..bytesField(2, keystroke.takeBytes());
      message.bytesField(1, instruction.takeBytes());
    }

    for (final event in events) {
      switch (event) {
        case UserKeystroke(:final bytes):
          pending.add(bytes);
        case UserResize(:final width, :final height):
          flushKeys();
          final resize = ProtoWriter()
            ..varintField(5, width)
            ..varintField(6, height);
          final instruction = ProtoWriter()..bytesField(3, resize.takeBytes());
          message.bytesField(1, instruction.takeBytes());
      }
    }
    flushKeys();
    return message.takeBytes();
  }

  static List<UserEvent> decode(Uint8List bytes) {
    final events = <UserEvent>[];
    final r = ProtoReader(bytes);
    while (!r.isAtEnd) {
      final key = r.next();
      if (key.field != 1 || key.wireType != 2) {
        r.skip(key.wireType);
        continue;
      }
      final inner = ProtoReader(r.readBytes());
      while (!inner.isAtEnd) {
        final k = inner.next();
        if (k.field == 2 && k.wireType == 2) {
          final keystroke = ProtoReader(inner.readBytes());
          while (!keystroke.isAtEnd) {
            final kk = keystroke.next();
            if (kk.field == 4 && kk.wireType == 2) {
              events.add(
                UserKeystroke(Uint8List.fromList(keystroke.readBytes())),
              );
            } else {
              keystroke.skip(kk.wireType);
            }
          }
        } else if (k.field == 3 && k.wireType == 2) {
          final size = _readSize(inner.readBytes());
          events.add(UserResize(size.width, size.height));
        } else {
          inner.skip(k.wireType);
        }
      }
    }
    return events;
  }
}

/// One instruction of a `HostBuffers.HostMessage`. Mosh's client acts on the
/// first of [hostBytes], [resize] and [echoAck] that is present, in that
/// order, and so does [MoshTerminalState.applyDiff].
class HostInstruction {
  const HostInstruction({this.hostBytes, this.resize, this.echoAck});

  /// Escape sequences that turn the client's copy of the screen into the
  /// server's. UTF-8.
  final Uint8List? hostBytes;
  final ({int width, int height})? resize;

  /// The newest of the client's states whose keystrokes the server has had
  /// time to echo; what confirms or refutes local-echo predictions.
  final int? echoAck;
}

/// Encodes and decodes `HostBuffers.HostMessage`.
abstract final class HostMessageCodec {
  static List<HostInstruction> decode(Uint8List bytes) {
    final out = <HostInstruction>[];
    final r = ProtoReader(bytes);
    while (!r.isAtEnd) {
      final key = r.next();
      if (key.field != 1 || key.wireType != 2) {
        r.skip(key.wireType);
        continue;
      }
      final inner = ProtoReader(r.readBytes());
      Uint8List? hostBytes;
      ({int width, int height})? resize;
      int? echoAck;
      while (!inner.isAtEnd) {
        final k = inner.next();
        if (k.field == 2 && k.wireType == 2) {
          final host = ProtoReader(inner.readBytes());
          hostBytes ??= Uint8List(0);
          while (!host.isAtEnd) {
            final hk = host.next();
            if (hk.field == 4 && hk.wireType == 2) {
              hostBytes = host.readBytes();
            } else {
              host.skip(hk.wireType);
            }
          }
        } else if (k.field == 3 && k.wireType == 2) {
          resize = _readSize(inner.readBytes());
        } else if (k.field == 7 && k.wireType == 2) {
          final ack = ProtoReader(inner.readBytes());
          echoAck ??= 0;
          while (!ack.isAtEnd) {
            final ak = ack.next();
            if (ak.field == 8 && ak.wireType == 0) {
              echoAck = ack.readVarint();
            } else {
              ack.skip(ak.wireType);
            }
          }
        } else {
          inner.skip(k.wireType);
        }
      }
      out.add(
        HostInstruction(hostBytes: hostBytes, resize: resize, echoAck: echoAck),
      );
    }
    return out;
  }

  /// The server's side, for tests that stand in for `mosh-server`.
  static Uint8List encode(List<HostInstruction> instructions) {
    final message = ProtoWriter();
    for (final instruction in instructions) {
      final inner = ProtoWriter();
      final echoAck = instruction.echoAck;
      if (echoAck != null) {
        inner.bytesField(
          7,
          (ProtoWriter()..varintField(8, echoAck)).takeBytes(),
        );
      }
      final resize = instruction.resize;
      if (resize != null) {
        inner.bytesField(
          3,
          (ProtoWriter()
                ..varintField(5, resize.width)
                ..varintField(6, resize.height))
              .takeBytes(),
        );
      }
      final hostBytes = instruction.hostBytes;
      if (hostBytes != null) {
        inner.bytesField(
          2,
          (ProtoWriter()..bytesField(4, hostBytes)).takeBytes(),
        );
      }
      message.bytesField(1, inner.takeBytes());
    }
    return message.takeBytes();
  }

  /// Convenience for tests: one instruction of host bytes from a string.
  static Uint8List hostString(String text) => encode([
    HostInstruction(hostBytes: Uint8List.fromList(utf8.encode(text))),
  ]);
}

({int width, int height}) _readSize(Uint8List bytes) {
  final r = ProtoReader(bytes);
  var width = 0, height = 0;
  while (!r.isAtEnd) {
    final k = r.next();
    if (k.field == 5 && k.wireType == 0) {
      width = r.readInt32();
    } else if (k.field == 6 && k.wireType == 0) {
      height = r.readInt32();
    } else {
      r.skip(k.wireType);
    }
  }
  return (width: width, height: height);
}
