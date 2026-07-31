import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/reconnect_policy.dart';

/// Runs [policy] the way [SessionReconnector] does — ask for a delay, start
/// an attempt, report a failure — and returns every delay it handed out.
///
/// The point of the policy being pure is that the whole two-minute schedule
/// can be exercised in a microsecond, which is what this does.
List<Duration> runToExhaustion(
  ReconnectPolicy policy, {
  ReconnectFailure failure = ReconnectFailure.transport,
}) {
  final delays = <Duration>[];
  while (true) {
    final delay = policy.nextDelay();
    if (delay == null) return delays;
    delays.add(delay);
    policy.attemptStarted();
    policy.failed(failure);
    if (policy.isFinished) return delays;
  }
}

void main() {
  group('a fresh policy', () {
    test('is idle, with nothing to explain', () {
      final policy = ReconnectPolicy();

      expect(policy.phase, ReconnectPhase.idle);
      expect(policy.attempts, 0);
      expect(policy.isActive, isFalse);
      expect(policy.isFinished, isFalse);
      expect(policy.stopReason, isNull);
    });
  });

  group('the backoff ladder', () {
    test('doubles, then caps, then runs out of budget', () {
      final policy = ReconnectPolicy();

      expect(
        runToExhaustion(policy),
        const [
          Duration(seconds: 2),
          Duration(seconds: 4),
          Duration(seconds: 8),
          Duration(seconds: 16),
          Duration(seconds: 30),
          // Capped: the last entry repeats rather than growing.
          Duration(seconds: 30),
          Duration(seconds: 30),
        ],
      );
      expect(policy.phase, ReconnectPhase.givenUp);
    });

    test('spends no more waiting than its budget allows', () {
      final policy = ReconnectPolicy();

      final delays = runToExhaustion(policy);
      final total = delays.fold(Duration.zero, (sum, d) => sum + d);

      expect(total, ReconnectPolicy.defaultBudget);
      expect(total, lessThanOrEqualTo(ReconnectPolicy.defaultBudget));
      expect(policy.scheduledDelay, total);
    });

    test('never waits past the budget rather than trimming a last delay', () {
      // 2 + 4 = 6 fits; the 8 that would follow does not, and is not
      // shortened to fit — a schedule that ends is better than one that
      // pretends.
      final policy = ReconnectPolicy(budget: const Duration(seconds: 10));

      expect(
        runToExhaustion(policy),
        const [Duration(seconds: 2), Duration(seconds: 4)],
      );
      expect(policy.scheduledDelay, const Duration(seconds: 6));
    });

    test('counts the attempts it actually made', () {
      final policy = ReconnectPolicy();

      runToExhaustion(policy);

      expect(policy.attempts, 7);
      expect(policy.stopReason, contains('7 attempts'));
    });

    test('honours a custom ladder', () {
      final policy = ReconnectPolicy(
        backoff: const [Duration(seconds: 1)],
        budget: const Duration(seconds: 3),
      );

      expect(runToExhaustion(policy), const [
        Duration(seconds: 1),
        Duration(seconds: 1),
        Duration(seconds: 1),
      ]);
    });

    test('reports waiting between attempts and connecting during one', () {
      final policy = ReconnectPolicy();

      policy.nextDelay();
      expect(policy.phase, ReconnectPhase.waiting);
      expect(policy.isActive, isTrue);

      policy.attemptStarted();
      expect(policy.phase, ReconnectPhase.connecting);
      expect(policy.isActive, isTrue);
      expect(policy.attempts, 1);
    });

    test('stays "connecting" between a transient failure and the next wait',
        () {
      // The banner should not flicker back to a different wording in the gap
      // between an attempt failing and the next one being scheduled.
      final policy = ReconnectPolicy();
      policy.nextDelay();
      policy.attemptStarted();

      policy.failed(ReconnectFailure.transport);

      expect(policy.phase, ReconnectPhase.connecting);
      expect(policy.isFinished, isFalse);
    });
  });

  group('failures that must never loop', () {
    test('an auth failure stops the schedule after one attempt', () {
      final policy = ReconnectPolicy();

      final delays = runToExhaustion(
        policy,
        failure: ReconnectFailure.authentication,
      );

      expect(delays, const [Duration(seconds: 2)]);
      expect(policy.attempts, 1);
      expect(policy.phase, ReconnectPhase.givenUp);
      expect(policy.isFinished, isTrue);
    });

    test('an auth failure says why, in terms of the account', () {
      final policy = ReconnectPolicy();
      policy.nextDelay();
      policy.attemptStarted();

      policy.failed(ReconnectFailure.authentication);

      expect(policy.stopReason, contains('rejected the saved credentials'));
      expect(policy.stopReason, contains('lock the account out'));
    });

    test('a host-key failure stops the schedule after one attempt', () {
      final policy = ReconnectPolicy();

      final delays = runToExhaustion(
        policy,
        failure: ReconnectFailure.hostKey,
      );

      expect(delays, const [Duration(seconds: 2)]);
      expect(policy.attempts, 1);
      expect(policy.phase, ReconnectPhase.givenUp);
    });

    test('missing credentials stop the schedule after one attempt', () {
      final policy = ReconnectPolicy();

      final delays = runToExhaustion(
        policy,
        failure: ReconnectFailure.noCredentials,
      );

      expect(delays, const [Duration(seconds: 2)]);
      expect(policy.phase, ReconnectPhase.givenUp);
      expect(policy.stopReason, contains('No saved credentials'));
    });

    test('a caller-supplied message wins over the stock one', () {
      final policy = ReconnectPolicy();
      policy.nextDelay();
      policy.attemptStarted();

      policy.failed(ReconnectFailure.hostKey, message: 'The key CHANGED.');

      expect(policy.stopReason, 'The key CHANGED.');
    });

    test('a finished policy hands out no more delays', () {
      final policy = ReconnectPolicy();
      policy.nextDelay();
      policy.attemptStarted();
      policy.failed(ReconnectFailure.authentication);

      expect(policy.nextDelay(), isNull);
      expect(policy.attempts, 1, reason: 'and starts no more attempts');
    });

    test('a finished policy ignores a later failure report', () {
      final policy = ReconnectPolicy();
      policy.nextDelay();
      policy.attemptStarted();
      policy.failed(ReconnectFailure.authentication);
      final reason = policy.stopReason;

      // An attempt already in flight when the policy stopped, reporting in
      // late, must not rewrite the explanation the user is reading.
      policy.failed(ReconnectFailure.transport);

      expect(policy.stopReason, reason);
      expect(policy.phase, ReconnectPhase.givenUp);
    });
  });

  group('success', () {
    test('ends the schedule and clears any explanation', () {
      final policy = ReconnectPolicy();
      policy.nextDelay();
      policy.attemptStarted();
      policy.failed(ReconnectFailure.transport);
      policy.nextDelay();
      policy.attemptStarted();

      policy.succeeded();

      expect(policy.phase, ReconnectPhase.connected);
      expect(policy.isFinished, isTrue);
      expect(policy.isActive, isFalse);
      expect(policy.stopReason, isNull);
      expect(policy.attempts, 2);
    });

    test('cannot be undone by a stop arriving afterwards', () {
      final policy = ReconnectPolicy();
      policy.nextDelay();
      policy.attemptStarted();
      policy.succeeded();

      policy.stop();

      expect(policy.phase, ReconnectPhase.connected);
    });
  });

  group('the user stopping it', () {
    test('is not a failure and explains nothing', () {
      final policy = ReconnectPolicy();
      policy.nextDelay();

      policy.stop();

      expect(policy.phase, ReconnectPhase.stopped);
      expect(policy.isFinished, isTrue);
      expect(policy.isActive, isFalse);
      expect(policy.stopReason, isNull);
    });

    test('stops the ladder dead', () {
      final policy = ReconnectPolicy();
      policy.nextDelay();
      policy.attemptStarted();

      policy.stop();

      expect(policy.nextDelay(), isNull);
      expect(policy.phase, ReconnectPhase.stopped);
    });
  });
}
