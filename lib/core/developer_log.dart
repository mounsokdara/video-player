import 'dart:async';

import 'package:video_player_app/native/android_bridge.dart';
import 'package:video_player_app/settings/settings.dart';

class DeveloperLog {
  DeveloperLog._();
  static final lines = <String>[];
  static const _max = 600;

  static void append(String msg) {
    if (!appSettings.developerEnabled || !appSettings.debugLog) return;
    final line = '${DateTime.now().toIso8601String()}  $msg';
    lines.add(line);
    if (lines.length > _max) lines.removeAt(0);
    unawaited(AndroidBridge.debugLog(line));
  }

  static void player(String msg) {
    if (!appSettings.logPlayerEvents) return;
    append('[PLAYER] $msg');
  }

  static void gesture(String msg) {
    if (!appSettings.logGestureEvents) return;
    append('[GESTURE] $msg');
  }

  static void lifecycle(String msg) {
    if (!appSettings.logLifecycleEvents) return;
    append('[LIFECYCLE] $msg');
  }

  static String get text {
    if (lines.isEmpty) return 'No debug lines yet. Turn on Log debug and use the player.';
    return lines.join('\n');
  }

  static void clear() {
    lines.clear();
    unawaited(AndroidBridge.clearLogs());
  }
}
