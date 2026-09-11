import 'dart:io';

class CaptionCue {
  const CaptionCue({required this.start, required this.end, required this.text});
  final Duration start;
  final Duration end;
  final String text;
}

class CaptionBook {
  CaptionBook(this.cues);
  final List<CaptionCue> cues;

  String at(Duration pos) {
    for (final c in cues) {
      if (pos >= c.start && pos <= c.end) return c.text;
    }
    return '';
  }

  void merge(CaptionBook other) {
    cues.addAll(other.cues);
    cues.sort((a, b) => a.start.compareTo(b.start));
  }

  static CaptionBook fromMaps(List<Map<String, dynamic>> raw) {
    final out = <CaptionCue>[];
    for (final m in raw) {
      final start = Duration(milliseconds: (m['startMs'] as num?)?.round() ?? 0);
      final endMs = (m['endMs'] as num?)?.round() ?? start.inMilliseconds + 1800;
      final text = '${m['text'] ?? ''}'.trim();
      if (text.isEmpty) continue;
      out.add(CaptionCue(start: start, end: Duration(milliseconds: endMs < start.inMilliseconds ? start.inMilliseconds + 1800 : endMs), text: text));
    }
    return CaptionBook(out);
  }

  static CaptionBook parseSidecar(String videoPath) {
    final dir = File(videoPath).parent.path;
    final stem = videoPath.replaceAll(RegExp(r'\.[^.]+$'), '');
    for (final ext in ['.srt', '.vtt', '.Srt', '.VTT']) {
      final f = File('$stem$ext');
      if (f.existsSync()) return CaptionBook(parseText(f.readAsStringSync(), vtt: ext.toLowerCase() == '.vtt'));
      final alt = File('$dir/${ext == '.vtt' ? 'captions.vtt' : 'captions.srt'}');
      if (alt.existsSync()) return CaptionBook(parseText(alt.readAsStringSync(), vtt: ext.toLowerCase() == '.vtt'));
    }
    return CaptionBook([]);
  }

  static List<CaptionCue> parseText(String raw, {bool vtt = false}) {
    final out = <CaptionCue>[];
    final blocks = raw.replaceAll('\r\n', '\n').split(RegExp(r'\n\s*\n'));
    for (final block in blocks) {
      final lines = block.trim().split('\n').where((l) => l.trim().isNotEmpty).toList();
      if (lines.isEmpty) continue;
      var i = 0;
      if (RegExp(r'^\d+$').hasMatch(lines.first)) i = 1;
      if (i >= lines.length) continue;
      final m = RegExp(r'(\d{1,2}:)?\d{1,2}:\d{2}[.,]\d{1,3}\s*-->\s*(\d{1,2}:)?\d{1,2}:\d{2}[.,]\d{1,3}').firstMatch(lines[i]);
      if (m == null) continue;
      final parts = lines[i].split(RegExp(r'\s*-->\s*'));
      if (parts.length < 2) continue;
      final start = _ts(parts[0]);
      final end = _ts(parts[1].split(' ').first);
      final text = lines.skip(i + 1).join('\n').replaceAll(RegExp(r'<[^>]+>'), '').trim();
      if (text.isEmpty) continue;
      out.add(CaptionCue(start: start, end: end, text: text));
    }
    return out;
  }

  static Duration _ts(String s) {
    final t = s.trim().replaceAll(',', '.');
    final bits = t.split(':');
    var h = 0, m = 0;
    double sec = 0;
    if (bits.length == 3) {
      h = int.tryParse(bits[0]) ?? 0;
      m = int.tryParse(bits[1]) ?? 0;
      sec = double.tryParse(bits[2]) ?? 0;
    } else if (bits.length == 2) {
      m = int.tryParse(bits[0]) ?? 0;
      sec = double.tryParse(bits[1]) ?? 0;
    }
    final ms = ((h * 3600 + m * 60) * 1000 + (sec * 1000)).round();
    return Duration(milliseconds: ms);
  }
}
