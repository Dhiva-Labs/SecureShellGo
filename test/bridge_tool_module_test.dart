import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/app_settings.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/models/host_ai_access.dart';
import 'package:secure_shell_go/services/bridge/bridge_approvals.dart';
import 'package:secure_shell_go/services/bridge/bridge_audit.dart';
import 'package:secure_shell_go/services/bridge/bridge_client_store.dart';
import 'package:secure_shell_go/services/bridge/bridge_grants.dart';
import 'package:secure_shell_go/services/bridge/bridge_policy.dart';
import 'package:secure_shell_go/services/bridge/bridge_tool_module.dart';
import 'package:secure_shell_go/services/bridge/bridge_tool_types.dart';
import 'package:secure_shell_go/services/bridge/bridge_tools.dart';

import 'fake_exec_session.dart';
import 'support/bridge_fakes.dart';
import 'support/bridge_temp_dir.dart';

// The seam later tool groups (jobs, the desktop) plug into, the built-in
// assistant's identity, and a controller token on the tool path.

/// A desktop the test pretends is open, owned by [clientId].
class _Desktop {
  _Desktop(this.clientId, this.host);

  final String clientId;
  final Host host;
}

/// A module like the desktop one will be: a desktop-use tool that finds the
/// caller's own desktop by id, decides, and returns a screenshot; a read
/// tool that runs a command; and a bug-shaped tool that forgets the policy.
class _FakeModule extends BridgeToolModule {
  final Map<String, _Desktop> desktops = {};
  final List<String> events = [];

  static const _shot = BridgeToolSpec(
    name: 'fake_screenshot',
    description: 'A screenshot of a desktop you opened (test only).',
    inputSchema: {'type': 'object'},
    kind: BridgeToolKind.desktopUse,
  );
  static const _uptime = BridgeToolSpec(
    name: 'fake_uptime',
    description: 'Runs uptime (test only).',
    inputSchema: {'type': 'object'},
    kind: BridgeToolKind.read,
  );
  static const _careless = BridgeToolSpec(
    name: 'fake_careless',
    description: 'Forgets to decide (test only).',
    inputSchema: {'type': 'object'},
    kind: BridgeToolKind.read,
  );
  static const _sneaky = BridgeToolSpec(
    name: 'fake_sneaky',
    description: 'Reaches for a server without an allow (test only).',
    inputSchema: {'type': 'object'},
    kind: BridgeToolKind.read,
  );

  @override
  List<BridgeToolSpec> get specs => const [_shot, _uptime, _careless, _sneaky];

  @override
  List<BridgeChangeTool> get changeTools => [
    BridgeChangeTool(
      spec: const BridgeToolSpec(
        name: 'fake_open_desktop',
        description: 'Opens a desktop (test only).',
        inputSchema: {'type': 'object'},
        kind: BridgeToolKind.desktop,
      ),
      arguments: const {'host'},
      plan: (args, context) async =>
          const BridgeChangePlan(summary: TerminalSummary()),
      run: (call, plan) async {
        desktops['d1'] = _Desktop('opener', call.host!);
        return const BridgeToolResult('desktop d1');
      },
    ),
  ];

  @override
  Map<String, Object?> auditArgs(String tool, Map<String, Object?> args) =>
      tool == 'fake_screenshot' ? {'desktop_id': args['desktop_id']} : args;

  @override
  Future<BridgeModuleOutcome> call(BridgeModuleCall call) async {
    switch (call.spec.name) {
      case 'fake_screenshot':
        final raw = call.rawArgs['desktop_id'];
        final desktop = raw is String ? desktops[raw] : null;
        final mine = desktop != null && desktop.clientId == call.client.id;
        Host? host;
        if (mine) {
          call.auditHost = desktop.host.label;
          for (final h in await call.hosts()) {
            if (bridgeSameServer(h, desktop.host)) host = h;
          }
        }
        final decision = call.decide(host: host, ownsLiveDesktop: mine);
        if (decision is BridgeRefuse) {
          return BridgeModuleOutcome.refused(decision);
        }
        call.args(const {'desktop_id'});
        return BridgeModuleOutcome.image(
          Uint8List.fromList([1, 2, 3]),
          imageMimeType: 'image/png',
          text: 'A screenshot. password=SECRET',
        );
      case 'fake_uptime':
        final host = await call.resolveHost(call.rawArgs['host']);
        final decision = call.decide(host: host);
        if (decision is BridgeRefuse) {
          return BridgeModuleOutcome.refused(decision);
        }
        call.args(const {'host'});
        final out = await call.withServer(host!, (c) => c.exec('uptime'));
        return BridgeModuleOutcome.ok('up: ${out.stdout}');
      case 'fake_careless':
        return const BridgeModuleOutcome.ok('ran without asking');
      case 'fake_sneaky':
        final host = await call.resolveHost('web');
        await call.withServer(host!, (c) => c.exec('reboot'));
        return const BridgeModuleOutcome.ok('rebooted');
    }
    return const BridgeModuleOutcome.error('unknown');
  }

  @override
  Future<void> ended(BridgeModuleEnd reason) async =>
      events.add('ended:${reason.name}');
}

final BridgeClient _phone = BridgeClient(
  id: 'p1',
  name: 'Phone',
  tokenHash: 'z',
  createdAt: DateTime.utc(2026),
  role: BridgeClientRole.controller,
);

void main() {
  late Directory temp;
  late BridgeToolsRig rig;
  late _FakeModule module;
  late BridgeApprovals approvals;
  late BridgeGrants grants;

  setUp(() async {
    temp = await bridgeTempDir('bridge_module');
    module = _FakeModule();
    approvals = BridgeApprovals(timedApprovalMinutes: () => 0);
    grants = BridgeGrants();
    rig = BridgeToolsRig(
      temp,
      scrub: (s) => s.replaceAll('SECRET', '[redacted]'),
      approvals: approvals,
      grants: grants,
      modules: [module],
    );
    rig.hosts = [
      bridgeHost('web1', 'web'),
      bridgeHost(
        'dsk1',
        'desk',
        access: HostAiAccess.askToChange,
      ).copyWith(aiDesktop: true),
      bridgeHost('full1', 'full', access: HostAiAccess.fullControl),
      bridgeHost('sec1', 'secret', access: HostAiAccess.off),
    ];
    rig.serve('web1', (cmd) => FakeExecSession(stdout: 'ran:$cmd'));
  });

  tearDown(() async {
    await approvals.dispose();
    await grants.dispose();
    await rig.connections.closeAll();
    await deleteTempDir(temp);
  });

  Future<BridgeApprovalRequest> card() async {
    for (var i = 0; i < 200; i++) {
      if (approvals.current.isNotEmpty) return approvals.current.last;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('no approval card appeared');
  }

  group('registration', () {
    test('a module\'s tools are listed with the rest', () {
      final names = rig.tools.tools.map((t) => t.name).toSet();
      expect(
        names,
        containsAll([
          'fake_screenshot',
          'fake_uptime',
          'fake_open_desktop',
          'list_hosts',
        ]),
      );
      expect(module.handles('fake_screenshot'), isTrue);
      expect(module.handles('fake_open_desktop'), isFalse);
      expect(rig.tools.modules, [module]);
    });

    test('a module may not serve a change, terminal or desktop tool itself',
        () {
      for (final kind in [
        BridgeToolKind.change,
        BridgeToolKind.terminal,
        BridgeToolKind.desktop,
      ]) {
        expect(
          () => BridgeToolsRig(temp, modules: [_OneSpec(kind, 'x')]),
          throwsArgumentError,
          reason: kind.name,
        );
      }
      for (final kind in [
        BridgeToolKind.read,
        BridgeToolKind.terminalUse,
        BridgeToolKind.desktopUse,
        BridgeToolKind.jobUse,
      ]) {
        BridgeToolsRig(temp, modules: [_OneSpec(kind, 'x')]);
      }
    });

    test('a name already taken is refused', () {
      expect(
        () => BridgeToolsRig(
          temp,
          modules: [_OneSpec(BridgeToolKind.read, 'list_hosts')],
        ),
        throwsArgumentError,
      );
      expect(
        () => BridgeToolsRig(
          temp,
          modules: [
            _OneSpec(BridgeToolKind.read, 'x'),
            _OneSpec(BridgeToolKind.jobUse, 'x'),
          ],
        ),
        throwsArgumentError,
      );
    });
  });

  group('a module call', () {
    test('runs on an allowed host, audited once by the tool host', () async {
      final r = await rig.call('fake_uptime', {'host': 'web'});
      expect(r.isError, false);
      expect(r.text, contains('ran:'));
      expect(rig.entries, hasLength(1));
      expect(rig.entries.single.tool, 'fake_uptime');
      expect(rig.entries.single.host, 'web');
      expect(rig.entries.single.outcome, BridgeAuditOutcome.ok);
    });

    test('a hidden host is refused by the policy, nothing runs', () async {
      final r = await rig.call('fake_uptime', {'host': 'secret'});
      expect(r.text, BridgeRefusals.hostNotAvailable.message);
      expect(rig.entries.single.detail, 'host_not_available');
      expect(rig.commands, isEmpty);
    });

    test('bridge off and a locked app refuse a module tool too', () async {
      rig.settings = const AppSettings();
      expect(
        (await rig.call('fake_uptime', {'host': 'web'})).text,
        BridgeRefusals.bridgeOff.message,
      );
      rig.settings = const AppSettings(bridgeEnabled: true);
      rig.locked = true;
      expect(
        (await rig.call('fake_uptime', {'host': 'web'})).text,
        BridgeRefusals.appLocked.message,
      );
      expect(rig.commands, isEmpty);
    });

    test('a module that skips the policy returns nothing', () async {
      final r = await rig.call('fake_careless');
      expect(r.isError, true);
      expect(r.text, isNot(contains('ran without asking')));
      expect(rig.entries.single.detail, 'not_decided');
    });

    test('a module cannot reach a server without an allow', () async {
      final r = await rig.call('fake_sneaky');
      expect(r.isError, true);
      expect(r.text, isNot(contains('rebooted')));
      expect(rig.commands, isEmpty);
    });

    test('invalid arguments refuse after the decision', () async {
      final r = await rig.call('fake_uptime', {'host': 'web', 'x': 1});
      expect(rig.entries.single.detail, 'invalid_arguments');
      expect(r.isError, true);
      expect(rig.commands, isEmpty);
    });
  });

  group('desktop use through a module', () {
    test('only the client that opened the desktop may use it; an image '
        'comes back with its text redacted', () async {
      module.desktops['d1'] = _Desktop(testBridgeClient.id, rig.hosts[1]);
      final r = await rig.tools.call(testBridgeClient, 'fake_screenshot', {
        'desktop_id': 'd1',
      });
      expect(r.isError, false);
      expect(r.image, Uint8List.fromList([1, 2, 3]));
      expect(r.imageMimeType, 'image/png');
      expect(r.text, isNot(contains('SECRET')));
      await Future<void>.delayed(Duration.zero);
      expect(rig.entries.single.host, 'desk');
      expect(rig.entries.single.args, '{"desktop_id":"d1"}');

      final other = BridgeClient(
        id: 'c9',
        name: 'Other',
        tokenHash: 'q',
        createdAt: DateTime.utc(2026),
      );
      final theirs = await rig.call('fake_screenshot', {
        'desktop_id': 'd1',
      }, other);
      final unknown = await rig.call('fake_screenshot', {'desktop_id': 'zz'});
      expect(theirs.text, BridgeRefusals.desktopNotAvailable.message);
      expect(unknown.text, theirs.text);
      // Another client's desktop never names its host in the log.
      expect(rig.entries.last.host, isNull);
    });

    test('the desktop switch turned off refuses further use', () async {
      module.desktops['d1'] = _Desktop(testBridgeClient.id, rig.hosts[1]);
      rig.hosts = [
        for (final h in rig.hosts)
          h.id == 'dsk1' ? h.copyWith(aiDesktop: false) : h,
      ];
      final r = await rig.call('fake_screenshot', {'desktop_id': 'd1'});
      expect(r.text, BridgeRefusals.desktopNotAllowed.message);
    });

    test('opening a desktop goes through the card, or full control', () async {
      final asked = rig.call('fake_open_desktop', {'host': 'desk'});
      final c = await card();
      expect(c.tool, 'fake_open_desktop');
      approvals.answer(c.id, BridgeApprovalAnswer.allowOnce);
      expect((await asked).text, 'desktop d1');
      expect(rig.entries.last.approval, BridgeAuditApproval.once);

      final full = await rig.call('fake_open_desktop', {'host': 'full'});
      expect(full.text, 'desktop d1');
      expect(rig.entries.last.approval, BridgeAuditApproval.fullControl);

      final refused = await rig.call('fake_open_desktop', {'host': 'web'});
      expect(refused.text, BridgeRefusals.changesNotAllowed.message);
    });
  });

  group('the built-in assistant', () {
    test('uses its own switch, never the channel\'s', () async {
      rig.settings = const AppSettings(bridgeEnabled: true);
      rig.builtinOn = false;
      var r = await rig.call('list_hosts', const {}, BridgeClient.builtin);
      expect(r.text, BridgeRefusals.bridgeOff.message);

      rig.settings = const AppSettings();
      rig.builtinOn = true;
      r = await rig.call('list_hosts', const {}, BridgeClient.builtin);
      expect(r.isError, false);
      expect(rig.entries.last.client, 'Built-in assistant');
      // ...and its switch never lets a paired assistant in.
      r = await rig.call('list_hosts');
      expect(r.text, BridgeRefusals.bridgeOff.message);
    });

    test('its changes get a card in its name, and a grant keyed to it',
        () async {
      rig.builtinOn = true;
      rig.settings = const AppSettings(bridgeTimedApprovalMinutes: 10);
      final r = rig.call('fake_open_desktop', {
        'host': 'desk',
      }, BridgeClient.builtin);
      final c = await card();
      expect(c.client.id, BridgeClient.builtinId);
      expect(c.client.name, 'Built-in assistant');
      approvals.answer(c.id, BridgeApprovalAnswer.allowOnce);
      expect((await r).isError, false);
      expect(rig.entries.last.client, 'Built-in assistant');
      expect(rig.entries.last.approval, BridgeAuditApproval.once);
      grants.grant(
        BridgeClient.builtinId,
        'dsk1',
        const Duration(minutes: 5),
        clientName: BridgeClient.builtin.name,
      );
      expect(grants.hasLive(BridgeClient.builtinId, 'dsk1'), isTrue);
      expect(grants.hasLive(testBridgeClient.id, 'dsk1'), isFalse);
    });

    test('switching the channel off spares its calls in flight', () async {
      rig.builtinOn = true;
      final web = rig.serve(
        'web1',
        (_) => FakeExecSession(
          stdout: 'late',
          exitDelay: const Duration(milliseconds: 200),
        ),
      );
      final mine = rig.tools.call(BridgeClient.builtin, 'fake_uptime', {
        'host': 'web',
      });
      final theirs = rig.tools.call(testBridgeClient, 'fake_uptime', {
        'host': 'web',
      });
      for (var i = 0; i < 200 && web.sessions.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      rig.tools.abandonAll(except: {BridgeClient.builtinId});
      expect((await theirs).text, BridgeTools.switchedOffMessage);
      final kept = await mine;
      expect(kept.isError, false);
      expect(kept.text, contains('late'));
    });
  });

  group('a controller token on the tool path', () {
    test('is refused before anything is looked up, for every tool', () async {
      for (final name in ['list_hosts', 'fake_uptime', 'fake_open_desktop']) {
        final r = await rig.call(name, {'host': 'web'}, _phone);
        expect(r.isError, true);
        expect(r.text, BridgeToolRefusals.notAnAssistant.message);
        expect(rig.entries.last.detail, 'not_an_assistant');
      }
      expect(rig.commands, isEmpty);
      expect(approvals.current, isEmpty);
    });
  });
}

class _OneSpec extends BridgeToolModule {
  _OneSpec(this.kind, this.name);

  final BridgeToolKind kind;
  final String name;

  @override
  List<BridgeToolSpec> get specs => [
    BridgeToolSpec(
      name: name,
      description: '',
      inputSchema: const {},
      kind: kind,
    ),
  ];
}
