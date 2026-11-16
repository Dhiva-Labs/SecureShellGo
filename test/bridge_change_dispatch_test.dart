import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/app_settings.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/models/host_ai_access.dart';
import 'package:secure_shell_go/services/bridge/bridge_approvals.dart';
import 'package:secure_shell_go/services/bridge/bridge_audit.dart';
import 'package:secure_shell_go/services/bridge/bridge_channel.dart';
import 'package:secure_shell_go/services/bridge/bridge_client_store.dart';
import 'package:secure_shell_go/services/bridge/bridge_grants.dart';
import 'package:secure_shell_go/services/bridge/bridge_policy.dart';
import 'package:secure_shell_go/services/bridge/bridge_tool_types.dart';
import 'package:secure_shell_go/services/bridge/bridge_tools.dart';
import 'package:secure_shell_go/services/bridge/mcp_server.dart';

import 'fake_exec_session.dart';
import 'support/bridge_fake_time.dart';
import 'support/bridge_fakes.dart';
import 'support/bridge_temp_dir.dart';

// The dispatcher's path for tools that change a server, end to end, with a
// test-only change tool (the real ones come in a later piece).

class _CommandPlan extends BridgeChangePlan {
  _CommandPlan(
    this.command,
    String hostName, {
    required super.matchesAllowedCommand,
  }) : super(
         summary: CommandSummary(command: command, hostNames: [hostName]),
       );

  final String command;
}

final BridgeChangeTool _fakeChange = BridgeChangeTool(
  spec: const BridgeToolSpec(
    name: 'fake_change',
    description: 'Runs a command (test only).',
    inputSchema: {'type': 'object'},
    kind: BridgeToolKind.change,
  ),
  arguments: const {'host', 'command'},
  plan: (args, context) async {
    final command = args.string('command', maxBytes: 4096)!;
    return _CommandPlan(
      command,
      context.hostName,
      matchesAllowedCommand: bridgeCommandIsAllowed(context.host, command),
    );
  },
  run: (call, plan) async {
    final result = await call.exec((plan as _CommandPlan).command);
    return BridgeToolResult('exit ${result.exitCode}: ${result.stdout}');
  },
  auditArgs: (args) => {
    'host': args['host'],
    'command_chars': '${args['command']}'.length,
  },
);

final BridgeChangeTool _fakeTerminal = BridgeChangeTool(
  spec: const BridgeToolSpec(
    name: 'fake_terminal',
    description: 'Opens a terminal (test only).',
    inputSchema: {'type': 'object'},
    kind: BridgeToolKind.terminal,
  ),
  arguments: const {'host'},
  plan: (args, context) async =>
      const BridgeChangePlan(summary: TerminalSummary()),
  run: (call, plan) async => const BridgeToolResult('terminal opened'),
);

final BridgeChangeTool _fakeMulti = BridgeChangeTool(
  spec: const BridgeToolSpec(
    name: 'fake_multi',
    description: 'Runs a command on several hosts (test only).',
    inputSchema: {'type': 'object'},
    kind: BridgeToolKind.change,
  ),
  arguments: const {'hosts', 'command'},
  plan: (args, context) async {
    final command = args.string('command', maxBytes: 4096)!;
    return _CommandPlan(
      command,
      context.hostNames.join(', '),
      matchesAllowedCommand: false,
    );
  },
  run: (call, plan) async {
    final result = await call.exec((plan as _CommandPlan).command);
    return BridgeToolResult('${result.exitCode}');
  },
  combine: (outcomes, plan) =>
      BridgeToolResult(outcomes.map((o) => '${o.hostName}=${o.text}').join(' ')),
);

Host _h(
  String id,
  String label,
  HostAiAccess access, {
  List<String> allowed = const [],
  bool terminal = false,
}) => bridgeHost(
  id,
  label,
  access: access,
).copyWith(aiAllowedCommands: allowed, aiTerminal: terminal);

class _Conn implements BridgeConnection {
  final incoming = StreamController<String>();
  final sent = <String>[];

  @override
  BridgeClient get client => testBridgeClient;

  @override
  Stream<String> get lines => incoming.stream;

  @override
  void send(String line) => sent.add(line);

  @override
  Future<void> close() async {}
}

final BridgeClient _otherClient = BridgeClient(
  id: 'c2',
  name: 'Other assistant',
  tokenHash: 'y',
  createdAt: DateTime.utc(2026),
);

void main() {
  late Directory temp;
  late FakeTime time;
  late BridgeToolsRig rig;
  late BridgeApprovals approvals;
  late BridgeGrants grants;
  late List<List<BridgeApprovalRequest>> cards;
  late StreamSubscription<List<BridgeApprovalRequest>> cardWatch;

  BridgeToolsRig build({
    int maxRunning = 4,
    Duration callTimeout = const Duration(seconds: 30),
  }) {
    time = FakeTime();
    late BridgeToolsRig built;
    approvals = BridgeApprovals(
      timedApprovalMinutes: () => built.settings.bridgeTimedApprovalMinutes,
      clock: time.clock,
      timer: time.timer,
    );
    grants = BridgeGrants(clock: time.clock, timer: time.timer);
    built = BridgeToolsRig(
      temp,
      maxRunning: maxRunning,
      callTimeout: callTimeout,
      approvals: approvals,
      grants: grants,
      changeTools: [_fakeChange, _fakeTerminal, _fakeMulti],
    );
    built.hosts = [
      _h('web1', 'web', HostAiAccess.askToChange, allowed: ['uptime']),
      _h('db01', 'db', HostAiAccess.readOnly, allowed: ['uptime']),
      _h(
        'sec1',
        'secret',
        HostAiAccess.off,
        allowed: ['uptime'],
        terminal: true,
      ),
      _h('trm1', 'term', HostAiAccess.askToChange, terminal: true),
    ];
    for (final id in ['web1', 'db01', 'trm1']) {
      built.serve(id, (cmd) => FakeExecSession(stdout: 'ran:$cmd'));
    }
    cards = [];
    cardWatch = approvals.pending.listen(cards.add);
    return built;
  }

  setUp(() async {
    temp = await bridgeTempDir('bridge_change');
    rig = build();
  });

  tearDown(() async {
    await cardWatch.cancel();
    await deleteTempDir(temp);
  });

  /// Waits until a card is up (real time, bounded).
  Future<BridgeApprovalRequest> card() async {
    for (var i = 0; i < 200; i++) {
      if (approvals.current.isNotEmpty) return approvals.current.last;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('no approval card appeared');
  }

  bool anyCardShown() => cards.any((l) => l.isNotEmpty);

  BridgeAuditEntry lastEntry() => rig.entries.last;

  group('allowed without a card', () {
    test('a command on the host\'s allowed list runs at once', () async {
      final r = await rig.call('fake_change', {
        'host': 'web',
        'command': 'uptime',
      });
      expect(r.isError, false);
      expect(r.text, 'exit 0: ran:uptime');
      expect(anyCardShown(), false);
      expect(lastEntry().approval, BridgeAuditApproval.allowedCommand);
      expect(lastEntry().outcome, BridgeAuditOutcome.ok);
      // The tool chose what is recorded.
      expect(lastEntry().args, '{"host":"web","command_chars":6}');
    });

    test('the allowed list matches exact text only', () async {
      final r = rig.call('fake_change', {
        'host': 'web',
        'command': 'uptime; reboot',
      });
      final c = await card();
      approvals.answer(c.id, BridgeApprovalAnswer.deny);
      expect((await r).isError, true);
      expect(rig.commands, isEmpty);
    });
  });

  group('the card', () {
    test('shows what the tool built, and allow once runs it once', () async {
      final r = rig.call('fake_change', {'host': 'web', 'command': 'whoami'});
      final c = await card();
      expect(c.tool, 'fake_change');
      expect(c.hostId, 'web1');
      expect(c.hostName, 'web');
      expect(c.client.id, testBridgeClient.id);
      final summary = c.summary as CommandSummary;
      expect(summary.command, 'whoami');
      expect(summary.hostNames, ['web']);
      expect(rig.commands, isEmpty, reason: 'nothing runs before the yes');
      approvals.answer(c.id, BridgeApprovalAnswer.allowOnce);
      final out = await r;
      expect(out.isError, false);
      expect(out.text, 'exit 0: ran:whoami');
      expect(lastEntry().approval, BridgeAuditApproval.once);
      expect(grants.current, isEmpty);

      // Once means once.
      final again = rig.call('fake_change', {
        'host': 'web',
        'command': 'whoami',
      });
      approvals.answer((await card()).id, BridgeApprovalAnswer.deny);
      expect((await again).isError, true);
    });

    test('allow for a while: the next call skips the card, until it '
        'expires', () async {
      rig.settings = const AppSettings(
        bridgeEnabled: true,
        bridgeTimedApprovalMinutes: 15,
      );
      final first = rig.call('fake_change', {'host': 'web', 'command': 'id'});
      approvals.answer((await card()).id, BridgeApprovalAnswer.allowForAWhile);
      expect((await first).isError, false);
      expect(lastEntry().approval, BridgeAuditApproval.forAWhile);
      expect(grants.hasLive(testBridgeClient.id, 'web1'), true);
      expect(grants.current.single.hostName, 'web');

      cards.clear();
      final second = await rig.call('fake_change', {
        'host': 'web',
        'command': 'rm -rf /tmp/x',
      });
      expect(second.isError, false);
      expect(anyCardShown(), false);
      expect(lastEntry().approval, BridgeAuditApproval.grant);

      // Another client does not get the grant.
      final other = rig.call('fake_change', {
        'host': 'web',
        'command': 'id',
      }, _otherClient);
      final c = await card();
      expect(c.client.id, 'c2');
      approvals.answer(c.id, BridgeApprovalAnswer.deny);
      expect((await other).isError, true);

      // Nor another host.
      rig.hosts = [...rig.hosts, _h('app1', 'app', HostAiAccess.askToChange)];
      rig.serve('app1', (cmd) => FakeExecSession(stdout: 'ran:$cmd'));
      final elsewhere = rig.call('fake_change', {
        'host': 'app',
        'command': 'id',
      });
      approvals.answer((await card()).id, BridgeApprovalAnswer.deny);
      expect((await elsewhere).isError, true);

      time.advance(const Duration(minutes: 15));
      final expired = rig.call('fake_change', {'host': 'web', 'command': 'id'});
      approvals.answer((await card()).id, BridgeApprovalAnswer.deny);
      expect((await expired).isError, true);
    });

    test(
      'allow for a while with the setting off is once, and no grant',
      () async {
        final r = rig.call('fake_change', {'host': 'web', 'command': 'id'});
        approvals.answer(
          (await card()).id,
          BridgeApprovalAnswer.allowForAWhile,
        );
        expect((await r).isError, false);
        expect(lastEntry().approval, BridgeAuditApproval.once);
        expect(grants.current, isEmpty);
      },
    );

    test('denied: refused, nothing ran', () async {
      final r = rig.call('fake_change', {'host': 'web', 'command': 'reboot'});
      approvals.answer((await card()).id, BridgeApprovalAnswer.deny);
      final out = await r;
      expect(out.isError, true);
      expect(out.text, BridgeToolRefusals.denied.message);
      expect(rig.commands, isEmpty);
      expect(lastEntry().approval, BridgeAuditApproval.denied);
      expect(lastEntry().outcome, BridgeAuditOutcome.refused);
      expect(lastEntry().detail, 'approval_denied');
    });

    test('timed out: silence is no', () async {
      final r = rig.call('fake_change', {'host': 'web', 'command': 'reboot'});
      await card();
      time.advance(const Duration(seconds: 120));
      final out = await r;
      expect(out.isError, true);
      expect(out.text, BridgeToolRefusals.approvalTimedOut.message);
      expect(rig.commands, isEmpty);
      expect(lastEntry().approval, BridgeAuditApproval.timedOut);
      expect(approvals.current, isEmpty);
    });

    BridgeClient clientNo(int n) => BridgeClient(
      id: 'k$n',
      name: 'Assistant $n',
      tokenHash: 'h$n',
      createdAt: DateTime.utc(2026),
    );

    test('a 4th waiting change from one assistant is refused as busy, '
        'without crowding out another', () async {
      final waiting = [
        for (var i = 0; i < 3; i++)
          rig.call('fake_change', {'host': 'web', 'command': 'c$i'}),
      ];
      for (var i = 0; i < 200 && approvals.current.length < 3; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final fourth = await rig.call('fake_change', {
        'host': 'web',
        'command': 'c3',
      });
      expect(fourth.text, BridgeToolRefusals.approvalsBusy.message);
      expect(lastEntry().approval, BridgeAuditApproval.none);
      final other = rig.call('fake_change', {
        'host': 'web',
        'command': 'x',
      }, _otherClient);
      for (var i = 0; i < 200 && approvals.current.length < 4; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(approvals.current, hasLength(4));
      expect(approvals.current.last.client.id, _otherClient.id);
      approvals.withdrawAll();
      await Future.wait([...waiting, other]);
      expect(rig.commands, isEmpty);
    });

    test('a 9th waiting change is refused as busy without a card', () async {
      final waiting = [
        for (var i = 0; i < 8; i++)
          rig.call('fake_change', {
            'host': 'web',
            'command': 'c$i',
          }, clientNo(i ~/ 3)),
      ];
      for (var i = 0; i < 200 && approvals.current.length < 8; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(approvals.current, hasLength(8));
      final ninth = await rig.call('fake_change', {
        'host': 'web',
        'command': 'c8',
      }, clientNo(2));
      expect(ninth.text, BridgeToolRefusals.approvalsBusy.message);
      expect(lastEntry().approval, BridgeAuditApproval.none);
      approvals.withdrawAll();
      await Future.wait(waiting);
      expect(rig.commands, isEmpty);
    });
  });

  group('withdrawn while waiting', () {
    test('a cancelled call withdraws its card and returns nothing', () async {
      final token = BridgeCallToken();
      final r = rig.call(
        'fake_change',
        {'host': 'web', 'command': 'reboot'},
        null,
        token,
      );
      final c = await card();
      token.cancel();
      final out = await r;
      expect(out.isError, true);
      expect(out.text, BridgeTools.cancelledMessage);
      expect(approvals.current, isEmpty);
      // A late answer changes nothing.
      approvals.answer(c.id, BridgeApprovalAnswer.allowOnce);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(rig.commands, isEmpty);
      expect(rig.entries, hasLength(1));
      expect(lastEntry().approval, BridgeAuditApproval.withdrawn);
      expect(rig.tools.inFlight, 0);
    });

    test('revoking the client withdraws its card', () async {
      final r = rig.call('fake_change', {'host': 'web', 'command': 'reboot'});
      await card();
      rig.tools.abandonClient(testBridgeClient.id);
      expect((await r).text, BridgeTools.revokedMessage);
      await Future<void>.delayed(Duration.zero);
      expect(approvals.current, isEmpty);
      expect(lastEntry().approval, BridgeAuditApproval.withdrawn);
    });

    test('switching the bridge off withdraws every card', () async {
      final a = rig.call('fake_change', {'host': 'web', 'command': 'a'});
      final b = rig.call('fake_change', {
        'host': 'web',
        'command': 'b',
      }, _otherClient);
      for (var i = 0; i < 200 && approvals.current.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      rig.tools.abandonAll();
      expect((await a).text, BridgeTools.switchedOffMessage);
      expect((await b).text, BridgeTools.switchedOffMessage);
      await Future<void>.delayed(Duration.zero);
      expect(approvals.current, isEmpty);
      expect(rig.commands, isEmpty);
    });

    test('the app locking while a card waits refuses as locked', () async {
      final r = rig.call('fake_change', {'host': 'web', 'command': 'reboot'});
      await card();
      rig.locked = true;
      approvals.withdrawAll(); // what the bridge service does on a lock
      final out = await r;
      expect(out.text, BridgeRefusals.appLocked.message);
      expect(lastEntry().approval, BridgeAuditApproval.withdrawn);
      expect(rig.commands, isEmpty);
    });
  });

  group('refused without a card', () {
    Future<void> refusedWithoutCard(
      Map<String, Object?> args,
      BridgeRefuse refusal, {
      String tool = 'fake_change',
    }) async {
      final r = await rig.call(tool, args);
      expect(r.isError, true);
      expect(r.text, refusal.message);
      expect(lastEntry().detail, refusal.code);
      expect(lastEntry().approval, BridgeAuditApproval.none);
      expect(anyCardShown(), false);
      expect(rig.commands, isEmpty);
    }

    test('a locked app', () async {
      rig.locked = true;
      await refusedWithoutCard({
        'host': 'web',
        'command': 'uptime',
      }, BridgeRefusals.appLocked);
    });

    test('the bridge off', () async {
      rig.settings = const AppSettings();
      await refusedWithoutCard({
        'host': 'web',
        'command': 'id',
      }, BridgeRefusals.bridgeOff);
    });

    test('a read-only host, even for a listed command', () async {
      await refusedWithoutCard({
        'host': 'db',
        'command': 'uptime',
      }, BridgeRefusals.changesNotAllowed);
    });

    test('a hidden and an unknown host: the same refusal as 1.6.0', () async {
      final read = await rig.call('server_stats', {'host': 'secret'});
      await refusedWithoutCard({
        'host': 'secret',
        'command': 'uptime',
      }, BridgeRefusals.hostNotAvailable);
      final hidden = rig.entries.last;
      await refusedWithoutCard({
        'host': 'nope',
        'command': 'id',
      }, BridgeRefusals.hostNotAvailable);
      expect(
        read.text.codeUnits,
        BridgeRefusals.hostNotAvailable.message.codeUnits,
      );
      expect(hidden.detail, rig.entries.last.detail);
    });

    test('invalid arguments to a hidden host read as a hidden host', () async {
      for (final args in [
        {'host': 'secret'},
        {'host': 'secret', 'command': ''},
        {'host': 'secret', 'command': 'id', 'extra': 1},
        {'host': 42, 'command': 'id'},
      ]) {
        await refusedWithoutCard(args, BridgeRefusals.hostNotAvailable);
      }
    });

    test('invalid arguments to a shared host: refused, no card', () async {
      for (final args in [
        {'host': 'web'},
        {'host': 'web', 'command': ''},
        {'host': 'web', 'command': 'a\u0000b'},
        {'host': 'web', 'command': 'id', 'extra': 1},
      ]) {
        final r = await rig.call('fake_change', args);
        expect(r.isError, true);
        expect(lastEntry().detail, 'invalid_arguments');
        expect(lastEntry().approval, BridgeAuditApproval.none);
      }
      expect(anyCardShown(), false);
    });

    test('a terminal on a host without its switch', () async {
      await refusedWithoutCard(
        {'host': 'web'},
        BridgeRefusals.terminalNotAllowed,
        tool: 'fake_terminal',
      );
    });
  });

  group('after the yes', () {
    test('a host stepped down while the card waited is refused', () async {
      final r = rig.call('fake_change', {'host': 'web', 'command': 'reboot'});
      final c = await card();
      rig.hosts = [
        for (final h in rig.hosts)
          h.id == 'web1' ? h.copyWith(aiAccess: HostAiAccess.readOnly) : h,
      ];
      approvals.answer(c.id, BridgeApprovalAnswer.allowOnce);
      final out = await r;
      expect(out.text, BridgeRefusals.changesNotAllowed.message);
      expect(rig.commands, isEmpty);
      // The user's answer is kept, and the entry says plainly that it did
      // not run, and why.
      expect(lastEntry().approval, BridgeAuditApproval.once);
      expect(lastEntry().outcome, BridgeAuditOutcome.refused);
      expect(
        lastEntry().detail,
        '${BridgeTools.refusedAfterApprovalPrefix}changes_not_allowed',
      );
    });

    test('the bridge switched off after the yes: refused after approval',
        () async {
      final r = rig.call('fake_change', {'host': 'web', 'command': 'reboot'});
      final c = await card();
      rig.onLoadHosts = () async => rig.settings = const AppSettings();
      approvals.answer(c.id, BridgeApprovalAnswer.allowOnce);
      expect((await r).text, BridgeRefusals.bridgeOff.message);
      expect(rig.commands, isEmpty);
      expect(lastEntry().approval, BridgeAuditApproval.once);
      expect(lastEntry().outcome, BridgeAuditOutcome.refused);
      expect(
        lastEntry().detail,
        '${BridgeTools.refusedAfterApprovalPrefix}bridge_off',
      );
    });

    test('approved and run: a failure while running is an error, not '
        '"refused after approval"', () async {
      final r = rig.call('fake_change', {'host': 'web', 'command': 'whoami'});
      final c = await card();
      rig.transports['web1']!.failWith = StateError('channel refused');
      approvals.answer(c.id, BridgeApprovalAnswer.allowOnce);
      expect((await r).isError, true);
      expect(lastEntry().approval, BridgeAuditApproval.once);
      expect(lastEntry().outcome, BridgeAuditOutcome.error);
      expect(
        lastEntry().detail,
        isNot(startsWith(BridgeTools.refusedAfterApprovalPrefix)),
      );
    });

    test('a host un-shared while the card waited is not available, and no '
        'grant is made', () async {
      rig.settings = const AppSettings(
        bridgeEnabled: true,
        bridgeTimedApprovalMinutes: 60,
      );
      final r = rig.call('fake_change', {'host': 'web', 'command': 'reboot'});
      final c = await card();
      rig.hosts = [
        for (final h in rig.hosts)
          h.id == 'web1' ? h.copyWith(aiAccess: HostAiAccess.off) : h,
      ];
      approvals.answer(c.id, BridgeApprovalAnswer.allowForAWhile);
      expect((await r).text, BridgeRefusals.hostNotAvailable.message);
      expect(grants.current, isEmpty);
      expect(rig.commands, isEmpty);
      expect(lastEntry().outcome, BridgeAuditOutcome.refused);
      expect(
        lastEntry().detail,
        '${BridgeTools.refusedAfterApprovalPrefix}host_not_available',
      );
    });

    test('grants of a host that no longer allows changes are dropped on the '
        'next call', () async {
      grants.grant(testBridgeClient.id, 'web1', const Duration(minutes: 5));
      grants.grant(testBridgeClient.id, 'trm1', const Duration(minutes: 5));
      rig.hosts = [
        for (final h in rig.hosts)
          h.id == 'web1' ? h.copyWith(aiAccess: HostAiAccess.readOnly) : h,
      ];
      await rig.call('server_stats', {'host': 'db'});
      expect(grants.current.map((g) => g.hostId), ['trm1']);
    });
  });

  group('adversarial: the world changes between two steps', () {
    Map<String, Object?> web(String command) => {
      'host': 'web',
      'command': command,
    };

    test('a client revoked while the hosts are re-read after a yes gets no '
        'grant', () async {
      rig.settings = const AppSettings(
        bridgeEnabled: true,
        bridgeTimedApprovalMinutes: 60,
      );
      final r = rig.call('fake_change', web('id'));
      final c = await card();
      rig.onLoadHosts = () async {
        rig.tools.abandonClient(testBridgeClient.id);
        grants.revokeClient(testBridgeClient.id);
        await Future<void>.delayed(Duration.zero);
      };
      approvals.answer(c.id, BridgeApprovalAnswer.allowForAWhile);
      final out = await r;
      expect(out.isError, true);
      expect(grants.current, isEmpty);
      expect(rig.commands, isEmpty);
      await Future<void>.delayed(Duration.zero);
      expect(lastEntry().outcome, BridgeAuditOutcome.refused);
      expect(
        lastEntry().detail,
        '${BridgeTools.refusedAfterApprovalPrefix}'
        '${BridgeTools.revokedMessage}',
      );
    });

    test('"allow for a while" switched off while the card waited is once, '
        'and no grant', () async {
      rig.settings = const AppSettings(
        bridgeEnabled: true,
        bridgeTimedApprovalMinutes: 60,
      );
      final r = rig.call('fake_change', web('id'));
      final c = await card();
      rig.onLoadHosts = () async {
        rig.settings = const AppSettings(bridgeEnabled: true);
      };
      approvals.answer(c.id, BridgeApprovalAnswer.allowForAWhile);
      expect((await r).isError, false);
      expect(grants.current, isEmpty);
      expect(lastEntry().approval, BridgeAuditApproval.once);
    });

    test(
      'a shorter setting while the card waited shortens the grant',
      () async {
        rig.settings = const AppSettings(
          bridgeEnabled: true,
          bridgeTimedApprovalMinutes: 60,
        );
        final r = rig.call('fake_change', web('id'));
        final c = await card();
        rig.onLoadHosts = () async {
          rig.settings = const AppSettings(
            bridgeEnabled: true,
            bridgeTimedApprovalMinutes: 5,
          );
        };
        approvals.answer(c.id, BridgeApprovalAnswer.allowForAWhile);
        expect((await r).isError, false);
        final g = grants.current.single;
        expect(g.expiresAt.difference(g.grantedAt), const Duration(minutes: 5));
      },
    );

    test('a host edited to another address while the card waited is not '
        'run', () async {
      final r = rig.call('fake_change', web('reboot'));
      final c = await card();
      rig.hosts = [
        for (final h in rig.hosts)
          h.id == 'web1' ? h.copyWith(hostname: 'elsewhere.example') : h,
      ];
      approvals.answer(c.id, BridgeApprovalAnswer.allowOnce);
      expect((await r).text, BridgeRefusals.hostNotAvailable.message);
      expect(rig.commands, isEmpty);
    });

    test('a host re-routed through another jump host while the card waited '
        'is not run', () async {
      final r = rig.call('fake_change', web('reboot'));
      final c = await card();
      rig.hosts = [
        for (final h in rig.hosts)
          h.id == 'web1' ? h.withJumpHost('db01') : h,
      ];
      approvals.answer(c.id, BridgeApprovalAnswer.allowOnce);
      expect((await r).text, BridgeRefusals.hostNotAvailable.message);
      expect(rig.commands, isEmpty);
    });

    test('a host edited to another user while the card waited is not '
        'run', () async {
      final r = rig.call('fake_change', web('reboot'));
      final c = await card();
      rig.hosts = [
        for (final h in rig.hosts)
          h.id == 'web1' ? h.copyWith(username: 'root') : h,
      ];
      approvals.answer(c.id, BridgeApprovalAnswer.allowOnce);
      expect((await r).text, BridgeRefusals.hostNotAvailable.message);
      expect(rig.commands, isEmpty);
    });

    test('a command taken off the allowed list while the call was being '
        'planned needs a card', () async {
      var reads = 0;
      rig.onLoadHosts = () async {
        // The second read is the one after planning.
        if (++reads == 2) {
          rig.hosts = [
            for (final h in rig.hosts)
              h.id == 'web1' ? h.copyWith(aiAllowedCommands: const []) : h,
          ];
        }
      };
      final r = rig.call('fake_change', web('uptime'));
      final c = await card();
      expect(rig.commands, isEmpty);
      approvals.answer(c.id, BridgeApprovalAnswer.deny);
      expect((await r).isError, true);
    });

    test('a host stepped down while the call was being planned is refused '
        'even with a live grant', () async {
      grants.grant(testBridgeClient.id, 'web1', const Duration(minutes: 5));
      var reads = 0;
      rig.onLoadHosts = () async {
        if (++reads == 2) {
          rig.hosts = [
            for (final h in rig.hosts)
              h.id == 'web1' ? h.copyWith(aiAccess: HostAiAccess.readOnly) : h,
          ];
        }
      };
      final out = await rig.call('fake_change', web('reboot'));
      expect(out.text, BridgeRefusals.changesNotAllowed.message);
      expect(rig.commands, isEmpty);
      expect(grants.current, isEmpty);
    });

    test('the bridge switched off while the call was being planned shows no '
        'card', () async {
      var reads = 0;
      rig.onLoadHosts = () async {
        if (++reads == 2) rig.settings = const AppSettings();
      };
      final out = await rig.call('fake_change', web('reboot'));
      expect(out.text, BridgeRefusals.bridgeOff.message);
      expect(anyCardShown(), false);
      expect(rig.commands, isEmpty);
    });

    test('a host edited to another address while the call was being planned '
        'is not run, even with a live grant', () async {
      grants.grant(testBridgeClient.id, 'web1', const Duration(minutes: 5));
      var reads = 0;
      rig.onLoadHosts = () async {
        if (++reads == 2) {
          rig.hosts = [
            for (final h in rig.hosts)
              h.id == 'web1' ? h.copyWith(hostname: 'elsewhere.example') : h,
          ];
        }
      };
      final out = await rig.call('fake_change', web('reboot'));
      expect(out.text, BridgeRefusals.hostNotAvailable.message);
      expect(anyCardShown(), false);
      expect(rig.commands, isEmpty);
    });
  });

  group('adversarial: a plan cannot vouch for itself', () {
    BridgeChangeTool liar(BridgeChangeSummary summary) => BridgeChangeTool(
      spec: const BridgeToolSpec(
        name: 'liar',
        description: 'Claims a list match it has no right to.',
        inputSchema: {'type': 'object'},
        kind: BridgeToolKind.change,
      ),
      arguments: const {'host'},
      plan: (args, context) async =>
          BridgeChangePlan(summary: summary, matchesAllowedCommand: true),
      run: (call, plan) async => const BridgeToolResult('ran'),
    );

    Future<void> expectCard(BridgeChangeSummary summary) async {
      await cardWatch.cancel();
      rig = build();
      // Rebuilt rig has only the fake tools; add the liar through a new one.
      final time2 = FakeTime();
      final a = BridgeApprovals(
        timedApprovalMinutes: () => 0,
        clock: time2.clock,
        timer: time2.timer,
      );
      final r2 = BridgeToolsRig(
        temp,
        approvals: a,
        grants: BridgeGrants(clock: time2.clock, timer: time2.timer),
        changeTools: [liar(summary)],
      );
      r2.hosts = rig.hosts;
      final call = r2.call('liar', {'host': 'web'});
      for (var i = 0; i < 200 && a.current.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(a.current, isNotEmpty, reason: 'a card must be shown');
      a.answer(a.current.single.id, BridgeApprovalAnswer.deny);
      expect((await call).isError, true);
    }

    test('a file write is never "on the list"', () async {
      await expectCard(
        const FileWriteSummary(
          path: '/etc/x',
          bytes: 1,
          replacesExisting: true,
          preview: 'x',
        ),
      );
    });

    test('a command on several hosts is never "on the list"', () async {
      await expectCard(
        CommandSummary(command: 'uptime', hostNames: ['web', 'db']),
      );
    });

    test('a command that is not on the list is not, whatever the plan '
        'says', () async {
      await expectCard(
        CommandSummary(command: 'uptime; reboot', hostNames: ['web']),
      );
    });

    test('a service action is never "on the list"', () async {
      await expectCard(
        const ServiceActionSummary(unit: 'nginx', action: 'restart'),
      );
    });
  });

  group('waiting for a person', () {
    test(
      'holds no run slot and does not count against the run deadline',
      () async {
        await cardWatch.cancel();
        rig = build(
          maxRunning: 1,
          callTimeout: const Duration(milliseconds: 300),
        );
        final change = rig.call('fake_change', {
          'host': 'web',
          'command': 'id',
        });
        final c = await card();
        expect(rig.tools.running, 0);
        // A read runs meanwhile, in the only slot.
        rig.serve('db01', (_) => FakeExecSession(stdout: '#=ssg=cpu\n4\n'));
        final read = await rig.call('server_stats', {'host': 'db'});
        expect(read.isError, false);
        // Longer than the whole call deadline, in real time.
        await Future<void>.delayed(const Duration(milliseconds: 450));
        approvals.answer(c.id, BridgeApprovalAnswer.allowOnce);
        final out = await change;
        expect(out.isError, false, reason: out.text);
        expect(out.text, 'exit 0: ran:id');
      },
    );
  });

  group('cancelled while running', () {
    test('the remote work is halted and nothing is returned', () async {
      final web = rig.serve(
        'web1',
        (_) => FakeExecSession(
          stdout: 'SECRET',
          exitDelay: const Duration(seconds: 5),
        ),
      );
      final token = BridgeCallToken();
      final r = rig.call(
        'fake_change',
        {'host': 'web', 'command': 'uptime'},
        null,
        token,
      );
      for (var i = 0; i < 200 && web.sessions.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(web.sessions, hasLength(1));
      token.cancel();
      final out = await r.timeout(const Duration(seconds: 1));
      expect(out.text, BridgeTools.cancelledMessage);
      expect(out.text, isNot(contains('SECRET')));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(web.sessions.single.stdinClosed, true);
      expect(lastEntry().approval, BridgeAuditApproval.allowedCommand);
      expect(rig.entries, hasLength(1));
    });

    test('a token cancelled after the call finished changes nothing', () async {
      final token = BridgeCallToken();
      final r = await rig.call(
        'fake_change',
        {'host': 'web', 'command': 'uptime'},
        null,
        token,
      );
      token.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(r.isError, false);
      expect(rig.entries, hasLength(1));
    });
  });

  group('terminal', () {
    test(
      'a card every time, even with a grant; never a grant from it',
      () async {
        rig.settings = const AppSettings(
          bridgeEnabled: true,
          bridgeTimedApprovalMinutes: 60,
        );
        grants.grant(testBridgeClient.id, 'trm1', const Duration(minutes: 60));
        final first = rig.call('fake_terminal', {'host': 'term'});
        final c = await card();
        expect(c.summary, isA<TerminalSummary>());
        approvals.answer(c.id, BridgeApprovalAnswer.allowForAWhile);
        expect((await first).text, 'terminal opened');
        expect(lastEntry().approval, BridgeAuditApproval.once);
        grants.revokeAll();
        final second = rig.call('fake_terminal', {'host': 'term'});
        approvals.answer((await card()).id, BridgeApprovalAnswer.deny);
        expect((await second).isError, true);
        expect(grants.current, isEmpty);
      },
    );
  });

  group('full control', () {
    setUp(() {
      rig.hosts = [
        ...rig.hosts,
        _h('full1', 'full', HostAiAccess.fullControl),
        _h('full2', 'full2', HostAiAccess.fullControl),
      ];
      rig.serve('full1', (cmd) => FakeExecSession(stdout: 'ran:$cmd'));
      rig.serve('full2', (cmd) => FakeExecSession(stdout: 'ran:$cmd'));
    });

    test('a change runs without a card, audited as full_control', () async {
      final r = await rig.call('fake_change', {
        'host': 'full',
        'command': 'reboot',
      });
      expect(r.isError, false);
      expect(r.text, 'exit 0: ran:reboot');
      expect(anyCardShown(), false);
      expect(lastEntry().approval, BridgeAuditApproval.fullControl);
      expect(lastEntry().outcome, BridgeAuditOutcome.ok);
      expect(grants.current, isEmpty, reason: 'nothing to grant');
    });

    test('a terminal opens without a card, audited as full_control', () async {
      final r = await rig.call('fake_terminal', {'host': 'full'});
      expect(r.text, 'terminal opened');
      expect(anyCardShown(), false);
      expect(lastEntry().approval, BridgeAuditApproval.fullControl);
    });

    test('an allowed-command list is not consulted, so the audit says why',
        () async {
      rig.hosts = [
        for (final h in rig.hosts)
          h.id == 'full1' ? h.copyWith(aiAllowedCommands: ['uptime']) : h,
      ];
      await rig.call('fake_change', {'host': 'full', 'command': 'uptime'});
      expect(lastEntry().approval, BridgeAuditApproval.fullControl);
    });

    test('a locked app and the bridge off still refuse, with no card',
        () async {
      rig.locked = true;
      var r = await rig.call('fake_change', {'host': 'full', 'command': 'id'});
      expect(r.text, BridgeRefusals.appLocked.message);
      rig.locked = false;
      rig.settings = const AppSettings();
      r = await rig.call('fake_terminal', {'host': 'full'});
      expect(r.text, BridgeRefusals.bridgeOff.message);
      expect(anyCardShown(), false);
      expect(rig.commands, isEmpty);
    });

    test('a host raised to full control while its card waited runs', () async {
      final r = rig.call('fake_change', {'host': 'web', 'command': 'whoami'});
      final c = await card();
      rig.hosts = [
        for (final h in rig.hosts)
          h.id == 'web1' ? h.copyWith(aiAccess: HostAiAccess.fullControl) : h,
      ];
      approvals.answer(c.id, BridgeApprovalAnswer.allowOnce);
      expect((await r).text, 'exit 0: ran:whoami');
      expect(lastEntry().approval, BridgeAuditApproval.once);
    });

    test('stepped down from full control while planning: a card again',
        () async {
      var reads = 0;
      rig.onLoadHosts = () async {
        // The first read resolves the host at full control; by the second
        // (after the plan) the user has set it to ask before each change.
        if (++reads == 2) {
          rig.hosts = [
            for (final h in rig.hosts)
              h.id == 'full1'
                  ? h.copyWith(aiAccess: HostAiAccess.askToChange)
                  : h,
          ];
        }
      };
      final r = rig.call('fake_change', {'host': 'full', 'command': 'id'});
      final c = await card();
      approvals.answer(c.id, BridgeApprovalAnswer.deny);
      expect((await r).isError, true);
      expect(rig.commands, isEmpty);
      expect(lastEntry().approval, BridgeAuditApproval.denied);
    });

    test('several hosts: no card only when every one is full control',
        () async {
      final r = await rig.call('fake_multi', {
        'hosts': ['full', 'full2'],
        'command': 'id',
      });
      expect(r.isError, false);
      expect(anyCardShown(), false);
      expect(lastEntry().approval, BridgeAuditApproval.fullControl);

      final mixed = rig.call('fake_multi', {
        'hosts': ['full', 'web'],
        'command': 'id',
      });
      final c = await card();
      approvals.answer(c.id, BridgeApprovalAnswer.allowOnce);
      expect((await mixed).isError, false);
      expect(lastEntry().approval, BridgeAuditApproval.once);
    });

    test('several hosts, full control plus a live grant: no card, audited '
        'as the grant', () async {
      grants.grant(testBridgeClient.id, 'web1', const Duration(minutes: 5));
      final r = await rig.call('fake_multi', {
        'hosts': ['full', 'web'],
        'command': 'id',
      });
      expect(r.isError, false);
      expect(anyCardShown(), false);
      expect(lastEntry().approval, BridgeAuditApproval.grant);
    });
  });

  group('MCP cancellation through the real tools', () {
    String callLine(Object id, Map<String, Object?> args) => jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': 'tools/call',
      'params': {'name': 'fake_change', 'arguments': args},
    });
    String cancelLine(Object id) => jsonEncode({
      'jsonrpc': '2.0',
      'method': 'notifications/cancelled',
      'params': {'requestId': id},
    });

    test('cancelled while waiting for approval: the card is withdrawn and no '
        'reply is sent', () async {
      final conn = _Conn();
      final done = McpServer(tools: rig.tools).serve(conn);
      conn.incoming.add(callLine(5, {'host': 'web', 'command': 'reboot'}));
      final c = await card();
      conn.incoming.add(cancelLine(5));
      for (var i = 0; i < 200 && approvals.current.isNotEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(approvals.current, isEmpty);
      approvals.answer(c.id, BridgeApprovalAnswer.allowOnce);
      await conn.incoming.close();
      await done;
      expect(conn.sent, isEmpty);
      expect(rig.commands, isEmpty);
      await Future<void>.delayed(Duration.zero);
      expect(rig.entries.single.approval, BridgeAuditApproval.withdrawn);
      expect(rig.entries.single.detail, BridgeTools.cancelledMessage);
    });

    test('cancelled while running: the remote work is halted and no reply is '
        'sent', () async {
      final web = rig.serve(
        'web1',
        (_) => FakeExecSession(
          stdout: 'SECRET',
          exitDelay: const Duration(seconds: 5),
        ),
      );
      final conn = _Conn();
      final done = McpServer(tools: rig.tools).serve(conn);
      conn.incoming.add(callLine('r1', {'host': 'web', 'command': 'uptime'}));
      for (var i = 0; i < 200 && web.sessions.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      conn.incoming.add(cancelLine('r1'));
      await conn.incoming.close();
      await done.timeout(const Duration(seconds: 2));
      expect(conn.sent, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(web.sessions.single.stdinClosed, true);
      expect(web.sessions.single.wasClosed, true);
      expect(rig.entries, hasLength(1));
    });
  });

  test('a change tool is listed with its kind, after the read tools', () {
    final names = rig.tools.tools.map((t) => t.name).toList();
    expect(names.sublist(names.length - 3), [
      'fake_change',
      'fake_terminal',
      'fake_multi',
    ]);
    // Only change, terminal and desktop tools go through the change path.
    for (final kind in [
      BridgeToolKind.read,
      BridgeToolKind.terminalUse,
      BridgeToolKind.desktopUse,
      BridgeToolKind.jobUse,
    ]) {
      expect(
        () => BridgeChangeTool(
          spec: BridgeToolSpec(
            name: 'x',
            description: '',
            inputSchema: const {},
            kind: kind,
          ),
          arguments: const {'host'},
          plan: (a, c) async =>
              const BridgeChangePlan(summary: TerminalSummary()),
          run: (c, p) async => const BridgeToolResult(''),
        ),
        throwsArgumentError,
        reason: kind.name,
      );
    }
    expect(
      BridgeChangeTool(
        spec: const BridgeToolSpec(
          name: 'x',
          description: '',
          inputSchema: {},
          kind: BridgeToolKind.desktop,
        ),
        arguments: const {'host'},
        plan: (a, c) async =>
            const BridgeChangePlan(summary: TerminalSummary()),
        run: (c, p) async => const BridgeToolResult(''),
      ).spec.kind,
      BridgeToolKind.desktop,
    );
  });
}
