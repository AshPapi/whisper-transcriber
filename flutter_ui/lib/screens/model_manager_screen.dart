import 'dart:async';
import 'package:flutter/material.dart';
import '../models/models.dart';
import '../services/backend_service.dart';

class ModelManagerScreen extends StatefulWidget {
  const ModelManagerScreen({super.key});

  @override
  State<ModelManagerScreen> createState() => _ModelManagerScreenState();
}

class _ModelManagerScreenState extends State<ModelManagerScreen> {
  final _backend = BackendService.instance;
  List<WhisperModel> _models = [];

  // Download state per model
  final Map<String, _DownloadState> _dlState = {};
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    _loadModels();
    _sub = _backend.events.listen(_onEvent);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _loadModels() async {
    try {
      final models = await _backend.getModels();
      if (mounted) setState(() => _models = models);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  void _onEvent(Map<String, dynamic> event) {
    final type = event['type'] as String?;
    final name = event['name'] as String?;
    if (name == null) return;

    switch (type) {
      case 'download_progress':
        setState(() {
          _dlState[name] = _DownloadState(
            pct: (event['pct'] as num).toInt(),
            speed: (event['speed_mbs'] as num).toDouble(),
          );
        });

      case 'download_done':
        setState(() => _dlState.remove(name));
        _loadModels();

      case 'download_cancelled':
      case 'download_error':
        setState(() => _dlState.remove(name));
        if (type == 'download_error') {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text(
                    'Download failed: ${event['msg'] ?? 'unknown error'}')),
          );
        }
    }
  }

  Future<void> _startDownload(String name) async {
    setState(() => _dlState[name] = const _DownloadState(pct: 0, speed: 0));
    try {
      await _backend.downloadModel(name);
    } catch (e) {
      setState(() => _dlState.remove(name));
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _cancelDownload(String name) async {
    await _backend.cancelDownload(name);
  }

  Future<void> _delete(String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete model?'),
        content: Text('Remove "$name" from disk?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _backend.deleteModel(name);
      _loadModels();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Models',
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(
            'Models are stored in ~/whisper_models/',
            style: TextStyle(
                fontSize: 12,
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha:0.5)),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: ListView.separated(
              itemCount: _models.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (ctx, i) {
                final m = _models[i];
                final dl = _dlState[m.name];
                return _ModelCard(
                  model: m,
                  dlState: dl,
                  onDownload: () => _startDownload(m.name),
                  onCancel: () => _cancelDownload(m.name),
                  onDelete: () => _delete(m.name),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _DownloadState {
  final int pct;
  final double speed;
  const _DownloadState({required this.pct, required this.speed});
}

class _ModelCard extends StatelessWidget {
  final WhisperModel model;
  final _DownloadState? dlState;
  final VoidCallback onDownload;
  final VoidCallback onCancel;
  final VoidCallback onDelete;

  const _ModelCard({
    required this.model,
    required this.dlState,
    required this.onDownload,
    required this.onCancel,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDownloading = dlState != null;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  model.downloaded
                      ? Icons.check_circle_outline
                      : Icons.cloud_download_outlined,
                  color: model.downloaded
                      ? Colors.green.shade600
                      : cs.onSurface.withValues(alpha:0.4),
                  size: 20,
                ),
                const SizedBox(width: 10),
                Text(model.name,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 15)),
                const SizedBox(width: 8),
                Text(model.sizeLabel,
                    style: TextStyle(
                        fontSize: 12, color: cs.onSurface.withValues(alpha:0.5))),
                if (model.name == 'turbo') ...[
                  const SizedBox(width: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: cs.primary.withValues(alpha:0.12),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text('recommended',
                        style: TextStyle(
                            fontSize: 10,
                            color: cs.primary,
                            fontWeight: FontWeight.w500)),
                  ),
                ],
                const Spacer(),
                if (isDownloading)
                  IconButton(
                    icon: const Icon(Icons.stop_circle_outlined),
                    tooltip: 'Cancel',
                    onPressed: onCancel,
                  )
                else if (model.downloaded)
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Delete',
                    onPressed: onDelete,
                  )
                else
                  FilledButton.tonal(
                    onPressed: onDownload,
                    child: const Text('Download'),
                  ),
              ],
            ),
            if (isDownloading) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: LinearProgressIndicator(
                      value: dlState!.pct / 100,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '${dlState!.pct}%  ${dlState!.speed.toStringAsFixed(1)} MB/s',
                    style: TextStyle(
                        fontSize: 11, color: cs.onSurface.withValues(alpha:0.5)),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
