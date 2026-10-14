import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:playback_core/playback_core.dart';

/// Optional Skip control for Cinema Mode pre-rolls; no trailer lookup or Seerr.
class CinemaSkipController extends ChangeNotifier {
  CinemaSkipController({required Future<void> Function() onSkip})
      : _onSkip = onSkip;

  final Future<void> Function() _onSkip;
  Timer? _hideTimer;
  Object? _queueItem;
  int _queueIndex = -1;
  int? _lastReadyToken;
  int? _previousReadyToken;
  Duration? _metadataDuration;
  Duration? _playerDuration;
  int _generation = 0;
  int _minimumSeconds = 15;
  int _autoHideSeconds = 15;
  bool _active = false;
  bool _enabled = false;
  bool _wanted = false;
  bool _playing = false;
  bool _skipping = false;

  int get generation => _generation;
  bool get enabled => _enabled;
  Duration get duration =>
      _playerDuration ?? _metadataDuration ?? Duration.zero;
  bool get eligible =>
      _active &&
      _enabled &&
      (_minimumSeconds == 0 ||
          duration >= Duration(seconds: _minimumSeconds));
  bool get visible => eligible && _wanted && !_skipping;

  void configure({
    required bool enabled,
    required int minimumSeconds,
    required int autoHideSeconds,
  }) {
    final minimum = minimumSeconds.clamp(0, 60);
    if (_enabled == enabled &&
        _minimumSeconds == minimum &&
        _autoHideSeconds == autoHideSeconds) {
      return;
    }
    _enabled = enabled;
    _minimumSeconds = minimum;
    _autoHideSeconds = autoHideSeconds;
    _restartTimer();
    notifyListeners();
  }

  /// Reconcile queue changes and playback readiness in one place, shared by
  /// Flutter playback and the native Apple TV host.
  void synchronize({
    required Object? item,
    required int index,
    required Map<String, dynamic>? preroll,
    required String? itemId,
    required PlaybackBringupState source,
    required Duration duration,
    required bool playing,
    bool initial = false,
  }) {
    if (initial || !identical(item, _queueItem) || index != _queueIndex) {
      _previousReadyToken = initial ? null : _lastReadyToken;
      _queueItem = item;
      _queueIndex = index;
      enter(preroll);
    }
    // Ignore a ready event from the outgoing pre-roll, even if its item ID
    // matches the next pre-roll. Only the new playback session can update it.
    if (preroll == null ||
        source.phase != PlaybackBringupPhase.ready ||
        source.itemId != itemId ||
        source.sessionToken == _previousReadyToken) {
      return;
    }
    _lastReadyToken = source.sessionToken;
    updatePlayback(duration: duration, playing: playing);
  }

  void enter(Map<String, dynamic>? item) {
    ++_generation;
    _hideTimer?.cancel();
    _hideTimer = null;
    _active = item != null;
    _wanted = _active;
    _playing = false;
    _skipping = false;
    _playerDuration = null;
    _metadataDuration = null;
    final ticks = int.tryParse(item?['RunTimeTicks']?.toString() ?? '');
    if (ticks != null && ticks > 0) {
      _metadataDuration = Duration(microseconds: ticks ~/ 10);
    }
    notifyListeners();
  }

  /// Call only when playback's ready token belongs to the current queue item.
  void updatePlayback({
    required Duration duration,
    required bool playing,
  }) {
    if (!_active) return;
    final wasVisible = visible;
    final wasPlaying = _playing;
    final oldDuration = this.duration;
    if (duration > Duration.zero) _playerDuration = duration;
    _playing = playing;
    if (wasVisible != visible || wasPlaying != playing) _restartTimer();
    if (oldDuration != this.duration || wasVisible != visible) {
      notifyListeners();
    }
  }

  /// User interaction can reveal a control hidden by the timeout or Back.
  void reveal() {
    if (!eligible || _skipping) return;
    if (visible) {
      _restartTimer();
      return;
    }
    _wanted = true;
    _restartTimer();
    notifyListeners();
  }

  void hide() {
    if (!_wanted) return;
    _wanted = false;
    _hideTimer?.cancel();
    _hideTimer = null;
    notifyListeners();
  }

  void activate() {
    if (!eligible) return;
    if (!visible) {
      reveal();
    } else {
      skip();
    }
  }

  void skip() {
    if (!visible || _skipping) return;
    _skipping = true;
    _hideTimer?.cancel();
    _hideTimer = null;
    final ticket = _generation;
    notifyListeners();
    unawaited(
      Future<void>.sync(_onSkip).catchError((Object _) {}).whenComplete(() {
        // An old Skip completion must not change the next pre-roll.
        if (ticket != _generation) return;
        _skipping = false;
        _restartTimer();
        notifyListeners();
      }),
    );
  }

  void _restartTimer() {
    _hideTimer?.cancel();
    _hideTimer = null;
    if (!visible || !_playing || _autoHideSeconds <= 0) return;
    _hideTimer = Timer(Duration(seconds: _autoHideSeconds), hide);
  }

  @override
  void dispose() {
    ++_generation;
    _hideTimer?.cancel();
    super.dispose();
  }
}
