import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:share_plus/share_plus.dart';
import 'package:vibration/vibration.dart';
import 'package:video_player_app/playback/engine.dart';
import 'package:volume_controller/volume_controller.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'package:video_player_app/native/android_bridge.dart';
import 'package:video_player_app/core/crash.dart';
import 'package:video_player_app/player/hud.dart';
import 'package:video_player_app/core/insets.dart';
import 'package:video_player_app/library/library.dart';
import 'package:video_player_app/main.dart';
import 'package:video_player_app/core/models.dart';
import 'package:video_player_app/player/player_fx.dart';
import 'package:video_player_app/player/player_more.dart';
import 'package:video_player_app/player/player_picture.dart';
import 'package:video_player_app/settings/settings.dart';
import 'package:video_player_app/settings/settings_ui.dart';
import 'package:video_player_app/playback/session.dart';
import 'package:video_player_app/core/widgets.dart';

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

class _PlayerPageState extends State<PlayerPage> with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late int index;
  PlaybackEngine? vc;
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
  bool _ytMax = false;
  bool _ytQueue = false;
  late final AnimationController _ytMaxAnim;
  final GlobalKey _ytVideoKey = GlobalKey();
  final ScrollController _ytScroll = ScrollController();

  VideoItem get item => widget.playlist[index];
  List<VideoItem> get list => widget.playlist;
  bool get _watch => appSettings.playlistStyle == PlaylistUiStyle.youtube && _ytMaxAnim.value < 0.85;

  @override
  void initState() {
    super.initState();
    _ytMaxAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
    _ytMaxAnim.addListener(() {
      if (mounted) setState(() {});
    });
    _ytMaxAnim.addStatusListener((s) {
      if (s == AnimationStatus.completed || s == AnimationStatus.dismissed) {
        if (mounted) _applySystemUi();
      }
    });
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
      kept = PlaybackSession.controller != null &&
          PlaybackSession.controller!.hasPlayer &&
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
      final keptEngine = vc;
      if (keptEngine != null) PlaybackSession.bind(keptEngine, item);
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
      _armHide();
    } else {
      unawaited(_startNew());
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
            unawaited(AndroidBridge.setStereoVolume(appSettings.audioBalanceLeft, appSettings.audioBalanceRight));
            unawaited(vc?.play() ?? Future<void>.value());
          case 'pause':
            vc?.pause();
          case 'duck':
            vc?.setVolume(0.2);
          case 'unduck':
            vc?.setVolume(1);
            unawaited(AndroidBridge.setStereoVolume(appSettings.audioBalanceLeft, appSettings.audioBalanceRight));
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
      unawaited(PlaybackSession.onAway(
        engine: vc,
        title: item.title,
        artist: item.folderName,
      ));
    } else if (state == AppLifecycleState.resumed) {
      unawaited(PlaybackSession.onBack(engine: vc));
      _applySystemUi();
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

  Future<void> _startNew() async {
    final other = PlaybackSession.controller;
    if (other != null && other != vc) {
      await PlaybackSession.stop();
    }
    if (mounted) await _boot();
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
    final hide = !sheetOpen && !_watch && (appSettings.alwaysHideNavBar || !showUi);
    SystemBars.apply(icons: Brightness.light, contrast: true, hide: hide);
  }

  void _setYtMax(bool max) {
    if (max == _ytMax && (max ? _ytMaxAnim.isCompleted : _ytMaxAnim.isDismissed)) {
      return;
    }
    setState(() {
      _ytMax = max;
      if (!max) _ytQueue = false;
      showUi = true;
    });
    if (max && _ytScroll.hasClients) {
      _ytScroll.jumpTo(0);
    }
    if (appSettings.reduceMotion) {
      _ytMaxAnim.value = max ? 1 : 0;
    } else if (max) {
      unawaited(_ytMaxAnim.forward());
    } else {
      unawaited(_ytMaxAnim.reverse());
    }
    _applySystemUi();
    _armHide();
  }

  void _syncPip() {
    final playing = vc?.value.isPlaying ?? false;
    AndroidBridge.setPlaying(playing);
    AndroidBridge.setPipEnabled(appSettings.autoMiniplayer && playing);
  }

  Future<void> _applySpeed() async {
    final rate = speeding ? 2.0 : speed;
    try {
      await vc?.applyTempo(rate: rate, pitchShift: appSettings.pitchShift);
    } catch (e, s) {
      CrashLog.record('SPEED', '$e', s);
    }
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
    final gen = ++_playerGen;
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
    final existing = vc;
    PlaybackEngine? opened;
    try {
      await CrashLog.breadcrumb('Open video ${item.path}');
      late final PlaybackEngine engine;
      if (existing != null && existing.hasPlayer) {
        engine = existing;
        try {
          await engine.open(item.path, hwdec: PlaybackSession.hwdecName());
        } catch (_) {
          await engine.open(item.path, hwdec: 'no');
        }
      } else {
        engine = await PlaybackSession.openWithFallback(item);
        opened = engine;
        if (!mounted || gen != _playerGen) {
          try {
            await engine.close();
          } catch (_) {}
          return;
        }
        engine.addListener(_tick);
      }
      if (!mounted || gen != _playerGen) {
        if (opened != null) {
          try {
            await opened.close();
          } catch (_) {}
        }
        return;
      }
      if (appSettings.resumePlayback) {
        final p = appSettings.resumeMap[item.path] ?? item.progress;
        final dur = engine.value.duration;
        if (p > 0 && p < 0.97 && dur.inMilliseconds > 0) {
          await engine.seekTo(Duration(milliseconds: (dur.inMilliseconds * p).round()));
        }
      }
      await engine.setLooping(appSettings.playMode == PlayMode.repeatOne);
      if (engine.value.hasError) {
        throw StateError(engine.value.errorDescription ?? 'Player failed to start');
      }
      vc = engine;
      PlaybackSession.bind(engine, item);
      _openFails = 0;
      _endedLatch = false;
      await AndroidBridge.requestAudioFocus();
      await engine.play();
      _lastPlaying = true;
      _syncPip();
      unawaited(_applySpeed());
      unawaited(AndroidBridge.preparePreview(item.path));
      unawaited(_applyEq());
      _applyRotation();
      if (mounted && gen == _playerGen) setState(() => ready = true);
      _armHide();
    } catch (e, s) {
      await CrashLog.breadcrumb('Open failed ${item.path}: $e');
      if (opened != null) {
        try {
          await opened.close();
        } catch (_) {}
        if (gen == _playerGen) vc = null;
      }
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
        final desc = c.value.errorDescription ?? '';
        unawaited(CrashLog.breadcrumb('Source error ${item.path}: $desc'));
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
      }
      if (!_endedLatch &&
          (c.value.completed ||
              (c.value.duration > Duration.zero &&
                  c.value.position >= c.value.duration - const Duration(milliseconds: 400) &&
                  !c.value.isPlaying))) {
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
    await AndroidBridge.setStereoVolume(appSettings.audioBalanceLeft, appSettings.audioBalanceRight);
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
    events?.cancel();
    _zoomHudTimer?.cancel();
    _leftHide?.cancel();
    _rightHide?.cancel();
    _midHide?.cancel();
    _ytMaxAnim.dispose();
    _ytScroll.dispose();
    vc?.removeListener(_tick);
    _persistProgress();
    unawaited(_unhookBrightness());
    if (PlaybackSession.replacing) {
      vc = null;
    } else if (_handedOff) {
      if (!PlaybackSession.keepAlive) {
        final dying = vc;
        vc = null;
        try {
          dying?.close();
        } catch (_) {}
        unawaited(AndroidBridge.stopBackground());
        unawaited(AndroidBridge.abandonAudioFocus());
      }
    } else {
      var keep = false;
      try {
        keep = (appSettings.inAppMiniplayer || appSettings.backgroundPlay) &&
            vc != null &&
            PlaybackSession.item != null &&
            PlaybackSession.controller != null &&
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
      } else if (PlaybackSession.controller == null) {
        vc = null;
      } else {
        PlaybackSession.keepAlive = false;
        final dying = vc;
        vc = null;
        try {
          dying?.close();
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
        if (_ytQueue) {
          setState(() => _ytQueue = false);
          return;
        }
        if (appSettings.playlistStyle == PlaylistUiStyle.youtube &&
            (_ytMax || _ytMaxAnim.value > 0.01)) {
          _setYtMax(false);
          return;
        }
        _armMiniThenPop();
      },
      child: appSettings.playlistStyle == PlaylistUiStyle.youtube
          ? _youtubePage(c, size, pad)
          : _fullScaffold(c, size, pad),
    );
  }

  Widget _fullScaffold(PlaybackEngine? c, Size size, EdgeInsets pad) {
    return _playerChrome(
      _stage(c, size, pad, watch: false),
    );
  }

  bool get _portraitVideo {
    final s = _sourceVideoSize();
    return s.height > s.width;
  }

  Size _sourceVideoSize() {
    try {
      final s = vc?.value.size;
      if (s != null && s.width > 1 && s.height > 1) return s;
    } catch (_) {}
    if (item.width > 1 && item.height > 1) {
      return Size(item.width.toDouble(), item.height.toDouble());
    }
    return const Size(16, 9);
  }

  double _ytMaxAnimT() => Curves.easeInOutCubic.transform(_ytMaxAnim.value);

  double _ytPaneMaxH(Size screen, double topGap, double t) {
    final usable = (screen.height - topGap).clamp(120.0, screen.height);
    final w = screen.width;
    final natural = _portraitVideo ? w * 16 / 9 : w * 9 / 16;
    final cap916 = w * 16 / 9;
    final leave = ui.lerpDouble(math.min(128.0, usable * 0.18), 0, t)!;
    final watchH = math.min(natural, math.min(cap916, usable - leave)).clamp(120.0, usable);
    return ui.lerpDouble(watchH, screen.height, t)!;
  }

  Widget _youtubePage(PlaybackEngine? c, Size size, EdgeInsets pad) {
    final t = _ytMaxAnimT();
    final light = Theme.of(context).brightness == Brightness.light;
    final topGap = ui.lerpDouble(pad.top, 0, t)!;
    final watchLike = t < 0.85;
    final maxH = _ytPaneMaxH(size, topGap, t);
    final minH = ui.lerpDouble(96, size.height, t)!.clamp(96.0, size.height);
    final bg = Color.lerp(Theme.of(context).colorScheme.surface, Colors.black, t)!;
    final stagePad = EdgeInsets.lerp(EdgeInsets.zero, pad, t)!;
    final scheme = Theme.of(context).colorScheme;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemBars.overlay(icons: (watchLike && light) ? Brightness.dark : Brightness.light),
      child: Scaffold(
        backgroundColor: bg,
        body: Column(
          children: [
            if (topGap > 0.5) SizedBox(height: topGap),
            Expanded(
              child: CustomScrollView(
                controller: _ytScroll,
                physics: t > 0.02
                    ? const NeverScrollableScrollPhysics()
                    : const AlwaysScrollableScrollPhysics(),
                clipBehavior: Clip.hardEdge,
                slivers: [
                  SliverPersistentHeader(
                    pinned: true,
                    delegate: _YtVideoHeader(
                      minH: math.min(minH, maxH),
                      maxH: math.max(minH, maxH),
                      builder: (h) => _stage(c, Size(size.width, h), stagePad, watch: watchLike),
                    ),
                  ),
                  SliverOpacity(
                    opacity: (1 - t).clamp(0.0, 1.0),
                    sliver: SliverIgnorePointer(
                      ignoring: t > 0.2,
                      sliver: SliverToBoxAdapter(child: _watchMeta()),
                    ),
                  ),
                  SliverOpacity(
                    opacity: (1 - t).clamp(0.0, 1.0),
                    sliver: SliverIgnorePointer(
                      ignoring: t > 0.2,
                      sliver: SliverPadding(
                        padding: EdgeInsets.only(bottom: 24 + pad.bottom),
                        sliver: SliverList(
                          delegate: SliverChildBuilderDelegate(
                            (_, i) => Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              child: _watchQueueTile(i, scheme),
                            ),
                            childCount: list.length,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stage(PlaybackEngine? c, Size size, EdgeInsets pad, {required bool watch}) {
    final g = !watch;
    return Listener(
        onPointerDown: g ? (e) => _pinchDown(e, size) : null,
        onPointerMove: g ? (e) => _pinchMove(e, size) : null,
        onPointerUp: g ? (e) => _pinchUp(e.pointer) : null,
        onPointerCancel: g ? (e) => _pinchUp(e.pointer) : null,
        child: Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) {
                _tapPos = d.localPosition;
                _tapBurst = false;
                if (!g) return;
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
                if (!g) {
                  if (locked) return;
                  _setUi(!showUi);
                  return;
                }
                if (locked || _pts.length >= 2 || _pinching || _gesture == 'pan' || _gesture == 'hold' || _gesture == 'pinch') return;
                if (_tapBurst || _ateTap) {
                  _tapBurst = false;
                  _ateTap = false;
                  return;
                }
                _uiBeforeTap = showUi;
                _setUi(!showUi);
              },
              onLongPressStart: !g
                  ? null
                  : (_) async {
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
              onLongPressEnd: !g
                  ? null
                  : (_) async {
                if (!speeding) return;
                speeding = false;
                _gesture = '';
                unawaited(_applySpeed());
                setState(() {});
              },
              onPanStart: !g
                  ? null
                  : (d) {
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
              onPanUpdate: !g
                  ? null
                  : (d) {
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
                  brightness = (panBase - dy / size.height).clamp(0.0, 1.0).toDouble();
                  unawaited(ScreenBrightness().setApplicationScreenBrightness(brightness));
                  if (appSettings.rememberBrightness) {
                    appSettings.brightness = brightness;
                  }
                  _flash('Brightness ${(brightness * 100).round()}%');
                  setState(() {});
                } else if (panKind == 'volume') {
                  volume = (panBase - dy / size.height).clamp(0.0, 1.0).toDouble();
                  try {
                    VolumeController.instance.setVolume(volume);
                  } catch (_) {}
                  _flash('Volume ${(volume * 100).round()}%');
                  setState(() {});
                }
              },
              onPanEnd: !g
                  ? null
                  : (_) async {
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
                child: ClipRect(
                  child: () {
                    try {
                      if (c != null && c.video != null) {
                        final w = size.width <= 0 ? 1.0 : size.width;
                        final h = size.height <= 0 ? 1.0 : size.height;
                        return _video(c, Size(w, h));
                      }
                    } catch (_) {}
                    return const Center(child: CircularProgressIndicator());
                  }(),
                ),
              ),
            ),
            if (g)
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
            if (_scrub != null && _previewBytes != null && appSettings.showSeekPreview && !(showUi && !locked))
              Positioned(
                left: 0,
                right: 0,
                bottom: 96 + pad.bottom,
                child: IgnorePointer(
                  child: Center(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.memory(_previewBytes!, width: 160, height: 90, fit: BoxFit.cover),
                    ),
                  ),
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
            if (showUi && !locked && !watch)
              HudLayer(
                fabs: decodeHud(appSettings.hudFabsJson),
                pad: pad,
                bottomReserve: 24,
                onTap: (id) => unawaited(_runAction(id)),
              ),
            if (showUi && !locked) ..._chrome(c, size, watch: watch, pad: pad),
            if (appSettings.playlistStyle == PlaylistUiStyle.youtube && (watch ? (!showUi || locked || size.height < 168) : true))
              _ytFrameButtons(watch: watch, pad: pad, stageH: size.height),
            if (_scrub != null && !(showUi && !locked)) _seekHud(c, pad),
          ],
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

  Widget _ytFrameButtons({required bool watch, required EdgeInsets pad, required double stageH}) {
    final extra = watch ? 0.0 : pad.bottom;
    final transport = showUi && !locked && stageH >= 168;
    final bottom = (transport ? 118.0 : (watch ? 8.0 : 20.0)) + extra;
    return Positioned(
      right: 4 + pad.right,
      bottom: bottom,
      child: Material(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(24),
        child: IconButton(
          tooltip: watch ? 'Maximize' : 'Minimize',
          onPressed: () => _setYtMax(watch),
          icon: AnimatedSwitcher(
            duration: appSettings.reduceMotion ? Duration.zero : const Duration(milliseconds: 220),
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: ScaleTransition(scale: anim, child: child),
            ),
            child: Icon(
              watch ? Icons.fullscreen : Icons.fullscreen_exit,
              key: ValueKey(watch),
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }

  Widget _ytQueueOverlay() {
    final size = MediaQuery.sizeOf(context);
    final pad = SystemBars.rawOf(context);
    final landscape = size.width > size.height;
    final panelW = landscape ? math.min(420.0, size.width * 0.46) : size.width;
    return Positioned.fill(
      child: Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: () => setState(() => _ytQueue = false),
            child: ColoredBox(color: Colors.black.withValues(alpha: 0.55)),
          ),
        ),
        Align(
          alignment: landscape ? Alignment.centerRight : Alignment.bottomCenter,
          child: Material(
            color: Theme.of(context).colorScheme.surface,
            elevation: 16,
            borderRadius: landscape
                ? const BorderRadius.horizontal(left: Radius.circular(16))
                : const BorderRadius.vertical(top: Radius.circular(16)),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              width: panelW,
              height: landscape ? size.height : size.height * 0.92,
              child: _youtubeQueueBody(
                context,
                pad,
                onClose: () => setState(() => _ytQueue = false),
                onPick: (i) {
                  setState(() => _ytQueue = false);
                  index = i;
                  unawaited(_openCurrent());
                },
              ),
            ),
          ),
        ),
      ],
      ),
    );
  }

  Widget _watchMeta() {
    final scheme = Theme.of(context).colorScheme;
    final created = item.created ?? item.modified;
    final bookmarked = item.bookmarked || appSettings.bookmarks.contains(item.path);
    final pinned = appSettings.pinned.contains(item.path);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(item.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, height: 1.25)),
          const SizedBox(height: 6),
          Text(
            '${DateFormat.yMMMd().format(created)}  ·  ${formatBytes(item.size)}',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              primary: false,
              children: [
                _watchChip('bookmark', bookmarked ? Icons.bookmark : Icons.bookmark_outline, 'Bookmark', on: bookmarked),
                const SizedBox(width: 8),
                _watchChip('pin', pinned ? Icons.push_pin : Icons.push_pin_outlined, 'Pin', on: pinned),
                const SizedBox(width: 8),
                _watchChip('share', Icons.share_outlined, 'Share'),
                const SizedBox(width: 8),
                _watchChip('properties', Icons.info_outline, 'Properties'),
                const SizedBox(width: 8),
                _watchChip('delete', Icons.delete_outline, 'Delete'),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text('Path: ${item.path}', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
          const SizedBox(height: 16),
          Row(
            children: [
              const Expanded(child: Text('Up next', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
              PopupMenuButton<PlayMode>(
                tooltip: 'Order',
                onSelected: (m) {
                  setState(() => appSettings.playMode = m);
                  appSettings.save();
                },
                itemBuilder: (_) => [
                  for (final m in PlayMode.values) PopupMenuItem(value: m, child: Text(_playModeLabel(m))),
                ],
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                  child: Row(
                    children: [
                      Text(_playModeLabel(appSettings.playMode), style: TextStyle(color: scheme.primary, fontSize: 13, fontWeight: FontWeight.w600)),
                      Icon(Icons.expand_more, color: scheme.primary, size: 18),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _watchChip(String id, IconData icon, String label, {bool on = false}) {
    final scheme = Theme.of(context).colorScheme;
    return ActionChip(
      avatar: Icon(icon, size: 18, color: on ? scheme.primary : scheme.onSurfaceVariant),
      label: Text(label),
      onPressed: () => unawaited(_runAction(id)),
    );
  }

  Widget _watchQueueTile(int i, ColorScheme scheme) {
    final v = list[i];
    final current = i == index;
    return InkWell(
      onTap: () {
        if (i == index) return;
        index = i;
        unawaited(_openCurrent());
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            SizedBox(
              width: 120,
              height: 68,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  VideoThumb(item: v, radius: 8),
                  if (current)
                    const ColoredBox(
                      color: Color(0x66000000),
                      child: Center(child: Icon(Icons.equalizer, color: Colors.white)),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    v.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: current ? FontWeight.w700 : FontWeight.w600, height: 1.25),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${formatDuration(v.duration)}  ·  ${formatBytes(v.size)}',
                    style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _seekHud(PlaybackEngine? c, EdgeInsets pad) {
    final pos = c?.value.position ?? Duration.zero;
    final dur = c?.value.duration ?? Duration.zero;
    final frac = dur.inMilliseconds == 0 ? 0.0 : ((_scrub ?? (pos.inMilliseconds / dur.inMilliseconds)).clamp(0.0, 1.0).toDouble());
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
  Widget _video(PlaybackEngine c, Size screen) {
    if (_handedOff) return const ColoredBox(color: Colors.black);
    try {
      if (!c.hasPlayer || c.video == null) {
        return const SizedBox.expand(child: Center(child: CircularProgressIndicator()));
      }
    } catch (_) {
      return const SizedBox.expand();
    }
    Widget player = AppVideo(key: _ytVideoKey, engine: c);
    var vw = c.value.size.width;
    var vh = c.value.size.height;
    if (vw <= 1 || vh <= 1) {
      vw = screen.width.clamp(1, 10000).toDouble();
      vh = screen.height.clamp(1, 10000).toDouble();
    }
    player = VlcFit(visW: vw, visH: vh, screen: screen, mode: aspect, child: player);
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
    return ClipRect(
      child: Center(
        child: VideoPicture(
          looks: PictureLooks.current(invert: invert, mirror: mirror, night: night),
          child: player,
        ),
      ),
    );
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

  List<String> _titleActionIds() {
    final raw = appSettings.titleActions.isEmpty ? const <String>['more'] : appSettings.titleActions;
    if (appSettings.playlistStyle != PlaylistUiStyle.youtube) return List<String>.from(raw);
    return [for (final id in raw) if (id != 'playlist') id];
  }

  List<Widget> _chrome(PlaybackEngine? c, Size size, {required bool watch, required EdgeInsets pad}) {
    final pos = c?.value.position ?? Duration.zero;
    final dur = c?.value.duration ?? Duration.zero;
    final playing = c?.value.isPlaying ?? false;
    final remain = dur - pos;
    final iconSize = appSettings.largeControls ? 40.0 : 32.0;
    final playSize = appSettings.largeControls ? 68.0 : 56.0;
    final wide = size.width >= 600;
    final compact = watch && size.height < 168;
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
                  if (!watch)
                    Expanded(
                      child: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                    ),
                  if (watch)
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          reverse: true,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (final id in _titleActionIds()) _titleBtn(id),
                            ],
                          ),
                        ),
                      ),
                    )
                  else
                    for (final id in _titleActionIds()) _titleBtn(id),
                ],
              ),
              if (!watch) _quickActions(),
              if (!watch && (appSettings.showClock || appSettings.showBattery))
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
      if (!compact)
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
                          : ((_scrub ?? (pos.inMilliseconds / dur.inMilliseconds)).clamp(0.0, 1.0).toDouble());
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
                              alignment: Alignment((frac * 2 - 1).clamp(-1.0, 1.0).toDouble(), 0),
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
                    if (!watch)
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
                      )
                    else
                      const SizedBox(width: 48),
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
                    if (!watch)
                      IconButton(
                        onPressed: _aspectSheet,
                        icon: const Icon(Icons.aspect_ratio, color: Colors.white),
                        tooltip: 'Screen mode',
                      )
                    else
                      IconButton(
                        tooltip: 'Maximize',
                        onPressed: () => _setYtMax(true),
                        icon: const Icon(Icons.fullscreen, color: Colors.white),
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
        'pin' => appSettings.pinned.contains(item.path),
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
          final done = await library.deleteVideos([item]);
          if (!done && mounted) showAllFilesFailed(context, 'Delete');
          PlaybackSession.keepAlive = false;
          widget.onChanged();
          if (mounted) Navigator.pop(context);
        }
      case 'bookmark':
        _toggleBookmark();
      case 'pin':
        _togglePin();
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
      case 'volume':
        await _volumeSheet();
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
        unawaited(_openCurrent());
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

  void _togglePin() {
    if (appSettings.pinned.contains(item.path)) {
      appSettings.pinned.remove(item.path);
    } else {
      appSettings.pinned.add(item.path);
    }
    appSettings.save();
    widget.onChanged();
    setState(() {});
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
    try {
      await Permission.notification.request();
    } catch (_) {}
    await PlaybackSession.syncNotification(engine: vc, title: item.title, artist: item.folderName);
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

class _YtVideoHeader extends SliverPersistentHeaderDelegate {
  _YtVideoHeader({
    required this.minH,
    required this.maxH,
    required this.builder,
  });

  final double minH;
  final double maxH;
  final Widget Function(double height) builder;

  @override
  double get minExtent => minH;

  @override
  double get maxExtent => math.max(minH, maxH);

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final h = (maxExtent - shrinkOffset).clamp(minExtent, maxExtent).toDouble();
    return ColoredBox(
      color: Colors.black,
      child: builder(h),
    );
  }

  @override
  bool shouldRebuild(covariant _YtVideoHeader old) => minH != old.minH || maxH != old.maxH;
}
