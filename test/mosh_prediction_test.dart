import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/mosh/mosh_overlay.dart';
import 'package:secure_shell_go/services/mosh/mosh_terminal.dart';

/// Mosh's local echo and its notification bar.
void main() {
  MoshFramebuffer screen(String input) {
    final fb = MoshFramebuffer(20, 4);
    MoshEmulator(fb).writeString(input);
    return fb;
  }

  String rowText(MoshFramebuffer fb, int y) => fb.rows[y].cells
      .map((c) => c.contents.isEmpty ? ' ' : c.contents)
      .join()
      .trimRight();

  group('prediction', () {
    late MoshPredictionEngine engine;
    var now = 1 << 32;

    /// What the client would draw over [server]'s screen.
    MoshFramebuffer shown(MoshFramebuffer server) {
      final fb = server.copy();
      engine
        ..cull(fb, now)
        ..apply(fb);
      return fb;
    }

    void type(String text, MoshFramebuffer onScreen, {required int frame}) {
      engine.localFrameSent = frame;
      for (final unit in text.codeUnits) {
        engine.newUserByte(unit, onScreen, now);
      }
    }

    setUp(() {
      engine = MoshPredictionEngine(mode: MoshPredictionMode.always);
      now = 1 << 32;
    });

    test('nothing is shown until a first guess has been confirmed — so a '
        'password prompt echoes nothing', () {
      final prompt = screen(r'$ ');
      type('a', prompt, frame: 0);
      expect(rowText(shown(prompt), 0), r'$');

      // The server echoes it, for an input frame at least as new.
      engine.localFrameLateAcked = 1;
      now += 40;
      final echoed = screen(r'$ a');
      expect(rowText(shown(echoed), 0), r'$ a');

      // From now on typing shows at once, before the server answers.
      type('bc', echoed, frame: 1);
      final predicted = shown(echoed);
      expect(rowText(predicted, 0), r'$ abc');
      expect(predicted.ds.cursorCol, 5);
    });

    test('a guess the server contradicts is withdrawn, with its epoch', () {
      final prompt = screen(r'$ ');
      type('a', prompt, frame: 0);
      engine.localFrameLateAcked = 1;
      final echoed = screen(r'$ a');
      shown(echoed);

      type('x', echoed, frame: 1);
      expect(rowText(shown(echoed), 0), r'$ ax');

      // The server has seen the keystroke (echo ack 2) and did not print it.
      engine.localFrameLateAcked = 2;
      now += 40;
      expect(rowText(shown(echoed), 0), r'$ a');
    });

    test('a slow link underlines guesses until they are confirmed', () {
      engine.sendInterval = 100;
      final prompt = screen(r'$ ');
      type('a', prompt, frame: 0);
      engine.localFrameLateAcked = 1;
      final echoed = screen(r'$ a');
      shown(echoed);

      type('b', echoed, frame: 1);
      final predicted = shown(echoed);
      expect(predicted.rows[0].cells[3].contents, 'b');
      expect(
        predicted.rows[0].cells[3].renditions
            .attribute(MoshRenditions.underlined),
        isTrue,
      );
    });

    test('backspace is predicted too', () {
      final prompt = screen(r'$ ab');
      type('c', prompt, frame: 0);
      engine.localFrameLateAcked = 1;
      final echoed = screen(r'$ abc');
      shown(echoed);

      type('\x7f', echoed, frame: 1);
      expect(rowText(shown(echoed), 0), r'$ ab');
    });

    test('on a fast link, adaptive mode shows nothing', () {
      engine = MoshPredictionEngine()..sendInterval = 20;
      final prompt = screen(r'$ ');
      type('a', prompt, frame: 0);
      engine.localFrameLateAcked = 1;
      final echoed = screen(r'$ a');
      shown(echoed);
      type('b', echoed, frame: 1);
      expect(rowText(shown(echoed), 0), r'$ a');
    });

    test('never means never', () {
      engine = MoshPredictionEngine(mode: MoshPredictionMode.never);
      final prompt = screen(r'$ ');
      type('a', prompt, frame: 0);
      engine.localFrameLateAcked = 1;
      shown(screen(r'$ a'));
      type('b', screen(r'$ a'), frame: 1);
      expect(rowText(shown(screen(r'$ a')), 0), r'$ a');
    });
  });

  group('notification bar', () {
    test('appears once the server has been silent for 6.5 s, and counts', () {
      const now = 1 << 32;
      final engine = MoshNotificationEngine(now);
      final fb = screen('hello');

      final quiet = fb.copy();
      engine.apply(quiet, now + 6000);
      expect(rowText(quiet, 0), 'hello');

      final late = fb.copy();
      engine.apply(late, now + 12000);
      expect(rowText(late, 0), 'mosh: Last contact 1');
      expect(late.rows[0].cells[0].renditions.background, 44);
      expect(engine.isLate(now + 12000), isTrue);

      final longer = MoshFramebuffer(60, 2);
      engine.apply(longer, now + 125000);
      expect(rowText(longer, 0), 'mosh: Last contact 2:05 ago.');

      engine
        ..serverHeard(now + 125000)
        ..serverAcked(now + 125000);
      expect(engine.isLate(now + 125500), isFalse);
    });
  });
}
