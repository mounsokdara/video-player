import 'package:flutter/services.dart';

import 'models.dart';

class AndroidBridge {
  AndroidBridge._();
  static const _ch = MethodChannel('app.videoplayer/android');

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

  static Future<void> setEqPreset(int preset) async {
    try {
      await _ch.invokeMethod('setEqPreset', {'preset': preset});
    } catch (_) {}
  }

  static Future<void> startBackground(String title) async {
    try {
      await _ch.invokeMethod('startBackground', {'title': title});
    } catch (_) {}
  }

  static Future<void> stopBackground() async {
    try {
      await _ch.invokeMethod('stopBackground');
    } catch (_) {}
  }

  static Future<void> toast(String msg) async {
    try {
      await _ch.invokeMethod('toast', {'msg': msg});
    } catch (_) {}
  }
}
