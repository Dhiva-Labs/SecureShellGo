/// Who is at the keyboard of a session an AI assistant opened through the
/// AI Bridge (`bridge/bridge_terminals.dart`).
///
/// - [driving]: the assistant types into it and reads it; the user watches
///   and can take over or stop it at any moment.
/// - [takenOver]: the user took it over (with the Take over button, or by
///   typing into it). The assistant can no longer type into it or read it;
///   the session is the user's, and stays open.
/// - [ended]: the assistant's terminal is over (closed, stopped, idle, the
///   connection dropped, the shell exited, the bridge switched off…). The
///   session may still be on screen, showing how it ended.
enum AssistantDriveState { driving, takenOver, ended }

/// The marker on a session an AI assistant drives: which paired assistant,
/// which terminal, and who has the keyboard now. Set on a
/// `SessionController` (its `assistantDrive`) only by the AI Bridge, and
/// read by the session tab to show a banner with Take over and Stop.
///
/// Pure Dart. It only ever moves forward: [driving] → [takenOver] or
/// [ended], and [takenOver] → [ended]; nothing hands the keyboard back to
/// the assistant.
class AssistantDrive {
  AssistantDrive({
    required this.terminalId,
    required this.clientId,
    required this.clientName,
    required this.hostName,
  });

  /// The id the assistant uses for this terminal; what Take over and Stop
  /// pass to `BridgeTerminals`.
  final String terminalId;

  /// The paired assistant driving it.
  final String clientId;

  /// Its name, for the banner.
  final String clientName;

  /// The host's name as the assistant knows it.
  final String hostName;

  AssistantDriveState get state => _state;
  AssistantDriveState _state = AssistantDriveState.driving;

  /// True while the assistant has the keyboard.
  bool get isDriving => _state == AssistantDriveState.driving;

  /// Why it [AssistantDriveState.ended], in a few words for the banner, or
  /// null.
  String? get endedReason => _endedReason;
  String? _endedReason;

  final List<void Function()> _listeners = [];

  /// Called, synchronously, after every change of [state].
  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) => _listeners.remove(listener);

  /// The user typed into the session while the assistant was driving it:
  /// that keystroke takes the keyboard, so two typists never interleave.
  /// Called by the session on the way from the user's keyboard to the
  /// shell, before the keystroke is sent. True when this took it over.
  bool userTyped() => takeOver();

  /// The user pressed Take over (or typed). False when the assistant was not
  /// driving.
  bool takeOver() {
    if (_state != AssistantDriveState.driving) return false;
    _state = AssistantDriveState.takenOver;
    _changed();
    return true;
  }

  /// The assistant's terminal is over. Idempotent; [reason] is kept from the
  /// first call that ends it.
  void end(String reason) {
    if (_state == AssistantDriveState.ended) return;
    _state = AssistantDriveState.ended;
    _endedReason = reason;
    _changed();
  }

  void _changed() {
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }
}
