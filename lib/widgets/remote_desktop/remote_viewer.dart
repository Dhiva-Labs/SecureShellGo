import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/input_profile.dart';
import '../../services/remote_desktop/csrd_keymap.dart';
import '../../services/remote_desktop/remote_input.dart';
import '../../services/remote_desktop/remote_input_touch.dart';
import '../../services/remote_desktop/remote_input_view.dart';
import 'frame_compositor.dart';
import 'remote_cursor.dart';
import 'remote_input_controller.dart';
import 'remote_screen_painter.dart';

/// The remote screen on the device, and everything that turns what the
/// person does to it into input for the remote.
///
/// Three kinds of hand are told apart per event, by the kind of pointer
/// that made it, rather than once per screen: a phone with a mouse attached
/// has both.
/// - **Mouse and trackpad** move the remote pointer where they point, press
///   its buttons, and scroll it. Ctrl and the wheel, or a pinch on a
///   trackpad, zoom the view instead.
/// - **Fingers and styluses** go through [RemoteTouchTracker].
/// - **The keyboard** goes to the remote whole while this has focus: every
///   key, Tab and Ctrl+W included, which is what a remote desktop is for.
///   The toolbar's release-keyboard button is the way out.
class RemoteViewer extends StatefulWidget {
  const RemoteViewer({
    super.key,
    required this.compositor,
    required this.viewport,
    required this.cursor,
    required this.input,
    required this.repaint,
    required this.focusNode,
    required this.touchMode,
    required this.viewOnly,
    this.onEscLongPress,
  });

  final FrameCompositor compositor;
  final RemoteViewport viewport;
  final RemoteCursor cursor;
  final RemoteInputController input;

  /// Poked whenever the viewport changes, so the painter redraws.
  final RepaintSignal repaint;

  /// Owned by the screen, which also needs to know whether the keyboard is
  /// going to the remote, and to take it back.
  final FocusNode focusNode;
  final RemoteTouchMode touchMode;
  final bool viewOnly;

  /// Esc held this long (see [escHoldTime]) while this is set: the way back
  /// out of focus mode for someone with a keyboard and no toolbar to click.
  final VoidCallback? onEscLongPress;

  static const Duration escHoldTime = Duration(milliseconds: 1200);

  @override
  State<RemoteViewer> createState() => _RemoteViewerState();
}

class _RemoteViewerState extends State<RemoteViewer>
    implements RemoteTouchSink {
  late final RemoteTouchTracker _tracker;
  final _acceleration = const TrackpadAcceleration();

  // Mouse
  var _buttons = 0;
  final _sentDown = <int>{};
  Offset? _mouse;
  Timer? _edgeTimer;
  var _edge = Offset.zero;

  // Trackpad pan/zoom
  var _panZoomScale = 1.0;
  var _pinching = false;

  // Touch
  var _touchInside = true;
  final _touchSent = <int>{};

  Timer? _escTimer;

  RemoteInputController get _input => widget.input;
  RemoteViewport get _view => widget.viewport;

  @override
  void initState() {
    super.initState();
    _tracker = RemoteTouchTracker(sink: this, mode: widget.touchMode);
  }

  @override
  void didUpdateWidget(RemoteViewer old) {
    super.didUpdateWidget(old);
    _tracker.mode = widget.touchMode;
    if (widget.viewOnly && !old.viewOnly) _tracker.reset();
    if (widget.onEscLongPress == null) _escTimer?.cancel();
  }

  @override
  void dispose() {
    _tracker.reset();
    _edgeTimer?.cancel();
    _escTimer?.cancel();
    super.dispose();
  }

  void _repaint() => widget.repaint.signal();

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final devices = InputProfile.of(context);
    final theme = Theme.of(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    _view.devicePixelRatio = dpr;
    return LayoutBuilder(
      builder: (context, constraints) {
        _view.resize(constraints.maxWidth, constraints.maxHeight);
        return Focus(
          focusNode: widget.focusNode,
          autofocus: true,
          onKeyEvent: _onKey,
          onFocusChange: (focused) {
            // Keys held when focus goes would otherwise stay down on the
            // remote, with nobody left to release them.
            if (!focused) _input.releaseAll();
          },
          child: MouseRegion(
            // The remote draws its own pointer; a second one, a round trip
            // ahead of it, would only be confusing. In view-only mode the
            // local one is the only one that moves, so it stays.
            cursor: devices.mouse && !widget.viewOnly
                ? SystemMouseCursors.none
                : MouseCursor.defer,
            onExit: (_) => _mouseLeft(),
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: _onPointerDown,
              onPointerMove: _onPointerMove,
              onPointerUp: _onPointerUp,
              onPointerCancel: _onPointerCancel,
              onPointerHover: _onPointerHover,
              onPointerSignal: _onPointerSignal,
              onPointerPanZoomStart: _onPanZoomStart,
              onPointerPanZoomUpdate: _onPanZoomUpdate,
              child: RepaintBoundary(
                child: SizedBox.expand(
                  child: CustomPaint(
                    painter: RemoteScreenPainter(
                      compositor: widget.compositor,
                      viewport: _view,
                      cursor: widget.cursor,
                      background: theme.scaffoldBackgroundColor,
                      devicePixelRatio: dpr,
                      repaint: Listenable.merge([
                        widget.compositor,
                        widget.cursor,
                        widget.repaint,
                      ]),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // ------------------------------------------------------------- pointers

  static bool _isMouse(PointerEvent e) =>
      InputProfile.classify(e.kind) == PointerClass.mouse;

  static bool _isTouch(PointerEvent e) =>
      InputProfile.classify(e.kind) == PointerClass.touch;

  void _onPointerDown(PointerDownEvent e) {
    widget.focusNode.requestFocus();
    if (_isMouse(e)) {
      _mouse = e.localPosition;
      _mouseButtons(e.localPosition, e.buttons);
    } else if (_isTouch(e)) {
      _tracker.down(
        e.pointer,
        e.localPosition.dx,
        e.localPosition.dy,
        e.timeStamp,
      );
    }
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (_isMouse(e)) {
      _mouseMoved(e.localPosition);
      _mouseButtons(e.localPosition, e.buttons);
    } else if (_isTouch(e)) {
      _tracker.move(
        e.pointer,
        e.localPosition.dx,
        e.localPosition.dy,
        e.timeStamp,
      );
    }
  }

  void _onPointerUp(PointerUpEvent e) {
    if (_isMouse(e)) {
      _mouseMoved(e.localPosition);
      _mouseButtons(e.localPosition, 0);
    } else if (_isTouch(e)) {
      _tracker.up(e.pointer, e.timeStamp);
    }
  }

  void _onPointerCancel(PointerCancelEvent e) {
    if (_isMouse(e)) {
      _mouseButtons(e.localPosition, 0);
    } else if (_isTouch(e)) {
      _tracker.cancel(e.pointer);
    }
  }

  void _onPointerHover(PointerHoverEvent e) {
    if (_isMouse(e)) _mouseMoved(e.localPosition);
  }

  void _onPointerSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    if (HardwareKeyboard.instance.isControlPressed) {
      // Ctrl and the wheel zoom the view, as they do in a browser.
      _view.zoomAt(
        math.exp(-e.scrollDelta.dy / 240),
        e.localPosition.dx,
        e.localPosition.dy,
      );
      _repaint();
      return;
    }
    if (_view.remoteFromView(e.localPosition.dx, e.localPosition.dy) == null) {
      return;
    }
    _input.scrollWheel(e.scrollDelta.dx, e.scrollDelta.dy);
  }

  void _onPanZoomStart(PointerPanZoomStartEvent e) {
    widget.focusNode.requestFocus();
    _panZoomScale = 1;
    _pinching = false;
  }

  void _onPanZoomUpdate(PointerPanZoomUpdateEvent e) {
    // Two fingers that pinch also drift, and those drifts must not scroll
    // the remote while the view is being zoomed.
    if ((e.scale - 1).abs() > 0.02) _pinching = true;
    if (e.scale != _panZoomScale) {
      _view.zoomAt(
        e.scale / _panZoomScale,
        e.localPosition.dx,
        e.localPosition.dy,
      );
      _panZoomScale = e.scale;
      _repaint();
    }
    if (!_pinching) _input.scrollFingers(e.panDelta.dx, e.panDelta.dy);
  }

  // ---------------------------------------------------------------- mouse

  void _mouseMoved(Offset at) {
    _mouse = at;
    if (!_view.isReady) return;
    final (x, y) = _view.remoteExactFromView(at.dx, at.dy);
    _input.moveCursorTo(x, y);
    _updateEdgePan(at);
  }

  void _mouseLeft() {
    _edgeTimer?.cancel();
    _edge = Offset.zero;
  }

  /// Applies the buttons now held, comparing them with the ones last seen.
  ///
  /// A press outside the picture (in the letterbox, or past the zoomed
  /// edge) is not sent, and neither is its release; a press inside is, and
  /// its release is too, wherever the pointer has got to by then.
  void _mouseButtons(Offset at, int mask) {
    final changes = remoteButtonChanges(_buttons, mask);
    _buttons = mask;
    for (final change in changes) {
      if (change.down) {
        if (_view.remoteFromView(at.dx, at.dy) == null || _input.blocked) {
          continue;
        }
        _mouseMoved(at);
        _input.pointerButton(change.button, down: true);
        _sentDown.add(change.button);
      } else if (_sentDown.remove(change.button)) {
        _mouseMoved(at);
        _input.pointerButton(change.button, down: false);
      }
    }
  }

  // Zoomed in, the pointer reaching the edge of the viewer is the only way
  // to see more of the screen with a mouse, since every other gesture is
  // spoken for.
  static const double _edgeBand = 32;
  static const double _edgeSpeed = 14;

  void _updateEdgePan(Offset at) {
    if (!_view.canPan) {
      _edgeTimer?.cancel();
      _edge = Offset.zero;
      return;
    }
    double along(double v, double size) {
      if (v < _edgeBand) return -(1 - v / _edgeBand).clamp(0, 1) * _edgeSpeed;
      if (v > size - _edgeBand) {
        return (1 - (size - v) / _edgeBand).clamp(0, 1) * _edgeSpeed;
      }
      return 0;
    }

    _edge = Offset(
      along(at.dx, _view.viewWidth),
      along(at.dy, _view.viewHeight),
    );
    if (_edge == Offset.zero) {
      _edgeTimer?.cancel();
      _edgeTimer = null;
    } else {
      _edgeTimer ??= Timer.periodic(const Duration(milliseconds: 16), (_) {
        final at = _mouse;
        if (at == null || _edge == Offset.zero || !_view.canPan) return;
        // The picture slides away from the pointer; the pointer's remote
        // position follows what is now under it.
        final before = _view.imageRect;
        _view.panBy(-_edge.dx, -_edge.dy);
        if (_view.imageRect == before) {
          // At the far edge already: nothing more to scroll to until the
          // pointer moves again.
          _edgeTimer?.cancel();
          _edgeTimer = null;
          return;
        }
        _repaint();
        _mouseMoved(at);
      });
    }
  }

  // ------------------------------------------------------------- keyboard

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (_input.blocked) return KeyEventResult.ignored;
    final code = csrdEvdevForUsbHid(event.physicalKey.usbHidUsage);
    // A key with no evdev code has nothing to send. It is left for whoever
    // else wants it, which on Android includes the soft keyboard's own.
    if (code == null) return KeyEventResult.ignored;
    switch (event) {
      case KeyDownEvent():
        _input.hardwareKey(code, down: true);
        if (code == CsrdEvdev.keyEsc && widget.onEscLongPress != null) {
          _escTimer?.cancel();
          _escTimer = Timer(RemoteViewer.escHoldTime, () {
            widget.onEscLongPress?.call();
          });
        }
      case KeyUpEvent():
        _input.hardwareKey(code, down: false);
        if (code == CsrdEvdev.keyEsc) _escTimer?.cancel();
      case KeyRepeatEvent():
        // The remote repeats a key it is holding down by itself.
        break;
    }
    return KeyEventResult.handled;
  }

  // ------------------------------------------------------- touch (sink)

  @override
  void cursorMoved(double dx, double dy, Duration dt) {
    if (!_view.isReady) return;
    final gain = _acceleration.gain(dx, dy, dt);
    final scale = _view.scale;
    _touchInside = true;
    _input.moveCursorBy(dx * gain / scale, dy * gain / scale);
    // The cursor can be walked off the part of the screen showing.
    if (_view.canPan && widget.cursor.hasPosition) {
      _view.ensureVisible(widget.cursor.x, widget.cursor.y);
      _repaint();
    }
  }

  @override
  void cursorAt(double x, double y) {
    if (!_view.isReady) return;
    _touchInside = _view.remoteFromView(x, y) != null;
    final (rx, ry) = _view.remoteExactFromView(x, y);
    _input.moveCursorTo(rx, ry);
  }

  /// A tap outside the picture is not sent. Only direct mode can land
  /// there: in trackpad mode the cursor is always on the screen.
  bool get _touchClickAllowed =>
      widget.touchMode == RemoteTouchMode.trackpad || _touchInside;

  @override
  void button(int button, {required bool down}) {
    if (down) {
      if (!_touchClickAllowed || _input.blocked) return;
      _input.pointerButton(button, down: true);
      _touchSent.add(button);
    } else if (_touchSent.remove(button)) {
      _input.pointerButton(button, down: false);
    }
  }

  @override
  void click(int button) {
    if (!_touchClickAllowed) return;
    _input.click(button);
  }

  @override
  void scroll(double dx, double dy) => _input.scrollFingers(dx, dy);

  @override
  void pinch(double factor, double focalX, double focalY) {
    _view.zoomAt(factor, focalX, focalY);
    _repaint();
  }

  @override
  void panView(double dx, double dy) {
    _view.panBy(dx, dy);
    _repaint();
  }

  @override
  void haptic() {
    unawaited(HapticFeedback.mediumImpact().catchError((Object _) {}));
  }
}
