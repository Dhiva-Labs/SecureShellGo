import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../services/assistant_drive.dart';
import '../services/bridge/bridge_desktops.dart';
import '../services/remote_desktop/csrd_client.dart';
import '../services/remote_desktop/remote_input_touch.dart';
import '../services/remote_desktop/remote_input_view.dart';
import '../services/remote_desktop/remote_screen_session.dart';
import '../services/ssh_service.dart';
import '../services/visible_text.dart';
import '../widgets/remote_desktop/frame_compositor.dart';
import '../widgets/remote_desktop/remote_cursor.dart';
import '../widgets/remote_desktop/remote_input_controller.dart';
import '../widgets/remote_desktop/remote_screen_painter.dart';
import '../widgets/remote_desktop/remote_viewer.dart';

/// Opens a remote screen on a transport that is already connected
/// (`openSignedInDesktop` in `remote_desktop_launch.dart`).
typedef AssistantScreenOpener =
    Future<RemoteScreenHandle> Function(
      SessionTransport transport, {
      required RemoteScreenProgress progress,
      required void Function(RemoteScreenSession session) attach,
    });

/// The assistant's desktop on the app side: the remote-desktop session, the
/// decoded screen the viewer draws, and screenshots encoded from that same
/// screen with `dart:ui`. What [BridgeDesktops] holds for each desktop.
///
/// It owns the connection it was opened on, dialled for it alone (no agent
/// or X11 forwarding: `BridgeConnections.dialOwned`), and hangs it up on
/// [close].
class AssistantDesktopLink implements BridgeDesktopScreen {
  AssistantDesktopLink._(this._transport);

  /// Dials [dial], opens the desktop on it with [opener], and starts
  /// decoding frames before the first one can arrive.
  static Future<AssistantDesktopLink> open({
    required Future<SessionTransport> Function() dial,
    required AssistantScreenOpener opener,
  }) async {
    final transport = await dial();
    final link = AssistantDesktopLink._(transport);
    try {
      final handle = await opener(
        transport,
        progress: (_) {},
        attach: link._attach,
      );
      link._handle = handle;
      if (link._session == null) link._attach(handle.session);
      return link;
    } catch (_) {
      await link.close();
      rethrow;
    }
  }

  final SessionTransport _transport;
  RemoteScreenHandle? _handle;
  RemoteScreenSession? _session;
  StreamSubscription<CsrdEvent>? _frames;
  StreamSubscription<CsrdEvent>? _events;
  final _first = Completer<void>();
  final _done = Completer<void>();
  var _closed = false;
  var _viewing = false;
  var _viewDisposed = false;

  /// The screen as decoded, for the viewer and for screenshots.
  final FrameCompositor compositor = FrameCompositor();

  /// The remote cursor's shape and position, for the viewer.
  final RemoteCursor cursor = RemoteCursor();

  void _attach(RemoteScreenSession session) {
    if (_session != null) return;
    _session = session;
    _frames = compositor.drive(session);
    compositor.addListener(_onFrame);
    _events = session.events.listen((event) {
      switch (event) {
        case CsrdCursorShapeEvent(:final shape):
          if (!_viewDisposed) cursor.setShape(shape);
        case CsrdCursorPosEvent(:final x, :final y):
          if (!_viewDisposed) cursor.setEchoed(x, y);
        case CsrdClosedEvent():
          _ended();
        default:
          break;
      }
    });
    unawaited(session.done.then((_) => _ended(), onError: (Object _) => _ended()));
  }

  void _onFrame() {
    if (!_first.isCompleted && compositor.value != null && width > 0) {
      _first.complete();
    }
  }

  void _ended() {
    if (!_first.isCompleted) {
      _first.completeError(
        StateError('The remote desktop session ended before it showed '
            'anything.'),
      );
      // Nobody may be waiting for it any more.
      _first.future.ignore();
    }
    if (!_done.isCompleted) _done.complete();
  }

  @override
  RemoteScreenSession get session => _session!;

  @override
  int get width => compositor.width;

  @override
  int get height => compositor.height;

  @override
  Future<void> get firstFrame => _first.future;

  @override
  Future<void> get done => _done.future;

  @override
  Future<Uint8List?> capturePng(int width, int height) async {
    final image = compositor.value?.clone();
    if (image == null) return null;
    try {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        Paint()..filterQuality = FilterQuality.medium,
      );
      final picture = recorder.endRecording();
      final scaled = await picture.toImage(width, height);
      picture.dispose();
      try {
        final data = await scaled.toByteData(format: ui.ImageByteFormat.png);
        return data?.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      } finally {
        scaled.dispose();
      }
    } finally {
      image.dispose();
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final session = _session;
    if (session != null) {
      try {
        await session.close();
      } catch (_) {
        // Already closed, or the transport is gone.
      }
    }
    unawaited(_frames?.cancel());
    unawaited(_events?.cancel());
    compositor.removeListener(_onFrame);
    _ended();
    try {
      await _handle?.release();
    } catch (_) {
      // Best effort: the agent's own idle timeout covers it.
    }
    _transport.close();
    if (!_viewing) _disposeView();
  }

  /// A viewer is drawing [compositor] and [cursor]: they are disposed when
  /// it is done with them ([viewerDone]), not on [close].
  void viewerStarted() => _viewing = true;

  void viewerDone() {
    _viewing = false;
    if (_closed) _disposeView();
  }

  void _disposeView() {
    if (_viewDisposed) return;
    _viewDisposed = true;
    compositor.dispose();
    cursor.dispose();
  }
}

/// Puts each new assistant desktop in front of the user, in its own viewer,
/// the moment it opens: the user sees what the assistant sees, always.
/// Mounted once, from `main.dart`, with the app's navigator key, like the
/// approval cards.
class AssistantDesktopHost {
  AssistantDesktopHost({
    required this.navigatorKey,
    required this.desktops,
    required this.lockChanges,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final BridgeDesktops desktops;

  /// The lock going up or coming down: a viewer gives up the keyboard when
  /// the lock goes up, so keys typed at the lock screen never reach the
  /// remote desktop under it.
  final Stream<bool> lockChanges;

  final Set<String> _shown = {};
  StreamSubscription<List<AssistantDesktop>>? _sub;
  late final Stream<bool> _locks = lockChanges.asBroadcastStream();

  void start() {
    _sub ??= desktops.changes.listen((list) {
      for (final d in list) {
        if (d.state != AssistantDriveState.driving) continue;
        if (!_shown.add(d.desktopId)) continue;
        _show(d.desktopId);
      }
    });
  }

  void _show(String desktopId) {
    final navigator = navigatorKey.currentState;
    if (navigator == null) {
      // Nowhere to show it: it must not run unseen.
      unawaited(desktops.viewerClosed(desktopId));
      return;
    }
    unawaited(
      navigator.push<void>(
        MaterialPageRoute(
          builder: (_) => AssistantDesktopScreen(
            desktops: desktops,
            desktopId: desktopId,
            lockChanges: _locks,
          ),
        ),
      ),
    );
  }

  Future<void> dispose() async {
    await _sub?.cancel();
  }
}

/// The viewer of an assistant desktop: the remote screen, live, under a
/// banner that says who is using it, with Take over and Stop. While the
/// assistant uses it the screen only shows; once the user takes over it is
/// an ordinary remote desktop in the user's hands. Leaving the viewer ends
/// the desktop.
class AssistantDesktopScreen extends StatefulWidget {
  const AssistantDesktopScreen({
    super.key,
    required this.desktops,
    required this.desktopId,
    this.lockChanges,
  });

  final BridgeDesktops desktops;
  final String desktopId;
  final Stream<bool>? lockChanges;

  @override
  State<AssistantDesktopScreen> createState() => _AssistantDesktopScreenState();
}

class _AssistantDesktopScreenState extends State<AssistantDesktopScreen> {
  AssistantDesktopLink? _link;
  AssistantDrive? _drive;
  RemoteInputController? _input;
  final _viewport = RemoteViewport();
  final _repaint = RepaintSignal();
  final _focus = FocusNode(debugLabel: 'assistant desktop viewer');
  StreamSubscription<bool>? _lock;

  @override
  void initState() {
    super.initState();
    final screen = widget.desktops.screenOf(widget.desktopId);
    _drive = widget.desktops.driveOf(widget.desktopId);
    if (screen is AssistantDesktopLink) {
      _link = screen..viewerStarted();
      _input = RemoteInputController(
        session: screen.session,
        cursor: screen.cursor,
      );
      screen.compositor.addListener(_syncSize);
      _syncSize();
    }
    _drive?.addListener(_onDrive);
    _lock = widget.lockChanges?.listen((locked) {
      if (locked) {
        _input?.releaseAll();
        _focus.unfocus();
      }
    });
  }

  @override
  void dispose() {
    unawaited(_lock?.cancel());
    _drive?.removeListener(_onDrive);
    _input?.releaseAll();
    _input?.dispose();
    final link = _link;
    link?.compositor.removeListener(_syncSize);
    // Leaving the viewer ends the desktop, the assistant's or the user's.
    unawaited(
      widget.desktops
          .viewerClosed(widget.desktopId)
          .whenComplete(() => link?.viewerDone()),
    );
    _repaint.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onDrive() {
    if (!mounted) return;
    final drive = _drive;
    if (drive != null && drive.state == AssistantDriveState.takenOver) {
      _focus.requestFocus();
    } else if (drive != null && drive.state == AssistantDriveState.ended) {
      _input?.releaseAll();
      _focus.unfocus();
    }
    setState(() {});
  }

  void _syncSize() {
    final link = _link;
    final input = _input;
    if (link == null || input == null) return;
    final w = link.compositor.width;
    final h = link.compositor.height;
    if (w == _viewport.remoteWidth && h == _viewport.remoteHeight) return;
    final first = _viewport.remoteWidth == 0;
    _viewport.setRemoteSize(w, h);
    input
      ..remoteWidth = w
      ..remoteHeight = h;
    if (!first) input.resetPointer();
    _repaint.signal();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final desktop = widget.desktops.byId(widget.desktopId);
    final drive = _drive;
    final link = _link;
    final input = _input;
    _viewport.devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    final state = drive?.state ?? AssistantDriveState.ended;
    final hasPicture = link != null && link.compositor.width > 0;
    final Widget body;
    if (link == null || input == null) {
      body = const SizedBox.shrink();
    } else if (!hasPicture) {
      body = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(l10n.remoteDesktopConnecting),
          ],
        ),
      );
    } else {
      final userHasIt = state == AssistantDriveState.takenOver;
      body = IgnorePointer(
        // Only shown while the assistant uses it, and after it ended: the
        // user's clicks and keys go to the remote only once taken over.
        ignoring: !userHasIt,
        child: ExcludeFocus(
          excluding: !userHasIt,
          child: RemoteViewer(
            key: const ValueKey('assistant-desktop-viewer'),
            compositor: link.compositor,
            viewport: _viewport,
            cursor: link.cursor,
            input: input,
            repaint: _repaint,
            focusNode: _focus,
            touchMode: RemoteTouchMode.trackpad,
            viewOnly: !userHasIt,
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(visibleLine(desktop?.hostName ?? '', maxChars: 60)),
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (drive != null)
              AssistantDesktopBanner(
                drive: drive,
                onTakeOver: () => widget.desktops.takeOver(widget.desktopId),
                onStop: () => unawaited(widget.desktops.stop(widget.desktopId)),
                onClose: () => Navigator.of(context).maybePop(),
              ),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }
}

/// Above an assistant desktop: who is using it, with Take over and Stop;
/// after the user took over, a quiet note; after it ended, why, and Close.
/// The assistant's name is drawn through [visibleLine], and cut: it is
/// whatever was typed at pairing.
class AssistantDesktopBanner extends StatelessWidget {
  const AssistantDesktopBanner({
    super.key,
    required this.drive,
    required this.onTakeOver,
    required this.onStop,
    required this.onClose,
  });

  final AssistantDrive drive;
  final VoidCallback onTakeOver;
  final VoidCallback onStop;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final name = visibleLine(drive.clientName, maxChars: 40);
    final driving = drive.state == AssistantDriveState.driving;
    final (text, icon) = switch (drive.state) {
      AssistantDriveState.driving => (
        l10n.assistantDesktopBannerDriving(name),
        Icons.smart_toy_outlined,
      ),
      AssistantDriveState.takenOver => (
        l10n.assistantDesktopBannerTakenOver(name),
        Icons.person_outline,
      ),
      AssistantDriveState.ended => (
        l10n.assistantDesktopBannerEnded(
          name,
          visibleLine(drive.endedReason ?? '', maxChars: 120),
        ),
        Icons.stop_circle_outlined,
      ),
    };
    return Material(
      key: ValueKey('assistant-desktop-banner-${drive.state.name}'),
      color: driving ? scheme.tertiaryContainer : scheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  icon,
                  size: 18,
                  color: driving ? scheme.onTertiaryContainer : null,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    text,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.3,
                      color: driving ? scheme.onTertiaryContainer : null,
                    ),
                  ),
                ),
              ],
            ),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Wrap(
                children: [
                  if (driving) ...[
                    TextButton(
                      key: const ValueKey('assistant-desktop-take-over'),
                      onPressed: onTakeOver,
                      child: Text(l10n.assistantBannerTakeOver),
                    ),
                    TextButton(
                      key: const ValueKey('assistant-desktop-stop'),
                      onPressed: onStop,
                      child: Text(l10n.assistantBannerStop),
                    ),
                  ] else if (drive.state == AssistantDriveState.ended)
                    TextButton(
                      key: const ValueKey('assistant-desktop-close'),
                      onPressed: onClose,
                      child: Text(l10n.sessionBannerClose),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
