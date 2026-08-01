import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../models/app_settings.dart';
import '../services/clipboard_paste.dart';
import '../services/session_controller.dart';
import '../services/settings_store.dart';
import '../theme.dart';
import '../widgets/terminal_key_bar.dart';

/// The interactive shell, as a *view on* a session rather than an owner of one.
///
/// Phase 1's `TerminalScreen` owned the connection and closed it in
/// `dispose()`. Phase 3 moved the transport to [SessionController]; Phase 12
/// moved the `Terminal` — the scrollback and cursor themselves — there too,
/// because a session now outlives the screen showing it and a buffer owned by
/// a `State` does not. What is left here is genuinely a view: the font, the
/// theme, selection, the extra-key bar, pinch-zoom and the clipboard.
class TerminalPane extends StatefulWidget {
  const TerminalPane({
    super.key,
    required this.session,
    required this.settingsStore,
    this.focusNode,
    this.autofocus = true,
  });

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

  @override
  State<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<TerminalPane>
    with AutomaticKeepAliveClientMixin {
  final TerminalController _terminalController = TerminalController();

  Terminal get _terminal => widget.session.terminal;

  /// Live text style, seeded from Settings and updated by pinch-zoom. Kept
  /// local (rather than re-reading `settingsStore.current` on every build) so
  /// the terminal does not jump mid-gesture if something else touched the
  /// store, and so the pinch preview is immediate.
  late double _fontSize;
  late TerminalColorScheme _colorScheme;

  /// Sticky Ctrl: armed by the extra-keys bar, consumed by the next
  /// keystroke that reaches [_sendToShell] — soft keyboard, hardware
  /// keyboard, or a key-bar character button all funnel through there.
  bool _ctrlSticky = false;

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

    _terminalController.addListener(_handleSelectionChange);
    // The buffer belongs to the session and may already be full of a shell
    // this pane never opened; asking for it again is a no-op.
    widget.session.onBell = _handleBell;
    widget.session.transformInput = _applySticky;
    unawaited(widget.session.ensureShell());
  }

  void _handleBell() {
    if (mounted) Feedback.forLongPress(context);
  }

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
      const SnackBar(content: Text('Copied'), duration: Duration(seconds: 1)),
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
      if (mounted) _snack('Clipboard is empty');
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
                'Paste $lines lines?',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              const Text(
                'Each line is sent to the shell as if typed and Enter '
                'pressed, so this can run more than one command.',
                style: TextStyle(height: 1.35),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      child: const Text('Paste'),
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
  KeyEventResult _handleHardwareKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;

    final keys = HardwareKeyboard.instance;
    if (!keys.isControlPressed || !keys.isShiftPressed) {
      return KeyEventResult.ignored;
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

  // ------------------------------------------------------------ pinch zoom

  void _onPointerDown(PointerDownEvent event) {
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
      // `SettingsStore.update` writes to disk and does not swallow I/O
      // failures, so this fire-and-forget needs its own handler — otherwise a
      // full disk turns a pinch-zoom into an unhandled async error long after
      // the gesture ended. The size is already applied on screen either way.
      unawaited(
        widget.settingsStore
            .update((s) => s.copyWith(terminalFontSize: _fontSize))
            .catchError((Object _) {}),
      );
    }
  }

  @override
  void dispose() {
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
                  child: TerminalView(
                    _terminal,
                    controller: _terminalController,
                    theme: AppTheme.terminalThemeFor(_colorScheme),
                    textStyle: TerminalStyle(
                      fontSize: _fontSize,
                      fontFamily: AppTheme.monoFontFamily,
                      fontFamilyFallback: AppTheme.monoFontFamilyFallback,
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    focusNode: widget.focusNode,
                    autofocus: widget.autofocus,
                    readOnly: closed,
                    backgroundOpacity: 0,
                    keyboardType: TextInputType.multiline,
                    shortcuts: _shortcuts,
                    onKeyEvent: _handleHardwareKeyEvent,
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
                      color: AppTheme.terminalThemeFor(_colorScheme).background,
                      child: const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(),
                            SizedBox(height: 16),
                            Text('Opening shell…'),
                          ],
                        ),
                      ),
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
                    onCopy: () => unawaited(_copySelection()),
                    onSelectAll: _selectAll,
                    onPaste: () => unawaited(_pasteFromClipboard()),
                  )
                : const SizedBox(width: double.infinity, height: 0),
          ),
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

/// Copy / Select all / Paste, shown while the terminal has an active
/// selection. See the slide-in site in [_TerminalPaneState.build] for why
/// this is a fixed bar rather than one anchored to the selection itself.
class _SelectionToolbar extends StatelessWidget {
  const _SelectionToolbar({
    required this.onCopy,
    required this.onSelectAll,
    required this.onPaste,
  });

  final VoidCallback onCopy;
  final VoidCallback onSelectAll;
  final VoidCallback onPaste;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.primary.withValues(alpha: 0.12),
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            const SizedBox(width: 12),
            Icon(
              Icons.highlight_alt,
              size: 16,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 8),
            const Text('Selected', style: TextStyle(fontSize: 12.5)),
            const Spacer(),
            TextButton.icon(
              onPressed: onSelectAll,
              icon: const Icon(Icons.select_all, size: 16),
              label: const Text('Select all'),
              style: TextButton.styleFrom(
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
            ),
            TextButton.icon(
              onPressed: onPaste,
              icon: const Icon(Icons.content_paste, size: 16),
              label: const Text('Paste'),
              style: TextButton.styleFrom(
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
            ),
            FilledButton.icon(
              onPressed: onCopy,
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('Copy'),
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 34),
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
            ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}
