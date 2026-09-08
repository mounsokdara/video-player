import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';

import 'settings.dart';

class AppTheme {
  static ThemeData build({
    required Brightness brightness,
    required AppSettings settings,
    ColorScheme? dynamicScheme,
  }) {
    final seed = settings.seed;
    ColorScheme scheme = settings.dynamicColor && dynamicScheme != null
        ? dynamicScheme.harmonized()
        : ColorScheme.fromSeed(seedColor: seed, brightness: brightness);

    if (settings.highContrast) {
      scheme = scheme.copyWith(
        outline: brightness == Brightness.dark ? Colors.white70 : Colors.black87,
        onSurface: brightness == Brightness.dark ? Colors.white : Colors.black,
      );
    }

    final radius = 16.0;
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      visualDensity: VisualDensity.standard,
      splashFactory: InkSparkle.splashFactory,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        scrolledUnderElevation: 0,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        titleTextStyle: TextStyle(
          fontSize: 22,
          fontWeight: settings.boldText ? FontWeight.w700 : FontWeight.w600,
          color: scheme.onSurface,
          letterSpacing: -0.3,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        elevation: 0,
        height: 72,
        indicatorColor: scheme.secondaryContainer,
        labelTextStyle: WidgetStateProperty.resolveWith((s) {
          final selected = s.contains(WidgetState.selected);
          return TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          );
        }),
      ),
      sliderTheme: SliderThemeData(
        trackHeight: 3,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        showDragHandle: true,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) {
          if (s.contains(WidgetState.selected)) return scheme.onPrimary;
          return scheme.outline;
        }),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: scheme.onSurfaceVariant,
        titleTextStyle: TextStyle(
          fontSize: 16,
          fontWeight: settings.boldText ? FontWeight.w600 : FontWeight.w500,
          color: scheme.onSurface,
        ),
        subtitleTextStyle: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        ),
      ),
      textTheme: brightness == Brightness.dark
          ? Typography.material2021(platform: TargetPlatform.android).white
          : Typography.material2021(platform: TargetPlatform.android).black,
    );
  }
}
