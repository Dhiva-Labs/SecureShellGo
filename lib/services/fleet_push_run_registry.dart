import 'dart:async';

import 'fleet_push_service.dart';

/// Keeps the most recent fan-out push reachable after the screen that
/// started it has been left — how the transfer panel finds its way back
/// into a push that is still running, or to its summary shortly after it
/// finishes. The same role `TransferHub` plays for ordinary per-session
/// transfers, at a much smaller scale: there is only ever one fan-out worth
/// pointing at, not one per session.
///
/// Holds at most one. A [FleetPushScreen] that starts a second push while
/// this is still holding the first [register]s over it, disposing the one
/// being replaced — a push nobody can reach any more is not worth keeping
/// its stream open for.
///
/// Free of Flutter imports, like the rest of `services/`.
class FleetPushRunRegistry {
  FleetPushService? _current;
  final _changes = StreamController<void>.broadcast();

  /// Fires whenever [current] changes identity — a new push registered, or
  /// the current one cleared. Does not fire on that push's own internal
  /// progress; a listener that wants live progress watches
  /// `current!.changes` itself once it has the instance.
  Stream<void> get changes => _changes.stream;

  FleetPushService? get current => _current;

  void register(FleetPushService service) {
    if (identical(_current, service)) return;
    _current?.dispose();
    _current = service;
    _notify();
  }

  /// Drops [service] if it is still the current one. Not called
  /// automatically when a push finishes — a finished push is still worth
  /// being able to open and read the summary of until the user dismisses it
  /// (the results screen's own "Done").
  void clear(FleetPushService service) {
    if (!identical(_current, service)) return;
    _current = null;
    service.dispose();
    _notify();
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  void dispose() {
    _current?.dispose();
    unawaited(_changes.close());
  }
}
