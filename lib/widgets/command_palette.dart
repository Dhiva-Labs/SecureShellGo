import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/fuzzy_match.dart';
import '../theme.dart';

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
      final query = _controller.text.trim();
      _visible = fuzzySort(query, widget.items, (item) => item.title);
      _selected = 0;
    });
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
                decoration: const InputDecoration(
                  hintText: 'Connect to a host, run a snippet, or jump to…',
                  prefixIcon: Icon(Icons.search),
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
                        'No matches',
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
                          color: selected
                              ? AppTheme.accent.withValues(alpha: 0.16)
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
