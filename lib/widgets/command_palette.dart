import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';
import '../services/fuzzy_match.dart';

enum PaletteItemKind { host, snippet, action }

/// One row the palette can show and act on. Built entirely by the caller
/// (`host_list_screen.dart`) — this widget only searches, ranks and
/// displays them, so it has no idea what a "host" or a "snippet" actually
/// is.
class PaletteItem {
  const PaletteItem({
    required this.kind,
    required this.title,
    this.subtitle,
    this.enabled = true,
    this.hint,
    required this.onSelect,
  });

  final PaletteItemKind kind;
  final String title;
  final String? subtitle;

  /// False for the snippet action when no session is open — still shown
  /// (and still reachable by keyboard, so the [hint] is discoverable) but
  /// picking it does nothing.
  final bool enabled;

  /// Shown instead of [subtitle] while [enabled] is false.
  final String? hint;

  final VoidCallback onSelect;
}

IconData _iconFor(PaletteItemKind kind) => switch (kind) {
      PaletteItemKind.host => Icons.dns_outlined,
      PaletteItemKind.snippet => Icons.bolt_outlined,
      PaletteItemKind.action => Icons.arrow_forward_outlined,
    };

/// Opens the command palette over whatever is currently on screen. Ctrl+K /
/// Cmd+K wiring lives in `host_list_screen.dart`, right next to the
/// `Shortcuts`/`Actions` pair that invokes this.
Future<void> showCommandPalette(
  BuildContext context, {
  required List<PaletteItem> items,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (context) => _CommandPaletteDialog(items: items),
  );
}

class _CommandPaletteDialog extends StatefulWidget {
  const _CommandPaletteDialog({required this.items});

  final List<PaletteItem> items;

  @override
  State<_CommandPaletteDialog> createState() => _CommandPaletteDialogState();
}

class _CommandPaletteDialogState extends State<_CommandPaletteDialog> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  List<PaletteItem> _visible = const [];
  int _selected = 0;

  /// One per row position, so the highlighted row can be found and scrolled
  /// to. Keyed by position rather than by item, so a new query reuses them.
  final _rowKeys = <int, GlobalKey>{};

  @override
  void initState() {
    super.initState();
    _visible = widget.items;
    _controller.addListener(_onQueryChanged);
    // A raw, focus-independent hook rather than `Shortcuts`/`Focus.onKeyEvent`
    // bubbling: `EditableText` (which the search field is built on) already
    // binds ArrowUp/ArrowDown/Enter for its own cursor movement and would
    // consume them before an ancestor `Focus` ever saw the event. Listening
    // at the `HardwareKeyboard` level runs regardless of which widget holds
    // focus, so the field can keep typing focus the whole time the list
    // below it is being driven by the arrow keys.
    HardwareKeyboard.instance.addHandler(_handleKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKey);
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onQueryChanged() {
    setState(() {
      _visible = _rank(_controller.text.trim());
      _selected = 0;
    });
    // The highlight is back on the first row, so the list goes back to it.
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
  }

  /// [PaletteItem.title] matches first, then the rest by their subtitle — a
  /// host's `user@host:port`, a snippet's command. An address is often what
  /// someone remembers of a host they named long ago, but a name typed in
  /// full should still find that host above another whose address happens
  /// to contain the same letters.
  List<PaletteItem> _rank(String query) {
    if (query.isEmpty) return widget.items;
    final scored = <(int, FuzzyMatch, int, PaletteItem)>[];
    for (var i = 0; i < widget.items.length; i++) {
      final item = widget.items[i];
      final byTitle = FuzzyMatch.match(query, item.title);
      if (byTitle != null) {
        scored.add((0, byTitle, i, item));
        continue;
      }
      final subtitle = item.subtitle;
      final bySubtitle =
          subtitle == null ? null : FuzzyMatch.match(query, subtitle);
      if (bySubtitle != null) scored.add((1, bySubtitle, i, item));
    }
    scored.sort((a, b) {
      final byField = a.$1.compareTo(b.$1);
      if (byField != 0) return byField;
      final byMatch = a.$2.compareTo(b.$2);
      if (byMatch != 0) return byMatch;
      return a.$3.compareTo(b.$3);
    });
    return [for (final entry in scored) entry.$4];
  }

  bool _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        _move(1);
        return true;
      case LogicalKeyboardKey.arrowUp:
        _move(-1);
        return true;
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        _activateSelected();
        return true;
      case LogicalKeyboardKey.escape:
        Navigator.of(context).maybePop();
        return true;
      default:
        return false;
    }
  }

  void _move(int delta) {
    if (_visible.isEmpty) return;
    setState(() {
      _selected = (_selected + delta) % _visible.length;
      if (_selected < 0) _selected += _visible.length;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealSelected());
  }

  /// Keeps the highlighted row on screen as the arrow keys move it, which
  /// otherwise walked off the bottom of the list and out of sight.
  ///
  /// A row far enough off screen is not built at all — the wrap from the
  /// first row to the last, say — so that one is first scrolled to roughly
  /// where it must be, then revealed exactly once it exists.
  void _revealSelected([int attempts = 3]) {
    if (!mounted) return;
    final row = _rowKeys[_selected]?.currentContext;
    if (row != null) {
      // Each policy scrolls only when the row is past its own edge, so
      // between them a row below the view comes up to its bottom, one above
      // comes down to its top, and one already in view stays where it is.
      for (final policy in const [
        ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        ScrollPositionAlignmentPolicy.keepVisibleAtStart,
      ]) {
        unawaited(Scrollable.ensureVisible(row, alignmentPolicy: policy));
      }
      return;
    }
    if (attempts == 0 || !_scrollController.hasClients) return;
    final position = _scrollController.position;
    final last = _visible.length - 1;
    position.jumpTo(
      last <= 0
          ? position.minScrollExtent
          : position.minScrollExtent +
              (position.maxScrollExtent - position.minScrollExtent) *
                  _selected /
                  last,
    );
    WidgetsBinding.instance
      ..addPostFrameCallback((_) => _revealSelected(attempts - 1))
      // A jump to where the list already was lays nothing out, and would
      // leave the callback waiting on a frame nothing else has asked for.
      ..ensureVisualUpdate();
  }

  void _activateSelected() {
    if (_selected < 0 || _selected >= _visible.length) return;
    _activate(_visible[_selected]);
  }

  void _activate(PaletteItem item) {
    if (!item.enabled) return;
    Navigator.of(context).pop();
    item.onSelect();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      alignment: Alignment.topCenter,
      insetPadding: const EdgeInsets.only(top: 96, left: 24, right: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: TextField(
                controller: _controller,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: context.l10n.paletteHint,
                  prefixIcon: const Icon(Icons.search),
                  border: InputBorder.none,
                ),
                // Redundant with the arrow-key handler's own Enter case:
                // this is the safety net if the raw hook is ever bypassed
                // (a platform where `HardwareKeyboard` events do not reach
                // this handler for some reason), so Enter still works when
                // the field visibly holds focus.
                onSubmitted: (_) => _activateSelected(),
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: _visible.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        context.l10n.paletteNoMatches,
                        style: theme.textTheme.bodyMedium,
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      shrinkWrap: true,
                      itemCount: _visible.length,
                      itemBuilder: (context, index) {
                        final item = _visible[index];
                        final selected = index == _selected;
                        return Material(
                          key: _rowKeys.putIfAbsent(index, GlobalKey.new),
                          color: selected
                              ? theme.colorScheme.primary.withValues(
                                  alpha: 0.16,
                                )
                              : Colors.transparent,
                          child: ListTile(
                            dense: true,
                            leading: Icon(
                              _iconFor(item.kind),
                              size: 20,
                              color: item.enabled
                                  ? null
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                            title: Text(
                              item.title,
                              style: TextStyle(
                                color: item.enabled
                                    ? null
                                    : theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            subtitle: !item.enabled && item.hint != null
                                ? Text(item.hint!)
                                : item.subtitle != null
                                    ? Text(item.subtitle!)
                                    : null,
                            onTap: () => _activate(item),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
