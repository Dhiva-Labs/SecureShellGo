import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/remote_desktop/csrd_messages.dart';
import 'package:secure_shell_go/services/remote_desktop/remote_input_touch.dart';

/// Records what the tracker asks for, as short strings.
class Recorder implements RemoteTouchSink {
  final log = <String>[];

  @override
  void cursorMoved(double dx, double dy, Duration dt) =>
      log.add('rel ${dx.round()},${dy.round()}');

  @override
  void cursorAt(double x, double y) => log.add('at ${x.round()},${y.round()}');

  @override
  void button(int button, {required bool down}) =>
      log.add('button $button ${down ? 'down' : 'up'}');

  @override
  void click(int button) => log.add('click $button');

  @override
  void scroll(double dx, double dy) =>
      log.add('scroll ${dx.round()},${dy.round()}');

  @override
  void pinch(double factor, double focalX, double focalY) =>
      log.add('pinch ${factor.toStringAsFixed(2)}');

  @override
  void panView(double dx, double dy) =>
      log.add('pan ${dx.round()},${dy.round()}');

  @override
  void haptic() => log.add('haptic');
}

/// A timer that fires when the test says so.
class FakeTimer implements Timer {
  FakeTimer(this.fire);
  final void Function() fire;
  var cancelled = false;
  var fired = false;

  @override
  void cancel() => cancelled = true;
  @override
  bool get isActive => !cancelled && !fired;
  @override
  int get tick => fired ? 1 : 0;

  void trigger() {
    if (cancelled) return;
    fired = true;
    fire();
  }
}

Duration ms(int n) => Duration(milliseconds: n);

void main() {
  late Recorder sink;
  late List<FakeTimer> timers;
  late RemoteTouchTracker tracker;

  void make(RemoteTouchMode mode) {
    sink = Recorder();
    timers = [];
    tracker = RemoteTouchTracker(
      sink: sink,
      mode: mode,
      timer: (after, fire) {
        final t = FakeTimer(fire);
        timers.add(t);
        return t;
      },
    );
  }

  group('trackpad mode', () {
    setUp(() => make(RemoteTouchMode.trackpad));

    test('a tap is a left click at the cursor', () {
      tracker.down(1, 100, 100, ms(0));
      tracker.up(1, ms(80));
      expect(sink.log, ['click ${CsrdButton.left}']);
      // The long press that was waiting is cancelled.
      expect(timers.single.cancelled, isTrue);
    });

    test('a tap that wobbles within the slop is still a tap', () {
      tracker.down(1, 100, 100, ms(0));
      tracker.move(1, 104, 103, ms(20));
      tracker.up(1, ms(60));
      expect(sink.log, ['click ${CsrdButton.left}']);
    });

    test('dragging moves the cursor by the finger\'s movement', () {
      tracker.down(1, 100, 100, ms(0));
      tracker.move(1, 130, 100, ms(16));
      tracker.move(1, 150, 110, ms(32));
      tracker.up(1, ms(48));
      // The first move crosses the slop and starts the drag; what follows
      // is the movement from event to event.
      expect(sink.log, ['rel 20,10']);
      expect(timers.single.cancelled, isTrue);
    });

    test('moving the cursor is not a click', () {
      tracker.down(1, 0, 0, ms(0));
      tracker.move(1, 50, 0, ms(10));
      tracker.up(1, ms(20));
      expect(sink.log.where((l) => l.startsWith('click')), isEmpty);
    });

    test('holding still then dragging drags with the left button down', () {
      tracker.down(1, 100, 100, ms(0));
      timers.single.trigger();
      expect(sink.log, ['haptic', 'button ${CsrdButton.left} down']);
      tracker.move(1, 140, 100, ms(500));
      tracker.up(1, ms(700));
      expect(sink.log.skip(2), ['rel 40,0', 'button ${CsrdButton.left} up']);
    });

    test('holding still then lifting is a held click, not a tap', () {
      tracker.down(1, 100, 100, ms(0));
      timers.single.trigger();
      tracker.up(1, ms(600));
      expect(sink.log, [
        'haptic',
        'button ${CsrdButton.left} down',
        'button ${CsrdButton.left} up',
      ]);
    });

    test('a long press does not fire once the finger has moved', () {
      tracker.down(1, 100, 100, ms(0));
      tracker.move(1, 150, 100, ms(100));
      expect(timers.single.cancelled, isTrue);
      timers.single.trigger();
      expect(sink.log, isNot(contains('haptic')));
    });

    test('two fingers tapped together are a right click', () {
      tracker.down(1, 100, 100, ms(0));
      tracker.down(2, 200, 100, ms(10));
      tracker.up(1, ms(90));
      tracker.up(2, ms(95));
      expect(sink.log, ['click ${CsrdButton.right}']);
    });

    test('two fingers resting too long are not a tap', () {
      tracker.down(1, 100, 100, ms(0));
      tracker.down(2, 200, 100, ms(10));
      tracker.up(1, ms(600));
      tracker.up(2, ms(610));
      expect(sink.log, isEmpty);
    });

    test(
      'two fingers dragging together scroll, with the first slop included',
      () {
        tracker.down(1, 100, 100, ms(0));
        tracker.down(2, 200, 100, ms(5));
        tracker.move(1, 100, 116, ms(16));
        // Nothing yet: the midpoint has moved 8, inside the slop.
        expect(sink.log, isEmpty);
        tracker.move(2, 200, 116, ms(17));
        expect(sink.log, ['scroll 0,16']);
        tracker.move(1, 100, 126, ms(32));
        tracker.move(2, 200, 126, ms(33));
        expect(sink.log.skip(1), ['scroll 0,5', 'scroll 0,5']);
        tracker.up(1, ms(60));
        tracker.up(2, ms(65));
        expect(sink.log.where((l) => l.startsWith('click')), isEmpty);
      },
    );

    test('two fingers moving apart pinch', () {
      tracker.down(1, 100, 100, ms(0));
      tracker.down(2, 200, 100, ms(5));
      tracker.move(1, 70, 100, ms(16));
      tracker.move(2, 230, 100, ms(17));
      // 100 apart to 160 apart, midpoint unmoved.
      expect(sink.log.where((l) => l.startsWith('pinch')), isNotEmpty);
      expect(sink.log.where((l) => l.startsWith('scroll')), isEmpty);
      final factors = [
        for (final l in sink.log)
          if (l.startsWith('pinch')) double.parse(l.substring(6)),
      ];
      var product = 1.0;
      for (final f in factors) {
        product *= f;
      }
      expect(product, closeTo(1.6, 0.02));
    });

    test('a scroll that drifts apart stays a scroll', () {
      tracker.down(1, 100, 100, ms(0));
      tracker.down(2, 200, 100, ms(5));
      tracker.move(1, 100, 140, ms(16));
      tracker.move(2, 204, 140, ms(17));
      tracker.move(1, 100, 180, ms(32));
      tracker.move(2, 212, 180, ms(33));
      expect(sink.log.where((l) => l.startsWith('pinch')), isEmpty);
      expect(sink.log.where((l) => l.startsWith('scroll')), isNotEmpty);
    });

    test('a pinch also pans with its midpoint', () {
      tracker.down(1, 100, 100, ms(0));
      tracker.down(2, 200, 100, ms(5));
      tracker.move(1, 60, 100, ms(16));
      tracker.move(2, 240, 100, ms(17));
      tracker.move(1, 60, 120, ms(32));
      tracker.move(2, 240, 120, ms(33));
      expect(sink.log.where((l) => l.startsWith('pan')), isNotEmpty);
    });

    test('three fingers pan the view', () {
      tracker.down(1, 100, 100, ms(0));
      tracker.down(2, 200, 100, ms(1));
      tracker.down(3, 150, 200, ms(2));
      tracker.move(1, 130, 100, ms(16));
      tracker.move(2, 230, 100, ms(17));
      tracker.move(3, 180, 200, ms(18));
      expect(sink.log.where((l) => l.startsWith('pan')), isNotEmpty);
      var dx = 0;
      for (final l in sink.log) {
        if (l.startsWith('pan')) dx += int.parse(l.substring(4).split(',')[0]);
      }
      expect(dx, 30);
    });

    test('a finger left after a gesture does not start another', () {
      tracker.down(1, 100, 100, ms(0));
      tracker.down(2, 200, 100, ms(5));
      tracker.move(1, 100, 160, ms(16));
      tracker.move(2, 200, 160, ms(17));
      tracker.up(1, ms(40));
      sink.log.clear();
      // The remaining finger would otherwise lurch the cursor.
      tracker.move(2, 200, 260, ms(60));
      tracker.up(2, ms(80));
      expect(sink.log, isEmpty);
      // And once everything is up, a new tap works again.
      tracker.down(3, 10, 10, ms(200));
      tracker.up(3, ms(250));
      expect(sink.log, ['click ${CsrdButton.left}']);
    });

    test('a second finger during a held drag lets go of the button', () {
      tracker.down(1, 100, 100, ms(0));
      timers.single.trigger();
      sink.log.clear();
      tracker.down(2, 200, 100, ms(600));
      expect(sink.log, ['button ${CsrdButton.left} up']);
      tracker.up(2, ms(700));
      tracker.up(1, ms(710));
      expect(sink.log, ['button ${CsrdButton.left} up']);
    });

    test('a cancelled touch never leaves the button held', () {
      tracker.down(1, 100, 100, ms(0));
      timers.single.trigger();
      sink.log.clear();
      tracker.cancel(1);
      expect(sink.log, ['button ${CsrdButton.left} up']);
      expect(tracker.active, isFalse);
    });

    test('reset lets go of everything', () {
      tracker.down(1, 100, 100, ms(0));
      timers.single.trigger();
      sink.log.clear();
      tracker.reset();
      expect(sink.log, ['button ${CsrdButton.left} up']);
      tracker.up(1, ms(10)); // late event for a finger already forgotten
      expect(sink.log, hasLength(1));
    });
  });

  group('direct mode', () {
    setUp(() => make(RemoteTouchMode.direct));

    test('a tap is a left click where it landed', () {
      tracker.down(1, 120, 80, ms(0));
      tracker.up(1, ms(60));
      expect(sink.log, ['at 120,80', 'click ${CsrdButton.left}']);
    });

    test('a drag presses where it landed and follows the finger', () {
      tracker.down(1, 100, 100, ms(0));
      tracker.move(1, 130, 100, ms(16));
      tracker.move(1, 160, 120, ms(32));
      tracker.up(1, ms(48));
      expect(sink.log, [
        'at 100,100',
        'button ${CsrdButton.left} down',
        'at 130,100',
        'at 160,120',
        'at 160,120',
        'button ${CsrdButton.left} up',
      ]);
    });

    test('holding still is a right click', () {
      tracker.down(1, 100, 100, ms(0));
      timers.single.trigger();
      expect(sink.log, ['haptic', 'at 100,100', 'click ${CsrdButton.right}']);
      sink.log.clear();
      // Lifting afterwards does not also click.
      tracker.up(1, ms(600));
      expect(sink.log, isEmpty);
    });

    test('two fingers tapped together right-click between them', () {
      tracker.down(1, 100, 100, ms(0));
      tracker.down(2, 200, 140, ms(10));
      tracker.up(1, ms(80));
      expect(sink.log, ['at 150,120', 'click ${CsrdButton.right}']);
    });

    test('two fingers still scroll', () {
      tracker.down(1, 100, 100, ms(0));
      tracker.down(2, 200, 100, ms(5));
      tracker.move(1, 100, 150, ms(16));
      tracker.move(2, 200, 150, ms(17));
      expect(sink.log.where((l) => l.startsWith('scroll')), isNotEmpty);
    });
  });
}
