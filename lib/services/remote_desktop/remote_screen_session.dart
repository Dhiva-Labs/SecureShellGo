import 'csrd_client.dart';
import 'csrd_messages.dart';

/// What the remote-desktop screen needs from a remote screen, whichever
/// protocol carries it.
///
/// [CsrdClient] is the one that matters: CrossShell's agent, which the app
/// uploads and runs for the session. A VNC client implements this too, for
/// the Macs whose only way in is their built-in Screen Sharing. The screen
/// and the compositor are written against this, so neither knows which.
///
/// Events, frames included, are [CsrdEvent]s whatever the protocol: a
/// backend that speaks something else translates into them, so there is
/// one decoded-frame shape for the compositor to draw.
///
/// Input is in the agent's terms, evdev key codes and its button numbers
/// (see `CsrdButton`). A backend that wants something else, X keysyms for
/// VNC, maps them itself, where it knows what it needs.
abstract interface class RemoteScreenSession {
  /// Broadcast, so listen before the session is connected: a frame nobody
  /// was listening for is lost, and an unacknowledged one stalls the
  /// stream. [CsrdClosedEvent] is always last.
  Stream<CsrdEvent> get events;

  CsrdClientState get state;

  /// Completes once the session has ended, for whatever reason.
  Future<CsrdCloseReason> get done;

  List<CsrdDisplayInfo> get displays;

  /// The display being shown, or null before the session has started.
  int? get display;

  CsrdQuality get quality;

  /// Whether [selectDisplay] can change the quality. VNC has no such knob,
  /// so the screen hides the control rather than offer one that does
  /// nothing.
  bool get supportsQuality;

  /// The last measured round trip, or null before there is one.
  Duration? get rtt;

  /// Input is not sent while this is on. Turning it on releases whatever
  /// is held first.
  bool get viewOnly;
  set viewOnly(bool value);

  /// True when the remote side said view-only and it cannot be turned off
  /// from here.
  bool get viewOnlyLocked;

  void selectDisplay(int display, {CsrdQuality? quality, int? maxFps});

  /// Says frame [seq] is on screen. Cumulative.
  void ackFrame(int seq);

  void pointerMove(int x, int y);

  /// [button] is a `CsrdButton` value, not Flutter's bit order.
  void pointerButton(int button, {required bool down});

  /// In 1/120-notch units; positive [dy] scrolls up.
  void scroll(int dx, int dy);

  /// [evdevCode] is a Linux evdev key code (see `csrd_keymap.dart`).
  void key(int evdevCode, {required bool down});

  void releaseAll();

  void sendClipboard(String text);

  /// Releases held input, then ends the session and closes its transport.
  Future<CsrdCloseReason> close({String? error});
}

/// How far opening a remote screen has got, for the screen to show while
/// it waits: "Uploading the agent…", "Starting the virtual desktop…".
typedef RemoteScreenProgress = void Function(String status);

/// An opened remote screen, and how to let go of what was started for it.
class RemoteScreenHandle {
  const RemoteScreenHandle({
    required this.session,
    required this.release,
    this.title,
    this.keepsRunning = false,
  });

  /// Already connected: the opener connects it, after the screen has had
  /// the chance to listen (see [RemoteScreenOpener]).
  final RemoteScreenSession session;

  /// Stops whatever was started on the remote for this screen: the agent,
  /// and for a virtual desktop its X server and programs. Called once the
  /// screen is done with [session], and safe to call more than once. For a
  /// virtual desktop kept running after disconnect it only detaches.
  final Future<void> Function() release;

  /// What the screen's title bar should call this, when it is something
  /// more specific than the host's name: "Virtual desktop :3".
  final String? title;

  /// True for a virtual desktop that outlives this screen, so the screen
  /// can say so on the way out instead of implying it was stopped.
  final bool keepsRunning;
}

/// Opens a remote screen: deploys and launches whatever the remote needs,
/// opens the channel to it and connects.
///
/// [attach] is called with the session after it is made and before it is
/// connected, which is the screen's one chance to start listening before
/// the first frame can arrive. Throws with a message fit to show when the
/// screen cannot be opened.
typedef RemoteScreenOpener = Future<RemoteScreenHandle> Function({
  required RemoteScreenProgress progress,
  required void Function(RemoteScreenSession session) attach,
});
