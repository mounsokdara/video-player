import 'dart:async';

import 'android_bridge.dart';
import 'settings.dart';

class DeveloperLog {
  DeveloperLog._();
  static final lines = <String>[];
  static const _max = 240;

  static void append(String msg) {
    if (!appSettings.developerEnabled || !appSettings.debugLog) return;
    final line = '${DateTime.now().toIso8601String()}  $msg';
    lines.add(line);
    if (lines.length > _max) lines.removeAt(0);
    unawaited(AndroidBridge.debugLog(line));
  }

  static String get text {
    if (lines.isEmpty) return 'No debug lines yet. Turn on Log debug and use the player.';
    return lines.join('\n');
  }

  static void clear() {
    lines.clear();
    unawaited(AndroidBridge.debugLog('__clear__'));
  }
}
