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
    with TickerProviderStateMixin {
  final GlobalKey _cardKey = GlobalKey();

  late final AnimationController _anim;
  Animation<Offset>? _posAnim;
  Animation<double>? _wAnim;

  double _w = MiniGeom.defW;
  Offset? _pos;
  var _parked = false;
  int _parkSide = 0;
  bool _dismissed = false;
  bool _wasPlayingBeforePark = false;
  bool _moved = false;
  bool _live = false;

  double _startW = MiniGeom.defW;
  Offset _startPos = Offset.zero;
  Offset _parentOrigin = Offset.zero;
  Offset _anchorInWidget = Offset.zero;

  VideoPlayerController? _ctrl;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(vsync: this);
    _anim.addListener(() {
      setState(() {
        if (_posAnim != null) _pos = _posAnim!.value;
        if (_wAnim != null) _w = _wAnim!.value;
      });
    });
    _bind();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bind();
  }

  @override
  void dispose() {
    _anim.dispose();
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

  Size get _screen => MediaQuery.sizeOf(context);

  Rect get _safe => MiniPhysics.safeZone(
        _screen,
        pad: widget.pad,
        navH: widget.navH,
      );

  Size get _video => MiniPhysics.videoSize();

  double get _h => MiniPhysics.boxFor(_w, _video).height;

  Offset get _rawPos =>
      _pos ?? MiniPhysics.defaultPos(_screen, _w, _h, _safe);

  double _overhang(Offset pos) {
    if (_parked) return 0;
    final screenW = _screen.width;
    if (pos.dx < 0) return -pos.dx;
    if (pos.dx + _w > screenW) return pos.dx + _w - screenW;
    return 0;
  }

  int _sideFor(Offset pos) {
    if (_parked) return _parkSide;
    final screenW = _screen.width;
    if (pos.dx < 0) return -1;
    if (pos.dx + _w > screenW) return 1;
    return 0;
  }

  double _arrowWidthFor(Offset pos) {
    if (!_parked && _overhang(pos) <= 0) return 0;
    if (_parked) return MiniGeom.arrowMaxW;
    final o = _overhang(pos);
    final full = MiniGeom.parkT * _w;
    return (MiniGeom.arrowMaxW * (o / full)).clamp(0.0, MiniGeom.arrowMaxW).toDouble();
  }

  void _pauseForPark() {
    final c = PlaybackSession.controller;
    if (c == null) return;
    try {
      if (c.value.isPlaying) {
        _wasPlayingBeforePark = true;
        unawaited(c.pause());
      }
    } catch (_) {}
  }

  void _resumeIfNeeded() {
    if (!_wasPlayingBeforePark) return;
    _wasPlayingBeforePark = false;
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
    if (_dismissed) return;
    final c = PlaybackSession.controller;
    if (c == null) return;
    try {
      if (c.value.isPlaying) {
        _wasPlayingBeforePark = false;
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

  void _onScaleStart(ScaleStartDetails d) {
    if (_dismissed) return;
    _anim.stop();
    final box = _cardKey.currentContext?.findRenderObject() as RenderBox?;
    final cardGlobal = box?.localToGlobal(Offset.zero) ?? Offset.zero;
    _startW = _w;
    _startPos = _rawPos;
    _parentOrigin = cardGlobal - _startPos;
    final focalInParent = d.focalPoint - _parentOrigin;
    _anchorInWidget = focalInParent - _startPos;
    _moved = false;
    final wasParked = _parked;
    setState(() {
      _parked = false;
      _parkSide = 0;
      _dismissed = false;
      _live = true;
    });
    if (wasParked) _resumeIfNeeded();
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (_dismissed) return;
    final pinching = (d.scale - 1).abs() > 0.02 || d.pointerCount >= 2;
    if ((_startPos - _rawPos).distance > MiniGeom.tapSlop ||
        (d.focalPoint - (_parentOrigin + _startPos + _anchorInWidget)).distance >
            MiniGeom.tapSlop ||
        pinching) {
      _moved = true;
    }
    final hi = MiniPhysics.maxWFor(_screen);
    final lo = math.min(MiniGeom.minW, hi);
    final targetW = MiniPhysics.softClamp(_startW * d.scale, lo, hi);
    final ratio = _startW == 0 ? 1.0 : targetW / _startW;
    final focalInParent = d.focalPoint - _parentOrigin;
    final newPos = focalInParent - _anchorInWidget * ratio;
    setState(() {
      _w = targetW;
      _pos = newPos;
      if (_parked) {
        _parked = false;
        _parkSide = 0;
        _resumeIfNeeded();
      }
    });
  }

  void _onScaleEnd(ScaleEndDetails _) {
    if (_dismissed) return;
    _live = false;
    if (!_moved) {
      if (_parked) {
        _unpark();
      } else {
        widget.onExpand();
      }
      return;
    }
    _settle();
  }

  void _onArrowPanStart(DragStartDetails _) {
    if (_dismissed) return;
    _anim.stop();
    setState(() {
      _parked = false;
      _parkSide = 0;
      _dismissed = false;
      _live = true;
    });
    _resumeIfNeeded();
  }

  void _onArrowPanUpdate(DragUpdateDetails d) {
    setState(() => _pos = _rawPos + d.delta);
  }

  void _onArrowPanEnd(DragEndDetails _) {
    _live = false;
    _settle();
  }

  void _settle() {
    final screen = _screen;
    final settledW = MiniPhysics.clampW(_w, screen);
    final fromPos = _rawPos;
    final video = _video;
    final settledH = MiniPhysics.boxFor(settledW, video).height;
    final safe = _safe;
    final dismissThresholdY = screen.height - (settledH * 0.4);

    if (fromPos.dy >= dismissThresholdY) {
      _pauseForPark();
      final targetY = screen.height + 20;
      setState(() {
        _parked = false;
        _parkSide = 0;
        _dismissed = true;
      });
      _animate(fromPos, Offset(fromPos.dx, targetY), _w, settledW, 280, () {
        unawaited(widget.onClose());
      });
      return;
    }

    final overhang = _overhang(fromPos);
    final full = MiniGeom.parkT * settledW;
    late final Offset to;
    if (overhang >= full) {
      final side = fromPos.dx < 0 ? -1 : 1;
      _pauseForPark();
      final targetX = side < 0 ? -settledW : screen.width;
      final maxY = math.max(safe.top, safe.bottom - settledH);
      final targetY = fromPos.dy.clamp(safe.top, maxY).toDouble();
      to = Offset(targetX, targetY);
      setState(() {
        _parked = true;
        _parkSide = side;
      });
    } else {
      to = MiniPhysics.edgeTarget(fromPos, settledW, settledH, safe);
      setState(() {
        _parked = false;
        _parkSide = 0;
      });
    }
    final dist = (to - fromPos).distance;
    final ms = (220 + dist * 0.45).clamp(220, 700).round();
    _animate(fromPos, to, _w, settledW, ms, null);
  }

  void _unpark() {
    if (!_parked && _parkSide == 0) return;
    final side = _parkSide == 0 ? _sideFor(_rawPos) : _parkSide;
    final video = _video;
    final targetW = MiniPhysics.clampW(_w, _screen);
    final targetH = MiniPhysics.boxFor(targetW, video).height;
    final safe = _safe;
    final targetX = side < 0 ? safe.left : math.max(safe.left, safe.right - targetW);
    final maxY = math.max(safe.top, safe.bottom - targetH);
    final targetY = _rawPos.dy.clamp(safe.top, maxY).toDouble();
    final fromPos = _rawPos;
    final to = Offset(targetX, targetY);
    final dist = (to - fromPos).distance;
    final ms = (220 + dist * 0.45).clamp(220, 700).round();
    setState(() {
      _parked = false;
      _parkSide = 0;
    });
    _resumeIfNeeded();
    _animate(fromPos, to, _w, targetW, ms, null);
  }

  void _animate(
    Offset from,
    Offset to,
    double fromW,
    double toW,
    int ms,
    VoidCallback? onDone,
  ) {
    _posAnim = Tween<Offset>(begin: from, end: to).animate(
      CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic),
    );
    _wAnim = Tween<double>(begin: fromW, end: toW).animate(
      CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic),
    );
    _anim.duration = Duration(milliseconds: ms);
    _anim.forward(from: 0).whenComplete(() {
      if (!mounted) return;
      _pos = to;
      _w = toW;
      onDone?.call();
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    _bind();
    final pos = _rawPos;
    final side = _sideFor(pos);
    final arrowW = _arrowWidthFor(pos);
    final h = _h;
    final scheme = Theme.of(context).colorScheme;

    final double arrowLeft;
    if (side < 0) {
      arrowLeft = pos.dx + _w;
    } else if (side > 0) {
      arrowLeft = pos.dx - arrowW;
    } else {
      arrowLeft = 0;
    }
    final arrowTop = pos.dy + h / 2 - MiniGeom.arrowH / 2;

    var dismissProgress = 1.0;
    if (pos.dy > _screen.height - h) {
      final beyond = pos.dy - (_screen.height - h);
      dismissProgress = (1.0 - (beyond / (h * 0.6))).clamp(0.0, 1.0).toDouble();
    }
    final opacity = _dismissed ? 0.0 : dismissProgress;

    final c = PlaybackSession.controller;
    final item = PlaybackSession.item;
    var playing = false;
    var progress = 0.0;
    try {
      playing = c?.value.isPlaying ?? false;
      final dur = c?.value.duration.inMilliseconds ?? 0;
      if (dur > 0) {
        progress = (c!.value.position.inMilliseconds / dur).clamp(0.0, 1.0).toDouble();
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
        frame = ColoredBox(
          color: const Color(0xFF05060A),
          child: Icon(Icons.play_circle, color: scheme.onSurface.withValues(alpha: 0.5)),
        );
      }
    } catch (_) {
      frame = const ColoredBox(color: Color(0xFF05060A));
    }

    final strokeColor = _live ? scheme.primary : scheme.outlineVariant;
    final strokeWidth = _live ? 1.6 : 1.0;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: pos.dx,
          top: pos.dy,
          width: _w,
          height: h,
          child: Opacity(
            opacity: opacity,
            child: IgnorePointer(
              ignoring: _dismissed || opacity < 0.1,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onScaleStart: _onScaleStart,
                onScaleUpdate: _onScaleUpdate,
                onScaleEnd: _onScaleEnd,
                child: Material(
                  key: _cardKey,
                  color: scheme.surface,
                  elevation: 0,
                  shadowColor: Colors.transparent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: BorderSide(
                      color: strokeColor,
                      width: strokeWidth,
                    ),
                  ),
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
                                height: 3,
                                child: LinearProgressIndicator(
                                  value: progress,
                                  minHeight: 3,
                                  backgroundColor: Colors.white24,
                                  color: const Color(0xFF9E8CFF),
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
        if (!_dismissed)
          Positioned(
            left: arrowLeft,
            top: arrowTop,
            width: arrowW,
            height: MiniGeom.arrowH,
            child: IgnorePointer(
              ignoring: arrowW < 6,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _unpark,
                onPanStart: _onArrowPanStart,
                onPanUpdate: _onArrowPanUpdate,
                onPanEnd: _onArrowPanEnd,
                child: DecoratedBox(
                  position: DecorationPosition.foreground,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.horizontal(
                      left: side > 0 ? Radius.zero : const Radius.circular(8),
                      right: side > 0 ? const Radius.circular(8) : Radius.zero,
                    ),
                    border: Border.all(
                      color: strokeColor,
                      width: strokeWidth,
                    ),
                  ),
                  child: MiniStickyArrow(side: side == 0 ? 1 : side, width: arrowW),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
