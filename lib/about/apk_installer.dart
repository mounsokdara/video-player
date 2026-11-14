import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

const _channel = MethodChannel('app.videoplayer/android');

String _fileName(String url) {
  final segs = Uri.parse(url).pathSegments;
  return segs.isEmpty || segs.last.isEmpty ? 'update.apk' : Uri.decodeComponent(segs.last);
}

String _size(int bytes) {
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

enum _Install { started, needsPermission, failed }

class _Cancelled implements Exception {
  const _Cancelled();
}

/// Downloads [url] inside the app and opens the system installer, no browser.
/// Errors and the unknown-sources prompt are shown in a dialog with Try again.
Future<void> downloadAndInstallApk(BuildContext context, String url) async {
  while (context.mounted) {
    final name = _fileName(url);
    final progress = ValueNotifier<(int, int)>((0, 0));
    var cancelled = false;
    final rootNav = Navigator.of(context, rootNavigator: true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('Downloading update'),
          content: ValueListenableBuilder<(int, int)>(
            valueListenable: progress,
            builder: (_, v, _) {
              final (received, total) = v;
              return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 12),
                LinearProgressIndicator(value: total > 0 ? received / total : null),
                const SizedBox(height: 12),
                Text(total > 0
                    ? '${_size(received)} / ${_size(total)}  (${(received * 100 ~/ total)}%)'
                    : (received > 0 ? _size(received) : 'Starting...')),
              ]);
            },
          ),
          actions: [TextButton(onPressed: () => cancelled = true, child: const Text('Cancel'))],
        ),
      ),
    );

    String? error;
    _Install? result;
    try {
      final file = await _download(url, name, (r, t) => progress.value = (r, t), () => cancelled);
      result = await _install(file.path);
    } on _Cancelled {
      result = null;
    } catch (e) {
      error = e is HttpException ? e.message : 'Download failed. Check your connection.';
    }
    rootNav.pop();
    progress.dispose();
    if (!context.mounted || (result == null && error == null)) return;

    if (result == _Install.started) return;
    final needsPermission = result == _Install.needsPermission;
    final retry = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(needsPermission ? 'Allow installing' : 'Could not install'),
        content: Text(needsPermission
            ? 'Turn on "Allow from this source" for Video Player, go back, then tap Try again.'
            : (error ?? 'The installer could not be opened.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Close')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Try again')),
        ],
      ),
    );
    if (retry != true) return;
  }
}

Future<File> _download(String url, String name, void Function(int, int) onProgress, bool Function() isCancelled) async {
  final dir = Directory('${(await getTemporaryDirectory()).path}/updates');
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  dir.createSync(recursive: true);
  final target = File('${dir.path}/$name');
  final part = File('${target.path}.part');

  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  IOSink? sink;
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close().timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) throw HttpException('Download failed (${response.statusCode})');
    final total = response.contentLength;
    var received = 0;
    sink = part.openWrite();
    await for (final chunk in response.timeout(const Duration(seconds: 30))) {
      if (isCancelled()) throw const _Cancelled();
      sink.add(chunk);
      received += chunk.length;
      onProgress(received, total);
    }
    await sink.flush();
    await sink.close();
    sink = null;
    if (total > 0 && received != total) throw const HttpException('Download incomplete, please try again');
    await part.rename(target.path);
    return target;
  } catch (_) {
    try {
      await sink?.close();
    } catch (_) {}
    if (part.existsSync()) part.deleteSync();
    rethrow;
  } finally {
    client.close(force: true);
  }
}

Future<_Install> _install(String path) async {
  try {
    switch (await _channel.invokeMethod<String>('installApk', {'path': path})) {
      case 'started':
        return _Install.started;
      case 'permission':
        return _Install.needsPermission;
      default:
        return _Install.failed;
    }
  } catch (_) {
    return _Install.failed;
  }
}
