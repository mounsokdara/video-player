import 'dart:async';

import 'package:flutter/material.dart';

import 'package:video_player_app/accessibility/live_caption/caption_files.dart';
import 'package:video_player_app/accessibility/live_caption/live_caption_controller.dart';
import 'package:video_player_app/core/models.dart';
import 'package:video_player_app/native/android_bridge.dart';
import 'package:video_player_app/settings/settings.dart';

String _fmt(int ms) {
  if (ms < 0) ms = 0;
  String two(int n) => n.toString().padLeft(2, '0');
  final h = ms ~/ 3600000;
  final m = (ms ~/ 60000) % 60;
  final s = (ms ~/ 1000) % 60;
  final f = (ms % 1000).toString().padLeft(3, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}.$f' : '${(ms ~/ 60000)}:${two(s)}.$f';
}

int? _parse(String raw) {
  final s = raw.trim().replaceAll(',', '.');
  if (s.isEmpty) return null;
  final parts = s.split(':');
  if (parts.length > 3) return null;
  final sec = double.tryParse(parts.last);
  if (sec == null || !sec.isFinite || sec < 0) return null;
  var total = sec * 1000;
  var mult = 60000;
  for (var i = parts.length - 2; i >= 0; i--) {
    final v = int.tryParse(parts[i]);
    if (v == null || v < 0) return null;
    total += v * mult;
    mult *= 60;
  }
  return total.round();
}

class CaptionEditorPage extends StatefulWidget {
  const CaptionEditorPage({super.key, required this.item, required this.onAction});

  final VideoItem item;
  final Future<void> Function(String id) onAction;

  @override
  State<CaptionEditorPage> createState() => _CaptionEditorPageState();
}

class _CaptionEditorPageState extends State<CaptionEditorPage> {
  List<CaptionCue>? _cues;
  bool _dirty = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final live = LiveCaptionController.instance.cuesFor(widget.item.path);
    final list = live.isNotEmpty
        ? <CaptionCue>[...live]
        : (await CaptionFiles.loadImported(widget.item.path) ?? <CaptionCue>[]);
    list.sort((a, b) => a.start.compareTo(b.start));
    if (!mounted) return;
    setState(() => _cues = list);
  }

  Future<void> _edit(int index) async {
    final cues = _cues;
    if (cues == null) return;
    final result = await showDialog<CaptionCue>(
      context: context,
      builder: (_) => _CueDialog(cue: cues[index]),
    );
    if (result == null || !mounted) return;
    setState(() {
      cues[index] = result;
      cues.sort((a, b) => a.start.compareTo(b.start));
      _dirty = true;
    });
  }

  Future<void> _add() async {
    final cues = _cues;
    if (cues == null) return;
    final start = cues.isEmpty ? 0 : cues.last.end;
    final result = await showDialog<CaptionCue>(
      context: context,
      builder: (_) => _CueDialog(cue: CaptionCue(start, start + 2000, '')),
    );
    if (result == null || !mounted) return;
    setState(() {
      cues.add(result);
      cues.sort((a, b) => a.start.compareTo(b.start));
      _dirty = true;
    });
  }

  void _delete(int index) {
    setState(() {
      _cues!.removeAt(index);
      _dirty = true;
    });
  }

  Future<void> _save() async {
    final cues = _cues;
    if (cues == null || _saving) return;
    if (cues.isEmpty) {
      unawaited(AndroidBridge.toast('Add at least one caption before saving'));
      return;
    }
    setState(() => _saving = true);
    try {
      await CaptionFiles.saveImported(widget.item.path, cues);
    } catch (e) {
      if (mounted) setState(() => _saving = false);
      unawaited(AndroidBridge.toast('Could not save the captions. $e'));
      return;
    }
    if (!appSettings.liveCaption) await widget.onAction('caption');
    LiveCaptionController.instance.applyImported(widget.item.path, cues);
    unawaited(AndroidBridge.toast('Saved ${cues.length} captions'));
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _confirmLeave() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text('Your edits to these captions have not been saved.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep editing')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Discard')),
        ],
      ),
    );
    if (discard == true && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final cues = _cues;
    final ctl = LiveCaptionController.instance;
    final extracting = !ctl.imported && (ctl.state == 'running' || ctl.state == 'waiting');
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_confirmLeave());
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Edit captions'),
          actions: [
            IconButton(tooltip: 'Add caption', onPressed: cues == null ? null : _add, icon: const Icon(Icons.add)),
            IconButton(
              tooltip: 'Save',
              onPressed: (cues == null || !_dirty || _saving) ? null : _save,
              icon: const Icon(Icons.check),
            ),
          ],
        ),
        body: cues == null
            ? const Center(child: CircularProgressIndicator())
            : cues.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('No captions yet. Tap + to add one, or let Live Caption extract some first.'),
                    ),
                  )
                : ListView.builder(
                    itemCount: cues.length + (extracting ? 1 : 0),
                    itemBuilder: (context, i) {
                      if (extracting && i == 0) {
                        return const ListTile(
                          leading: Icon(Icons.info_outline),
                          title: Text('Extraction is still running'),
                          subtitle: Text('Saving keeps only the captions listed here and stops it.'),
                        );
                      }
                      final index = i - (extracting ? 1 : 0);
                      final c = cues[index];
                      return ListTile(
                        title: Text(c.text, maxLines: 3, overflow: TextOverflow.ellipsis),
                        subtitle: Text('${_fmt(c.start)} to ${_fmt(c.end)}'),
                        trailing: IconButton(
                          tooltip: 'Delete',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _delete(index),
                        ),
                        onTap: () => _edit(index),
                      );
                    },
                  ),
      ),
    );
  }
}

class _CueDialog extends StatefulWidget {
  const _CueDialog({required this.cue});
  final CaptionCue cue;

  @override
  State<_CueDialog> createState() => _CueDialogState();
}

class _CueDialogState extends State<_CueDialog> {
  late final TextEditingController _text = TextEditingController(text: widget.cue.text);
  late final TextEditingController _start = TextEditingController(text: _fmt(widget.cue.start));
  late final TextEditingController _end = TextEditingController(text: _fmt(widget.cue.end));
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    _start.dispose();
    _end.dispose();
    super.dispose();
  }

  void _done() {
    final body = _text.text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).join('\n');
    final s = _parse(_start.text);
    final e = _parse(_end.text);
    if (body.isEmpty) {
      setState(() => _error = 'The text cannot be empty');
    } else if (s == null || e == null) {
      setState(() => _error = 'Use a time like 1:23.500');
    } else if (e <= s) {
      setState(() => _error = 'The end must be after the start');
    } else {
      Navigator.pop(context, CaptionCue(s, e, body));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Caption'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _text,
              autofocus: true,
              minLines: 1,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Text'),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _start,
                    keyboardType: TextInputType.datetime,
                    decoration: const InputDecoration(labelText: 'Start'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _end,
                    keyboardType: TextInputType.datetime,
                    decoration: const InputDecoration(labelText: 'End'),
                  ),
                ),
              ],
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _done, child: const Text('OK')),
      ],
    );
  }
}
