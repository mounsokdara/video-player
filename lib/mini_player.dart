import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'android_bridge.dart';
import 'main.dart';
import 'player.dart';

/// Layout numbers from the HTML mini-player demo. Keep them here.
class MiniGeom {
  MiniGeom._();

  static const minW = 15.0;
  static const maxW = 60.0;
  static const defW = 30.0;
  static const marginX = 1.5;
  static const marginY = 2.0;
  static const offscreen = 0.6;
  static const tapSlop = 8.0;
  static const arrowW = 26.0;
  static const arrowH = 82.0;
  static const barH = 44.0;
  static const snapMs = 500;
  static const ease = Cubic(0.22, 1.0, 0.36, 1.0);
}

/// Off-screen, settle, and hide/close math from the HTML demo.
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
    final ar = (video.width <= 0 || video.height <= 0) ? 16 / 9 : video.width / video.height;
    var w = (widthVw / 100) * screen.width;
    var vidH = w / ar;
    final maxVid = screen.height * 0.40;
    if (vidH > maxVid) {
      vidH = maxVid;
      w = vidH * ar;
    }
    final minW = screen.width * MiniGeom.minW / 100;
    if (w < minW) {
      w = minW;
      vidH = math.min(w / ar, maxVid);
    }
    return Size(w, vidH + MiniGeom.barH);
  }

  static double offscreenFrac(Rect r, Size screen) {
    final ow = math.max(0.0, math.min(r.right, screen.width) - math.max(r.left, 0.0));
    final oh = math.max(0.0, math.min(r.bottom, screen.height) - math.max(r.top, 0.0));
    final total = r.width * r.height;
    if (total <= 0) return 1;
    return 1 - (ow * oh) / total;
  }

  static double offBottom(Rect r, Size screen) {
    if (r.height <= 0) return 0;
    return ((r.bottom - screen.height) / r.height).clamp(0.0, 1.0).toDouble();
  }

  static Offset settlePos(Rect r, Size screen, Size box, {required double navH, required EdgeInsets pad}) {
    final mx = screen.width * MiniGeom.marginX / 100;
    final my = screen.height * MiniGeom.marginY / 100;
    final minX = math.max(mx, pad.left);
    final maxX = math.max(minX, screen.width - box.width - math.max(mx, pad.right));
    final minY = math.max(my, pad.top + 8);
    final maxY = math.max(minY, screen.height - box.height - navH - my);
    final left = (r.left + r.width / 2) < screen.width / 2 ? minX : maxX;
    final top = r.top.clamp(minY, maxY).toDouble();
    return Offset(left, top);
  }
}

/// 26×82 edge tab. Sibling of the player so a clipping Stack cannot eat it.
class MiniStickyArrow extends StatelessWidget {
  const MiniStickyArrow({
    super.key,
    required this.side,
    required this.dragging,
    required this.onTap,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  final String side;
  final bool dragging;
  final VoidCallback onTap;
  final GestureDragStartCallback onDragStart;
  final GestureDragUpdateCallback onDragUpdate;
  final GestureDragEndCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    final left = side == 'left';
    return GestureDetector(
      onTap: onTap,
      onPanStart: onDragStart,
      onPanUpdate: onDragUpdate,
      onPanEnd: onDragEnd,
      onPanCancel: () => onDragEnd(DragEndDetails()),
      child: Material(
        color: const Color(0xFF14161C),
        elevation: 10,
        borderRadius: BorderRadius.horizontal(
          left: left ? Radius.zero : const Radius.circular(8),
          right: left ? const Radius.circular(8) : Radius.zero,
        ),
        child: SizedBox(
          width: MiniGeom.arrowW,
          height: MiniGeom.arrowH,
          child: Icon(
            left ? Icons.chevron_right : Icons.chevron_left,
            size: 14,
            color: const Color(0xFFCFD5E4),
          ),
        ),
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
    Widget ctrl({required String label, required IconData icon, required VoidCallback onTap, bool play = false}) {
      final child = Icon(icon, size: play ? 18 : 17, color: const Color(0xFFCFD5E4));
      return Tooltip(
        message: label,
        child: Material(
          color: play ? Colors.white.withValues(alpha: 0.13) : Colors.transparent,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(width: play ? 34 : 30, height: play ? 34 : 30, child: Center(child: child)),
          ),
        ),
      );
    }

    return SizedBox(
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
                style: const TextStyle(color: Color(0xFFF1F3F8), fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.2),
              ),
            ),
            ctrl(label: 'Previous', icon: Icons.skip_previous, onTap: onPrev),
            const SizedBox(width: 2),
            ctrl(label: playing ? 'Pause' : 'Play', icon: playing ? Icons.pause : Icons.play_arrow, onTap: onPlay, play: true),
            const SizedBox(width: 2),
            ctrl(label: 'Next', icon: Icons.skip_next, onTap: onNext),
          ],
        ),
      ),
    );
  }
}

/// Floating mini player. One [VideoPlayer] texture. Physics match the HTML demo.
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

class _MiniPlayerOverlayState extends State<MiniPlayerOverlay> with SingleTickerProviderStateMixin {
  double _left = 0;
  double _top = 0;
  double _widthVw = MiniGeom.defW;
  bool _ready = false;
  bool _dragging = false;
  bool _resizing = false;
  bool _closing = false;
  bool _moved = false;
  String? _hiddenSide;
  bool _pausedForHide = false;
  Offset _startFocal = Offset.zero;
  Offset _startPos = Offset.zero;
  double _startBoxW = 0;
  double _pinchFx = 0.5;
  double _pinchFy = 0.5;
  VideoPlayerController? _ctrl;

  late final AnimationController _move;
  double _fromLeft = 0;
  double _fromTop = 0;
  double _fromW = MiniGeom.defW;
  double _toLeft = 0;
  double _toTop = 0;
  double _toW = MiniGeom.defW;

  @override
  void initState() {
    super.initState();
    _move = AnimationController(vsync: this, duration: const Duration(milliseconds: MiniGeom.snapMs));
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
    setState(() {
      _left = _fromLeft + (_toLeft - _fromLeft) * t;
      _top = _fromTop + (_toTop - _fromTop) * t;
      _widthVw = _fromW + (_toW - _fromW) * t;
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

  Rect _rect(Size box) => Rect.fromLTWH(_left, _top, box.width, box.height);

  void _park(String side, Size screen, Size box) {
    _hiddenSide = side;
    final left = side == 'left' ? -box.width : screen.width;
    _animateTo(left, _top, _widthVw, onDone: _pauseForHide);
  }

  void _reveal(Size screen, Size box, {bool animate = true}) {
    final side = _hiddenSide ?? ((_left + box.width / 2) < screen.width / 2 ? 'left' : 'right');
    _hiddenSide = null;
    final target = MiniPhysics.settlePos(
      Rect.fromLTWH(side == 'left' ? 0 : screen.width - box.width, _top, box.width, box.height),
      screen,
      box,
      navH: widget.navH,
      pad: widget.pad,
    );
    if (animate) {
      _animateTo(target.dx, target.dy, _widthVw, onDone: _resumeIfNeeded);
    } else {
      _move.stop();
      setState(() {
        _left = target.dx;
        _top = target.dy;
      });
      _resumeIfNeeded();
    }
  }

  void _settle(Size screen, Size box) {
    final w = _widthVw.clamp(MiniGeom.minW, MiniGeom.maxW).toDouble();
    final next = MiniPhysics.box(screen, MiniPhysics.videoSize(), w);
    final target = MiniPhysics.settlePos(_rect(box), screen, next, navH: widget.navH, pad: widget.pad);
    _hiddenSide = null;
    _animateTo(target.dx, target.dy, w, onDone: _resumeIfNeeded);
  }

  void _finishDrag(Size screen, Size box) {
    final r = _rect(box);
    if (MiniPhysics.offBottom(r, screen) >= MiniGeom.offscreen) {
      unawaited(_close(screen, box));
      return;
    }
    if (MiniPhysics.offscreenFrac(r, screen) >= MiniGeom.offscreen) {
      final side = (r.left + r.width / 2) < screen.width / 2 ? 'left' : 'right';
      _park(side, screen, box);
      return;
    }
    if (_hiddenSide != null) {
      _reveal(screen, box);
      return;
    }
    _settle(screen, box);
  }

  Future<void> _close(Size screen, Size box) async {
    if (_closing) return;
    _closing = true;
    _pausedForHide = false;
    _hiddenSide = null;
    _animateTo(_left, screen.height + 8, _widthVw);
    await Future<void>.delayed(const Duration(milliseconds: MiniGeom.snapMs));
    await widget.onClose();
  }

  void _onScaleStart(ScaleStartDetails d, Size box) {
    if (_closing) return;
    _move.stop();
    _moved = false;
    _startFocal = d.focalPoint;
    _startPos = Offset(_left, _top);
    _startBoxW = box.width;
    _pinchFx = box.width <= 0 ? 0.5 : ((d.focalPoint.dx - _left) / box.width).clamp(0.0, 1.0).toDouble();
    _pinchFy = box.height <= 0 ? 0.5 : ((d.focalPoint.dy - _top) / box.height).clamp(0.0, 1.0).toDouble();
  }

  void _onScaleUpdate(ScaleUpdateDetails d, Size screen) {
    if (_closing) return;
    final pinching = (d.scale - 1).abs() > 0.02 || d.pointerCount >= 2;
    if ((_startFocal - d.focalPoint).distance > MiniGeom.tapSlop || pinching) _moved = true;
    if (pinching) {
      _resizing = true;
      _dragging = false;
      if (_hiddenSide != null) {
        _hiddenSide = null;
        _resumeIfNeeded();
      }
      final newWpx = math.max(_startBoxW * d.scale, 40.0);
      var vw = (newWpx / screen.width * 100).clamp(MiniGeom.minW, MiniGeom.maxW).toDouble();
      final box = MiniPhysics.box(screen, MiniPhysics.videoSize(), vw);
      setState(() {
        _widthVw = vw;
        _left = d.focalPoint.dx - _pinchFx * box.width;
        _top = d.focalPoint.dy - _pinchFy * box.height;
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
  }

  void _onScaleEnd(ScaleEndDetails d, Size screen, Size box) {
    if (_closing) return;
    final was = _moved;
    _dragging = false;
    _resizing = false;
    if (!was) return;
    _finishDrag(screen, box);
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

  @override
  Widget build(BuildContext context) {
    _bind();
    final screen = MediaQuery.sizeOf(context);
    final video = MiniPhysics.videoSize();
    final box = MiniPhysics.box(screen, video, _widthVw);
    if (!_ready) {
      _ready = true;
      final mx = math.max(screen.width * MiniGeom.marginX / 100, widget.pad.right);
      final my = math.max(screen.height * MiniGeom.marginY / 100, 8.0);
      _widthVw = MiniGeom.defW;
      final start = MiniPhysics.box(screen, video, _widthVw);
      _left = screen.width - start.width - mx;
      _top = (screen.height * 0.55 - start.height / 2).clamp(my, math.max(my, screen.height - widget.navH - start.height - my)).toDouble();
    }

    final c = PlaybackSession.controller;
    final item = PlaybackSession.item;
    var playing = false;
    var progress = 0.0;
    try {
      playing = c?.value.isPlaying ?? false;
      final dur = c?.value.duration.inMilliseconds ?? 0;
      if (dur > 0) progress = (c!.value.position.inMilliseconds / dur).clamp(0.0, 1.0).toDouble();
    } catch (_) {}

    Widget frame;
    try {
      if (c != null && c.value.isInitialized) {
        frame = VideoPlayer(c);
      } else {
        frame = const ColoredBox(color: Color(0xFF05060A), child: Center(child: Icon(Icons.play_circle, color: Colors.white70)));
      }
    } catch (_) {
      frame = const ColoredBox(color: Color(0xFF05060A));
    }

    final hidden = _hiddenSide != null && !_dragging && !_resizing;
    final animating = _move.isAnimating;
    final arrowTop = (_top + box.height / 2 - MiniGeom.arrowH / 2).clamp(8.0, math.max(8.0, screen.height - MiniGeom.arrowH - 8)).toDouble();

    return Stack(
      clipBehavior: Clip.none,
      children: [
        if (!_closing)
          Positioned(
            left: _left,
            top: _top,
            width: box.width,
            height: box.height,
            child: IgnorePointer(
              ignoring: hidden,
              child: Opacity(
                opacity: hidden && !animating ? 0 : 1,
                child: GestureDetector(
                  onScaleStart: (d) => _onScaleStart(d, box),
                  onScaleUpdate: (d) => _onScaleUpdate(d, screen),
                  onScaleEnd: (d) => _onScaleEnd(d, screen, box),
                  onTap: () {
                    if (_moved || _dragging) return;
                    if (_hiddenSide != null) {
                      _reveal(screen, box);
                      return;
                    }
                    widget.onExpand();
                  },
                  child: Material(
                    color: const Color(0xFF14161C),
                    elevation: 14,
                    borderRadius: BorderRadius.circular(math.max(8, box.width * 0.035)),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        Expanded(
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              ColoredBox(color: const Color(0xFF05060A), child: frame),
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
        if (_hiddenSide != null && !_closing)
          Positioned(
            left: _hiddenSide == 'left' ? 0 : screen.width - MiniGeom.arrowW,
            top: arrowTop,
            width: MiniGeom.arrowW,
            height: MiniGeom.arrowH,
            child: MiniStickyArrow(
              side: _hiddenSide!,
              dragging: _dragging,
              onTap: () => _reveal(screen, box),
              onDragStart: (d) {
                _moved = false;
                _startFocal = d.globalPosition;
                _startPos = Offset(_left, _top);
              },
              onDragUpdate: (d) {
                if ((d.globalPosition - _startFocal).distance < MiniGeom.tapSlop && !_moved) return;
                if (!_moved) {
                  _moved = true;
                  _hiddenSide = null;
                  _resumeIfNeeded();
                }
                setState(() {
                  _dragging = true;
                  _left += d.delta.dx;
                  _top += d.delta.dy;
                });
              },
              onDragEnd: (_) {
                _dragging = false;
                if (!_moved) {
                  _reveal(screen, box);
                } else {
                  _finishDrag(screen, MiniPhysics.box(screen, MiniPhysics.videoSize(), _widthVw));
                }
              },
            ),
          ),
      ],
    );
  }
}
