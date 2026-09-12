import 'package:flutter/material.dart';

import 'mini_geom.dart';

class MiniStickyArrow extends StatelessWidget {
  const MiniStickyArrow({
    super.key,
    required this.side,
    required this.width,
  });

  final String side;
  final double width;

  @override
  Widget build(BuildContext context) {
    final left = side == 'left';
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: MiniGeom.ease,
      width: width,
      height: MiniGeom.arrowH,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.horizontal(
          left: left ? Radius.zero : const Radius.circular(12),
          right: left ? const Radius.circular(12) : Radius.zero,
        ),
      ),
      clipBehavior: Clip.hardEdge,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 250),
        curve: MiniGeom.ease,
        opacity: width < 8 ? 0 : 1,
        child: Icon(left ? Icons.chevron_right : Icons.chevron_left,
            size: 24, color: scheme.onSurface),
      ),
    );
  }
}

class MiniTransportBar extends StatelessWidget {
  const MiniTransportBar({
    super.key,
    required this.title,
    required this.playing,
    required this.onPrev,
    required this.onPlay,
    required this.onNext,
  });

  final String title;
  final bool playing;
  final VoidCallback onPrev;
  final VoidCallback onPlay;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    Widget ctrl(String label, IconData icon, VoidCallback onTap, {bool play = false}) {
      final size = play ? 34.0 : 30.0;
      return Tooltip(
        message: label,
        child: Material(
          color: play ? scheme.onSurface.withValues(alpha: 0.12) : Colors.transparent,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: size,
              height: size,
              child: Icon(icon, size: play ? 18 : 17, color: scheme.onSurface),
            ),
          ),
        ),
      );
    }

    return ColoredBox(
      color: scheme.surface,
      child: SizedBox(
        height: MiniGeom.barH,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
              ctrl('Previous', Icons.skip_previous, onPrev),
              const SizedBox(width: 4),
              ctrl(playing ? 'Pause' : 'Play',
                  playing ? Icons.pause : Icons.play_arrow, onPlay, play: true),
              const SizedBox(width: 4),
              ctrl('Next', Icons.skip_next, onNext),
            ],
          ),
        ),
      ),
    );
  }
}
