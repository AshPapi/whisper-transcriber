import 'dart:async';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../models/models.dart';
import '../services/backend_service.dart';

class HomeScreen extends StatefulWidget {
  final void Function(List<String> taskIds) onTranscribeStarted;

  const HomeScreen({super.key, required this.onTranscribeStarted});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _backend = BackendService.instance;

  List<String> _files = [];
  List<WhisperModel> _models = [];
  String? _selectedModel;
  String _lang = 'auto';
  int _beam = 5;
  String _device = 'cpu';
  bool _loading = false;
  bool _dragging = false;
  String? _error;

  static const _supportedExt = {
    'mp3', 'wav', 'ogg', 'flac', 'm4a', 'aac', 'wma', 'opus',
    'mp4', 'mkv', 'avi', 'mov', 'webm', 'flv', 'ts', 'm4v',
  };

  static const _languages = [
    ('auto', 'Auto detect'),
    ('ru', 'Russian'),
    ('en', 'English'),
    ('de', 'German'),
    ('fr', 'French'),
    ('es', 'Spanish'),
    ('it', 'Italian'),
    ('zh', 'Chinese'),
    ('ja', 'Japanese'),
    ('uk', 'Ukrainian'),
    ('pl', 'Polish'),
    ('pt', 'Portuguese'),
    ('nl', 'Dutch'),
    ('tr', 'Turkish'),
    ('ar', 'Arabic'),
    ('ko', 'Korean'),
  ];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    try {
      final settings = await _backend.getSettings();
      final models = await _backend.getModels();
      if (!mounted) return;
      setState(() {
        _lang = settings.lang;
        _beam = settings.beam;
        _device = settings.device;
        _models = models.where((m) => m.downloaded).toList();
        if (_models.isNotEmpty) {
          _selectedModel = _models
              .firstWhere(
                (m) => m.name == 'turbo',
                orElse: () => _models.first,
              )
              .name;
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _addFiles(List<String> paths) {
    final valid = paths.where((p) {
      final ext = p.split('.').last.toLowerCase();
      return _supportedExt.contains(ext);
    }).toList();
    if (valid.isEmpty) return;
    setState(() => _files = [..._files, ...valid]);
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.any,
    );
    if (result != null) {
      _addFiles(result.files.map((f) => f.path!).toList());
    }
  }

  Future<void> _startTranscribe() async {
    if (_files.isEmpty || _selectedModel == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ids = await _backend.transcribe(
        files: _files,
        modelName: _selectedModel!,
        language: _lang,
        beamSize: _beam,
        device: _device,
      );
      setState(() => _files = []);
      widget.onTranscribeStarted(ids);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Transcribe',
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 20),

          // Drop zone
          Expanded(
            child: DropTarget(
              onDragDone: (details) =>
                  _addFiles(details.files.map((f) => f.path).toList()),
              onDragEntered: (_) => setState(() => _dragging = true),
              onDragExited: (_) => setState(() => _dragging = false),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: double.infinity,
                decoration: BoxDecoration(
                  border: Border.all(
                    color: _dragging
                        ? cs.primary
                        : cs.outline.withValues(alpha:0.4),
                    width: _dragging ? 2 : 1,
                  ),
                  borderRadius: BorderRadius.circular(12),
                  color: _dragging
                      ? cs.primary.withValues(alpha:0.06)
                      : cs.surface,
                ),
                child: _files.isEmpty
                    ? _buildDropHint(cs)
                    : _buildFileList(cs),
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Controls row
          _buildControls(cs),

          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: cs.error, fontSize: 12)),
          ],

          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: (_files.isEmpty || _selectedModel == null || _loading)
                  ? null
                  : _startTranscribe,
              icon: _loading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.play_arrow_rounded),
              label: Text(_loading ? 'Starting...' : 'Transcribe'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDropHint(ColorScheme cs) => InkWell(
        onTap: _pickFiles,
        borderRadius: BorderRadius.circular(12),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_upload_outlined,
                  size: 52, color: cs.primary.withValues(alpha:0.6)),
              const SizedBox(height: 12),
              Text('Drop files here or click to browse',
                  style: TextStyle(
                      color: cs.onSurface.withValues(alpha:0.7), fontSize: 15)),
              const SizedBox(height: 6),
              Text('Video & audio files supported',
                  style: TextStyle(
                      color: cs.onSurface.withValues(alpha:0.4), fontSize: 12)),
            ],
          ),
        ),
      );

  Widget _buildFileList(ColorScheme cs) => Column(
        children: [
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: _files.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (ctx, i) {
                final name = _files[i].split(RegExp(r'[/\\]')).last;
                return ListTile(
                  dense: true,
                  leading: const Icon(Icons.audio_file_outlined),
                  title: Text(name,
                      style: const TextStyle(fontSize: 13),
                      overflow: TextOverflow.ellipsis),
                  trailing: IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: () =>
                        setState(() => _files.removeAt(i)),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: TextButton.icon(
              onPressed: _pickFiles,
              icon: const Icon(Icons.add),
              label: const Text('Add more files'),
            ),
          ),
        ],
      );

  Widget _buildControls(ColorScheme cs) => Wrap(
        spacing: 12,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          // Model
          SizedBox(
            width: 160,
            child: DropdownButtonFormField<String>(
              value: _selectedModel,
              decoration: const InputDecoration(labelText: 'Model'),
              items: _models
                  .map((m) => DropdownMenuItem(
                      value: m.name, child: Text(m.name)))
                  .toList(),
              onChanged: (v) => setState(() => _selectedModel = v),
              hint: _models.isEmpty
                  ? const Text('No models', style: TextStyle(fontSize: 13))
                  : null,
            ),
          ),

          // Language
          SizedBox(
            width: 160,
            child: DropdownButtonFormField<String>(
              value: _lang,
              decoration: const InputDecoration(labelText: 'Language'),
              items: _languages
                  .map((l) => DropdownMenuItem(
                      value: l.$1, child: Text(l.$2)))
                  .toList(),
              onChanged: (v) => setState(() => _lang = v!),
            ),
          ),

          // Device
          SizedBox(
            width: 110,
            child: DropdownButtonFormField<String>(
              value: _device,
              decoration: const InputDecoration(labelText: 'Device'),
              items: const [
                DropdownMenuItem(value: 'cpu', child: Text('CPU')),
                DropdownMenuItem(value: 'cuda', child: Text('CUDA')),
              ],
              onChanged: (v) => setState(() => _device = v!),
            ),
          ),

          // Beam size
          SizedBox(
            width: 90,
            child: TextFormField(
              initialValue: _beam.toString(),
              decoration: const InputDecoration(labelText: 'Beam'),
              keyboardType: TextInputType.number,
              onChanged: (v) {
                final n = int.tryParse(v);
                if (n != null && n >= 1) setState(() => _beam = n);
              },
            ),
          ),
        ],
      );
}
