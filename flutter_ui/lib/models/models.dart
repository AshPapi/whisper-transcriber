/// Data models for Whisper Transcriber

class WhisperModel {
  final String name;
  final String sizeLabel;
  final int sizeMb;
  final bool downloaded;
  final String? path;

  const WhisperModel({
    required this.name,
    required this.sizeLabel,
    required this.sizeMb,
    required this.downloaded,
    this.path,
  });

  factory WhisperModel.fromJson(Map<String, dynamic> j) => WhisperModel(
        name: j['name'] as String,
        sizeLabel: j['size_label'] as String,
        sizeMb: (j['size_mb'] as num).toInt(),
        downloaded: j['downloaded'] as bool,
        path: j['path'] as String?,
      );
}

class Segment {
  final int id;
  final double start;
  final double end;
  String text;

  Segment({
    required this.id,
    required this.start,
    required this.end,
    required this.text,
  });

  factory Segment.fromJson(Map<String, dynamic> j) => Segment(
        id: (j['id'] as num).toInt(),
        start: (j['start'] as num).toDouble(),
        end: (j['end'] as num).toDouble(),
        text: j['text'] as String,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'start': start,
        'end': end,
        'text': text,
      };

  String get startFormatted => _fmt(start);
  String get endFormatted => _fmt(end);

  static String _fmt(double s) {
    final t = s.toInt();
    final m = t ~/ 60;
    final h = m ~/ 60;
    final sec = t % 60;
    final min = m % 60;
    return h > 0
        ? '${h.toString().padLeft(2, '0')}:${min.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}'
        : '${min.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }
}

enum TaskStatus { queued, running, done, error, cancelled }

class TranscribeTask {
  final String taskId;
  final String file;
  final String model;
  TaskStatus status;
  String statusText;
  List<Segment> segments;
  String? error;

  TranscribeTask({
    required this.taskId,
    required this.file,
    required this.model,
    this.status = TaskStatus.queued,
    this.statusText = '',
    List<Segment>? segments,
    this.error,
  }) : segments = segments ?? [];

  String get fileName => file.split(RegExp(r'[/\\]')).last;

  bool get isActive => status == TaskStatus.queued || status == TaskStatus.running;
}

class AppSettings {
  String modelsDir;
  String device;
  String lang;
  int beam;

  AppSettings({
    required this.modelsDir,
    required this.device,
    required this.lang,
    required this.beam,
  });

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        modelsDir: j['models_dir'] as String,
        device: j['device'] as String,
        lang: j['lang'] as String,
        beam: (j['beam'] as num).toInt(),
      );
}
