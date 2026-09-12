import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
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
import 'hud.dart';
import 'insets.dart';
import 'library.dart';
import 'main.dart';
import 'models.dart';
import 'player_fx.dart';
import 'player_more.dart';
import 'player_picture.dart';
import 'settings.dart';
import 'settings_ui.dart';
import 'session.dart';
import 'widgets.dart';

part 'player_gestures.dart';
part 'player_sheets.dart';

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
  StreamSubscription<Map<String, dynamic>>? events;
  double _zoomScale = 1;
  final _pts = <int, Offset>{};
  double _pinchStart = 0;
  double _pinchBase = 1;
  double? _scrub;
  Uint8List? _previewBytes;
  int _playerGen = 0;
  double? _systemBrightness;
  Offset _zoomPan = Offset.zero;
  Offset _pinchStartFocal = Offset.zero;
  Offset _pinchBasePan = Offset.zero;
  bool _pinching = false;
  bool _showZoomHud = false;
  Timer? _zoomHudTimer;
  DateTime? _tapAt;
  Offset? _tapPos;
  DateTime _lastBg = DateTime.fromMillisecondsSinceEpoch(0);
  bool _chromeHeld = false;
  bool _uiBeforeTap = true;
  final _ripples = <RippleSpec>[];
  int _rippleSeq = 0;
  int _activeRipples = 0;
  int _leftCount = 0;
  int _rightCount = 0;
  bool _leftOn = false;
  bool _rightOn = false;
  bool _midOn = false;
  bool _midPlayingIcon = true;
  final _midBursts = <MidBurst>[];
  String? _currentSide;
  Timer? _leftHide;
  Timer? _rightHide;
  Timer? _midHide;
  DateTime _leftTap = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _rightTap = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _midTap = DateTime.fromMillisecondsSinceEpoch(0);
  String _gesture = '';
  bool _previewBusy = false;
  double? _previewWant;
  bool _tapBurst = false;
  bool _ateTap = false;
  bool _handedOff = false;
  bool _endedLatch = false;
  int _openFails = 0;

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
      kept = (PlaybackSession.active || PlaybackSession.transferring) &&
          PlaybackSession.controller != null &&
          PlaybackSession.controller!.value.isInitialized &&
          PlaybackSession.item?.path == widget.playlist[index].path;
    } catch (_) {
      kept = false;
    }
    PlaybackSession.transferring = false;
    if (kept) {
      vc = PlaybackSession.take();
      ready = true;
      speed = PlaybackSession.speed;
      aspect = PlaybackSession.aspect;
      vc?.addListener(_tick);
      _lastPlaying = vc?.value.isPlaying ?? false;
      _endedLatch = false;
      _openFails = 0;
      unawaited(WakelockPlus.enable());
      unawaited(AndroidBridge.setKeepScreenOn(true));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_hookBrightness());
      });
      unawaited(AndroidBridge.requestAudioFocus());
      unawaited(_applyEq());
      _applySystemUi();
      _applyRotation();
      _applySpeed();
      _syncBackground();
      _armHide();
    } else {
      if (PlaybackSession.controller != null && PlaybackSession.controller != vc) {
        unawaited(PlaybackSession.stop());
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
            unawaited(AndroidBridge.requestAudioFocus());
            vc?.setVolume(1);
            vc?.play();
          case 'pause':
            vc?.pause();
          case 'duck':
            vc?.setVolume(0.2);
          case 'unduck':
            vc?.setVolume(1);
          case 'next':
            unawaited(_next());
          case 'prev':
            unawaited(_prev());
          case 'seek':
            final ms = e['positionMs'];
            if (ms is num) unawaited(vc?.seekTo(Duration(milliseconds: ms.round())) ?? Future<void>.value());
        }
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
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
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _hookBrightness();
      try {
        VolumeController.instance.showSystemUI = false;
        volume = await VolumeController.instance.getVolume();
      } catch (_) {}
      if (mounted) setState(() {});
    });
    await _openCurrent();
  }

  void _applyRotation() {
    final m = switch (appSettings.rotation) {
      RotationLock.none => 'none',
      RotationLock.auto => 'sensor',
      RotationLock.autoVideo => _orientForVideo(),
      RotationLock.landscape => 'landscape',
      RotationLock.portrait => 'portrait',
      RotationLock.landscapeNormal => 'landscape_normal',
      RotationLock.landscapeReverse => 'landscape_reverse',
      RotationLock.portraitNormal => 'portrait_normal',
      RotationLock.portraitReverse => 'portrait_reverse',
    };
    AndroidBridge.setOrientation(m);
  }

  String _orientForVideo() {
    Size? s;
    try {
      s = vc?.value.size;
    } catch (_) {}
    if (s == null || s.width <= 0 || s.height <= 0) {
      if (item.width > 0 && item.height > 0) {
        s = Size(item.width.toDouble(), item.height.toDouble());
      }
    }
    if (s == null || s.width <= 0 || s.height <= 0) return 'none';
    if (s.width > s.height) return 'landscape_normal';
    if (s.width < s.height) return 'portrait_normal';
    return 'none';
  }

  void _applySystemUi() {
    SystemBars.alwaysHide = appSettings.alwaysHideNavBar;
    final sheetOpen = SystemBars.popupCount > 0;
    final hide = !sheetOpen && (appSettings.alwaysHideNavBar || !showUi);
    SystemBars.apply(icons: Brightness.light, contrast: true, hide: hide);
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
    await AndroidBridge.setPlaybackParams(speed: rate, pitchShift: appSettings.pitchShift);
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
    final old = vc;
    final gen = ++_playerGen;
    vc = null;
    ready = false;
    _endedLatch = false;
    _scrub = null;
    _previewBytes = null;
    _zoomScale = 1;
    _zoomPan = Offset.zero;
    _pinching = false;
    _showZoomHud = false;
    _pts.clear();
    if (mounted) setState(() {});
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || gen != _playerGen) return;
    try {
      old?.removeListener(_tick);
      await old?.dispose();
    } catch (_) {}
    VideoPlayerController? c;
    try {
      await CrashLog.breadcrumb('Open video ${item.path}');
      c = await PlaybackSession.openWithFallback(item);
      if (!mounted || gen != _playerGen) {
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
      await c.setLooping(appSettings.playMode == PlayMode.repeatOne);
      if (c.value.hasError) {
        throw StateError(c.value.errorDescription ?? 'Player failed to start');
      }
      vc = c;
      _openFails = 0;
      _endedLatch = false;
      await AndroidBridge.requestAudioFocus();
      await c.play();
      _lastPlaying = true;
      _syncPip();
      unawaited(_syncBackground());
      unawaited(_applySpeed());
      unawaited(AndroidBridge.preparePreview(item.path));
      unawaited(_applyEq());
      _applyRotation();
      if (mounted && gen == _playerGen) setState(() => ready = true);
      _armHide();
    } catch (e, s) {
      await CrashLog.breadcrumb('Open failed ${item.path}: $e');
      try {
        await c?.dispose();
      } catch (_) {}
      if (gen == _playerGen) vc = null;
      if (mounted) setState(() => ready = false);
      if (mounted && gen == _playerGen) {
        _openFails++;
        if (_openFails < list.length && appSettings.playMode != PlayMode.noAutoplay) {
          await _next();
        } else {
          CrashLog.record('PLAY', '$e', s);
        }
      }
    }
  }

  void _tick() {
    final c = vc;
    if (c == null || !mounted) return;
    try {
      if (!c.value.isInitialized) return;
      if (c.value.hasError) {
        unawaited(CrashLog.breadcrumb('Source error ${item.path}: ${c.value.errorDescription}'));
        if (!_endedLatch) {
          _endedLatch = true;
          unawaited(_next());
        }
        return;
      }
      final pos = c.value.position.inMilliseconds.toDouble();
      final dur = c.value.duration.inMilliseconds.toDouble().clamp(1, double.infinity);
      final p = (pos / dur).clamp(0.0, 1.0).toDouble();
      item.progress = p;
      appSettings.resumeMap[item.path] = p;
      if (abA != null && abB != null && pos / 1000 >= abB!) {
        c.seekTo(Duration(milliseconds: (abA! * 1000).round()));
      }
      final playing = c.value.isPlaying;
      final nowTick = DateTime.now();
      if (playing != _lastPlaying) {
        _lastPlaying = playing;
        _syncPip();
        unawaited(_syncBackground());
      }
      if (appSettings.backgroundPlay && nowTick.difference(_lastBg) >= const Duration(milliseconds: 800)) {
        _lastBg = nowTick;
        unawaited(_syncBackground());
      }
      if (!_endedLatch &&
          c.value.position >= c.value.duration - const Duration(milliseconds: 400) &&
          !c.value.isPlaying) {
        _endedLatch = true;
        _onEnded();
      }
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
        _endedLatch = false;
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
        if (appSettings.playMode == PlayMode.loopAll || _openFails > 0) {
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
    } else if (appSettings.playMode == PlayMode.loopAll && list.isNotEmpty) {
      index = list.length - 1;
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
    if (locked || _chromeHeld || _scrub != null) return;
    hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && (vc?.value.isPlaying ?? false) && !locked && !_chromeHeld && _scrub == null) {
        _setUi(false);
      }
    });
  }

  void _holdChrome(bool on) {
    _chromeHeld = on;
    if (on) {
      hideTimer?.cancel();
    } else {
      _armHide();
    }
  }

  void _flash(String text) {
    setState(() => overlay = text);
    overlayTimer?.cancel();
    overlayTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => overlay = '');
    });
  }

  Future<void> _applyEq() async {
    await AndroidBridge.applyEqualizer(
      enabled: appSettings.eqEnabled,
      bands: appSettings.eqBands,
      bassOn: appSettings.bassBoostOn,
      bass: appSettings.bassBoost,
      surroundOn: appSettings.surroundOn,
      surround: appSettings.surround,
    );
  }

  Future<void> _hookBrightness() async {
    try {
      _systemBrightness ??= await ScreenBrightness().system;
      brightness = await ScreenBrightness().application;
      if (appSettings.rememberBrightness && appSettings.brightness >= 0) {
        brightness = appSettings.brightness;
        await ScreenBrightness().setApplicationScreenBrightness(brightness);
      }
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> _unhookBrightness() async {
    try {
      await ScreenBrightness().resetApplicationScreenBrightness();
    } catch (_) {}
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
    _zoomHudTimer?.cancel();
    _leftHide?.cancel();
    _rightHide?.cancel();
    _midHide?.cancel();
    vc?.removeListener(_tick);
    _persistProgress();
    unawaited(_unhookBrightness());
    if (_handedOff) {
      if (!PlaybackSession.keepAlive) {
        final dying = vc;
        vc = null;
        try {
          dying?.dispose();
        } catch (_) {}
        unawaited(AndroidBridge.stopBackground());
        unawaited(AndroidBridge.abandonAudioFocus());
      }
    } else {
      var keep = false;
      try {
        keep = (appSettings.inAppMiniplayer || appSettings.backgroundPlay) &&
            vc != null &&
            ready &&
            (vc?.value.isInitialized ?? false);
      } catch (_) {
        keep = false;
      }
    if (keep && vc != null) {
        PlaybackSession.claim(
          c: vc!,
          item: item,
          list: list,
          at: index,
          speed: speed,
          aspect: aspect,
        );
        unawaited(_syncBackground());
      } else {
        PlaybackSession.keepAlive = false;
        final dying = vc;
        vc = null;
        try {
          dying?.dispose();
        } catch (_) {}
        unawaited(AndroidBridge.stopBackground());
        unawaited(AndroidBridge.abandonAudioFocus());
        unawaited(AndroidBridge.preparePreview(''));
      }
    }
    WakelockPlus.disable();
    AndroidBridge.setKeepScreenOn(false);
    AndroidBridge.setPlaying(false);
    AndroidBridge.setPipEnabled(false);
    AndroidBridge.setOrientation('none');
    SystemBars.alwaysHide = false;
    SystemBars.apply(icons: Brightness.light, contrast: true, hide: false);
    super.dispose();
  }

  void _armMiniThenPop() {
    if (_handedOff) return;
    _handedOff = true;
    final want = appSettings.inAppMiniplayer || appSettings.backgroundPlay;
    var keep = false;
    try {
      keep = want && vc != null && ready && (vc?.value.isInitialized ?? false);
    } catch (_) {
      keep = false;
    }
    if (keep && vc != null) {
      PlaybackSession.claim(
        c: vc!,
        item: item,
        list: list,
        at: index,
        speed: speed,
        aspect: aspect,
      );
      unawaited(_syncBackground());
    } else {
      PlaybackSession.keepAlive = false;
    }
    if (mounted) {
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = vc;
    final size = MediaQuery.sizeOf(context);
    final pad = MediaQuery.viewPaddingOf(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _armMiniThenPop();
      },
      child: _playerChrome(
        Listener(
        onPointerDown: (e) => _pinchDown(e, size),
        onPointerMove: (e) => _pinchMove(e, size),
        onPointerUp: (e) => _pinchUp(e.pointer),
        onPointerCancel: (e) => _pinchUp(e.pointer),
        child: Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) {
                _tapPos = d.localPosition;
                _tapBurst = false;
                if (locked || _pts.length >= 2 || _pinching || _gesture == 'pan' || _gesture == 'hold' || _gesture == 'pinch') {
                  _ateTap = true;
                  return;
                }
                if (_wouldBurst(_tapPos ?? Offset.zero, size)) {
                  _tapBurst = true;
                  _ateTap = true;
                  _onVideoTap(_tapPos ?? Offset.zero, size);
                } else {
                  _armFirstTap(_tapPos ?? Offset.zero, size);
                }
              },
              onTap: () {
                if (locked || _pts.length >= 2 || _pinching || _gesture == 'pan' || _gesture == 'hold' || _gesture == 'pinch') return;
                if (_tapBurst || _ateTap) {
                  _tapBurst = false;
                  _ateTap = false;
                  return;
                }
                _uiBeforeTap = showUi;
                _setUi(!showUi);
              },
              onLongPressStart: (_) async {
                if (locked || !appSettings.longPress2x || c == null) return;
                if (_pts.length >= 2 || _pinching || _gesture == 'pan') return;
                _gesture = 'hold';
                _ateTap = true;
                speeding = true;
                unawaited(_applySpeed());
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
                _gesture = '';
                unawaited(_applySpeed());
                setState(() {});
              },
              onPanStart: (d) {
                if (locked || !appSettings.gestureControl) return;
                if (_pts.length >= 2 || _pinching || _gesture == 'hold' || _gesture == 'pinch') return;
                _gesture = 'pan';
                _tapBurst = false;
                _ateTap = true;
                _leftTap = DateTime.fromMillisecondsSinceEpoch(0);
                _rightTap = DateTime.fromMillisecondsSinceEpoch(0);
                _midTap = DateTime.fromMillisecondsSinceEpoch(0);
                panStart = d.localPosition;
                panKind = '';
              },
              onPanUpdate: (d) {
                if (locked || !appSettings.gestureControl || panStart == null || c == null) return;
                if (_pts.length >= 2 || _pinching) return;
                final dx = d.localPosition.dx - panStart!.dx;
                final dy = d.localPosition.dy - panStart!.dy;
                if (panKind.isEmpty) {
                  if (dx.abs() > 24 && dx.abs() > dy.abs()) {
                    panKind = 'seek';
                    panBase = c.value.position.inMilliseconds.toDouble();
                  } else if (dy.abs() > 24) {
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
                  setState(() => _scrub = next / dur);
                  _queuePreview((next / dur).toDouble());
                  _flash(formatDuration(Duration(milliseconds: next.round())));
                } else if (panKind == 'brightness') {
                  brightness = (panBase - dy / size.height).clamp(0.0, 1.0);
                  unawaited(ScreenBrightness().setApplicationScreenBrightness(brightness));
                  if (appSettings.rememberBrightness) {
                    appSettings.brightness = brightness;
                  }
                  _flash('Brightness ${(brightness * 100).round()}%');
                  setState(() {});
                } else if (panKind == 'volume') {
                  volume = (panBase - dy / size.height).clamp(0.0, 1.0);
                  try {
                    VolumeController.instance.setVolume(volume);
                  } catch (_) {}
                  _flash('Volume ${(volume * 100).round()}%');
                  setState(() {});
                }
              },
              onPanEnd: (_) async {
                if (panKind == 'seek' && _scrub != null && c != null) {
                  final dur = c.value.duration.inMilliseconds;
                  unawaited(c.seekTo(Duration(milliseconds: (_scrub! * dur).round())));
                }
                panKind = '';
                _scrub = null;
                _previewBytes = null;
                _gesture = '';
                if (mounted) setState(() {});
              },
              child: ColoredBox(
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
            ),
            PlayerRippleLayer(
              size: size,
              ripples: _ripples,
              leftCount: _leftCount,
              rightCount: _rightCount,
              leftOn: _leftOn,
              rightOn: _rightOn,
              midBursts: _midBursts,
              reduceMotion: appSettings.reduceMotion,
              onRippleDone: (id) {
                if (!mounted) return;
                setState(() {
                  _ripples.removeWhere((e) => e.id == id);
                  _activeRipples = (_activeRipples - 1).clamp(0, 99);
                });
              },
              onMidDone: (id) {
                if (!mounted) return;
                setState(() => _midBursts.removeWhere((e) => e.id == id));
              },
            ),
            if (speeding)
              const IgnorePointer(
                child: Center(
                  child: _HudChip(child: Text('2.0×', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: 0.4))),
                ),
              ),
            if (overlay.isNotEmpty && !speeding)
              IgnorePointer(
                child: Center(
                  child: _HudChip(child: Text(overlay, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600))),
                ),
              ),
            if (_showZoomHud || _pinching)
              Positioned(
                top: pad.top + 56,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: Center(
                    child: _HudChip(
                      child: Text(
                        '${(_zoomScale * 100).round()}%',
                        style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ),
              ),
            if (locked)
              Positioned(
                right: 16 + pad.right,
                bottom: 24 + pad.bottom,
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
            if (!locked)
              HudLayer(
                fabs: decodeHud(appSettings.hudFabsJson),
                pad: pad,
                bottomReserve: 24,
                onTap: (id) => unawaited(_runAction(id)),
              ),
            if (showUi && !locked) ..._chrome(c, size),
            if (_scrub != null && !(showUi && !locked)) _seekHud(c, pad),
          ],
        ),
      ),
    ),
    );
  }

  Widget _playerChrome(Widget body) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemBars.overlay(icons: Brightness.light),
      child: Scaffold(
        backgroundColor: Colors.black,
        resizeToAvoidBottomInset: false,
        body: body,
      ),
    );
  }
  Widget _seekHud(VideoPlayerController? c, EdgeInsets pad) {
    final pos = c?.value.position ?? Duration.zero;
    final dur = c?.value.duration ?? Duration.zero;
    final frac = dur.inMilliseconds == 0 ? 0.0 : ((_scrub ?? (pos.inMilliseconds / dur.inMilliseconds)).clamp(0.0, 1.0));
    final shown = Duration(milliseconds: (frac * dur.inMilliseconds).round());
    return Positioned(
      left: 12,
      right: 12,
      bottom: 28 + pad.bottom,
      child: IgnorePointer(
        child: Material(
          color: Colors.black.withValues(alpha: 0.62),
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
            child: Row(
              children: [
                Text(_stamp(shown), style: const TextStyle(color: Colors.white, fontFeatures: [ui.FontFeature.tabularFigures()], fontSize: 12)),
                Expanded(
                  child: Slider(value: frac, onChanged: null),
                ),
                Text(_stamp(dur), style: const TextStyle(color: Colors.white, fontFeatures: [ui.FontFeature.tabularFigures()], fontSize: 12)),
              ],
            ),
          ),
        ),
      ),
    );
  }
  Widget _video(VideoPlayerController c, Size screen) {
    if (_handedOff) return const ColoredBox(color: Colors.black);
    try {
      if (!c.value.isInitialized) {
        return const SizedBox.expand(child: Center(child: CircularProgressIndicator()));
      }
    } catch (_) {
      return const SizedBox.expand();
    }
    Widget player = VideoPlayer(key: ValueKey(_playerGen), c);
    player = _fit(player, c, screen);
    final w = screen.width <= 0 ? 1.0 : screen.width;
    final h = screen.height <= 0 ? 1.0 : screen.height;
    player = SizedBox(width: w, height: h, child: player);
    if (_zoomScale > 1.001 || _zoomScale < 0.999 || _zoomPan != Offset.zero) {
      player = Transform(
        alignment: Alignment.center,
        transform: Matrix4.identity()
          ..translate(_zoomPan.dx, _zoomPan.dy)
          ..scale(_zoomScale),
        child: player,
      );
    }
    return Center(
      child: VideoPicture(
        looks: PictureLooks.current(invert: invert, mirror: mirror, night: night),
        child: player,
      ),
    );
  }

  Widget _fit(Widget child, VideoPlayerController c, Size screen) {
    var vw = c.value.size.width;
    var vh = c.value.size.height;
    if (vw <= 1 || vh <= 1) {
      vw = screen.width.clamp(1, 10000);
      vh = screen.height.clamp(1, 10000);
    }
    if (screen.width < 2 || screen.height < 2) {
      return child;
    }
    switch (aspect) {
      case AspectMode.fit:
        return FittedBox(fit: BoxFit.contain, child: SizedBox(width: vw, height: vh, child: child));
      case AspectMode.zoom:
        return FittedBox(fit: BoxFit.cover, child: SizedBox(width: vw, height: vh, child: child));
      case AspectMode.stretch:
        return SizedBox(width: screen.width, height: screen.height, child: child);
      case AspectMode.original:
        final scale = math.min(1.0, math.min(screen.width / vw, screen.height / vh));
        return Center(
          child: SizedBox(
            width: vw * scale,
            height: vh * scale,
            child: child,
          ),
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

  Widget _titleBtn(String id) {
    switch (id) {
      case 'hdr':
        return TextButton(
          onPressed: () => setState(() => hdr = !hdr),
          child: Text(hdr ? 'HDR' : 'SDR', style: TextStyle(color: hdr ? Colors.white : Colors.white54, fontWeight: FontWeight.w700)),
        );
      case 'eq':
        return IconButton(
          tooltip: appSettings.eqEnabled ? 'Equalizer on' : 'Equalizer off',
          onPressed: () async {
            try {
              appSettings.eqEnabled = !appSettings.eqEnabled;
              await appSettings.save();
              await _applyEq();
              if (mounted) setState(() {});
              _flash(appSettings.eqEnabled ? 'Equalizer on' : 'Equalizer off');
            } catch (e, s) {
              CrashLog.record('EQ', '$e', s);
            }
          },
          onLongPress: () async {
            CrashLog.breadcrumb('Open equalizer');
            await Navigator.push(context, MaterialPageRoute(builder: (_) => const EqualizerPage()));
            await _applyEq();
          },
          icon: Icon(Icons.equalizer, color: appSettings.eqEnabled ? Colors.white : Colors.white54),
        );
      case 'playlist':
        return IconButton(onPressed: _playlist, icon: const Icon(Icons.queue_music, color: Colors.white));
      case 'more':
        return IconButton(onPressed: _more, icon: const Icon(Icons.more_vert, color: Colors.white));
      default:
        return IconButton(
          tooltip: AppSettings.allQuickActions[id] ?? id,
          onPressed: () => unawaited(_runAction(id)),
          icon: Icon(_actionIcon(id), color: Colors.white),
        );
    }
  }

  List<Widget> _chrome(VideoPlayerController? c, Size size) {
    final pos = c?.value.position ?? Duration.zero;
    final dur = c?.value.duration ?? Duration.zero;
    final playing = c?.value.isPlaying ?? false;
    final remain = dur - pos;
    final pad = MediaQuery.viewPaddingOf(context);
    final iconSize = appSettings.largeControls ? 40.0 : 32.0;
    final playSize = appSettings.largeControls ? 68.0 : 56.0;
    final wide = size.width >= 600;
    return [
      Positioned(
        top: 0,
        left: pad.left,
        right: pad.right,
        child: Listener(
          onPointerDown: (_) => _holdChrome(true),
          onPointerUp: (_) => _holdChrome(false),
          onPointerCancel: (_) => _holdChrome(false),
          child: Container(
          padding: EdgeInsets.only(top: pad.top),
          decoration: const BoxDecoration(
            gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.black87, Colors.transparent]),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  IconButton(onPressed: _armMiniThenPop, icon: const Icon(Icons.keyboard_arrow_down, color: Colors.white)),
                  Expanded(
                    child: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                  ),
                  for (final id in (appSettings.titleActions.isEmpty ? const <String>['more'] : appSettings.titleActions)) _titleBtn(id),
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
      ),
      Positioned(
        left: pad.left,
        right: pad.right,
        bottom: 0,
        child: Listener(
          onPointerDown: (_) => _holdChrome(true),
          onPointerUp: (_) => _holdChrome(false),
          onPointerCancel: (_) => _holdChrome(false),
          child: Container(
          padding: EdgeInsets.fromLTRB(8, 12, 8, 12 + pad.bottom),
          decoration: const BoxDecoration(
            gradient: LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [Colors.black87, Colors.transparent]),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(_stamp(_scrub != null ? Duration(milliseconds: ((_scrub! * dur.inMilliseconds).round())) : pos), style: const TextStyle(color: Colors.white, fontFeatures: [ui.FontFeature.tabularFigures()], fontSize: 13)),
                  ),
                  Expanded(
                    child: LayoutBuilder(builder: (ctx, box) {
                      final frac = dur.inMilliseconds == 0
                          ? 0.0
                          : ((_scrub ?? (pos.inMilliseconds / dur.inMilliseconds)).clamp(0.0, 1.0));
                      Widget mark(double? sec, Color color) {
                        if (sec == null || dur.inMilliseconds <= 0) return const SizedBox.shrink();
                        final x = (sec * 1000 / dur.inMilliseconds).clamp(0.0, 1.0) * box.maxWidth;
                        return Positioned(
                          left: x - 1,
                          top: 6,
                          child: Container(width: 2, height: 22, color: color),
                        );
                      }
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_scrub != null && _previewBytes != null && appSettings.showSeekPreview)
                            Align(
                              alignment: Alignment((frac * 2 - 1).clamp(-1.0, 1.0), 0),
                              child: Transform.translate(
                                offset: const Offset(0, -6),
                                child: IgnorePointer(
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: Image.memory(_previewBytes!, width: 140, height: 80, fit: BoxFit.cover),
                                  ),
                                ),
                              ),
                            ),
                          Stack(
                            alignment: Alignment.center,
                            children: [
                              SliderTheme(
                                data: SliderTheme.of(context).copyWith(
                                  overlayColor: Colors.white24,
                                  trackHeight: 2,
                                ),
                                child: Slider(
                                  value: frac,
                                  onChangeStart: (_) => _holdChrome(true),
                                  onChanged: (v) {
                                    setState(() => _scrub = v);
                                    _queuePreview(v);
                                  },
                                  onChangeEnd: (v) async {
                                    _holdChrome(false);
                                    if (c == null) return;
                                    await c.seekTo(Duration(milliseconds: (v * dur.inMilliseconds).round()));
                                    setState(() {
                                      _scrub = null;
                                      _previewBytes = null;
                                    });
                                  },
                                ),
                              ),
                              mark(abA, const Color(0xFFFFC107)),
                              mark(abB, const Color(0xFFFF7043)),
                            ],
                          ),
                        ],
                      );
                    }),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text(
                      appSettings.showRemaining ? '-${_stamp(remain)}' : _stamp(dur),
                      style: const TextStyle(color: Colors.white, fontFeatures: [ui.FontFeature.tabularFigures()], fontSize: 13),
                    ),
                  ),
                ],
              ),
              SizedBox(
                height: playSize + 12,
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
                    Expanded(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (wide)
                            IconButton(
                              tooltip: 'Seek back',
                              onPressed: () => unawaited(_seekBy(-appSettings.seekStepSeconds)),
                              icon: Icon(Icons.replay_10, color: Colors.white, size: iconSize),
                            ),
                          IconButton(
                            tooltip: 'Previous',
                            onPressed: () => unawaited(_prev()),
                            icon: Icon(Icons.skip_previous, color: Colors.white, size: iconSize),
                          ),
                          IconButton(
                            onPressed: _togglePlay,
                            icon: Icon(playing ? Icons.pause_circle : Icons.play_circle, color: Colors.white, size: playSize),
                          ),
                          IconButton(
                            tooltip: 'Next',
                            onPressed: () => unawaited(_next()),
                            icon: Icon(Icons.skip_next, color: Colors.white, size: iconSize),
                          ),
                          if (wide)
                            IconButton(
                              tooltip: 'Seek forward',
                              onPressed: () => unawaited(_seekBy(appSettings.seekStepSeconds)),
                              icon: Icon(Icons.forward_10, color: Colors.white, size: iconSize),
                            ),
                        ],
                      ),
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
        ),
      ),
    ];
  }

  Widget _quickActions() {
    Widget chip(String id) {
      final on = switch (id) {
        'background' => appSettings.backgroundPlay,
        'bookmark' => item.bookmarked || appSettings.bookmarks.contains(item.path),
        'night' => night,
        'ab' => abA != null,
        _ => false,
      };
      final icon = _actionIcon(id);
      final label = AppSettings.allQuickActions[id] ?? id;
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
      child: Row(children: [for (final a in appSettings.quickActions) chip(a)]),
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
          PlaybackSession.keepAlive = false;
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
            await _applyEq();
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
        _screenshot();
      case 'zoom':
        await _zoomSheet();
      case 'skipBack':
        unawaited(_seekBy(-appSettings.seekStepSeconds));
      case 'skipForward':
        unawaited(_seekBy(appSettings.seekStepSeconds));
      case 'quickbar':
        if (mounted) {
          await Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => QuickActionsEditor(onChanged: () { if (mounted) setState(() {}); })),
          );
        }
      case 'share':
        await SharePlus.instance.share(ShareParams(files: [XFile(item.path)], title: item.title));
      case 'properties':
        await showProperties(context, item);
      case 'navbar':
        appSettings.alwaysHideNavBar = !appSettings.alwaysHideNavBar;
        SystemBars.alwaysHide = appSettings.alwaysHideNavBar;
        await appSettings.save();
        if (SystemBars.popupCount <= 0 && mounted) {
          _applySystemUi();
        }
        _flash(appSettings.alwaysHideNavBar ? 'Navigation bar hidden' : 'Navigation bar follows controls');
      default:
        break;
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
    }
    _flash(on ? (playing ? 'PIP on' : 'PIP starts when a video is playing') : 'PIP off');
    setState(() {});
  }

  void _togglePlay() {
    final c = vc;
    if (c == null) return;
    if (c.value.isPlaying) {
      c.pause();
    } else {
      unawaited(AndroidBridge.requestAudioFocus());
      c.play();
    }
    setState(() {});
    _armHide();
    unawaited(_syncBackground());
  }

  String _stamp(Duration d) {
    final n = d.isNegative ? Duration.zero : d;
    final h = n.inHours;
    final m = n.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = n.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  Future<void> _more() async {
    await showPlayerMoreSheet(
      context: context,
      item: item,
      speed: speed,
      zoomScale: _zoomScale,
      onAction: _runAction,
      onOrganize: () async {
        if (!mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => QuickActionsEditor(onChanged: () {
            if (mounted) setState(() {});
          })),
        );
      },
    );
    if (mounted) _applySystemUi();
  }
}

class _HudChip extends StatelessWidget {
  const _HudChip({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.72), borderRadius: BorderRadius.circular(12)),
      child: child,
    );
  }
}
