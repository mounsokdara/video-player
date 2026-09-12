import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'session.dart';

class MiniGeom {
  MiniGeom._();
  static const defW = 216.0;
  static const minW = 140.0;
  static const maxW = 520.0;
  static const fallbackAr = 216 / 122;
  static const barH = 44.0;
  static const safeInset = 16.0;
  static const arrowMaxW = 28.0;
  static const arrowH = 132.0;
  static const parkT = 0.6;
  static const rubber = 0.35;
  static const tapSlop = 5.0;
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
    return const Size(216, 122);
  }

  static double aspect(Size video) {
    if (video.width <= 0 || video.height <= 0) return MiniGeom.fallbackAr;
    return video.width / video.height;
  }

  static Size boxFor(double w, Size video) {
    final ar = aspect(video);
    return Size(w, w / ar + MiniGeom.barH);
  }

  static double maxWFor(Size screen) =>
      math.min(MiniGeom.maxW, math.max(MiniGeom.minW, screen.width * 0.95));

  static double clampW(double w, Size screen) {
    final hi = maxWFor(screen);
    final lo = math.min(MiniGeom.minW, hi);
    return w.clamp(lo, hi).toDouble();
  }

  static double softClamp(double v, double lo, double hi, [double k = MiniGeom.rubber]) {
    if (v < lo) return lo - (lo - v) * k;
    if (v > hi) return hi + (v - hi) * k;
    return v;
  }

  static Rect safeZone(Size screen, {required EdgeInsets pad, required double navH}) {
    final l = math.max(MiniGeom.safeInset, pad.left);
    final t = math.max(MiniGeom.safeInset, pad.top);
    final r = math.max(l, screen.width - math.max(MiniGeom.safeInset, pad.right));
    final b = math.max(t, screen.height - math.max(MiniGeom.safeInset, navH));
    return Rect.fromLTRB(l, t, r, b);
  }

  static Offset edgeTarget(Offset p, double w, double h, Rect safe) {
    final leftX = safe.left;
    final rightX = math.max(safe.left, safe.right - w);
    final goLeft = (p.dx + w / 2) < (safe.left + safe.right) / 2;
    final maxY = math.max(safe.top, safe.bottom - h);
    return Offset(goLeft ? leftX : rightX, p.dy.clamp(safe.top, maxY).toDouble());
  }

  static Offset defaultPos(Size screen, double w, double h, Rect safe) {
    return Offset(
      math.max(safe.left, safe.right - w),
      math.max(safe.top, safe.bottom - h),
    );
  }
}
