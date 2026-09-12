import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'mini_geom.dart';

class MiniStickyArrow extends StatelessWidget {
  const MiniStickyArrow({
    super.key,
    required this.side,
    required this.width,
  });

  final int side;
  final double width;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          CustomPaint(
            painter: _ArrowPainter(side: side, color: scheme.surface),
          ),
          Opacity(
            opacity: ((width - 8) / 16).clamp(0.0, 1.0).toDouble(),
            child: CustomPaint(
              painter: _ChevronPainter(
                color: scheme.onSurface.withValues(alpha: 0.7),
                pointRight: side < 0,
              ),
            ),
          ),
        ],
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
    return ColoredBox(
      color: scheme.surface,
      child: SizedBox(
        height: MiniGeom.barH,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
              ),
              _BarButton(icon: Icons.skip_previous_rounded, onTap: onPrev),
              _BarButton(
                icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                onTap: onPlay,
              ),
              _BarButton(icon: Icons.skip_next_rounded, onTap: onNext),
            ],
          ),
        ),
      ),
    );
  }
}

class _BarButton extends StatelessWidget {
  const _BarButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkResponse(
      onTap: onTap,
      radius: 20,
      child: SizedBox(
        width: 32,
        height: MiniGeom.barH,
        child: Icon(icon, size: 20, color: Theme.of(context).colorScheme.onSurface),
      ),
    );
  }
}

class _ArrowPainter extends CustomPainter {
  _ArrowPainter({required this.side, required this.color});
  final int side;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final paint = Paint()..color = color;
    const r = 12.0;
    final w = size.width;
    final h = size.height;
    final rr = math.min(r, math.min(w, h) / 2);
    final path = Path();
    if (side < 0) {
      path.moveTo(0, 0);
      path.lineTo(w - rr, 0);
      path.quadraticBezierTo(w, 0, w, rr);
      path.lineTo(w, h - rr);
      path.quadraticBezierTo(w, h, w - rr, h);
      path.lineTo(0, h);
      path.close();
    } else {
      path.moveTo(w, 0);
      path.lineTo(rr, 0);
      path.quadraticBezierTo(0, 0, 0, rr);
      path.lineTo(0, h - rr);
      path.quadraticBezierTo(0, h, rr, h);
      path.lineTo(w, h);
      path.close();
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_ArrowPainter old) => old.side != side || old.color != color;
}

class _ChevronPainter extends CustomPainter {
  const _ChevronPainter({required this.color, required this.pointRight});
  final Color color;
  final bool pointRight;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final cx = size.width / 2;
    final cy = size.height / 2;
    const hw = 4.0;
    const hh = 7.0;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path();
    if (pointRight) {
      path.moveTo(cx - hw, cy - hh);
      path.lineTo(cx + hw, cy);
      path.lineTo(cx - hw, cy + hh);
    } else {
      path.moveTo(cx + hw, cy - hh);
      path.lineTo(cx - hw, cy);
      path.lineTo(cx + hw, cy + hh);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_ChevronPainter old) =>
      old.color != color || old.pointRight != pointRight;
}
