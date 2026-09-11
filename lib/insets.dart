import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'android_bridge.dart';

/// System bars (status + navigation + cutout) as layout padding.
/// Uses [MediaQuery.viewPadding] only — never gesture insets or IME viewInsets
/// for chrome. Matches Android edge-to-edge: draw behind bars, pad interactive UI.
/// https://developer.android.com/design/ui/mobile/guides/foundations/system-bars
class SystemBars {
  static int popupCount = 0;
  static bool alwaysHide = false;
  static Brightness iconBrightness = Brightness.light;

  static EdgeInsets of(BuildContext context) => MediaQuery.viewPaddingOf(context);

  /// Unconsumed window insets. Scaffold / NavigationBar / SafeArea call
  /// [MediaQuery.removePadding], which also zeroes [MediaQuery.viewPadding]
  /// for descendants — so a modal opened from the library would otherwise
  /// sit under the 3-button nav. [MediaQueryData.fromView] reads the view.
  static EdgeInsets rawOf(BuildContext context) {
    return MediaQueryData.fromView(View.of(context)).viewPadding;
  }

  static SystemUiOverlayStyle overlay({required Brightness icons, bool contrast = true}) {
    final status = icons;
    final bar = icons == Brightness.light ? Brightness.dark : Brightness.light;
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      statusBarIconBrightness: status,
      statusBarBrightness: bar,
      systemNavigationBarIconBrightness: status,
      systemNavigationBarContrastEnforced: contrast,
      systemStatusBarContrastEnforced: false,
    );
  }

  static void apply({required Brightness icons, bool contrast = true, bool forceShow = false, bool? hide}) {
    iconBrightness = icons;
    final shouldHide = hide ?? (alwaysHide && popupCount <= 0 && !forceShow);
    if (shouldHide) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setSystemUIOverlayStyle(overlay(icons: icons, contrast: contrast));
    }
    unawaited(AndroidBridge.applySystemBars(
      lightIcons: icons == Brightness.light,
      contrast: contrast,
      hide: shouldHide,
    ));
  }

  static Future<T?> modal<T>(Future<T?> Function() run) async {
    popupCount++;
    apply(icons: iconBrightness, forceShow: true);
    try {
      return await run();
    } finally {
      popupCount--;
      apply(icons: iconBrightness);
    }
  }
}
