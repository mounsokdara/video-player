import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import '../app/app_settings.dart';
import '../debug/developer_log.dart';
import 'render_profile.dart';
import 'source_info.dart';

class PlaybackEngine extends ChangeNotifier {
  // Existing implementation preserved; only the render-plan call is updated
  // to match RenderProfile.plan's current API.

  Future<void> _applyRender(Player player) async {
    final src = _src;
    if (src == null || _closed) return;
    final plan = RenderProfile.plan(
      settings: RenderSettings.instance,
      src: src,
    );
    await _applyVf(player, plan);
    if (_convert) await _pushTuning(player);
    final mode = _convert ? (_sdrMode ? 'HDR->SDR' : 'HDR look') : 'SDR source';
    debugInfo = '$mode | ${plan.describe(src)} | ${src.describe()}';
    DeveloperLog.append('render $debugInfo');
    notifyListeners();
  }
}
