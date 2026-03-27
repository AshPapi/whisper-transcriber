import 'package:flutter/material.dart';
import '../models/models.dart';
import '../services/backend_service.dart';

class QueueScreen extends StatelessWidget {
  final List<TranscribeTask> tasks;
  final void Function(TranscribeTask task) onViewResult;

  const QueueScreen({
    super.key,
    required this.tasks,
    required this.onViewResult,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Queue',
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 16),
          if (tasks.isEmpty)
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.queue_music_outlined,
                        size: 48,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha:0.3)),
                    const SizedBox(height: 12),
                    Text(
                      'No tasks yet',
                      style: TextStyle(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha:0.4)),
                    ),
                  ],
                ),
              ),
            )
          else
            Expanded(
              child: ListView.separated(
                itemCount: tasks.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (ctx, i) => _TaskCard(
                  task: tasks[i],
                  onViewResult: () => onViewResult(tasks[i]),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _TaskCard extends StatelessWidget {
  final TranscribeTask task;
  final VoidCallback onViewResult;

  const _TaskCard({required this.task, required this.onViewResult});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            _StatusIcon(status: task.status),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    task.fileName,
                    style: const TextStyle(
                        fontWeight: FontWeight.w500, fontSize: 14),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  _StatusRow(task: task),
                  if (task.status == TaskStatus.running ||
                      task.status == TaskStatus.queued) ...[
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      borderRadius: BorderRadius.circular(4),
                      value: task.status == TaskStatus.queued ? null : null,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            if (task.status == TaskStatus.done)
              FilledButton.tonal(
                onPressed: onViewResult,
                child: const Text('View'),
              )
            else if (task.isActive)
              IconButton(
                icon: const Icon(Icons.stop_circle_outlined),
                tooltip: 'Cancel',
                onPressed: () => BackendService.instance.cancelTask(task.taskId),
              ),
          ],
        ),
      ),
    );
  }
}

class _StatusIcon extends StatelessWidget {
  final TaskStatus status;
  const _StatusIcon({required this.status});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    switch (status) {
      case TaskStatus.queued:
        return Icon(Icons.schedule_outlined, color: cs.onSurface.withValues(alpha:0.4));
      case TaskStatus.running:
        return SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary),
        );
      case TaskStatus.done:
        return Icon(Icons.check_circle_outline, color: Colors.green.shade600);
      case TaskStatus.error:
        return Icon(Icons.error_outline, color: cs.error);
      case TaskStatus.cancelled:
        return Icon(Icons.cancel_outlined, color: cs.onSurface.withValues(alpha:0.4));
    }
  }
}

class _StatusRow extends StatelessWidget {
  final TranscribeTask task;
  const _StatusRow({required this.task});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final style = TextStyle(fontSize: 12, color: cs.onSurface.withValues(alpha:0.5));

    switch (task.status) {
      case TaskStatus.queued:
        return Text('Waiting…', style: style);
      case TaskStatus.running:
        return Text(
          _translateStatus(task.statusText),
          style: style.copyWith(color: cs.primary),
        );
      case TaskStatus.done:
        return Text('${task.segments.length} segments', style: style);
      case TaskStatus.error:
        return Text(
          task.error ?? 'Unknown error',
          style: style.copyWith(color: cs.error),
          overflow: TextOverflow.ellipsis,
        );
      case TaskStatus.cancelled:
        return Text('Cancelled', style: style);
    }
  }

  String _translateStatus(String s) {
    if (s.startsWith('loading_model:')) {
      return 'Loading model on ${s.split(':').last}…';
    }
    return switch (s) {
      'extracting_audio' => 'Extracting audio…',
      'converting_audio' => 'Converting audio…',
      'transcribing' => 'Transcribing…',
      _ => s,
    };
  }
}
