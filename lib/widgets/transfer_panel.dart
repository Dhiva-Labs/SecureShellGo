import 'package:flutter/material.dart';

import '../services/remote_path.dart';
import '../services/transfer_queue.dart';
import '../theme.dart';

/// Rebuilds [builder] whenever anything in [queue] changes.
class TransferQueueBuilder extends StatelessWidget {
  const TransferQueueBuilder({
    super.key,
    required this.queue,
    required this.builder,
  });

  final TransferQueue queue;
  final Widget Function(BuildContext context, List<TransferTask> tasks) builder;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<TransferTask>>(
      stream: queue.changes,
      initialData: queue.tasks,
      builder: (context, snapshot) =>
          builder(context, snapshot.data ?? const <TransferTask>[]),
    );
  }
}

/// The strip above the key bar / list that says how transfers are going.
///
/// Collapsed to a single line on purpose: a download is something the user
/// started and then wants to keep browsing through, so it earns one line and a
/// tap target, not a modal.
class TransferSummaryBar extends StatelessWidget {
  const TransferSummaryBar({super.key, required this.queue, required this.onTap});

  final TransferQueue queue;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TransferQueueBuilder(
      queue: queue,
      builder: (context, tasks) {
        if (tasks.isEmpty) return const SizedBox.shrink();

        final active = tasks.where((t) => t.status.isActive).toList();
        final failed = tasks.where((t) => t.status == TransferStatus.failed);
        final done = tasks.where((t) => t.status == TransferStatus.completed);

        final String label;
        final IconData icon;
        Color? color;
        if (active.isNotEmpty) {
          final running = active.firstWhere(
            (t) => t.status == TransferStatus.running,
            orElse: () => active.first,
          );
          final queued = active.length - 1;
          label = queued > 0
              ? '${running.name}  ·  $queued more queued'
              : running.name;
          icon = running.direction == TransferDirection.download
              ? Icons.download
              : Icons.upload;
        } else if (failed.isNotEmpty) {
          label = failed.length == 1
              ? '${failed.first.name} failed'
              : '${failed.length} transfers failed';
          icon = Icons.error_outline;
          color = AppTheme.danger;
        } else {
          label = done.length == 1
              ? 'Saved ${done.first.destination ?? done.first.name}'
              : '${done.length} files saved to Downloads';
          icon = Icons.check_circle_outline;
          color = AppTheme.accent;
        }

        final progress = queue.aggregateProgress;

        return Material(
          color: AppTheme.surface,
          child: InkWell(
            onTap: onTap,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (active.isNotEmpty)
                  LinearProgressIndicator(
                    value: progress,
                    minHeight: 2,
                    backgroundColor: Colors.transparent,
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                  child: Row(
                    children: [
                      Icon(icon, size: 18, color: color),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      if (active.isNotEmpty && progress != null)
                        Text(
                          '${(progress * 100).round()}%',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      const SizedBox(width: 4),
                      const Icon(Icons.expand_less, size: 18),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The full transfer list, as a bottom sheet.
Future<void> showTransfersSheet(BuildContext context, TransferQueue queue) {
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
        child: TransferQueueBuilder(
          queue: queue,
          builder: (context, tasks) {
            final anyFinished = tasks.any((t) => t.status.isFinished);
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 8, 4),
                  child: Row(
                    children: [
                      Text(
                        'Transfers',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const Spacer(),
                      if (queue.hasActive)
                        TextButton(
                          onPressed: queue.cancelAll,
                          child: const Text('Cancel all'),
                        ),
                      if (anyFinished)
                        TextButton(
                          onPressed: queue.clearFinished,
                          child: const Text('Clear'),
                        ),
                    ],
                  ),
                ),
                if (tasks.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 32),
                    child: Text('Nothing transferred yet.'),
                  )
                else
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      padding: const EdgeInsets.only(bottom: 12),
                      itemCount: tasks.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) => _TransferTile(
                        task: tasks[tasks.length - 1 - index],
                        onCancel: queue.cancel,
                      ),
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

class _TransferTile extends StatelessWidget {
  const _TransferTile({required this.task, required this.onCancel});

  final TransferTask task;
  final void Function(String id) onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitle = _subtitle();

    return ListTile(
      dense: true,
      leading: Icon(
        switch (task.status) {
          TransferStatus.completed => Icons.check_circle,
          TransferStatus.failed => Icons.error,
          TransferStatus.cancelled => Icons.cancel,
          _ => task.direction == TransferDirection.download
              ? Icons.download
              : Icons.upload,
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
          Text(subtitle, style: theme.textTheme.bodySmall),
          if (task.status.isActive) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(value: task.progress, minHeight: 3),
          ],
        ],
      ),
      trailing: task.status.isActive
          ? IconButton(
              tooltip: 'Cancel',
              icon: const Icon(Icons.close, size: 20),
              onPressed: () => onCancel(task.id),
            )
          : null,
    );
  }

  String _subtitle() {
    switch (task.status) {
      case TransferStatus.queued:
        return 'Waiting…';
      case TransferStatus.completed:
        return '${RemotePath.formatBytes(task.transferredBytes)} · '
            '${task.destination ?? 'saved'}';
      case TransferStatus.cancelled:
        return 'Cancelled';
      case TransferStatus.failed:
        return task.error ?? 'Failed';
      case TransferStatus.running:
        final moved = RemotePath.formatBytes(task.transferredBytes);
        final total = task.totalBytes;
        final speed = task.bytesPerSecond;
        final rate =
            speed == null ? '' : ' · ${RemotePath.formatBytes(speed.round())}/s';
        if (total == null) return '$moved$rate';
        return '$moved of ${RemotePath.formatBytes(total)}'
            ' · ${task.percent}%$rate';
    }
  }
}
