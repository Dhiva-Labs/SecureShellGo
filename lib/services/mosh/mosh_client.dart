import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'mosh_connection.dart';
import 'mosh_display.dart';
import 'mosh_overlay.dart';
import 'mosh_protobuf.dart';
import 'mosh_terminal.dart';
import 'mosh_transport.dart';

/// Thrown by [MoshClient.connect] when the server never answers over UDP —
/// a firewall in the way, almost always.
class MoshUnreachableException implements Exception {
  const MoshUnreachableException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// How a Mosh session ended.
class MoshExit {
  const MoshExit({required this.clean, this.reason});

  /// True when the server shut down in an orderly way (the shell exited) or
  /// acknowledged this client's goodbye.
  final bool clean;
  final String? reason;
}

/// One Mosh session's client side, from the first datagram to the last: the
/// event loop of Mosh's `STMClient::main`, driven by datagrams, keystrokes
/// and a timer instead of `select()`.
///
/// What it produces is [output]: escape sequences to write into a terminal
/// that shows nothing else, which then shows exactly what the server's
/// screen holds, plus Mosh's overlays.
class MoshClient {
  MoshClient({
    required Uint8List key,
    required InternetAddress address,
    required int port,
    required int columns,
    required int rows,
    MoshUdpBinder bind = bindRawMoshSocket,
    MoshClock clock = moshMonotonicNow,
    MoshPredictionMode prediction = MoshPredictionMode.adaptive,
  }) : _clock = clock,
       _columns = columns < 1 ? 80 : columns.clamp(1, moshMaxTerminalSize),
       _rows = rows < 1 ? 24 : rows.clamp(1, moshMaxTerminalSize),
       _predictions = MoshPredictionEngine(mode: prediction),
       _notifications = MoshNotificationEngine(clock()) {
    connection = MoshConnection(
      key: key,
      serverAddress: address,
      serverPort: port,
      bind: bind,
      clock: clock,
    );
    transport =
        MoshTransport(
            connection: connection,
            width: _columns,
            height: _rows,
            clock: clock,
          )
          ..onFatal = _fatal
          ..onInstruction = _instructionArrived;
    // Mosh's client sends its keystrokes with a minimal delay.
    transport.sendMinDelay = 1;
    _shown = MoshFramebuffer(_columns, _rows);
    // The server's terminal starts at 80×24; the first thing it hears is
    // the real size.
    transport.userStream.push(UserResize(_columns, _rows));
  }

  final MoshClock _clock;
  late final MoshConnection connection;
  late final MoshTransport transport;
  final MoshDisplay _display = const MoshDisplay();
  final MoshPredictionEngine _predictions;
  final MoshNotificationEngine _notifications;

  int _columns;
  int _rows;

  /// What the terminal is showing: the last frame drawn, overlays and all.
  late MoshFramebuffer _shown;
  var _drawnOnce = false;
  var _repaintRequested = false;

  final _output = StreamController<String>.broadcast(sync: true);
  final _done = Completer<MoshExit>();
  final _connected = Completer<void>();
  Timer? _timer;
  var _iterationScheduled = false;
  var _closed = false;

  /// Escape sequences for the terminal, in order.
  Stream<String> get output => _output.stream;

  /// Completes once, when the session is over for any reason.
  Future<MoshExit> get done => _done.future;

  bool get isClosed => _closed;

  /// True once the server's first screen has arrived.
  bool get isConnected => transport.remoteStateNum != 0;

  /// True while the server has been out of touch long enough for the
  /// "Last contact" bar to show.
  bool get isLate => _notifications.isLate(_clock());

  /// Opens the socket and starts talking. Completes when the server's first
  /// screen arrives; throws [MoshUnreachableException] when nothing comes
  /// back within [timeout].
  Future<void> connect({Duration timeout = const Duration(seconds: 10)}) async {
    await connection.open();
    _scheduleIteration();
    try {
      await _connected.future.timeout(timeout);
    } on TimeoutException {
      _finish(
        const MoshExit(
          clean: false,
          reason: 'No reply from mosh-server over UDP.',
        ),
      );
      throw MoshUnreachableException(
        'mosh-server did not answer on UDP port ${connection.serverPort}; '
        'a firewall is probably blocking it.',
      );
    }
  }

  /// Bytes the user typed or pasted.
  void sendInput(List<int> bytes) {
    if (_closed || transport.shutdownInProgress || bytes.isEmpty) return;
    _predictions.localFrameSent = transport.sentStateLast;
    // Pastes are not predicted.
    final paste = bytes.length > 100;
    if (paste) _predictions.reset();
    final now = _clock();
    for (final byte in bytes) {
      if (!paste) _predictions.newUserByte(byte, _shown, now);
      // Ctrl-L redraws the screen locally as well as remotely.
      if (byte == 0x0c) _repaintRequested = true;
    }
    transport.userStream.push(UserKeystroke(Uint8List.fromList(bytes)));
    _scheduleIteration();
  }

  /// The terminal is now [columns] × [rows].
  void resize(int columns, int rows) {
    if (_closed || columns < 1 || rows < 1) return;
    // The server echoes the size back, and the client refuses one past this.
    if (columns > moshMaxTerminalSize) columns = moshMaxTerminalSize;
    if (rows > moshMaxTerminalSize) rows = moshMaxTerminalSize;
    if (columns == _columns && rows == _rows) return;
    _columns = columns;
    _rows = rows;
    if (!transport.shutdownInProgress) {
      transport.userStream.push(UserResize(columns, rows));
    }
    _predictions.reset();
    // The terminal has reflowed what it was showing; draw from scratch.
    _repaintRequested = true;
    _scheduleIteration();
  }

  /// Redraws everything on the next frame — after something else wrote into
  /// the terminal, say.
  void repaint() {
    _repaintRequested = true;
    _scheduleIteration();
  }

  /// The device's network changed: move to a fresh local port now, rather
  /// than after ten seconds of silence.
  void networkChanged() {
    if (_closed) return;
    connection.hopPort();
    _scheduleIteration();
  }

  /// Says goodbye to the server and waits (a few seconds at most) for it to
  /// agree. Ends the server's shell too.
  Future<MoshExit> close() {
    if (!_closed && !transport.shutdownInProgress) {
      transport.startShutdown();
      _scheduleIteration();
    }
    return done;
  }

  /// Stops at once, without telling the server — which keeps the session
  /// open for a later client, until its own timeout.
  void abandon() => endBecause('Closed.');

  /// Ends the session at once, for [reason], without telling the server.
  void endBecause(String reason) =>
      _finish(MoshExit(clean: false, reason: reason));

  void _fatal(String reason) => _finish(MoshExit(clean: false, reason: reason));

  void _instructionArrived() {
    _notifications.serverHeard(transport.latestRemoteStateTimestamp);
    _notifications.serverAcked(transport.sentStateAckedTimestamp);
    _predictions
      ..sendInterval = transport.sendInterval
      ..localFrameLateAcked = transport.latestRemoteState.echoAck;
    if (!_connected.isCompleted && isConnected) _connected.complete();
    _scheduleIteration();
  }

  /// Runs one iteration soon, coalescing everything that happens before it.
  void _scheduleIteration() {
    if (_closed || _iterationScheduled) return;
    _iterationScheduled = true;
    scheduleMicrotask(() {
      _iterationScheduled = false;
      _iterate();
    });
  }

  void _iterate() {
    if (_closed) return;
    _timer?.cancel();
    _timer = null;

    if (transport.shutdownInProgress && transport.shutdownAcknowledged) {
      _finish(const MoshExit(clean: true));
      return;
    }
    if (transport.shutdownInProgress && transport.shutdownAckTimedOut) {
      _finish(
        const MoshExit(
          clean: false,
          reason: 'The server did not acknowledge the goodbye.',
        ),
      );
      return;
    }
    if (transport.counterpartyShutdownAckSent) {
      _outputNewFrame();
      _finish(const MoshExit(clean: true, reason: 'The session ended.'));
      return;
    }

    transport.tick();
    final error = connection.sendError;
    if (error != null) {
      _notifications.setNetworkError(error, _clock());
    } else {
      _notifications.clearNetworkError(_clock());
    }

    if (isConnected) _outputNewFrame();

    var wait = transport.waitTime();
    if (isConnected) {
      wait = _min(wait, _notifications.waitTime(_clock()));
      wait = _min(wait, _predictions.waitTime);
    } else {
      wait = _min(wait, 250);
    }
    // Something always comes due within seconds (the acknowledgement timer),
    // but keep "never" from overflowing a Duration.
    _timer = Timer(Duration(milliseconds: wait.clamp(0, 60000)), _iterate);
  }

  static int _min(int a, int b) => a < b ? a : b;

  void _outputNewFrame() {
    final now = _clock();
    final next = transport.latestRemoteState.fb.copy();
    // Until the server has caught up with a resize, show its screen cut or
    // padded to the terminal's new size rather than drawn at the old one.
    if (next.ds.width != _columns || next.ds.height != _rows) {
      next.resize(_columns, _rows);
    }
    _predictions
      ..cull(next, now)
      ..apply(next);
    _notifications
      ..adjustMessage(now)
      ..apply(next, now);

    final initialized = _drawnOnce && !_repaintRequested;
    final frame = _display.newFrame(initialized, _shown, next);
    if (!_drawnOnce) {
      _drawnOnce = true;
      _emit(MoshDisplay.open);
    }
    _emit(frame);
    _repaintRequested = false;
    _shown = next;
  }

  void _emit(String text) {
    if (text.isEmpty || _output.isClosed) return;
    _output.add(text);
  }

  void _finish(MoshExit exit) {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    _timer = null;
    if (_drawnOnce) _emit(MoshDisplay.close);
    connection.close();
    if (!_done.isCompleted) _done.complete(exit);
    if (!_connected.isCompleted) {
      _connected.future.ignore();
      _connected.completeError(
        MoshUnreachableException(exit.reason ?? 'Mosh stopped.'),
      );
    }
    unawaited(_output.close());
  }
}
