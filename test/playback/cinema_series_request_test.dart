import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/repositories/seerr_repository.dart';
import 'package:moonfin/data/services/seerr/seerr_api_models.dart';
import 'package:moonfin/playback/cinema_mode_controller.dart';
import 'package:moonfin/preference/seerr_preferences.dart';
import 'package:server_core/server_core.dart';

class CinemaTvRepository extends Fake implements SeerrRepository {
  int permissions = SeerrPermission.requestTv;
  int lookups = 0;
  Completer<SeerrRequest>? submission;
  Completer<SeerrTvDetails>? detailsResponse;
  int? failOnLookup;
  SeerrTvDetails details = const SeerrTvDetails(id: 42, numberOfSeasons: 5);
  final submissions = <({int id, String type, List<int>? seasons, bool all})>[];
  @override
  bool get isAvailable => true;
  @override
  Future<void> ensureInitialized({bool force = false}) async {}
  @override
  Future<SeerrUser> getCurrentUser() async =>
      SeerrUser(id: 5, permissions: permissions);
  @override
  Future<SeerrTvDetails> getTvDetails(int tmdbId) async {
    lookups++;
    expect(tmdbId, 42);
    if (lookups == failOnLookup) throw StateError('Seerr detail refresh failed');
    if (detailsResponse != null) return detailsResponse!.future;
    return details;
  }

  @override
  Future<SeerrRequest> createRequest({
    required int mediaId,
    required String mediaType,
    List<int>? seasons,
    bool allSeasons = false,
    bool is4k = false,
    int? profileId,
    String? rootFolder,
    int? serverId,
  }) async {
    expect(is4k, false);
    submissions.add((
      id: mediaId,
      type: mediaType,
      seasons: seasons,
      all: allSeasons,
    ));
    return submission?.future ??
        Future.value(const SeerrRequest(id: 1, status: 2, type: 'tv'));
  }
}

class CinemaTvPreferences extends Fake implements SeerrPreferences {
  @override
  String get hdTvServerId => '';
  @override
  String get hdTvProfileId => '';
  @override
  String get hdTvRootFolderId => '';
}

void main() {
  late CinemaTvRepository repository;
  late CinemaModeController controller;
  late String account;
  late int dialogs;
  late int? selected;
  late bool Function() current;
  late Completer<SeerrTvDetails?> dialog;

  setUp(() {
    repository = CinemaTvRepository();
    account = 'account-a';
    dialogs = 0;
    selected = null;
    dialog = Completer();
    controller = CinemaModeController(
      seerr: () async => repository,
      accountKey: () => account,
      onSkip: () async {},
      onError: (e) => fail('$e'),
      onRequestSeries: (repo, details, user, season, isCurrent) {
        dialogs++;
        selected = season;
        current = isCurrent;
        return dialog.future;
      },
    );
  });
  tearDown(() => controller.dispose());

  void enter([int? season = 5]) => controller.enter(
    item: {'Type': 'Video', 'RunTimeTicks': 900000000},
    resolveMedia: () async =>
        CinemaMedia(42, CinemaMediaType.tv, season: season),
  );

  test(
    'TV permission, typed lookup, validated season and duplicate dialog guard',
    () {
      fakeAsync((time) {
        dialog = Completer();
        enter();
        time.flushMicrotasks();
        expect(controller.isSeries, true);
        expect(controller.canRequest, true);
        controller.request();
        controller.request();
        time.flushMicrotasks();
        expect(dialogs, 1);
        expect(selected, 5);
        expect(repository.submissions, isEmpty);
        dialog.complete(); // Cancel never submits.
        time.flushMicrotasks();
        expect(controller.canRequest, true);
      });
    },
  );

  test('failed TV status refresh after picker completion is not a request failure',
      () {
    fakeAsync((time) {
      enter();
      time.flushMicrotasks();
      expect(repository.lookups, 1);
      repository.failOnLookup = 2;
      controller.request();
      time.flushMicrotasks();
      expect(dialogs, 1);
      dialog.complete();
      time.flushMicrotasks();
      expect(repository.lookups, 2);
      expect(controller.seerrState, CinemaSeerrState.hidden);
      expect(controller.canRequest, isFalse);
    });
  });

  test('timeout confirmation updates the rail without another detail lookup', () {
    fakeAsync((time) {
      enter();
      time.flushMicrotasks();
      controller.request();
      time.flushMicrotasks();
      repository.failOnLookup = 2;
      dialog.complete(
        const SeerrTvDetails(
          id: 42,
          numberOfSeasons: 5,
          mediaInfo: SeerrMediaInfo(status: SeerrMediaStatus.available),
        ),
      );
      time.flushMicrotasks();
      expect(repository.lookups, 1);
      expect(controller.seerrState, CinemaSeerrState.available);
      expect(controller.canRequest, isFalse);
    });
  });

  test('TV picker submission errors still reach the controller', () {
    fakeAsync((time) {
      final captured = <Object>[];
      final rejecting = CinemaModeController(
        seerr: () async => repository,
        accountKey: () => account,
        onSkip: () async {},
        onError: captured.add,
        onRequestSeries: (_, _, _, _, _) async {
          throw StateError('Seerr rejected request');
        },
      );
      rejecting.enter(
        item: {'Type': 'Video', 'RunTimeTicks': 900000000},
        resolveMedia: () async =>
            const CinemaMedia(42, CinemaMediaType.tv, season: 5),
      );
      time.flushMicrotasks();
      rejecting.request();
      time.flushMicrotasks();
      expect(repository.lookups, 1);
      expect(captured, hasLength(1));
      expect(rejecting.seerrState, CinemaSeerrState.hidden);
      rejecting.dispose();
    });
  });

  test('movie permission alone cannot open a TV request', () {
    fakeAsync((time) {
      dialog = Completer();
      repository.permissions = SeerrPermission.requestMovie;
      enter();
      time.flushMicrotasks();
      expect(controller.seerrState, CinemaSeerrState.hidden);
      expect(repository.lookups, 0);
      controller.request();
      expect(dialogs, 0);
    });
  });

  test(
    'invalid season is not preselected and changing account invalidates dialog',
    () {
      fakeAsync((time) {
        dialog = Completer();
        enter(99);
        time.flushMicrotasks();
        controller.request();
        time.flushMicrotasks();
        expect(selected, null);
        expect(current(), true);
        account = 'account-b';
        expect(current(), false);
        dialog.complete(
          const SeerrTvDetails(
            id: 42,
            mediaInfo: SeerrMediaInfo(status: SeerrMediaStatus.available),
          ),
        );
        time.flushMicrotasks();
        expect(repository.lookups, 1);
        expect(controller.visible, false);
      });
    },
  );

  test('changing trailers invalidates an open series dialog', () {
    fakeAsync((time) {
      dialog = Completer();
      enter();
      time.flushMicrotasks();
      controller.request();
      time.flushMicrotasks();
      enter();
      expect(current(), false);
      dialog.complete(
        const SeerrTvDetails(
          id: 42,
          mediaInfo: SeerrMediaInfo(status: SeerrMediaStatus.available),
        ),
      );
      time.flushMicrotasks();
      expect(controller.seerrState, CinemaSeerrState.request);
    });
  });

  test('partial series offers missing seasons but excludes available or requested ones', () {
    final details = SeerrTvDetails(
      id: 42,
      numberOfSeasons: 3,
      mediaInfo: const SeerrMediaInfo(
        status: SeerrMediaStatus.partiallyAvailable,
        seasons: [SeerrSeasonAvailability(seasonNumber: 1, status: 5)],
        requests: [
          SeerrRequest(
            id: 1,
            status: 2,
            type: 'tv',
            seasons: [SeerrSeasonRequest(id: 1, seasonNumber: 2, status: 2)],
          ),
        ],
      ),
    );
    expect(cinemaRequestableSeasons(details), {3});
    expect(cinemaTvSeerrState(details), CinemaSeerrState.request);
    expect(
      cinemaTvSeerrState(
        const SeerrTvDetails(
          id: 42,
          mediaInfo: SeerrMediaInfo(status: 6),
          numberOfSeasons: 3,
        ),
      ),
      CinemaSeerrState.hidden,
    );
    expect(
      cinemaTvSeerrState(const SeerrTvDetails(id: 42)),
      CinemaSeerrState.hidden,
    );
  });

  for (final status in [
    'Returning Series',
    'In Production',
    'Ended',
    'Canceled',
    null,
  ]) {
    test(
      'available $status series only offers a new season when continuing',
      () {
        final details = SeerrTvDetails(
          id: 42,
          status: status,
          numberOfSeasons: 5,
          mediaInfo: SeerrMediaInfo(
            status: SeerrMediaStatus.available,
            seasons: [
              for (var season = 1; season <= 4; season++)
                SeerrSeasonAvailability(
                  seasonNumber: season,
                  status: SeerrMediaStatus.available,
                ),
            ],
          ),
        );
        expect(cinemaRequestableSeasons(details), {5});
        expect(
          cinemaTvSeerrState(details),
          status == 'Returning Series' || status == 'In Production'
              ? CinemaSeerrState.request
              : CinemaSeerrState.available,
        );
      },
    );
  }

  test('native All Seasons uses Seerr all, not enumerated seasons', () {
    final selection = cinemaTvRequestSelection(
      {'allSeasons': true, 'seasons': <int>[]},
      {2, 5},
      const SeerrQuotaDetail(limit: 4, remaining: 2),
    );
    expect(selection, isNotNull);
    expect(selection!.allSeasons, isTrue);
    expect(selection.seasons, isNull);
  });

  test('native explicit season selection is sorted and deduplicated', () {
    final selection = cinemaTvRequestSelection(
      {'allSeasons': false, 'seasons': [5, 2, 5]},
      {2, 5},
      null,
    );
    expect(selection?.allSeasons, isFalse);
    expect(selection?.seasons, [2, 5]);
  });

  test('native selection rejects malformed and unrequestable seasons', () {
    for (final value in [
      {'seasons': [2]},
      {'allSeasons': false, 'seasons': [2.0]},
      {'allSeasons': false, 'seasons': [99]},
      {'allSeasons': false, 'seasons': <int>[]},
      {'allSeasons': true, 'seasons': [2]},
    ]) {
      expect(cinemaTvRequestSelection(value, {2, 5}, null), isNull);
    }
    expect(
      cinemaTvRequestSelection(
        {'allSeasons': true, 'seasons': <int>[]},
        <int>{},
        null,
      ),
      isNull,
    );
  });

  test('quota applies equally to all and explicitly chosen seasons', () {
    const quota = SeerrQuotaDetail(limit: 3, remaining: 1);
    expect(
      cinemaTvRequestSelection(
        {'allSeasons': true, 'seasons': <int>[]},
        {2, 5},
        quota,
      ),
      isNull,
    );
    expect(
      cinemaTvRequestSelection(
        {'allSeasons': false, 'seasons': [2, 5]},
        {2, 5},
        quota,
      ),
      isNull,
    );
    expect(
      cinemaTvRequestSelection(
        {'allSeasons': false, 'seasons': [5]},
        {2, 5},
        quota,
      )?.seasons,
      [5],
    );
    expect(
      cinemaTvRequestSelection(
        {'allSeasons': false, 'seasons': [5]},
        {2, 5},
        const SeerrQuotaDetail(limit: 5, remaining: 5, restricted: true),
      ),
      isNull,
    );
  });

  test(
    'continuing series with every season available has no request action',
    () {
      final details = SeerrTvDetails(
        id: 42,
        status: 'Returning Series',
        numberOfSeasons: 5,
        mediaInfo: SeerrMediaInfo(
          status: SeerrMediaStatus.available,
          seasons: [
            for (var season = 1; season <= 5; season++)
              SeerrSeasonAvailability(
                seasonNumber: season,
                status: SeerrMediaStatus.available,
              ),
          ],
        ),
      );
      expect(cinemaRequestableSeasons(details), isEmpty);
      expect(cinemaTvSeerrState(details), CinemaSeerrState.available);
    },
  );
}
