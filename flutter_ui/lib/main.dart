import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'models/models.dart';
import 'screens/home_screen.dart';
import 'screens/model_manager_screen.dart';
import 'screens/queue_screen.dart';
import 'screens/result_screen.dart';
import 'services/backend_service.dart';
import 'theme/app_theme.dart';

Process? _backendProcess;

Future<void> _startBackend() async {
  // backend.exe sits next to the Flutter exe
  final exeDir = p.dirname(Platform.resolvedExecutable);
  final backendExe = p.join(exeDir, 'backend.exe');
  if (!File(backendExe).existsSync()) return; // dev mode — backend started manually

  _backendProcess = await Process.start(
    backendExe,
    [],
    mode: ProcessStartMode.detachedWithStdio,
  );
}

Future<void> _waitForBackend() async {
  const timeout = Duration(seconds: 90);
  const interval = Duration(milliseconds: 500);
  final deadline = DateTime.now().add(timeout);

  while (DateTime.now().isBefore(deadline)) {
    if (await BackendService.instance.isAlive()) return;
    await Future.delayed(interval);
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _startBackend();
  runApp(const WhisperApp());
}


class WhisperApp extends StatefulWidget {
  const WhisperApp({super.key});

  @override
  State<WhisperApp> createState() => _WhisperAppState();
}

class _WhisperAppState extends State<WhisperApp> {
  ThemeMode _themeMode = ThemeMode.light;

  void _toggleTheme() => setState(() {
        _themeMode =
            _themeMode == ThemeMode.light ? ThemeMode.dark : ThemeMode.light;
      });

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Whisper Transcriber',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: _themeMode,
        home: MainShell(
          themeMode: _themeMode,
          onToggleTheme: _toggleTheme,
        ),
      );
}

class MainShell extends StatefulWidget {
  final ThemeMode themeMode;
  final VoidCallback onToggleTheme;

  const MainShell({
    super.key,
    required this.themeMode,
    required this.onToggleTheme,
  });

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _navIndex = 0;
  final List<TranscribeTask> _tasks = [];
  TranscribeTask? _viewingResult;
  bool _backendAlive = false;
  bool _backendReady = false;
  StreamSubscription? _eventSub;
  Timer? _healthTimer;

  @override
  void initState() {
    super.initState();
    _waitForBackendThenConnect();
    _eventSub = BackendService.instance.events.listen(_onEvent);
  }

  Future<void> _waitForBackendThenConnect() async {
    await _waitForBackend();
    if (!mounted) return;
    setState(() => _backendReady = true);
    BackendService.instance.connectWebSocket();
    _startHealthCheck();
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _healthTimer?.cancel();
    _backendProcess?.kill();
    super.dispose();
  }

  void _startHealthCheck() {
    _checkHealth();
    _healthTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _checkHealth(),
    );
  }

  Future<void> _checkHealth() async {
    final alive = await BackendService.instance.isAlive();
    if (mounted && alive != _backendAlive) {
      setState(() => _backendAlive = alive);
    }
  }

  void _onEvent(Map<String, dynamic> event) {
    final type = event['type'] as String?;
    final taskId = event['task_id'] as String?;

    switch (type) {
      case 'task_status':
        _updateTask(taskId, (t) {
          t.status = TaskStatus.running;
          t.statusText = event['status'] as String? ?? '';
        });

      case 'segment':
        _updateTask(taskId, (t) {
          final seg = Segment.fromJson(
              event['segment'] as Map<String, dynamic>);
          t.segments.add(seg);
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

  void _updateTask(String? taskId, void Function(TranscribeTask) fn) {
    if (taskId == null) return;
    setState(() {
      final idx = _tasks.indexWhere((t) => t.taskId == taskId);
      if (idx >= 0) fn(_tasks[idx]);
    });
  }

  void _onTranscribeStarted(List<String> taskIds) {
    setState(() {
      for (final id in taskIds) {
        _tasks.add(TranscribeTask(
          taskId: id,
          file: '',
          model: '',
        ));
      }
      _navIndex = 1; // switch to queue
    });
  }

  void _viewResult(TranscribeTask task) {
    setState(() {
      _viewingResult = task;
      _navIndex = 1;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.themeMode == ThemeMode.dark;
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(Icons.mic_rounded, color: cs.primary, size: 22),
            const SizedBox(width: 8),
            const Text('Whisper Transcriber'),
          ],
        ),
        actions: [
          // Backend status indicator
          Tooltip(
            message: _backendAlive ? 'Backend connected' : 'Backend offline',
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Icon(
                Icons.circle,
                size: 10,
                color: _backendAlive ? Colors.green : Colors.red,
              ),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: Icon(isDark ? Icons.light_mode : Icons.dark_mode),
            tooltip: isDark ? 'Light theme' : 'Dark theme',
            onPressed: widget.onToggleTheme,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _navIndex,
            onDestinationSelected: (i) {
              setState(() {
                _navIndex = i;
                if (i != 1) _viewingResult = null;
              });
            },
            labelType: NavigationRailLabelType.all,
            destinations: [
              const NavigationRailDestination(
                icon: Icon(Icons.add_box_outlined),
                selectedIcon: Icon(Icons.add_box_rounded),
                label: Text('Transcribe'),
              ),
              NavigationRailDestination(
                icon: Badge(
                  isLabelVisible:
                      _tasks.any((t) => t.isActive),
                  child: const Icon(Icons.list_alt_outlined),
                ),
                selectedIcon: Badge(
                  isLabelVisible:
                      _tasks.any((t) => t.isActive),
                  child: const Icon(Icons.list_alt_rounded),
                ),
                label: const Text('Queue'),
              ),
              const NavigationRailDestination(
                icon: Icon(Icons.storage_outlined),
                selectedIcon: Icon(Icons.storage_rounded),
                label: Text('Models'),
              ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (!_backendReady) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 20),
            const Text('Starting backend…',
                style: TextStyle(fontSize: 15)),
            const SizedBox(height: 8),
            Text('First launch may take up to a minute',
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.5))),
          ],
        ),
      );
    }
    if (_navIndex == 0) {
      return HomeScreen(onTranscribeStarted: _onTranscribeStarted);
    }
    if (_navIndex == 1) {
      if (_viewingResult != null) {
        return ResultScreen(
          task: _viewingResult!,
          onClose: () => setState(() => _viewingResult = null),
        );
      }
      return QueueScreen(
        tasks: _tasks,
        onViewResult: _viewResult,
      );
    }
    return const ModelManagerScreen();
  }
}
