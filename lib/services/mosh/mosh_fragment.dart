import 'dart:io' show ZLibCodec;
import 'dart:typed_data';

import 'mosh_protobuf.dart';

/// Mosh splits each compressed [TransportInstruction] into fragments small
/// enough for one datagram, and reassembles them on the far side
/// (`network/transportfragment.cc`).
///
/// A fragment is a 10-byte header — the instruction id (uint64, big-endian)
/// and the fragment number (uint16, big-endian, top bit set on the last one)
/// — followed by a slice of the zlib-compressed instruction.
class MoshFragment {
  const MoshFragment({
    required this.id,
    required this.number,
    required this.isFinal,
    required this.contents,
  });

  static const headerLength = 10;

  final int id;
  final int number;
  final bool isFinal;
  final Uint8List contents;

  Uint8List encode() {
    final out = Uint8List(headerLength + contents.length);
    final view = ByteData.sublistView(out);
    view.setUint64(0, id);
    view.setUint16(8, (isFinal ? 0x8000 : 0) | number);
    out.setRange(headerLength, out.length, contents);
    return out;
  }

  /// Null for a datagram too short to hold a fragment header.
  static MoshFragment? decode(Uint8List bytes) {
    if (bytes.length < headerLength) return null;
    final view = ByteData.sublistView(bytes);
    final combined = view.getUint16(8);
    return MoshFragment(
      id: view.getUint64(0),
      number: combined & 0x7fff,
      isFinal: combined & 0x8000 != 0,
      contents: Uint8List.sublistView(bytes, headerLength),
    );
  }
}

/// zlib, as Mosh's `compress()`/`uncompress()` produce and expect it.
final _zlib = ZLibCodec();

/// Mosh refuses to inflate an instruction past 4 MiB (`Compressor`'s
/// buffer), which bounds what a hostile peer can make this allocate.
const _maxInstructionBytes = 2048 * 2048;

/// Collects fragments until one instruction is complete.
///
/// Like Mosh's, it only ever assembles the newest instruction: a fragment
/// with a new id throws away whatever was half-collected, since the sender
/// only starts a new instruction when the old one is obsolete.
class MoshFragmentAssembly {
  final List<MoshFragment?> _fragments = [];
  int? _currentId;
  var _arrived = 0;
  var _total = -1;

  /// Adds [fragment]; returns the instruction once it is whole.
  ///
  /// Throws [ProtobufFormatException] or [FormatException] for an
  /// instruction that does not decompress or parse — a misbehaving peer, not
  /// a lossy network, since every datagram was authenticated first.
  TransportInstruction? add(MoshFragment fragment) {
    if (_currentId != fragment.id) {
      _fragments
        ..clear()
        ..length = fragment.number + 1;
      _fragments[fragment.number] = fragment;
      _arrived = 1;
      _total = -1;
      _currentId = fragment.id;
    } else if (_fragments.length > fragment.number &&
        _fragments[fragment.number] != null) {
      // A duplicate; the first copy stands.
    } else {
      if (_fragments.length < fragment.number + 1) {
        _fragments.length = fragment.number + 1;
      }
      _fragments[fragment.number] = fragment;
      _arrived++;
    }

    if (fragment.isFinal) {
      _total = fragment.number + 1;
      if (_fragments.length > _total) {
        // Fragments numbered past the last one cannot belong to this
        // instruction; drop them, as Mosh's resize does.
        for (var i = _total; i < _fragments.length; i++) {
          if (_fragments[i] != null) _arrived--;
        }
        _fragments.length = _total;
      }
    }

    if (_arrived != _total) return null;

    final encoded = BytesBuilder(copy: false);
    for (final piece in _fragments) {
      encoded.add(piece!.contents);
    }
    _fragments.clear();
    _arrived = 0;
    _total = -1;
    final inflated = _zlib.decode(encoded.takeBytes());
    if (inflated.length > _maxInstructionBytes) {
      throw const FormatException('Mosh instruction too large');
    }
    return TransportInstruction.decode(Uint8List.fromList(inflated));
  }
}

/// Turns instructions into fragments, numbering them as Mosh's sender does.
class MoshFragmenter {
  var _nextId = 0;
  TransportInstruction? _last;
  var _lastMtu = -1;

  /// The ack number of the last instruction sent — what tells the client it
  /// has acknowledged the server's shutdown.
  int get lastAckSent => _last?.ackNum ?? 0;

  List<MoshFragment> fragment(TransportInstruction instruction, int mtu) {
    final room = mtu - MoshFragment.headerLength;
    final last = _last;
    // A retransmission of the same instruction keeps its id, so a receiver
    // can complete it from fragments of both copies.
    if (last == null ||
        instruction.oldNum != last.oldNum ||
        instruction.newNum != last.newNum ||
        instruction.ackNum != last.ackNum ||
        instruction.throwawayNum != last.throwawayNum ||
        !_sameBytes(instruction.chaff, last.chaff) ||
        instruction.protocolVersion != last.protocolVersion ||
        _lastMtu != room) {
      _nextId++;
    }
    _last = instruction;
    _lastMtu = room;

    final payload = Uint8List.fromList(_zlib.encode(instruction.encode()));
    final out = <MoshFragment>[];
    var number = 0;
    var at = 0;
    while (at < payload.length) {
      final end = payload.length - at > room ? at + room : payload.length;
      out.add(MoshFragment(
        id: _nextId,
        number: number++,
        isFinal: end == payload.length,
        contents: Uint8List.sublistView(payload, at, end),
      ));
      at = end;
    }
    return out;
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
