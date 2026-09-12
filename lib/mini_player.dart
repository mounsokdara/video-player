import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'android_bridge.dart';
import 'mini_chrome.dart';
import 'mini_geom.dart';
import 'player_picture.dart';
import 'session.dart';
import 'settings.dart';

export 'mini_chrome.dart';
export 'mini_geom.dart';

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

class _MiniPlayerOverlayState extends State<MiniPlayerOverlay>
    with SingleTickerProviderStateMixin {
  double _left = 0, _top = 0;
  double _scale = 1;
  bool _ready = false;
  bool _dragging = false;
  bool _resizing = false;
  bool _closing = false;
  bool _moved = false;
  String? _hiddenSide;
  bool _pausedForHide = false;
  double _arrowL = 0, _arrowR = 0;
  double _dragOpacity = 1;
  Offset _startFocal = Offset.zero;
  Offset _startPos = Offset.zero;
  double _startScale = 1;
  double _pinchFx = 0.5, _pinchFy = 0.5;
  VideoPlayerController? _ctrl;

  late final AnimationController _move;
  double _fromLeft = 0, _fromTop = 0, _fromScale = 1;
  double _toLeft = 0, _toTop = 0, _toScale = 1;

  @override
  void initState() {
    super.initState();
    _move = AnimationController(
        vsync: this, duration: const Duration(milliseconds: MiniGeom.snapMs));
    _move.addListener(_onMove);
    _bind();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bind();
  }

  @override
  void dispose() {
    _move.removeListener(_onMove);
    _move.dispose();
    try {
      _ctrl?.removeListener(_onTick);
    } catch (_) {}
    super.dispose();
  }

  void _bind() {
    final next = PlaybackSession.controller;
    if (identical(next, _ctrl)) return;
    try {
      _ctrl?.removeListener(_onTick);
    } catch (_) {}
    _ctrl = next;
    _ctrl?.addListener(_onTick);
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  void _onMove() {
    final t = MiniGeom.ease.transform(_move.value.clamp(0.0, 1.0).toDouble());
    if (!mounted) return;
    setState(() {
      _left = _fromLeft + (_toLeft - _fromLeft) * t;
      _top = _fromTop + (_toTop - _fromTop) * t;
      _scale = _fromScale + (_toScale - _fromScale) * t;
      if (!_closing) _followArrows();
    });
  }

  void _animateTo(double left, double top, double scale, {VoidCallback? onDone}) {
    _fromLeft = _left;
    _fromTop = _top;
    _fromScale = _scale;
    _toLeft = left;
    _toTop = top;
    _toScale = scale;
    _move.stop();
    _move.duration = const Duration(milliseconds: MiniGeom.snapMs);
    _move.forward(from: 0).whenComplete(() {
      if (!mounted) return;
      _left = _toLeft;
      _top = _toTop;
      _scale = _toScale;
      onDone?.call();
      if (mounted) setState(() {});
    });
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

  Future<void> _togglePlay() async {
    final c = PlaybackSession.controller;
    if (c == null) return;
    try {
      if (c.value.isPlaying) {
        _pausedForHide = false;
        await c.pause();
      } else {
        await AndroidBridge.requestAudioFocus();
        await c.play();
      }
      if (appSettings.backgroundPlay) {
        await AndroidBridge.updateBackground(
          playing: c.value.isPlaying,
          positionMs: c.value.position.inMilliseconds,
          durationMs: c.value.duration.inMilliseconds,
        );
      } else {
        await AndroidBridge.stopBackground();
      }
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Rect _rect(Size box) => Rect.fromLTWH(_left, _top, box.width, box.height);

  Size _boxFor(Size screen) =>
      MiniPhysics.visualBox(screen, MiniPhysics.videoSize(), _scale);

  String _sideFor(Rect r, Size screen) =>
      (r.left + r.width / 2) < screen.width / 2 ? 'left' : 'right';

  void _refreshArrows(Rect r, Size screen, {double threshold = 0.02}) {
    final ox = MiniPhysics.offX(r, screen);
    if (ox > threshold) {
      _setArrows(_sideFor(r, screen),
          (ox / MiniGeom.hideT).clamp(0.0, 1.0).toDouble());
    } else {
      _setArrows(null, 0);
    }
  }

  void _followArrows() {
    if (!mounted || _closing || _dragging || _resizing) return;
    final screen = MediaQuery.sizeOf(context);
    _refreshArrows(_rect(_boxFor(screen)), screen);
  }

  void _setArrows(String? side, double progress) {
    final p = progress.clamp(0.0, 1.0).toDouble();
    _arrowL = side == 'left' ? p : 0;
    _arrowR = side == 'right' ? p : 0;
  }

  void _park(String side, Size screen, Size box) {
    _hiddenSide = side;
    _setArrows(side, 1);
    _dragOpacity = 1;
    final left = side == 'left' ? -box.width : screen.width;
    _animateTo(left, _top, _scale, onDone: () {
      if (!mounted) return;
      _setArrows(side, 1);
      _pauseForHide();
    });
  }

  void _unhide(Size screen, Size box) {
    final side = _hiddenSide ?? _sideFor(_rect(box), screen);
    _setArrows(side, 1);
    _dragOpacity = 1;
    _dragging = false;
    _resizing = false;
    final seed = Rect.fromLTWH(
      side == 'left' ? 0 : screen.width - box.width,
      _top,
      box.width,
      box.height,
    );
    final target = MiniPhysics.settlePos(seed, screen, box,
        navH: widget.navH, pad: widget.pad);
    _animateTo(target.dx, target.dy, _scale, onDone: () {
      if (!mounted) return;
      _hiddenSide = null;
      _followArrows();
      _resumeIfNeeded();
    });
  }

  void _settle(Size screen, Size box) {
    final s = MiniGeom.clampScale(_scale, screen);
    final next = MiniPhysics.visualBox(screen, MiniPhysics.videoSize(), s);
    final target = MiniPhysics.settlePos(_rect(box), screen, next,
        navH: widget.navH, pad: widget.pad);
    _hiddenSide = null;
    _setArrows(null, 0);
    _dragOpacity = 1;
    _animateTo(target.dx, target.dy, s, onDone: _resumeIfNeeded);
  }

  void _finishDrag(Size screen, Size box) {
    final r = _rect(box);
    final ox = MiniPhysics.offX(r, screen);
    final ob = MiniPhysics.offBottom(r, screen);
    final lo = MiniGeom.clampScale(MiniGeom.minScale, screen);
    final over = _scale > MiniGeom.maxScale + 0.001;
    final under = _scale < lo - 0.001;

    if (ob >= MiniGeom.closeT && !over && !under) {
      unawaited(_close());
    } else if (ox >= MiniGeom.hideT && !over && !under) {
      _park(_sideFor(r, screen), screen, box);
    } else if (_hiddenSide != null) {
      _unhide(screen, box);
    } else {
      _settle(screen, box);
    }
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    _pausedForHide = false;
    _hiddenSide = null;
    _setArrows(null, 0);
    _move.stop();
    if (mounted) setState(() {});
    await Future<void>.delayed(const Duration(milliseconds: MiniGeom.closeMs));
    await widget.onClose();
  }

  void _onScaleStart(ScaleStartDetails d, Size box) {
    if (_closing) return;
    _move.stop();
    _moved = false;
    _startFocal = d.focalPoint;
    _startPos = Offset(_left, _top);
    _startScale = _scale;
    _pinchFx = box.width <= 0
        ? 0.5
        : ((d.focalPoint.dx - _left) / box.width).clamp(0.0, 1.0).toDouble();
    _pinchFy = box.height <= 0
        ? 0.5
        : ((d.focalPoint.dy - _top) / box.height).clamp(0.0, 1.0).toDouble();
  }

  void _onScaleUpdate(ScaleUpdateDetails d, Size screen) {
    if (_closing) return;
    final pinching = (d.scale - 1).abs() > 0.02 || d.pointerCount >= 2;
    if ((_startFocal - d.focalPoint).distance > MiniGeom.tapSlop || pinching) {
      _moved = true;
    }

    if (pinching) {
      _resizing = true;
      _dragging = false;
      if (_hiddenSide != null) {
        _hiddenSide = null;
        _resumeIfNeeded();
      }
      _setArrows(null, 0);
      final nextScale = MiniGeom.clampScale(_startScale * d.scale, screen);
      final box = MiniPhysics.visualBox(screen, MiniPhysics.videoSize(), nextScale);
      setState(() {
        _scale = nextScale;
        _left = d.focalPoint.dx - _pinchFx * box.width;
        _top = d.focalPoint.dy - _pinchFy * box.height;
        _dragOpacity = 1;
      });
      return;
    }

    if (!_moved) return;
    _dragging = true;
    _resizing = false;
    if (_hiddenSide != null) {
      _hiddenSide = null;
      _resumeIfNeeded();
    }
    setState(() {
      _left = _startPos.dx + (d.focalPoint.dx - _startFocal.dx);
      _top = _startPos.dy + (d.focalPoint.dy - _startFocal.dy);
    });
    final r = _rect(_boxFor(screen));
    _dragOpacity = math.max(0.1, 1 - MiniPhysics.offBottom(r, screen));
    _refreshArrows(r, screen, threshold: 0.05);
    setState(() {});
  }

  void _onScaleEnd(ScaleEndDetails d, Size screen, Size box) {
    if (_closing) return;
    final was = _moved;
    _dragging = false;
    _resizing = false;
    if (!was) return;
    _finishDrag(screen, _boxFor(screen));
  }

  Widget _arrow(String side, double width, double leftOffset, Size screen, Size box) {
    return Positioned(
      left: leftOffset,
      top: (box.height - MiniGeom.arrowH) / 2,
      child: GestureDetector(
        onScaleStart: (d) => _onScaleStart(d, box),
        onScaleUpdate: (d) => _onScaleUpdate(d, screen),
        onScaleEnd: (d) => _onScaleEnd(d, screen, box),
        onTap: () {
          if (_moved || _closing) return;
          _unhide(screen, box);
        },
        child: MiniStickyArrow(side: side, width: width),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    _bind();
    final screen = MediaQuery.sizeOf(context);
    final video = MiniPhysics.videoSize();
    final base = MiniPhysics.baseBox(screen, video);
    var box = MiniPhysics.visualBox(screen, video, _scale);

    if (!_ready) {
      _ready = true;
      _scale = MiniGeom.clampScale(1, screen);
      final start = MiniPhysics.visualBox(screen, video, _scale);
      box = start;
      _left = screen.width - start.width - widget.pad.right;
      _top = (screen.height * 0.55 - start.height / 2)
          .clamp(
            widget.pad.top,
            math.max(widget.pad.top, screen.height - widget.navH - start.height),
          )
          .toDouble();
    }

    final c = PlaybackSession.controller;
    final item = PlaybackSession.item;
    var playing = false;
    var progress = 0.0;
    try {
      playing = c?.value.isPlaying ?? false;
      final dur = c?.value.duration.inMilliseconds ?? 0;
      if (dur > 0) {
        progress = (c!.value.position.inMilliseconds / dur)
            .clamp(0.0, 1.0)
            .toDouble();
      }
    } catch (_) {}

    Widget frame;
    try {
      if (c != null && c.value.isInitialized) {
        frame = VideoPicture(
          looks: PictureLooks.current(),
          child: VideoPlayer(c),
        );
      } else {
        frame = const ColoredBox(
          color: Color(0xFF05060A),
          child: Center(child: Icon(Icons.play_circle, color: Colors.white70)),
        );
      }
    } catch (_) {
      frame = const ColoredBox(color: Color(0xFF05060A));
    }

    final live = _dragging || _resizing;
    final aL = _arrowL * MiniGeom.arrowMax;
    final aR = _arrowR * MiniGeom.arrowMax;
    final extraL = aR;
    final extraR = aL;
    final radius = math.max(8.0, base.width * 0.035);
    final scheme = Theme.of(context).colorScheme;
    final closeMs = _closing ? MiniGeom.closeMs : 0;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: _left - extraL,
          top: _top,
          width: box.width + extraL + extraR,
          height: box.height,
          child: AnimatedOpacity(
            duration: Duration(milliseconds: closeMs),
            opacity: _closing ? 0 : _dragOpacity,
            child: AnimatedScale(
              duration: Duration(milliseconds: closeMs),
              scale: _closing ? 0.8 : 1,
              alignment: Alignment.bottomCenter,
              child: AnimatedSlide(
                duration: Duration(milliseconds: closeMs),
                offset: _closing ? const Offset(0, 0.3) : Offset.zero,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned(
                      left: extraL,
                      top: 0,
                      width: box.width,
                      height: box.height,
                      child: GestureDetector(
                        onScaleStart: (d) => _onScaleStart(d, box),
                        onScaleUpdate: (d) => _onScaleUpdate(d, screen),
                        onScaleEnd: (d) => _onScaleEnd(d, screen, box),
                        onTap: () {
                          if (_moved || live || _closing) return;
                          if (_hiddenSide != null) {
                            _unhide(screen, box);
                          } else {
                            widget.onExpand();
                          }
                        },
                        child: Transform.scale(
                          scale: _scale,
                          alignment: Alignment.topLeft,
                          child: SizedBox(
                            width: base.width,
                            height: base.height,
                            child: Material(
                              color: scheme.surface,
                              elevation: 14,
                              borderRadius: BorderRadius.circular(radius),
                              clipBehavior: Clip.antiAlias,
                              child: Column(
                                children: [
                                  Expanded(
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        ColoredBox(
                                            color: const Color(0xFF05060A),
                                            child: frame),
                                        Align(
                                          alignment: Alignment.bottomCenter,
                                          child: SizedBox(
                                            height: 2,
                                            child: LinearProgressIndicator(
                                              value: progress,
                                              backgroundColor: Colors.white24,
                                              color: const Color(0xFF7AA2FF),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  MiniTransportBar(
                                    title: item?.title ?? '',
                                    playing: playing,
                                    onPrev: () => unawaited(widget.onPrev()),
                                    onPlay: () => unawaited(_togglePlay()),
                                    onNext: () => unawaited(widget.onNext()),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    _arrow('left', aL, extraL + box.width, screen, box),
                    _arrow('right', aR, 0, screen, box),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
