import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'android_bridge.dart';
import 'main.dart';
import 'session.dart';

class MiniGeom {
  MiniGeom._();
  static const minW = 15.0;
  static const maxW = 95.0;
  static const defW = 30.0;
  static const hideT = 0.6;
  static const tapSlop = 5.0;
  static const arrowMax = 44.0;
  static const arrowH = 120.0;
  static const barH = 44.0;
  static const snapMs = 500;
  static const ease = Cubic(0.22, 1.0, 0.36, 1.0);
}

class MiniPhysics {
  MiniPhysics._();

  static Size videoSize() {
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

  static Size box(Size screen, Size video, double widthVw) {
    final ar = (video.width <= 0 || video.height <= 0)
        ? 16 / 9
        : video.width / video.height;
    var w = (widthVw / 100) * screen.width;
    var vidH = w / ar;
    final maxVid = screen.height * 0.55;
    if (vidH > maxVid) {
      vidH = maxVid;
      w = vidH * ar;
    }
    return Size(w, vidH + MiniGeom.barH);
  }

  static double offX(Rect r, Size screen) {
    if (r.width <= 0) return 1;
    final visW = math.max(0.0, math.min(screen.width, r.right) - math.max(0.0, r.left));
    return 1 - visW / r.width;
  }

  static Offset settlePos(
    Rect r,
    Size screen,
    Size box, {
    required double navH,
    required EdgeInsets pad,
  }) {
    final minX = pad.left;
    final maxX = math.max(minX, screen.width - box.width - pad.right);
    final minY = pad.top;
    final maxY = math.max(minY, screen.height - box.height - navH);
    final left = (r.left + r.width / 2) < screen.width / 2 ? minX : maxX;
    final top = r.top.clamp(minY, maxY).toDouble();
    return Offset(left, top);
  }
}

class MiniStickyArrow extends StatelessWidget {
  const MiniStickyArrow({
    super.key,
    required this.side,
    required this.width,
  });

  final String side;
  final double width;

  @override
  Widget build(BuildContext context) {
    final left = side == 'left';
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: MiniGeom.ease,
      width: width,
      height: MiniGeom.arrowH,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.horizontal(
          left: left ? Radius.zero : const Radius.circular(12),
          right: left ? const Radius.circular(12) : Radius.zero,
        ),
      ),
      clipBehavior: Clip.hardEdge,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 250),
        curve: MiniGeom.ease,
        opacity: width < 8 ? 0 : 1,
        child: Icon(left ? Icons.chevron_right : Icons.chevron_left,
            size: 24, color: scheme.onSurface),
      ),
    );
  }
}

class MiniTransportBar extends StatelessWidget {
  const MiniTransportBar({
    super.key,
    required this.title,
    required this.playing,
    required this.onPrev,
    required this.onPlay,
    required this.onNext,
  });

  final String title;
  final bool playing;
  final VoidCallback onPrev;
  final VoidCallback onPlay;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    Widget ctrl(String label, IconData icon, VoidCallback onTap, {bool play = false}) {
      final size = play ? 34.0 : 30.0;
      return Tooltip(
        message: label,
        child: Material(
          color: play ? scheme.onSurface.withValues(alpha: 0.12) : Colors.transparent,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: size,
              height: size,
              child: Icon(icon, size: play ? 18 : 17, color: scheme.onSurface),
            ),
          ),
        ),
      );
    }

    return ColoredBox(
      color: scheme.surface,
      child: SizedBox(
        height: MiniGeom.barH,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
              ctrl('Previous', Icons.skip_previous, onPrev),
              const SizedBox(width: 4),
              ctrl(playing ? 'Pause' : 'Play',
                  playing ? Icons.pause : Icons.play_arrow, onPlay, play: true),
              const SizedBox(width: 4),
              ctrl('Next', Icons.skip_next, onNext),
            ],
          ),
        ),
      ),
    );
  }
}

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
  double _widthVw = MiniGeom.defW;
  bool _ready = false;
  bool _dragging = false;
  bool _moved = false;
  String? _hiddenSide;
  bool _pausedForHide = false;
  double _arrowL = 0, _arrowR = 0;
  Offset _startFocal = Offset.zero;
  Offset _startPos = Offset.zero;
  VideoPlayerController? _ctrl;

  late final AnimationController _move;
  double _fromLeft = 0, _fromTop = 0, _fromW = MiniGeom.defW;
  double _toLeft = 0, _toTop = 0, _toW = MiniGeom.defW;

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
      _widthVw = _fromW + (_toW - _fromW) * t;
      _followArrows();
    });
  }

  void _animateTo(double left, double top, double widthVw, {VoidCallback? onDone}) {
    _fromLeft = _left;
    _fromTop = _top;
    _fromW = _widthVw;
    _toLeft = left;
    _toTop = top;
    _toW = widthVw;
    _move.stop();
    _move.duration = const Duration(milliseconds: MiniGeom.snapMs);
    _move.forward(from: 0).whenComplete(() {
      if (!mounted) return;
      _left = _toLeft;
      _top = _toTop;
      _widthVw = _toW;
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
      MiniPhysics.box(screen, MiniPhysics.videoSize(), _widthVw);

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
    if (!mounted || _dragging) return;
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
    final left = side == 'left' ? -box.width : screen.width;
    _animateTo(left, _top, _widthVw, onDone: () {
      if (!mounted) return;
      _setArrows(side, 1);
      _pauseForHide();
    });
  }

  void _unhide(Size screen, Size box) {
    final side = _hiddenSide ?? _sideFor(_rect(box), screen);
    _setArrows(side, 1);
    _dragging = false;
    final seed = Rect.fromLTWH(
      side == 'left' ? 0 : screen.width - box.width,
      _top,
      box.width,
      box.height,
    );
    final target = MiniPhysics.settlePos(seed, screen, box,
        navH: widget.navH, pad: widget.pad);
    _animateTo(target.dx, target.dy, _widthVw, onDone: () {
      if (!mounted) return;
      _hiddenSide = null;
      _followArrows();
      _resumeIfNeeded();
    });
  }

  void _settle(Size screen, Size box) {
    final w = _widthVw.clamp(MiniGeom.minW, MiniGeom.maxW).toDouble();
    final next = MiniPhysics.box(screen, MiniPhysics.videoSize(), w);
    final target = MiniPhysics.settlePos(_rect(box), screen, next,
        navH: widget.navH, pad: widget.pad);
    _hiddenSide = null;
    _setArrows(null, 0);
    _animateTo(target.dx, target.dy, w, onDone: _resumeIfNeeded);
  }

  void _finishDrag(Size screen, Size box) {
    final r = _rect(box);
    final ox = MiniPhysics.offX(r, screen);

    if (ox >= MiniGeom.hideT) {
      _park(_sideFor(r, screen), screen, box);
    } else if (_hiddenSide != null) {
      _unhide(screen, box);
    } else {
      _settle(screen, box);
    }
  }

  void _onScaleStart(ScaleStartDetails d) {
    _move.stop();
    _moved = false;
    _startFocal = d.focalPoint;
    _startPos = Offset(_left, _top);
  }

  void _onScaleUpdate(ScaleUpdateDetails d, Size screen) {
    if ((_startFocal - d.focalPoint).distance > MiniGeom.tapSlop) _moved = true;
    if (!_moved) return;

    _dragging = true;
    if (_hiddenSide != null) {
      _hiddenSide = null;
      _resumeIfNeeded();
    }
    setState(() {
      _left = _startPos.dx + (d.focalPoint.dx - _startFocal.dx);
      _top = _startPos.dy + (d.focalPoint.dy - _startFocal.dy);
    });
    _refreshArrows(_rect(_boxFor(screen)), screen, threshold: 0.05);
    setState(() {});
  }

  void _onScaleEnd(ScaleEndDetails d, Size screen) {
    final was = _moved;
    _dragging = false;
    if (!was) return;
    _finishDrag(screen, _boxFor(screen));
  }

  Widget _arrow(String side, double width, double leftOffset, Size screen, Size box) {
    return Positioned(
      left: leftOffset,
      top: (box.height - MiniGeom.arrowH) / 2,
      child: GestureDetector(
        onScaleStart: _onScaleStart,
        onScaleUpdate: (d) => _onScaleUpdate(d, screen),
        onScaleEnd: (d) => _onScaleEnd(d, screen),
        onTap: () {
          if (_moved) return;
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
    final box = MiniPhysics.box(screen, video, _widthVw);

    if (!_ready) {
      _ready = true;
      _widthVw = MiniGeom.defW;
      final start = MiniPhysics.box(screen, video, _widthVw);
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
        frame = VideoPlayer(c);
      } else {
        frame = const ColoredBox(
          color: Color(0xFF05060A),
          child: Center(child: Icon(Icons.play_circle, color: Colors.white70)),
        );
      }
    } catch (_) {
      frame = const ColoredBox(color: Color(0xFF05060A));
    }

    final aL = _arrowL * MiniGeom.arrowMax;
    final aR = _arrowR * MiniGeom.arrowMax;
    final extraL = aR;
    final extraR = aL;
    final radius = math.max(8.0, box.width * 0.035);
    final scheme = Theme.of(context).colorScheme;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: _left - extraL,
          top: _top,
          width: box.width + extraL + extraR,
          height: box.height,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: extraL,
                top: 0,
                width: box.width,
                height: box.height,
                child: GestureDetector(
                  onScaleStart: _onScaleStart,
                  onScaleUpdate: (d) => _onScaleUpdate(d, screen),
                  onScaleEnd: (d) => _onScaleEnd(d, screen),
                  onTap: () {
                    if (_moved) return;
                    if (_hiddenSide != null) {
                      _unhide(screen, box);
                    } else {
                      widget.onExpand();
                    }
                  },
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
              _arrow('left', aL, extraL + box.width, screen, box),
              _arrow('right', aR, 0, screen, box),
            ],
          ),
        ),
      ],
    );
  }
}
