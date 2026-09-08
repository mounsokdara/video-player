import 'package:flutter/services.dart';

import 'models.dart';

class AndroidBridge {
  AndroidBridge._();
  static const _ch = MethodChannel('app.videoplayer/android');
  static const _ev = EventChannel('app.videoplayer/events');

  static Stream<Map<String, dynamic>> events() {
    return _ev.receiveBroadcastStream().map((e) {
      if (e is Map) return Map<String, dynamic>.from(e);
      return <String, dynamic>{'type': '$e'};
    });
  }

  static Future<bool> hasAllFilesAccess() async {
    try {
      return await _ch.invokeMethod<bool>('hasAllFilesAccess') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> requestAllFilesAccess() async {
    try {
      await _ch.invokeMethod('requestAllFilesAccess');
    } catch (_) {}
  }

  static Future<List<StorageVolumeInfo>> listStorageVolumes() async {
    try {
      final raw = await _ch.invokeMethod<List<dynamic>>('listStorageVolumes') ?? [];
      return raw.map((e) {
        final m = Map<String, dynamic>.from(e as Map);
        return StorageVolumeInfo(
          path: m['path'] as String? ?? '',
          description: m['description'] as String? ?? 'Storage',
          isPrimary: m['isPrimary'] as bool? ?? false,
          isRemovable: m['isRemovable'] as bool? ?? false,
          isSd: m['isSd'] as bool? ?? false,
          isUsb: m['isUsb'] as bool? ?? false,
          state: m['state'] as String? ?? 'mounted',
        );
      }).where((v) => v.path.isNotEmpty).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<List<Map<String, dynamic>>> listVideoFiles(String path) async {
    try {
      final raw = await _ch.invokeMethod<List<dynamic>>('listVideoFiles', {'path': path}) ?? [];
      return raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<bool> deletePath(String path) async {
    try {
      return await _ch.invokeMethod<bool>('deletePath', {'path': path}) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<String?> renamePath(String path, String name) async {
    try {
      return await _ch.invokeMethod<String>('renamePath', {'path': path, 'name': name});
    } catch (_) {
      return null;
    }
  }

  static Future<void> setOrientation(String mode) async {
    try {
      await _ch.invokeMethod('setOrientation', {'mode': mode});
    } catch (_) {}
  }

  static Future<void> setKeepScreenOn(bool on) async {
    try {
      await _ch.invokeMethod('setKeepScreenOn', {'on': on});
    } catch (_) {}
  }

  static Future<void> enterPip() async {
    try {
      await _ch.invokeMethod('enterPip');
    } catch (_) {}
  }

  static Future<void> setPipEnabled(bool on) async {
    try {
      await _ch.invokeMethod('setPipEnabled', {'on': on});
    } catch (_) {}
  }

  static Future<void> setPlaying(bool on) async {
    try {
      await _ch.invokeMethod('setPlaying', {'on': on});
    } catch (_) {}
  }

  static Future<Map<String, dynamic>?> initEqualizer(int sessionId) async {
    try {
      final raw = await _ch.invokeMethod('initEqualizer', {'sessionId': sessionId});
      if (raw is Map) return Map<String, dynamic>.from(raw);
    } catch (_) {}
    return null;
  }

  static Future<void> setEqBand(int band, int level) async {
    try {
      await _ch.invokeMethod('setEqBand', {'band': band, 'level': level});
    } catch (_) {}
  }

  static Future<void> setEqBands(List<int> levels) async {
    try {
      await _ch.invokeMethod('setEqBands', {'levels': levels});
    } catch (_) {}
  }

  static Future<void> setEqPreset(int preset) async {
    try {
      await _ch.invokeMethod('setEqPreset', {'preset': preset});
    } catch (_) {}
  }

  static Future<void> setEqEnabled(bool on) async {
    try {
      await _ch.invokeMethod('setEqEnabled', {'on': on});
    } catch (_) {}
  }

  static Future<void> setBassBoost({required bool on, required int strength}) async {
    try {
      await _ch.invokeMethod('setBassBoost', {'on': on, 'strength': strength});
    } catch (_) {}
  }

  static Future<void> setSurround({required bool on, required int strength}) async {
    try {
      await _ch.invokeMethod('setVirtualizer', {'on': on, 'strength': strength});
    } catch (_) {}
  }

  static Future<void> setPlaybackParams({required double speed, required bool pitchShift}) async {
    try {
      await _ch.invokeMethod('setPlaybackParams', {
        'speed': speed,
        'pitchShift': pitchShift,
      });
    } catch (_) {}
  }

  static Future<void> startBackground({
    required String title,
    String? artist,
    bool playing = true,
    int positionMs = 0,
    int durationMs = 0,
  }) async {
    try {
      await _ch.invokeMethod('startBackground', {
        'title': title,
        'artist': artist ?? 'Video Player',
        'playing': playing,
        'positionMs': positionMs,
        'durationMs': durationMs,
      });
    } catch (_) {}
  }

  static Future<void> updateBackground({
    required bool playing,
    int? positionMs,
    int? durationMs,
    String? title,
  }) async {
    try {
      await _ch.invokeMethod('updateBackground', {
        'playing': playing,
        if (positionMs != null) 'positionMs': positionMs,
        if (durationMs != null) 'durationMs': durationMs,
        if (title != null) 'title': title,
      });
    } catch (_) {}
  }

  static Future<void> stopBackground() async {
    try {
      await _ch.invokeMethod('stopBackground');
    } catch (_) {}
  }

  static Future<String?> screenshot({required String path, required int positionMs, String? title}) async {
    try {
      return await _ch.invokeMethod<String>('screenshot', {
        'path': path,
        'positionMs': positionMs,
        'title': title ?? 'frame',
      });
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, dynamic>?> mediaInfo(String path) async {
    try {
      final raw = await _ch.invokeMethod('mediaInfo', {'path': path});
      if (raw is Map) return Map<String, dynamic>.from(raw);
    } catch (_) {}
    return null;
  }

  static Future<String?> pendingOpen() async {
    try {
      return await _ch.invokeMethod<String>('pendingOpen');
    } catch (_) {
      return null;
    }
  }

  static Future<void> toast(String msg) async {
    try {
      await _ch.invokeMethod('toast', {'msg': msg});
    } catch (_) {}
  }
}
