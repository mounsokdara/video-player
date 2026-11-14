import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

class PasteProgress {
  const PasteProgress({this.name = '', this.done = 0, this.total = 0, this.item = 0, this.items = 0});
  final String name;
  final int done;
  final int total;
  final int item;
  final int items;
}

class PasteResult {
  int failed = 0;
  bool cancelled = false;
  final List<String> completedSources = [];
  final List<(String, String)> moved = [];
  final List<(String, String)> copiedFiles = [];
  bool get ok => failed == 0 && !cancelled;
}

class PasteJob {
  PasteJob({required this.cut});
  final bool cut;
  bool _cancelled = false;
  bool get cancelled => _cancelled;
  final ValueNotifier<PasteProgress> progress = ValueNotifier(const PasteProgress());
  void cancel() => _cancelled = true;
}

class _Cancel implements Exception {
  const _Cancel();
}

Future<int> _sizeOf(String path) async {
  try {
    if (FileSystemEntity.isDirectorySync(path)) {
      var total = 0;
      await for (final e in Directory(path).list(recursive: true, followLinks: false)) {
        if (e is File) {
          try {
            total += await e.length();
          } catch (_) {}
        }
      }
      return total;
    }
    return await File(path).length();
  } catch (_) {
    return 0;
  }
}

String _uniqueDest(String dir, String name, {required bool isDir}) {
  var dest = p.join(dir, name);
  if (!_exists(dest)) return dest;
  final stem = isDir ? name : p.basenameWithoutExtension(name);
  final ext = isDir ? '' : p.extension(name);
  var n = 1;
  while (true) {
    dest = p.join(dir, '${stem}_copy${n == 1 ? '' : n}$ext');
    if (!_exists(dest)) return dest;
    n++;
  }
}

bool _exists(String path) => FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.notFound;

/// Copies or moves [sources] into [dir], reporting progress through [job] and stopping when it is cancelled.
/// A cancelled or failed copy never leaves a half-written file or folder behind, and a move never deletes
/// the source until the copy finished.
Future<PasteResult> transferAll(List<String> sources, String dir, PasteJob job) async {
  final result = PasteResult();
  final totals = <String, int>{};
  var total = 0;
  for (final s in sources) {
    if (job.cancelled) break;
    totals[s] = await _sizeOf(s);
    total += totals[s]!;
  }
  var done = 0;
  var lastTick = 0;
  final clock = Stopwatch()..start();

  void tick(String name, int item, {bool force = false}) {
    if (!force && clock.elapsedMilliseconds - lastTick < 100) return;
    lastTick = clock.elapsedMilliseconds;
    job.progress.value = PasteProgress(name: name, done: done, total: total, item: item, items: sources.length);
  }

  Future<void> copyFile(File src, String dest, int item) async {
    Directory(p.dirname(dest)).createSync(recursive: true);
    final out = File(dest).openWrite();
    var sinceFlush = 0;
    try {
      await for (final chunk in src.openRead()) {
        if (job.cancelled) throw const _Cancel();
        out.add(chunk);
        done += chunk.length;
        sinceFlush += chunk.length;
        if (sinceFlush >= 4 * 1024 * 1024) {
          await out.flush();
          sinceFlush = 0;
        }
        tick(p.basename(src.path), item);
      }
      await out.flush();
    } finally {
      await out.close();
    }
    try {
      File(dest).setLastModifiedSync(src.lastModifiedSync());
    } catch (_) {}
    result.copiedFiles.add((src.path, dest));
  }

  Future<void> copyDir(Directory src, String dest, int item) async {
    Directory(dest).createSync(recursive: true);
    await for (final e in src.list(followLinks: false)) {
      if (job.cancelled) throw const _Cancel();
      final target = p.join(dest, p.basename(e.path));
      if (e is File) {
        await copyFile(e, target, item);
      } else if (e is Directory) {
        await copyDir(e, target, item);
      }
    }
  }

  void removePartial(String dest) {
    try {
      if (FileSystemEntity.isDirectorySync(dest)) {
        Directory(dest).deleteSync(recursive: true);
      } else if (File(dest).existsSync()) {
        File(dest).deleteSync();
      }
    } catch (_) {}
  }

  for (var i = 0; i < sources.length; i++) {
    if (job.cancelled) break;
    final src = sources[i];
    final isDir = FileSystemEntity.isDirectorySync(src);
    if (!isDir && !File(src).existsSync()) {
      result.failed++;
      continue;
    }
    if (isDir && (p.equals(src, dir) || p.isWithin(src, dir))) {
      result.failed++;
      continue;
    }
    if (job.cut && p.equals(p.dirname(src), dir)) {
      result.completedSources.add(src);
      continue;
    }
    final dest = _uniqueDest(dir, p.basename(src), isDir: isDir);
    tick(p.basename(src), i + 1, force: true);

    if (job.cut) {
      try {
        if (isDir) {
          await Directory(src).rename(dest);
        } else {
          await File(src).rename(dest);
        }
        done += totals[src] ?? 0;
        result.moved.add((src, dest));
        result.completedSources.add(src);
        tick(p.basename(src), i + 1, force: true);
        continue;
      } catch (_) {
        // Other volume: fall through to copy, then delete the source.
      }
    }

    try {
      if (isDir) {
        await copyDir(Directory(src), dest, i + 1);
      } else {
        await copyFile(File(src), dest, i + 1);
      }
      if (job.cut) {
        try {
          if (isDir) {
            Directory(src).deleteSync(recursive: true);
          } else {
            File(src).deleteSync();
          }
        } catch (_) {}
        result.moved.add((src, dest));
      }
      result.completedSources.add(src);
    } on _Cancel {
      removePartial(dest);
      result.copiedFiles.removeWhere((c) => c.$2 == dest || p.isWithin(dest, c.$2));
      break;
    } catch (_) {
      removePartial(dest);
      result.copiedFiles.removeWhere((c) => c.$2 == dest || p.isWithin(dest, c.$2));
      result.failed++;
    }
  }
  result.cancelled = job.cancelled;
  tick('', sources.length, force: true);
  return result;
}
