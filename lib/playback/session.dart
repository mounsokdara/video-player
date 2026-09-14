import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'package:video_player_app/native/android_bridge.dart';
import 'package:video_player_app/core/crash.dart';
import 'package:video_player_app/playback/engine.dart';
import 'package:video_player_app/core/models.dart';
import 'package:video_player_app/settings/settings.dart';

class MiniMemory {
  MiniMemory._();
  static double w = 216;
  static double? dx;
  static double? dy;
  static bool parked = false;
  static int parkSide = 0;

  static void reset() {
    w = 216;
    dx = null;
    dy = null;
    parked = false;
    parkSide = 0;
  }
}

class PlaybackSession {
  static PlaybackEngine? controller;
  static VideoItem? item;
  static List<VideoItem> playlist = [];
  static int index = 0;
  static bool keepAlive = false;
  static bool transferring = false;
  static double speed = 1;
  static AspectMode aspect = AspectMode.fit;
  static VoidCallback? onMutated;
  static Timer? sleepTimer;
  static Duration? sleepLeft;

  static bool _endedLatch = false;
  static bool _busy = false;
  static int _failStreak = 0;
  static VoidCallback? _hook;

  static const _endSlop = Duration(milliseconds: 400);
  static const _replayAfter = Duration(seconds: 3);

  static bool get active => keepAlive && controller != null && item != null;

  static String _hwdec({bool forceSoftware = false}) {
    if (forceSoftware || appSettings.decoder == DecoderMode.sw || !appSettings.hwPriority) {
      return 'no';
    }
    if (appSettings.decoder == DecoderMode.hw) return 'mediacodec';
    return 'auto';
  }

  static Future<PlaybackEngine> openWithFallback(VideoItem next, {bool forceSoftware = false}) async {
    try {
      return await _openOnce(next.path, hwdec: _hwdec(forceSoftware: forceSoftware));
    } catch (e, s) {
      if (forceSoftware || _hwdec(forceSoftware: forceSoftware) == 'no') {
        CrashLog.record('PLAY', '$e', s);
        rethrow;
      }
      try {
        return await _openOnce(next.path, hwdec: 'no');
      } catch (e2, s2) {
        CrashLog.record('PLAY', '$e2', s2);
        rethrow;
      }
    }
  }

  static Future<PlaybackEngine> _openOnce(String path, {required String hwdec}) async {
    final c = PlaybackEngine();
    try {
      await c.open(path, hwdec: hwdec);
      if (c.value.hasError) {
        throw StateError(c.value.errorDescription ?? 'Source error');
      }
      return c;
    } catch (e) {
      try {
        await c.close();
      } catch (_) {}
      rethrow;
    }
  }

  static void _listen() {
    _unlisten();
    final c = controller;
    if (c == null) return;
    void hook() => _onTick();
    _hook = hook;
    c.addListener(hook);
  }

  static void _unlisten() {
    final h = _hook;
    if (h != null) {
      try {
        controller?.removeListener(h);
      } catch (_) {}
    }
    _hook = null;
  }

  static void _onTick() {
    if (!keepAlive || _busy) return;
    final c = controller;
    if (c == null) return;
    try {
      if (c.value.hasError) {
        unawaited(_onSourceError(c.value.errorDescription));
        return;
      }
      if (c.value.completed) {
        unawaited(onEnded());
        return;
      }
      if (!c.value.isInitialized) return;
      final dur = c.value.duration;
      if (dur > Duration.zero && c.value.position >= dur - _endSlop && !c.value.isPlaying) {
        unawaited(onEnded());
      }
    } catch (e, s) {
      CrashLog.record('SESSION', '$e', s);
    }
  }

  static Future<void> _onSourceError(String? desc) async {
    if (_busy || !keepAlive) return;
    final current = item;
    final text = desc ?? '';
    if (current != null && _hwdec() != 'no') {
      await CrashLog.breadcrumb('Retry software decoder ${current.path}');
      final list = playlist;
      final at = index;
      final ok = await swapTo(current, list: list, at: at, forceSoftware: true);
      if (ok) return;
    }
    await CrashLog.breadcrumb('Source error ${item?.path}: $text');
    await skip(1, fromError: true);
    if (_failStreak >= playlist.length) {
      CrashLog.record('PLAY', text.isEmpty ? 'Source error' : text, null);
    }
  }

  static void claim({
    required PlaybackEngine c,
    required VideoItem item,
    required List<VideoItem> list,
    required int at,
    required double speed,
    required AspectMode aspect,
  }) {
    controller = c;
    PlaybackSession.item = item;
    playlist = List<VideoItem>.from(list);
    index = at;
    PlaybackSession.speed = speed;
    PlaybackSession.aspect = aspect;
    keepAlive = true;
    _endedLatch = false;
    _failStreak = 0;
    _listen();
  }

  static PlaybackEngine? take() {
    _unlisten();
    keepAlive = false;
    transferring = false;
    _endedLatch = false;
    return controller;
  }

  static Future<void> stop() async {
    keepAlive = false;
    _unlisten();
    _endedLatch = false;
    _busy = false;
    _failStreak = 0;
    sleepTimer?.cancel();
    sleepTimer = null;
    sleepLeft = null;
    MiniMemory.reset();
    final dying = controller;
    controller = null;
    item = null;
    playlist = [];
    onMutated?.call();
    await Future<void>.delayed(Duration.zero);
    try {
      await dying?.pause();
    } catch (_) {}
    try {
      await dying?.close();
    } catch (_) {}
    await AndroidBridge.stopBackground();
    await AndroidBridge.abandonAudioFocus();
  }

  static void armSleep(Duration total) {
    sleepTimer?.cancel();
    sleepLeft = total;
    sleepTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      final left = sleepLeft;
      if (left == null) {
        t.cancel();
        return;
      }
      final next = left - const Duration(seconds: 1);
      if (next <= Duration.zero) {
        t.cancel();
        sleepTimer = null;
        sleepLeft = null;
        unawaited(_onSleepFire());
        return;
      }
      sleepLeft = next;
      onMutated?.call();
    });
  }

  static void cancelSleep() {
    sleepTimer?.cancel();
    sleepTimer = null;
    sleepLeft = null;
    onMutated?.call();
  }

  static Future<void> _onSleepFire() async {
    try {
      await controller?.pause();
    } catch (_) {}
    await stop();
    try {
      appNavigator.currentState?.popUntil((r) => r.isFirst);
    } catch (_) {}
  }

  static void pauseForBackground() {
    if (appSettings.backgroundPlay) return;
    final c = controller;
    if (c == null) return;
    try {
      if (c.value.isPlaying) {
        unawaited(c.pause());
        unawaited(AndroidBridge.stopBackground());
      }
    } catch (_) {}
  }

  static Future<void> keepBackgroundAlive() async {
    if (!appSettings.backgroundPlay || !active) return;
    final c = controller;
    final next = item;
    if (c == null || next == null) return;
    await AndroidBridge.startBackground(
      title: next.title,
      artist: next.folderName,
      playing: c.value.isPlaying,
      positionMs: c.value.position.inMilliseconds,
      durationMs: c.value.duration.inMilliseconds,
    );
  }

  static Future<void> applyOutput(PlaybackEngine c, VideoItem next) async {
    try {
      await c.setLooping(appSettings.playMode == PlayMode.repeatOne);
    } catch (_) {}
    try {
      await c.setPlaybackSpeed(speed);
    } catch (_) {}
    await AndroidBridge.setPlaybackParams(speed: speed, pitchShift: appSettings.pitchShift);
    await AndroidBridge.applyEqualizer(
      enabled: appSettings.eqEnabled,
      bands: appSettings.eqBands,
      bassOn: appSettings.bassBoostOn,
      bass: appSettings.bassBoost,
      surroundOn: appSettings.surroundOn,
      surround: appSettings.surround,
    );
    await AndroidBridge.setStereoVolume(appSettings.audioBalanceLeft, appSettings.audioBalanceRight);
    if (appSettings.backgroundPlay) {
      await AndroidBridge.startBackground(
        title: next.title,
        artist: next.folderName,
        playing: c.value.isPlaying,
        positionMs: c.value.position.inMilliseconds,
        durationMs: c.value.duration.inMilliseconds,
      );
    }
  }

  static Future<void> onEnded() async {
    if (_endedLatch || _busy || !keepAlive) return;
    _endedLatch = true;
    switch (appSettings.playMode) {
      case PlayMode.repeatOne:
        try {
          await controller?.seekTo(Duration.zero);
          await controller?.play();
        } catch (_) {}
        _endedLatch = false;
      case PlayMode.noAutoplay:
        return;
      case PlayMode.loopAll:
      case PlayMode.order:
      case PlayMode.shuffle:
        if (appSettings.autoPlayNext ||
            appSettings.playMode == PlayMode.loopAll ||
            appSettings.playMode == PlayMode.shuffle) {
          await skip(1, fromEnd: true);
        }
    }
  }

  static int nextIndex({required int delta}) {
    final list = playlist;
    if (list.isEmpty) return index;
    final mode = appSettings.playMode;
    if (delta > 0) {
      if (mode == PlayMode.shuffle) {
        if (list.length == 1) return 0;
        var n = math.Random().nextInt(list.length);
        if (n == index) n = (n + 1) % list.length;
        return n;
      }
      if (index >= list.length - 1) {
        return mode == PlayMode.loopAll ? 0 : index;
      }
      return index + 1;
    }
    if (index > 0) return index - 1;
    return mode == PlayMode.loopAll ? list.length - 1 : 0;
  }

  static Future<void> skip(int delta, {bool fromEnd = false, bool fromError = false}) async {
    if (_busy) return;
    if (controller == null && item == null) return;
    final list = playlist;
    if (list.isEmpty) return;

    if (delta < 0 && !fromEnd && !fromError) {
      final pos = controller?.value.position ?? Duration.zero;
      if (pos > _replayAfter) {
        try {
          await controller?.seekTo(Duration.zero);
          if (!(controller?.value.isPlaying ?? false)) await controller?.play();
        } catch (_) {}
        return;
      }
    }

    var next = nextIndex(delta: delta);
    if (fromError && next == index && list.length > 1) {
      next = (index + 1) % list.length;
    }
    if (next == index && !fromError) return;
    if (fromError) {
      _failStreak++;
      if (_failStreak >= list.length) return;
    } else {
      _failStreak = 0;
    }
    final ok = await swapTo(list[next], list: list, at: next);
    if (!ok && list.length > 1 && _failStreak < list.length) {
      await skip(1, fromError: true);
    }
  }

  static Future<bool> swapTo(VideoItem next, {required List<VideoItem> list, required int at, bool forceSoftware = false}) async {
    if (_busy) return false;
    _busy = true;
    _endedLatch = true;
    final old = controller;
    _unlisten();
    PlaybackEngine? c;
    try {
      c = await openWithFallback(next, forceSoftware: forceSoftware);
      await AndroidBridge.requestAudioFocus();
      await c.play();
      controller = c;
      item = next;
      playlist = List<VideoItem>.from(list);
      index = at;
      keepAlive = true;
      _endedLatch = false;
      _failStreak = 0;
      _listen();
      onMutated?.call();
      await AndroidBridge.preparePreview(next.path);
      await applyOutput(c, next);
      await Future<void>.delayed(Duration.zero);
      try {
        await old?.close();
      } catch (_) {}
      return true;
    } catch (e, s) {
      CrashLog.record('PLAY', '$e', s);
      try {
        await c?.close();
      } catch (_) {}
      controller = old;
      keepAlive = old != null;
      if (old != null) _listen();
      return false;
    } finally {
      _busy = false;
    }
  }
}
