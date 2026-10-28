import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/remote_desktop/csrd_messages.dart';
import 'package:secure_shell_go/services/remote_desktop/remote_input.dart';

/// The pure input pieces, tested against the cases `input.rs` tests for its
/// own limiter and accumulator, plus the Flutter-specific parts: button bits
/// and which way Flutter's two kinds of scrolling point.
void main() {
  group('buttons', () {
    test('the copied Flutter bits are Flutter\'s', () {
      expect(FlutterButtons.primary, kPrimaryButton);
      expect(FlutterButtons.secondary, kSecondaryButton);
      expect(FlutterButtons.middle, kMiddleMouseButton);
      expect(FlutterButtons.back, kBackMouseButton);
      expect(FlutterButtons.forward, kForwardMouseButton);
    });

    test('Flutter\'s bit order is mapped to the wire\'s numbers', () {
      expect(csrdButtonForFlutterBit(kPrimaryButton), CsrdButton.left);
      expect(csrdButtonForFlutterBit(kSecondaryButton), CsrdButton.right);
      expect(csrdButtonForFlutterBit(kMiddleMouseButton), CsrdButton.middle);
      expect(csrdButtonForFlutterBit(kBackMouseButton), CsrdButton.back);
      expect(csrdButtonForFlutterBit(kForwardMouseButton), CsrdButton.forward);
      // A stylus barrel button has no wire button.
      expect(csrdButtonForFlutterBit(kPrimaryStylusButton | 0x20), isNull);
      expect(csrdButtonForFlutterBit(0x40), isNull);
      expect(csrdButtonForFlutterBit(0), isNull);
    });

    test('changes are the difference of two masks, releases first', () {
      expect(remoteButtonChanges(0, kPrimaryButton), [
        const RemoteButtonChange(CsrdButton.left, down: true),
      ]);
      expect(remoteButtonChanges(kPrimaryButton, 0), [
        const RemoteButtonChange(CsrdButton.left, down: false),
      ]);
      expect(remoteButtonChanges(kPrimaryButton, kPrimaryButton), isEmpty);
      // Left held, right pressed: only the right is new.
      expect(
        remoteButtonChanges(kPrimaryButton, kPrimaryButton | kSecondaryButton),
        [const RemoteButtonChange(CsrdButton.right, down: true)],
      );
      // Left swapped for middle in one event: let go before pressing.
      expect(remoteButtonChanges(kPrimaryButton, kMiddleMouseButton), [
        const RemoteButtonChange(CsrdButton.left, down: false),
        const RemoteButtonChange(CsrdButton.middle, down: true),
      ]);
      // Bits the wire has no button for change nothing.
      expect(remoteButtonChanges(0, 0x40), isEmpty);
    });
  });

  group('MoveLimiter', () {
    Duration ms(int n) => Duration(milliseconds: n);

    test('sends the first, holds the rest, then flushes the latest', () {
      final l = MoveLimiter();
      expect(l.push(ms(0), (1, 1)), (1, 1));
      // Too soon: held, the latest wins.
      expect(l.push(ms(2), (2, 2)), isNull);
      expect(l.push(ms(4), (3, 3)), isNull);
      expect(l.deadline, ms(8));
      expect(l.flushDue(ms(5)), isNull);
      expect(l.flushDue(ms(8)), (3, 3));
      expect(l.flushDue(ms(30)), isNull);
      expect(l.deadline, isNull);
      // After the interval a new move goes out at once.
      expect(l.push(ms(30), (9, 9)), (9, 9));
    });

    test('drops repeats and sends the held move before a click', () {
      final l = MoveLimiter();
      expect(l.push(ms(0), (5, 5)), (5, 5));
      expect(l.push(ms(20), (5, 5)), isNull); // the same place
      expect(l.push(ms(21), (6, 6)), (6, 6));
      expect(l.push(ms(22), (7, 7)), isNull);
      expect(l.force(ms(23), (7, 7)), (7, 7));
      // Moving back to the last position sent cancels a held move.
      expect(l.push(ms(25), (8, 8)), isNull);
      expect(l.push(ms(26), (7, 7)), isNull);
      expect(l.flushDue(ms(40)), isNull);
      expect(l.force(ms(30), (7, 7)), isNull);
      expect(l.force(ms(31), (1, 2)), (1, 2));
      expect(l.force(ms(32), (1, 2)), isNull);
      l.reset();
      expect(l.push(ms(41), (7, 7)), (7, 7));
    });

    test('a timer that fired takes what is held, due or not', () {
      final l = MoveLimiter();
      l.push(ms(0), (1, 1));
      l.push(ms(1), (2, 2));
      expect(l.takePending(ms(1)), (2, 2));
      expect(l.takePending(ms(2)), isNull);
    });

    test('a 1 kHz mouse for a second sends about 125 moves, never more', () {
      final l = MoveLimiter();
      var sent = 0;
      for (var i = 0; i < 1000; i++) {
        final now = ms(i);
        if (l.push(now, (i, 0)) != null) sent++;
        if (l.flushDue(now) != null) sent++;
      }
      expect(sent, inInclusiveRange(100, 130));
    });
  });

  group('ScrollAccumulator', () {
    test('a wheel notch of 40 px is 120 units, scrolling down is negative', () {
      final s = ScrollAccumulator();
      expect(s.addWheel(0, 40), (0, -120));
      expect(s.addWheel(0, -80), (0, 240));
      // Flutter: positive dx scrolls right, and so does the wire.
      expect(s.addWheel(40, 0), (120, 0));
      expect(s.addWheel(-40, 0), (-120, 0));
    });

    test('fingers move the content: down is up, and right is left', () {
      final s = ScrollAccumulator();
      expect(s.addFingers(0, 40), (0, 120));
      expect(s.addFingers(0, -20), (0, -60));
      expect(s.addFingers(40, 0), (-120, 0));
    });

    test('fractions are carried over rather than lost', () {
      final s = ScrollAccumulator();
      // 0.4 of a unit three times: 1.2, so one unit is out and 0.2 is kept.
      const step = 0.4 * 40 / 120;
      expect(s.addFingers(0, step), isNull);
      expect(s.addFingers(0, step), isNull);
      expect(s.addFingers(0, step), (0, 1));
      expect(s.addFingers(0, 0), isNull);
      s.reset();
      expect(s.addFingers(0, -20), (0, -60));
    });

    test('a huge scroll is clamped to 16 bits', () {
      final s = ScrollAccumulator();
      expect(s.addWheel(0, -1e6), (0, 32767));
      expect(s.addWheel(0, 1e6), (0, -32768));
    });
  });

  group('TrackpadAcceleration', () {
    const a = TrackpadAcceleration();

    test('a slow finger is not accelerated', () {
      // 10 px over 100 ms is 0.1 px/ms.
      expect(a.gain(10, 0, const Duration(milliseconds: 100)), 1);
    });

    test('a fast finger is multiplied, up to a cap', () {
      // 1 px/ms is a quick, deliberate swipe: about 2.2 times.
      final fast = a.gain(10, 0, const Duration(milliseconds: 10));
      expect(fast, closeTo(2.2, 0.01));
      final faster = a.gain(15, 0, const Duration(milliseconds: 10));
      expect(faster, greaterThan(fast));
      expect(faster, lessThan(3.5));
      expect(a.gain(5000, 0, const Duration(milliseconds: 10)), 3.5);
    });

    test('a zero gap between events is not an infinite speed', () {
      // 4 px in "0 ms" is read as 4 px in 4 ms: 1 px/ms, not infinity.
      final g = a.gain(4, 0, Duration.zero);
      expect(g, closeTo(2.2, 0.01));
    });
  });
}
