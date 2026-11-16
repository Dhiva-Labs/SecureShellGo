import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/bridge/bridge_grants.dart';

import 'support/bridge_fake_time.dart';

void main() {
  late FakeTime time;
  late BridgeGrants grants;

  setUp(() {
    time = FakeTime();
    grants = BridgeGrants(clock: time.clock, timer: time.timer);
  });

  test('a grant is live until, and not at, its expiry', () {
    grants.grant('c1', 'hA', const Duration(minutes: 5));
    expect(grants.hasLive('c1', 'hA'), isTrue);
    time.now = time.now.add(
      const Duration(minutes: 5) - const Duration(microseconds: 1),
    );
    expect(grants.hasLive('c1', 'hA'), isTrue);
    time.now = time.now.add(const Duration(microseconds: 1));
    // Exactly at the boundary, before the timer has run: already gone.
    expect(grants.hasLive('c1', 'hA'), isFalse);
    expect(grants.current, isEmpty);
  });

  test('the expiry timer removes it and tells listeners', () async {
    final seen = <int>[];
    final sub = grants.changes.listen((l) => seen.add(l.length));
    grants.grant('c1', 'hA', const Duration(minutes: 5));
    time.advance(const Duration(minutes: 5));
    await Future<void>.delayed(Duration.zero);
    expect(seen, [0, 1, 0]);
    expect(time.activeTimers, 0);
    await sub.cancel();
  });

  test('a grant for one client is not usable by another', () {
    grants.grant('c1', 'hA', const Duration(minutes: 5));
    expect(grants.hasLive('c2', 'hA'), isFalse);
  });

  test('a grant for host A does not cover host B', () {
    grants.grant('c1', 'hA', const Duration(minutes: 5));
    expect(grants.hasLive('c1', 'hB'), isFalse);
  });

  test('granting again replaces the expiry', () {
    grants.grant('c1', 'hA', const Duration(minutes: 60));
    grants.grant('c1', 'hA', const Duration(minutes: 5));
    expect(grants.current, hasLength(1));
    time.advance(const Duration(minutes: 5));
    expect(grants.hasLive('c1', 'hA'), isFalse);
    expect(time.activeTimers, 0);
  });

  test('a zero or negative duration grants nothing', () {
    expect(grants.grant('c1', 'hA', Duration.zero), isNull);
    expect(grants.grant('c1', 'hA', const Duration(seconds: -1)), isNull);
    expect(grants.hasLive('c1', 'hA'), isFalse);
  });

  test('revokeClient, revokeHost, retainHosts, revoke', () {
    grants.grant('c1', 'hA', const Duration(minutes: 5));
    grants.grant('c1', 'hB', const Duration(minutes: 5));
    grants.grant('c2', 'hA', const Duration(minutes: 5));
    grants.grant('c2', 'hC', const Duration(minutes: 5));
    grants.revokeClient('c1');
    expect(grants.hasLive('c1', 'hA'), isFalse);
    expect(grants.hasLive('c1', 'hB'), isFalse);
    expect(grants.hasLive('c2', 'hA'), isTrue);
    grants.revokeHost('hA');
    expect(grants.hasLive('c2', 'hA'), isFalse);
    expect(grants.hasLive('c2', 'hC'), isTrue);
    grants.grant('c2', 'hD', const Duration(minutes: 5));
    grants.retainHosts({'hD'});
    expect(grants.hasLive('c2', 'hC'), isFalse);
    expect(grants.hasLive('c2', 'hD'), isTrue);
    grants.revoke('c2', 'hD');
    expect(grants.current, isEmpty);
    expect(time.activeTimers, 0);
  });

  test('revokeClientsExcept keeps only paired clients', () {
    grants.grant('c1', 'hA', const Duration(minutes: 5));
    grants.grant('c2', 'hA', const Duration(minutes: 5));
    grants.revokeClientsExcept({'c2'});
    expect(grants.hasLive('c1', 'hA'), isFalse);
    expect(grants.hasLive('c2', 'hA'), isTrue);
  });

  test('revokeAll (bridge off, app lock) ends every grant', () async {
    final seen = <int>[];
    final sub = grants.changes.listen((l) => seen.add(l.length));
    grants.grant('c1', 'hA', const Duration(minutes: 5));
    grants.grant('c2', 'hB', const Duration(minutes: 15));
    grants.revokeAll();
    await Future<void>.delayed(Duration.zero);
    expect(grants.current, isEmpty);
    expect(seen, [0, 1, 2, 0]);
    expect(time.activeTimers, 0);
    await sub.cancel();
  });

  test('current lists live grants oldest first with remaining time', () {
    grants.grant('c1', 'hA', const Duration(minutes: 5), hostName: 'web');
    time.advance(const Duration(minutes: 1));
    grants.grant('c1', 'hB', const Duration(minutes: 15));
    final list = grants.current;
    expect(list.map((g) => g.hostId), ['hA', 'hB']);
    expect(list.first.hostName, 'web');
    expect(list.first.remainingAt(time.now), const Duration(minutes: 4));
    expect(
      list.first.remainingAt(time.now.add(const Duration(hours: 1))),
      Duration.zero,
    );
  });

  test('dispose ends grants and closes the stream', () async {
    grants.grant('c1', 'hA', const Duration(minutes: 5));
    final done = Completer<void>();
    grants.changes.listen((_) {}, onDone: done.complete);
    await grants.dispose();
    await done.future;
    expect(grants.hasLive('c1', 'hA'), isFalse);
    expect(grants.grant('c1', 'hA', const Duration(minutes: 5)), isNull);
  });
}
