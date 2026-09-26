import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:video_player_hdr/video_player_hdr.dart';

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
  VideoPlayerHdrController? hdrPlayer;
  final _subs = <StreamSubscription<dynamic>>[];
  EngineValue value = const EngineValue();
  bool _closed = false;
  String? _hwdec;
  bool _hdr = true;
  String? _path;
  Future<void>? _inFlight;
  double _rate = 1;
  bool _pitchShift = false;
  bool wantPlay = false;

  bool get hasPlayer => !_closed && (_player != null || hdrPlayer != null);

  Future<void> open(String path, {required String hwdec, bool? hdr}) async {
    if (hdr != null) _hdr = hdr;
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
    _path = path;
    value = const EngineValue();
    notifyListeners();
    if (_hdr) {
      _hwdec = hwdec;
      await _openHdr(path);
      return;
    }
    await _openMpv(path, hwdec);
  }

  Future<void> _openHdr(String path) async {
    await _disposeMpv();
    await _disposeHdr();
    final controller = _hdrControllerFor(path);
    hdrPlayer = controller;
    notifyListeners();
    controller.addListener(_onHdr);
    await controller.initialize(viewType: VideoViewType.platformView);
    if (_closed) {
      await _disposeHdr();
      return;
    }
    try {
      await controller.setPlaybackSpeed(_rate <= 0 ? 1 : _rate);
    } catch (_) {}
    _onHdr();
    if (value.hasError) {
      throw StateError(value.errorDescription ?? 'Source error');
    }
    if (!value.isInitialized) {
      throw StateError('Source error');
    }
  }

  VideoPlayerHdrController _hdrControllerFor(String path) {
    if (path.startsWith('content:')) {
      return VideoPlayerHdrController.contentUri(Uri.parse(path));
    }
    if (path.startsWith('http://') || path.startsWith('https://')) {
      return VideoPlayerHdrController.networkUrl(Uri.parse(path));
    }
    if (path.startsWith('file:')) {
      return VideoPlayerHdrController.file(File(Uri.parse(path).toFilePath()));
    }
    return VideoPlayerHdrController.file(File(path));
  }

  void _onHdr() {
    final c = hdrPlayer;
    if (c == null) return;
    final v = c.value;
    value = EngineValue(
      isInitialized: v.isInitialized,
      isPlaying: v.isPlaying,
      isBuffering: v.isBuffering,
      hasError: v.hasError,
      completed: v.isCompleted,
      errorDescription: v.errorDescription,
      position: v.position,
      duration: v.duration,
      size: v.size,
    );
    notifyListeners();
  }

  Future<void> _openMpv(String path, String hwdec) async {
    await _disposeHdr();
    if (_player != null && _hwdec != null && _hwdec != hwdec) {
      await _disposeMpv();
    }
    final wantHw = hwdec != 'no';
    if (_player == null) {
      final player = Player(
        configuration: const PlayerConfiguration(
          pitch: false,
          title: 'Video Player',
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
    await _applyPitchCorrection(player, _pitchShift);
    await player.open(Media(_mediaUri(path)), play: false);
    await _waitReady(player);
    await player.setRate(_rate <= 0 ? 1 : _rate);
    _emit(player);
    if (_closed) return;
    if (value.hasError) {
      throw StateError(value.errorDescription ?? 'Source error');
    }
  }

  Future<void> applyTempo({required double rate, required bool pitchShift}) async {
    _rate = rate.clamp(0.25, 8.0).toDouble();
    _pitchShift = pitchShift;
    final hdr = hdrPlayer;
    if (hdr != null) {
      try {
        await hdr.setPlaybackSpeed(_rate);
      } catch (_) {}
      return;
    }
    final player = _player;
    if (player == null) return;
    await _applyPitchCorrection(player, pitchShift);
    try {
      await player.setRate(_rate);
    } catch (_) {}
  }

  Future<void> applyHdr(bool on) async {
    if (_hdr == on) return;
    _hdr = on;
    final path = _path;
    if (path == null) return;
    final pos = value.position;
    final playing = wantPlay;
    await open(path, hwdec: _hwdec ?? 'mediacodec', hdr: on);
    if (pos > Duration.zero) {
      try {
        await seekTo(pos);
      } catch (_) {}
    }
    if (playing) {
      await play();
    } else {
      await pause();
    }
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
        await _setNative(platform, 'hwdec', hwdec);
        await _setNative(platform, 'hwdec-codecs', 'h264,hevc,vp8,vp9,av1,mpeg4,mpeg2video,mjpeg');
        await _setNative(platform, 'video-sync', 'audio');
        await _setNative(platform, 'vd-lavc-dr', 'no');
        return;
      }
      await (platform as dynamic).setProperty('hwdec', hwdec);
    } catch (_) {}
  }

  Future<void> _setNative(NativePlayer platform, String key, String value) async {
    try {
      await platform.setProperty(key, value);
    } catch (_) {}
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
    if (hdrPlayer != null) {
      await hdrPlayer!.play();
      return;
    }
    await _player?.play();
  }

  Future<void> pause() async {
    wantPlay = false;
    if (hdrPlayer != null) {
      await hdrPlayer!.pause();
      return;
    }
    await _player?.pause();
  }

  Future<void> _pauseOthers() async {
    final others = _alive.where((e) => !identical(e, this) && !e._closed).toList();
    for (final e in others) {
      e.wantPlay = false;
      try {
        await e.hdrPlayer?.pause();
      } catch (_) {}
      try {
        await e._player?.pause();
      } catch (_) {}
    }
  }

  Future<void> seekTo(Duration d) async {
    if (hdrPlayer != null) {
      await hdrPlayer!.seekTo(d);
      return;
    }
    await _player?.seek(d);
  }

  Future<void> setVolume(double v) async {
    final vol = v.clamp(0.0, 1.0).toDouble();
    if (hdrPlayer != null) {
      await hdrPlayer!.setVolume(vol);
      return;
    }
    await _player?.setVolume(vol * 100);
  }

  Future<void> setPlaybackSpeed(double r) async {
    await applyTempo(rate: r, pitchShift: _pitchShift);
  }

  Future<void> setLooping(bool on) async {
    if (hdrPlayer != null) {
      await hdrPlayer!.setLooping(on);
      return;
    }
    await _player?.setPlaylistMode(on ? PlaylistMode.single : PlaylistMode.none);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    wantPlay = false;
    _alive.remove(this);
    await _disposeHdr();
    await _disposeMpv();
    super.dispose();
  }

  @override
  void dispose() {
    unawaited(close());
  }

  Future<void> _disposeHdr() async {
    final c = hdrPlayer;
    hdrPlayer = null;
    if (c == null) return;
    try {
      c.removeListener(_onHdr);
    } catch (_) {}
    try {
      await c.pause();
    } catch (_) {}
    try {
      await c.dispose();
    } catch (_) {}
  }

  Future<void> _disposeMpv() async {
    for (final s in _subs) {
      try {
        await s.cancel();
      } catch (_) {}
    }
    _subs.clear();
    final p = _player;
    _player = null;
    video = null;
    if (hdrPlayer == null) {
      value = const EngineValue();
      notifyListeners();
    }
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
  VideoPlayerHdrController? _hdr;

  @override
  void initState() {
    super.initState();
    _controller = widget.engine.video;
    _hdr = widget.engine.hdrPlayer;
    widget.engine.addListener(_onEngine);
  }

  @override
  void didUpdateWidget(covariant AppVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.engine, widget.engine)) {
      oldWidget.engine.removeListener(_onEngine);
      widget.engine.addListener(_onEngine);
      _controller = widget.engine.video;
      _hdr = widget.engine.hdrPlayer;
    }
  }

  @override
  void dispose() {
    widget.engine.removeListener(_onEngine);
    super.dispose();
  }

  void _onEngine() {
    final next = widget.engine.video;
    final hdr = widget.engine.hdrPlayer;
    if ((!identical(next, _controller) || !identical(hdr, _hdr)) && mounted) {
      setState(() {
        _controller = next;
        _hdr = hdr;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final hdr = _hdr;
    if (hdr != null) {
      Widget child = VideoPlayerHdr(hdr);
      final rot = hdr.value.rotationCorrection;
      if (rot == 90 || rot == 180 || rot == 270) {
        child = RotatedBox(quarterTurns: rot ~/ 90, child: child);
      }
      return ColoredBox(color: Colors.black, child: child);
    }
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
