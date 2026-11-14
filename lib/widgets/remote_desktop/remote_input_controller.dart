import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../services/remote_desktop/csrd_keymap.dart';
import '../../services/remote_desktop/remote_input.dart';
import '../../services/remote_desktop/remote_input_text.dart';
import '../../services/remote_desktop/remote_screen_session.dart';
import 'remote_cursor.dart';

/// A modifier the extra-keys bar can arm for the next key.
enum RemoteModifier {
  ctrl(CsrdEvdev.keyLeftCtrl),
  alt(CsrdEvdev.keyLeftAlt),
  shift(CsrdEvdev.keyLeftShift),
  meta(CsrdEvdev.keyLeftMeta);

  const RemoteModifier(this.evdev);

  /// The key pressed to hold it.
  final int evdev;
}

/// Everything the viewer sends to the remote, in one place: the rate-limited
/// pointer, scrolling, keys with the modifiers armed on the extra-keys bar,
/// typed text, and the release of whatever is held.
///
/// Gestures and key events are turned into calls here by the widgets; this
/// is where the rules live that must hold whichever device they came from:
/// nothing goes out in view-only mode, a click always lands where the
/// pointer is shown, and what is held can always be let go of.
class RemoteInputController extends ChangeNotifier {
  RemoteInputController({
    required this.session,
    required this.cursor,
    Duration Function()? clock,
  }) : _clock = clock ?? _stopwatchClock();

  final RemoteScreenSession session;
  final RemoteCursor cursor;
  final Duration Function() _clock;

  /// How long after the person last moved the pointer the agent's idea of
  /// its position is trusted again; see [RemoteCursor].
  static const Duration localCursorHold = Duration(milliseconds: 300);

  /// Between putting text on the remote clipboard and pressing Ctrl+V.
  /// The agent hands the text to the remote's clipboard on its own thread,
  /// so a paste sent straight behind it can beat it there and paste what was
  /// on the clipboard before.
  static const Duration pasteSettle = Duration(milliseconds: 150);

  final _limiter = MoveLimiter();
  final _scroll = ScrollAccumulator();
  final _held = <int>{};
  final _heldMods = <int, List<RemoteModifier>>{};
  final _swallowUp = <int>{};
  final _sticky = <RemoteModifier>{};
  Timer? _flush;
  Timer? _localTimer;
  var _disposed = false;

  /// The remote screen's size in its own pixels, kept up to date by the
  /// viewer. The cursor cannot be moved relatively without it.
  int remoteWidth = 0;
  int remoteHeight = 0;

  /// True when nothing may be sent: the session is view-only.
  bool get blocked => _disposed || session.viewOnly;

  /// The modifiers armed for the next key.
  Set<RemoteModifier> get armed => Set.unmodifiable(_sticky);

  // ------------------------------------------------------------- pointer

  /// The person's pointer is over remote pixel ([x], [y]): shows the cursor
  /// there at once and sends the move, at most once per
  /// [remoteMoveInterval].
  void movePointer(int x, int y) => moveCursorTo(x.toDouble(), y.toDouble());

  /// Moves the cursor to a fractional position in the remote's pixels,
  /// within the screen.
  void moveCursorTo(double x, double y) {
    if (blocked || remoteWidth <= 0 || remoteHeight <= 0) return;
    final cx = x.clamp(0, remoteWidth - 1).toDouble();
    final cy = y.clamp(0, remoteHeight - 1).toDouble();
    _showLocal(cx, cy);
    final p = _limiter.push(_clock(), (cx.floor(), cy.floor()));
    if (p != null) {
      _flush?.cancel();
      session.pointerMove(p.$1, p.$2);
    } else {
      _scheduleFlush();
    }
  }

  /// Moves the cursor by ([dx], [dy]) remote pixels from where it is, for
  /// trackpad mode.
  void moveCursorBy(double dx, double dy) {
    if (blocked) return;
    moveCursorTo(
      (cursor.hasPosition ? cursor.x : remoteWidth / 2) + dx,
      (cursor.hasPosition ? cursor.y : remoteHeight / 2) + dy,
    );
  }

  /// Puts the remote pointer exactly where the cursor is shown, whatever the
  /// rate limit says. A click calls this first.
  void _settlePointer() {
    if (!cursor.hasPosition) return;
    final p = _limiter.force(_clock(), (cursor.x.floor(), cursor.y.floor()));
    _flush?.cancel();
    if (p != null) session.pointerMove(p.$1, p.$2);
  }

  /// [button] (a `CsrdButton`) goes down or up at the cursor.
  void pointerButton(int button, {required bool down}) {
    if (blocked) return;
    _settlePointer();
    session.pointerButton(button, down: down);
  }

  /// A click of [button] at the cursor.
  void click(int button) {
    if (blocked) return;
    _settlePointer();
    session.pointerButton(button, down: true);
    session.pointerButton(button, down: false);
  }

  /// A mouse wheel turned: `PointerScrollEvent.scrollDelta`.
  void scrollWheel(double dx, double dy) =>
      _sendScroll(_scroll.addWheel(dx, dy));

  /// Fingers moved on glass or a trackpad.
  void scrollFingers(double dx, double dy) =>
      _sendScroll(_scroll.addFingers(dx, dy));

  void _sendScroll((int, int)? units) {
    if (blocked) {
      _scroll.reset();
      return;
    }
    if (units != null) session.scroll(units.$1, units.$2);
  }

  /// A display switch: the old position and what was held back for it mean
  /// nothing on the new screen.
  void resetPointer() {
    _limiter.reset();
    _flush?.cancel();
    _scroll.reset();
    cursor.clearPosition();
  }

  void _showLocal(double x, double y) {
    cursor.setLocal(x, y);
    _localTimer?.cancel();
    _localTimer = Timer(localCursorHold, cursor.releaseLocal);
  }

  /// A move that arrived too soon is sent when it is due, so the pointer
  /// always ends up where the person stopped it.
  void _scheduleFlush() {
    if (_flush?.isActive ?? false) return;
    final deadline = _limiter.deadline;
    if (deadline == null) return;
    final wait = deadline - _clock();
    _flush = Timer(wait.isNegative ? Duration.zero : wait, () {
      if (blocked) return;
      final p = _limiter.takePending(_clock());
      if (p != null) session.pointerMove(p.$1, p.$2);
    });
  }

  // -------------------------------------------------------------- keys

  /// A key from a hardware keyboard, by evdev code. With a modifier armed
  /// on the extra-keys bar the key is typed with it instead, as one stroke,
  /// and its release is dropped.
  void hardwareKey(int evdev, {required bool down}) {
    if (blocked) return;
    if (down) {
      if (_sticky.isNotEmpty && !_isModifierKey(evdev)) {
        _swallowUp.add(evdev);
        tapKey(evdev);
        return;
      }
      _held.add(evdev);
      session.key(evdev, down: true);
    } else {
      if (_swallowUp.remove(evdev)) return;
      // A release for a key this side never pressed (it went down before
      // the viewer had focus) is not the remote's business.
      if (_held.remove(evdev)) session.key(evdev, down: false);
    }
  }

  /// Presses and releases [evdev], with the armed modifiers and then
  /// [modifiers] held around it. The armed ones are used up.
  void tapKey(int evdev, {Iterable<RemoteModifier> modifiers = const []}) {
    if (blocked) return;
    final mods = _takeModifiers(modifiers);
    for (final m in mods) {
      session.key(m.evdev, down: true);
    }
    session.key(evdev, down: true);
    session.key(evdev, down: false);
    for (final m in mods.reversed) {
      session.key(m.evdev, down: false);
    }
  }

  /// Presses [evdev] and keeps it down until [releaseKey]: a held arrow
  /// key, whose repeating the remote does itself.
  void holdKey(int evdev) {
    if (blocked || _held.contains(evdev)) return;
    final mods = _takeModifiers(const []);
    for (final m in mods) {
      session.key(m.evdev, down: true);
    }
    _heldMods[evdev] = mods;
    _held.add(evdev);
    session.key(evdev, down: true);
  }

  void releaseKey(int evdev) {
    if (!_held.remove(evdev)) return;
    final mods = _heldMods.remove(evdev) ?? const [];
    if (blocked) return;
    session.key(evdev, down: false);
    for (final m in mods.reversed) {
      session.key(m.evdev, down: false);
    }
  }

  /// Types a soft keyboard's change: Backspace for each character removed,
  /// then the new text as key strokes (see `remote_input_text.dart`).
  /// Returns the characters that could not be typed.
  List<String> typeChange(EditingChange change) {
    if (blocked) return const [];
    for (var i = 0; i < change.deleted; i++) {
      tapKey(CsrdEvdev.keyBackspace);
    }
    return typeText(change.inserted);
  }

  /// Types [text] as key strokes, a US-layout key for each character. The
  /// first one carries any armed modifier. Returns the characters that have
  /// no key and were skipped.
  List<String> typeText(String text) {
    if (blocked) return const [];
    final plan = keystrokesForText(text);
    for (final s in plan.strokes) {
      tapKey(
        s.evdev,
        modifiers: s.shift ? const [RemoteModifier.shift] : const [],
      );
    }
    return plan.untypable;
  }

  /// Puts [text] on the remote clipboard and pastes it with Ctrl+V.
  Future<void> pasteToRemote(String text) async {
    if (blocked) return;
    session.sendClipboard(text);
    await Future<void>.delayed(pasteSettle);
    if (blocked) return;
    tapKey(CsrdEvdev.keyV, modifiers: const [RemoteModifier.ctrl]);
  }

  /// Arms [modifier] for the next key, or disarms it.
  void toggleModifier(RemoteModifier modifier) {
    if (!_sticky.remove(modifier)) _sticky.add(modifier);
    notifyListeners();
  }

  /// The armed ones, then [extra], without repeats, in a fixed order, and
  /// the armed ones used up.
  List<RemoteModifier> _takeModifiers(Iterable<RemoteModifier> extra) {
    final wanted = {..._sticky, ...extra};
    if (_sticky.isNotEmpty) {
      _sticky.clear();
      notifyListeners();
    }
    return [
      for (final m in RemoteModifier.values)
        if (wanted.contains(m)) m,
    ];
  }

  static bool _isModifierKey(int evdev) =>
      evdev == CsrdEvdev.keyLeftCtrl ||
      evdev == CsrdEvdev.keyRightCtrl ||
      evdev == CsrdEvdev.keyLeftAlt ||
      evdev == CsrdEvdev.keyRightAlt ||
      evdev == CsrdEvdev.keyLeftShift ||
      evdev == CsrdEvdev.keyRightShift ||
      evdev == CsrdEvdev.keyLeftMeta ||
      evdev == CsrdEvdev.keyRightMeta;

  /// Lets go of everything held, here and on the remote: for focus lost, the
  /// app leaving the foreground, view-only going on, and the screen closing.
  void releaseAll() {
    _held.clear();
    _heldMods.clear();
    _swallowUp.clear();
    _scroll.reset();
    _flush?.cancel();
    if (_sticky.isNotEmpty) {
      _sticky.clear();
      if (!_disposed) notifyListeners();
    }
    if (!blocked) session.releaseAll();
  }

  @override
  void dispose() {
    _disposed = true;
    _flush?.cancel();
    _localTimer?.cancel();
    super.dispose();
  }

  static Duration Function() _stopwatchClock() {
    final watch = Stopwatch()..start();
    return () => watch.elapsed;
  }
}
