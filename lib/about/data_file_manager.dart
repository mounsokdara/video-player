import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:video_player_app/about/about_widgets.dart';
import 'package:video_player_app/core/slide_snackbar.dart';
import 'package:video_player_app/core/widgets.dart' show confirm;
import 'package:video_player_app/library/library.dart' show formatBytes;

class _Root {
  const _Root(this.label, this.path);
  final String label;
  final String path;
}

class _Entry {
  const _Entry({
    required this.path,
    required this.name,
    required this.isDir,
    required this.isLink,
    required this.size,
    required this.modified,
    this.count,
  });
  final String path;
  final String name;
  final bool isDir;
  final bool isLink;
  final int size;
  final DateTime modified;
  final int? count;
}

final _dateFormat = DateFormat('yyyy-MM-dd HH:mm');
const _maxTextBytes = 1024 * 1024;

Future<List<_Root>> _findRoots() async {
  final out = <_Root>[];
  void add(String label, String? path) {
    if (path == null || out.any((r) => r.path == path)) return;
    if (Directory(path).existsSync()) out.add(_Root(label, path));
  }

  final cache = (await getTemporaryDirectory()).path;
  add('App data (root)', Directory(cache).parent.path);
  add('App cache', cache);
  add('App files', (await getApplicationSupportDirectory()).path);
  add('App documents', (await getApplicationDocumentsDirectory()).path);
  try {
    for (final d in await getExternalCacheDirectories() ?? const <Directory>[]) {
      add('External app cache', d.path);
    }
    for (final d in await getExternalStorageDirectories() ?? const <Directory>[]) {
      add('External app files', d.path);
    }
  } catch (_) {}
  add('Device root (/)', '/');
  return out;
}

Future<int> _folderSize(String path) async {
  var total = 0;
  try {
    await for (final e in Directory(path).list(recursive: true, followLinks: false)) {
      if (e is File) {
        try {
          total += await e.length();
        } catch (_) {}
      }
    }
  } catch (_) {}
  return total;
}

int? _count(String path) {
  try {
    return Directory(path).listSync().length;
  } catch (_) {
    return null;
  }
}

class DataFileManagerPage extends StatefulWidget {
  const DataFileManagerPage({super.key});

  @override
  State<DataFileManagerPage> createState() => _DataFileManagerPageState();
}

class _DataFileManagerPageState extends State<DataFileManagerPage> {
  List<_Root> _roots = const [];
  String? _rootPath;
  String? _dir;
  List<_Entry> _entries = const [];
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final roots = await _findRoots();
    if (!mounted) return;
    setState(() {
      _roots = roots;
      _loading = false;
    });
  }

  void _openRoot(_Root r) {
    _rootPath = r.path;
    _dir = r.path;
    _load();
  }

  void _openDir(String path) {
    _dir = path;
    _load();
  }

  void _up() {
    final dir = _dir;
    if (dir == null) return;
    if (dir == _rootPath || p.dirname(dir) == dir) {
      setState(() {
        _dir = null;
        _rootPath = null;
        _entries = const [];
        _error = null;
      });
    } else {
      _dir = p.dirname(dir);
      _load();
    }
  }

  void _load() {
    final dir = _dir;
    if (dir == null) return;
    try {
      final entries = <_Entry>[];
      for (final e in Directory(dir).listSync(followLinks: false)) {
        final st = e.statSync();
        final isDir = FileSystemEntity.isDirectorySync(e.path);
        entries.add(_Entry(
          path: e.path,
          name: p.basename(e.path),
          isDir: isDir,
          isLink: e is Link,
          size: st.size < 0 ? 0 : st.size,
          modified: st.modified,
          count: isDir ? _count(e.path) : null,
        ));
      }
      entries.sort((a, b) {
        if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      setState(() {
        _entries = entries;
        _error = null;
      });
    } catch (_) {
      setState(() {
        _entries = const [];
        _error = 'Cannot open this folder (permission denied).';
      });
    }
  }

  Future<void> _copyPath(String path) async {
    await Clipboard.setData(ClipboardData(text: path));
    if (!mounted) return;
    SlideSnackBar.show(context, message: 'Path copied', behavior: SnackBarBehavior.floating, duration: const Duration(seconds: 2));
  }

  Future<void> _view(_Entry e) async {
    if (e.size > _maxTextBytes) return _details(e, note: 'Too large to preview (over 1 MB).');
    try {
      final bytes = await File(e.path).readAsBytes();
      if (bytes.contains(0)) return _details(e, note: 'Binary file, no preview.');
      final text = utf8.decode(bytes);
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute<void>(builder: (_) => _TextViewPage(name: e.name, text: text)),
      );
    } on FormatException {
      await _details(e, note: 'Binary file, no preview.');
    } catch (_) {
      await _details(e, note: 'Cannot read this file.');
    }
  }

  Future<void> _details(_Entry e, {String? note}) async {
    if (!mounted) return;
    final st = FileStat.statSync(e.path);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(e.name, maxLines: 2, overflow: TextOverflow.ellipsis),
        content: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            SelectableText(e.path, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 12),
            Text('Type: ${e.isLink ? 'Link' : (e.isDir ? 'Folder' : 'File')}'),
            if (e.isDir)
              FutureBuilder<int>(
                future: _folderSize(e.path),
                builder: (_, s) => Text('Size: ${s.hasData ? formatBytes(s.data!) : 'calculating...'}'),
              )
            else
              Text('Size: ${formatBytes(e.size)}'),
            Text('Modified: ${_dateFormat.format(st.modified)}'),
            Text('Permissions: ${st.modeString()}'),
            if (note != null) ...[const SizedBox(height: 12), Text(note)],
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    );
  }

  Future<void> _delete(_Entry e) async {
    final ok = await confirm(
      context,
      'Delete ${e.isDir ? 'folder' : 'file'}?',
      '${e.name}\n\nDeleting app data can reset settings or break the app.',
    );
    if (!ok || !mounted) return;
    try {
      if (e.isLink) {
        Link(e.path).deleteSync();
      } else if (e.isDir) {
        Directory(e.path).deleteSync(recursive: true);
      } else {
        File(e.path).deleteSync();
      }
    } catch (_) {
      if (mounted) SlideSnackBar.show(context, message: 'Could not delete (permission denied)', behavior: SnackBarBehavior.floating, duration: const Duration(seconds: 3));
    }
    _load();
  }

  void _menu(_Entry e) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('Details'),
            onTap: () {
              Navigator.pop(ctx);
              _details(e);
            },
          ),
          ListTile(
            leading: const Icon(Icons.content_copy),
            title: const Text('Copy path'),
            onTap: () {
              Navigator.pop(ctx);
              _copyPath(e.path);
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('Delete'),
            onTap: () {
              Navigator.pop(ctx);
              _delete(e);
            },
          ),
        ]),
      ),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final scheme = Theme.of(context).colorScheme;
    if (_dir == null) {
      return ListView(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Text(
            "Browse this app's private folders. Deleting files here can reset settings or break the app.",
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
          ),
        ),
        for (final r in _roots)
          ListTile(
            leading: const Icon(Icons.folder_special_outlined),
            title: Text(r.label),
            subtitle: Text(r.path, style: const TextStyle(fontSize: 12)),
            onTap: () => _openRoot(r),
          ),
      ]);
    }
    if (_error != null) {
      return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center)));
    }
    if (_entries.isEmpty) return const Center(child: Text('Empty folder'));
    return ListView.builder(
      itemCount: _entries.length,
      itemBuilder: (_, i) {
        final e = _entries[i];
        final when = _dateFormat.format(e.modified);
        return ListTile(
          leading: Icon(e.isLink ? Icons.link : (e.isDir ? Icons.folder : Icons.insert_drive_file_outlined)),
          title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(e.isDir ? '${e.count ?? '?'} items · $when' : '${formatBytes(e.size)} · $when'),
          onTap: () => e.isDir ? _openDir(e.path) : _view(e),
          onLongPress: () => _menu(e),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final dir = _dir;
    return PopScope(
      canPop: dir == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _up();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: standaloneBack(context),
          title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(dir == null ? 'Data file manager' : (p.basename(dir).isEmpty ? dir : p.basename(dir))),
            if (dir != null) Text(dir, style: const TextStyle(fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
          ]),
          actions: [
            if (dir != null) IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: _load),
          ],
        ),
        body: _body(),
      ),
    );
  }
}

class _TextViewPage extends StatelessWidget {
  const _TextViewPage({required this.name, required this.text});
  final String name;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Copy',
            icon: const Icon(Icons.content_copy),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (context.mounted) {
                SlideSnackBar.show(context, message: 'Copied', behavior: SnackBarBehavior.floating, duration: const Duration(seconds: 2));
              }
            },
          ),
        ],
      ),
      body: Scrollbar(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: SelectableText(text, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        ),
      ),
    );
  }
}
