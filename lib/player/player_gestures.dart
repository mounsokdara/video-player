part of 'player.dart';

extension PlayerGestures on _PlayerPageState {
  void _pinchDown(PointerDownEvent e, Size size) {
    _pts[e.pointer] = e.localPosition;
    if (_pts.length == 2 && appSettings.allowZoom) {
      if (_gesture == 'pan' || _gesture == 'hold') return;
      _gesture = 'pinch';
      _ateTap = true;
      final pts = _pts.values.toList();
      _pinchStart = (pts[0] - pts[1]).distance;
      _pinchBase = _zoomScale;
      _pinchBasePan = _zoomPan;
      _pinchStartFocal = Offset((pts[0].dx + pts[1].dx) / 2, (pts[0].dy + pts[1].dy) / 2);
      _pinching = true;
      _showZoomHud = true;
      _zoomHudTimer?.cancel();
      if (mounted) setState(() {});
    }
  }

  void _pinchMove(PointerMoveEvent e, Size size) {
    _pts[e.pointer] = e.localPosition;
    if (_pts.length < 2 || !appSettings.allowZoom) return;
    final pts = _pts.values.toList();
    final dist = (pts[0] - pts[1]).distance;
    final focal = Offset((pts[0].dx + pts[1].dx) / 2, (pts[0].dy + pts[1].dy) / 2);
    if (_pinchStart <= 12) {
      _pinchStart = dist;
      _pinchBase = _zoomScale;
      _pinchBasePan = _zoomPan;
      _pinchStartFocal = focal;
      return;
    }
    final nextScale = (_pinchBase * dist / _pinchStart).clamp(0.01, 10.0);
    final center = Offset(size.width / 2, size.height / 2);
    Offset nextPan;
    if (nextScale <= 1.001) {
      nextPan = Offset.zero;
    } else {
      final content = (_pinchStartFocal - center - _pinchBasePan) / _pinchBase;
      nextPan = focal - center - content * nextScale;
      final maxX = (nextScale - 1) * size.width / 2 + 48;
      final maxY = (nextScale - 1) * size.height / 2 + 48;
      nextPan = Offset(nextPan.dx.clamp(-maxX, maxX), nextPan.dy.clamp(-maxY, maxY));
    }
    if ((nextScale - _zoomScale).abs() > 0.004 || (nextPan - _zoomPan).distance > 0.5) {
      setState(() {
        _zoomScale = nextScale;
        _zoomPan = nextScale <= 0.011 ? Offset.zero : nextPan;
        _pinching = true;
        _showZoomHud = true;
      });
    }
  }

  void _pinchUp(int pointer) {
    _pts.remove(pointer);
    if (_pts.length < 2 && _pinching) {
      _pinching = false;
      _gesture = '';
      if (_zoomScale < 0.011) {
        _zoomScale = 0.01;
        _zoomPan = Offset.zero;
      }
      _zoomHudTimer?.cancel();
      _zoomHudTimer = Timer(const Duration(milliseconds: 900), () {
        if (mounted) setState(() => _showZoomHud = false);
      });
      if (mounted) setState(() {});
    }
  }

  bool _wouldBurst(Offset pos, Size size) {
    final now = DateTime.now();
    final zone = tapZoneFor(pos, size);
    final last = switch (zone) {
      TapZone.left => _leftTap,
      TapZone.right => _rightTap,
      TapZone.middle => _midTap,
    };
    final zoneOn = switch (zone) {
      TapZone.left => _leftOn,
      TapZone.right => _rightOn,
      TapZone.middle => _midOn,
    };
    return _activeRipples > 0 || now.difference(last) < const Duration(milliseconds: 320) || zoneOn;
  }

  void _armFirstTap(Offset pos, Size size) {
    final now = DateTime.now();
    final zone = tapZoneFor(pos, size);
    _uiBeforeTap = showUi;
    switch (zone) {
      case TapZone.left:
        _leftTap = now;
      case TapZone.right:
        _rightTap = now;
      case TapZone.middle:
        _midTap = now;
    }
  }

  void _onVideoTap(Offset pos, Size size) {
    const tapWindow = Duration(milliseconds: 320);
    const hideDelay = Duration(milliseconds: 900);
    const midHide = Duration(milliseconds: 700);
    final now = DateTime.now();
    final zone = tapZoneFor(pos, size);
    final side = switch (zone) {
      TapZone.left => 'left',
      TapZone.right => 'right',
      TapZone.middle => 'mid',
    };
    final last = switch (zone) {
      TapZone.left => _leftTap,
      TapZone.right => _rightTap,
      TapZone.middle => _midTap,
    };
    final zoneOn = switch (zone) {
      TapZone.left => _leftOn,
      TapZone.right => _rightOn,
      TapZone.middle => _midOn,
    };
    final isDouble = now.difference(last) < tapWindow;
    final rippleActive = _activeRipples > 0;
    _tapAt = now;
    _tapPos = pos;

    if (!rippleActive && !isDouble && !zoneOn) {
      if (zone == TapZone.left) _leftTap = now;
      if (zone == TapZone.right) _rightTap = now;
      if (zone == TapZone.middle) _midTap = now;
      _uiBeforeTap = showUi;
      _setUi(!showUi);
      return;
    }

    _setUi(_uiBeforeTap);

    if (zone == TapZone.left || zone == TapZone.right) {
      if (!appSettings.doubleTapSeek) {
        _setUi(!showUi);
        return;
      }
      if (_currentSide != null && _currentSide != side) {
        _resetSide(_currentSide!);
        if (side == 'left') {
          _leftCount = 0;
        } else {
          _rightCount = 0;
        }
      }
      _currentSide = side;
      final step = appSettings.seekStepSeconds;
      if (zone == TapZone.left) {
        _leftTap = now;
        _leftCount += step;
        _leftOn = true;
        _spawnRipple(zone, pos, size);
        _leftHide?.cancel();
        _leftHide = Timer(hideDelay, () {
          if (!mounted) return;
          setState(() {
            _leftOn = false;
            _leftCount = 0;
            _leftTap = DateTime.fromMillisecondsSinceEpoch(0);
            if (_currentSide == 'left') _currentSide = null;
          });
        });
        unawaited(_seekBy(-step));
      } else {
        _rightTap = now;
        _rightCount += step;
        _rightOn = true;
        _spawnRipple(zone, pos, size);
        _rightHide?.cancel();
        _rightHide = Timer(hideDelay, () {
          if (!mounted) return;
          setState(() {
            _rightOn = false;
            _rightCount = 0;
            _rightTap = DateTime.fromMillisecondsSinceEpoch(0);
            if (_currentSide == 'right') _currentSide = null;
          });
        });
        unawaited(_seekBy(step));
      }
      setState(() {});
      return;
    }

    _midTap = now;
    _midOn = true;
    final playing = vc?.value.isPlaying ?? false;
    _togglePlay();
    _midPlayingIcon = !playing;
    _spawnRipple(TapZone.middle, pos, size);
    _midBursts.add(MidBurst(id: _rippleSeq, playing: !playing));
    _midHide?.cancel();
    _midHide = Timer(midHide, () {
      if (!mounted) return;
      setState(() {
        _midOn = false;
        _midTap = DateTime.fromMillisecondsSinceEpoch(0);
      });
    });
    setState(() {});
  }

  void _resetSide(String side) {
    if (side == 'left') {
      _leftHide?.cancel();
      _leftOn = false;
      _leftCount = 0;
      _leftTap = DateTime.fromMillisecondsSinceEpoch(0);
    } else if (side == 'right') {
      _rightHide?.cancel();
      _rightOn = false;
      _rightCount = 0;
      _rightTap = DateTime.fromMillisecondsSinceEpoch(0);
    }
  }

  void _spawnRipple(TapZone zone, Offset pos, Size size) {
    final spec = makeRipple(id: _rippleSeq++, zone: zone, pos: pos, size: size);
    _ripples.add(spec);
    _activeRipples++;
  }
  void _queuePreview(double frac) {
    if (!appSettings.showSeekPreview) return;
    _previewWant = frac;
    if (_previewBusy) return;
    unawaited(_runPreview());
  }

  Future<void> _runPreview() async {
    _previewBusy = true;
    while (_previewWant != null && mounted && _scrub != null) {
      final frac = _previewWant!;
      _previewWant = null;
      final dur = vc?.value.duration.inMilliseconds ?? 0;
      if (dur <= 0) break;
      final bytes = await AndroidBridge.previewFrame(
        path: item.path,
        positionMs: (frac.clamp(0.0, 1.0) * dur).round(),
      );
      if (mounted && _scrub != null) setState(() => _previewBytes = bytes);
    }
    _previewBusy = false;
  }
}
