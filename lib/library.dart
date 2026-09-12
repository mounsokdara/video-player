import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';

import 'android_bridge.dart';
import 'models.dart';
import 'settings.dart';

enum ScanStatus { idle, running, ok, empty, noPermission, failed }

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
  bool get scanning => _scanning;

  ScanStatus scanStatus = ScanStatus.idle;
  String? scanError;

  int hiddenVideoCount = 0;
  int unresolvedCount = 0;

  bool get hasVideos => videos.isNotEmpty;

  bool get shouldShowEmptyState =>
      !_scanning && videos.isEmpty && scanStatus == ScanStatus.empty;

  String? get emptyStateMessage {
    if (_scanning || videos.isNotEmpty) return null;
    if (!permissionReady && !allFiles) {
      return 'Media permission is required to find your videos';
    }
    switch (scanStatus) {
      case ScanStatus.failed:
        return 'Scan failed. Pull to refresh to try again.';
      case ScanStatus.empty:
        if (hiddenVideoCount > 0) {
          return '$hiddenVideoCount hidden video'
              '${hiddenVideoCount == 1 ? '' : 's'} — enable "Show hidden folders"';
        }
        if (unresolvedCount > 0) {
          return '$unresolvedCount video(s) could not be opened';
        }
        return 'No video found';
      default:
        return null;
    }
  }

  final Map<String, Uint8List?> _thumbs = {};
  String? clipPath;
  bool clipCut = false;

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

  Future<void> scan({bool deep = false}) async {
    if (_scanning) return;
    _scanning = true;
    scanStatus = ScanStatus.running;
    scanError = null;
    hiddenVideoCount = 0;
    unresolvedCount = 0;

    try {
      var result = await _collect(deep: deep);
      if (result.items.isEmpty && !deep) {
        result = await _collect(deep: true);
      }

      videos
        ..clear()
        ..addAll(result.items);
      hiddenVideoCount = result.hiddenCount;
      unresolvedCount = result.unresolved;
      _thumbs.removeWhere((k, _) => videos.every((v) => v.id != k));
      _rebuildFolders();

      if (videos.isNotEmpty) {
        scanStatus = ScanStatus.ok;
      } else if (!permissionReady && !allFiles) {
        scanStatus = ScanStatus.noPermission;
      } else if (result.sourcesTried > 0 &&
          result.sourcesFailed == result.sourcesTried) {
        scanStatus = ScanStatus.failed;
      } else {
        scanStatus = ScanStatus.empty;
      }
    } catch (e) {
      scanError = e.toString();
      scanStatus = ScanStatus.failed;
    } finally {
      _scanning = false;
    }
  }

  Future<_ScanResult> _collect({required bool deep}) async {
    final hidden = settings.showHiddenFolders;
    final items = <VideoItem>[];
    final byPath = <String, int>{};
    final byAsset = <String, int>{};

    var sourcesTried = 0;
    var sourcesFailed = 0;
    var unresolved = 0;
    var hiddenCount = 0;

    volumes
      ..clear()
      ..addAll(await AndroidBridge.listStorageVolumes());

    sourcesTried++;
    try {
      for (final m in await AndroidBridge.listIndexedVideos()) {
        final path = (m['path'] as String?) ?? '';
        if (path.isEmpty) continue;
        if (!looksLikeVideo(path, mime: m['mime'] as String?)) continue;
        if (!hidden && _isHiddenPath(path)) continue;
        _put(
          items,
          byPath,
          byAsset,
          VideoItem(
            id: '${m['id'] ?? path}',
            path: path,
            title: m['name'] as String? ?? p.basename(path),
            folder: m['folder'] as String? ?? p.dirname(path),
            size: (m['size'] as num?)?.toInt() ?? 0,
            modified: DateTime.fromMillisecondsSinceEpoch(
              (m['modified'] as num?)?.toInt() ?? 0,
            ),
            duration: Duration(
              milliseconds: (m['durationMs'] as num?)?.toInt() ?? 0,
            ),
            width: (m['width'] as num?)?.toInt() ?? 0,
            height: (m['height'] as num?)?.toInt() ?? 0,
            mime: m['mime'] as String?,
            assetId: m['id']?.toString(),
            progress: settings.resumeMap[path] ?? 0,
            bookmarked: settings.bookmarks.contains(path),
          ),
        );
      }
    } catch (e) {
      sourcesFailed++;
      scanError ??= 'MediaStore: $e';
    }

    sourcesTried++;
    try {
      final albums = await PhotoManager.getAssetPathList(
        type: RequestType.video,
        hasAll: true,
        onlyAll: true,
      );
      for (final album in albums) {
        final count = await album.assetCountAsync;
        for (var start = 0; start < count; start += 120) {
          final end = (start + 120).clamp(0, count);
          final assets = await album.getAssetListRange(start: start, end: end);
          for (final a in assets) {
            final path = await _resolveAssetPath(a);
            if (path == null) {
              unresolved++;
              continue;
            }
            if (!looksLikeVideo(path, mime: a.mimeType)) continue;
            if (!hidden && _isHiddenPath(path)) continue;
            _put(
              items,
              byPath,
              byAsset,
              VideoItem(
                id: a.id,
                path: path,
                title: p.basename(path),
                folder: p.dirname(path),
                size: 0,
                modified: a.modifiedDateTime,
                created: a.createDateTime,
                duration:
                    a.duration > 0 ? Duration(seconds: a.duration) : Duration.zero,
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
    } catch (e) {
      sourcesFailed++;
      scanError ??= 'MediaStore (media): $e';
    }

    final targets = <StorageVolumeInfo>[
      ...volumes.where((v) => v.path.isNotEmpty && !v.isPrimary),
      if (deep || items.isEmpty)
        ...volumes.where((v) => v.path.isNotEmpty && v.isPrimary),
    ];
    if (targets.isNotEmpty) {
      sourcesTried++;
      try {
        for (final vol in targets) {
          final files =
              await AndroidBridge.listVideoFiles(vol.path, includeHidden: hidden);
          for (final m in files) {
            final path = (m['path'] as String?) ?? '';
            if (path.isEmpty) continue;
            if (!looksLikeVideo(path)) continue;
            if (!hidden && _isHiddenPath(path)) continue;
            final name = m['name'] as String? ?? p.basename(path);
            _put(
              items,
              byPath,
              byAsset,
              VideoItem(
                id: path,
                path: path,
                title: name,
                folder: m['folder'] as String? ?? p.dirname(path),
                size: (m['size'] as num?)?.toInt() ?? 0,
                modified: DateTime.fromMillisecondsSinceEpoch(
                  (m['modified'] as num?)?.toInt() ?? 0,
                ),
                progress: settings.resumeMap[path] ?? 0,
                bookmarked: settings.bookmarks.contains(path),
              ),
            );
          }
        }
      } catch (e) {
        sourcesFailed++;
        scanError ??= 'Filesystem: $e';
      }
    }

    if (deep && items.isEmpty && !hidden) {
      for (final vol in volumes.where((v) => v.path.isNotEmpty)) {
        try {
          final files = await AndroidBridge.listVideoFiles(
            vol.path,
            includeHidden: true,
          );
          for (final m in files) {
            final path = (m['path'] as String?) ?? '';
            if (path.isEmpty) continue;
            if (!looksLikeVideo(path)) continue;
            if (_isHiddenPath(path)) hiddenCount++;
          }
        } catch (_) {
        }
      }
    }

    return _ScanResult(
      items: items,
      hiddenCount: hiddenCount,
      unresolved: unresolved,
      sourcesTried: sourcesTried,
      sourcesFailed: sourcesFailed,
    );
  }

  Future<String?> _resolveAssetPath(AssetEntity a) async {
    final file = await _safeFile(a);
    if (file != null && file.path.isNotEmpty) return file.path;

    final origin = await _safeOriginFile(a);
    if (origin != null && origin.path.isNotEmpty) return origin.path;

    final title = a.title;
    if (title.isEmpty) return null;

    final rel = (a.relativePath ?? '').replaceAll('\\', '/');
    final tail = rel.isEmpty
        ? title
        : '${rel.replaceAll(RegExp(r'^/+|/+$'), '')}/$title';

    final roots = <String>[
      '/storage/emulated/0',
      for (final v in volumes)
        if (v.path.isNotEmpty) v.path,
    ];
    for (final root in roots) {
      final candidate = '$root/$tail';
      if (File(candidate).existsSync()) return candidate;
    }

    return roots.isEmpty ? null : '${roots.first}/$tail';
  }

  Future<File?> _safeFile(AssetEntity a) async {
    try {
      return await a.file;
    } catch (_) {
      return null;
    }
  }

  Future<File?> _safeOriginFile(AssetEntity a) async {
    try {
      return await a.originFile;
    } catch (_) {
      return null;
    }
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

  List<VideoItem> sorted(
    SortBy sort, {
    bool desc = true,
    String query = '',
    String filter = 'all',
  }) {
    var list = List<VideoItem>.from(videos);
    if (filter == 'bookmarked') {
      list = list
          .where((v) => settings.bookmarks.contains(v.path) || v.bookmarked)
          .toList();
    } else if (filter == 'pinned') {
      list = list.where((v) => settings.pinned.contains(v.path)).toList();
    }
    if (query.trim().isNotEmpty) {
      final q = query.toLowerCase();
      list = list
          .where(
            (v) =>
                v.title.toLowerCase().contains(q) ||
                v.folder.toLowerCase().contains(q),
          )
          .toList();
    }

    int cmp(VideoItem a, VideoItem b) {
      final ap = settings.pinned.contains(a.path) ? 1 : 0;
      final bp = settings.pinned.contains(b.path) ? 1 : 0;
      if (ap != bp) return bp.compareTo(ap);
      final ab = (settings.bookmarks.contains(a.path) || a.bookmarked) ? 1 : 0;
      final bb = (settings.bookmarks.contains(b.path) || b.bookmarked) ? 1 : 0;
      if (filter == 'all' && ab != bb) return bb.compareTo(ab);
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
      final pins = list.where((v) => settings.pinned.contains(v.path)).toList();
      final rest = list
          .where((v) => !settings.pinned.contains(v.path))
          .toList()
          .reversed
          .toList();
      return [...pins, ...rest];
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
    final paths = items
        .map((v) => v.path)
        .where((path) => path.isNotEmpty)
        .toList();
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

  void copyEntry(String path) {
    clipPath = path;
    clipCut = false;
  }

  void cutEntry(String path) {
    clipPath = path;
    clipCut = true;
  }

  Future<bool> pasteInto(String dir) async {
    final src = clipPath;
    if (src == null || src.isEmpty) return false;
    final name = p.basename(src);
    var dest = p.join(dir, name);
    if (dest == src) return false;
    if (File(dest).existsSync() || Directory(dest).existsSync()) {
      final stem = p.basenameWithoutExtension(name);
      final ext = p.extension(name);
      dest = p.join(dir, '${stem}_copy$ext');
    }
    if (clipCut) {
      final moved = await AndroidBridge.movePath(src, dest);
      if (moved == null) return false;
      clipPath = null;
      clipCut = false;
      final i = videos.indexWhere((v) => v.path == src);
      if (i >= 0) {
        videos[i] = videos[i].copyWith(path: moved, title: p.basename(moved));
      }
      _rebuildFolders();
      return true;
    }
    final ok = await AndroidBridge.copyPath(src, dest);
    if (ok) {
      VideoItem? srcItem;
      for (final v in videos) {
        if (v.path == src) srcItem = v;
      }
      videos.add(
        VideoItem(
          id: dest,
          path: dest,
          title: p.basename(dest),
          folder: dir,
          size: srcItem?.size ?? File(dest).lengthSync(),
          modified: DateTime.now(),
          duration: srcItem?.duration ?? Duration.zero,
        ),
      );
      _rebuildFolders();
    }
    return ok;
  }

  Future<bool> deletePath(String path) async {
    final ok = await AndroidBridge.deletePath(path);
    videos.removeWhere((v) => v.path == path);
    _rebuildFolders();
    return ok;
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
        return p
            .basename(a.path)
            .toLowerCase()
            .compareTo(p.basename(b.path).toLowerCase());
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

class _ScanResult {
  _ScanResult({
    required this.items,
    required this.hiddenCount,
    required this.unresolved,
    required this.sourcesTried,
    required this.sourcesFailed,
  });

  final List<VideoItem> items;
  final int hiddenCount;
  final int unresolved;
  final int sourcesTried;
  final int sourcesFailed;
}

void _put(
  List<VideoItem> items,
  Map<String, int> byPath,
  Map<String, int> byAsset,
  VideoItem v,
) {
  final path = v.path;
  final asset = v.assetId;

  int? index;
  if (path.isNotEmpty) index = byPath[path];
  if (index == null && asset != null) index = byAsset[asset];

  if (index == null) {
    final i = items.length;
    items.add(v);
    if (path.isNotEmpty) byPath[path] = i;
    if (asset != null) byAsset[asset] = i;
    return;
  }

  final old = items[index];
  final merged = old.copyWith(
    assetId: old.assetId ?? asset,
    path: old.path.isNotEmpty ? old.path : path,
    title: old.title.isNotEmpty ? old.title : v.title,
    size: old.size != 0 ? old.size : v.size,
    duration: old.duration > Duration.zero ? old.duration : v.duration,
    width: old.width != 0 ? old.width : v.width,
    height: old.height != 0 ? old.height : v.height,
    mime: old.mime ?? v.mime,
  );
  items[index] = merged;
  if (merged.path.isNotEmpty) byPath[merged.path] = index;
  if (merged.assetId != null) byAsset[merged.assetId!] = index;
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
  if (path.startsWith('content:')) {
    final m = (mime ?? '').toLowerCase();
    if (m.isEmpty) return true;
    return m.startsWith('video/');
  }
  final name = p.basename(path).toLowerCase();
  if (name.endsWith('.d.ts')) return false;
  final ext = p.extension(name).toLowerCase();
  final m = (mime ?? '').toLowerCase();
  if (m.startsWith('text/')) return false;
  if (m.contains('javascript') || m.contains('json') || m.contains('typescript')) {
    return false;
  }
  if (m.startsWith('video/')) {
    if (ext == '.tsx' || ext == '.jsx') return false;
    if (ext == '.ts' && !m.contains('mp2t')) {
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
  if (n < 1024 * 1024 * 1024) {
    return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(n / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

String formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  if (h > 0) return '$h:$m:$s';
  return '${d.inMinutes}:$s';
}
