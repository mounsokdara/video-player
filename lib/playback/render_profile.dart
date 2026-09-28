import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:shared_preferences/shared_preferences.dart';

/// How the render frame-rate limiter picks its cap.
enum FpsMode { off, auto, fixed }

/// How the render resolution limiter picks its cap.
enum ResMode { autoVideo, autoScreen, fixed }

/// Brightness tuning for one colour mode.
/// [peak] is the nit level mpv treats as the screen's white (higher = darker),
/// [gamma] is a mid-tone shift from -100 to 100 (negative = darker).
class HdrTuning {
  const HdrTuning(this.peak, this.gamma);
  final int peak;
  final int gamma;
}

class ResPreset {
  const ResPreset(this.label, this.p);
  final String label;
  final int p;
}

/// User options for the render pipeline. Saved with SharedPreferences and
/// independent from the rest of the app settings.
class RenderSettings {
  RenderSettings._();
  static final RenderSettings instance = RenderSettings._();

  static const fpsPresets = <int>[1, 5, 10, 15, 24, 30, 45, 60, 90, 120];
  static const fpsMin = 1;
  static const fpsMax = 240;

  /// Shorter side of the frame: 1080 means 1920x1080 or 1080x1920.
  static const resPresets = <ResPreset>[
    ResPreset('Low', 240),
    ResPreset('360p', 360),
    ResPreset('480p', 480),
    ResPreset('720p', 720),
    ResPreset('1080p', 1080),
    ResPreset('1440p', 1440),
    ResPreset('4K', 2160),
    ResPreset('5K', 2880),
    ResPreset('8K', 4320),
    ResPreset('10K', 5760),
  ];
  static const resMin = 90;
  static const resMax = 8640;

  static const defaultPeakHdr = 400;
  static const defaultPeakSdr = 203;

  FpsMode fpsMode = FpsMode.off;
  int fpsValue = 30;
  ResMode resMode = ResMode.autoVideo;
  int resValue = 1080;

  /// Open HDR videos in SDR mode without asking.
  bool autoSdr = false;

  /// For HDR / >8-bit videos (software decode): drop late frames and skip the
  /// loop filter on non-reference frames. Applies to the next video.
  bool fastDecode = true;

  int peakHdr = defaultPeakHdr;
  int gammaHdr = 0;
  int peakSdr = defaultPeakSdr;
  int gammaSdr = 0;

  bool _loaded = false;

  HdrTuning tuning({required bool sdr}) =>
      sdr ? HdrTuning(peakSdr, gammaSdr) : HdrTuning(peakHdr, gammaHdr);

  void setTuning({required bool sdr, int? peak, int? gamma}) {
    if (sdr) {
      if (peak != null) peakSdr = peak.clamp(50, 2000);
      if (gamma != null) gammaSdr = gamma.clamp(-100, 100);
    } else {
      if (peak != null) peakHdr = peak.clamp(50, 2000);
      if (gamma != null) gammaHdr = gamma.clamp(-100, 100);
    }
  }

  void resetTuning({required bool sdr}) {
    if (sdr) {
      peakSdr = defaultPeakSdr;
      gammaSdr = 0;
    } else {
      peakHdr = defaultPeakHdr;
      gammaHdr = 0;
    }
  }

  void resetLimits() {
    fpsMode = FpsMode.off;
    fpsValue = 30;
    resMode = ResMode.autoVideo;
    resValue = 1080;
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      fpsMode = FpsMode.values[(p.getInt('rs_fpsMode') ?? 0).clamp(0, FpsMode.values.length - 1)];
      fpsValue = (p.getInt('rs_fpsValue') ?? 30).clamp(fpsMin, fpsMax);
      resMode = ResMode.values[(p.getInt('rs_resMode') ?? 0).clamp(0, ResMode.values.length - 1)];
      resValue = (p.getInt('rs_resValue') ?? 1080).clamp(resMin, resMax);
      autoSdr = p.getBool('rs_autoSdr') ?? false;
      fastDecode = p.getBool('rs_fastDecode') ?? true;
      // 'hdrPeak' / 'hdrGamma' are the keys of the first tuning sheet.
      peakHdr = (p.getInt('rs_peakHdr') ?? p.getInt('hdrPeak') ?? defaultPeakHdr).clamp(50, 2000);
      gammaHdr = (p.getInt('rs_gammaHdr') ?? p.getInt('hdrGamma') ?? 0).clamp(-100, 100);
      peakSdr = (p.getInt('rs_peakSdr') ?? defaultPeakSdr).clamp(50, 2000);
      gammaSdr = (p.getInt('rs_gammaSdr') ?? 0).clamp(-100, 100);
    } catch (_) {}
  }

  Future<void> save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt('rs_fpsMode', fpsMode.index);
      await p.setInt('rs_fpsValue', fpsValue);
      await p.setInt('rs_resMode', resMode.index);
      await p.setInt('rs_resValue', resValue);
      await p.setBool('rs_autoSdr', autoSdr);
      await p.setBool('rs_fastDecode', fastDecode);
      await p.setInt('rs_peakHdr', peakHdr);
      await p.setInt('rs_gammaHdr', gammaHdr);
      await p.setInt('rs_peakSdr', peakSdr);
      await p.setInt('rs_gammaSdr', gammaSdr);
    } catch (_) {}
  }
}

/// What mpv reports about the decoded video, before any filter.
class SourceInfo {
  const SourceInfo({
    required this.pix,
    required this.gamma,
    required this.primaries,
    required this.matrix,
    required this.sigPeak,
    required this.w,
    required this.h,
    required this.fps,
  });

  final String pix;
  final String gamma;
  final String primaries;
  final String matrix;
  final String sigPeak;
  final int w;
  final int h;
  final double fps;

  /// False while mpv has not produced a single decoded frame format.
  bool get decoded => pix.isNotEmpty;

  /// PQ / HLG transfer, or wide-gamut BT.2020 with a high signal peak.
  bool get hdr {
    if (gamma.contains('hlg') ||
        gamma.contains('pq') ||
        gamma.contains('st2084') ||
        gamma.contains('smpte2084') ||
        gamma.contains('bt.2100')) {
      return true;
    }
    if (primaries.contains('2020')) {
      final peak = double.tryParse(sigPeak);
      if (peak != null && peak > 1.1) return true;
      if (deep) return true;
    }
    return matrix.contains('2020');
  }

  /// More than 8 bits per channel (yuv420p10, p010, ...).
  bool get deep => RegExp(r'p0(10|12|16)|p(10|12|14|16)(le|be)?$').hasMatch(pix);

  /// HDR and >8-bit frames need the safe path: software decode, 8-bit frames.
  bool get needsConvert => hdr || deep;

  String describe() =>
      'pix=$pix gamma=$gamma prim=$primaries matrix=$matrix peak=$sigPeak size=${w}x$h fps=${fps.toStringAsFixed(2)} hdr=$hdr deep=$deep';
}

class ScreenInfo {
  const ScreenInfo(this.width, this.height, this.hz);
  final double width;
  final double height;
  final double hz;

  static ScreenInfo current() {
    try {
      final view = ui.PlatformDispatcher.instance.views.first;
      final size = view.physicalSize;
      final hz = view.display.refreshRate;
      return ScreenInfo(size.width, size.height, hz >= 1 ? hz : 60);
    } catch (_) {
      return const ScreenInfo(0, 0, 60);
    }
  }
}

/// Which optional mpv filters this libmpv build really has. Filled in by the
/// engine the first time it tries each one. null = not tried yet.
class RenderCaps {
  const RenderCaps._();
  static bool? fps;
  static bool? scale;

  static bool? of(String token) => token == 'fps' ? fps : (token == 'scale' ? scale : null);

  static void set(String token, bool value) {
    if (token == 'fps') fps = value;
    if (token == 'scale') scale = value;
  }
}

/// One optional filter (frame-rate or resolution limiter).
class RenderExtra {
  const RenderExtra(this.token, this.filter);

  /// Name that must show up when the chain is read back from mpv.
  final String token;

  /// The mpv `vf` entry.
  final String filter;
}

/// The mpv filter chain for one video.
class RenderPlan {
  const RenderPlan({
    required this.baseline,
    required this.extras,
    this.fpsCap,
    this.outW,
    this.outH,
  });

  /// Known-good chain: only the 8-bit conversion for HDR/deep sources.
  final String baseline;

  /// Limiters, in the order they should run.
  final List<RenderExtra> extras;

  final int? fpsCap;
  final int? outW;
  final int? outH;

  /// The full intended chain, used to skip work when nothing changed.
  String get key => [...extras.map((e) => e.filter), if (baseline.isNotEmpty) baseline].join(',');

  String describe(SourceInfo src) {
    final size = outW != null ? '${src.w}x${src.h}->${outW}x$outH' : '${src.w}x${src.h}';
    final fps = fpsCap != null ? '${src.fps.toStringAsFixed(0)}->${fpsCap}fps' : '${src.fps.toStringAsFixed(0)}fps';
    return '$size $fps vf=${key.isEmpty ? '-' : key}';
  }
}

/// Turns settings + source + screen into a [RenderPlan]. Pure, no side effects.
class RenderProfile {
  const RenderProfile._();

  static RenderPlan plan({
    required RenderSettings settings,
    required SourceInfo src,
    required ScreenInfo screen,
  }) {
    final extras = <RenderExtra>[];

    // Frame rate: only ever drops frames, never invents them.
    int? want;
    switch (settings.fpsMode) {
      case FpsMode.off:
        break;
      case FpsMode.auto:
        want = screen.hz.round();
      case FpsMode.fixed:
        want = settings.fpsValue;
    }
    int? fpsCap;
    if (want != null && want >= 1 && src.fps > want + 0.5 && RenderCaps.fps != false) {
      fpsCap = want;
      extras.add(RenderExtra('fps', 'lavfi=[fps=$want]'));
    }

    // Resolution: the limit applies to the shorter side and never upscales.
    int? limit;
    switch (settings.resMode) {
      case ResMode.autoVideo:
        break;
      case ResMode.autoScreen:
        limit = _screenLimit(src, screen);
      case ResMode.fixed:
        limit = settings.resValue;
    }
    int? outW;
    int? outH;
    if (limit != null && src.w > 0 && src.h > 0 && RenderCaps.scale != false) {
      final short = math.min(src.w, src.h);
      if (limit < short) {
        final f = limit / short;
        outW = _even(src.w * f);
        outH = _even(src.h * f);
        extras.add(RenderExtra('scale', 'lavfi=[scale=w=$outW:h=$outH]'));
      }
    }

    return RenderPlan(
      baseline: src.needsConvert ? 'format=yuv420p' : '',
      extras: extras,
      fpsCap: fpsCap,
      outW: outW,
      outH: outH,
    );
  }

  /// Largest shorter-side that still fits the video inside the screen.
  static int? _screenLimit(SourceInfo src, ScreenInfo screen) {
    if (screen.width <= 0 || screen.height <= 0 || src.w <= 0 || src.h <= 0) return null;
    final longSide = math.max(screen.width, screen.height);
    final shortSide = math.min(screen.width, screen.height);
    final landscape = src.w >= src.h;
    final fitW = landscape ? longSide : shortSide;
    final fitH = landscape ? shortSide : longSide;
    final f = math.min(fitW / src.w, fitH / src.h);
    if (f >= 1) return null;
    return math.max(2, (math.min(src.w, src.h) * f).round());
  }

  static int _even(double v) {
    var n = v.round();
    if (n.isOdd) n -= 1;
    return math.max(2, n);
  }
}
