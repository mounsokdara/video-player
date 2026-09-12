import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'session.dart';

class MiniGeom {
  MiniGeom._();
  static const minW = 15.0;
  static const maxW = 95.0;
  static const defW = 30.0;
  static const hideT = 0.6;
  static const closeT = 0.6;
  static const tapSlop = 5.0;
  static const arrowMax = 44.0;
  static const arrowH = 120.0;
  static const barH = 44.0;
  static const snapMs = 500;
  static const closeMs = 300;
  static const minPx = 96.0;
  static const ease = Cubic(0.22, 1.0, 0.36, 1.0);

  static double get minScale => minW / defW;
  static double get maxScale => maxW / defW;

  static double clampScale(double scale, Size screen) {
    final baseW = (defW / 100) * screen.width;
    var lo = minScale;
    if (baseW > 1) {
      lo = math.max(minScale, minPx / baseW);
    }
    lo = lo.clamp(minScale, maxScale).toDouble();
    return scale.clamp(lo, maxScale).toDouble();
  }
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

  static Size baseBox(Size screen, Size video) {
    final ar = (video.width <= 0 || video.height <= 0)
        ? 16 / 9
        : video.width / video.height;
    var w = (MiniGeom.defW / 100) * screen.width;
    var vidH = w / ar;
    final maxVid = screen.height * 0.55;
    if (vidH > maxVid) {
      vidH = maxVid;
      w = vidH * ar;
    }
    return Size(w, vidH + MiniGeom.barH);
  }

  static Size visualBox(Size screen, Size video, double scale) {
    final base = baseBox(screen, video);
    return Size(base.width * scale, base.height * scale);
  }

  static double offX(Rect r, Size screen) {
    if (r.width <= 0) return 1;
    final visW = math.max(0.0, math.min(screen.width, r.right) - math.max(0.0, r.left));
    return 1 - visW / r.width;
  }

  static double offBottom(Rect r, Size screen) =>
      r.height <= 0 ? 0 : math.max(0.0, (r.bottom - screen.height) / r.height);

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
