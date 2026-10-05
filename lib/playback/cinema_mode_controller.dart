import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/repositories/seerr_repository.dart';
import '../data/services/cinema_movie_resolver.dart';
import '../data/services/seerr/seerr_api_models.dart';

enum CinemaAction { skip, request }

enum CinemaSeerrState {
  hidden,
  request,
  requesting,
  requested,
  pending,
  processing,
  partiallyAvailable,
  available,
}

/// Media and request status codes are different enums. Only standard movie
/// requests count here, because this action always requests the standard edition.
CinemaSeerrState cinemaSeerrState({
  int? mediaStatus,
  List<SeerrRequest>? requests,
  required bool canRequest,
  bool acknowledged = false,
}) {
  if (!canRequest || mediaStatus == SeerrMediaStatus.blocklisted) {
    return CinemaSeerrState.hidden;
  }
  switch (mediaStatus) {
    case SeerrMediaStatus.pending:
      return CinemaSeerrState.pending;
    case SeerrMediaStatus.processing:
      return CinemaSeerrState.processing;
    case SeerrMediaStatus.partiallyAvailable:
      return CinemaSeerrState.partiallyAvailable;
    case SeerrMediaStatus.available:
      return CinemaSeerrState.available;
  }
  final active =
      requests?.any(
        (r) =>
            !r.is4k &&
            r.type == 'movie' &&
            (r.status == SeerrRequest.statusPending ||
                r.status == SeerrRequest.statusApproved),
      ) ??
      false;
  if (acknowledged || active) return CinemaSeerrState.requested;
  return mediaStatus == null ||
          mediaStatus == SeerrMediaStatus.unknown ||
          mediaStatus == SeerrMediaStatus.deleted
      ? CinemaSeerrState.request
      : CinemaSeerrState.hidden;
}

/// One lifetime/visibility/input model for TV, touch and desktop. Network work
/// never participates in opening or advancing playback.
class CinemaModeController extends ChangeNotifier {
  CinemaModeController({
    required this._seerr,
    required this._accountKey,
    required this._onSkip,
    required this._onError,
  });

  final Future<SeerrRepository> Function() _seerr;
  SeerrRepository? _requestRepository;
  final Object Function() _accountKey;
  final Future<void> Function() _onSkip;
  final void Function(Object) _onError;
  int _generation = 0;
  Object? _account;
  bool _disposed = false;
  bool _active = false;
  bool _wanted = false;
  bool _playing = false;
  bool _skipping = false;
  bool _sending = false;
  Duration? _metadataDuration;
  Duration? _playerDuration;
  int _minimumSeconds = 15;
  int _autoHideSeconds = 10;
  Timer? _hideTimer;
  DateTime? _lastSkip;

  int? movieId;
  CinemaSeerrState seerrState = CinemaSeerrState.hidden;
  CinemaAction focusedAction = CinemaAction.skip;
  Duration get duration =>
      _metadataDuration ?? _playerDuration ?? Duration.zero;
  bool get eligible =>
      _active &&
      (_minimumSeconds == 0 || duration >= Duration(seconds: _minimumSeconds));
  bool get visible =>
      eligible && _wanted && !_skipping && _account == _accountKey();
  bool get canRequest =>
      visible && seerrState == CinemaSeerrState.request && !_sending;
  int get generation => _generation;

  void enter({
    required Map<String, dynamic>? item,
    required Future<int?> Function() resolveMovie,
    bool allowSeerr = true,
  }) {
    final ticket = ++_generation;
    _hideTimer?.cancel();
    _hideTimer = null;
    _account = _accountKey();
    _active = item != null;
    _wanted = _active;
    _playing = _skipping = _sending = false;
    _metadataDuration = _playerDuration = null;
    movieId = item == null ? null : CinemaMovieResolver.directMovieId(item);
    seerrState = CinemaSeerrState.hidden;
    _requestRepository = null;
    focusedAction = CinemaAction.skip;
    final ticks = int.tryParse(item?['RunTimeTicks']?.toString() ?? '');
    if (ticks != null && ticks > 0) {
      _metadataDuration = Duration(microseconds: ticks ~/ 10);
    }
    notifyListeners();
    if (_active) unawaited(_load(ticket, resolveMovie, allowSeerr));
  }

  bool _current(int ticket) =>
      !_disposed &&
      ticket == _generation &&
      _active &&
      _account == _accountKey();

  Future<void> _load(
    int ticket,
    Future<int?> Function() resolveMovie,
    bool allowSeerr,
  ) async {
    try {
      final id =
          movieId ?? await resolveMovie().timeout(const Duration(seconds: 10));
      if (!_current(ticket) || id == null || id <= 0) return;
      movieId = id;
      notifyListeners();
      if (!allowSeerr) return;
      final repository = await _seerr().timeout(const Duration(seconds: 10));
      if (!_current(ticket)) return;
      await repository.ensureInitialized().timeout(const Duration(seconds: 10));
      if (!_current(ticket) || !repository.isAvailable) return;
      final user = await repository.getCurrentUser().timeout(
        const Duration(seconds: 10),
      );
      if (!_current(ticket)) return;
      final permitted =
          user.hasPermission(SeerrPermission.request) ||
          user.hasPermission(SeerrPermission.requestMovie);
      if (!permitted) return;
      final details = await repository
          .getMovieDetails(id)
          .timeout(const Duration(seconds: 10));
      if (!_current(ticket)) return;
      _requestRepository = repository;
      seerrState = cinemaSeerrState(
        mediaStatus: details.mediaInfo?.status,
        requests: details.mediaInfo?.requests,
        canRequest: permitted,
      );
      notifyListeners();
    } catch (_) {
      // Optional identity/status lookup failures leave playback and Skip alone.
    }
  }

  void configure({required int minimumSeconds, required int autoHideSeconds}) {
    final minimum = minimumSeconds.clamp(0, 60);
    if (_minimumSeconds == minimum && _autoHideSeconds == autoHideSeconds) {
      return;
    }
    _minimumSeconds = minimum;
    _autoHideSeconds = autoHideSeconds;
    _restartTimer();
    notifyListeners();
  }

  /// Call only with a duration and playing state belonging to this queue item.
  void updatePlayback({required Duration duration, required bool playing}) {
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

  void reveal() {
    if (!eligible || _skipping || _account != _accountKey()) return;
    if (visible) return;
    _wanted = true;
    focusedAction = CinemaAction.skip;
    _restartTimer();
    notifyListeners();
  }

  void hide() {
    _wanted = false;
    _hideTimer?.cancel();
    _hideTimer = null;
    focusedAction = CinemaAction.skip;
    notifyListeners();
  }

  void moveLeft() {
    if (!visible) return;
    if (canRequest) focusedAction = CinemaAction.request;
    _restartTimer();
    notifyListeners();
  }

  void moveRight() {
    if (!visible) return;
    focusedAction = CinemaAction.skip;
    _restartTimer();
    notifyListeners();
  }

  void activate() {
    if (!visible) {
      reveal();
      return;
    }
    if (focusedAction == CinemaAction.request) {
      unawaited(request());
    } else {
      skip();
    }
  }

  void skip() {
    // Also used by the dedicated fast-forward key, which may skip a short intro.
    if (!_active || _skipping || _account != _accountKey()) return;
    final now = DateTime.now();
    if (_lastSkip != null &&
        now.difference(_lastSkip!) < const Duration(milliseconds: 400)) {
      return;
    }
    _lastSkip = now;
    _skipping = true;
    _hideTimer?.cancel();
    _hideTimer = null;
    final ticket = _generation;
    notifyListeners();
    unawaited(
      _onSkip().catchError((Object error) {
        if (!_current(ticket)) return;
        _skipping = false;
        _onError(error);
        _restartTimer();
        notifyListeners();
      }),
    );
  }

  Future<void> request() async {
    final repository = _requestRepository;
    if (!canRequest || movieId == null || repository == null) return;
    final ticket = _generation;
    final id = movieId!;
    _sending = true;
    seerrState = CinemaSeerrState.requesting;
    focusedAction = CinemaAction.skip;
    _restartTimer();
    notifyListeners();
    try {
      final response = await repository
          .createRequest(mediaId: id, mediaType: 'movie', is4k: false)
          .timeout(const Duration(seconds: 20));
      if (!_current(ticket)) return;
      seerrState = cinemaSeerrState(
        mediaStatus: response.media?.status,
        canRequest: true,
        acknowledged: true,
      );
    } catch (error) {
      if (!_current(ticket)) return;
      // A timeout can mean the server accepted the request. Reconcile once
      // before offering a retry, and never automatically submit it again.
      seerrState = CinemaSeerrState.hidden;
      try {
        final details = await repository
            .getMovieDetails(id)
            .timeout(const Duration(seconds: 10));
        if (!_current(ticket)) return;
        seerrState = cinemaSeerrState(
          mediaStatus: details.mediaInfo?.status,
          requests: details.mediaInfo?.requests,
          canRequest: true,
        );
      } catch (_) {
        /* Uncertain outcome: don't offer another request. */
      }
      if (_current(ticket)) _onError(error);
    } finally {
      if (_current(ticket)) {
        _sending = false;
        _restartTimer();
        notifyListeners();
      }
    }
  }

  void _restartTimer() {
    _hideTimer?.cancel();
    _hideTimer = null;
    if (!visible || !_playing || _sending || _autoHideSeconds <= 0) return;
    _hideTimer = Timer(Duration(seconds: _autoHideSeconds), hide);
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    _hideTimer?.cancel();
    super.dispose();
  }
}
