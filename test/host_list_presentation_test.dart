import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/app_settings.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/services/host_grouping.dart';
import 'package:secure_shell_go/theme.dart';
import 'package:secure_shell_go/widgets/host_color_dot.dart';
import 'package:secure_shell_go/widgets/host_list_presentation.dart';

/// A stand-in for `HostListScreen`'s own state management, so these tests
/// pump only the presentation layer it delegates to — not the full screen,
/// which needs a HostStore/CredentialStore/SshService/SessionManager fleet
/// these tests have no use for, and whose "+" FAB and host-edit menu entry
/// would pull in `HostEditScreen`, which is known to hang `pumpWidget`.
///
/// Mirrors exactly what `_HostListScreenState._buildHostList` does: turns
/// [hosts] + [query] into sections via [HostGrouping.buildSections], and
/// keeps its own collapsed-group set the same way `AppSettings.collapsedGroups`
/// does, so [HostListPresentation] is driven the same way the real screen
/// drives it.
class _Harness extends StatefulWidget {
  const _Harness({
    required this.hosts,
    required this.style,
    required this.width,
    this.query = '',
    this.initialCollapsed = const <String>{},
    this.connectingHostId,
    this.onConnect,
    this.onHostMenu,
    this.onRename,
    this.onDelete,
  });

  final List<Host> hosts;
  final UiStyle style;
  final double width;
  final String query;
  final Set<String> initialCollapsed;
  final String? connectingHostId;
  final ValueChanged<Host>? onConnect;
  final ValueChanged<Host>? onHostMenu;
  final ValueChanged<String>? onRename;
  final ValueChanged<String>? onDelete;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final Set<String> _collapsed = {};

  @override
  void initState() {
    super.initState();
    _collapsed.addAll(widget.initialCollapsed);
  }

  @override
  Widget build(BuildContext context) {
    final sections = HostGrouping.buildSections(widget.hosts, query: widget.query);
    final searching = widget.query.trim().isNotEmpty;

    return MaterialApp(
      theme: AppTheme.themeFor(widget.style, Brightness.dark),
      home: Scaffold(
        body: CustomScrollView(
          slivers: HostListPresentation.buildSectionSlivers(
            sections: sections,
            style: widget.style,
            width: widget.width,
            searching: searching,
            isCollapsed: (s) =>
                !searching && _collapsed.contains(s.settingsKey),
            connectingHostId: widget.connectingHostId,
            actions: HostListActions(
              onToggleSection: (s) => setState(() {
                if (!_collapsed.remove(s.settingsKey)) {
                  _collapsed.add(s.settingsKey);
                }
              }),
              onRenameGroup: (g) => widget.onRename?.call(g),
              onDeleteGroup: (g) => widget.onDelete?.call(g),
              onConnect: (h) => widget.onConnect?.call(h),
              onHostMenu: (h) => widget.onHostMenu?.call(h),
            ),
          ),
        ),
      ),
    );
  }
}

void main() {
  Host host(
    String id, {
    String label = '',
    String? group,
    DateTime? lastConnectedAt,
    HostColorLabel? colorLabel,
  }) {
    return Host(
      id: id,
      label: label,
      hostname: '$id.example.com',
      port: 22,
      username: 'dev',
      authMethod: SshAuthMethod.password,
      group: group,
      lastConnectedAt: lastConnectedAt,
      colorLabel: colorLabel,
    );
  }

  // A desktop-width window (>= WindowSizeClass.expandedBreakpoint) so every
  // style's own idiom — not the shared mobile fallback — is what renders.
  const desktopWidth = 1000.0;
  const mediumWidth = 700.0;
  const mobileWidth = 400.0;

  final twoHosts = [
    host('a', label: 'Alpha box', group: 'Work'),
    host('b', label: 'Beta box', group: 'Work'),
  ];

  group('every style renders a group header, its hosts and the count', () {
    for (final style in UiStyle.values) {
      testWidgets(style.name, (tester) async {
        await tester.pumpWidget(
          _Harness(hosts: twoHosts, style: style, width: desktopWidth),
        );
        await tester.pumpAndSettle();

        // aws is the one variant that renders the group name upper-cased —
        // its own "tight bar" console idiom, see `_StyledGroupHeader`.
        final expectedName = style == UiStyle.aws ? 'WORK' : 'Work';
        expect(find.text(expectedName), findsOneWidget);
        expect(find.text('2'), findsOneWidget);
        expect(find.textContaining('Alpha box'), findsOneWidget);
        expect(find.textContaining('Beta box'), findsOneWidget);
      });
    }
  });

  group('desktop structural idiom by style', () {
    testWidgets('aurora: a 2-column fixed grid at expanded width', (
      tester,
    ) async {
      await tester.pumpWidget(
        _Harness(hosts: twoHosts, style: UiStyle.aurora, width: desktopWidth),
      );
      await tester.pumpAndSettle();

      expect(find.byType(SliverGrid), findsOneWidget);
      expect(find.byType(Card), findsWidgets);
      final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
      expect(
        grid.gridDelegate,
        isA<SliverGridDelegateWithFixedCrossAxisCount>(),
      );
    });

    testWidgets('aurora: the plain list at medium width — "responsive" means '
        'this, not just the grid', (tester) async {
      await tester.pumpWidget(
        _Harness(hosts: twoHosts, style: UiStyle.aurora, width: mediumWidth),
      );
      await tester.pumpAndSettle();

      expect(find.byType(SliverGrid), findsNothing);
      expect(find.byType(ListTile), findsWidgets);
    });

    testWidgets('aws: a dense table with hairline separators, no grid, no '
        'cards', (tester) async {
      await tester.pumpWidget(
        _Harness(hosts: twoHosts, style: UiStyle.aws, width: desktopWidth),
      );
      await tester.pumpAndSettle();

      expect(find.byType(SliverGrid), findsNothing);
      expect(find.byType(Card), findsNothing);
      expect(find.byType(ListTile), findsNothing);
      expect(find.byType(Divider), findsWidgets);
    });

    testWidgets('gcp: an airy responsive card grid, distinct delegate from '
        "aurora's fixed 2-column one", (tester) async {
      await tester.pumpWidget(
        _Harness(hosts: twoHosts, style: UiStyle.gcp, width: desktopWidth),
      );
      await tester.pumpAndSettle();

      expect(find.byType(SliverGrid), findsOneWidget);
      expect(find.byType(Card), findsWidgets);
      final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
      expect(
        grid.gridDelegate,
        isA<SliverGridDelegateWithMaxCrossAxisExtent>(),
      );
    });

    testWidgets('azure: a flat list (no grid, no cards) with a left accent '
        'stripe on the group header', (tester) async {
      await tester.pumpWidget(
        _Harness(hosts: twoHosts, style: UiStyle.azure, width: desktopWidth),
      );
      await tester.pumpAndSettle();

      expect(find.byType(SliverGrid), findsNothing);
      expect(find.byType(Card), findsNothing);
      expect(find.byType(ListTile), findsWidgets);
      expect(find.byKey(const ValueKey('groupHeaderAccentStripe')), findsOneWidget);
    });
  });

  testWidgets(
    'the mobile presentation is chosen below the desktop breakpoint '
    'regardless of style',
    (tester) async {
      for (final style in UiStyle.values) {
        await tester.pumpWidget(
          _Harness(hosts: twoHosts, style: style, width: mobileWidth),
        );
        await tester.pumpAndSettle();

        // Always the plain one-column list: no grid, no table, no elevated
        // card, whichever UiStyle is active.
        expect(find.byType(SliverGrid), findsNothing, reason: style.name);
        expect(find.byType(Card), findsNothing, reason: style.name);
        expect(find.byType(ListTile), findsWidgets, reason: style.name);
        // No accent stripe either — that is desktop-only azure chrome.
        expect(
          find.byKey(const ValueKey('groupHeaderAccentStripe')),
          findsNothing,
          reason: style.name,
        );
      }
    },
  );

  group('collapse/expand', () {
    testWidgets('tapping the header hides and re-shows its hosts (aurora)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _Harness(hosts: twoHosts, style: UiStyle.aurora, width: desktopWidth),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Alpha box'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.expand_more));
      await tester.pumpAndSettle();
      expect(find.textContaining('Alpha box'), findsNothing);

      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pumpAndSettle();
      expect(find.textContaining('Alpha box'), findsOneWidget);
    });

    testWidgets('tapping the header hides and re-shows its hosts (aws '
        "table)", (tester) async {
      await tester.pumpWidget(
        _Harness(hosts: twoHosts, style: UiStyle.aws, width: desktopWidth),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Alpha box'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.expand_more));
      await tester.pumpAndSettle();
      expect(find.textContaining('Alpha box'), findsNothing);
    });
  });

  testWidgets(
    'search filtering reduces the rendered hosts and force-expands a '
    'previously-collapsed matching section',
    (tester) async {
      await tester.pumpWidget(
        _Harness(
          hosts: twoHosts,
          style: UiStyle.aurora,
          width: desktopWidth,
          query: 'alpha',
          initialCollapsed: const {'Work'},
        ),
      );
      await tester.pumpAndSettle();

      // Collapsed in AppSettings, but a live search always shows a match.
      expect(find.textContaining('Alpha box'), findsOneWidget);
      expect(find.textContaining('Beta box'), findsNothing);
      // Filtered, not the whole-group count — one host matched, one shows.
      expect(find.text('1'), findsOneWidget);
    },
  );

  testWidgets('the host menu still opens, for every style', (tester) async {
    for (final style in UiStyle.values) {
      Host? tapped;
      await tester.pumpWidget(
        _Harness(
          hosts: [host('solo', label: 'Solo box', group: 'Work')],
          style: style,
          width: desktopWidth,
          onHostMenu: (h) => tapped = h,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();

      expect(tapped?.id, 'solo', reason: style.name);
    }
  });

  testWidgets('connect-on-tap fires onConnect, for every style', (
    tester,
  ) async {
    for (final style in UiStyle.values) {
      Host? tapped;
      await tester.pumpWidget(
        _Harness(
          hosts: [host('solo', label: 'Solo box', group: 'Work')],
          style: style,
          width: desktopWidth,
          onConnect: (h) => tapped = h,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.textContaining('Solo box'));
      await tester.pumpAndSettle();

      expect(tapped?.id, 'solo', reason: style.name);
    }
  });

  testWidgets(
    'a connecting host shows its own loading state instead of the more '
    'button',
    (tester) async {
      await tester.pumpWidget(
        _Harness(
          hosts: [host('solo', label: 'Solo box', group: 'Work')],
          style: UiStyle.aws,
          width: desktopWidth,
          connectingHostId: 'solo',
        ),
      );
      // Not pumpAndSettle: an indeterminate CircularProgressIndicator
      // animates forever, so settling would time out waiting for it to stop.
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byTooltip('More'), findsNothing);
    },
  );

  group('the group header overflow menu', () {
    testWidgets('renames a named group but has nothing for Ungrouped', (
      tester,
    ) async {
      String? renamed;
      await tester.pumpWidget(
        _Harness(
          hosts: [
            host('a', label: 'Alpha box', group: 'Work'),
            host('b', label: 'Beta box'), // Ungrouped
          ],
          style: UiStyle.gcp,
          width: desktopWidth,
          onRename: (g) => renamed = g,
        ),
      );
      await tester.pumpAndSettle();

      // Named "Work" gets the overflow menu; the trailing Ungrouped section
      // does not.
      expect(find.byTooltip('Group actions'), findsOneWidget);

      await tester.tap(find.byTooltip('Group actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename group'));
      await tester.pumpAndSettle();

      expect(renamed, 'Work');
    });

    testWidgets('deletes a named group, on the azure variant', (
      tester,
    ) async {
      String? deleted;
      await tester.pumpWidget(
        _Harness(
          hosts: [host('a', label: 'Alpha box', group: 'Work')],
          style: UiStyle.azure,
          width: desktopWidth,
          onDelete: (g) => deleted = g,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Group actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete group'));
      await tester.pumpAndSettle();

      expect(deleted, 'Work');
    });
  });

  testWidgets('colour tags still render for a host that has one', (
    tester,
  ) async {
    await tester.pumpWidget(
      _Harness(
        hosts: [
          host(
            'a',
            label: 'Alpha box',
            group: 'Work',
            colorLabel: HostColorLabel.teal,
          ),
        ],
        style: UiStyle.aws,
        width: desktopWidth,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(HostColorDot), findsOneWidget);
  });
}
