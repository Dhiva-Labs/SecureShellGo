import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/broadcast_input.dart';
import 'package:secure_shell_go/services/terminal_workspace.dart';

/// The whole of what the broadcast seam needs from a session — the same four
/// lines `terminal_workspace_test` gets away with, and for the same reason.
class FakeSession implements WorkspaceSession {
  FakeSession(this.id);

  @override
  final String id;

  final List<String> written = [];

  @override
  void writeInput(String data) => written.add(data);
}

WorkspaceSessionResolver resolverFor(List<FakeSession> sessions) {
  return (id) {
    for (final session in sessions) {
      if (session.id == id) return session;
    }
    return null;
  };
}

/// A workspace split into [panes] panes, each showing one fake session, with
/// the *first* pane focused — the arrangement nearly every test below wants.
///
/// Returns the workspace and the sessions in pane order, so a test can assert
/// on "everyone except the one I typed in" without hunting for ids.
({TerminalWorkspace workspace, List<FakeSession> sessions}) splitWorkspace(
  int panes,
) {
  final sessions = [for (var i = 0; i < panes; i++) FakeSession('s$i')];
  final workspace = TerminalWorkspace(resolveSession: resolverFor(sessions));
  workspace.syncSessions([for (final session in sessions) session.id]);
  for (var i = 1; i < panes; i++) {
    workspace.splitFocused(WorkspaceAxis.row);
  }
  // Opening and splitting leaves the sessions in whatever panes the workspace
  // chose to fill; these tests are about *which pane is focused*, so pin the
  // arrangement down rather than reasoning about it at every call site.
  for (var i = 0; i < panes; i++) {
    workspace.showSession(sessions[i].id, inPaneId: workspace.panes[i].id);
  }
  workspace.focusPane(workspace.panes.first.id);
  return (workspace: workspace, sessions: sessions);
}

/// The change stream is a broadcast [Stream], so a notification lands a
/// microtask after the mutation that caused it.
Future<void> settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  group('the toggle', () {
    test('is off to begin with', () {
      final split = splitWorkspace(2);
      final broadcast = BroadcastInput(workspace: split.workspace);
      addTearDown(broadcast.dispose);

      expect(broadcast.enabled, isFalse);
    });

    test('refuses to turn on when there is only one pane', () {
      final workspace = TerminalWorkspace();
      final broadcast = BroadcastInput(workspace: workspace);
      addTearDown(broadcast.dispose);

      expect(broadcast.isAvailable, isFalse);
      broadcast.setEnabled(true);

      expect(broadcast.enabled, isFalse);
    });

    test('turns on in a split, and back off again', () {
      final split = splitWorkspace(2);
      final broadcast = BroadcastInput(workspace: split.workspace);
      addTearDown(broadcast.dispose);

      broadcast.toggle();
      expect(broadcast.enabled, isTrue);

      broadcast.toggle();
      expect(broadcast.enabled, isFalse);
    });

    test('publishes every change', () async {
      final split = splitWorkspace(2);
      final broadcast = BroadcastInput(workspace: split.workspace);
      addTearDown(broadcast.dispose);

      var notifications = 0;
      broadcast.changes.listen((_) => notifications++);

      broadcast.setEnabled(true);
      // Setting it to what it already is is not a change.
      broadcast.setEnabled(true);
      broadcast.setEnabled(false);
      await settle();

      expect(notifications, 2);
    });

    test('turns itself off when the split collapses to one pane', () async {
      final split = splitWorkspace(2);
      final workspace = split.workspace;
      final broadcast = BroadcastInput(workspace: workspace);
      addTearDown(broadcast.dispose);

      broadcast.setEnabled(true);
      expect(broadcast.enabled, isTrue);

      workspace.closePane(workspace.panes.last.id);
      await settle();

      expect(workspace.isSplit, isFalse);
      expect(broadcast.enabled, isFalse,
          reason: 'a mode nobody can see must not stay armed');
    });

    test('does not re-arm itself when the user splits again', () async {
      final split = splitWorkspace(2);
      final workspace = split.workspace;
      final broadcast = BroadcastInput(workspace: workspace);
      addTearDown(broadcast.dispose);

      broadcast.setEnabled(true);
      workspace.closePane(workspace.panes.last.id);
      await settle();
      workspace.splitFocused(WorkspaceAxis.row);
      await settle();

      expect(workspace.isSplit, isTrue);
      expect(broadcast.enabled, isFalse);
    });

    test('counts every visible pane, the focused one included', () {
      final split = splitWorkspace(3);
      final broadcast = BroadcastInput(workspace: split.workspace);
      addTearDown(broadcast.dispose);

      expect(broadcast.targetCount, 3);
    });
  });

  group('while off', () {
    test('a keystroke goes nowhere near the other panes', () {
      final split = splitWorkspace(3);
      final broadcast = BroadcastInput(workspace: split.workspace);
      addTearDown(broadcast.dispose);

      expect(broadcast.handleInput('s0', 'ls\r'), 0);
      for (final session in split.sessions) {
        expect(session.written, isEmpty);
      }
    });
  });

  group('while on', () {
    test('mirrors into every pane except the one being typed in', () {
      final split = splitWorkspace(3);
      final broadcast = BroadcastInput(workspace: split.workspace);
      addTearDown(broadcast.dispose);
      broadcast.setEnabled(true);

      final delivered = broadcast.handleInput('s0', 'uptime\r');

      expect(delivered, 2);
      // The focused pane has already had it — that is how it got here —
      // and a second copy would double every character the user types.
      expect(split.sessions[0].written, isEmpty);
      expect(split.sessions[1].written, ['uptime\r']);
      expect(split.sessions[2].written, ['uptime\r']);
    });

    test('follows the focus rather than a fixed pane', () {
      final split = splitWorkspace(3);
      final workspace = split.workspace;
      final broadcast = BroadcastInput(workspace: workspace);
      addTearDown(broadcast.dispose);
      broadcast.setEnabled(true);

      workspace.focusPane(workspace.panes[1].id);
      broadcast.handleInput('s1', 'w\r');

      expect(split.sessions[0].written, ['w\r']);
      expect(split.sessions[1].written, isEmpty);
      expect(split.sessions[2].written, ['w\r']);
    });

    test('ignores output from a pane that is not focused', () {
      final split = splitWorkspace(3);
      final broadcast = BroadcastInput(workspace: split.workspace);
      addTearDown(broadcast.dispose);
      broadcast.setEnabled(true);

      // A background program answering a query on pane 2 is not the user
      // typing, and must not be treated as if it were.
      final delivered = broadcast.handleInput('s2', '\x1b[?1;2c');

      expect(delivered, 0);
      for (final session in split.sessions) {
        expect(session.written, isEmpty);
      }
    });

    test('cannot feed itself', () {
      final sessions = [FakeSession('s0'), FakeSession('s1')];
      late BroadcastInput broadcast;
      // A session that re-enters the broadcaster the instant it is written to
      // — which is exactly what the live wiring does, since a mirrored
      // keystroke arrives through the same input tap a real one does.
      final reentrant = _ReentrantSession('s1', () {
        broadcast.handleInput('s0', 'x');
      });
      final workspace = TerminalWorkspace(
        resolveSession: (id) => id == 's0' ? sessions[0] : reentrant,
      );
      workspace.syncSessions(['s0', 's1']);
      workspace.splitFocused(WorkspaceAxis.row);
      workspace.showSession('s0', inPaneId: workspace.panes.first.id);
      workspace.showSession('s1', inPaneId: workspace.panes.last.id);
      workspace.focusPane(workspace.panes.first.id);
      broadcast = BroadcastInput(workspace: workspace);
      addTearDown(broadcast.dispose);
      broadcast.setEnabled(true);

      broadcast.handleInput('s0', 'x');

      // One delivery, not a stack overflow.
      expect(reentrant.written, ['x']);
    });

    test('leaves an empty pane out of the count of who took it', () {
      final split = splitWorkspace(3);
      final workspace = split.workspace;
      final broadcast = BroadcastInput(workspace: workspace);
      addTearDown(broadcast.dispose);
      broadcast.setEnabled(true);

      workspace.clearPane(workspace.panes.last.id);

      expect(broadcast.handleInput('s0', 'ls\r'), 1);
      expect(split.sessions[1].written, ['ls\r']);
      expect(split.sessions[2].written, isEmpty);
    });

    test('mirrors a paste as the single write the terminal made it', () {
      final split = splitWorkspace(2);
      final broadcast = BroadcastInput(workspace: split.workspace);
      addTearDown(broadcast.dispose);
      broadcast.setEnabled(true);

      // What `Terminal.paste` emits when the remote program asked for
      // bracketed paste: one write, markers and all.
      const pasted = '\x1b[200~echo hello\x1b[201~';
      broadcast.handleInput('s0', pasted);

      expect(split.sessions[1].written, [pasted]);
    });

    test('mirrors an extra-key-bar escape sequence', () {
      final split = splitWorkspace(2);
      final broadcast = BroadcastInput(workspace: split.workspace);
      addTearDown(broadcast.dispose);
      broadcast.setEnabled(true);

      // Up-arrow, and Ctrl-C, as the key bar produces them.
      broadcast.handleInput('s0', '\x1b[A');
      broadcast.handleInput('s0', '\x03');

      expect(split.sessions[1].written, ['\x1b[A', '\x03']);
    });

    test('ignores an empty write', () {
      final split = splitWorkspace(2);
      final broadcast = BroadcastInput(workspace: split.workspace);
      addTearDown(broadcast.dispose);
      broadcast.setEnabled(true);

      expect(broadcast.handleInput('s0', ''), 0);
      expect(split.sessions[1].written, isEmpty);
    });
  });

  group('mouse reports', () {
    test('are recognised in both encodings', () {
      // SGR, button down and button up.
      expect(BroadcastInput.isMouseReport('\x1b[<0;40;12M'), isTrue);
      expect(BroadcastInput.isMouseReport('\x1b[<0;40;12m'), isTrue);
      // X10, with its three raw coordinate bytes.
      expect(BroadcastInput.isMouseReport('\x1b[M\x20\x30\x40'), isTrue);
    });

    test('do not catch ordinary keys or text', () {
      expect(BroadcastInput.isMouseReport('m'), isFalse);
      expect(BroadcastInput.isMouseReport('\x1b[A'), isFalse);
      expect(BroadcastInput.isMouseReport('make\r'), isFalse);
      expect(BroadcastInput.isMouseReport('\x1b[200~m\x1b[201~'), isFalse);
    });

    test('are never mirrored', () {
      final split = splitWorkspace(2);
      final broadcast = BroadcastInput(workspace: split.workspace);
      addTearDown(broadcast.dispose);
      broadcast.setEnabled(true);

      // A click at row 12, column 40 of *this* pane means nothing in a pane of
      // a different size running a different program.
      expect(broadcast.handleInput('s0', '\x1b[<0;40;12M'), 0);
      expect(split.sessions[1].written, isEmpty);
    });
  });
}

/// A session that calls back into the broadcaster the moment it is written to.
class _ReentrantSession implements WorkspaceSession {
  _ReentrantSession(this.id, this.onWrite);

  @override
  final String id;

  final void Function() onWrite;

  final List<String> written = [];

  @override
  void writeInput(String data) {
    written.add(data);
    onWrite();
  }
}
