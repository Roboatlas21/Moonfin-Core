import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:server_core/server_core.dart';

import '../data/repositories/seerr_repository.dart';
import '../data/services/cinema_movie_resolver.dart';
import '../data/services/log_service.dart';
import '../data/services/seerr/seerr_api_models.dart';
import '../data/viewmodels/seerr_media_detail_view_model.dart';

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

Set<int> cinemaRequestableSeasons(SeerrTvDetails details) {
  final quality = SeerrQualityStatus.of(
    is4k: false,
    mediaInfo: details.mediaInfo,
    canManageRequests: false,
    currentUserId: null,
  );
  final reported = details.seasons
      .where((s) => s.seasonNumber > 0)
      .map((s) => s.seasonNumber)
      .toSet();
  final seasons = reported.isNotEmpty
      ? reported
      : {for (var i = 1; i <= (details.numberOfSeasons ?? 0); i++) i};
  return seasons.difference(quality.unavailableOrRequestedSeasons);
}

CinemaSeerrState cinemaTvSeerrState(SeerrTvDetails details) {
  final status = details.mediaInfo?.status;
  if (status == SeerrMediaStatus.blocklisted ||
      (status != null && !{0, 1, 2, 3, 4, 5, 7}.contains(status))) {
    return CinemaSeerrState.hidden;
  }
  // An in-flight or partly available series can still have other seasons to ask for.
  if (status != SeerrMediaStatus.available &&
      cinemaRequestableSeasons(details).isNotEmpty) {
    return CinemaSeerrState.request;
  }
  final state = cinemaSeerrState(
    mediaStatus: status,
    canRequest: true,
    acknowledged:
        details.mediaInfo?.requests?.any(
          (r) =>
              !r.is4k &&
              r.type == 'tv' &&
              (r.status == SeerrRequest.statusPending ||
                  r.status == SeerrRequest.statusApproved),
        ) ??
        false,
  );
  return state == CinemaSeerrState.request ? CinemaSeerrState.hidden : state;
}

/// One lifetime/visibility/input model for TV, touch and desktop. Network work
/// never participates in opening or advancing playback.
class CinemaModeController extends ChangeNotifier {
  CinemaModeController({
    required this._seerr,
    required this._accountKey,
    required this._onSkip,
    required this._onError,
    this.onRequestSeries,
  });

  final Future<SeerrRepository> Function() _seerr;
  SeerrRepository? _requestRepository;
  final Object Function() _accountKey;
  final Future<void> Function() _onSkip;
  final void Function(Object) _onError;
  final Future<void> Function(
    SeerrRepository repository,
    SeerrTvDetails details,
    SeerrUser user,
    int? season,
    bool Function() isCurrent,
  )?
  onRequestSeries;
  SeerrTvDetails? _tvDetails;
  SeerrUser? _user;
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

  CinemaMedia? media;
  bool get isSeries => media?.type == CinemaMediaType.tv;
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
    required Future<CinemaMedia?> Function() resolveMedia,
  }) {
    final ticket = ++_generation;
    _hideTimer?.cancel();
    _hideTimer = null;
    _account = _accountKey();
    _active = item != null;
    _wanted = _active;
    _playing = _skipping = _sending = false;
    _metadataDuration = _playerDuration = null;
    media = item == null ? null : CinemaMovieResolver.directMedia(item);
    _tvDetails = null;
    _user = null;
    seerrState = CinemaSeerrState.hidden;
    _requestRepository = null;
    focusedAction = CinemaAction.skip;
    final ticks = int.tryParse(item?['RunTimeTicks']?.toString() ?? '');
    if (ticks != null && ticks > 0) {
      _metadataDuration = Duration(microseconds: ticks ~/ 10);
    }
    notifyListeners();
    if (_active) unawaited(_load(ticket, resolveMedia));
  }

  bool _current(int ticket) =>
      !_disposed &&
      ticket == _generation &&
      _active &&
      _account == _accountKey();

  Future<void> _load(
    int ticket,
    Future<CinemaMedia?> Function() resolveMedia,
  ) async {
    // TEMP: trace the missing Seerr action without changing lookup behavior.
    final clock = Stopwatch()..start();
    var stage = 'resolve_media';
    void trace(String message) {
      if (!GetIt.instance.isRegistered<LogService>()) return;
      GetIt.instance<LogService>().seerr(
        '[CinemaSeerr] lookup=$ticket stage=$stage '
        'elapsedMs=${clock.elapsedMilliseconds} $message',
        level: LogLevel.info,
      );
    }

    bool current() {
      if (_current(ticket)) return true;
      final reason = _disposed
          ? 'disposed'
          : ticket != _generation
          ? 'trailer_changed'
          : !_active
          ? 'inactive'
          : 'account_changed';
      trace('result=discarded reason=$reason');
      return false;
    }

    try {
      trace(
        'start directTmdb=${media?.tmdbId ?? 'none'} '
        'durationSeconds=${duration.inSeconds} minimumSeconds=$_minimumSeconds',
      );
      final resolved =
          media ?? await resolveMedia().timeout(const Duration(seconds: 10));
      if (!current()) return;
      if (resolved == null || resolved.tmdbId <= 0) {
        trace('result=hidden reason=no_typed_id');
        return;
      }
      final id = resolved.tmdbId;
      trace('resolvedTmdb=$id type=${resolved.type.name}');
      media = resolved;
      notifyListeners();
      stage = 'repository';
      trace('start');
      final repository = await _seerr().timeout(const Duration(seconds: 10));
      if (!current()) return;
      stage = 'initialize';
      trace('start');
      await repository.ensureInitialized().timeout(const Duration(seconds: 10));
      if (!current()) return;
      final serviceAvailable = repository.isAvailable;
      trace('serviceAvailable=$serviceAvailable');
      if (!serviceAvailable) {
        trace('result=hidden reason=service_unavailable');
        return;
      }
      stage = 'current_user';
      trace('start');
      final user = await repository.getCurrentUser().timeout(
        const Duration(seconds: 10),
      );
      if (!current()) return;
      final permitted =
          user.hasPermission(SeerrPermission.request) ||
          user.hasPermission(
            isSeries ? SeerrPermission.requestTv : SeerrPermission.requestMovie,
          );
      trace('success canRequest=$permitted');
      if (!permitted) {
        trace('result=hidden reason=media_permission_denied');
        return;
      }
      _user = user;
      if (isSeries) {
        if (onRequestSeries == null) return;
        stage = 'tv_details';
        final details = await repository
            .getTvDetails(id)
            .timeout(const Duration(seconds: 10));
        if (!current() || details.id != id) return;
        _tvDetails = details;
        _requestRepository = repository;
        seerrState = cinemaTvSeerrState(details);
        trace('success result=${seerrState.name}');
        notifyListeners();
        return;
      }
      stage = 'movie_details';
      trace('start tmdb=$id');
      final details = await repository
          .getMovieDetails(id)
          .timeout(const Duration(seconds: 10));
      if (!current()) return;
      _requestRepository = repository;
      seerrState = cinemaSeerrState(
        mediaStatus: details.mediaInfo?.status,
        requests: details.mediaInfo?.requests,
        canRequest: permitted,
      );
      final requestStatuses =
          details.mediaInfo?.requests
              ?.where((r) => !r.is4k && r.type == 'movie')
              .map((r) => r.status)
              .join(',') ??
          '';
      final reason = seerrState == CinemaSeerrState.hidden
          ? 'blocked_or_unsupported_media_status'
          : 'status_mapped';
      trace(
        'success mediaStatus=${details.mediaInfo?.status ?? 'none'} '
        'standardMovieRequestStatuses=[$requestStatuses] '
        'result=${seerrState.name} overlayVisible=$visible '
        'eligible=$eligible wanted=$_wanted skipping=$_skipping '
        'reason=$reason',
      );
      notifyListeners();
    } catch (error) {
      // Optional identity/status lookup failures leave playback and Skip alone.
      // Never stringify errors: URLs, headers and response bodies may be private.
      final httpError = error is DioException
          ? ' dioType=${error.type.name} '
                'httpStatus=${error.response?.statusCode ?? 'none'}'
          : '';
      trace(
        'result=lookup_failed errorType=${error.runtimeType} '
        'timeout=${error is TimeoutException}$httpError',
      );
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
    if (!canRequest || media == null || repository == null) return;
    final ticket = _generation;
    final id = media!.tmdbId;
    if (isSeries) {
      await _requestSeries(repository, ticket, id);
      return;
    }
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

  Future<void> _requestSeries(
    SeerrRepository repository,
    int ticket,
    int id,
  ) async {
    final details = _tvDetails;
    final user = _user;
    if (details == null || user == null || onRequestSeries == null) return;
    _sending = true;
    focusedAction = CinemaAction.skip;
    _restartTimer();
    notifyListeners();
    try {
      final seasons = cinemaRequestableSeasons(details);
      final season = seasons.contains(media?.season) ? media?.season : null;
      await onRequestSeries!(
        repository,
        details,
        user,
        season,
        () => _current(ticket) && !_skipping,
      );
      if (!_current(ticket)) return;
      // Cancel and submit both refresh; another user may have requested a season.
      seerrState = CinemaSeerrState.hidden;
      final refreshed = await repository
          .getTvDetails(id)
          .timeout(const Duration(seconds: 10));
      if (!_current(ticket) || refreshed.id != id) return;
      _tvDetails = refreshed;
      seerrState = cinemaTvSeerrState(refreshed);
    } catch (error) {
      if (!_current(ticket)) return;
      seerrState = CinemaSeerrState.hidden;
      _onError(error);
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
