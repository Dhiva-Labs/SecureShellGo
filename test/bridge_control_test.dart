import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/app_settings.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/services/bridge/bridge_approvals.dart';
import 'package:secure_shell_go/services/bridge/bridge_audit.dart';
import 'package:secure_shell_go/services/bridge/bridge_channel.dart';
import 'package:secure_shell_go/services/bridge/bridge_client_store.dart';
import 'package:secure_shell_go/services/bridge/bridge_control.dart';
import 'package:secure_shell_go/services/bridge/bridge_control_protocol.dart';
import 'package:secure_shell_go/services/bridge/bridge_grants.dart';
import 'package:secure_shell_go/services/bridge/bridge_jobs.dart';
import 'package:secure_shell_go/services/bridge/bridge_redactor.dart';

import 'support/bridge_temp_dir.dart';

/// One phone's side of a session, in memory.
class _Phone implements BridgeConnection {
  _Phone(this.client);

  @override
  final BridgeClient client;
  final _in = StreamController<String>();
  final List<Map<String, Object?>> sent = [];
  final _sent = StreamController<Map<String, Object?>>.broadcast();
  bool closed = false;
  int _cursor = 0;

  @override
  Stream<String> get lines => _in.stream;

  @override
  void send(String line) {
    expect(line.contains('\n'), false);
    final m = jsonDecode(line) as Map<String, Object?>;
    sent.add(m);
    _sent.add(m);
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    // Not awaited: a lines stream nobody listened to never reports done.
    unawaited(_in.close());
  }

  void push(Object message) =>
      _in.add(message is String ? message : jsonEncode(message));

  /// The next message sent after the last one taken that matches [test].
  Future<Map<String, Object?>> next([
    bool Function(Map<String, Object?> m)? test,
  ]) async {
    bool ok(Map<String, Object?> m) => test == null || test(m);
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (true) {
      while (_cursor < sent.length) {
        final m = sent[_cursor++];
        if (ok(m)) return m;
      }
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) fail('no matching message; sent: $sent');
      // Wakes on the next message, whatever it is; the loop above judges.
      await _sent.stream.first.timeout(left, onTimeout: () => const {});
    }
  }

  Future<Map<String, Object?>> type(String t) => next((m) => m['type'] == t);

  Future<Map<String, Object?>> result(String re) =>
      next((m) => m['type'] == 'result' && m['re'] == re);
}

BridgeClient _controller(String id, String name) => BridgeClient(
  id: id,
  name: name,
  tokenHash: 'x',
  createdAt: DateTime.utc(2026),
  role: BridgeClientRole.controller,
);

final _assistant = BridgeClient(
  id: 'c1',
  name: 'Desk\u202e assistant',
  tokenHash: 'x',
  createdAt: DateTime.utc(2026),
);

class _Source implements BridgeControlSource {
  final items = <BridgeControlItem>[];
  final stopped = <String>[];
  final _changes = StreamController<void>.broadcast();

  @override
  ControlItemKind get kind => ControlItemKind.job;

  @override
  List<BridgeControlItem> get current => List.of(items);

  @override
  Stream<void> get changes => _changes.stream;

  void changed() => _changes.add(null);

  @override
  Future<bool> stop(String id) async {
    final before = items.length;
    items.removeWhere((i) => i.id == id);
    if (items.length == before) return false;
    stopped.add(id);
    changed();
    return true;
  }
}

/// The real jobs module, with the person's Stop recorded instead of dialled.
class _RecordingJobs extends BridgeJobs {
  _RecordingJobs(BridgeJobRegistry registry)
    : super(registry: registry, redactor: BridgeRedactor(scrub: (s) => s));

  final stopped = <String>[];

  @override
  Future<bool> stopByUser(String jobId) async {
    stopped.add(jobId);
    return true;
  }
}

/// An audit log whose read can be held after it has read the file, so an
/// entry recorded in that moment is one the read did not see.
class _HeldReadAudit extends BridgeAuditLog {
  _HeldReadAudit({required super.scrub, required super.directory});

  final readDone = Completer<void>();
  final release = Completer<void>();

  @override
  Future<List<BridgeAuditEntry>> recent({int limit = 200}) async {
    final entries = await super.recent(limit: limit);
    if (!readDone.isCompleted) readDone.complete();
    await release.future;
    return entries;
  }
}

void main() {
  late Directory temp;
  late AppSettings settings;
  late bool locked;
  late DateTime now;
  late BridgeApprovals approvals;
  late BridgeGrants grants;
  late BridgeAuditLog audit;
  late _Source jobs;
  late BridgeControlServer server;
  final phones = <_Phone>[];

  setUp(() async {
    temp = await bridgeTempDir('bridge_ctl');
    settings = const AppSettings(bridgePhoneControl: true);
    locked = false;
    now = DateTime.utc(2026, 11, 17, 12);
    approvals = BridgeApprovals(
      timedApprovalMinutes: () => settings.bridgeTimedApprovalMinutes,
      clock: () => now,
    );
    grants = BridgeGrants();
    audit = BridgeAuditLog(scrub: (s) => s, directory: temp);
    jobs = _Source();
    server = BridgeControlServer(
      approvals: approvals,
      grants: grants,
      audit: audit,
      isAppLocked: () => locked,
      settings: () => settings,
      sources: [jobs],
      clock: () => now,
    );
  });

  tearDown(() async {
    await server.dispose();
    for (final p in phones) {
      await p.close();
    }
    phones.clear();
    await approvals.dispose();
    await grants.dispose();
    await audit.dispose();
    await deleteTempDir(temp);
  });

  /// A phone connected and through its first snapshot.
  Future<_Phone> connect({String id = 'p1', String name = 'Pixel'}) async {
    final phone = _Phone(_controller(id, name));
    phones.add(phone);
    unawaited(server.serve(phone));
    await phone.type('synced');
    return phone;
  }

  ({String id, Future<BridgeApprovalOutcome> outcome}) ask(
    BridgeChangeSummary summary,
  ) {
    final r = approvals.request(
      client: _assistant,
      hostId: 'h1',
      hostName: 'web',
      tool: 'run_command',
      summary: summary,
    );
    return (id: r.id, outcome: approvals.ask(r));
  }

  test('a snapshot, then the waiting cards in their visible-safe form', () async {
    settings = settings.copyWith(bridgeTimedApprovalMinutes: 15);
    final first = ask(
      CommandSummary(command: 'rm -rf x\u202e\nexit', hostNames: ['web']),
    );
    grants.grant('c1', 'h1', const Duration(minutes: 5), clientName: 'A', hostName: 'web');
    jobs.items.add(
      const BridgeControlItem(id: 'j1', clientName: 'A', hostName: 'web', state: 'running', label: 'dev'),
    );
    await audit.record(
      client: 'A',
      host: 'web',
      tool: 'list_hosts',
      args: const {},
      outcome: BridgeAuditOutcome.ok,
      ms: 1,
    );

    final phone = _Phone(_controller('p1', 'Pixel'));
    phones.add(phone);
    unawaited(server.serve(phone));
    final snapshot = await phone.type('snapshot');
    expect(snapshot['v'], bridgeControlProtocolVersion);
    final state = snapshot['state'] as Map;
    expect(state['locked'], false);
    expect(state['timedMinutes'], 15);
    expect(state['controller'], 'Pixel');
    expect((snapshot['grants'] as List).single['host'], 'web');
    expect((snapshot['items'] as List).single['label'], 'dev');
    expect((snapshot['activity'] as List).single['tool'], 'list_hosts');

    final added = await phone.type('approval');
    final card = ControlApproval.fromJson(added['approval']);
    expect(card.id, first.id);
    expect(card.kind, ControlApprovalKind.command);
    expect(card.assistant, 'Desk[U+202E] assistant');
    expect(card.host, 'web');
    expect(card.timedAllowed, true);
    expect(card.remaining, BridgeApprovals.defaultTimeout);
    expect(card.command!.hosts, ['web']);
    expect(card.command!.command.text, contains('[U+202E]'));
    expect(jsonEncode(added), isNot(contains('\u202e')));
    expect(jsonEncode(added), isNot(contains('example')));
    await phone.type('synced');
    expect(server.connected.single.name, 'Pixel');
  });

  test('an answer goes through the same path, once, and says how it ended', () async {
    final phone = await connect();
    final asked = ask(CommandSummary(command: 'ls', hostNames: ['web']));
    final card = await phone.type('approval');
    expect((card['approval'] as Map)['id'], asked.id);

    phone.push({'type': 'answer', 're': 'r1', 'approval': asked.id, 'answer': 'once'});
    final result = await phone.result('r1');
    expect(result['ok'], true);
    expect(result['outcome'], 'allowedOnce');
    final outcome = await asked.outcome;
    expect(outcome, BridgeApprovalOutcome.allowedOnce);
    expect(outcome.via, 'controller:Pixel');
    final removed = await phone.type('approval_removed');
    expect(removed['id'], asked.id);
    expect(removed['end'], 'allowedOnce');

    // A second answer to the same card is refused.
    phone.push({'type': 'answer', 're': 'r2', 'approval': asked.id, 'answer': 'deny'});
    final again = await phone.result('r2');
    expect(again['ok'], false);
    expect(again['code'], 'not_found');
  });

  test('deny from the phone', () async {
    final phone = await connect();
    final asked = ask(const ServiceActionSummary(unit: 'nginx', action: 'restart'));
    await phone.type('approval');
    phone.push({'type': 'answer', 're': 'r1', 'approval': asked.id, 'answer': 'deny'});
    expect((await phone.result('r1'))['outcome'], 'denied');
    expect((await asked.outcome).kind, BridgeApprovalOutcomeKind.denied);
  });

  test('answering a withdrawn or timed-out card fails cleanly', () async {
    final phone = await connect();
    final withdrawn = ask(CommandSummary(command: 'ls', hostNames: ['web']));
    await phone.type('approval');
    approvals.withdraw(withdrawn.id);
    expect((await phone.type('approval_removed'))['end'], 'withdrawn');
    phone.push({'type': 'answer', 're': 'r1', 'approval': withdrawn.id, 'answer': 'once'});
    final r1 = await phone.result('r1');
    expect(r1['ok'], false);
    expect(r1['code'], 'not_found');

    final late = ask(CommandSummary(command: 'ls', hostNames: ['web']));
    await phone.type('approval');
    // Past the expiry, before the timer has run: the clock is the judge.
    now = now.add(const Duration(minutes: 5));
    phone.push({'type': 'answer', 're': 'r2', 'approval': late.id, 'answer': 'once'});
    final r2 = await phone.result('r2');
    expect(r2['ok'], false);
    expect(r2['code'], 'not_found');
    expect(r2['outcome'], 'timedOut');
    expect((await late.outcome).kind, BridgeApprovalOutcomeKind.timedOut);

    phone.push({'type': 'answer', 're': 'r3', 'approval': 'approval-nope', 'answer': 'deny'});
    expect((await phone.result('r3'))['code'], 'not_found');
  });

  test('"allow for a while" only as the desktop allows it', () async {
    final phone = await connect();
    final a = ask(CommandSummary(command: 'ls', hostNames: ['web']));
    await phone.type('approval');

    // Off on the desktop.
    phone.push({'type': 'answer', 're': 'r1', 'approval': a.id, 'answer': 'for_minutes', 'minutes': 15});
    expect((await phone.result('r1'))['code'], 'not_allowed');

    settings = settings.copyWith(bridgeTimedApprovalMinutes: 15);
    // Another length than the configured one.
    phone.push({'type': 'answer', 're': 'r2', 'approval': a.id, 'answer': 'for_minutes', 'minutes': 60});
    expect((await phone.result('r2'))['code'], 'not_allowed');
    expect(approvals.current, hasLength(1));

    phone.push({'type': 'answer', 're': 'r3', 'approval': a.id, 'answer': 'for_minutes', 'minutes': 15});
    final ok = await phone.result('r3');
    expect(ok['ok'], true);
    expect(ok['outcome'], 'allowedForAWhile');
    expect((await a.outcome).grantFor, const Duration(minutes: 15));

    // Never for a terminal.
    final t = ask(const TerminalSummary());
    final card = await phone.type('approval');
    expect((card['approval'] as Map)['timedAllowed'], false);
    phone.push({'type': 'answer', 're': 'r4', 'approval': t.id, 'answer': 'for_minutes', 'minutes': 15});
    expect((await phone.result('r4'))['code'], 'not_allowed');
    expect(approvals.current, hasLength(1));
  });

  test('locked: an empty snapshot, every action refused, until unlocked', () async {
    final a = ask(CommandSummary(command: 'ls', hostNames: ['web']));
    grants.grant('c1', 'h1', const Duration(minutes: 5));
    locked = true;
    final phone = _Phone(_controller('p1', 'Pixel'));
    phones.add(phone);
    unawaited(server.serve(phone));
    final snapshot = await phone.type('snapshot');
    expect((snapshot['state'] as Map)['locked'], true);
    expect(snapshot['grants'], isEmpty);
    expect(snapshot['activity'], isEmpty);
    final synced = await phone.next(
      (m) => m['type'] == 'synced' || m['type'] == 'approval',
    );
    expect(synced['type'], 'synced');

    phone.push({'type': 'answer', 're': 'r1', 'approval': a.id, 'answer': 'once'});
    expect((await phone.result('r1'))['code'], 'locked');
    phone.push({'type': 'stop_grant', 're': 'r2', 'grant': 'x'});
    expect((await phone.result('r2'))['code'], 'locked');
    phone.push({'type': 'ping', 're': 'r3'});
    expect((await phone.result('r3'))['ok'], true);
    expect(approvals.current, hasLength(1));
    expect(grants.current, hasLength(1));

    locked = false;
    server.lockChanged(false);
    final fresh = await phone.type('snapshot');
    expect((fresh['state'] as Map)['locked'], false);
    expect(fresh['grants'], hasLength(1));
    expect(((await phone.type('approval'))['approval'] as Map)['id'], a.id);
  });

  test('nothing can be widened: no message pairs, sets, or calls a tool', () async {
    settings = settings.copyWith(bridgeTimedApprovalMinutes: 5);
    final phone = await connect();
    final a = ask(CommandSummary(command: 'ls', hostNames: ['web']));
    await phone.type('approval');
    final before = settings;

    for (final (i, message) in <Object>[
      {'type': 'pair', 're': 'w1', 'name': 'evil'},
      {'type': 'set_setting', 're': 'w2', 'bridgeTimedApprovalMinutes': 60},
      {'type': 'set_host_access', 're': 'w3', 'host': 'web', 'level': 'fullControl'},
      {'type': 'tools/call', 're': 'w4', 'name': 'run_command'},
      {'type': 'grant', 're': 'w5', 'host': 'web'},
    ].indexed) {
      phone.push(message);
      final r = await phone.result('w${i + 1}');
      expect(r['ok'], false);
      expect(r['code'], 'unknown_type');
    }
    // MCP itself: no `re`, so a session-level error.
    phone.push({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'tools/call',
      'params': {'name': 'run_command', 'arguments': {'host': 'web', 'command': 'id'}},
    });
    expect((await phone.type('error'))['code'], 'malformed');
    phone.push('not json at all');
    expect((await phone.type('error'))['code'], 'malformed');
    phone.push('{"type":"ping","re":"${'x' * (70 * 1024)}"}');
    expect((await phone.type('error'))['code'], 'too_large');

    expect(identical(settings, before), true);
    expect(approvals.current.single.id, a.id);
    expect(grants.current, isEmpty);
    // The session is still usable.
    phone.push({'type': 'ping', 're': 'p'});
    expect((await phone.result('p'))['ok'], true);
  });

  test('stop a grant and an item, each once', () async {
    final phone = await connect();
    grants.grant('c1', 'h1', const Duration(minutes: 5), clientName: 'A', hostName: 'web');
    final listed = await phone.type('grants');
    final id = ((listed['grants'] as List).single as Map)['id'] as String;
    phone.push({'type': 'stop_grant', 're': 'r1', 'grant': id});
    expect((await phone.result('r1'))['ok'], true);
    expect(grants.current, isEmpty);
    phone.push({'type': 'stop_grant', 're': 'r2', 'grant': id});
    expect((await phone.result('r2'))['code'], 'not_found');

    jobs.items.add(
      const BridgeControlItem(id: 'j1', clientName: 'A', hostName: 'web', state: 'running'),
    );
    jobs.changed();
    final items = await phone.type('items');
    expect((items['items'] as List).single['id'], 'j1');
    phone.push({'type': 'stop_item', 're': 'r3', 'kind': 'terminal', 'id': 'j1'});
    expect((await phone.result('r3'))['code'], 'not_found');
    phone.push({'type': 'stop_item', 're': 'r4', 'kind': 'job', 'id': 'j1'});
    expect((await phone.result('r4'))['ok'], true);
    expect(jobs.stopped, ['j1']);
    phone.push({'type': 'stop_item', 're': 'r5', 'kind': 'job', 'id': 'j1'});
    expect((await phone.result('r5'))['code'], 'not_found');
  });

  test('a phone sees a registered job and its Stop reaches stopByUser', () async {
    final registry = BridgeJobRegistry(file: File('${temp.path}/jobs.json'));
    final real = _RecordingJobs(registry);
    final withJobs = BridgeControlServer(
      approvals: approvals,
      grants: grants,
      isAppLocked: () => locked,
      settings: () => settings,
      sources: [BridgeJobsControlSource(real)],
      clock: () => now,
    );
    addTearDown(withJobs.dispose);
    await registry.add(
      BridgeJobRecord(
        id: 'job0000000000001',
        clientId: 'c1',
        hostId: 'h1',
        hostname: '10.0.0.5',
        port: 22,
        username: 'root',
        transport: HostTransport.ssh,
        jumpHostId: null,
        hostName: 'web',
        startedAt: DateTime.utc(2026, 11, 17, 11),
        name: 'dev server',
        clientName: 'Desk assistant',
      ),
    );
    final phone = _Phone(_controller('p9', 'Pixel'));
    phones.add(phone);
    unawaited(withJobs.serve(phone));
    final snapshot = await phone.type('snapshot');
    final item = (snapshot['items'] as List).single as Map;
    expect(item['kind'], 'job');
    expect(item['id'], 'job0000000000001');
    expect(item['host'], 'web');
    expect(item['label'], 'dev server');
    expect(item['assistant'], 'Desk assistant');
    expect(jsonEncode(snapshot), isNot(contains('10.0.0.5')));
    await phone.type('synced');

    phone.push({'type': 'stop_item', 're': 'r1', 'kind': 'job', 'id': 'job0000000000001'});
    expect((await phone.result('r1'))['ok'], true);
    expect(real.stopped, ['job0000000000001']);

    // An id the app does not know is "already ended" and never dialled.
    phone.push({'type': 'stop_item', 're': 'r2', 'kind': 'job', 'id': 'job0000000000002'});
    expect((await phone.result('r2'))['code'], 'not_found');
    expect(real.stopped, ['job0000000000001']);

    // The lock refuses it before it reaches the source.
    locked = true;
    phone.push({'type': 'stop_item', 're': 'r3', 'kind': 'job', 'id': 'job0000000000001'});
    expect((await phone.result('r3'))['code'], 'locked');
    expect(real.stopped, ['job0000000000001']);
  });

  test('new activity is sent, with where an answer came from', () async {
    final phone = await connect();
    await audit.record(
      client: 'A',
      host: 'web',
      tool: 'run_command',
      args: const {'command': 'ls'},
      outcome: BridgeAuditOutcome.ok,
      ms: 3,
      approval: BridgeAuditApproval.once,
      via: 'controller:Pixel',
    );
    final entry = (await phone.type('activity'))['entry'] as Map;
    expect(entry['tool'], 'run_command');
    expect(entry['approval'], 'once');
    expect(entry['via'], 'controller:Pixel');
  });

  test('an entry recorded while the snapshot is being read is still sent',
      () async {
    final held = _HeldReadAudit(scrub: (s) => s, directory: temp);
    addTearDown(held.dispose);
    final own = BridgeControlServer(
      approvals: approvals,
      grants: grants,
      audit: held,
      isAppLocked: () => locked,
      settings: () => settings,
      clock: () => now,
    );
    addTearDown(own.dispose);
    final phone = _Phone(_controller('p1', 'Pixel'));
    phones.add(phone);
    unawaited(own.serve(phone));
    await held.readDone.future;
    await held.record(
      client: 'A',
      host: 'web',
      tool: 'late_entry',
      args: const {},
      outcome: BridgeAuditOutcome.ok,
      ms: 1,
      approval: BridgeAuditApproval.none,
    );
    held.release.complete();
    final snapshot = await phone.type('snapshot');
    expect(snapshot['activity'], isEmpty);
    final late = await phone.type('activity');
    expect((late['entry'] as Map)['tool'], 'late_entry');
    // And it comes before `synced`, once.
    final order = phone.sent.map((m) => m['type']).toList();
    expect(order.indexOf('activity'), lessThan(order.indexOf('synced')));
    expect(order.where((t) => t == 'activity'), hasLength(1));
  });

  test('at most two phones; a third is told and closed', () async {
    await connect(id: 'p1');
    await connect(id: 'p2', name: 'Tablet');
    final third = _Phone(_controller('p3', 'Old phone'));
    phones.add(third);
    await server.serve(third);
    expect(third.sent.single['code'], 'too_many_sessions');
    expect(third.closed, true);
    expect(server.connected, hasLength(2));
  });

  test('only a controller, only with Phone control on', () async {
    final assistant = _Phone(_assistant);
    phones.add(assistant);
    await server.serve(assistant);
    expect(assistant.closed, true);
    expect(assistant.sent, isEmpty);

    settings = settings.copyWith(bridgePhoneControl: false);
    final phone = _Phone(_controller('p1', 'Pixel'));
    phones.add(phone);
    await server.serve(phone);
    expect(phone.closed, true);
    expect(phone.sent, isEmpty);
    expect(server.connected, isEmpty);
  });

  test('a revoked phone, or Phone control switched off, closes the session at once', () async {
    final keep = await connect(id: 'p1');
    final gone = await connect(id: 'p2', name: 'Lost phone');
    server.closeClientsExcept({'p1', BridgeClient.builtinId});
    expect((await gone.type('error'))['code'], 'refused');
    expect(gone.closed, true);
    expect(keep.closed, false);
    for (var i = 0; i < 200 && server.connected.length != 1; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(server.connected.single.id, 'p1');

    settings = settings.copyWith(bridgePhoneControl: false);
    server.settingsChanged(settings);
    expect((await keep.type('error'))['code'], 'refused');
    await Future<void>.delayed(Duration.zero);
    expect(keep.closed, true);
  });

  test('a new "allow for a while" length re-sends the cards', () async {
    server.settingsChanged(settings);
    final phone = await connect();
    ask(CommandSummary(command: 'ls', hostNames: ['web']));
    final first = await phone.type('approval');
    expect((first['approval'] as Map)['timedAllowed'], false);
    settings = settings.copyWith(bridgeTimedApprovalMinutes: 5);
    server.settingsChanged(settings);
    final snapshot = await phone.type('snapshot');
    expect((snapshot['state'] as Map)['timedMinutes'], 5);
    final again = await phone.type('approval');
    expect((again['approval'] as Map)['timedAllowed'], true);
  });

  group('audit via', () {
    test('written and read back; older lines still parse', () {
      final entry = BridgeAuditEntry(
        ts: DateTime.utc(2026, 11, 17),
        client: 'A',
        host: 'web',
        tool: 'run_command',
        args: '{}',
        outcome: BridgeAuditOutcome.ok,
        detail: '',
        ms: 1,
        approval: BridgeAuditApproval.once,
        via: 'controller:Pixel',
      );
      final back = BridgeAuditEntry.tryParse(jsonEncode(entry.toJson()))!;
      expect(back.via, 'controller:Pixel');
      expect(back.approval, BridgeAuditApproval.once);

      final old = {...entry.toJson()}..remove('via');
      final parsed = BridgeAuditEntry.tryParse(jsonEncode(old))!;
      expect(parsed.via, isNull);
      expect(jsonEncode(parsed.toJson()), isNot(contains('via')));

      final odd = {...entry.toJson(), 'via': 7};
      expect(BridgeAuditEntry.tryParse(jsonEncode(odd))!.via, isNull);
    });
  });
}
