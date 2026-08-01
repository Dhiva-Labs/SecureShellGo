import 'package:flutter/material.dart';

import '../services/session_manager.dart';
import '../services/terminal_workspace.dart';
import '../theme.dart';

/// Draws [TerminalWorkspace]'s pane tree.
///
/// Hand-rolled rather than reached for off pub: a split view is two nested
/// `Flex`es and a draggable gap, the ratios already live in the controller,
/// and every package that does this brings its own state model that would then
/// be the second place the layout is described.
///
/// Nothing here owns anything. Every gesture goes straight to the workspace,
/// which notifies, and the screen above rebuilds — so the tree on screen and
/// the tree in the controller cannot drift.
class WorkspaceView extends StatelessWidget {
  const WorkspaceView({
    super.key,
    required this.workspace,
    required this.sessions,
    required this.paneContent,
    required this.onAddSession,
    this.broadcasting = false,
  });

  final TerminalWorkspace workspace;

  /// Whether keystrokes typed into the focused pane are being mirrored into
  /// every other visible pane.
  ///
  /// Drawn here as well as in the app bar, and drawn loudly, because the app
  /// bar is not where the user is looking while they type. The state is
  /// dangerous in exactly one way — a command meant for a staging box landing
  /// on a production one — and the mitigation is that every pane about to
  /// receive it is wearing the same warning colour as the "Disconnect" button.
  final bool broadcasting;

  /// Every open session, in tab-strip order — what a pane's picker offers.
  final List<ManagedSession> sessions;

  /// The live page for a session.
  ///
  /// Supplied by the screen rather than built here because the same element
  /// has to survive being moved between panes (and out of the panes
  /// altogether, when its pane closes): the screen holds a `GlobalKey` per
  /// session so Flutter reparents that subtree instead of tearing down its
  /// file browser and its scroll position.
  final Widget Function(ManagedSession entry) paneContent;

  final VoidCallback onAddSession;

  /// Thickness of the draggable gap between two panes. Wide enough to grab
  /// with a mouse without aiming; the visible line inside it is 1px.
  static const double dividerThickness = 6;

  ManagedSession? _entryFor(String? sessionId) {
    if (sessionId == null) return null;
    for (final entry in sessions) {
      if (entry.id == sessionId) return entry;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) => _node(context, workspace.root);

  Widget _node(BuildContext context, WorkspaceNode node) {
    switch (node) {
      case WorkspacePane():
        return _pane(context, node);
      case WorkspaceSplit():
        return _split(context, node);
    }
  }

  Widget _split(BuildContext context, WorkspaceSplit split) {
    final horizontal = split.axis == WorkspaceAxis.row;

    return LayoutBuilder(
      builder: (context, constraints) {
        final extent =
            horizontal ? constraints.maxWidth : constraints.maxHeight;
        // The divider is not part of either child's share, so the ratio stays
        // a property of the two panes rather than drifting with how many
        // dividers happen to be nested inside them.
        final free = (extent - dividerThickness).clamp(0.0, double.infinity);
        final firstExtent = free * split.ratio;

        final children = <Widget>[
          // First child sized, second child `Expanded`: two fractional
          // children would each round independently and leave a hairline of
          // background showing between them at some window widths.
          SizedBox(
            width: horizontal ? firstExtent : null,
            height: horizontal ? null : firstExtent,
            child: _node(context, split.first),
          ),
          _WorkspaceDivider(
            axis: split.axis,
            onDrag: (delta) {
              if (free <= 0) return;
              workspace.setRatio(split.id, split.ratio + delta / free);
            },
          ),
          Expanded(child: _node(context, split.second)),
        ];

        return horizontal
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              );
      },
    );
  }

  Widget _pane(BuildContext context, WorkspacePane pane) {
    final entry = _entryFor(pane.sessionId);
    final content = entry == null
        ? _EmptyPane(
            sessions: sessions,
            onChoose: (id) => workspace.showSession(id, inPaneId: pane.id),
            onAddSession: onAddSession,
          )
        : paneContent(entry);

    // One pane is not a workspace: no border, no header, no dividers, and so
    // no pixel of difference from the layout that existed before any of this.
    if (!workspace.isSplit) return content;

    final focused = pane.id == workspace.focusedPaneId;
    // An empty pane has no shell to receive anything, so it stays neutral —
    // colouring it would overstate how far the broadcast reaches.
    final receiving = broadcasting && entry != null;
    return Listener(
      // Focus follows the click anywhere in the pane, including the header and
      // the gaps around the terminal. Translucent so the terminal underneath
      // still gets the same pointer event and puts its own caret in.
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => workspace.focusPane(pane.id),
      child: DecoratedBox(
        decoration: BoxDecoration(
          // Constant width, colour only: a border that thickened on focus
          // would resize the terminal inside it, and resizing a terminal
          // reflows the remote program. Clicking around a workspace must not
          // make `htop` redraw.
          border: Border.all(
            width: 1.5,
            color: receiving
                ? AppTheme.danger
                : focused
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
        child: Column(
          children: [
            _PaneHeader(
              workspace: workspace,
              pane: pane,
              entry: entry,
              sessions: sessions,
              focused: focused,
              receiving: receiving,
            ),
            Expanded(child: content),
          ],
        ),
      ),
    );
  }
}

/// The draggable gap between two panes.
class _WorkspaceDivider extends StatelessWidget {
  const _WorkspaceDivider({required this.axis, required this.onDrag});

  final WorkspaceAxis axis;

  /// Pixels moved along the split's axis since the last update.
  final void Function(double delta) onDrag;

  @override
  Widget build(BuildContext context) {
    final horizontal = axis == WorkspaceAxis.row;
    final line = Theme.of(context).colorScheme.outlineVariant;

    return MouseRegion(
      cursor: horizontal
          ? SystemMouseCursors.resizeColumn
          : SystemMouseCursors.resizeRow,
      child: GestureDetector(
        // Opaque: the gap is the handle, and a drag that started on it must
        // not also reach the terminal behind and start selecting text.
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate:
            horizontal ? (details) => onDrag(details.delta.dx) : null,
        onVerticalDragUpdate:
            horizontal ? null : (details) => onDrag(details.delta.dy),
        child: SizedBox(
          width: horizontal ? WorkspaceView.dividerThickness : null,
          height: horizontal ? null : WorkspaceView.dividerThickness,
          child: Center(
            child: SizedBox(
              width: horizontal ? 1 : double.infinity,
              height: horizontal ? double.infinity : 1,
              child: ColoredBox(color: line),
            ),
          ),
        ),
      ),
    );
  }
}

/// What a pane's menu can do to it.
enum _PaneAction { splitRight, splitDown, close }

/// The strip along the top of a pane: which session it is showing, and the
/// menu that splits or closes it.
///
/// Only built when the workspace is split — see [WorkspaceView._pane].
class _PaneHeader extends StatelessWidget {
  const _PaneHeader({
    required this.workspace,
    required this.pane,
    required this.entry,
    required this.sessions,
    required this.focused,
    required this.receiving,
  });

  final TerminalWorkspace workspace;
  final WorkspacePane pane;
  final ManagedSession? entry;
  final List<ManagedSession> sessions;
  final bool focused;

  /// Whether broadcast input is on and this pane has a shell to receive it.
  final bool receiving;

  /// Menu value for "show nothing here". Never collides with a session id,
  /// which `SessionManager` always builds as `session-<n>`.
  static const String _clearPane = '';

  void _choose(String value) {
    if (value == _clearPane) {
      workspace.clearPane(pane.id);
      return;
    }
    workspace.showSession(value, inPaneId: pane.id);
  }

  void _act(_PaneAction action) {
    switch (action) {
      case _PaneAction.splitRight:
        workspace.split(pane.id, WorkspaceAxis.row);
      case _PaneAction.splitDown:
        workspace.split(pane.id, WorkspaceAxis.column);
      case _PaneAction.close:
        workspace.closePane(pane.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = entry;
    final canSplit = workspace.canSplit;

    return Material(
      // The focused pane's tint is stronger than its neighbours' in both
      // moods, so "which pane am I typing in" survives the warning colour
      // rather than being flattened by it.
      color: receiving
          ? AppTheme.danger.withValues(alpha: focused ? 0.30 : 0.18)
          : focused
              ? theme.colorScheme.primary.withValues(alpha: 0.12)
              : theme.colorScheme.surfaceContainerHigh,
      child: SizedBox(
        height: 30,
        child: Row(
          children: [
            const SizedBox(width: 8),
            if (receiving) ...[
              const Tooltip(
                message: 'Receiving broadcast input',
                child: Icon(Icons.podcasts, size: 12, color: AppTheme.danger),
              ),
              const SizedBox(width: 7),
            ],
            if (session != null) ...[
              Icon(
                Icons.circle,
                size: 7,
                color: session.isClosed
                    ? theme.colorScheme.error
                    : theme.colorScheme.primary,
              ),
              const SizedBox(width: 7),
            ],
            Flexible(
              child: PopupMenuButton<String>(
                tooltip: 'Session in this pane',
                position: PopupMenuPosition.under,
                onSelected: _choose,
                itemBuilder: (context) => [
                  for (final candidate in sessions)
                    CheckedPopupMenuItem<String>(
                      value: candidate.id,
                      checked: candidate.id == pane.sessionId,
                      child: Text(
                        candidate.host.displayName,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  if (session != null) ...[
                    const PopupMenuDivider(),
                    const PopupMenuItem<String>(
                      value: _clearPane,
                      child: Text('Leave this pane empty'),
                    ),
                  ],
                ],
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        session?.host.displayName ?? 'No session',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight:
                              focused ? FontWeight.w600 : FontWeight.normal,
                          color: session == null
                              ? theme.colorScheme.onSurfaceVariant
                              : theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                    const Icon(Icons.arrow_drop_down, size: 16),
                  ],
                ),
              ),
            ),
            const Spacer(),
            PopupMenuButton<_PaneAction>(
              tooltip: 'Pane',
              position: PopupMenuPosition.under,
              icon: const Icon(Icons.more_vert, size: 16),
              splashRadius: 16,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
              onSelected: _act,
              itemBuilder: (context) => [
                PopupMenuItem<_PaneAction>(
                  value: _PaneAction.splitRight,
                  enabled: canSplit,
                  child: const _PaneMenuRow(
                    icon: Icons.splitscreen,
                    label: 'Split right',
                  ),
                ),
                PopupMenuItem<_PaneAction>(
                  value: _PaneAction.splitDown,
                  enabled: canSplit,
                  child: const _PaneMenuRow(
                    icon: Icons.horizontal_split,
                    label: 'Split down',
                  ),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem<_PaneAction>(
                  value: _PaneAction.close,
                  child: _PaneMenuRow(
                    icon: Icons.close_fullscreen,
                    label: 'Close pane',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PaneMenuRow extends StatelessWidget {
  const _PaneMenuRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16),
        const SizedBox(width: 10),
        Text(label, style: const TextStyle(fontSize: 13)),
      ],
    );
  }
}

/// A pane with nothing in it — split off and not yet filled, or left behind by
/// a session the user closed.
///
/// Carries its own session picker rather than pointing at the header's: the
/// header only exists while the workspace is split, and the one case where a
/// *single* pane is empty (its session was closed while others are still open)
/// is exactly the case with no header to point at.
class _EmptyPane extends StatelessWidget {
  const _EmptyPane({
    required this.sessions,
    required this.onChoose,
    required this.onAddSession,
  });

  final List<ManagedSession> sessions;
  final void Function(String sessionId) onChoose;
  final VoidCallback onAddSession;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ColoredBox(
      color: theme.colorScheme.surfaceContainerHigh,
      child: Center(
        // Scrollable, because the pane this is offering to fill can be a
        // quarter of the window and the list of sessions to offer grows with
        // every one the user opens. `Center` still centres it while it fits.
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.terminal,
                size: 26,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 10),
              Text(
                'No session in this pane',
                style: TextStyle(
                  fontSize: 13,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  for (final entry in sessions)
                    OutlinedButton(
                      onPressed: () => onChoose(entry.id),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 32),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        textStyle: const TextStyle(fontSize: 12.5),
                      ),
                      // A `Wrap` moves an over-wide child to its own line but
                      // cannot make it narrower, and a host label is whatever
                      // the user typed. Cap it and ellipsise.
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 132),
                        child: Text(
                          entry.host.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  FilledButton.tonalIcon(
                    onPressed: onAddSession,
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('New session'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 32),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      textStyle: const TextStyle(fontSize: 12.5),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
