import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'android_bridge.dart';
import 'player.dart';

/// Floating mini player: 1:1 drag, pinch-scale, elastic snap to a side,
/// 30px edge peek, drag-down to close. Size follows the video aspect.
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
  double _scale = 1;
  bool _ready = false;
  bool _hiding = false;
  int _hideDir = 0;
  bool _closing = false;
  bool _moved = false;

  late final AnimationController _spring;
  late final AnimationController _appear;

  Offset _from = Offset.zero;
  Offset _to = Offset.zero;
  double _fromScale = 1;
  double _toScale = 1;
  double _bounce = 1;

  Offset _startFocal = Offset.zero;
  Offset _startPos = Offset.zero;
  double _startScale = 1;
  Offset _lastFocal = Offset.zero;
  DateTime _lastT = DateTime.now();
  Offset _vel = Offset.zero;

  static const _peek = 30.0;
  static const _minScale = 0.55;
  static const _maxScale = 2.4;
  static const _restMin = 0.62;
  static const _restMax = 2.05;

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
    var w = (short * 0.42).clamp(148.0, 280.0);
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

  Offset _dockPos(Size screen, Size box, {required bool right}) {
    final w = box.width * _scale;
    final h = box.height * _scale;
    final x = right ? screen.width - w - 10 : 10.0;
    final y = (screen.height - h - 12 - widget.navH - widget.pad.bottom).clamp(
      widget.pad.top + 8,
      math.max(widget.pad.top + 8, screen.height - 80),
    );
    return Offset(x, y);
  }

  @override
  void initState() {
    super.initState();
    _spring = AnimationController.unbounded(vsync: this);
    _spring.addListener(_onSpring);
    _appear = AnimationController(vsync: this, duration: const Duration(milliseconds: 460));
  }

  void _onSpring() {
    final raw = _spring.value;
    final t = Curves.elasticOut.transform(raw.clamp(0.0, 1.0));
    final extra = (_bounce - 1) * math.sin(t * math.pi) * (1 - t);
    setState(() {
      _pos = Offset.lerp(_from, _to, t)! + Offset(0, extra * 18 * _bounce.sign);
      _scale = _fromScale + (_toScale - _fromScale) * t;
    });
  }

  @override
  void dispose() {
    _spring.removeListener(_onSpring);
    _spring.dispose();
    _appear.dispose();
    super.dispose();
  }

  void _animateTo(Offset target, double scale, {double energy = 1}) {
    _from = _pos;
    _to = target;
    _fromScale = _scale;
    _toScale = scale;
    final travel = (_pos - target).distance + (_scale - scale).abs() * 90;
    final fling = _vel.distance;
    _bounce = (0.7 + (fling / 2800).clamp(0.0, 1.1) + (travel / 420).clamp(0.0, 0.8) + ((_scale - 1).abs() * 0.35)).clamp(0.7, 2.2);
    final dur = (440 + travel * 0.4 + fling * 0.06 + energy * 80).clamp(380, 980).round();
    _spring.stop();
    _spring.value = 0;
    _spring.animateTo(1, duration: Duration(milliseconds: dur), curve: Curves.linear);
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    final screen = MediaQuery.sizeOf(context);
    _vel = Offset(_vel.dx, math.max(_vel.dy, 1400));
    _animateTo(Offset(_pos.dx, screen.height + 64), math.max(0.62, _scale * 0.78), energy: 1.3);
    _appear.reverse();
    await Future<void>.delayed(const Duration(milliseconds: 280));
    await widget.onClose();
  }

  void _onScaleStart(ScaleStartDetails d) {
    if (_closing) return;
    _spring.stop();
    _moved = false;
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
    if (nextScale < _minScale) {
      nextScale = _minScale - (_minScale - nextScale) * 0.32;
    } else if (nextScale > _maxScale) {
      nextScale = _maxScale + (nextScale - _maxScale) * 0.32;
    }

    final local = Offset(
      (_startFocal.dx - _startPos.dx) / _startScale,
      (_startFocal.dy - _startPos.dy) / _startScale,
    );
    var next = d.focalPoint - Offset(local.dx * nextScale, local.dy * nextScale);

    final h = box.height * nextScale;
    final minY = widget.pad.top - 28;
    final maxY = screen.height + 28 - h;
    if (next.dy < minY) {
      next = Offset(next.dx, minY + (next.dy - minY) * 0.28);
    } else if (next.dy > maxY) {
      next = Offset(next.dx, maxY + (next.dy - maxY) * 0.28);
    }

    setState(() {
      _pos = next;
      _scale = nextScale;
      _hiding = false;
    });
  }

  void _onScaleEnd(ScaleEndDetails d, Size screen, Size box) {
    if (_closing) return;
    _vel = d.velocity.pixelsPerSecond;
    var scale = _scale;
    if (scale < _restMin || scale > _restMax) {
      scale = scale.clamp(_restMin, _restMax);
    }
    final w = box.width * scale;
    final h = box.height * scale;
    final cx = _pos.dx + w / 2;
    final bottom = _pos.dy + h;

    final flungDown = _vel.dy > 1100 || (bottom > screen.height - 40 && _vel.dy > 240) || _pos.dy > screen.height * 0.78;
    if (flungDown) {
      unawaited(_close());
      return;
    }

    var x = _pos.dx;
    var y = _pos.dy.clamp(widget.pad.top + 6, math.max(widget.pad.top + 6, screen.height - h - widget.navH - 8));
    final flungLeft = _vel.dx < -880;
    final flungRight = _vel.dx > 880;
    final pastLeft = _pos.dx < -_peek || cx < screen.width * 0.18;
    final pastRight = _pos.dx + w > screen.width + _peek || cx > screen.width * 0.82;

    if (flungLeft || (pastLeft && !flungRight) || (_hideDir == -1 && cx < screen.width * 0.32)) {
      x = _peek - w;
      _hiding = true;
      _hideDir = -1;
    } else if (flungRight || (pastRight && !flungLeft) || (_hideDir == 1 && cx > screen.width * 0.68)) {
      x = screen.width - _peek;
      _hiding = true;
      _hideDir = 1;
    } else {
      _hiding = false;
      _hideDir = 0;
      x = cx < screen.width / 2 ? 10.0 : screen.width - w - 10;
    }

    _animateTo(Offset(x, y), scale, energy: 1 + (_vel.distance / 2400).clamp(0.0, 1.0));
  }

  void _reveal(Size screen, Size box) {
    final w = box.width * _scale;
    final x = _hideDir < 0 ? 10.0 : screen.width - w - 10;
    _hiding = false;
    _hideDir = 0;
    _animateTo(Offset(x, _pos.dy), _scale);
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final video = _videoSize();
    final box = _boxFor(screen, video);
    if (!_ready) {
      _ready = true;
      _pos = Offset(screen.width - box.width - 10, screen.height + 48);
      _scale = 0.82;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _appear.forward();
        _animateTo(_dockPos(screen, box, right: true), 1, energy: 1.15);
      });
    }

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
            width: video.width.clamp(1, 8000),
            height: video.height.clamp(1, 8000),
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

    return Positioned(
      left: _pos.dx,
      top: _pos.dy,
      width: visW,
      height: visH,
      child: AnimatedBuilder(
        animation: _appear,
        builder: (_, child) {
          final t = Curves.easeOutBack.transform(_appear.value.clamp(0.0, 1.0));
          return Opacity(
            opacity: _appear.value.clamp(0.0, 1.0),
            child: Transform.scale(scale: 0.86 + 0.14 * t, alignment: Alignment.bottomCenter, child: child),
          );
        },
        child: GestureDetector(
          onScaleStart: _onScaleStart,
          onScaleUpdate: (d) => _onScaleUpdate(d, screen, box),
          onScaleEnd: (d) => _onScaleEnd(d, screen, box),
          child: Material(
            elevation: 14,
            color: scheme.surface,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: Column(
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
          ),
        ),
      ),
    );
  }
}
