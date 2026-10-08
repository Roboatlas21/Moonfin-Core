import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:moonfin/data/services/seerr/seerr_seasons.dart';
import 'package:server_core/server_core.dart';

import '../data/repositories/seerr_repository.dart';
import '../data/services/cinema_media_resolver.dart';
import '../data/services/seerr/seerr_api_models.dart';

enum CinemaAction { skip, request }

bool _activeRequest(SeerrRequest request, String type, bool is4k) =>
    request.is4k == is4k &&
    request.type == type &&
    (request.status == SeerrRequest.statusPending ||
        request.status == SeerrRequest.statusApproved);

enum CinemaSeerrState {
  hidden,
  request,
  requested,
  pending,
  processing,
  partiallyAvailable,
  available,
}

/// Both Flutter and Apple TV use this callback to submit the seasons the user selected.
typedef CinemaTvSubmit = Future<SeerrTvDetails?> Function(
  Map<String, dynamic> selection,
  SeerrQuotaDetail? quota,
  bool Function() isAllowed,
);

/// Seerr reports availability and requests separately for standard and 4K.
CinemaSeerrState cinemaSeerrState({
  int? mediaStatus,
  List<SeerrRequest>? requests,
  bool is4k = false,
  bool acknowledged = false,
}) => switch (mediaStatus) {
  SeerrMediaStatus.blocklisted => CinemaSeerrState.hidden,
  SeerrMediaStatus.pending => CinemaSeerrState.pending,
  SeerrMediaStatus.processing => CinemaSeerrState.processing,
  SeerrMediaStatus.partiallyAvailable => CinemaSeerrState.partiallyAvailable,
  SeerrMediaStatus.available => CinemaSeerrState.available,
  _ when acknowledged ||
      (requests?.any((r) => _activeRequest(r, 'movie', is4k)) ?? false) =>
    CinemaSeerrState.requested,
  null || SeerrMediaStatus.unknown || SeerrMediaStatus.deleted =>
    CinemaSeerrState.request,
  _ => CinemaSeerrState.hidden,
};

/// Check that the selected seasons can be requested. Keep "All Seasons" as its own option
/// instead of turning it into a list.
({bool allSeasons, List<int>? seasons})? cinemaTvRequestSelection(
  Map<String, dynamic> raw,
  Set<int> requestableSeasons,
  SeerrQuotaDetail? quota,
) {
  final allSeasons = raw['allSeasons'];
  final nativeSeasons = raw['seasons'];
  if (allSeasons is! bool ||
      nativeSeasons is! List ||
      nativeSeasons.any((value) => value is! int)) {
    return null;
  }
  final selected = nativeSeasons.cast<int>().toSet();
  if (requestableSeasons.isEmpty ||
      (allSeasons && selected.isNotEmpty) ||
      (!allSeasons && selected.isEmpty) ||
      !requestableSeasons.containsAll(selected) ||
      seerrQuotaBlocked(
        quota,
        seerrTvQuotaNeeded(
          allSeasons: allSeasons,
          requestableSeasons: requestableSeasons,
          selectedSeasons: selected,
        ),
      )) {
    return null;
  }
  return (
    allSeasons: allSeasons,
    seasons: allSeasons ? null : (selected.toList()..sort()),
  );
}

Set<int> cinemaRequestableSeasons(
  SeerrTvDetails details, {
  bool is4k = false,
}) =>
    seerrSeasonNumbersOf(details.seasons, details.numberOfSeasons ?? 0)
        .toSet()
        .difference(seerrUnavailableOrRequestedSeasons(
          details.mediaInfo,
          is4k: is4k,
        ));

bool cinemaSeriesIsContinuing(SeerrTvDetails details) {
  final status = (details.status ?? '').toLowerCase();
  return status.isNotEmpty && status != 'ended' && status != 'canceled';
}

CinemaSeerrState cinemaTvSeerrState(
  SeerrTvDetails details, {
  bool is4k = false,
  Set<int> excludedSeasons = const {},
}) {
  final status = is4k
      ? details.mediaInfo?.status4k
      : details.mediaInfo?.status;
  if (status == SeerrMediaStatus.blocklisted ||
      (status != null && !{0, 1, 2, 3, 4, 5, 7}.contains(status))) {
    return CinemaSeerrState.hidden;
  }
  // A show marked available may still have a new season. Show Request only when another season
  // can be requested.
  if ((status != SeerrMediaStatus.available ||
          cinemaSeriesIsContinuing(details)) &&
      cinemaRequestableSeasons(details, is4k: is4k)
          .difference(excludedSeasons)
          .isNotEmpty) {
    return CinemaSeerrState.request;
  }
  final acknowledged = details.mediaInfo?.requests?.any(
        (r) => _activeRequest(r, 'tv', is4k),
      ) ?? false;
  // Seerr may still say "partially available" after accepting the selected seasons.
  if (status == SeerrMediaStatus.partiallyAvailable &&
      (acknowledged || excludedSeasons.isNotEmpty)) {
    return CinemaSeerrState.requested;
  }
  final state = cinemaSeerrState(
    mediaStatus: status,
    is4k: is4k,
    acknowledged: acknowledged,
  );
  if (state != CinemaSeerrState.request) return state;
  return excludedSeasons.isNotEmpty
      ? CinemaSeerrState.requested
      : CinemaSeerrState.hidden;
}

/// Submit a valid TV request once. If it times out, check those specific seasons before
/// deciding whether it succeeded.
Future<({Set<int> seasons, SeerrTvDetails? confirmed})?> submitCinemaTvRequest({
  required SeerrRepository repository,
  required SeerrTvDetails details,
  required Map<String, dynamic> selection,
  required SeerrQuotaDetail? quota,
  required bool Function() isAllowed,
  Set<int> excludedSeasons = const {},
  Set<int> excluded4kSeasons = const {},
  bool allowStandard = true,
  bool allow4k = false,
}) async {
  if (!isAllowed()) return null;
  if (selection['is4k'] != null && selection['is4k'] is! bool) return null;
  final is4k = selection['is4k'] == true;
  if (is4k ? !allow4k : !allowStandard) return null;
  final excluded = is4k ? excluded4kSeasons : excludedSeasons;
  final requestable = cinemaRequestableSeasons(details, is4k: is4k)
      .difference(excluded);
  final choice = cinemaTvRequestSelection(selection, requestable, quota);
  // Reject invalid or outdated choices, especially "All Seasons" while an earlier request may
  // still be processing.
  if (choice == null || (choice.allSeasons && excluded.isNotEmpty)) {
    return null;
  }
  final expected = choice.allSeasons ? requestable : choice.seasons!.toSet();
  try {
    await repository.createRequest(
      mediaId: details.id,
      mediaType: 'tv',
      seasons: choice.seasons,
      allSeasons: choice.allSeasons,
      is4k: is4k,
    ).timeout(const Duration(seconds: 20));
  } on TimeoutException {
    // A timeout does not mean Seerr rejected the request. Check the result instead of sending
    // it twice.
    if (!isAllowed()) return null;
    try {
      final refreshed = await repository.getTvDetails(details.id)
          .timeout(const Duration(seconds: 10));
      if (!isAllowed()) return null;
      if (refreshed.id == details.id &&
          seerrUnavailableOrRequestedSeasons(
            refreshed.mediaInfo,
            is4k: is4k,
          ).containsAll(expected)) {
        return (seasons: expected, confirmed: refreshed);
      }
    } catch (_) {
      // If the status check also fails, leave the result uncertain and do not resend the
      // request.
    }
    if (!isAllowed()) return null;
    rethrow;
  } catch (_) {
    if (!isAllowed()) return null;
    rethrow;
  }
  return (seasons: expected, confirmed: null);
}

typedef CinemaTvQualityOptions = ({
  bool standard,
  bool fourK,
  Set<int> excludedStandard,
  Set<int> excluded4k,
});

/// Shows a quality picker only when both movie qualities can be requested.
typedef CinemaMovieSubmit = Future<void> Function(
  bool is4k,
  bool Function() isAllowed,
);

/// Manages when trailer actions appear and how they respond across devices. Seerr checks must
/// never delay playback.
class CinemaModeController extends ChangeNotifier {
  CinemaModeController({
    required this._seerr,
    required this._accountKey,
    required this._onSkip,
    this.onRequestSeries,
    this.onRequestMovie,
  });

  final Future<SeerrRepository> Function() _seerr;
  SeerrRepository? _requestRepository;
  final Object Function() _accountKey;
  final Future<void> Function() _onSkip;

  /// Returns refreshed TV show details if a timed-out request was confirmed.
  final Future<SeerrTvDetails?> Function(
    SeerrRepository repository,
    SeerrTvDetails details,
    SeerrUser user,
    CinemaTvQualityOptions options,
    bool Function() isCurrent,
    CinemaTvSubmit submit,
  )?
  onRequestSeries;
  final Future<void> Function(
    SeerrRepository repository,
    SeerrMovieDetails details,
    SeerrUser user,
    bool Function() isCurrent,
    CinemaMovieSubmit submit,
  )? onRequestMovie;

  SeerrTvDetails? _tvDetails;
  SeerrMovieDetails? _movieDetails;
  SeerrUser? _user;
  bool _allowStandard = false;
  bool _allow4k = false;
  bool _requestableStandard = false;
  bool _requestable4k = false;
  final Set<bool> _submittedMovieQualities = {};
  final Map<bool, Set<int>> _submittedTvSeasons = {
    false: <int>{},
    true: <int>{},
  };
  int _generation = 0;
  Object? _account;
  bool _active = false;
  bool _wanted = false;
  bool _playing = false;
  bool _skipping = false;
  bool _sending = false;
  Duration? _metadataDuration;
  Duration? _playerDuration;
  int _minimumSeconds = 15;
  int _autoHideSeconds = 15;
  Timer? _hideTimer;
  DateTime? _lastSkip;

  CinemaMedia? media;
  bool get isSeries => media?.type == CinemaMediaType.tv;
  bool get only4kRequestable => !_requestableStandard && _requestable4k;

  bool get isTvRequestMore {
    final is4k = only4kRequestable;
    final info = _tvDetails?.mediaInfo;
    return _submittedTvSeasons[is4k]!.isNotEmpty ||
        SeerrMediaStatus.isAvailable(is4k ? info?.status4k : info?.status) ||
        (info?.requests?.any((r) => _activeRequest(r, 'tv', is4k)) ?? false);
  }
  CinemaSeerrState seerrState = CinemaSeerrState.hidden;
  CinemaAction focusedAction = CinemaAction.skip;
  Duration get duration =>
      _playerDuration ?? _metadataDuration ?? Duration.zero;
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
    _active = item != null;
    _account = _active ? _accountKey() : null;
    _wanted = _active;
    _playing = _skipping = _sending = false;
    _metadataDuration = _playerDuration = null;
    media = item == null ? null : CinemaMediaResolver.directMedia(item);
    _tvDetails = null;
    _movieDetails = null;
    _user = null;
    _allowStandard = _allow4k = false;
    _requestableStandard = _requestable4k = false;
    _submittedMovieQualities.clear();
    for (final seasons in _submittedTvSeasons.values) {
      seasons.clear();
    }
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
      ticket == _generation &&
      _active &&
      _account == _accountKey();

  Future<void> _load(
    int ticket,
    Future<CinemaMedia?> Function() resolveMedia,
  ) async {
    try {
      final resolved = media ?? await resolveMedia();
      if (!_current(ticket) || resolved == null || resolved.tmdbId <= 0) return;
      final id = resolved.tmdbId;
      media = resolved;
      notifyListeners();
      final repository = await _seerr().timeout(const Duration(seconds: 10));
      if (!_current(ticket)) return;
      await repository.ensureInitialized().timeout(const Duration(seconds: 10));
      if (!_current(ticket) || !repository.isAvailable) return;
      final user = await repository.getCurrentUser().timeout(
        const Duration(seconds: 10),
      );
      if (!_current(ticket)) return;
      _allowStandard =
          user.hasPermission(SeerrPermission.request) ||
          user.hasPermission(
            isSeries ? SeerrPermission.requestTv : SeerrPermission.requestMovie,
          );
      _allow4k = isSeries ? user.canRequest4kTv : user.canRequest4kMovies;
      if (!_allowStandard && !_allow4k) return;
      _user = user;
      if (isSeries && onRequestSeries == null) return;

      if (_allow4k) {
        try {
          final settings = await repository
              .getPublicSettings()
              .timeout(const Duration(seconds: 5));
          if (!_current(ticket)) return;
          final flag = isSeries ? 'series4kEnabled' : 'movie4kEnabled';
          if (settings.containsKey(flag)) _allow4k = settings[flag] == true;
        } catch (_) {
          // Like upstream Seerr, keep permission-based 4K access if settings are unavailable.
        }
      }
      if (!_allowStandard && !_allow4k) return;
      if (await _refreshStatus(repository, ticket, id)) {
        _requestRepository = repository;
        notifyListeners();
      }
    } catch (_) {
      // If Seerr cannot identify the trailer or load its status, playback and Skip still work.
    }
  }

  /// Refresh the request status, reusing TV details already fetched by the picker when
  /// possible.
  Future<bool> _refreshStatus(
    SeerrRepository repository,
    int ticket,
    int id, {
    SeerrTvDetails? confirmedTv,
  }) async {
    if (isSeries) {
      final tv =
          confirmedTv ??
          await repository
              .getTvDetails(id)
              .timeout(const Duration(seconds: 10));
      if (!_current(ticket) || tv.id != id) return false;
      _tvDetails = tv;
      _updateTvState(tv);
    } else {
      final movie = await repository
          .getMovieDetails(id)
          .timeout(const Duration(seconds: 10));
      if (!_current(ticket) || movie.id != id) return false;
      _movieDetails = movie;
      _updateMovieState(movie.mediaInfo);
    }
    return true;
  }

  CinemaSeerrState _statusWhenNotRequestable(
    CinemaSeerrState standard,
    CinemaSeerrState fourK,
  ) {
    final states = [
      if (_allowStandard) standard,
      if (_allow4k) fourK,
    ];
    for (final status in [
      CinemaSeerrState.available,
      CinemaSeerrState.partiallyAvailable,
      CinemaSeerrState.processing,
      CinemaSeerrState.pending,
      CinemaSeerrState.requested,
    ]) {
      if (states.contains(status)) return status;
    }
    return CinemaSeerrState.hidden;
  }

  void _updateMovieState(SeerrMediaInfo? info) {
    final standard = cinemaSeerrState(
      mediaStatus: info?.status,
      requests: info?.requests,
    );
    final fourK = cinemaSeerrState(
      mediaStatus: info?.status4k,
      requests: info?.requests,
      is4k: true,
    );
    final blocked = info?.status == SeerrMediaStatus.blocklisted ||
        info?.status4k == SeerrMediaStatus.blocklisted;
    _requestableStandard = !blocked &&
        _allowStandard &&
        standard == CinemaSeerrState.request &&
        !_submittedMovieQualities.contains(false);
    _requestable4k = !blocked &&
        _allow4k &&
        fourK == CinemaSeerrState.request &&
        !_submittedMovieQualities.contains(true);
    seerrState = _requestableStandard || _requestable4k
        ? CinemaSeerrState.request
        : _submittedMovieQualities.isNotEmpty
            ? CinemaSeerrState.requested
            : _statusWhenNotRequestable(standard, fourK);
  }

  void _updateTvState(SeerrTvDetails details) {
    final standard = cinemaTvSeerrState(
      details,
      excludedSeasons: _submittedTvSeasons[false]!,
    );
    final fourK = cinemaTvSeerrState(
      details,
      is4k: true,
      excludedSeasons: _submittedTvSeasons[true]!,
    );
    final blocked = details.mediaInfo?.status == SeerrMediaStatus.blocklisted ||
        details.mediaInfo?.status4k == SeerrMediaStatus.blocklisted;
    _requestableStandard =
        !blocked && _allowStandard && standard == CinemaSeerrState.request;
    _requestable4k =
        !blocked && _allow4k && fourK == CinemaSeerrState.request;
    seerrState = _requestableStandard || _requestable4k
        ? CinemaSeerrState.request
        : _submittedTvSeasons.values.any((seasons) => seasons.isNotEmpty)
            ? CinemaSeerrState.requested
            : _statusWhenNotRequestable(standard, fourK);
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

  /// Only pass playback information for the current trailer, not the previous one.
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
    if (visible) {
      _restartTimer();
      return;
    }
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

  void moveLeft() =>
      _moveFocus(canRequest ? CinemaAction.request : CinemaAction.skip);

  void moveRight() => _moveFocus(CinemaAction.skip);

  void _moveFocus(CinemaAction action) {
    if (!visible) return;
    focusedAction = action;
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
      _onSkip().catchError((Object _) {
        if (!_current(ticket)) return;
        _skipping = false;
        _restartTimer();
        notifyListeners();
      }),
    );
  }

  void _setSending(bool sending) {
    _sending = sending;
    if (sending) focusedAction = CinemaAction.skip;
    _restartTimer();
    notifyListeners();
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
    _setSending(true);
    try {
      final isAllowed = () => _current(ticket) && !_skipping;
      if (_requestableStandard && _requestable4k) {
        final details = _movieDetails;
        final user = _user;
        if (details != null && user != null && onRequestMovie != null) {
          await onRequestMovie!(
            repository,
            details,
            user,
            isAllowed,
            (is4k, maySubmit) =>
                _submitMovie(repository, ticket, id, is4k, maySubmit),
          );
        }
      } else {
        await _submitMovie(
          repository,
          ticket,
          id,
          _requestable4k,
          isAllowed,
        );
      }
    } catch (_) {
      // A picker failure should not affect playback or Skip.
    } finally {
      if (_current(ticket)) _setSending(false);
    }
  }

  Future<void> _submitMovie(
    SeerrRepository repository,
    int ticket,
    int id,
    bool is4k,
    bool Function() isAllowed,
  ) async {
    if (!isAllowed() || !(is4k ? _requestable4k : _requestableStandard)) {
      return;
    }
    _submittedMovieQualities.add(is4k);
    _updateMovieState(_movieDetails?.mediaInfo);
    try {
      await repository
          .createRequest(mediaId: id, mediaType: 'movie', is4k: is4k)
          .timeout(const Duration(seconds: 20));
      if (!_current(ticket)) return;
      _updateMovieState(_movieDetails?.mediaInfo);
    } catch (_) {
      if (!_current(ticket)) return;
      // An error or timeout does not prove Seerr rejected the request.
      // Refresh once without resubmitting the same quality.
      try {
        if (!await _refreshStatus(repository, ticket, id)) return;
      } catch (_) {}
      if (!_requestableStandard && !_requestable4k) {
        seerrState = CinemaSeerrState.hidden;
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
    var acknowledged = false;
    _setSending(true);
    try {
      final options = (
        standard: _requestableStandard,
        fourK: _requestable4k,
        excludedStandard: Set<int>.of(_submittedTvSeasons[false]!),
        excluded4k: Set<int>.of(_submittedTvSeasons[true]!),
      );
      final confirmed = await onRequestSeries!(
        repository,
        details,
        user,
        options,
        () => _current(ticket) && !_skipping,
        (selection, quota, isAllowed) async {
          final result = await submitCinemaTvRequest(
            repository: repository,
            details: details,
            selection: selection,
            quota: quota,
            isAllowed: isAllowed,
            excludedSeasons: options.excludedStandard,
            excluded4kSeasons: options.excluded4k,
            allowStandard: options.standard,
            allow4k: options.fourK,
          );
          if (_current(ticket) && isAllowed() && result != null) {
            _submittedTvSeasons[selection['is4k'] == true]!
                .addAll(result.seasons);
            acknowledged = true;
          }
          return result?.confirmed;
        },
      );
      // A cancelled picker does not change availability.
      if (!_current(ticket) || !acknowledged) return;
      _updateTvState(details);
      try {
        await _refreshStatus(repository, ticket, id, confirmedTv: confirmed);
      } catch (_) {}
    } catch (_) {
      if (!_current(ticket)) return;
      seerrState = CinemaSeerrState.hidden;
    } finally {
      if (_current(ticket)) _setSending(false);
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
    ++_generation;
    _hideTimer?.cancel();
    super.dispose();
  }
}
