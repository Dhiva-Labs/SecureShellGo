/// RFB (VNC) on the wire: the constants, the client's own messages, and the
/// reader that pulls the server's bytes off a stream.
///
/// RFB is specified by RFC 6143 (version 3.8) and the community-maintained
/// `rfbproto` document, which adds the pseudo-encodings used here. Every
/// integer on the wire is big-endian.
///
/// Unlike CSRD, RFB messages carry no length: how long a message is only
/// becomes known while reading it (a rect's encoding decides what follows
/// its header). So the server's side is read by pulling, with
/// [RfbByteReader], rather than by cutting the stream into frames first.
/// The server is untrusted: nothing here allocates for more than has
/// actually arrived, and every count it sends is checked by the caller
/// before it is used to size anything.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

/// Largest framebuffer side accepted, matching CSRD's `csrdMaxDimension`.
/// The area is capped separately, at `csrdMaxFramePixels` (8192 × 8192):
/// two 5K screens side by side are wider than 8192 but well within it.
const int rfbMaxDimension = 16384;

/// Largest cursor side accepted, as for CSRD.
const int rfbMaxCursorSide = 256;

/// Largest desktop name, cut text and failure reason accepted, in bytes.
const int rfbMaxText = 1 << 20;

/// Largest Diffie-Hellman key in Apple Remote Desktop authentication, in
/// bytes: 4096 bits, four times what macOS actually sends.
const int rfbMaxDhKeyBytes = 512;

/// Pixels a single update may cover, as a multiple of the framebuffer's
/// area. A real server never sends overlapping rects, so its updates cover
/// the screen at most once; anything far over that is a server making this
/// viewer decode the same pixels over and over.
const int rfbMaxUpdateCoverage = 4;

/// Message types, server to client.
abstract final class RfbServerMessage {
  static const framebufferUpdate = 0;
  static const setColourMapEntries = 1;
  static const bell = 2;
  static const serverCutText = 3;
}

/// Message types, client to server.
abstract final class RfbClientMessage {
  static const setPixelFormat = 0;
  static const setEncodings = 2;
  static const framebufferUpdateRequest = 3;
  static const keyEvent = 4;
  static const pointerEvent = 5;
  static const clientCutText = 6;
}

/// Security types this client knows.
abstract final class RfbSecurity {
  static const invalid = 0;
  static const none = 1;
  static const vncAuth = 2;

  /// Apple Remote Desktop: Diffie-Hellman, then the macOS account's user
  /// name and password under AES-128.
  static const appleRemoteDesktop = 30;
}

/// Encodings and pseudo-encodings.
abstract final class RfbEncoding {
  static const raw = 0;
  static const copyRect = 1;
  static const zrle = 16;
  static const cursor = -239;
  static const desktopSize = -223;
  static const lastRect = -224;
  static const extendedDesktopSize = -308;

  /// What this client asks for, most preferred first.
  static const List<int> requested = [
    zrle,
    copyRect,
    raw,
    cursor,
    desktopSize,
    extendedDesktopSize,
    lastRect,
  ];
}

/// Pointer button-mask bits.
abstract final class RfbButtonMask {
  static const left = 1 << 0;
  static const middle = 1 << 1;
  static const right = 1 << 2;
  static const wheelUp = 1 << 3;
  static const wheelDown = 1 << 4;
  static const wheelLeft = 1 << 5;
  static const wheelRight = 1 << 6;

  /// X button 8, which X clients take as Back. Forward is button 9, which
  /// the 8-bit mask cannot carry.
  static const back = 1 << 7;
}

/// What the server sent was not RFB, or not RFB this client accepts: a
/// value out of range, a rect outside the framebuffer, corrupt compressed
/// data, an unknown message or encoding.
class RfbProtocolException implements Exception {
  const RfbProtocolException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The stream ended while a read was waiting on it.
class RfbEndOfStream implements Exception {
  const RfbEndOfStream();
  @override
  String toString() => 'the connection was closed';
}

// ------------------------------------------------------- client messages

/// The pixel format this client always asks for: 32 bits per pixel, depth
/// 24, little-endian true colour with red at bit 16, green at 8 and blue at
/// 0. In memory that is B, G, R, X: `ui.PixelFormat.bgra8888` once the X
/// byte is made 0xFF. ZRLE then sends three-byte CPIXELs, B, G, R.
Uint8List rfbSetPixelFormat() {
  final b = ByteData(20);
  b.setUint8(0, RfbClientMessage.setPixelFormat);
  // 1..3 padding.
  b.setUint8(4, 32); // bits per pixel
  b.setUint8(5, 24); // depth
  b.setUint8(6, 0); // big-endian flag
  b.setUint8(7, 1); // true colour
  b.setUint16(8, 255); // red max
  b.setUint16(10, 255); // green max
  b.setUint16(12, 255); // blue max
  b.setUint8(14, 16); // red shift
  b.setUint8(15, 8); // green shift
  b.setUint8(16, 0); // blue shift
  // 17..19 padding.
  return b.buffer.asUint8List();
}

Uint8List rfbSetEncodings(List<int> encodings) {
  final b = ByteData(4 + 4 * encodings.length);
  b.setUint8(0, RfbClientMessage.setEncodings);
  b.setUint16(2, encodings.length);
  for (var i = 0; i < encodings.length; i++) {
    b.setInt32(4 + 4 * i, encodings[i]);
  }
  return b.buffer.asUint8List();
}

Uint8List rfbUpdateRequest({
  required bool incremental,
  required int x,
  required int y,
  required int width,
  required int height,
}) {
  final b = ByteData(10);
  b.setUint8(0, RfbClientMessage.framebufferUpdateRequest);
  b.setUint8(1, incremental ? 1 : 0);
  b.setUint16(2, x);
  b.setUint16(4, y);
  b.setUint16(6, width);
  b.setUint16(8, height);
  return b.buffer.asUint8List();
}

Uint8List rfbKeyEvent(int keysym, {required bool down}) {
  final b = ByteData(8);
  b.setUint8(0, RfbClientMessage.keyEvent);
  b.setUint8(1, down ? 1 : 0);
  b.setUint32(4, keysym);
  return b.buffer.asUint8List();
}

Uint8List rfbPointerEvent(int buttonMask, int x, int y) {
  final b = ByteData(6);
  b.setUint8(0, RfbClientMessage.pointerEvent);
  b.setUint8(1, buttonMask);
  b.setUint16(2, x);
  b.setUint16(4, y);
  return b.buffer.asUint8List();
}

/// ClientCutText carrying [latin1Text], which must already be Latin-1 (see
/// [rfbLatin1Encode]).
Uint8List rfbClientCutText(Uint8List latin1Text) {
  final out = Uint8List(8 + latin1Text.length);
  final b = ByteData.sublistView(out);
  b.setUint8(0, RfbClientMessage.clientCutText);
  b.setUint32(4, latin1Text.length);
  out.setRange(8, out.length, latin1Text);
  return out;
}

/// [text] as RFB cut text: Latin-1, the only character set the core
/// protocol has, with line ends as a bare newline, as the specification
/// asks. Characters outside Latin-1 become `?`; there is no way to carry
/// them without the extended-clipboard extension, which this client does
/// not speak. At most [maxBytes] bytes.
Uint8List rfbLatin1Encode(String text, {int maxBytes = rfbMaxText}) {
  final normalised = text.replaceAll('\r\n', '\n');
  final out = <int>[];
  for (final rune in normalised.runes) {
    if (out.length >= maxBytes) break;
    out.add(rune <= 0xff ? rune : 0x3f);
  }
  return Uint8List.fromList(out);
}

/// [bytes] as Latin-1 text: every byte is a character, so nothing can fail.
String rfbLatin1Decode(Uint8List bytes) => latin1.decode(bytes);

// ---------------------------------------------------------------- reading

/// Pulls bytes off a stream as the protocol asks for them.
///
/// Memory is bounded by what has arrived, never by what was asked for: a
/// read of 100 MiB holds nothing extra until 100 MiB turn up. While nobody
/// is reading (the person is typing a password, say) the subscription is
/// paused once [pauseAbove] bytes are waiting, so a server cannot fill
/// this side's memory by talking out of turn.
class RfbByteReader {
  RfbByteReader(Stream<Uint8List> input, {this.pauseAbove = 4 << 20}) {
    _subscription = input.listen(
      _onData,
      onError: (Object e) {
        _error = e;
        _wake();
      },
      onDone: () {
        _done = true;
        _wake();
      },
    );
  }

  final int pauseAbove;
  late final StreamSubscription<Uint8List> _subscription;
  final _chunks = ListQueue<Uint8List>();
  var _offset = 0;
  var _buffered = 0;
  var _consumed = 0;
  var _done = false;
  var _cancelled = false;
  Object? _error;
  Completer<void>? _waiter;

  /// Bytes handed out so far, for a bandwidth readout.
  int get consumed => _consumed;

  /// Bytes received and not yet read.
  int get buffered => _buffered;

  void _onData(Uint8List chunk) {
    if (chunk.isEmpty || _cancelled) return;
    _chunks.add(chunk);
    _buffered += chunk.length;
    if (_waiter == null && _buffered > pauseAbove && !_subscription.isPaused) {
      _subscription.pause();
    }
    _wake();
  }

  void _wake() {
    final w = _waiter;
    _waiter = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  Future<void> _more() {
    final error = _error;
    if (error != null) throw error;
    if (_done || _cancelled) throw const RfbEndOfStream();
    final w = _waiter = Completer<void>();
    if (_subscription.isPaused) _subscription.resume();
    return w.future;
  }

  /// Exactly [n] bytes: a view into a received chunk when they sit in one,
  /// else a copy. With [copy], always a fresh list this caller owns.
  Future<Uint8List> bytes(int n, {bool copy = false}) async {
    if (n < 0) throw RfbProtocolException('negative length $n');
    while (_buffered < n) {
      await _more();
    }
    return _take(n, copy: copy);
  }

  Future<int> u8() async {
    while (_buffered < 1) {
      await _more();
    }
    final c = _chunks.first;
    final v = c[_offset];
    _skipBuffered(1);
    return v;
  }

  Future<int> u16() async {
    final b = await bytes(2);
    return b[0] << 8 | b[1];
  }

  Future<int> u32() async {
    final b = await bytes(4);
    return b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3];
  }

  Future<int> s32() async {
    final v = await u32();
    return v >= 0x80000000 ? v - 0x100000000 : v;
  }

  /// Reads and drops [n] bytes, never holding more than one chunk of them.
  Future<void> skip(int n) async {
    while (n > 0) {
      if (_buffered == 0) await _more();
      final take = n < _buffered ? n : _buffered;
      _skipBuffered(take);
      n -= take;
    }
  }

  /// Stops reading. A read waiting now, or made later, ends with
  /// [RfbEndOfStream].
  Future<void> cancel() {
    _cancelled = true;
    _chunks.clear();
    _buffered = 0;
    _wake();
    return _subscription.cancel();
  }

  Uint8List _take(int n, {required bool copy}) {
    if (n == 0) return Uint8List(0);
    final first = _chunks.first;
    if (first.length - _offset >= n) {
      final view = Uint8List.sublistView(first, _offset, _offset + n);
      _skipBuffered(n);
      return copy ? Uint8List.fromList(view) : view;
    }
    final out = Uint8List(n);
    var filled = 0;
    while (filled < n) {
      final c = _chunks.first;
      final avail = c.length - _offset;
      final take = avail < n - filled ? avail : n - filled;
      out.setRange(filled, filled + take, c, _offset);
      filled += take;
      _skipBuffered(take);
    }
    return out;
  }

  void _skipBuffered(int n) {
    _buffered -= n;
    _consumed += n;
    while (n > 0) {
      final first = _chunks.first;
      final left = first.length - _offset;
      if (n < left) {
        _offset += n;
        return;
      }
      n -= left;
      _chunks.removeFirst();
      _offset = 0;
    }
  }
}
