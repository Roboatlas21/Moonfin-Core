import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:moonfin/data/services/seerr/seerr_seasons.dart';
import 'package:server_core/server_core.dart';

import '../data/repositories/seerr_repository.dart';
import '../data/services/cinema_media_resolver.dart';
import '../data/services/seerr/seerr_api_models.dart';

enum CinemaAction { skip, request }

bool _activeStandardRequest(SeerrRequest request, String type) =>
    !request.is4k &&
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

/// Movie availability and request states use different status codes. Only regular movie
/// requests matter here.
CinemaSeerrState cinemaSeerrState({
  int? mediaStatus,
  List<SeerrRequest>? requests,
  bool acknowledged = false,
}) => switch (mediaStatus) {
  SeerrMediaStatus.blocklisted => CinemaSeerrState.hidden,
  SeerrMediaStatus.pending => CinemaSeerrState.pending,
  SeerrMediaStatus.processing => CinemaSeerrState.processing,
  SeerrMediaStatus.partiallyAvailable => CinemaSeerrState.partiallyAvailable,
  SeerrMediaStatus.available => CinemaSeerrState.available,
  _ when acknowledged ||
      (requests?.any((r) => _activeStandardRequest(r, 'movie')) ?? false) =>
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

Set<int> cinemaRequestableSeasons(SeerrTvDetails details) =>
    seerrSeasonNumbersOf(details.seasons, details.numberOfSeasons ?? 0)
        .toSet()
        .difference(seerrUnavailableOrRequestedSeasons(
          details.mediaInfo,
          is4k: false,
        ));

bool cinemaSeriesIsContinuing(SeerrTvDetails details) {
  final status = (details.status ?? '').toLowerCase();
  return status.isNotEmpty && status != 'ended' && status != 'canceled';
}

CinemaSeerrState cinemaTvSeerrState(
  SeerrTvDetails details, {
  Set<int> excludedSeasons = const {},
}) {
  final status = details.mediaInfo?.status;
  if (status == SeerrMediaStatus.blocklisted ||
      (status != null && !{0, 1, 2, 3, 4, 5, 7}.contains(status))) {
    return CinemaSeerrState.hidden;
  }
  // A show marked available may still have a new season. Show Request only when another season
  // can be requested.
  if ((status != SeerrMediaStatus.available ||
          cinemaSeriesIsContinuing(details)) &&
      cinemaRequestableSeasons(details)
          .difference(excludedSeasons)
          .isNotEmpty) {
    return CinemaSeerrState.request;
  }
  final acknowledged = details.mediaInfo?.requests?.any(
        (r) => _activeStandardRequest(r, 'tv'),
      ) ?? false;
  // Seerr may still say "partially available" after accepting the selected seasons.
  if (status == SeerrMediaStatus.partiallyAvailable &&
      (acknowledged || excludedSeasons.isNotEmpty)) {
    return CinemaSeerrState.requested;
  }
  final state = cinemaSeerrState(
    mediaStatus: status,
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
}) async {
  if (!isAllowed()) return null;
  final requestable = cinemaRequestableSeasons(details)
      .difference(excludedSeasons);
  final choice = cinemaTvRequestSelection(selection, requestable, quota);
  // Reject invalid or outdated choices, especially "All Seasons" while an earlier request may
  // still be processing.
  if (choice == null || (choice.allSeasons && excludedSeasons.isNotEmpty)) {
    return null;
  }
  final expected = choice.allSeasons ? requestable : choice.seasons!.toSet();
  try {
    await repository.createRequest(
      mediaId: details.id,
      mediaType: 'tv',
      seasons: choice.seasons,
      allSeasons: choice.allSeasons,
      is4k: false,
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
            is4k: false,
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

/// Manages when trailer actions appear and how they respond across devices. Seerr checks must
/// never delay playback.
class CinemaModeController extends ChangeNotifier {
  CinemaModeController({
    required this._seerr,
    required this._accountKey,
    required this._onSkip,
    this.onRequestSeries,
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
    Set<int> excludedSeasons,
    bool Function() isCurrent,
    CinemaTvSubmit submit,
  )?
  onRequestSeries;
  SeerrTvDetails? _tvDetails;
  SeerrUser? _user;
  final Set<int> _submittedTvSeasons = {};
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
  bool get isTvRequestMore {
    final info = _tvDetails?.mediaInfo;
    return _submittedTvSeasons.isNotEmpty ||
        SeerrMediaStatus.isAvailable(info?.status) ||
        (info?.requests?.any((r) => _activeStandardRequest(r, 'tv')) ?? false);
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
    _user = null;
    _submittedTvSeasons.clear();
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
      final permitted =
          user.hasPermission(SeerrPermission.request) ||
          user.hasPermission(
            isSeries ? SeerrPermission.requestTv : SeerrPermission.requestMovie,
          );
      if (!permitted) return;
      _user = user;
      if (isSeries && onRequestSeries == null) return;
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
      seerrState = cinemaTvSeerrState(
        tv,
        excludedSeasons: _submittedTvSeasons,
      );
    } else {
      final movie = await repository
          .getMovieDetails(id)
          .timeout(const Duration(seconds: 10));
      if (!_current(ticket)) return false;
      seerrState = cinemaSeerrState(
        mediaStatus: movie.mediaInfo?.status,
        requests: movie.mediaInfo?.requests,
      );
    }
    return true;
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
      final response = await repository
          .createRequest(mediaId: id, mediaType: 'movie', is4k: false)
          .timeout(const Duration(seconds: 20));
      if (!_current(ticket)) return;
      seerrState = cinemaSeerrState(
        mediaStatus: response.media?.status,
        acknowledged: true,
      );
    } catch (_) {
      if (!_current(ticket)) return;
      // Seerr may have accepted the request even though an error was returned. Refresh once,
      // but do not submit again.
      seerrState = CinemaSeerrState.hidden;
      try {
        if (!await _refreshStatus(repository, ticket, id)) return;
        // Seerr may still show the old status after accepting the request. Keep Request hidden
        // rather than risk a duplicate.
        if (seerrState == CinemaSeerrState.request) {
          seerrState = CinemaSeerrState.hidden;
        }
      } catch (_) {
        // If status cannot be confirmed, leave Request hidden.
      }
    } finally {
      if (_current(ticket)) _setSending(false);
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
      final requestable = cinemaRequestableSeasons(details);
      // Seerr may not show newly requested seasons right away.
      final excluded = requestable.intersection(_submittedTvSeasons);
      final confirmed = await onRequestSeries!(
        repository,
        details,
        user,
        excluded,
        () => _current(ticket) && !_skipping,
        (selection, quota, isAllowed) async {
          final result = await submitCinemaTvRequest(
            repository: repository,
            details: details,
            selection: selection,
            quota: quota,
            isAllowed: isAllowed,
            excludedSeasons: excluded,
          );
          if (_current(ticket) && isAllowed() && result != null) {
            _submittedTvSeasons.addAll(result.seasons);
            acknowledged = true;
          }
          return result?.confirmed;
        },
      );
      // If the picker is cancelled, keep Request available. Refresh status only after a request
      // was submitted.
      if (!_current(ticket) || !acknowledged) return;
      seerrState = cinemaTvSeerrState(
        details,
        excludedSeasons: _submittedTvSeasons,
      );
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
