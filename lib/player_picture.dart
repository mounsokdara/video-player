import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'models.dart';
import 'settings.dart';

class PictureLooks {
  const PictureLooks({
    required this.mirror,
    required this.invert,
    required this.grayscale,
    required this.colorCorrection,
    required this.contrast,
    required this.saturation,
    required this.deuteranopia,
    required this.protanopia,
    required this.tritanopia,
    required this.night,
    required this.nightWarmth,
    required this.extraDim,
  });

  final bool mirror;
  final bool invert;
  final bool grayscale;
  final bool colorCorrection;
  final double contrast;
  final double saturation;
  final bool deuteranopia;
  final bool protanopia;
  final bool tritanopia;
  final bool night;
  final double nightWarmth;
  final bool extraDim;

  factory PictureLooks.current({
    bool? invert,
    bool? mirror,
    bool? night,
  }) {
    final s = appSettings;
    return PictureLooks(
      mirror: mirror ?? s.mirror,
      invert: invert ?? s.invertColors,
      grayscale: s.grayscale || s.monochrome,
      colorCorrection: s.colorCorrection,
      contrast: s.contrast,
      saturation: s.saturation,
      deuteranopia: s.colorBlindDeuteranopia,
      protanopia: s.colorBlindProtanopia,
      tritanopia: s.colorBlindTritanopia,
      night: night ?? s.nightMode,
      nightWarmth: s.nightWarmth,
      extraDim: s.extraDim,
    );
  }
}

class PictureMatrices {
  PictureMatrices._();

  static const invert = <double>[
    -1, 0, 0, 0, 255,
    0, -1, 0, 0, 255,
    0, 0, -1, 0, 255,
    0, 0, 0, 1, 0,
  ];
  static const gray = <double>[
    0.2126, 0.7152, 0.0722, 0, 0,
    0.2126, 0.7152, 0.0722, 0, 0,
    0.2126, 0.7152, 0.0722, 0, 0,
    0, 0, 0, 1, 0,
  ];
  static const deut = <double>[
    0.625, 0.375, 0, 0, 0,
    0.7, 0.3, 0, 0, 0,
    0, 0.3, 0.7, 0, 0,
    0, 0, 0, 1, 0,
  ];
  static const prot = <double>[
    0.567, 0.433, 0, 0, 0,
    0.558, 0.442, 0, 0, 0,
    0, 0.242, 0.758, 0, 0,
    0, 0, 0, 1, 0,
  ];
  static const trit = <double>[
    0.95, 0.05, 0, 0, 0,
    0, 0.433, 0.567, 0, 0,
    0, 0.475, 0.525, 0, 0,
    0, 0, 0, 1, 0,
  ];

  static List<double> contrastSaturation(double c, double s) {
    const lumR = 0.2126, lumG = 0.7152, lumB = 0.0722;
    final sr = (1 - s) * lumR;
    final sg = (1 - s) * lumG;
    final sb = (1 - s) * lumB;
    final t = (1 - c) / 2 * 255;
    return [
      c * (sr + s), c * sg, c * sb, 0, t,
      c * sr, c * (sg + s), c * sb, 0, t,
      c * sr, c * sg, c * (sb + s), 0, t,
      0, 0, 0, 1, 0,
    ];
  }
}

class VideoPicture extends StatelessWidget {
  const VideoPicture({
    super.key,
    required this.child,
    required this.looks,
  });

  final Widget child;
  final PictureLooks looks;

  @override
  Widget build(BuildContext context) {
    Widget player = child;
    if (looks.mirror) {
      player = Transform.flip(flipX: true, child: player);
    }
    final filters = <ColorFilter>[];
    if (looks.invert) {
      filters.add(const ColorFilter.matrix(PictureMatrices.invert));
    }
    if (looks.grayscale) {
      filters.add(const ColorFilter.matrix(PictureMatrices.gray));
    }
    if (looks.colorCorrection && (looks.contrast != 1 || looks.saturation != 1)) {
      filters.add(ColorFilter.matrix(
          PictureMatrices.contrastSaturation(looks.contrast, looks.saturation)));
    }
    if (looks.deuteranopia) {
      filters.add(const ColorFilter.matrix(PictureMatrices.deut));
    }
    if (looks.protanopia) {
      filters.add(const ColorFilter.matrix(PictureMatrices.prot));
    }
    if (looks.tritanopia) {
      filters.add(const ColorFilter.matrix(PictureMatrices.trit));
    }
    for (final f in filters) {
      player = ColorFiltered(colorFilter: f, child: player);
    }
    if (looks.night) {
      player = ColorFiltered(
        colorFilter: ColorFilter.mode(
          Color.fromARGB((80 + looks.nightWarmth * 80).round(), 255, 140, 40),
          BlendMode.multiply,
        ),
        child: player,
      );
    }
    if (looks.extraDim) {
      player = ColorFiltered(
        colorFilter: ColorFilter.mode(Colors.black.withValues(alpha: 0.35), BlendMode.darken),
        child: player,
      );
    }
    return player;
  }
}

class VideoPad {
  const VideoPad({
    required this.visW,
    required this.visH,
    required this.codedW,
    required this.codedH,
    this.sarNum = 1,
    this.sarDen = 1,
    this.cropL = 0,
    this.cropT = 0,
  });

  final double visW;
  final double visH;
  final double codedW;
  final double codedH;
  final double sarNum;
  final double sarDen;
  final double cropL;
  final double cropT;

  static const none = VideoPad(visW: 0, visH: 0, codedW: 0, codedH: 0);

  bool get hasPad => codedW > visW + 0.5 || codedH > visH + 0.5;

  static double _align16(double v) {
    if (v <= 1) return v;
    return ((v + 15) ~/ 16) * 16.0;
  }

  factory VideoPad.resolve({required Size size, Map<String, dynamic>? native}) {
    var visW = size.width;
    var visH = size.height;
    var codedW = visW;
    var codedH = visH;
    var sarNum = 1.0;
    var sarDen = 1.0;
    var cropL = 0.0;
    var cropT = 0.0;
    final n = native;
    if (n != null) {
      final nVisW = (n['visW'] as num?)?.toDouble() ?? 0;
      final nVisH = (n['visH'] as num?)?.toDouble() ?? 0;
      final nCodedW = (n['codedW'] as num?)?.toDouble() ?? 0;
      final nCodedH = (n['codedH'] as num?)?.toDouble() ?? 0;
      if (visW < 2 && nVisW >= 2) visW = nVisW;
      if (visH < 2 && nVisH >= 2) visH = nVisH;
      if (nCodedW > codedW) codedW = nCodedW;
      if (nCodedH > codedH) codedH = nCodedH;
      final sn = (n['sarNum'] as num?)?.toDouble();
      final sd = (n['sarDen'] as num?)?.toDouble();
      if (sn != null && sd != null && sn > 0 && sd > 0) {
        sarNum = sn;
        sarDen = sd;
      }
      cropL = (n['cropL'] as num?)?.toDouble() ?? 0;
      cropT = (n['cropT'] as num?)?.toDouble() ?? 0;
      if (cropL < 0) cropL = 0;
      if (cropT < 0) cropT = 0;
    }
    if (visW < 2) visW = 1;
    if (visH < 2) visH = 1;
    if (codedW < visW) codedW = visW;
    if (codedH < visH) codedH = visH;
    if (codedW <= visW && visW > 1 && visW % 16 != 0) {
      codedW = _align16(visW);
    }
    if (codedH <= visH && visH > 1 && visH % 16 != 0) {
      codedH = _align16(visH);
    }
    if (cropL > codedW - visW) cropL = math.max(0, codedW - visW);
    if (cropT > codedH - visH) cropT = math.max(0, codedH - visH);
    return VideoPad(
      visW: visW,
      visH: visH,
      codedW: codedW,
      codedH: codedH,
      sarNum: sarNum,
      sarDen: sarDen,
      cropL: cropL,
      cropT: cropT,
    );
  }
}

class VlcSurface extends StatelessWidget {
  const VlcSurface({
    super.key,
    required this.pad,
    required this.screen,
    required this.mode,
    required this.child,
  });

  final VideoPad pad;
  final Size screen;
  final AspectMode mode;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final sw = screen.width;
    final sh = screen.height;
    if (sw < 2 || sh < 2) return ClipRect(child: child);
    final visW = math.max(pad.visW, 1.0);
    final visH = math.max(pad.visH, 1.0);
    final codedW = math.max(pad.codedW, visW);
    final codedH = math.max(pad.codedH, visH);
    var dw = sw;
    var dh = sh;
    var vw = visW;
    if (pad.sarDen != 0 && pad.sarNum != pad.sarDen) {
      vw = visW * pad.sarNum / pad.sarDen;
    }
    var ar = vw / visH;
    final dar = dw / dh;
    switch (mode) {
      case AspectMode.fit:
        if (dar < ar) {
          dh = dw / ar;
        } else {
          dw = dh * ar;
        }
      case AspectMode.zoom:
        if (dar >= ar) {
          dh = dw / ar;
        } else {
          dw = dh * ar;
        }
      case AspectMode.stretch:
        break;
      case AspectMode.original:
        dh = visH;
        dw = vw;
      case AspectMode.ratio16_9:
        ar = 16 / 9;
        if (dar < ar) {
          dh = dw / ar;
        } else {
          dw = dh * ar;
        }
      case AspectMode.ratio4_3:
        ar = 4 / 3;
        if (dar < ar) {
          dh = dw / ar;
        } else {
          dw = dh * ar;
        }
      case AspectMode.ratio21_9:
        ar = 21 / 9;
        if (dar < ar) {
          dh = dw / ar;
        } else {
          dw = dh * ar;
        }
      case AspectMode.ratio2_35:
        ar = 2.35;
        if (dar < ar) {
          dh = dw / ar;
        } else {
          dw = dh * ar;
        }
      case AspectMode.ratio1_1:
        ar = 1;
        if (dar < ar) {
          dh = dw / ar;
        } else {
          dw = dh * ar;
        }
      case AspectMode.ratio9_16:
        ar = 9 / 16;
        if (dar < ar) {
          dh = dw / ar;
        } else {
          dw = dh * ar;
        }
    }
    final surfaceW = dw * codedW / visW;
    final surfaceH = dh * codedH / visH;
    final shiftX = dw * pad.cropL / visW;
    final shiftY = dh * pad.cropT / visH;
    Widget painted = child;
    if (shiftX > 0.5 || shiftY > 0.5) {
      painted = Transform.translate(offset: Offset(-shiftX, -shiftY), child: painted);
    }
    Widget video;
    if (codedW > visW + 0.5 || codedH > visH + 0.5) {
      video = SizedBox(
        width: dw,
        height: dh,
        child: ClipRect(
          clipBehavior: Clip.hardEdge,
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: surfaceW,
            maxWidth: surfaceW,
            minHeight: surfaceH,
            maxHeight: surfaceH,
            child: SizedBox(width: surfaceW, height: surfaceH, child: painted),
          ),
        ),
      );
    } else {
      video = SizedBox(width: dw, height: dh, child: painted);
    }
    return ClipRect(
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: sw,
        height: sh,
        child: Center(child: video),
      ),
    );
  }
}

class DecoderPadClip extends StatelessWidget {
  const DecoderPadClip({
    super.key,
    required this.pad,
    required this.child,
  });

  final VideoPad pad;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final visW = math.max(pad.visW, 1.0);
    final visH = math.max(pad.visH, 1.0);
    final codedW = math.max(pad.codedW, visW);
    final codedH = math.max(pad.codedH, visH);
    if (codedW <= visW + 0.5 && codedH <= visH + 0.5) {
      return child;
    }
    Widget painted = child;
    if (pad.cropL > 0.5 || pad.cropT > 0.5) {
      painted = Transform.translate(offset: Offset(-pad.cropL, -pad.cropT), child: painted);
    }
    return ClipRect(
      clipBehavior: Clip.hardEdge,
      child: OverflowBox(
        alignment: Alignment.topLeft,
        minWidth: codedW,
        maxWidth: codedW,
        minHeight: codedH,
        maxHeight: codedH,
        child: SizedBox(width: codedW, height: codedH, child: painted),
      ),
    );
  }
}
