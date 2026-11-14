import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'package:video_player_app/accessibility/live_caption/caption_editor.dart';
import 'package:video_player_app/accessibility/live_caption/live_caption_controller.dart';
import 'package:video_player_app/core/models.dart';
import 'package:video_player_app/core/widgets.dart' show showAppSheet;
import 'package:video_player_app/native/android_bridge.dart';
import 'package:video_player_app/settings/settings.dart';

class CaptionFiles {
  CaptionFiles._();

  static String _t(int ms) {
    if (ms < 0) ms = 0;
    String two(int n) => n.toString().padLeft(2, '0');
    final h = ms ~/ 3600000;
    final m = (ms ~/ 60000) % 60;
    final s = (ms ~/ 1000) % 60;
    final f = (ms % 1000).toString().padLeft(3, '0');
    return '${two(h)}:${two(m)}:${two(s)},$f';
  }

  static String toSrt(List<CaptionCue> cues) {
    final sorted = [...cues]..sort((a, b) => a.start.compareTo(b.start));
    final b = StringBuffer();
    var n = 0;
    for (final c in sorted) {
      final text = c.text.trim();
      if (text.isEmpty) continue;
      n++;
      final end = c.end > c.start ? c.end : c.start + 1500;
      b
        ..writeln(n)
        ..writeln('${_t(c.start)} --> ${_t(end)}')
        ..writeln(text)
        ..writeln();
    }
    return b.toString();
  }

  static final RegExp _timing = RegExp(
    r'(?:(\d+):)?(\d{1,2}):(\d{2})[.,](\d{1,3})\s*-->\s*(?:(\d+):)?(\d{1,2}):(\d{2})[.,](\d{1,3})',
  );

  static int _ms(String? h, String m, String s, String f) {
    final frac = int.parse(f.padRight(3, '0'));
    return ((int.tryParse(h ?? '0') ?? 0) * 3600 + int.parse(m) * 60 + int.parse(s)) * 1000 + frac;
  }

  static List<CaptionCue> parse(String raw) {
    var text = raw;
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final out = <CaptionCue>[];
    for (final block in text.split(RegExp(r'\n[ \t]*\n'))) {
      final lines = block.split('\n');
      final at = lines.indexWhere((l) => l.contains('-->'));
      if (at < 0) continue;
      final m = _timing.firstMatch(lines[at]);
      if (m == null) continue;
      final start = _ms(m.group(1), m.group(2)!, m.group(3)!, m.group(4)!);
      final end = _ms(m.group(5), m.group(6)!, m.group(7)!, m.group(8)!);
      final body = lines
          .sublist(at + 1)
          .map((l) => l.replaceAll(RegExp(r'<[^>]*>'), '').replaceAll(RegExp(r'\{[^}]*\}'), '').trim())
          .where((l) => l.isNotEmpty)
          .join('\n')
          .replaceAll('&amp;', '&')
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>')
          .replaceAll('&nbsp;', ' ');
      if (body.isEmpty) continue;
      out.add(CaptionCue(start, end > start ? end : start + 1500, body));
    }
    out.sort((a, b) => a.start.compareTo(b.start));
    return out;
  }

  static String _key(String path) {
    var a = 0x811c9dc5;
    var b = 0x01234567;
    for (final c in utf8.encode(path)) {
      a = ((a ^ c) * 0x01000193) & 0xFFFFFFFF;
      b = ((b ^ c) * 0x01000193) & 0xFFFFFFFF;
    }
    return a.toRadixString(16).padLeft(8, '0') + b.toRadixString(16).padLeft(8, '0');
  }

  static Future<File> _store(String videoPath) async {
    final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'imported_captions'));
    return File(p.join(dir.path, '${_key(videoPath)}.srt'));
  }

  static Future<bool> hasImported(String videoPath) async {
    try {
      return await (await _store(videoPath)).exists();
    } catch (_) {
      return false;
    }
  }

  static Future<List<CaptionCue>?> loadImported(String videoPath) async {
    try {
      final f = await _store(videoPath);
      if (!await f.exists()) return null;
      final cues = parse(await f.readAsString());
      return cues.isEmpty ? null : cues;
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveImported(String videoPath, List<CaptionCue> cues) async {
    final f = await _store(videoPath);
    await f.parent.create(recursive: true);
    await f.writeAsString(toSrt(cues), flush: true);
  }

  static Future<void> removeImported(String videoPath) async {
    try {
      final f = await _store(videoPath);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  static Future<void> showSheet(
    BuildContext context,
    VideoItem item, {
    required Future<void> Function(String id) onAction,
  }) async {
    final has = await hasImported(item.path);
    if (!context.mounted) return;
    await showAppSheet<void>(
      context: context,
      children: (ctx) => [
        const ListTile(title: Text('Captions file', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600))),
        ListTile(
          leading: const Icon(Icons.file_upload_outlined),
          title: const Text('Export captions'),
          subtitle: const Text('Save the captions as a .srt file next to the video'),
          onTap: () async {
            Navigator.pop(ctx);
            await exportCaptions(context, item);
          },
        ),
        ListTile(
          leading: const Icon(Icons.edit_outlined),
          title: const Text('Edit captions'),
          subtitle: const Text('Fix the text and timing for this video'),
          onTap: () async {
            Navigator.pop(ctx);
            if (!context.mounted) return;
            await Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => CaptionEditorPage(item: item, onAction: onAction)),
            );
          },
        ),
        ListTile(
          leading: const Icon(Icons.file_download_outlined),
          title: const Text('Import captions'),
          subtitle: const Text('Use a .srt or .vtt file for this video'),
          onTap: () async {
            Navigator.pop(ctx);
            await importCaptions(context, item, onAction: onAction);
          },
        ),
        if (has)
          ListTile(
            leading: const Icon(Icons.auto_awesome_outlined),
            title: const Text('Use AI captions again'),
            subtitle: const Text('Remove the imported captions for this video'),
            onTap: () async {
              Navigator.pop(ctx);
              await removeImported(item.path);
              LiveCaptionController.instance.clearImported(item.path);
              unawaited(AndroidBridge.toast('Imported captions removed'));
            },
          ),
      ],
    );
  }

  static Future<void> exportCaptions(BuildContext context, VideoItem item) async {
    final cues = LiveCaptionController.instance.cuesFor(item.path);
    if (cues.isEmpty) {
      unawaited(AndroidBridge.toast(
        appSettings.liveCaption
            ? 'No captions yet. Let Live Caption extract some first, or import a file'
            : 'Turn on Live Caption first, then export once captions appear',
      ));
      return;
    }
    final srt = toSrt(cues);
    final base = p.withoutExtension(item.path);
    var out = File('$base (captions).srt');
    var n = 2;
    while (out.existsSync()) {
      out = File('$base (captions $n).srt');
      n++;
    }
    try {
      await out.writeAsString(srt, flush: true);
      unawaited(AndroidBridge.toast('Saved ${p.basename(out.path)} next to the video'));
    } catch (_) {
      try {
        final tmp = File(p.join((await getTemporaryDirectory()).path, p.basename(out.path)));
        await tmp.writeAsString(srt, flush: true);
        await SharePlus.instance.share(ShareParams(files: [XFile(tmp.path)]));
      } catch (e) {
        unawaited(AndroidBridge.toast('Could not export captions. $e'));
      }
    }
  }

  static Future<void> importCaptions(
    BuildContext context,
    VideoItem item, {
    required Future<void> Function(String id) onAction,
  }) async {
    String? text;
    try {
      text = await AndroidBridge.pickTextFile();
    } catch (e) {
      unawaited(AndroidBridge.toast('Could not open that file. $e'));
      return;
    }
    if (text == null) return;
    final cues = parse(text);
    if (cues.isEmpty) {
      unawaited(AndroidBridge.toast('No captions found in that file. Use a .srt or .vtt file'));
      return;
    }
    try {
      await saveImported(item.path, cues);
    } catch (e) {
      unawaited(AndroidBridge.toast('Could not save the captions. $e'));
      return;
    }
    if (!appSettings.liveCaption) await onAction('caption');
    LiveCaptionController.instance.applyImported(item.path, cues);
    unawaited(AndroidBridge.toast('Imported ${cues.length} captions'));
  }
}
