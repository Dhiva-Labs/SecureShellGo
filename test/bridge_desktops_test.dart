import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/models/host_ai_access.dart';
import 'package:secure_shell_go/services/assistant_drive.dart';
import 'package:secure_shell_go/services/bridge/bridge_approvals.dart';
import 'package:secure_shell_go/services/bridge/bridge_audit.dart';
import 'package:secure_shell_go/services/bridge/bridge_client_store.dart';
import 'package:secure_shell_go/services/bridge/bridge_desktops.dart';
import 'package:secure_shell_go/services/bridge/bridge_grants.dart';
import 'package:secure_shell_go/services/bridge/bridge_policy.dart';
import 'package:secure_shell_go/services/bridge/bridge_tool_module.dart';
import 'package:secure_shell_go/services/bridge/bridge_tool_types.dart';
import 'package:secure_shell_go/services/bridge/mcp_server.dart';
import 'package:secure_shell_go/services/remote_desktop/csrd_keymap.dart';
import 'package:secure_shell_go/services/remote_desktop/csrd_messages.dart';
import 'package:secure_shell_go/services/remote_desktop/remote_screen_session.dart';

import 'support/bridge_fake_time.dart';
import 'support/bridge_fakes.dart';
import 'support/bridge_temp_dir.dart';

// The assistant's desktop tools, against a fake remote screen: no real
// remote desktop is opened here (that needs a signed-in graphical session
// on a server, which a test machine does not have).

/// Records the input the tools send.
class _FakeSession implements RemoteScreenSession {
  final List<String> sent = [];

  @override
  bool viewOnly = false;

  @override
  void pointerMove(int x, int y) => sent.add('move $x,$y');

  @override
  void pointerButton(int button, {required bool down}) =>
      sent.add('button $button ${down ? 'down' : 'up'}');

  @override
  void scroll(int dx, int dy) => sent.add('scroll $dx,$dy');

  @override
  void key(int evdevCode, {required bool down}) =>
      sent.add('key $evdevCode ${down ? 'down' : 'up'}');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeScreen implements BridgeDesktopScreen {
  _FakeScreen() {
    _first.complete();
  }

  @override
  final _FakeSession session = _FakeSession();

  @override
  int width = 1920;

  @override
  int height = 1080;

  final _first = Completer<void>();
  final _done = Completer<void>();
  var closed = 0;
  final List<(int, int)> captures = [];
  Uint8List png = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 1, 2, 3]);

  /// Called while a capture is in progress (to take it over meanwhile).
  void Function()? duringCapture;

  /// The remote side ends the session by itself.
  void drop() => _done.complete();

  @override
  Future<void> get firstFrame => _first.future;

  @override
  Future<void> get done => _done.future;

  @override
  Future<Uint8List?> capturePng(int width, int height) async {
    captures.add((width, height));
    duringCapture?.call();
    return png;
  }

  @override
  Future<void> close() async {
    closed++;
    if (!_done.isCompleted) _done.complete();
  }
}

final BridgeClient _other = BridgeClient(
  id: 'c2',
  name: 'Other assistant',
  tokenHash: 'y',
  createdAt: DateTime.utc(2026),
);

Host _deskHost({
  String id = 'dsk1',
  String label = 'desk',
  HostAiAccess access = HostAiAccess.askToChange,
  bool desktop = true,
}) => bridgeHost(id, label, access: access).copyWith(
  aiDesktop: desktop,
  // Set on the host, and still never on the desktop's connection.
  agentForwarding: true,
  x11Forwarding: true,
);

void main() {
  late Directory temp;
  late BridgeToolsRig rig;
  late BridgeApprovals approvals;
  late BridgeGrants grants;
  late BridgeDesktops desktops;
  late FakeTime time;
  late List<Host> opened;
  late List<_FakeScreen> screens;
  late Future<BridgeDesktopScreen> Function(Host host) opener;

  setUp(() async {
    temp = await bridgeTempDir('bridge_desktops');
    time = FakeTime();
    opened = [];
    screens = [];
    opener = (host) async {
      final s = _FakeScreen();
      screens.add(s);
      return s;
    };
    desktops = BridgeDesktops(
      open: (host) {
        opened.add(host);
        return opener(host);
      },
      clock: time.clock,
      timer: time.timer,
    );
    approvals = BridgeApprovals(timedApprovalMinutes: () => 15);
    grants = BridgeGrants();
    rig = BridgeToolsRig(
      temp,
      approvals: approvals,
      grants: grants,
      modules: [desktops],
    );
    rig.hosts = [
      _deskHost(),
      _deskHost(id: 'full1', label: 'full', access: HostAiAccess.fullControl,
          desktop: false),
      _deskHost(id: 'nodesk', label: 'nodesk', desktop: false),
      bridgeHost('ro1', 'ro'),
      bridgeHost('sec1', 'secret', access: HostAiAccess.off),
    ];
  });

  tearDown(() async {
    await desktops.dispose();
    await approvals.dispose();
    await grants.dispose();
    await rig.connections.closeAll();
    await deleteTempDir(temp);
  });

  Future<BridgeApprovalRequest> card() =>
      approvals.pending.firstWhere((l) => l.isNotEmpty).then((l) => l.last);

  /// Opens a desktop on [host], answering the card with [answer] when one
  /// comes. Returns the result and the desktop id it named.
  Future<({String text, bool isError, String? id})> open(
    String host, {
    BridgeApprovalAnswer? answer = BridgeApprovalAnswer.allowOnce,
    BridgeClient? client,
  }) async {
    final pending = rig.call('open_desktop', {'host': host}, client);
    if (answer != null) {
      final request = await card();
      approvals.answer(request.id, answer);
    }
    final r = await pending;
    final id = RegExp(r'desktop_id: (\S+)').firstMatch(r.text)?.group(1);
    return (text: r.text, isError: r.isError, id: id);
  }

  Future<BridgeToolResult> use(
    String tool,
    Map<String, Object?> args, [
    BridgeClient? client,
  ]) async {
    final r = await rig.tools.call(client ?? testBridgeClient, tool, args);
    await Future<void>.delayed(Duration.zero);
    return r;
  }

  void expectNotAvailable(BridgeToolResult r, [BridgeRefuse? exactly]) {
    expect(r.isError, isTrue, reason: r.text);
    expect(r.hasImage, isFalse);
    expect(rig.entries.last.detail, 'desktop_not_available');
    if (exactly != null) expect(r.text, exactly.message);
  }

  group('registration', () {
    test('open_desktop goes through the change path; the rest are '
        'desktop-use tools', () {
      final specs = {for (final s in rig.tools.tools) s.name: s};
      expect(specs['open_desktop']!.kind, BridgeToolKind.desktop);
      for (final name in [
        'desktop_screenshot',
        'desktop_click',
        'desktop_move',
        'desktop_scroll',
        'desktop_type',
        'desktop_key',
        'close_desktop',
      ]) {
        expect(specs[name]!.kind, BridgeToolKind.desktopUse, reason: name);
        expect(desktops.handles(name), isTrue);
      }
      expect(desktops.handles('open_desktop'), isFalse);
      expect(desktops.changeTools.single.spec.name, 'open_desktop');
    });
  });

  group('open_desktop and the policy', () {
    test('a host without the desktop switch: desktop_not_allowed, no card, '
        'nothing opened', () async {
      final r = await open('nodesk', answer: null);
      expect(r.isError, isTrue);
      expect(r.text, BridgeRefusals.desktopNotAllowed.message);
      expect(rig.entries.last.detail, 'desktop_not_allowed');
      expect(approvals.current, isEmpty);
      expect(opened, isEmpty);
    });

    test('read-only and closed hosts are refused as for any change',
        () async {
      expect((await open('ro', answer: null)).text,
          BridgeRefusals.changesNotAllowed.message);
      expect((await open('secret', answer: null)).text,
          BridgeRefusals.hostNotAvailable.message);
      expect(opened, isEmpty);
    });

    test('ask to change with the switch on: a desktop card; deny opens '
        'nothing', () async {
      final pending = rig.call('open_desktop', {'host': 'desk'});
      final request = await card();
      expect(request.summary, isA<DesktopSummary>());
      expect(request.tool, 'open_desktop');
      expect(request.hostName, 'desk');
      expect(request.client.id, testBridgeClient.id);
      approvals.answer(request.id, BridgeApprovalAnswer.deny);
      final r = await pending;
      expect(r.isError, isTrue);
      expect(opened, isEmpty);
      expect(rig.entries.last.approval, BridgeAuditApproval.denied);
    });

    test('a yes opens it, without forwarding, and says the id and sizes',
        () async {
      final r = await open('desk');
      expect(r.isError, isFalse, reason: r.text);
      expect(r.id, startsWith('desk-'));
      expect(r.text, contains('Screen: 1920 x 1080 pixels'));
      expect(r.text, contains('Screenshots are 1280 x 720 pixels'));
      expect(opened.single.id, 'dsk1');
      expect(opened.single.agentForwarding, isFalse);
      expect(opened.single.x11Forwarding, isFalse);
      expect(rig.entries.last.approval, BridgeAuditApproval.once);
      final live = desktops.current.single;
      expect(live.desktopId, r.id);
      expect(live.state, AssistantDriveState.driving);
      expect(live.clientName, testBridgeClient.name);
      expect(desktops.driveOf(r.id!)!.isDriving, isTrue);
      expect(desktops.screenOf(r.id!), same(screens.single));
    });

    test('"allow for a while" counts as once: no grant, and the next one '
        'asks again', () async {
      final first = await open('desk',
          answer: BridgeApprovalAnswer.allowForAWhile);
      expect(first.isError, isFalse);
      expect(rig.entries.last.approval, BridgeAuditApproval.once);
      expect(grants.current, isEmpty);
      await use('close_desktop', {'desktop_id': first.id});
      final pending = rig.call('open_desktop', {'host': 'desk'});
      final request = await card();
      approvals.answer(request.id, BridgeApprovalAnswer.deny);
      await pending;
    });

    test('a live time-limited approval and an allowed command never skip '
        'the card', () async {
      rig.hosts = [
        _deskHost().copyWith(aiAllowedCommands: ['open_desktop']),
      ];
      grants.grant(testBridgeClient.id, 'dsk1', const Duration(minutes: 10));
      final pending = rig.call('open_desktop', {'host': 'desk'});
      final request = await card();
      expect(request.summary, isA<DesktopSummary>());
      approvals.answer(request.id, BridgeApprovalAnswer.deny);
      expect((await pending).isError, isTrue);
      expect(opened, isEmpty);
    });

    test('full control: no card, audited as full_control', () async {
      final r = await open('full', answer: null);
      expect(r.isError, isFalse, reason: r.text);
      expect(approvals.current, isEmpty);
      expect(rig.entries.last.approval, BridgeAuditApproval.fullControl);
    });

    test('a second desktop is refused before any card, from any client',
        () async {
      await open('full', answer: null);
      final again = await open('desk', answer: null);
      expect(again.text, BridgeDesktopRefusals.limit.message);
      expect(rig.entries.last.detail, 'desktop_limit');
      final other = await open('full', answer: null, client: _other);
      expect(other.text, BridgeDesktopRefusals.limit.message);
      expect(opened, hasLength(1));
    });

    test('one the user took over does not count against the limit',
        () async {
      final first = await open('full', answer: null);
      desktops.takeOver(first.id!);
      final second = await open('full', answer: null);
      expect(second.isError, isFalse, reason: second.text);
    });

    test('a desktop that cannot be opened says why and leaves nothing',
        () async {
      opener = (_) async => throw Exception('no desktop is signed in');
      final r = await open('full', answer: null);
      expect(r.isError, isTrue);
      expect(desktops.current, isEmpty);
      expect(desktops.liveCount, 0);
      // The slot is free again.
      opener = (host) async => _FakeScreen();
      expect((await open('full', answer: null)).isError, isFalse);
    });

    test('the bridge switched off while it opened: closed as it lands',
        () async {
      final gate = Completer<void>();
      final screen = _FakeScreen();
      opener = (_) async {
        await gate.future;
        return screen;
      };
      final pending = open('full', answer: null);
      await Future<void>.delayed(Duration.zero);
      await desktops.ended(BridgeModuleEnd.bridgeOff);
      gate.complete();
      final r = await pending;
      expect(r.isError, isTrue);
      expect(screen.closed, greaterThan(0));
      expect(desktops.current, isEmpty);
    });
  });

  group('using it', () {
    late String id;
    late _FakeScreen screen;

    setUp(() async {
      final r = await open('desk');
      id = r.id!;
      screen = screens.single;
    });

    test('a screenshot is an image result, scaled, that reaches the MCP '
        'layer as image content', () async {
      final r = await use('desktop_screenshot', {'desktop_id': id});
      expect(r.isError, isFalse, reason: r.text);
      expect(r.image, screen.png);
      expect(r.imageMimeType, 'image/png');
      expect(screen.captures.single, (1280, 720));
      expect(r.text, contains('1280 x 720 pixels'));
      expect(r.text, contains("scaled down from the screen's 1920 x 1080"));
      final mcp = mcpToolResultContent(r);
      final content = mcp['content']! as List;
      expect(content.first, {
        'type': 'image',
        'data': base64Encode(screen.png),
        'mimeType': 'image/png',
      });
      expect((content[1] as Map)['type'], 'text');
      expect(mcp['isError'], isFalse);
      final entry = rig.entries.last;
      expect(entry.tool, 'desktop_screenshot');
      expect(entry.host, 'desk');
      expect(entry.outcome, BridgeAuditOutcome.ok);
    });

    test('a small screen is not scaled', () async {
      screen
        ..width = 1024
        ..height = 768;
      final r = await use('desktop_screenshot', {'desktop_id': id});
      expect(screen.captures.single, (1024, 768));
      expect(r.text, contains('not scaled'));
    });

    test('clicks land on the real screen pixel under the screenshot pixel',
        () async {
      var r = await use('desktop_click', {'desktop_id': id, 'x': 640, 'y': 360});
      expect(r.isError, isFalse, reason: r.text);
      expect(screen.session.sent, [
        'move 960,540',
        'button ${CsrdButton.left} down',
        'button ${CsrdButton.left} up',
      ]);
      screen.session.sent.clear();
      r = await use('desktop_click', {
        'desktop_id': id,
        'x': 1279,
        'y': 719,
        'button': 'right',
        'double': true,
      });
      expect(r.isError, isFalse, reason: r.text);
      expect(screen.session.sent, [
        'move 1919,1079',
        'button ${CsrdButton.right} down',
        'button ${CsrdButton.right} up',
        'button ${CsrdButton.right} down',
        'button ${CsrdButton.right} up',
      ]);
      screen.session.sent.clear();
      await use('desktop_click', {
        'desktop_id': id,
        'x': 0,
        'y': 0,
        'button': 'middle',
      });
      expect(screen.session.sent.first, 'move 0,0');
      expect(screen.session.sent[1], 'button ${CsrdButton.middle} down');
    });

    test('coordinates outside the screenshot, and bad buttons, are refused '
        'and send nothing', () async {
      for (final args in <Map<String, Object?>>[
        {'x': 1280, 'y': 0},
        {'x': 0, 'y': 720},
        {'x': -1, 'y': 0},
        {'x': 1.5, 'y': 0},
        {'x': '3', 'y': 0},
        {'y': 0},
        {'x': 1, 'y': 1, 'button': 'back'},
        {'x': 1, 'y': 1, 'double': 'yes'},
        {'x': 1, 'y': 1, 'extra': 1},
      ]) {
        final r = await use('desktop_click', {'desktop_id': id, ...args});
        expect(r.isError, isTrue, reason: '$args');
        expect(rig.entries.last.detail, 'invalid_arguments', reason: '$args');
      }
      expect(screen.session.sent, isEmpty);
    });

    test('move and scroll map the same way; positive dy scrolls down',
        () async {
      await use('desktop_move', {'desktop_id': id, 'x': 100, 'y': 50});
      expect(screen.session.sent, ['move 150,75']);
      screen.session.sent.clear();
      final r = await use('desktop_scroll', {
        'desktop_id': id,
        'x': 100,
        'y': 50,
        'dy': 3,
        'dx': -1,
      });
      expect(r.isError, isFalse, reason: r.text);
      expect(screen.session.sent, ['move 150,75', 'scroll -120,-360']);
      final none = await use('desktop_scroll', {
        'desktop_id': id,
        'x': 1,
        'y': 1,
      });
      expect(none.isError, isTrue);
      final far = await use('desktop_scroll', {
        'desktop_id': id,
        'x': 1,
        'y': 1,
        'dy': 51,
      });
      expect(far.isError, isTrue);
    });

    test('after the screen size changed, clicks wait for a new screenshot',
        () async {
      await use('desktop_screenshot', {'desktop_id': id});
      screen
        ..width = 1280
        ..height = 1024;
      final r = await use('desktop_click', {'desktop_id': id, 'x': 1, 'y': 1});
      expect(r.isError, isTrue);
      expect(r.text, contains('screen size changed'));
      expect(screen.session.sent, isEmpty);
      await use('desktop_screenshot', {'desktop_id': id});
      final ok = await use('desktop_click', {
        'desktop_id': id,
        'x': 1279,
        'y': 1023,
      });
      expect(ok.isError, isFalse, reason: ok.text);
      expect(screen.session.sent.first, 'move 1279,1023');
    });

    test('typing sends key presses, Shift for capitals', () async {
      final r = await use('desktop_type', {'desktop_id': id, 'text': 'aB\n'});
      expect(r.isError, isFalse, reason: r.text);
      expect(r.text, 'Typed 3 characters. Take a screenshot to see the '
          'result.');
      expect(screen.session.sent, [
        'key ${CsrdEvdev.keyA} down',
        'key ${CsrdEvdev.keyA} up',
        'key ${CsrdEvdev.keyLeftShift} down',
        'key ${CsrdEvdev.keyB} down',
        'key ${CsrdEvdev.keyB} up',
        'key ${CsrdEvdev.keyLeftShift} up',
        'key ${CsrdEvdev.keyEnter} down',
        'key ${CsrdEvdev.keyEnter} up',
      ]);
    });

    test('text with a character that has no key is refused whole: nothing '
        'typed, and the refusal never repeats the text', () async {
      final r = await use('desktop_type', {
        'desktop_id': id,
        'text': 'hunter2ä',
      });
      expect(r.isError, isTrue);
      expect(r.text, isNot(contains('hunter2')));
      expect(r.text, isNot(contains('ä')));
      expect(screen.session.sent, isEmpty);
      final long = await use('desktop_type', {
        'desktop_id': id,
        'text': 'a' * 2001,
      });
      expect(long.isError, isTrue);
      final empty = await use('desktop_type', {'desktop_id': id, 'text': ''});
      expect(empty.isError, isTrue);
      expect(screen.session.sent, isEmpty);
    });

    test('the activity log records how long the typed text was, never the '
        'text', () async {
      await use('desktop_type', {'desktop_id': id, 'text': 'S3cretPassw0rd'});
      final entry = rig.entries.last;
      expect(entry.tool, 'desktop_type');
      expect(entry.args, isNot(contains('S3cretPassw0rd')));
      expect(entry.args, contains('14 characters'));
      expect(entry.args, contains(id));
      // A refused call (an extra argument) is not recorded either.
      await use('desktop_type', {
        'desktop_id': id,
        'text': 'S3cretPassw0rd',
        'also': 'S3cretPassw0rd',
      });
      expect(rig.entries.last.args, isNot(contains('S3cretPassw0rd')));
      // The auditArgs hook itself.
      expect(
        desktops.auditArgs('desktop_type', {
          'desktop_id': 'x',
          'text': 'pässwörd',
        }),
        {'desktop_id': 'x', 'text': '[8 characters, not recorded]'},
      );
    });

    test('keys: named keys and combinations from the list, modifiers held '
        'around the key', () async {
      var r = await use('desktop_key', {'desktop_id': id, 'keys': 'ctrl+c'});
      expect(r.isError, isFalse, reason: r.text);
      expect(screen.session.sent, [
        'key ${CsrdEvdev.keyLeftCtrl} down',
        'key ${CsrdEvdev.keyC} down',
        'key ${CsrdEvdev.keyC} up',
        'key ${CsrdEvdev.keyLeftCtrl} up',
      ]);
      screen.session.sent.clear();
      r = await use('desktop_key', {'desktop_id': id, 'keys': 'Alt+F4'});
      expect(screen.session.sent, [
        'key ${CsrdEvdev.keyLeftAlt} down',
        'key ${CsrdEvdev.keyF4} down',
        'key ${CsrdEvdev.keyF4} up',
        'key ${CsrdEvdev.keyLeftAlt} up',
      ]);
      screen.session.sent.clear();
      r = await use('desktop_key', {'desktop_id': id, 'keys': 'super'});
      expect(screen.session.sent, [
        'key ${CsrdEvdev.keyLeftMeta} down',
        'key ${CsrdEvdev.keyLeftMeta} up',
      ]);
      screen.session.sent.clear();
      r = await use('desktop_key', {'desktop_id': id, 'keys': 'sudo rm'});
      expect(r.isError, isTrue);
      expect(rig.entries.last.detail, 'invalid_arguments');
      expect(screen.session.sent, isEmpty);
    });

    test('a session the remote side keeps view-only says so', () async {
      screen.session.viewOnly = true;
      final r = await use('desktop_click', {'desktop_id': id, 'x': 1, 'y': 1});
      expect(r.isError, isTrue);
      expect(r.text, contains('only lets this desktop be watched'));
      expect(screen.session.sent, isEmpty);
    });

    test('no picture yet: a plain error, not a refusal', () async {
      screen
        ..width = 0
        ..height = 0;
      final r = await use('desktop_screenshot', {'desktop_id': id});
      expect(r.isError, isTrue);
      expect(r.text, contains('not shown a picture yet'));
      expect(rig.entries.last.outcome, BridgeAuditOutcome.error);
    });

    test('close_desktop closes it; it is gone for its assistant after',
        () async {
      final r = await use('close_desktop', {'desktop_id': id});
      expect(r.isError, isFalse);
      expect(screen.closed, 1);
      expect(desktops.current, isEmpty);
      expectNotAvailable(
        await use('desktop_screenshot', {'desktop_id': id}),
        BridgeDesktopRefusals.closed,
      );
    });

    test("another client's id is refused exactly like an unknown one, and "
        'its desktop gets nothing', () async {
      final r = await use('desktop_click', {
        'desktop_id': id,
        'x': 1,
        'y': 1,
      }, _other);
      expectNotAvailable(r, BridgeRefusals.desktopNotAvailable);
      final unknown = await use('desktop_screenshot', {'desktop_id': 'desk-x'});
      expectNotAvailable(unknown, BridgeRefusals.desktopNotAvailable);
      final shot = await use('desktop_screenshot', {'desktop_id': id}, _other);
      expectNotAvailable(shot, BridgeRefusals.desktopNotAvailable);
      expect(screen.session.sent, isEmpty);
      expect(screen.captures, isEmpty);
      // Nothing about the other client's desktop in its audit entry.
      expect(rig.entries.last.host, isNull);
      final bad = await use('desktop_screenshot', {'desktop_id': 42});
      expectNotAvailable(bad, BridgeRefusals.desktopNotAvailable);
    });

    test('taken over: the assistant loses it, the session stays open for '
        'the user', () async {
      expect(desktops.takeOver(id), isTrue);
      expectNotAvailable(
        await use('desktop_screenshot', {'desktop_id': id}),
        BridgeDesktopRefusals.takenOver,
      );
      expectNotAvailable(
        await use('desktop_type', {'desktop_id': id, 'text': 'x'}),
        BridgeDesktopRefusals.takenOver,
      );
      expect(screen.captures, isEmpty);
      expect(screen.session.sent, isEmpty);
      expect(screen.closed, 0);
      expect(desktops.current.single.state, AssistantDriveState.takenOver);
      // Lifecycle events leave the user's desktop alone…
      await desktops.ended(BridgeModuleEnd.bridgeOff);
      await desktops.hostsChanged([]);
      expect(screen.closed, 0);
      // …and closing the viewer ends it.
      await desktops.viewerClosed(id);
      expect(screen.closed, 1);
      expect(desktops.current, isEmpty);
    });

    test('taken over while a screenshot was being made: the picture is not '
        'handed over', () async {
      screen.duringCapture = () => desktops.takeOver(id);
      final r = await use('desktop_screenshot', {'desktop_id': id});
      expectNotAvailable(r, BridgeDesktopRefusals.takenOver);
    });

    test('Stop closes it', () async {
      await desktops.stop(id);
      expect(screen.closed, 1);
      expectNotAvailable(
        await use('desktop_move', {'desktop_id': id, 'x': 1, 'y': 1}),
        BridgeDesktopRefusals.stopped,
      );
      expect(desktops.byId(id)!.endedBy, AssistantDesktopEnd.stoppedByUser);
    });

    test('closing the viewer closes it', () async {
      await desktops.viewerClosed(id);
      expect(screen.closed, 1);
      expectNotAvailable(await use('desktop_screenshot', {'desktop_id': id}));
    });

    test('the session ending by itself closes it', () async {
      screen.drop();
      await Future<void>.delayed(Duration.zero);
      expect(desktops.current, isEmpty);
      expectNotAvailable(
        await use('desktop_screenshot', {'desktop_id': id}),
        BridgeDesktopRefusals.connectionLost,
      );
    });

    test('idle for 10 minutes: closed; any use resets the clock', () async {
      time.advance(const Duration(minutes: 9));
      await use('desktop_move', {'desktop_id': id, 'x': 1, 'y': 1});
      time.advance(const Duration(minutes: 9));
      expect(desktops.liveCount, 1);
      time.advance(const Duration(minutes: 1, seconds: 1));
      await Future<void>.delayed(Duration.zero);
      expect(desktops.liveCount, 0);
      expect(screen.closed, 1);
      expectNotAvailable(
        await use('desktop_screenshot', {'desktop_id': id}),
        BridgeDesktopRefusals.idle,
      );
    });

    test('the host stepped below the desktop: closed on the host change',
        () async {
      rig.hosts = [_deskHost(desktop: false)];
      await desktops.hostsChanged(rig.hosts);
      expect(screen.closed, 1);
      expectNotAvailable(
        await use('desktop_screenshot', {'desktop_id': id}),
        BridgeDesktopRefusals.hostChanged,
      );
    });

    test('the host stepped down before the change was heard: the next call '
        'closes it', () async {
      rig.hosts = [_deskHost(access: HostAiAccess.readOnly)];
      expectNotAvailable(
        await use('desktop_screenshot', {'desktop_id': id}),
        BridgeDesktopRefusals.hostChanged,
      );
      await Future<void>.delayed(Duration.zero);
      expect(screen.closed, 1);
      expect(screen.captures, isEmpty);
    });

    test('the host now points at another server, or was deleted: closed',
        () async {
      final moved = [
        _deskHost().copyWith(hostname: 'elsewhere.example.test'),
      ];
      await desktops.hostsChanged(moved);
      expect(screen.closed, 1);
      rig.hosts = moved;
      expectNotAvailable(await use('desktop_screenshot', {'desktop_id': id}));
    });

    test('a deleted host closes it', () async {
      await desktops.hostsChanged([]);
      expect(screen.closed, 1);
    });

    test('raising the host to full control keeps it open', () async {
      await desktops.hostsChanged([
        _deskHost(access: HostAiAccess.fullControl, desktop: false),
      ]);
      expect(screen.closed, 0);
      expect(desktops.liveCount, 1);
    });

    test('the client revoked: closed', () async {
      await desktops.clientsChanged({BridgeClient.builtinId, _other.id});
      expect(screen.closed, 1);
      expect(desktops.byId(id)!.endedBy, AssistantDesktopEnd.clientRevoked);
    });

    test('app locked: closed, and calls say the app is locked', () async {
      rig.locked = true;
      final r = await use('desktop_screenshot', {'desktop_id': id});
      expect(r.isError, isTrue);
      expect(rig.entries.last.detail, 'app_locked');
      await Future<void>.delayed(Duration.zero);
      expect(screen.closed, 1);
      rig.locked = false;
      expectNotAvailable(await use('desktop_screenshot', {'desktop_id': id}));
    });

    test('app locked (the lifecycle call): closed', () async {
      await desktops.ended(BridgeModuleEnd.appLocked);
      expect(screen.closed, 1);
      expect(desktops.byId(id)!.endedBy, AssistantDesktopEnd.appLocked);
    });

    test('bridge off: closed, and calls say the bridge is off', () async {
      await desktops.ended(BridgeModuleEnd.bridgeOff);
      expect(screen.closed, 1);
      rig.settings = rig.settings.copyWith(bridgeEnabled: false);
      final r = await use('desktop_screenshot', {'desktop_id': id});
      expect(rig.entries.last.detail, 'bridge_off');
      expect(r.isError, isTrue);
    });
  });

  test("bridge off spares the built-in assistant's desktop", () async {
    rig.builtinOn = true;
    final r = await open('full', answer: null, client: BridgeClient.builtin);
    expect(r.isError, isFalse, reason: r.text);
    await desktops.ended(BridgeModuleEnd.bridgeOff);
    expect(desktops.liveCount, 1);
    await desktops.clientsChanged({BridgeClient.builtinId});
    expect(desktops.liveCount, 1);
    await desktops.ended(BridgeModuleEnd.appLocked);
    expect(desktops.liveCount, 0);
  });

  test("the built-in assistant switched off closes its desktop only",
      () async {
    rig.builtinOn = true;
    final r = await open('full', answer: null, client: BridgeClient.builtin);
    expect(r.isError, isFalse, reason: r.text);
    await desktops.ended(BridgeModuleEnd.builtinOff);
    expect(desktops.liveCount, 0);
    expect(desktops.byId(r.id!)!.endedBy, AssistantDesktopEnd.clientRevoked);
    // A paired client's is not the built-in switch's business.
    final paired = await open('full', answer: null);
    expect(paired.isError, isFalse, reason: paired.text);
    await desktops.ended(BridgeModuleEnd.builtinOff);
    expect(desktops.liveCount, 1);
  });

  test('dispose closes every desktop, the user\'s too', () async {
    final r = await open('full', answer: null);
    desktops.takeOver(r.id!);
    await desktops.dispose();
    expect(screens.single.closed, 1);
  });

  group('the maths', () {
    test('screenshots keep the shape, longest side at most 1280, never '
        'upscaled', () {
      expect(BridgeDesktops.screenshotSize(1920, 1080), (1280, 720));
      expect(BridgeDesktops.screenshotSize(1080, 1920), (720, 1280));
      expect(BridgeDesktops.screenshotSize(2560, 1600), (1280, 800));
      expect(BridgeDesktops.screenshotSize(3840, 2160), (1280, 720));
      expect(BridgeDesktops.screenshotSize(1366, 768), (1280, 720));
      expect(BridgeDesktops.screenshotSize(1280, 1024), (1280, 1024));
      expect(BridgeDesktops.screenshotSize(800, 600), (800, 600));
      expect(BridgeDesktops.screenshotSize(5000, 10), (1280, 3));
      expect(BridgeDesktops.screenshotSize(1, 5000), (1, 1280));
    });

    test('a screenshot pixel maps to the real pixel under its centre, '
        'inside the screen', () {
      expect(BridgeDesktops.toScreen(0, 1280, 1920), 0);
      expect(BridgeDesktops.toScreen(1, 1280, 1920), 2);
      expect(BridgeDesktops.toScreen(640, 1280, 1920), 960);
      expect(BridgeDesktops.toScreen(1279, 1280, 1920), 1919);
      expect(BridgeDesktops.toScreen(719, 720, 1080), 1079);
      // Not scaled: the same pixel.
      for (final x in [0, 1, 500, 1023]) {
        expect(BridgeDesktops.toScreen(x, 1024, 1024), x);
      }
      // Every screenshot pixel lands on the screen, and in order.
      var last = -1;
      for (var x = 0; x < 1280; x++) {
        final r = BridgeDesktops.toScreen(x, 1280, 3840);
        expect(r, inInclusiveRange(0, 3839));
        expect(r, greaterThan(last));
        last = r;
      }
    });
  });

  group('the key list', () {
    test('accepts named keys, letters, digits, F-keys and combinations, '
        'ignoring case and spaces', () {
      final enter = DesktopKeyCombo.parse('Enter')!;
      expect(enter.key, CsrdEvdev.keyEnter);
      expect(enter.modifiers, isEmpty);
      final combo = DesktopKeyCombo.parse(' Ctrl + Shift + T ')!;
      expect(combo.modifiers, [CsrdEvdev.keyLeftCtrl, CsrdEvdev.keyLeftShift]);
      expect(combo.key, CsrdEvdev.keyT);
      expect(DesktopKeyCombo.parse('alt+f4')!.key, CsrdEvdev.keyF4);
      expect(DesktopKeyCombo.parse('F12')!.key, CsrdEvdev.keyF12);
      expect(DesktopKeyCombo.parse('super')!.key, CsrdEvdev.keyLeftMeta);
      expect(DesktopKeyCombo.parse('win+l')!.modifiers, [
        CsrdEvdev.keyLeftMeta,
      ]);
      expect(DesktopKeyCombo.parse('ctrl+alt+delete')!.key, CsrdEvdev.keyDelete);
      expect(DesktopKeyCombo.parse('esc')!.key, CsrdEvdev.keyEsc);
      expect(DesktopKeyCombo.parse('ctrl+0')!.key, CsrdEvdev.key0);
      for (final k in ['Tab', 'Escape', 'Backspace', 'Home', 'End', 'PageUp',
          'PageDown', 'Up', 'Down', 'Left', 'Right', 'Space', 'Insert',
          'PrintScreen']) {
        expect(DesktopKeyCombo.parse(k), isNotNull, reason: k);
      }
    });

    test('refuses anything else', () {
      for (final k in [
        '',
        '+',
        'ctrl+',
        '+c',
        'ctrl+alt',
        'ctrl+ctrl+c',
        'ctrl+control+c',
        'hyper+c',
        'f13',
        'ä',
        'é',
        'ctrl+c+v',
        'ctrl alt t',
        'shift+alt+ctrl+super+x',
        'x' * 65,
        'KEY_A',
        '\u0000',
      ]) {
        expect(DesktopKeyCombo.parse(k), isNull, reason: k);
      }
    });
  });
}
