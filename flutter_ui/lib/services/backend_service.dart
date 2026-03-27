import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/models.dart';

const _baseUrl = 'http://127.0.0.1:8765';
const _wsUrl = 'ws://127.0.0.1:8765/ws';

class BackendService {
  static final BackendService instance = BackendService._();
  BackendService._();

  WebSocketChannel? _channel;
  StreamSubscription? _wsSub;
  final _eventController = StreamController<Map<String, dynamic>>.broadcast();
  bool _disposed = false;

  Stream<Map<String, dynamic>> get events => _eventController.stream;

  void connectWebSocket() {
    if (_disposed) return;
    // Close previous connection and subscription
    _wsSub?.cancel();
    _wsSub = null;
    try { _channel?.sink.close(); } catch (_) {}
    _channel = null;

    try {
      _channel = WebSocketChannel.connect(Uri.parse(_wsUrl));
      _wsSub = _channel!.stream.listen(
        (data) {
          try {
            final event = json.decode(data as String) as Map<String, dynamic>;
            if (!_eventController.isClosed) {
              _eventController.add(event);
            }
          } catch (_) {}
        },
        onDone: () {
          if (!_disposed) {
            Future.delayed(const Duration(seconds: 2), connectWebSocket);
          }
        },
        onError: (_) {
          if (!_disposed) {
            Future.delayed(const Duration(seconds: 2), connectWebSocket);
          }
        },
      );
    } catch (_) {
      if (!_disposed) {
        Future.delayed(const Duration(seconds: 2), connectWebSocket);
      }
    }
  }

  void dispose() {
    _disposed = true;
    _wsSub?.cancel();
    _wsSub = null;
    try { _channel?.sink.close(); } catch (_) {}
    _channel = null;
    _eventController.close();
  }

  // ── Models ────────────────────────────────────────────────────────────────

  Future<List<WhisperModel>> getModels() async {
    final resp = await http.get(Uri.parse('$_baseUrl/models'));
    _checkStatus(resp);
    final list = json.decode(resp.body) as List;
    return list
        .map((e) => WhisperModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> downloadModel(String name) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/models/download'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'name': name}),
    );
    _checkStatus(resp);
  }

  Future<void> cancelDownload(String name) async {
    final resp =
        await http.delete(Uri.parse('$_baseUrl/models/download/$name'));
    _checkStatus(resp);
  }

  Future<void> deleteModel(String name) async {
    final resp = await http.delete(Uri.parse('$_baseUrl/models/$name'));
    _checkStatus(resp);
  }

  // ── Transcription ─────────────────────────────────────────────────────────

  Future<List<String>> transcribe({
    required List<String> files,
    required String modelName,
    String language = 'auto',
    int beamSize = 5,
    String? device,
  }) async {
    final body = {
      'files': files,
      'model_name': modelName,
      'language': language,
      'beam_size': beamSize,
      if (device != null) 'device': device,
    };
    final resp = await http.post(
      Uri.parse('$_baseUrl/transcribe'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode(body),
    );
    _checkStatus(resp);
    final data = json.decode(resp.body) as Map<String, dynamic>;
    return List<String>.from(data['task_ids'] as List);
  }

  Future<void> cancelTask(String taskId) async {
    final resp =
        await http.delete(Uri.parse('$_baseUrl/transcribe/$taskId'));
    _checkStatus(resp);
  }

  Future<List<Segment>> getResult(String taskId) async {
    final resp =
        await http.get(Uri.parse('$_baseUrl/transcribe/$taskId/result'));
    _checkStatus(resp);
    final data = json.decode(resp.body) as Map<String, dynamic>;
    final list = data['segments'] as List;
    return list
        .map((e) => Segment.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // ── Devices ────────────────────────────────────────────────────────────────

  Future<List<Map<String, String>>> getDevices() async {
    try {
      final resp = await http.get(Uri.parse('$_baseUrl/devices'));
      _checkStatus(resp);
      final list = json.decode(resp.body) as List;
      return list
          .map((e) => Map<String, String>.from(e as Map))
          .toList();
    } catch (_) {
      return [
        {'id': 'cpu', 'name': 'CPU'},
        {'id': 'cuda', 'name': 'CUDA'},
      ];
    }
  }

  // ── Settings ──────────────────────────────────────────────────────────────

  Future<AppSettings> getSettings() async {
    final resp = await http.get(Uri.parse('$_baseUrl/settings'));
    _checkStatus(resp);
    return AppSettings.fromJson(
        json.decode(resp.body) as Map<String, dynamic>);
  }

  Future<AppSettings> updateSettings(Map<String, dynamic> patch) async {
    final resp = await http.patch(
      Uri.parse('$_baseUrl/settings'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode(patch),
    );
    _checkStatus(resp);
    return AppSettings.fromJson(
        json.decode(resp.body) as Map<String, dynamic>);
  }

  // ── Health ────────────────────────────────────────────────────────────────

  Future<bool> isAlive() async {
    try {
      final resp = await http
          .get(Uri.parse('$_baseUrl/settings'))
          .timeout(const Duration(seconds: 3));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  void _checkStatus(http.Response resp) {
    if (resp.statusCode >= 400) {
      String msg;
      try {
        final body = json.decode(resp.body) as Map;
        msg = body['detail']?.toString() ?? resp.body;
      } catch (_) {
        msg = resp.body;
      }
      throw Exception('Backend error ${resp.statusCode}: $msg');
    }
  }
}
