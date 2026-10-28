import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../services/remote_path.dart';
import '../services/transfer_queue.dart';

/// The icon for a direction, in one place so the summary bar and the row in
/// the sheet cannot drift apart.
///
/// A server-to-server transfer gets a sideways arrow rather than an up or a
/// down one: neither end of it is this device, and calling it an upload is
/// what made the summary bar tell users the opposite of what happened last
/// time a direction was added without looking here.
IconData iconForDirection(TransferDirection direction) => switch (direction) {
      TransferDirection.download => Icons.download,
      TransferDirection.upload => Icons.upload,
      TransferDirection.serverToServer => Icons.swap_horiz,
    };

/// What an interrupted row says: how far it had got, and that it carries on
/// by itself — shared by the session sheet and the all-sessions panel, for
/// the same reason [iconForDirection] is.
String interruptedSubtitle(TransferTask task, AppLocalizations l10n) {
  final percent = task.percent;
  final where = percent == null || task.transferredBytes == 0
      ? l10n.transferPanelInterrupted
      : l10n.transferPanelInterruptedAt(percent);
  return '$where · ${task.error ?? l10n.transferPanelResumesLater}';
}

/// A transfer row's second line — the same in the session sheet and the
/// all-sessions panel. [withRate] adds the speed of a running transfer.
String transferSubtitle(
  TransferTask task,
  AppLocalizations l10n, {
  bool withRate = false,
}) {
  switch (task.status) {
    case TransferStatus.queued:
      // A server-to-server transfer's row would otherwise be the one place
      // in the app where "where is this going?" has no answer at all.
      return task.direction == TransferDirection.serverToServer
          ? l10n.transferPanelWaitingFor(
              task.destinationLabel ?? l10n.transferPanelAnotherServer,
            )
          : l10n.transferPanelWaiting;
    case TransferStatus.completed:
      final size = RemotePath.formatBytes(task.transferredBytes);
      final landed = task.destination ?? l10n.transferPanelSaved;
      return task.direction == TransferDirection.serverToServer &&
              task.moveSource
          ? '$size · ${l10n.transferPanelMovedTo(landed)}'
          : '$size · $landed';
    case TransferStatus.cancelled:
      return l10n.transferPanelCancelled;
    case TransferStatus.interrupted:
      return interruptedSubtitle(task, l10n);
    case TransferStatus.failed:
      return task.error ?? l10n.transferPanelFailed;
    case TransferStatus.running:
      final moved = RemotePath.formatBytes(task.transferredBytes);
      final total = task.totalBytes;
      final speed = withRate ? task.bytesPerSecond : null;
      final rate =
          speed == null ? '' : ' · ${RemotePath.formatBytes(speed.round())}/s';
      if (total == null) return '$moved$rate';
      return '${l10n.transferPanelProgress(moved, RemotePath.formatBytes(total))}'
          ' · ${task.percent}%$rate';
  }
}

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
        final theme = Theme.of(context);
        final l10n = context.l10n;

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
              ? '${running.name}  ·  ${l10n.transferPanelMoreQueued(queued)}'
              : running.name;
          icon = iconForDirection(running.direction);
        } else if (failed.isNotEmpty) {
          label = failed.length == 1
              ? l10n.transferPanelOneFailed(failed.first.name)
              : l10n.transferPanelManyFailed(failed.length);
          icon = Icons.error_outline;
          color = theme.colorScheme.error;
        } else {
          // Direction matters in the wording now that uploading is a
          // first-class flow: three files pushed to a server being reported
          // as "saved to Downloads" is not a rounding error, it is the app
          // telling the user the opposite of what happened.
          final uploads =
              done.where((t) => t.direction == TransferDirection.upload);
          final downloads =
              done.where((t) => t.direction == TransferDirection.download);
          final sent = done
              .where((t) => t.direction == TransferDirection.serverToServer);
          if (done.length == 1) {
            final only = done.first;
            final where = only.destination ?? only.name;
            label = switch (only.direction) {
              TransferDirection.upload => l10n.transferPanelUploaded(where),
              TransferDirection.download => l10n.transferPanelSavedFile(where),
              TransferDirection.serverToServer => only.moveSource
                  ? l10n.transferPanelMovedToDestination(where)
                  : l10n.transferPanelCopiedTo(where),
            };
          } else if (uploads.isEmpty && sent.isEmpty) {
            label = l10n.transferPanelSavedToDownloads(done.length);
          } else if (downloads.isEmpty && sent.isEmpty) {
            label = l10n.transferPanelFilesUploaded(done.length);
          } else if (downloads.isEmpty && uploads.isEmpty) {
            label = l10n.transferPanelFilesSent(done.length);
          } else {
            // Mixed. Naming each part beats a single verb that is wrong for
            // two thirds of what just happened.
            label = [
              if (downloads.isNotEmpty)
                l10n.transferPanelDownloadedCount(downloads.length),
              if (uploads.isNotEmpty)
                l10n.transferPanelUploadedCount(uploads.length),
              if (sent.isNotEmpty) l10n.transferPanelSentCount(sent.length),
            ].join(' · ');
          }
          icon = Icons.check_circle_outline;
          color = theme.colorScheme.primary;
        }

        final progress = queue.aggregateProgress;

        return Material(
          color: theme.colorScheme.surfaceContainerHigh,
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
///
/// [onOpen] hands a finished download to whatever app can display it, and
/// returns false if nothing on the device can. Omitted (in a context with no
/// device storage behind it) the "Open" action simply does not appear.
Future<void> showTransfersSheet(
  BuildContext context,
  TransferQueue queue, {
  Future<bool> Function(TransferTask task)? onOpen,
}) {
  final theme = Theme.of(context);
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: theme.colorScheme.surfaceContainerHigh,
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
                        context.l10n.transferPanelTitle,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const Spacer(),
                      if (queue.hasActive)
                        TextButton(
                          onPressed: queue.cancelAll,
                          child: Text(context.l10n.transferPanelCancelAll),
                        ),
                      if (anyFinished)
                        TextButton(
                          onPressed: queue.clearFinished,
                          child: Text(context.l10n.transferPanelClear),
                        ),
                    ],
                  ),
                ),
                if (tasks.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 32),
                    child: Text(context.l10n.transferPanelEmpty),
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
                        onRetry: queue.retry,
                        onOpen: onOpen,
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
  const _TransferTile({
    required this.task,
    required this.onCancel,
    required this.onRetry,
    this.onOpen,
  });

  final TransferTask task;
  final void Function(String id) onCancel;
  final TransferTask? Function(String id) onRetry;
  final Future<bool> Function(TransferTask task)? onOpen;

  bool get _canOpen =>
      onOpen != null &&
      task.status == TransferStatus.completed &&
      task.direction == TransferDirection.download &&
      (task.destinationUri?.isNotEmpty ?? false);

  Future<void> _open(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final noApp = context.l10n.transferPanelNoAppForFile;
    final opened = await onOpen!(task);
    if (!opened) {
      messenger.showSnackBar(SnackBar(content: Text(noApp)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitle = transferSubtitle(task, context.l10n, withRate: true);

    return ListTile(
      dense: true,
      leading: Icon(
        switch (task.status) {
          TransferStatus.completed => Icons.check_circle,
          TransferStatus.failed => Icons.error,
          TransferStatus.cancelled => Icons.cancel,
          TransferStatus.interrupted => Icons.sync_problem,
          _ => iconForDirection(task.direction),
        },
        color: switch (task.status) {
          TransferStatus.completed => theme.colorScheme.primary,
          TransferStatus.failed => theme.colorScheme.error,
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
      trailing: _buildAction(context),
    );
  }

  Widget? _buildAction(BuildContext context) {
    if (task.status.isActive) {
      return IconButton(
        tooltip: MaterialLocalizations.of(context).cancelButtonLabel,
        icon: const Icon(Icons.close, size: 20),
        onPressed: () => onCancel(task.id),
      );
    }
    // A failed transfer is the one row where the user has something better to
    // do than read the error: try it again, without hunting for the file or
    // the folder a second time.
    if (task.status == TransferStatus.failed) {
      return TextButton(
        onPressed: () => onRetry(task.id),
        child: Text(context.l10n.transferPanelRetry),
      );
    }
    if (_canOpen) {
      return TextButton(
        onPressed: () => unawaited(_open(context)),
        child: Text(context.l10n.transferPanelOpen),
      );
    }
    return null;
  }
}
