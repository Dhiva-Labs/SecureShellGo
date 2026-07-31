import 'dart:async';

import 'package:flutter/material.dart';

import '../services/app_lock_controller.dart';
import '../theme.dart';

/// The full-screen gate that covers the app while it is locked.
///
/// ## An overlay, not a route
///
/// This sits above the [Navigator] (installed through `MaterialApp.builder`)
/// rather than being pushed onto it, and that is the whole design.
///
/// A pushed lock route would be a route like any other: the system back
/// gesture, a `Navigator.pop` from a stray callback, or a deep link could all
/// take it off the stack, and each of those is a way past the lock. There is
/// no stack entry here to pop, so there is nothing to pop past. The
/// [PopScope] below then catches the remaining case — a back gesture with
/// nothing above it — so the button cannot close the app out from under a
/// live session either.
///
/// ## What is left running underneath
///
/// The app stays in the widget tree, so SSH sessions, SFTP transfers and port
/// forwards all keep running while the gate is up. A lock is a lock, not a
/// disconnect. It is wrapped in an [AbsorbPointer] and an [ExcludeSemantics]
/// so that nothing underneath can be touched or read out by a screen reader
/// while it is covered.
///
/// ## Not leaking what is behind
///
/// The cover is fully opaque — a solid fill, not a blur and not a translucent
/// scrim. A blur is a reversible transform of the pixels it is hiding, and
/// "mostly unreadable" is not a security property worth relying on when a
/// terminal full of production hostnames is the thing being hidden.
///
/// The other half of that is the OS screenshot buffer, which this widget
/// cannot reach: the recent-apps thumbnail is taken by the system as the app
/// is backgrounded. `AppLockBridge.kt` sets `FLAG_SECURE` for as long as the
/// lock is switched on, which is what keeps the terminal out of the app
/// switcher and out of screenshots.
class AppLockGate extends StatefulWidget {
  const AppLockGate({
    super.key,
    required this.controller,
    required this.child,
  });

  final AppLockController controller;
  final Widget child;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate>
    with WidgetsBindingObserver {
  StreamSubscription<AppLockState>? _subscription;

  /// Ticks only while a cooldown is counting down, so an idle lock screen is
  /// not rebuilding once a second for nothing.
  Timer? _cooldownTicker;

  /// Whether the sheet has already been raised for the current lock.
  ///
  /// Without this, [_promptIfNeeded] and the change listener chase each
  /// other: a dismissed sheet reports `cancelled`, which emits a new locked
  /// state, which fires the listener, which raises the sheet again — an
  /// unclosable prompt the user cannot get out of. Reset when the gate opens,
  /// and again when the app is brought back to the foreground, so a genuine
  /// return to a locked app still gets its prompt.
  bool _autoPrompted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _subscription = widget.controller.changes.listen((_) {
      if (!mounted) return;
      setState(_syncCooldownTicker);
      _promptIfNeeded();
    });
    _promptIfNeeded();
  }

  @override
  void dispose() {
    _cooldownTicker?.cancel();
    unawaited(_subscription?.cancel());
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Swallows the system back button while the gate is up.
  ///
  /// This, rather than a [PopScope], because the gate lives *above* the
  /// [Navigator] (installed through `MaterialApp.builder`) and a `PopScope`
  /// only does anything with an enclosing `ModalRoute` to register itself
  /// with — up here there is none, so one would sit in the tree looking
  /// protective and doing nothing.
  ///
  /// [WidgetsBinding] offers every observer a back press before the navigator
  /// sees it, and returning true ends the dispatch. So while locked, back
  /// neither pops a route underneath the cover nor closes the app out from
  /// under a live session.
  @override
  Future<bool> didPopRoute() async {
    if (widget.controller.isLocked) return true;
    return super.didPopRoute();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // `paused`/`hidden` rather than `inactive`: on both Android and desktop,
    // `inactive` fires for things that are not the user leaving — a
    // notification shade pulled halfway down, a permission dialog, a window
    // losing focus for a moment — and locking on those would be maddening
    // with the timeout set to Immediately.
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        widget.controller.onBackgrounded();
      case AppLifecycleState.resumed:
        widget.controller.onForegrounded();
        // Coming back to a locked app should raise the sheet again, even if
        // one was already dismissed before leaving.
        _autoPrompted = false;
        _promptIfNeeded();
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  /// Raises the OS sheet as soon as the gate goes up, so the common case is
  /// one glance at a fingerprint reader rather than a tap and then a glance.
  void _promptIfNeeded() {
    final controller = widget.controller;
    if (!controller.isLocked) {
      _autoPrompted = false;
      return;
    }
    if (_autoPrompted) return;
    if (controller.state.phase == AppLockPhase.authenticating) return;
    if (controller.isInCooldown()) return;
    _autoPrompted = true;
    unawaited(controller.authenticate());
  }

  void _syncCooldownTicker() {
    final running = widget.controller.isInCooldown();
    if (running && _cooldownTicker == null) {
      _cooldownTicker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() {});
        if (!widget.controller.isInCooldown()) {
          _cooldownTicker?.cancel();
          _cooldownTicker = null;
        }
      });
    } else if (!running) {
      _cooldownTicker?.cancel();
      _cooldownTicker = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final locked = widget.controller.isLocked;
    return Stack(
      children: [
        // Still built, still running: the sessions behind this are the whole
        // reason the lock is not a disconnect.
        ExcludeSemantics(
          excluding: locked,
          child: AbsorbPointer(absorbing: locked, child: widget.child),
        ),
        if (locked)
          _LockCover(
            controller: widget.controller,
            onUnlock: () => unawaited(widget.controller.authenticate()),
          ),
      ],
    );
  }
}

class _LockCover extends StatelessWidget {
  const _LockCover({required this.controller, required this.onUnlock});

  final AppLockController controller;
  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cooling = controller.isInCooldown();
    final remaining = controller.cooldownRemaining();
    final busy = controller.state.phase == AppLockPhase.authenticating;

    // Back is handled in [_AppLockGateState.didPopRoute], not by a PopScope —
    // see the note there on why one would be inert at this level.
    return Material(
      // Opaque, and the app's own background rather than a scrim over the
      // live tree. See the class doc on why this is not a blur.
      color: theme.scaffoldBackgroundColor,
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.lock_outline, size: 56, color: AppTheme.accent),
                  const SizedBox(height: 20),
                  Text(
                    'SecureShell Go is locked',
                    style: theme.textTheme.titleLarge,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Your sessions and tunnels are still running.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 28),
                  if (cooling)
                    Text(
                      'Too many attempts. Try again in '
                      '${_formatRemaining(remaining)}.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                      textAlign: TextAlign.center,
                    )
                  else
                    FilledButton.icon(
                      onPressed: busy ? null : onUnlock,
                      icon: const Icon(Icons.lock_open_outlined),
                      label: Text(busy ? 'Waiting…' : 'Unlock'),
                    ),
                  if (!cooling && controller.state.failedAttempts > 0) ...[
                    const SizedBox(height: 14),
                    Text(
                      _attemptsMessage(controller.state.failedAttempts),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Says how many tries are left before the wait, and — deliberately — says
  /// nothing that could be read as a threat to the user's data, because there
  /// is none: running out of attempts costs a delay and nothing else.
  static String _attemptsMessage(int failed) {
    final left = AppLockController.attemptsBeforeCooldown -
        (failed % AppLockController.attemptsBeforeCooldown);
    if (left == 1) return 'One more try before a short wait.';
    return '$left more tries before a short wait.';
  }

  static String _formatRemaining(Duration remaining) {
    final seconds = remaining.inSeconds + (remaining.inMilliseconds % 1000 > 0
        ? 1
        : 0);
    if (seconds < 60) return '${seconds}s';
    final minutes = (seconds / 60).ceil();
    return '${minutes}m';
  }
}
