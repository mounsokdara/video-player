import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:video_player_app/core/developer_log.dart';
import 'package:video_player_app/playback/render_profile.dart';
import 'package:video_player_app/settings/settings.dart';

class EngineValue {
  const EngineValue({
    this.isInitialized = false,
    this.isPlaying = false,
    this.isBuffering = false,
    this.hasError = false,
    this.completed = false,
    this.errorDescription,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.size = Size.zero,
  });

  final bool isInitialized;
  final bool isPlaying;
  final bool isBuffering;
  final bool hasError;
  final bool completed;
  final String? errorDescription;
  final Duration position;
  final Duration duration;
  final Size size;
}

class PlaybackEngine extends ChangeNotifier {
  static final _alive = <PlaybackEngine>{};

  Player? _player;
  VideoController? video;
  final _subs = <StreamSubscription<dynamic>>[];
  EngineValue value = const EngineValue();
  bool _closed = false;
  String? _hwdec;
  Future<void>? _inFlight;
  double _rate = 1;
  bool _pitchShift = false;
  bool wantPlay = false;
  String debugInfo = '';
  String? _codecWarn;

  bool get hasPlayer => _player != null && !_closed;

  Future<void> open(String path, {required String hwdec}) async {
    await _queue(() => _openBody(path, hwdec: hwdec));
  }

  Future<void> _queue(Future<void> Function() job) async {
    while (_inFlight != null) {
      try {
        await _inFlight;
      } catch (_) {}
    }
    final gate = Completer<void>();
    _inFlight = gate.future;
    try {
      await job();
    } finally {
      if (!gate.isCompleted) gate.complete();
      if (identical(_inFlight, gate.future)) _inFlight = null;
    }
  }

  Future<void> _openBody(String path, {required String hwdec}) async {
    _closed = false;
    _alive.add(this);
    await _pauseOthers();
    value = const EngineValue();
    notifyListeners();
    if (_player == null) {
      final player = Player(
        configuration: const PlayerConfiguration(
          pitch: false,
          title: 'Video Player',
          logLevel: MPVLogLevel.warn,
        ),
      );
      _player = player;
      video = VideoController(
        player,
        configuration: VideoControllerConfiguration(
          enableHardwareAcceleration: true,
          hwdec: hwdec,
          androidAttachSurfaceAfterVideoParameters: true,
        ),
      );
      _bind(player);
    }
    final player = _player!;
    _hwdec = hwdec;
    await _applyHwdec(player, hwdec);
    await _resetPerFile(player);
    await _applyPitchCorrection(player, _pitchShift);
    await player.open(Media(_mediaUri(path)), play: false);
    await _waitReady(player);
    final decoded = await _prepareRender(player);
    if (!decoded && _codecWarn != null && !value.hasError) {
      // No decoder could produce video at all: a real failure, so let the
      // caller retry (software) as before.
      value = EngineValue(hasError: true, errorDescription: _codecWarn);
      notifyListeners();
    }
    await player.setRate(_rate <= 0 ? 1 : _rate);
    _emit(player);
    if (value.hasError) {
      throw StateError(value.errorDescription ?? 'Source error');
    }
  }

  Future<void> applyTempo({required double rate, required bool pitchShift}) async {
    _rate = rate.clamp(0.25, 8.0).toDouble();
    _pitchShift = pitchShift;
    final player = _player;
    if (player == null) return;
    await _applyPitchCorrection(player, pitchShift);
    try {
      await player.setRate(_rate);
    } catch (_) {}
  }

  Future<void> _applyPitchCorrection(Player player, bool pitchShift) async {
    try {
      final platform = player.platform;
      if (platform is NativePlayer) {
        await platform.setProperty('audio-pitch-correction', pitchShift ? 'no' : 'yes');
      }
    } catch (_) {}
  }

  Future<void> _applyHwdec(Player player, String hwdec) async {
    try {
      final platform = player.platform;
      if (platform is NativePlayer) {
        await platform.setProperty('hwdec', hwdec);
        try {
          await platform.setProperty('hwdec-codecs', 'h264,hevc,vp8,vp9,av1,mpeg4,mpeg2video');
        } catch (_) {}
        try {
          await platform.setProperty('video-sync', 'audio');
        } catch (_) {}
        try {
          await platform.setProperty('vd-lavc-dr', 'no');
        } catch (_) {}
        return;
      }
      await (platform as dynamic).setProperty('hwdec', hwdec);
    } catch (_) {}
  }

  Future<void> _setProp(Player player, String name, String value) async {
    try {
      final platform = player.platform;
      if (platform is NativePlayer) await platform.setProperty(name, value);
    } catch (_) {}
  }

  Future<String> _getProp(Player player, String name) async {
    try {
      final platform = player.platform;
      if (platform is NativePlayer) {
        return (await platform.getProperty(name)).trim().toLowerCase();
      }
    } catch (_) {}
    return '';
  }

  // ---- render pipeline ---------------------------------------------------
  //
  // The picture goes: decoder -> mpv filter chain (fps limit, resolution
  // limit, 8-bit conversion) -> GL renderer (tone-mapping) -> Flutter texture.
  // HDR and >8-bit sources use software decode and 8-bit frames, because the
  // hardware path shows a black picture on many phones.

  SourceInfo? _src;
  bool _convert = false;
  bool _sdrMode = false;
  String? _lastVf;

  /// True while the current video is HDR or >8-bit and uses the safe path.
  bool get hdrActive => _convert;

  /// True = SDR look, false = HDR look. Only matters while [hdrActive].
  bool get sdrMode => _sdrMode;

  SourceInfo? get source => _src;

  /// Neutral settings for every new file. The player is reused between files,
  /// so anything the previous video changed has to be undone here.
  Future<void> _resetPerFile(Player player) async {
    _src = null;
    _convert = false;
    _lastVf = null;
    debugInfo = '';
    _codecWarn = null;
    await _setProp(player, 'vf', '');
    await _setProp(player, 'tone-mapping', 'auto');
    await _setProp(player, 'hdr-compute-peak', 'auto');
    await _setProp(player, 'target-peak', 'auto');
    await _setProp(player, 'target-trc', 'auto');
    await _setProp(player, 'target-prim', 'auto');
    await _setProp(player, 'gamut-mapping-mode', 'auto');
    await _setProp(player, 'gamma', '0');
    await _setProp(player, 'video-output-levels', 'auto');
    await _setProp(player, 'dither-depth', 'no');
  }

  Future<SourceInfo> _probeSource(Player player) async {
    var pix = '';
    var gamma = '';
    for (var i = 0; i < 30 && !_closed; i++) {
      pix = await _getProp(player, 'video-params/pixelformat');
      gamma = await _getProp(player, 'video-params/gamma');
      if (pix.isNotEmpty && gamma.isNotEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
    Future<double?> numOf(String name) async => double.tryParse(await _getProp(player, name));
    return SourceInfo(
      pix: pix,
      gamma: gamma,
      primaries: await _getProp(player, 'video-params/primaries'),
      matrix: await _getProp(player, 'video-params/colormatrix'),
      sigPeak: await _getProp(player, 'video-params/sig-peak'),
      w: ((await numOf('video-params/w')) ?? 0).round(),
      h: ((await numOf('video-params/h')) ?? 0).round(),
      fps: (await numOf('container-fps')) ?? (await numOf('estimated-vf-fps')) ?? 0,
    );
  }

  /// Runs once per file, after it opened. Returns false when no decoder
  /// produced any video format.
  Future<bool> _prepareRender(Player player) async {
    final rs = RenderSettings.instance;
    await rs.load();
    if (_closed) return true;
    final src = await _probeSource(player);
    _src = src;
    _convert = src.needsConvert;
    _sdrMode = rs.autoSdr || (appSettings.rememberHdr && !appSettings.hdrOn);
    DeveloperLog.append('video ${src.describe()} hwdec=$_hwdec');
    final switchToSoftware = _convert;
    if (switchToSoftware) await _setProp(player, 'hwdec', 'no');
    await _applyRender(player);
    if (switchToSoftware) {
      // The decoder has to restart for the hardware -> software switch.
      try {
        await player.seek(player.state.position);
      } catch (_) {}
    }
    return src.decoded;
  }

  /// Builds the plan from the current settings and pushes it to mpv.
  Future<void> _applyRender(Player player) async {
    final src = _src;
    if (src == null || _closed) return;
    final plan = RenderProfile.plan(
      settings: RenderSettings.instance,
      src: src,
      screen: ScreenInfo.current(),
    );
    await _applyVf(player, plan);
    if (_convert) await _pushTuning(player);
    final mode = _convert ? (_sdrMode ? 'HDR->SDR' : 'HDR look') : 'SDR source';
    debugInfo = '$mode | ${plan.describe(src)} | ${src.describe()}';
    DeveloperLog.append('render $debugInfo');
    notifyListeners();
  }

  /// Applies the known-good chain first, then tries to add the limiters. If
  /// this libmpv build lacks a filter, the known-good chain stays in place.
  Future<void> _applyVf(Player player, RenderPlan plan) async {
    if (_lastVf == plan.full) return;
    await _setProp(player, 'vf', plan.baseline);
    if (plan.full != plan.baseline) {
      await _setProp(player, 'vf', plan.full);
      final back = await _getProp(player, 'vf');
      final missing = back.isNotEmpty && plan.tokens.any((t) => !back.contains(t));
      if (missing) {
        DeveloperLog.append('render: filter missing in this libmpv build, using ${plan.baseline.isEmpty ? 'no filter' : plan.baseline}. wanted=${plan.full} got=$back');
        await _setProp(player, 'vf', plan.baseline);
      }
    }
    _lastVf = plan.full;
  }

  Future<void> _pushTuning(Player player) async {
    final t = RenderSettings.instance.tuning(sdr: _sdrMode);
    await _setProp(player, 'target-peak', '${t.peak}');
    await _setProp(player, 'gamma', '${t.gamma}');
  }

  /// Pushes only the brightness values; cheap enough to call while dragging.
  Future<void> retune() async {
    final player = _player;
    if (player == null || _closed || !_convert) return;
    await _pushTuning(player);
  }

  /// Re-applies fps limit, resolution limit and brightness after the user
  /// changed a setting, without reopening the video.
  Future<void> reapplyRender() async {
    final player = _player;
    if (player == null || _closed) return;
    _lastVf = null;
    await _applyRender(player);
  }

  /// Switches the current HDR video between the SDR and HDR look.
  Future<void> setSdrMode(bool sdr) async {
    _sdrMode = sdr;
    appSettings.hdrOn = !sdr;
    if (appSettings.rememberHdr) unawaited(appSettings.save());
    final player = _player;
    if (player != null && _convert && !_closed) await _pushTuning(player);
    notifyListeners();
  }

  String _mediaUri(String path) {
    if (path.startsWith('content:') ||
        path.startsWith('http:') ||
        path.startsWith('https:') ||
        path.startsWith('file:') ||
        path.startsWith('rtsp:') ||
        path.startsWith('rtmp:')) {
      return path;
    }
    return Uri.file(path).toString();
  }

  Future<void> _waitReady(Player player) async {
    final start = DateTime.now();
    while (DateTime.now().difference(start) < const Duration(seconds: 12)) {
      if (_closed) return;
      _emit(player);
      if (value.hasError) return;
      if (player.state.duration > Duration.zero || _pixels(player) > 0 || player.state.playing) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
  }

  int _pixels(Player player) {
    final w = player.state.width ?? 0;
    final h = player.state.height ?? 0;
    if (w > 1 && h > 1) return w * h;
    return 0;
  }

  Size _sizeOf(Player player) {
    final w = player.state.width ?? 0;
    final h = player.state.height ?? 0;
    if (w > 1 && h > 1) return Size(w.toDouble(), h.toDouble());
    return Size.zero;
  }

  void _bind(Player player) {
    void push() => _emit(player);
    _subs.addAll([
      player.stream.playing.listen((_) => push()),
      player.stream.completed.listen((done) {
        if (!done) {
          push();
          return;
        }
        value = EngineValue(
          isInitialized: true,
          isPlaying: false,
          isBuffering: false,
          hasError: value.hasError,
          completed: true,
          errorDescription: value.errorDescription,
          position: player.state.position,
          duration: player.state.duration,
          size: _sizeOf(player),
        );
        notifyListeners();
      }),
      player.stream.position.listen((_) => push()),
      player.stream.duration.listen((_) => push()),
      player.stream.buffering.listen((_) => push()),
      player.stream.width.listen((_) => push()),
      player.stream.height.listen((_) => push()),
      player.stream.log.listen((e) => DeveloperLog.append('mpv[${e.prefix}] ${e.text.trim()}')),
      player.stream.error.listen((e) {
        // A hardware decoder that fails to start logs "Could not open codec"
        // while mpv quietly falls back to software decoding. That is not a
        // failed open; _openBody decides after checking a frame was decoded.
        if (e.toLowerCase().contains('could not open codec')) {
          _codecWarn = e;
          DeveloperLog.append('non-fatal decoder message ignored: $e');
          return;
        }
        value = EngineValue(
          isInitialized: value.isInitialized,
          isPlaying: false,
          hasError: true,
          completed: false,
          errorDescription: e,
          position: value.position,
          duration: value.duration,
          size: value.size,
        );
        notifyListeners();
      }),
    ]);
  }

  void _emit(Player player) {
    if (value.hasError) return;
    final size = _sizeOf(player);
    final ready = player.state.duration > Duration.zero || size.width > 1 || player.state.playing;
    final playing = player.state.playing;
    value = EngineValue(
      isInitialized: ready,
      isPlaying: playing,
      isBuffering: player.state.buffering,
      hasError: false,
      completed: playing ? false : value.completed,
      position: player.state.position,
      duration: player.state.duration,
      size: size,
    );
    notifyListeners();
  }

  Future<void> play() async {
    wantPlay = true;
    _alive.add(this);
    await _pauseOthers();
    await _player?.play();
  }

  Future<void> pause() async {
    wantPlay = false;
    await _player?.pause();
  }

  Future<void> _pauseOthers() async {
    final others = _alive.where((e) => !identical(e, this) && !e._closed).toList();
    for (final e in others) {
      e.wantPlay = false;
      try {
        await e._player?.pause();
      } catch (_) {}
    }
  }

  Future<void> seekTo(Duration d) async {
    await _player?.seek(d);
  }

  Future<void> setVolume(double v) async {
    await _player?.setVolume((v.clamp(0.0, 1.0) * 100).toDouble());
  }


  Future<void> setLooping(bool on) async {
    await _player?.setPlaylistMode(on ? PlaylistMode.single : PlaylistMode.none);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    wantPlay = false;
    _alive.remove(this);
    await _disposePlayer();
    super.dispose();
  }

  @override
  void dispose() {
    unawaited(close());
  }

  Future<void> _disposePlayer() async {
    _alive.remove(this);
    for (final s in _subs) {
      try {
        await s.cancel();
      } catch (_) {}
    }
    _subs.clear();
    final p = _player;
    _player = null;
    video = null;
    _hwdec = null;
    value = const EngineValue();
    notifyListeners();
    if (p == null) return;
    try {
      await p.pause();
    } catch (_) {}
    try {
      final platform = p.platform;
      if (platform is NativePlayer) {
        await platform.setProperty('vo', 'null');
      }
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 40));
    try {
      await p.stop();
    } catch (_) {}
    try {
      await p.dispose();
    } catch (_) {}
  }
}

class AppVideo extends StatefulWidget {
  const AppVideo({super.key, required this.engine, this.fit = BoxFit.fill});
  final PlaybackEngine engine;
  final BoxFit fit;

  @override
  State<AppVideo> createState() => _AppVideoState();
}

class _AppVideoState extends State<AppVideo> {
  VideoController? _controller;
  String _info = '';

  @override
  void initState() {
    super.initState();
    _controller = widget.engine.video;
    widget.engine.addListener(_onEngine);
  }

  @override
  void didUpdateWidget(covariant AppVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.engine, widget.engine)) {
      oldWidget.engine.removeListener(_onEngine);
      widget.engine.addListener(_onEngine);
      _controller = widget.engine.video;
    }
  }

  @override
  void dispose() {
    widget.engine.removeListener(_onEngine);
    super.dispose();
  }

  void _onEngine() {
    final next = widget.engine.video;
    final info = widget.engine.debugInfo;
    if (mounted && (!identical(next, _controller) || info != _info)) {
      setState(() {
        _controller = next;
        _info = info;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    if (c == null) return const ColoredBox(color: Colors.black);
    final video = Video(
      controller: c,
      fill: Colors.black,
      fit: widget.fit,
      controls: NoVideoControls,
    );
    if (!(appSettings.developerEnabled && appSettings.debugLog) || _info.isEmpty) {
      return video;
    }
    return Stack(
      fit: StackFit.passthrough,
      children: [
        video,
        Positioned(
          left: 6,
          top: 40,
          right: 6,
          child: IgnorePointer(
            child: Text(
              _info,
              style: const TextStyle(color: Colors.yellowAccent, fontSize: 10, backgroundColor: Colors.black54),
            ),
          ),
        ),
      ],
    );
  }
}
