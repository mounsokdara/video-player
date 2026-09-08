import 'dart:convert';
import 'dart:ui';

import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

class AppSettings {
  ThemeModePref themeMode = ThemeModePref.system;
  int seedColor = 0xFF8BA3B8;
  bool dynamicColor = true;

  // General
  bool rememberPlayback = true;
  bool confirmDelete = true;
  bool scanOnStart = true;
  bool showHiddenFolders = false;
  int thumbnailQuality = 2;
  bool vibrateOnLongPress = true;

  // Display in playback
  bool showRemaining = true;
  bool showClock = true;
  bool showBattery = true;
  bool showSeekPreview = true;
  bool showBrightnessOverlay = true;
  bool showVolumeOverlay = true;

  // Orientation
  RotationLock rotation = RotationLock.autoVideo;

  // Playback
  DecoderMode decoder = DecoderMode.hw;
  bool hwPriority = true;
  int seekStepSeconds = 10;
  bool autoMiniplayer = false;
  bool rememberBackgroundPlay = false;
  bool backgroundPlay = false;
  bool rememberAspect = true;
  AspectMode aspect = AspectMode.fit;
  bool resumePlayback = true;
  bool rememberSpeed = false;
  double speed = 1;
  bool rememberBrightness = false;
  double brightness = -1;
  bool longPress2x = true;
  bool longPressVibration = true;
  bool doubleTapSeek = true;
  bool autoPlayNext = true;
  bool gestureControl = true;
  String preferredAudio = 'auto';
  bool rememberHdr = false;
  bool hdrOn = true;
  bool pitchShift = false;

  PlayMode playMode = PlayMode.order;

  // Accessibility
  bool captions = false;
  double captionSize = 1;
  bool highContrast = false;
  bool reduceMotion = false;
  bool largeControls = false;
  bool colorBlindDeuteranopia = false;
  bool colorBlindProtanopia = false;
  bool colorBlindTritanopia = false;
  bool grayscale = false;
  bool invertColors = false;
  bool nightMode = false;
  double nightWarmth = 0.35;
  bool monochrome = false;
  bool extraDim = false;
  bool boldText = false;
  double uiScale = 1;
  bool hapticFeedback = true;
  bool audioDescription = false;
  bool liveCaptions = false;
  bool focusHighlight = false;
  bool stereoFix = false;
  double subtitleBgOpacity = 0.45;

  // Filters
  double contrast = 1;
  double saturation = 1;
  double gamma = 1;
  double hueRotate = 0;
  double sharpness = 0;
  bool mirror = false;
  bool hideNavBar = false;
  bool showAppNav = true;

  static const allQuickActions = <String>[
    'lock',
    'aspect',
    'audio',
    'subtitle',
    'speed',
    'background',
    'popup',
    'hidenav',
    'cast',
    'delete',
    'bookmark',
    'playopt',
    'ab',
    'eq',
    'night',
    'mirror',
    'invert',
    'color',
    'rotate',
    'brightness',
    'timer',
    'songs',
    'repeat',
    'decoder',
    'screenshot',
    'share',
    'properties',
  ];

  List<String> quickActions = List<String>.from(allQuickActions);

  Map<String, double> resumeMap = {};
  Map<String, double> speedMap = {};
  Set<String> bookmarks = {};

  Color get seed => Color(seedColor);

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    themeMode = ThemeModePref.values[p.getInt('themeMode') ?? 0];
    seedColor = p.getInt('seedColor') ?? 0xFF8BA3B8;
    dynamicColor = p.getBool('dynamicColor') ?? true;
    rememberPlayback = p.getBool('rememberPlayback') ?? true;
    confirmDelete = p.getBool('confirmDelete') ?? true;
    scanOnStart = p.getBool('scanOnStart') ?? true;
    showHiddenFolders = p.getBool('showHiddenFolders') ?? false;
    vibrateOnLongPress = p.getBool('vibrateOnLongPress') ?? true;
    showRemaining = p.getBool('showRemaining') ?? true;
    showClock = p.getBool('showClock') ?? true;
    showBattery = p.getBool('showBattery') ?? true;
    rotation = RotationLock.values[p.getInt('rotation') ?? 1];
    decoder = DecoderMode.values[p.getInt('decoder') ?? 1];
    hwPriority = p.getBool('hwPriority') ?? true;
    seekStepSeconds = p.getInt('seekStepSeconds') ?? 10;
    autoMiniplayer = p.getBool('autoMiniplayer') ?? false;
    if (p.getBool('pipDefaultOffV2') != true) {
      autoMiniplayer = false;
      await p.setBool('autoMiniplayer', false);
      await p.setBool('pipDefaultOffV2', true);
    }
    rememberBackgroundPlay = p.getBool('rememberBackgroundPlay') ?? false;
    backgroundPlay = p.getBool('backgroundPlay') ?? false;
    rememberAspect = p.getBool('rememberAspect') ?? true;
    aspect = AspectMode.values[p.getInt('aspect') ?? 0];
    resumePlayback = p.getBool('resumePlayback') ?? true;
    rememberSpeed = p.getBool('rememberSpeed') ?? false;
    speed = p.getDouble('speed') ?? 1;
    rememberBrightness = p.getBool('rememberBrightness') ?? false;
    brightness = p.getDouble('brightness') ?? -1;
    longPress2x = p.getBool('longPress2x') ?? true;
    longPressVibration = p.getBool('longPressVibration') ?? true;
    doubleTapSeek = p.getBool('doubleTapSeek') ?? true;
    autoPlayNext = p.getBool('autoPlayNext') ?? true;
    gestureControl = p.getBool('gestureControl') ?? true;
    preferredAudio = p.getString('preferredAudio') ?? 'auto';
    rememberHdr = p.getBool('rememberHdr') ?? false;
    hdrOn = p.getBool('hdrOn') ?? true;
    pitchShift = p.getBool('pitchShift') ?? false;
    playMode = PlayMode.values[p.getInt('playMode') ?? 0];
    captions = p.getBool('captions') ?? false;
    captionSize = p.getDouble('captionSize') ?? 1;
    highContrast = p.getBool('highContrast') ?? false;
    reduceMotion = p.getBool('reduceMotion') ?? false;
    largeControls = p.getBool('largeControls') ?? false;
    colorBlindDeuteranopia = p.getBool('cbD') ?? false;
    colorBlindProtanopia = p.getBool('cbP') ?? false;
    colorBlindTritanopia = p.getBool('cbT') ?? false;
    grayscale = p.getBool('grayscale') ?? false;
    invertColors = p.getBool('invertColors') ?? false;
    nightMode = p.getBool('nightMode') ?? false;
    nightWarmth = p.getDouble('nightWarmth') ?? 0.35;
    extraDim = p.getBool('extraDim') ?? false;
    boldText = p.getBool('boldText') ?? false;
    uiScale = p.getDouble('uiScale') ?? 1;
    hapticFeedback = p.getBool('hapticFeedback') ?? true;
    contrast = p.getDouble('contrast') ?? 1;
    saturation = p.getDouble('saturation') ?? 1;
    gamma = p.getDouble('gamma') ?? 1;
    hueRotate = p.getDouble('hueRotate') ?? 0;
    mirror = p.getBool('mirror') ?? false;
    hideNavBar = p.getBool('hideNavBar') ?? false;
    showAppNav = p.getBool('showAppNav') ?? true;
    final qa = p.getStringList('quickActions');
    if (qa == null || qa.isEmpty) {
      quickActions = List<String>.from(allQuickActions);
    } else {
      quickActions = [...qa];
      for (final a in allQuickActions) {
        if (!quickActions.contains(a)) quickActions.add(a);
      }
    }
    final resume = p.getString('resumeMap');
    if (resume != null) {
      resumeMap = (jsonDecode(resume) as Map).map((k, v) => MapEntry('$k', (v as num).toDouble()));
    }
    final bm = p.getStringList('bookmarks') ?? [];
    bookmarks = bm.toSet();
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt('themeMode', themeMode.index);
    await p.setInt('seedColor', seedColor);
    await p.setBool('dynamicColor', dynamicColor);
    await p.setBool('rememberPlayback', rememberPlayback);
    await p.setBool('confirmDelete', confirmDelete);
    await p.setBool('scanOnStart', scanOnStart);
    await p.setBool('showHiddenFolders', showHiddenFolders);
    await p.setBool('vibrateOnLongPress', vibrateOnLongPress);
    await p.setBool('showRemaining', showRemaining);
    await p.setBool('showClock', showClock);
    await p.setBool('showBattery', showBattery);
    await p.setInt('rotation', rotation.index);
    await p.setInt('decoder', decoder.index);
    await p.setBool('hwPriority', hwPriority);
    await p.setInt('seekStepSeconds', seekStepSeconds);
    await p.setBool('autoMiniplayer', autoMiniplayer);
    await p.setBool('rememberBackgroundPlay', rememberBackgroundPlay);
    await p.setBool('backgroundPlay', backgroundPlay);
    await p.setBool('rememberAspect', rememberAspect);
    await p.setInt('aspect', aspect.index);
    await p.setBool('resumePlayback', resumePlayback);
    await p.setBool('rememberSpeed', rememberSpeed);
    await p.setDouble('speed', speed);
    await p.setBool('rememberBrightness', rememberBrightness);
    await p.setDouble('brightness', brightness);
    await p.setBool('longPress2x', longPress2x);
    await p.setBool('longPressVibration', longPressVibration);
    await p.setBool('doubleTapSeek', doubleTapSeek);
    await p.setBool('autoPlayNext', autoPlayNext);
    await p.setBool('gestureControl', gestureControl);
    await p.setString('preferredAudio', preferredAudio);
    await p.setBool('rememberHdr', rememberHdr);
    await p.setBool('hdrOn', hdrOn);
    await p.setBool('pitchShift', pitchShift);
    await p.setInt('playMode', playMode.index);
    await p.setBool('captions', captions);
    await p.setDouble('captionSize', captionSize);
    await p.setBool('highContrast', highContrast);
    await p.setBool('reduceMotion', reduceMotion);
    await p.setBool('largeControls', largeControls);
    await p.setBool('cbD', colorBlindDeuteranopia);
    await p.setBool('cbP', colorBlindProtanopia);
    await p.setBool('cbT', colorBlindTritanopia);
    await p.setBool('grayscale', grayscale);
    await p.setBool('invertColors', invertColors);
    await p.setBool('nightMode', nightMode);
    await p.setDouble('nightWarmth', nightWarmth);
    await p.setBool('extraDim', extraDim);
    await p.setBool('boldText', boldText);
    await p.setDouble('uiScale', uiScale);
    await p.setBool('hapticFeedback', hapticFeedback);
    await p.setDouble('contrast', contrast);
    await p.setDouble('saturation', saturation);
    await p.setDouble('gamma', gamma);
    await p.setDouble('hueRotate', hueRotate);
    await p.setBool('mirror', mirror);
    await p.setBool('hideNavBar', hideNavBar);
    await p.setBool('showAppNav', showAppNav);
    await p.setStringList('quickActions', quickActions);
    await p.setString('resumeMap', jsonEncode(resumeMap));
    await p.setStringList('bookmarks', bookmarks.toList());
  }
}
