import 'dart:math';
import 'dart:typed_data';

import 'mosh_connection.dart';
import 'mosh_fragment.dart';
import 'mosh_protobuf.dart';
import 'mosh_terminal.dart';

/// Mosh's State Synchronization Protocol, client side
/// (`networktransport-impl.h`, `transportsender-impl.h`).
///
/// Each side keeps numbered *states* — the client its stream of keystrokes
/// and resizes, the server its screen — and sends the other the difference
/// between the newest state and one the other side is believed to have.
/// Every datagram also acknowledges the newest state received. Nothing is
/// ever retransmitted as such: a lost datagram is simply overtaken by the
/// next difference, computed against what is now known to have arrived.
/// That is why a Mosh session shrugs off loss, reordering and long silences.
///
/// Timing follows Mosh exactly: a frame at most every SRTT/2 (20–250 ms),
/// keystrokes after a 1 ms gathering delay, an empty acknowledgement 100 ms
/// after data arrives or every 3 s regardless, and retries at the frame rate
/// for ten seconds after the server was last heard from.
class MoshTransport {
  MoshTransport({
    required this.connection,
    required int width,
    required int height,
    MoshClock clock = moshMonotonicNow,
    Random? random,
  })
    // ignore: prefer_initializing_formals
    : _clock = clock,
       _random = random ?? Random() {
    final now = _clock();
    _sentStates = [_SentState(now, 0, 0)];
    _assumedReceiver = _sentStates.first;
    _nextAckTime = now;
    _nextSendTime = now;
    _receivedStates = [
      _ReceivedState(0, now, MoshTerminalState(width, height)),
    ];
    connection.onPayload = _receivePayload;
  }

  static const protocolVersion = 2;
  static const sendIntervalMin = 20;
  static const sendIntervalMax = 250;
  static const ackInterval = 3000;
  static const ackDelay = 100;
  static const shutdownRetries = 16;
  static const activeRetryTimeout = 10000;

  /// "Never", for timer fields Mosh sets to uint64 max.
  static const _never = 1 << 62;

  final MoshConnection connection;
  final MoshClock _clock;
  final Random _random;

  /// Raised (and the session ended) for a server speaking another protocol
  /// version.
  void Function(String reason)? onFatal;

  /// Called after a new screen state has been accepted.
  void Function()? onRemoteState;

  // ---------------------------------------------------------------- sender

  final MoshUserStream userStream = MoshUserStream();

  /// First: what the server is known to have. Last: what was last sent.
  late List<_SentState> _sentStates;
  late _SentState _assumedReceiver;
  final MoshFragmenter _fragmenter = MoshFragmenter();
  late int _nextAckTime;
  late int _nextSendTime;
  var _shutdownInProgress = false;
  var _shutdownTries = 0;
  var _shutdownStart = -1;
  var _ackNum = 0;
  var _pendingDataAck = false;

  /// How long to gather input before sending it. Mosh's client uses 1 ms.
  int sendMinDelay = 1;

  /// When a new screen state last arrived.
  var _lastHeard = 0;
  int? _mindelayClock;

  // -------------------------------------------------------------- receiver

  late List<_ReceivedState> _receivedStates;
  var _receiverQuenchTimer = 0;
  final MoshFragmentAssembly _fragments = MoshFragmentAssembly();

  /// Instructions that would not decompress or parse.
  int malformed = 0;

  // --------------------------------------------------------------- getters

  /// The newest screen the server has sent.
  MoshTerminalState get latestRemoteState => _receivedStates.last.state;

  /// When [latestRemoteState] arrived.
  int get latestRemoteStateTimestamp => _receivedStates.last.timestamp;

  /// 0 until the server's first state arrives.
  int get remoteStateNum => _receivedStates.last.num;

  int get sentStateAcked => _sentStates.first.num;
  int get sentStateAckedTimestamp => _sentStates.first.timestamp;
  int get sentStateLast => _sentStates.last.num;

  bool get shutdownInProgress => _shutdownInProgress;
  bool get shutdownAcknowledged => _sentStates.first.num == moshShutdownNum;

  /// True once this side has acknowledged the server's own shutdown.
  bool get counterpartyShutdownAckSent =>
      _fragmenter.lastAckSent == moshShutdownNum;

  bool get shutdownAckTimedOut {
    if (!_shutdownInProgress) return false;
    return _shutdownTries >= shutdownRetries ||
        _clock() - _shutdownStart >= activeRetryTimeout;
  }

  void startShutdown() {
    if (_shutdownInProgress) return;
    _shutdownStart = _clock();
    _shutdownInProgress = true;
  }

  /// Roughly two frames per round trip, within Mosh's frame-rate limits.
  int get sendInterval {
    final interval = (connection.srtt / 2).ceil();
    if (interval < sendIntervalMin) return sendIntervalMin;
    if (interval > sendIntervalMax) return sendIntervalMax;
    return interval;
  }

  // --------------------------------------------------------------- sending

  void _calculateTimers() {
    final now = _clock();
    _updateAssumedReceiverState();
    _rationalizeStates();

    if (_pendingDataAck && _nextAckTime > now + ackDelay) {
      _nextAckTime = now + ackDelay;
    }

    final current = userStream.size;
    if (current != _sentStates.last.state) {
      final mindelay = _mindelayClock ??= now;
      _nextSendTime = max(
        mindelay + sendMinDelay,
        _sentStates.last.timestamp + sendInterval,
      );
    } else if (current != _assumedReceiver.state &&
        _lastHeard + activeRetryTimeout > now) {
      _nextSendTime = _sentStates.last.timestamp + sendInterval;
      final mindelay = _mindelayClock;
      if (mindelay != null) {
        _nextSendTime = max(_nextSendTime, mindelay + sendMinDelay);
      }
    } else if (current != _sentStates.first.state &&
        _lastHeard + activeRetryTimeout > now) {
      _nextSendTime =
          _sentStates.last.timestamp + connection.timeout + ackDelay;
    } else {
      _nextSendTime = _never;
    }

    // Hurry the shutdown handshake along.
    if (_shutdownInProgress || _ackNum == moshShutdownNum) {
      _nextAckTime = _sentStates.last.timestamp + sendInterval;
    }
  }

  /// Milliseconds until [tick] next has something to do.
  int waitTime() {
    _calculateTimers();
    final next = min(_nextAckTime, _nextSendTime);
    final now = _clock();
    return next > now ? next - now : 0;
  }

  /// Sends a difference or an empty acknowledgement if one is due.
  void tick() {
    _calculateTimers();
    final now = _clock();
    if (now < _nextAckTime && now < _nextSendTime) return;

    var diff = userStream.diff(_assumedReceiver.state);
    diff = _attemptProspectiveResendOptimization(diff);

    if (diff.isEmpty) {
      if (now >= _nextAckTime) {
        _sendEmptyAck();
        _mindelayClock = null;
      }
      if (now >= _nextSendTime) {
        _nextSendTime = _never;
        _mindelayClock = null;
      }
    } else if (now >= _nextSendTime || now >= _nextAckTime) {
      _sendToReceiver(diff);
      _mindelayClock = null;
    }
  }

  void _sendEmptyAck() {
    final now = _clock();
    final newNum = _shutdownInProgress
        ? moshShutdownNum
        : _sentStates.last.num + 1;
    _addSentState(now, newNum, userStream.size);
    _sendInFragments(Uint8List(0), newNum);
    _nextAckTime = now + ackInterval;
    _nextSendTime = _never;
  }

  void _addSentState(int timestamp, int num, int state) {
    _sentStates.add(_SentState(timestamp, num, state));
    if (_sentStates.length > 32) {
      // Drop one from the middle; the ends are what matter.
      _sentStates.removeAt(_sentStates.length - 16);
    }
  }

  void _sendToReceiver(Uint8List diff) {
    final current = userStream.size;
    var newNum = current == _sentStates.last.state
        ? _sentStates.last.num
        : _sentStates.last.num + 1;
    if (_shutdownInProgress) newNum = moshShutdownNum;

    if (newNum == _sentStates.last.num) {
      _sentStates.last.timestamp = _clock();
    } else {
      _addSentState(_clock(), newNum, current);
    }
    _sendInFragments(diff, newNum);

    _assumedReceiver = _sentStates.last;
    _nextAckTime = _clock() + ackInterval;
    _nextSendTime = _never;
  }

  void _sendInFragments(Uint8List diff, int newNum) {
    final chaff = Uint8List(_random.nextInt(17));
    for (var i = 0; i < chaff.length; i++) {
      chaff[i] = _random.nextInt(256);
    }
    final instruction = TransportInstruction(
      protocolVersion: protocolVersion,
      oldNum: _assumedReceiver.num,
      newNum: newNum,
      ackNum: _ackNum,
      throwawayNum: _sentStates.first.num,
      diff: diff,
      chaff: chaff,
    );
    if (newNum == moshShutdownNum) _shutdownTries++;
    final fragments = _fragmenter.fragment(
      instruction,
      connection.mtu - 12 - 16, // Connection::ADDED_BYTES, Session::ADDED_BYTES
    );
    for (final fragment in fragments) {
      connection.send(fragment.encode());
    }
    _pendingDataAck = false;
  }

  void _updateAssumedReceiverState() {
    final now = _clock();
    // Start from what is known, and give the benefit of the doubt to states
    // sent recently enough that they may well have arrived.
    _assumedReceiver = _sentStates.first;
    for (var i = 1; i < _sentStates.length; i++) {
      if (now - _sentStates[i].timestamp < connection.timeout + ackDelay) {
        _assumedReceiver = _sentStates[i];
      } else {
        return;
      }
    }
  }

  void _rationalizeStates() => userStream.forgetBefore(_sentStates.first.state);

  Uint8List _attemptProspectiveResendOptimization(Uint8List proposed) {
    if (identical(_assumedReceiver, _sentStates.first)) return proposed;
    final resend = userStream.diff(_sentStates.first.state);
    // Resend from the known state if that is no longer, or only a little
    // longer and still small.
    if (resend.length <= proposed.length ||
        (resend.length < 1000 && resend.length - proposed.length < 100)) {
      _assumedReceiver = _sentStates.first;
      return resend;
    }
    return proposed;
  }

  void _processAcknowledgmentThrough(int ackNum) {
    // An acknowledgement of a state already culled says nothing new.
    if (!_sentStates.any((s) => s.num == ackNum)) return;
    _sentStates.removeWhere((s) => compareUint64(s.num, ackNum) < 0);
  }

  // ------------------------------------------------------------- receiving

  void _receivePayload(Uint8List payload) {
    final fragment = MoshFragment.decode(payload);
    if (fragment == null) {
      malformed++;
      return;
    }
    TransportInstruction? instruction;
    try {
      instruction = _fragments.add(fragment);
    } catch (_) {
      malformed++;
      return;
    }
    if (instruction != null) _receiveInstruction(instruction);
  }

  void _receiveInstruction(TransportInstruction inst) {
    if (inst.protocolVersion != protocolVersion) {
      onFatal?.call(
        'The server speaks Mosh protocol version '
        '${inst.protocolVersion}; this app speaks $protocolVersion.',
      );
      return;
    }

    _processAcknowledgmentThrough(inst.ackNum);
    // End-to-end connectivity: what keeps the connection from hopping ports.
    connection.lastRoundtripSuccess = sentStateAckedTimestamp;

    // Already have it?
    if (_receivedStates.any((s) => s.num == inst.newNum)) return;

    // Must have the state it was computed against; anything else is out of
    // order, and dropping it is part of how idempotency is enforced.
    final reference = _receivedStates
        .where((s) => s.num == inst.oldNum)
        .firstOrNull;
    if (reference == null) return;

    _processThrowawayUntil(inst.throwawayNum);

    if (_receivedStates.length > 1024) {
      final now = _clock();
      if (now < _receiverQuenchTimer) return;
      _receiverQuenchTimer = now + 15000;
    }

    final state = reference.state.copy();
    if (inst.diff.isNotEmpty) {
      try {
        state.applyDiff(inst.diff);
      } on ProtobufFormatException {
        malformed++;
        return;
      }
    }
    final received = _ReceivedState(inst.newNum, _clock(), state);

    for (var i = 0; i < _receivedStates.length; i++) {
      if (compareUint64(_receivedStates[i].num, received.num) > 0) {
        // Out of order: kept, but not acknowledged or shown yet.
        _receivedStates.insert(i, received);
        return;
      }
    }
    _receivedStates.add(received);
    _ackNum = received.num;
    _lastHeard = received.timestamp;
    if (inst.diff.isNotEmpty) _pendingDataAck = true;
    onRemoteState?.call();
  }

  void _processThrowawayUntil(int throwawayNum) {
    // The server will never again compute a difference against these.
    final keep = _receivedStates
        .where((s) => compareUint64(s.num, throwawayNum) >= 0)
        .toList();
    if (keep.isEmpty) keep.add(_receivedStates.last);
    _receivedStates = keep;
  }
}

class _SentState {
  _SentState(this.timestamp, this.num, this.state);
  int timestamp;
  final int num;

  /// How many user events this state holds; see [MoshUserStream].
  final int state;
}

class _ReceivedState {
  _ReceivedState(this.num, this.timestamp, this.state);
  final int num;
  final int timestamp;
  final MoshTerminalState state;
}

/// Everything the user has typed and every resize, in order: the client's
/// state in Mosh's protocol.
///
/// Mosh compares and trims these states as whole event lists; since every
/// state is a prefix of the same stream, a state here is just the number of
/// events in it, and only events not yet acknowledged are kept.
class MoshUserStream {
  final List<UserEvent> _events = [];
  var _base = 0;

  /// The state number for "everything so far".
  int get size => _base + _events.length;

  void push(UserEvent event) => _events.add(event);

  /// The `UserMessage` carrying every event after state [from]; empty when
  /// there are none.
  Uint8List diff(int from) {
    final start = from - _base;
    if (start >= _events.length) return Uint8List(0);
    return UserMessageCodec.encode(_events.sublist(start < 0 ? 0 : start));
  }

  /// Drops events the server is known to have.
  void forgetBefore(int state) {
    final drop = state - _base;
    if (drop <= 0) return;
    _events.removeRange(0, drop > _events.length ? _events.length : drop);
    _base = state;
  }
}
