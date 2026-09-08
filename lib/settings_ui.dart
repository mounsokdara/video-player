import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

import 'android_bridge.dart';
import 'main.dart';
import 'models.dart';

class SettingsHub extends StatelessWidget {
  const SettingsHub({super.key, required this.onChanged});
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget tile(IconData icon, String title, String sub, Widget page) {
      return ListTile(
        leading: CircleAvatar(
          backgroundColor: scheme.surfaceContainerHighest,
          foregroundColor: scheme.onSurface,
          child: Icon(icon),
        ),
        title: Text(title),
        subtitle: Text(sub),
        trailing: const Icon(Icons.chevron_right),
        onTap: () async {
          await Navigator.push(context, MaterialPageRoute(builder: (_) => page));
          onChanged();
        },
      );
    }

    return CustomScrollView(
      slivers: [
        const SliverAppBar(pinned: true, title: Text('Settings')),
        SliverList.list(children: [
          tile(Icons.tune, 'General', 'Library, delete, scanning, storage', GeneralSettings(onChanged: onChanged)),
          tile(Icons.videocam_outlined, 'Video', 'Display, playback, decoder, gestures', VideoSettings(onChanged: onChanged)),
          tile(Icons.accessibility_new, 'Accessibility', 'Captions, color filters, motion, text', AccessSettings(onChanged: onChanged)),
          tile(Icons.palette_outlined, 'Theme', 'Dark / light / system and Material 3 color', ThemeSettings(onChanged: onChanged)),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.folder_open),
            title: const Text('All-files access'),
            subtitle: const Text('Required to read, write, and delete on SD and USB'),
            onTap: () => library.ensureAllFiles(),
          ),
          ListTile(
            leading: const Icon(Icons.equalizer),
            title: const Text('Equalizer'),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const EqualizerPage())),
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('About'),
            subtitle: const Text('Video Player 1.0'),
            onTap: () async {
              final info = await PackageInfo.fromPlatform();
              if (!context.mounted) return;
              showAboutDialog(
                context: context,
                applicationName: 'Video Player',
                applicationVersion: '${info.version} (${info.buildNumber})',
                applicationLegalese: 'Local-only Android player. Material 3.',
              );
            },
          ),
        ]),
      ],
    );
  }
}

class GeneralSettings extends StatefulWidget {
  const GeneralSettings({super.key, required this.onChanged});
  final VoidCallback onChanged;
  @override
  State<GeneralSettings> createState() => _GeneralSettingsState();
}

class _GeneralSettingsState extends State<GeneralSettings> {
  @override
  Widget build(BuildContext context) {
    final s = appSettings;
    void set(VoidCallback fn) {
      setState(fn);
      s.save();
      widget.onChanged();
    }

    return Scaffold(
      appBar: AppBar(title: const Text('General')),
      body: ListView(children: [
        SwitchListTile(title: const Text('Scan library on start'), value: s.scanOnStart, onChanged: (v) => set(() => s.scanOnStart = v)),
        SwitchListTile(title: const Text('Confirm before delete'), value: s.confirmDelete, onChanged: (v) => set(() => s.confirmDelete = v)),
        SwitchListTile(title: const Text('Show hidden folders'), value: s.showHiddenFolders, onChanged: (v) => set(() => s.showHiddenFolders = v)),
        SwitchListTile(title: const Text('Haptic feedback'), value: s.hapticFeedback, onChanged: (v) => set(() => s.hapticFeedback = v)),
        SwitchListTile(title: const Text('Remember playback progress'), value: s.rememberPlayback, onChanged: (v) => set(() => s.rememberPlayback = v)),
        ListTile(
          title: const Text('Clear resume history'),
          onTap: () => set(() => s.resumeMap.clear()),
        ),
        ListTile(
          title: const Text('App permissions'),
          subtitle: const Text('Storage, notifications, display over other apps'),
          onTap: openAppSettings,
        ),
        ListTile(
          title: const Text('Source on GitHub'),
          subtitle: const Text('github.com/mounsokdara/video-player'),
          onTap: () => launchUrl(Uri.parse('https://github.com/mounsokdara/video-player'), mode: LaunchMode.externalApplication),
        ),
      ]),
    );
  }
}

class VideoSettings extends StatefulWidget {
  const VideoSettings({super.key, required this.onChanged});
  final VoidCallback onChanged;
  @override
  State<VideoSettings> createState() => _VideoSettingsState();
}

class _VideoSettingsState extends State<VideoSettings> {
  @override
  Widget build(BuildContext context) {
    final s = appSettings;
    void set(VoidCallback fn) {
      setState(fn);
      s.save();
      widget.onChanged();
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Video')),
      body: ListView(children: [
        _h('Display'),
        SwitchListTile(title: const Text('Remaining time'), subtitle: const Text('Show countdown instead of duration'), value: s.showRemaining, onChanged: (v) => set(() => s.showRemaining = v)),
        SwitchListTile(title: const Text('Clock'), subtitle: const Text('Show clock during playback'), value: s.showClock, onChanged: (v) => set(() => s.showClock = v)),
        SwitchListTile(title: const Text('Battery'), value: s.showBattery, onChanged: (v) => set(() => s.showBattery = v)),
        _h('Screen orientation'),
        ListTile(
          title: const Text('Default rotation'),
          subtitle: Text(s.rotation.name),
          onTap: () async {
            final v = await showModalBottomSheet<RotationLock>(
              context: context,
              builder: (ctx) => ListView(
                shrinkWrap: true,
                children: [
                  for (final e in RotationLock.values)
                    ListTile(title: Text(e.name), onTap: () => Navigator.pop(ctx, e)),
                ],
              ),
            );
            if (v != null) set(() => s.rotation = v);
          },
        ),
        _h('Playback'),
        SwitchListTile(title: const Text('Use HW decoder in priority'), value: s.hwPriority, onChanged: (v) => set(() { s.hwPriority = v; s.decoder = v ? DecoderMode.hw : DecoderMode.sw; })),
        ListTile(
          title: const Text('Decoder'),
          subtitle: Text(s.decoder.name.toUpperCase()),
          onTap: () async {
            final v = await showModalBottomSheet<DecoderMode>(
              context: context,
              builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, children: [
                for (final e in DecoderMode.values) ListTile(title: Text(e.name.toUpperCase()), onTap: () => Navigator.pop(ctx, e)),
              ]),
            );
            if (v != null) set(() => s.decoder = v);
          },
        ),
        ListTile(
          title: const Text('Time to fast forward and rewind'),
          subtitle: Text('${s.seekStepSeconds} seconds'),
          trailing: SizedBox(
            width: 120,
            child: Slider(
              min: 5,
              max: 30,
              divisions: 5,
              value: s.seekStepSeconds.toDouble(),
              onChanged: (v) => set(() => s.seekStepSeconds = v.round()),
            ),
          ),
        ),
        SwitchListTile(title: const Text('Auto Miniplayer'), subtitle: const Text('Continue in a floating window when leaving the app'), value: s.autoMiniplayer, onChanged: (v) => set(() => s.autoMiniplayer = v)),
        SwitchListTile(title: const Text('Background play'), value: s.backgroundPlay, onChanged: (v) => set(() => s.backgroundPlay = v)),
        SwitchListTile(title: const Text('Remember background play'), subtitle: const Text('Keep the option on for every video'), value: s.rememberBackgroundPlay, onChanged: (v) => set(() => s.rememberBackgroundPlay = v)),
        SwitchListTile(title: const Text('Remember aspect ratio'), value: s.rememberAspect, onChanged: (v) => set(() => s.rememberAspect = v)),
        SwitchListTile(title: const Text('Resume'), subtitle: const Text('Continue from where you stopped'), value: s.resumePlayback, onChanged: (v) => set(() => s.resumePlayback = v)),
        SwitchListTile(title: const Text('Remember speed'), value: s.rememberSpeed, onChanged: (v) => set(() => s.rememberSpeed = v)),
        SwitchListTile(title: const Text('Remember brightness'), subtitle: const Text('Off follows system brightness'), value: s.rememberBrightness, onChanged: (v) => set(() => s.rememberBrightness = v)),
        SwitchListTile(title: const Text('Long press to play at 2×'), value: s.longPress2x, onChanged: (v) => set(() => s.longPress2x = v)),
        SwitchListTile(title: const Text('Long press vibration'), value: s.longPressVibration, onChanged: (v) => set(() => s.longPressVibration = v)),
        SwitchListTile(title: const Text('Double tap to fast forward and rewind'), value: s.doubleTapSeek, onChanged: (v) => set(() => s.doubleTapSeek = v)),
        SwitchListTile(title: const Text('Auto play next'), subtitle: const Text('Takes effect in Order mode'), value: s.autoPlayNext, onChanged: (v) => set(() => s.autoPlayNext = v)),
        SwitchListTile(title: const Text('Gesture control'), value: s.gestureControl, onChanged: (v) => set(() => s.gestureControl = v)),
        ListTile(
          title: const Text('Preferred audio language'),
          subtitle: Text(s.preferredAudio),
          onTap: () async {
            final v = await showModalBottomSheet<String>(
              context: context,
              builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, children: [
                for (final l in ['auto', 'en', 'km', 'zh', 'ja', 'ko', 'hi', 'es', 'fr'])
                  ListTile(title: Text(l), onTap: () => Navigator.pop(ctx, l)),
              ]),
            );
            if (v != null) set(() => s.preferredAudio = v);
          },
        ),
        SwitchListTile(title: const Text('Remember HDR mode'), value: s.rememberHdr, onChanged: (v) => set(() => s.rememberHdr = v)),
      ]),
    );
  }

  Widget _h(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
        child: Text(t, style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600)),
      );
}

class AccessSettings extends StatefulWidget {
  const AccessSettings({super.key, required this.onChanged});
  final VoidCallback onChanged;
  @override
  State<AccessSettings> createState() => _AccessSettingsState();
}

class _AccessSettingsState extends State<AccessSettings> {
  @override
  Widget build(BuildContext context) {
    final s = appSettings;
    void set(VoidCallback fn) {
      setState(fn);
      s.save();
      widget.onChanged();
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Accessibility')),
      body: ListView(children: [
        _h('Captions'),
        SwitchListTile(title: const Text('Captions'), value: s.captions, onChanged: (v) => set(() => s.captions = v)),
        SwitchListTile(title: const Text('Live captions'), value: s.liveCaptions, onChanged: (v) => set(() => s.liveCaptions = v)),
        ListTile(
          title: const Text('Caption size'),
          subtitle: Slider(min: 0.8, max: 2, value: s.captionSize, onChanged: (v) => set(() => s.captionSize = v)),
        ),
        _h('Display filters'),
        SwitchListTile(title: const Text('High contrast'), value: s.highContrast, onChanged: (v) => set(() => s.highContrast = v)),
        SwitchListTile(title: const Text('Grayscale'), value: s.grayscale, onChanged: (v) => set(() => s.grayscale = v)),
        SwitchListTile(title: const Text('Invert colors'), value: s.invertColors, onChanged: (v) => set(() => s.invertColors = v)),
        SwitchListTile(title: const Text('Night mode'), value: s.nightMode, onChanged: (v) => set(() => s.nightMode = v)),
        SwitchListTile(title: const Text('Extra dim'), value: s.extraDim, onChanged: (v) => set(() => s.extraDim = v)),
        SwitchListTile(title: const Text('Deuteranopia filter'), value: s.colorBlindDeuteranopia, onChanged: (v) => set(() => s.colorBlindDeuteranopia = v)),
        SwitchListTile(title: const Text('Protanopia filter'), value: s.colorBlindProtanopia, onChanged: (v) => set(() => s.colorBlindProtanopia = v)),
        SwitchListTile(title: const Text('Tritanopia filter'), value: s.colorBlindTritanopia, onChanged: (v) => set(() => s.colorBlindTritanopia = v)),
        _h('Motion and control'),
        SwitchListTile(title: const Text('Reduce motion'), value: s.reduceMotion, onChanged: (v) => set(() => s.reduceMotion = v)),
        SwitchListTile(title: const Text('Large controls'), value: s.largeControls, onChanged: (v) => set(() => s.largeControls = v)),
        SwitchListTile(title: const Text('Bold text'), value: s.boldText, onChanged: (v) => set(() => s.boldText = v)),
        SwitchListTile(title: const Text('Focus highlight'), value: s.focusHighlight, onChanged: (v) => set(() => s.focusHighlight = v)),
        SwitchListTile(title: const Text('Audio description'), value: s.audioDescription, onChanged: (v) => set(() => s.audioDescription = v)),
        SwitchListTile(title: const Text('Stereo fix'), value: s.stereoFix, onChanged: (v) => set(() => s.stereoFix = v)),
        ListTile(
          title: const Text('Interface scale'),
          subtitle: Slider(min: 0.85, max: 1.35, value: s.uiScale, onChanged: (v) => set(() => s.uiScale = v)),
        ),
      ]),
    );
  }

  Widget _h(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
        child: Text(t, style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600)),
      );
}

class ThemeSettings extends StatefulWidget {
  const ThemeSettings({super.key, required this.onChanged});
  final VoidCallback onChanged;
  @override
  State<ThemeSettings> createState() => _ThemeSettingsState();
}

class _ThemeSettingsState extends State<ThemeSettings> {
  static const seeds = <(String, int)>[
    ('Steel', 0xFF8BA3B8),
    ('Ink', 0xFFC5CDD6),
    ('Slate', 0xFF6E7C8A),
    ('Teal', 0xFF4F8B8A),
    ('Forest', 0xFF5F7A63),
    ('Ocean', 0xFF4A6FA5),
    ('Sand', 0xFFA09080),
    ('Rose', 0xFF8E6B73),
  ];

  @override
  Widget build(BuildContext context) {
    final s = appSettings;
    void set(VoidCallback fn) {
      setState(fn);
      s.save();
      widget.onChanged();
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Theme')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          const Text('Mode', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          SegmentedButton<ThemeModePref>(
            segments: const [
              ButtonSegment(value: ThemeModePref.system, label: Text('System'), icon: Icon(Icons.brightness_auto)),
              ButtonSegment(value: ThemeModePref.light, label: Text('Light'), icon: Icon(Icons.light_mode)),
              ButtonSegment(value: ThemeModePref.dark, label: Text('Dark'), icon: Icon(Icons.dark_mode)),
            ],
            selected: {s.themeMode},
            onSelectionChanged: (v) => set(() => s.themeMode = v.first),
          ),
          const SizedBox(height: 20),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Dynamic color'),
            subtitle: const Text('Use wallpaper colors when the device supports Material You'),
            value: s.dynamicColor,
            onChanged: (v) => set(() => s.dynamicColor = v),
          ),
          const SizedBox(height: 8),
          const Text('Seed color', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final e in seeds)
                GestureDetector(
                  onTap: () => set(() => s.seedColor = e.$2),
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: Color(e.$2),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: s.seedColor == e.$2 ? Theme.of(context).colorScheme.onSurface : Colors.transparent,
                        width: 3,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 24),
          Text('Material 3 roles', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'Primary, secondary, tertiary, and surface containers are generated from the seed using ColorScheme.fromSeed. This matches Material You roles used by Flutter.',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _swatch(context, 'Primary', Theme.of(context).colorScheme.primary),
              _swatch(context, 'Secondary', Theme.of(context).colorScheme.secondary),
              _swatch(context, 'Tertiary', Theme.of(context).colorScheme.tertiary),
              _swatch(context, 'Surface', Theme.of(context).colorScheme.surface),
              _swatch(context, 'Container', Theme.of(context).colorScheme.surfaceContainer),
              _swatch(context, 'Error', Theme.of(context).colorScheme.error),
            ],
          ),
        ],
      ),
    );
  }

  Widget _swatch(BuildContext context, String l, Color c) {
    return Container(
      width: 104,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(12)),
      child: Text(l, style: TextStyle(color: c.computeLuminance() > 0.5 ? Colors.black : Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }
}

class EqualizerPage extends StatefulWidget {
  const EqualizerPage({super.key});
  @override
  State<EqualizerPage> createState() => _EqualizerPageState();
}

class _EqualizerPageState extends State<EqualizerPage> {
  Map<String, dynamic>? eq;
  List<int> levels = List.filled(5, 0);
  int min = -1500;
  int max = 1500;
  List<int> freqs = [60, 230, 910, 3600, 14000];
  List<String> presets = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final data = await AndroidBridge.initEqualizer(0);
    if (data != null && mounted) {
      setState(() {
        eq = data;
        min = (data['min'] as num?)?.toInt() ?? -1500;
        max = (data['max'] as num?)?.toInt() ?? 1500;
        freqs = ((data['freqs'] as List?) ?? freqs).map((e) => (e as num).toInt()).toList();
        levels = ((data['levels'] as List?) ?? levels).map((e) => (e as num).toInt()).toList();
        presets = ((data['presets'] as List?) ?? []).map((e) => '$e').toList();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Equalizer')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            if (presets.isNotEmpty)
              SizedBox(
                height: 40,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (var i = 0; i < presets.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ActionChip(
                          label: Text(presets[i]),
                          onPressed: () async {
                            await AndroidBridge.setEqPreset(i);
                            await _load();
                          },
                        ),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 16),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < freqs.length; i++)
                    Expanded(
                      child: Column(
                        children: [
                          Expanded(
                            child: RotatedBox(
                              quarterTurns: -1,
                              child: Slider(
                                min: min.toDouble(),
                                max: max.toDouble(),
                                value: (i < levels.length ? levels[i] : 0).toDouble().clamp(min.toDouble(), max.toDouble()),
                                onChanged: (v) {
                                  setState(() {
                                    if (i >= levels.length) levels = List.from(levels)..addAll(List.filled(i - levels.length + 1, 0));
                                    levels[i] = v.round();
                                  });
                                  AndroidBridge.setEqBand(i, v.round());
                                },
                              ),
                            ),
                          ),
                          Text(freqs[i] >= 1000 ? '${(freqs[i] / 1000).toStringAsFixed(1)}k' : '${freqs[i]}', style: const TextStyle(fontSize: 11)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
