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
  // If backend is already running (e.g. previous instance), reuse it
  if (await BackendService.instance.isAlive()) return;

  final exeDir = p.dirname(Platform.resolvedExecutable);
  final backendExe = p.join(exeDir, 'backend', 'backend.exe');
  if (!File(backendExe).existsSync()) return;
  _backendProcess = await Process.start(
    backendExe, [],
    workingDirectory: p.dirname(backendExe),
    mode: ProcessStartMode.normal,
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

  // Catch all uncaught Flutter framework errors (prevents red screen crash)
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
  };

  // Catch all uncaught async errors in the zone (e.g. WebSocket exceptions)
  runZonedGuarded(() async {
    await _startBackend();
    runApp(const WhisperApp());
  }, (error, stack) {
    // Swallow zone errors silently — app keeps running
    debugPrint('Zone error (caught): $error');
  });
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
    _waitForBackend().then((_) {
      if (!mounted) return;
      setState(() { _ready = true; _alive = true; });
      BackendService.instance.connectWebSocket();
      _healthTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
        final alive = await BackendService.instance.isAlive();
        if (mounted && alive != _alive) setState(() => _alive = alive);
      });
    });
  }

  @override
  void dispose() {
    _healthTimer?.cancel();
    BackendService.instance.dispose();
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
                    color: cs.onSurface.withValues(alpha: 0.5))),
          ],
        ),
      );
}
