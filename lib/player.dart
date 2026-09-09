import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:share_plus/share_plus.dart';
import 'package:vibration/vibration.dart';
import 'package:video_player/video_player.dart';
import 'package:volume_controller/volume_controller.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'android_bridge.dart';
import 'crash.dart';
import 'library.dart';
import 'main.dart';
import 'models.dart';
import 'settings.dart';
import 'settings_ui.dart';
import 'widgets.dart';

class PlaybackSession {
  static VideoPlayerController? controller;
  static VideoItem? item;
  static List<VideoItem> playlist = [];
  static int index = 0;
  static bool keepAlive = false;
  static double speed = 1;
  static AspectMode aspect = AspectMode.fit;

  static bool get active => keepAlive && controller != null && item != null;

  static Future<void> stop() async {
    keepAlive = false;
    try {
      await controller?.pause();
    } catch (_) {}
    try {
      controller?.removeListener(() {});
      await controller?.dispose();
    } catch (_) {}
    controller = null;
    item = null;
    playlist = [];
    await AndroidBridge.stopBackground();
  }
}

class _Burst {
  _Burst({required this.id, required this.pos, required this.label, required this.icon});
  final int id;
  final Offset pos;
  final String label;
  final IconData icon;
}

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key, required this.playlist, required this.index, required this.onChanged});
  final List<VideoItem> playlist;
  final int index;
  final VoidCallback onChanged;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> with WidgetsBindingObserver {
  late int index;
  VideoPlayerController? vc;
  bool ready = false;
  bool showUi = true;
  bool locked = false;
  Timer? hideTimer;
  double brightness = 0.5;
  double volume = 0.5;
  String overlay = '';
  Timer? overlayTimer;
  bool speeding = false;
  double? abA;
  double? abB;
  Timer? sleepTimer;
  Duration? sleepLeft;
  Timer? clockTimer;
  Timer? persistTimer;
  DateTime now = DateTime.now();
  int battery = 100;
  bool hdr = true;
  late AspectMode aspect;
  double speed = 1;
  Offset? panStart;
  String panKind = '';
  double panBase = 0;
  bool night = false;
  bool mirror = false;
  bool invert = false;
  bool _lastPlaying = false;
  DateTime _lastUi = DateTime.fromMillisecondsSinceEpoch(0);
  final bursts = <_Burst>[];
  int _burstSeq = 0;
  final zoom = TransformationController();
  StreamSubscription<Map<String, dynamic>>? events;

  VideoItem get item => widget.playlist[index];
  List<VideoItem> get list => widget.playlist;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    index = widget.index.clamp(0, widget.playlist.length - 1);
    aspect = appSettings.aspect;
    speed = appSettings.rememberSpeed ? appSettings.speed : 1;
    hdr = appSettings.rememberHdr ? appSettings.hdrOn : true;
    night = appSettings.nightMode;
    mirror = appSettings.mirror;
    invert = appSettings.invertColors;
    bool kept = false;
    try {
      kept = PlaybackSession.active &&
          PlaybackSession.controller != null &&
          PlaybackSession.controller!.value.isInitialized &&
          PlaybackSession.item?.path == widget.playlist[index].path;
    } catch (_) {
      kept = false;
    }
    if (kept) {
      vc = PlaybackSession.controller;
      ready = true;
      speed = PlaybackSession.speed;
      aspect = PlaybackSession.aspect;
      PlaybackSession.keepAlive = false;
      vc?.addListener(_tick);
      _lastPlaying = vc?.value.isPlaying ?? false;
      _applySystemUi();
      _applyRotation();
      _applySpeed();
      _syncBackground();
      _armHide();
    } else {
      if (PlaybackSession.controller != null && PlaybackSession.controller != vc) {
        PlaybackSession.stop();
      }
      _boot();
    }
    clockTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      setState(() => now = DateTime.now());
      Battery().batteryLevel.then((v) {
        if (mounted) setState(() => battery = v);
      });
    });
    persistTimer = Timer.periodic(const Duration(seconds: 4), (_) => _persistProgress());
    events = AndroidBridge.events().listen((e) {
      if (e['type'] == 'media') {
        switch (e['action']) {
          case 'play':
            vc?.play();
          case 'pause':
            vc?.pause();
          case 'next':
            _next();
          case 'prev':
            _prev();
        }
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      _persistProgress();
      if (!appSettings.backgroundPlay) {
        vc?.pause();
        AndroidBridge.stopBackground();
      } else {
        _syncBackground();
      }
    } else if (state == AppLifecycleState.resumed) {
      _applySystemUi();
      if (appSettings.backgroundPlay) _syncBackground();
    }
  }

  Future<void> _boot() async {
    await WakelockPlus.enable();
    await AndroidBridge.setKeepScreenOn(true);
    await AndroidBridge.setPlaying(false);
    await AndroidBridge.setPipEnabled(false);
    _applySystemUi();
    _applyRotation();
    try {
      brightness = await ScreenBrightness().application;
    } catch (_) {}
    try {
      VolumeController.instance.showSystemUI = false;
      volume = await VolumeController.instance.getVolume();
    } catch (_) {}
    if (appSettings.rememberBrightness && appSettings.brightness >= 0) {
      brightness = appSettings.brightness;
      try {
        await ScreenBrightness().setApplicationScreenBrightness(brightness);
      } catch (_) {}
    }
    await _openCurrent();
  }

  void _applyRotation() {
    final m = switch (appSettings.rotation) {
      RotationLock.auto => 'auto',
      RotationLock.autoVideo => 'auto',
      RotationLock.landscape => 'landscape',
      RotationLock.portrait => 'portrait',
      RotationLock.landscapeNormal => 'landscape_normal',
      RotationLock.landscapeReverse => 'landscape_reverse',
      RotationLock.portraitNormal => 'portrait_normal',
      RotationLock.portraitReverse => 'portrait_reverse',
      RotationLock.locked => 'locked',
    };
    AndroidBridge.setOrientation(m);
  }

  void _applySystemUi() {
    final hide = appSettings.alwaysHideNavBar || !showUi || locked;
    if (hide) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarContrastEnforced: false,
        systemStatusBarContrastEnforced: false,
      ));
    }
  }

  void _syncPip() {
    final playing = vc?.value.isPlaying ?? false;
    AndroidBridge.setPlaying(playing);
    AndroidBridge.setPipEnabled(appSettings.autoMiniplayer && playing);
  }

  Future<void> _applySpeed() async {
    final rate = speeding ? 2.0 : speed;
    try {
      await vc?.setPlaybackSpeed(rate);
    } catch (e, s) {
      CrashLog.record('SPEED', '$e', s);
    }
  }

  Future<void> _syncBackground() async {
    if (!appSettings.backgroundPlay) {
      await AndroidBridge.stopBackground();
      return;
    }
    final c = vc;
    await AndroidBridge.startBackground(
      title: item.title,
      artist: item.folderName,
      playing: c?.value.isPlaying ?? false,
      positionMs: c?.value.position.inMilliseconds ?? 0,
      durationMs: c?.value.duration.inMilliseconds ?? 0,
    );
    await AndroidBridge.updateBackground(
      playing: c?.value.isPlaying ?? false,
      positionMs: c?.value.position.inMilliseconds ?? 0,
      durationMs: c?.value.duration.inMilliseconds ?? 0,
      title: item.title,
    );
  }

  Future<void> _persistProgress() async {
    final c = vc;
    if (c == null || !c.value.isInitialized) return;
    final dur = c.value.duration.inMilliseconds;
    if (dur <= 0) return;
    final p = (c.value.position.inMilliseconds / dur).clamp(0.0, 1.0).toDouble();
    item.progress = p;
    appSettings.resumeMap[item.path] = p;
    await appSettings.save();
  }

  Future<void> _openCurrent() async {
    try {
      await vc?.dispose();
    } catch (_) {}
    try {
      zoom.value = Matrix4.identity();
    } catch (_) {}
    if (mounted) {
      setState(() {
        ready = false;
        vc = null;
      });
    }
    VideoPlayerController? c;
    try {
      await CrashLog.breadcrumb('Open video ${item.path}');
      final file = File(item.path);
      if (!file.existsSync()) {
        if (mounted) {
          setState(() => ready = false);
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('File not found: ${item.title}')));
        }
        return;
      }
      c = VideoPlayerController.file(
        file,
        videoPlayerOptions: VideoPlayerOptions(
          mixWithOthers: true,
          allowBackgroundPlayback: appSettings.backgroundPlay,
        ),
      );
      vc = c;
      await c.initialize();
      await CrashLog.breadcrumb('Initialized ${item.title}');
      if (!mounted || vc != c) {
        try {
          await c.dispose();
        } catch (_) {}
        return;
      }
      if (appSettings.resumePlayback) {
        final p = appSettings.resumeMap[item.path] ?? item.progress;
        final dur = c.value.duration;
        if (p > 0 && p < 0.97 && dur.inMilliseconds > 0) {
          await c.seekTo(Duration(milliseconds: (dur.inMilliseconds * p).round()));
        }
      }
      c.addListener(_tick);
      c.setLooping(appSettings.playMode == PlayMode.repeatOne);
      await c.play();
      _lastPlaying = true;
      _syncPip();
      await _syncBackground();
      await _applySpeed();
      if (mounted) setState(() => ready = true);
      _armHide();
      if (appSettings.eqEnabled) {
        try {
          await Future<void>.delayed(const Duration(milliseconds: 400));
          await AndroidBridge.initEqualizer(0);
          await AndroidBridge.setEqEnabled(true);
          await AndroidBridge.setEqBands(appSettings.eqBands);
          await AndroidBridge.setBassBoost(on: appSettings.bassBoostOn, strength: appSettings.bassBoost);
          await AndroidBridge.setSurround(on: appSettings.surroundOn, strength: appSettings.surround);
        } catch (e, s) {
          CrashLog.record('EQ', '$e', s);
        }
      }
    } catch (e, s) {
      CrashLog.record('PLAY', '$e', s);
      try {
        await c?.dispose();
      } catch (_) {}
      vc = null;
      if (mounted) {
        setState(() => ready = false);
      }
    }
  }

  void _tick() {
    final c = vc;
    if (c == null || !mounted) return;
    try {
      if (!c.value.isInitialized) return;
      final pos = c.value.position.inMilliseconds.toDouble();
      final dur = c.value.duration.inMilliseconds.toDouble().clamp(1, double.infinity);
      final p = (pos / dur).clamp(0.0, 1.0).toDouble();
      item.progress = p;
      appSettings.resumeMap[item.path] = p;
      if (abA != null && abB != null && pos / 1000 >= abB!) {
        c.seekTo(Duration(milliseconds: (abA! * 1000).round()));
      }
      final playing = c.value.isPlaying;
      if (playing != _lastPlaying) {
        _lastPlaying = playing;
        _syncPip();
        _syncBackground();
      }
      if (c.value.position >= c.value.duration - const Duration(milliseconds: 400) && !c.value.isPlaying) {
        _onEnded();
      }
      final nowTick = DateTime.now();
      if (nowTick.difference(_lastUi) >= const Duration(milliseconds: 120)) {
        _lastUi = nowTick;
        setState(() {});
      }
    } catch (e, s) {
      CrashLog.record('TICK', '$e', s);
    }
  }

  Future<void> _onEnded() async {
    switch (appSettings.playMode) {
      case PlayMode.repeatOne:
        await vc?.seekTo(Duration.zero);
        await vc?.play();
      case PlayMode.noAutoplay:
        return;
      case PlayMode.loopAll:
      case PlayMode.order:
      case PlayMode.shuffle:
        if (appSettings.autoPlayNext || appSettings.playMode == PlayMode.loopAll || appSettings.playMode == PlayMode.shuffle) {
          await _next();
        }
    }
  }

  Future<void> _next() async {
    if (list.isEmpty) return;
    if (appSettings.playMode == PlayMode.shuffle) {
      index = math.Random().nextInt(list.length);
    } else {
      if (index >= list.length - 1) {
        if (appSettings.playMode == PlayMode.loopAll) {
          index = 0;
        } else {
          return;
        }
      } else {
        index += 1;
      }
    }
    await _openCurrent();
  }

  Future<void> _prev() async {
    if ((vc?.value.position ?? Duration.zero) > const Duration(seconds: 3)) {
      await vc?.seekTo(Duration.zero);
      return;
    }
    if (index > 0) {
      index -= 1;
      await _openCurrent();
    }
  }

  void _setUi(bool on) {
    setState(() => showUi = on);
    _applySystemUi();
    if (on) _armHide();
  }

  void _armHide() {
    hideTimer?.cancel();
    if (locked) return;
    hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && (vc?.value.isPlaying ?? false) && !locked) {
        _setUi(false);
      }
    });
  }

  void _flash(String text) {
    setState(() => overlay = text);
    overlayTimer?.cancel();
    overlayTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => overlay = '');
    });
  }

  void _ripple(Offset pos, String label, IconData icon) {
    final burst = _Burst(id: _burstSeq++, pos: pos, label: label, icon: icon);
    setState(() => bursts.add(burst));
    Future.delayed(const Duration(milliseconds: 520), () {
      if (mounted) setState(() => bursts.removeWhere((b) => b.id == burst.id));
    });
  }

  Future<void> _seekBy(int seconds) async {
    final c = vc;
    if (c == null) return;
    final next = c.value.position + Duration(seconds: seconds);
    final d = c.value.duration;
    await c.seekTo(next < Duration.zero ? Duration.zero : (next > d ? d : next));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    hideTimer?.cancel();
    overlayTimer?.cancel();
    clockTimer?.cancel();
    persistTimer?.cancel();
    sleepTimer?.cancel();
    events?.cancel();
    vc?.removeListener(_tick);
    _persistProgress();
    var keep = false;
    try {
      keep = appSettings.backgroundPlay && (vc?.value.isPlaying ?? false);
    } catch (_) {
      keep = false;
    }
    if (keep && vc != null) {
      PlaybackSession.keepAlive = true;
      PlaybackSession.controller = vc;
      PlaybackSession.item = item;
      PlaybackSession.playlist = List<VideoItem>.from(list);
      PlaybackSession.index = index;
      PlaybackSession.speed = speed;
      PlaybackSession.aspect = aspect;
      _syncBackground();
    } else {
      PlaybackSession.keepAlive = false;
      vc?.dispose();
      AndroidBridge.stopBackground();
    }
    zoom.dispose();
    WakelockPlus.disable();
    AndroidBridge.setKeepScreenOn(false);
    AndroidBridge.setPlaying(false);
    AndroidBridge.setPipEnabled(false);
    AndroidBridge.setOrientation('auto');
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = vc;
    final size = MediaQuery.sizeOf(context);
    final pad = MediaQuery.paddingOf(context);
    final insets = MediaQuery.viewInsetsOf(context);
    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: true,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (locked) return;
          _setUi(!showUi);
        },
        onDoubleTapDown: (d) {
          if (locked) return;
          final x = d.localPosition.dx;
          if (x < size.width * 0.33 && appSettings.doubleTapSeek) {
            _ripple(d.localPosition, '-${appSettings.seekStepSeconds}s', Icons.replay);
            _seekBy(-appSettings.seekStepSeconds);
          } else if (x > size.width * 0.67 && appSettings.doubleTapSeek) {
            _ripple(d.localPosition, '+${appSettings.seekStepSeconds}s', Icons.forward);
            _seekBy(appSettings.seekStepSeconds);
          } else {
            final playing = vc?.value.isPlaying ?? false;
            _ripple(d.localPosition, playing ? 'Paused' : 'Playing', playing ? Icons.pause : Icons.play_arrow);
            _togglePlay();
          }
        },
        onLongPressStart: (_) async {
          if (locked || !appSettings.longPress2x || c == null) return;
          speeding = true;
          await _applySpeed();
          if (appSettings.longPressVibration) {
            try {
              if (await Vibration.hasVibrator()) Vibration.vibrate(duration: 20);
            } catch (_) {}
          }
          setState(() {});
        },
        onLongPressEnd: (_) async {
          if (!speeding) return;
          speeding = false;
          await _applySpeed();
          setState(() {});
        },
        onPanStart: (d) {
          if (locked || !appSettings.gestureControl) return;
          panStart = d.localPosition;
          panKind = '';
        },
        onPanUpdate: (d) async {
          if (locked || !appSettings.gestureControl || panStart == null || c == null) return;
          final dx = d.localPosition.dx - panStart!.dx;
          final dy = d.localPosition.dy - panStart!.dy;
          if (panKind.isEmpty) {
            if (dx.abs() > 18 && dx.abs() > dy.abs()) {
              panKind = 'seek';
              panBase = c.value.position.inMilliseconds.toDouble();
            } else if (dy.abs() > 18) {
              panKind = panStart!.dx < size.width / 2 ? 'brightness' : 'volume';
              panBase = panKind == 'brightness' ? brightness : volume;
            } else {
              return;
            }
          }
          if (panKind == 'seek') {
            final dur = c.value.duration.inMilliseconds.toDouble().clamp(1, double.infinity);
            final delta = (dx / size.width) * dur * 0.6;
            final next = (panBase + delta).clamp(0, dur);
            await c.seekTo(Duration(milliseconds: next.round()));
            _flash(formatDuration(Duration(milliseconds: next.round())));
          } else if (panKind == 'brightness') {
            brightness = (panBase - dy / size.height).clamp(0.0, 1.0);
            try {
              await ScreenBrightness().setApplicationScreenBrightness(brightness);
            } catch (_) {}
            if (appSettings.rememberBrightness) {
              appSettings.brightness = brightness;
            }
            _flash('Brightness ${(brightness * 100).round()}%');
          } else if (panKind == 'volume') {
            volume = (panBase - dy / size.height).clamp(0.0, 1.0);
            try {
              await VolumeController.instance.setVolume(volume);
            } catch (_) {}
            _flash('Volume ${(volume * 100).round()}%');
          }
          setState(() {});
        },
        onPanEnd: (_) => panKind = '',
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(
              color: Colors.black,
              child: () {
                try {
                  if (ready && c != null && c.value.isInitialized) {
                    final w = size.width <= 0 ? 1.0 : size.width;
                    final h = size.height <= 0 ? 1.0 : size.height;
                    return _video(c, Size(w, h));
                  }
                } catch (_) {}
                return const Center(child: CircularProgressIndicator());
              }(),
            ),
            for (final b in bursts)
              Positioned(
                left: b.pos.dx - 72,
                top: b.pos.dy - 72,
                child: IgnorePointer(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0.15, end: 1),
                    duration: appSettings.reduceMotion ? Duration.zero : const Duration(milliseconds: 480),
                    builder: (_, t, child) {
                      return Opacity(
                        opacity: (1 - t).clamp(0, 1),
                        child: Transform.scale(scale: 0.7 + t * 0.7, child: child),
                      );
                    },
                    child: Container(
                      width: 144,
                      height: 144,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withValues(alpha: 0.16),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.35), width: 2),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(b.icon, color: Colors.white, size: 34),
                          const SizedBox(height: 4),
                          Text(b.label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            if (speeding)
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                  decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.72), borderRadius: BorderRadius.circular(999)),
                  child: const Text('2.0×', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: 0.4)),
                ),
              ),
            if (overlay.isNotEmpty && !speeding)
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
                  child: Text(overlay, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                ),
              ),
            if (locked)
              Positioned(
                right: 16 + pad.right,
                bottom: 24 + pad.bottom + insets.bottom,
                child: IconButton.filledTonal(
                  onPressed: () {
                    setState(() {
                      locked = false;
                      showUi = true;
                    });
                    _applySystemUi();
                    _armHide();
                  },
                  icon: const Icon(Icons.lock_open),
                ),
              ),
            if (showUi && !locked) ..._chrome(c, size),
          ],
        ),
      ),
    );
  }

  Widget _video(VideoPlayerController c, Size screen) {
    try {
      if (!c.value.isInitialized) {
        return const SizedBox.expand(child: Center(child: CircularProgressIndicator()));
      }
    } catch (_) {
      return const SizedBox.expand();
    }
    Widget player = VideoPlayer(c);
    player = _fit(player, c, screen);
    final w = screen.width <= 0 ? 1.0 : screen.width;
    final h = screen.height <= 0 ? 1.0 : screen.height;
    player = SizedBox(width: w, height: h, child: player);
    if (appSettings.allowZoom) {
      player = InteractiveViewer(
        transformationController: zoom,
        minScale: 1,
        maxScale: 5,
        panEnabled: false,
        scaleEnabled: true,
        child: player,
      );
    }
    if (mirror) player = Transform.flip(flipX: true, child: player);
    final filters = <ColorFilter>[];
    if (invert) filters.add(const ColorFilter.matrix(_invert));
    if (appSettings.grayscale || appSettings.monochrome) {
      filters.add(const ColorFilter.matrix(_gray));
    }
    if (appSettings.colorCorrection && (appSettings.contrast != 1 || appSettings.saturation != 1)) {
      filters.add(ColorFilter.matrix(_cs(appSettings.contrast, appSettings.saturation)));
    }
    if (appSettings.colorBlindDeuteranopia) filters.add(const ColorFilter.matrix(_deut));
    if (appSettings.colorBlindProtanopia) filters.add(const ColorFilter.matrix(_prot));
    if (appSettings.colorBlindTritanopia) filters.add(const ColorFilter.matrix(_trit));
    for (final f in filters) {
      player = ColorFiltered(colorFilter: f, child: player);
    }
    if (night || appSettings.nightMode) {
      player = ColorFiltered(
        colorFilter: ColorFilter.mode(Color.fromARGB((80 + appSettings.nightWarmth * 80).round(), 255, 140, 40), BlendMode.multiply),
        child: player,
      );
    }
    if (appSettings.extraDim) {
      player = ColorFiltered(colorFilter: ColorFilter.mode(Colors.black.withValues(alpha: 0.35), BlendMode.darken), child: player);
    }
    return Center(child: player);
  }

  Widget _fit(Widget child, VideoPlayerController c, Size screen) {
    var vw = c.value.size.width;
    var vh = c.value.size.height;
    if (vw <= 0 || vh <= 0) {
      vw = screen.width.clamp(1, 10000);
      vh = screen.height.clamp(1, 10000);
    }
    switch (aspect) {
      case AspectMode.fit:
        return FittedBox(fit: BoxFit.contain, child: SizedBox(width: vw, height: vh, child: child));
      case AspectMode.zoom:
        return FittedBox(fit: BoxFit.cover, child: SizedBox(width: vw, height: vh, child: child));
      case AspectMode.stretch:
        return SizedBox(width: screen.width, height: screen.height, child: child);
      case AspectMode.original:
        return OverflowBox(
          maxWidth: vw,
          maxHeight: vh,
          child: SizedBox(width: vw, height: vh, child: child),
        );
      case AspectMode.ratio16_9:
        return AspectRatio(aspectRatio: 16 / 9, child: child);
      case AspectMode.ratio4_3:
        return AspectRatio(aspectRatio: 4 / 3, child: child);
      case AspectMode.ratio21_9:
        return AspectRatio(aspectRatio: 21 / 9, child: child);
      case AspectMode.ratio1_1:
        return AspectRatio(aspectRatio: 1, child: child);
      case AspectMode.ratio2_35:
        return AspectRatio(aspectRatio: 2.35, child: child);
      case AspectMode.ratio9_16:
        return AspectRatio(aspectRatio: 9 / 16, child: child);
    }
  }

  List<Widget> _chrome(VideoPlayerController? c, Size size) {
    final pos = c?.value.position ?? Duration.zero;
    final dur = c?.value.duration ?? Duration.zero;
    final playing = c?.value.isPlaying ?? false;
    final remain = dur - pos;
    final pad = MediaQuery.paddingOf(context);
    final insets = MediaQuery.viewInsetsOf(context);
    final iconSize = appSettings.largeControls ? 40.0 : 32.0;
    final playSize = appSettings.largeControls ? 68.0 : 56.0;
    return [
      Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: Container(
          padding: EdgeInsets.only(top: pad.top),
          decoration: const BoxDecoration(
            gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.black87, Colors.transparent]),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.keyboard_arrow_down, color: Colors.white)),
                  Expanded(
                    child: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                  ),
                  TextButton(
                    onPressed: () => setState(() => hdr = !hdr),
                    child: Text(hdr ? 'HDR' : 'SDR', style: TextStyle(color: hdr ? Colors.white : Colors.white54, fontWeight: FontWeight.w700)),
                  ),
                  IconButton(
                    tooltip: appSettings.eqEnabled ? 'Equalizer on' : 'Equalizer off',
                    onPressed: () async {
                      try {
                        appSettings.eqEnabled = !appSettings.eqEnabled;
                        if (appSettings.eqEnabled) {
                          await AndroidBridge.initEqualizer(0);
                        }
                        await AndroidBridge.setEqEnabled(appSettings.eqEnabled);
                        await appSettings.save();
                        if (mounted) setState(() {});
                        _flash(appSettings.eqEnabled ? 'Equalizer on' : 'Equalizer off');
                      } catch (e, s) {
                        CrashLog.record('EQ', '$e', s);
                      }
                    },
                    onLongPress: () {
                      CrashLog.breadcrumb('Open equalizer');
                      Navigator.push(context, MaterialPageRoute(builder: (_) => const EqualizerPage()));
                    },
                    icon: Icon(Icons.equalizer, color: appSettings.eqEnabled ? Colors.white : Colors.white54),
                  ),
                  IconButton(onPressed: _playlist, icon: const Icon(Icons.queue_music, color: Colors.white)),
                  IconButton(onPressed: _more, icon: const Icon(Icons.more_vert, color: Colors.white)),
                ],
              ),
              _quickActions(),
              if (appSettings.showClock || appSettings.showBattery)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    [
                      if (appSettings.showClock) TimeOfDay.fromDateTime(now).format(context),
                      if (appSettings.showBattery) '$battery%',
                    ].join('  ·  '),
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
      ),
      Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: Container(
          padding: EdgeInsets.fromLTRB(8, 12, 8, 12 + pad.bottom + insets.bottom),
          decoration: const BoxDecoration(
            gradient: LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [Colors.black87, Colors.transparent]),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Text(_stamp(pos), style: const TextStyle(color: Colors.white, fontFeatures: [ui.FontFeature.tabularFigures()], fontSize: 12)),
                  Expanded(
                    child: Slider(
                      value: dur.inMilliseconds == 0 ? 0 : (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0),
                      onChanged: (v) {
                        if (c == null) return;
                        c.seekTo(Duration(milliseconds: (v * dur.inMilliseconds).round()));
                      },
                    ),
                  ),
                  Text(
                    appSettings.showRemaining ? '-${_stamp(remain)}' : _stamp(dur),
                    style: const TextStyle(color: Colors.white, fontFeatures: [ui.FontFeature.tabularFigures()], fontSize: 12),
                  ),
                ],
              ),
              SizedBox(
                height: playSize + 12,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(onPressed: _prev, icon: Icon(Icons.skip_previous, color: Colors.white, size: iconSize)),
                        IconButton(
                          onPressed: _togglePlay,
                          icon: Icon(playing ? Icons.pause_circle : Icons.play_circle, color: Colors.white, size: playSize),
                        ),
                        IconButton(onPressed: _next, icon: Icon(Icons.skip_next, color: Colors.white, size: iconSize)),
                      ],
                    ),
                    Positioned(
                      right: 0,
                      child: Row(
                        children: [
                          IconButton(
                            onPressed: () {
                              setState(() {
                                locked = true;
                                showUi = false;
                              });
                              _applySystemUi();
                            },
                            icon: const Icon(Icons.lock_outline, color: Colors.white),
                            tooltip: 'Lock',
                          ),
                          IconButton(
                            onPressed: _aspectSheet,
                            icon: const Icon(Icons.aspect_ratio, color: Colors.white),
                            tooltip: 'Screen mode',
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ];
  }

  Widget _quickActions() {
    Widget chip(String id) {
      final on = switch (id) {
        'background' => appSettings.backgroundPlay,
        _ => false,
      };
      final icon = switch (id) {
        'speed' => Icons.speed,
        'background' => Icons.headphones_outlined,
        'screenshot' => Icons.camera_alt_outlined,
        _ => Icons.tune,
      };
      final label = switch (id) {
        'speed' => 'Speed',
        'background' => 'Background',
        'screenshot' => 'Screenshot',
        _ => id,
      };
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: TextButton.icon(
          onPressed: () => _runAction(id),
          icon: Icon(icon, color: on ? Colors.white : Colors.white70, size: 20),
          label: Text(label, style: TextStyle(color: on ? Colors.white : Colors.white70, fontSize: 12)),
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(children: [for (final a in AppSettings.defaultQuickActions) chip(a)]),
    );
  }

  Future<void> _runAction(String id) async {
    switch (id) {
      case 'lock':
        setState(() {
          locked = true;
          showUi = false;
        });
        _applySystemUi();
      case 'aspect':
        await _aspectSheet();
      case 'speed':
        await _speedSheet();
      case 'rotate':
        await _rotationSheet();
      case 'audio':
        await _simple('Audio track', 'The current file exposes the default audio track. Multi-track selection uses the system decoder.');
      case 'subtitle':
        setState(() => appSettings.captions = !appSettings.captions);
        await appSettings.save();
      case 'background':
        await _toggleBackground(!appSettings.backgroundPlay);
      case 'popup':
        await _togglePopup(!appSettings.autoMiniplayer);
      case 'cast':
        await _simple('Cast', 'Use Android wireless display / Cast from the system quick settings.');
      case 'delete':
        final ok = await confirm(context, 'Delete this video?', item.title);
        if (ok) {
          await library.deleteVideos([item]);
          widget.onChanged();
          if (mounted) Navigator.pop(context);
        }
      case 'bookmark':
        _toggleBookmark();
      case 'playopt':
        await _playOptions();
      case 'ab':
        _cycleAb();
      case 'eq':
        try {
          await CrashLog.breadcrumb('Open equalizer');
          if (mounted) {
            await Navigator.push(context, MaterialPageRoute(builder: (_) => const EqualizerPage()));
          }
        } catch (e, s) {
          CrashLog.record('EQ', '$e', s);
        }
      case 'night':
        setState(() {
          night = !night;
          appSettings.nightMode = night;
        });
        await appSettings.save();
      case 'mirror':
        setState(() {
          mirror = !mirror;
          appSettings.mirror = mirror;
        });
        await appSettings.save();
      case 'invert':
        setState(() {
          invert = !invert;
          appSettings.invertColors = invert;
        });
        await appSettings.save();
      case 'color':
        await _colorSheet();
      case 'brightness':
        await _brightnessSheet();
      case 'timer':
        await _timerSheet();
      case 'songs':
        await _simple('Songs', 'Audio-only entries from the same folder can be queued from Folders.');
      case 'repeat':
        await _playlist();
      case 'decoder':
        appSettings.decoder = switch (appSettings.decoder) {
          DecoderMode.auto => DecoderMode.hw,
          DecoderMode.hw => DecoderMode.sw,
          DecoderMode.sw => DecoderMode.auto,
        };
        await appSettings.save();
        _flash('${appSettings.decoder.name.toUpperCase()} decoder');
      case 'screenshot':
        await _screenshot();
      case 'share':
        await SharePlus.instance.share(ShareParams(files: [XFile(item.path)], title: item.title));
      case 'properties':
        await showProperties(context, item);
      default:
        await _more();
    }
  }

  void _toggleBookmark() {
    if (appSettings.bookmarks.contains(item.path)) {
      appSettings.bookmarks.remove(item.path);
      item.bookmarked = false;
    } else {
      appSettings.bookmarks.add(item.path);
      item.bookmarked = true;
    }
    appSettings.save();
    widget.onChanged();
    setState(() {});
  }

  void _cycleAb() {
    final pos = (vc?.value.position.inMilliseconds ?? 0) / 1000.0;
    if (abA == null) {
      abA = pos;
      _flash('A marker');
    } else if (abB == null) {
      abB = pos;
      _flash('AB loop');
    } else {
      abA = null;
      abB = null;
      _flash('AB cleared');
    }
    setState(() {});
  }

  Future<void> _toggleBackground(bool on) async {
    appSettings.backgroundPlay = on;
    await appSettings.save();
    await _syncBackground();
    setState(() {});
    _flash(on ? 'Background play on' : 'Background play off');
  }

  Future<void> _togglePopup(bool on) async {
    appSettings.autoMiniplayer = on;
    await appSettings.save();
    final playing = vc?.value.isPlaying ?? false;
    if (on && playing) {
      await AndroidBridge.setPlaying(true);
      await AndroidBridge.enterPip();
    } else {
      await AndroidBridge.setPipEnabled(on && playing);
      if (on && !playing) _flash('Pop-up starts when a video is playing');
    }
    setState(() {});
  }

  Future<void> _togglePlay() async {
    final c = vc;
    if (c == null) return;
    if (c.value.isPlaying) {
      await c.pause();
    } else {
      await c.play();
    }
    await _syncBackground();
    setState(() {});
    _armHide();
  }

  String _stamp(Duration d) {
    final n = d.isNegative ? Duration.zero : d;
    final h = n.inHours;
    final m = n.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = n.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  Future<void> _playlist() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        final pad = MediaQuery.paddingOf(ctx);
        final insets = MediaQuery.viewInsetsOf(ctx);
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          builder: (_, sc) {
            return Padding(
              padding: EdgeInsets.only(bottom: pad.bottom + insets.bottom),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                    child: Row(
                      children: [
                        const Expanded(child: Text('Playlist', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600))),
                        IconButton(onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close)),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Wrap(
                      spacing: 8,
                      children: [
                        for (final m in PlayMode.values)
                          ChoiceChip(
                            label: Text(switch (m) {
                              PlayMode.order => 'Order',
                              PlayMode.loopAll => 'Loop all',
                              PlayMode.repeatOne => 'Repeat current',
                              PlayMode.shuffle => 'Shuffle all',
                              PlayMode.noAutoplay => 'No autoplay',
                            }),
                            selected: appSettings.playMode == m,
                            onSelected: (_) {
                              setState(() => appSettings.playMode = m);
                              appSettings.save();
                              Navigator.pop(ctx);
                            },
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      controller: sc,
                      itemCount: list.length,
                      itemBuilder: (_, i) {
                        final v = list[i];
                        return ListTile(
                          selected: i == index,
                          leading: SizedBox(width: 64, height: 40, child: VideoThumb(item: v, radius: 6)),
                          title: Text(v.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(formatDuration(v.duration)),
                          onTap: () {
                            Navigator.pop(ctx);
                            index = i;
                            _openCurrent();
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _more() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, ss) {
          void refresh() {
            ss(() {});
            setState(() {});
          }

          Widget go(IconData i, String t, String id, {String? sub}) => ListTile(
                leading: Icon(i),
                title: Text(t),
                subtitle: sub == null ? null : Text(sub),
                onTap: () async {
                  Navigator.pop(ctx);
                  await _runAction(id);
                },
              );

          Widget tog(IconData i, String t, bool v, Future<void> Function(bool) on, {String? sub}) => SwitchListTile(
                secondary: Icon(i),
                title: Text(t),
                subtitle: sub == null ? null : Text(sub),
                value: v,
                onChanged: (n) async {
                  await on(n);
                  await appSettings.save();
                  refresh();
                },
              );

          Widget head(String t) => Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text(t, style: TextStyle(color: Theme.of(ctx).colorScheme.primary, fontWeight: FontWeight.w600)),
              );

          final pad = MediaQuery.paddingOf(ctx);
          final insets = MediaQuery.viewInsetsOf(ctx);
          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.86,
            builder: (_, sc) => ListView(
              controller: sc,
              padding: EdgeInsets.only(bottom: pad.bottom + insets.bottom + 16),
              children: [
                const ListTile(title: Text('More', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600))),
                head('Playback'),
                go(Icons.lock_outline, 'Lock', 'lock'),
                go(Icons.aspect_ratio, 'Screen mode', 'aspect'),
                go(Icons.speed, 'Speed', 'speed', sub: '${speed.toStringAsFixed(2)}×'),
                go(Icons.tune, 'Play option', 'playopt'),
                go(Icons.repeat, 'AB Repeat', 'ab'),
                go(Icons.queue_music, 'Repeat mode', 'repeat'),
                go(Icons.memory, 'Decoder', 'decoder', sub: appSettings.decoder.name.toUpperCase()),
                head('Audio'),
                go(Icons.audiotrack_outlined, 'Audio track', 'audio'),
                tog(Icons.headphones_outlined, 'Background play', appSettings.backgroundPlay, _toggleBackground, sub: 'Music-style notification, keeps audio going'),
                tog(Icons.graphic_eq, 'Pitch shift', appSettings.pitchShift, (n) async {
                  appSettings.pitchShift = n;
                  await _applySpeed();
                }, sub: 'On: pitch follows speed. Off: time-stretch.'),
                go(Icons.equalizer, 'Equalizer', 'eq', sub: appSettings.eqEnabled ? 'On · ${appSettings.eqPreset}' : 'Off'),
                head('Picture'),
                tog(Icons.subtitles_outlined, 'Subtitle', appSettings.captions, (n) async {
                  appSettings.captions = n;
                }),
                tog(Icons.nights_stay_outlined, 'Night mode', night, (n) async {
                  night = n;
                  appSettings.nightMode = n;
                }),
                tog(Icons.flip, 'Mirror', mirror, (n) async {
                  mirror = n;
                  appSettings.mirror = n;
                }),
                tog(Icons.invert_colors, 'Invert filter', invert, (n) async {
                  invert = n;
                  appSettings.invertColors = n;
                }),
                tog(Icons.color_lens_outlined, 'Color correction', appSettings.colorCorrection, (n) async {
                  appSettings.colorCorrection = n;
                }, sub: 'Contrast, saturation, gamma, hue'),
                go(Icons.tune, 'Color correction sliders', 'color'),
                go(Icons.screen_rotation, 'Rotation control', 'rotate'),
                go(Icons.brightness_6_outlined, 'Brightness', 'brightness'),
                head('System'),
                tog(Icons.picture_in_picture_alt, 'Pop-up', appSettings.autoMiniplayer, _togglePopup, sub: 'Only while playing'),
                tog(Icons.navigation_outlined, 'Always hide navigation bar', appSettings.alwaysHideNavBar, (n) async {
                  appSettings.alwaysHideNavBar = n;
                  _applySystemUi();
                }, sub: 'Otherwise the system bar follows the controller'),
                go(Icons.timer_outlined, 'Timer', 'timer'),
                go(Icons.cast, 'Cast', 'cast'),
                head('File'),
                tog(item.bookmarked ? Icons.bookmark : Icons.bookmark_border, 'Bookmark', item.bookmarked, (n) async {
                  _toggleBookmark();
                }),
                go(Icons.camera_alt_outlined, 'Screenshot', 'screenshot', sub: 'Saves the current frame to DCIM/Screenshots'),
                go(Icons.share_outlined, 'Share', 'share'),
                go(Icons.delete_outline, 'Delete', 'delete'),
                go(Icons.info_outline, 'Properties', 'properties'),
                go(Icons.library_music_outlined, 'Songs', 'songs'),
              ],
            ),
          );
        });
      },
    );
  }

  Future<void> _simple(String t, String b) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(title: Text(t), content: Text(b), actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))]),
    );
  }

  Future<void> _speedSheet() async {
    double local = speed;
    final box = TextEditingController(text: speed.toStringAsFixed(2));
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        final insets = MediaQuery.viewInsetsOf(ctx);
        final pad = MediaQuery.paddingOf(ctx);
        return StatefulBuilder(builder: (ctx, ss) {
          return Padding(
            padding: EdgeInsets.fromLTRB(20, 8, 20, 24 + insets.bottom + pad.bottom),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Speed', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                Slider(
                    min: 0.25,
                    max: 4,
                    value: local,
                    onChanged: (v) {
                      ss(() => local = v);
                      box.text = v.toStringAsFixed(2);
                    }),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: box,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(labelText: 'Speed value', border: OutlineInputBorder()),
                        onSubmitted: (t) {
                          final n = double.tryParse(t);
                          if (n != null) ss(() => local = n.clamp(0.25, 4));
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilterChip(
                      label: const Text('Pitch shift'),
                      selected: appSettings.pitchShift,
                      onSelected: (v) async {
                        ss(() => appSettings.pitchShift = v);
                        await appSettings.save();
                        await _applySpeed();
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () async {
                    speed = local;
                    appSettings.speed = local;
                    await _applySpeed();
                    await appSettings.save();
                    if (ctx.mounted) Navigator.pop(ctx);
                    setState(() {});
                  },
                  child: const Text('Apply'),
                ),
              ],
            ),
          );
        });
      },
    );
  }

  Future<void> _brightnessSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: StatefulBuilder(builder: (ctx, ss) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Brightness', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                  Row(
                    children: [
                      const Icon(Icons.brightness_low),
                      Expanded(
                        child: Slider(
                          value: brightness,
                          onChanged: (v) async {
                            ss(() => brightness = v);
                            try {
                              await ScreenBrightness().setApplicationScreenBrightness(v);
                            } catch (_) {}
                            if (appSettings.rememberBrightness) {
                              appSettings.brightness = v;
                            }
                          },
                          onChangeEnd: (_) => appSettings.save(),
                        ),
                      ),
                      Text('${(brightness * 100).round()}%'),
                    ],
                  ),
                ],
              ),
            );
          }),
        );
      },
    );
  }

  Future<void> _aspectSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        Widget item(AspectMode m, String t, String s) => RadioListTile<AspectMode>(
              value: m,
              groupValue: aspect,
              title: Text(t),
              subtitle: Text(s),
              onChanged: (v) {
                setState(() => aspect = v!);
                if (appSettings.rememberAspect) {
                  appSettings.aspect = v!;
                  appSettings.save();
                }
                Navigator.pop(ctx);
              },
            );
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(title: Text('Screen mode', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600))),
              item(AspectMode.fit, 'Fit', 'Contain the full frame'),
              item(AspectMode.zoom, 'Zoomed full screen', 'Cover the display, crop overflow'),
              item(AspectMode.original, 'Original size', '1:1 video pixels on this screen'),
              item(AspectMode.stretch, 'Stretch', 'Fill without preserving ratio'),
              item(AspectMode.ratio16_9, '16:9', 'Force 16:9'),
              item(AspectMode.ratio4_3, '4:3', 'Force 4:3'),
              item(AspectMode.ratio21_9, '21:9', 'Force 21:9'),
              item(AspectMode.ratio2_35, '2.35:1', 'Cinema'),
              item(AspectMode.ratio1_1, '1:1', 'Square'),
              item(AspectMode.ratio9_16, '9:16', 'Portrait'),
            ],
          ),
        );
      },
    );
  }

  Future<void> _rotationSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final e in RotationLock.values)
                RadioListTile<RotationLock>(
                  value: e,
                  groupValue: appSettings.rotation,
                  title: Text(switch (e) {
                    RotationLock.auto => 'Auto rotate sensor',
                    RotationLock.autoVideo => 'Auto rotate to video resolution',
                    RotationLock.landscape => 'Lock landscape',
                    RotationLock.portrait => 'Lock portrait',
                    RotationLock.landscapeNormal => 'Lock normal landscape',
                    RotationLock.landscapeReverse => 'Lock upside-down landscape',
                    RotationLock.portraitNormal => 'Lock portrait normal',
                    RotationLock.portraitReverse => 'Lock portrait upside-down',
                    RotationLock.locked => 'Lock current',
                  }),
                  onChanged: (v) {
                    appSettings.rotation = v!;
                    appSettings.save();
                    _applyRotation();
                    Navigator.pop(ctx);
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _colorSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        final insets = MediaQuery.viewInsetsOf(ctx);
        return SafeArea(
          child: StatefulBuilder(builder: (ctx, ss) {
            return Padding(
              padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + insets.bottom),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Color correction', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Enable'),
                    value: appSettings.colorCorrection,
                    onChanged: (v) => ss(() => appSettings.colorCorrection = v),
                  ),
                  _sl('Contrast', appSettings.contrast, 0.4, 2, (v) => ss(() => appSettings.contrast = v)),
                  _sl('Saturation', appSettings.saturation, 0, 2, (v) => ss(() => appSettings.saturation = v)),
                  _sl('Gamma', appSettings.gamma, 0.4, 2.2, (v) => ss(() => appSettings.gamma = v)),
                  _sl('Hue', appSettings.hueRotate, -180, 180, (v) => ss(() => appSettings.hueRotate = v)),
                  FilledButton(
                    onPressed: () {
                      appSettings.save();
                      Navigator.pop(ctx);
                      setState(() {});
                    },
                    child: const Text('Done'),
                  ),
                ],
              ),
            );
          }),
        );
      },
    );
  }

  Widget _sl(String t, double v, double a, double b, ValueChanged<double> on) {
    return Row(children: [
      SizedBox(width: 92, child: Text(t)),
      Expanded(child: Slider(min: a, max: b, value: v.clamp(a, b), onChanged: on)),
    ]);
  }

  Future<void> _timerSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final m in [15, 30, 45, 60, 90])
                ListTile(
                  title: Text('Stop in $m min'),
                  onTap: () {
                    sleepTimer?.cancel();
                    var left = Duration(minutes: m);
                    sleepTimer = Timer.periodic(const Duration(seconds: 1), (t) {
                      left -= const Duration(seconds: 1);
                      if (left <= Duration.zero) {
                        t.cancel();
                        vc?.pause();
                      }
                      if (mounted) setState(() => sleepLeft = left);
                    });
                    Navigator.pop(ctx);
                    _flash('Timer $m min');
                  },
                ),
              ListTile(
                title: const Text('Cancel timer'),
                onTap: () {
                  sleepTimer?.cancel();
                  sleepLeft = null;
                  Navigator.pop(ctx);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _playOptions() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                title: const Text('Auto play next'),
                value: appSettings.autoPlayNext,
                onChanged: (v) {
                  setState(() => appSettings.autoPlayNext = v);
                  appSettings.save();
                  Navigator.pop(ctx);
                },
              ),
              SwitchListTile(
                title: const Text('Resume from last position'),
                value: appSettings.resumePlayback,
                onChanged: (v) {
                  setState(() => appSettings.resumePlayback = v);
                  appSettings.save();
                  Navigator.pop(ctx);
                },
              ),
              SwitchListTile(
                title: const Text('Background play'),
                value: appSettings.backgroundPlay,
                onChanged: (v) {
                  _toggleBackground(v);
                  Navigator.pop(ctx);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _screenshot() async {
    final path = await AndroidBridge.screenshot(
      path: item.path,
      positionMs: vc?.value.position.inMilliseconds ?? 0,
      title: item.title,
    );
    if (path != null) {
      _flash('Saved to DCIM/Screenshots');
      await AndroidBridge.toast('Saved to DCIM/Screenshots');
    } else {
      _flash('Could not capture frame');
    }
  }
}

const _invert = <double>[
  -1, 0, 0, 0, 255,
  0, -1, 0, 0, 255,
  0, 0, -1, 0, 255,
  0, 0, 0, 1, 0,
];
const _gray = <double>[
  0.2126, 0.7152, 0.0722, 0, 0,
  0.2126, 0.7152, 0.0722, 0, 0,
  0.2126, 0.7152, 0.0722, 0, 0,
  0, 0, 0, 1, 0,
];
const _deut = <double>[
  0.625, 0.375, 0, 0, 0,
  0.7, 0.3, 0, 0, 0,
  0, 0.3, 0.7, 0, 0,
  0, 0, 0, 1, 0,
];
const _prot = <double>[
  0.567, 0.433, 0, 0, 0,
  0.558, 0.442, 0, 0, 0,
  0, 0.242, 0.758, 0, 0,
  0, 0, 0, 1, 0,
];
const _trit = <double>[
  0.95, 0.05, 0, 0, 0,
  0, 0.433, 0.567, 0, 0,
  0, 0.475, 0.525, 0, 0,
  0, 0, 0, 1, 0,
];

List<double> _cs(double c, double s) {
  final lumR = 0.2126, lumG = 0.7152, lumB = 0.0722;
  final sr = (1 - s) * lumR;
  final sg = (1 - s) * lumG;
  final sb = (1 - s) * lumB;
  final t = (1 - c) / 2 * 255;
  return [
    c * (sr + s), c * sg, c * sb, 0, t,
    c * sr, c * (sg + s), c * sb, 0, t,
    c * sr, c * sg, c * (sb + s), 0, t,
    0, 0, 0, 1, 0,
  ];
}
