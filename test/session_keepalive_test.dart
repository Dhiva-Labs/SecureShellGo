import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/session_keepalive.dart';

/// A [Timer] the test fires by hand.
///
/// The alternative — letting the real `Timer.periodic` run — would mean a unit
/// test that waits half a minute per tick, so the schedule is injected instead.
/// That is the same seam-shaped trick as `SessionTransport` and
/// `RemoteFileSystem`: the thing that is hard to control in a test is the thing
/// that gets an interface.
class FakeTimer implements Timer {
  FakeTimer(this.duration, this.callback);

  final Duration duration;
  final void Function(Timer timer) callback;

  var cancelCount = 0;
  var _tick = 0;

  @override
  bool get isActive => cancelCount == 0;

  @override
  int get tick => _tick;

  @override
  void cancel() => cancelCount++;

  /// Delivers one tick, as the real timer would.
  void fire() {
    if (!isActive) {
      fail('a cancelled keep-alive timer must never fire again');
    }
    _tick++;
    callback(this);
  }
}

/// Records the schedule the keep-alive asks for, and hands back [FakeTimer]s.
class FakeScheduler {
  final List<FakeTimer> timers = [];

  Timer create(Duration interval, void Function(Timer timer) tick) {
    final timer = FakeTimer(interval, tick);
    timers.add(timer);
    return timer;
  }

  FakeTimer get only {
    expect(timers, hasLength(1));
    return timers.single;
  }
}

void main() {
  group('scheduling', () {
    test('starts one timer at the fixed interval', () {
      final scheduler = FakeScheduler();
      final keepalive = SessionKeepalive(
        ping: () async {},
        scheduler: scheduler.create,
      )..start();
      addTearDown(keepalive.stop);

      expect(scheduler.timers, hasLength(1));
      expect(scheduler.only.duration, SessionKeepalive.interval);
      expect(keepalive.isRunning, isTrue);
    });

    test('the interval is a constant, not a preference', () {
      // Pinned deliberately: this number describes the middleboxes between the
      // phone and the server, not a taste, so it must not quietly drift into
      // being a setting.
      expect(SessionKeepalive.interval, const Duration(seconds: 30));
      expect(SessionKeepalive.pingTimeout, lessThan(SessionKeepalive.interval));
    });

    test('a repeat start does not stack up a second timer', () {
      final scheduler = FakeScheduler();
      final keepalive = SessionKeepalive(
        ping: () async {},
        scheduler: scheduler.create,
      )
        ..start()
        ..start();
      addTearDown(keepalive.stop);

      expect(scheduler.timers, hasLength(1));
    });

    test('each tick sends exactly one keep-alive', () async {
      var pings = 0;
      final scheduler = FakeScheduler();
      final keepalive = SessionKeepalive(
        ping: () async => pings++,
        scheduler: scheduler.create,
      )..start();
      addTearDown(keepalive.stop);

      scheduler.only.fire();
      await Future<void>.delayed(Duration.zero);
      scheduler.only.fire();
      await Future<void>.delayed(Duration.zero);

      expect(pings, 2);
      expect(keepalive.pingCount, 2);
      expect(keepalive.skippedCount, isZero);
    });

    test('stop cancels the timer', () {
      final scheduler = FakeScheduler();
      final keepalive = SessionKeepalive(
        ping: () async {},
        scheduler: scheduler.create,
      )..start();

      keepalive.stop();

      expect(scheduler.only.isActive, isFalse);
      expect(keepalive.isRunning, isFalse);
    });

    test('stop is idempotent and start after it is a no-op', () {
      final scheduler = FakeScheduler();
      final keepalive = SessionKeepalive(
        ping: () async {},
        scheduler: scheduler.create,
      )..start();

      keepalive
        ..stop()
        ..stop()
        ..start();

      // A session ends once. Restarting the schedule on a dead transport would
      // only produce pings nobody is listening for.
      expect(scheduler.timers, hasLength(1));
      expect(keepalive.isRunning, isFalse);
    });
  });

  group('a ping that misbehaves', () {
    test('a failure does not stop later keep-alives', () async {
      var pings = 0;
      final scheduler = FakeScheduler();
      final keepalive = SessionKeepalive(
        ping: () async {
          pings++;
          throw StateError('write to a closed socket');
        },
        scheduler: scheduler.create,
      )..start();
      addTearDown(keepalive.stop);

      scheduler.only.fire();
      await Future<void>.delayed(Duration.zero);
      scheduler.only.fire();
      await Future<void>.delayed(Duration.zero);

      // Reporting is `connection.done`'s job; a keep-alive that throws must
      // not race it with a worse message, and must not disable itself either.
      expect(pings, 2);
    });

    test('a tick landing on an unanswered ping is skipped, not stacked',
        () async {
      final answers = <Completer<void>>[];
      final scheduler = FakeScheduler();
      final keepalive = SessionKeepalive(
        ping: () {
          final answer = Completer<void>();
          answers.add(answer);
          return answer.future;
        },
        scheduler: scheduler.create,
      )..start();
      addTearDown(keepalive.stop);

      scheduler.only.fire();
      await Future<void>.delayed(Duration.zero);
      scheduler.only.fire();
      await Future<void>.delayed(Duration.zero);

      expect(answers, hasLength(1), reason: 'only one ping may be in flight');
      expect(keepalive.skippedCount, 1);

      answers.single.complete();
      await Future<void>.delayed(Duration.zero);

      scheduler.only.fire();
      await Future<void>.delayed(Duration.zero);
      expect(answers, hasLength(2), reason: 'the guard must clear again');
    });

    test('a ping that never answers unblocks after the timeout', () async {
      // The bug this guards against is dartssh2's own SSHKeepAlive: its
      // in-flight flag is cleared in a `finally` after an unbounded `await`,
      // so one ping that never completes silences keep-alives forever — which
      // is exactly what a silently dropped NAT mapping looks like. Racing the
      // ping against a timeout is what stops that here; the timeout is
      // shortened so the test does not have to wait 20 s for it.
      var pings = 0;
      final scheduler = FakeScheduler();
      final keepalive = SessionKeepalive(
        ping: () {
          pings++;
          return Completer<void>().future;
        },
        scheduler: scheduler.create,
        timeout: const Duration(milliseconds: 20),
      )..start();
      addTearDown(keepalive.stop);

      scheduler.only.fire();
      await Future<void>.delayed(const Duration(milliseconds: 60));

      scheduler.only.fire();
      await Future<void>.delayed(Duration.zero);

      expect(pings, 2);
      expect(keepalive.skippedCount, isZero);
    });
  });
}
