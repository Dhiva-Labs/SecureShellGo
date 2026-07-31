import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/terminal_workspace.dart';

/// The whole of what the broadcast seam needs from a session, and therefore
/// the whole of what a test of it needs to provide — which is the point of
/// [WorkspaceSession] being as narrow as it is.
class FakeSession implements WorkspaceSession {
  FakeSession(this.id);

  @override
  final String id;

  final List<String> written = [];

  @override
  void writeInput(String data) => written.add(data);
}

/// A resolver over a fixed set of sessions, so a test can also arrange for a
/// binding to resolve to *nothing* — a session closed out from under a pane.
WorkspaceSessionResolver resolverFor(List<FakeSession> sessions) {
  return (id) {
    for (final session in sessions) {
      if (session.id == id) return session;
    }
    return null;
  };
}

/// The manager's change stream is a broadcast [Stream], so a notification
/// lands a microtask after the mutation that caused it — same shape as
/// `session_manager_test`'s settle().
Future<void> settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  group('a fresh workspace', () {
    test('is one empty pane, focused', () {
      final workspace = TerminalWorkspace();
      addTearDown(workspace.dispose);

      expect(workspace.paneCount, 1);
      expect(workspace.isSplit, isFalse);
      expect(workspace.canSplit, isTrue);
      expect(workspace.root, isA<WorkspacePane>());
      expect(workspace.focusedPane.isEmpty, isTrue);
      expect(workspace.focusedPaneId, (workspace.root as WorkspacePane).id);
      expect(workspace.visibleSessionIds, isEmpty);
    });
  });

  group('splitting', () {
    test('turns the focused pane into two and focuses the new one', () {
      final workspace = TerminalWorkspace();
      addTearDown(workspace.dispose);
      final original = workspace.focusedPane;

      final created = workspace.splitFocused(WorkspaceAxis.row);

      expect(created, isNotNull);
      expect(workspace.paneCount, 2);
      expect(workspace.isSplit, isTrue);
      expect(workspace.focusedPaneId, created!.id);
      expect(workspace.panes, [original, created]);
    });

    test('leaves the pane it split exactly where it was', () {
      final workspace = TerminalWorkspace();
      addTearDown(workspace.dispose);
      final original = workspace.focusedPane;

      workspace.splitFocused(WorkspaceAxis.row);

      final root = workspace.root as WorkspaceSplit;
      expect(root.axis, WorkspaceAxis.row);
      expect(root.first, same(original));
      expect(root.ratio, TerminalWorkspace.evenRatio);
    });

    test('a column split stacks rather than sits side by side', () {
      final workspace = TerminalWorkspace();
      addTearDown(workspace.dispose);

      workspace.splitFocused(WorkspaceAxis.column);

      expect((workspace.root as WorkspaceSplit).axis, WorkspaceAxis.column);
    });

    test('splitting inside a split nests in place, without reshuffling', () {
      final workspace = TerminalWorkspace();
      addTearDown(workspace.dispose);
      final first = workspace.focusedPane;

      final second = workspace.splitFocused(WorkspaceAxis.row)!;
      final third = workspace.splitFocused(WorkspaceAxis.column)!;

      final root = workspace.root as WorkspaceSplit;
      expect(root.axis, WorkspaceAxis.row);
      expect(root.first, same(first));

      final inner = root.second as WorkspaceSplit;
      expect(inner.axis, WorkspaceAxis.column);
      expect(inner.first, same(second));
      expect(inner.second, same(third));
      // Reading order: left column, then the two stacked on the right.
      expect(workspace.panes, [first, second, third]);
    });

    test('a fifth pane is refused, and nothing moves', () {
      final workspace = TerminalWorkspace();
      addTearDown(workspace.dispose);

      workspace.splitFocused(WorkspaceAxis.row);
      workspace.splitFocused(WorkspaceAxis.column);
      workspace.splitFocused(WorkspaceAxis.row);
      expect(workspace.paneCount, TerminalWorkspace.paneLimit);
      expect(workspace.canSplit, isFalse);

      final focusedBefore = workspace.focusedPaneId;
      expect(workspace.splitFocused(WorkspaceAxis.row), isNull);
      expect(workspace.paneCount, TerminalWorkspace.paneLimit);
      expect(workspace.focusedPaneId, focusedBefore);
    });

    test('splitting a pane that is not there does nothing', () {
      final workspace = TerminalWorkspace();
      addTearDown(workspace.dispose);

      expect(workspace.split('pane-nope', WorkspaceAxis.row), isNull);
      expect(workspace.paneCount, 1);
    });

    test('the new pane picks up an open session nothing is showing', () {
      final workspace = TerminalWorkspace();
      addTearDown(workspace.dispose);
      workspace.syncSessions(['s1', 's2'], activeId: 's1');

      final created = workspace.splitFocused(WorkspaceAxis.row);

      expect(created!.sessionId, 's2');
      expect(workspace.visibleSessionIds, ['s1', 's2']);
    });

    test('the new pane stays empty when every session is already up', () {
      final workspace = TerminalWorkspace();
      addTearDown(workspace.dispose);
      workspace.syncSessions(['s1'], activeId: 's1');

      final created = workspace.splitFocused(WorkspaceAxis.row);

      expect(created!.sessionId, isNull);
    });

    test('notifies', () async {
      final workspace = TerminalWorkspace();
      addTearDown(workspace.dispose);
      final notified = workspace.changes.first;

      workspace.splitFocused(WorkspaceAxis.row);

      await notified;
    });
  });

  group('closing a pane', () {
    test('hands the space to its sibling and collapses the split', () {
      final workspace = TerminalWorkspace();
      addTearDown(workspace.dispose);
      final first = workspace.focusedPane;
      final second = workspace.splitFocused(WorkspaceAxis.row)!;

      expect(workspace.closePane(second.id), isTrue);

      expect(workspace.paneCount, 1);
      expect(workspace.root, same(first));
      expect(workspace.isSplit, isFalse);
    });

    test('the last pane cannot be closed', () {
      final workspace = TerminalWorkspace();
      addTearDown(workspace.dispose);

      expect(workspace.closePane(workspace.focusedPaneId), isFalse);
      expect(workspace.paneCount, 1);
    });

    test('the focus moves out of the pane that went', () {
      final workspace = TerminalWorkspace();
      addTearDown(workspace.dispose);
      final first = workspace.focusedPane;
      final second = workspace.splitFocused(WorkspaceAxis.row)!;
      workspace.focusPane(first.id);

      workspace.closePane(first.id);

      expect(workspace.focusedPaneId, second.id);
      expect(workspace.paneById(first.id), isNull);
    });

    test('closing some other pane leaves the focus alone', () {
      final workspace = TerminalWorkspace();
      addTearDown(workspace.dispose);
      final first = workspace.focusedPane;
      workspace.splitFocused(WorkspaceAxis.row);
      final third = workspace.splitFocused(WorkspaceAxis.row)!;

      workspace.closePane(first.id);

      expect(workspace.focusedPaneId, third.id);
      expect(workspace.paneCount, 2);
    });

    test('the session it was showing stays open and can come back', () {
      final workspace = TerminalWorkspace();
      addTearDown(workspace.dispose);
      workspace.syncSessions(['s1', 's2'], activeId: 's1');
      final second = workspace.splitFocused(WorkspaceAxis.row)!;
      expect(second.sessionId, 's2');

      workspace.closePane(second.id);
      expect(workspace.visibleSessionIds, ['s1']);

      // Still known, so it is still offerable — closing a pane is a layout
      // edit, not a disconnect.
      workspace.showSession('s2');
      expect(workspace.visibleSessionIds, ['s2']);
    });

    test('collapsing an inner split leaves the outer ratio untouched', () {
      final workspace = TerminalWorkspace();
      addTearDown(workspace.dispose);
      workspace.splitFocused(WorkspaceAxis.row);
      final outer = workspace.root as WorkspaceSplit;
      workspace.setRatio(outer.id, 0.3);

      final third = workspace.splitFocused(WorkspaceAxis.column)!;
      workspace.closePane(third.id);

      expect(workspace.paneCount, 2);
      expect((workspace.root as WorkspaceSplit).ratio, 0.3);
    });
  });

  group('resizing', () {
    test('moves the divider of the split it names', () {
      final workspace = TerminalWorkspace();
      addTearDown(workspace.dispose);
      workspace.splitFocused(WorkspaceAxis.row);
      final split = workspace.root as WorkspaceSplit;

      workspace.setRatio(split.id, 0.7);

      expect(split.ratio, 0.7);
    });

    test('clamps at both ends so a pane can never be dragged shut', () {
      final workspace = TerminalWorkspace();
      addTearDown(workspace.dispose);
      workspace.splitFocused(WorkspaceAxis.row);
      final split = workspace.root as WorkspaceSplit;

      workspace.setRatio(split.id, 0);
      expect(split.ratio, TerminalWorkspace.minRatio);

      workspace.setRatio(split.id, 5);
      expect(split.ratio, 1 - TerminalWorkspace.minRatio);
    });

    test('an unknown split is ignored', () {
      final workspace = TerminalWorkspace();
      addTearDown(workspace.dispose);

      workspace.setRatio('split-nope', 0.7);

      expect(workspace.paneCount, 1);
    });

    test('nested splits keep their own ratios', () {
      final workspace = TerminalWorkspace();
      addTearDown(workspace.dispose);
      workspace.splitFocused(WorkspaceAxis.row);
      final outer = workspace.root as WorkspaceSplit;
      workspace.splitFocused(WorkspaceAxis.column);
      final inner = outer.second as WorkspaceSplit;

      workspace.setRatio(outer.id, 0.25);
      workspace.setRatio(inner.id, 0.8);

      expect(outer.ratio, 0.25);
      expect(inner.ratio, 0.8);
    });

    test('sub-pixel drag noise does not repaint the workspace', () async {
      final workspace = TerminalWorkspace();
      addTearDown(workspace.dispose);
      workspace.splitFocused(WorkspaceAxis.row);
      final split = workspace.root as WorkspaceSplit;

      var notifications = 0;
      final subscription = workspace.changes.listen((_) => notifications++);
      addTearDown(subscription.cancel);

      workspace.setRatio(split.id, TerminalWorkspace.evenRatio + 0.0001);
      await settle();

      expect(notifications, 0);
      expect(split.ratio, TerminalWorkspace.evenRatio);
    });
  });

  group('focus', () {
    test('exactly one pane is focused, whatever the tree looks like', () {
      final workspace = TerminalWorkspace();
      addTearDown(workspace.dispose);

      workspace.splitFocused(WorkspaceAxis.row);
      workspace.splitFocused(WorkspaceAxis.column);
      workspace.splitFocused(WorkspaceAxis.row);

      final focused =
          workspace.panes.where((p) => p.id == workspace.focusedPaneId);
      expect(focused, hasLength(1));
    });

    test('follows a click into another pane', () async {
      final workspace = TerminalWorkspace();
      addTearDown(workspace.dispose);
      final first = workspace.focusedPane;
      workspace.splitFocused(WorkspaceAxis.row);
      final notified = workspace.changes.first;

      workspace.focusPane(first.id);

      await notified;
      expect(workspace.focusedPaneId, first.id);
    });

    test('a pane that is not there cannot take the keyboard', () {
      final workspace = TerminalWorkspace();
      addTearDown(workspace.dispose);
      final before = workspace.focusedPaneId;

      workspace.focusPane('pane-nope');

      expect(workspace.focusedPaneId, before);
    });
  });

  group('session bindings', () {
    test('showSession fills the focused pane by default', () {
      final workspace = TerminalWorkspace();
      addTearDown(workspace.dispose);

      workspace.showSession('s1');

      expect(workspace.focusedSessionId, 's1');
      expect(workspace.visibleSessionIds, ['s1']);
    });

    test('a session is never in two panes at once', () {
      final workspace = TerminalWorkspace();
      addTearDown(workspace.dispose);
      final first = workspace.focusedPane;
      final second = workspace.splitFocused(WorkspaceAxis.row)!;
      workspace.showSession('s1', inPaneId: first.id);

      workspace.showSession('s1', inPaneId: second.id);

      expect(second.sessionId, 's1');
      expect(first.sessionId, isNull);
      expect(workspace.visibleSessionIds, ['s1']);
    });

    test('moving a visible session onto an occupied pane swaps the two', () {
      final workspace = TerminalWorkspace();
      addTearDown(workspace.dispose);
      final first = workspace.focusedPane;
      final second = workspace.splitFocused(WorkspaceAxis.row)!;
      workspace.showSession('s1', inPaneId: first.id);
      workspace.showSession('s2', inPaneId: second.id);

      workspace.showSession('s2', inPaneId: first.id);

      expect(first.sessionId, 's2');
      expect(second.sessionId, 's1');
    });

    test('clearing a pane empties it without disturbing the others', () {
      final workspace = TerminalWorkspace();
      addTearDown(workspace.dispose);
      final first = workspace.focusedPane;
      final second = workspace.splitFocused(WorkspaceAxis.row)!;
      workspace.showSession('s1', inPaneId: first.id);
      workspace.showSession('s2', inPaneId: second.id);

      workspace.clearPane(first.id);

      expect(first.sessionId, isNull);
      expect(second.sessionId, 's2');
      expect(workspace.visibleSessionIds, ['s2']);
    });

    test('showSession on a pane that is not there does nothing', () {
      final workspace = TerminalWorkspace();
      addTearDown(workspace.dispose);

      workspace.showSession('s1', inPaneId: 'pane-nope');

      expect(workspace.visibleSessionIds, isEmpty);
    });

    test('re-showing what is already there is not a change', () async {
      final workspace = TerminalWorkspace();
      addTearDown(workspace.dispose);
      workspace.showSession('s1');

      var notifications = 0;
      final subscription = workspace.changes.listen((_) => notifications++);
      addTearDown(subscription.cancel);

      workspace.showSession('s1');
      await settle();

      expect(notifications, 0);
    });
  });

  group('syncSessions', () {
    test('the first sync puts the active session in the only pane', () {
      final workspace = TerminalWorkspace();
      addTearDown(workspace.dispose);

      workspace.syncSessions(['s1', 's2', 's3'], activeId: 's2');

      expect(workspace.focusedSessionId, 's2');
      expect(workspace.paneCount, 1);
    });

    test('with no active named, the newest of a batch wins', () {
      final workspace = TerminalWorkspace();
      addTearDown(workspace.dispose);

      workspace.syncSessions(['s1', 's2']);

      expect(workspace.focusedSessionId, 's2');
    });

    test('a newly opened session lands in the focused pane', () {
      final workspace = TerminalWorkspace();
      addTearDown(workspace.dispose);
      workspace.syncSessions(['s1'], activeId: 's1');
      final second = workspace.splitFocused(WorkspaceAxis.row)!;
      expect(workspace.focusedPaneId, second.id);

      workspace.syncSessions(['s1', 's2'], activeId: 's2');

      expect(second.sessionId, 's2');
      expect(workspace.visibleSessionIds, ['s1', 's2']);
    });

    test('a closed session empties its pane rather than removing it', () {
      final workspace = TerminalWorkspace();
      addTearDown(workspace.dispose);
      workspace.syncSessions(['s1', 's2'], activeId: 's1');
      final second = workspace.splitFocused(WorkspaceAxis.row)!;
      expect(second.sessionId, 's2');

      workspace.syncSessions(['s1'], activeId: 's1');

      expect(workspace.paneCount, 2);
      expect(second.sessionId, isNull);
      expect(workspace.visibleSessionIds, ['s1']);
    });

    test('a session closing elsewhere does not move the visible ones', () {
      final workspace = TerminalWorkspace();
      addTearDown(workspace.dispose);
      workspace.syncSessions(['s1', 's2', 's3'], activeId: 's1');
      final second = workspace.splitFocused(WorkspaceAxis.row)!;
      expect(second.sessionId, 's2');

      workspace.syncSessions(['s1', 's2'], activeId: 's1');

      expect(workspace.visibleSessionIds, ['s1', 's2']);
    });

    test('re-syncing the same set changes nothing and says nothing',
        () async {
      final workspace = TerminalWorkspace();
      addTearDown(workspace.dispose);
      workspace.syncSessions(['s1', 's2'], activeId: 's1');

      var notifications = 0;
      final subscription = workspace.changes.listen((_) => notifications++);
      addTearDown(subscription.cancel);

      workspace.syncSessions(['s1', 's2'], activeId: 's1');
      await settle();

      expect(notifications, 0);
    });

    test('a session reopened after being closed counts as new again', () {
      final workspace = TerminalWorkspace();
      addTearDown(workspace.dispose);
      workspace.syncSessions(['s1'], activeId: 's1');
      workspace.syncSessions([], activeId: null);
      expect(workspace.visibleSessionIds, isEmpty);

      workspace.syncSessions(['s2'], activeId: 's2');

      expect(workspace.focusedSessionId, 's2');
    });
  });

  group('the broadcast seam', () {
    test('enumerates visible sessions in reading order', () {
      final sessions = [FakeSession('s1'), FakeSession('s2')];
      final workspace = TerminalWorkspace(
        resolveSession: resolverFor(sessions),
      );
      addTearDown(workspace.dispose);
      final first = workspace.focusedPane;
      final second = workspace.splitFocused(WorkspaceAxis.row)!;
      workspace.showSession('s2', inPaneId: first.id);
      workspace.showSession('s1', inPaneId: second.id);

      expect(workspace.visibleSessionIds, ['s2', 's1']);
      expect(
        workspace.visibleSessions().map((s) => s.id),
        ['s2', 's1'],
      );
    });

    test('skips empty panes', () {
      final sessions = [FakeSession('s1')];
      final workspace = TerminalWorkspace(
        resolveSession: resolverFor(sessions),
      );
      addTearDown(workspace.dispose);
      workspace.showSession('s1');
      workspace.splitFocused(WorkspaceAxis.row);

      expect(workspace.paneCount, 2);
      expect(workspace.visibleSessions(), hasLength(1));
    });

    test('writes to every visible session and counts them', () {
      final sessions = [FakeSession('s1'), FakeSession('s2')];
      final workspace = TerminalWorkspace(
        resolveSession: resolverFor(sessions),
      );
      addTearDown(workspace.dispose);
      final first = workspace.focusedPane;
      workspace.showSession('s1', inPaneId: first.id);
      final second = workspace.splitFocused(WorkspaceAxis.row)!;
      workspace.showSession('s2', inPaneId: second.id);

      expect(workspace.writeToVisibleSessions('uptime\r'), 2);

      expect(sessions[0].written, ['uptime\r']);
      expect(sessions[1].written, ['uptime\r']);
    });

    test('can leave the pane the user is typing in alone', () {
      final sessions = [FakeSession('s1'), FakeSession('s2')];
      final workspace = TerminalWorkspace(
        resolveSession: resolverFor(sessions),
      );
      addTearDown(workspace.dispose);
      final first = workspace.focusedPane;
      workspace.showSession('s1', inPaneId: first.id);
      final second = workspace.splitFocused(WorkspaceAxis.row)!;
      workspace.showSession('s2', inPaneId: second.id);
      expect(workspace.focusedSessionId, 's2');

      expect(
        workspace.writeToVisibleSessions('ls\r', skipFocused: true),
        1,
      );

      expect(sessions[0].written, ['ls\r']);
      expect(sessions[1].written, isEmpty);
    });

    test('a binding the resolver no longer knows is skipped, not thrown', () {
      final sessions = [FakeSession('s1')];
      final workspace = TerminalWorkspace(
        resolveSession: resolverFor(sessions),
      );
      addTearDown(workspace.dispose);
      final first = workspace.focusedPane;
      workspace.showSession('s1', inPaneId: first.id);
      final second = workspace.splitFocused(WorkspaceAxis.row)!;
      workspace.showSession('gone', inPaneId: second.id);

      expect(workspace.visibleSessionIds, ['s1', 'gone']);
      expect(workspace.writeToVisibleSessions('w\r'), 1);
      expect(sessions[0].written, ['w\r']);
    });

    test('without a resolver it still answers, honestly', () {
      final workspace = TerminalWorkspace();
      addTearDown(workspace.dispose);
      workspace.showSession('s1');

      expect(workspace.visibleSessionIds, ['s1']);
      expect(workspace.visibleSessions(), isEmpty);
      expect(workspace.writeToVisibleSessions('x'), 0);
    });
  });
}
