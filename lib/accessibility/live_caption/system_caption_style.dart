import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'package:video_player_app/native/android_bridge.dart';

class SystemCaptionStyle {
  const SystemCaptionStyle({
    this.fontScale = 1.0,
    this.foreground,
    this.background,
    this.window,
    this.edgeType = 0,
    this.edgeColor,
    this.bold = false,
    this.italic = false,
  });

  static const edgeNone = 0;
  static const edgeOutline = 1;
  static const edgeDropShadow = 2;
  static const edgeRaised = 3;
  static const edgeDepressed = 4;

  final double fontScale;
  final Color? foreground;
  final Color? background;
  final Color? window;
  final int edgeType;
  final Color? edgeColor;
  final bool bold;
  final bool italic;

  static Color? _color(Object? v) {
    if (v is! int) return null;
    final c = v & 0xFFFFFFFF;
    if (c == 0x00FFFFFE) return null;
    return Color(c);
  }

  factory SystemCaptionStyle.fromMap(Map<String, dynamic> m) {
    final edge = m['edgeType'];
    return SystemCaptionStyle(
      fontScale: ((m['fontScale'] as num?)?.toDouble() ?? 1.0).clamp(0.25, 2.0).toDouble(),
      foreground: _color(m['foreground']),
      background: _color(m['background']),
      window: _color(m['window']),
      edgeType: edge is int && edge >= 0 && edge <= 4 ? edge : edgeNone,
      edgeColor: _color(m['edgeColor']),
      bold: m['bold'] == true,
      italic: m['italic'] == true,
    );
  }

  static final ValueNotifier<SystemCaptionStyle> current = ValueNotifier(const SystemCaptionStyle());

  static Future<void> refresh() async {
    final m = await AndroidBridge.captionStyle();
    if (m.isEmpty) return;
    current.value = SystemCaptionStyle.fromMap(m);
  }
}
