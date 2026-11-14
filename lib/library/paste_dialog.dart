import 'package:flutter/material.dart';

import 'package:video_player_app/library/file_transfer.dart';
import 'package:video_player_app/library/library.dart';
import 'package:video_player_app/main.dart' show library;

/// Pastes the clipboard into [dir] behind a progress dialog the person can cancel.
Future<PasteResult> pasteWithProgress(BuildContext context, String dir) async {
  final job = PasteJob(cut: library.clipCut);
  final rootNav = Navigator.of(context, rootNavigator: true);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(canPop: false, child: _PasteDialog(job: job)),
  );
  final res = await library.pasteInto(dir, job: job);
  rootNav.pop();
  return res;
}

class _PasteDialog extends StatefulWidget {
  const _PasteDialog({required this.job});
  final PasteJob job;

  @override
  State<_PasteDialog> createState() => _PasteDialogState();
}

class _PasteDialogState extends State<_PasteDialog> {
  bool _cancelling = false;

  @override
  Widget build(BuildContext context) {
    final job = widget.job;
    return AlertDialog(
      title: Text(job.cut ? 'Moving' : 'Copying'),
      content: ValueListenableBuilder<PasteProgress>(
        valueListenable: job.progress,
        builder: (_, v, _) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (v.items > 1) Text('Item ${v.item} of ${v.items}', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)),
          Text(v.name.isEmpty ? 'Preparing...' : v.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          LinearProgressIndicator(value: v.total > 0 ? (v.done / v.total).clamp(0.0, 1.0) : null),
          const SizedBox(height: 12),
          Text(v.total > 0 ? '${formatBytes(v.done)} / ${formatBytes(v.total)}  (${v.done * 100 ~/ v.total}%)' : ''),
        ]),
      ),
      actions: [
        TextButton(
          onPressed: _cancelling
              ? null
              : () {
                  setState(() => _cancelling = true);
                  job.cancel();
                },
          child: Text(_cancelling ? 'Cancelling...' : 'Cancel'),
        ),
      ],
    );
  }
}
