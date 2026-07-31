import 'dart:async';

import 'session_controller.dart';

/// Which way a split arranges its two children.
///
/// Named after the arrangement rather than after the divider on purpose:
/// every terminal emulator disagrees about whether "split horizontally" means
/// a horizontal divider or two panes side by side, and half the users of each
/// one mean the opposite. The menu says "Split right" and "Split down" for the
/// same reason.
enum WorkspaceAxis {
  /// Two children side by side, divider running top to bottom.
  row,

  /// Two children one above the other, divider running left to right.
  column,
}

/// A node in the pane tree: either a [WorkspacePane] or a [WorkspaceSplit].
///
/// Sealed so the layout can switch over it exhaustively — a third kind of node
/// would then be a compile error at every site that draws one, rather than a
/// silently unhandled case.
sealed class WorkspaceNode {
  WorkspaceNode._(this.id);

  /// Unique for the life of the process. Panes are identified by id rather
  /// than by position because the position is exactly what splitting and
  /// closing change.
  final String id;
}

/// One rectangle of screen showing (at most) one session.
///
/// The binding is a session *id*, not a controller: a pane outlives the
/// session it was showing, and a layout that held a live object would keep a
/// dead transport alive and would have to be told when to let go.
class WorkspacePane extends WorkspaceNode {
  WorkspacePane._(super.id) : super._();

  /// The session on screen here, or null for a pane the user has emptied (or
  /// whose session has since been closed).
  String? get sessionId => _sessionId;
  String? _sessionId;

  bool get isEmpty => _sessionId == null;
}

/// Two children and the divider between them.
class WorkspaceSplit extends WorkspaceNode {
  /// Positional, unusually for this codebase, because the fields behind
  /// [first], [second] and [ratio] are private and a *named* initialising
  /// formal cannot start with an underscore — the alternative is three
  /// hand-written assignments and three lint suppressions for no gain. One
  /// private call site, in [TerminalWorkspace.split].
  WorkspaceSplit._(super.id, this.axis, this._first, this._second, this._ratio)
      : super._();

  final WorkspaceAxis axis;

  /// Left child in a [WorkspaceAxis.row], top child in a column.
  WorkspaceNode get first => _first;
  WorkspaceNode _first;

  WorkspaceNode get second => _second;
  WorkspaceNode _second;

  /// The fraction of this split's extent given to [first], clamped away from
  /// the ends by [TerminalWorkspace.minRatio]. A terminal squeezed below a few
  /// columns is not a smaller terminal, it is an unusable one, and a divider
  /// dragged to the very edge cannot be dragged back.
  double get ratio => _ratio;
  double _ratio;
}

/// Somewhere a broadcast can put keystrokes.
///
/// Deliberately the whole of what the workspace knows about a session. The
/// pane tree is a *layout*: it has no business with transports, transfer
/// queues or SFTP channels, and keeping the surface this narrow is what makes
/// "type once, send to every visible pane" a wiring job rather than a rewrite
/// — see [TerminalWorkspace.writeToVisibleSessions].
///
/// [LiveWorkspaceSession] is the production implementation; a test satisfies
/// this in four lines.
abstract class WorkspaceSession {
  String get id;

  /// Sends [data] to this session's shell exactly as if it had been typed.
  void writeInput(String data);
}

/// Finds the live session behind a pane's binding, or null when it has been
/// closed since the pane was bound to it.
typedef WorkspaceSessionResolver = WorkspaceSession? Function(String sessionId);

/// The pane tree of the desktop split-terminal workspace: what is split, how
/// far, which session is in which rectangle, and which rectangle has the
/// keyboard.
///
/// Free of Flutter imports like the rest of `services/`, and for the same
/// reason: the interesting part of a split view is the tree arithmetic —
/// splitting in place, collapsing a split when one side closes, keeping
/// exactly one pane focused however the tree is rearranged — and none of that
/// needs a widget tree to be true. Listeners get a plain broadcast [Stream],
/// matching [SessionController] and `SessionManager`.
///
/// It is built in `main.dart` alongside `SessionManager` rather than by a
/// route, for the same reason the manager is: leaving the sessions screen for
/// the host list is how a second session gets opened, and coming back must
/// find the layout — splits, ratios, bindings and all — where it was left.
///
/// Mobile never builds one. The tabbed phone layout is untouched by any of
/// this; the screen gates on the platform before it so much as reads the tree.
class TerminalWorkspace {
  TerminalWorkspace({WorkspaceSessionResolver? resolveSession})
      // ignore: prefer_initializing_formals
      : _resolveSession = resolveSession {
    _root = _newPane();
    _focusedPaneId = (_root as WorkspacePane).id;
  }

  /// Four is the cap the phase was given, and it is also about where the
  /// arithmetic stops being kind: a 1280-wide window quartered leaves each
  /// terminal around 78 columns, which is one column short of the width most
  /// people's `$COLUMNS` habits assume.
  static const int paneLimit = 4;

  /// The closest a divider may be dragged to either end of its split.
  static const double minRatio = 0.15;

  /// A new split divides its pane in half.
  static const double evenRatio = 0.5;

  final WorkspaceSessionResolver? _resolveSession;

  late WorkspaceNode _root;
  late String _focusedPaneId;

  /// Every open session id, in the order the tab strip shows them. Kept so
  /// [syncSessions] can tell a session that has just been opened from one that
  /// has been open all along, and so a freshly split pane has something to
  /// offer to fill itself with.
  final List<String> _known = [];

  var _nodeCounter = 0;

  final _changes = StreamController<void>.broadcast();

  /// Fires whenever the tree, a ratio, a binding or the focus changes.
  Stream<void> get changes => _changes.stream;

  WorkspaceNode get root => _root;

  /// Every pane, left to right and top to bottom — the order the user reads
  /// them in, which is also the order a broadcast should visit them in.
  List<WorkspacePane> get panes {
    final found = <WorkspacePane>[];
    void visit(WorkspaceNode node) {
      switch (node) {
        case WorkspacePane():
          found.add(node);
        case WorkspaceSplit():
          visit(node.first);
          visit(node.second);
      }
    }

    visit(_root);
    return List.unmodifiable(found);
  }

  int get paneCount => panes.length;

  /// True once the workspace is showing more than one pane. The single-pane
  /// case is deliberately indistinguishable from the layout that existed
  /// before any of this: no pane chrome, no dividers.
  bool get isSplit => paneCount > 1;

  /// Whether another split would stay inside [paneLimit].
  bool get canSplit => paneCount < paneLimit;

  String get focusedPaneId => _focusedPaneId;

  /// The pane with the keyboard. Never null: every mutation that could strand
  /// the focus moves it somewhere real before it returns.
  WorkspacePane get focusedPane => paneById(_focusedPaneId)!;

  /// The session in the focused pane, or null when that pane is empty.
  String? get focusedSessionId => focusedPane.sessionId;

  WorkspacePane? paneById(String id) {
    for (final pane in panes) {
      if (pane.id == id) return pane;
    }
    return null;
  }

  /// The pane showing [sessionId], or null when it is not on screen. At most
  /// one pane can be showing it — see [showSession].
  WorkspacePane? paneForSession(String sessionId) {
    for (final pane in panes) {
      if (pane.sessionId == sessionId) return pane;
    }
    return null;
  }

  WorkspaceSplit? splitById(String id) {
    WorkspaceSplit? search(WorkspaceNode node) {
      if (node is! WorkspaceSplit) return null;
      if (node.id == id) return node;
      return search(node.first) ?? search(node.second);
    }

    return search(_root);
  }

  // ------------------------------------------------------------------ focus

  /// Gives [paneId] the keyboard. Unknown ids are ignored.
  void focusPane(String paneId) {
    if (_focusedPaneId == paneId || paneById(paneId) == null) return;
    _focusedPaneId = paneId;
    _notify();
  }

  // ----------------------------------------------------------------- splits

  /// Splits the focused pane, or returns null when the workspace is already at
  /// [paneLimit].
  WorkspacePane? splitFocused(WorkspaceAxis axis) =>
      split(_focusedPaneId, axis);

  /// Splits [paneId] along [axis], putting the new pane after the existing one
  /// and moving the focus into it.
  ///
  /// The existing pane keeps its session and its place in the tree — the split
  /// is spliced in *above* it, so nothing already on screen jumps to a
  /// different corner. The new pane picks up the first open session that is
  /// not already visible somewhere, because a freshly split pane that shows
  /// nothing is a hole the user then has to fill by hand for the one case
  /// (a second server is already open) the whole feature exists for.
  ///
  /// Returns the new pane, or null when the split was refused.
  WorkspacePane? split(String paneId, WorkspaceAxis axis) {
    if (!canSplit) return null;
    final pane = paneById(paneId);
    if (pane == null) return null;

    final created = _newPane();
    final parent = _parentOf(paneId);
    final split = WorkspaceSplit._(
      _nextId('split'),
      axis,
      pane,
      created,
      evenRatio,
    );
    if (parent == null) {
      _root = split;
    } else if (parent.first.id == paneId) {
      parent._first = split;
    } else {
      parent._second = split;
    }

    created._sessionId = _firstUnboundSession();
    _focusedPaneId = created.id;
    _notify();
    return created;
  }

  /// Closes [paneId]; its sibling takes over the space the split was using.
  ///
  /// The session in it is *not* touched. Closing a pane is a layout edit —
  /// the session carries on running in the background and is one tap away in
  /// the tab strip, which is the difference between this and closing a tab.
  ///
  /// Refuses to close the last pane: a workspace with no panes has nothing to
  /// focus and nowhere to put the next session.
  bool closePane(String paneId) {
    final parent = _parentOf(paneId);
    // No parent means this is the root, which means it is the only pane.
    if (parent == null) return false;

    final sibling = parent.first.id == paneId ? parent.second : parent.first;
    final grandparent = _parentOf(parent.id);
    if (grandparent == null) {
      _root = sibling;
    } else if (grandparent.first.id == parent.id) {
      grandparent._first = sibling;
    } else {
      grandparent._second = sibling;
    }

    // The focus can only be stranded if it was in the pane that just went, or
    // somewhere under it — which cannot happen, since panes have no children.
    if (paneById(_focusedPaneId) == null) {
      _focusedPaneId = _firstPaneUnder(sibling).id;
    }
    _notify();
    return true;
  }

  /// Moves the divider of [splitId], as a fraction of that split's extent
  /// given to its first child. Clamped to [minRatio] at both ends.
  ///
  /// Ratios live here rather than in the widget that draws the divider so they
  /// survive everything a widget does not: a rebuild, a window resize, a trip
  /// to the host list and back.
  void setRatio(String splitId, double ratio) {
    final split = splitById(splitId);
    if (split == null) return;
    final clamped = ratio.clamp(minRatio, 1 - minRatio).toDouble();
    // Sub-pixel drag noise would otherwise repaint every pane on the screen
    // for a change nobody can see.
    if ((clamped - split._ratio).abs() < 0.0005) return;
    split._ratio = clamped;
    _notify();
  }

  // --------------------------------------------------------------- bindings

  /// Shows [sessionId] in [inPaneId], defaulting to the focused pane.
  ///
  /// A session appears in at most one pane, and this is where that invariant
  /// is kept. Two panes on one session would mean two `TerminalView`s over one
  /// `Terminal`, each reporting its own column count into the same
  /// `onResize` — the PTY would be resized twice per frame, to two different
  /// sizes, and full-screen programs would flicker between them.
  ///
  /// So a session that is already on screen is *swapped* rather than
  /// duplicated: the pane that had it takes whatever the target pane was
  /// showing (possibly nothing). Dragging session B onto the pane showing A
  /// therefore trades their places, which is what the gesture looks like it
  /// should do.
  void showSession(String sessionId, {String? inPaneId}) {
    final pane = paneById(inPaneId ?? _focusedPaneId);
    if (pane == null) return;
    if (_bind(pane, sessionId)) _notify();
  }

  /// Empties [paneId] without closing it. The session keeps running and stays
  /// in the tab strip.
  void clearPane(String paneId) {
    final pane = paneById(paneId);
    if (pane == null || pane._sessionId == null) return;
    pane._sessionId = null;
    _notify();
  }

  /// Reconciles the layout with the sessions that are actually open.
  ///
  /// Called by the screen whenever `SessionManager` changes, which is the only
  /// thing that knows. Two jobs:
  ///
  /// * a session that has been closed stops being drawn — its pane empties
  ///   rather than vanishing, because the *layout* is the user's and closing
  ///   a tab is not a request to rearrange it;
  /// * a session that has just been opened appears in the focused pane, which
  ///   is what "open a new session" is asking for when there is a pane in
  ///   front of you. [activeId] breaks the tie when several arrive at once
  ///   (the first sync after the screen is pushed, with sessions already
  ///   open).
  void syncSessions(List<String> openSessionIds, {String? activeId}) {
    final open = openSessionIds.toSet();
    var changed = false;

    for (final pane in panes) {
      final bound = pane._sessionId;
      if (bound != null && !open.contains(bound)) {
        pane._sessionId = null;
        changed = true;
      }
    }

    final arrived =
        openSessionIds.where((id) => !_known.contains(id)).toList();
    _known
      ..clear()
      ..addAll(openSessionIds);

    if (arrived.isNotEmpty) {
      var target = arrived.last;
      if (activeId != null && arrived.contains(activeId)) target = activeId;
      if (_bind(focusedPane, target)) changed = true;
    }

    if (changed) _notify();
  }

  // -------------------------------------------------------- broadcast seam

  /// Every session currently on screen, in reading order.
  ///
  /// This and [writeToVisibleSessions] are the seam the broadcast-input
  /// feature plugs into: "which shells is the user looking at" and "put this
  /// in all of them". No UI for it yet — deliberately — but the answer to both
  /// questions belongs to whatever owns the layout, and this owns the layout.
  List<String> get visibleSessionIds {
    final ids = <String>[];
    for (final pane in panes) {
      final id = pane.sessionId;
      if (id != null) ids.add(id);
    }
    return List.unmodifiable(ids);
  }

  /// The live session behind every visible pane, skipping panes that are empty
  /// and bindings the resolver no longer recognises.
  ///
  /// Empty when no resolver was supplied — a workspace built without one (unit
  /// tests of the tree arithmetic) can still be asked, and answers honestly.
  List<WorkspaceSession> visibleSessions() {
    final resolve = _resolveSession;
    if (resolve == null) return const [];
    final found = <WorkspaceSession>[];
    for (final id in visibleSessionIds) {
      final session = resolve(id);
      if (session != null) found.add(session);
    }
    return List.unmodifiable(found);
  }

  /// Types [data] into every visible pane's shell, and returns how many
  /// sessions took it.
  ///
  /// [skipFocused] leaves the pane the user is actually typing in alone, which
  /// is what a broadcast driven by real keystrokes needs — that pane has
  /// already had them.
  int writeToVisibleSessions(String data, {bool skipFocused = false}) {
    final focused = focusedSessionId;
    var written = 0;
    for (final session in visibleSessions()) {
      if (skipFocused && session.id == focused) continue;
      session.writeInput(data);
      written++;
    }
    return written;
  }

  // ---------------------------------------------------------------- private

  /// Puts [sessionId] in [pane], swapping with whichever pane had it. Returns
  /// whether anything moved. The swap is the invariant described on
  /// [showSession]; it lives here so [syncSessions] cannot forget it.
  bool _bind(WorkspacePane pane, String sessionId) {
    if (pane._sessionId == sessionId) return false;
    final displaced = pane._sessionId;
    final previous = paneForSession(sessionId);
    pane._sessionId = sessionId;
    previous?._sessionId = displaced;
    return true;
  }

  WorkspacePane _newPane() => WorkspacePane._(_nextId('pane'));

  String _nextId(String prefix) => '$prefix-${_nodeCounter++}';

  /// The split holding [nodeId], or null when it is the root.
  WorkspaceSplit? _parentOf(String nodeId) {
    WorkspaceSplit? search(WorkspaceNode node) {
      if (node is! WorkspaceSplit) return null;
      if (node.first.id == nodeId || node.second.id == nodeId) return node;
      return search(node.first) ?? search(node.second);
    }

    return search(_root);
  }

  WorkspacePane _firstPaneUnder(WorkspaceNode node) {
    var current = node;
    while (current is WorkspaceSplit) {
      current = current.first;
    }
    return current as WorkspacePane;
  }

  /// The first open session with no pane of its own, in tab-strip order.
  String? _firstUnboundSession() {
    final visible = visibleSessionIds.toSet();
    for (final id in _known) {
      if (!visible.contains(id)) return id;
    }
    return null;
  }

  void _notify() {
    if (_changes.isClosed) return;
    _changes.add(null);
  }

  Future<void> dispose() => _changes.close();
}

/// The production [WorkspaceSession]: a pane's binding, resolved to the live
/// session behind it.
///
/// `Terminal.textInput` is the same door the extra-key bar and the soft
/// keyboard already go through, so a broadcast write is indistinguishable from
/// typing — including the view's sticky-Ctrl rewrite, which is the point.
class LiveWorkspaceSession implements WorkspaceSession {
  const LiveWorkspaceSession(this.id, this.controller);

  @override
  final String id;

  final SessionController controller;

  @override
  void writeInput(String data) => controller.terminal.textInput(data);
}
