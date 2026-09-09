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
  bool manageMedia = false;

  bool _scanning = false;
  final Map<String, Uint8List?> _thumbs = {};

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
    manageMedia = await AndroidBridge.canManageMedia();
  }

  Future<void> ensureAllFiles() async {
    allFiles = await AndroidBridge.hasAllFilesAccess();
    if (!allFiles) await AndroidBridge.requestAllFilesAccess();
  }

  Future<void> ensureManageMedia() async {
    manageMedia = await AndroidBridge.canManageMedia();
    if (!manageMedia) {
      await AndroidBridge.requestManageMedia();
      manageMedia = await AndroidBridge.canManageMedia();
    }
  }

  Future<void> scan() async {
    if (_scanning) return;
    _scanning = true;
    try {
      await _scanBody();
    } finally {
      _scanning = false;
    }
  }

  Future<void> _scanBody() async {
    final next = <VideoItem>[];
    final seen = <String>{};
    final hidden = settings.showHiddenFolders;

    volumes
      ..clear()
      ..addAll(await AndroidBridge.listStorageVolumes());

    // MediaStore is indexed and fast. Native walks only removable volumes so
    // pull-to-refresh does not crawl the whole internal disk.
    try {
      final paths = await PhotoManager.getAssetPathList(
        type: RequestType.video,
        hasAll: true,
        onlyAll: true,
      );
      for (final album in paths) {
        final count = await album.assetCountAsync;
        for (var start = 0; start < count; start += 120) {
          final end = (start + 120).clamp(0, count);
          final assets = await album.getAssetListRange(start: start, end: end);
          for (final a in assets) {
            final path = _assetPath(a);
            if (path == null || path.isEmpty || seen.contains(path)) continue;
            if (!looksLikeVideo(path, mime: a.mimeType)) continue;
            if (!hidden && _isHiddenPath(path)) continue;
            seen.add(path);
            next.add(
              VideoItem(
                id: a.id,
                path: path,
                title: p.basename(path),
                folder: p.dirname(path),
                size: 0,
                modified: a.modifiedDateTime,
                created: a.createDateTime,
                duration: a.duration > 0 ? Duration(seconds: a.duration) : Duration.zero,
                width: a.width,
                height: a.height,
                mime: a.mimeType,
                assetId: a.id,
                progress: settings.resumeMap[path] ?? 0,
                bookmarked: settings.bookmarks.contains(path),
              ),
            );
          }
        }
      }
    } catch (_) {}

    final nativeTargets = <StorageVolumeInfo>[
      ...volumes.where((v) => v.path.isNotEmpty && !v.isPrimary),
      if (next.isEmpty) ...volumes.where((v) => v.path.isNotEmpty && v.isPrimary),
    ];
    for (final vol in nativeTargets) {
      if (vol.path.isEmpty) continue;
      final extra = await AndroidBridge.listVideoFiles(vol.path, includeHidden: hidden);
      for (final m in extra) {
        final path = m['path'] as String? ?? '';
        if (path.isEmpty || seen.contains(path)) continue;
        if (!looksLikeVideo(path)) continue;
        if (!hidden && _isHiddenPath(path)) continue;
        seen.add(path);
        final name = m['name'] as String? ?? p.basename(path);
        next.add(
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

    videos
      ..clear()
      ..addAll(next);
    _thumbs.removeWhere((k, _) => videos.every((v) => v.id != k));
    _rebuildFolders();
  }

  String? _assetPath(AssetEntity a) {
    final title = a.title;
    final rel = a.relativePath;
    if (title == null || title.isEmpty || rel == null || rel.isEmpty) return null;
    final prefix = rel.startsWith('/') ? rel : '/storage/emulated/0/$rel';
    final base = prefix.endsWith('/') ? prefix : '$prefix/';
    return '$base$title';
  }

  bool _isHiddenPath(String path) {
    return p.split(path).any((s) => s.startsWith('.'));
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
    if (_thumbs.containsKey(item.id)) return _thumbs[item.id];
    Uint8List? data;
    if (item.assetId != null) {
      try {
        final asset = await AssetEntity.fromId(item.assetId!);
        if (asset != null) {
          data = await asset.thumbnailDataWithSize(ThumbnailSize(size, size));
        }
      } catch (_) {}
    }
    _thumbs[item.id] = data;
    return data;
  }

  Future<bool> deleteVideos(List<VideoItem> items) async {
    if (items.isEmpty) return true;
    final paths = items.map((v) => v.path).where((p) => p.isNotEmpty).toList();
    await AndroidBridge.deletePaths(paths);
    var leftover = items.where((v) => File(v.path).existsSync()).toList();
    if (leftover.isNotEmpty) {
      manageMedia = await AndroidBridge.canManageMedia();
      if (!manageMedia) {
        await AndroidBridge.requestManageMedia();
      }
      await AndroidBridge.deletePaths(leftover.map((v) => v.path).toList());
      leftover = leftover.where((v) => File(v.path).existsSync()).toList();
    }
    var ok = leftover.isEmpty;
    for (final v in items) {
      if (!File(v.path).existsSync()) {
        videos.removeWhere((x) => x.id == v.id || x.path == v.path);
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
