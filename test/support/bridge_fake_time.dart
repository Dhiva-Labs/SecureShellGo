import 'dart:async';

/// A clock and timers moved by hand, for `BridgeApprovals` and
/// `BridgeGrants`: tests advance time instead of sleeping.
class FakeTime {
  FakeTime([DateTime? start]) : now = start ?? DateTime.utc(2026, 11, 15, 12);

  DateTime now;
  final List<FakeTimer> _timers = [];

  DateTime clock() => now;

  Timer timer(Duration delay, void Function() callback) {
    final t = FakeTimer._(this, now.add(delay), callback);
    _timers.add(t);
    return t;
  }

  /// Timers not yet run or cancelled.
  int get activeTimers => _timers.where((t) => t.isActive).length;

  /// Moves the clock by [by], running every timer that falls due, in order
  /// of due time, with the clock set to each one's due time as it runs.
  void advance(Duration by) {
    final end = now.add(by);
    while (true) {
      final due =
          _timers.where((t) => t.isActive && !t._due.isAfter(end)).toList()
            ..sort((a, b) => a._due.compareTo(b._due));
      if (due.isEmpty) break;
      final next = due.first;
      if (next._due.isAfter(now)) now = next._due;
      next._fire();
    }
    now = end;
  }
}

class FakeTimer implements Timer {
  FakeTimer._(this._owner, this._due, this._callback);

  final FakeTime _owner;
  final DateTime _due;
  final void Function() _callback;
  bool _active = true;

  void _fire() {
    if (!_active) return;
    _active = false;
    _owner._timers.remove(this);
    _callback();
  }

  @override
  void cancel() {
    _active = false;
    _owner._timers.remove(this);
  }

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}
