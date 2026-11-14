import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:video_player_app/accessibility/live_caption/live_caption_controller.dart';
import 'package:video_player_app/accessibility/live_caption/system_caption_style.dart';

class EnginePositionListenable implements ValueListenable<int> {
  EnginePositionListenable(this._source, this._read);
  final Listenable _source;
  final int Function() _read;

  @override
  int get value => _read();

  @override
  void addListener(VoidCallback listener) => _source.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => _source.removeListener(listener);
}

class LiveCaptionOverlay extends StatefulWidget {
  const LiveCaptionOverlay({super.key, required this.path, required this.position, this.compact = false});

  final String path;

  final ValueListenable<int> position;

  final bool compact;

  @override
  State<LiveCaptionOverlay> createState() => _LiveCaptionOverlayState();
}

class _LiveCaptionOverlayState extends State<LiveCaptionOverlay> with WidgetsBindingObserver {
  final LiveCaptionController _ctl = LiveCaptionController.instance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SystemCaptionStyle.refresh();
    _ctl.attach(this, widget.path, widget.position);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) SystemCaptionStyle.refresh();
  }

  @override
  void didUpdateWidget(LiveCaptionOverlay old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path || old.position != widget.position) {
      _ctl.attach(this, widget.path, widget.position);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ctl.detach(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final compact = widget.compact;
    return AnimatedBuilder(
      animation: Listenable.merge([_ctl, widget.position]),
      builder: (context, _) {
        final text = _ctl.textAt(widget.position.value);
        final chip = _ctl.chipText;
        final p = _ctl.chipProgress;
        if (text.isEmpty && chip == null) return const SizedBox.shrink();
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (chip != null)
              Container(
                margin: EdgeInsets.only(bottom: text.isEmpty ? 0 : 4),
                padding: EdgeInsets.symmetric(horizontal: compact ? 6 : 10, vertical: compact ? 2 : 4),
                decoration: BoxDecoration(
                  color: const Color(0x99000000),
                  borderRadius: BorderRadius.circular(compact ? 6 : 10),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      chip,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white70, fontSize: compact ? 9 : 12),
                    ),
                    if (p != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: SizedBox(
                          width: compact ? 70 : 140,
                          height: 3,
                          child: LinearProgressIndicator(
                            value: p,
                            minHeight: 3,
                            backgroundColor: Colors.white24,
                            color: const Color(0xFF9E8CFF),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            if (text.isNotEmpty)
              ValueListenableBuilder<SystemCaptionStyle>(
                valueListenable: SystemCaptionStyle.current,
                builder: (context, style, _) => _captionBox(text, style, compact),
              ),
          ],
        );
      },
    );
  }

  Widget _captionBox(String text, SystemCaptionStyle style, bool compact) {
    final box = Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 6 : 12, vertical: compact ? 2 : 6),
      decoration: BoxDecoration(
        color: style.background ?? const Color(0xB8000000),
        borderRadius: BorderRadius.circular(compact ? 6 : 8),
      ),
      child: _captionText(text, style, compact),
    );
    final window = style.window;
    if (window == null || window.a == 0) return box;
    return Container(
      padding: EdgeInsets.all(compact ? 3 : 6),
      decoration: BoxDecoration(color: window, borderRadius: BorderRadius.circular(compact ? 8 : 12)),
      child: box,
    );
  }

  Widget _captionText(String text, SystemCaptionStyle style, bool compact) {
    final color = style.foreground ?? Colors.white;
    final edge = style.edgeColor ?? Colors.black;
    final base = TextStyle(
      fontSize: (compact ? 11 : 18) * style.fontScale,
      height: 1.25,
      fontWeight: style.bold ? FontWeight.w700 : FontWeight.w500,
      fontStyle: style.italic ? FontStyle.italic : FontStyle.normal,
    );
    final lines = compact ? 2 : 3;
    Widget fill(List<Shadow>? shadows) => Text(
          text,
          textAlign: TextAlign.center,
          maxLines: lines,
          overflow: TextOverflow.ellipsis,
          style: base.copyWith(color: color, shadows: shadows),
        );
    switch (style.edgeType) {
      case SystemCaptionStyle.edgeOutline:
        return Stack(
          children: [
            Text(
              text,
              textAlign: TextAlign.center,
              maxLines: lines,
              overflow: TextOverflow.ellipsis,
              style: base.copyWith(
                foreground: Paint()
                  ..style = PaintingStyle.stroke
                  ..strokeJoin = StrokeJoin.round
                  ..strokeWidth = compact ? 2 : 3
                  ..color = edge,
              ),
            ),
            fill(null),
          ],
        );
      case SystemCaptionStyle.edgeDropShadow:
        return fill([Shadow(color: edge, blurRadius: 2, offset: const Offset(1.5, 1.5))]);
      case SystemCaptionStyle.edgeRaised:
        return fill([
          const Shadow(color: Colors.white, blurRadius: 1, offset: Offset(-1, -1)),
          Shadow(color: edge, blurRadius: 1, offset: const Offset(1, 1)),
        ]);
      case SystemCaptionStyle.edgeDepressed:
        return fill([
          Shadow(color: edge, blurRadius: 1, offset: const Offset(-1, -1)),
          const Shadow(color: Colors.white, blurRadius: 1, offset: Offset(1, 1)),
        ]);
      default:
        return fill(null);
    }
  }
}
