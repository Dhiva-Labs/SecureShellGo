/// Input logic for the remote-desktop viewer that needs no widgets: the
/// port of `crossshell-view/src/input.rs` (pointer-move limiting, scroll
/// conversion, button mapping) plus the one piece a touch screen adds,
/// trackpad-style cursor acceleration.
///
/// Nothing here imports Flutter. Times are passed in as [Duration]s from
/// whatever monotonic clock the caller keeps, and positions are plain
/// numbers, so each piece is tested with made-up input and no engine.
library;

import 'dart:math' as math;

import 'csrd_messages.dart';

// ----------------------------------------------------------------- buttons

/// Flutter's button bits (`kPrimaryMouseButton` and friends in
/// `package:flutter/gestures.dart`). Copied rather than imported to keep
/// this file free of Flutter; `remote_input_test.dart` checks they have not
/// moved.
abstract final class FlutterButtons {
  static const primary = 0x01;
  static const secondary = 0x02;
  static const middle = 0x04;
  static const back = 0x08;
  static const forward = 0x10;
}

/// The [CsrdButton] for one Flutter button [bit], or null for a bit the
/// wire has no button for (a stylus barrel button, say).
///
/// Flutter's bit order is not the wire's: bit 1 is the secondary button
/// and bit 2 the middle one, where the wire numbers left, middle, right.
int? csrdButtonForFlutterBit(int bit) => switch (bit) {
  FlutterButtons.primary => CsrdButton.left,
  FlutterButtons.secondary => CsrdButton.right,
  FlutterButtons.middle => CsrdButton.middle,
  FlutterButtons.back => CsrdButton.back,
  FlutterButtons.forward => CsrdButton.forward,
  _ => null,
};

/// One button going down or up.
class RemoteButtonChange {
  const RemoteButtonChange(this.button, {required this.down});

  /// A [CsrdButton].
  final int button;
  final bool down;

  @override
  bool operator ==(Object other) =>
      other is RemoteButtonChange &&
      other.button == button &&
      other.down == down;

  @override
  int get hashCode => Object.hash(button, down);

  @override
  String toString() => 'RemoteButtonChange($button, ${down ? 'down' : 'up'})';
}

/// What changed between two Flutter button masks, as wire buttons.
///
/// Flutter reports the buttons held *now* on every event, and a release as
/// a mask without the bit, so the change is the difference. Releases come
/// first: when a press and a release arrive together the old button is let
/// go of before the new one goes down, as a real mouse does.
List<RemoteButtonChange> remoteButtonChanges(int previous, int current) {
  final out = <RemoteButtonChange>[];
  final released = previous & ~current;
  final pressed = current & ~previous;
  for (final bit in const [
    FlutterButtons.primary,
    FlutterButtons.secondary,
    FlutterButtons.middle,
    FlutterButtons.back,
    FlutterButtons.forward,
  ]) {
    final button = csrdButtonForFlutterBit(bit)!;
    if (released & bit != 0) out.add(RemoteButtonChange(button, down: false));
  }
  for (final bit in const [
    FlutterButtons.primary,
    FlutterButtons.secondary,
    FlutterButtons.middle,
    FlutterButtons.back,
    FlutterButtons.forward,
  ]) {
    final button = csrdButtonForFlutterBit(bit)!;
    if (pressed & bit != 0) out.add(RemoteButtonChange(button, down: true));
  }
  return out;
}

// ------------------------------------------------------------ move limiter

/// At most one pointer move per this long.
///
/// A 1 kHz mouse would otherwise send a thousand messages a second down an
/// SSH channel, each one a packet. 8 ms is about 125 a second, more than a
/// display can show.
const Duration remoteMoveInterval = Duration(milliseconds: 8);

/// Rate-limits pointer moves while never losing the final position: a move
/// that arrives too soon is held, and [flushDue] (or [force], before a
/// click) lets it go. The port of `MoveLimiter` in `input.rs`.
class MoveLimiter {
  Duration? _lastSentAt;
  (int, int)? _lastSent;
  (int, int)? _pending;

  /// The position held back, waiting for [flushDue].
  (int, int)? get pending => _pending;

  /// A new pointer position. Returns it when it should be sent now.
  (int, int)? push(Duration now, (int, int) p) {
    if (_lastSent == p) {
      _pending = null;
      return null;
    }
    final at = _lastSentAt;
    if (at != null && now - at < remoteMoveInterval) {
      _pending = p;
      return null;
    }
    return _sent(now, p);
  }

  /// The held move, once it is due.
  (int, int)? flushDue(Duration now) {
    final p = _pending;
    if (p == null) return null;
    final at = _lastSentAt;
    if (at == null || now - at >= remoteMoveInterval) return _sent(now, p);
    return null;
  }

  /// The held move whether or not it is due: for a timer that was set for
  /// the deadline and has just fired.
  (int, int)? takePending(Duration now) {
    final p = _pending;
    return p == null ? null : _sent(now, p);
  }

  /// [p] now, unless the remote pointer is already there. A click calls
  /// this first, so it lands where the pointer is shown to be.
  (int, int)? force(Duration now, (int, int) p) {
    if (_lastSent == p) {
      _pending = null;
      return null;
    }
    return _sent(now, p);
  }

  /// When the held move becomes due, or null with nothing held.
  Duration? get deadline {
    final at = _lastSentAt;
    return _pending == null || at == null ? null : at + remoteMoveInterval;
  }

  /// Forgets everything, after a display switch: the old position means
  /// nothing on the new screen.
  void reset() {
    _lastSentAt = null;
    _lastSent = null;
    _pending = null;
  }

  (int, int) _sent(Duration now, (int, int) p) {
    _lastSentAt = now;
    _lastSent = p;
    _pending = null;
    return p;
  }
}

// ----------------------------------------------------------------- scrolling

/// Pixels of touchpad movement that count as one wheel notch.
const double remotePixelsPerNotch = 40;

/// Wire units in one wheel notch.
const int remoteUnitsPerNotch = 120;

/// Turns scroll movement in pixels into wire units (1/120 notch, +y up,
/// +x right), carrying the fraction over so slow scrolling is not lost.
/// The port of `ScrollAccum` in `input.rs`.
///
/// The two entry points differ in whose movement they count, because Flutter
/// reports the two kinds of scrolling opposite ways round.
class ScrollAccumulator {
  ScrollAccumulator({this.pixelsPerNotch = remotePixelsPerNotch});

  final double pixelsPerNotch;
  double _x = 0;
  double _y = 0;

  /// A mouse wheel: `PointerScrollEvent.scrollDelta`, where a positive `dy`
  /// means "scroll down" and a positive `dx` "scroll right".
  (int, int)? addWheel(double dx, double dy) =>
      _add(dx / pixelsPerNotch, -dy / pixelsPerNotch);

  /// Fingers moving on a trackpad or on glass: a `panDelta`, or the change
  /// in two fingers' midpoint. The content follows the fingers, so fingers
  /// moving down scroll up and fingers moving right scroll left.
  (int, int)? addFingers(double dx, double dy) =>
      _add(-dx / pixelsPerNotch, dy / pixelsPerNotch);

  (int, int)? _add(double notchesX, double notchesY) {
    _x += notchesX * remoteUnitsPerNotch;
    _y += notchesY * remoteUnitsPerNotch;
    final dx = _x.truncateToDouble();
    final dy = _y.truncateToDouble();
    _x -= dx;
    _y -= dy;
    if (dx == 0 && dy == 0) return null;
    return (_clamp16(dx), _clamp16(dy));
  }

  void reset() {
    _x = 0;
    _y = 0;
  }

  static int _clamp16(double v) => v.clamp(-32768.0, 32767.0).toInt();
}

// ------------------------------------------------------------- acceleration

/// How far the remote cursor goes for a finger's movement in trackpad
/// mode.
///
/// A slow finger moves the cursor exactly as far as it moves on screen, so
/// aiming a few pixels is possible. A fast one is multiplied, so crossing a
/// 1080p screen on a phone does not take five swipes. The curve is the
/// usual one: unity below a speed, a ramp above it, a cap.
class TrackpadAcceleration {
  const TrackpadAcceleration({
    this.slowSpeed = 0.25,
    this.ramp = 1.6,
    this.maxGain = 3.5,
  });

  /// Speed, in view pixels per millisecond, up to which there is no gain.
  final double slowSpeed;

  /// Extra gain per pixel/ms above [slowSpeed].
  final double ramp;
  final double maxGain;

  /// Events closer together than this are treated as this far apart: a
  /// batched pair of moves reporting a 0 ms gap would read as infinitely
  /// fast.
  static const _minMillis = 4.0;

  /// The multiplier for a movement of ([dx], [dy]) view pixels in [dt].
  double gain(double dx, double dy, Duration dt) {
    final millis = math.max(dt.inMicroseconds / 1000, _minMillis);
    final speed = math.sqrt(dx * dx + dy * dy) / millis;
    return (1 + math.max(0, speed - slowSpeed) * ramp).clamp(1, maxGain);
  }
}
