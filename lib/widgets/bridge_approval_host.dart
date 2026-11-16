import 'dart:async';

import 'package:flutter/material.dart';

import '../services/bridge/bridge_approvals.dart';
import 'bridge_approval_card.dart';

/// Shows the AI Bridge's approval cards over whatever screen is in front.
///
/// Mounted once, from `main.dart`, with the app's navigator key, the same way
/// the vault passphrase dialog and the host-key dialog are raised from
/// wherever a service needs them. It listens to [BridgeApprovals.pending] and
/// keeps one card on screen while anything is waiting: the oldest request,
/// with "N more waiting" for the rest. When one is answered the next takes
/// its place in the same dialog, and the card's Allow buttons arm again.
///
/// ## Never above, never under, the lock
///
/// A locked app shows no card. The service withdraws every request when the
/// app locks; this also closes the dialog on the lock, and does not raise one
/// while [isLocked]. A dialog left under the lock screen would still take
/// key presses (the lock only absorbs pointers), so it is removed, not
/// covered.
class BridgeApprovalHost {
  BridgeApprovalHost({
    required this.navigatorKey,
    required this.approvals,
    required this.isLocked,
    required this.lockChanges,
    required this.timedMinutes,
    this.clock = DateTime.now,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final BridgeApprovals approvals;

  /// Whether the app lock is up now.
  final bool Function() isLocked;

  /// The lock going up or coming down.
  final Stream<bool> lockChanges;

  /// `AppSettings.bridgeTimedApprovalMinutes`, read when a card is drawn.
  final int Function() timedMinutes;
  final DateTime Function() clock;

  final ValueNotifier<List<BridgeApprovalRequest>> _list =
      ValueNotifier<List<BridgeApprovalRequest>>(const []);
  StreamSubscription<List<BridgeApprovalRequest>>? _pending;
  StreamSubscription<bool>? _lock;
  Route<void>? _route;
  bool _disposed = false;

  /// Starts listening.
  void start() {
    _pending ??= approvals.pending.listen((list) {
      _list.value = list;
      _sync();
    });
    _lock ??= lockChanges.listen((_) => _sync());
  }

  /// Whether a card is on screen.
  bool get isShowing => _route != null;

  void _sync() {
    if (_disposed) return;
    final show = !isLocked() && _list.value.isNotEmpty;
    if (show && _route == null) {
      _show();
    } else if (!show && _route != null) {
      _close();
    }
  }

  void _show() {
    final navigator = navigatorKey.currentState;
    final context = navigatorKey.currentContext;
    if (navigator == null || context == null) {
      // Before the first frame: try again once there is a navigator.
      WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
      return;
    }
    final route = DialogRoute<void>(
      context: context,
      // A tap beside the card does nothing: only a button, Escape or back
      // answers, and the last two are a no.
      barrierDismissible: false,
      builder: (_) => ValueListenableBuilder<List<BridgeApprovalRequest>>(
        valueListenable: _list,
        builder: (context, list, _) {
          if (list.isEmpty || isLocked()) return const SizedBox.shrink();
          final first = list.first;
          return BridgeApprovalCard(
            // A new key per request: state, and with it the Allow buttons'
            // one-second wait, starts over for each.
            key: ValueKey(first.id),
            request: first,
            waiting: list.length - 1,
            timedMinutes: timedMinutes(),
            clock: clock,
            onAnswer: (answer) => approvals.answer(first.id, answer),
            // The service has already denied; the stream drops it.
            onExpired: () =>
                approvals.answer(first.id, BridgeApprovalAnswer.deny),
          );
        },
      ),
    );
    _route = route;
    unawaited(
      navigator.push(route).whenComplete(() {
        if (identical(_route, route)) {
          _route = null;
          // Removed by something else while requests wait: raise it again.
          if (!_disposed) {
            WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
          }
        }
      }),
    );
  }

  void _close() {
    final route = _route;
    if (route == null) return;
    _route = null;
    navigatorKey.currentState?.removeRoute(route);
  }

  Future<void> dispose() async {
    _disposed = true;
    await _pending?.cancel();
    await _lock?.cancel();
    _close();
    _list.dispose();
  }
}
