import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'android_bridge.dart';
import 'player.dart';

/// Geometry for the floating mini player. Keep numbers here — not scattered.
class MiniPlayerGeom {
  MiniPlayerGeom._();

  /// Visible edge tab when the window is parked off-screen (YouTube-style).
  static const handle = 12.0;
  static const snapMs = 220;
  static const appearMs = 240;
  static const closeMs = 220;
  static const minScale = 0.55;
  static const maxScale = 2.4;
  static const restMin = 0.62;
  static const restMax = 2.05;
  static const margin = 10.0;
  static const grabberH = 96.0;
  static const flingHide = 900.0;
  static const flingClose = 1100.0;
}

/// Floating mini player: 1:1 drag, pinch-scale, short ease-out snap,
/// YouTube hide (off-screen + 12px grabber, pause while hidden),
/// drag-down to close. Size follows the video aspect.
class MiniPlayerOverlay extends StatefulWidget {
  const MiniPlayerOverlay({
    super.key,
    required this.pad,
    required this.navH,
    required this.onExpand,
    required this.onClose,
    required this.onPrev,
    required this.onNext,
  });

  final EdgeInsets pad;
  final double navH;
  final VoidCallback onExpand;
  final Future<void> Function() onClose;
  final Future<void> Function() onPrev;
  final Future<void> Function() onNext;

  @override
  State<MiniPlayerOverlay> createState() => _MiniPlayerOverlayState();
}

class _MiniPlayerOverlayState extends State<MiniPlayerOverlay> with TickerProviderStateMixin {
  Offset _pos = Offset.zero;
  double _nx = 1;
  double _ny = 1;
  double _scale = 1;
  bool _live = false;
  bool _ready = false;
  bool _hiding = false;
  int _hideDir = 0;
  bool _closing = false;
  bool _moved = false;
  bool _pausedForHide = false;

  late final AnimationController _move;
  late final AnimationController _appear;

  double _fromNx = 1;
  double _fromNy = 1;
  double _toNx = 1;
  double _toNy = 1;
  double _fromScale = 1;
  double _toScale = 1;

  Offset _startFocal = Offset.zero;
  Offset _startPos = Offset.zero;
  double _startScale = 1;
  Offset _lastFocal = Offset.zero;
  DateTime _lastT = DateTime.now();
  Offset _vel = Offset.zero;

  Size _videoSize() {
    try {
      final s = PlaybackSession.controller?.value.size;
      if (s != null && s.width > 1 && s.height > 1) return s;
    } catch (_) {}
    final item = PlaybackSession.item;
    if (item != null && item.width > 1 && item.height > 1) {
      return Size(item.width.toDouble(), item.height.toDouble());
    }
    return const Size(16, 9);
  }

  Size _boxFor(Size screen, Size video) {
    final ar = (video.width <= 0 || video.height <= 0) ? 16 / 9 : video.width / video.height;
    final short = math.min(screen.width, screen.height);
    var w = (short * 0.42).clamp(148.0, 280.0).toDouble();
    var h = w / ar;
    final maxH = screen.height * 0.34;
    if (h > maxH) {
      h = maxH;
      w = h * ar;
    }
    if (h < 72) {
      h = 72;
      w = h * ar;
    }
    return Size(w, h + 40);
  }

  ({double minX, double maxX, double minY, double maxY}) _range(Size screen, double w, double h) {
    final minX = MiniPlayerGeom.margin;
    final maxX = math.max(minX, screen.width - w - MiniPlayerGeom.margin);
    final minY = widget.pad.top + 8.0;
    final maxY = math.max(minY, screen.height - h - widget.navH - 8.0);
    return (minX: minX, maxX: maxX, minY: minY, maxY: maxY);
  }

  Offset _pixel(Size screen, {double? scale, double? nx, double? ny, bool hiding = false, int hideDir = 0}) {
    final s = scale ?? _scale;
    final box = _boxFor(screen, _videoSize());
    final w = box.width * s;
    final h = box.height * s;
    final r = _range(screen, w, h);
    final nnx = nx ?? _nx;
    final nny = ny ?? _ny;
    final y = (r.minY + nny * (r.maxY - r.minY)).toDouble();
    if (hiding) {
      final x = hideDir < 0 ? MiniPlayerGeom.handle - w : screen.width - MiniPlayerGeom.handle;
      return Offset(x, y);
    }
    return Offset((r.minX + nnx * (r.maxX - r.minX)).toDouble(), y);
  }

  void _captureNorm(Size screen, Offset p, {double? scale}) {
    final s = scale ?? _scale;
    final box = _boxFor(screen, _videoSize());
    final w = box.width * s;
    final h = box.height * s;
    final r = _range(screen, w, h);
    final spanX = math.max(1.0, r.maxX - r.minX);
    final spanY = math.max(1.0, r.maxY - r.minY);
    _nx = ((p.dx - r.minX) / spanX).clamp(0.0, 1.0).toDouble();
    _ny = ((p.dy - r.minY) / spanY).clamp(0.0, 1.0).toDouble();
  }

  Offset _dockPos(Size screen, {required bool right}) {
    return _pixel(screen, nx: right ? 1.0 : 0.0, ny: 1.0, hiding: false);
  }

  @override
  void initState() {
    super.initState();
    _move = AnimationController(vsync: this, duration: const Duration(milliseconds: MiniPlayerGeom.snapMs));
    _move.addListener(_onMove);
    _appear = AnimationController(vsync: this, duration: const Duration(milliseconds: MiniPlayerGeom.appearMs));
  }

  void _onMove() {
    final t = Curves.easeOutCubic.transform(_move.value.clamp(0.0, 1.0).toDouble());
    setState(() {
      _nx = _fromNx + (_toNx - _fromNx) * t;
      _ny = _fromNy + (_toNy - _fromNy) * t;
      _scale = _fromScale + (_toScale - _fromScale) * t;
      final screen = MediaQuery.sizeOf(context);
      _pos = _pixel(screen, hiding: _hiding, hideDir: _hideDir);
    });
  }

  @override
  void dispose() {
    _move.removeListener(_onMove);
    _move.dispose();
    _appear.dispose();
    super.dispose();
  }

  void _pauseForHide() {
    final c = PlaybackSession.controller;
    if (c == null) return;
    try {
      if (c.value.isPlaying) {
        _pausedForHide = true;
        unawaited(c.pause());
      }
    } catch (_) {}
  }

  void _resumeIfNeeded() {
    if (!_pausedForHide) return;
    _pausedForHide = false;
    final c = PlaybackSession.controller;
    if (c == null) return;
    unawaited(() async {
      try {
        await AndroidBridge.requestAudioFocus();
        await c.play();
      } catch (_) {}
      if (mounted) setState(() {});
    }());
  }

  void _animateTo(Offset target, double scale, {bool hiding = false, int hideDir = 0, int ms = MiniPlayerGeom.snapMs}) {
    final screen = MediaQuery.sizeOf(context);
    _fromNx = _nx;
    _fromNy = _ny;
    _fromScale = _scale;
    if (hiding) {
      _toNx = hideDir < 0 ? 0 : 1;
      _captureNorm(screen, target, scale: scale);
      _toNy = _ny;
      _nx = _fromNx;
      _ny = _fromNy;
    } else {
      _captureNorm(screen, target, scale: scale);
      _toNx = _nx;
      _toNy = _ny;
      _nx = _fromNx;
      _ny = _fromNy;
    }
    _hiding = hiding;
    _hideDir = hideDir;
    _toScale = scale;
    _live = true;
    _move.stop();
    _move.duration = Duration(milliseconds: ms);
    _move.forward(from: 0).whenComplete(() {
      if (!mounted) return;
      _live = false;
      if (!hiding) {
        _nx = _toNx;
        _ny = _toNy;
        _resumeIfNeeded();
      } else {
        _pauseForHide();
      }
      if (mounted) setState(() {});
    });
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    _pausedForHide = false;
    _fromNx = _nx;
    _fromNy = _ny;
    _fromScale = _scale;
    _toNx = _nx;
    _toNy = 1.45;
    _toScale = math.max(MiniPlayerGeom.restMin, _scale * 0.78);
    _live = true;
    _hiding = false;
    _move.stop();
    _move.duration = const Duration(milliseconds: MiniPlayerGeom.closeMs);
    _move.forward(from: 0);
    _appear.reverse();
    await Future<void>.delayed(const Duration(milliseconds: MiniPlayerGeom.closeMs));
    await widget.onClose();
  }

  void _onScaleStart(ScaleStartDetails d) {
    if (_closing) return;
    _move.stop();
    _live = true;
    _moved = false;
    final screen = MediaQuery.sizeOf(context);
    _pos = _pixel(screen, hiding: _hiding, hideDir: _hideDir);
    _startFocal = d.focalPoint;
    _startPos = _pos;
    _startScale = _scale;
    _lastFocal = d.focalPoint;
    _lastT = DateTime.now();
    _vel = Offset.zero;
  }

  void _onScaleUpdate(ScaleUpdateDetails d, Size screen, Size box) {
    if (_closing) return;
    final now = DateTime.now();
    final dt = math.max(8, now.difference(_lastT).inMilliseconds).toDouble();
    _vel = (d.focalPoint - _lastFocal) * (1000 / dt);
    _lastFocal = d.focalPoint;
    _lastT = now;
    if ((d.focalPoint - _startFocal).distance > 5 || (d.scale - 1).abs() > 0.02) _moved = true;

    var nextScale = _startScale * d.scale;
    if (nextScale < MiniPlayerGeom.minScale) {
      nextScale = MiniPlayerGeom.minScale - (MiniPlayerGeom.minScale - nextScale) * 0.32;
    } else if (nextScale > MiniPlayerGeom.maxScale) {
      nextScale = MiniPlayerGeom.maxScale + (nextScale - MiniPlayerGeom.maxScale) * 0.32;
    }

    final pinching = (d.scale - 1).abs() > 0.02;
    Offset next;
    if (pinching) {
      _scale = nextScale;
      _captureNorm(screen, _startPos, scale: _startScale);
      final base = _pixel(screen);
      next = base + (d.focalPoint - _startFocal);
      _captureNorm(screen, next);
      next = _pixel(screen);
    } else {
      next = _startPos + (d.focalPoint - _startFocal);
    }

    setState(() {
      _pos = next;
      _scale = nextScale;
      _hiding = false;
      _live = true;
    });
  }

  void _onScaleEnd(ScaleEndDetails d, Size screen, Size box) {
    if (_closing) return;
    _vel = d.velocity.pixelsPerSecond;
    var scale = _scale;
    if (scale < MiniPlayerGeom.restMin || scale > MiniPlayerGeom.restMax) {
      scale = scale.clamp(MiniPlayerGeom.restMin, MiniPlayerGeom.restMax).toDouble();
    }
    final w = box.width * scale;
    final h = box.height * scale;
    final cx = _pos.dx + w / 2;
    final bottom = _pos.dy + h;

    final flungDown = _vel.dy > MiniPlayerGeom.flingClose ||
        (bottom > screen.height - 40 && _vel.dy > 240) ||
        _pos.dy > screen.height * 0.78;
    if (flungDown) {
      unawaited(_close());
      return;
    }

    final r = _range(screen, w, h);
    final y = _pos.dy.clamp(r.minY, r.maxY).toDouble();
    final flungSide = _vel.dx.abs() > MiniPlayerGeom.flingHide && _vel.dx.abs() > _vel.dy.abs() * 0.8;
    final offLeft = _pos.dx <= MiniPlayerGeom.handle - w + 1 || _pos.dx + w * 0.45 < 0;
    final offRight = _pos.dx >= screen.width - MiniPlayerGeom.handle - 1 || _pos.dx > screen.width - w * 0.45;

    if ((flungSide && _vel.dx < 0) || offLeft) {
      _animateTo(Offset(MiniPlayerGeom.handle - w, y), scale, hiding: true, hideDir: -1);
      return;
    }
    if ((flungSide && _vel.dx > 0) || offRight) {
      _animateTo(Offset(screen.width - MiniPlayerGeom.handle, y), scale, hiding: true, hideDir: 1);
      return;
    }

    _hiding = false;
    _hideDir = 0;
    final x = cx < screen.width / 2 ? r.minX : r.maxX;
    _animateTo(Offset(x, y), scale);
  }

  void _reveal(Size screen, Size box) {
    _hiding = false;
    _hideDir = 0;
    final r = _range(screen, box.width * _scale, box.height * _scale);
    final x = _nx < 0.5 ? r.minX : r.maxX;
    _animateTo(Offset(x, _pixel(screen).dy), _scale);
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final video = _videoSize();
    final box = _boxFor(screen, video);
    if (!_ready) {
      _ready = true;
      _nx = 1;
      _ny = 1.18;
      _scale = 0.82;
      _pos = _pixel(screen);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _appear.forward();
        _animateTo(_dockPos(screen, right: true), 1);
      });
    }

    final draw = _live ? _pos : _pixel(screen, hiding: _hiding, hideDir: _hideDir);

    final c = PlaybackSession.controller;
    final item = PlaybackSession.item;
    var playing = false;
    try {
      playing = c?.value.isPlaying ?? false;
    } catch (_) {}

    Widget frame;
    try {
      if (c != null && c.value.isInitialized) {
        frame = FittedBox(
          fit: BoxFit.contain,
          child: SizedBox(
            width: video.width.clamp(1, 8000).toDouble(),
            height: video.height.clamp(1, 8000).toDouble(),
            child: VideoPlayer(key: ValueKey(item?.path), c),
          ),
        );
      } else {
        frame = const ColoredBox(
          color: Colors.black26,
          child: Center(child: Icon(Icons.play_circle, color: Colors.white70)),
        );
      }
    } catch (_) {
      frame = const ColoredBox(color: Colors.black26);
    }

    final scheme = Theme.of(context).colorScheme;
    final visW = box.width * _scale;
    final visH = box.height * _scale;
    final barH = (40.0 * _scale.clamp(0.78, 1.25));
    final parked = _hiding && !_live && !_closing;

    Widget btn(String t, IconData i, VoidCallback on) {
      return IconButton(
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: BoxConstraints.tightFor(width: 36 * _scale.clamp(0.8, 1.2), height: 36 * _scale.clamp(0.8, 1.2)),
        tooltip: t,
        color: scheme.onSurface,
        onPressed: on,
        icon: Icon(i, size: 22 * _scale.clamp(0.8, 1.15)),
      );
    }

    final grabber = Align(
      alignment: _hideDir < 0 ? Alignment.centerRight : Alignment.centerLeft,
      child: Material(
        color: scheme.surfaceContainerHighest,
        elevation: 8,
        borderRadius: BorderRadius.horizontal(
          left: _hideDir < 0 ? Radius.zero : const Radius.circular(10),
          right: _hideDir < 0 ? const Radius.circular(10) : Radius.zero,
        ),
        child: SizedBox(
          width: MiniPlayerGeom.handle,
          height: math.min(visH, MiniPlayerGeom.grabberH),
          child: Icon(
            _hideDir < 0 ? Icons.chevron_right : Icons.chevron_left,
            size: 14,
            color: scheme.onSurface,
          ),
        ),
      ),
    );

    return Positioned(
      left: draw.dx,
      top: draw.dy,
      width: visW,
      height: visH,
      child: AnimatedBuilder(
        animation: _appear,
        builder: (_, child) {
          final t = Curves.easeOutCubic.transform(_appear.value.clamp(0.0, 1.0).toDouble());
          return Opacity(
            opacity: _appear.value.clamp(0.0, 1.0).toDouble(),
            child: Transform.scale(scale: 0.92 + 0.08 * t, alignment: Alignment.bottomCenter, child: child),
          );
        },
        child: GestureDetector(
          onScaleStart: _onScaleStart,
          onScaleUpdate: (d) => _onScaleUpdate(d, screen, box),
          onScaleEnd: (d) => _onScaleEnd(d, screen, box),
          child: parked
              ? grabber
              : Material(
                  elevation: 14,
                  color: scheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Column(
                        children: [
                          Expanded(
                            child: GestureDetector(
                              onTap: () {
                                if (_hiding) {
                                  _reveal(screen, box);
                                  return;
                                }
                                if (_moved) return;
                                widget.onExpand();
                              },
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  frame,
                                  if (!playing)
                                    const IgnorePointer(
                                      child: ColoredBox(
                                        color: Color(0x33000000),
                                        child: Center(child: Icon(Icons.play_arrow, color: Colors.white, size: 36)),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          SizedBox(
                            height: barH,
                            child: Row(
                              children: [
                                btn('Previous', Icons.skip_previous, () => unawaited(widget.onPrev())),
                                btn(
                                  playing ? 'Pause' : 'Play',
                                  playing ? Icons.pause : Icons.play_arrow,
                                  () async {
                                    final live = PlaybackSession.controller;
                                    if (live == null) return;
                                    if (live.value.isPlaying) {
                                      _pausedForHide = false;
                                      await live.pause();
                                    } else {
                                      await AndroidBridge.requestAudioFocus();
                                      await live.play();
                                    }
                                    await AndroidBridge.updateBackground(
                                      playing: live.value.isPlaying,
                                      positionMs: live.value.position.inMilliseconds,
                                      durationMs: live.value.duration.inMilliseconds,
                                    );
                                    if (mounted) setState(() {});
                                  },
                                ),
                                btn('Next', Icons.skip_next, () => unawaited(widget.onNext())),
                                Expanded(
                                  child: Text(
                                    item?.title ?? '',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: scheme.onSurface,
                                      fontSize: 11 * _scale.clamp(0.8, 1.2),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      if (_hiding) grabber,
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}
