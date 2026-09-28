import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:video_player_app/playback/engine.dart';
import 'package:video_player_app/playback/render_profile.dart';

/// Bottom sheet with the render options: HDR/SDR mode, brightness,
/// frame-rate limit and resolution limit. Everything applies live.
Future<void> showRenderSheet(BuildContext context, PlaybackEngine? engine) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.88),
    builder: (_) => _RenderSheet(engine: engine),
  );
}

class _RenderSheet extends StatefulWidget {
  const _RenderSheet({required this.engine});
  final PlaybackEngine? engine;

  @override
  State<_RenderSheet> createState() => _RenderSheetState();
}

class _RenderSheetState extends State<_RenderSheet> {
  final _rs = RenderSettings.instance;
  final _fpsCtl = TextEditingController();
  final _resCtl = TextEditingController();
  late bool _fpsCustom;
  late bool _resCustom;
  late bool _sdr;

  PlaybackEngine? get _e => widget.engine;

  @override
  void initState() {
    super.initState();
    _fpsCustom = _rs.fpsMode == FpsMode.fixed && !RenderSettings.fpsPresets.contains(_rs.fpsValue);
    _resCustom = _rs.resMode == ResMode.fixed && !RenderSettings.resPresets.any((r) => r.p == _rs.resValue);
    _sdr = _e?.sdrMode ?? _rs.autoSdr;
    if (_fpsCustom) _fpsCtl.text = '${_rs.fpsValue}';
    if (_resCustom) _resCtl.text = '${_rs.resValue}';
  }

  @override
  void dispose() {
    _fpsCtl.dispose();
    _resCtl.dispose();
    super.dispose();
  }

  Future<void> _commit() async {
    await _rs.save();
    await _e?.reapplyRender();
  }

  void _setFps(FpsMode mode, {int? value}) {
    setState(() {
      _fpsCustom = false;
      _rs.fpsMode = mode;
      if (value != null) _rs.fpsValue = value;
    });
    _commit();
  }

  void _applyCustomFps() {
    final n = int.tryParse(_fpsCtl.text.trim());
    if (n == null) return;
    setState(() {
      _rs.fpsMode = FpsMode.fixed;
      _rs.fpsValue = n.clamp(RenderSettings.fpsMin, RenderSettings.fpsMax);
      _fpsCtl.text = '${_rs.fpsValue}';
    });
    FocusScope.of(context).unfocus();
    _commit();
  }

  void _setRes(ResMode mode, {int? value}) {
    setState(() {
      _resCustom = false;
      _rs.resMode = mode;
      if (value != null) _rs.resValue = value;
    });
    _commit();
  }

  void _applyCustomRes() {
    final n = int.tryParse(_resCtl.text.trim());
    if (n == null) return;
    setState(() {
      _rs.resMode = ResMode.fixed;
      _rs.resValue = n.clamp(RenderSettings.resMin, RenderSettings.resMax);
      _resCtl.text = '${_rs.resValue}';
    });
    FocusScope.of(context).unfocus();
    _commit();
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) {
    return ChoiceChip(label: Text(label), selected: selected, onSelected: (_) => onTap());
  }

  Widget _title(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Text(text, style: Theme.of(context).textTheme.titleMedium),
    );
  }

  Widget _hint(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(text, style: Theme.of(context).textTheme.bodySmall),
    );
  }

  Widget _numberField(TextEditingController controller, String label, VoidCallback onApply) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(labelText: label, isDense: true, border: const OutlineInputBorder()),
              onSubmitted: (_) => onApply(),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(onPressed: onApply, child: const Text('Set')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final e = _e;
    final active = e?.hdrActive ?? false;
    final src = e?.source;
    final tune = _rs.tuning(sdr: _sdr);
    final hz = ScreenInfo.current().hz.round();

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Render settings', style: Theme.of(context).textTheme.titleLarge),

              _title('HDR / SDR'),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment<bool>(value: false, label: Text('HDR')),
                  ButtonSegment<bool>(value: true, label: Text('SDR')),
                ],
                selected: {_sdr},
                onSelectionChanged: active
                    ? (s) {
                        setState(() => _sdr = s.first);
                        e?.setSdrMode(_sdr);
                      }
                    : null,
              ),
              _hint(active
                  ? 'Switches this video live. Neither mode is real HDR output: the picture is always tone-mapped for your screen. HDR matches the phone gallery, SDR is brighter.'
                  : 'Only for HDR videos. The current video is not HDR.'),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Auto convert HDR to SDR'),
                subtitle: const Text('Open every HDR video in SDR mode.'),
                value: _rs.autoSdr,
                onChanged: (v) {
                  setState(() => _rs.autoSdr = v);
                  _rs.save();
                },
              ),

              _title('${_sdr ? 'SDR' : 'HDR'} brightness'),
              Text('White level: ${tune.peak} nits (higher = darker)'),
              Slider(
                value: tune.peak.toDouble().clamp(100.0, 1000.0).toDouble(),
                min: 100,
                max: 1000,
                divisions: 36,
                onChanged: (v) {
                  setState(() => _rs.setTuning(sdr: _sdr, peak: v.round()));
                  e?.retune();
                },
                onChangeEnd: (_) => _rs.save(),
              ),
              Text('Mid-tones: ${tune.gamma} (negative = darker)'),
              Slider(
                value: tune.gamma.toDouble().clamp(-50.0, 50.0).toDouble(),
                min: -50,
                max: 50,
                divisions: 100,
                onChanged: (v) {
                  setState(() => _rs.setTuning(sdr: _sdr, gamma: v.round()));
                  e?.retune();
                },
                onChangeEnd: (_) => _rs.save(),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () {
                    setState(() => _rs.resetTuning(sdr: _sdr));
                    _rs.save();
                    e?.retune();
                  },
                  child: const Text('Reset brightness'),
                ),
              ),

              _title('Frame-rate limit'),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  _chip('Off', _rs.fpsMode == FpsMode.off, () => _setFps(FpsMode.off)),
                  _chip('Auto · $hz Hz', _rs.fpsMode == FpsMode.auto, () => _setFps(FpsMode.auto)),
                  for (final f in RenderSettings.fpsPresets)
                    _chip('$f', _rs.fpsMode == FpsMode.fixed && !_fpsCustom && _rs.fpsValue == f,
                        () => _setFps(FpsMode.fixed, value: f)),
                  _chip('Custom', _fpsCustom, () => setState(() => _fpsCustom = true)),
                ],
              ),
              if (_fpsCustom) _numberField(_fpsCtl, 'FPS (${RenderSettings.fpsMin}-${RenderSettings.fpsMax})', _applyCustomFps),
              _hint('Only drops frames above the limit, never adds any. Auto uses your screen refresh rate.'
                  '${src != null && src.fps > 0 ? ' This video: ${src.fps.round()} fps.' : ''}'),

              _title('Resolution limit'),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  _chip('Auto · video', _rs.resMode == ResMode.autoVideo, () => _setRes(ResMode.autoVideo)),
                  _chip('Auto · screen', _rs.resMode == ResMode.autoScreen, () => _setRes(ResMode.autoScreen)),
                  for (final r in RenderSettings.resPresets)
                    _chip(r.label, _rs.resMode == ResMode.fixed && !_resCustom && _rs.resValue == r.p,
                        () => _setRes(ResMode.fixed, value: r.p)),
                  _chip('Custom P', _resCustom, () => setState(() => _resCustom = true)),
                ],
              ),
              if (_resCustom) _numberField(_resCtl, 'P (${RenderSettings.resMin}-${RenderSettings.resMax})', _applyCustomRes),
              _hint('Shrinks the picture before it is drawn. The limit is the shorter side (720p = 1280×720 or 720×1280) and it never upscales. Auto · video keeps the original size, Auto · screen fits your display.'
                  '${src != null && src.w > 0 ? ' This video: ${src.w}×${src.h}.' : ''}'),

              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () {
                    setState(() {
                      _rs.resetLimits();
                      _fpsCustom = false;
                      _resCustom = false;
                    });
                    _commit();
                  },
                  child: const Text('Reset limits'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
