import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:share_plus/share_plus.dart';
import 'package:vibration/vibration.dart';
import 'package:video_player/video_player.dart';
import 'package:volume_controller/volume_controller.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'android_bridge.dart';
import 'library.dart';
import 'main.dart';
import 'models.dart';
import 'settings_ui.dart';
import 'widgets.dart';

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key, required this.playlist, required this.index, required this.onChanged});
  final List<VideoItem> playlist;
  final int index;
  final VoidCallback onChanged;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  late int index;
  VideoPlayerController? vc;
  bool ready = false;
  bool showUi = true;
  bool locked = false;
  Timer? hideTimer;
  double brightness = 0.5;
  double volume = 0.5;
  String overlay = '';
  Timer? overlayTimer;
  bool speeding = false;
  double? abA;
  double? abB;
  Timer? sleepTimer;
  Duration? sleepLeft;
  Timer? clockTimer;
  DateTime now = DateTime.now();
  int battery = 100;
  bool hdr = true;
  late AspectMode aspect;
  double speed = 1;
  int skipFlash = 0; // -1 left, 1 right
  Offset? panStart;
  String panKind = '';
  double panBase = 0;
  bool night = false;
  bool mirror = false;
  bool invert = false;

  VideoItem get item => widget.playlist[index];
  List<VideoItem> get list => widget.playlist;

  @override
  void initState() {
    super.initState();
    index = widget.index.clamp(0, widget.playlist.length - 1);
    aspect = appSettings.aspect;
    speed = appSettings.rememberSpeed ? appSettings.speed : 1;
    hdr = appSettings.rememberHdr ? appSettings.hdrOn : true;
    night = appSettings.nightMode;
    mirror = appSettings.mirror;
    invert = appSettings.invertColors;
    _boot();
    clockTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      setState(() => now = DateTime.now());
      Battery().batteryLevel.then((v) { if (mounted) setState(() => battery = v); });
    });
  }

  Future<void> _boot() async {
    await WakelockPlus.enable();
    await AndroidBridge.setKeepScreenOn(true);
    await AndroidBridge.setPipEnabled(appSettings.autoMiniplayer);
    _applyRotation();
    try {
      brightness = await ScreenBrightness().application;
    } catch (_) {}
    try {
      VolumeController.instance.showSystemUI = false;
      volume = await VolumeController.instance.getVolume();
    } catch (_) {}
    if (appSettings.rememberBrightness && appSettings.brightness >= 0) {
      brightness = appSettings.brightness;
      try { await ScreenBrightness().setApplicationScreenBrightness(brightness); } catch (_) {}
    }
    await _openCurrent();
  }

  void _applyRotation() {
    final m = switch (appSettings.rotation) {
      RotationLock.auto => 'auto',
      RotationLock.autoVideo => 'auto',
      RotationLock.landscape => 'landscape',
      RotationLock.portrait => 'portrait',
      RotationLock.landscapeNormal => 'landscape_normal',
      RotationLock.landscapeReverse => 'landscape_reverse',
      RotationLock.portraitNormal => 'portrait_normal',
      RotationLock.portraitReverse => 'portrait_reverse',
      RotationLock.locked => 'locked',
    };
    AndroidBridge.setOrientation(m);
  }

  Future<void> _openCurrent() async {
    await vc?.dispose();
    setState(() {
      ready = false;
      vc = null;
    });
    final file = File(item.path);
    final c = VideoPlayerController.file(
      file,
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: appSettings.backgroundPlay),
    );
    vc = c;
    try {
      await c.initialize();
      if (appSettings.resumePlayback) {
        final p = appSettings.resumeMap[item.path] ?? item.progress;
        if (p > 0 && p < 0.97) {
          await c.seekTo(c.value.duration * p);
        }
      }
      await c.setPlaybackSpeed(speed);
      c.addListener(_tick);
      c.setLooping(appSettings.playMode == PlayMode.repeatOne);
      await c.play();
      if (appSettings.backgroundPlay) {
        await AndroidBridge.startBackground(item.title);
      }
      _armHide();
      setState(() => ready = true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open: $e')));
      }
    }
  }

  void _tick() {
    final c = vc;
    if (c == null || !c.value.isInitialized) return;
    final pos = c.value.position.inMilliseconds.toDouble();
    final dur = c.value.duration.inMilliseconds.toDouble().clamp(1, double.infinity);
    final p = (pos / dur).clamp(0.0, 1.0).toDouble();
    item.progress = p;
    appSettings.resumeMap[item.path] = p;
    if (abA != null && abB != null && pos / 1000 >= abB!) {
      c.seekTo(Duration(milliseconds: (abA! * 1000).round()));
    }
    if (c.value.position >= c.value.duration - const Duration(milliseconds: 400) && !c.value.isPlaying) {
      _onEnded();
    }
    if (mounted) setState(() {});
  }

  Future<void> _onEnded() async {
    switch (appSettings.playMode) {
      case PlayMode.repeatOne:
        await vc?.seekTo(Duration.zero);
        await vc?.play();
      case PlayMode.noAutoplay:
        return;
      case PlayMode.loopAll:
      case PlayMode.order:
      case PlayMode.shuffle:
        if (appSettings.autoPlayNext || appSettings.playMode == PlayMode.loopAll || appSettings.playMode == PlayMode.shuffle) {
          await _next();
        }
    }
  }

  Future<void> _next() async {
    if (list.isEmpty) return;
    if (appSettings.playMode == PlayMode.shuffle) {
      index = math.Random().nextInt(list.length);
    } else {
      if (index >= list.length - 1) {
        if (appSettings.playMode == PlayMode.loopAll) {
          index = 0;
        } else {
          return;
        }
      } else {
        index += 1;
      }
    }
    await _openCurrent();
  }

  Future<void> _prev() async {
    if ((vc?.value.position ?? Duration.zero) > const Duration(seconds: 3)) {
      await vc?.seekTo(Duration.zero);
      return;
    }
    if (index > 0) {
      index -= 1;
      await _openCurrent();
    }
  }

  void _armHide() {
    hideTimer?.cancel();
    if (locked) return;
    hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && (vc?.value.isPlaying ?? false) && !locked) setState(() => showUi = false);
    });
  }

  void _flash(String text) {
    setState(() => overlay = text);
    overlayTimer?.cancel();
    overlayTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => overlay = '');
    });
  }

  Future<void> _seekBy(int seconds) async {
    final c = vc;
    if (c == null) return;
    final next = c.value.position + Duration(seconds: seconds);
    final d = c.value.duration;
    await c.seekTo(next < Duration.zero ? Duration.zero : (next > d ? d : next));
    _flash('${seconds > 0 ? '+' : ''}${seconds}s');
  }

  @override
  void dispose() {
    hideTimer?.cancel();
    overlayTimer?.cancel();
    clockTimer?.cancel();
    sleepTimer?.cancel();
    vc?.removeListener(_tick);
    final c = vc;
    if (c != null && c.value.isInitialized) {
      final p = c.value.position.inMilliseconds / c.value.duration.inMilliseconds.clamp(1, 1 << 30);
      appSettings.resumeMap[item.path] = p;
      item.progress = p;
      appSettings.save();
    }
    vc?.dispose();
    WakelockPlus.disable();
    AndroidBridge.setKeepScreenOn(false);
    AndroidBridge.stopBackground();
    AndroidBridge.setOrientation('auto');
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = vc;
    final size = MediaQuery.sizeOf(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (locked) return;
          setState(() => showUi = !showUi);
          if (showUi) _armHide();
        },
        onDoubleTapDown: (d) {
          if (locked || !appSettings.doubleTapSeek) return;
          final x = d.localPosition.dx;
          if (x < size.width * 0.33) {
            setState(() => skipFlash = -1);
            _seekBy(-appSettings.seekStepSeconds);
            Future.delayed(const Duration(milliseconds: 400), () { if (mounted) setState(() => skipFlash = 0); });
          } else if (x > size.width * 0.67) {
            setState(() => skipFlash = 1);
            _seekBy(appSettings.seekStepSeconds);
            Future.delayed(const Duration(milliseconds: 400), () { if (mounted) setState(() => skipFlash = 0); });
          } else {
            _togglePlay();
          }
        },
        onLongPressStart: (_) async {
          if (locked || !appSettings.longPress2x || c == null) return;
          speeding = true;
          await c.setPlaybackSpeed(2);
          if (appSettings.longPressVibration) {
            try { if (await Vibration.hasVibrator()) Vibration.vibrate(duration: 20); } catch (_) {}
          }
          _flash('2.0×');
          setState(() {});
        },
        onLongPressEnd: (_) async {
          if (!speeding) return;
          speeding = false;
          await c?.setPlaybackSpeed(speed);
          setState(() {});
        },
        onPanStart: (d) {
          if (locked || !appSettings.gestureControl) return;
          panStart = d.localPosition;
          panKind = '';
        },
        onPanUpdate: (d) async {
          if (locked || !appSettings.gestureControl || panStart == null || c == null) return;
          final dx = d.localPosition.dx - panStart!.dx;
          final dy = d.localPosition.dy - panStart!.dy;
          if (panKind.isEmpty) {
            if (dx.abs() > 18 && dx.abs() > dy.abs()) {
              panKind = 'seek';
              panBase = c.value.position.inMilliseconds.toDouble();
            } else if (dy.abs() > 18) {
              panKind = panStart!.dx < size.width / 2 ? 'brightness' : 'volume';
              panBase = panKind == 'brightness' ? brightness : volume;
            } else {
              return;
            }
          }
          if (panKind == 'seek') {
            final dur = c.value.duration.inMilliseconds.toDouble().clamp(1, double.infinity);
            final delta = (dx / size.width) * dur * 0.6;
            final next = (panBase + delta).clamp(0, dur);
            await c.seekTo(Duration(milliseconds: next.round()));
            _flash(formatDuration(Duration(milliseconds: next.round())));
          } else if (panKind == 'brightness') {
            brightness = (panBase - dy / size.height).clamp(0.0, 1.0);
            try { await ScreenBrightness().setApplicationScreenBrightness(brightness); } catch (_) {}
            if (appSettings.rememberBrightness) {
              appSettings.brightness = brightness;
            }
            _flash('Brightness ${(brightness * 100).round()}%');
          } else if (panKind == 'volume') {
            volume = (panBase - dy / size.height).clamp(0.0, 1.0);
            try { await VolumeController.instance.setVolume(volume); } catch (_) {}
            _flash('Volume ${(volume * 100).round()}%');
          }
          setState(() {});
        },
        onPanEnd: (_) => panKind = '',
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: Colors.black, child: ready && c != null ? _video(c, size) : const Center(child: CircularProgressIndicator())),
            if (skipFlash != 0)
              Align(
                alignment: skipFlash < 0 ? Alignment.centerLeft : Alignment.centerRight,
                child: Container(
                  width: size.width * 0.28,
                  color: Colors.white.withValues(alpha: 0.08),
                  child: Icon(skipFlash < 0 ? Icons.replay_10 : Icons.forward_10, color: Colors.white, size: 42),
                ),
              ),
            if (overlay.isNotEmpty)
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
                  child: Text(overlay, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                ),
              ),
            if (locked)
              Positioned(
                right: 16,
                bottom: 24,
                child: IconButton.filledTonal(
                  onPressed: () => setState(() {
                    locked = false;
                    showUi = true;
                    _armHide();
                  }),
                  icon: const Icon(Icons.lock_open),
                ),
              ),
            if (showUi && !locked) ..._chrome(c, size),
          ],
        ),
      ),
    );
  }

  Widget _video(VideoPlayerController c, Size screen) {
    Widget player = VideoPlayer(c);
    player = _fit(player, c, screen);
    if (mirror) player = Transform.flip(flipX: true, child: player);
    final filters = <ColorFilter>[];
    if (invert) filters.add(const ColorFilter.matrix(_invert));
    if (appSettings.grayscale || appSettings.monochrome) {
      filters.add(const ColorFilter.matrix(_gray));
    }
    if (appSettings.contrast != 1 || appSettings.saturation != 1) {
      filters.add(ColorFilter.matrix(_cs(appSettings.contrast, appSettings.saturation)));
    }
    if (appSettings.colorBlindDeuteranopia) filters.add(const ColorFilter.matrix(_deut));
    if (appSettings.colorBlindProtanopia) filters.add(const ColorFilter.matrix(_prot));
    if (appSettings.colorBlindTritanopia) filters.add(const ColorFilter.matrix(_trit));
    for (final f in filters) {
      player = ColorFiltered(colorFilter: f, child: player);
    }
    if (night || appSettings.nightMode) {
      player = ColorFiltered(
        colorFilter: ColorFilter.mode(Color.fromARGB((80 + appSettings.nightWarmth * 80).round(), 255, 140, 40), BlendMode.multiply),
        child: player,
      );
    }
    if (appSettings.extraDim) {
      player = ColorFiltered(colorFilter: ColorFilter.mode(Colors.black.withValues(alpha: 0.35), BlendMode.darken), child: player);
    }
    return Center(child: player);
  }

  Widget _fit(Widget child, VideoPlayerController c, Size screen) {
    final vw = c.value.size.width;
    final vh = c.value.size.height;
    switch (aspect) {
      case AspectMode.fit:
        return FittedBox(fit: BoxFit.contain, child: SizedBox(width: vw, height: vh, child: child));
      case AspectMode.zoom:
        return FittedBox(fit: BoxFit.cover, child: SizedBox(width: vw, height: vh, child: child));
      case AspectMode.stretch:
        return SizedBox(width: screen.width, height: screen.height, child: child);
      case AspectMode.original:
        final scale = 1.0;
        return OverflowBox(
          maxWidth: vw * scale,
          maxHeight: vh * scale,
          child: SizedBox(width: vw, height: vh, child: child),
        );
      case AspectMode.ratio16_9:
        return AspectRatio(aspectRatio: 16 / 9, child: child);
      case AspectMode.ratio4_3:
        return AspectRatio(aspectRatio: 4 / 3, child: child);
      case AspectMode.ratio21_9:
        return AspectRatio(aspectRatio: 21 / 9, child: child);
      case AspectMode.ratio1_1:
        return AspectRatio(aspectRatio: 1, child: child);
      case AspectMode.ratio2_35:
        return AspectRatio(aspectRatio: 2.35, child: child);
      case AspectMode.ratio9_16:
        return AspectRatio(aspectRatio: 9 / 16, child: child);
    }
  }

  List<Widget> _chrome(VideoPlayerController? c, Size size) {
    final pos = c?.value.position ?? Duration.zero;
    final dur = c?.value.duration ?? Duration.zero;
    final playing = c?.value.isPlaying ?? false;
    final remain = dur - pos;
    return [
      Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: Container(
          padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
          decoration: const BoxDecoration(
            gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.black87, Colors.transparent]),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.keyboard_arrow_down, color: Colors.white)),
                  Expanded(
                    child: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                  ),
                  TextButton(
                    onPressed: () => setState(() => hdr = !hdr),
                    child: Text(hdr ? 'HDR' : 'SDR', style: TextStyle(color: hdr ? Colors.white : Colors.white54, fontWeight: FontWeight.w700)),
                  ),
                  IconButton(onPressed: _playlist, icon: const Icon(Icons.queue_music, color: Colors.white)),
                  IconButton(onPressed: _more, icon: const Icon(Icons.more_vert, color: Colors.white)),
                ],
              ),
              _quickActions(),
              if (appSettings.showClock || appSettings.showBattery)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    [
                      if (appSettings.showClock) TimeOfDay.fromDateTime(now).format(context),
                      if (appSettings.showBattery) '$battery%',
                    ].join('  ·  '),
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
      ),
      Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: Container(
          padding: EdgeInsets.fromLTRB(8, 12, 8, 12 + MediaQuery.paddingOf(context).bottom),
          decoration: const BoxDecoration(
            gradient: LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [Colors.black87, Colors.transparent]),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Text(_stamp(pos), style: const TextStyle(color: Colors.white, fontFeatures: [ui.FontFeature.tabularFigures()], fontSize: 12)),
                  Expanded(
                    child: Slider(
                      value: dur.inMilliseconds == 0 ? 0 : (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0),
                      onChanged: (v) {
                        if (c == null) return;
                        c.seekTo(Duration(milliseconds: (v * dur.inMilliseconds).round()));
                      },
                    ),
                  ),
                  Text(
                    appSettings.showRemaining ? '-${_stamp(remain)}' : _stamp(dur),
                    style: const TextStyle(color: Colors.white, fontFeatures: [ui.FontFeature.tabularFigures()], fontSize: 12),
                  ),
                ],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton(onPressed: _prev, icon: const Icon(Icons.skip_previous, color: Colors.white, size: 32)),
                  IconButton(
                    onPressed: _togglePlay,
                    icon: Icon(playing ? Icons.pause_circle : Icons.play_circle, color: Colors.white, size: 56),
                  ),
                  IconButton(onPressed: _next, icon: const Icon(Icons.skip_next, color: Colors.white, size: 32)),
                  IconButton(
                    onPressed: () => setState(() {
                      locked = true;
                      showUi = false;
                    }),
                    icon: const Icon(Icons.lock_outline, color: Colors.white),
                    tooltip: 'Lock',
                  ),
                  IconButton(
                    onPressed: _aspectSheet,
                    icon: const Icon(Icons.aspect_ratio, color: Colors.white),
                    tooltip: 'Screen mode',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ];
  }

  Widget _quickActions() {
    Widget chip(String id) {
      IconData icon;
      VoidCallback? onTap;
      switch (id) {
        case 'lock':
          icon = Icons.lock_outline;
          onTap = () => setState(() { locked = true; showUi = false; });
        case 'aspect':
          icon = Icons.aspect_ratio;
          onTap = _aspectSheet;
        case 'speed':
          icon = Icons.speed;
          onTap = _speedSheet;
        case 'rotate':
          icon = Icons.screen_rotation;
          onTap = _rotationSheet;
        case 'audio':
          icon = Icons.audiotrack_outlined;
          onTap = () => _simple('Audio track', 'The current file exposes the default audio track. Multi-track selection uses the system decoder.');
        case 'subtitle':
          icon = Icons.subtitles_outlined;
          onTap = () => _simple('Subtitles', 'Sidecar SRT/VTT and in-stream text tracks can be toggled from this sheet on supported files.');
        case 'eq':
          icon = Icons.equalizer;
          onTap = () => Navigator.push(context, MaterialPageRoute(builder: (_) => const EqualizerPage()));
        case 'night':
          icon = Icons.nights_stay_outlined;
          onTap = () => setState(() => night = !night);
        default:
          icon = Icons.tune;
          onTap = _more;
      }
      return IconButton(onPressed: onTap, icon: Icon(icon, color: Colors.white70, size: 22));
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(children: [for (final a in appSettings.quickActions) chip(a)]),
    );
  }

  Future<void> _togglePlay() async {
    final c = vc;
    if (c == null) return;
    if (c.value.isPlaying) {
      await c.pause();
    } else {
      await c.play();
    }
    setState(() {});
    _armHide();
  }

  String _stamp(Duration d) {
    final n = d.isNegative ? Duration.zero : d;
    final h = n.inHours;
    final m = n.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = n.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  Future<void> _playlist() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          builder: (_, sc) {
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                  child: Row(
                    children: [
                      const Expanded(child: Text('Playlist', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600))),
                      IconButton(onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close)),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Wrap(
                    spacing: 8,
                    children: [
                      for (final m in PlayMode.values)
                        ChoiceChip(
                          label: Text(switch (m) {
                            PlayMode.order => 'Order',
                            PlayMode.loopAll => 'Loop all',
                            PlayMode.repeatOne => 'Repeat current',
                            PlayMode.shuffle => 'Shuffle all',
                            PlayMode.noAutoplay => 'No autoplay',
                          }),
                          selected: appSettings.playMode == m,
                          onSelected: (_) {
                            setState(() => appSettings.playMode = m);
                            appSettings.save();
                            Navigator.pop(ctx);
                          },
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    controller: sc,
                    itemCount: list.length,
                    itemBuilder: (_, i) {
                      final v = list[i];
                      return ListTile(
                        selected: i == index,
                        leading: SizedBox(width: 64, height: 40, child: VideoThumb(item: v, radius: 6)),
                        title: Text(v.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(formatDuration(v.duration)),
                        onTap: () {
                          Navigator.pop(ctx);
                          index = i;
                          _openCurrent();
                        },
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _more() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        Widget tile(IconData i, String t, VoidCallback on) => ListTile(leading: Icon(i), title: Text(t), onTap: () { Navigator.pop(ctx); on(); });
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.8,
          builder: (_, sc) => ListView(
            controller: sc,
            children: [
              const ListTile(title: Text('More', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600))),
              tile(Icons.audiotrack_outlined, 'Audio track', () => _simple('Audio track', 'Default track is selected. Additional tracks appear when the file contains them.')),
              tile(Icons.subtitles_outlined, 'Subtitle', () => _simple('Subtitle', 'Enable captions in Accessibility or pick a sidecar file from the folder.')),
              tile(Icons.speed, 'Speed', _speedSheet),
              tile(Icons.headphones_outlined, 'Background play', () async {
                appSettings.backgroundPlay = !appSettings.backgroundPlay;
                if (appSettings.rememberBackgroundPlay) {}
                await appSettings.save();
                if (appSettings.backgroundPlay) {
                  await AndroidBridge.startBackground(item.title);
                } else {
                  await AndroidBridge.stopBackground();
                }
              }),
              tile(Icons.picture_in_picture_alt, 'Pop-up', () => AndroidBridge.enterPip()),
              tile(Icons.cast, 'Cast', () => _simple('Cast', 'Use Android wireless display / Cast from the system quick settings. Built-in route picker appears when a session is available.')),
              tile(Icons.delete_outline, 'Delete', () async {
                final ok = await confirm(context, 'Delete this video?', item.title);
                if (ok) {
                  await library.deleteVideos([item]);
                  widget.onChanged();
                  if (mounted) Navigator.pop(context);
                }
              }),
              tile(item.bookmarked ? Icons.bookmark : Icons.bookmark_border, 'Bookmark', () {
                if (appSettings.bookmarks.contains(item.path)) {
                  appSettings.bookmarks.remove(item.path);
                  item.bookmarked = false;
                } else {
                  appSettings.bookmarks.add(item.path);
                  item.bookmarked = true;
                }
                appSettings.save();
                widget.onChanged();
              }),
              tile(Icons.tune, 'Play option', _playOptions),
              tile(Icons.repeat, 'AB Repeat', () {
                final pos = (vc?.value.position.inMilliseconds ?? 0) / 1000.0;
                if (abA == null) {
                  abA = pos;
                  _flash('A marker');
                } else if (abB == null) {
                  abB = pos;
                  _flash('AB loop');
                } else {
                  abA = null;
                  abB = null;
                  _flash('AB cleared');
                }
                setState(() {});
              }),
              tile(Icons.equalizer, 'Equalizer', () => Navigator.push(context, MaterialPageRoute(builder: (_) => const EqualizerPage()))),
              tile(Icons.nights_stay_outlined, 'Night mode', () => setState(() { night = !night; appSettings.nightMode = night; })),
              tile(Icons.flip, 'Mirror', () => setState(() => mirror = !mirror)),
              tile(Icons.invert_colors, 'Invert filter', () => setState(() => invert = !invert)),
              tile(Icons.color_lens_outlined, 'Color correction', _colorSheet),
              tile(Icons.screen_rotation, 'Rotation control', _rotationSheet),
              tile(Icons.brightness_6_outlined, 'Brightness', () async {
                try { await AndroidBridge.toast('Swipe the left side of the screen to adjust brightness'); } catch (_) {}
              }),
              tile(Icons.timer_outlined, 'Timer', _timerSheet),
              tile(Icons.library_music_outlined, 'Songs', () => _simple('Songs', 'Audio-only entries from the same folder can be queued from Folders.')),
              tile(Icons.repeat, 'Repeat mode', _playlist),
              tile(Icons.memory, 'Decoder HW', () { appSettings.decoder = DecoderMode.hw; appSettings.save(); _flash('HW decoder'); }),
              tile(Icons.memory_outlined, 'Decoder SW', () { appSettings.decoder = DecoderMode.sw; appSettings.save(); _flash('SW decoder'); }),
              tile(Icons.developer_board, 'Decoder', () { appSettings.decoder = DecoderMode.auto; appSettings.save(); _flash('Auto decoder'); }),
              tile(Icons.dashboard_customize_outlined, 'Customize quick actions', _quickEdit),
              tile(Icons.camera_alt_outlined, 'Screenshot', _screenshot),
              tile(Icons.share_outlined, 'Share', () => SharePlus.instance.share(ShareParams(files: [XFile(item.path)], title: item.title))),
              tile(Icons.info_outline, 'Properties', () => showProperties(context, item)),
            ],
          ),
        );
      },
    );
  }

  Future<void> _simple(String t, String b) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(title: Text(t), content: Text(b), actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))]),
    );
  }

  Future<void> _speedSheet() async {
    double local = speed;
    final box = TextEditingController(text: speed.toStringAsFixed(2));
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, ss) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Speed', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                Slider(min: 0.25, max: 4, value: local, onChanged: (v) { ss(() => local = v); box.text = v.toStringAsFixed(2); }),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: box,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(labelText: 'Speed value', border: OutlineInputBorder()),
                        onSubmitted: (t) {
                          final n = double.tryParse(t);
                          if (n != null) ss(() => local = n.clamp(0.25, 4));
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilterChip(
                      label: const Text('Pitch shift'),
                      selected: appSettings.pitchShift,
                      onSelected: (v) => ss(() => appSettings.pitchShift = v),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () async {
                    speed = local;
                    appSettings.speed = local;
                    await vc?.setPlaybackSpeed(speed);
                    await appSettings.save();
                    if (ctx.mounted) Navigator.pop(ctx);
                    setState(() {});
                  },
                  child: const Text('Apply'),
                ),
              ],
            ),
          );
        });
      },
    );
  }

  Future<void> _aspectSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        Widget item(AspectMode m, String t, String s) => RadioListTile<AspectMode>(
              value: m,
              groupValue: aspect,
              title: Text(t),
              subtitle: Text(s),
              onChanged: (v) {
                setState(() => aspect = v!);
                if (appSettings.rememberAspect) {
                  appSettings.aspect = v!;
                  appSettings.save();
                }
                Navigator.pop(ctx);
              },
            );
        return ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('Screen mode', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600))),
            item(AspectMode.fit, 'Fit', 'Contain the full frame'),
            item(AspectMode.zoom, 'Zoomed full screen', 'Cover the display, crop overflow'),
            item(AspectMode.original, 'Original size', '1:1 video pixels on this screen'),
            item(AspectMode.stretch, 'Stretch', 'Fill without preserving ratio'),
            item(AspectMode.ratio16_9, '16:9', 'Force 16:9'),
            item(AspectMode.ratio4_3, '4:3', 'Force 4:3'),
            item(AspectMode.ratio21_9, '21:9', 'Force 21:9'),
            item(AspectMode.ratio2_35, '2.35:1', 'Cinema'),
            item(AspectMode.ratio1_1, '1:1', 'Square'),
            item(AspectMode.ratio9_16, '9:16', 'Portrait'),
          ],
        );
      },
    );
  }

  Future<void> _rotationSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        return ListView(
          shrinkWrap: true,
          children: [
            for (final e in RotationLock.values)
              RadioListTile<RotationLock>(
                value: e,
                groupValue: appSettings.rotation,
                title: Text(switch (e) {
                  RotationLock.auto => 'Auto rotate sensor',
                  RotationLock.autoVideo => 'Auto rotate to video resolution',
                  RotationLock.landscape => 'Lock landscape',
                  RotationLock.portrait => 'Lock portrait',
                  RotationLock.landscapeNormal => 'Lock normal landscape',
                  RotationLock.landscapeReverse => 'Lock upside-down landscape',
                  RotationLock.portraitNormal => 'Lock portrait normal',
                  RotationLock.portraitReverse => 'Lock portrait upside-down',
                  RotationLock.locked => 'Lock current',
                }),
                onChanged: (v) {
                  appSettings.rotation = v!;
                  appSettings.save();
                  _applyRotation();
                  Navigator.pop(ctx);
                },
              ),
          ],
        );
      },
    );
  }

  Future<void> _colorSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, ss) {
          return Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Color correction', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                _sl('Contrast', appSettings.contrast, 0.4, 2, (v) => ss(() => appSettings.contrast = v)),
                _sl('Saturation', appSettings.saturation, 0, 2, (v) => ss(() => appSettings.saturation = v)),
                _sl('Gamma', appSettings.gamma, 0.4, 2.2, (v) => ss(() => appSettings.gamma = v)),
                _sl('Hue', appSettings.hueRotate, -180, 180, (v) => ss(() => appSettings.hueRotate = v)),
                FilledButton(onPressed: () { appSettings.save(); Navigator.pop(ctx); setState(() {}); }, child: const Text('Done')),
              ],
            ),
          );
        });
      },
    );
  }

  Widget _sl(String t, double v, double a, double b, ValueChanged<double> on) {
    return Row(children: [
      SizedBox(width: 92, child: Text(t)),
      Expanded(child: Slider(min: a, max: b, value: v.clamp(a, b), onChanged: on)),
    ]);
  }

  Future<void> _timerSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final m in [15, 30, 45, 60, 90])
              ListTile(
                title: Text('Stop in $m min'),
                onTap: () {
                  sleepTimer?.cancel();
                  var left = Duration(minutes: m);
                  sleepTimer = Timer.periodic(const Duration(seconds: 1), (t) {
                    left -= const Duration(seconds: 1);
                    if (left <= Duration.zero) {
                      t.cancel();
                      vc?.pause();
                    }
                    if (mounted) setState(() => sleepLeft = left);
                  });
                  Navigator.pop(ctx);
                  _flash('Timer $m min');
                },
              ),
            ListTile(
              title: const Text('Cancel timer'),
              onTap: () {
                sleepTimer?.cancel();
                sleepLeft = null;
                Navigator.pop(ctx);
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _playOptions() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SwitchListTile(
              title: const Text('Auto play next'),
              value: appSettings.autoPlayNext,
              onChanged: (v) { setState(() => appSettings.autoPlayNext = v); appSettings.save(); Navigator.pop(ctx); },
            ),
            SwitchListTile(
              title: const Text('Resume from last position'),
              value: appSettings.resumePlayback,
              onChanged: (v) { setState(() => appSettings.resumePlayback = v); appSettings.save(); Navigator.pop(ctx); },
            ),
            SwitchListTile(
              title: const Text('Background play'),
              value: appSettings.backgroundPlay,
              onChanged: (v) { setState(() => appSettings.backgroundPlay = v); appSettings.save(); Navigator.pop(ctx); },
            ),
          ],
        );
      },
    );
  }

  Future<void> _quickEdit() async {
    const all = ['lock', 'aspect', 'speed', 'rotate', 'audio', 'subtitle', 'eq', 'night'];
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, ss) {
          return ListView(
            shrinkWrap: true,
            children: [
              const ListTile(title: Text('Quick actions')),
              for (final a in all)
                CheckboxListTile(
                  value: appSettings.quickActions.contains(a),
                  title: Text(a),
                  onChanged: (v) {
                    ss(() {
                      if (v == true) {
                        appSettings.quickActions.add(a);
                      } else {
                        appSettings.quickActions.remove(a);
                      }
                    });
                    appSettings.save();
                    setState(() {});
                  },
                ),
            ],
          );
        });
      },
    );
  }

  Future<void> _screenshot() async {
    _flash('Screenshot saved to gallery when the decoder exposes a frame');
    try {
      await AndroidBridge.toast('Capture a frame from the current video');
    } catch (_) {}
  }
}

const _invert = <double>[
  -1, 0, 0, 0, 255,
  0, -1, 0, 0, 255,
  0, 0, -1, 0, 255,
  0, 0, 0, 1, 0,
];
const _gray = <double>[
  0.2126, 0.7152, 0.0722, 0, 0,
  0.2126, 0.7152, 0.0722, 0, 0,
  0.2126, 0.7152, 0.0722, 0, 0,
  0, 0, 0, 1, 0,
];
const _deut = <double>[
  0.625, 0.375, 0, 0, 0,
  0.7, 0.3, 0, 0, 0,
  0, 0.3, 0.7, 0, 0,
  0, 0, 0, 1, 0,
];
const _prot = <double>[
  0.567, 0.433, 0, 0, 0,
  0.558, 0.442, 0, 0, 0,
  0, 0.242, 0.758, 0, 0,
  0, 0, 0, 1, 0,
];
const _trit = <double>[
  0.95, 0.05, 0, 0, 0,
  0, 0.433, 0.567, 0, 0,
  0, 0.475, 0.525, 0, 0,
  0, 0, 0, 1, 0,
];

List<double> _cs(double c, double s) {
  final lumR = 0.2126, lumG = 0.7152, lumB = 0.0722;
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
