import 'package:flutter_test/flutter_test.dart';

/// Waiting in widget tests for work that runs on the real event loop — file
/// writes, `chmod`, encryption — which a fake clock does not move.
///
/// `testWidgets` runs on a fake clock, so an `await` on a file completes
/// only once the real event loop has turned *and* the test's own microtask
/// queue has been flushed; [settleIo] alternates the two. A fixed number of
/// turns is not enough on a loaded machine: the suites that save hosts and
/// credentials passed alone and failed in the full run, so the helpers below
/// wait on a condition, against a real-time limit, instead.

/// Turns both event loops [rounds] times.
Future<void> settleIo(WidgetTester tester, {int rounds = 40}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

/// Runs [checks] on the real event loop until they pass, turning both loops
/// between tries, for up to [timeout] of real time; then fails with the last
/// failure, plus whatever [describe] adds about the screen.
///
/// The failure is caught inside `runAsync` and rethrown out here: `runAsync`
/// reports anything its callback throws as a test failure on the spot, so a
/// retry around it would never get to retry. A check that something was
/// *not* written passes on its first try, as it would have with a fixed wait.
Future<void> checkEventually(
  WidgetTester tester,
  Future<void> Function() checks, {
  Duration timeout = const Duration(seconds: 30),
  String Function()? describe,
}) async {
  final clock = Stopwatch()..start();
  while (true) {
    Object? failure;
    StackTrace? failureStack;
    await tester.runAsync(() async {
      try {
        await checks();
      } catch (e, stack) {
        failure = e;
        failureStack = stack;
      }
    });
    if (failure == null) return;
    if (clock.elapsed > timeout) {
      final context = describe?.call();
      Error.throwWithStackTrace(
        context == null ? failure! : TestFailure('$failure\n$context'),
        failureStack!,
      );
    }
    await settleIo(tester, rounds: 10);
  }
}

/// Turns both event loops until [condition] holds or [timeout] of real time
/// passes — for what the screen shows once background work has finished.
/// The expectation that follows says whether it did.
Future<void> settleUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final clock = Stopwatch()..start();
  while (!condition() && clock.elapsed < timeout) {
    await settleIo(tester, rounds: 10);
  }
}
