import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import 'android_bridge.dart';
import 'library.dart';
import 'main.dart';
import 'models.dart';
import 'player.dart';
import 'settings_ui.dart';
import 'widgets.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.onSettingsChanged});
  final VoidCallback onSettingsChanged;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int tab = 0;
  bool loading = true;
  String? error;
  bool selecting = false;
  final selected = <String>{};
  LayoutMode layout = LayoutMode.list;
  SortBy sort = SortBy.date;
  bool sortDesc = true;
  String query = '';
  bool searching = false;
  final searchCtrl = TextEditingController();

  // folders
  String? folderPath;
  final folderTrail = <String>[];

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      await library.requestPermissions();
      if (appSettings.scanOnStart) await library.scan();
    } catch (e) {
      error = '$e';
    }
    if (mounted) setState(() => loading = false);
  }

  List<VideoItem> get visible => library.sorted(sort, desc: sortDesc, query: query);

  Future<void> _open(VideoItem item, {List<VideoItem>? playlist}) async {
    final list = playlist ?? visible;
    final i = list.indexWhere((v) => v.id == item.id);
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerPage(
        playlist: list,
        index: i < 0 ? 0 : i,
        onChanged: () => setState(() {}),
      ),
    ));
    setState(() {});
  }

  void _toggleSelect(VideoItem item) {
    setState(() {
      selecting = true;
      if (selected.contains(item.id)) {
        selected.remove(item.id);
        if (selected.isEmpty) selecting = false;
      } else {
        selected.add(item.id);
      }
    });
  }

  Future<void> _deleteSelected() async {
    final items = library.videos.where((v) => selected.contains(v.id)).toList();
    if (items.isEmpty) return;
    final ok = !appSettings.confirmDelete || await confirm(context, 'Delete ${items.length} videos?', 'This cannot be undone.');
    if (ok != true) return;
    await library.deleteVideos(items);
    setState(() {
      selected.clear();
      selecting = false;
    });
  }

  Future<void> _shareSelected() async {
    final items = library.videos.where((v) => selected.contains(v.id)).toList();
    if (items.isEmpty) return;
    await SharePlus.instance.share(ShareParams(files: items.map((e) => XFile(e.path)).toList()));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: IndexedStack(
        index: tab,
        children: [
          _videos(scheme),
          _folders(scheme),
          SettingsHub(onChanged: widget.onSettingsChanged),
        ],
      ),
      bottomNavigationBar: appSettings.showAppNav
          ? NavigationBar(
              selectedIndex: tab,
              onDestinationSelected: (i) => setState(() {
                tab = i;
                selecting = false;
                selected.clear();
                searching = false;
              }),
              destinations: const [
                NavigationDestination(icon: Icon(Icons.play_circle_outline), selectedIcon: Icon(Icons.play_circle), label: 'Videos'),
                NavigationDestination(icon: Icon(Icons.folder_outlined), selectedIcon: Icon(Icons.folder), label: 'Folders'),
                NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Settings'),
              ],
            )
          : null,
    );
  }

  Widget _videos(ColorScheme scheme) {
    final items = visible;
    return NestedScrollView(
      headerSliverBuilder: (context, inner) {
        return [
          SliverAppBar(
            pinned: true,
            title: searching
                ? TextField(
                    controller: searchCtrl,
                    autofocus: true,
                    decoration: const InputDecoration(hintText: 'Search videos', border: InputBorder.none),
                    onChanged: (v) => setState(() => query = v),
                  )
                : Text(selecting ? '${selected.length} selected' : 'Videos'),
            actions: [
              if (selecting) ...[
                IconButton(onPressed: _shareSelected, icon: const Icon(Icons.share_outlined), tooltip: 'Share'),
                IconButton(onPressed: _deleteSelected, icon: const Icon(Icons.delete_outline), tooltip: 'Delete'),
                IconButton(
                  onPressed: () => setState(() {
                    selecting = false;
                    selected.clear();
                  }),
                  icon: const Icon(Icons.close),
                ),
              ] else ...[
                IconButton(
                  onPressed: () => setState(() {
                    searching = !searching;
                    if (!searching) {
                      query = '';
                      searchCtrl.clear();
                    }
                  }),
                  icon: const Icon(Icons.search),
                ),
                PopupMenuButton<String>(
                  onSelected: (v) async {
                    if (v == 'eq') {
                      Navigator.push(context, MaterialPageRoute(builder: (_) => const EqualizerPage()));
                    } else if (v == 'refresh') {
                      await _boot();
                    } else if (v == 'select') {
                      setState(() => selecting = true);
                    } else if (v == 'allfiles') {
                      await library.ensureAllFiles();
                      await _boot();
                    } else if (v == 'nav') {
                      setState(() => appSettings.showAppNav = !appSettings.showAppNav);
                      appSettings.save();
                      widget.onSettingsChanged();
                    } else if (v == 'import') {
                      final r = await FilePicker.platform.pickFiles(type: FileType.video, allowMultiple: true);
                      if (r != null) {
                        for (final f in r.files) {
                          if (f.path == null) continue;
                          if (!looksLikeVideo(f.path!)) continue;
                          library.videos.add(VideoItem(
                            id: f.path!,
                            path: f.path!,
                            title: f.name,
                            folder: p.dirname(f.path!),
                            size: f.size,
                            modified: DateTime.now(),
                          ));
                        }
                        setState(() {});
                      }
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'eq', child: Text('Equalizer')),
                    const PopupMenuItem(value: 'refresh', child: Text('Refresh')),
                    const PopupMenuItem(value: 'select', child: Text('Select')),
                    const PopupMenuItem(value: 'allfiles', child: Text('Grant all-files access')),
                    const PopupMenuItem(value: 'import', child: Text('Import files')),
                    PopupMenuItem(value: 'nav', child: Text(appSettings.showAppNav ? 'Hide navigation bar' : 'Show navigation bar')),
                  ],
                ),
              ],
            ],
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${items.length} videos  ·  ${formatBytes(library.totalBytes)}',
                      style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
                    ),
                  ),
                  IconButton(
                    tooltip: layout == LayoutMode.list ? 'Grid' : 'List',
                    onPressed: () => setState(() => layout = layout == LayoutMode.list ? LayoutMode.grid : LayoutMode.list),
                    icon: Icon(layout == LayoutMode.list ? Icons.grid_view : Icons.view_list),
                  ),
                  IconButton(
                    tooltip: 'Sort',
                    onPressed: _sortSheet,
                    icon: const Icon(Icons.sort),
                  ),
                ],
              ),
            ),
          ),
        ];
      },
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : items.isEmpty
              ? _empty()
              : layout == LayoutMode.list
                  ? ListView.builder(
                      padding: const EdgeInsets.only(bottom: 24),
                      itemCount: items.length,
                      itemBuilder: (_, i) {
                        final item = items[i];
                        return VideoListTile(
                          item: item,
                          selected: selected.contains(item.id),
                          selecting: selecting,
                          onTap: () => selecting ? _toggleSelect(item) : _open(item),
                          onLongPress: () => _toggleSelect(item),
                          onMenu: () => showVideoMenu(context, item, onChanged: () => setState(() {}), onPlay: () => _open(item)),
                        );
                      },
                    )
                  : GridView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: MediaQuery.sizeOf(context).width >= 900 ? 4 : MediaQuery.sizeOf(context).width >= 600 ? 3 : 2,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        childAspectRatio: 0.82,
                      ),
                      itemCount: items.length,
                      itemBuilder: (_, i) {
                        final item = items[i];
                        return VideoGridCard(
                          item: item,
                          selected: selected.contains(item.id),
                          selecting: selecting,
                          onTap: () => selecting ? _toggleSelect(item) : _open(item),
                          onLongPress: () => _toggleSelect(item),
                          onMenu: () => showVideoMenu(context, item, onChanged: () => setState(() {}), onPlay: () => _open(item)),
                        );
                      },
                    ),
    );
  }

  Widget _empty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.movie_filter_outlined, size: 56, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            const Text('No videos found', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(
              'Grant all-files access so the player can read internal storage, SD cards, and USB drives.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () async {
                await library.ensureAllFiles();
                await _boot();
              },
              child: const Text('Grant access'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _sortSheet() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Sort by'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final s in SortBy.values)
                RadioListTile<SortBy>(
                  value: s,
                  groupValue: sort,
                  title: Text(switch (s) {
                    SortBy.name => 'Name',
                    SortBy.date => 'Date',
                    SortBy.size => 'Size',
                    SortBy.duration => 'Duration',
                    SortBy.folder => 'Folder',
                  }),
                  onChanged: (v) {
                    setState(() => sort = v!);
                    Navigator.pop(ctx);
                  },
                ),
              SwitchListTile(
                title: const Text('Descending'),
                value: sortDesc,
                onChanged: (v) {
                  setState(() => sortDesc = v);
                  Navigator.pop(ctx);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _folders(ColorScheme scheme) {
    final roots = library.volumes;
    final path = folderPath;
    if (path == null) {
      return CustomScrollView(
        slivers: [
          const SliverAppBar(pinned: true, title: Text('Folders')),
          if (loading)
            const SliverFillRemaining(child: Center(child: CircularProgressIndicator()))
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              sliver: SliverList.list(children: [
                if (roots.isEmpty)
                  ListTile(
                    leading: const Icon(Icons.sd_storage_outlined),
                    title: const Text('Internal storage'),
                    subtitle: const Text('Tap to browse'),
                    onTap: () => setState(() {
                      folderPath = '/storage/emulated/0';
                      folderTrail
                        ..clear()
                        ..add(folderPath!);
                    }),
                  ),
                for (final v in roots)
                  Card(
                    child: ListTile(
                      leading: Icon(v.isUsb ? Icons.usb : v.isSd ? Icons.sd_card : Icons.smartphone_outlined),
                      title: Text(v.description),
                      subtitle: Text(
                        [
                          v.path,
                          if (v.isUsb) 'USB',
                          if (v.isSd) 'SD card',
                          v.state,
                        ].join(' · '),
                      ),
                      onTap: () => setState(() {
                        folderPath = v.path;
                        folderTrail
                          ..clear()
                          ..add(v.path);
                      }),
                    ),
                  ),
                const SizedBox(height: 12),
                Text('Libraries', style: TextStyle(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                for (final f in library.folders)
                  ListTile(
                    leading: const Icon(Icons.folder_outlined),
                    title: Text(f.name),
                    subtitle: Text('${f.videoCount} videos · ${formatBytes(f.size)}'),
                    onTap: () {
                      final vids = library.videos.where((v) => v.folder == f.path).toList();
                      if (vids.isNotEmpty) _open(vids.first, playlist: vids);
                    },
                    onLongPress: () => setState(() {
                      folderPath = f.path;
                      folderTrail
                        ..clear()
                        ..add(f.path);
                    }),
                    trailing: IconButton(
                      icon: const Icon(Icons.more_vert),
                      onPressed: () => _folderMenu(f.path, f.name),
                    ),
                  ),
              ]),
            ),
        ],
      );
    }

    final ents = library.listDir(path);
    return Column(
      children: [
        AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => setState(() {
              if (folderTrail.length <= 1) {
                folderPath = null;
                folderTrail.clear();
              } else {
                folderTrail.removeLast();
                folderPath = folderTrail.last;
              }
            }),
          ),
          title: Text(p.basename(path).isEmpty ? path : p.basename(path)),
          actions: [
            IconButton(
              icon: const Icon(Icons.more_vert),
              onPressed: () => _folderMenu(path, p.basename(path)),
            ),
          ],
        ),
        Expanded(
          child: ListView.builder(
            itemCount: ents.length,
            itemBuilder: (_, i) {
              final e = ents[i];
              final name = p.basename(e.path);
              final isDir = e is Directory;
              VideoItem? video;
              if (!isDir) {
                video = library.videos.cast<VideoItem?>().firstWhere((v) => v!.path == e.path, orElse: () => null);
                video ??= VideoItem(
                  id: e.path,
                  path: e.path,
                  title: name,
                  folder: path,
                  size: (e as File).existsSync() ? e.lengthSync() : 0,
                  modified: e.statSync().modified,
                );
              }
              return ListTile(
                leading: isDir
                    ? const Icon(Icons.folder)
                    : SizedBox(width: 56, height: 36, child: video != null ? VideoThumb(item: video, radius: 6) : const Icon(Icons.movie_outlined)),
                title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: isDir ? const Text('Folder') : Text(formatBytes(video?.size ?? 0)),
                trailing: isDir
                    ? IconButton(icon: const Icon(Icons.more_vert), onPressed: () => _folderMenu(e.path, name))
                    : IconButton(
                        icon: const Icon(Icons.more_vert),
                        onPressed: video == null
                            ? null
                            : () => showVideoMenu(context, video!, onChanged: () => setState(() {}), onPlay: () => _open(video!)),
                      ),
                onTap: () {
                  if (isDir) {
                    setState(() {
                      folderPath = e.path;
                      folderTrail.add(e.path);
                    });
                  } else if (video != null) {
                    if (selecting) {
                      _toggleSelect(video);
                    } else {
                      final vids = ents.whereType<File>().map((f) {
                        return library.videos.cast<VideoItem?>().firstWhere((v) => v!.path == f.path, orElse: () => VideoItem(
                              id: f.path,
                              path: f.path,
                              title: p.basename(f.path),
                              folder: path,
                              size: f.lengthSync(),
                              modified: f.statSync().modified,
                            ));
                      }).whereType<VideoItem>().toList();
                      _open(video, playlist: vids);
                    }
                  }
                },
                onLongPress: () {
                  if (!isDir && video != null) _toggleSelect(video);
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _folderMenu(String path, String name) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(name), subtitle: Text(path)),
            ListTile(
              leading: const Icon(Icons.refresh),
              title: const Text('Scan this folder'),
              onTap: () async {
                Navigator.pop(ctx);
                final extra = await AndroidBridge.listVideoFiles(path);
                for (final m in extra) {
                  final vp = m['path'] as String? ?? '';
                  if (vp.isEmpty || library.videos.any((v) => v.path == vp)) continue;
                  library.videos.add(VideoItem(
                    id: vp,
                    path: vp,
                    title: m['name'] as String? ?? p.basename(vp),
                    folder: m['folder'] as String? ?? p.dirname(vp),
                    size: (m['size'] as num?)?.toInt() ?? 0,
                    modified: DateTime.fromMillisecondsSinceEpoch((m['modified'] as num?)?.toInt() ?? 0),
                  ));
                }
                setState(() {});
              },
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('Properties'),
              onTap: () {
                Navigator.pop(ctx);
                final dir = Directory(path);
                showDialog<void>(
                  context: context,
                  builder: (d) => AlertDialog(
                    title: const Text('Folder'),
                    content: Text('Path: $path\nExists: ${dir.existsSync()}'),
                    actions: [TextButton(onPressed: () => Navigator.pop(d), child: const Text('Close'))],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
