import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:xterm/xterm.dart';

import '../l10n/l10n.dart';
import '../models/app_settings.dart';
import '../services/clipboard_paste.dart';
import '../services/input_profile.dart';
import '../services/session_controller.dart';
import '../services/session_recorder.dart';
import '../services/settings_store.dart';
import '../services/terminal_links.dart';
import '../services/terminal_search.dart';
import '../theme.dart';
import '../widgets/session_log_actions.dart';
import '../widgets/session_shortcuts.dart';
import '../widgets/terminal_cursor.dart';
import '../widgets/terminal_find_bar.dart';
import '../widgets/terminal_fonts.dart';
import '../widgets/terminal_key_bar.dart';

/// The interactive shell, as a *view on* a session rather than an owner of one.
///
/// Phase 1's `TerminalScreen` owned the connection and closed it in
/// `dispose()`. Phase 3 moved the transport to [SessionController]; Phase 12
/// moved the `Terminal` — the scrollback and cursor themselves — there too,
/// because a session now outlives the screen showing it and a buffer owned by
/// a `State` does not. What is left here is genuinely a view: the font, the
/// theme, the cursor, selection, the extra-key bar, zoom, the clipboard,
/// find, and links.
class TerminalPane extends StatefulWidget {
  const TerminalPane({
    super.key,
    required this.session,
    required this.settingsStore,
    this.focusNode,
    this.autofocus = true,
    this.openLink,
  });

  /// Opens the find bar over [session]'s terminal — the session menu's
  /// "Find in terminal", for a touch screen with no Ctrl+Shift+F. False when
  /// no pane is showing that session.
  static bool showFind(SessionController session) {
    final pane = _panes[session];
    if (pane == null || !pane.mounted) return false;
    pane._openFind();
    return true;
  }

  final SessionController session;

  /// Where the font size and colour scheme come from, and where a pinch-zoom
  /// is persisted back to.
  final SettingsStore settingsStore;

  /// The terminal's keyboard focus, supplied from outside when several
  /// sessions are open at once.
  ///
  /// All of them are in the widget tree together (that is what keeps a
  /// background `htop` running), so their `TerminalView`s are all live and all
  /// focusable. The session screen owns the node so that bringing a tab to the
  /// front can put the caret back in *that* terminal — otherwise the keystroke
  /// after a tab switch goes wherever the focus happened to be left.
  final FocusNode? focusNode;

  /// Whether to take focus on first build. False for a session opened behind
  /// another, which must not steal the keyboard from the one in front.
  final bool autofocus;

  /// Opens a link from the terminal in the browser. Test seam; the default
  /// is the platform's own handler. Only ever handed an `http`/`https`
  /// address — see [TerminalLinks].
  final Future<bool> Function(Uri uri)? openLink;

  @override
  State<TerminalPane> createState() => _TerminalPaneState();
}

/// The pane showing each session, for [TerminalPane.showFind].
final Expando<_TerminalPaneState> _panes = Expando('terminal panes');

class _TerminalPaneState extends State<TerminalPane>
    with AutomaticKeepAliveClientMixin, SingleTickerProviderStateMixin {
  final TerminalController _terminalController = TerminalController();

  /// For what xterm knows about where things are on screen: the cursor's
  /// rectangle, the cell under a pointer, the height of a line.
  final GlobalKey<TerminalViewState> _viewKey = GlobalKey();

  /// The terminal's scroll position, to bring a find match into view and to
  /// keep the cursor drawn in the right place while scrolling.
  final ScrollController _scrollController = ScrollController();

  /// The terminal's focus when the screen did not supply one. The cursor
  /// needs to know whether the terminal has the keyboard, so there is always
  /// a node this pane can see.
  FocusNode? _ownFocusNode;
  FocusNode get _focusNode =>
      widget.focusNode ?? (_ownFocusNode ??= FocusNode(debugLabel: 'terminal'));

  RecordingTerminal get _terminal => widget.session.terminal;

  /// Live text style, seeded from Settings and updated by pinch-zoom. Kept
  /// local (rather than re-reading `settingsStore.current` on every build) so
  /// the terminal does not jump mid-gesture if something else touched the
  /// store, and so the pinch preview is immediate.
  late double _fontSize;
  late TerminalColorScheme _colorScheme;

  /// When the extra-keys row shows; followed live, so changing it in
  /// Settings takes effect on a session that is already open. So are the
  /// cursor, the bell and the typeface.
  late KeyBarMode _keyBarMode;
  late TerminalCursorStyle _cursorStyle;
  late bool _cursorBlink;
  late TerminalBell _bell;
  late TerminalFont _font;
  StreamSubscription<AppSettings>? _settingsChanges;

  /// Built once per size and typeface: xterm has no equality on
  /// [TerminalStyle], and a new one re-measures and re-lays out every glyph.
  TerminalStyle? _textStyleMemo;

  /// The visual bell's flash.
  late final AnimationController _bellFlash = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

  /// Running for [_bellInterval] after the bell rings, when it does not ring
  /// again: a burst of bells (`cat` of a binary file, `yes $'\a'`) is a
  /// vibration or a flash every so often, not one long buzz.
  Timer? _bellQuiet;
  static const Duration _bellInterval = Duration(milliseconds: 250);

  late final TerminalFindController _find = TerminalFindController(
    terminal: _terminal,
    controller: _terminalController,
    reveal: _reveal,
    bottomRow: _bottomVisibleRow,
  );
  final FocusNode _findFocus = FocusNode(debugLabel: 'terminal find');
  final TextEditingController _findText = TextEditingController();

  StreamSubscription<SessionRecorder>? _recordingChanges;

  /// The link under a mouse with Ctrl held, highlighted, and shown with a
  /// hand cursor.
  TerminalHighlight? _hoverHighlight;
  TerminalLinkHit? _hoverLink;

  /// A finger held still on the terminal: on a link, that opens the link
  /// menu rather than selecting text. See [_onLinkPointerDown].
  Timer? _longPressTimer;
  int? _longPressPointer;
  Offset? _longPressStart;

  /// Fingers on the terminal now. Two is a pinch, never a long-press.
  final Set<int> _linkPointers = {};

  /// Where the primary mouse button went down, for Ctrl+click. Watched here
  /// because xterm 4.0.0 never calls `TerminalView.onTapUp`: its gesture
  /// detector keeps the callback and calls only one TerminalView leaves
  /// unset.
  int? _clickPointer;
  Offset? _clickStart;

  /// Sticky Ctrl: armed by the extra-keys bar, consumed by the next
  /// keystroke that reaches [_sendToShell] — soft keyboard, hardware
  /// keyboard, or a key-bar character button all funnel through there.
  ///
  /// Only while the bar is on screen to show it armed: [build] disarms it
  /// whenever the bar is not shown, or the next key typed after the bar went
  /// away would reach the shell as a control code with nothing to say why.
  bool _ctrlSticky = false;

  /// The buttons held at the last pointer down on the terminal. xterm hands
  /// a middle-button tap to the same callback as a right-button one, and a
  /// middle click is a paste on Linux, not a request for a menu.
  int _lastDownButtons = 0;

  /// Pointer ids currently down, for the hand-rolled two-finger pinch — see
  /// [_onPointerMove]. Deliberately not a `GestureDetector`/`ScaleGestureRecognizer`:
  /// that would enter the gesture arena against the terminal's own internal
  /// drag recognizer (used for text selection) and risk breaking it. Raw
  /// pointer events are delivered to every widget in the hit-test chain
  /// regardless of who wins the arena, so this never competes for the
  /// gesture — it just watches.
  final Map<int, Offset> _activePointers = {};
  double? _pinchStartDistance;
  double? _pinchStartFontSize;

  /// Mirrors `_terminalController.selection != null`, kept as its own field
  /// so the selection toolbar's slide-in only rebuilds on the edges (empty →
  /// non-empty and back) rather than on every selection-extend notification.
  bool _hasSelection = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();

    final settings = widget.settingsStore.current;
    _fontSize = settings.terminalFontSize;
    _colorScheme = settings.colorScheme;
    _keyBarMode = settings.keyBarMode;
    _cursorStyle = settings.cursorStyle;
    _cursorBlink = settings.cursorBlink;
    _bell = settings.bell;
    _font = settings.terminalFont;
    _settingsChanges = widget.settingsStore.changes.listen(_followSettings);

    _panes[widget.session] = this;
    _find.addListener(_handleFindChange);
    _recordingChanges = _terminal.recordingChanges.listen(_handleRecording);
    _terminalController.addListener(_handleSelectionChange);
    // The buffer belongs to the session and may already be full of a shell
    // this pane never opened; asking for it again is a no-op.
    widget.session.onBell = _handleBell;
    widget.session.transformInput = _applySticky;
    unawaited(widget.session.ensureShell());
    // A log that stopped by itself while this session was not on screen.
    if (_terminal.unannounced.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        for (final ending in _terminal.unannounced) {
          unawaited(SessionLogActions.announce(context, _terminal, ending));
        }
      });
    }
  }

  void _followSettings(AppSettings settings) {
    if (!mounted) return;
    if (settings.keyBarMode == _keyBarMode &&
        settings.cursorStyle == _cursorStyle &&
        settings.cursorBlink == _cursorBlink &&
        settings.bell == _bell &&
        settings.terminalFont == _font) {
      return;
    }
    setState(() {
      _keyBarMode = settings.keyBarMode;
      _cursorStyle = settings.cursorStyle;
      _cursorBlink = settings.cursorBlink;
      _bell = settings.bell;
      _font = settings.terminalFont;
    });
  }

  /// Settings > Terminal > Bell.
  void _handleBell() {
    if (!mounted || _bellQuiet != null) return;
    _bellQuiet = Timer(_bellInterval, () => _bellQuiet = null);
    switch (_bell) {
      case TerminalBell.vibrate:
        Feedback.forLongPress(context);
      case TerminalBell.visual:
        unawaited(_bellFlash.forward(from: 0));
      case TerminalBell.off:
        break;
    }
  }

  TerminalStyle get _textStyle {
    final family = TerminalFonts.familyFor(_font);
    final memo = _textStyleMemo;
    if (memo != null && memo.fontSize == _fontSize && memo.fontFamily == family) {
      return memo;
    }
    return _textStyleMemo = TerminalStyle(
      fontSize: _fontSize,
      fontFamily: family,
      fontFamilyFallback: TerminalFonts.fallbackFor(_font),
    );
  }

  /// xterm's own cursor is drawn transparent (see [TerminalCursorOverlay]);
  /// the shape is passed on anyway so the two never disagree.
  TerminalCursorType get _xtermCursorType => switch (_cursorStyle) {
        TerminalCursorStyle.block => TerminalCursorType.block,
        TerminalCursorStyle.underline => TerminalCursorType.underline,
        TerminalCursorStyle.bar => TerminalCursorType.verticalBar,
      };

  void _handleSelectionChange() {
    final selected = _terminalController.selection != null;
    if (selected != _hasSelection) setState(() => _hasSelection = selected);
  }

  /// Applies a sticky Ctrl to what the key bar or the soft keyboard produced.
  ///
  /// The session writes to the shell; this only decides what the keystroke
  /// *is*, which is a property of the on-screen modifier and so belongs here.
  String _applySticky(String data) {
    if (!_ctrlSticky) return data;
    final payload = _asCtrlCode(data) ?? data;
    // Sticky-once: armed by one tap on "Ctrl", consumed by the very next
    // keystroke, exactly like a physical sticky-modifier key.
    if (mounted) setState(() => _ctrlSticky = false);
    return payload;
  }

  /// Maps a single typed character to its control code (`a`-`z` → 1-26,
  /// `[`\`]^_` → 27-31), the same table `Terminal.charInput(ctrl: true)` uses
  /// internally. Anything else (a whole pasted string, a non-Latin key) is
  /// left alone rather than mangled.
  static String? _asCtrlCode(String data) {
    if (data.length != 1) return null;
    final lower = data.toLowerCase().codeUnitAt(0);
    if (lower >= 0x61 && lower <= 0x7a) {
      return String.fromCharCode(lower - 0x61 + 1);
    }
    final code = data.codeUnitAt(0);
    if (code >= 0x5b && code <= 0x5f) {
      return String.fromCharCode(code - 0x5b + 27);
    }
    return null;
  }

  void _toggleCtrlSticky() => setState(() => _ctrlSticky = !_ctrlSticky);

  // ------------------------------------------------------ clipboard actions

  /// Copies the current selection, with the haptic tick + brief confirmation
  /// the task asked for, then clears the selection — matching how a copy
  /// ends on every other platform.
  Future<void> _copySelection() async {
    final range = _terminalController.selection;
    if (range == null) return;

    final text = _terminal.buffer.getText(range);
    await Clipboard.setData(ClipboardData(text: text));
    HapticFeedback.lightImpact();
    _terminalController.clearSelection();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(context.l10n.terminalCopied),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  /// Extends the current selection to the whole scrollback — the same range
  /// xterm's own (now-disabled, see [_shortcuts]) Ctrl+A shortcut used to
  /// select, offered here as a toolbar button instead so the shell keeps
  /// Ctrl+A for "beginning of line".
  void _selectAll() {
    final buffer = _terminal.buffer;
    _terminalController.setSelection(
      buffer.createAnchor(0, buffer.height - _terminal.viewHeight),
      buffer.createAnchor(_terminal.viewWidth, buffer.height - 1),
      mode: SelectionMode.line,
    );
  }

  /// Reads the system clipboard and sends it to the shell as one write —
  /// after a confirmation sheet if it looks like more than one command.
  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) {
      if (mounted) _snack(context.l10n.terminalClipboardEmpty);
      return;
    }

    if (ClipboardPaste.needsConfirmation(text)) {
      final confirmed = await _confirmMultilinePaste(text);
      if (!confirmed || !mounted) return;
    }

    _terminalController.clearSelection();
    // `Terminal.paste` sends the text in one shot — wrapped in
    // bracketed-paste escapes if (and only if) the remote program declared
    // it supports them, otherwise identical to `textInput`. Either way it is
    // a single write, as asked for; no bracketed-paste handling to build
    // ourselves.
    _terminal.paste(text);
  }

  /// "Paste 3 lines?" — running several unseen commands back to back is the
  /// classic terminal footgun, so a multi-line clip gets a confirmation
  /// instead of running straight away. [ClipboardPaste] decides what counts
  /// as multi-line; it is unit-tested on its own in `clipboard_paste_test`.
  Future<bool> _confirmMultilinePaste(String text) async {
    final lines = ClipboardPaste.lineCount(text);
    final result = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.l10n.terminalPasteLinesTitle(lines),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                context.l10n.terminalPasteLinesBody,
                style: const TextStyle(height: 1.35),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: Text(
                        MaterialLocalizations.of(context).cancelButtonLabel,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      child: Text(context.l10n.terminalPaste),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    return result ?? false;
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// Fully replaces xterm's built-in shortcut map (see [_shortcuts] for why)
  /// rather than layering on top of it — [_handleHardwareKeyEvent] is the one
  /// place hardware-keyboard copy/paste is decided.
  static const Map<ShortcutActivator, Intent> _shortcuts = {};

  /// Intercepts Ctrl+Shift+C / Ctrl+Shift+V from a physical keyboard for
  /// copy/paste, the standard terminal-emulator convention precisely because
  /// plain Ctrl+C and Ctrl+V already mean something to the shell (SIGINT, and
  /// — in `vim`/readline — visual-block/literal-insert respectively).
  ///
  /// xterm 4.x ships default shortcuts of its own (`defaultTerminalShortcuts`
  /// in the package) that would otherwise steal plain Ctrl+V for paste and
  /// Ctrl+A for "select all" — the second of those is bash's "beginning of
  /// line", used constantly. [TerminalView.shortcuts] is overridden to the
  /// empty [_shortcuts] map above specifically to disable that, so every key
  /// this handler does not claim falls straight through to the terminal's
  /// normal input handling and reaches the shell untouched.
  ///
  /// The session screen's own chords (new session, next tab — see
  /// `session_shortcuts.dart`) are taken out first, for the same reason: the
  /// terminal would otherwise send every one of them to the shell.
  KeyEventResult _handleHardwareKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) {
      if (_hoverLink != null && !_linkModifierHeld) _clearHoverLink();
      return KeyEventResult.ignored;
    }

    final shortcut = SessionShortcuts.dispatch(context, event);
    if (shortcut != KeyEventResult.ignored) return shortcut;

    if (_handleZoomKey(event)) return KeyEventResult.handled;

    final keys = HardwareKeyboard.instance;
    // Ctrl+_ — Ctrl+Shift+- on most layouts — is undo in readline and
    // Emacs. xterm sends nothing for it: its Ctrl table is the letters, and
    // only without Shift.
    if (keys.isControlPressed &&
        !keys.isAltPressed &&
        (event.logicalKey == LogicalKeyboardKey.underscore ||
            (keys.isShiftPressed &&
                event.logicalKey == LogicalKeyboardKey.minus))) {
      _terminal.textInput('\x1f');
      return KeyEventResult.handled;
    }

    if (!keys.isControlPressed || !keys.isShiftPressed) {
      return KeyEventResult.ignored;
    }

    if (event.logicalKey == LogicalKeyboardKey.keyF) {
      _openFind();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyC) {
      unawaited(_copySelection());
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyV) {
      unawaited(_pasteFromClipboard());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ---------------------------------------------------------- context menu

  /// Right-click, where a mouse is in use: the selection toolbar's three
  /// actions, at the pointer, the way every desktop terminal offers them —
  /// with Open and Copy link first when the click was on an address, and
  /// Find after. Touch keeps the toolbar that slides in under a long-press
  /// selection.
  Future<void> _showContextMenu(TapUpDetails details, CellOffset _) async {
    if (_lastDownButtons & kSecondaryMouseButton == 0) return;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final at = overlay.globalToLocal(details.globalPosition);
    final keyboard = InputProfile.of(context).keyboard;
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final link = _linkAtGlobal(details.globalPosition);

    PopupMenuItem<_TerminalMenu> item(
      _TerminalMenu value,
      String label,
      IconData icon, {
      String? keys,
      bool enabled = true,
    }) {
      return PopupMenuItem<_TerminalMenu>(
        value: value,
        enabled: enabled,
        child: Row(
          children: [
            Icon(icon, size: 18),
            const SizedBox(width: 12),
            Expanded(child: Text(label)),
            if (keyboard && keys != null) ...[
              const SizedBox(width: 24),
              Text(
                keys,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      );
    }

    final choice = await showMenu<_TerminalMenu>(
      context: context,
      position: RelativeRect.fromRect(
        at & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: [
        if (link != null) ...[
          item(_TerminalMenu.openLink, l10n.terminalOpenLink, Icons.open_in_new,
              keys: _linkClickKeys),
          item(_TerminalMenu.copyLink, l10n.terminalCopyLink, Icons.link),
          const PopupMenuDivider(),
        ],
        item(_TerminalMenu.copy, l10n.terminalCopy, Icons.copy,
            keys: 'Ctrl+Shift+C', enabled: _hasSelection),
        item(_TerminalMenu.paste, l10n.terminalPaste, Icons.content_paste,
            keys: 'Ctrl+Shift+V'),
        item(_TerminalMenu.selectAll, l10n.terminalSelectAll, Icons.select_all),
        const PopupMenuDivider(),
        item(_TerminalMenu.find, l10n.terminalFindMenu, Icons.search,
            keys: 'Ctrl+Shift+F'),
      ],
    );
    switch (choice) {
      case _TerminalMenu.openLink:
        await _openLink(link!);
      case _TerminalMenu.copyLink:
        await _copyLink(link!);
      case _TerminalMenu.copy:
        await _copySelection();
      case _TerminalMenu.paste:
        await _pasteFromClipboard();
      case _TerminalMenu.selectAll:
        _selectAll();
      case _TerminalMenu.find:
        _openFind();
      case null:
        break;
    }
  }

  // ----------------------------------------------------------------- links

  /// The link under [global], a position on screen, if there is one.
  TerminalLinkHit? _linkAtGlobal(Offset global) {
    final cell = _cellAtGlobal(global);
    if (cell == null) return null;
    return TerminalLinks.inBuffer(_terminal.buffer, cell);
  }

  /// The buffer cell under [global], or null over the padding, below the
  /// last line, or before the terminal has been laid out.
  CellOffset? _cellAtGlobal(Offset global) {
    final view = _viewKey.currentState;
    if (view == null || !view.mounted) return null;
    try {
      final render = view.renderTerminal;
      final local = render.globalToLocal(global);
      final cell = render.getCellOffset(local);
      final cellRect = render.getOffset(cell) & render.cellSize;
      return cellRect.contains(local) ? cell : null;
    } catch (_) {
      return null;
    }
  }

  /// Ctrl, or ⌘ on a Mac — the modifier that turns a click into "follow".
  ///
  /// With Shift as well while the program has asked for the mouse (tmux or
  /// vim with mouse mode on): xterm already sends it every click, Ctrl+click
  /// included, and a click meant for tmux must not also open a browser.
  bool get _linkModifierHeld {
    final keys = HardwareKeyboard.instance;
    final held = keys.isControlPressed ||
        (defaultTargetPlatform == TargetPlatform.macOS && keys.isMetaPressed);
    if (_terminal.mouseMode == MouseMode.none) return held;
    return held && keys.isShiftPressed;
  }

  /// What to hold to open a link with a click, for the context menu.
  String get _linkClickKeys => _terminal.mouseMode == MouseMode.none
      ? 'Ctrl+click'
      : 'Ctrl+Shift+click';

  /// With Ctrl held, a link under the mouse is highlighted and the pointer
  /// becomes a hand, so it is clear before clicking what Ctrl+click will do.
  void _onLinkPointerHover(PointerHoverEvent event) {
    final link = _linkModifierHeld ? _linkAtGlobal(event.position) : null;
    if (link?.begin == _hoverLink?.begin && link?.end == _hoverLink?.end) {
      return;
    }
    _clearHoverLink(notify: false);
    if (link != null) {
      final buffer = _terminal.buffer;
      _hoverHighlight = _terminalController.highlight(
        p1: buffer.createAnchorFromOffset(link.begin),
        p2: buffer.createAnchor(link.end.x, link.end.y),
        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.28),
      );
    }
    setState(() => _hoverLink = link);
  }

  void _clearHoverLink({bool notify = true}) {
    final highlight = _hoverHighlight;
    _hoverHighlight = null;
    if (highlight != null) {
      highlight.dispose();
      highlight.p1.dispose();
      highlight.p2.dispose();
    }
    if (_hoverLink == null) return;
    if (notify && mounted) {
      setState(() => _hoverLink = null);
    } else {
      _hoverLink = null;
    }
  }

  /// A mouse button going down may be the start of a Ctrl+click. A finger
  /// held still on a link opens a menu for it, the way a browser does,
  /// instead of selecting the word under it; off a link, a long-press selects
  /// text exactly as before — this only watches for the hold.
  void _onLinkPointerDown(PointerDownEvent event) {
    _cancelLongPress();
    _linkPointers.add(event.pointer);
    if (event.kind == PointerDeviceKind.mouse) {
      final primary = event.buttons & kPrimaryMouseButton != 0;
      _clickPointer = primary ? event.pointer : null;
      _clickStart = event.position;
      return;
    }
    if (_linkPointers.length > 1) return;
    _longPressPointer = event.pointer;
    _longPressStart = event.position;
    final at = event.position;
    _longPressTimer = Timer(kLongPressTimeout, () {
      _longPressTimer = null;
      _longPressPointer = null;
      final link = _linkAtGlobal(at);
      if (link == null || !mounted) return;
      // xterm selects the word under a long-press at the same moment; this
      // menu is instead of that, so the selection goes once it has landed.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _terminalController.clearSelection();
        unawaited(_showLinkMenu(link, at));
      });
    });
  }

  void _onLinkPointerMove(PointerMoveEvent event) {
    final start = _longPressStart;
    if (event.pointer != _longPressPointer || start == null) return;
    if ((event.position - start).distance > kTouchSlop) _cancelLongPress();
  }

  /// Ctrl+click, where a mouse is in use, opens a link straight away. A
  /// click that became a drag (selecting text) does not.
  void _onLinkPointerUp(PointerUpEvent event) {
    final start = _clickStart;
    if (event.pointer == _clickPointer &&
        start != null &&
        (event.position - start).distance <= kTouchSlop &&
        _linkModifierHeld) {
      final link = _linkAtGlobal(event.position);
      if (link != null) unawaited(_openLink(link));
    }
    _onLinkPointerEnd(event);
  }

  void _onLinkPointerEnd(PointerEvent event) {
    _linkPointers.remove(event.pointer);
    if (event.pointer == _clickPointer) {
      _clickPointer = null;
      _clickStart = null;
    }
    if (event.pointer == _longPressPointer) _cancelLongPress();
  }

  void _cancelLongPress() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
    _longPressPointer = null;
    _longPressStart = null;
  }

  Future<void> _showLinkMenu(TerminalLinkHit link, Offset global) async {
    HapticFeedback.selectionClick();
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final at = overlay.globalToLocal(global);
    final theme = Theme.of(context);
    final choice = await showMenu<_TerminalMenu>(
      context: context,
      position: RelativeRect.fromRect(at & Size.zero, Offset.zero & overlay.size),
      items: [
        PopupMenuItem<_TerminalMenu>(
          enabled: false,
          height: 36,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 260),
            child: Text(
              link.text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        PopupMenuItem<_TerminalMenu>(
          value: _TerminalMenu.openLink,
          child: Row(
            children: [
              const Icon(Icons.open_in_new, size: 18),
              const SizedBox(width: 12),
              Text(context.l10n.terminalOpenLink),
            ],
          ),
        ),
        PopupMenuItem<_TerminalMenu>(
          value: _TerminalMenu.copyLink,
          child: Row(
            children: [
              const Icon(Icons.link, size: 18),
              const SizedBox(width: 12),
              Text(context.l10n.terminalCopyLink),
            ],
          ),
        ),
      ],
    );
    switch (choice) {
      case _TerminalMenu.openLink:
        await _openLink(link);
      case _TerminalMenu.copyLink:
        await _copyLink(link);
      default:
        break;
    }
  }

  /// Hands an `http`/`https` address to the browser — checked again here,
  /// whatever found it. Nothing else is ever opened.
  Future<void> _openLink(TerminalLinkHit link) async {
    final uri = TerminalLinks.parse(link.uri.toString());
    if (uri == null) return;
    final open = widget.openLink ?? _launchInBrowser;
    final opened = await open(uri);
    if (!opened && mounted) _snack(context.l10n.terminalNoAppForLink);
  }

  static Future<bool> _launchInBrowser(Uri uri) async {
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  Future<void> _copyLink(TerminalLinkHit link) async {
    await Clipboard.setData(ClipboardData(text: link.text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(context.l10n.terminalLinkCopied),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  // ------------------------------------------------------------------ find

  /// Ctrl+Shift+F, the context menu, or the session menu. A single-line
  /// selection becomes the query, as in an editor.
  void _openFind() {
    final range = _terminalController.selection;
    if (range != null) {
      final selected = _terminal.buffer.getText(range).trim();
      if (selected.isNotEmpty &&
          !selected.contains('\n') &&
          selected.length <= 200) {
        _findText.text = selected;
        _find.query = TerminalSearchQuery(
          selected,
          caseSensitive: _find.query.caseSensitive,
        );
      }
    }
    _find.open();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_find.isOpen) return;
      _findFocus.requestFocus();
      _findText.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _findText.text.length,
      );
    });
  }

  void _closeFind() {
    _find.close();
    _focusNode.requestFocus();
  }

  void _handleFindChange() {
    if (mounted) setState(() {});
  }

  /// The last buffer row on screen: where a search starts from, so a user
  /// who has scrolled up to read something finds what is there first.
  int _bottomVisibleRow() {
    final view = _viewKey.currentState;
    final last = _terminal.buffer.height - 1;
    if (view == null || !view.mounted || !_scrollController.hasClients) {
      return last;
    }
    try {
      final lineHeight = view.renderTerminal.lineHeight;
      final position = _scrollController.position;
      final row =
          ((position.pixels + position.viewportDimension) / lineHeight).floor() -
              1;
      return row.clamp(0, last);
    } catch (_) {
      return last;
    }
  }

  /// Scrolls so [match] is on screen — in the middle, unless it already was
  /// visible and clear of the find bar.
  void _reveal(TerminalMatch match) {
    final view = _viewKey.currentState;
    if (view == null || !view.mounted || !_scrollController.hasClients) return;
    final double lineHeight;
    try {
      lineHeight = view.renderTerminal.lineHeight;
    } catch (_) {
      return;
    }
    final position = _scrollController.position;
    final top = match.start.y * lineHeight;
    final bottom = (match.end.y + 1) * lineHeight;
    // The bar's height: two rows of touch-sized buttons on a phone.
    const findBarAllowance = 120.0;
    final viewTop = position.pixels;
    final viewBottom = viewTop + position.viewportDimension;
    if (top >= viewTop + findBarAllowance && bottom <= viewBottom) return;
    final target = top - position.viewportDimension / 2 + lineHeight / 2;
    position.jumpTo(
      target.clamp(position.minScrollExtent, position.maxScrollExtent),
    );
  }

  // ----------------------------------------------------------- session log

  /// The badge comes and goes; a log that stopped by itself is finished and
  /// saved by the session manager, and said here once it has been.
  void _handleRecording(SessionRecorder recorder) {
    if (!mounted) return;
    setState(() {});
    final ending = recorder.ending;
    if (ending != null) {
      unawaited(SessionLogActions.announce(
        context,
        _terminal,
        ending,
        justNow: true,
      ));
    }
  }

  // ------------------------------------------------------------------ zoom

  /// Ctrl+= / Ctrl+− / Ctrl+0, as in the editor and most terminal
  /// emulators: larger, smaller, back to the default. Saved like a
  /// pinch-zoom, so the next session opens at the same size. Ctrl+Shift+−
  /// is not a zoom: that is Ctrl+_, readline's undo, and goes to the shell.
  bool _handleZoomKey(KeyEvent event) {
    final keys = HardwareKeyboard.instance;
    final modifier = keys.isControlPressed ||
        (defaultTargetPlatform == TargetPlatform.macOS && keys.isMetaPressed);
    if (!modifier || keys.isAltPressed) return false;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.equal ||
        key == LogicalKeyboardKey.add ||
        key == LogicalKeyboardKey.numpadAdd) {
      _setFontSize(_fontSize + 1);
      return true;
    }
    if (keys.isShiftPressed) return false;
    if (key == LogicalKeyboardKey.minus ||
        key == LogicalKeyboardKey.numpadSubtract) {
      _setFontSize(_fontSize - 1);
      return true;
    }
    if (key == LogicalKeyboardKey.digit0 || key == LogicalKeyboardKey.numpad0) {
      _setFontSize(AppSettings.defaultFontSize);
      return true;
    }
    return false;
  }

  void _setFontSize(double size) {
    final clamped = AppSettings.clampFontSize(size.roundToDouble());
    if (clamped != _fontSize) setState(() => _fontSize = clamped);
    _saveFontSize();
  }

  /// `SettingsStore.update` writes to disk and does not swallow I/O
  /// failures, so this fire-and-forget needs its own handler — otherwise a
  /// full disk turns a zoom into an unhandled async error long after the
  /// gesture ended. The size is already applied on screen either way.
  void _saveFontSize() {
    unawaited(
      widget.settingsStore
          .update((s) => s.copyWith(terminalFontSize: _fontSize))
          .catchError((Object _) {}),
    );
  }

  // ------------------------------------------------------------ pinch zoom

  void _onPointerDown(PointerDownEvent event) {
    _lastDownButtons = event.buttons;
    _activePointers[event.pointer] = event.position;
    if (_activePointers.length == 2) {
      final points = _activePointers.values.toList(growable: false);
      _pinchStartDistance = (points[0] - points[1]).distance;
      _pinchStartFontSize = _fontSize;
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_activePointers.containsKey(event.pointer)) return;
    _activePointers[event.pointer] = event.position;

    final startDistance = _pinchStartDistance;
    final startFontSize = _pinchStartFontSize;
    if (_activePointers.length != 2 || startDistance == null || startDistance <= 0 ||
        startFontSize == null) {
      return;
    }

    final points = _activePointers.values.toList(growable: false);
    final distance = (points[0] - points[1]).distance;
    final size = AppSettings.clampFontSize(
      startFontSize * (distance / startDistance),
    );
    if ((size - _fontSize).abs() >= 0.25) setState(() => _fontSize = size);
  }

  void _onPointerEnd(PointerEvent event) {
    _activePointers.remove(event.pointer);
    if (_activePointers.length < 2 && _pinchStartDistance != null) {
      _pinchStartDistance = null;
      _pinchStartFontSize = null;
      _saveFontSize();
    }
  }

  @override
  void dispose() {
    unawaited(_settingsChanges?.cancel());
    unawaited(_recordingChanges?.cancel());
    _bellQuiet?.cancel();
    _cancelLongPress();
    if (identical(_panes[widget.session], this)) _panes[widget.session] = null;
    // Before the controller: the highlights it disposes notify through it.
    _find.removeListener(_handleFindChange);
    _find.dispose();
    _clearHoverLink(notify: false);
    _findFocus.dispose();
    _findText.dispose();
    _bellFlash.dispose();
    _scrollController.dispose();
    _ownFocusNode?.dispose();
    _terminalController.removeListener(_handleSelectionChange);
    // Hand the hooks back. The shell, the connection and the buffer belong to
    // the SessionController — closing or clearing any of them here is exactly
    // the bug this pane keeps being refactored away from.
    if (widget.session.onBell == _handleBell) widget.session.onBell = null;
    if (widget.session.transformInput == _applySticky) {
      widget.session.transformInput = null;
    }
    _terminalController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final ready = widget.session.isShellReady;
    final closed = widget.session.isClosed || widget.session.shellError != null;
    final input = InputProfile.of(context);
    // By Settings' "Extra keys row": automatically, it goes while a hardware
    // keyboard is doing the typing — a tablet in a keyboard cover, a DeX
    // desk, a desktop — and comes back with the soft keyboard. See
    // [InputDevices.showsKeyBar].
    final keyBar = !closed && ready && input.showsKeyBar(_keyBarMode);
    // No setState: this build is what draws the bar, and there is no bar.
    if (!keyBar) _ctrlSticky = false;
    final terminalTheme = AppTheme.terminalThemeFor(_colorScheme);
    final textStyle = _textStyle;

    return Column(
      children: [
        Expanded(
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerEnd,
            onPointerCancel: _onPointerEnd,
            child: Stack(
              children: [
                // Built from the first frame, even before the shell is open:
                // laying it out is what reports the real column/row count, and
                // that is what the session waits for before creating the PTY.
                // Behind a placeholder it could not report anything, so every
                // shell opened at 80×24 and was resized a moment later — which
                // is one redraw of the first prompt at the wrong width.
                Positioned.fill(
                  // Its own listener, inside the pinch one: it is only about
                  // the terminal's cells, never the find bar over them.
                  child: Listener(
                    behavior: HitTestBehavior.translucent,
                    onPointerDown: _onLinkPointerDown,
                    onPointerMove: _onLinkPointerMove,
                    onPointerUp: _onLinkPointerUp,
                    onPointerCancel: _onLinkPointerEnd,
                    onPointerHover: _onLinkPointerHover,
                    child: MouseRegion(
                      onExit: (_) => _clearHoverLink(),
                      child: TerminalView(
                        _terminal,
                        key: _viewKey,
                        controller: _terminalController,
                        scrollController: _scrollController,
                        // The cursor is drawn by the overlay below.
                        theme: TerminalCursorOverlay.withoutCursor(
                          terminalTheme,
                        ),
                        textStyle: textStyle,
                        cursorType: _xtermCursorType,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        focusNode: _focusNode,
                        autofocus: widget.autofocus,
                        readOnly: closed,
                        backgroundOpacity: 0,
                        keyboardType: TextInputType.multiline,
                        shortcuts: _shortcuts,
                        onKeyEvent: _handleHardwareKeyEvent,
                        onSecondaryTapUp:
                            input.mouse ? _showContextMenu : null,
                        mouseCursor: _hoverLink != null
                            ? SystemMouseCursors.click
                            : SystemMouseCursors.text,
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: TerminalCursorOverlay(
                    terminal: _terminal,
                    viewKey: _viewKey,
                    focusNode: _focusNode,
                    scrollController: _scrollController,
                    shape: _cursorStyle,
                    blink: _cursorBlink,
                    theme: terminalTheme,
                    textStyle: textStyle,
                  ),
                ),
                // Settings > Terminal > Bell > Flash the screen.
                Positioned.fill(
                  child: IgnorePointer(
                    child: AnimatedBuilder(
                      animation: _bellFlash,
                      builder: (context, _) {
                        if (!_bellFlash.isAnimating) {
                          return const SizedBox.shrink();
                        }
                        return ColoredBox(
                          color: terminalTheme.foreground.withValues(
                            alpha: 0.22 * (1 - _bellFlash.value),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                if (!ready && !closed)
                  Positioned.fill(
                    // The live TerminalView underneath already renders in
                    // `terminalThemeFor(_colorScheme)` — this loading cover
                    // matches that background rather than the app's chrome
                    // background, so there is no flash when the shell
                    // becomes ready and the cover is removed.
                    child: ColoredBox(
                      color: terminalTheme.background,
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const CircularProgressIndicator(),
                            const SizedBox(height: 16),
                            Text(context.l10n.terminalOpeningShell),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (_find.isOpen || _terminal.isRecording)
                  Positioned(
                    top: 6,
                    left: 6,
                    right: 6,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        if (_find.isOpen)
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 560),
                            child: TerminalFindBar(
                              find: _find,
                              focusNode: _findFocus,
                              textController: _findText,
                              touch: input.touch,
                              onClose: _closeFind,
                            ),
                          ),
                        if (_terminal.isRecording)
                          Padding(
                            padding: EdgeInsets.only(top: _find.isOpen ? 6 : 0),
                            child: _RecordingBadge(
                              onStop: () => unawaited(
                                SessionLogActions.stop(context, widget.session),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (!closed && ready) ...[
          // Slides in above the key bar while a selection is active. A fixed
          // slim bar rather than one anchored to the selection's on-screen
          // rectangle: xterm 4.x exposes the selected *range* (as buffer
          // coordinates) through `TerminalController.selection` but not a
          // screen-space rect for it — `RenderTerminal`, which does know
          // where cells land on screen, is a package-internal render object
          // with no public accessor. Anchoring against it would mean reaching
          // past the package's public API into something that can change
          // under us; a bar that always docks in the same place is the robust
          // choice, and it is where a thumb already is after a long-press
          // selection on a phone.
          AnimatedSize(
            duration: const Duration(milliseconds: 150),
            alignment: Alignment.bottomCenter,
            child: _hasSelection
                ? _SelectionToolbar(
                    touch: input.touch,
                    onCopy: () => unawaited(_copySelection()),
                    onSelectAll: _selectAll,
                    onPaste: () => unawaited(_pasteFromClipboard()),
                  )
                : const SizedBox(width: double.infinity, height: 0),
          ),
          if (keyBar)
            TerminalKeyBar(
              onKey: (key, {bool ctrl = false, bool alt = false}) =>
                  _terminal.keyInput(key, ctrl: ctrl, alt: alt),
              onText: _terminal.textInput,
              ctrlActive: _ctrlSticky,
              onToggleCtrl: _toggleCtrlSticky,
              onPaste: () => unawaited(_pasteFromClipboard()),
            ),
        ],
      ],
    );
  }
}

enum _TerminalMenu { openLink, copyLink, copy, paste, selectAll, find }

/// Shown over the terminal while its output is being recorded, so a log is
/// never written without the user being able to see it. Small, since it sits
/// over the text; a tap opens a menu to stop rather than stopping outright,
/// so a stray tap on that corner of the terminal cannot end the recording.
class _RecordingBadge extends StatelessWidget {
  const _RecordingBadge({required this.onStop});

  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return PopupMenuButton<bool>(
      tooltip: l10n.sessionLogRecordingTooltip,
      position: PopupMenuPosition.under,
      onSelected: (_) => onStop(),
      itemBuilder: (context) => [
        PopupMenuItem<bool>(
          value: true,
          child: Text(l10n.sessionLogStopAndSave),
        ),
      ],
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.fiber_manual_record,
                size: 10,
                color: theme.colorScheme.error,
              ),
              const SizedBox(width: 4),
              Text(
                l10n.sessionLogRecBadge,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Copy / Select all / Paste, shown while the terminal has an active
/// selection. See the slide-in site in [_TerminalPaneState.build] for why
/// this is a fixed bar rather than one anchored to the selection itself.
class _SelectionToolbar extends StatelessWidget {
  const _SelectionToolbar({
    required this.onCopy,
    required this.onSelectAll,
    required this.onPaste,
    this.touch = false,
  });

  /// Touch has been seen: tall enough for 48dp buttons.
  final bool touch;
  final VoidCallback onCopy;
  final VoidCallback onSelectAll;
  final VoidCallback onPaste;

  static const _captionStyle = TextStyle(fontSize: 12.5);

  /// The width the bar needs with every button labelled: the four words,
  /// as this language and text size draw them, plus the icons, gaps and
  /// padding around them.
  static double _labelledWidth(
    BuildContext context,
    TextStyle? buttonStyle,
    List<String> buttons,
    String caption,
  ) {
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    double width(String text, TextStyle? style) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: direction,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final w = painter.width;
      painter.dispose();
      return w;
    }

    // 12 + 16 + 8 before the caption; 8 after Copy; each button's icon and
    // gap (24) and padding (16, 16, 24); a little slack for rounding.
    return 36 + 8 + 3 * 24 + 16 + 16 + 24 + 12 +
        width(caption, _captionStyle) +
        buttons.fold<double>(0, (sum, label) => sum + width(label, buttonStyle));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return Material(
      color: theme.colorScheme.primary.withValues(alpha: 0.12),
      child: SizedBox(
        height: touch ? 48 : 44,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // A small phone, large text or a language with long words has no
            // room for three labelled buttons: Select all and Paste keep
            // their icons, named in tooltips, and Copy keeps its word.
            final labelled = constraints.maxWidth >=
                _labelledWidth(
                  context,
                  theme.textTheme.labelLarge,
                  [l10n.terminalSelectAll, l10n.terminalPaste, l10n.terminalCopy],
                  l10n.terminalSelected,
                );
            final compact = TextButton.styleFrom(
              minimumSize: Size.zero,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            );
            return Row(
              children: [
                const SizedBox(width: 12),
                Icon(
                  Icons.highlight_alt,
                  size: 16,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.terminalSelected,
                    style: _captionStyle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (labelled) ...[
                  TextButton.icon(
                    onPressed: onSelectAll,
                    icon: const Icon(Icons.select_all, size: 16),
                    label: Text(l10n.terminalSelectAll),
                    style: compact,
                  ),
                  TextButton.icon(
                    onPressed: onPaste,
                    icon: const Icon(Icons.content_paste, size: 16),
                    label: Text(l10n.terminalPaste),
                    style: compact,
                  ),
                ] else ...[
                  IconButton(
                    tooltip: l10n.terminalSelectAll,
                    onPressed: onSelectAll,
                    icon: const Icon(Icons.select_all, size: 18),
                  ),
                  IconButton(
                    tooltip: l10n.terminalPaste,
                    onPressed: onPaste,
                    icon: const Icon(Icons.content_paste, size: 18),
                  ),
                ],
                // Never wider than what is left, so even the longest word
                // at the largest text size shortens rather than overflows.
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: math.max(0, constraints.maxWidth - 36 - 8 - 96),
                  ),
                  child: FilledButton.icon(
                    onPressed: onCopy,
                    icon: const Icon(Icons.copy, size: 16),
                    label: Text(
                      l10n.terminalCopy,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 34),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
            );
          },
        ),
      ),
    );
  }
}
