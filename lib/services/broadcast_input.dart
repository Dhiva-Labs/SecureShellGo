import 'dart:async';

import 'terminal_workspace.dart';

/// "Type once, send to every visible pane."
///
/// The workspace already answers both halves of the question — [
/// TerminalWorkspace.visibleSessionIds] is which shells are on screen and
/// [TerminalWorkspace.writeToVisibleSessions] puts bytes in all of them — so
/// what is left, and all that is here, is *policy*: whether the feature is on,
/// which keystrokes are eligible, and the two guards that stop a broadcast
/// from feeding itself.
///
/// Free of Flutter imports like the rest of `services/`, which is what lets
/// the interesting behaviour be tested against a workspace of fake
/// [WorkspaceSession]s rather than through a widget tree and a live shell.
///
/// **Default off, and off again the moment it stops making sense.** The risk
/// this feature carries is not subtle — it is `rm -rf` arriving on a
/// production box because the user forgot which mode they were in — so the
/// state is never sticky: it cannot be turned on outside a split, it turns
/// itself off when the split collapses, and it is built per-visit to the
/// sessions screen, so walking away and coming back always finds it off.
class BroadcastInput {
  BroadcastInput({required TerminalWorkspace workspace})
      : _workspace = workspace {
    _watch = workspace.changes.listen((_) => _handleWorkspaceChange());
  }

  final TerminalWorkspace _workspace;
  late final StreamSubscription<void> _watch;

  final _changes = StreamController<void>.broadcast();

  /// Fires when the toggle changes — including when it turns *itself* off.
  Stream<void> get changes => _changes.stream;

  /// Whether keystrokes are being mirrored right now.
  bool get enabled => _enabled;
  var _enabled = false;

  /// Guards against a broadcast being mistaken for typing.
  ///
  /// A mirrored keystroke is delivered by writing into another session's
  /// terminal, which is — deliberately, so that it is indistinguishable from
  /// real input — the same path a real keystroke takes. That session's own
  /// input tap therefore fires, and without this flag it would ask to
  /// broadcast in turn. The focus check below already refuses that, so this is
  /// the second of two locks on the same door: cheap, and the kind of loop
  /// that is very unpleasant to debug from a bug report.
  var _delivering = false;

  /// How many panes a keystroke would land in, the focused one included.
  ///
  /// Counting the pane being typed into is what makes the chip's number match
  /// what the user sees: four panes lit up red is "broadcasting to 4 panes",
  /// not to 3.
  int get targetCount => _workspace.visibleSessionIds.length;

  /// Whether the toggle should be offered at all. One pane is not a broadcast.
  bool get isAvailable => _workspace.isSplit;

  /// Turns mirroring on or off. Refuses to turn on outside a split, so the
  /// state can never be true while the UI that explains it is not on screen.
  void setEnabled(bool value) {
    final next = value && isAvailable;
    if (next == _enabled) return;
    _enabled = next;
    _notify();
  }

  void toggle() => setEnabled(!_enabled);

  /// The workspace changed shape. The only thing that matters here is a split
  /// collapsing back to one pane: leaving the toggle armed would mean the next
  /// split silently resumed broadcasting, with the chip appearing at the same
  /// moment the user was doing something else entirely.
  void _handleWorkspaceChange() {
    if (_enabled && !isAvailable) setEnabled(false);
  }

  /// [data] was just typed into [sourceSessionId]. Mirrors it into every
  /// *other* visible pane and returns how many took it.
  ///
  /// Returns 0 — doing nothing at all — in every case that is not
  /// unambiguously a person typing into the pane they are looking at:
  ///
  ///  * the feature is off;
  ///  * this is itself a mirrored keystroke arriving ([_delivering]);
  ///  * the source is not the focused pane. Panes other than the focused one
  ///    can still emit — a background program answering a query, a mouse
  ///    report — and none of that is the user typing;
  ///  * the payload is a mouse report ([isMouseReport]).
  int handleInput(String sourceSessionId, String data) {
    if (!_enabled || _delivering || data.isEmpty) return 0;
    if (sourceSessionId != _workspace.focusedSessionId) return 0;
    if (isMouseReport(data)) return 0;

    _delivering = true;
    try {
      // `skipFocused` is what stops the pane the user is actually typing in
      // from receiving its own keystroke twice: xterm has already delivered it
      // there, which is how it got here.
      return _workspace.writeToVisibleSessions(data, skipFocused: true);
    } finally {
      _delivering = false;
    }
  }

  /// Whether [data] is a mouse report on its way to a program that asked for
  /// mouse tracking.
  ///
  /// These come out of the same `Terminal.onOutput` door as keystrokes but
  /// they are not keystrokes: a report says "button 1 went down at row 12,
  /// column 40 *of this pane*", and the coordinates mean nothing in a pane of
  /// a different size running a different program. Mirroring one would move
  /// another server's `vim` cursor to a point the user never clicked.
  ///
  /// Matches the two encodings xterm emits: SGR (`CSI < b ; x ; y M|m`, the
  /// modern default) and X10 (`CSI M` followed by three raw bytes).
  static bool isMouseReport(String data) {
    if (data.startsWith('\x1b[M')) return true;
    if (!data.startsWith('\x1b[<')) return false;
    return data.endsWith('M') || data.endsWith('m');
  }

  void _notify() {
    if (_changes.isClosed) return;
    _changes.add(null);
  }

  Future<void> dispose() async {
    await _watch.cancel();
    await _changes.close();
  }
}
