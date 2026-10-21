import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../services/terminal_search.dart';

/// Searching one terminal: the query, the matches, which one is current, and
/// the highlights that show them.
///
/// Highlights are xterm's own ([TerminalController.highlight]), anchored to
/// the cells they cover, so they stay on the text as new output scrolls it
/// up. While the search is open, new output also re-runs it — at most every
/// [refreshDelay], so a stream of output keeps the count true without a
/// search per line — and the current match stays the one the user was on.
class TerminalFindController extends ChangeNotifier {
  TerminalFindController({
    required this.terminal,
    required this.controller,
    required this.reveal,
    this.bottomRow,
    this.matchColor = const Color(0x66FFD54F),
    this.currentColor = const Color(0xAAFF9100),
    this.refreshDelay = const Duration(milliseconds: 500),
  });

  final Terminal terminal;
  final TerminalController controller;

  /// Scrolls a match into view.
  final void Function(TerminalMatch match) reveal;

  /// The last buffer row on screen, where a new search starts looking from.
  /// Null means the bottom of the buffer.
  final int Function()? bottomRow;

  final Color matchColor;
  final Color currentColor;
  final Duration refreshDelay;

  /// The most matches found and highlighted; past this the count reads
  /// "1000+" and the newest ones are kept.
  static const int limit = 1000;

  bool get isOpen => _open;
  bool _open = false;

  TerminalSearchQuery get query => _query;
  TerminalSearchQuery _query = const TerminalSearchQuery('');

  List<TerminalMatch> get matches => _matches;
  List<TerminalMatch> _matches = const [];

  bool get truncated => _truncated;
  bool _truncated = false;

  /// Index into [matches], or null when there are none.
  int? get current => _current;
  int? _current;

  /// Why the query could not be searched for: a regular expression that
  /// does not compile.
  String? get error => _error;
  String? _error;

  final List<TerminalHighlight> _highlights = [];
  TerminalHighlight? _currentHighlight;
  Timer? _refresh;

  void open() {
    if (_open) return;
    _open = true;
    terminal.addListener(_scheduleRefresh);
    _run(keepPlace: false);
    notifyListeners();
  }

  void close() {
    if (!_open) return;
    _open = false;
    terminal.removeListener(_scheduleRefresh);
    _refresh?.cancel();
    _refresh = null;
    _clearHighlights();
    _matches = const [];
    _current = null;
    _truncated = false;
    notifyListeners();
  }

  set query(TerminalSearchQuery value) {
    if (value == _query) return;
    _query = value;
    if (_open) _run(keepPlace: false);
    notifyListeners();
  }

  void next() => _step(1);
  void previous() => _step(-1);

  void _step(int by) {
    final current = _current;
    if (current == null || _matches.isEmpty) return;
    _current = (current + by) % _matches.length;
    _showCurrent(reveal: true);
    notifyListeners();
  }

  void _scheduleRefresh() {
    if (_refresh != null) return;
    _refresh = Timer(refreshDelay, () {
      _refresh = null;
      if (!_open) return;
      _run(keepPlace: true);
      notifyListeners();
    });
  }

  /// Searches again. With [keepPlace], the current match stays the one the
  /// user was on (its highlight's anchor has followed it as output arrived);
  /// otherwise the newest match on or above [bottomRow] is taken, which is
  /// where the eye already is.
  void _run({required bool keepPlace}) {
    final anchor = _currentHighlight?.p1;
    final previous =
        keepPlace && anchor != null && anchor.attached ? anchor.offset : null;
    _clearHighlights();
    _error = null;
    try {
      final result = searchTerminalBuffer(
        terminal.buffer,
        _query,
        limit: limit,
      );
      _matches = result.matches;
      _truncated = result.truncated;
    } on FormatException catch (e) {
      _matches = const [];
      _truncated = false;
      _error = e.message;
    }
    _current = previous != null
        ? matchNear(_matches, previous)
        : nearestMatchAbove(
            _matches,
            bottomRow?.call() ?? terminal.buffer.height - 1,
          );

    final buffer = terminal.buffer;
    for (final match in _matches) {
      _highlights.add(controller.highlight(
        p1: buffer.createAnchorFromOffset(match.start),
        p2: buffer.createAnchor(match.end.x, match.end.y),
        color: matchColor,
      ));
    }
    // Output arriving does not pull the view away from what is being read.
    _showCurrent(reveal: previous == null);
  }

  void _showCurrent({required bool reveal}) {
    _disposeHighlight(_currentHighlight);
    _currentHighlight = null;
    final index = _current;
    if (index == null) return;
    final match = _matches[index];
    final buffer = terminal.buffer;
    _currentHighlight = controller.highlight(
      p1: buffer.createAnchorFromOffset(match.start),
      p2: buffer.createAnchor(match.end.x, match.end.y),
      color: currentColor,
    );
    if (reveal) this.reveal(match);
  }

  void _clearHighlights() {
    _disposeHighlight(_currentHighlight);
    _currentHighlight = null;
    for (final highlight in _highlights) {
      _disposeHighlight(highlight);
    }
    _highlights.clear();
  }

  /// A highlight's anchors stay in their line's list until disposed
  /// themselves, which would slow every later edit of that line.
  static void _disposeHighlight(TerminalHighlight? highlight) {
    if (highlight == null) return;
    highlight.dispose();
    highlight.p1.dispose();
    highlight.p2.dispose();
  }

  /// "3 of 12", "No results", "1000+".
  String get summary {
    if (_error != null) return 'Invalid pattern';
    if (_query.isEmpty) return '';
    if (_matches.isEmpty) return 'No results';
    final total = '${_matches.length}${_truncated ? '+' : ''}';
    final index = _current;
    return index == null ? total : '${index + 1} of $total';
  }

  @override
  void dispose() {
    if (_open) terminal.removeListener(_scheduleRefresh);
    _refresh?.cancel();
    _clearHighlights();
    super.dispose();
  }
}

/// The find bar over the terminal: the query, how many matched, case and
/// regular-expression toggles, previous / next, and close.
///
/// Enter goes to the next match and Shift+Enter to the previous (F3 and
/// Shift+F3 too); Escape closes. On a narrow screen the toggles move to a
/// second row rather than squeezing the query to nothing.
class TerminalFindBar extends StatefulWidget {
  const TerminalFindBar({
    super.key,
    required this.find,
    required this.onClose,
    this.focusNode,
    this.textController,
    this.touch = false,
  });

  final TerminalFindController find;
  final VoidCallback onClose;

  /// The query field's, so the pane can put the caret back in it.
  final FocusNode? focusNode;
  final TextEditingController? textController;

  /// Touch has been seen: 48dp buttons.
  final bool touch;

  @override
  State<TerminalFindBar> createState() => _TerminalFindBarState();
}

class _TerminalFindBarState extends State<TerminalFindBar> {
  late final FocusNode _ownFocus = FocusNode(debugLabel: 'terminal find');
  late final TextEditingController _ownText = TextEditingController(
    text: widget.find.query.pattern,
  );

  FocusNode get _focus => widget.focusNode ?? _ownFocus;
  TextEditingController get _text => widget.textController ?? _ownText;

  @override
  void initState() {
    super.initState();
    _focus.onKeyEvent = _handleKey;
    widget.find.addListener(_changed);
  }

  @override
  void didUpdateWidget(TerminalFindBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.find != widget.find) {
      oldWidget.find.removeListener(_changed);
      widget.find.addListener(_changed);
    }
    _focus.onKeyEvent = _handleKey;
  }

  @override
  void dispose() {
    widget.find.removeListener(_changed);
    if (_focus.onKeyEvent == _handleKey) _focus.onKeyEvent = null;
    _ownFocus.dispose();
    _ownText.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// Ahead of the text field: Enter would otherwise be "done" and drop the
  /// focus.
  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      widget.onClose();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.f3) {
      shift ? widget.find.previous() : widget.find.next();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _setQuery({String? pattern, bool? caseSensitive, bool? regex}) {
    final query = widget.find.query;
    widget.find.query = TerminalSearchQuery(
      pattern ?? query.pattern,
      caseSensitive: caseSensitive ?? query.caseSensitive,
      regex: regex ?? query.regex,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final find = widget.find;
    final query = find.query;
    final buttonSize = widget.touch ? 48.0 : 36.0;
    final error = find.error != null;

    Widget iconButton({
      required IconData icon,
      required String tooltip,
      required VoidCallback? onPressed,
    }) =>
        IconButton(
          icon: Icon(icon, size: 20),
          tooltip: tooltip,
          onPressed: onPressed,
          constraints: BoxConstraints.tightFor(
            width: buttonSize,
            height: buttonSize,
          ),
          padding: EdgeInsets.zero,
        );

    Widget toggle({
      required String label,
      required String tooltip,
      required bool selected,
      required VoidCallback onPressed,
    }) =>
        Tooltip(
          message: tooltip,
          child: Semantics(
            toggled: selected,
            button: true,
            label: tooltip,
            excludeSemantics: true,
            child: SizedBox(
              width: buttonSize,
              height: buttonSize,
              child: TextButton(
                onPressed: onPressed,
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: Size.zero,
                  backgroundColor: selected
                      ? theme.colorScheme.primary.withValues(alpha: 0.18)
                      : null,
                  foregroundColor: selected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                child: Text(
                  label,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
          ),
        );

    final field = TextField(
      controller: _text,
      focusNode: _focus,
      autofocus: true,
      onChanged: (value) => _setQuery(pattern: value),
      onSubmitted: (_) => find.next(),
      // Keeps the soft keyboard up after its search key.
      onEditingComplete: () {},
      textInputAction: TextInputAction.search,
      autocorrect: false,
      enableSuggestions: false,
      style: const TextStyle(fontSize: 14),
      decoration: InputDecoration(
        isDense: true,
        hintText: 'Find',
        filled: false,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        prefixIcon: const Icon(Icons.search, size: 18),
        prefixIconConstraints:
            const BoxConstraints(minWidth: 32, minHeight: 32),
        contentPadding: const EdgeInsets.symmetric(vertical: 10),
      ),
    );

    final count = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Text(
        find.summary,
        maxLines: 1,
        style: theme.textTheme.bodySmall?.copyWith(
          color: error
              ? theme.colorScheme.error
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );

    final toggles = [
      toggle(
        label: 'Aa',
        tooltip: 'Match case',
        selected: query.caseSensitive,
        onPressed: () => _setQuery(caseSensitive: !query.caseSensitive),
      ),
      toggle(
        label: '.*',
        tooltip: 'Regular expression',
        selected: query.regex,
        onPressed: () => _setQuery(regex: !query.regex),
      ),
    ];
    final hasMatches = find.matches.isNotEmpty;
    final arrows = [
      iconButton(
        icon: Icons.keyboard_arrow_up,
        tooltip: 'Previous match (Shift+Enter)',
        onPressed: hasMatches ? find.previous : null,
      ),
      iconButton(
        icon: Icons.keyboard_arrow_down,
        tooltip: 'Next match (Enter)',
        onPressed: hasMatches ? find.next : null,
      ),
    ];
    final close = iconButton(
      icon: Icons.close,
      tooltip: 'Close (Esc)',
      onPressed: widget.onClose,
    );

    return Material(
      elevation: 3,
      color: theme.colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(10),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < 440;
          if (!narrow) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(
                children: [
                  Expanded(child: field),
                  count,
                  ...toggles,
                  ...arrows,
                  close,
                ],
              ),
            );
          }
          return Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(children: [Expanded(child: field), ...arrows, close]),
                Row(
                  children: [
                    ...toggles,
                    const Spacer(),
                    Flexible(child: count),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
