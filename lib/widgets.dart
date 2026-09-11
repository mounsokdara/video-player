import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import 'android_bridge.dart';
import 'library.dart';
import 'main.dart';
import 'models.dart';

class VideoThumb extends StatefulWidget {
  const VideoThumb({super.key, required this.item, this.radius = 12});
  final VideoItem item;
  final double radius;

  @override
  State<VideoThumb> createState() => _VideoThumbState();
}

class _VideoThumbState extends State<VideoThumb> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant VideoThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id) _load();
  }

  Future<void> _load() async {
    final data = await library.thumbnailFor(widget.item);
    if (mounted) setState(() => _bytes = data);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(
            color: scheme.surfaceContainerHighest,
            child: _bytes != null
                ? Image.memory(_bytes!, fit: BoxFit.cover)
                : Icon(Icons.movie_outlined, color: scheme.onSurfaceVariant),
          ),
          Positioned(
            right: 6,
            bottom: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                formatDuration(widget.item.duration),
                style: const TextStyle(color: Colors.white, fontSize: 11, fontFeatures: [FontFeature.tabularFigures()]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ResumeBar extends StatelessWidget {
  const ResumeBar({super.key, required this.progress});
  final double progress;

  @override
  Widget build(BuildContext context) {
    if (progress <= 0.01) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: LinearProgressIndicator(
        value: progress.clamp(0, 1),
        minHeight: 3,
        color: scheme.primary,
        backgroundColor: scheme.surfaceContainerHighest,
      ),
    );
  }
}

class VideoListTile extends StatelessWidget {
  const VideoListTile({
    super.key,
    required this.item,
    required this.selected,
    required this.selecting,
    required this.onTap,
    required this.onLongPress,
    required this.onMenu,
  });

  final VideoItem item;
  final bool selected;
  final bool selecting;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected ? scheme.secondaryContainer.withValues(alpha: 0.45) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 128,
                height: 72,
                child: VideoThumb(item: item, radius: 10),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, height: 1.25)),
                    const SizedBox(height: 4),
                    Text(
                      '${formatBytes(item.size)}  ·  ${DateFormat.yMMMd().format(item.modified)}',
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                    if (appSettings.pinned.contains(item.path) || item.bookmarked)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Row(
                          children: [
                            if (appSettings.pinned.contains(item.path))
                              Icon(Icons.push_pin, size: 14, color: scheme.primary),
                            if (item.bookmarked || appSettings.bookmarks.contains(item.path))
                              Padding(
                                padding: const EdgeInsets.only(left: 4),
                                child: Icon(Icons.bookmark, size: 14, color: scheme.primary),
                              ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 6),
                    ResumeBar(progress: item.progress),
                  ],
                ),
              ),
              if (selecting)
                Checkbox(
                  value: selected,
                  onChanged: (_) => onTap(),
                )
              else
                IconButton(onPressed: onMenu, icon: const Icon(Icons.more_vert), visualDensity: VisualDensity.compact),
            ],
          ),
        ),
      ),
    );
  }
}

class VideoGridCard extends StatelessWidget {
  const VideoGridCard({
    super.key,
    required this.item,
    required this.selected,
    required this.selecting,
    required this.onTap,
    required this.onLongPress,
    required this.onMenu,
  });

  final VideoItem item;
  final bool selected;
  final bool selecting;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  VideoThumb(item: item, radius: 0),
                  if (selecting)
                    Positioned(
                      left: 8,
                      top: 8,
                      child: Icon(
                        selected ? Icons.check_circle : Icons.circle_outlined,
                        color: selected ? scheme.primary : Colors.white,
                      ),
                    ),
                  Positioned(
                    right: 0,
                    top: 0,
                    child: IconButton(
                      onPressed: onMenu,
                      icon: const Icon(Icons.more_vert, color: Colors.white, size: 20),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
              child: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, height: 1.25)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          formatBytes(item.size),
                          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  ResumeBar(progress: item.progress),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> showVideoMenu(BuildContext context, VideoItem item, {required VoidCallback onChanged, required VoidCallback onPlay}) async {
  final scheme = Theme.of(context).colorScheme;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) {
      final pad = MediaQuery.viewPaddingOf(ctx);
      final insets = MediaQuery.viewInsetsOf(ctx);
      return Padding(
        padding: EdgeInsets.only(bottom: pad.bottom + insets.bottom),
        child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: SizedBox(width: 64, height: 40, child: VideoThumb(item: item, radius: 8)),
              title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(formatBytes(item.size)),
            ),
            const Divider(height: 1),
            ListTile(leading: const Icon(Icons.play_arrow), title: const Text('Play'), onTap: () { Navigator.pop(ctx); onPlay(); }),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('Rename'),
              onTap: () async {
                Navigator.pop(ctx);
                await Future<void>.delayed(const Duration(milliseconds: 160));
                if (!context.mounted) return;
                final name = await promptText(context, 'Rename', item.title);
                if (name != null && name.trim().isNotEmpty) {
                  await library.rename(item, name.trim());
                  onChanged();
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: const Text('Share'),
              onTap: () async {
                Navigator.pop(ctx);
                await SharePlus.instance.share(ShareParams(files: [XFile(item.path)], title: item.title));
              },
            ),
            ListTile(
              leading: Icon(item.bookmarked ? Icons.bookmark : Icons.bookmark_border),
              title: Text(item.bookmarked ? 'Remove bookmark' : 'Bookmark'),
              onTap: () {
                Navigator.pop(ctx);
                if (appSettings.bookmarks.contains(item.path)) {
                  appSettings.bookmarks.remove(item.path);
                  item.bookmarked = false;
                } else {
                  appSettings.bookmarks.add(item.path);
                  item.bookmarked = true;
                }
                appSettings.save();
                onChanged();
              },
            ),
            ListTile(
              leading: Icon(appSettings.pinned.contains(item.path) ? Icons.push_pin : Icons.push_pin_outlined),
              title: Text(appSettings.pinned.contains(item.path) ? 'Unpin' : 'Pin to top'),
              onTap: () {
                Navigator.pop(ctx);
                if (appSettings.pinned.contains(item.path)) {
                  appSettings.pinned.remove(item.path);
                } else {
                  appSettings.pinned.add(item.path);
                }
                appSettings.save();
                onChanged();
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: scheme.error),
              title: Text('Delete', style: TextStyle(color: scheme.error)),
              onTap: () async {
                Navigator.pop(ctx);
                final ok = !appSettings.confirmDelete || await confirm(context, 'Delete this video?', item.title);
                if (ok == true) {
                  await library.deleteVideos([item]);
                  onChanged();
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('Properties'),
              onTap: () {
                Navigator.pop(ctx);
                showProperties(context, item);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
        ),
      );
    },
  );
}

Future<void> showProperties(BuildContext context, VideoItem item) async {
  final file = File(item.path);
  final exists = file.existsSync();
  final stat = exists ? await file.stat() : null;
  var size = item.size;
  if (exists) {
    try {
      final n = file.lengthSync();
      if (n > 0) size = n;
    } catch (_) {}
  }
  if (size <= 0) size = await AndroidBridge.fileSize(item.path);
  final info = await AndroidBridge.mediaInfo(item.path);
  if (!context.mounted) return;
  final fps = (info?['fps'] as num?)?.toDouble() ?? item.fps;
  final bitrate = (info?['bitrate'] as num?)?.toInt() ?? item.bitrate;
  final frames = (info?['frameCount'] as num?)?.toInt() ?? item.frameCount;
  final width = (info?['width'] as num?)?.toInt() ?? item.width;
  final height = (info?['height'] as num?)?.toInt() ?? item.height;
  final durationMs = (info?['durationMs'] as num?)?.toInt();
  String fpsLabel;
  if (fps == null || fps <= 0) {
    fpsLabel = '-';
  } else if ((fps - fps.round()).abs() < 0.05) {
    fpsLabel = '${fps.round()} fps';
  } else {
    fpsLabel = '${fps.toStringAsFixed(2)} fps';
  }
  final rows = <(String, String)>[
    ('Name', item.title),
    ('Path', item.path),
    ('Folder', item.folder),
    ('Size', '${formatBytes(size)}  ($size bytes)'),
    ('Duration', durationMs != null ? formatDuration(Duration(milliseconds: durationMs)) : formatDuration(item.duration)),
    ('Resolution', width > 0 && height > 0 ? '$width×$height' : item.resolutionLabel),
    ('Width', '$width px'),
    ('Height', '$height px'),
    ('Frame rate', fpsLabel),
    ('Frame count', frames != null && frames > 0 ? '$frames' : '-'),
    ('Bitrate', bitrate != null && bitrate > 0 ? '${(bitrate / 1000).toStringAsFixed(0)} kbps' : '-'),
    ('Aspect', width > 0 && height > 0 ? (width / height).toStringAsFixed(4) : '-'),
    ('Container', item.extension.toUpperCase()),
    ('MIME', item.mime ?? (info?['mime'] as String?) ?? 'video/${item.extension}'),
    ('Created', item.created != null ? DateFormat.yMMMMd().add_Hms().format(item.created!) : '-'),
    ('Modified', DateFormat.yMMMMd().add_Hms().format(stat?.modified ?? item.modified)),
    ('Accessed', stat != null ? DateFormat.yMMMMd().add_Hms().format(stat.accessed) : '-'),
    ('Changed', stat != null ? DateFormat.yMMMMd().add_Hms().format(stat.changed) : '-'),
    ('Exists', exists ? 'Yes' : 'Missing'),
    ('Readable', exists ? 'Yes' : 'No'),
    ('Bookmarked', item.bookmarked ? 'Yes' : 'No'),
    ('Resume', '${(item.progress * 100).toStringAsFixed(1)}%'),
    ('Storage', item.path.contains('usb') ? 'USB / OTG' : item.path.contains('sdcard') || item.path.contains('/storage/') && !item.path.contains('emulated') ? 'SD card / volume' : 'Internal'),
  ];
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) {
      final pad = MediaQuery.viewPaddingOf(ctx);
      final insets = MediaQuery.viewInsetsOf(ctx);
      return DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.72,
        maxChildSize: 0.95,
        builder: (_, controller) {
          return Padding(
            padding: EdgeInsets.only(bottom: pad.bottom + insets.bottom),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 8, 8),
                  child: Row(
                    children: [
                      const Expanded(child: Text('Properties', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600))),
                      IconButton(onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close)),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.separated(
                    controller: controller,
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                    itemCount: rows.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final r = rows[i];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(width: 110, child: Text(r.$1, style: TextStyle(color: Theme.of(ctx).colorScheme.onSurfaceVariant))),
                            Expanded(child: SelectableText(r.$2, style: const TextStyle(fontWeight: FontWeight.w500))),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      );
    },
  );
}

Future<bool> confirm(BuildContext context, String title, String body) async {
  final scheme = Theme.of(context).colorScheme;
  final v = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: scheme.error, foregroundColor: scheme.onError),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  return v ?? false;
}

Future<String?> promptText(BuildContext context, String title, String initial) async {
  final c = TextEditingController(text: initial);
  try {
    return await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (ctx) {
        final insets = MediaQuery.viewInsetsOf(ctx);
        return Padding(
          padding: EdgeInsets.fromLTRB(20, 4, 20, 16 + insets.bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              TextField(
                controller: c,
                autofocus: true,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(border: OutlineInputBorder()),
                onSubmitted: (v) => Navigator.pop(ctx, v),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                  const SizedBox(width: 8),
                  FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Save')),
                ],
              ),
            ],
          ),
        );
      },
    );
  } finally {
    c.dispose();
  }
}

class ChipScroller extends StatelessWidget {
  const ChipScroller({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: children.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) => children[i],
      ),
    );
  }
}

Future<void> showFolderEntryMenu(
  BuildContext context, {
  required String path,
  required bool isDir,
  required VoidCallback onChanged,
  VoidCallback? onOpen,
}) async {
  final scheme = Theme.of(context).colorScheme;
  final name = path.split(RegExp(r'[/\\]')).last;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) {
      final pad = MediaQuery.viewPaddingOf(ctx);
      final insets = MediaQuery.viewInsetsOf(ctx);
      return Padding(
        padding: EdgeInsets.only(bottom: pad.bottom + insets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis), subtitle: Text(isDir ? 'Folder' : 'Video')),
            if (onOpen != null)
              ListTile(
                leading: const Icon(Icons.open_in_new),
                title: Text(isDir ? 'Open' : 'Play'),
                onTap: () {
                  Navigator.pop(ctx);
                  onOpen();
                },
              ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('Rename'),
              onTap: () async {
                Navigator.pop(ctx);
                await Future<void>.delayed(const Duration(milliseconds: 160));
                if (!context.mounted) return;
                final next = await promptText(context, 'Rename', name);
                if (next != null && next.trim().isNotEmpty) {
                  await AndroidBridge.renamePath(path, next.trim());
                  onChanged();
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copy'),
              onTap: () {
                Navigator.pop(ctx);
                library.copyEntry(path);
                onChanged();
              },
            ),
            ListTile(
              leading: const Icon(Icons.content_cut),
              title: const Text('Cut'),
              onTap: () {
                Navigator.pop(ctx);
                library.cutEntry(path);
                onChanged();
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: scheme.error),
              title: Text('Delete', style: TextStyle(color: scheme.error)),
              onTap: () async {
                Navigator.pop(ctx);
                final ok = !appSettings.confirmDelete || await confirm(context, 'Delete ${isDir ? 'folder' : 'video'}?', name);
                if (ok == true) {
                  await library.deletePath(path);
                  onChanged();
                }
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}
