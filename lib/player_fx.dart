import 'dart:math' as math;

import 'package:flutter/material.dart';

enum TapZone { left, middle, right }

TapZone tapZoneFor(Offset pos, Size size) {
  if (pos.dx < size.width * 0.30) return TapZone.left;
  if (pos.dx > size.width * 0.70) return TapZone.right;
  return TapZone.middle;
}

class RippleSpec {
  RippleSpec({
    required this.id,
    required this.local,
    required this.radius,
    required this.zone,
  });
  final int id;
  final Offset local;
  final double radius;
  final TapZone zone;
}

class PlayerRippleLayer extends StatelessWidget {
  const PlayerRippleLayer({
    super.key,
    required this.size,
    required this.ripples,
    required this.leftCount,
    required this.rightCount,
    required this.leftOn,
    required this.rightOn,
    required this.midOn,
    required this.playing,
    required this.reduceMotion,
    required this.onRippleDone,
  });

  final Size size;
  final List<RippleSpec> ripples;
  final int leftCount;
  final int rightCount;
  final bool leftOn;
  final bool rightOn;
  final bool midOn;
  final bool playing;
  final bool reduceMotion;
  final ValueChanged<int> onRippleDone;

  @override
  Widget build(BuildContext context) {
    final leftW = size.width * 0.30;
    final rightW = size.width * 0.30;
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: [
                for (final r in ripples.where((e) => e.zone == TapZone.middle))
                  _RippleBlob(
                    key: ValueKey(r.id),
                    spec: r,
                    reduceMotion: reduceMotion,
                    onDone: () => onRippleDone(r.id),
                  ),
              ],
            ),
          ),
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: leftW,
            child: ClipPath(
              clipper: const _DPadClipper(fromLeft: true),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  for (final r in ripples.where((e) => e.zone == TapZone.left))
                    _RippleBlob(
                      key: ValueKey(r.id),
                      spec: r,
                      reduceMotion: reduceMotion,
                      onDone: () => onRippleDone(r.id),
                    ),
                  if (leftOn) _SeekIndicator(seconds: leftCount, left: true),
                ],
              ),
            ),
          ),
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            width: rightW,
            child: ClipPath(
              clipper: const _DPadClipper(fromLeft: false),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  for (final r in ripples.where((e) => e.zone == TapZone.right))
                    _RippleBlob(
                      key: ValueKey(r.id),
                      spec: r,
                      reduceMotion: reduceMotion,
                      onDone: () => onRippleDone(r.id),
                    ),
                  if (rightOn) _SeekIndicator(seconds: rightCount, left: false),
                ],
              ),
            ),
          ),
          if (midOn) _PlayPauseIndicator(playing: playing),
        ],
      ),
    );
  }
}

class _DPadClipper extends CustomClipper<Path> {
  const _DPadClipper({required this.fromLeft});
  final bool fromLeft;

  @override
  Path getClip(Size size) {
    final r = Radius.elliptical(size.width, size.height / 2);
    final rect = Offset.zero & size;
    final rrect = fromLeft
        ? RRect.fromRectAndCorners(rect, topRight: r, bottomRight: r)
        : RRect.fromRectAndCorners(rect, topLeft: r, bottomLeft: r);
    return Path()..addRRect(rrect);
  }

  @override
  bool shouldReclip(covariant _DPadClipper old) => old.fromLeft != fromLeft;
}

class _RippleBlob extends StatefulWidget {
  const _RippleBlob({
    super.key,
    required this.spec,
    required this.reduceMotion,
    required this.onDone,
  });
  final RippleSpec spec;
  final bool reduceMotion;
  final VoidCallback onDone;

  @override
  State<_RippleBlob> createState() => _RippleBlobState();
}

class _RippleBlobState extends State<_RippleBlob> with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: widget.reduceMotion ? Duration.zero : const Duration(milliseconds: 1150),
    );
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed) widget.onDone();
    });
    _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final spec = widget.spec;
    final d = spec.radius * 2;
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) {
        final t = _c.value;
        final scale = t < 0.70 ? const Cubic(0.18, 0.62, 0.30, 1).transform(t / 0.70) : 1.0;
        final opacity = t < 0.70 ? 0.55 : 0.55 * (1 - (t - 0.70) / 0.30);
        return Positioned(
          left: spec.local.dx - spec.radius,
          top: spec.local.dy - spec.radius,
          width: d,
          height: d,
          child: Transform.scale(
            scale: scale,
            child: Opacity(
              opacity: opacity.clamp(0.0, 1.0),
              child: const DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0x4DFFFFFF),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SeekIndicator extends StatelessWidget {
  const _SeekIndicator({required this.seconds, required this.left});
  final int seconds;
  final bool left;

  @override
  Widget build(BuildContext context) {
    final chevs = _Chevrons(left: left);
    final secs = _PopSecs(key: ValueKey(seconds), value: seconds);
    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: left ? [secs, const SizedBox(width: 14), chevs] : [chevs, const SizedBox(width: 14), secs],
      ),
    );
  }
}

class _PopSecs extends StatefulWidget {
  const _PopSecs({super.key, required this.value});
  final int value;

  @override
  State<_PopSecs> createState() => _PopSecsState();
}

class _PopSecsState extends State<_PopSecs> with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 340))..forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, child) {
        final t = _c.value;
        final s = t < 0.45 ? 1 + 0.18 * (t / 0.45) : 1.18 - 0.18 * ((t - 0.45) / 0.55);
        return Transform.scale(scale: s, child: child);
      },
      child: Text(
        '${widget.value}',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 26,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
          height: 1,
          shadows: [Shadow(color: Color(0x99000000), blurRadius: 10, offset: Offset(0, 2))],
        ),
      ),
    );
  }
}

class _Chevrons extends StatelessWidget {
  const _Chevrons({required this.left});
  final bool left;

  @override
  Widget build(BuildContext context) {
    final angle = left ? -135 * math.pi / 180 : 45 * math.pi / 180;
    Widget chev(double opacity) {
      return Opacity(
        opacity: opacity,
        child: Transform.rotate(
          angle: angle,
          child: Container(
            width: 12,
            height: 12,
            margin: const EdgeInsets.symmetric(horizontal: 0.5),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(2),
              border: const Border(
                top: BorderSide(color: Colors.white, width: 3),
                right: BorderSide(color: Colors.white, width: 3),
              ),
            ),
          ),
        ),
      );
    }

    final kids = [chev(0.55), chev(0.78), chev(1)];
    return Row(mainAxisSize: MainAxisSize.min, children: left ? kids.reversed.toList() : kids);
  }
}

class _PlayPauseIndicator extends StatelessWidget {
  const _PlayPauseIndicator({required this.playing});
  final bool playing;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 88,
        height: 88,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.black.withValues(alpha: 0.30),
          boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 28, offset: Offset(0, 8))],
        ),
        child: Center(
          child: playing
              ? Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: CustomPaint(size: const Size(26, 32), painter: _PlayPainter()),
                )
              : const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _PauseBar(),
                    SizedBox(width: 9),
                    _PauseBar(),
                  ],
                ),
        ),
      ),
    );
  }
}

class _PauseBar extends StatelessWidget {
  const _PauseBar();
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 9,
      height: 32,
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(3)),
    );
  }
}

class _PlayPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, size.height / 2)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

RippleSpec makeRipple({
  required int id,
  required TapZone zone,
  required Offset pos,
  required Size size,
}) {
  final layer = switch (zone) {
    TapZone.left => Rect.fromLTWH(0, 0, size.width * 0.30, size.height),
    TapZone.right => Rect.fromLTWH(size.width * 0.70, 0, size.width * 0.30, size.height),
    TapZone.middle => Rect.fromLTWH(0, 0, size.width, size.height),
  };
  final local = Offset(pos.dx - layer.left, pos.dy - layer.top);
  final dx = math.max(local.dx, layer.width - local.dx);
  final dy = math.max(local.dy, layer.height - local.dy);
  return RippleSpec(id: id, local: local, radius: math.sqrt(dx * dx + dy * dy), zone: zone);
}
