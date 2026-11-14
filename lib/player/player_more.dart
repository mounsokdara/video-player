import 'package:flutter/material.dart';

import 'package:video_player_app/accessibility/live_caption/caption_files.dart';
import 'package:video_player_app/core/insets.dart';
import 'package:video_player_app/core/models.dart';
import 'package:video_player_app/settings/settings.dart';

IconData playerActionIcon(String id) => switch (id) {
      'speed' => Icons.speed,
      'background' => Icons.headphones_outlined,
      'screenshot' => Icons.camera_alt_outlined,
      'lock' => Icons.lock_outline,
      'aspect' => Icons.aspect_ratio,
      'ab' => Icons.repeat,
      'eq' => Icons.equalizer,
      'volume' => Icons.volume_up_outlined,
      'bookmark' => Icons.bookmark_outline,
      'brightness' => Icons.brightness_6_outlined,
      'rotate' => Icons.screen_rotation,
      'share' => Icons.share_outlined,
      'night' => Icons.nights_stay_outlined,
      'zoom' => Icons.zoom_in,
      'skipBack' => Icons.replay_10,
      'skipForward' => Icons.forward_10,
      'popup' => Icons.picture_in_picture_alt,
      'hdr' => Icons.hdr_on,
      'playlist' => Icons.queue_music,
      'more' => Icons.more_vert,
      'color' => Icons.color_lens_outlined,
      'timer' => Icons.timer_outlined,
      'properties' => Icons.info_outline,
      'playopt' => Icons.tune,
      'decoder' => Icons.memory,
      'mirror' => Icons.flip,
      'invert' => Icons.invert_colors,
      'repeat' => Icons.queue_music,
      'delete' => Icons.delete_outline,
      'cast' => Icons.cast,
      'navbar' => Icons.navigation_outlined,
      'caption' => Icons.closed_caption_outlined,
      'captionSettings' => Icons.manage_accounts_outlined,
      _ => Icons.tune,
    };

String? playerActionSub(String id, {required double speed, required double zoomScale}) => switch (id) {
      'speed' => '${speed.toStringAsFixed(2)}×',
      'zoom' => '${(zoomScale * 100).round()}%',
      'decoder' => appSettings.decoder.name.toUpperCase(),
      'eq' => appSettings.eqEnabled ? 'On · ${appSettings.eqPreset}' : 'Off',
      'background' => appSettings.backgroundPlay ? 'On' : 'Off',
      'popup' => appSettings.autoMiniplayer ? 'On' : 'Off',
      'navbar' => appSettings.alwaysHideNavBar ? 'Always hidden' : 'Follows controls',
      'caption' => appSettings.liveCaption ? 'On' : 'Off',
      'captionSettings' => 'AI model, language, caption style',
      _ => null,
    };

Future<void> showPlayerMoreSheet({
  required BuildContext context,
  required VideoItem item,
  required double speed,
  required double zoomScale,
  required Future<void> Function(String id) onAction,
  required Future<void> Function() onOrganize,
}) {
  const sections = <String, List<String>>{
    'Playback': ['speed', 'lock', 'ab', 'skipBack', 'skipForward', 'playopt', 'decoder', 'timer', 'repeat'],
    'Audio': ['background', 'eq', 'volume'],
    'Captions': ['caption'],
    'Picture': ['screenshot', 'aspect', 'brightness', 'rotate', 'night', 'zoom', 'color', 'mirror', 'invert'],
    'System': ['popup', 'navbar', 'cast'],
    'File': ['bookmark', 'share', 'properties', 'delete'],
  };
  const toggles = {'background', 'popup', 'night', 'mirror', 'invert', 'navbar', 'bookmark', 'caption'};
  final scheme = Theme.of(context).colorScheme;
  return SystemBars.modal(
    () => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, ss) {
          bool onFor(String id) => switch (id) {
                'background' => appSettings.backgroundPlay,
                'popup' => appSettings.autoMiniplayer,
                'night' => appSettings.nightMode,
                'mirror' => appSettings.mirror,
                'invert' => appSettings.invertColors,
                'navbar' => appSettings.alwaysHideNavBar,
                'caption' => appSettings.liveCaption,
                'bookmark' => item.bookmarked || appSettings.bookmarks.contains(item.path),
                _ => false,
              };
          final seen = <String>{'captionSettings'};
          return SafeArea(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 16),
              children: [
                ListTile(
                  title: Text('More', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: scheme.onSurface)),
                ),
                ListTile(
                  leading: Icon(Icons.dashboard_customize_outlined, color: scheme.onSurface),
                  title: Text('Organize quick actions', style: TextStyle(color: scheme.onSurface)),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await onOrganize();
                  },
                ),
                for (final section in sections.entries) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Text(section.key, style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w700)),
                  ),
                  for (final id in section.value)
                    if (AppSettings.allQuickActions.containsKey(id) && seen.add(id))
                      id == 'caption'
                          ? _SplitActionTile(
                              icon: playerActionIcon(id),
                              title: AppSettings.allQuickActions[id]!,
                              subtitle: playerActionSub(id, speed: speed, zoomScale: zoomScale),
                              value: onFor(id),
                              onOpen: () async {
                                Navigator.pop(ctx);
                                await onAction('captionSettings');
                              },
                              onToggle: () async {
                                await onAction(id);
                                ss(() {});
                              },
                            )
                          : toggles.contains(id)
                          ? SwitchListTile(
                              secondary: Icon(playerActionIcon(id), color: scheme.onSurface),
                              title: Text(AppSettings.allQuickActions[id]!, style: TextStyle(color: scheme.onSurface)),
                              subtitle: playerActionSub(id, speed: speed, zoomScale: zoomScale) == null
                                  ? null
                                  : Text(
                                      playerActionSub(id, speed: speed, zoomScale: zoomScale)!,
                                      style: TextStyle(color: scheme.onSurfaceVariant),
                                    ),
                              value: onFor(id),
                              onChanged: (_) async {
                                await onAction(id);
                                ss(() {});
                              },
                            )
                          : ListTile(
                              leading: Icon(playerActionIcon(id), color: scheme.onSurface),
                              title: Text(AppSettings.allQuickActions[id]!, style: TextStyle(color: scheme.onSurface)),
                              subtitle: playerActionSub(id, speed: speed, zoomScale: zoomScale) == null
                                  ? null
                                  : Text(
                                      playerActionSub(id, speed: speed, zoomScale: zoomScale)!,
                                      style: TextStyle(color: scheme.onSurfaceVariant),
                                    ),
                              onTap: () async {
                                Navigator.pop(ctx);
                                await onAction(id);
                              },
                            ),
                  if (section.key == 'Captions')
                    ListTile(
                      leading: Icon(Icons.subtitles_outlined, color: scheme.onSurface),
                      title: Text('Captions file', style: TextStyle(color: scheme.onSurface)),
                      subtitle: Text('Export or import .srt', style: TextStyle(color: scheme.onSurfaceVariant)),
                      onTap: () async {
                        Navigator.pop(ctx);
                        await CaptionFiles.showSheet(context, item, onAction: onAction);
                      },
                    ),
                ],
                for (final e in AppSettings.allQuickActions.entries)
                  if (seen.add(e.key))
                    ListTile(
                      leading: Icon(playerActionIcon(e.key), color: scheme.onSurface),
                      title: Text(e.value, style: TextStyle(color: scheme.onSurface)),
                      subtitle: playerActionSub(e.key, speed: speed, zoomScale: zoomScale) == null
                          ? null
                          : Text(
                              playerActionSub(e.key, speed: speed, zoomScale: zoomScale)!,
                              style: TextStyle(color: scheme.onSurfaceVariant),
                            ),
                      onTap: () async {
                        Navigator.pop(ctx);
                        await onAction(e.key);
                      },
                    ),
              ],
            ),
          );
        });
      },
    ),
  );
}


class _SplitActionTile extends StatelessWidget {
  const _SplitActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onOpen,
    required this.onToggle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final Future<void> Function() onOpen;
  final Future<void> Function() onToggle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: ListTile(
            leading: Icon(icon, color: scheme.onSurface),
            title: Text(title, style: TextStyle(color: scheme.onSurface)),
            subtitle: subtitle == null ? null : Text(subtitle!, style: TextStyle(color: scheme.onSurfaceVariant)),
            onTap: onOpen,
          ),
        ),
        SizedBox(height: 40, child: VerticalDivider(width: 1, thickness: 1, color: scheme.outlineVariant)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Switch(value: value, onChanged: (_) => onToggle()),
        ),
      ],
    );
  }
}
