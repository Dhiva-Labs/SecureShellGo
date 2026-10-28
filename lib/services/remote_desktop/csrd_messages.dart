/// CSRD, the wire protocol of CrossShell's remote-desktop agent: every
/// message, its byte layout, and the framing that cuts a byte stream into
/// messages.
///
/// This is a port of `crossshell-proto`'s `msg.rs` and `lib.rs`, and those
/// files are the specification: a message this library encodes is byte for
/// byte what the Rust crate encodes, and `test/remote_desktop/` checks that
/// against messages the Rust crate wrote. Framing is `u8 type | u32 length
/// (little-endian) | payload`, and every integer in a payload is
/// little-endian.
///
/// The agent on the other end of the channel is treated as untrusted input,
/// the way the Rust decoder treats it. Nothing here allocates more than the
/// bytes that actually arrived, every declared length is checked against
/// what is present, and a payload over the limit is refused from its header
/// alone, before any of it is buffered.
library;

import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

/// Sent at the start of [CsrdHello]: `CSRD`.
const List<int> csrdMagic = [0x43, 0x53, 0x52, 0x44];

/// Wire protocol version. The agent refuses any other.
const int csrdVersion = 1;

/// The agent's default loopback port, when it is run without one.
const int csrdDefaultHostPort = 47821;

/// Largest payload either end accepts once the handshake is done.
const int csrdMaxPayload = 64 << 20;

/// Largest payload the agent accepts before it has checked the token, so a
/// [CsrdHello] or [CsrdStart] this client sends must stay under it: the
/// agent drops an oversized one without so much as a [CsrdReject].
const int csrdMaxPreauthPayload = 1024;

/// Session token length, in bytes.
const int csrdTokenLength = 32;

/// Frames the agent may have in flight without a [CsrdFrameAck].
const int csrdMaxInflightFrames = 2;

/// Largest frame width or height either end accepts.
const int csrdMaxDimension = 16384;

/// Largest [CsrdClipboardText] either end accepts, in UTF-8 bytes.
const int csrdMaxClipboard = 1 << 20;

/// Largest cursor image side, in pixels.
const int csrdMaxCursorSide = 256;

/// `Hello.caps` / `Welcome.caps` bit: tiles may be [CsrdEncoding.deflate].
/// This client always asks for it, because Dart has zlib (native, in
/// `dart:io`) and no zstd.
const int csrdCapDeflate = 1 << 0;

/// Something on the wire was not CSRD: a truncated or overlong message, a
/// length over its limit, an unknown type.
class CsrdProtocolException implements Exception {
  const CsrdProtocolException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A frame's tiles could not be decoded: a rect outside the frame, corrupt
/// compressed data, a tile that inflates past its rect.
class CsrdCodecException implements Exception {
  const CsrdCodecException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Message type bytes, as in `msg.rs`'s `kind` module.
abstract final class CsrdKind {
  static const hello = 0x01;
  static const welcome = 0x02;
  static const reject = 0x03;
  static const start = 0x10;
  static const selectDisplay = 0x11;
  static const frame = 0x20;
  static const frameAck = 0x21;
  static const cursorShape = 0x22;
  static const cursorPos = 0x23;
  static const displaysChanged = 0x24;
  static const pointerMove = 0x30;
  static const pointerButton = 0x31;
  static const scroll = 0x32;
  static const key = 0x33;
  static const releaseAll = 0x34;
  static const clipboardText = 0x40;
  static const ping = 0x50;
  static const pong = 0x51;
  static const notice = 0x60;
}

/// Pointer buttons on the wire.
abstract final class CsrdButton {
  static const left = 1;
  static const middle = 2;
  static const right = 3;
  static const back = 4;
  static const forward = 5;
}

/// [CsrdNotice] levels.
abstract final class CsrdNoticeLevel {
  static const info = 0;
  static const warn = 1;
  static const error = 2;
}

/// How one rect of a frame is encoded. Pixel data is BGRX throughout: the
/// fourth byte is whatever the capture API left there, never alpha.
enum CsrdEncoding {
  raw(0),
  zstd(1),
  jpeg(2),
  fill(3),
  deflate(4);

  const CsrdEncoding(this.wire);
  final int wire;

  static CsrdEncoding? fromWire(int value) => switch (value) {
    0 => raw,
    1 => zstd,
    2 => jpeg,
    3 => fill,
    4 => deflate,
    _ => null,
  };
}

/// One display the agent can share.
class CsrdDisplayInfo {
  const CsrdDisplayInfo({
    required this.index,
    required this.name,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.primary,
  });

  /// What [CsrdStart] and [CsrdSelectDisplay] name it by. Not necessarily
  /// its position in the list.
  final int index;
  final String name;

  /// Position on the remote's virtual desktop; may be negative.
  final int x;
  final int y;
  final int width;
  final int height;
  final bool primary;

  @override
  bool operator ==(Object other) =>
      other is CsrdDisplayInfo &&
      other.index == index &&
      other.name == name &&
      other.x == x &&
      other.y == y &&
      other.width == width &&
      other.height == height &&
      other.primary == primary;

  @override
  int get hashCode => Object.hash(index, name, x, y, width, height, primary);

  @override
  String toString() =>
      'CsrdDisplayInfo($index, "$name", ${width}x$height+$x+$y'
      '${primary ? ', primary' : ''})';
}

/// One updated rectangle of a frame, still encoded.
class CsrdRect {
  const CsrdRect({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.encoding,
    required this.data,
  });

  final int x;
  final int y;
  final int width;
  final int height;
  final CsrdEncoding encoding;

  /// For a decoded message, a view into its payload: no copy is made per
  /// rect.
  final Uint8List data;

  /// x, y, w, h (u16 each), encoding (u8), data length (u32).
  static const headerLength = 2 * 4 + 1 + 4;

  @override
  bool operator ==(Object other) =>
      other is CsrdRect &&
      other.x == x &&
      other.y == y &&
      other.width == width &&
      other.height == height &&
      other.encoding == encoding &&
      _bytesEqual(other.data, data);

  @override
  int get hashCode => Object.hash(x, y, width, height, encoding, data.length);

  @override
  String toString() =>
      'CsrdRect(${width}x$height+$x+$y, ${encoding.name}, '
      '${data.length} bytes)';
}

/// One CSRD message. [encode] gives the complete wire form, header
/// included; [CsrdMessage.decode] reads one payload back.
sealed class CsrdMessage {
  const CsrdMessage();

  /// The type byte, from [CsrdKind].
  int get kind;

  /// The fields, for equality and [toString].
  List<Object?> get _fields;

  void _write(_Out out);

  /// The whole message as it goes on the wire.
  Uint8List encode() {
    final out = _Out(kind, _sizeHint);
    _write(out);
    return out.finish();
  }

  int get _sizeHint => 64;

  /// Decodes the payload of one message of type [kind].
  ///
  /// Throws [CsrdProtocolException] for anything `msg.rs` would refuse,
  /// including trailing bytes. Byte fields of the result ([CsrdRect.data],
  /// [CsrdCursorShape.rgba]) are views into [payload], not copies.
  static CsrdMessage decode(int kind, Uint8List payload) {
    final c = _In(payload);
    final CsrdMessage m = switch (kind) {
      CsrdKind.hello => _decodeHello(c),
      CsrdKind.welcome => CsrdWelcome(
        version: c.u16(),
        caps: c.u32(),
        displays: c.displays(),
      ),
      CsrdKind.reject => CsrdReject(c.str()),
      CsrdKind.start => CsrdStart(
        display: c.u8(),
        quality: c.u8(),
        maxFps: c.u8(),
        viewOnly: c.u8() & 1 == 1,
      ),
      CsrdKind.selectDisplay => CsrdSelectDisplay(
        display: c.u8(),
        quality: c.u8(),
        maxFps: c.u8(),
      ),
      CsrdKind.frame => _decodeFrame(c),
      CsrdKind.frameAck => CsrdFrameAck(c.u32()),
      CsrdKind.cursorShape => _decodeCursorShape(c),
      CsrdKind.cursorPos => CsrdCursorPos(c.i32(), c.i32()),
      CsrdKind.displaysChanged => CsrdDisplaysChanged(c.displays()),
      CsrdKind.pointerMove => CsrdPointerMove(c.i32(), c.i32()),
      CsrdKind.pointerButton => CsrdPointerButton(c.u8(), down: c.u8() != 0),
      CsrdKind.scroll => CsrdScroll(c.i16(), c.i16()),
      CsrdKind.key => CsrdKey(c.u16(), down: c.u8() != 0),
      CsrdKind.releaseAll => const CsrdReleaseAll(),
      CsrdKind.clipboardText => _decodeClipboard(c, payload.length),
      CsrdKind.ping => CsrdPing(c.u64()),
      CsrdKind.pong => CsrdPong(c.u64()),
      CsrdKind.notice => CsrdNotice(c.u8(), c.str()),
      _ => throw CsrdProtocolException(
        'unknown message type ${_hexByte(kind)}',
      ),
    };
    if (c.remaining != 0) {
      throw CsrdProtocolException(
        '${c.remaining} trailing bytes in message ${_hexByte(kind)}',
      );
    }
    return m;
  }

  static CsrdHello _decodeHello(_In c) {
    final magic = c.take(4);
    if (!_bytesEqual(magic, csrdMagic)) {
      throw const CsrdProtocolException('bad magic');
    }
    final version = c.u16();
    // Copied: a token outlives the buffer it arrived in.
    final token = Uint8List.fromList(c.take(csrdTokenLength));
    return CsrdHello(
      version: version,
      token: token,
      viewerName: c.str(),
      caps: c.u32(),
    );
  }

  static CsrdFrame _decodeFrame(_In c) {
    final seq = c.u32();
    final width = c.u32();
    final height = c.u32();
    final n = c.u16();
    // Each rect needs at least its header: an absurd count is refused
    // before anything is allocated for it.
    if (n * CsrdRect.headerLength > c.remaining) {
      throw const CsrdProtocolException('rect count exceeds payload');
    }
    final rects = <CsrdRect>[];
    for (var i = 0; i < n; i++) {
      final x = c.u16();
      final y = c.u16();
      final w = c.u16();
      final h = c.u16();
      final wire = c.u8();
      final encoding = CsrdEncoding.fromWire(wire);
      if (encoding == null) {
        throw CsrdProtocolException('unknown rect encoding $wire');
      }
      final len = c.u32();
      rects.add(
        CsrdRect(
          x: x,
          y: y,
          width: w,
          height: h,
          encoding: encoding,
          data: c.take(len),
        ),
      );
    }
    return CsrdFrame(seq: seq, width: width, height: height, rects: rects);
  }

  static CsrdCursorShape _decodeCursorShape(_In c) {
    final width = c.u16();
    final height = c.u16();
    final hotX = c.u16();
    final hotY = c.u16();
    if (width > csrdMaxCursorSide || height > csrdMaxCursorSide) {
      throw const CsrdProtocolException('cursor larger than 256x256');
    }
    return CsrdCursorShape(
      width: width,
      height: height,
      hotX: hotX,
      hotY: hotY,
      rgba: c.take(width * height * 4),
    );
  }

  static CsrdClipboardText _decodeClipboard(_In c, int length) {
    if (length > csrdMaxClipboard) {
      throw const CsrdProtocolException('clipboard text too large');
    }
    try {
      return CsrdClipboardText(utf8.decode(c.take(length)));
    } on FormatException {
      throw const CsrdProtocolException('clipboard text is not utf-8');
    }
  }

  @override
  bool operator ==(Object other) {
    if (other is! CsrdMessage || other.runtimeType != runtimeType) {
      return false;
    }
    final a = _fields;
    final b = other._fields;
    for (var i = 0; i < a.length; i++) {
      if (!_fieldEqual(a[i], b[i])) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    runtimeType,
    Object.hashAll(_fields.map((f) => f is Uint8List ? f.length : f)),
  );

  @override
  String toString() {
    final fields = _fields
        .map((f) => f is Uint8List ? '${f.length} bytes' : '$f')
        .join(', ');
    return '$runtimeType($fields)';
  }
}

/// Viewer → agent, first: who we are and the token that lets us in.
class CsrdHello extends CsrdMessage {
  const CsrdHello({
    required this.version,
    required this.token,
    required this.viewerName,
    required this.caps,
  });

  final int version;

  /// Exactly [csrdTokenLength] bytes. Shorter is padded with zeros and
  /// longer is cut, since the wire field has a fixed width.
  final Uint8List token;

  /// Shown to the person at the remote ("being viewed from …"). The agent
  /// keeps 64 characters of it.
  final String viewerName;
  final int caps;

  @override
  int get kind => CsrdKind.hello;
  @override
  List<Object?> get _fields => [version, token, viewerName, caps];

  @override
  void _write(_Out o) {
    o.bytes(csrdMagic);
    o.u16(version);
    final t = Uint8List(csrdTokenLength)
      ..setRange(0, token.length.clamp(0, csrdTokenLength), token);
    o.bytes(t);
    o.str(viewerName);
    o.u32(caps);
  }
}

/// Agent → viewer: the token was right; these are the displays.
class CsrdWelcome extends CsrdMessage {
  const CsrdWelcome({
    required this.version,
    required this.caps,
    required this.displays,
  });

  final int version;

  /// The `Hello.caps` bits the agent accepted.
  final int caps;
  final List<CsrdDisplayInfo> displays;

  @override
  int get kind => CsrdKind.welcome;
  @override
  List<Object?> get _fields => [version, caps, displays];

  @override
  void _write(_Out o) {
    o.u16(version);
    o.u32(caps);
    o.displays(displays);
  }
}

/// Agent → viewer, instead of [CsrdWelcome] (or at any time later): no.
class CsrdReject extends CsrdMessage {
  const CsrdReject(this.reason);
  final String reason;

  @override
  int get kind => CsrdKind.reject;
  @override
  List<Object?> get _fields => [reason];

  @override
  void _write(_Out o) => o.str(reason);
}

/// Viewer → agent, after [CsrdWelcome]: start streaming this display.
class CsrdStart extends CsrdMessage {
  const CsrdStart({
    required this.display,
    required this.quality,
    required this.maxFps,
    required this.viewOnly,
  });

  final int display;

  /// 0 lossless, 1 balanced, 2 speed; the agent reads anything else as
  /// balanced.
  final int quality;

  /// The agent clamps it to 1–120.
  final int maxFps;

  /// Fixed for the session: the agent opens no input injector at all for a
  /// view-only viewer, so this cannot be switched off later without
  /// reconnecting.
  final bool viewOnly;

  @override
  int get kind => CsrdKind.start;
  @override
  List<Object?> get _fields => [display, quality, maxFps, viewOnly];

  @override
  void _write(_Out o) {
    o.u8(display);
    o.u8(quality);
    o.u8(maxFps);
    o.u8(viewOnly ? 1 : 0);
  }
}

/// Viewer → agent: switch display, quality or frame rate. The next frame is
/// a full refresh.
class CsrdSelectDisplay extends CsrdMessage {
  const CsrdSelectDisplay({
    required this.display,
    required this.quality,
    required this.maxFps,
  });

  final int display;
  final int quality;
  final int maxFps;

  @override
  int get kind => CsrdKind.selectDisplay;
  @override
  List<Object?> get _fields => [display, quality, maxFps];

  @override
  void _write(_Out o) {
    o.u8(display);
    o.u8(quality);
    o.u8(maxFps);
  }
}

/// Agent → viewer: the rects that changed since the previous frame.
class CsrdFrame extends CsrdMessage {
  const CsrdFrame({
    required this.seq,
    required this.width,
    required this.height,
    required this.rects,
  });

  /// Counts up by one per frame, from 1, wrapping at 2³².
  final int seq;
  final int width;
  final int height;
  final List<CsrdRect> rects;

  /// Compressed bytes this frame carried, for a bandwidth readout.
  int get dataBytes => rects.fold(0, (sum, r) => sum + r.data.length);

  @override
  int get kind => CsrdKind.frame;
  @override
  List<Object?> get _fields => [seq, width, height, rects];

  @override
  int get _sizeHint =>
      14 + rects.fold(0, (s, r) => s + CsrdRect.headerLength + r.data.length);

  @override
  void _write(_Out o) {
    o.u32(seq);
    o.u32(width);
    o.u32(height);
    final n = rects.length.clamp(0, 0xffff);
    o.u16(n);
    for (final r in rects.take(n)) {
      o.u16(r.x);
      o.u16(r.y);
      o.u16(r.width);
      o.u16(r.height);
      o.u8(r.encoding.wire);
      o.u32(r.data.length);
      o.bytes(r.data);
    }
  }
}

/// Viewer → agent: frames up to and including [seq] are on screen.
class CsrdFrameAck extends CsrdMessage {
  const CsrdFrameAck(this.seq);
  final int seq;

  @override
  int get kind => CsrdKind.frameAck;
  @override
  List<Object?> get _fields => [seq];

  @override
  void _write(_Out o) => o.u32(seq);
}

/// Agent → viewer: the remote pointer's image. Zero width or height means
/// the pointer is hidden.
class CsrdCursorShape extends CsrdMessage {
  const CsrdCursorShape({
    required this.width,
    required this.height,
    required this.hotX,
    required this.hotY,
    required this.rgba,
  });

  final int width;
  final int height;

  /// Not checked against the size by the protocol: clamp before use.
  final int hotX;
  final int hotY;

  /// `width * height * 4` bytes, straight (not premultiplied) RGBA.
  final Uint8List rgba;

  bool get hidden => width == 0 || height == 0;

  @override
  int get kind => CsrdKind.cursorShape;
  @override
  List<Object?> get _fields => [width, height, hotX, hotY, rgba];

  @override
  int get _sizeHint => 8 + rgba.length;

  @override
  void _write(_Out o) {
    o.u16(width);
    o.u16(height);
    o.u16(hotX);
    o.u16(hotY);
    o.bytes(rgba);
  }
}

/// Agent → viewer: where the remote pointer is, in display pixels.
class CsrdCursorPos extends CsrdMessage {
  const CsrdCursorPos(this.x, this.y);
  final int x;
  final int y;

  @override
  int get kind => CsrdKind.cursorPos;
  @override
  List<Object?> get _fields => [x, y];

  @override
  void _write(_Out o) {
    o.i32(x);
    o.i32(y);
  }
}

/// Agent → viewer: the set of displays changed.
class CsrdDisplaysChanged extends CsrdMessage {
  const CsrdDisplaysChanged(this.displays);
  final List<CsrdDisplayInfo> displays;

  @override
  int get kind => CsrdKind.displaysChanged;
  @override
  List<Object?> get _fields => [displays];

  @override
  void _write(_Out o) => o.displays(displays);
}

/// Viewer → agent: move the pointer to display pixel ([x], [y]). The agent
/// clamps to the display.
class CsrdPointerMove extends CsrdMessage {
  const CsrdPointerMove(this.x, this.y);
  final int x;
  final int y;

  @override
  int get kind => CsrdKind.pointerMove;
  @override
  List<Object?> get _fields => [x, y];

  @override
  void _write(_Out o) {
    o.i32(x);
    o.i32(y);
  }
}

/// Viewer → agent: a [CsrdButton] went down or up.
class CsrdPointerButton extends CsrdMessage {
  const CsrdPointerButton(this.button, {required this.down});
  final int button;
  final bool down;

  @override
  int get kind => CsrdKind.pointerButton;
  @override
  List<Object?> get _fields => [button, down];

  @override
  void _write(_Out o) {
    o.u8(button);
    o.u8(down ? 1 : 0);
  }
}

/// Viewer → agent: wheel movement in 1/120-notch units. Positive [dy]
/// scrolls up, positive [dx] scrolls right.
class CsrdScroll extends CsrdMessage {
  const CsrdScroll(this.dx, this.dy);
  final int dx;
  final int dy;

  @override
  int get kind => CsrdKind.scroll;
  @override
  List<Object?> get _fields => [dx, dy];

  @override
  void _write(_Out o) {
    o.i16(dx);
    o.i16(dy);
  }
}

/// Viewer → agent: a key, by Linux evdev code (see `csrd_keymap.dart`).
class CsrdKey extends CsrdMessage {
  const CsrdKey(this.code, {required this.down});
  final int code;
  final bool down;

  @override
  int get kind => CsrdKind.key;
  @override
  List<Object?> get _fields => [code, down];

  @override
  void _write(_Out o) {
    o.u16(code);
    o.u8(down ? 1 : 0);
  }
}

/// Viewer → agent: let go of every key and button this viewer holds.
class CsrdReleaseAll extends CsrdMessage {
  const CsrdReleaseAll();

  @override
  int get kind => CsrdKind.releaseAll;
  @override
  List<Object?> get _fields => const [];

  @override
  void _write(_Out o) {}
}

/// Either way: the clipboard's text. The payload is the UTF-8, unprefixed.
class CsrdClipboardText extends CsrdMessage {
  const CsrdClipboardText(this.text);
  final String text;

  @override
  int get kind => CsrdKind.clipboardText;
  @override
  List<Object?> get _fields => [text];

  @override
  int get _sizeHint => text.length * 3;

  @override
  void _write(_Out o) => o.bytes(utf8.encode(text));
}

/// Either way: answer with a [CsrdPong] carrying the same value.
///
/// The wire value is a u64. Dart's int is 64-bit, so it holds every bit
/// pattern, but values from 2⁶³ up read as negative numbers. This client
/// only ever sends nanosecond timestamps, nowhere near that.
class CsrdPing extends CsrdMessage {
  const CsrdPing(this.value);
  final int value;

  @override
  int get kind => CsrdKind.ping;
  @override
  List<Object?> get _fields => [value];

  @override
  void _write(_Out o) => o.u64(value);
}

/// The answer to a [CsrdPing]; see there for the value's range.
class CsrdPong extends CsrdMessage {
  const CsrdPong(this.value);
  final int value;

  @override
  int get kind => CsrdKind.pong;
  @override
  List<Object?> get _fields => [value];

  @override
  void _write(_Out o) => o.u64(value);
}

/// Agent → viewer: something to tell the person. An empty [text] withdraws
/// the previous notice (capture came back, say).
class CsrdNotice extends CsrdMessage {
  const CsrdNotice(this.level, this.text);

  /// A [CsrdNoticeLevel].
  final int level;
  final String text;

  @override
  int get kind => CsrdKind.notice;
  @override
  List<Object?> get _fields => [level, text];

  @override
  void _write(_Out o) {
    o.u8(level);
    o.str(text);
  }
}

/// Cuts a byte stream into messages, whatever the chunk boundaries: the
/// port of `MessageReader`.
///
/// Memory is bounded by what has actually arrived, never by what a header
/// claims: a header announcing 64 MiB costs nothing until 64 MiB turn up,
/// and one announcing more than [maxPayload] is refused as soon as its five
/// bytes are in.
class CsrdMessageReader {
  CsrdMessageReader({this._maxPayload = csrdMaxPayload});

  final _chunks = ListQueue<Uint8List>();

  /// How far into the first chunk the next unread byte is.
  var _offset = 0;
  var _buffered = 0;
  CsrdProtocolException? _broken;

  int _maxPayload;

  /// The payload limit, never above [csrdMaxPayload]. It can change between
  /// messages: the handshake reads under a small one.
  int get maxPayload =>
      _maxPayload < csrdMaxPayload ? _maxPayload : csrdMaxPayload;
  set maxPayload(int value) => _maxPayload = value;

  /// Bytes received and not yet handed out as messages.
  int get bufferedBytes => _buffered;

  /// Appends bytes as they came off the transport. A [Uint8List] is kept
  /// as it is, without a copy, so it must not be changed afterwards; socket
  /// and channel chunks never are.
  void add(List<int> bytes) {
    if (bytes.isEmpty) return;
    final chunk = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    _chunks.add(chunk);
    _buffered += chunk.length;
  }

  /// The next complete message, or null until more bytes arrive.
  ///
  /// Throws [CsrdProtocolException] for a message that does not decode, after
  /// consuming it, as `msg.rs` does. An oversized header is different: it is
  /// not consumed, since there is no telling where the next message starts,
  /// and every later call throws the same error.
  CsrdMessage? next() {
    final broken = _broken;
    if (broken != null) throw broken;
    if (_buffered < 5) return null;
    final kind = _peek(0);
    final len =
        _peek(1) | (_peek(2) << 8) | (_peek(3) << 16) | (_peek(4) << 24);
    if (len > maxPayload) {
      throw _broken = CsrdProtocolException(
        'payload of $len bytes for type ${_hexByte(kind)} exceeds limit',
      );
    }
    if (_buffered < 5 + len) return null;
    _skip(5);
    return CsrdMessage.decode(kind, _consume(len));
  }

  int _peek(int i) {
    var at = _offset + i;
    for (final c in _chunks) {
      if (at < c.length) return c[at];
      at -= c.length;
    }
    throw StateError('peek past the buffered bytes');
  }

  void _skip(int n) {
    _buffered -= n;
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

  /// [n] bytes as one list: a view when they sit in one chunk, which is the
  /// common case for small messages, else one copy.
  Uint8List _consume(int n) {
    if (n == 0) return Uint8List(0);
    final first = _chunks.first;
    if (first.length - _offset >= n) {
      final view = Uint8List.sublistView(first, _offset, _offset + n);
      _skip(n);
      return view;
    }
    final out = Uint8List(n);
    var filled = 0;
    while (filled < n) {
      final c = _chunks.first;
      final take = (c.length - _offset).clamp(0, n - filled);
      out.setRange(filled, filled + take, c, _offset);
      filled += take;
      _skip(take);
    }
    return out;
  }
}

/// Lowercase hex, which is how tokens travel in `host.json` and on stdin.
String csrdToHex(List<int> bytes) {
  const digits = '0123456789abcdef';
  final s = StringBuffer();
  for (final b in bytes) {
    s
      ..write(digits[(b >> 4) & 0xf])
      ..write(digits[b & 0xf]);
  }
  return s.toString();
}

/// Parses [csrdToHex]'s output, either case, ignoring surrounding
/// whitespace. Null for anything that is not whole bytes of hex.
Uint8List? csrdFromHex(String text) {
  final s = text.trim();
  if (s.length.isOdd) return null;
  int? nibble(int c) {
    if (c >= 0x30 && c <= 0x39) return c - 0x30;
    if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
    if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;
    return null;
  }

  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final hi = nibble(s.codeUnitAt(2 * i));
    final lo = nibble(s.codeUnitAt(2 * i + 1));
    if (hi == null || lo == null) return null;
    out[i] = hi << 4 | lo;
  }
  return out;
}

// ------------------------------------------------------------- the bytes

String _hexByte(int v) => '0x${v.toRadixString(16).padLeft(2, '0')}';

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _fieldEqual(Object? a, Object? b) {
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
  return a == b;
}

/// The encoder. Integers are written as their low bits, the way a Rust
/// field of that width would hold them; range checks belong to the caller
/// that made the number up.
class _Out {
  _Out(int kind, int sizeHint) : _b = Uint8List(5 + sizeHint) {
    _b[0] = kind;
    _d = ByteData.sublistView(_b);
  }

  Uint8List _b;
  late ByteData _d;
  var _n = 5;

  void _room(int more) {
    if (_n + more <= _b.length) return;
    var size = _b.length * 2;
    while (size < _n + more) {
      size *= 2;
    }
    _b = Uint8List(size)..setRange(0, _n, _b);
    _d = ByteData.sublistView(_b);
  }

  void u8(int v) {
    _room(1);
    _b[_n++] = v & 0xff;
  }

  void u16(int v) {
    _room(2);
    _d.setUint16(_n, v & 0xffff, Endian.little);
    _n += 2;
  }

  void i16(int v) => u16(v);

  void u32(int v) {
    _room(4);
    _d.setUint32(_n, v & 0xffffffff, Endian.little);
    _n += 4;
  }

  void i32(int v) => u32(v);

  void u64(int v) {
    _room(8);
    _d.setInt64(_n, v, Endian.little);
    _n += 8;
  }

  void bytes(List<int> b) {
    _room(b.length);
    _b.setRange(_n, _n + b.length, b);
    _n += b.length;
  }

  /// u16 length prefix; text past 65535 UTF-8 bytes is cut on a character
  /// boundary, as `msg.rs` does.
  void str(String s) {
    final b = utf8.encode(s);
    var end = b.length < 0xffff ? b.length : 0xffff;
    while (end < b.length && (b[end] & 0xc0) == 0x80) {
      end--;
    }
    u16(end);
    bytes(Uint8List.sublistView(b, 0, end));
  }

  void displays(List<CsrdDisplayInfo> displays) {
    final n = displays.length < 255 ? displays.length : 255;
    u8(n);
    for (final d in displays.take(n)) {
      u8(d.index);
      str(d.name);
      i32(d.x);
      i32(d.y);
      u32(d.width);
      u32(d.height);
      u8(d.primary ? 1 : 0);
    }
  }

  Uint8List finish() {
    _d.setUint32(1, _n - 5, Endian.little);
    return Uint8List.sublistView(_b, 0, _n);
  }
}

/// The decoder: every read bounds-checked against what is present.
class _In {
  _In(this._b) : _d = ByteData.sublistView(_b);

  final Uint8List _b;
  final ByteData _d;
  var _p = 0;

  int get remaining => _b.length - _p;

  void _need(int n) {
    if (n > remaining) {
      throw const CsrdProtocolException('truncated message');
    }
  }

  Uint8List take(int n) {
    _need(n);
    final view = Uint8List.sublistView(_b, _p, _p + n);
    _p += n;
    return view;
  }

  int u8() {
    _need(1);
    return _b[_p++];
  }

  int u16() {
    _need(2);
    final v = _d.getUint16(_p, Endian.little);
    _p += 2;
    return v;
  }

  int i16() {
    _need(2);
    final v = _d.getInt16(_p, Endian.little);
    _p += 2;
    return v;
  }

  int u32() {
    _need(4);
    final v = _d.getUint32(_p, Endian.little);
    _p += 4;
    return v;
  }

  int i32() {
    _need(4);
    final v = _d.getInt32(_p, Endian.little);
    _p += 4;
    return v;
  }

  /// The u64's bit pattern; see [CsrdPing].
  int u64() {
    _need(8);
    final v = _d.getInt64(_p, Endian.little);
    _p += 8;
    return v;
  }

  String str() {
    final bytes = take(u16());
    try {
      return utf8.decode(bytes);
    } on FormatException {
      throw const CsrdProtocolException('string is not utf-8');
    }
  }

  List<CsrdDisplayInfo> displays() {
    final n = u8();
    return [
      for (var i = 0; i < n; i++)
        CsrdDisplayInfo(
          index: u8(),
          name: str(),
          x: i32(),
          y: i32(),
          width: u32(),
          height: u32(),
          primary: u8() != 0,
        ),
    ];
  }
}
