import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/models.dart';

class ResultScreen extends StatefulWidget {
  final TranscribeTask task;
  final VoidCallback onClose;

  const ResultScreen({super.key, required this.task, required this.onClose});

  @override
  State<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends State<ResultScreen> {
  late List<Segment> _segments;
  final _searchCtrl = TextEditingController();
  String _query = '';
  bool _edited = false;

  @override
  void initState() {
    super.initState();
    _segments = List.from(widget.task.segments);
    _searchCtrl.addListener(() {
      setState(() => _query = _searchCtrl.text.toLowerCase());
    });
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

  String _toTxt() => _segments.map((s) => s.text).join('\n');

  static String _srtTime(double s) {
    final ms = ((s % 1) * 1000).toInt();
    final t = s.toInt();
    return '${_hms(t)},${ms.toString().padLeft(3, '0')}';
  }

  static String _vttTime(double s) {
    final ms = ((s % 1) * 1000).toInt();
    final t = s.toInt();
    return '${_hms(t)}.${ms.toString().padLeft(3, '0')}';
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

    final baseName =
        widget.task.fileName.replaceAll(RegExp(r'\.[^.]+$'), '');
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Save $format',
      fileName: '$baseName.$format',
    );
    if (path == null) return;

    await File(path).writeAsString(content, encoding: utf8Codec);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved to $path')),
      );
    }
  }

  static const utf8Codec = SystemEncoding();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final filtered = _filtered;

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: widget.onClose,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.task.fileName,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // Export buttons
              _ExportButton(label: 'SRT', onTap: () => _export('srt')),
              const SizedBox(width: 6),
              _ExportButton(label: 'VTT', onTap: () => _export('vtt')),
              const SizedBox(width: 6),
              _ExportButton(label: 'TXT', onTap: () => _export('txt')),
            ],
          ),
          const SizedBox(height: 12),
          // Search
          TextField(
            controller: _searchCtrl,
            decoration: InputDecoration(
              hintText: 'Search…',
              prefixIcon: const Icon(Icons.search, size: 18),
              suffixIcon: _query.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 16),
                      onPressed: () => _searchCtrl.clear(),
                    )
                  : null,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${filtered.length} segment${filtered.length == 1 ? '' : 's'}',
            style: TextStyle(
                fontSize: 12, color: cs.onSurface.withOpacity(0.5)),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.separated(
              itemCount: filtered.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (ctx, i) =>
                  _SegmentTile(
                    segment: filtered[i],
                    query: _query,
                    onCopy: () {
                      Clipboard.setData(
                          ClipboardData(text: filtered[i].text));
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        const SnackBar(
                            content: Text('Copied'),
                            duration: Duration(seconds: 1)),
                      );
                    },
                    onChanged: (text) {
                      setState(() {
                        filtered[i].text = text;
                        _edited = true;
                      });
                    },
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ExportButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _ExportButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) => OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Text(label, style: const TextStyle(fontSize: 12)),
      );
}

class _SegmentTile extends StatefulWidget {
  final Segment segment;
  final String query;
  final VoidCallback onCopy;
  final void Function(String) onChanged;

  const _SegmentTile({
    required this.segment,
    required this.query,
    required this.onCopy,
    required this.onChanged,
  });

  @override
  State<_SegmentTile> createState() => _SegmentTileState();
}

class _SegmentTileState extends State<_SegmentTile> {
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
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Timestamps
          SizedBox(
            width: 110,
            child: Text(
              '${widget.segment.startFormatted}\n${widget.segment.endFormatted}',
              style: TextStyle(
                  fontSize: 11,
                  color: cs.onSurface.withOpacity(0.4),
                  height: 1.6,
                  fontFamily: 'monospace'),
            ),
          ),
          const SizedBox(width: 10),
          // Text
          Expanded(
            child: _editing
                ? TextField(
                    controller: _ctrl,
                    maxLines: null,
                    autofocus: true,
                    style: const TextStyle(fontSize: 13),
                    onSubmitted: (v) {
                      widget.onChanged(v);
                      setState(() => _editing = false);
                    },
                    onTapOutside: (_) {
                      widget.onChanged(_ctrl.text);
                      setState(() => _editing = false);
                    },
                  )
                : GestureDetector(
                    onDoubleTap: () => setState(() => _editing = true),
                    child: widget.query.isNotEmpty
                        ? _highlightedText(
                            widget.segment.text, widget.query, cs)
                        : Text(widget.segment.text,
                            style: const TextStyle(fontSize: 13, height: 1.5)),
                  ),
          ),
          // Actions
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.copy_outlined, size: 15),
                tooltip: 'Copy',
                onPressed: widget.onCopy,
              ),
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 15),
                tooltip: 'Edit',
                onPressed: () => setState(() => _editing = !_editing),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _highlightedText(String text, String query, ColorScheme cs) {
    final lower = text.toLowerCase();
    final spans = <TextSpan>[];
    var start = 0;
    int idx;
    while ((idx = lower.indexOf(query, start)) != -1) {
      if (idx > start) {
        spans.add(TextSpan(text: text.substring(start, idx)));
      }
      spans.add(TextSpan(
        text: text.substring(idx, idx + query.length),
        style: TextStyle(
            backgroundColor: cs.primary.withOpacity(0.25),
            color: cs.primary),
      ));
      start = idx + query.length;
    }
    if (start < text.length) {
      spans.add(TextSpan(text: text.substring(start)));
    }
    return RichText(
      text: TextSpan(
        style: TextStyle(
            fontSize: 13, height: 1.5, color: cs.onSurface),
        children: spans,
      ),
    );
  }
}
