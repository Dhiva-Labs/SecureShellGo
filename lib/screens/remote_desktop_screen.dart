import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';
import '../services/input_profile.dart';
import '../services/remote_desktop/csrd_client.dart';
import '../services/remote_desktop/remote_input_text.dart';
import '../services/remote_desktop/remote_input_touch.dart';
import '../services/remote_desktop/remote_input_view.dart';
import '../services/remote_desktop/remote_screen_session.dart';
import '../widgets/error_banner.dart';
import '../widgets/remote_desktop/frame_compositor.dart';
import '../widgets/remote_desktop/remote_cursor.dart';
import '../widgets/remote_desktop/remote_input_controller.dart';
import '../widgets/remote_desktop/remote_key_bar.dart';
import '../widgets/remote_desktop/remote_notice_banner.dart';
import '../widgets/remote_desktop/remote_screen_painter.dart';
import '../widgets/remote_desktop/remote_soft_keyboard.dart';
import '../widgets/remote_desktop/remote_stats.dart';
import '../widgets/remote_desktop/remote_toolbar.dart';
import '../widgets/remote_desktop/remote_viewer.dart';

/// Opens the remote-desktop viewer for [hostName] on top of the current
/// screen, and completes when it is closed.
///
/// [opener] does the work of getting a remote screen: whatever the remote
/// needs deployed and started, the channel to it, the handshake. The screen
/// shows its progress, and calls it again for Retry and Reconnect.
Future<void> openRemoteDesktop(
  BuildContext context, {
  required String hostName,
  required RemoteScreenOpener opener,
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => RemoteDesktopScreen(hostName: hostName, opener: opener),
    ),
  );
}

/// The remote desktop: opening it, watching and driving it, and what is left
/// when it ends.
///
/// ```text
/// opening ──► connected ──► closed ──► (Reconnect) ──► opening
///    │                                                    ▲
///    └──► failed ──────────────── (Retry) ────────────────┘
/// ```
///
/// Each time the opener runs, the screen makes a fresh set of the objects
/// that belong to one session (the compositor, the cursor, the input
/// controller, the viewport) and throws them away with it, so a reconnect
/// cannot inherit a stale pointer position or a held key from the last one.
class RemoteDesktopScreen extends StatefulWidget {
  const RemoteDesktopScreen({
    super.key,
    required this.hostName,
    required this.opener,
  });

  final String hostName;
  final RemoteScreenOpener opener;

  @override
  State<RemoteDesktopScreen> createState() => _RemoteDesktopScreenState();
}

enum _Phase { opening, failed, connected, closed }

/// Everything that belongs to one opened session.
class _Link {
  _Link(this.session, double devicePixelRatio)
    : cursor = RemoteCursor(),
      viewport = RemoteViewport(devicePixelRatio: devicePixelRatio),
      compositor = FrameCompositor() {
    input = RemoteInputController(session: session, cursor: cursor);
  }

  final RemoteScreenSession session;
  final RemoteCursor cursor;
  final RemoteViewport viewport;
  final FrameCompositor compositor;
  late final RemoteInputController input;
  final repaint = RepaintSignal();
  final meter = RemoteStatsMeter();
  final clock = Stopwatch()..start();

  late StreamSubscription<CsrdEvent> frames;
  late StreamSubscription<CsrdEvent> events;
  RemoteScreenHandle? handle;

  /// Set once the session has ended, even while it is still being opened.
  CsrdCloseReason? closed;
  var _released = false;

  /// Keeps the viewport and the input controller to the size of the remote
  /// screen, and forgets the pointer when it changes: a position on the old
  /// display means nothing on the new one.
  void syncSize() {
    final w = compositor.width;
    final h = compositor.height;
    if (w == viewport.remoteWidth && h == viewport.remoteHeight) return;
    final first = viewport.remoteWidth == 0;
    viewport.setRemoteSize(w, h);
    input
      ..remoteWidth = w
      ..remoteHeight = h;
    if (!first) input.resetPointer();
    repaint.signal();
  }

  /// Ends the session and lets go of everything: held keys first, then the
  /// channel, then what was started on the remote, once.
  Future<void> close() async {
    input.releaseAll();
    try {
      await session.close();
    } catch (_) {
      // Already closed, or the transport is gone: nothing left to tell it.
    }
    // Cancelling takes effect at once; the futures are not waited on.
    unawaited(frames.cancel());
    unawaited(events.cancel());
    compositor.removeListener(syncSize);
    compositor.dispose();
    cursor.dispose();
    input.dispose();
    repaint.dispose();
    await release();
  }

  Future<void> release() async {
    final h = handle;
    if (h == null || _released) return;
    _released = true;
    try {
      await h.release();
    } catch (_) {
      // Releasing is best effort: the remote's own idle timeout covers an
      // agent that could not be told to stop.
    }
  }
}

class _RemoteDesktopScreenState extends State<RemoteDesktopScreen> {
  var _phase = _Phase.opening;
  var _attempt = 0;
  _Link? _link;
  String? _progress;
  var _waiting = false;
  String? _error;
  CsrdCloseReason? _closeReason;
  var _keepsRunning = false;

  CsrdNoticeEvent? _notice;
  var _clipboardSync = true;
  var _focusMode = false;
  var _immersive = false;
  bool? _keyBarOverride;
  var _touchMode = RemoteTouchMode.trackpad;
  var _warnedUntypable = false;

  final _viewFocus = FocusNode(debugLabel: 'remote desktop viewer');
  late final RemoteSoftKeyboard _softKeyboard;
  late final AppLifecycleListener _lifecycle;
  final _stats = ValueNotifier<String>('');
  Timer? _statsTimer;

  late ScaffoldMessengerState _messenger;
  late String _keepsRunningText;
  late String _cantTypeText;
  late String _pasteLabel;

  @override
  void initState() {
    super.initState();
    _softKeyboard = RemoteSoftKeyboard(
      onChange: _onSoftKeyboard,
      onClosed: () {
        if (mounted) setState(() {});
      },
    );
    // Held keys must not outlive the window being looked at: the app going to
    // the background, or on a desktop the window losing focus.
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (state != AppLifecycleState.resumed) _link?.input.releaseAll();
      },
    );
    _viewFocus.addListener(() {
      if (_viewFocus.hasFocus) _wantKeys = true;
    });
    // Not from initState itself: an opener that reports progress as soon as
    // it starts would call setState while the tree is still being built.
    scheduleMicrotask(() {
      if (mounted) unawaited(_open(initial: true));
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Kept for the way out: the screen is gone by the time the snackbar
    // needs saying, and neither the messenger nor the language can be looked
    // up from a State that is being disposed.
    _messenger = ScaffoldMessenger.of(context);
    final l10n = context.l10n;
    _keepsRunningText = l10n.remoteDesktopKeepsRunning;
    _cantTypeText = l10n.remoteDesktopCantTypeThat;
    _pasteLabel = l10n.remoteDesktopPasteToRemote;
  }

  @override
  void dispose() {
    _attempt++;
    _lifecycle.dispose();
    _statsTimer?.cancel();
    _softKeyboard.dispose();
    _viewFocus.dispose();
    _stats.dispose();
    if (_immersive) {
      unawaited(_systemUi(SystemUiMode.edgeToEdge));
    }
    final link = _link;
    _link = null;
    if (link != null) unawaited(link.close());
    final keeps = link?.handle?.keepsRunning ?? _keepsRunning;
    if (keeps) {
      final messenger = _messenger;
      final text = _keepsRunningText;
      // After this frame: a snackbar cannot be shown while the tree is being
      // taken apart, and it belongs to the screen underneath anyway.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (messenger.mounted) {
          messenger.showSnackBar(SnackBar(content: Text(text)));
        }
      });
    }
    super.dispose();
  }

  // ------------------------------------------------------------- opening

  bool _current(int attempt) => mounted && attempt == _attempt;

  Future<void> _open({bool initial = false}) async {
    final attempt = ++_attempt;
    _Link? link;
    if (!initial) {
      setState(() {
        _phase = _Phase.opening;
        _progress = null;
        _waiting = false;
        _error = null;
        _closeReason = null;
        _notice = null;
        _stats.value = '';
      });
    }
    try {
      final handle = await widget.opener(
        progress: (status) {
          if (_current(attempt)) setState(() => _progress = status);
        },
        attach: (session) => link = _attach(session, attempt),
      );
      // An opener that never called attach has still opened a screen: take
      // the session now, and live with the frames it may have missed.
      final opened = link ??= _attach(handle.session, attempt);
      opened.handle = handle;
      if (!_current(attempt)) {
        // Cancelled, or the screen left, while the opener was working. Its
        // result is not wanted, but what it started is on the remote.
        await opened.close();
        return;
      }
      _link = opened;
      final reason = opened.closed;
      if (reason != null) {
        _ended(opened, reason);
      } else {
        setState(() => _phase = _Phase.connected);
        _startStats(opened);
      }
    } catch (e) {
      final started = link;
      if (started != null) unawaited(started.close());
      if (!_current(attempt)) return;
      setState(() {
        _phase = _Phase.failed;
        _error = _describe(e);
      });
    }
  }

  /// Starts listening to [session] before it is connected, so no event,
  /// the first frame above all, is missed.
  _Link _attach(RemoteScreenSession session, int attempt) {
    final dpr = mounted ? MediaQuery.devicePixelRatioOf(context) : 1.0;
    final link = _Link(session, dpr);
    link.compositor.addListener(link.syncSize);
    link.frames = link.compositor.drive(session);
    link.events = session.events.listen((e) => _onEvent(link, attempt, e));
    return link;
  }

  void _onEvent(_Link link, int attempt, CsrdEvent event) {
    switch (event) {
      case CsrdWaitingEvent():
        if (_current(attempt) && _phase == _Phase.opening) {
          setState(() => _waiting = true);
        }
      case CsrdConnectedEvent() || CsrdDisplaysEvent():
        if (_current(attempt)) setState(() {});
      case CsrdFrameEvent(:final frame):
        link.meter.addFrame(link.clock.elapsed, frame.wireBytes);
      case CsrdCursorShapeEvent(:final shape):
        link.cursor.setShape(shape);
      case CsrdCursorPosEvent(:final x, :final y):
        link.cursor.setEchoed(x, y);
      case final CsrdNoticeEvent notice:
        if (_current(attempt)) {
          setState(() => _notice = notice.text.isEmpty ? null : notice);
        }
      case CsrdClipboardEvent(:final text):
        if (_clipboardSync) unawaited(_setLocalClipboard(text));
      case CsrdRttEvent():
        break;
      case CsrdClosedEvent(:final reason):
        link.closed = reason;
        if (identical(_link, link) && _current(attempt)) _ended(link, reason);
    }
  }

  /// The session is over: say so, and let go of the remote at once rather
  /// than when the person gets round to leaving.
  void _ended(_Link link, CsrdCloseReason reason) {
    _statsTimer?.cancel();
    _keepsRunning = link.handle?.keepsRunning ?? false;
    _link = null;
    unawaited(link.close());
    setState(() {
      _phase = _Phase.closed;
      _closeReason = reason;
    });
  }

  Future<void> _retry() => _open();

  Future<void> _reconnect() => _open();

  Future<void> _setLocalClipboard(String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
    } catch (_) {
      // A clipboard the platform will not give up is not worth a banner.
    }
  }

  static String _describe(Object error) {
    if (error is CsrdConnectException) return error.reason.text;
    final text = error.toString();
    return text.startsWith('Exception: ') ? text.substring(11) : text;
  }

  // --------------------------------------------------------------- stats

  void _startStats(_Link link) {
    _statsTimer?.cancel();
    void tick() {
      final now = link.clock.elapsed;
      final fps = link.meter.fps(now);
      final rate = (link.meter.bytesPerSecond(now) / 1024).round();
      final rtt = link.session.rtt;
      final l10n = context.l10n;
      _stats.value = rtt == null
          ? l10n.remoteDesktopStatsNoRtt(fps, rate)
          : l10n.remoteDesktopStats(fps, rtt.inMilliseconds, rate);
    }

    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) tick();
    });
  }

  // ------------------------------------------------------------- actions

  void _toggleViewOnly(_Link link) {
    final session = link.session;
    if (session.viewOnlyLocked) return;
    if (!session.viewOnly) {
      // Let go of what is held first, while it can still be sent.
      link.input.releaseAll();
      session.viewOnly = true;
    } else {
      session.viewOnly = false;
    }
    setState(() {});
    _refocus();
  }

  void _selectQuality(_Link link, CsrdQuality quality) {
    final display = link.session.display;
    if (display == null) return;
    link.session.selectDisplay(display, quality: quality);
    setState(() {});
    _refocus();
  }

  void _selectDisplay(_Link link, int display) {
    if (display == link.session.display) return;
    try {
      link.session.selectDisplay(display);
    } on ArgumentError {
      // The set of displays changed under the menu.
      return;
    }
    link.input.resetPointer();
    setState(() {});
    _refocus();
  }

  Future<void> _pasteToRemote(_Link link) async {
    String? text;
    try {
      text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    } catch (_) {
      text = null;
    }
    if (!mounted) return;
    if (text == null || text.isEmpty) {
      _messenger.showSnackBar(
        SnackBar(content: Text(context.l10n.remoteDesktopClipboardEmpty)),
      );
      return;
    }
    await link.input.pasteToRemote(text);
    _refocus();
  }

  void _toggleViewMode(_Link link) {
    final view = link.viewport;
    if (view.mode == RemoteViewMode.fit) {
      final cursor = link.cursor;
      view.setMode(
        RemoteViewMode.actual,
        focusX: cursor.hasPosition ? cursor.x : null,
        focusY: cursor.hasPosition ? cursor.y : null,
      );
    } else {
      view.setMode(RemoteViewMode.fit);
    }
    link.repaint.signal();
    setState(() {});
    _refocus();
  }

  void _toggleTouchMode() {
    setState(() {
      _touchMode = _touchMode == RemoteTouchMode.trackpad
          ? RemoteTouchMode.direct
          : RemoteTouchMode.trackpad;
    });
    _refocus();
  }

  /// Hands the keyboard back to the rest of the app. The viewer takes it
  /// again at the next click or tap on the screen. Held keys are let go of
  /// by the viewer losing focus.
  void _releaseKeyboard() {
    _viewFocus.unfocus();
    _wantKeys = false;
    setState(() {});
  }

  /// Whether the toolbar should hand the keyboard back to the screen after
  /// an action. False once the person has deliberately let go of it, until
  /// they click the screen again.
  var _wantKeys = true;

  /// A toolbar button that took the keyboard when it was pressed gives it
  /// back, so the next key still reaches the remote.
  void _refocus() {
    if (_wantKeys && !_viewFocus.hasFocus) _viewFocus.requestFocus();
  }

  void _toggleSoftKeyboard() {
    final open = InputProfile.of(context).softKeyboardOpen;
    if (_softKeyboard.isAttached && open) {
      _softKeyboard.hide();
    } else {
      _softKeyboard.show();
    }
    setState(() {});
  }

  void _onSoftKeyboard(EditingChange change) {
    final link = _link;
    if (link == null) return;
    final skipped = link.input.typeChange(change);
    if (skipped.isNotEmpty && !_warnedUntypable && !link.input.blocked) {
      _warnedUntypable = true;
      _messenger.showSnackBar(
        SnackBar(
          content: Text(_cantTypeText),
          action: SnackBarAction(
            label: _pasteLabel,
            onPressed: () => unawaited(_pasteToRemote(link)),
          ),
        ),
      );
    }
  }

  Future<void> _systemUi(SystemUiMode mode) async {
    try {
      await SystemChrome.setEnabledSystemUIMode(mode);
    } catch (_) {
      // Not every embedder has a system UI to hide.
    }
  }

  void _setFocusMode(bool on) {
    if (on == _focusMode) return;
    setState(() => _focusMode = on);
    if (Theme.of(context).platform == TargetPlatform.android) {
      _immersive = on;
      unawaited(
        _systemUi(on ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge),
      );
    }
  }

  // --------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return switch (_phase) {
      _Phase.opening => _buildOpening(context),
      _Phase.failed => _buildFailed(context),
      _Phase.closed => _buildClosed(context),
      _Phase.connected => _buildConnected(context, _link!),
    };
  }

  AppBar _simpleAppBar(BuildContext context) =>
      AppBar(title: Text(_link?.handle?.title ?? widget.hostName));

  Widget _centered(List<Widget> children) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    ),
  );

  Widget _buildOpening(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: _simpleAppBar(context),
      body: _centered([
        const Center(child: CircularProgressIndicator()),
        const SizedBox(height: 20),
        Text(
          _progress ?? l10n.remoteDesktopConnecting,
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium,
        ),
        if (_waiting) ...[
          const SizedBox(height: 12),
          Text(
            l10n.remoteDesktopWaiting,
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
        const SizedBox(height: 24),
        Center(
          child: OutlinedButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child: Text(l10n.remoteDesktopCancel),
          ),
        ),
      ]),
    );
  }

  Widget _buildFailed(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: _simpleAppBar(context),
      body: _centered([
        Text(
          l10n.remoteDesktopFailedTitle,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 16),
        ErrorBanner(message: _error ?? ''),
        const SizedBox(height: 24),
        Center(
          child: FilledButton(
            onPressed: _retry,
            child: Text(l10n.remoteDesktopRetry),
          ),
        ),
      ]),
    );
  }

  Widget _buildClosed(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: _simpleAppBar(context),
      body: _centered([
        Icon(
          Icons.desktop_access_disabled_outlined,
          size: 40,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(height: 12),
        Text(
          l10n.remoteDesktopEnded,
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          _closeReason?.text ?? '',
          textAlign: TextAlign.center,
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 24),
        Center(
          child: FilledButton(
            onPressed: _reconnect,
            child: Text(l10n.remoteDesktopReconnect),
          ),
        ),
      ]),
    );
  }

  Widget _buildConnected(BuildContext context, _Link link) {
    final l10n = context.l10n;
    final devices = InputProfile.of(context);
    final session = link.session;
    final showKeyBar = _keyBarOverride ?? devices.touch;
    final notice = _notice;

    final viewer = RemoteViewer(
      key: const ValueKey('remote-viewer'),
      compositor: link.compositor,
      viewport: link.viewport,
      cursor: link.cursor,
      input: link.input,
      repaint: link.repaint,
      focusNode: _viewFocus,
      touchMode: _touchMode,
      viewOnly: session.viewOnly,
      onEscLongPress: _focusMode ? () => _setFocusMode(false) : null,
    );

    return Scaffold(
      appBar: _focusMode
          ? null
          : AppBar(
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    link.handle?.title ?? widget.hostName,
                    style: const TextStyle(fontSize: 16),
                  ),
                  ValueListenableBuilder<String>(
                    valueListenable: _stats,
                    builder: (context, text, _) => Text(
                      text,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
              actions: [
                IconButton(
                  tooltip: l10n.remoteDesktopFocusMode,
                  icon: const Icon(Icons.fullscreen),
                  onPressed: () => _setFocusMode(true),
                ),
                IconButton(
                  tooltip: l10n.remoteDesktopDisconnect,
                  icon: const Icon(Icons.power_settings_new),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ],
            ),
      body: Stack(
        children: [
          // Clear of the notch and the navigation bar: a remote desktop is
          // no use if the corner you need is under one.
          SafeArea(
            child: Column(
              children: [
                if (!_focusMode)
                  ListenableBuilder(
                    listenable: _viewFocus,
                    builder: (context, _) => RemoteToolbar(
                      displays: session.displays,
                      display: session.display,
                      onSelectDisplay: (d) => _selectDisplay(link, d),
                      supportsQuality: session.supportsQuality,
                      quality: session.quality,
                      onSelectQuality: (q) => _selectQuality(link, q),
                      viewOnly: session.viewOnly,
                      viewOnlyLocked: session.viewOnlyLocked,
                      onToggleViewOnly: () => _toggleViewOnly(link),
                      clipboardSync: _clipboardSync,
                      onToggleClipboardSync: () {
                        setState(() => _clipboardSync = !_clipboardSync);
                        _refocus();
                      },
                      onPasteToRemote: () => unawaited(_pasteToRemote(link)),
                      viewMode: link.viewport.mode,
                      onToggleViewMode: () => _toggleViewMode(link),
                      keyBarVisible: showKeyBar,
                      onToggleKeyBar: () {
                        setState(() => _keyBarOverride = !showKeyBar);
                        _refocus();
                      },
                      showTouchMode: devices.touch,
                      touchMode: _touchMode,
                      onToggleTouchMode: _toggleTouchMode,
                      showReleaseKeyboard: devices.keyboard,
                      keyboardCaptured: _viewFocus.hasFocus,
                      onReleaseKeyboard: _releaseKeyboard,
                    ),
                  ),
                if (notice != null)
                  RemoteNoticeBanner(
                    level: notice.level,
                    text: notice.text,
                    onDismiss: () => setState(() => _notice = null),
                  ),
                Expanded(child: viewer),
                if (showKeyBar)
                  RemoteKeyBar(
                    input: link.input,
                    keyboardOpen:
                        _softKeyboard.isAttached && devices.softKeyboardOpen,
                    onToggleKeyboard: _toggleSoftKeyboard,
                  ),
              ],
            ),
          ),
          if (_focusMode)
            Positioned(
              top: 0,
              right: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Opacity(
                    opacity: 0.55,
                    child: IconButton.filledTonal(
                      tooltip: l10n.remoteDesktopExitFocusMode,
                      icon: const Icon(Icons.fullscreen_exit),
                      onPressed: () => _setFocusMode(false),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
