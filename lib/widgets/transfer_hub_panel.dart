import 'package:flutter/material.dart';

import '../services/remote_path.dart';
import '../services/transfer_hub.dart';
import '../services/transfer_queue.dart';
import '../theme.dart';
import 'transfer_panel.dart' show iconForDirection;

/// Rebuilds [builder] whenever [hub]'s merged list changes — the
/// multi-session equivalent of `TransferQueueBuilder` in
/// `transfer_panel.dart`.
class TransferHubBuilder extends StatelessWidget {
  const TransferHubBuilder({
    super.key,
    required this.hub,
    required this.builder,
  });

  final TransferHub hub;
  final Widget Function(BuildContext context, List<AggregatedTransfer> items)
      builder;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<AggregatedTransfer>>(
      stream: hub.changes,
      initialData: hub.items,
      builder: (context, snapshot) =>
          builder(context, snapshot.data ?? const <AggregatedTransfer>[]),
    );
  }
}

/// App-bar icon for the unified panel: every transfer on every open session,
/// with a badge for how many are active right now — the same shape as
/// `session_screen.dart`'s per-session `_TransferAction`, but fed by [hub]
/// instead of one session's own queue.
class TransferHubAction extends StatelessWidget {
  const TransferHubAction({super.key, required this.hub, required this.onTap});

  final TransferHub hub;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TransferHubBuilder(
      hub: hub,
      builder: (context, items) {
        if (items.isEmpty) return const SizedBox.shrink();
        final active = items.where((i) => i.task.status.isActive).length;
        final failed =
            items.any((i) => i.task.status == TransferStatus.failed);

        return IconButton(
          tooltip: 'All transfers',
          onPressed: onTap,
          icon: Badge(
            isLabelVisible: active > 0 || failed,
            backgroundColor: failed && active == 0 ? AppTheme.danger : null,
            label: active > 0 ? Text('$active') : null,
            child: const Icon(Icons.swap_calls),
          ),
        );
      },
    );
  }
}

/// The unified transfer list, as a bottom sheet: every session's uploads,
/// downloads and server-to-server copies, newest first, in one place.
Future<void> showTransferHubSheet(BuildContext context, TransferHub hub) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppTheme.surface,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: TransferHubBuilder(
          hub: hub,
          builder: (context, items) {
            final anyFinished = items.any((i) => i.task.status.isFinished);
            final anyActive = items.any((i) => i.task.status.isActive);
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 8, 4),
                  child: Row(
                    children: [
                      Text(
                        'All transfers',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const Spacer(),
                      if (anyActive)
                        TextButton(
                          onPressed: () {
                            for (final item in items) {
                              if (!item.task.status.isActive) continue;
                              hub.cancel(item.sessionId, item.task.id);
                            }
                          },
                          child: const Text('Cancel all'),
                        ),
                      if (anyFinished)
                        TextButton(
                          onPressed: hub.clearCompleted,
                          child: const Text('Clear'),
                        ),
                    ],
                  ),
                ),
                if (items.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 32),
                    child: Text('Nothing transferred yet.'),
                  )
                else
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      padding: const EdgeInsets.only(bottom: 12),
                      itemCount: items.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) =>
                          _HubTile(item: items[index], hub: hub),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    ),
  );
}

class _HubTile extends StatelessWidget {
  const _HubTile({required this.item, required this.hub});

  final AggregatedTransfer item;
  final TransferHub hub;

  @override
  Widget build(BuildContext context) {
    final task = item.task;
    final theme = Theme.of(context);

    return ListTile(
      dense: true,
      leading: Icon(
        switch (task.status) {
          TransferStatus.completed => Icons.check_circle,
          TransferStatus.failed => Icons.error,
          TransferStatus.cancelled => Icons.cancel,
          _ => iconForDirection(task.direction),
        },
        color: switch (task.status) {
          TransferStatus.completed => AppTheme.accent,
          TransferStatus.failed => AppTheme.danger,
          _ => theme.colorScheme.onSurfaceVariant,
        },
      ),
      title: Text(
        task.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 2),
          // Naming the session is the whole point of a unified panel: a row
          // with no host label reads as ambiguous the moment more than one
          // session has something moving.
          Text(
            item.sessionLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          Text(_subtitle(task), style: theme.textTheme.bodySmall),
          if (task.status.isActive) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(value: task.progress, minHeight: 3),
          ],
        ],
      ),
      isThreeLine: true,
      trailing: _buildAction(),
    );
  }

  Widget? _buildAction() {
    final task = item.task;
    if (task.status.isActive) {
      return IconButton(
        tooltip: 'Cancel',
        icon: const Icon(Icons.close, size: 20),
        onPressed: () => hub.cancel(item.sessionId, task.id),
      );
    }
    // Only a failure has something better to do than read the error — see
    // `transfer_panel.dart`'s `_TransferTile` for the same rule on the
    // single-session sheet this mirrors.
    if (task.status == TransferStatus.failed) {
      return TextButton(
        onPressed: () => hub.retry(item.sessionId, task.id),
        child: const Text('Retry'),
      );
    }
    return null;
  }

  static String _subtitle(TransferTask task) {
    switch (task.status) {
      case TransferStatus.queued:
        return task.direction == TransferDirection.serverToServer
            ? 'Waiting… → ${task.destinationLabel ?? 'another server'}'
            : 'Waiting…';
      case TransferStatus.completed:
        final landed = task.destination ?? 'saved';
        return task.direction == TransferDirection.serverToServer &&
                task.moveSource
            ? '${RemotePath.formatBytes(task.transferredBytes)} · moved to '
                '$landed'
            : '${RemotePath.formatBytes(task.transferredBytes)} · $landed';
      case TransferStatus.cancelled:
        return 'Cancelled';
      case TransferStatus.failed:
        return task.error ?? 'Failed';
      case TransferStatus.running:
        final moved = RemotePath.formatBytes(task.transferredBytes);
        final total = task.totalBytes;
        if (total == null) return moved;
        return '$moved of ${RemotePath.formatBytes(total)} · ${task.percent}%';
    }
  }
}
