import 'package:flutter/material.dart';

import '../models/app_settings.dart';
import '../models/host.dart';
import '../services/host_grouping.dart';
import '../services/layout_breakpoints.dart';
import 'host_color_dot.dart';

/// The callbacks every presentation variant below needs. One bundle instead
/// of five loose parameters on every section builder — `host_list_screen.dart`
/// still owns what each of these actually does (persisting a collapsed set,
/// pushing the edit screen, opening the bottom sheet); this file only ever
/// calls them.
class HostListActions {
  const HostListActions({
    required this.onToggleSection,
    required this.onRenameGroup,
    required this.onDeleteGroup,
    required this.onConnect,
    required this.onHostMenu,
    this.onToggleSelect,
    this.onSelectAllInGroup,
  });

  final void Function(HostSection section) onToggleSection;
  final void Function(String group) onRenameGroup;
  final void Function(String group) onDeleteGroup;
  final void Function(Host host) onConnect;
  final void Function(Host host) onHostMenu;

  /// Flips one host's checked state while selection mode is on. Null (the
  /// default) is what every existing caller gets, and is indistinguishable
  /// from "selection mode is off" as far as this file's widgets are
  /// concerned — see [HostListPresentation.buildSectionSlivers]'s
  /// `selectionMode` parameter, which is the actual gate.
  final void Function(Host host)? onToggleSelect;

  /// The group header's own checkbox: select (or clear) every host in that
  /// section at once.
  final void Function(HostSection section)? onSelectAllInGroup;
}

/// Chooses and builds the saved-hosts list's per-section slivers.
///
/// A phone-width (or split-screen-narrow) window always gets the plain
/// one-column list regardless of [UiStyle] — see [_listSection]'s doc. Only a
/// desktop-width window (`WindowSizeClass.isAtLeastMedium`, the same gate
/// `session_screen.dart` uses for its own desktop-only split view) picks a
/// structural idiom by style: aurora keeps today's grouped-headers-plus-
/// responsive-grid look exactly, and aws/gcp/azure each get their own console-
/// inspired layout. `host_list_screen.dart` hands this already-built
/// [HostSection] list and a callback bundle; nothing here reaches back into
/// stores or navigation.
class HostListPresentation {
  const HostListPresentation._();

  static List<Widget> buildSectionSlivers({
    required List<HostSection> sections,
    required UiStyle style,
    required double width,
    required bool searching,
    required bool Function(HostSection section) isCollapsed,
    required String? connectingHostId,
    required HostListActions actions,
    /// Whether the list is showing checkboxes instead of connect-on-tap.
    /// False everywhere except while a fleet push is being set up — see
    /// `host_list_screen.dart`. Every existing caller leaves this at the
    /// default, which renders identically to before this parameter existed.
    bool selectionMode = false,
    Set<String> selectedHostIds = const <String>{},
  }) {
    final windowClass = WindowSizeClass.forWidth(width);

    if (!windowClass.isAtLeastMedium) {
      return [
        for (final section in sections)
          _listSection(
            section: section,
            collapsed: isCollapsed(section),
            dense: false,
            searching: searching,
            connectingHostId: connectingHostId,
            actions: actions,
            selectionMode: selectionMode,
            selectedHostIds: selectedHostIds,
          ),
      ];
    }

    final expandedLayout = windowClass == WindowSizeClass.expanded;
    return switch (style) {
      UiStyle.aurora => [
          for (final section in sections)
            expandedLayout
                ? _gridSection(
                    section: section,
                    collapsed: isCollapsed(section),
                    searching: searching,
                    connectingHostId: connectingHostId,
                    actions: actions,
                    selectionMode: selectionMode,
                    selectedHostIds: selectedHostIds,
                  )
                : _listSection(
                    section: section,
                    collapsed: isCollapsed(section),
                    dense: false,
                    searching: searching,
                    connectingHostId: connectingHostId,
                    actions: actions,
                    selectionMode: selectionMode,
                    selectedHostIds: selectedHostIds,
                  ),
        ],
      UiStyle.aws => [
          for (final section in sections)
            _awsSection(
              section: section,
              collapsed: isCollapsed(section),
              searching: searching,
              connectingHostId: connectingHostId,
              actions: actions,
              selectionMode: selectionMode,
              selectedHostIds: selectedHostIds,
            ),
        ],
      UiStyle.gcp => [
          for (final section in sections)
            _gcpSection(
              section: section,
              collapsed: isCollapsed(section),
              searching: searching,
              connectingHostId: connectingHostId,
              actions: actions,
              selectionMode: selectionMode,
              selectedHostIds: selectedHostIds,
            ),
        ],
      UiStyle.azure => [
          for (final section in sections)
            _listSection(
              section: section,
              collapsed: isCollapsed(section),
              dense: true,
              searching: searching,
              connectingHostId: connectingHostId,
              actions: actions,
              headerVariant: _HeaderVariant.azure,
              selectionMode: selectionMode,
              selectedHostIds: selectedHostIds,
            ),
        ],
    };
  }
}

/// One collapsible group: its header sliver, then (unless collapsed) its
/// body sliver — the shape every variant below shares, so a bottom margin can
/// sit on the pair without a separate sliver-padding entry per section
/// leaking into `CustomScrollView.slivers`. Lifted from the pre-wave-2
/// `_buildSection` unchanged.
Widget _sectionSliver({
  required Widget header,
  required bool collapsed,
  required Widget Function() body,
}) {
  return SliverPadding(
    padding: const EdgeInsets.only(bottom: 6),
    sliver: SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(child: header),
        if (!collapsed) body(),
      ],
    ),
  );
}

/// Which per-style chrome [_StyledGroupHeader] renders. Not the same axis as
/// [UiStyle] — [_listSection] is reused by mobile (always [aurora]), aurora's
/// own desktop list mode, and azure's desktop list (the one place a list
/// section wants non-aurora chrome) — so it takes its own small enum instead
/// of a full [UiStyle] switch.
enum _HeaderVariant { aurora, aws, gcp, azure }

// ---------------------------------------------------------------------------
// Aurora + mobile: today's grouped header, either a one-column list or (
// aurora, expanded width only) a 2-column card grid. Ported from
// `host_list_screen.dart`'s pre-wave-2 `_buildSection`/`_GroupHeader`/
// `_buildListSliver`/`_buildGridSliver`/`_HostCard` byte-for-byte in
// substance — only split into reusable pieces and renamed to avoid clashing
// with the screen's own remaining private types.
// ---------------------------------------------------------------------------

/// The plain one-column list: aurora's own look at compact/medium width, and
/// — regardless of [UiStyle] — the only thing a phone or a narrow split-
/// screen window ever renders. A phone has no room for a table's columns or
/// a card grid, and the point of wave 2's variants is structural, not
/// colour, which mobile already gets from [AppTheme.themeFor] without any of
/// this. [dense] is azure's one accommodation: its rows are its own
/// [_HeaderVariant.azure], slightly tighter than aurora's, but still this
/// same list, not a bespoke row type.
Widget _listSection({
  required HostSection section,
  required bool collapsed,
  required bool dense,
  required bool searching,
  required String? connectingHostId,
  required HostListActions actions,
  _HeaderVariant headerVariant = _HeaderVariant.aurora,
  bool selectionMode = false,
  Set<String> selectedHostIds = const <String>{},
}) {
  return _sectionSliver(
    header: _StyledGroupHeader(
      section: section,
      collapsed: collapsed,
      variant: headerVariant,
      onToggle: searching ? null : () => actions.onToggleSection(section),
      onRename: section.isUngrouped
          ? null
          : () => actions.onRenameGroup(section.group!),
      onDelete: section.isUngrouped
          ? null
          : () => actions.onDeleteGroup(section.group!),
      selectionMode: selectionMode,
      selectedHostIds: selectedHostIds,
      onSelectAll: actions.onSelectAllInGroup,
    ),
    collapsed: collapsed,
    body: () => SliverList.separated(
      itemCount: section.hosts.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final host = section.hosts[index];
        final selected = selectedHostIds.contains(host.id);
        return _ListHostRow(
          host: host,
          connecting: connectingHostId == host.id,
          dense: dense,
          selectionMode: selectionMode,
          selected: selected,
          onTap: selectionMode
              ? () => actions.onToggleSelect?.call(host)
              : () => actions.onConnect(host),
          onMore: () => actions.onHostMenu(host),
        );
      },
    ),
  );
}

/// Aurora's expanded-width grid: unchanged from before wave 2.
Widget _gridSection({
  required HostSection section,
  required bool collapsed,
  required bool searching,
  required String? connectingHostId,
  required HostListActions actions,
  bool selectionMode = false,
  Set<String> selectedHostIds = const <String>{},
}) {
  return _sectionSliver(
    header: _StyledGroupHeader(
      section: section,
      collapsed: collapsed,
      variant: _HeaderVariant.aurora,
      onToggle: searching ? null : () => actions.onToggleSection(section),
      onRename: section.isUngrouped
          ? null
          : () => actions.onRenameGroup(section.group!),
      onDelete: section.isUngrouped
          ? null
          : () => actions.onDeleteGroup(section.group!),
      selectionMode: selectionMode,
      selectedHostIds: selectedHostIds,
      onSelectAll: actions.onSelectAllInGroup,
    ),
    collapsed: collapsed,
    body: () => SliverPadding(
      padding: const EdgeInsets.all(12),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          mainAxisExtent: 104,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final host = section.hosts[index];
            final selected = selectedHostIds.contains(host.id);
            return _AuroraHostCard(
              host: host,
              connecting: connectingHostId == host.id,
              selectionMode: selectionMode,
              selected: selected,
              onTap: selectionMode
                  ? () => actions.onToggleSelect?.call(host)
                  : () => actions.onConnect(host),
              onMore: () => actions.onHostMenu(host),
            );
          },
          childCount: section.hosts.length,
        ),
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// AWS-inspired: a dense, single-line-per-host table with aligned columns —
// the resource-list feel of that console.
// ---------------------------------------------------------------------------

Widget _awsSection({
  required HostSection section,
  required bool collapsed,
  required bool searching,
  required String? connectingHostId,
  required HostListActions actions,
  bool selectionMode = false,
  Set<String> selectedHostIds = const <String>{},
}) {
  return _sectionSliver(
    header: _StyledGroupHeader(
      section: section,
      collapsed: collapsed,
      variant: _HeaderVariant.aws,
      onToggle: searching ? null : () => actions.onToggleSection(section),
      onRename: section.isUngrouped
          ? null
          : () => actions.onRenameGroup(section.group!),
      onDelete: section.isUngrouped
          ? null
          : () => actions.onDeleteGroup(section.group!),
      selectionMode: selectionMode,
      selectedHostIds: selectedHostIds,
      onSelectAll: actions.onSelectAllInGroup,
    ),
    collapsed: collapsed,
    body: () => SliverList.separated(
      itemCount: section.hosts.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final host = section.hosts[index];
        final selected = selectedHostIds.contains(host.id);
        return _AwsHostRow(
          host: host,
          connecting: connectingHostId == host.id,
          selectionMode: selectionMode,
          selected: selected,
          onTap: selectionMode
              ? () => actions.onToggleSelect?.call(host)
              : () => actions.onConnect(host),
          onMore: () => actions.onHostMenu(host),
        );
      },
    ),
  );
}

/// One table-style row: name, target and last-connected in fixed-flex
/// columns on a single line, so a group reads like a resource list rather
/// than a stack of cards.
class _AwsHostRow extends StatelessWidget {
  const _AwsHostRow({
    required this.host,
    required this.connecting,
    required this.onTap,
    required this.onMore,
    this.selectionMode = false,
    this.selected = false,
  });

  final Host host;
  final bool connecting;
  final VoidCallback onTap;
  final VoidCallback onMore;
  final bool selectionMode;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final textStyle = TextStyle(fontSize: 13, color: scheme.onSurface);
    final mutedStyle = theme.textTheme.bodySmall?.copyWith(
      fontFamily: 'monospace',
      color: scheme.onSurfaceVariant,
    );

    return Material(
      color: Colors.transparent,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTap: connecting || selectionMode ? null : onMore,
        child: InkWell(
          onTap: connecting ? null : onTap,
          onLongPress: connecting || selectionMode ? null : onMore,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Row(
              children: [
                if (selectionMode)
                  Checkbox(
                    value: selected,
                    onChanged: (_) => onTap(),
                  )
                else
                  SizedBox(
                    width: 18,
                    child: host.colorLabel == null
                        ? null
                        : HostColorDot(colorLabel: host.colorLabel, size: 8),
                  ),
                Icon(
                  host.authMethod == SshAuthMethod.password
                      ? Icons.password
                      : Icons.key,
                  size: 14,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 3,
                  child: Text(
                    host.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textStyle.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 3,
                  child: Text(
                    host.target,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: mutedStyle,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: Text(
                    host.lastConnectedAt == null
                        ? '—'
                        : _formatLastConnected(host.lastConnectedAt!),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: mutedStyle,
                  ),
                ),
                SizedBox(
                  width: 28,
                  height: 28,
                  child: selectionMode
                      ? null
                      : connecting
                          ? const Padding(
                              padding: EdgeInsets.all(5),
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : IconButton(
                              tooltip: 'More',
                              padding: EdgeInsets.zero,
                              iconSize: 17,
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(Icons.more_vert),
                              onPressed: onMore,
                            ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// GCP-inspired: an airy card grid — larger cards, generous padding, the
// theme's own soft shadow (see `theme.dart`'s `_gcpLight`/`_gcpDark`
// `cardElevation: 2`), light section titles with room to breathe above them.
// ---------------------------------------------------------------------------

Widget _gcpSection({
  required HostSection section,
  required bool collapsed,
  required bool searching,
  required String? connectingHostId,
  required HostListActions actions,
  bool selectionMode = false,
  Set<String> selectedHostIds = const <String>{},
}) {
  return _sectionSliver(
    header: _StyledGroupHeader(
      section: section,
      collapsed: collapsed,
      variant: _HeaderVariant.gcp,
      onToggle: searching ? null : () => actions.onToggleSection(section),
      onRename: section.isUngrouped
          ? null
          : () => actions.onRenameGroup(section.group!),
      onDelete: section.isUngrouped
          ? null
          : () => actions.onDeleteGroup(section.group!),
      selectionMode: selectionMode,
      selectedHostIds: selectedHostIds,
      onSelectAll: actions.onSelectAllInGroup,
    ),
    collapsed: collapsed,
    body: () => SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      sliver: SliverGrid(
        // Max-extent (not a fixed count) so the grid answers a wider window
        // with more columns on its own, the way aurora's grid only ever
        // answers with a fixed 2 — gcp's whole idiom is "give the cards room",
        // so a card should not have to shrink to fit a rigid column count.
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 380,
          mainAxisExtent: 144,
          mainAxisSpacing: 16,
          crossAxisSpacing: 16,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final host = section.hosts[index];
            final selected = selectedHostIds.contains(host.id);
            return _GcpHostCard(
              host: host,
              connecting: connectingHostId == host.id,
              selectionMode: selectionMode,
              selected: selected,
              onTap: selectionMode
                  ? () => actions.onToggleSelect?.call(host)
                  : () => actions.onConnect(host),
              onMore: () => actions.onHostMenu(host),
            );
          },
          childCount: section.hosts.length,
        ),
      ),
    ),
  );
}

/// A roomier take on aurora's `_HostCard`: more padding, a bigger avatar, the
/// theme's own elevated `CardThemeData` doing the soft-shadow work.
class _GcpHostCard extends StatelessWidget {
  const _GcpHostCard({
    required this.host,
    required this.connecting,
    required this.onTap,
    required this.onMore,
    this.selectionMode = false,
    this.selected = false,
  });

  final Host host;
  final bool connecting;
  final VoidCallback onTap;
  final VoidCallback onMore;
  final bool selectionMode;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTap: connecting || selectionMode ? null : onMore,
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: connecting ? null : onTap,
          onLongPress: connecting || selectionMode ? null : onMore,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                selectionMode
                    ? Checkbox(value: selected, onChanged: (_) => onTap())
                    : _hostAvatar(context, host, radius: 22),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        host.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        host.target,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                      if (host.lastConnectedAt != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            _formatLastConnected(host.lastConnectedAt!),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (selectionMode)
                  const SizedBox.shrink()
                else if (connecting)
                  const Padding(
                    padding: EdgeInsets.all(8),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else
                  IconButton(
                    tooltip: 'More',
                    icon: const Icon(Icons.more_vert, size: 20),
                    onPressed: onMore,
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared header chrome — background/stripe/padding/text vary by
// [_HeaderVariant], everything else (chevron, count, rename/delete menu) is
// identical, so all four idioms stay behaviourally in lock-step.
// ---------------------------------------------------------------------------

class _StyledGroupHeader extends StatelessWidget {
  const _StyledGroupHeader({
    required this.section,
    required this.collapsed,
    required this.variant,
    required this.onToggle,
    this.onRename,
    this.onDelete,
    this.selectionMode = false,
    this.selectedHostIds = const <String>{},
    this.onSelectAll,
  });

  final HostSection section;
  final bool collapsed;
  final _HeaderVariant variant;
  final VoidCallback? onToggle;
  final VoidCallback? onRename;
  final VoidCallback? onDelete;

  /// While true, [onSelectAll] is offered as a tristate checkbox in place of
  /// the collapse chevron's usual neighbour — checked when every host in
  /// this section is selected, indeterminate when only some are, and
  /// unchecked when none are.
  final bool selectionMode;
  final Set<String> selectedHostIds;
  final void Function(HostSection section)? onSelectAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final rawName = section.group ?? 'Ungrouped';
    final count = section.hosts.length;

    final EdgeInsets padding;
    final Color? background;
    final Color? leftAccent;
    final TextStyle? titleStyle;
    final double chevronSize;
    final String name;

    switch (variant) {
      case _HeaderVariant.aurora:
        padding = const EdgeInsets.fromLTRB(8, 8, 4, 8);
        background = scheme.surfaceContainerHighest.withValues(alpha: 0.4);
        leftAccent = null;
        chevronSize = 20;
        titleStyle =
            theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700);
        name = rawName;
      case _HeaderVariant.aws:
        // A tight bar with an all-caps label — the resource-list category
        // header feel that idiom's row density (`_AwsHostRow`) carries on.
        padding = const EdgeInsets.fromLTRB(10, 6, 4, 6);
        background = scheme.surfaceContainerHigh;
        leftAccent = null;
        chevronSize = 16;
        titleStyle = theme.textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
          color: scheme.onSurface,
        );
        name = rawName.toUpperCase();
      case _HeaderVariant.gcp:
        // No background band at all — "light section title", room above it
        // rather than a bar to set it apart.
        padding = const EdgeInsets.fromLTRB(4, 26, 4, 10);
        background = null;
        leftAccent = null;
        chevronSize = 20;
        titleStyle =
            theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600);
        name = rawName;
      case _HeaderVariant.azure:
        padding = const EdgeInsets.fromLTRB(0, 10, 8, 10);
        background = null;
        leftAccent = scheme.primary;
        chevronSize = 18;
        titleStyle =
            theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600);
        name = rawName;
    }

    final selectedCount =
        section.hosts.where((h) => selectedHostIds.contains(h.id)).length;

    final row = Row(
      children: [
        if (leftAccent != null) ...[
          Container(
            key: const ValueKey('groupHeaderAccentStripe'),
            width: 3,
            height: 18,
            color: leftAccent,
          ),
          const SizedBox(width: 10),
        ],
        if (selectionMode)
          SizedBox(
            width: 32,
            height: 32,
            child: Checkbox(
              value: selectedCount == 0
                  ? false
                  : selectedCount == section.hosts.length
                      ? true
                      : null, // indeterminate: some, not all, selected
              tristate: true,
              onChanged: (_) => onSelectAll?.call(section),
            ),
          )
        else
          Icon(
            collapsed ? Icons.chevron_right : Icons.expand_more,
            size: chevronSize,
            color: scheme.onSurfaceVariant,
          ),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: titleStyle,
          ),
        ),
        Text(
          '$count',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        _GroupOverflowMenu(onRename: onRename, onDelete: onDelete),
      ],
    );

    final content = Padding(padding: padding, child: row);

    return Material(
      color: background ?? Colors.transparent,
      child: InkWell(onTap: onToggle, child: content),
    );
  }
}

/// The rename/delete overflow menu — identical across every variant, only
/// shown for a named group, never for Ungrouped. A fixed-width blank when
/// there is nothing to show, so the count column stays aligned whether or
/// not a given section has the menu.
class _GroupOverflowMenu extends StatelessWidget {
  const _GroupOverflowMenu({this.onRename, this.onDelete});

  final VoidCallback? onRename;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    if (onRename == null && onDelete == null) {
      return const SizedBox(width: 40);
    }
    return PopupMenuButton<_GroupMenuAction>(
      tooltip: 'Group actions',
      icon: const Icon(Icons.more_vert, size: 20),
      onSelected: (action) => switch (action) {
        _GroupMenuAction.rename => onRename?.call(),
        _GroupMenuAction.delete => onDelete?.call(),
      },
      itemBuilder: (context) => const [
        PopupMenuItem(
          value: _GroupMenuAction.rename,
          child: Text('Rename group'),
        ),
        PopupMenuItem(
          value: _GroupMenuAction.delete,
          child: Text('Delete group'),
        ),
      ],
    );
  }
}

enum _GroupMenuAction { rename, delete }

// ---------------------------------------------------------------------------
// Row/card widgets shared or nearly-shared across variants.
// ---------------------------------------------------------------------------

/// The plain list row aurora (compact/medium), mobile and azure all use.
/// [dense] only tightens the vertical padding — azure's "medium-density"
/// ask — everything else about the row is identical, including the actions
/// it exposes.
class _ListHostRow extends StatelessWidget {
  const _ListHostRow({
    required this.host,
    required this.connecting,
    required this.dense,
    required this.onTap,
    required this.onMore,
    this.selectionMode = false,
    this.selected = false,
  });

  final Host host;
  final bool connecting;
  final bool dense;
  final VoidCallback onTap;
  final VoidCallback onMore;
  final bool selectionMode;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    // ListTile has no onSecondaryTap of its own, so wrap it: on desktop
    // right-click opens the same action sheet long-press opens on touch
    // devices. Behind the tile so the ink and hover effects still come from
    // the tile itself, not a bare GestureDetector — same pattern as
    // file_browser_pane.dart's _EntryTile.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTap: connecting || selectionMode ? null : onMore,
      child: ListTile(
        contentPadding: EdgeInsets.symmetric(
          horizontal: 16,
          vertical: dense ? 6 : 10,
        ),
        leading: selectionMode
            ? Checkbox(value: selected, onChanged: (_) => onTap())
            : _hostAvatar(context, host, radius: 22),
        title: Text(
          host.displayName,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 2),
            Text(host.target),
            if (host.lastConnectedAt != null)
              Text(
                'Last connected '
                '${_formatLastConnected(host.lastConnectedAt!)}',
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        trailing: selectionMode
            ? null
            : connecting
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : IconButton(
                tooltip: 'More',
                icon: const Icon(Icons.more_vert),
                onPressed: onMore,
              ),
        onTap: connecting ? null : onTap,
        onLongPress: connecting || selectionMode ? null : onMore,
      ),
    );
  }
}

/// Aurora's expanded-width grid card. Byte-for-byte the pre-wave-2
/// `_HostCard`.
class _AuroraHostCard extends StatelessWidget {
  const _AuroraHostCard({
    required this.host,
    required this.connecting,
    required this.onTap,
    required this.onMore,
    this.selectionMode = false,
    this.selected = false,
  });

  final Host host;
  final bool connecting;
  final VoidCallback onTap;
  final VoidCallback onMore;
  final bool selectionMode;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTap: connecting || selectionMode ? null : onMore,
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: connecting ? null : onTap,
          onLongPress: connecting || selectionMode ? null : onMore,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                selectionMode
                    ? Checkbox(value: selected, onChanged: (_) => onTap())
                    : _hostAvatar(context, host, radius: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        host.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        host.target,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                      if (host.lastConnectedAt != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            _formatLastConnected(host.lastConnectedAt!),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (selectionMode)
                  const SizedBox.shrink()
                else if (connecting)
                  const Padding(
                    padding: EdgeInsets.all(8),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else
                  IconButton(
                    tooltip: 'More',
                    icon: const Icon(Icons.more_vert, size: 20),
                    onPressed: onMore,
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The leading avatar for a list row or card: the auth-method icon, plus a
/// small badge in the corner for [Host.colorLabel] when it has one. Ported
/// from `host_list_screen.dart`'s pre-wave-2 top-level `_hostAvatar`.
Widget _hostAvatar(
  BuildContext context,
  Host host, {
  required double radius,
}) {
  final theme = Theme.of(context);
  final avatar = CircleAvatar(
    radius: radius,
    backgroundColor: theme.colorScheme.surfaceContainerHigh,
    child: Icon(
      host.authMethod == SshAuthMethod.password ? Icons.password : Icons.key,
      size: radius,
    ),
  );

  if (host.colorLabel == null) return avatar;

  return Stack(
    clipBehavior: Clip.none,
    children: [
      avatar,
      Positioned(
        right: -1,
        bottom: -1,
        // The backdrop is what keeps the badge legible against an avatar
        // background close to it in hue — without it a red tag on top of the
        // (also warm) default avatar background nearly disappears.
        child: Container(
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: theme.colorScheme.surfaceContainerHighest,
          ),
          child: HostColorDot(colorLabel: host.colorLabel, size: radius * 0.64),
        ),
      ),
    ],
  );
}

/// `today at 14:32`, `26 Jul at 14:32` this year, `26 Jul 2024` before that —
/// ported from `host_list_screen.dart`'s pre-wave-2 top-level function of the
/// same name, used by every row/card variant above.
String _formatLastConnected(DateTime time) {
  final local = time.toLocal();
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final now = DateTime.now();
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');

  if (local.year == now.year && local.month == now.month && local.day == now.day) {
    return 'today at $hh:$mm';
  }
  if (local.year == now.year) {
    return '${local.day} ${months[local.month - 1]} at $hh:$mm';
  }
  return '${local.day} ${months[local.month - 1]} ${local.year}';
}
