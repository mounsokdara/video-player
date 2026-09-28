import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:video_player_app/core/developer_log.dart';

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
  bool _eightBit = false;

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
    final wantHw = hwdec != 'no';
    final hadHw = _hwdec != null && _hwdec != 'no';
    if (_player != null && wantHw != hadHw) {
      await _disposePlayer();
    }
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
          enableHardwareAcceleration: wantHw,
          hwdec: hwdec,
        ),
      );
      _bind(player);
    }
    final player = _player!;
    _hwdec = hwdec;
    await _applyHwdec(player, hwdec);
    await _applyHdrPipeline(player);
    await _applyPitchCorrection(player, _pitchShift);
    await player.open(Media(_mediaUri(path)), play: false);
    await _waitReady(player);
    await _adaptForDeepColor(player);
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

  /// Flutter shows the video through an SDR surface, so HDR (PQ / HLG,
  /// BT.2020) has to be tone-mapped down to SDR by mpv's GPU renderer.
  /// Resets per-file state and sets tone-mapping options that work on GLES.
  Future<void> _applyHdrPipeline(Player player) async {
    _eightBit = false;
    await _setProp(player, 'vf', '');
    await _setProp(player, 'target-prim', 'bt.709');
    await _setProp(player, 'target-trc', 'srgb');
    await _setProp(player, 'tone-mapping', 'hable');
    // Peak detection needs compute shaders, which most GLES 3.0 GPUs lack.
    await _setProp(player, 'hdr-compute-peak', 'no');
  }

  /// Many Android GPUs cannot sample 10-bit (16-bit unorm) textures from the
  /// GLES renderer, which shows up as a black picture with working audio.
  /// If the decoded frames are HDR or >8-bit, convert them to 8-bit on the
  /// CPU first; the colour tags survive, so tone-mapping still happens.
  Future<void> _adaptForDeepColor(Player player) async {
    if (_closed || _hwdec == null || _hwdec == 'no' || _eightBit) return;
    var pix = '';
    for (var i = 0; i < 25 && !_closed; i++) {
      pix = await _getProp(player, 'video-params/pixelformat');
      if (pix.isNotEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
    final gamma = await _getProp(player, 'video-params/gamma');
    final hdr = gamma == 'pq' || gamma == 'hlg';
    final deep = RegExp(r'p0(10|12|16)|p(10|12|14|16)(le|be)?$').hasMatch(pix);
    DeveloperLog.append('video pixfmt=$pix gamma=$gamma hdr=$hdr deep=$deep hwdec=$_hwdec');
    if (!hdr && !deep) return;
    _eightBit = true;
    await _setProp(player, 'vf', 'format=yuv420p');
    DeveloperLog.append('HDR/10-bit source: forcing 8-bit yuv420p before GL upload');
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

  Future<void> setPlaybackSpeed(double r) async {
    await applyTempo(rate: r, pitchShift: _pitchShift);
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
    if (!identical(next, _controller) && mounted) {
      setState(() => _controller = next);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    if (c == null) return const ColoredBox(color: Colors.black);
    return Video(
      controller: c,
      fill: Colors.black,
      fit: widget.fit,
      controls: NoVideoControls,
    );
  }
}
