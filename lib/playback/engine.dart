import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

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
  Player? _player;
  VideoController? video;
  final _subs = <StreamSubscription<dynamic>>[];
  EngineValue value = const EngineValue();
  bool _closed = false;
  String? _hwdec;
  Future<void>? _inFlight;
  double _rate = 1;
  bool _pitchShift = false;
  bool _audioOnly = false;
  bool wantPlay = false;

  bool get hasPlayer => _player != null && !_closed;
  bool get audioOnly => _audioOnly;

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
    if (_audioOnly) await _applyAudioOnly(true);
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
        if (_audioOnly && wantPlay) {
          final dur = player.state.duration;
          final pos = player.state.position;
          if (dur > Duration.zero && pos < dur - const Duration(milliseconds: 800)) {
            unawaited(forcePlay());
            return;
          }
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

  Future<void> setAudioOnly(bool on) async {
    _audioOnly = on;
    await _applyAudioOnly(on);
  }

  Future<void> _applyAudioOnly(bool on) async {
    try {
      final platform = _player?.platform;
      if (platform is NativePlayer) {
        await platform.setProperty('vid', on ? 'no' : 'auto');
        if (on) {
          await platform.setProperty('pause', 'no');
        }
      }
    } catch (_) {}
  }

  Future<void> forcePlay() async {
    wantPlay = true;
    try {
      await _player?.play();
    } catch (_) {}
    try {
      final platform = _player?.platform;
      if (platform is NativePlayer) {
        await platform.setProperty('pause', 'no');
      }
    } catch (_) {}
  }

  Future<void> play() async {
    wantPlay = true;
    await _player?.play();
  }

  Future<void> pause() async {
    wantPlay = false;
    await _player?.pause();
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
    _audioOnly = false;
    await _disposePlayer();
    super.dispose();
  }

  @override
  void dispose() {
    unawaited(close());
  }

  Future<void> _disposePlayer() async {
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
