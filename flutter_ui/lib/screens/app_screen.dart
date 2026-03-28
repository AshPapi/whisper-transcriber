import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/models.dart';
import '../services/backend_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Main single-screen widget
// ─────────────────────────────────────────────────────────────────────────────

class AppScreen extends StatefulWidget {
  const AppScreen({super.key});

  @override
  State<AppScreen> createState() => _AppScreenState();
}

class _AppScreenState extends State<AppScreen> {
  final _backend = BackendService.instance;

  // ── Files ──
  List<String> _files = [];
  bool _dragging = false;

  // ── Static model list (always shown, download status loaded from backend) ──
  static const _staticModels = [
    ('tiny',     '~75 MB',   75),
    ('base',     '~145 MB',  145),
    ('small',    '~466 MB',  466),
    ('medium',   '~1.5 GB',  1500),
    ('large-v2', '~2.9 GB',  2900),
    ('large-v3', '~2.9 GB',  2900),
    ('turbo',    '~1.5 GB',  1500),
  ];

  // ── Settings ──
  List<WhisperModel> _allModels = _buildStaticModels();
  String? _selectedModel;
  String _lang = 'auto';
  String _device = 'cpu';
  int _beam = 5;
  String _modelsDir = '';

  static List<WhisperModel> _buildStaticModels() => _staticModels
      .map((m) => WhisperModel(
            name: m.$1, sizeLabel: m.$2, sizeMb: m.$3, downloaded: false))
      .toList();

  // ── Tasks ──
  final List<TranscribeTask> _tasks = [];
  TranscribeTask? _viewingTask;

  // ── Download state ──
  final Map<String, _DlState> _dlState = {};

  // ── Devices (loaded from backend) ──
  List<Map<String, String>> _devices = [
    {'id': 'cpu', 'name': 'CPU'},
    {'id': 'cuda', 'name': 'CUDA'},
  ];

  // ── UI state ──
  bool _transcribing = false;
  String? _error;
  StreamSubscription? _eventSub;

  static const _supportedExt = {
    'mp3', 'wav', 'ogg', 'flac', 'm4a', 'aac', 'wma', 'opus',
    'mp4', 'mkv', 'avi', 'mov', 'webm', 'flv', 'ts', 'm4v',
  };

  static const _languages = [
    ('auto', 'Авто'), ('ru', 'Русский'), ('en', 'Английский'),
    ('de', 'Немецкий'), ('fr', 'Французский'), ('es', 'Испанский'),
    ('it', 'Итальянский'), ('zh', 'Китайский'), ('ja', 'Японский'),
    ('uk', 'Украинский'), ('pl', 'Польский'), ('pt', 'Португальский'),
    ('nl', 'Нидерландский'), ('tr', 'Турецкий'), ('ar', 'Арабский'), ('ko', 'Корейский'),
  ];

  @override
  void initState() {
    super.initState();
    _loadData();
    _eventSub = _backend.events.listen(_onEvent);
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    super.dispose();
  }

  Future<void> _loadData() async {
    try {
      final settings = await _backend.getSettings();
      if (mounted) {
        setState(() {
          _lang = settings.lang;
          _beam = settings.beam;
          _device = settings.device;
          _modelsDir = settings.modelsDir;
        });
      }
    } catch (_) {}

    try {
      final devices = await _backend.getDevices();
      if (mounted && devices.isNotEmpty) {
        setState(() {
          _devices = devices;
          // Ensure current device is in the list
          if (!_devices.any((d) => d['id'] == _device)) {
            _device = _devices.first['id']!;
          }
        });
      }
    } catch (_) {}

    try {
      final models = await _backend.getModels();
      if (!mounted) return;
      setState(() {
        _allModels = models;
        final downloaded = models.where((m) => m.downloaded).toList();
        if (downloaded.isNotEmpty) {
          _selectedModel ??= downloaded
              .firstWhere((m) => m.name == 'turbo',
                  orElse: () => downloaded.first)
              .name;
        }
      });
    } catch (_) {}
  }

  Future<void> _cancelDownload(String name) async {
    try {
      await _backend.cancelDownload(name);
      setState(() => _dlState.remove(name));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _loadModelsOnly() async {
    try {
      final models = await _backend.getModels();
      if (!mounted) return;
      setState(() {
        // Only update download status, don't touch active downloads
        _allModels = models.map((m) {
          // If currently downloading this model, keep it as not-downloaded in list
          // (the dlState handles the UI, downloaded flag will update when done)
          return m;
        }).toList();
        final downloaded = models.where((m) => m.downloaded).toList();
        if (_selectedModel != null && !downloaded.any((m) => m.name == _selectedModel)) {
          _selectedModel = null;
        }
        if (downloaded.isNotEmpty && _selectedModel == null) {
          _selectedModel = downloaded
              .firstWhere((m) => m.name == 'turbo',
                  orElse: () => downloaded.first)
              .name;
        }
      });
    } catch (_) {}
  }

  void _onEvent(Map<String, dynamic> event) {
    if (!mounted) return;
    final type = event['type'] as String?;

    // ── Transcription events ──
    final taskId = event['task_id'] as String?;
    if (taskId != null) {
      switch (type) {
        case 'task_status':
          _updateTask(taskId, (t) {
            t.status = TaskStatus.running;
            t.statusText = event['status'] as String? ?? '';
          });
        case 'segment':
          _updateTask(taskId, (t) {
            t.segments.add(
                Segment.fromJson(event['segment'] as Map<String, dynamic>));
          });
        case 'task_done':
          _updateTask(taskId, (t) => t.status = TaskStatus.done);
        case 'task_error':
          _updateTask(taskId, (t) {
            t.status = TaskStatus.error;
            t.error = event['msg'] as String?;
          });
      }
    }

    // ── Download events ──
    final name = event['name'] as String?;
    if (name != null) {
      switch (type) {
        case 'download_progress':
          setState(() {
            _dlState[name] = _DlState(
              pct: (event['pct'] as num).toInt(),
              speed: (event['speed_mbs'] as num).toDouble(),
            );
          });
        case 'download_done':
          setState(() => _dlState.remove(name));
          _loadModelsOnly();
        case 'download_cancelled':
          setState(() => _dlState.remove(name));
        case 'download_error':
          setState(() => _dlState.remove(name));
          if (mounted) {
            final msg = event['msg'] as String? ?? 'Неизвестная ошибка';
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Ошибка загрузки $name: $msg')));
          }
      }
    }
  }

  void _updateTask(String taskId, void Function(TranscribeTask) fn) {
    setState(() {
      final idx = _tasks.indexWhere((t) => t.taskId == taskId);
      if (idx >= 0) fn(_tasks[idx]);
    });
  }

  void _addFiles(List<String> paths) {
    final valid = paths.where((filePath) {
      final ext = filePath.split('.').last.toLowerCase();
      return _supportedExt.contains(ext);
    }).toList();
    if (valid.isEmpty) return;
    setState(() => _files = [..._files, ...valid]);
  }

  Future<void> _pickFiles() async {
    final result =
        await FilePicker.platform.pickFiles(allowMultiple: true, type: FileType.any);
    if (result != null) _addFiles(result.files.map((f) => f.path!).toList());
  }

  Future<void> _startTranscribe() async {
    if (_files.isEmpty || _selectedModel == null) return;
    setState(() { _transcribing = true; _error = null; });
    try {
      final ids = await _backend.transcribe(
        files: _files,
        modelName: _selectedModel!,
        language: _lang,
        beamSize: _beam,
        device: _device,
      );
      setState(() {
        for (var i = 0; i < ids.length; i++) {
          _tasks.insert(0, TranscribeTask(taskId: ids[i], file: _files[i], model: _selectedModel!));
        }
        _files = [];
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _transcribing = false);
    }
  }

  Future<void> _downloadModel(String name) async {
    setState(() => _dlState[name] = const _DlState(pct: 0, speed: 0));
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

  Future<void> _deleteModel(String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить модель?'),
        content: Text('Удалить "$name" с диска?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Удалить')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _backend.deleteModel(name);
      if (_selectedModel == name) {
        setState(() => _selectedModel = null);
      }
      _loadData();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Left panel ──────────────────────────────────────────────────────
        SizedBox(
          width: 340,
          child: _buildLeftPanel(),
        ),
        const VerticalDivider(width: 1),
        // ── Right panel ─────────────────────────────────────────────────────
        Expanded(child: _buildRightPanel()),
      ],
    );
  }

  Widget _buildLeftPanel() {
    final cs = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ── Drop zone ──
        _buildDropZone(cs),
        const SizedBox(height: 16),

        // ── Transcription settings ──
        _SectionLabel('Настройки'),
        const SizedBox(height: 8),
        _buildSettings(cs),
        const SizedBox(height: 16),

        // ── Models ──
        _SectionLabel('Модели'),
        const SizedBox(height: 4),
        _buildModelsPath(cs),
        const SizedBox(height: 8),
        _buildModelsList(cs),
        const SizedBox(height: 16),

        // ── Error ──
        if (_error != null) ...[
          Text(_error!, style: TextStyle(color: cs.error, fontSize: 12)),
          const SizedBox(height: 8),
        ],

        // ── Transcribe button ──
        FilledButton.icon(
          onPressed: (_files.isEmpty || _selectedModel == null || _transcribing)
              ? null
              : _startTranscribe,
          icon: _transcribing
              ? const SizedBox(
                  width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.play_arrow_rounded),
          label: Text(_transcribing ? 'Запуск…' : 'Транскрибировать'),
          style: FilledButton.styleFrom(
              minimumSize: const Size(double.infinity, 44)),
        ),
      ],
    );
  }

  Widget _buildDropZone(ColorScheme cs) {
    return DropTarget(
      onDragDone: (d) => _addFiles(d.files.map((f) => f.path).toList()),
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: 130,
        decoration: BoxDecoration(
          border: Border.all(
            color: _dragging ? cs.primary : cs.outline.withValues(alpha: 0.4),
            width: _dragging ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(10),
          color: _dragging ? cs.primary.withValues(alpha: 0.06) : cs.surface,
        ),
        child: _files.isEmpty ? _buildDropHint(cs) : _buildFileList(cs),
      ),
    );
  }

  Widget _buildDropHint(ColorScheme cs) => InkWell(
        onTap: _pickFiles,
        borderRadius: BorderRadius.circular(10),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_upload_outlined,
                  size: 36, color: cs.primary.withValues(alpha: 0.6)),
              const SizedBox(height: 8),
              Text('Перетащите файлы или нажмите для выбора',
                  style: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.6), fontSize: 13)),
            ],
          ),
        ),
      );

  Widget _buildFileList(ColorScheme cs) => Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              itemCount: _files.length,
              itemBuilder: (ctx, i) {
                final name = _files[i].split(RegExp(r'[/\\]')).last;
                return ListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                  leading: const Icon(Icons.audio_file_outlined, size: 18),
                  title: Text(name,
                      style: const TextStyle(fontSize: 12),
                      overflow: TextOverflow.ellipsis),
                  trailing: IconButton(
                    icon: const Icon(Icons.close, size: 14),
                    onPressed: () => setState(() => _files.removeAt(i)),
                  ),
                );
              },
            ),
          ),
          TextButton.icon(
            onPressed: _pickFiles,
            icon: const Icon(Icons.add, size: 14),
            label: const Text('Добавить ещё', style: TextStyle(fontSize: 12)),
          ),
        ],
      );

  Widget _buildSettings(ColorScheme cs) => Column(
        children: [
          // Model selector
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: _selectedModel,
                  decoration: const InputDecoration(
                      labelText: 'Модель', isDense: true),
                  items: _allModels
                      .where((m) => m.downloaded)
                      .fold<List<WhisperModel>>([], (acc, m) {
                        if (!acc.any((x) => x.name == m.name)) acc.add(m);
                        return acc;
                      })
                      .map((m) => DropdownMenuItem(
                          value: m.name, child: Text(m.name)))
                      .toList(),
                  onChanged: (v) => setState(() => _selectedModel = v),
                  hint: const Text('Нет модели',
                      style: TextStyle(fontSize: 13)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: _lang,
                  decoration: const InputDecoration(
                      labelText: 'Язык', isDense: true),
                  items: _languages
                      .map((l) => DropdownMenuItem(
                          value: l.$1, child: Text(l.$2)))
                      .toList(),
                  onChanged: (v) {
                    setState(() => _lang = v!);
                    _backend.updateSettings({'lang': v});
                  },
                  isExpanded: true,
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 55,
                child: TextFormField(
                  initialValue: _beam.toString(),
                  decoration: const InputDecoration(
                      labelText: 'Beam', isDense: true),
                  keyboardType: TextInputType.number,
                  onChanged: (v) {
                    final n = int.tryParse(v);
                    if (n != null && n >= 1) {
                      setState(() => _beam = n);
                      _backend.updateSettings({'beam': n});
                    }
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            value: _devices.any((d) => d['id'] == _device) ? _device : _devices.first['id'],
            decoration: const InputDecoration(
                labelText: 'Устройство', isDense: true),
            items: _devices
                .map((d) => DropdownMenuItem(
                    value: d['id'], child: Text(d['name']!, overflow: TextOverflow.ellipsis)))
                .toList(),
            onChanged: (v) {
              setState(() => _device = v!);
              _backend.updateSettings({'device': v});
            },
            isExpanded: true,
          ),
        ],
      );

  void _openModelsFolder() {
    final dir = _modelsDir.isEmpty
        ? '${Platform.environment['USERPROFILE'] ?? ''}\\whisper_models'
        : _modelsDir;
    // Create directory if it doesn't exist so Explorer opens it (not Documents)
    Directory(dir).createSync(recursive: true);
    Process.run('explorer', [dir]);
  }

  Widget _buildModelsPath(ColorScheme cs) {
    return Row(
      children: [
        Icon(Icons.folder_outlined, size: 14,
            color: cs.onSurface.withValues(alpha: 0.5)),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            _modelsDir.isEmpty ? '~/whisper_models' : _modelsDir,
            style: TextStyle(
                fontSize: 11,
                color: cs.onSurface.withValues(alpha: 0.5)),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        InkWell(
          onTap: _openModelsFolder,
          borderRadius: BorderRadius.circular(4),
          child: Tooltip(
            message: 'Открыть папку',
            child: Icon(Icons.open_in_new, size: 14,
                color: cs.onSurface.withValues(alpha: 0.4)),
          ),
        ),
      ],
    );
  }

  Widget _buildModelsList(ColorScheme cs) {
    return Column(
      children: _allModels.map((m) => _buildModelRow(m, cs)).toList(),
    );
  }

  Widget _buildModelRow(WhisperModel m, ColorScheme cs) {
    final dl = _dlState[m.name];
    final isDownloading = dl != null;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                m.downloaded
                    ? Icons.check_circle_outline
                    : Icons.radio_button_unchecked,
                size: 14,
                color: m.downloaded
                    ? Colors.green.shade600
                    : cs.onSurface.withValues(alpha: 0.35),
              ),
              const SizedBox(width: 6),
              Text(m.name,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: m.downloaded
                          ? FontWeight.w500
                          : FontWeight.normal)),
              const SizedBox(width: 4),
              Text(m.sizeLabel,
                  style: TextStyle(
                      fontSize: 11,
                      color: cs.onSurface.withValues(alpha: 0.4))),
              if (m.name == 'turbo') ...[
                const SizedBox(width: 4),
                Text('rec',
                    style: TextStyle(
                        fontSize: 10,
                        color: cs.primary,
                        fontWeight: FontWeight.w500)),
              ],
              const Spacer(),
              if (isDownloading)
                InkWell(
                  onTap: () => _cancelDownload(m.name),
                  borderRadius: BorderRadius.circular(4),
                  child: Tooltip(
                    message: 'Отменить загрузку',
                    child: Icon(Icons.cancel_outlined, size: 16,
                        color: cs.error),
                  ),
                )
              else if (m.downloaded)
                InkWell(
                  onTap: () => _deleteModel(m.name),
                  borderRadius: BorderRadius.circular(4),
                  child: Icon(Icons.delete_outline, size: 16,
                      color: cs.onSurface.withValues(alpha: 0.4)),
                )
              else
                InkWell(
                  onTap: () => _downloadModel(m.name),
                  borderRadius: BorderRadius.circular(4),
                  child: Icon(Icons.download_outlined, size: 16,
                      color: cs.primary),
                ),
            ],
          ),
          if (isDownloading) ...[
            const SizedBox(height: 3),
            Row(
              children: [
                const SizedBox(width: 20),
                Expanded(
                  child: LinearProgressIndicator(
                    value: dl.pct / 100,
                    minHeight: 3,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 6),
                Text('${dl.pct}% · ${dl.speed.toStringAsFixed(1)} MB/s',
                    style: TextStyle(
                        fontSize: 10,
                        color: cs.onSurface.withValues(alpha: 0.5))),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // ── Right panel ─────────────────────────────────────────────────────────────

  Widget _buildRightPanel() {
    if (_viewingTask != null) {
      return _ResultView(
        task: _viewingTask!,
        onClose: () => setState(() => _viewingTask = null),
      );
    }
    return _buildTaskList();
  }

  Widget _buildTaskList() {
    final cs = Theme.of(context).colorScheme;

    if (_tasks.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.mic_none_rounded,
                size: 52, color: cs.onSurface.withValues(alpha: 0.2)),
            const SizedBox(height: 12),
            Text('Добавьте файлы и нажмите «Транскрибировать»',
                style: TextStyle(
                    color: cs.onSurface.withValues(alpha: 0.4), fontSize: 14)),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _tasks.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (ctx, i) => _TaskCard(
        task: _tasks[i],
        onView: () => setState(() => _viewingTask = _tasks[i]),
        onCancel: () async {
          setState(() => _tasks[i].status = TaskStatus.cancelled);
          try {
            await _backend.cancelTask(_tasks[i].taskId);
          } catch (_) {
            // Task may already be done/errored on backend — UI already updated
          }
        },
        onDelete: () => setState(() => _tasks.removeAt(i)),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Task card
// ─────────────────────────────────────────────────────────────────────────────

class _TaskCard extends StatelessWidget {
  final TranscribeTask task;
  final VoidCallback onView;
  final VoidCallback onCancel;
  final VoidCallback onDelete;

  const _TaskCard(
      {required this.task, required this.onView, required this.onCancel, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            _statusIcon(cs),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(task.fileName,
                      style: const TextStyle(
                          fontWeight: FontWeight.w500, fontSize: 13),
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  _statusText(cs),
                  if (task.isActive) ...[
                    const SizedBox(height: 6),
                    LinearProgressIndicator(
                      value: _transcribeProgress(task.statusText),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (task.status == TaskStatus.done) ...[
              FilledButton.tonal(
                  onPressed: onView, child: const Text('Открыть')),
              const SizedBox(width: 4),
              IconButton(
                  icon: const Icon(Icons.delete_outline, size: 18),
                  tooltip: 'Удалить',
                  onPressed: onDelete),
            ] else if (task.isActive)
              IconButton(
                  icon: const Icon(Icons.stop_circle_outlined),
                  tooltip: 'Отмена',
                  onPressed: onCancel)
            else
              IconButton(
                  icon: const Icon(Icons.delete_outline, size: 18),
                  tooltip: 'Удалить',
                  onPressed: onDelete),
          ],
        ),
      ),
    );
  }

  double? _transcribeProgress(String s) {
    if (s.startsWith('transcribing:')) {
      final pct = int.tryParse(s.split(':').last) ?? 0;
      return pct > 0 ? pct / 100.0 : null; // null = indeterminate (pulsing)
    }
    return null; // indeterminate for loading_model, extracting_audio, etc.
  }

  Widget _statusIcon(ColorScheme cs) {
    return switch (task.status) {
      TaskStatus.queued =>
        Icon(Icons.schedule_outlined,
            size: 18, color: cs.onSurface.withValues(alpha: 0.4)),
      TaskStatus.running => SizedBox(
          width: 18, height: 18,
          child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary)),
      TaskStatus.done =>
        Icon(Icons.check_circle_outline,
            size: 18, color: Colors.green.shade600),
      TaskStatus.error =>
        Icon(Icons.error_outline, size: 18, color: cs.error),
      TaskStatus.cancelled =>
        Icon(Icons.cancel_outlined,
            size: 18, color: cs.onSurface.withValues(alpha: 0.4)),
    };
  }

  Widget _statusText(ColorScheme cs) {
    final style =
        TextStyle(fontSize: 11, color: cs.onSurface.withValues(alpha: 0.5));
    return switch (task.status) {
      TaskStatus.queued => Text('В очереди…', style: style),
      TaskStatus.running => Text(_translateStatus(task.statusText),
          style: style.copyWith(color: cs.primary)),
      TaskStatus.done =>
        Text('${task.segments.length} сегментов', style: style),
      TaskStatus.error => Text(task.error ?? 'Ошибка',
          style: style.copyWith(color: cs.error),
          overflow: TextOverflow.ellipsis),
      TaskStatus.cancelled => Text('Отменено', style: style),
    };
  }

  String _translateStatus(String s) {
    if (s.startsWith('loading_model:')) {
      return 'Загрузка модели (${s.split(':').last})…';
    }
    if (s.startsWith('transcribing:')) {
      final pct = s.split(':').last;
      return pct == '0' ? 'Транскрибация…' : 'Транскрибация $pct%…';
    }
    return switch (s) {
      'extracting_audio' => 'Извлечение аудио…',
      'converting_audio' => 'Конвертация аудио…',
      'transcribing' => 'Транскрибация…',
      _ => s,
    };
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Result viewer (inline in right panel)
// ─────────────────────────────────────────────────────────────────────────────

class _ResultView extends StatefulWidget {
  final TranscribeTask task;
  final VoidCallback onClose;

  const _ResultView({required this.task, required this.onClose});

  @override
  State<_ResultView> createState() => _ResultViewState();
}

class _ResultViewState extends State<_ResultView> {
  late List<Segment> _segments;
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _segments = List.from(widget.task.segments);
    _searchCtrl.addListener(
        () => setState(() => _query = _searchCtrl.text.toLowerCase()));
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  List<Segment> get _filtered => _query.isEmpty
      ? _segments
      : _segments.where((s) => s.text.toLowerCase().contains(_query)).toList();

  String _toSrt() {
    final sb = StringBuffer();
    for (var i = 0; i < _segments.length; i++) {
      final s = _segments[i];
      sb.writeln(i + 1);
      sb.writeln('${_srtTime(s.start)} --> ${_srtTime(s.end)}');
      sb.writeln(s.text);
      sb.writeln();
    }
    return sb.toString();
  }

  String _toVtt() {
    final sb = StringBuffer('WEBVTT\n\n');
    for (final s in _segments) {
      sb.writeln('${_vttTime(s.start)} --> ${_vttTime(s.end)}');
      sb.writeln(s.text);
      sb.writeln();
    }
    return sb.toString();
  }

  String _toTxt() => _segments
      .map((s) => '[${s.startFormatted} - ${s.endFormatted}] ${s.text}')
      .join('\n');

  static String _srtTime(double s) {
    final ms = ((s % 1) * 1000).toInt();
    return '${_hms(s.toInt())},${ms.toString().padLeft(3, '0')}';
  }

  static String _vttTime(double s) {
    final ms = ((s % 1) * 1000).toInt();
    return '${_hms(s.toInt())}.${ms.toString().padLeft(3, '0')}';
  }

  static String _hms(int t) {
    final h = t ~/ 3600;
    final m = (t % 3600) ~/ 60;
    final s = t % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  Future<void> _export(String format) async {
    final content = switch (format) {
      'srt' => _toSrt(),
      'vtt' => _toVtt(),
      _ => _toTxt(),
    };
    final base = widget.task.fileName.replaceAll(RegExp(r'\.[^.]+$'), '');
    final path = await FilePicker.platform
        .saveFile(dialogTitle: 'Сохранить $format', fileName: '$base.$format');
    if (path == null) return;
    await File(path).writeAsString(content, encoding: utf8);
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Сохранено: $path')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final filtered = _filtered;

    return Column(
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
          child: Row(
            children: [
              IconButton(
                  icon: const Icon(Icons.arrow_back), onPressed: widget.onClose),
              Expanded(
                child: Text(widget.task.fileName,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 14),
                    overflow: TextOverflow.ellipsis),
              ),
              _ExBtn('SRT', () => _export('srt')),
              const SizedBox(width: 6),
              _ExBtn('VTT', () => _export('vtt')),
              const SizedBox(width: 6),
              _ExBtn('TXT', () => _export('txt')),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: TextField(
            controller: _searchCtrl,
            decoration: InputDecoration(
              hintText: 'Поиск…',
              prefixIcon: const Icon(Icons.search, size: 18),
              isDense: true,
              suffixIcon: _query.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 16),
                      onPressed: () => _searchCtrl.clear())
                  : null,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('${filtered.length} сегментов',
                style: TextStyle(
                    fontSize: 11,
                    color: cs.onSurface.withValues(alpha: 0.4))),
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            itemCount: filtered.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (ctx, i) => _SegRow(
              segment: filtered[i],
              query: _query,
              onCopy: () {
                Clipboard.setData(ClipboardData(text: filtered[i].text));
                ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                    content: Text('Скопировано'),
                    duration: Duration(seconds: 1)));
              },
              onChanged: (t) => setState(() => filtered[i].text = t),
            ),
          ),
        ),
      ],
    );
  }
}

class _ExBtn extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _ExBtn(this.label, this.onTap);

  @override
  Widget build(BuildContext context) => OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap),
        child: Text(label, style: const TextStyle(fontSize: 11)),
      );
}

class _SegRow extends StatefulWidget {
  final Segment segment;
  final String query;
  final VoidCallback onCopy;
  final void Function(String) onChanged;

  const _SegRow(
      {required this.segment,
      required this.query,
      required this.onCopy,
      required this.onChanged});

  @override
  State<_SegRow> createState() => _SegRowState();
}

class _SegRowState extends State<_SegRow> {
  bool _editing = false;
  late TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.segment.text);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              '${widget.segment.startFormatted}\n${widget.segment.endFormatted}',
              style: TextStyle(
                  fontSize: 10,
                  color: cs.onSurface.withValues(alpha: 0.4),
                  height: 1.6,
                  fontFamily: 'monospace'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _editing
                ? TextField(
                    controller: _ctrl,
                    maxLines: null,
                    autofocus: true,
                    style: const TextStyle(fontSize: 13),
                    onTapOutside: (_) {
                      widget.onChanged(_ctrl.text);
                      setState(() => _editing = false);
                    },
                  )
                : GestureDetector(
                    onDoubleTap: () => setState(() => _editing = true),
                    child: widget.query.isNotEmpty
                        ? _highlight(widget.segment.text, widget.query, cs)
                        : Text(widget.segment.text,
                            style: const TextStyle(fontSize: 13, height: 1.5)),
                  ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                  icon: const Icon(Icons.copy_outlined, size: 14),
                  onPressed: widget.onCopy),
              IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 14),
                  onPressed: () => setState(() => _editing = !_editing)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _highlight(String text, String query, ColorScheme cs) {
    final lower = text.toLowerCase();
    final spans = <TextSpan>[];
    var start = 0;
    int idx;
    while ((idx = lower.indexOf(query, start)) != -1) {
      if (idx > start) spans.add(TextSpan(text: text.substring(start, idx)));
      spans.add(TextSpan(
        text: text.substring(idx, idx + query.length),
        style: TextStyle(
            backgroundColor: cs.primary.withValues(alpha: 0.25),
            color: cs.primary),
      ));
      start = idx + query.length;
    }
    if (start < text.length) spans.add(TextSpan(text: text.substring(start)));
    return RichText(
      text: TextSpan(
        style:
            TextStyle(fontSize: 13, height: 1.5, color: cs.onSurface),
        children: spans,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Text(text,
      style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
          color:
              Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5)));
}

class _DlState {
  final int pct;
  final double speed;
  const _DlState({required this.pct, required this.speed});
}
