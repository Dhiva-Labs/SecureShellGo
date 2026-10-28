/// Turns fingers on glass into what a mouse would have done: the gesture
/// half of the remote-desktop viewer for phones and tablets.
///
/// Two ways of using a touch screen as a pointer, picked by [RemoteTouchMode]:
///
/// **Trackpad** (the default). The screen is a touchpad and the cursor is
/// somewhere else on it.
/// - one finger dragging moves the cursor relatively, faster if the finger is
/// - a tap is a left click, at the cursor
/// - two fingers tapped together are a right click
/// - two fingers dragging scroll
/// - two fingers pinching zoom the view
/// - a finger held still, then dragged, drags with the left button down
///
/// **Direct**. The remote is the screen, and touching it touches it.
/// - a tap is a left click where it landed
/// - a finger dragging drags with the left button down, from where it landed
/// - holding still is a right click, as on a phone's own touch screen
/// - two fingers scroll and pinch exactly as above
///
/// In either mode three fingers dragging pan the zoomed view, since one
/// finger is the pointer and two are spoken for.
///
/// The tracker only classifies. What a gesture does goes through a
/// [RemoteTouchSink], and it is given times rather than reading a clock, so
/// it is tested by feeding it made-up touches.
library;

import 'dart:async';
import 'dart:math' as math;

import 'csrd_messages.dart';

enum RemoteTouchMode { trackpad, direct }

/// What the viewer does for a gesture. All positions and distances are in
/// the viewer's logical pixels, as the pointer events gave them.
abstract interface class RemoteTouchSink {
  /// Trackpad: the finger moved ([dx], [dy]) over [dt]. The sink scales it
  /// to remote pixels and applies acceleration.
  void cursorMoved(double dx, double dy, Duration dt);

  /// Direct: the pointer goes to viewer point ([x], [y]).
  void cursorAt(double x, double y);

  /// A `CsrdButton` goes down or up at the cursor.
  void button(int button, {required bool down});

  /// A `CsrdButton` is pressed and released at the cursor.
  void click(int button);

  /// Two fingers scrolled by ([dx], [dy]): the movement of their midpoint.
  void scroll(double dx, double dy);

  /// The view zooms by [factor] about ([focalX], [focalY]).
  void pinch(double factor, double focalX, double focalY);

  /// The view moves by ([dx], [dy]).
  void panView(double dx, double dy);

  /// A long press was recognised.
  void haptic();
}

typedef TouchTimerFactory =
    Timer Function(Duration after, void Function() fire);

enum _Phase {
  /// No finger down.
  idle,

  /// One finger down and still: a tap, or a long press, so far.
  one,

  /// One finger, moved past the slop: moving the cursor, or dragging.
  dragging,

  /// Two fingers, not yet moved enough to say what they are doing.
  two,
  scrolling,
  pinching,
  panning,

  /// The gesture has been used up (a click was sent, or more fingers came
  /// than mean anything): nothing more happens until every finger is up.
  spent,
}

class _Finger {
  _Finger(this.x, this.y, this.t) : downX = x, downY = y, lastT = t;
  double x;
  double y;
  final double downX;
  final double downY;
  final Duration t;
  Duration lastT;
}

class _Group {
  const _Group(this.cx, this.cy, this.distance);
  final double cx;
  final double cy;
  final double distance;
}

class RemoteTouchTracker {
  RemoteTouchTracker({
    required this.sink,
    this.mode = RemoteTouchMode.trackpad,
    this.slop = 10,
    this.longPressAfter = const Duration(milliseconds: 450),
    this.twoFingerTapWithin = const Duration(milliseconds: 350),
    TouchTimerFactory? timer,
  }) : _timer = timer ?? Timer.new;

  final RemoteTouchSink sink;
  RemoteTouchMode mode;

  /// How far a finger can wander and still be a tap or a held press.
  final double slop;
  final Duration longPressAfter;

  /// Two fingers lifted within this of the second landing are a tap.
  final Duration twoFingerTapWithin;

  final TouchTimerFactory _timer;
  final _fingers = <int, _Finger>{};
  _Phase _phase = _Phase.idle;
  Timer? _longPress;
  var _held = false;
  late Duration _groupStart;
  late _Group _groupOrigin;
  late _Group _groupLast;

  /// True while a gesture is under way.
  bool get active => _phase != _Phase.idle;

  void down(int id, double x, double y, Duration t) {
    if (_fingers.containsKey(id)) return;
    _fingers[id] = _Finger(x, y, t);
    if (_phase == _Phase.spent) return;
    switch (_fingers.length) {
      case 1:
        _phase = _Phase.one;
        _longPress = _timer(longPressAfter, _longPressed);
      case 2:
        _stopLongPress();
        if (_held) {
          // A second finger while dragging with the button down ends the
          // drag and is not itself a gesture: its tap must not click.
          _releaseHeld();
          _phase = _Phase.spent;
          return;
        }
        _phase = _Phase.two;
        _groupStart = t;
        _groupOrigin = _groupLast = _group();
      case 3:
        _phase = _Phase.panning;
        _groupLast = _group();
      default:
        _phase = _Phase.spent;
    }
  }

  void move(int id, double x, double y, Duration t) {
    final finger = _fingers[id];
    if (finger == null) return;
    final dx = x - finger.x;
    final dy = y - finger.y;
    final dt = t - finger.lastT;
    finger.x = x;
    finger.y = y;
    finger.lastT = t;
    switch (_phase) {
      case _Phase.one:
        if (_distanceFromDown(finger) <= slop) return;
        _stopLongPress();
        _phase = _Phase.dragging;
        if (mode == RemoteTouchMode.direct) {
          // The press goes where the finger landed, not where it has got
          // to by the time it is known to be a drag.
          sink.cursorAt(finger.downX, finger.downY);
          sink.button(CsrdButton.left, down: true);
          _held = true;
          sink.cursorAt(x, y);
        }
      case _Phase.dragging:
        if (mode == RemoteTouchMode.direct) {
          sink.cursorAt(x, y);
        } else {
          sink.cursorMoved(dx, dy, dt);
        }
      case _Phase.two:
        final g = _group();
        final spread = (g.distance - _groupOrigin.distance).abs();
        final travel = math.sqrt(
          math.pow(g.cx - _groupOrigin.cx, 2) +
              math.pow(g.cy - _groupOrigin.cy, 2),
        );
        if (math.max(spread, travel) <= slop) return;
        // Fingers moving apart or together are a pinch; moving the same way
        // are a scroll. The first to clear the slop decides, for good: a
        // scroll whose fingers drift a little must not start zooming.
        _phase = spread > travel ? _Phase.pinching : _Phase.scrolling;
        _applyGroup(_group());
      case _Phase.scrolling || _Phase.pinching:
        _applyGroup(_group());
      case _Phase.panning:
        final g = _group();
        sink.panView(g.cx - _groupLast.cx, g.cy - _groupLast.cy);
        _groupLast = g;
      case _Phase.idle || _Phase.spent:
        break;
    }
  }

  void up(int id, Duration t) {
    final finger = _fingers[id];
    if (finger == null) return;
    switch (_phase) {
      case _Phase.one:
        // Still and short: a tap. A long press has already moved on.
        _stopLongPress();
        if (mode == RemoteTouchMode.direct) {
          sink.cursorAt(finger.downX, finger.downY);
        }
        sink.click(CsrdButton.left);
      case _Phase.dragging:
        if (mode == RemoteTouchMode.direct) sink.cursorAt(finger.x, finger.y);
        _releaseHeld();
      case _Phase.two:
        if (t - _groupStart <= twoFingerTapWithin) {
          if (mode == RemoteTouchMode.direct) {
            final g = _group();
            sink.cursorAt(g.cx, g.cy);
          }
          sink.click(CsrdButton.right);
        }
      case _Phase.idle ||
          _Phase.scrolling ||
          _Phase.pinching ||
          _Phase.panning ||
          _Phase.spent:
        break;
    }
    _fingers.remove(id);
    _afterLift();
  }

  /// The system took the touch away (a palm rejected, an edge swipe): end
  /// without acting on it, but never leave a button held.
  void cancel(int id) {
    if (_fingers.remove(id) == null) return;
    _stopLongPress();
    _releaseHeld();
    _afterLift();
  }

  /// Ends everything, for when the viewer is going away or input is being
  /// turned off.
  void reset() {
    _stopLongPress();
    _releaseHeld();
    _fingers.clear();
    _phase = _Phase.idle;
  }

  void _afterLift() {
    if (_fingers.isEmpty) {
      _phase = _Phase.idle;
    } else {
      // Fingers left over from a gesture that has ended do not start a new
      // one: the remaining finger would otherwise jump the cursor.
      _phase = _Phase.spent;
    }
  }

  void _longPressed() {
    _longPress = null;
    if (_phase != _Phase.one || _fingers.length != 1) return;
    final finger = _fingers.values.single;
    sink.haptic();
    if (mode == RemoteTouchMode.direct) {
      sink.cursorAt(finger.x, finger.y);
      sink.click(CsrdButton.right);
      _phase = _Phase.spent;
    } else {
      sink.button(CsrdButton.left, down: true);
      _held = true;
      _phase = _Phase.dragging;
    }
  }

  void _applyGroup(_Group g) {
    final last = _groupLast;
    if (_phase == _Phase.pinching) {
      if (last.distance > 0 && g.distance > 0) {
        sink.pinch(g.distance / last.distance, last.cx, last.cy);
      }
      sink.panView(g.cx - last.cx, g.cy - last.cy);
    } else {
      sink.scroll(g.cx - last.cx, g.cy - last.cy);
    }
    _groupLast = g;
  }

  void _releaseHeld() {
    if (!_held) return;
    _held = false;
    sink.button(CsrdButton.left, down: false);
  }

  void _stopLongPress() {
    _longPress?.cancel();
    _longPress = null;
  }

  double _distanceFromDown(_Finger f) {
    final dx = f.x - f.downX;
    final dy = f.y - f.downY;
    return math.sqrt(dx * dx + dy * dy);
  }

  /// Midpoint of the fingers down, and for two of them the gap between.
  _Group _group() {
    var sx = 0.0;
    var sy = 0.0;
    for (final f in _fingers.values) {
      sx += f.x;
      sy += f.y;
    }
    final n = _fingers.length;
    var distance = 0.0;
    if (n == 2) {
      final a = _fingers.values.first;
      final b = _fingers.values.last;
      distance = math.sqrt(math.pow(a.x - b.x, 2) + math.pow(a.y - b.y, 2));
    }
    return _Group(sx / n, sy / n, distance);
  }
}
