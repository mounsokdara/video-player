import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

const _channel = MethodChannel('app.videoplayer/android');

enum _Install { started, needsPermission, failed }

class _Cancelled implements Exception {
  const _Cancelled();
}

/// Downloads [url] inside the app and opens the system installer, no browser.
/// Errors and the unknown-sources prompt are shown in a dialog with Try again.
Future<void> downloadAndInstallApk(BuildContext context, String url) async {
  while (context.mounted) {
    final progress = ValueNotifier<double?>(null);
    var cancelled = false;
    final rootNav = Navigator.of(context, rootNavigator: true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('Downloading update'),
          content: ValueListenableBuilder<double?>(
            valueListenable: progress,
            builder: (_, v, _) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              LinearProgressIndicator(value: v),
              const SizedBox(height: 12),
              Text(v == null ? 'Starting...' : '${(v * 100).round()}%'),
            ]),
          ),
          actions: [TextButton(onPressed: () => cancelled = true, child: const Text('Cancel'))],
        ),
      ),
    );

    String? error;
    _Install? result;
    try {
      final file = await _download(url, (v) => progress.value = v, () => cancelled);
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

Future<File> _download(String url, void Function(double?) onProgress, bool Function() isCancelled) async {
  final dir = Directory('${(await getTemporaryDirectory()).path}/updates');
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  dir.createSync(recursive: true);
  final target = File('${dir.path}/update.apk');
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
      onProgress(total > 0 ? received / total : null);
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
