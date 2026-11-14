import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'csrd_client.dart';
import 'csrd_messages.dart';
import 'csrd_tiles.dart';
import 'remote_screen_session.dart';
import 'rfb_auth.dart';
import 'rfb_keysyms.dart';
import 'rfb_protocol.dart';
import 'rfb_zrle.dart';

export 'rfb_auth.dart' show RfbAuthKind, RfbCredentialsCallback;
export 'rfb_keysyms.dart' show RfbCommandKey;

/// A VNC viewer behind [RemoteScreenSession]: the second way the remote
/// desktop screen can show a remote, for Macs, whose only way in is their
/// built-in Screen Sharing, and for any host that already runs a VNC
/// server.
///
/// Like [CsrdClient] it is handed the two halves of a byte stream, in the
/// app a dartssh2 `forwardLocal` channel to `127.0.0.1:5900` on the remote,
/// and owns that transport from then on.
///
/// ```text
/// connect():  ◄─ ProtocolVersion ─►            3.3, 3.7 or 3.8
///             ◄─ security types ─► choice      None, VNC (DES), Apple (30)
///             credentials callback, then the answer ─►
///             ◄─ SecurityResult
///             ClientInit (shared) ─►  ◄─ ServerInit (size, name)
///             SetPixelFormat, SetEncodings, FramebufferUpdateRequest ─►
/// then:       ◄─ FramebufferUpdate → frames … ackFrame → next request ─►
///             ◄─ ServerCutText, Bell, SetColourMapEntries
///             PointerEvent, KeyEvent, ClientCutText ─►
/// close():    key-ups and a zero button mask ─►, then the channel closes
/// ```
///
/// **Flow control.** RFB's own: the server sends one update per request.
/// Each update becomes one or more frames, and the next request goes out
/// once the last of them is acknowledged with [ackFrame], which the
/// compositor does when it is on screen. At most one update is ever in
/// flight, and the frame rate follows what this device can draw.
///
/// **Updates and frames.** RFB applies an update's rects in order, and a
/// CopyRect reads the framebuffer as the rects before it left it. Frames
/// here are applied all at once, copies reading the screen as it was
/// before the frame (see [CsrdCopyTile]). So an update is cut into
/// consecutive frames wherever a copy's source was drawn by an earlier rect
/// of the same update, and at a resize, where the size changes.
///
/// **Not here.** RFB has no ping, so [rtt] stays null; a dead link is
/// noticed by the SSH connection under it. There is one display, the
/// framebuffer, whatever ExtendedDesktopSize says about the screens in it.
/// The clipboard is Latin-1, the only character set the core protocol has:
/// characters outside it become `?` on the way out.
///
/// Listen to [events] before calling [connect]: as for [CsrdClient], it is
/// a broadcast stream, and a frame nobody hears is never acknowledged.
class RfbClient implements RemoteScreenSession {
  /// [random] is for Apple authentication's key and padding; tests pass a
  /// seeded one. The default is `Random.secure()`.
  RfbClient({
    required this._input,
    required this._output,
    this.timing = const RfbTiming(),
    this.commandKey = RfbCommandKey.superKey,
    this._random,
  });

  final Stream<Uint8List> _input;
  final StreamSink<List<int>> _output;
  final Random? _random;
  final RfbTiming timing;

  /// Which keysym the Meta / Command / Windows key goes out as. The Mac
  /// opener asks for [RfbCommandKey.metaKey].
  final RfbCommandKey commandKey;

  final _events = StreamController<CsrdEvent>.broadcast();
  final _connected = Completer<void>();
  final _done = Completer<CsrdCloseReason>();
  final _zrle = RfbZrleDecoder();

  late final RfbByteReader _r;
  var _state = CsrdClientState.idle;
  CsrdCloseReason? _closeReason;
  var _authFailed = false;
  Timer? _handshakeTimer;

  final _outbox = <_Outgoing>[];
  var _flushScheduled = false;
  var _outputBroken = false;

  int? _version;
  int? _securityType;
  String? _name;
  var _width = 0;
  var _height = 0;
  List<CsrdDisplayInfo> _displays = const [];
  var _viewOnly = false;
  final _encodingsSeen = <int>{};

  // Flow control.
  var _seq = 0;
  var _ackedThrough = 0;
  int? _awaitingAck;
  var _requestOutstanding = false;
  var _needFull = true;

  // The frame being built from the current update.
  final _tiles = <CsrdTile>[];
  final _touched = <_Rect>[];
  var _frameStart = 0;
  var _updateArea = 0;

  // Input.
  var _buttons = 0;
  var _pointerX = 0;
  var _pointerY = 0;
  var _pointerKnown = false;
  var _scrollX = 0;
  var _scrollY = 0;

  /// evdev code → the keysym its press was sent as, so the release goes
  /// out as the same keysym.
  final _held = <int, int>{};

  @override
  Stream<CsrdEvent> get events => _events.stream;

  @override
  CsrdClientState get state => _state;

  @override
  Future<CsrdCloseReason> get done => _done.future;

  CsrdCloseReason? get closeReason => _closeReason;

  /// One display, the whole framebuffer, once connected.
  @override
  List<CsrdDisplayInfo> get displays => _displays;

  @override
  int? get display => _displays.isEmpty ? null : 0;

  /// ZRLE, CopyRect and Raw are all lossless.
  @override
  CsrdQuality get quality => CsrdQuality.lossless;

  @override
  bool get supportsQuality => false;

  @override
  Duration? get rtt => null;

  @override
  bool get viewOnly => _viewOnly;

  @override
  set viewOnly(bool value) {
    if (value == _viewOnly) return;
    if (value) releaseAll();
    _viewOnly = value;
  }

  /// Nothing about a VNC session fixes it as view-only.
  @override
  bool get viewOnlyLocked => false;

  /// The RFB minor version agreed on (3, 7 or 8), once it has been.
  int? get protocolVersion => _version;

  /// The security type used, an [RfbSecurity] value, once chosen.
  int? get securityType => _securityType;

  /// The desktop's name from ServerInit: a Mac sends its computer name.
  String? get desktopName => _name;

  int get framebufferWidth => _width;
  int get framebufferHeight => _height;

  /// Every encoding and pseudo-encoding the server has used so far.
  Set<int> get encodingsSeen => Set.unmodifiable(_encodingsSeen);

  /// Runs the handshake, asking [credentials] for a password when the
  /// server wants one. Completes once the first update has been asked for.
  ///
  /// Throws [CsrdConnectException] when the session does not get that far:
  /// its reason is [CsrdCloseKind.local] when [credentials] returned null
  /// (the person cancelled), and the exception is an
  /// [RfbAuthFailedException] when the server turned the credentials down,
  /// so the screen can ask again.
  Future<void> connect({
    required RfbCredentialsCallback credentials,
    bool viewOnly = false,
  }) {
    if (_state != CsrdClientState.idle) {
      throw StateError('connect() was already called');
    }
    _state = CsrdClientState.handshaking;
    _viewOnly = viewOnly;
    _r = RfbByteReader(_input);
    _startHandshakeTimer();
    unawaited(_run(credentials));
    return _connected.future;
  }

  /// There is one display; asking for it again asks for a full refresh.
  @override
  void selectDisplay(int display, {CsrdQuality? quality, int? maxFps}) {
    if (_state != CsrdClientState.connected) return;
    if (display != 0) {
      throw ArgumentError.value(display, 'display', 'not offered by the host');
    }
    _needFull = true;
  }

  /// Says frame [seq], and every frame before it, is on screen. Once the
  /// last frame of an update is, the next update is asked for.
  @override
  void ackFrame(int seq) {
    if (_state != CsrdClientState.connected) return;
    if (seq <= _ackedThrough || seq > _seq) return;
    _ackedThrough = seq;
    final waiting = _awaitingAck;
    if (waiting != null && seq >= waiting) {
      _awaitingAck = null;
      _requestUpdate();
    }
  }

  @override
  void pointerMove(int x, int y) {
    if (!_inputAllowed) return;
    _pointerX = x.clamp(0, _width - 1);
    _pointerY = y.clamp(0, _height - 1);
    _pointerKnown = true;
    _sendPointer(move: true);
  }

  /// Left, middle and right are RFB buttons 1–3; Back is X button 8.
  /// Forward, X button 9, does not fit RFB's 8-bit mask and is dropped.
  @override
  void pointerButton(int button, {required bool down}) {
    if (!_inputAllowed) return;
    final bit = switch (button) {
      CsrdButton.left => RfbButtonMask.left,
      CsrdButton.middle => RfbButtonMask.middle,
      CsrdButton.right => RfbButtonMask.right,
      CsrdButton.back => RfbButtonMask.back,
      _ => 0,
    };
    if (bit == 0) return;
    final next = down ? _buttons | bit : _buttons & ~bit;
    if (next == _buttons) return;
    _buttons = next;
    _sendPointer();
  }

  /// One press and release of wheel button 4 (up) or 5 (down), 6 (left)
  /// or 7 (right) per 120 units; what is left over is kept for the next
  /// call, so a touchpad's small steps add up to notches.
  @override
  void scroll(int dx, int dy) {
    if (!_inputAllowed) return;
    // A notch is a press and a release; 64 of them in one go is more than
    // any wheel or flick makes.
    const most = 120 * 64;
    _scrollY = (_scrollY + dy).clamp(-most, most);
    _scrollX = (_scrollX + dx).clamp(-most, most);
    while (_scrollY >= 120) {
      _click(RfbButtonMask.wheelUp);
      _scrollY -= 120;
    }
    while (_scrollY <= -120) {
      _click(RfbButtonMask.wheelDown);
      _scrollY += 120;
    }
    while (_scrollX >= 120) {
      _click(RfbButtonMask.wheelRight);
      _scrollX -= 120;
    }
    while (_scrollX <= -120) {
      _click(RfbButtonMask.wheelLeft);
      _scrollX += 120;
    }
  }

  /// The key's keysym, from `rfb_keysyms.dart`; keys with none are dropped.
  /// A release goes out only for a key this viewer pressed.
  @override
  void key(int evdevCode, {required bool down}) {
    if (!_inputAllowed) return;
    if (down) {
      final keysym = rfbKeysymForEvdev(evdevCode, commandKey: commandKey);
      if (keysym == null) return;
      _held[evdevCode] = keysym;
      _send(rfbKeyEvent(keysym, down: true));
    } else {
      final keysym = _held.remove(evdevCode);
      if (keysym == null) return;
      _send(rfbKeyEvent(keysym, down: false));
    }
  }

  /// Lets go of every key this viewer holds and sends a zero button mask.
  @override
  void releaseAll() {
    if (!_inputAllowed) return;
    for (final m in _releaseMessages()) {
      _send(m);
    }
  }

  /// Puts [text] on the remote clipboard as Latin-1 (see
  /// [rfbLatin1Encode]): characters outside it become `?`, and text past
  /// 1 MiB is cut.
  @override
  void sendClipboard(String text) {
    if (!_inputAllowed) return;
    _send(rfbClientCutText(rfbLatin1Encode(text)));
  }

  @override
  Future<CsrdCloseReason> close({String? error}) async {
    await _shutdown(
      error == null
          ? const CsrdCloseReason.local()
          : CsrdCloseReason.error(error),
      release: true,
    );
    return done;
  }

  // ------------------------------------------------------------ reading

  bool get _inputAllowed => _state == CsrdClientState.connected && !_viewOnly;

  Future<void> _run(RfbCredentialsCallback credentials) async {
    try {
      await _handshake(credentials);
      while (_state == CsrdClientState.connected) {
        await _message();
      }
    } on _Abandoned {
      // Closed while waiting; whoever closed it said why.
    } on RfbEndOfStream {
      if (_state == CsrdClientState.handshaking) {
        _fail(
          'the VNC server closed the connection during the handshake',
          release: false,
        );
      } else if (_state == CsrdClientState.connected) {
        unawaited(_shutdown(const CsrdCloseReason.peer(), release: false));
      }
    } on _HandshakeFailure catch (e) {
      _fail(e.message, release: false);
    } on RfbProtocolException catch (e) {
      _fail('bad data from the VNC server: $e');
    } catch (e) {
      if (_state != CsrdClientState.closed) {
        _fail('network error: $e', release: false);
      }
    }
  }

  Future<void> _handshake(RfbCredentialsCallback credentials) async {
    final banner = await _r.bytes(12);
    final text = String.fromCharCodes(banner);
    final match = RegExp(r'^RFB (\d{3})\.(\d{3})\n$').firstMatch(text);
    if (match == null) {
      throw _HandshakeFailure(
        'the other end is not a VNC server: it began with '
        '"${_printable(text)}"',
      );
    }
    final major = int.parse(match[1]!);
    final minor = int.parse(match[2]!);
    if (major < 3) {
      throw _HandshakeFailure(
        'the VNC server speaks RFB $major.$minor, which is too old',
      );
    }
    // 3.4–3.6 are to be read as 3.3; Apple's 3.889 is 3.8 and then some.
    final version = major > 3 || minor >= 8 ? 8 : (minor == 7 ? 7 : 3);
    _version = version;
    _send(Uint8List.fromList(ascii.encode('RFB 003.00$version\n')));

    final int type;
    if (version == 3) {
      type = await _r.u32();
      if (type == RfbSecurity.invalid) {
        throw _HandshakeFailure(
          'the VNC server refused the connection: '
          '${await _reason() ?? 'no reason given'}',
        );
      }
    } else {
      final n = await _r.u8();
      if (n == 0) {
        throw _HandshakeFailure(
          'the VNC server refused the connection: '
          '${await _reason() ?? 'no reason given'}',
        );
      }
      final offered = await _r.bytes(n, copy: true);
      type = _chooseSecurity(offered);
      _send(Uint8List.fromList([type]));
    }
    _securityType = type;

    switch (type) {
      case RfbSecurity.none:
        break;
      case RfbSecurity.vncAuth:
        final challenge = await _r.bytes(16, copy: true);
        final c = await _ask(credentials, RfbAuthKind.vncPassword);
        _send(rfbVncAuthResponse(c.password, challenge));
      case RfbSecurity.appleRemoteDesktop:
        final generator = await _r.u16();
        final keyLength = await _r.u16();
        if (keyLength == 0 || keyLength > rfbMaxDhKeyBytes) {
          throw RfbProtocolException('Diffie-Hellman key of $keyLength bytes');
        }
        final prime = await _r.bytes(keyLength, copy: true);
        final serverKey = await _r.bytes(keyLength, copy: true);
        final c = await _ask(credentials, RfbAuthKind.appleAccount);
        _send(
          rfbArdResponse(
            generator: generator,
            prime: prime,
            serverPublicKey: serverKey,
            username: c.username ?? '',
            password: c.password,
            random: _random,
          ).wire,
        );
      default:
        throw _HandshakeFailure(
          'the VNC server asked for security type $type, which this '
          'viewer does not support',
        );
    }

    // 3.3 and 3.7 send no SecurityResult after None.
    if (type != RfbSecurity.none || version == 8) {
      final result = await _r.u32();
      if (result != 0) {
        final reason = version == 8 ? await _reason() : null;
        _authFailed = type != RfbSecurity.none;
        final what = switch (type) {
          RfbSecurity.appleRemoteDesktop =>
            'the user name or password was not accepted',
          RfbSecurity.vncAuth => 'the VNC password was not accepted',
          _ => 'the VNC server refused the connection',
        };
        throw _HandshakeFailure(reason == null ? what : '$what ($reason)');
      }
    }

    _send(Uint8List.fromList([1])); // ClientInit: shared
    final width = await _r.u16();
    final height = await _r.u16();
    await _r.skip(16); // its pixel format, replaced by ours just below
    final nameLength = await _r.u32();
    if (nameLength > rfbMaxText) {
      throw RfbProtocolException('desktop name of $nameLength bytes');
    }
    final name = utf8.decode(await _r.bytes(nameLength), allowMalformed: true);
    _checkSize(width, height);
    _width = width;
    _height = height;
    _name = name;
    _displays = [_displayInfo()];

    _send(rfbSetPixelFormat());
    _send(rfbSetEncodings(RfbEncoding.requested));
    _state = CsrdClientState.connected;
    _handshakeTimer?.cancel();
    _requestUpdate();
    _emit(CsrdConnectedEvent(_displays, 0, 0));
    _connected.complete();
  }

  /// None if offered, then Apple's (a Mac's own accounts), then VNC's.
  int _chooseSecurity(Uint8List offered) {
    for (final t in const [
      RfbSecurity.none,
      RfbSecurity.appleRemoteDesktop,
      RfbSecurity.vncAuth,
    ]) {
      if (offered.contains(t)) return t;
    }
    throw _HandshakeFailure(
      'the VNC server offers no way in that this viewer supports '
      '(security types ${offered.join(', ')})',
    );
  }

  Future<({String? username, String password})> _ask(
    RfbCredentialsCallback credentials,
    RfbAuthKind kind,
  ) async {
    // The person may take a while; the server is waiting too.
    _handshakeTimer?.cancel();
    final ({String? username, String password})? answer;
    try {
      answer = await credentials(kind);
    } catch (e) {
      if (_state == CsrdClientState.closed) throw const _Abandoned();
      throw _HandshakeFailure('could not get the credentials: $e');
    }
    if (_state == CsrdClientState.closed) throw const _Abandoned();
    if (answer == null) {
      unawaited(_shutdown(const CsrdCloseReason.local(), release: false));
      throw const _Abandoned();
    }
    _startHandshakeTimer();
    return answer;
  }

  /// A failure reason, or null when the server hung up instead of giving
  /// one.
  Future<String?> _reason() async {
    try {
      final n = await _r.u32();
      if (n > rfbMaxText) return 'a reason too long to show';
      return utf8.decode(await _r.bytes(n), allowMalformed: true);
    } on RfbEndOfStream {
      return null;
    }
  }

  Future<void> _message() async {
    final type = await _r.u8();
    switch (type) {
      case RfbServerMessage.framebufferUpdate:
        await _update();
      case RfbServerMessage.setColourMapEntries:
        // Only for colour-mapped formats, which this client never asks for.
        await _r.skip(3);
        final n = await _r.u16();
        await _r.skip(n * 6);
      case RfbServerMessage.bell:
        break;
      case RfbServerMessage.serverCutText:
        await _r.skip(3);
        final n = await _r.u32();
        if (n > rfbMaxText) {
          // Too big to hold, but not wrong: dropped, not fatal.
          await _r.skip(n);
        } else {
          _emit(CsrdClipboardEvent(rfbLatin1Decode(await _r.bytes(n))));
        }
      default:
        throw RfbProtocolException('unknown message type $type');
    }
  }

  // ------------------------------------------------------------ updates

  Future<void> _update() async {
    _requestOutstanding = false;
    await _r.skip(1);
    final count = await _r.u16();
    final seqBefore = _seq;
    _frameStart = _r.consumed;
    _updateArea = 0;
    rects:
    for (var i = 0; i < count; i++) {
      final x = await _r.u16();
      final y = await _r.u16();
      final w = await _r.u16();
      final h = await _r.u16();
      final encoding = await _r.s32();
      _encodingsSeen.add(encoding);
      switch (encoding) {
        case RfbEncoding.raw:
          _checkRect(x, y, w, h, 'Raw');
          if (w == 0 || h == 0) continue;
          final px = await _r.bytes(w * h * 4, copy: true);
          for (var j = 3; j < px.length; j += 4) {
            px[j] = 0xff;
          }
          _addTile(CsrdPixelTile(x, y, w, h, px));
        case RfbEncoding.copyRect:
          final sx = await _r.u16();
          final sy = await _r.u16();
          _checkRect(x, y, w, h, 'CopyRect');
          _checkRect(sx, sy, w, h, 'CopyRect source', count: false);
          if (w == 0 || h == 0) continue;
          _addCopy(CsrdCopyTile(x, y, w, h, srcX: sx, srcY: sy));
        case RfbEncoding.zrle:
          final length = await _r.u32();
          _checkRect(x, y, w, h, 'ZRLE');
          if (length > RfbZrleDecoder.maxCompressed(w, h)) {
            throw RfbProtocolException(
              '$length bytes of ZRLE data for a ${w}x$h rect',
            );
          }
          // Decoded even when empty: the zlib stream has to stay in step.
          final z = _zrle.decode(await _r.bytes(length), w, h);
          if (w == 0 || h == 0) continue;
          final color = z.color;
          _addTile(
            color != null
                ? CsrdFillTile(x, y, w, h, color)
                : CsrdPixelTile(x, y, w, h, z.bgra!),
          );
        case RfbEncoding.cursor:
          await _cursor(x, y, w, h);
        case RfbEncoding.desktopSize:
          _resize(w, h);
        case RfbEncoding.extendedDesktopSize:
          final screens = await _r.u8();
          await _r.skip(3 + screens * 16);
          // y is the status: non-zero answers a resize request that failed,
          // and leaves the size as it was.
          if (y == 0) _resize(w, h);
        case RfbEncoding.lastRect:
          break rects;
        default:
          throw RfbProtocolException(
            'the server used encoding $encoding, which this viewer did not '
            'ask for',
          );
      }
    }
    _flushFrame();
    if (_seq != seqBefore) {
      _awaitingAck = _seq;
    } else if (_awaitingAck == null) {
      // Nothing to draw (only a cursor, say): nothing will be acked, so
      // ask again now.
      _requestUpdate();
    }
  }

  /// Checks the rect is inside the framebuffer and, with [count], adds it
  /// to the update's area.
  void _checkRect(
    int x,
    int y,
    int w,
    int h,
    String what, {
    bool count = true,
  }) {
    if (x + w > _width || y + h > _height) {
      throw RfbProtocolException(
        '$what rect ${w}x$h+$x+$y outside the ${_width}x$_height framebuffer',
      );
    }
    if (!count) return;
    _updateArea += w * h;
    if (_updateArea > rfbMaxUpdateCoverage * _width * _height) {
      throw const RfbProtocolException(
        'an update covering the screen many times over',
      );
    }
  }

  void _checkSize(int w, int h) {
    if (w == 0 ||
        h == 0 ||
        w > rfbMaxDimension ||
        h > rfbMaxDimension ||
        w * h > csrdMaxFramePixels) {
      throw RfbProtocolException(
        'a ${w}x$h framebuffer, which this viewer does not accept',
      );
    }
  }

  /// Per frame; past this an update goes on in another frame, so a server
  /// sending thousands of tiny rects cannot make the source checks of its
  /// copies quadratic.
  static const _maxTilesPerFrame = 1024;

  void _addTile(CsrdTile t) {
    _tiles.add(t);
    _touched.add(_Rect(t.x, t.y, t.width, t.height));
    if (_tiles.length >= _maxTilesPerFrame) _flushFrame();
  }

  void _addCopy(CsrdCopyTile t) {
    final src = _Rect(t.srcX, t.srcY, t.width, t.height);
    if (_touched.any(src.overlaps)) _flushFrame();
    _addTile(t);
  }

  void _resize(int w, int h) {
    _checkSize(w, h);
    if (w == _width && h == _height) return;
    _flushFrame();
    _width = w;
    _height = h;
    _pointerX = _pointerX.clamp(0, w - 1);
    _pointerY = _pointerY.clamp(0, h - 1);
    _displays = [_displayInfo()];
    _needFull = true;
    _emit(CsrdDisplaysEvent(_displays));
  }

  void _flushFrame() {
    if (_tiles.isEmpty) return;
    final frame = CsrdDecodedFrame(
      seq: ++_seq,
      width: _width,
      height: _height,
      tiles: List.unmodifiable(_tiles),
      wireBytes: _r.consumed - _frameStart,
    );
    _tiles.clear();
    _touched.clear();
    _frameStart = _r.consumed;
    _emit(CsrdFrameEvent(frame));
  }

  Future<void> _cursor(int hotX, int hotY, int w, int h) async {
    if (w > rfbMaxCursorSide || h > rfbMaxCursorSide) {
      throw RfbProtocolException('a ${w}x$h cursor, over 256x256');
    }
    final px = await _r.bytes(w * h * 4);
    final stride = (w + 7) >> 3;
    final mask = await _r.bytes(stride * h);
    if (w == 0 || h == 0) {
      _emit(
        CsrdCursorShapeEvent(
          CsrdCursorShape(
            width: 0,
            height: 0,
            hotX: 0,
            hotY: 0,
            rgba: Uint8List(0),
          ),
        ),
      );
      return;
    }
    final rgba = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final i = (y * w + x) * 4;
        rgba[i] = px[i + 2];
        rgba[i + 1] = px[i + 1];
        rgba[i + 2] = px[i];
        final bit = (mask[y * stride + (x >> 3)] >> (7 - (x & 7))) & 1;
        rgba[i + 3] = bit == 1 ? 0xff : 0;
      }
    }
    _emit(
      CsrdCursorShapeEvent(
        CsrdCursorShape(
          width: w,
          height: h,
          hotX: hotX,
          hotY: hotY,
          rgba: rgba,
        ),
      ),
    );
  }

  CsrdDisplayInfo _displayInfo() => CsrdDisplayInfo(
    index: 0,
    name: _name ?? '',
    x: 0,
    y: 0,
    width: _width,
    height: _height,
    primary: true,
  );

  void _requestUpdate() {
    if (_requestOutstanding || _state != CsrdClientState.connected) return;
    _requestOutstanding = true;
    _send(
      rfbUpdateRequest(
        incremental: !_needFull,
        x: 0,
        y: 0,
        width: _width,
        height: _height,
      ),
    );
    _needFull = false;
  }

  // -------------------------------------------------------------- output

  void _sendPointer({bool move = false}) =>
      _send(rfbPointerEvent(_buttons, _pointerX, _pointerY), pointerMove: move);

  void _click(int bit) {
    _send(rfbPointerEvent(_buttons | bit, _pointerX, _pointerY));
    _send(rfbPointerEvent(_buttons, _pointerX, _pointerY));
  }

  List<Uint8List> _releaseMessages() {
    final out = [
      for (final keysym in _held.values) rfbKeyEvent(keysym, down: false),
    ];
    _held.clear();
    if (_buttons != 0 || _pointerKnown) {
      _buttons = 0;
      out.add(rfbPointerEvent(0, _pointerX, _pointerY));
    }
    return out;
  }

  /// Queues [bytes]. Everything queued in one turn of the event loop goes
  /// out as one write, and of consecutive pointer moves only the last is
  /// kept, as [CsrdClient] does.
  void _send(Uint8List bytes, {bool pointerMove = false}) {
    if (_state == CsrdClientState.closed || _outputBroken) return;
    if (pointerMove && _outbox.isNotEmpty && _outbox.last.pointerMove) {
      _outbox[_outbox.length - 1] = _Outgoing(bytes, pointerMove: true);
    } else {
      _outbox.add(_Outgoing(bytes, pointerMove: pointerMove));
    }
    if (!_flushScheduled) {
      _flushScheduled = true;
      scheduleMicrotask(_flush);
    }
  }

  void _flush() {
    _flushScheduled = false;
    if (_outbox.isEmpty || _outputBroken) return;
    final bytes = BytesBuilder(copy: false);
    for (final m in _outbox) {
      bytes.add(m.bytes);
    }
    _outbox.clear();
    try {
      _output.add(bytes.takeBytes());
    } catch (e) {
      _outputBroken = true;
      _fail('cannot write to the VNC server: $e', release: false);
    }
  }

  // ------------------------------------------------------------- the end

  void _startHandshakeTimer() {
    _handshakeTimer?.cancel();
    _handshakeTimer = Timer(timing.handshakeTimeout, () {
      if (_state == CsrdClientState.handshaking) {
        _fail(
          'the VNC server did not answer within '
          '${timing.handshakeTimeout.inSeconds} s',
          release: false,
        );
      }
    });
  }

  void _fail(String message, {bool release = true}) {
    unawaited(_shutdown(CsrdCloseReason.error(message), release: release));
  }

  Future<void> _shutdown(
    CsrdCloseReason reason, {
    required bool release,
  }) async {
    if (_state == CsrdClientState.closed) {
      await done;
      return;
    }
    final wasConnected = _state == CsrdClientState.connected;
    final started = _state != CsrdClientState.idle;
    _state = CsrdClientState.closed;
    _closeReason = reason;
    _handshakeTimer?.cancel();

    // Whatever is queued goes out, then the release. A view-only session
    // let go of everything when it became one, and sends no input at all.
    if (release && wasConnected && !_viewOnly && !_outputBroken) {
      for (final m in _releaseMessages()) {
        _outbox.add(_Outgoing(m));
      }
    }
    _flush();

    if (!_connected.isCompleted) {
      _connected.completeError(
        _authFailed
            ? RfbAuthFailedException(reason)
            : CsrdConnectException(reason),
      );
      unawaited(_connected.future.catchError((_) {}));
    }
    _emit(CsrdClosedEvent(reason));
    unawaited(_events.close());
    if (started) await _r.cancel();
    try {
      await _output.close().timeout(timing.closeFlushTimeout);
    } catch (_) {
      // Already closed, or the far end stopped reading.
    }
    if (!_done.isCompleted) _done.complete(reason);
  }

  void _emit(CsrdEvent e) {
    if (!_events.isClosed) _events.add(e);
  }
}

/// The server turned the credentials down. A [CsrdConnectException], so a
/// caller that only knows that type still sees a failed connect; the
/// screen can catch this one to ask again.
class RfbAuthFailedException extends CsrdConnectException {
  const RfbAuthFailedException(super.reason);
}

/// [RfbClient]'s clocks. Tests shorten them.
class RfbTiming {
  const RfbTiming({
    this.handshakeTimeout = const Duration(seconds: 30),
    this.closeFlushTimeout = const Duration(milliseconds: 400),
  });

  /// How long each step of the handshake may take the server. Time spent
  /// waiting on the credentials callback does not count.
  final Duration handshakeTimeout;

  /// How long closing waits for the channel to take the final key-ups.
  final Duration closeFlushTimeout;
}

class _Outgoing {
  const _Outgoing(this.bytes, {this.pointerMove = false});
  final Uint8List bytes;
  final bool pointerMove;
}

class _Rect {
  const _Rect(this.x, this.y, this.w, this.h);
  final int x, y, w, h;

  bool overlaps(_Rect o) =>
      x < o.x + o.w && o.x < x + w && y < o.y + o.h && o.y < y + h;
}

class _HandshakeFailure implements Exception {
  const _HandshakeFailure(this.message);
  final String message;
}

class _Abandoned implements Exception {
  const _Abandoned();
}

String _printable(String s) =>
    s.replaceAll(RegExp(r'[^\x20-\x7e]'), '?').trim();
