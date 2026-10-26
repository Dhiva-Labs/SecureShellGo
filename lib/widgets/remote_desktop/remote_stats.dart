import 'dart:collection';

/// A rolling one-second count of frames and bytes, for the small readout in
/// the toolbar.
///
/// Times are passed in rather than read, from any monotonic clock, so the
/// window is tested with made-up ones.
class RemoteStatsMeter {
  RemoteStatsMeter({this.window = const Duration(seconds: 1)});

  final Duration window;
  final _samples = ListQueue<(Duration, int)>();
  var _bytes = 0;

  /// A frame of [wireBytes] compressed bytes arrived at [now].
  void addFrame(Duration now, int wireBytes) {
    _samples.add((now, wireBytes));
    _bytes += wireBytes;
    _expire(now);
  }

  /// Frames in the window ending at [now].
  int fps(Duration now) {
    _expire(now);
    return _samples.length;
  }

  /// Compressed bytes per second over the window ending at [now].
  int bytesPerSecond(Duration now) {
    _expire(now);
    return (_bytes * 1000000 / window.inMicroseconds).round();
  }

  void clear() {
    _samples.clear();
    _bytes = 0;
  }

  void _expire(Duration now) {
    while (_samples.isNotEmpty && now - _samples.first.$1 >= window) {
      _bytes -= _samples.removeFirst().$2;
    }
  }
}
