import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'csrd_messages.dart';
import 'csrd_tiles.dart';
import 'remote_screen_session.dart';

/// The viewer side of one CSRD session: the port of CrossShell's
/// `crossshell-view/src/net.rs`, over whatever carries the bytes.
///
/// It is handed a byte stream and a sink, which in the app are the two
/// halves of a dartssh2 `forwardLocal` channel to the agent's loopback port
/// on the remote, and in tests are in-memory pipes. There is no socket here
/// and no local listening port. The client owns that transport from then
/// on, and closes it when the session ends.
///
/// ```text
/// connect():  Hello (token, name, CAP_DEFLATE) ─►
///             ◄─ Welcome (displays, caps)  or  Reject (reason)
///             Start (display, quality, fps, view-only) ─►
/// then:       ◄─ Frame … FrameAck ─►       at most 2 frames unacked
///             Ping ─► ◄─ Pong              every 2 s; silence for 15 s = dead
///             ◄─ Cursor*, Notice, DisplaysChanged, ClipboardText
///             PointerMove/Button, Scroll, Key, ReleaseAll, ClipboardText ─►
/// close():    ReleaseAll ─►, then the channel is closed
/// ```
///
/// Frames are acknowledged only when [ackFrame] is called, which the
/// compositor does once a frame is actually on screen. The agent stops at
/// two unacknowledged frames, so the frame rate follows what this device
/// can draw, and a viewer that stops drawing (an app in the background)
/// stops the stream without further ado.
///
/// Listen to [events] before calling [connect]: it is a broadcast stream,
/// and an event nobody is listening for is gone, a frame included, and an
/// unacknowledged frame stalls the stream.
class CsrdClient implements RemoteScreenSession {
  CsrdClient({
    required this._input,
    required this._output,
    this.timing = const CsrdTiming(),
    CsrdFrameDecoder? decode,
  }) : _decode = decode ?? CsrdTileDecoder.decode;

  final Stream<Uint8List> _input;
  final StreamSink<List<int>> _output;
  final CsrdFrameDecoder _decode;
  final CsrdTiming timing;

  final _events = StreamController<CsrdEvent>.broadcast();
  final _connected = Completer<void>();
  final _done = Completer<CsrdCloseReason>();
  final _reader = CsrdMessageReader(maxPayload: _welcomePayloadLimit);
  final _clock = Stopwatch()..start();

  StreamSubscription<Uint8List>? _subscription;
  var _state = CsrdClientState.idle;
  CsrdCloseReason? _closeReason;

  /// What [connect] was asked for, until the Welcome says what is possible.
  CsrdConnectOptions? _pendingStart;

  final _outbox = <CsrdMessage>[];
  var _flushScheduled = false;
  var _outputBroken = false;

  /// Frames received and not yet acknowledged, oldest first.
  final _unacked = ListQueue<int>();
  Future<void> _decoding = Future.value();

  Timer? _waitingTimer;
  Timer? _handshakeTimer;
  Timer? _pingTimer;
  var _lastHeard = Duration.zero;

  /// The last error notice, while it stands: if the agent hangs up after
  /// one (capture failed), that is the reason, not a bare end of stream.
  String? _errorNotice;

  List<CsrdDisplayInfo> _displays = const [];
  int? _display;
  var _quality = CsrdQuality.balanced;
  var _maxFps = 30;
  var _hostCaps = 0;
  var _viewOnlyLocked = false;
  var _viewOnly = false;
  Duration? _rtt;

  /// Everything that happens in the session, in order. Ends with one
  /// [CsrdClosedEvent].
  @override
  Stream<CsrdEvent> get events => _events.stream;

  @override
  CsrdClientState get state => _state;

  /// Completes once, when the session is over for any reason.
  @override
  Future<CsrdCloseReason> get done => _done.future;

  /// Why the session ended; null while it has not.
  CsrdCloseReason? get closeReason => _closeReason;

  /// The agent's displays, as of the last [CsrdWelcome] or
  /// [CsrdDisplaysEvent]. Empty before the handshake.
  @override
  List<CsrdDisplayInfo> get displays => _displays;

  /// The display being streamed: the one asked for if the agent has it,
  /// else its primary, else its first.
  @override
  int? get display => _display;
  @override
  CsrdQuality get quality => _quality;

  @override
  bool get supportsQuality => true;
  int get maxFps => _maxFps;

  /// The `Welcome.caps` bits.
  int get hostCaps => _hostCaps;

  /// The latest ping round trip.
  @override
  Duration? get rtt => _rtt;

  /// Frames received and not yet acknowledged.
  int get unackedFrames => _unacked.length;

  /// True while input and outgoing clipboard text are being dropped.
  @override
  bool get viewOnly => _viewOnly;

  /// True when the session was started view-only. The agent then opened no
  /// input injector at all, so [viewOnly] cannot be turned off without
  /// reconnecting.
  @override
  bool get viewOnlyLocked => _viewOnlyLocked;

  /// Stops sending input (and clipboard text), or starts again. Turning it
  /// on releases whatever this viewer holds down first, so no key is left
  /// stuck on the remote. Ignored when [viewOnlyLocked].
  @override
  set viewOnly(bool value) {
    if (value == _viewOnly || (!value && _viewOnlyLocked)) return;
    if (value) releaseAll();
    _viewOnly = value;
  }

  /// Runs the handshake. Completes once [CsrdStart] has been sent, and
  /// throws [CsrdConnectException] when the agent rejects this viewer,
  /// cannot do what it needs, or does not answer in time.
  ///
  /// Waiting can be long: on KDE and wlroots desktops the agent sits on a
  /// consent dialog on the remote screen before it answers. After
  /// [CsrdTiming.waitingNoticeAfter] a [CsrdWaitingEvent] says so.
  Future<void> connect(CsrdConnectOptions options) {
    if (_state != CsrdClientState.idle) {
      throw StateError('connect() was already called');
    }
    if (options.token.length != csrdTokenLength) {
      throw ArgumentError.value(
        options.token.length,
        'token',
        'must be $csrdTokenLength bytes',
      );
    }
    _state = CsrdClientState.handshaking;
    _quality = options.quality;
    _maxFps = _fps(options.maxFps);
    _viewOnlyLocked = _viewOnly = options.viewOnly;
    _pendingStart = options;
    _subscription = _input.listen(
      _onData,
      onError: (Object e) => _fail('network error: $e', release: false),
      onDone: _onDone,
    );
    _send(
      CsrdHello(
        version: csrdVersion,
        token: options.token,
        viewerName: _viewerName(options.viewerName),
        caps: csrdCapDeflate,
      ),
    );
    _waitingTimer = Timer(timing.waitingNoticeAfter, () {
      if (_state == CsrdClientState.handshaking) {
        _emit(
          const CsrdWaitingEvent(
            'Waiting for the remote side (it may be showing a consent '
            'dialog)',
          ),
        );
      }
    });
    _handshakeTimer = Timer(timing.handshakeTimeout, () {
      _fail(
        'the remote side did not answer within '
        '${timing.handshakeTimeout.inSeconds} s',
      );
    });
    return _connected.future;
  }

  /// Switches display, quality or frame rate; what is not given stays. The
  /// next frame is a full refresh, possibly of another size.
  ///
  /// Throws [ArgumentError] for a display the agent did not list: the agent
  /// ends the whole session over one.
  @override
  void selectDisplay(int display, {CsrdQuality? quality, int? maxFps}) {
    if (_state != CsrdClientState.connected) return;
    if (!_displays.any((d) => d.index == display)) {
      throw ArgumentError.value(display, 'display', 'not offered by the host');
    }
    _display = display;
    if (quality != null) _quality = quality;
    if (maxFps != null) _maxFps = _fps(maxFps);
    _send(
      CsrdSelectDisplay(
        display: display,
        quality: _quality.wire,
        maxFps: _maxFps,
      ),
    );
  }

  /// Says frame [seq], and every frame before it, is on screen. Unknown,
  /// repeated and out-of-date acknowledgements are ignored.
  @override
  void ackFrame(int seq) {
    if (_state != CsrdClientState.connected || !_unacked.contains(seq)) {
      return;
    }
    while (_unacked.removeFirst() != seq) {}
    _send(CsrdFrameAck(seq));
  }

  /// Moves the remote pointer to display pixel ([x], [y]). Moves queued
  /// together collapse into the last one.
  @override
  void pointerMove(int x, int y) {
    if (!_inputAllowed) return;
    _send(CsrdPointerMove(_i32(x), _i32(y)));
  }

  /// A [CsrdButton] went [down] or up. Other numbers are ignored, as the
  /// agent would.
  @override
  void pointerButton(int button, {required bool down}) {
    if (!_inputAllowed || button < 1 || button > 5) return;
    _send(CsrdPointerButton(button, down: down));
  }

  /// Wheel movement in 1/120-notch units: positive [dy] scrolls up,
  /// positive [dx] right. Clamped to the wire's 16 bits.
  @override
  void scroll(int dx, int dy) {
    if (!_inputAllowed || (dx == 0 && dy == 0)) return;
    _send(CsrdScroll(dx.clamp(-0x8000, 0x7fff), dy.clamp(-0x8000, 0x7fff)));
  }

  /// A key by evdev [code] (see `csrd_keymap.dart`).
  @override
  void key(int code, {required bool down}) {
    if (!_inputAllowed || code < 1 || code > 0xffff) return;
    _send(CsrdKey(code, down: down));
  }

  /// Releases every key and button this viewer holds on the remote. For
  /// focus loss, and anything else after which held keys would be a
  /// surprise.
  @override
  void releaseAll() {
    if (!_inputAllowed) return;
    _send(const CsrdReleaseAll());
  }

  /// Puts [text] on the remote clipboard. Text over [csrdMaxClipboard]
  /// UTF-8 bytes is cut on a character boundary: the agent would end the
  /// session over a longer one, not just refuse it.
  @override
  void sendClipboard(String text) {
    if (!_inputAllowed) return;
    _send(CsrdClipboardText(_truncateUtf8(text, csrdMaxClipboard)));
  }

  /// Ends the session: releases held input on the remote, gives the
  /// channel [CsrdTiming.closeFlushTimeout] to carry that, and closes it.
  /// With [error], the session is reported as having failed with it (a
  /// frame the compositor could not decode, say) rather than closed by the
  /// user.
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

  // ---------------------------------------------------------------- input

  bool get _inputAllowed => _state == CsrdClientState.connected && !_viewOnly;

  void _onData(Uint8List chunk) {
    if (_state == CsrdClientState.closed) return;
    _lastHeard = _clock.elapsed;
    _reader.add(chunk);
    try {
      while (_state != CsrdClientState.closed) {
        final m = _reader.next();
        if (m == null) break;
        if (_state == CsrdClientState.handshaking) {
          _onHandshake(m);
        } else {
          _onMessage(m);
        }
      }
    } on CsrdProtocolException catch (e) {
      _fail('bad message from the remote side: $e');
    }
  }

  void _onDone() {
    if (_state == CsrdClientState.closed) return;
    if (_state == CsrdClientState.handshaking) {
      _fail(
        'the remote side closed the connection before answering',
        release: false,
      );
      return;
    }
    final notice = _errorNotice;
    unawaited(
      _shutdown(
        notice != null
            ? CsrdCloseReason.error(notice)
            : const CsrdCloseReason.peer(),
        release: false,
      ),
    );
  }

  void _onHandshake(CsrdMessage m) {
    switch (m) {
      case CsrdWelcome(:final version, :final caps, :final displays):
        if (version != csrdVersion) {
          _fail(
            'the remote side speaks protocol version $version, this viewer '
            'speaks $csrdVersion',
          );
          return;
        }
        if (caps & csrdCapDeflate == 0) {
          _fail(
            'the agent on the remote side is too old for this viewer: it '
            'cannot send deflate-compressed tiles, and this viewer has no '
            'zstd decoder. Update the agent.',
          );
          return;
        }
        if (displays.isEmpty) {
          _fail('the remote side has no displays to share');
          return;
        }
        final options = _pendingStart!;
        _pendingStart = null;
        final display = displays.any((d) => d.index == options.display)
            ? options.display
            : displays
                  .firstWhere((d) => d.primary, orElse: () => displays.first)
                  .index;
        _displays = List.unmodifiable(displays);
        _display = display;
        _hostCaps = caps;
        _send(
          CsrdStart(
            display: display,
            quality: _quality.wire,
            maxFps: _maxFps,
            viewOnly: options.viewOnly,
          ),
        );
        _state = CsrdClientState.connected;
        _reader.maxPayload = csrdMaxPayload;
        _waitingTimer?.cancel();
        _handshakeTimer?.cancel();
        _pingTimer = Timer.periodic(timing.pingEvery, (_) => _tick());
        // Ping right away, so the first round trip is known early.
        _tick();
        _emit(CsrdConnectedEvent(_displays, display, caps));
        _connected.complete();
      case CsrdReject(:final reason):
        _fail('the remote side rejected the connection: $reason');
      default:
        _fail(
          'unexpected message 0x${m.kind.toRadixString(16).padLeft(2, '0')} '
          'instead of welcome',
        );
    }
  }

  void _onMessage(CsrdMessage m) {
    switch (m) {
      case CsrdFrame():
        _onFrame(m);
      case CsrdCursorShape():
        _emit(CsrdCursorShapeEvent(m));
      case CsrdCursorPos(:final x, :final y):
        _emit(CsrdCursorPosEvent(x, y));
      case CsrdDisplaysChanged(:final displays):
        _displays = List.unmodifiable(displays);
        _emit(CsrdDisplaysEvent(_displays));
      case CsrdNotice(:final level, :final text):
        if (level >= CsrdNoticeLevel.error && text.isNotEmpty) {
          _errorNotice = text;
        } else if (text.isEmpty) {
          _errorNotice = null;
        }
        _emit(CsrdNoticeEvent(level, text));
      case CsrdClipboardText(:final text):
        _emit(CsrdClipboardEvent(text));
      case CsrdPing(:final value):
        _send(CsrdPong(value));
      case CsrdPong(:final value):
        final rtt = _clock.elapsedMicroseconds * 1000 - value;
        _rtt = Duration(microseconds: rtt < 0 ? 0 : rtt ~/ 1000);
        _emit(CsrdRttEvent(_rtt!));
      case CsrdReject(:final reason):
        _fail('rejected: $reason');
      default:
        // The handshake's messages and the viewer's own are not valid here;
        // the Rust viewer ignores them too.
        break;
    }
  }

  void _onFrame(CsrdFrame frame) {
    // A host keeping to the window never has more than two frames here
    // that this viewer has not acknowledged. One that does not would have
    // frames pile up, decoded, faster than they can be drawn.
    if (_unacked.length >= csrdMaxInflightFrames) {
      _fail(
        'the remote side sent more than $csrdMaxInflightFrames frames '
        'without waiting for them to be acknowledged',
      );
      return;
    }
    _unacked.add(frame.seq);
    // Decoding may hop to another isolate; chaining keeps frames in order.
    _decoding = _decoding.then((_) async {
      if (_state == CsrdClientState.closed) return;
      final CsrdDecodedFrame decoded;
      try {
        decoded = await _decode(frame);
      } catch (e) {
        _fail('bad frame from the remote side: $e');
        return;
      }
      if (_state == CsrdClientState.closed) return;
      _emit(CsrdFrameEvent(decoded));
    });
  }

  void _tick() {
    if (_state != CsrdClientState.connected) return;
    if (_clock.elapsed - _lastHeard > timing.deadAfter) {
      _fail(
        'the remote side stopped responding for '
        '${timing.deadAfter.inSeconds} s',
      );
      return;
    }
    _send(CsrdPing(_clock.elapsedMicroseconds * 1000));
  }

  // --------------------------------------------------------------- output

  /// Queues [m]. Everything queued in one turn of the event loop goes out
  /// as one write, so one SSH packet, and of consecutive pointer moves only
  /// the last is kept, as the Rust viewer's writer does.
  void _send(CsrdMessage m) {
    if (_state == CsrdClientState.closed || _outputBroken) return;
    if (m is CsrdPointerMove &&
        _outbox.isNotEmpty &&
        _outbox.last is CsrdPointerMove) {
      _outbox[_outbox.length - 1] = m;
    } else {
      _outbox.add(m);
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
      bytes.add(m.encode());
    }
    _outbox.clear();
    try {
      _output.add(bytes.takeBytes());
    } catch (e) {
      _outputBroken = true;
      _fail('cannot write to the remote side: $e', release: false);
    }
  }

  // ------------------------------------------------------------- the end

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
    _state = CsrdClientState.closed;
    _closeReason = reason;
    _waitingTimer?.cancel();
    _handshakeTimer?.cancel();
    _pingTimer?.cancel();

    // Whatever is queued goes out, then the release: a key pressed just
    // before closing is let go of, not left down.
    if (release && wasConnected && !_viewOnlyLocked && !_outputBroken) {
      _outbox.add(const CsrdReleaseAll());
    }
    _flush();

    if (!_connected.isCompleted) {
      _connected.completeError(CsrdConnectException(reason));
      // connect()'s caller hears about it; nobody else needs to.
      unawaited(_connected.future.catchError((_) {}));
    }
    _emit(CsrdClosedEvent(reason));
    unawaited(_events.close());
    await _subscription?.cancel();
    try {
      await _output.close().timeout(timing.closeFlushTimeout);
    } catch (_) {
      // Already closed, or the far end stopped reading: either way there
      // is nothing more to deliver.
    }
    if (!_done.isCompleted) _done.complete(reason);
  }

  void _emit(CsrdEvent e) {
    if (!_events.isClosed) _events.add(e);
  }
}

/// What [CsrdClient] does with a frame's rects. The default decodes on a
/// worker isolate when a frame is large; see [CsrdTileDecoder.decode].
typedef CsrdFrameDecoder = Future<CsrdDecodedFrame> Function(CsrdFrame frame);

/// The agent's Welcome: well under this even with 255 displays of 200-byte
/// names. It arrives before the agent has shown anything about itself, so
/// it is not given the post-handshake 64 MiB.
const _welcomePayloadLimit = 64 << 10;

/// The agent keeps 64 characters of the name; sending more would only
/// risk the Hello going over the agent's 1 KiB pre-auth limit, which it
/// answers by hanging up without a reason.
String _viewerName(String name) => String.fromCharCodes(name.runes.take(64));

int _fps(int fps) => fps.clamp(1, 120);

int _i32(int v) => v.clamp(-0x80000000, 0x7fffffff);

String _truncateUtf8(String text, int maxBytes) {
  final bytes = utf8.encode(text);
  if (bytes.length <= maxBytes) return text;
  var end = maxBytes;
  while (end > 0 && (bytes[end] & 0xc0) == 0x80) {
    end--;
  }
  return utf8.decode(Uint8List.sublistView(bytes, 0, end));
}

/// Wire quality levels.
enum CsrdQuality {
  /// Every tile exact: Fill and Deflate only.
  lossless(0),

  /// JPEG at 80 for photographic tiles, refined to exact once they stay
  /// still.
  balanced(1),

  /// JPEG at 60, refined the same way.
  speed(2);

  const CsrdQuality(this.wire);
  final int wire;
}

/// The session's clocks. The defaults are CrossShell's; tests shorten them.
class CsrdTiming {
  const CsrdTiming({
    this.waitingNoticeAfter = const Duration(seconds: 3),
    this.handshakeTimeout = const Duration(seconds: 120),
    this.pingEvery = const Duration(seconds: 2),
    this.deadAfter = const Duration(seconds: 15),
    this.closeFlushTimeout = const Duration(milliseconds: 400),
  });

  /// When to say the agent may be waiting on a consent dialog.
  final Duration waitingNoticeAfter;

  /// When to stop waiting for the Welcome.
  final Duration handshakeTimeout;

  /// The agent counts a viewer silent for 15 s as gone, and answers every
  /// ping, so pings both keep the session up and measure the round trip.
  final Duration pingEvery;

  /// Nothing at all from the agent for this long ends the session.
  final Duration deadAfter;

  /// How long closing waits for the channel to take the final ReleaseAll.
  final Duration closeFlushTimeout;
}

class CsrdConnectOptions {
  const CsrdConnectOptions({
    required this.token,
    required this.viewerName,
    this.display = 0,
    this.quality = CsrdQuality.balanced,
    this.maxFps = 30,
    this.viewOnly = false,
  });

  /// The agent's 32-byte session token, from its `host.json`.
  final Uint8List token;

  /// Shown to the person at the remote in the "being viewed" notice.
  final String viewerName;

  /// The display wanted. If the agent has no such display, its primary is
  /// started instead.
  final int display;
  final CsrdQuality quality;

  /// 1–120.
  final int maxFps;

  /// Sends no input for the whole session; see [CsrdClient.viewOnlyLocked].
  final bool viewOnly;
}

enum CsrdClientState { idle, handshaking, connected, closed }

enum CsrdCloseKind {
  /// This side closed the session.
  local,

  /// The agent closed the connection cleanly.
  peer,

  /// Anything else; see [CsrdCloseReason.message].
  error,
}

class CsrdCloseReason {
  const CsrdCloseReason.local() : kind = CsrdCloseKind.local, message = null;
  const CsrdCloseReason.peer() : kind = CsrdCloseKind.peer, message = null;
  const CsrdCloseReason.error(String this.message) : kind = CsrdCloseKind.error;

  final CsrdCloseKind kind;
  final String? message;

  /// A sentence for the person.
  String get text => switch (kind) {
    CsrdCloseKind.local => 'closed by user',
    CsrdCloseKind.peer => 'the remote side closed the connection',
    CsrdCloseKind.error => message!,
  };

  @override
  bool operator ==(Object other) =>
      other is CsrdCloseReason &&
      other.kind == kind &&
      other.message == message;

  @override
  int get hashCode => Object.hash(kind, message);

  @override
  String toString() => 'CsrdCloseReason(${kind.name}: $text)';
}

/// [CsrdClient.connect] did not get as far as a running session.
class CsrdConnectException implements Exception {
  const CsrdConnectException(this.reason);
  final CsrdCloseReason reason;
  @override
  String toString() => reason.text;
}

/// Something that happened in a session.
sealed class CsrdEvent {
  const CsrdEvent();
}

/// No Welcome yet, for a while: the agent may be showing a consent dialog.
final class CsrdWaitingEvent extends CsrdEvent {
  const CsrdWaitingEvent(this.message);
  final String message;
}

/// The handshake is done and streaming has been asked for.
final class CsrdConnectedEvent extends CsrdEvent {
  const CsrdConnectedEvent(this.displays, this.display, this.caps);
  final List<CsrdDisplayInfo> displays;

  /// The display actually started.
  final int display;
  final int caps;
}

/// A frame, decoded and ready to composite. Acknowledge it with
/// [CsrdClient.ackFrame] once it is on screen.
final class CsrdFrameEvent extends CsrdEvent {
  const CsrdFrameEvent(this.frame);
  final CsrdDecodedFrame frame;
}

/// The remote pointer's image; [CsrdCursorShape.hidden] when there is none.
final class CsrdCursorShapeEvent extends CsrdEvent {
  const CsrdCursorShapeEvent(this.shape);
  final CsrdCursorShape shape;
}

/// The remote pointer moved (by itself, or after our input), in display
/// pixels.
final class CsrdCursorPosEvent extends CsrdEvent {
  const CsrdCursorPosEvent(this.x, this.y);
  final int x;
  final int y;
}

/// The agent's set of displays changed; also in [CsrdClient.displays].
final class CsrdDisplaysEvent extends CsrdEvent {
  const CsrdDisplaysEvent(this.displays);
  final List<CsrdDisplayInfo> displays;
}

/// Something to tell the person. An empty [text] withdraws the last one.
final class CsrdNoticeEvent extends CsrdEvent {
  const CsrdNoticeEvent(this.level, this.text);

  /// A [CsrdNoticeLevel].
  final int level;
  final String text;
}

/// The remote clipboard now holds [text].
final class CsrdClipboardEvent extends CsrdEvent {
  const CsrdClipboardEvent(this.text);
  final String text;
}

/// A ping came back; also in [CsrdClient.rtt].
final class CsrdRttEvent extends CsrdEvent {
  const CsrdRttEvent(this.rtt);
  final Duration rtt;
}

/// The session is over; always the last event.
final class CsrdClosedEvent extends CsrdEvent {
  const CsrdClosedEvent(this.reason);
  final CsrdCloseReason reason;
}
