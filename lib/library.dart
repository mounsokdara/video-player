import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';

import 'android_bridge.dart';
import 'models.dart';
import 'settings.dart';

class LibraryService {
  LibraryService(this.settings);

  final AppSettings settings;
  final List<VideoItem> videos = [];
  final List<FolderNode> folders = [];
  final List<StorageVolumeInfo> volumes = [];
  bool permissionReady = false;
  bool allFiles = false;

  Future<void> requestPermissions() async {
    await [
      Permission.videos,
      Permission.storage,
      Permission.audio,
      Permission.notification,
    ].request();

    final pm = await PhotoManager.requestPermissionExtend();
    permissionReady = pm.isAuth || pm.hasAccess;

    allFiles = await AndroidBridge.hasAllFilesAccess();
    if (!allFiles) {
      await Permission.manageExternalStorage.request();
      allFiles = await AndroidBridge.hasAllFilesAccess();
    }
  }

  Future<void> ensureAllFiles() async {
    allFiles = await AndroidBridge.hasAllFilesAccess();
    if (!allFiles) await AndroidBridge.requestAllFilesAccess();
  }

  Future<void> scan() async {
    videos.clear();
    folders.clear();
    volumes.clear();
    volumes.addAll(await AndroidBridge.listStorageVolumes());

    final seen = <String>{};

    try {
      final paths = await PhotoManager.getAssetPathList(
        type: RequestType.video,
        hasAll: true,
        onlyAll: false,
      );
      for (final album in paths) {
        final count = await album.assetCountAsync;
        final assets = await album.getAssetListRange(start: 0, end: count);
        for (final a in assets) {
          final file = await a.file;
          if (file == null) continue;
          if (!looksLikeVideo(file.path, mime: a.mimeType)) continue;
          if (seen.contains(file.path)) continue;
          seen.add(file.path);
          videos.add(
            VideoItem(
              id: a.id,
              path: file.path,
              title: p.basename(file.path),
              folder: p.dirname(file.path),
              size: await file.length(),
              modified: a.modifiedDateTime,
              created: a.createDateTime,
              duration: a.duration > 0 ? Duration(seconds: a.duration) : Duration.zero,
              width: a.width,
              height: a.height,
              mime: a.mimeType,
              assetId: a.id,
              progress: settings.resumeMap[file.path] ?? 0,
              bookmarked: settings.bookmarks.contains(file.path),
            ),
          );
        }
      }
    } catch (_) {}

    for (final vol in volumes) {
      if (vol.path.isEmpty) continue;
      final extra = await AndroidBridge.listVideoFiles(vol.path);
      for (final m in extra) {
        final path = m['path'] as String? ?? '';
        if (path.isEmpty || seen.contains(path)) continue;
        if (!looksLikeVideo(path)) continue;
        seen.add(path);
        final name = m['name'] as String? ?? p.basename(path);
        videos.add(
          VideoItem(
            id: path,
            path: path,
            title: name,
            folder: m['folder'] as String? ?? p.dirname(path),
            size: (m['size'] as num?)?.toInt() ?? 0,
            modified: DateTime.fromMillisecondsSinceEpoch((m['modified'] as num?)?.toInt() ?? 0),
            progress: settings.resumeMap[path] ?? 0,
            bookmarked: settings.bookmarks.contains(path),
          ),
        );
      }
    }

    _rebuildFolders();
  }

  void _rebuildFolders() {
    folders.clear();
    final map = <String, FolderNode>{};
    for (final v in videos) {
      final node = map.putIfAbsent(
        v.folder,
        () => FolderNode(path: v.folder, name: v.folderName),
      );
      node.videoCount += 1;
      node.size += v.size;
    }
    folders.addAll(map.values);
    folders.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  List<VideoItem> sorted(SortBy sort, {bool desc = true, String query = ''}) {
    var list = List<VideoItem>.from(videos);
    if (query.trim().isNotEmpty) {
      final q = query.toLowerCase();
      list = list.where((v) => v.title.toLowerCase().contains(q) || v.folder.toLowerCase().contains(q)).toList();
    }
    int cmp(VideoItem a, VideoItem b) {
      switch (sort) {
        case SortBy.name:
          return a.title.toLowerCase().compareTo(b.title.toLowerCase());
        case SortBy.date:
          return a.modified.compareTo(b.modified);
        case SortBy.size:
          return a.size.compareTo(b.size);
        case SortBy.duration:
          return a.duration.compareTo(b.duration);
        case SortBy.folder:
          return a.folder.toLowerCase().compareTo(b.folder.toLowerCase());
      }
    }

    list.sort(cmp);
    if (desc && sort != SortBy.name && sort != SortBy.folder) {
      list = list.reversed.toList();
    }
    return list;
  }

  int get totalBytes => videos.fold(0, (a, b) => a + b.size);

  Future<Uint8List?> thumbnailFor(VideoItem item, {int size = 240}) async {
    if (item.assetId != null) {
      try {
        final asset = await AssetEntity.fromId(item.assetId!);
        if (asset != null) {
          return await asset.thumbnailDataWithSize(ThumbnailSize(size, size));
        }
      } catch (_) {}
    }
    return null;
  }

  Future<bool> deleteVideos(List<VideoItem> items) async {
    var ok = true;
    for (final v in items) {
      var deleted = false;
      if (v.assetId != null) {
        try {
          final result = await PhotoManager.editor.deleteWithIds([v.assetId!]);
          deleted = result.isNotEmpty;
        } catch (_) {}
      }
      if (!deleted) {
        deleted = await AndroidBridge.deletePath(v.path);
        if (!deleted) {
          try {
            final f = File(v.path);
            if (f.existsSync()) {
              await f.delete();
              deleted = true;
            }
          } catch (_) {}
        }
      }
      if (deleted) {
        videos.removeWhere((x) => x.id == v.id);
      } else {
        ok = false;
      }
    }
    _rebuildFolders();
    return ok;
  }

  Future<VideoItem?> rename(VideoItem item, String newName) async {
    final dest = await AndroidBridge.renamePath(item.path, newName);
    if (dest == null) return null;
    final next = item.copyWith(title: newName, path: dest);
    final i = videos.indexWhere((v) => v.id == item.id);
    if (i >= 0) videos[i] = next;
    return next;
  }

  List<FileSystemEntity> listDir(String path) {
    final dir = Directory(path);
    if (!dir.existsSync()) return [];
    try {
      final ents = dir.listSync();
      ents.sort((a, b) {
        final ad = a is Directory;
        final bd = b is Directory;
        if (ad != bd) return ad ? -1 : 1;
        return p.basename(a.path).toLowerCase().compareTo(p.basename(b.path).toLowerCase());
      });
      return ents.where((e) {
        final name = p.basename(e.path);
        if (!settings.showHiddenFolders && name.startsWith('.')) return false;
        if (e is Directory) return true;
        return looksLikeVideo(e.path);
      }).toList();
    } catch (_) {
      return [];
    }
  }
}

const videoExtensions = {
  '.mp4',
  '.mkv',
  '.webm',
  '.avi',
  '.mov',
  '.m4v',
  '.3gp',
  '.flv',
  '.wmv',
  '.mpeg',
  '.mpg',
  '.m2ts',
  '.mts',
  '.vob',
  '.f4v',
  '.ogv',
};

const textExtensions = {
  '.ts',
  '.tsx',
  '.js',
  '.jsx',
  '.mjs',
  '.cjs',
  '.json',
  '.txt',
  '.md',
  '.css',
  '.html',
  '.htm',
  '.xml',
  '.svg',
  '.map',
  '.yml',
  '.yaml',
  '.py',
  '.java',
  '.kt',
  '.dart',
  '.c',
  '.h',
  '.cpp',
  '.go',
  '.rs',
  '.sh',
  '.log',
  '.csv',
  '.toml',
  '.ini',
};

bool looksLikeVideo(String path, {String? mime}) {
  final name = p.basename(path).toLowerCase();
  if (name.endsWith('.d.ts')) return false;
  final ext = p.extension(name).toLowerCase();
  final m = (mime ?? '').toLowerCase();
  if (m.startsWith('text/')) return false;
  if (m.contains('javascript') || m.contains('json') || m.contains('typescript')) return false;
  if (m.startsWith('video/')) {
    if (ext == '.tsx' || ext == '.jsx') return false;
    if (ext == '.ts' && !m.contains('mp2t') && m != 'video/mp2t') {
      // Some stacks mislabel TypeScript as a generic video type; require MPEG-TS.
      return _isMpegTsFile(path);
    }
    return true;
  }
  if (ext == '.ts') return _isMpegTsFile(path);
  if (textExtensions.contains(ext)) return false;
  return videoExtensions.contains(ext);
}

bool _isMpegTsFile(String path) {
  try {
    final f = File(path);
    if (!f.existsSync() || f.lengthSync() < 188) return false;
    final raf = f.openSync();
    final b = raf.readByteSync();
    raf.closeSync();
    return b == 0x47;
  } catch (_) {
    return false;
  }
}

String formatBytes(int n) {
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
  if (n < 1024 * 1024 * 1024) return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(n / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

String formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  if (h > 0) return '$h:$m:$s';
  return '${d.inMinutes}:$s';
}
