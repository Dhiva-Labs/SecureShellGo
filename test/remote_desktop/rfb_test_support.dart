import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:secure_shell_go/services/remote_desktop/csrd_client.dart';
import 'package:secure_shell_go/services/remote_desktop/rfb_protocol.dart';

// ------------------------------------------------------------ the bytes

List<int> be16(int v) => [(v >> 8) & 0xff, v & 0xff];
List<int> be32(int v) => [
  (v >> 24) & 0xff,
  (v >> 16) & 0xff,
  (v >> 8) & 0xff,
  v & 0xff,
];

/// A rect header: x, y, w, h, encoding.
List<int> rectHeader(int x, int y, int w, int h, int encoding) => [
  ...be16(x),
  ...be16(y),
  ...be16(w),
  ...be16(h),
  ...be32(encoding & 0xffffffff),
];

/// A FramebufferUpdate header for [count] rects.
List<int> updateHeader(int count) => [0, 0, ...be16(count)];

/// The ServerInit for a [w] × [h] desktop called [name], with a big-endian
/// 16-bit server pixel format the client is expected to replace.
List<int> serverInit(int w, int h, String name) {
  final n = utf8.encode(name);
  return [
    ...be16(w),
    ...be16(h),
    16,
    16,
    1,
    1,
    ...be16(31),
    ...be16(63),
    ...be16(31),
    11,
    5,
    0,
    0,
    0,
    0,
    ...be32(n.length),
    ...n,
  ];
}

/// One client → server message, parsed.
sealed class ClientMsg {
  const ClientMsg();
}

class SetPixelFormatMsg extends ClientMsg {
  const SetPixelFormatMsg(this.bytes);
  final Uint8List bytes;
}

class SetEncodingsMsg extends ClientMsg {
  const SetEncodingsMsg(this.encodings);
  final List<int> encodings;
}

class UpdateRequestMsg extends ClientMsg {
  const UpdateRequestMsg(this.incremental, this.x, this.y, this.w, this.h);
  final bool incremental;
  final int x, y, w, h;
  @override
  String toString() => 'UpdateRequest(inc: $incremental, ${w}x$h+$x+$y)';
}

class KeyMsg extends ClientMsg {
  const KeyMsg(this.keysym, {required this.down});
  final int keysym;
  final bool down;
  @override
  bool operator ==(Object other) =>
      other is KeyMsg && other.keysym == keysym && other.down == down;
  @override
  int get hashCode => Object.hash(keysym, down);
  @override
  String toString() =>
      'Key(0x${keysym.toRadixString(16)}, ${down ? 'down' : 'up'})';
}

class PointerMsg extends ClientMsg {
  const PointerMsg(this.mask, this.x, this.y);
  final int mask, x, y;
  @override
  bool operator ==(Object other) =>
      other is PointerMsg && other.mask == mask && other.x == x && other.y == y;
  @override
  int get hashCode => Object.hash(mask, x, y);
  @override
  String toString() => 'Pointer($mask, $x, $y)';
}

class CutTextMsg extends ClientMsg {
  const CutTextMsg(this.bytes);
  final Uint8List bytes;
}

/// A VNC server at the far end of an in-memory pipe, driven by the test.
///
/// The handshake is scripted byte by byte with [read] and [send]; once it
/// is done, [parseMessages] turns everything the client sends into
/// [ClientMsg]s in [received].
///
/// With [chunker], every [send] arrives at the client cut into random
/// pieces, down to single bytes, which is what the reader has to cope
/// with on a real channel.
class FakeRfbServer {
  FakeRfbServer({this.chunker}) {
    reader = RfbByteReader(
      _fromClient.stream.map(Uint8List.fromList),
      pauseAbove: 1 << 30,
    );
    _fromClient.done.then((_) {}, onError: (_) {});
  }

  final Random? chunker;
  final _toClient = StreamController<Uint8List>();
  final _fromClient = StreamController<List<int>>();
  late final RfbByteReader reader;
  final _clientClosed = Completer<void>();

  final received = <ClientMsg>[];
  final _waiters = <Completer<void>>[];
  var _cursor = 0;
  var _parsing = false;

  Stream<Uint8List> get clientInput => _toClient.stream;
  StreamSink<List<int>> get clientOutput => _ClosingSink(_fromClient, () {
    if (!_clientClosed.isCompleted) _clientClosed.complete();
    _wake();
  });

  /// Completes when the client closes its output.
  Future<void> get clientClosed => _clientClosed.future;

  void send(List<int> bytes) {
    if (_toClient.isClosed) return;
    final data = Uint8List.fromList(bytes);
    final rng = chunker;
    if (rng == null) {
      _toClient.add(data);
      return;
    }
    var at = 0;
    while (at < data.length) {
      final n = min(
        data.length - at,
        1 + rng.nextInt(rng.nextBool() ? 4 : 600),
      );
      _toClient.add(Uint8List.sublistView(data, at, at + n));
      at += n;
    }
  }

  Future<void> hangUp() async {
    if (!_toClient.isClosed) await _toClient.close();
  }

  Future<Uint8List> read(int n) => reader.bytes(n, copy: true);

  /// The client's 12-byte version reply, after sending [version].
  Future<String> exchangeVersion([String version = 'RFB 003.008\n']) async {
    send(ascii.encode(version));
    return ascii.decode(await read(12));
  }

  /// A 3.8 handshake with no security, up to and including ServerInit.
  Future<void> handshakeNone({
    int width = 64,
    int height = 48,
    String name = 'test desktop',
  }) async {
    await exchangeVersion();
    send([1, RfbSecurity.none]);
    expectByte(await read(1), RfbSecurity.none);
    send(be32(0));
    expectByte(await read(1), 1); // shared
    send(serverInit(width, height, name));
    parseMessages();
  }

  static void expectByte(Uint8List got, int want) {
    if (got.length != 1 || got[0] != want) {
      throw StateError('expected byte $want, got $got');
    }
  }

  /// From here on, reads the client's messages into [received].
  void parseMessages() {
    if (_parsing) return;
    _parsing = true;
    unawaited(_parse());
  }

  Future<void> _parse() async {
    try {
      while (true) {
        final type = await reader.u8();
        final ClientMsg m;
        switch (type) {
          case 0:
            m = SetPixelFormatMsg(await read(19));
          case 2:
            await read(1);
            final n = await reader.u16();
            final list = <int>[];
            for (var i = 0; i < n; i++) {
              list.add(await reader.s32());
            }
            m = SetEncodingsMsg(list);
          case 3:
            final inc = await reader.u8();
            m = UpdateRequestMsg(
              inc != 0,
              await reader.u16(),
              await reader.u16(),
              await reader.u16(),
              await reader.u16(),
            );
          case 4:
            final down = await reader.u8();
            await read(2);
            m = KeyMsg(await reader.u32(), down: down != 0);
          case 5:
            m = PointerMsg(
              await reader.u8(),
              await reader.u16(),
              await reader.u16(),
            );
          case 6:
            await read(3);
            m = CutTextMsg(await read(await reader.u32()));
          default:
            throw StateError('unknown client message $type');
        }
        received.add(m);
        _wake();
      }
    } on RfbEndOfStream {
      _wake();
    }
  }

  void _wake() {
    for (final w in _waiters) {
      if (!w.isCompleted) w.complete();
    }
    _waiters.clear();
  }

  /// The next message of type [T] the client sends, skipping (but keeping)
  /// others.
  Future<T> next<T extends ClientMsg>({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      while (_cursor < received.length) {
        final m = received[_cursor++];
        if (m is T) return m;
      }
      if (_clientClosed.isCompleted) {
        throw StateError('client closed before sending a $T');
      }
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) throw TimeoutException('no $T', timeout);
      final w = Completer<void>();
      _waiters.add(w);
      await w.future.timeout(left, onTimeout: () {});
    }
  }

  /// Messages of type [T] received so far.
  List<T> all<T extends ClientMsg>() => received.whereType<T>().toList();

  /// Lets the client's queued writes, and the parser, catch up.
  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }
}

/// Tells the server when the client closes its output.
class _ClosingSink implements StreamSink<List<int>> {
  _ClosingSink(this._inner, this._onClose);
  final StreamController<List<int>> _inner;
  final void Function() _onClose;

  @override
  void add(List<int> data) => _inner.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);
  @override
  Future<void> addStream(Stream<List<int>> stream) => _inner.addStream(stream);
  @override
  Future<void> close() {
    _onClose();
    return _inner.close();
  }

  @override
  Future<void> get done => _inner.done;
}

// ------------------------------------------------------------- pictures

/// A BGRA picture with alpha 0xFF, for building rects and checking frames.
class Picture {
  Picture(this.width, this.height) : bgra = Uint8List(width * height * 4) {
    for (var i = 3; i < bgra.length; i += 4) {
      bgra[i] = 0xff;
    }
  }

  final int width;
  final int height;
  final Uint8List bgra;

  /// 0xRRGGBB.
  int pixel(int x, int y) {
    final i = (y * width + x) * 4;
    return bgra[i + 2] << 16 | bgra[i + 1] << 8 | bgra[i];
  }

  void set(int x, int y, int rgb) {
    final i = (y * width + x) * 4;
    bgra[i] = rgb & 0xff;
    bgra[i + 1] = (rgb >> 8) & 0xff;
    bgra[i + 2] = (rgb >> 16) & 0xff;
    bgra[i + 3] = 0xff;
  }

  void fillRect(int x, int y, int w, int h, int rgb) {
    for (var yy = y; yy < y + h; yy++) {
      for (var xx = x; xx < x + w; xx++) {
        set(xx, yy, rgb);
      }
    }
  }

  /// RFB CopyRect semantics: read the source as it is now, then write.
  void copyRect(int sx, int sy, int w, int h, int dx, int dy) {
    final src = sub(sx, sy, w, h);
    blit(dx, dy, src);
  }

  Picture sub(int x, int y, int w, int h) {
    final p = Picture(w, h);
    for (var row = 0; row < h; row++) {
      p.bgra.setRange(
        row * w * 4,
        (row + 1) * w * 4,
        bgra,
        ((y + row) * width + x) * 4,
      );
    }
    return p;
  }

  void blit(int x, int y, Picture p) {
    for (var row = 0; row < p.height; row++) {
      bgra.setRange(
        ((y + row) * width + x) * 4,
        ((y + row) * width + x + p.width) * 4,
        p.bgra,
        row * p.width * 4,
      );
    }
  }

  /// BGRX bytes as a Raw rect sends them, with junk in the X byte.
  Uint8List rawWire() {
    final out = Uint8List.fromList(bgra);
    for (var i = 3; i < out.length; i += 4) {
      out[i] = (i * 31) & 0xff;
    }
    return out;
  }
}

/// A deterministic busy picture: gradients, stripes and a few flat areas.
Picture busyPicture(int w, int h, {int seed = 1}) {
  final p = Picture(w, h);
  var s = seed | 1;
  int next() {
    s ^= (s << 13) & 0xffffffff;
    s ^= s >> 17;
    s ^= (s << 5) & 0xffffffff;
    return s;
  }

  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final band = (x ~/ 23 + y ~/ 17) % 5;
      final rgb = switch (band) {
        0 => 0x204060,
        1 => ((x * 3) & 0xff) << 16 | ((y * 5) & 0xff) << 8 | 0x80,
        2 => next() & 0xffffff,
        3 => (x + y).isEven ? 0xffffff : 0x000000,
        _ => 0x10a0c0,
      };
      p.set(x, y, rgb);
    }
  }
  return p;
}

// ------------------------------------------------------------------ ZRLE

/// How to encode one ZRLE tile.
enum Sub { raw, solid, packed, plainRle, paletteRle }

/// The tile-level ZRLE encoder this test suite needs: every subencoding,
/// by choice, over one long-lived zlib stream, as a server keeps one.
class ZrleEncoder {
  final RawZLibFilter _deflate = RawZLibFilter.deflateFilter(level: 6);

  /// The rect's compressed data (without its length prefix).
  Uint8List encodeRect(
    Picture p,
    int x,
    int y,
    int w,
    int h,
    Sub Function(int tileIndex, Picture tile) choose,
  ) => compress(plainRect(p, x, y, w, h, choose));

  /// The rect's tiles before compression.
  static List<int> plainRect(
    Picture p,
    int x,
    int y,
    int w,
    int h,
    Sub Function(int tileIndex, Picture tile) choose,
  ) {
    final plain = <int>[];
    var index = 0;
    for (var ty = 0; ty < h; ty += 64) {
      final th = min(64, h - ty);
      for (var tx = 0; tx < w; tx += 64) {
        final tw = min(64, w - tx);
        final tile = p.sub(x + tx, y + ty, tw, th);
        plain.addAll(encodeTile(tile, choose(index++, tile)));
      }
    }
    return plain;
  }

  /// Sync-flushed, so the client can decode it without the rest of the
  /// stream, as a real server flushes every rect.
  Uint8List compress(List<int> plain) {
    _deflate.process(plain, 0, plain.length);
    final out = BytesBuilder();
    for (List<int>? piece; (piece = _deflate.processed(flush: true)) != null;) {
      out.add(piece!);
    }
    return out.takeBytes();
  }

  /// A whole rect as it goes on the wire: header, length, data.
  List<int> wireRect(
    Picture p,
    int x,
    int y,
    int w,
    int h, {
    Sub Function(int tileIndex, Picture tile)? choose,
  }) {
    final data = encodeRect(p, x, y, w, h, choose ?? bestSub);
    return [...rectHeader(x, y, w, h, 16), ...be32(data.length), ...data];
  }
}

List<int> cpixel(int rgb) => [
  rgb & 0xff,
  (rgb >> 8) & 0xff,
  (rgb >> 16) & 0xff,
];

List<int> colours(Picture t) {
  final seen = <int>{};
  final order = <int>[];
  for (var y = 0; y < t.height; y++) {
    for (var x = 0; x < t.width; x++) {
      if (seen.add(t.pixel(x, y))) order.add(t.pixel(x, y));
    }
  }
  return order;
}

/// Every subencoding the tile can take, in turn by tile index.
Sub mixedSub(int index, Picture t) {
  final n = colours(t).length;
  if (n == 1) return Sub.solid;
  final options = [
    Sub.raw,
    Sub.plainRle,
    if (n <= 127) Sub.paletteRle,
    if (n <= 16) Sub.packed,
  ];
  return options[index % options.length];
}

/// What a sensible encoder would pick.
Sub bestSub(int index, Picture t) {
  final n = colours(t).length;
  if (n == 1) return Sub.solid;
  if (n <= 16) return Sub.packed;
  if (n <= 127) return Sub.paletteRle;
  return Sub.raw;
}

List<int> runLength(int run) {
  final out = <int>[];
  var left = run - 1;
  while (left >= 255) {
    out.add(255);
    left -= 255;
  }
  out.add(left);
  return out;
}

List<int> encodeTile(Picture t, Sub sub) {
  final px = [
    for (var y = 0; y < t.height; y++)
      for (var x = 0; x < t.width; x++) t.pixel(x, y),
  ];
  switch (sub) {
    case Sub.raw:
      return [0, for (final c in px) ...cpixel(c)];
    case Sub.solid:
      return [1, ...cpixel(px.first)];
    case Sub.packed:
      final palette = colours(t);
      if (palette.length < 2) palette.add(palette.first ^ 1);
      final size = palette.length;
      final bits = size == 2 ? 1 : (size <= 4 ? 2 : 4);
      final out = [size, for (final c in palette) ...cpixel(c)];
      for (var y = 0; y < t.height; y++) {
        var byte = 0, used = 0;
        for (var x = 0; x < t.width; x++) {
          byte = byte << bits | palette.indexOf(t.pixel(x, y));
          used += bits;
          if (used == 8) {
            out.add(byte);
            byte = 0;
            used = 0;
          }
        }
        if (used > 0) out.add(byte << (8 - used));
      }
      return out;
    case Sub.plainRle:
      final out = [128];
      for (var i = 0; i < px.length;) {
        var j = i + 1;
        while (j < px.length && px[j] == px[i]) {
          j++;
        }
        out
          ..addAll(cpixel(px[i]))
          ..addAll(runLength(j - i));
        i = j;
      }
      return out;
    case Sub.paletteRle:
      final palette = colours(t);
      if (palette.length < 2) palette.add(palette.first ^ 1);
      final out = [128 + palette.length, for (final c in palette) ...cpixel(c)];
      for (var i = 0; i < px.length;) {
        var j = i + 1;
        while (j < px.length && px[j] == px[i]) {
          j++;
        }
        final index = palette.indexOf(px[i]);
        if (j - i == 1) {
          out.add(index);
        } else {
          out
            ..add(index | 0x80)
            ..addAll(runLength(j - i));
        }
        i = j;
      }
      return out;
  }
}

/// The index of the first pixel at which two BGRA buffers differ in B, G
/// or R, or -1.
int firstDifference(Uint8List a, Uint8List b) {
  if (a.length != b.length) return -2;
  for (var i = 0; i < a.length; i += 4) {
    if (a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2]) {
      return i ~/ 4;
    }
  }
  return -1;
}

/// Everything a session emits, with a way to wait for the next of a kind.
class EventLog {
  EventLog(Stream<CsrdEvent> events) {
    events.listen(
      (e) {
        this.events.add(e);
        _wake();
      },
      onDone: () {
        _closed = true;
        _wake();
      },
    );
  }

  final events = <CsrdEvent>[];
  final _waiters = <Completer<void>>[];
  var _cursor = 0;
  var _closed = false;

  void _wake() {
    for (final w in _waiters) {
      if (!w.isCompleted) w.complete();
    }
    _waiters.clear();
  }

  /// The next event that is a [T], skipping (but keeping) others.
  Future<T> next<T extends CsrdEvent>({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      while (_cursor < events.length) {
        final e = events[_cursor++];
        if (e is T) return e;
      }
      if (_closed) throw StateError('events ended before a $T');
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) throw TimeoutException('no $T', timeout);
      final w = Completer<void>();
      _waiters.add(w);
      await w.future.timeout(left, onTimeout: () {});
    }
  }

  List<T> all<T extends CsrdEvent>() => events.whereType<T>().toList();
}
