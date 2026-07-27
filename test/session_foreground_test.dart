import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/session_foreground.dart';

/// Records what the platform was asked to do, in order.
///
/// The Kotlin side is not testable here and does not need to be — it is a
/// notification and two lifecycle calls. What is worth testing is the
/// *decision*: when the service should start, when it should stop, and which
/// sequences of route lifecycles must not produce either.
class FakeForegroundChannel implements SessionForegroundChannel {
  FakeForegroundChannel({this.failWith});

  /// Simulates the platform refusing (a background-start restriction).
  final Object? failWith;

  final List<String> calls = [];
  final List<String> labels = [];

  /// When set, [start] parks until it is completed, so tests can interleave.
  Completer<void>? gate;

  @override
  Future<void> start(String label) async {
    calls.add('start');
    labels.add(label);
    final gate = this.gate;
    if (gate != null) await gate.future;
    if (failWith != null) throw failWith!;
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    if (failWith != null) throw failWith!;
  }
}

void main() {
  group('the start/stop decision', () {
    test('the first session starts the service, named after the host',
        () async {
      final channel = FakeForegroundChannel();
      final controller = SessionForegroundController(channel: channel);

      await controller.acquire('MyLinuxPC');

      expect(channel.calls, ['start']);
      expect(channel.labels, ['MyLinuxPC']);
      expect(controller.isRunning, isTrue);
      expect(controller.holders, 1);
    });

    test('the last session stops it', () async {
      final channel = FakeForegroundChannel();
      final controller = SessionForegroundController(channel: channel);

      await controller.acquire('MyLinuxPC');
      await controller.release();

      expect(channel.calls, ['start', 'stop']);
      expect(controller.isRunning, isFalse);
      expect(controller.holders, isZero);
    });

    test('a second session does not start a second service', () async {
      final channel = FakeForegroundChannel();
      final controller = SessionForegroundController(channel: channel);

      await controller.acquire('MyLinuxPC');
      await controller.acquire('build-box');

      expect(channel.calls, ['start']);
      expect(controller.holders, 2);
    });

    test('the notification keeps naming the session that opened first',
        () async {
      final channel = FakeForegroundChannel();
      final controller = SessionForegroundController(channel: channel);

      await controller.acquire('MyLinuxPC');
      await controller.acquire('build-box');

      expect(channel.labels, ['MyLinuxPC']);
    });

    test('releasing one of two sessions leaves the service running', () async {
      final channel = FakeForegroundChannel();
      final controller = SessionForegroundController(channel: channel);

      await controller.acquire('MyLinuxPC');
      await controller.acquire('build-box');
      await controller.release();

      expect(channel.calls, ['start']);
      expect(controller.isRunning, isTrue);
      expect(controller.holders, 1);

      await controller.release();
      expect(channel.calls, ['start', 'stop']);
      expect(controller.isRunning, isFalse);
    });

    test('a route pushed over another never stops the live one', () async {
      // The ordering that would break a plain boolean: Flutter runs the new
      // route's initState before the old route's dispose, so the sequence is
      // acquire, acquire, release — and the service must still be up.
      final channel = FakeForegroundChannel();
      final controller = SessionForegroundController(channel: channel);

      await controller.acquire('first');
      await controller.acquire('second');
      await controller.release();

      expect(channel.calls, ['start']);
      expect(controller.isRunning, isTrue);
    });
  });

  group('releases that should do nothing', () {
    test('a release with nothing held is ignored', () async {
      final channel = FakeForegroundChannel();
      final controller = SessionForegroundController(channel: channel);

      await controller.release();

      expect(channel.calls, isEmpty);
      expect(controller.holders, isZero);
    });

    test('an extra release cannot drive the count negative', () async {
      final channel = FakeForegroundChannel();
      final controller = SessionForegroundController(channel: channel);

      await controller.acquire('MyLinuxPC');
      await controller.release();
      await controller.release();

      // Two stops would be harmless; a *negative* count would not — the next
      // acquire would fail to reach the 0 → 1 edge and the session would run
      // with no service behind it.
      expect(channel.calls, ['start', 'stop']);
      expect(controller.holders, isZero);

      await controller.acquire('MyLinuxPC');
      expect(channel.calls, ['start', 'stop', 'start']);
    });
  });

  group('ordering and failure', () {
    test('a release chases a slow start rather than overtaking it', () async {
      // A session that drops immediately after connecting would otherwise
      // deliver stop-then-start and strand an ongoing notification with no
      // connection behind it.
      final channel = FakeForegroundChannel()..gate = Completer<void>();
      final controller = SessionForegroundController(channel: channel);

      final acquired = controller.acquire('MyLinuxPC');
      // Let the start reach the platform and park on the gate.
      await Future<void>.delayed(Duration.zero);
      expect(channel.calls, ['start']);

      final released = controller.release();
      await Future<void>.delayed(Duration.zero);

      expect(channel.calls, ['start'], reason: 'stop must wait its turn');

      channel.gate!.complete();
      await acquired;
      await released;

      expect(channel.calls, ['start', 'stop']);
      expect(controller.isRunning, isFalse);
    });

    test('a platform refusal does not poison later calls', () async {
      final channel = FakeForegroundChannel(failWith: StateError('no dice'));
      final controller = SessionForegroundController(channel: channel);

      await controller.acquire('MyLinuxPC');
      await controller.release();
      await controller.acquire('MyLinuxPC');

      // The service is what keeps the process alive; the session works either
      // way, so a refusal must not take the whole chain down with it.
      expect(channel.calls, ['start', 'stop', 'start']);
    });
  });

  test('the shared instance exists, since the service is process-wide', () {
    expect(SessionForegroundController.instance, isNotNull);
    expect(SessionForegroundController.instance.holders, isZero);
  });
}
