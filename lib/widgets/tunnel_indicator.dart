import 'dart:async';

import 'package:flutter/material.dart';

import '../services/tunnel_runtime.dart';

/// The sessions screen's "something is listening" chip.
///
/// A port forward is the one thing this app does that keeps working while
/// nothing on screen mentions it — the user is in a shell, and meanwhile
/// 127.0.0.1:5432 on their machine is quietly reaching a database through
/// it. This is the reminder, and it renders nothing at all when no tunnel is
/// running so it costs nothing in the ordinary case.
class TunnelIndicator extends StatefulWidget {
  const TunnelIndicator({super.key, required this.tunnels, this.onTap});

  final TunnelRuntime tunnels;

  /// Optional: the sessions screen has no route to the tunnels list of its
  /// own, so by default this is an indicator rather than a button.
  final VoidCallback? onTap;

  @override
  State<TunnelIndicator> createState() => _TunnelIndicatorState();
}

class _TunnelIndicatorState extends State<TunnelIndicator> {
  StreamSubscription<TunnelStatus>? _changes;

  @override
  void initState() {
    super.initState();
    _changes = widget.tunnels.changes.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _changes?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.tunnels.activeCount;
    if (count == 0) return const SizedBox.shrink();
    final theme = Theme.of(context);

    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: theme.colorScheme.primary.withValues(alpha: 0.16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.swap_horiz, size: 15, color: theme.colorScheme.primary),
          const SizedBox(width: 4),
          Text(
            '$count',
            style: TextStyle(
              color: theme.colorScheme.primary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );

    return Tooltip(
      message: count == 1 ? '1 tunnel running' : '$count tunnels running',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: widget.onTap == null
            ? chip
            : InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: widget.onTap,
                child: chip,
              ),
      ),
    );
  }
}
