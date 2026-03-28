import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'screens/app_screen.dart';
import 'services/backend_service.dart';
import 'theme/app_theme.dart';

Process? _backendProcess;

Future<void> _startBackend() async {
  // If backend is alive AND we own the process, reuse it
  if (_backendProcess != null && await BackendService.instance.isAlive()) return;

  // Kill orphan backend left by a previous Flutter instance
  if (await BackendService.instance.isAlive()) {
    await BackendService.instance.shutdown();
    await Future.delayed(const Duration(milliseconds: 1500));
  }

  final exeDir = p.dirname(Platform.resolvedExecutable);
  final backendExe = p.join(exeDir, 'backend', 'backend.exe');
  if (!File(backendExe).existsSync()) return;
  // Pass our PID so backend can exit when Flutter closes
  // Use fully detached mode: no pipes, no console window.
  // The backend manages its own log file (~\whisper_backend.log).
  _backendProcess = await Process.start(
    backendExe, [pid.toString()],
    workingDirectory: p.dirname(backendExe),
    mode: ProcessStartMode.detached,
  );
}

Future<bool> _waitForBackend() async {
  const timeout = Duration(seconds: 90);
  const interval = Duration(milliseconds: 500);
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await BackendService.instance.isAlive()) return true;
    await Future.delayed(interval);
  }
  return false;
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final crashLog = File('${Platform.environment['USERPROFILE'] ?? Platform.environment['HOME']}/whisper_flutter_crash.log');

  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    try {
      crashLog.writeAsStringSync(
        '[${DateTime.now()}] Flutter error:\n${details.exceptionAsString()}\n${details.stack}\n\n',
        mode: FileMode.append,
      );
    } catch (_) {}
  };

  try {
    await _startBackend();
  } catch (e, st) {
    try { crashLog.writeAsStringSync('[${DateTime.now()}] _startBackend error: $e\n$st\n\n', mode: FileMode.append); } catch (_) {}
  }
  runApp(const WhisperApp());
}

class WhisperApp extends StatefulWidget {
  const WhisperApp({super.key});

  @override
  State<WhisperApp> createState() => _WhisperAppState();
}

class _WhisperAppState extends State<WhisperApp> {
  ThemeMode _themeMode = ThemeMode.light;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Whisper Транскрибатор',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: _themeMode,
        home: _Shell(
          themeMode: _themeMode,
          onToggleTheme: () => setState(() => _themeMode =
              _themeMode == ThemeMode.light ? ThemeMode.dark : ThemeMode.light),
        ),
      );
}

class _Shell extends StatefulWidget {
  final ThemeMode themeMode;
  final VoidCallback onToggleTheme;
  const _Shell({required this.themeMode, required this.onToggleTheme});

  @override
  State<_Shell> createState() => _ShellState();
}

class _ShellState extends State<_Shell> {
  bool _ready = false;
  bool _alive = false;
  Timer? _healthTimer;

  @override
  void initState() {
    super.initState();
    _waitForBackend().then((alive) {
      if (!mounted) return;
      setState(() { _ready = true; _alive = alive; });
      if (alive) BackendService.instance.connectWebSocket();
      _healthTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
        final alive = await BackendService.instance.isAlive();
        if (mounted && alive != _alive) {
          setState(() => _alive = alive);
          if (alive) BackendService.instance.connectWebSocket();
        }
      });
    });
  }

  @override
  void dispose() {
    _healthTimer?.cancel();
    BackendService.instance.disconnectWebSocket();
    _backendProcess?.kill();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.themeMode == ThemeMode.dark;
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          Icon(Icons.mic_rounded, color: cs.primary, size: 20),
          const SizedBox(width: 8),
          const Text('Whisper Транскрибатор'),
        ]),
        actions: [
          Tooltip(
            message: _ready
                ? (_alive ? 'Бэкенд работает' : 'Бэкенд недоступен')
                : 'Запуск бэкенда…',
            child: _ready
                ? Icon(Icons.circle,
                    size: 9, color: _alive ? Colors.green : Colors.red)
                : const SizedBox(
                    width: 9, height: 9,
                    child: CircularProgressIndicator(strokeWidth: 1.5)),
          ),
          const SizedBox(width: 6),
          IconButton(
            icon: Icon(isDark ? Icons.light_mode : Icons.dark_mode),
            onPressed: widget.onToggleTheme,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _ready ? const AppScreen() : _buildLoading(cs),
    );
  }

  Widget _buildLoading(ColorScheme cs) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 20),
            const Text('Запуск бэкенда…', style: TextStyle(fontSize: 15)),
            const SizedBox(height: 8),
            Text('Первый запуск может занять до минуты',
                style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurface.withValues(alpha:0.5))),
          ],
        ),
      );
}
