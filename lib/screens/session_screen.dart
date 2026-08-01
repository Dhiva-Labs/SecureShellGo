import 'dart:async';

import 'package:flutter/material.dart';

import '../services/broadcast_input.dart';
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
import '../widgets/snippet_picker.dart';
import '../widgets/transfer_hub_panel.dart';
import '../widgets/transfer_panel.dart';
import '../widgets/tunnel_indicator.dart';
import 'file_browser_pane.dart';
import 'log_viewer_screen.dart';
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
/// Phase 13 adds a second body for desktop only: the split workspace, where up
/// to four panes each show a session and the rest wait in the tab strip. The
/// bargain above is unchanged there — a session with no pane of its own is
/// still built, still laid out at full size, and merely not painted. Phones
/// and tablets never build a workspace at all; see [_isDesktop].
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

  /// Test seam; production leaves this to the default channel-backed one.
  final KeepAwakeController keepAwake;

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

/// What the app bar's split button can do to the focused pane.
enum _WorkspaceAction { splitRight, splitDown, closePane }

/// The monitoring views reachable from a session's overflow menu.
///
/// They live behind one menu rather than as three more icons because none of
/// them is something the user reaches for mid-keystroke — the bar is already
/// carrying everything that is.
enum _MonitorAction { stats, services, tail }

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
    super.dispose();
  }

  /// Desktop platforms — Linux, macOS, Windows — where a window is big enough
  /// and a mouse precise enough for a split workspace to be worth having.
  /// Same shape as `FileBrowserPane`'s check, and for the same reason: it
  /// reads the platform through the theme so a test can swap it with
  /// [debugDefaultTargetPlatformOverride].
  static bool _isDesktop(BuildContext context) {
    switch (Theme.of(context).platform) {
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        return true;
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.fuchsia:
        return false;
    }
  }

  /// Tells the workspace which sessions exist. Mobile never calls this — and
  /// never reads the workspace either, so the tabbed layout is untouched by
  /// everything below.
  void _syncWorkspace() {
    if (!_isDesktop(context)) return;
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
  /// Desktop only, like everything else past [_syncWorkspace]'s guard: the
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

  /// A tab was tapped. On desktop that means "show this one in the pane I am
  /// looking at" — otherwise a tab for a session that is not in any pane would
  /// change the app bar and nothing else.
  void _selectSession(String id) {
    if (_isDesktop(context)) _workspace.showSession(id);
    widget.sessions.select(id);
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
    // Drop the soft keyboard on the way out of the terminal, or the file list
    // opens behind it.
    FocusManager.instance.primaryFocus?.unfocus();
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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
          'That session has been closed. Reopen it to send its files.',
        ),
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
      final transfers = entry.controller.transfers.activeCount;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Disconnect?'),
          content: Text(
            transfers > 0
                ? 'Close the session on ${entry.host.displayName}? '
                    '$transfers transfer${transfers == 1 ? '' : 's'} '
                    '${transfers == 1 ? 'is' : 'are'} still running and will '
                    'be cancelled.'
                : 'Close the session on ${entry.host.displayName}?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Stay'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Disconnect'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    await widget.sessions.close(entry.id);
    // The last tab closing takes the screen with it — there is nothing left
    // here to look at, and the host list is where a new session starts.
    if (mounted && widget.sessions.isEmpty) Navigator.of(context).pop();
  }

  /// One session's page, with the identity that lets it be moved rather than
  /// rebuilt. See [_pageKeys].
  Widget _page(
    ManagedSession entry, {
    required SessionManager manager,
    required bool active,
    required bool wide,
  }) {
    return _SessionPage(
      key: _pageKeys.putIfAbsent(entry.id, GlobalKey.new),
      entry: entry,
      manager: manager,
      settingsStore: widget.settingsStore,
      active: active,
      wide: wide,
    );
  }

  /// Phones and tablets: one session at a time, all of them alive.
  Widget _tabbedBody(
    SessionManager manager,
    List<ManagedSession> entries,
    bool wide,
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
              wide: wide,
            ),
          ),
      ],
    );
  }

  /// Desktop: the pane tree, over every session that has no pane of its own.
  Widget _workspaceBody(
    SessionManager manager,
    List<ManagedSession> entries,
    bool wide,
  ) {
    final visible = _workspace.visibleSessionIds.toSet();
    final focusedSessionId = _workspace.focusedSessionId;
    // A split pane is half a window or less. Handing it the side-by-side
    // layout would put a 40-column terminal next to a file browser too narrow
    // to read a filename in, so a split workspace gives each pane the
    // one-view-at-a-time layout and the app bar's toggle switches the focused
    // one between them.
    final paneWide = wide && !_workspace.isSplit;

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
                  wide: paneWide,
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
            wide: paneWide,
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
    final wide = WindowSizeClass.forWidth(
      MediaQuery.sizeOf(context).width,
    ).isAtLeastMedium;

    // Desktop gets the split workspace; everything else gets the tabbed
    // layout it always had, untouched.
    final desktop = _isDesktop(context);
    final split = desktop && _workspace.isSplit;

    // Only offer the drop target when there is anywhere to drop *from*: with
    // one session open there is no other tab to drag to. The strip does not
    // even render in that case, but the callback is defined on the widget so
    // the check has to be here.
    final canReceiveDrops = entries.length > 1;

    final closed = active.isClosed;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        leading: IconButton(
          tooltip: entries.length == 1
              ? 'Host list — this session stays connected'
              : 'Host list — these sessions stay connected',
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
                Text(
                  closed ? 'disconnected' : active.host.target,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
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
          if (desktop)
            PopupMenuButton<_WorkspaceAction>(
              tooltip: 'Split the focused pane',
              icon: const Icon(Icons.splitscreen_outlined),
              onSelected: _handleWorkspaceAction,
              itemBuilder: (context) => [
                PopupMenuItem<_WorkspaceAction>(
                  value: _WorkspaceAction.splitRight,
                  enabled: _workspace.canSplit,
                  child: const Text('Split right'),
                ),
                PopupMenuItem<_WorkspaceAction>(
                  value: _WorkspaceAction.splitDown,
                  enabled: _workspace.canSplit,
                  child: const Text('Split down'),
                ),
                const PopupMenuDivider(),
                PopupMenuItem<_WorkspaceAction>(
                  value: _WorkspaceAction.closePane,
                  // Closing the only pane would leave nothing to focus and
                  // nowhere to put the next session.
                  enabled: split,
                  child: const Text('Close pane'),
                ),
              ],
            ),
          // Persistent across every tab, unlike the button above: this one
          // is not "this session's transfers" but every session's, so it
          // stays put — and its badge counted — whichever tab is in front.
          TransferHubAction(
            hub: _hub,
            onTap: () => showTransferHubSheet(context, _hub),
          ),
          // Both panes are already on screen side by side in the wide layout,
          // so a toggle between them means nothing there — except in a split
          // workspace, where each pane is narrow and shows one at a time.
          if (!wide || split)
            IconButton(
              tooltip: active.view == SessionView.terminal
                  ? 'Browse files'
                  : 'Back to terminal',
              icon: Icon(
                active.view == SessionView.terminal
                    ? Icons.folder_outlined
                    : Icons.terminal,
              ),
              onPressed: () => _show(
                active.view == SessionView.terminal
                    ? SessionView.files
                    : SessionView.terminal,
              ),
            ),
          IconButton(
            tooltip: 'Snippets',
            icon: const Icon(Icons.bolt_outlined),
            onPressed: _openSnippetPicker,
          ),
          // Monitoring. Disabled on a closed session: all three run commands
          // over the transport, and there is not one.
          PopupMenuButton<_MonitorAction>(
            tooltip: 'Monitor this server',
            icon: const Icon(Icons.monitor_heart_outlined),
            enabled: !closed,
            onSelected: (action) =>
                unawaited(_handleMonitorAction(action, active.controller)),
            itemBuilder: (context) => const [
              PopupMenuItem<_MonitorAction>(
                value: _MonitorAction.stats,
                child: Text('Server stats'),
              ),
              PopupMenuItem<_MonitorAction>(
                value: _MonitorAction.services,
                child: Text('Services & processes'),
              ),
              PopupMenuItem<_MonitorAction>(
                value: _MonitorAction.tail,
                child: Text('Tail a file…'),
              ),
            ],
          ),
          // With one session open this is the only sign that a second one is
          // possible, so it stays in the bar rather than living only in the
          // tab strip that has not appeared yet.
          IconButton(
            tooltip: 'New session',
            icon: const Icon(Icons.add),
            onPressed: _addSession,
          ),
          IconButton(
            tooltip: closed ? 'Close tab' : 'Disconnect',
            icon: Icon(closed ? Icons.close : Icons.power_settings_new),
            color: closed ? null : theme.colorScheme.error,
            onPressed: () => unawaited(_closeActive()),
          ),
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
                onSelect: _selectSession,
                onClose: (entry) => unawaited(_closeSession(entry)),
                onAdd: _addSession,
                onDrop: canReceiveDrops ? _handleTabDrop : null,
              ),
            Expanded(
              child: desktop
                  ? _workspaceBody(manager, entries, wide)
                  : _tabbedBody(manager, entries, wide),
            ),
          ],
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
    required this.wide,
  });

  final ManagedSession entry;
  final SessionManager manager;
  final SettingsStore settingsStore;
  final bool active;
  final bool wide;

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
        }
      });
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
        content: Text(widget.active ? reason : '${widget.entry.host.displayName}: $reason'),
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
    final opened = await _session.openDownload(task);
    if (!opened) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('No app on this device can open that file.'),
        ),
      );
    }
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

    // Once the layout has gone wide, the file browser pane is live and its
    // SFTP channel open; folding back to compact should not throw that away
    // and re-show the "not built yet" placeholder in the IndexedStack branch.
    if (widget.wide) widget.manager.markFilesBuilt(entry.id);

    return Column(
      children: [
        // Reconnecting takes precedence over the disconnected banner: both
        // describe the same dead transport, but only one of them is still a
        // live story. Neither blocks anything — the scrollback stays on
        // screen and stays scrollable underneath.
        if (_session.isReconnecting)
          _ReconnectingBanner(
            message: _session.reconnectMessage,
            onStop: () => setState(_session.stopReconnecting),
          )
        else if (entry.isClosed)
          _DisconnectedBanner(
            message: entry.controller.closeReason,
            onClose: () => unawaited(widget.manager.close(entry.id)),
          ),
        Expanded(
          child: widget.wide
              // Tablets, DeX and unfolded foldables: both panes live at once,
              // sharing the one `SessionController` — the file browser opening
              // its SFTP channel here is deliberate, not lazy, since there is
              // no "ask for it" tap in this layout for it to wait on.
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 3, child: _terminalPane()),
                    const VerticalDivider(width: 1),
                    Expanded(flex: 2, child: _fileBrowserPane()),
                  ],
                )
              // Phones: one pane at a time behind the app-bar toggle.
              : IndexedStack(
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
    this.onDrop,
  });

  final List<ManagedSession> sessions;
  final String? activeId;

  /// Phones get narrower tabs; a tablet or a desktop window has room to show
  /// the whole host label.
  final bool compact;

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
        height: compact ? 42 : 46,
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
                    maxWidth: compact ? 148 : 220,
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
              tooltip: 'New session',
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
    this.onDrop,
  });

  final ManagedSession entry;
  final bool selected;
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
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
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
                          ? 'Close ${entry.host.displayName}'
                          : 'Disconnect ${entry.host.displayName}',
                      icon: const Icon(Icons.close, size: 15),
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      constraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
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
SnackBar buildDownloadSavedSnackBar({
  required List<TransferTask> batch,
  required void Function(TransferTask task) onOpen,
  required VoidCallback onShowAll,
  String? from,
}) {
  final single = batch.length == 1 ? batch.single : null;
  final uri = single?.destinationUri;
  // Named only when the download finished on a session other than the one on
  // screen, so the ordinary single-session case reads exactly as it always did.
  final prefix = from == null ? '' : '$from: ';

  return SnackBar(
    persist: false,
    content: Text(
      single != null
          ? '${prefix}Saved ${single.destination ?? single.name}'
          : '$prefix${batch.length} files saved to Downloads',
    ),
    action: single != null && uri != null && uri.isNotEmpty
        ? SnackBarAction(label: 'Open', onPressed: () => onOpen(single))
        // A batch has no single file to open, so the useful action is the
        // list of what landed — every row there has its own "Open".
        : SnackBarAction(label: 'Show', onPressed: onShowAll),
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
        tooltip: 'Broadcast input to every visible pane',
        icon: const Icon(Icons.podcasts_outlined),
        onPressed: onToggle,
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Tooltip(
        message: 'Broadcasting — tap to stop',
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
                    'Broadcasting to $paneCount '
                    '${paneCount == 1 ? 'pane' : 'panes'}',
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
          tooltip: 'Transfers',
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

/// "Reconnecting…", above the terminal whose transport has just died.
///
/// Deliberately not a dialog, not a modal barrier and not a full-screen
/// placeholder: the session may well be back in two seconds, and having thrown
/// a modal over the user's scrollback for a Wi-Fi handover would be a worse
/// experience than the drop it is reporting. The old buffer stays on screen
/// and stays readable throughout.
class _ReconnectingBanner extends StatelessWidget {
  const _ReconnectingBanner({this.message, required this.onStop});

  final String? message;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.primary.withValues(alpha: 0.13),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message ?? 'Reconnecting…',
                style: const TextStyle(fontSize: 13, height: 1.3),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              // Reconnecting is a guess about what the user wants; this is how
              // they say otherwise, without having to close the tab to do it.
              onPressed: onStop,
              child: const Text('Stop'),
            ),
          ],
        ),
      ),
    );
  }
}

class _DisconnectedBanner extends StatelessWidget {
  const _DisconnectedBanner({this.message, required this.onClose});

  final String? message;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.error.withValues(alpha: 0.15),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Row(
          children: [
            Icon(Icons.link_off, color: theme.colorScheme.error, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message ?? 'Connection closed.',
                style: const TextStyle(fontSize: 13, height: 1.3),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              // A dead session's tab is the one thing left to do something
              // about, and closing it is the only useful thing — the others
              // are unaffected either way.
              onPressed: onClose,
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }
}
