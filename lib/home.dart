import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import 'android_bridge.dart';
import 'crash.dart';
import 'library.dart';
import 'main.dart';
import 'models.dart';
import 'player.dart';
import 'settings.dart';
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
  Timer? refreshTimer;
  StreamSubscription<Map<String, dynamic>>? events;

  String? folderPath;
  final folderTrail = <String>[];

  @override
  void initState() {
    super.initState();
    _boot();
    events = AndroidBridge.events().listen(_onEvent);
    refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted || !appSettings.autoRefresh) return;
      _refresh();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _consumePending());
  }

  @override
  void dispose() {
    refreshTimer?.cancel();
    events?.cancel();
    searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _consumePending() async {
    final path = await AndroidBridge.pendingOpen();
    if (path != null && path.isNotEmpty && mounted) {
      await _openPath(path);
    }
  }

  void _onEvent(Map<String, dynamic> e) {
    final type = e['type'] as String? ?? '';
    if (type == 'open') {
      final path = e['path'] as String?;
      if (path != null) _openPath(path);
    } else if (type == 'media') {
      final action = e['action'] as String? ?? '';
      if (!PlaybackSession.active) {
        if (action == 'refresh') _boot();
        return;
      }
      final c = PlaybackSession.controller;
      switch (action) {
        case 'play':
          c?.play();
        case 'pause':
          c?.pause();
        case 'next':
          _sessionSkip(1);
        case 'prev':
          _sessionSkip(-1);
        case 'refresh':
          _boot();
      }
      if (mounted) setState(() {});
    }
  }

  bool _busy = false;

  Future<void> _boot({bool spinner = true}) async {
    if (_busy) return;
    _busy = true;
    if (spinner && library.videos.isEmpty && mounted) {
      setState(() {
        loading = true;
        error = null;
      });
    }
    try {
      await library.requestPermissions();
      if (appSettings.scanOnStart || appSettings.autoRefresh || !spinner) {
        await library.scan();
      }
    } catch (e, s) {
      error = '$e';
      CrashLog.record('LIBRARY', '$e', s);
    }
    _busy = false;
    if (mounted) setState(() => loading = false);
  }

  Future<void> _refresh() async {
    if (_busy) return;
    _busy = true;
    try {
      await library.scan();
    } catch (e, s) {
      CrashLog.record('LIBRARY', '$e', s);
    }
    _busy = false;
    if (mounted) setState(() {});
  }

  List<VideoItem> get visible => library.sorted(sort, desc: sortDesc, query: query);

  List<String> get tabs => appSettings.visibleTabs;

  int get safeTab {
    if (tabs.isEmpty) return 0;
    return tab.clamp(0, tabs.length - 1);
  }

  Future<void> _open(VideoItem item, {List<VideoItem>? playlist}) async {
    await CrashLog.breadcrumb('Play ${item.path}');
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

  Future<void> _openPath(String path) async {
    if (!looksLikeVideo(path)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('That file is not a playable video')));
      }
      return;
    }
    VideoItem? item;
    for (final v in library.videos) {
      if (v.path == path) item = v;
    }
    item ??= VideoItem(
      id: path,
      path: path,
      title: p.basename(path),
      folder: p.dirname(path),
      size: File(path).existsSync() ? File(path).lengthSync() : 0,
      modified: DateTime.now(),
    );
    if (library.videos.every((v) => v.path != path)) {
      library.videos.add(item);
    }
    await _open(item, playlist: [item, ...visible.where((v) => v.path != path)]);
  }

  Future<void> _sessionSkip(int delta) async {
    if (!PlaybackSession.active) return;
    final list = PlaybackSession.playlist;
    if (list.isEmpty) return;
    var next = PlaybackSession.index + delta;
    if (next < 0) next = 0;
    if (next >= list.length) next = list.length - 1;
    if (next == PlaybackSession.index && delta != 0) return;
    await _open(list[next], playlist: list);
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

  Future<void> _import() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.video, allowMultiple: true);
    if (r == null) return;
    for (final f in r.files) {
      if (f.path == null) continue;
      if (!looksLikeVideo(f.path!)) continue;
      if (library.videos.any((v) => v.path == f.path)) continue;
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

  void _openHiddenTab(String id) {
    final dest = switch (id) {
      'videos' => VideosHub(
          loading: loading,
          layout: layout,
          sort: sort,
          sortDesc: sortDesc,
          query: query,
          searching: searching,
          searchCtrl: searchCtrl,
          selecting: selecting,
          selected: selected,
          items: visible,
          onSearch: (on) => setState(() {
            searching = on;
            if (!on) {
              query = '';
              searchCtrl.clear();
            }
          }),
          onQuery: (v) => setState(() => query = v),
          onLayout: (v) => setState(() => layout = v),
          onSort: _sortSheet,
          onOpen: _open,
          onToggleSelect: _toggleSelect,
          onShareSelected: _shareSelected,
          onDeleteSelected: _deleteSelected,
          onClearSelect: () => setState(() {
            selecting = false;
            selected.clear();
          }),
          onSelectMode: () => setState(() => selecting = true),
          onRefresh: _refresh,
          onImport: _import,
          overflow: _overflowItems(),
        ),
      'folders' => FoldersHub(
          loading: loading,
          folderPath: folderPath,
          folderTrail: folderTrail,
          onPath: (path, trail) => setState(() {
            folderPath = path;
            folderTrail
              ..clear()
              ..addAll(trail);
          }),
          onOpen: _open,
          onToggleSelect: _toggleSelect,
          selecting: selecting,
          overflow: _overflowItems(),
          onOverflow: _onOverflow,
          onRefresh: _refresh,
        ),
      'settings' => SettingsHub(onChanged: widget.onSettingsChanged, overflow: _overflowItems(), onOverflow: _onOverflow),
      _ => const SizedBox.shrink(),
    };
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => Scaffold(body: dest)));
  }

  List<PopupMenuEntry<String>> _overflowItems() {
    final hidden = appSettings.hiddenTabs;
    return [
      const PopupMenuItem(value: 'eq', child: Text('Equalizer')),
      const PopupMenuItem(value: 'refresh', child: Text('Refresh')),
      const PopupMenuItem(value: 'select', child: Text('Select')),
      const PopupMenuItem(value: 'import', child: Text('Import files')),
      const PopupMenuItem(value: 'tabs', child: Text('Visible tabs')),
      const PopupMenuItem(value: 'crash', child: Text('Crash report')),
      for (final id in hidden)
        PopupMenuItem(value: 'tab:$id', child: Text(AppSettings.tabLabels[id] ?? id)),
    ];
  }

  Future<void> _onOverflow(String v) async {
    if (v == 'eq') {
      try {
        await CrashLog.breadcrumb('Open equalizer');
        if (!context.mounted) return;
        await Navigator.push(context, MaterialPageRoute(builder: (_) => const EqualizerPage()));
      } catch (e, s) {
        CrashLog.record('EQ', '$e', s);
      }
    } else if (v == 'refresh') {
      await _refresh();
    } else if (v == 'select') {
      setState(() => selecting = true);
    } else if (v == 'import') {
      await _import();
    } else if (v == 'tabs') {
      await showTabVisibilityDialog(context, () {
        setState(() {
          if (tab >= tabs.length) tab = 0;
        });
        widget.onSettingsChanged();
      });
    } else if (v == 'crash') {
      await CrashLog.show();
    } else if (v.startsWith('tab:')) {
      _openHiddenTab(v.substring(4));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    final wide = size.width >= 840;
    final current = tabs.isEmpty ? 'videos' : tabs[safeTab];

    Widget pageFor(String id) {
      switch (id) {
        case 'folders':
          return FoldersHub(
            loading: loading,
            folderPath: folderPath,
            folderTrail: folderTrail,
            onPath: (path, trail) => setState(() {
              folderPath = path;
              folderTrail
                ..clear()
                ..addAll(trail);
            }),
            onOpen: _open,
            onToggleSelect: _toggleSelect,
            selecting: selecting,
            overflow: _overflowItems(),
            onOverflow: _onOverflow,
            onRefresh: _refresh,
          );
        case 'settings':
          return SettingsHub(onChanged: widget.onSettingsChanged, overflow: _overflowItems(), onOverflow: _onOverflow);
        default:
          return VideosHub(
            loading: loading,
            layout: layout,
            sort: sort,
            sortDesc: sortDesc,
            query: query,
            searching: searching,
            searchCtrl: searchCtrl,
            selecting: selecting,
            selected: selected,
            items: visible,
            onSearch: (on) => setState(() {
              searching = on;
              if (!on) {
                query = '';
                searchCtrl.clear();
              }
            }),
            onQuery: (v) => setState(() => query = v),
            onLayout: (v) => setState(() => layout = v),
            onSort: _sortSheet,
            onOpen: _open,
            onToggleSelect: _toggleSelect,
            onShareSelected: _shareSelected,
            onDeleteSelected: _deleteSelected,
            onClearSelect: () => setState(() {
              selecting = false;
              selected.clear();
            }),
            onSelectMode: () => setState(() => selecting = true),
            onRefresh: _refresh,
            onImport: _import,
            overflow: _overflowItems(),
            onOverflow: _onOverflow,
          );
      }
    }

    NavigationDestination dest(String id) {
      return switch (id) {
        'folders' => const NavigationDestination(icon: Icon(Icons.folder_outlined), selectedIcon: Icon(Icons.folder), label: 'Folders'),
        'settings' => const NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Settings'),
        _ => const NavigationDestination(icon: Icon(Icons.play_circle_outline), selectedIcon: Icon(Icons.play_circle), label: 'Videos'),
      };
    }

    NavigationRailDestination rail(String id) {
      return switch (id) {
        'folders' => const NavigationRailDestination(icon: Icon(Icons.folder_outlined), selectedIcon: Icon(Icons.folder), label: Text('Folders')),
        'settings' => const NavigationRailDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: Text('Settings')),
        _ => const NavigationRailDestination(icon: Icon(Icons.play_circle_outline), selectedIcon: Icon(Icons.play_circle), label: Text('Videos')),
      };
    }

    final body = pageFor(current);
    final pad = MediaQuery.paddingOf(context);

    Widget shell(Widget child) {
      return Stack(
        children: [
          child,
          if (PlaybackSession.active)
            Positioned(
              left: 12,
              right: 12,
              bottom: (wide ? 16.0 : (tabs.length <= 1 ? 16.0 : 88.0)) + pad.bottom,
              child: Material(
                elevation: 6,
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(16),
                child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                child: Row(
                  children: [
                    const Icon(Icons.headphones),
                    const SizedBox(width: 10),
                    Expanded(
                      child: InkWell(
                        onTap: () {
                          final item = PlaybackSession.item;
                          if (item != null) _open(item, playlist: PlaybackSession.playlist);
                        },
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(PlaybackSession.item?.title ?? 'Playing', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                            const Text('Playing in the background', style: TextStyle(fontSize: 12)),
                          ],
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Previous',
                      onPressed: () => _sessionSkip(-1),
                      icon: const Icon(Icons.skip_previous),
                    ),
                    IconButton(
                      tooltip: (PlaybackSession.controller?.value.isPlaying ?? false) ? 'Pause' : 'Play',
                      onPressed: () async {
                        final c = PlaybackSession.controller;
                        if (c == null) return;
                        if (c.value.isPlaying) {
                          await c.pause();
                        } else {
                          await c.play();
                        }
                        await AndroidBridge.updateBackground(
                          playing: c.value.isPlaying,
                          positionMs: c.value.position.inMilliseconds,
                          durationMs: c.value.duration.inMilliseconds,
                        );
                        setState(() {});
                      },
                      icon: Icon((PlaybackSession.controller?.value.isPlaying ?? false) ? Icons.pause : Icons.play_arrow),
                    ),
                    IconButton(
                      tooltip: 'Next',
                      onPressed: () => _sessionSkip(1),
                      icon: const Icon(Icons.skip_next),
                    ),
                    IconButton(
                      tooltip: 'Stop',
                      onPressed: () async {
                        await PlaybackSession.stop();
                        setState(() {});
                      },
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              ),
            ),
        ],
      );
    }

    if (wide) {
      return Scaffold(
        body: shell(
          Row(
            children: [
              NavigationRail(
                selectedIndex: safeTab,
                onDestinationSelected: (i) => setState(() {
                  tab = i;
                  selecting = false;
                  selected.clear();
                  searching = false;
                }),
                labelType: NavigationRailLabelType.all,
                destinations: [for (final id in tabs) rail(id)],
              ),
              const VerticalDivider(width: 1),
              Expanded(child: body),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      body: shell(body),
      bottomNavigationBar: tabs.length <= 1
          ? null
          : NavigationBar(
              selectedIndex: safeTab,
              onDestinationSelected: (i) => setState(() {
                tab = i;
                selecting = false;
                selected.clear();
                searching = false;
              }),
              destinations: [for (final id in tabs) dest(id)],
            ),
      backgroundColor: scheme.surface,
    );
  }

  Future<void> _sortSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(title: Text('Sort by', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600))),
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
}

class VideosHub extends StatelessWidget {
  const VideosHub({
    super.key,
    required this.loading,
    required this.layout,
    required this.sort,
    required this.sortDesc,
    required this.query,
    required this.searching,
    required this.searchCtrl,
    required this.selecting,
    required this.selected,
    required this.items,
    required this.onSearch,
    required this.onQuery,
    required this.onLayout,
    required this.onSort,
    required this.onOpen,
    required this.onToggleSelect,
    required this.onShareSelected,
    required this.onDeleteSelected,
    required this.onClearSelect,
    required this.onSelectMode,
    required this.onRefresh,
    required this.onImport,
    required this.overflow,
    this.onOverflow,
  });

  final bool loading;
  final LayoutMode layout;
  final SortBy sort;
  final bool sortDesc;
  final String query;
  final bool searching;
  final TextEditingController searchCtrl;
  final bool selecting;
  final Set<String> selected;
  final List<VideoItem> items;
  final void Function(bool) onSearch;
  final void Function(String) onQuery;
  final void Function(LayoutMode) onLayout;
  final Future<void> Function() onSort;
  final Future<void> Function(VideoItem item, {List<VideoItem>? playlist}) onOpen;
  final void Function(VideoItem) onToggleSelect;
  final Future<void> Function() onShareSelected;
  final Future<void> Function() onDeleteSelected;
  final VoidCallback onClearSelect;
  final VoidCallback onSelectMode;
  final Future<void> Function() onRefresh;
  final Future<void> Function() onImport;
  final List<PopupMenuEntry<String>> overflow;
  final Future<void> Function(String)? onOverflow;

  int _columns(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    if (w >= 1400) return 5;
    if (w >= 1100) return 4;
    if (w >= 700) return 3;
    return 2;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pad = MediaQuery.paddingOf(context);
    return RefreshIndicator(
      displacement: 52,
      strokeWidth: 2.4,
      notificationPredicate: (n) => n.depth <= 1,
      onRefresh: onRefresh,
      child: NestedScrollView(
      headerSliverBuilder: (context, inner) {
        return [
          SliverAppBar(
            pinned: true,
            title: searching
                ? TextField(
                    controller: searchCtrl,
                    autofocus: true,
                    decoration: const InputDecoration(hintText: 'Search videos', border: InputBorder.none),
                    onChanged: onQuery,
                  )
                : Text(selecting ? '${selected.length} selected' : 'Videos'),
            actions: [
              if (selecting) ...[
                IconButton(onPressed: onShareSelected, icon: const Icon(Icons.share_outlined), tooltip: 'Share'),
                IconButton(onPressed: onDeleteSelected, icon: const Icon(Icons.delete_outline), tooltip: 'Delete'),
                IconButton(onPressed: onClearSelect, icon: const Icon(Icons.close)),
              ] else ...[
                IconButton(
                  onPressed: () => onSearch(!searching),
                  icon: const Icon(Icons.search),
                ),
                PopupMenuButton<String>(
                  onSelected: (v) => onOverflow?.call(v),
                  itemBuilder: (_) => overflow,
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
                    onPressed: () => onLayout(layout == LayoutMode.list ? LayoutMode.grid : LayoutMode.list),
                    icon: Icon(layout == LayoutMode.list ? Icons.grid_view : Icons.view_list),
                  ),
                  IconButton(
                    tooltip: 'Sort',
                    onPressed: onSort,
                    icon: const Icon(Icons.sort),
                  ),
                ],
              ),
            ),
          ),
        ];
      },
      body: loading
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: const [SizedBox(height: 220, child: Center(child: CircularProgressIndicator()))],
            )
          : items.isEmpty
              ? CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [SliverFillRemaining(hasScrollBody: false, child: _EmptyLibrary(onRefresh: onRefresh, onImport: onImport))],
                )
              : layout == LayoutMode.list
                  ? ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: EdgeInsets.only(bottom: 24 + pad.bottom),
                      itemCount: items.length,
                      itemBuilder: (_, i) {
                        final item = items[i];
                        return VideoListTile(
                          item: item,
                          selected: selected.contains(item.id),
                          selecting: selecting,
                          onTap: () => selecting ? onToggleSelect(item) : onOpen(item),
                          onLongPress: () => onToggleSelect(item),
                          onMenu: () => showVideoMenu(context, item, onChanged: () {}, onPlay: () => onOpen(item)),
                        );
                      },
                    )
                  : GridView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: EdgeInsets.fromLTRB(12, 0, 12, 24 + pad.bottom),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: _columns(context),
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
                          onTap: () => selecting ? onToggleSelect(item) : onOpen(item),
                          onLongPress: () => onToggleSelect(item),
                          onMenu: () => showVideoMenu(context, item, onChanged: () {}, onPlay: () => onOpen(item)),
                        );
                      },
                    ),
    ),
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({required this.onRefresh, required this.onImport});
  final Future<void> Function() onRefresh;
  final Future<void> Function() onImport;

  @override
  Widget build(BuildContext context) {
    final granted = library.allFiles;
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.movie_filter_outlined, size: 56, color: scheme.outline),
              const SizedBox(height: 12),
              Text(
                granted ? 'No videos on this device' : 'Need storage access',
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                granted
                    ? 'Nothing playable turned up in internal storage, SD cards, or USB drives. Import a file or copy videos onto the device, then scan again.'
                    : 'Grant all-files access so the player can read internal storage, SD cards, and USB drives.',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 20),
              if (!granted)
                FilledButton(
                  onPressed: () async {
                    await library.ensureAllFiles();
                    await onRefresh();
                  },
                  child: const Text('Grant access'),
                )
              else ...[
                FilledButton(onPressed: onImport, child: const Text('Import videos')),
                const SizedBox(height: 8),
                TextButton(onPressed: onRefresh, child: const Text('Scan again')),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class FoldersHub extends StatelessWidget {
  const FoldersHub({
    super.key,
    required this.loading,
    required this.folderPath,
    required this.folderTrail,
    required this.onPath,
    required this.onOpen,
    required this.onToggleSelect,
    required this.selecting,
    this.overflow = const [],
    this.onOverflow,
    required this.onRefresh,
  });

  final bool loading;
  final String? folderPath;
  final List<String> folderTrail;
  final void Function(String? path, List<String> trail) onPath;
  final Future<void> Function(VideoItem item, {List<VideoItem>? playlist}) onOpen;
  final void Function(VideoItem) onToggleSelect;
  final bool selecting;
  final List<PopupMenuEntry<String>> overflow;
  final Future<void> Function(String)? onOverflow;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pad = MediaQuery.paddingOf(context);
    final roots = library.volumes;
    final path = folderPath;
    if (path == null) {
      return RefreshIndicator(
        displacement: 52,
        strokeWidth: 2.4,
        notificationPredicate: (n) => n.depth <= 1,
        onRefresh: onRefresh,
        child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverAppBar(
            pinned: true,
            title: const Text('Folders'),
            actions: [
              if (overflow.isNotEmpty)
                PopupMenuButton<String>(
                  onSelected: (v) => onOverflow?.call(v),
                  itemBuilder: (_) => overflow,
                ),
            ],
          ),
          if (loading)
            const SliverFillRemaining(child: Center(child: CircularProgressIndicator()))
          else
            SliverPadding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 24 + pad.bottom),
              sliver: SliverList.list(children: [
                if (roots.isEmpty)
                  ListTile(
                    leading: const Icon(Icons.sd_storage_outlined),
                    title: const Text('Internal storage'),
                    subtitle: const Text('Tap to browse'),
                    onTap: () => onPath('/storage/emulated/0', ['/storage/emulated/0']),
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
                      onTap: () => onPath(v.path, [v.path]),
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
                      if (vids.isNotEmpty) onOpen(vids.first, playlist: vids);
                    },
                    onLongPress: () => onPath(f.path, [f.path]),
                  ),
              ]),
            ),
        ],
      ),
      );
    }

    final ents = library.listDir(path);
    return Column(
      children: [
        AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () {
              if (folderTrail.length <= 1) {
                onPath(null, []);
              } else {
                final next = List<String>.from(folderTrail)..removeLast();
                onPath(next.last, next);
              }
            },
          ),
          title: Text(p.basename(path).isEmpty ? path : p.basename(path)),
        ),
        Expanded(
          child: RefreshIndicator(
            displacement: 52,
            strokeWidth: 2.4,
            onRefresh: onRefresh,
            child: ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.only(bottom: pad.bottom + 16),
            itemCount: ents.length,
            itemBuilder: (_, i) {
              final e = ents[i];
              final name = p.basename(e.path);
              final isDir = e is Directory;
              VideoItem? video;
              if (!isDir) {
                for (final v in library.videos) {
                  if (v.path == e.path) video = v;
                }
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
                onTap: () {
                  if (isDir) {
                    onPath(e.path, [...folderTrail, e.path]);
                  } else if (video != null) {
                    if (selecting) {
                      onToggleSelect(video);
                    } else {
                      final vids = ents.whereType<File>().map((f) {
                        VideoItem? found;
                        for (final v in library.videos) {
                          if (v.path == f.path) found = v;
                        }
                        return found ??
                            VideoItem(
                              id: f.path,
                              path: f.path,
                              title: p.basename(f.path),
                              folder: path,
                              size: f.lengthSync(),
                              modified: f.statSync().modified,
                            );
                      }).toList();
                      onOpen(video, playlist: vids);
                    }
                  }
                },
              );
            },
          ),
          ),
        ),
      ],
    );
  }
}
