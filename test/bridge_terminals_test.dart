import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/app_settings.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/models/host_ai_access.dart';
import 'package:secure_shell_go/services/assistant_drive.dart';
import 'package:secure_shell_go/services/bridge/bridge_approvals.dart';
import 'package:secure_shell_go/services/bridge/bridge_audit.dart';
import 'package:secure_shell_go/services/bridge/bridge_channel.dart';
import 'package:secure_shell_go/services/bridge/bridge_client_store.dart';
import 'package:secure_shell_go/services/bridge/bridge_connections.dart';
import 'package:secure_shell_go/services/bridge/bridge_grants.dart';
import 'package:secure_shell_go/services/bridge/bridge_policy.dart';
import 'package:secure_shell_go/services/bridge/bridge_redactor.dart';
import 'package:secure_shell_go/services/bridge/bridge_service.dart';
import 'package:secure_shell_go/services/bridge/bridge_terminals.dart';
import 'package:secure_shell_go/services/bridge/bridge_tool_types.dart';
import 'package:secure_shell_go/services/bridge/bridge_tools.dart';
import 'package:secure_shell_go/services/device_storage.dart';
import 'package:secure_shell_go/services/diagnostics_log.dart';
import 'package:secure_shell_go/services/session_controller.dart';
import 'package:secure_shell_go/services/session_foreground.dart';
import 'package:secure_shell_go/services/session_manager.dart';
import 'package:secure_shell_go/services/settings_store.dart';
import 'package:secure_shell_go/widgets/session_banners.dart';

import 'support/bridge_fake_time.dart';
import 'support/bridge_fakes.dart';
import 'support/bridge_temp_dir.dart';
import 'support/fake_transport.dart';

/// A shell channel with no SSH underneath: records every byte written to
/// it, and lets the test play the server's output.
class _Shell implements SSHSession {
  _Shell(this.columns, this.rows);

  final int columns;
  final int rows;
  final _done = Completer<void>();
  final _stdout = StreamController<Uint8List>.broadcast();
  final BytesBuilder written = BytesBuilder();
  var closed = false;

  String get writtenText => utf8.decode(written.toBytes());

  /// The server printing [text].
  void emit(String text) => _stdout.add(Uint8List.fromList(utf8.encode(text)));

  @override
  Stream<Uint8List> get stdout => _stdout.stream;

  @override
  Stream<Uint8List> get stderr => const Stream.empty();

  @override
  Future<void> get done => _done.future;

  @override
  int? exitCode;

  @override
  void write(Uint8List data) => written.add(data);

  @override
  void resizeTerminal(int width, int height, [int? pw, int? ph]) {}

  @override
  void close() {
    closed = true;
    hangUp();
  }

  void hangUp() {
    if (!_done.isCompleted) _done.complete();
  }

  /// `exit` typed in the shell.
  void exit(int status) {
    exitCode = status;
    hangUp();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not faked');
}

/// A dialled connection whose shell opens.
class _ShellTransport extends FakeTransportBase {
  _ShellTransport(Host host) : super(host: host);

  final List<_Shell> shells = [];
  var commandShells = 0;

  _Shell get shell => shells.single;

  @override
  Future<SSHSession> startShell({
    required int columns,
    required int rows,
    String terminalType = 'xterm-256color',
  }) async {
    final shell = _Shell(columns, rows);
    shells.add(shell);
    return shell;
  }

  @override
  Future<SSHSession> startCommandShell(
    String command, {
    required int columns,
    required int rows,
    String terminalType = 'xterm-256color',
  }) {
    commandShells++;
    return startShell(columns: columns, rows: rows);
  }

  @override
  void endChannels() {
    for (final s in shells) {
      s.hangUp();
    }
  }

  @override
  void close() {
    super.close();
    endChannels();
  }
}

class _Storage implements DeviceStorage {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('storage is not used here');
}

class _Foreground implements SessionForegroundChannel {
  @override
  Future<void> start(String label) async {}

  @override
  Future<void> stop() async {}
}

class _NoTimer implements Timer {
  @override
  bool get isActive => false;
  @override
  int get tick => 0;
  @override
  void cancel() {}
}

final BridgeClient _other = BridgeClient(
  id: 'c2',
  name: 'Other assistant',
  tokenHash: 'y',
  createdAt: DateTime.utc(2026),
);

Host _h(
  String id,
  String label,
  HostAiAccess access, {
  bool terminal = false,
  List<String> allowed = const [],
}) => bridgeHost(
  id,
  label,
  access: access,
).copyWith(aiTerminal: terminal, aiAllowedCommands: allowed);

class _Rig {
  _Rig(Directory auditDir) {
    approvals = BridgeApprovals(
      timedApprovalMinutes: () => settings.bridgeTimedApprovalMinutes,
      clock: time.clock,
      timer: time.timer,
    );
    grants = BridgeGrants(clock: time.clock, timer: time.timer);
    sessions = SessionManager(
      foreground: SessionForegroundController(channel: _Foreground()),
      createController: (connection, resolve, credentials) => SessionController(
        connection: connection,
        storage: _Storage(),
        resolveRemoteTarget: resolve,
        keepaliveScheduler: (_, _) => _NoTimer(),
      ),
    );
    terminals = BridgeTerminals(
      sessions: sessions,
      dial: (host) async {
        final gate = dialGate;
        if (gate != null) await gate.future;
        final failure = dialFailure;
        if (failure != null) throw failure;
        final t = _ShellTransport(host);
        dialled.add(t);
        return t;
      },
      clock: time.clock,
      timer: time.timer,
    );
    audit = BridgeAuditLog(scrub: (s) => s, directory: auditDir);
    audit.entries.listen(entries.add);
    tools = BridgeTools(
      loadHosts: () async => hosts,
      settings: () => settings,
      isAppLocked: () => locked,
      connections: BridgeConnections(
        openTransport: (_) => null,
        credentialLookup: (_) async => null,
        dialer: (_, _) async => throw StateError('not used'),
      ),
      redactor: BridgeRedactor(
        scrub: (s) => s.replaceAll('hunter2', '[redacted]'),
      ),
      audit: audit,
      approvals: approvals,
      grants: grants,
      changeTools: [terminals.openTool],
      terminalUseTools: terminals.useTools,
    );
    approvals.pending.listen(cards.add);
  }

  final FakeTime time = FakeTime();
  late final BridgeApprovals approvals;
  late final BridgeGrants grants;
  late final SessionManager sessions;
  late final BridgeTerminals terminals;
  late final BridgeAuditLog audit;
  late final BridgeTools tools;
  final List<BridgeAuditEntry> entries = [];
  final List<List<BridgeApprovalRequest>> cards = [];
  final List<_ShellTransport> dialled = [];
  Completer<void>? dialGate;
  Object? dialFailure;
  AppSettings settings = const AppSettings(bridgeEnabled: true);
  bool locked = false;
  List<Host> hosts = [
    _h('trm1', 'term', HostAiAccess.askToChange, terminal: true),
    _h('trm2', 'term2', HostAiAccess.askToChange, terminal: true),
    _h('web1', 'web', HostAiAccess.askToChange, allowed: ['uptime']),
    _h('db01', 'db', HostAiAccess.readOnly, terminal: true),
  ];

  int get cardsShown => {
    for (final l in cards)
      for (final r in l) r.id,
  }.length;

  Future<({String text, bool isError})> call(
    String name,
    Map<String, Object?> args, {
    BridgeClient? client,
    BridgeCallToken? cancel,
  }) async {
    final r = await tools.call(
      client ?? testBridgeClient,
      name,
      args,
      cancel: cancel,
    );
    await Future<void>.delayed(Duration.zero);
    return (text: r.text, isError: r.isError);
  }

  Future<BridgeApprovalRequest> card() async {
    for (var i = 0; i < 400; i++) {
      if (approvals.current.isNotEmpty) return approvals.current.last;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('no approval card appeared');
  }

  /// `open_terminal` answered with [answer]; the result.
  Future<({String text, bool isError})> open(
    String host, {
    BridgeApprovalAnswer answer = BridgeApprovalAnswer.allowOnce,
    BridgeClient? client,
  }) async {
    final pending = call('open_terminal', {'host': host}, client: client);
    final request = await card();
    expect(request.summary, isA<TerminalSummary>());
    approvals.answer(request.id, answer);
    return pending;
  }

  /// The terminal id in an `open_terminal` result.
  static String idOf(String text) => RegExp(
    r'terminal_id: (term(?:-[0-9a-f]{8}){4})\n',
  ).firstMatch(text)!.group(1)!;

  Future<String> openId(String host, {BridgeClient? client}) async {
    final r = await open(host, client: client);
    expect(r.isError, false, reason: r.text);
    return idOf(r.text);
  }

  ManagedSession sessionOf(String terminalId) {
    final t = terminals.current.firstWhere((t) => t.terminalId == terminalId);
    return sessions.byId(t.sessionId)!;
  }

  Future<void> settle() async {
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }
}

void main() {
  late Directory temp;
  late _Rig rig;

  setUp(() async {
    temp = await bridgeTempDir('bridge_terminals');
    rig = _Rig(temp);
  });

  tearDown(() async {
    await rig.terminals.dispose();
    await rig.sessions.dispose();
    await rig.approvals.dispose();
    await rig.grants.dispose();
    await deleteTempDir(temp);
  });

  test('the four tools are listed with their kinds', () {
    final kinds = {for (final t in rig.tools.tools) t.name: t.kind};
    expect(kinds['open_terminal'], BridgeToolKind.terminal);
    expect(kinds['send_input'], BridgeToolKind.terminalUse);
    expect(kinds['read_screen'], BridgeToolKind.terminalUse);
    expect(kinds['close_terminal'], BridgeToolKind.terminalUse);
    final send = rig.tools.tools.firstWhere((t) => t.name == 'send_input');
    expect(send.description, contains(r'"\n"'));
  });

  group('opening', () {
    test('opens a real, visible session marked as driven by the assistant, '
        'at 120x32, after a yes', () async {
      final r = await rig.open('term');
      expect(r.isError, false, reason: r.text);
      final id = _Rig.idOf(r.text);
      expect(rig.sessions.length, 1);
      final session = rig.sessionOf(id);
      final drive = session.controller.assistantDrive!;
      expect(drive.terminalId, id);
      expect(drive.clientId, testBridgeClient.id);
      expect(drive.clientName, testBridgeClient.name);
      expect(drive.state, AssistantDriveState.driving);
      expect(rig.dialled.single.shell.columns, 120);
      expect(rig.dialled.single.shell.rows, 32);
      expect(rig.terminals.liveCount, 1);
      expect(rig.terminals.bySession(session.id)!.terminalId, id);
      expect(rig.entries.last.tool, 'open_terminal');
      expect(rig.entries.last.approval, BridgeAuditApproval.once);
    });

    test('does not take the front from the session the user is in', () async {
      final mine = rig.sessions.open(_ShellTransport(rig.hosts.first));
      final id = await rig.openId('term');
      expect(rig.sessions.activeId, mine.id);
      expect(rig.sessionOf(id).id, isNot(mine.id));
    });

    test('needs a card every time, even with a live grant and an allowed '
        'list, and a "for a while" yes grants nothing', () async {
      rig.settings = const AppSettings(
        bridgeEnabled: true,
        bridgeTimedApprovalMinutes: 15,
      );
      rig.hosts = [
        _h(
          'trm1',
          'term',
          HostAiAccess.askToChange,
          terminal: true,
          allowed: ['bash', 'open_terminal'],
        ),
      ];
      rig.grants.grant(testBridgeClient.id, 'trm1', const Duration(hours: 1));
      final first = await rig.open(
        'term',
        answer: BridgeApprovalAnswer.allowForAWhile,
      );
      expect(first.isError, false, reason: first.text);
      expect(rig.cardsShown, 1);
      final second = await rig.open('term');
      expect(second.isError, false, reason: second.text);
      expect(rig.cardsShown, 2);
      expect(rig.entries.map((e) => e.approval), [
        BridgeAuditApproval.once,
        BridgeAuditApproval.once,
      ]);
    });

    test('denied, timed out and withdrawn open nothing', () async {
      final denied = await rig.open('term', answer: BridgeApprovalAnswer.deny);
      expect(denied.isError, true);
      expect(denied.text, BridgeToolRefusals.denied.message);

      final timing = rig.call('open_terminal', {'host': 'term'});
      await rig.card();
      rig.time.advance(const Duration(seconds: 121));
      final timedOut = await timing;
      expect(timedOut.text, BridgeToolRefusals.approvalTimedOut.message);

      final withdrawing = rig.call('open_terminal', {'host': 'term'});
      final request = await rig.card();
      rig.approvals.withdraw(request.id);
      final withdrawn = await withdrawing;
      expect(withdrawn.isError, true);

      expect(rig.dialled, isEmpty);
      expect(rig.sessions.length, 0);
      expect(rig.terminals.current, isEmpty);
      expect(rig.entries.map((e) => e.approval), [
        BridgeAuditApproval.denied,
        BridgeAuditApproval.timedOut,
        BridgeAuditApproval.withdrawn,
      ]);
    });

    test(
      'a third terminal is refused before any card, across clients',
      () async {
        await rig.openId('term');
        await rig.openId('term2', client: _other);
        expect(rig.cardsShown, 2);
        final third = await rig.call('open_terminal', {'host': 'term'});
        expect(third.isError, true);
        expect(third.text, BridgeTerminalRefusals.limit.message);
        expect(rig.cardsShown, 2);
        expect(rig.sessions.length, 2);
        expect(rig.entries.last.detail, 'terminal_limit');
      },
    );

    test('a taken-over terminal no longer counts toward the limit', () async {
      final a = await rig.openId('term');
      await rig.openId('term2');
      rig.terminals.takeOver(a);
      final third = await rig.open('term');
      expect(third.isError, false, reason: third.text);
    });

    test(
      'hosts that do not allow a terminal are refused with no card',
      () async {
        for (final (host, refusal) in [
          ('web', BridgeRefusals.terminalNotAllowed),
          ('db', BridgeRefusals.changesNotAllowed),
          ('nope', BridgeRefusals.hostNotAvailable),
        ]) {
          final r = await rig.call('open_terminal', {'host': host});
          expect(r.text, refusal.message, reason: host);
        }
        expect(rig.cardsShown, 0);
      },
    );

    test('a dial that fails opens no session', () async {
      rig.dialFailure = const BridgeConnectFailure('Could not connect.');
      final r = await rig.open('term');
      expect(r.isError, true);
      expect(r.text, contains('Could not connect.'));
      expect(rig.sessions.length, 0);
      expect(rig.terminals.current, isEmpty);
    });

    test('cancelled while dialling: the late connection is hung up, no '
        'session is opened', () async {
      rig.dialGate = Completer<void>();
      final cancel = BridgeCallToken();
      final pending = rig.call('open_terminal', {
        'host': 'term',
      }, cancel: cancel);
      final request = await rig.card();
      rig.approvals.answer(request.id, BridgeApprovalAnswer.allowOnce);
      await rig.settle();
      cancel.cancel();
      final r = await pending;
      expect(r.isError, true);
      rig.dialGate!.complete();
      await rig.settle();
      expect(rig.dialled.single.closeCount, greaterThan(0));
      expect(rig.sessions.length, 0);
      expect(rig.terminals.liveCount, 0);
    });

    test('a host with a persistent session still gets a plain login shell, '
        'and no startup command', () async {
      rig.hosts = [
        _h('trm1', 'term', HostAiAccess.askToChange, terminal: true).copyWith(
          persistentSession: PersistentSession.tmux,
          startupCommand: 'sudo -i',
        ),
      ];
      final id = await rig.openId('term');
      expect(rig.dialled.single.commandShells, 0);
      await rig.settle();
      expect(rig.dialled.single.shell.writtenText, isEmpty);
      expect(rig.sessionOf(id).controller.assistantDrive, isNotNull);
    });
  });

  group('typing and reading', () {
    test('input reaches the PTY byte for byte, control characters included, '
        'and is never mirrored or rewritten', () async {
      final id = await rig.openId('term');
      final controller = rig.sessionOf(id).controller;
      final mirrored = <String>[];
      controller.onInputSent = mirrored.add;
      controller.transformInput = (s) => 'REWRITTEN';
      const text = 'echo "é ünï" \x03\x1b[A\t\x04\r\n';
      final r = await rig.call('send_input', {'terminal_id': id, 'text': text});
      expect(r.isError, false, reason: r.text);
      expect(rig.dialled.single.shell.written.toBytes(), utf8.encode(text));
      expect(mirrored, isEmpty);
      expect(controller.assistantDrive!.isDriving, true);
    });

    test(
      'input is checked: at most 4096 characters, no NUL, not empty',
      () async {
        final id = await rig.openId('term');
        for (final bad in ['', 'a\x00b', 'x' * 4097, 42]) {
          final r = await rig.call('send_input', {
            'terminal_id': id,
            'text': bad,
          });
          expect(r.isError, true);
          expect(r.text, startsWith('Invalid arguments'));
        }
        final ok = await rig.call('send_input', {
          'terminal_id': id,
          'text': 'é' * 4096,
        });
        expect(ok.isError, false, reason: ok.text);
        expect(rig.dialled.single.shell.writtenText, 'é' * 4096);
      },
    );

    test('read_screen returns the screen, redacted, never audited', () async {
      final id = await rig.openId('term');
      final shell = rig.dialled.single.shell;
      shell.emit('\$ echo hello\r\nhello\r\npassword hunter2\r\n');
      shell.emit(
        '-----BEGIN OPENSSH PRIVATE KEY-----\r\nAAAAB3NzaC1yc2E\r\n'
        '-----END OPENSSH PRIVATE KEY-----\r\n\$ ',
      );
      await rig.settle();
      final r = await rig.call('read_screen', {'terminal_id': id});
      expect(r.isError, false, reason: r.text);
      expect(r.text, contains('hello'));
      expect(r.text, contains('password [redacted]'));
      expect(r.text, isNot(contains('hunter2')));
      expect(r.text, isNot(contains('AAAAB3NzaC1yc2E')));
      expect(r.text, startsWith('[120x32;'));
      final entry = rig.entries.last;
      expect(entry.tool, 'read_screen');
      expect(entry.args, '{"terminal_id":"$id"}');
      expect(entry.detail, isNot(contains('hello')));
      expect(entry.host, 'term');
      final log = [
        for (final f in temp.listSync().whereType<File>()) f.readAsStringSync(),
      ].join();
      expect(log, contains('read_screen'));
      expect(log, isNot(contains('hello')));
    });

    test('read_screen is bounded to the last 200 lines', () async {
      final id = await rig.openId('term');
      final shell = rig.dialled.single.shell;
      shell.emit([for (var i = 0; i < 500; i++) 'line $i'].join('\r\n'));
      await rig.settle();
      final r = await rig.call('read_screen', {'terminal_id': id});
      final body = r.text.split('\n').skip(1).toList();
      expect(body, hasLength(200));
      expect(body.last, 'line 499');
      expect(body.first, 'line 300');
    });

    test('screenText caps the bytes from the end', () {
      final terminal = rig.sessions
          .open(_ShellTransport(rig.hosts.first))
          .controller
          .terminal;
      terminal.resize(120, 32);
      for (var i = 0; i < 100; i++) {
        terminal.write('${'x' * 100} $i\r\n');
      }
      final text = BridgeTerminals.screenText(terminal, maxBytes: 1000);
      expect(utf8.encode(text).length, lessThan(1400));
      expect(text, contains(' 99'));
    });

    test('the session goes on being read whether or not a pane shows it, and '
        'a pane\'s size applies once one reports it', () async {
      final id = await rig.openId('term');
      final controller = rig.sessionOf(id).controller;
      controller.terminal.resize(80, 24);
      final r = await rig.call('read_screen', {'terminal_id': id});
      expect(r.text, startsWith('[80x24;'));
    });

    test('every call leaves exactly one audit entry; input is recorded '
        'scrubbed and capped like other arguments', () async {
      final id = await rig.openId('term');
      await rig.call('send_input', {
        'terminal_id': id,
        'text': 'export PASS=hunter2 ${'y' * 1000}\n',
      });
      await rig.call('read_screen', {'terminal_id': id});
      await rig.call('close_terminal', {'terminal_id': id});
      await rig.call('send_input', {'terminal_id': id, 'text': 'x'});
      expect(rig.entries.map((e) => e.tool), [
        'open_terminal',
        'send_input',
        'read_screen',
        'close_terminal',
        'send_input',
      ]);
      final input = rig.entries[1];
      expect(
        input.args.length,
        lessThanOrEqualTo(BridgeAuditLog.maxArgsChars + 2),
      );
      expect(input.host, 'term');
      expect(rig.entries.last.outcome, BridgeAuditOutcome.refused);
    });
  });

  group('who may use a terminal', () {
    test('another client\'s terminal is refused exactly like an unknown id, '
        'before its arguments are looked at', () async {
      final id = await rig.openId('term');
      for (final tool in ['send_input', 'read_screen', 'close_terminal']) {
        final args = <String, Object?>{
          'terminal_id': id,
          if (tool == 'send_input') 'text': 'x' * 5000,
        };
        final theirs = await rig.call(tool, args, client: _other);
        final unknown = await rig.call(tool, {
          ...args,
          'terminal_id': 'term-00000000-00000000-00000000-00000000',
        });
        expect(theirs.isError, true);
        expect(theirs.text, BridgeRefusals.terminalNotAvailable.message);
        expect(unknown.text.codeUnits, theirs.text.codeUnits);
        expect(rig.entries[rig.entries.length - 2].host, isNull);
        expect(rig.entries.last.host, isNull);
      }
      expect(rig.dialled.single.shell.writtenText, isEmpty);
      expect(rig.terminals.liveCount, 1);
    });

    test('a missing or odd terminal_id names nothing', () async {
      for (final id in [null, 7, '', 'x' * 500]) {
        final r = await rig.call('read_screen', {'terminal_id': id});
        expect(r.text, BridgeRefusals.terminalNotAvailable.message);
      }
    });
  });

  group('take over, stop, and the end of a terminal', () {
    Future<void> expectRefused(String id, BridgeRefuse refusal) async {
      for (final (tool, args) in [
        ('send_input', {'terminal_id': id, 'text': 'x'}),
        ('read_screen', {'terminal_id': id}),
      ]) {
        final r = await rig.call(tool, args);
        expect(r.isError, true, reason: tool);
        expect(r.text, refusal.message, reason: tool);
      }
    }

    test(
      'take over: refused from then on, the session stays the user\'s',
      () async {
        final id = await rig.openId('term');
        final session = rig.sessionOf(id);
        expect(rig.terminals.takeOver(id), true);
        expect(rig.terminals.takeOver(id), false);
        await expectRefused(id, BridgeTerminalRefusals.takenOver);
        expect(
          session.controller.assistantDrive!.state,
          AssistantDriveState.takenOver,
        );
        expect(rig.sessions.byId(session.id), isNotNull);
        expect(rig.dialled.single.closeCount, 0);
        // The user types; it reaches the shell as theirs.
        session.controller.terminal.textInput('ls\r');
        expect(rig.dialled.single.shell.writtenText, 'ls\r');
        // Lifecycle closes leave the user's session alone.
        await rig.terminals.closeAll(AssistantTerminalEnd.bridgeOff);
        expect(rig.sessions.byId(session.id), isNotNull);
      },
    );

    test(
      'the user\'s first keystroke takes over; a terminal reply does not',
      () async {
        final id = await rig.openId('term');
        final controller = rig.sessionOf(id).controller;
        final shell = rig.dialled.single.shell;
        // The server asks for the device attributes; the terminal answers by
        // itself. Not the user typing.
        shell.emit('\x1b[c');
        await rig.settle();
        expect(controller.assistantDrive!.isDriving, true);
        expect(shell.writtenText, isNotEmpty);
        controller.terminal.textInput('q');
        expect(controller.assistantDrive!.state, AssistantDriveState.takenOver);
        expect(shell.writtenText, endsWith('q'));
        await expectRefused(id, BridgeTerminalRefusals.takenOver);
        expect(controller.writeAssistantInput('rm -rf /\n'), false);
      },
    );

    test('stop closes the session', () async {
      final id = await rig.openId('term');
      final transport = rig.dialled.single;
      await rig.terminals.stop(id);
      await rig.terminals.stop(id);
      expect(rig.sessions.length, 0);
      expect(transport.closeCount, greaterThan(0));
      expect(transport.shell.closed, true);
      await expectRefused(id, BridgeTerminalRefusals.stopped);
      expect(rig.terminals.current, isEmpty);
    });

    test('a tab the user closed is gone for the assistant too', () async {
      final id = await rig.openId('term');
      await rig.sessions.close(rig.sessionOf(id).id);
      await rig.settle();
      await expectRefused(id, BridgeTerminalRefusals.stopped);
    });

    test(
      'close_terminal closes it, and closing again says it is closed',
      () async {
        final id = await rig.openId('term');
        final r = await rig.call('close_terminal', {'terminal_id': id});
        expect(r.isError, false, reason: r.text);
        expect(rig.sessions.length, 0);
        expect(rig.dialled.single.closeCount, greaterThan(0));
        final again = await rig.call('close_terminal', {'terminal_id': id});
        expect(again.text, BridgeTerminalRefusals.closed.message);
        await expectRefused(id, BridgeTerminalRefusals.closed);
      },
    );

    test(
      'idle for 10 minutes: closed; any input or read resets the clock',
      () async {
        final id = await rig.openId('term');
        rig.time.advance(const Duration(minutes: 9));
        await rig.call('read_screen', {'terminal_id': id});
        rig.time.advance(const Duration(minutes: 9));
        await rig.call('send_input', {'terminal_id': id, 'text': 'x'});
        rig.time.advance(const Duration(minutes: 9));
        expect(rig.terminals.liveCount, 1);
        rig.time.advance(const Duration(minutes: 1));
        await rig.settle();
        expect(rig.sessions.length, 0);
        expect(rig.dialled.single.closeCount, greaterThan(0));
        await expectRefused(id, BridgeTerminalRefusals.idle);
      },
    );

    test('bridge off: refused at once, and the terminal is closed', () async {
      final id = await rig.openId('term');
      rig.settings = const AppSettings();
      await expectRefused(id, BridgeRefusals.bridgeOff);
      await rig.settle();
      expect(rig.sessions.length, 0);
      rig.settings = const AppSettings(bridgeEnabled: true);
      await expectRefused(id, BridgeTerminalRefusals.closed);
    });

    test('app locked: refused, and closed', () async {
      final id = await rig.openId('term');
      rig.locked = true;
      await expectRefused(id, BridgeRefusals.appLocked);
      await rig.settle();
      expect(rig.sessions.length, 0);
    });

    test('closeAll, closeClientsExcept and hostsChanged close what they '
        'should, and only that', () async {
      final mine = await rig.openId('term');
      final theirs = await rig.openId('term2', client: _other);
      await rig.terminals.closeClientsExcept({testBridgeClient.id});
      expect(rig.terminals.liveCount, 1);
      final stillMine = await rig.call('read_screen', {'terminal_id': mine});
      expect(stillMine.isError, false, reason: stillMine.text);
      final r = await rig.call('read_screen', {
        'terminal_id': theirs,
      }, client: _other);
      expect(r.text, BridgeTerminalRefusals.closed.message);

      // An unrelated edit keeps it.
      await rig.terminals.hostsChanged([
        for (final h in rig.hosts)
          h.id == 'trm1' ? h.copyWith(label: 'renamed') : h,
      ]);
      expect(rig.terminals.liveCount, 1);
      await rig.terminals.closeAll(AssistantTerminalEnd.appLocked);
      expect(rig.terminals.liveCount, 0);
      expect(rig.sessions.length, 0);
    });

    for (final (name, edit, refusal) in [
      (
        'stepped down',
        (Host h) => h.copyWith(aiAccess: HostAiAccess.readOnly),
        BridgeRefusals.changesNotAllowed,
      ),
      (
        'terminal switched off',
        (Host h) => h.copyWith(aiTerminal: false),
        BridgeRefusals.terminalNotAllowed,
      ),
      (
        'un-shared',
        (Host h) => h.copyWith(aiAccess: HostAiAccess.off),
        BridgeRefusals.hostNotAvailable,
      ),
      (
        'pointed at another server',
        (Host h) => h.copyWith(hostname: 'elsewhere.example.test'),
        BridgeRefusals.hostNotAvailable,
      ),
    ]) {
      test('host $name: the next call is refused and the terminal closed; '
          'the change stream closes it too', () async {
        final original = rig.hosts;
        final edited = [for (final h in original) h.id == 'trm1' ? edit(h) : h];
        final id = await rig.openId('term');
        rig.hosts = edited;
        final r = await rig.call('send_input', {
          'terminal_id': id,
          'text': 'x',
        });
        expect(r.text, refusal.message);
        await rig.settle();
        expect(rig.sessions.length, 0);
        expect(rig.dialled.single.shell.writtenText, isEmpty);
        // Closed now: the next call says so, even with the host put back.
        rig.hosts = original;
        await expectRefused(id, BridgeTerminalRefusals.closed);

        // With no call at all: the change stream's list closes it.
        rig.hosts = original;
        final again = await rig.openId('term');
        await rig.terminals.hostsChanged(edited);
        expect(rig.sessions.length, 0);
        expect(rig.dialled.last.closeCount, greaterThan(0));
        rig.hosts = original;
        await expectRefused(again, BridgeTerminalRefusals.closed);
      });
    }

    test('the host change stream closes a terminal without a call', () async {
      final id = await rig.openId('term');
      await rig.terminals.hostsChanged([
        for (final h in rig.hosts)
          if (h.id != 'trm1') h,
      ]);
      expect(rig.sessions.length, 0);
      await expectRefused(id, BridgeTerminalRefusals.closed);
    });

    test('the connection drops: the next call says so; nothing reconnects '
        'for the assistant', () async {
      final id = await rig.openId('term');
      final session = rig.sessionOf(id);
      rig.dialled.single.drop(const SocketException('gone'));
      await rig.settle();
      await expectRefused(id, BridgeTerminalRefusals.connectionLost);
      expect(session.controller.isReconnecting, false);
      expect(
        session.controller.assistantDrive!.state,
        AssistantDriveState.ended,
      );
    });

    test('the shell exits: the next call says so', () async {
      final id = await rig.openId('term');
      rig.dialled.single.shell.exit(0);
      await rig.settle();
      await expectRefused(id, BridgeTerminalRefusals.shellEnded);
    });

    test('dispose closes every terminal the assistant drives', () async {
      await rig.openId('term');
      final transport = rig.dialled.single;
      await rig.terminals.dispose();
      expect(rig.sessions.length, 0);
      expect(transport.closeCount, greaterThan(0));
    });

    test('the id survives the app\'s own secret scrubber', () async {
      final r = await rig.open('term');
      final id = _Rig.idOf(r.text);
      final scrubbed = SecretScrubber().scrub(r.text);
      expect(scrubbed, contains('terminal_id: $id\n'));
    });

    test('ids are random and never reused', () async {
      final seen = <String>{};
      for (var i = 0; i < 4; i++) {
        final id = await rig.openId('term');
        expect(seen.add(id), true);
        await rig.call('close_terminal', {'terminal_id': id});
      }
    });

    test('the list for the UI follows every change', () async {
      final lists = <List<AssistantTerminal>>[];
      final sub = rig.terminals.changes.listen(lists.add);
      final id = await rig.openId('term');
      rig.terminals.takeOver(id);
      await rig.settle();
      expect(lists.last.single.state, AssistantDriveState.takenOver);
      expect(lists.last.single.clientName, testBridgeClient.name);
      expect(lists.last.single.hostName, 'term');
      await rig.terminals.stop(id);
      await rig.settle();
      expect(lists.last, isEmpty);
      await sub.cancel();
    });
  });

  group('checker findings', () {
    test('the host\'s agent and X11 forwarding never reach the assistant\'s '
        'shell: the dial is given the host with both off', () async {
      final dialledFor = <Host>[];
      final sessions = rig.sessions;
      final own = BridgeTerminals(
        sessions: sessions,
        dial: (host) async {
          dialledFor.add(host);
          return _ShellTransport(host);
        },
        clock: rig.time.clock,
        timer: rig.time.timer,
      );
      addTearDown(own.dispose);
      rig.hosts = [
        _h(
          'trm1',
          'term',
          HostAiAccess.askToChange,
          terminal: true,
        ).copyWith(agentForwarding: true, x11Forwarding: true),
      ];
      final tools = BridgeTools(
        loadHosts: () async => rig.hosts,
        settings: () => rig.settings,
        isAppLocked: () => false,
        connections: rig.tools.connections,
        redactor: BridgeRedactor(scrub: (s) => s),
        audit: rig.audit,
        approvals: rig.approvals,
        changeTools: [own.openTool],
        terminalUseTools: own.useTools,
      );
      final pending = tools.call(testBridgeClient, 'open_terminal', {
        'host': 'term',
      });
      final request = await rig.card();
      rig.approvals.answer(request.id, BridgeApprovalAnswer.allowOnce);
      final r = await pending;
      expect(r.isError, false, reason: r.text);
      expect(dialledFor.single.agentForwarding, false);
      expect(dialledFor.single.x11Forwarding, false);
      expect(own.current.single.hostId, 'trm1');
    });

    test('dialOwned dials without the host\'s agent and X11 forwarding',
        () async {
      final dialledFor = <Host>[];
      final connections = BridgeConnections(
        openTransport: (_) => null,
        credentialLookup: (_) async => const SshCredentials(password: 'pw'),
        dialer: (host, _) async {
          dialledFor.add(host);
          return _ShellTransport(host);
        },
      );
      final host = _h(
        'trm1',
        'term',
        HostAiAccess.askToChange,
        terminal: true,
      ).copyWith(agentForwarding: true, x11Forwarding: true);
      final transport = await connections.dialOwned(host);
      transport.close();
      expect(dialledFor.single.agentForwarding, false);
      expect(dialledFor.single.x11Forwarding, false);
      expect(dialledFor.single.id, 'trm1');
    });

    test('the app locks while the terminal is still opening: it is closed '
        'as it lands, not left behind', () async {
      rig.dialGate = Completer<void>();
      final pending = rig.call('open_terminal', {'host': 'term'});
      final request = await rig.card();
      rig.approvals.answer(request.id, BridgeApprovalAnswer.allowOnce);
      await rig.settle();
      await rig.terminals.closeAll(AssistantTerminalEnd.appLocked);
      rig.dialGate!.complete();
      final r = await pending;
      expect(r.isError, true);
      expect(r.text, isNot(contains('terminal_id')));
      await rig.settle();
      expect(rig.sessions.length, 0);
      expect(rig.terminals.liveCount, 0);
      expect(rig.terminals.current, isEmpty);
      expect(rig.dialled.single.closeCount, greaterThan(0));
    });

    test('the host stops allowing a terminal while it is still opening: '
        'closed as it lands', () async {
      rig.dialGate = Completer<void>();
      final pending = rig.call('open_terminal', {'host': 'term'});
      final request = await rig.card();
      rig.approvals.answer(request.id, BridgeApprovalAnswer.allowOnce);
      await rig.settle();
      await rig.terminals.hostsChanged([
        _h('trm1', 'term', HostAiAccess.readOnly, terminal: true),
      ]);
      rig.dialGate!.complete();
      final r = await pending;
      expect(r.isError, true);
      expect(r.text, isNot(contains('terminal_id')));
      await rig.settle();
      expect(rig.sessions.length, 0);
      expect(rig.terminals.liveCount, 0);
    });

    test('closeAll cuts every terminal off at once, before any session '
        'has finished closing', () async {
      await rig.openId('term');
      await rig.openId('term2');
      final drives = [
        for (final s in rig.sessions.sessions) s.controller.assistantDrive!,
      ];
      final closing = rig.terminals.closeAll(AssistantTerminalEnd.bridgeOff);
      expect(drives.map((d) => d.state), everyElement(AssistantDriveState.ended));
      await closing;
      expect(rig.sessions.length, 0);
    });

    test('a secret the terminal wrapped across two rows is still found '
        'by the redactor', () async {
      final id = await rig.openId('term');
      // "hunter2" straddles column 120.
      rig.dialled.single.shell.emit('${'x' * 117}hunter2 tail\r\n');
      await rig.settle();
      final r = await rig.call('read_screen', {'terminal_id': id});
      expect(r.text, isNot(contains('hunter2')));
      expect(r.text, isNot(contains('hun\n')));
      expect(r.text, contains('[redacted]'));
    });

    test('a call to a terminal cannot choose the host its audit entry '
        'names', () async {
      final id = await rig.openId('term');
      await rig.call('send_input', {
        'terminal_id': id,
        'text': 'x',
        'host': 'a-name-the-caller-made-up',
      });
      expect(rig.entries.last.host, 'term');
      final theirs = await rig.call('read_screen', {
        'terminal_id': id,
        'host': 'db',
      }, client: _other);
      expect(theirs.text, BridgeRefusals.terminalNotAvailable.message);
      // What the other client put in its own argument names nothing true.
      expect(rig.entries.last.host, isNull);
    });
  });

  group('the bridge service closes them on its events', () {
    late SettingsStore settings;
    late BridgeClientStore clients;
    late BridgeClient paired;
    late StreamController<bool> lock;
    late StreamController<List<Host>> hostChanges;
    late BridgeService service;

    setUp(() async {
      settings = SettingsStore(file: File('${temp.path}/settings.json'));
      await settings.save(settings.current.copyWith(bridgeEnabled: true));
      clients = BridgeClientStore(file: File('${temp.path}/clients.json'));
      paired = (await clients.create('Desk assistant')).client;
      lock = StreamController<bool>.broadcast();
      hostChanges = StreamController<List<Host>>.broadcast();
      service = BridgeService(
        settingsStore: settings,
        clients: clients,
        tools: rig.tools,
        connections: rig.tools.connections,
        createListener: (verify) async => BridgeListener(
          bridgeDir: '${temp.path}/bridge',
          verify: verify,
          transport: platformBridgeTransport,
        ),
        appLockChanges: lock.stream,
        hostChanges: hostChanges.stream,
        terminals: rig.terminals,
      );
      await service.start();
    });

    tearDown(() async {
      await service.dispose();
      await lock.close();
      await hostChanges.close();
    });

    test('exposes the registry to the UI', () {
      expect(service.terminals, same(rig.terminals));
    });

    test('bridge switched off', () async {
      await rig.openId('term', client: paired);
      await settings.update((s) => s.copyWith(bridgeEnabled: false));
      for (var i = 0; i < 100 && rig.sessions.length > 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(rig.sessions.length, 0);
      expect(rig.terminals.liveCount, 0);
    });

    test('app locked', () async {
      await rig.openId('term', client: paired);
      lock.add(true);
      await rig.settle();
      expect(rig.sessions.length, 0);
    });

    test('client revoked', () async {
      await rig.openId('term', client: paired);
      await rig.openId('term2');
      await clients.revoke(paired.id);
      await rig.settle();
      expect(rig.terminals.liveCount, 0);
      expect(rig.sessions.length, 0);
    });

    test('host changed', () async {
      await rig.openId('term', client: paired);
      hostChanges.add([
        for (final h in rig.hosts)
          h.id == 'trm1' ? h.copyWith(aiTerminal: false) : h,
      ]);
      await rig.settle();
      expect(rig.sessions.length, 0);
    });

    test('re-routing the host through another jump host withdraws its '
        'cards, revokes its grants and closes the terminal', () async {
      await rig.openId('term', client: paired);
      rig.grants.grant(paired.id, 'trm1', const Duration(minutes: 15));
      final waiting = rig.call('open_terminal', {
        'host': 'term',
      }, client: paired);
      await rig.card();
      final rerouted = [
        for (final h in rig.hosts) h.id == 'trm1' ? h.withJumpHost('trm2') : h,
      ];
      rig.hosts = rerouted;
      hostChanges.add(rerouted);
      await rig.settle();
      expect((await waiting).isError, true);
      expect(rig.approvals.current, isEmpty);
      expect(rig.grants.hasLive(paired.id, 'trm1'), false);
      expect(rig.terminals.liveCount, 0);
      expect(rig.sessions.length, 0);
    });

    test('dispose', () async {
      await rig.openId('term', client: paired);
      await service.dispose();
      expect(rig.sessions.length, 0);
    });
  });

  group('the session banner, against the real registry', () {
    Future<void> pumpBanner(WidgetTester tester, ManagedSession session) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StreamBuilder<void>(
                stream: session.controller.changes,
                builder: (_, _) => SessionBanners(
                  session: session,
                  terminals: rig.terminals,
                  onCloseTab: () => fail('Stop must go through the registry'),
                ),
              ),
            ),
          ),
        );

    testWidgets('Take over takes over that terminal, and the assistant\'s '
        'send_input is refused from then on', (tester) async {
      late String id;
      late String other;
      await tester.runAsync(() async {
        id = await rig.openId('term');
        other = await rig.openId('term2');
      });
      final session = rig.sessionOf(id);
      await pumpBanner(tester, session);
      expect(
        find.byKey(const ValueKey('assistant-banner-driving')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('assistant-take-over')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('assistant-banner-takenOver')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('assistant-take-over')), findsNothing);
      late ({String text, bool isError}) refused;
      late ({String text, bool isError}) untouched;
      await tester.runAsync(() async {
        refused = await rig.call('send_input', {
          'terminal_id': id,
          'text': 'rm -rf /tmp/x\n',
        });
        untouched = await rig.call('send_input', {
          'terminal_id': other,
          'text': 'uptime\n',
        });
      });
      expect(refused.isError, isTrue);
      expect(refused.text, BridgeTerminalRefusals.takenOver.message);
      expect(rig.dialled.first.shell.writtenText, isNot(contains('rm -rf')));
      // Only that terminal: the other one still takes the assistant's input.
      expect(untouched.isError, isFalse, reason: untouched.text);
      expect(rig.dialled.last.shell.writtenText, contains('uptime'));
      expect(rig.sessions.byId(session.id), isNotNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Stop stops that terminal through the registry', (
      tester,
    ) async {
      late String id;
      late String other;
      await tester.runAsync(() async {
        id = await rig.openId('term');
        other = await rig.openId('term2');
      });
      final session = rig.sessionOf(id);
      await pumpBanner(tester, session);
      await tester.tap(find.byKey(const ValueKey('assistant-stop')));
      // The stop runs from the tap, on the test's clock: turn both loops
      // until it has closed the shell (bounded; the expectations decide).
      for (var i = 0; i < 200 && !rig.dialled.first.shell.closed; i++) {
        await tester.runAsync(rig.settle);
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(rig.sessions.byId(session.id), isNull);
      expect(rig.dialled.first.shell.closed, isTrue);
      expect(rig.terminals.current.map((t) => t.terminalId), [other]);
      late ({String text, bool isError}) refused;
      await tester.runAsync(() async {
        refused = await rig.call('send_input', {
          'terminal_id': id,
          'text': 'x',
        });
      });
      expect(refused.isError, isTrue);
      expect(refused.text, BridgeTerminalRefusals.stopped.message);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
