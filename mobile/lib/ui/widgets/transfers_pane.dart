import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/models/models.dart';
import '../view_models/downloader_view_model.dart';

class TransfersPane extends StatelessWidget {
  const TransfersPane({
    super.key,
    required this.viewModel,
  });

  final DownloaderViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final tasks = viewModel.tasksSorted;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
          child: Row(
            children: [
              Icon(Icons.download_for_offline_rounded, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        'Transfers & History',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    if (tasks.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: scheme.primaryContainer,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          '${tasks.length}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onPrimaryContainer,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Refresh history',
                onPressed: viewModel.refreshRecentTasks,
                icon: const Icon(Icons.refresh_rounded, size: 20),
              ),
              if (tasks.isNotEmpty)
                TextButton.icon(
                  onPressed: () => _confirmClearHistory(context),
                  icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                  label: const Text('Clear'),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: tasks.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.history_toggle_off_rounded,
                          size: 48,
                          color: scheme.outline,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'No downloads yet',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Server queue progress and device transfers appear here. History auto-expires after 24 hours.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(14),
                  itemCount: tasks.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final task = tasks[index];
                    final local = viewModel.transferForTask(task.taskId);
                    return _TaskTransferCard(
                      task: task,
                      local: local,
                      viewModel: viewModel,
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _confirmClearHistory(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear download history?'),
        content: const Text(
          'Removes finished items from your 24-hour history and deletes any expired server files. Active downloads continue uninterrupted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await viewModel.clearAllHistory();
    }
  }
}

class _TaskTransferCard extends StatelessWidget {
  const _TaskTransferCard({
    required this.task,
    required this.local,
    required this.viewModel,
  });

  final TaskStatusInfo task;
  final LocalTransferItem? local;
  final DownloaderViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (badgeText, badgeColor, badgeFg) = _badgeStyle(scheme);

    final fileExistsLocally = local != null &&
        local!.state == TransferState.completed &&
        local!.localPath.isNotEmpty &&
        File(local!.localPath).existsSync();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  task.kind == 'playlist'
                      ? Icons.folder_zip_outlined
                      : Icons.video_file_outlined,
                  color: scheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        task.kind == 'playlist' ? 'Playlist ZIP' : (task.format ?? 'Video'),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: badgeColor,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    badgeText,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: badgeFg,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),

            // Phase 1: Server processing progress
            if (task.isActive) ...[
              LinearProgressIndicator(
                value: task.percent > 0 ? (task.percent / 100.0).clamp(0.0, 1.0) : null,
                borderRadius: BorderRadius.circular(999),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      task.progress.isNotEmpty
                          ? task.progress
                          : 'Processing (${task.percent.toStringAsFixed(0)}%)…',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => viewModel.cancelServerTask(task.taskId),
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            ],

            if (task.isFailed || task.isExpired) ...[
              Text(
                task.error ?? (task.isExpired ? 'Expired on server' : 'Download failed'),
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
              ),
            ],

            if (task.note != null && task.note!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                task.note!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.tertiary,
                ),
              ),
            ],

            // Phase 2: Device transfer (resumable HTTP Range)
            if (task.isCompleted) ...[
              if (local == null || local!.state == TransferState.idle) ...[
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    FilledButton.icon(
                      onPressed: () => viewModel.downloadTaskToDevice(task.taskId),
                      icon: const Icon(Icons.save_alt_rounded, size: 18),
                      label: const Text('Save to Device'),
                    ),
                    Text(
                      'Ready for resumable transfer',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ] else if (local!.state == TransferState.downloading) ...[
                LinearProgressIndicator(
                  value: local!.progressRatio,
                  borderRadius: BorderRadius.circular(999),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        local!.totalBytes > 0
                            ? '${formatByteCount(local!.receivedBytes)} / ${formatByteCount(local!.totalBytes)}'
                            : '${formatByteCount(local!.receivedBytes)} downloaded',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => viewModel.pauseDeviceTransfer(task.taskId),
                      icon: const Icon(Icons.pause_rounded, size: 16),
                      label: const Text('Pause'),
                    ),
                  ],
                ),
              ] else if (local!.state == TransferState.paused) ...[
                LinearProgressIndicator(
                  value: local!.progressRatio,
                  borderRadius: BorderRadius.circular(999),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Paused at ${formatByteCount(local!.receivedBytes)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: () => viewModel.downloadTaskToDevice(task.taskId),
                      icon: const Icon(Icons.play_arrow_rounded, size: 18),
                      label: const Text('Resume'),
                    ),
                  ],
                ),
              ] else if (local!.state == TransferState.failed) ...[
                Text(
                  local!.error ?? 'Transfer interrupted',
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
                ),
                const SizedBox(height: 6),
                FilledButton.tonalIcon(
                  onPressed: () => viewModel.downloadTaskToDevice(task.taskId),
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('Resume Transfer'),
                ),
              ] else if (local!.state == TransferState.completed) ...[
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            local!.filename,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            'Saved locally · ${formatByteCount(local!.receivedBytes)}',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (fileExistsLocally)
                      Builder(
                        builder: (btnCtx) => FilledButton.tonalIcon(
                          onPressed: () => _shareLocalFile(btnCtx, local!),
                          icon: const Icon(Icons.ios_share_rounded, size: 18),
                          label: const Text('Share / Save'),
                        ),
                      )
                    else
                      FilledButton.tonalIcon(
                        onPressed: () => viewModel.downloadTaskToDevice(task.taskId),
                        icon: const Icon(Icons.save_alt_rounded, size: 18),
                        label: const Text('Re-download'),
                      ),
                  ],
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  (String, Color, Color) _badgeStyle(ColorScheme scheme) {
    if (local != null) {
      switch (local!.state) {
        case TransferState.downloading:
          return ('Downloading', scheme.primaryContainer, scheme.onPrimaryContainer);
        case TransferState.paused:
          return ('Paused', scheme.secondaryContainer, scheme.onSecondaryContainer);
        case TransferState.completed:
          return ('Saved', const Color(0xFFDCFCE7), const Color(0xFF166534));
        case TransferState.failed:
          return ('Retry', scheme.errorContainer, scheme.onErrorContainer);
        case TransferState.idle:
          break;
      }
    }
    switch (task.status) {
      case 'processing':
      case 'queued':
        return ('Server ${task.percent.toStringAsFixed(0)}%', scheme.primaryContainer, scheme.onPrimaryContainer);
      case 'completed':
        return ('Ready', scheme.tertiaryContainer, scheme.onTertiaryContainer);
      case 'failed':
      case 'cancelled':
        return (task.status.toUpperCase(), scheme.errorContainer, scheme.onErrorContainer);
      case 'expired':
        return ('Expired', scheme.surfaceContainerHighest, scheme.onSurfaceVariant);
      default:
        return (task.status, scheme.surfaceContainerHighest, scheme.onSurfaceVariant);
    }
  }

  Future<void> _shareLocalFile(BuildContext context, LocalTransferItem item) async {
    Rect? origin;
    final box = context.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize) {
      origin = box.localToGlobal(Offset.zero) & box.size;
    }
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(item.localPath)],
        text: item.title,
        sharePositionOrigin: origin,
      ),
    );
  }
}
