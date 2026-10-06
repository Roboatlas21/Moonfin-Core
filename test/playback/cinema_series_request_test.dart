import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/repositories/seerr_repository.dart';
import 'package:moonfin/data/services/seerr/seerr_api_models.dart';
import 'package:moonfin/data/viewmodels/seerr_media_detail_view_model.dart';
import 'package:moonfin/playback/cinema_mode_controller.dart';
import 'package:moonfin/preference/seerr_preferences.dart';
import 'package:server_core/server_core.dart';

class CinemaTvRepository extends Fake implements SeerrRepository {
  int permissions = SeerrPermission.requestTv;
  int lookups = 0;
  Completer<SeerrRequest>? submission;
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
  late Completer<void> dialog;

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
        dialog.complete();
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
      dialog.complete();
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

  test('existing picker model submits only selected TV seasons and rejects stale submission', () async {
    var allowed = true;
    final vm = SeerrMediaDetailViewModel.forCinema(
      repository,
      CinemaTvPreferences(),
      details: repository.details,
      user: const SeerrUser(id: 5, permissions: SeerrPermission.requestTv),
      requestAllowed: () => allowed,
    );
    addTearDown(vm.dispose);
    await vm.submitRequest(seasons: [5]);
    expect(repository.submissions.single.id, 42);
    expect(repository.submissions.single.type, 'tv');
    expect(repository.submissions.single.seasons, [5]);
    expect(repository.submissions.single.all, false);
    allowed = false;
    await vm.submitRequest(seasons: [4]);
    expect(repository.submissions.length, 1);
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
