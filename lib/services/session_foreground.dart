import 'dart:async';

import 'package:flutter/services.dart';

/// The platform half of the "a session is open" foreground service.
///
/// An interface rather than a bare [MethodChannel] call for the usual reason
/// in this codebase: the interesting logic is the *decision* about when to
/// start and stop, and that decision should be testable without a device.
abstract class SessionForegroundChannel {
  /// Promotes the app to a foreground service, labelled with [label].
  Future<void> start(String label);

  /// Drops back out of the foreground and removes the notification.
  Future<void> stop();
}

/// The real channel. Mirrors `keep_awake.dart`: one small hand-written channel
/// rather than a plugin such as `flutter_foreground_task`, which is the
/// standing policy for Android platform work in this project — see
/// `StorageBridge.kt` for why. The Kotlin side is
/// `SessionForegroundService.kt`, wired up in `MainActivity`.
class MethodChannelSessionForeground implements SessionForegroundChannel {
  const MethodChannelSessionForeground();

  static const MethodChannel channel =
      MethodChannel('com.dhivalabs.secure_shell_go/session_service');

  @override
  Future<void> start(String label) => _invoke('start', <String, dynamic>{
        'label': label,
      });

  @override
  Future<void> stop() => _invoke('stop', const <String, dynamic>{});

  static Future<void> _invoke(String method, Map<String, dynamic> args) async {
    try {
      await channel.invokeMethod<void>(method, args);
    } on MissingPluginException {
      // Desktop and unit-test runs: there is no service to promote.
    } on PlatformException {
      // The service is what keeps the *process* alive; if the platform
      // refuses (a background start restriction, notifications disabled at the
      // OS level) the session itself is still perfectly usable, so this is not
      // worth interrupting the user over.
    }
  }
}

/// Decides when the foreground service should be running.
///
/// The rule is a plain reference count: the service starts when the first
/// session opens and stops when the last one closes. The app only allows one
/// session at a time today, but the count is here anyway because the two
/// things that would break a naive boolean are both already reachable —
/// a `SessionScreen` pushed while another is still on the navigator stack
/// (its `dispose` would stop the service out from under the live one), and
/// the ordinary teardown order, where the *new* screen's `initState` runs
/// before the *old* screen's `dispose`.
///
/// Platform calls are chained onto a single future rather than fired in
/// parallel, so an acquire immediately followed by a release can never arrive
/// at the platform as stop-then-start and leave a stranded notification.
class SessionForegroundController {
  SessionForegroundController({SessionForegroundChannel? channel})
      : _channel = channel ?? const MethodChannelSessionForeground();

  /// The process-wide count. The service is a property of the process, not of
  /// any one route, so — unlike the stores built in `main.dart` — this one
  /// genuinely is a singleton rather than something passed down by
  /// constructor. Screens still take it as an optional parameter so tests can
  /// substitute their own.
  static final SessionForegroundController instance =
      SessionForegroundController();

  final SessionForegroundChannel _channel;

  var _holders = 0;
  Future<void> _pending = Future<void>.value();

  /// How many live sessions are currently holding the service open.
  int get holders => _holders;

  /// Whether the service should be running right now.
  bool get isRunning => _holders > 0;

  /// Registers one more live session. Starts the service on the 0 → 1 edge,
  /// naming it after [label]; later acquires only bump the count, so the
  /// notification keeps naming the session that opened first.
  Future<void> acquire(String label) {
    _holders++;
    if (_holders > 1) return _pending;
    return _enqueue(() => _channel.start(label));
  }

  /// Re-labels a service that is already running, without touching the count.
  ///
  /// [acquire] deliberately only labels on the 0 → 1 edge — a second session
  /// must not be able to rename a notification out from under the first as a
  /// side effect of opening. But once several sessions *are* open, "MyLinuxPC"
  /// is no longer what the notification is about, so the session manager says
  /// so explicitly through here ("2 sessions connected"), and says it again
  /// when closing one takes the count back to a single named host.
  ///
  /// A no-op when nothing holds the service: there is no notification to
  /// rename, and starting one here would strand it.
  Future<void> relabel(String label) {
    if (_holders == 0) return _pending;
    return _enqueue(() => _channel.start(label));
  }

  /// Releases one session. Stops the service on the 1 → 0 edge. A release
  /// without a matching acquire is ignored rather than driving the count
  /// negative, so a double `dispose` cannot stop a service another route owns.
  Future<void> release() {
    if (_holders == 0) return _pending;
    _holders--;
    if (_holders > 0) return _pending;
    return _enqueue(_channel.stop);
  }

  Future<void> _enqueue(Future<void> Function() action) {
    return _pending = _pending.then((_) => action()).catchError((Object _) {
      // The channel already swallows the failures worth swallowing; this is
      // only here so one bad call cannot poison every later one in the chain.
    });
  }
}
