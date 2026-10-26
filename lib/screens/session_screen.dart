import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../services/broadcast_input.dart';
import '../services/display_hinge.dart';
import '../services/fleet_push_run_registry.dart';
import '../services/input_profile.dart';
import '../services/keep_awake.dart';
import '../services/layout_breakpoints.dart';
import '../services/session_controller.dart';
import '../services/session_manager.dart';
import '../services/settings_store.dart';
import '../services/snippet_store.dart';
import '../services/terminal_workspace.dart';
import '../services/transfer_hub.dart';
import '../services/transfer_queue.dart';
import '../services/tunnel_runtime.dart';
import '../theme.dart';
import '../widgets/hinge_split.dart';
import '../widgets/session_banners.dart';
import '../widgets/session_log_actions.dart';
import '../widgets/session_shortcuts.dart';
import '../widgets/snippet_picker.dart';
import '../widgets/transfer_hub_panel.dart';
import '../widgets/transfer_panel.dart';
import '../widgets/tunnel_indicator.dart';
import 'file_browser_pane.dart';
import 'fleet_push_screen.dart';
import 'log_viewer_screen.dart';
import 'remote_app_launcher.dart';
import 'remote_desktop_launch.dart';
import 'server_stats_screen.dart';
import 'services_screen.dart';
import 'terminal_pane.dart';
import 'workspace_view.dart';

/// Every open session, as tabs over one screen.
///
/// Phase 3 lifted ownership of the connection out of the terminal and into a
/// `SessionController` held by this screen; Phase 12 lifts it one level
/// further, out of the widget tree and into [SessionManager]. The reason is
/// the same shape as last time: as long as the route owned the session, the
/// only way to reach the host list — which is where a *second* session comes
/// from — was to tear the first one down.
///
/// So this screen owns nothing but the view now. Popping it leaves the
/// sessions connected and takes the user back to the host list, which says so;
/// closing a tab is what ends a session, and closing the last one is what
/// brings the foreground service down and pops this route.
///
/// Every open session is in the widget tree at once, inside an [IndexedStack].
/// That is not an optimisation — it is the requirement: a `htop` in the
/// session behind this one keeps running, keeps redrawing into its own
/// `Terminal`, and is exactly where it was when its tab comes back to the
/// front, because its `TerminalPane` was never disposed.
///
/// Phase 13 adds a second body for a mouse: the split workspace, where up to
/// four panes each show a session and the rest wait in the tab strip. The
/// bargain above is unchanged there — a session with no pane of its own is
/// still built, still laid out at full size, and merely not painted. Touch
/// alone never builds a workspace at all; see [_workspaceOn].
class SessionsScreen extends StatefulWidget {
  const SessionsScreen({
    super.key,
    required this.sessions,
    required this.settingsStore,
    this.onAddSession,
    this.workspace,
    this.snippetStore,
    this.autoOpenSnippetPicker = false,
    this.tunnels,
    this.fleetPushRegistry,
    KeepAwakeController? keepAwake,
  }) : keepAwake = keepAwake ?? const MethodChannelKeepAwake();

  final SessionManager sessions;
  final SettingsStore settingsStore;

  /// Goes to the host list to start another session. Null falls back to
  /// popping this route, which lands in the same place.
  final VoidCallback? onAddSession;

  /// The desktop pane layout, built in `main.dart` so that splits, ratios and
  /// bindings survive a trip to the host list — which is how a second session
  /// is opened, and so the single most likely moment for the user to want the
  /// layout back the way they left it.
  ///
  /// Null builds a private one that lives and dies with this route, which is
  /// what tests (and mobile, which never reads it) get.
  final TerminalWorkspace? workspace;

  /// Backs the lightning-bolt snippet picker. Optional, like `shareIntake`
  /// on `HostListScreen`, so a caller that does not care just gets a fresh
  /// store — see `_snippetStore` below.
  final SnippetStore? snippetStore;

  /// Opens the snippet picker for the active session as soon as this screen
  /// is built — how the command palette's "Snippets…" result (wired in
  /// `host_list_screen.dart`) lands on a session it had to push this whole
  /// screen to reach.
  final bool autoOpenSnippetPicker;

  /// Backs the app bar's tunnel count chip. Null — every test, and any
  /// build without the tunnel manager wired in — simply shows no chip.
  final TunnelRuntime? tunnels;

  /// The one place a running fleet push can be found again once its own
  /// setup screen has been left — surfaced as a banner in the "all
  /// transfers" sheet, see `widgets/transfer_hub_panel.dart`. Null (every
  /// test, and any build without it wired in) just means that sheet never
  /// shows the banner.
  final FleetPushRunRegistry? fleetPushRegistry;

  /// Test seam; production leaves this to the default channel-backed one.
  final KeepAwakeController keepAwake;

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

/// What the app bar's split button can do to the focused pane.
enum _WorkspaceAction { splitRight, splitDown, closePane }

/// How one session's terminal and file browser share its page.
enum _Panes {
  /// One at a time, behind the app bar's toggle: phones, split panes, and a
  /// terminal the user has asked to have the whole width.
  single,

  /// Terminal left, files right — either side of the hinge, when one runs
  /// down the middle of the screen.
  sideBySide,

  /// Terminal above a half-open fold, files below it: a foldable stood on a
  /// table like a laptop.
  stacked,
}

/// The monitoring views reachable from a session's overflow menu.
///
/// They live behind one menu rather than as three more icons because none of
/// them is something the user reaches for mid-keystroke — the bar is already
/// carrying everything that is.
enum _MonitorAction { stats, services, tail }

/// The session's menu, the app bar's ⋮: the terminal's find and session log,
/// then the monitoring views — and, on a phone too narrow for its icons,
/// every other action but the files toggle, so the host's name keeps room to
/// be read.
enum _SessionMenu {
  find,
  recordLog,
  stopLog,
  snippets,
  stats,
  services,
  tail,
  remoteDesktop,
  appWindow,
  newSession,
  close,
}

/// Below this width the snippets, new-session and disconnect buttons go into
/// [_SessionMenu]. A 320dp phone has room for the back arrow, the files
/// toggle and about three more icons; with all five the host's name was down
/// to its first letter and an ellipsis.
const double _overflowActionsBelow = 360;

class _SessionsScreenState extends State<SessionsScreen> {
  StreamSubscription<void>? _changes;
  StreamSubscription<void>? _workspaceChanges;
  StreamSubscription<void>? _broadcastChanges;

  /// Falls back to a route-scoped workspace when none was handed down — see
  /// [SessionsScreen.workspace]. Only that fallback is disposed here.
  late final TerminalWorkspace _workspace =
      widget.workspace ?? TerminalWorkspace();
  late final bool _ownsWorkspace = widget.workspace == null;

  /// Whether typing goes to every visible pane at once.
  ///
  /// Route-scoped on purpose, unlike the workspace above. The layout is the
  /// user's and has to survive a trip to the host list; "everything I type
  /// goes to four servers" is a *mode*, and a mode that outlived the screen it
  /// is explained on would be waiting, unannounced, for the next person to
  /// open a session and start typing. Coming back here always finds it off.
  late final BroadcastInput _broadcast = BroadcastInput(workspace: _workspace);

  /// One stable key per session, so that moving a session between panes — or
  /// out of the panes entirely when its pane closes — *reparents* its page
  /// rather than rebuilding it. Without this, dragging a session to the other
  /// half of the window would reset its file browser to the home directory
  /// and re-open its SFTP channel.
  final Map<String, GlobalKey> _pageKeys = {};

  /// Backs the lightning-bolt icon in the app bar. See the field doc on
  /// `SessionsScreen.snippetStore`.
  late final SnippetStore _snippetStore = widget.snippetStore ?? SnippetStore();

  // Merges every open session's own TransferQueue for the "all transfers"
  // app-bar icon below — see transfer_hub.dart. Built once per screen, not
  // per session, since it is the *set* of sessions this follows.
  late final TransferHub _hub = TransferHub.forSessionManager(widget.sessions);

  /// The terminal has the whole width, where it would otherwise share it with
  /// the file browser. Route-scoped: the next visit starts side by side.
  bool _terminalFullWidth = false;

  /// Where the keyboard goes when it leaves a terminal for something that
  /// takes no typing — the files, or a tab that shows them.
  ///
  /// Under the [Shortcuts] in [build], which is the point. Unfocusing would
  /// hand the keyboard to the route's scope, above them, and Ctrl+Shift+E,
  /// Ctrl+Tab and Ctrl+Shift+T would then reach nothing until a click put it
  /// back somewhere below. Skips traversal: it is a resting place, not a
  /// control Tab should stop on.
  final FocusNode _screenFocus =
      FocusNode(debugLabel: 'sessions screen', skipTraversal: true);

  @override
  void initState() {
    super.initState();
    // One subscription for N sessions: the manager folds every session's own
    // change stream into its own, so a drop on a background tab still repaints
    // that tab's status dot.
    _changes = widget.sessions.changes.listen((_) {
      if (!mounted) return;
      _syncWorkspace();
      setState(() {});
    });
    _workspaceChanges = _workspace.changes.listen(_handleWorkspaceChange);
    // Its own stream rather than a flag read during build: the broadcaster
    // also turns *itself* off (when a split collapses), and that has to repaint
    // the app bar and every pane header without anything else having happened.
    _broadcastChanges = _broadcast.changes.listen((_) {
      if (mounted) setState(() {});
    });
    if (widget.settingsStore.current.keepScreenAwake) {
      unawaited(widget.keepAwake.setEnabled(true));
    }
    if (widget.autoOpenSnippetPicker) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openSnippetPicker();
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The first sync has to happen after the platform is readable and before
    // the first build, which is exactly this hook. Doing it in `build` would
    // mean mutating a controller — and notifying its listeners — from inside a
    // build, which is the "setState() called during build" crash.
    _syncWorkspace();
  }

  @override
  void dispose() {
    _changes?.cancel();
    _workspaceChanges?.cancel();
    _broadcastChanges?.cancel();
    // Hand the taps back. This screen is the only thing that ever sets them,
    // and the sessions outlive it — a closure left pointing at a disposed
    // broadcaster would fire on the next keystroke after the user came back.
    for (final entry in widget.sessions.sessions) {
      entry.controller.onInputSent = null;
    }
    unawaited(_broadcast.dispose());
    unawaited(_hub.dispose());
    if (_ownsWorkspace) unawaited(_workspace.dispose());
    // The sessions are deliberately *not* disposed here — they belong to the
    // manager and outlive this route.
    unawaited(widget.keepAwake.setEnabled(false));
    _screenFocus.dispose();
    super.dispose();
  }

  /// Whether the split workspace is on offer: wherever a mouse or trackpad is
  /// in hand — a desktop, a DeX window, a tablet in a trackpad cover — since
  /// dragging a divider and working four panes want a precise pointer, not
  /// whichever operating system is underneath. See `input_profile.dart`.
  ///
  /// A split, once made, stays on offer whatever was touched since: taking
  /// the panes away because a finger brushed a touch laptop's screen would
  /// lose the layout the user built.
  bool _workspaceOn(BuildContext context) =>
      InputProfile.of(context).mouse || _workspace.isSplit;

  /// Tells the workspace which sessions exist. Touch alone never calls this —
  /// and never reads the workspace either, so the tabbed layout is untouched
  /// by everything below. Runs again from [didChangeDependencies] when a
  /// mouse first turns up, which is how a DeX user's sessions find their way
  /// into a workspace.
  void _syncWorkspace() {
    if (!_workspaceOn(context)) return;
    final manager = widget.sessions;
    final ids = manager.sessions.map((s) => s.id).toList(growable: false);
    _pageKeys.removeWhere((id, _) => !ids.contains(id));
    _workspace.syncSessions(ids, activeId: manager.activeId);
    _attachInputTaps(manager);
  }

  /// Points every open session's keystroke tap at the broadcaster.
  ///
  /// Re-applied on every sync rather than once per session, because a session
  /// opened later has to be tapped too and this is the one place that hears
  /// about every one of them. The tap itself is inert while broadcasting is
  /// off — [BroadcastInput.handleInput] returns before doing anything — so
  /// this costs one null check per keystroke in the ordinary case.
  ///
  /// Workspace only, like everything else past [_syncWorkspace]'s guard: the
  /// tabbed phone layout has one session on screen at a time, so there is
  /// nothing to broadcast *to*.
  void _attachInputTaps(SessionManager manager) {
    for (final entry in manager.sessions) {
      final id = entry.id;
      entry.controller.onInputSent = (data) => _broadcast.handleInput(id, data);
    }
  }

  void _handleWorkspaceChange(void _) {
    if (!mounted) return;
    // The app bar's title, transfer button and disconnect action all read
    // `SessionManager.active`. On desktop the pane holding the keyboard *is*
    // the session the user is working in, so the two are kept in step here
    // rather than left as two competing ideas of what "active" means.
    final focused = _workspace.focusedSessionId;
    if (focused != null) widget.sessions.select(focused);
    setState(() {});
  }

  /// A tab was tapped. In the workspace that means "show this one in the pane
  /// I am looking at" — otherwise a tab for a session that is not in any pane
  /// would change the app bar and nothing else.
  void _selectSession(String id) {
    if (_workspaceOn(context)) _workspace.showSession(id);
    widget.sessions.select(id);
  }

  /// Ctrl+Tab and Ctrl+Shift+Tab: the next or previous tab, wrapping round.
  ///
  /// In a split workspace a session that already has a pane is reached by
  /// moving the focus to that pane. Showing it in the focused one, as a tab
  /// tap does, would trade the two panes' sessions — a layout rearranged by a
  /// key that only meant "go to the next one".
  void _cycleSession({required bool backwards}) {
    final entries = widget.sessions.sessions;
    if (entries.length < 2) return;
    final at = entries.indexWhere((s) => s.id == widget.sessions.activeId);
    final next = (at + (backwards ? -1 : 1)) % entries.length;
    final id = entries[next].id;
    final pane =
        _workspaceOn(context) ? _workspace.paneForSession(id) : null;
    if (pane != null) {
      _workspace.focusPane(pane.id);
      widget.sessions.select(id);
      return;
    }
    _selectSession(id);
  }

  /// The terminal takes the whole width, or gives the files their side back.
  /// Going full width shows the terminal, whichever pane was last toggled
  /// to on a narrower screen — that is what the button says it does.
  void _toggleTerminalFullWidth() {
    final active = widget.sessions.active;
    setState(() => _terminalFullWidth = !_terminalFullWidth);
    if (_terminalFullWidth && active != null) {
      widget.sessions.showView(active.id, SessionView.terminal);
    }
  }

  void _toggleFiles() {
    final active = widget.sessions.active;
    if (active == null) return;
    _show(active.view == SessionView.terminal
        ? SessionView.files
        : SessionView.terminal);
  }

  void _handleWorkspaceAction(_WorkspaceAction action) {
    switch (action) {
      case _WorkspaceAction.splitRight:
        _workspace.splitFocused(WorkspaceAxis.row);
      case _WorkspaceAction.splitDown:
        _workspace.splitFocused(WorkspaceAxis.column);
      case _WorkspaceAction.closePane:
        _workspace.closePane(_workspace.focusedPaneId);
    }
  }

  /// Opens one of the monitoring views on [session].
  ///
  /// Each is a plain pushed route that borrows the session's already-
  /// authenticated transport for exec channels; none of them owns the
  /// session, and leaving one leaves the shell and any transfers untouched.
  Future<void> _handleMonitorAction(
    _MonitorAction action,
    SessionController session,
  ) async {
    switch (action) {
      case _MonitorAction.stats:
        await openServerStats(context, session: session);
      case _MonitorAction.services:
        await openServicesScreen(context, session: session);
      case _MonitorAction.tail:
        await promptAndTailFile(
          context,
          session: session,
          settingsStore: widget.settingsStore,
        );
    }
  }

  Future<void> _handleSessionMenu(
    _SessionMenu choice,
    SessionController session,
  ) async {
    switch (choice) {
      case _SessionMenu.find:
        // On a phone the file browser may be in front; find is for the
        // terminal, so that comes forward first.
        _show(SessionView.terminal);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) TerminalPane.showFind(session);
        });
      case _SessionMenu.recordLog:
        await SessionLogActions.start(context, session);
      case _SessionMenu.stopLog:
        await SessionLogActions.stop(context, session);
      case _SessionMenu.snippets:
        _openSnippetPicker();
      case _SessionMenu.stats:
        await _handleMonitorAction(_MonitorAction.stats, session);
      case _SessionMenu.services:
        await _handleMonitorAction(_MonitorAction.services, session);
      case _SessionMenu.tail:
        await _handleMonitorAction(_MonitorAction.tail, session);
      case _SessionMenu.remoteDesktop:
        await startRemoteDesktop(context, session);
      case _SessionMenu.appWindow:
        await openRemoteAppLauncher(
          context,
          session: session,
          onOfferVirtualDesktop: () =>
              unawaited(startRemoteDesktop(context, session, virtualOnly: true)),
          listInstalledApps: () => installedRemoteApps(session),
        );
      case _SessionMenu.newSession:
        _addSession();
      case _SessionMenu.close:
        await _closeActive();
    }
  }

  void _addSession() {
    final add = widget.onAddSession;
    if (add != null) {
      add();
      return;
    }
    Navigator.of(context).pop();
  }

  /// Opens the snippet picker (FEATURE 1) over the active session — the
  /// lightning-bolt app-bar icon, and where `autoOpenSnippetPicker` lands.
  void _openSnippetPicker() {
    final active = widget.sessions.active;
    if (active == null) return;
    unawaited(
      showSnippetPicker(
        context,
        snippetStore: _snippetStore,
        session: active.controller,
      ),
    );
  }

  void _show(SessionView view) {
    final active = widget.sessions.active;
    if (active == null || active.view == view) return;
    // Take the focus out of the terminal, which drops the soft keyboard on
    // the way to the files — or the file list opens behind it. To the
    // screen's own node, not by unfocusing: see [_screenFocus]. Coming back
    // to the terminal, the page puts the caret in it if there is a keyboard
    // to type with.
    _screenFocus.requestFocus();
    widget.sessions.showView(active.id, view);
  }

  Future<void> _closeActive() async {
    final active = widget.sessions.active;
    if (active == null) return;
    await _closeSession(active);
  }

  /// A file (or a selection) was dragged from one session's browser onto
  /// [target]'s tab. The payload carries every entry the user meant to send
  /// and names the source, so we can queue the transfer on the source
  /// session's queue and hand the destination to the shared flow that the
  /// per-entry action sheet also uses.
  ///
  /// Same-session drops are refused earlier, in the [DragTarget]'s
  /// `onWillAcceptWithDetails`; by the time this runs, the drop is real.
  Future<void> _handleTabDrop(
    ManagedSession target,
    TabDropPayload payload,
  ) async {
    final source = widget.sessions.byId(payload.sourceSessionId);
    if (source == null) {
      // The source session was closed between the drag starting and the drop
      // landing. Surface a message rather than dropping silently.
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(context.l10n.sessionTabDropClosed),
      ));
      return;
    }

    // Drop always brings the destination to the front, so the user can see
    // the folder picker land on the tab they were aiming for.
    widget.sessions.select(target.id);

    await sendEntriesToSession(
      context,
      source: source.controller,
      destination: target,
      entries: payload.entries,
      // Drag-and-drop is copy semantics: it lands a duplicate. Moving a file
      // is destructive on the source and stays behind the explicit "Move to
      // another server…" action sheet row.
      move: false,
    );
  }

  /// Ends one session, asking first if there is anything to lose.
  ///
  /// Only this session: the confirmation names it, the transfer count is its
  /// own, and every other tab carries on regardless of the answer.
  Future<void> _closeSession(ManagedSession entry) async {
    if (!entry.isClosed) {
      final l10n = context.l10n;
      final transfers = entry.controller.transfers.activeCount;
      final question = transfers > 0
          ? l10n.sessionCloseQuestionTransfers(
              transfers, entry.host.displayName)
          : l10n.sessionCloseQuestion(entry.host.displayName);
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.sessionCloseTitle),
          content: Text(
            SessionLogActions.isRecording(entry.controller)
                ? l10n.sessionCloseWithLog(question)
                : question,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(l10n.sessionCloseStay),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(l10n.sessionDisconnect),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    // A log being recorded is saved before its session goes.
    if (SessionLogActions.isRecording(entry.controller) && mounted) {
      await SessionLogActions.stopBeforeClose(context, entry.controller);
    }

    // The last tab closing takes the screen with it — there is nothing left
    // here to look at, and the host list is where a new session starts.
    //
    // The pop has to happen on the near side of the teardown. `close` drops
    // the session from the list before its first await and only then waits
    // on `controller.dispose()`, which closes the SSH transport and can take
    // seconds against a server that has stopped answering. By then this
    // screen has already rebuilt with nothing to show and fallen back to the
    // empty Scaffold above, so awaiting the whole of `close` first left the
    // user watching a blank window for the length of the disconnect.
    final closing = widget.sessions.close(entry.id);
    if (mounted && widget.sessions.isEmpty) Navigator.of(context).pop();
    await closing;
  }

  /// One session's page, with the identity that lets it be moved rather than
  /// rebuilt. See [_pageKeys].
  Widget _page(
    ManagedSession entry, {
    required SessionManager manager,
    required bool active,
    required _Panes panes,
  }) {
    return _SessionPage(
      key: _pageKeys.putIfAbsent(entry.id, GlobalKey.new),
      entry: entry,
      manager: manager,
      settingsStore: widget.settingsStore,
      active: active,
      panes: panes,
      screenFocus: _screenFocus,
    );
  }

  /// Phones and tablets: one session at a time, all of them alive.
  Widget _tabbedBody(
    SessionManager manager,
    List<ManagedSession> entries,
    _Panes panes,
  ) {
    return IndexedStack(
      index: entries.indexWhere((s) => s.id == manager.activeId),
      sizing: StackFit.expand,
      children: [
        for (final entry in entries)
          // Every session's terminal is live and focusable at once. Without
          // this, a keystroke after switching tabs would go to whichever
          // terminal happened to hold focus — including one the user cannot
          // see.
          ExcludeFocus(
            excluding: entry.id != manager.activeId,
            child: _page(
              entry,
              manager: manager,
              active: entry.id == manager.activeId,
              panes: panes,
            ),
          ),
      ],
    );
  }

  /// With a mouse: the pane tree, over every session that has no pane of its
  /// own.
  ///
  /// [panes] is already [_Panes.single] when the workspace is split: a split
  /// pane is half a window or less, and handing it the side-by-side layout
  /// would put a 40-column terminal next to a file browser too narrow to read
  /// a filename in — so each pane shows one view at a time and the app bar's
  /// toggle switches the focused one between them.
  Widget _workspaceBody(
    SessionManager manager,
    List<ManagedSession> entries,
    _Panes panes,
  ) {
    final visible = _workspace.visibleSessionIds.toSet();
    final focusedSessionId = _workspace.focusedSessionId;

    return Stack(
      fit: StackFit.expand,
      children: [
        // A session with no pane of its own is still built and still laid out
        // at the full size of the workspace — it is simply never painted.
        // That is the same bargain the tabbed layout's IndexedStack makes, and
        // it is what keeps a background `htop` running, and running at a width
        // it will not have to reflow from when its pane comes back.
        for (final entry in entries)
          if (!visible.contains(entry.id))
            Visibility(
              visible: false,
              maintainState: true,
              maintainAnimation: true,
              maintainSize: true,
              maintainInteractivity: false,
              child: ExcludeFocus(
                child: _page(
                  entry,
                  manager: manager,
                  active: false,
                  panes: panes,
                ),
              ),
            ),
        WorkspaceView(
          workspace: _workspace,
          sessions: entries,
          onAddSession: _addSession,
          broadcasting: _broadcast.enabled,
          paneContent: (entry) => _page(
            entry,
            manager: manager,
            // Exactly one pane is focused, and a session appears in at most
            // one pane, so at most one page is `active` — which is what puts
            // the caret in that terminal and keeps it out of the others.
            active: entry.id == focusedSessionId,
            panes: panes,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final manager = widget.sessions;
    final entries = manager.sessions;
    final active = manager.active;

    if (active == null) {
      // Only reachable for the frame between the last session closing and the
      // pop landing.
      return const Scaffold(body: SizedBox.shrink());
    }

    // Material 3 window size classes (see `layout_breakpoints.dart`), read
    // from `MediaQuery` rather than the platform/device — a Chromebook, a
    // DeX window and an unfolded foldable are all just "wide" by width, and a
    // physical tablet in split-screen is not.
    final size = MediaQuery.sizeOf(context);
    final wide = WindowSizeClass.forWidth(size.width).isAtLeastMedium;
    final input = InputProfile.of(context);

    // A mouse gets the split workspace; touch gets the tabbed layout it
    // always had, untouched.
    final workspaceOn = _workspaceOn(context);
    final split = workspaceOn && _workspace.isSplit;

    // Terminal and files share the page when the window is wide *and* tall
    // enough for both to be usable, or when a hinge has already split the
    // screen in two — then each gets a side, or the half above and below a
    // fold in tabletop posture.
    final hinge = HingeCut.axisOf(MediaQuery.displayFeaturesOf(context), size);
    final roomForBoth = hinge != null ||
        WindowSizeClass.fitsSideBySide(size.width, size.height);
    final panes = split || _terminalFullWidth || !roomForBoth
        ? _Panes.single
        : hinge == HingeAxis.stacked
            ? _Panes.stacked
            : _Panes.sideBySide;

    // Only offer the drop target when there is anywhere to drop *from*: with
    // one session open there is no other tab to drag to. The strip does not
    // even render in that case, but the callback is defined on the widget so
    // the check has to be here.
    final canReceiveDrops = entries.length > 1;

    final closed = active.isClosed;
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final narrow = size.width < _overflowActionsBelow;

    final scaffold = Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        leading: IconButton(
          tooltip: entries.length == 1
              ? l10n.sessionBackOne
              : l10n.sessionBackMany,
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              active.host.displayName,
              style: const TextStyle(fontSize: 16),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.circle,
                  size: 8,
                  color: closed
                      ? theme.colorScheme.error
                      : theme.colorScheme.primary,
                ),
                const SizedBox(width: 6),
                // Flexible: on a phone the actions leave the title a hundred
                // pixels or so, and a long user@host overflowed them.
                Flexible(
                  child: Text(
                    closed ? l10n.sessionDisconnectedStatus : active.host.target,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          // A port forward keeps working while the user is in a shell with
          // nothing on screen mentioning it, so it gets a standing reminder
          // here. Renders nothing when no tunnel is running.
          if (widget.tunnels != null)
            TunnelIndicator(tunnels: widget.tunnels!),
          // First in the row, and impossible to miss once it is on: while
          // broadcasting, this is the single most important fact about what
          // the next keystroke is going to do.
          if (split)
            _BroadcastAction(
              enabled: _broadcast.enabled,
              paneCount: _broadcast.targetCount,
              // No `setState`: toggling publishes on the broadcaster's own
              // stream, which this screen is already listening to.
              onToggle: _broadcast.toggle,
            ),
          _TransferAction(
            queue: active.controller.transfers,
            onTap: () => showTransfersSheet(
              context,
              active.controller.transfers,
              onOpen: active.controller.openDownload,
            ),
          ),
          if (workspaceOn)
            PopupMenuButton<_WorkspaceAction>(
              tooltip: l10n.sessionSplitTooltip,
              icon: const Icon(Icons.splitscreen_outlined),
              onSelected: _handleWorkspaceAction,
              itemBuilder: (context) => [
                PopupMenuItem<_WorkspaceAction>(
                  value: _WorkspaceAction.splitRight,
                  enabled: _workspace.canSplit,
                  child: Text(l10n.workspaceSplitRight),
                ),
                PopupMenuItem<_WorkspaceAction>(
                  value: _WorkspaceAction.splitDown,
                  enabled: _workspace.canSplit,
                  child: Text(l10n.workspaceSplitDown),
                ),
                const PopupMenuDivider(),
                PopupMenuItem<_WorkspaceAction>(
                  value: _WorkspaceAction.closePane,
                  // Closing the only pane would leave nothing to focus and
                  // nowhere to put the next session.
                  enabled: split,
                  child: Text(l10n.workspaceClosePane),
                ),
              ],
            ),
          // Persistent across every tab, unlike the button above: this one
          // is not "this session's transfers" but every session's, so it
          // stays put — and its badge counted — whichever tab is in front.
          TransferHubAction(
            hub: _hub,
            onTap: () {
              // Captured before the sheet opens: once its banner is tapped,
              // the sheet itself is popped first, and a `Navigator` handle
              // stays valid across that in a way a `BuildContext` from
              // inside the (about to be torn down) sheet does not.
              final navigator = Navigator.of(context);
              showTransferHubSheet(
                context,
                _hub,
                fleetPush: widget.fleetPushRegistry,
                onOpenFleetPush: (sheetContext, service) {
                  Navigator.of(sheetContext).pop();
                  navigator.push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => FleetPushResultsScreen(
                        service: service,
                        registry: widget.fleetPushRegistry,
                      ),
                    ),
                  );
                },
              );
            },
          ),
          // Both panes are already on screen when they share the page, so a
          // toggle between them means nothing there — only where they take
          // turns: a phone, a split workspace pane, a full-width terminal.
          if (panes == _Panes.single)
            IconButton(
              tooltip: SessionShortcuts.tooltip(
                active.view == SessionView.terminal
                    ? l10n.sessionBrowseFiles
                    : l10n.sessionBackToTerminal,
                SessionShortcuts.toggleFiles,
                keyboard: input.keyboard,
              ),
              icon: Icon(
                active.view == SessionView.terminal
                    ? Icons.folder_outlined
                    : Icons.terminal,
              ),
              onPressed: _toggleFiles,
            ),
          // Where they could share it, the terminal can have it all instead:
          // a tablet's 40% for files is a lot to give up to a log being
          // tailed.
          if (!split && roomForBoth)
            IconButton(
              tooltip: SessionShortcuts.tooltip(
                _terminalFullWidth
                    ? l10n.sessionShowFilesBeside
                    : l10n.sessionTerminalFullWidth,
                SessionShortcuts.toggleFullWidth,
                keyboard: input.keyboard,
              ),
              icon: Icon(
                _terminalFullWidth
                    ? Icons.vertical_split_outlined
                    : Icons.open_in_full,
              ),
              onPressed: _toggleTerminalFullWidth,
            ),
          // On a desktop-sized window remote desktop gets a button of its
          // own; on a phone it is in the menu, with everything else.
          if (!narrow)
            IconButton(
              tooltip: l10n.sessionRemoteDesktop,
              icon: const Icon(Icons.desktop_windows_outlined),
              onPressed: closed || active.controller.isSshLostUnderMosh
                  ? null
                  : () => unawaited(
                      startRemoteDesktop(context, active.controller),
                    ),
            ),
          if (!narrow)
            IconButton(
              tooltip: l10n.sessionSnippets,
              icon: const Icon(Icons.bolt_outlined),
              onPressed: _openSnippetPicker,
            ),
          // The session's menu: find and the session log first — they work
          // on the terminal's own buffer, so a closed session's scrollback
          // can still be searched and its log saved — then monitoring,
          // disabled on a closed session: all three run commands over the
          // transport, and there is not one. On a narrow phone the buttons
          // around it move in here too.
          PopupMenuButton<_SessionMenu>(
            tooltip: MaterialLocalizations.of(context).moreButtonTooltip,
            icon: const Icon(Icons.more_vert),
            onSelected: (choice) =>
                unawaited(_handleSessionMenu(choice, active.controller)),
            itemBuilder: (context) {
              final recording =
                  SessionLogActions.isRecording(active.controller);
              return [
                PopupMenuItem<_SessionMenu>(
                  value: _SessionMenu.find,
                  child: Row(
                    children: [
                      Expanded(child: Text(l10n.sessionFindInTerminal)),
                      if (input.keyboard) ...[
                        const SizedBox(width: 24),
                        Text(
                          'Ctrl+Shift+F',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (recording)
                  PopupMenuItem<_SessionMenu>(
                    value: _SessionMenu.stopLog,
                    child: Text(l10n.sessionLogStopAndSave),
                  )
                else
                  PopupMenuItem<_SessionMenu>(
                    value: _SessionMenu.recordLog,
                    enabled: !closed,
                    child: Text(l10n.sessionLogRecordMenu),
                  ),
                if (narrow)
                  PopupMenuItem<_SessionMenu>(
                    value: _SessionMenu.snippets,
                    child: Text(l10n.sessionSnippets),
                  ),
                const PopupMenuDivider(),
                PopupMenuItem<_SessionMenu>(
                  value: _SessionMenu.stats,
                  enabled: !closed,
                  child: Text(l10n.sessionServerStats),
                ),
                PopupMenuItem<_SessionMenu>(
                  value: _SessionMenu.services,
                  enabled: !closed,
                  child: Text(l10n.sessionServicesProcesses),
                ),
                PopupMenuItem<_SessionMenu>(
                  value: _SessionMenu.tail,
                  enabled: !closed,
                  child: Text(l10n.sessionTailFile),
                ),
                // Both need the SSH side: a Mosh session whose SSH link has
                // gone has nothing to carry a desktop or an X11 window.
                const PopupMenuDivider(),
                PopupMenuItem<_SessionMenu>(
                  value: _SessionMenu.remoteDesktop,
                  enabled: !closed && !active.controller.isSshLostUnderMosh,
                  child: Text(l10n.sessionRemoteDesktop),
                ),
                PopupMenuItem<_SessionMenu>(
                  value: _SessionMenu.appWindow,
                  enabled: !closed && !active.controller.isSshLostUnderMosh,
                  child: Text(l10n.sessionOpenAppWindow),
                ),
                if (narrow) ...[
                  const PopupMenuDivider(),
                  PopupMenuItem<_SessionMenu>(
                    value: _SessionMenu.newSession,
                    child: Text(l10n.sessionNew),
                  ),
                  PopupMenuItem<_SessionMenu>(
                    value: _SessionMenu.close,
                    child: Text(
                      closed ? l10n.sessionCloseTab : l10n.sessionDisconnect,
                      style: closed
                          ? null
                          : TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                ],
              ];
            },
          ),
          if (!narrow) ...[
            // With one session open this is the only sign that a second one
            // is possible, so it stays in the bar rather than living only in
            // the tab strip that has not appeared yet.
            IconButton(
              tooltip: SessionShortcuts.tooltip(
                l10n.sessionNew,
                SessionShortcuts.newSession,
                keyboard: input.keyboard,
              ),
              icon: const Icon(Icons.add),
              onPressed: _addSession,
            ),
            IconButton(
              tooltip: closed ? l10n.sessionCloseTab : l10n.sessionDisconnect,
              icon: Icon(closed ? Icons.close : Icons.power_settings_new),
              color: closed ? null : theme.colorScheme.error,
              onPressed: () => unawaited(_closeActive()),
            ),
          ],
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // One session looks as it always did: no strip, no chrome, just
            // the session.
            if (entries.length > 1)
              SessionTabStrip(
                sessions: entries,
                activeId: manager.activeId,
                compact: !wide,
                touch: input.touch,
                onSelect: _selectSession,
                onClose: (entry) => unawaited(_closeSession(entry)),
                onAdd: _addSession,
                onDrop: canReceiveDrops ? _handleTabDrop : null,
              ),
            Expanded(
              child: workspaceOn
                  ? _workspaceBody(manager, entries, panes)
                  : _tabbedBody(manager, entries, panes),
            ),
          ],
        ),
      ),
    );

    // Every chord has a binding here for whatever has the focus, and the
    // terminal hands its own to the same actions before the shell can see
    // them — see `session_shortcuts.dart`.
    return Shortcuts(
      shortcuts: SessionShortcuts.bindings,
      child: Actions(
        actions: <Type, Action<Intent>>{
          NewSessionIntent: _SessionAction<NewSessionIntent>(
            onInvoke: (_) => _addSession(),
          ),
          CycleSessionIntent: _SessionAction<CycleSessionIntent>(
            enabled: entries.length > 1,
            onInvoke: (intent) => _cycleSession(backwards: intent.backwards),
          ),
          ToggleSessionFilesIntent: _SessionAction<ToggleSessionFilesIntent>(
            enabled: panes == _Panes.single,
            onInvoke: (_) => _toggleFiles(),
          ),
          ToggleTerminalFullWidthIntent:
              _SessionAction<ToggleTerminalFullWidthIntent>(
            enabled: !split && roomForBoth,
            onInvoke: (_) => _toggleTerminalFullWidth(),
          ),
        },
        child: Focus(
          focusNode: _screenFocus,
          child: scaffold,
        ),
      ),
    );
  }
}

/// One session's two panes, and everything that is true of that session alone.
///
/// A widget per session rather than a map of per-session state on the screen:
/// [IndexedStack] keeps every child's `State` alive, so this is where a
/// session's pane keys, terminal focus and announcement subscriptions can live
/// without any of them needing to be looked up by id.
class _SessionPage extends StatefulWidget {
  const _SessionPage({
    super.key,
    required this.entry,
    required this.manager,
    required this.settingsStore,
    required this.active,
    required this.panes,
    required this.screenFocus,
  });

  final ManagedSession entry;
  final SessionManager manager;
  final SettingsStore settingsStore;
  final bool active;
  final _Panes panes;

  /// The screen's resting place for the keyboard, under its shortcuts — see
  /// `_SessionsScreenState._screenFocus`.
  final FocusNode screenFocus;

  @override
  State<_SessionPage> createState() => _SessionPageState();
}

class _SessionPageState extends State<_SessionPage> {
  /// Stable identities for the two panes, so that going from the compact
  /// `IndexedStack` to the medium/expanded side-by-side `Row` (and back, on a
  /// fold or a DeX window resize) moves the *same* `TerminalPane` /
  /// `FileBrowserPane` element instead of destroying and recreating it.
  /// `TerminalPane`'s `Terminal` — scrollback, cursor, the lot — lives inside
  /// its `State`, created once in `initState`; only a `GlobalKey` lets Flutter
  /// reparent that `State` across a structural change in the same build rather
  /// than tearing it down. Without this, folding or resizing into a wide
  /// window would silently drop the running session's scrollback and open a
  /// second SFTP channel.
  final GlobalKey _terminalPaneKey = GlobalKey();
  final GlobalKey _fileBrowserPaneKey = GlobalKey();

  /// Owned here rather than by `TerminalPane` so that a tab coming to the
  /// front can put the caret back in this terminal.
  final FocusNode _terminalFocus = FocusNode(debugLabel: 'terminal');

  StreamSubscription<void>? _sessionChanges;
  StreamSubscription<List<TransferTask>>? _transferChanges;

  /// The view this page last showed, to notice the terminal coming back.
  late SessionView _shownView = widget.entry.view;

  SessionController get _session => widget.entry.controller;

  @override
  void initState() {
    super.initState();
    _sessionChanges = _session.changes.listen(_handleSessionChange);
    _transferChanges = _session.transfers.changes.listen(_handleTransfers);
  }

  @override
  void didUpdateWidget(_SessionPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Coming to the front: put the keyboard back where the user expects it.
    // Post-frame because `ExcludeFocus` above only stops excluding this
    // subtree as part of the same build that is running right now.
    if (!oldWidget.active && widget.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !widget.active) return;
        if (widget.entry.view == SessionView.terminal &&
            !widget.entry.isClosed) {
          _terminalFocus.requestFocus();
        } else {
          _focusScreenIfStranded();
        }
      });
    }
    // Back from the files with Ctrl+Shift+E: the toggle took the focus out of
    // the terminal to put the soft keyboard away, which a hardware keyboard
    // has no use for — the next key belongs in the terminal it just switched
    // back to. Off to the files some other way (a shared file arriving), the
    // terminal behind them must not keep the keys.
    final view = widget.entry.view;
    if (view != _shownView) {
      _shownView = view;
      if (widget.active &&
          view == SessionView.terminal &&
          !widget.entry.isClosed &&
          InputProfile.of(context).keyboard) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && widget.active) _terminalFocus.requestFocus();
        });
      } else if (widget.active && view == SessionView.files) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && widget.active) _focusScreenIfStranded();
        });
      }
    }
  }

  /// Gives the keyboard to the screen where this page has left it nowhere
  /// useful: in its terminal, now hidden behind the files, or dropped to the
  /// route's scope above the screen's shortcuts — which is where it lands
  /// when the tab that had it goes to the back. Focus anywhere else, a
  /// dialog or the file browser's path field, is left where it is.
  void _focusScreenIfStranded() {
    final primary = FocusManager.instance.primaryFocus;
    final screen = widget.screenFocus;
    if (primary == null ||
        _terminalFocus.hasFocus ||
        identical(primary, screen.enclosingScope)) {
      screen.requestFocus();
    }
  }

  @override
  void dispose() {
    _sessionChanges?.cancel();
    _transferChanges?.cancel();
    _terminalFocus.dispose();
    super.dispose();
  }

  void _handleSessionChange(void _) {
    if (!mounted) return;
    setState(() {
      // A share can arrive on a session showing the terminal; the file browser
      // is where the destination gets chosen, so go there.
      if (_session.pendingUpload != null) {
        widget.manager.showView(widget.entry.id, SessionView.files);
      }
    });

    // Whose drop this was matters now that several sessions can be open, and
    // the session itself remembers whether it has been announced — a `State`
    // is too short-lived a thing to be trusted with that.
    final reason = _session.takeDisconnectAnnouncement();
    if (reason == null) return;
    final theme = Theme.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          widget.active
              ? reason
              : context.l10n.sessionOnHost(widget.entry.host.displayName, reason),
        ),
        backgroundColor: theme.colorScheme.error,
      ),
    );
  }

  /// Announces finished downloads, with a way straight to the file.
  ///
  /// Downloads land in the shared Downloads collection, which is the right
  /// default and also completely invisible from inside this app — so the
  /// moment one finishes is the moment to offer "Open", rather than leaving
  /// the user to go and find a file manager.
  ///
  /// Which downloads are new, and whether the batch is finished, is decided by
  /// [SessionController.takeDownloadAnnouncement] rather than here — that
  /// memory has to outlive this `State`, which a fold, a window resize or any
  /// other reason to rebuild the route is free to replace.
  void _handleTransfers(List<TransferTask> tasks) {
    if (!mounted) return;

    final batch = _session.takeDownloadAnnouncement(tasks);
    if (batch.isEmpty) return;

    ScaffoldMessenger.of(context).showSnackBar(
      buildDownloadSavedSnackBar(
        context.l10n,
        batch: batch,
        // A download that finished on a session the user is not looking at
        // still gets announced — with the host named, since "Saved notes.txt"
        // from a tab three along is otherwise a mystery.
        from: widget.active ? null : widget.entry.host.displayName,
        onOpen: (task) => unawaited(_openDownload(task)),
        onShowAll: () => unawaited(
          showTransfersSheet(
            context,
            _session.transfers,
            onOpen: _session.openDownload,
          ),
        ),
      ),
    );
  }

  Future<void> _openDownload(TransferTask task) async {
    final messenger = ScaffoldMessenger.of(context);
    final noApp = context.l10n.transferPanelNoAppForFile;
    final opened = await _session.openDownload(task);
    if (!opened) {
      messenger.showSnackBar(SnackBar(content: Text(noApp)));
    }
  }

  /// The banner's "Close tab", on a session that has already ended: its log,
  /// if one is still being kept, is saved first.
  Future<void> _closeTab() async {
    await SessionLogActions.stopBeforeClose(context, _session);
    await widget.manager.close(widget.entry.id);
  }

  Widget _terminalPane() {
    return TerminalPane(
      key: _terminalPaneKey,
      session: _session,
      settingsStore: widget.settingsStore,
      focusNode: _terminalFocus,
      // Only the session in front may take the keyboard when it is built.
      autofocus: widget.active,
    );
  }

  Widget _fileBrowserPane() {
    return FileBrowserPane(
      key: _fileBrowserPaneKey,
      session: _session,
      settingsStore: widget.settingsStore,
      sessions: widget.manager,
      sessionId: widget.entry.id,
      initialShowHidden: widget.settingsStore.current.showHiddenFilesByDefault,
    );
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;

    // Once both panes have been on screen, the file browser is live and its
    // SFTP channel open; folding back to compact should not throw that away
    // and re-show the "not built yet" placeholder in the IndexedStack branch.
    if (widget.panes != _Panes.single) widget.manager.markFilesBuilt(entry.id);

    return Column(
      children: [
        SessionBanners(
          session: entry,
          onCloseTab: () => unawaited(_closeTab()),
        ),
        Expanded(
          child: switch (widget.panes) {
            // Phones: one pane at a time behind the app-bar toggle.
            _Panes.single => IndexedStack(
                index: entry.view == SessionView.terminal ? 0 : 1,
                sizing: StackFit.expand,
                children: [
                  _terminalPane(),
                  if (entry.filesBuilt)
                    _fileBrowserPane()
                  else
                    const SizedBox.shrink(),
                ],
              ),
            // Tablets, DeX and foldables: both panes live at once, sharing the
            // one `SessionController` — the file browser opening its SFTP
            // channel here is deliberate, not lazy, since there is no "ask for
            // it" tap in this layout for it to wait on. Split at the hinge
            // when there is one.
            _Panes.sideBySide => HingeSplit(
                axis: HingeAxis.sideBySide,
                first: _terminalPane(),
                second: _fileBrowserPane(),
              ),
            _Panes.stacked => HingeSplit(
                axis: HingeAxis.stacked,
                first: _terminalPane(),
                second: _fileBrowserPane(),
              ),
          },
        ),
      ],
    );
  }
}

/// The row of open sessions, above the panes.
///
/// Only appears from the second session on. A strip with one tab in it is
/// chrome that says nothing, and the whole point of the single-session case is
/// that it should look exactly as it did before any of this existed.
@visibleForTesting
class SessionTabStrip extends StatelessWidget {
  const SessionTabStrip({
    super.key,
    required this.sessions,
    required this.activeId,
    required this.compact,
    required this.onSelect,
    required this.onClose,
    required this.onAdd,
    this.touch = false,
    this.onDrop,
  });

  final List<ManagedSession> sessions;
  final String? activeId;

  /// Phones get narrower tabs; a tablet or a desktop window has room to show
  /// the whole host label.
  final bool compact;

  /// Touch has been seen: every tab, and its close button, is a 48dp target.
  /// A mouse gets the slimmer strip it always had.
  final bool touch;

  final void Function(String id) onSelect;
  final void Function(ManagedSession entry) onClose;
  final VoidCallback onAdd;

  /// A file (or a selection) was dropped onto [target]'s tab from another
  /// session's browser. Null when there is nothing to drag from — one
  /// session open, or the callers are still on a build that predates the
  /// drag-and-drop path.
  ///
  /// Non-nullable target because same-session drops are refused earlier by
  /// each tab's [DragTarget], so a callback that runs has already crossed
  /// that check.
  final void Function(ManagedSession target, TabDropPayload payload)? onDrop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      child: SizedBox(
        height: touch ? 52 : (compact ? 42 : 46),
        child: Row(
          children: [
            Expanded(
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                itemCount: sessions.length,
                itemBuilder: (context, index) {
                  final entry = sessions[index];
                  return _SessionTab(
                    entry: entry,
                    selected: entry.id == activeId,
                    touch: touch,
                    maxWidth: (compact ? 148 : 220) + (touch ? 16 : 0),
                    onTap: () => onSelect(entry.id),
                    onClose: () => onClose(entry),
                    onDrop: onDrop == null
                        ? null
                        : (payload) => onDrop!(entry, payload),
                  );
                },
              ),
            ),
            const VerticalDivider(width: 1, indent: 8, endIndent: 8),
            IconButton(
              tooltip: context.l10n.sessionNew,
              icon: const Icon(Icons.add, size: 20),
              onPressed: onAdd,
            ),
          ],
        ),
      ),
    );
  }
}

class _SessionTab extends StatelessWidget {
  const _SessionTab({
    required this.entry,
    required this.selected,
    required this.maxWidth,
    required this.onTap,
    required this.onClose,
    this.touch = false,
    this.onDrop,
  });

  final ManagedSession entry;
  final bool selected;
  final bool touch;
  final double maxWidth;
  final VoidCallback onTap;
  final VoidCallback onClose;

  /// A payload was dropped onto this tab. Same-session drops are already
  /// filtered out; null when there is no cross-session drop path (only one
  /// session open).
  final void Function(TabDropPayload payload)? onDrop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final closed = entry.isClosed;

    // The base tab: same widget the drag-target below wraps around, so a tab
    // that does not accept drops (only one session open, or a build with no
    // drop callback wired in) looks and behaves exactly as it always did.
    Widget buildTab({required bool hovering}) {
      // Material asserts `shape` and `borderRadius` are not both set: use one
      // or the other. The hovering border needs to hug the rounded corners,
      // so it goes through `shape`; the non-hovering path stays on the
      // simpler `borderRadius` it always used.
      final radius = BorderRadius.circular(8);
      return Padding(
        padding: EdgeInsets.symmetric(vertical: touch ? 2 : 4, horizontal: 2),
        child: Material(
          color: selected
              ? theme.colorScheme.primary.withValues(alpha: 0.16)
              : Colors.transparent,
          borderRadius: hovering ? null : radius,
          shape: hovering
              ? RoundedRectangleBorder(
                  side: BorderSide(color: theme.colorScheme.primary, width: 2),
                  borderRadius: radius,
                )
              : null,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: Padding(
                padding: const EdgeInsets.only(left: 10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.circle,
                      size: 8,
                      color: closed
                          ? theme.colorScheme.error
                          : theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        entry.host.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.normal,
                          color: selected
                              ? theme.colorScheme.onSurface
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: closed
                          ? context.l10n.sessionTabClose(entry.host.displayName)
                          : context.l10n
                              .sessionTabDisconnect(entry.host.displayName),
                      icon: const Icon(Icons.close, size: 15),
                      // Compact density takes 8dp back off the constraints
                      // below, which touch cannot spare.
                      visualDensity: touch
                          ? VisualDensity.standard
                          : VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      constraints: BoxConstraints(
                        minWidth: touch ? 48 : 32,
                        minHeight: touch ? 48 : 32,
                      ),
                      onPressed: onClose,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    final drop = onDrop;
    if (drop == null) return buildTab(hovering: false);

    // The type parameter is not decoration: `DragTarget<TabDropPayload>`
    // silently refuses any other payload type, and without it Flutter's
    // arena would happily match a `DragTarget<dynamic>` against payloads
    // meant for something else — the drop would land with no visible error.
    return DragTarget<TabDropPayload>(
      onWillAcceptWithDetails: (details) {
        // A drop onto the tab of the session the file already lives on is a
        // no-op (same-session copy is a rename or a `cp` on the shell, not a
        // transfer). Refuse it silently: no highlight, and the drag continues
        // as if this tab were not there, so releasing over it counts as a
        // cancel.
        return details.data.sourceSessionId != entry.id;
      },
      onAcceptWithDetails: (details) => drop(details.data),
      builder: (context, candidateData, rejectedData) =>
          buildTab(hovering: candidateData.isNotEmpty),
    );
  }
}

/// The "saved" announcement for a batch of finished downloads.
///
/// Built by a free function, rather than inline where it is shown, so that a
/// test can hold it and watch it go away — because the bug this shape exists
/// to keep fixed was entirely about how long it stayed.
///
/// `persist: false` is the fix and is not optional. Flutter's [SnackBar]
/// derives `persist` from whether an action was given — `persist ?? action !=
/// null` — so any bar with a button on it defaults to staying up until
/// something dismisses it. The dismissal timer still runs; it just returns
/// without hiding anything. This announcement has carried an "Open" action
/// since it was written, so it inherited that default and sat on screen
/// through folder changes, Settings, the host list and reconnects, which
/// read as the app being stuck rather than as a considered choice. Four
/// seconds and gone is right here: "Open" is a convenience, not the only way
/// to the file — the same action lives permanently on the row in the
/// transfers sheet behind the app bar's button.
@visibleForTesting
SnackBar buildDownloadSavedSnackBar(
  AppLocalizations l10n, {
  required List<TransferTask> batch,
  required void Function(TransferTask task) onOpen,
  required VoidCallback onShowAll,
  String? from,
}) {
  final single = batch.length == 1 ? batch.single : null;
  final uri = single?.destinationUri;
  final saved = single != null
      ? l10n.transferPanelSavedFile(single.destination ?? single.name)
      : l10n.transferPanelSavedToDownloads(batch.length);

  return SnackBar(
    persist: false,
    // Named only when the download finished on a session other than the one
    // on screen, so the ordinary single-session case reads exactly as it
    // always did.
    content: Text(from == null ? saved : l10n.sessionOnHost(from, saved)),
    action: single != null && uri != null && uri.isNotEmpty
        ? SnackBarAction(
            label: l10n.transferPanelOpen,
            onPressed: () => onOpen(single),
          )
        // A batch has no single file to open, so the useful action is the
        // list of what landed — every row there has its own "Open".
        : SnackBarAction(label: l10n.sessionDownloadShow, onPressed: onShowAll),
  );
}

/// The broadcast-input toggle, and — while it is on — the loudest thing in
/// the app bar.
///
/// Two quite different shapes on purpose. Off, it is an ordinary icon button
/// that says nothing, because "not broadcasting" is the normal state of the
/// world and normal states do not deserve chrome. On, it becomes a filled
/// warning-coloured chip that names the number of panes involved, because at
/// that point the user's mental model and the app's behaviour have diverged in
/// a way that can cost them a production server — and an icon in a slightly
/// different tint is not enough to close that gap.
class _BroadcastAction extends StatelessWidget {
  const _BroadcastAction({
    required this.enabled,
    required this.paneCount,
    required this.onToggle,
  });

  final bool enabled;

  /// How many panes a keystroke lands in, the focused one included.
  final int paneCount;

  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    if (!enabled) {
      return IconButton(
        tooltip: context.l10n.sessionBroadcastStart,
        icon: const Icon(Icons.podcasts_outlined),
        onPressed: onToggle,
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Tooltip(
        message: context.l10n.sessionBroadcastStop,
        child: Material(
          color: AppTheme.danger,
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.podcasts, size: 16, color: Colors.white),
                  const SizedBox(width: 6),
                  Text(
                    context.l10n.sessionBroadcastingTo(paneCount),
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// An action that is only sometimes there to take: a disabled one leaves its
/// key to the terminal, see [SessionShortcuts.dispatch].
class _SessionAction<T extends Intent> extends CallbackAction<T> {
  _SessionAction({required super.onInvoke, this.enabled = true});

  final bool enabled;

  @override
  bool isEnabled(T intent) => enabled;
}

/// App-bar transfer button, with a count badge while anything is moving.
class _TransferAction extends StatelessWidget {
  const _TransferAction({required this.queue, required this.onTap});

  final TransferQueue queue;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return TransferQueueBuilder(
      queue: queue,
      builder: (context, tasks) {
        if (tasks.isEmpty) return const SizedBox.shrink();
        final active = tasks.where((t) => t.status.isActive).length;
        final failed = tasks.any((t) => t.status == TransferStatus.failed);

        return IconButton(
          tooltip: context.l10n.transferPanelTitle,
          onPressed: onTap,
          icon: Badge(
            isLabelVisible: active > 0 || failed,
            backgroundColor:
                failed && active == 0 ? theme.colorScheme.error : null,
            label: active > 0 ? Text('$active') : null,
            child: const Icon(Icons.swap_vert),
          ),
        );
      },
    );
  }
}
