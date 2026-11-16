import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/bridge/bridge_approvals.dart';
import 'package:secure_shell_go/services/bridge/bridge_client_store.dart';

import 'support/bridge_fake_time.dart';

BridgeClient _client(String id) => BridgeClient(
  id: id,
  name: 'Assistant $id',
  tokenHash: 'x',
  createdAt: DateTime.utc(2026),
);

void main() {
  late FakeTime time;
  late int minutes;
  late BridgeApprovals approvals;

  setUp(() {
    time = FakeTime();
    minutes = 0;
    approvals = BridgeApprovals(
      timedApprovalMinutes: () => minutes,
      clock: time.clock,
      timer: time.timer,
    );
  });

  BridgeApprovalRequest req({
    String client = 'c1',
    String host = 'h1',
    BridgeChangeSummary? summary,
  }) => approvals.request(
    client: _client(client),
    hostId: host,
    hostName: 'web',
    tool: 'run_command',
    summary: summary ?? CommandSummary(command: 'ls', hostNames: ['web']),
  );

  /// The outcome of [f] once it completes, or null while it has not.
  Future<BridgeApprovalOutcome?> settled(Future<BridgeApprovalOutcome> f) {
    BridgeApprovalOutcome? out;
    f.then((o) => out = o);
    return Future<void>.delayed(Duration.zero).then((_) => out);
  }

  test('a request is filled in from the clock, expiring in 120 s', () {
    final r = req();
    expect(r.createdAt, time.now);
    expect(r.expiresAt, time.now.add(const Duration(seconds: 120)));
    expect(req().id, isNot(r.id));
  });

  test('allow once', () async {
    final r = req();
    final f = approvals.ask(r);
    expect(approvals.current.single.id, r.id);
    approvals.answer(r.id, BridgeApprovalAnswer.allowOnce);
    expect(await f, BridgeApprovalOutcome.allowedOnce);
    expect(approvals.current, isEmpty);
  });

  test('deny', () async {
    final r = req();
    final f = approvals.ask(r);
    approvals.answer(r.id, BridgeApprovalAnswer.deny);
    expect(await f, BridgeApprovalOutcome.denied);
  });

  test('silence is no: unanswered at 120 s is timed out', () async {
    final r = req();
    final f = approvals.ask(r);
    time.advance(const Duration(seconds: 119));
    expect(await settled(f), isNull);
    time.advance(const Duration(seconds: 1));
    expect(await f, BridgeApprovalOutcome.timedOut);
    expect(approvals.current, isEmpty);
    expect(time.activeTimers, 0);
  });

  test('an answer after the timeout is ignored', () async {
    final r = req();
    final f = approvals.ask(r);
    time.advance(const Duration(seconds: 121));
    approvals.answer(r.id, BridgeApprovalAnswer.allowOnce);
    expect(await f, BridgeApprovalOutcome.timedOut);
  });

  test('an answer at the expiry instant, before the timer ran, is a '
      'timeout', () async {
    final r = req();
    final f = approvals.ask(r);
    // The clock passes the expiry without the timer having run yet.
    time.now = r.expiresAt;
    approvals.answer(r.id, BridgeApprovalAnswer.allowOnce);
    expect(await f, BridgeApprovalOutcome.timedOut);
  });

  test('a second answer is ignored; the first wins', () async {
    final r = req();
    final f = approvals.ask(r);
    approvals.answer(r.id, BridgeApprovalAnswer.deny);
    approvals.answer(r.id, BridgeApprovalAnswer.allowOnce);
    expect(await f, BridgeApprovalOutcome.denied);
  });

  test('an answer for an unknown id changes nothing', () async {
    final r = req();
    final f = approvals.ask(r);
    approvals.answer('nope', BridgeApprovalAnswer.allowOnce);
    approvals.answer('', BridgeApprovalAnswer.allowForAWhile);
    expect(await settled(f), isNull);
    expect(approvals.current.single.id, r.id);
  });

  test('withdraw, then answer: withdrawn, and the answer is ignored', () async {
    final r = req();
    final f = approvals.ask(r);
    approvals.withdraw(r.id);
    approvals.answer(r.id, BridgeApprovalAnswer.allowOnce);
    expect(await f, BridgeApprovalOutcome.withdrawn);
    expect(time.activeTimers, 0);
  });

  test('allow for a while with the setting off counts as once', () async {
    final r = req();
    final f = approvals.ask(r);
    approvals.answer(r.id, BridgeApprovalAnswer.allowForAWhile);
    final out = await f;
    expect(out, BridgeApprovalOutcome.allowedOnce);
    expect(out.grantFor, isNull);
  });

  test(
    'allow for a while carries the setting at the time of the answer',
    () async {
      final r = req();
      final f = approvals.ask(r);
      minutes = 15;
      approvals.answer(r.id, BridgeApprovalAnswer.allowForAWhile);
      final out = await f;
      expect(out.kind, BridgeApprovalOutcomeKind.allowedForAWhile);
      expect(out.grantFor, const Duration(minutes: 15));
      expect(out.allowed, isTrue);
    },
  );

  test('allow for a while never covers a terminal', () async {
    minutes = 60;
    final r = req(summary: const TerminalSummary());
    final f = approvals.ask(r);
    approvals.answer(r.id, BridgeApprovalAnswer.allowForAWhile);
    expect(await f, BridgeApprovalOutcome.allowedOnce);
  });

  test('a 9th pending request is refused at once as busy', () async {
    // Three clients, none past its own cap of 3: only the global cap bites.
    final waiting = [
      for (var i = 0; i < 8; i++) approvals.ask(req(client: 'c${i ~/ 3}')),
    ];
    expect(approvals.current, hasLength(8));
    final ninth = req(client: 'c2');
    expect(await approvals.ask(ninth), BridgeApprovalOutcome.busy);
    expect(approvals.current, hasLength(8));
    expect(approvals.current.map((r) => r.id), isNot(contains(ninth.id)));
    // Once one is answered there is room again.
    approvals.answer(approvals.current.first.id, BridgeApprovalAnswer.deny);
    final tenth = approvals.ask(req(client: 'c9'));
    expect(approvals.current, hasLength(8));
    approvals.withdrawAll();
    expect(await tenth, BridgeApprovalOutcome.withdrawn);
    expect((await Future.wait(waiting)).map((o) => o.kind).toSet(), {
      BridgeApprovalOutcomeKind.denied,
      BridgeApprovalOutcomeKind.withdrawn,
    });
  });

  test('a 4th pending request from one client is busy; others still get '
      'theirs', () async {
    final mine = [for (var i = 0; i < 3; i++) approvals.ask(req(client: 'a'))];
    final fourth = req(client: 'a');
    expect(await approvals.ask(fourth), BridgeApprovalOutcome.busy);
    expect(approvals.current.map((r) => r.id), isNot(contains(fourth.id)));
    // Another client is not crowded out.
    final theirs = approvals.ask(req(client: 'b'));
    expect(approvals.current, hasLength(4));
    // Once one of the three ends, the client has room again.
    approvals.answer(approvals.current.first.id, BridgeApprovalAnswer.deny);
    final again = approvals.ask(req(client: 'a'));
    expect(approvals.current.where((r) => r.client.id == 'a'), hasLength(3));
    approvals.withdrawAll();
    await Future.wait([...mine, theirs, again]);
    expect(approvals.current, isEmpty);
  });

  test('withdrawHost takes only that host\'s requests', () async {
    final a = approvals.ask(req(host: 'hA'));
    final b = approvals.ask(req(client: 'c2', host: 'hB'));
    approvals.withdrawHost('hA');
    expect(await a, BridgeApprovalOutcome.withdrawn);
    expect(approvals.current.single.hostId, 'hB');
    approvals.withdrawHost('hB');
    expect(await b, BridgeApprovalOutcome.withdrawn);
  });

  test('one call, one pending request: the same id twice throws', () {
    final r = req();
    unawaited(approvals.ask(r));
    expect(() => approvals.ask(r), throwsArgumentError);
    approvals.withdraw(r.id);
  });

  test('withdrawClient takes only that client\'s requests', () async {
    final a = approvals.ask(req(client: 'a'));
    final b = approvals.ask(req(client: 'b'));
    approvals.withdrawClient('a');
    expect(await a, BridgeApprovalOutcome.withdrawn);
    expect(await settled(b), isNull);
    expect(approvals.current.single.client.id, 'b');
    approvals.withdrawClientsExcept({'a'});
    expect(await b, BridgeApprovalOutcome.withdrawn);
  });

  test('withdrawAll ends everything and leaks nothing', () async {
    final all = [for (var i = 0; i < 5; i++) approvals.ask(req(client: 'c$i'))];
    approvals.withdrawAll();
    for (final o in await Future.wait(all)) {
      expect(o, BridgeApprovalOutcome.withdrawn);
    }
    expect(approvals.current, isEmpty);
    expect(time.activeTimers, 0);
  });

  test('the pending stream starts with the current list, oldest first, and '
      'follows every change', () async {
    final seen = <List<String>>[];
    final first = req();
    unawaited(approvals.ask(first));
    final sub = approvals.pending.listen(
      (l) => seen.add([for (final r in l) r.id]),
    );
    await Future<void>.delayed(Duration.zero);
    time.advance(const Duration(seconds: 1));
    final second = req();
    unawaited(approvals.ask(second));
    final third = req();
    unawaited(approvals.ask(third));
    approvals.answer(second.id, BridgeApprovalAnswer.deny);
    time.advance(const Duration(seconds: 119));
    await Future<void>.delayed(Duration.zero);
    expect(seen, [
      [first.id],
      [first.id, second.id],
      [first.id, second.id, third.id],
      [first.id, third.id],
      [third.id],
    ]);
    approvals.withdrawAll();
    await Future<void>.delayed(Duration.zero);
    expect(seen.last, isEmpty);
    await sub.cancel();
  });

  test('completed requests are not kept', () async {
    for (var i = 0; i < 100; i++) {
      final r = req();
      final f = approvals.ask(r);
      switch (i % 4) {
        case 0:
          approvals.answer(r.id, BridgeApprovalAnswer.allowOnce);
        case 1:
          approvals.answer(r.id, BridgeApprovalAnswer.deny);
        case 2:
          approvals.withdraw(r.id);
        case 3:
          time.advance(const Duration(seconds: 120));
      }
      await f;
    }
    expect(approvals.current, isEmpty);
    expect(time.activeTimers, 0);
  });

  test('a request already past its expiry times out at once', () async {
    final r = req();
    time.advance(const Duration(seconds: 200));
    expect(await approvals.ask(r), BridgeApprovalOutcome.timedOut);
    expect(approvals.current, isEmpty);
  });

  test('a caller cannot stretch the wait past the timeout', () async {
    final now = time.now;
    final r = BridgeApprovalRequest(
      id: 'long',
      client: _client('c1'),
      hostId: 'h1',
      hostName: 'web',
      tool: 'run_command',
      summary: CommandSummary(command: 'ls', hostNames: ['web']),
      createdAt: now,
      expiresAt: now.add(const Duration(hours: 1)),
    );
    final f = approvals.ask(r);
    time.advance(const Duration(seconds: 120));
    expect(await f, BridgeApprovalOutcome.timedOut);
  });

  test('dispose withdraws and closes the stream', () async {
    final f = approvals.ask(req());
    final done = Completer<void>();
    approvals.pending.listen((_) {}, onDone: done.complete);
    await approvals.dispose();
    expect(await f, BridgeApprovalOutcome.withdrawn);
    await done.future;
    expect(await approvals.ask(req()), BridgeApprovalOutcome.withdrawn);
  });
}
