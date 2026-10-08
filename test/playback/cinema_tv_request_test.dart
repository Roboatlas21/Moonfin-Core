import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/repositories/seerr_repository.dart';
import 'package:moonfin/data/services/seerr/seerr_api_models.dart';
import 'package:moonfin/playback/cinema_mode_controller.dart';

class _Repo extends Fake implements SeerrRepository {
  int submissions = 0;
  int lookups = 0;
  bool expected4k = false;
  int permissions = SeerrPermission.requestTv;
  final submitted4k = <bool>[];
  final submittedSeasons = <List<int>?>[];
  final post = Completer<SeerrRequest>();

  @override
  bool get isAvailable => true;

  @override
  Future<void> ensureInitialized({bool force = false}) async {}

  @override
  Future<SeerrUser> getCurrentUser() async =>
      SeerrUser(id: 5, permissions: permissions);

  @override
  Future<Map<String, dynamic>> getPublicSettings() async =>
      {'series4kEnabled': true};

  SeerrTvDetails refreshed = const SeerrTvDetails(id: 42);

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
  }) {
    expect(mediaId, 42);
    expect(mediaType, 'tv');
    expect(is4k, expected4k);
    submissions++;
    submitted4k.add(is4k);
    submittedSeasons.add(seasons);
    return post.future;
  }

  @override
  Future<SeerrTvDetails> getTvDetails(int id) async {
    expect(id, 42);
    lookups++;
    return refreshed;
  }
}

const _original = SeerrTvDetails(
  id: 42,
  numberOfSeasons: 3,
  mediaInfo: SeerrMediaInfo(
    status: SeerrMediaStatus.partiallyAvailable,
    seasons: [SeerrSeasonAvailability(seasonNumber: 1, status: 5)],
  ),
);

SeerrTvDetails _requestedSeasons(List<int> seasons) => SeerrTvDetails(
  id: 42,
  mediaInfo: SeerrMediaInfo(
    status: SeerrMediaStatus.processing,
    requests: [
      SeerrRequest(
        id: 8,
        status: SeerrRequest.statusApproved,
        type: 'tv',
        seasons: [
          for (final number in seasons)
            SeerrSeasonRequest(id: number, seasonNumber: number, status: 2),
        ],
      ),
    ],
  ),
);

void main() {
  test('cancelling TV picker preserves Request without a refresh', () async {
    final repo = _Repo()..refreshed = _original;
    final controller = CinemaModeController(
      seerr: () async => repo,
      accountKey: () => 'server/user',
      onSkip: () async {},
      onRequestSeries: (
        repository,
        details,
        user,
        excluded,
        isCurrent,
        submit,
      ) async => null,
    );
    try {
      controller.enter(
        item: {
          'Type': 'Series',
          'RunTimeTicks': 900000000,
          'ProviderIds': {'Tmdb': '42'},
        },
        resolveMedia: () async => null,
      );
      await Future<void>.delayed(Duration.zero);
      expect(repo.lookups, 1);
      expect(controller.canRequest, isTrue);

      await controller.request();

      expect(repo.submissions, 0);
      expect(repo.lookups, 1);
      expect(controller.seerrState, CinemaSeerrState.request);
      expect(controller.canRequest, isTrue);
    } finally {
      controller.dispose();
    }
  });


  test('4K-only TV permission opens the season picker in 4K', () async {
    final repo = _Repo()
      ..permissions = SeerrPermission.request4kTv
      ..refreshed = _original;
    CinemaTvQualityOptions? offered;
    final controller = CinemaModeController(
      seerr: () async => repo,
      accountKey: () => 'server/user',
      onSkip: () async {},
      onRequestSeries: (
        repository, details, user, options, isCurrent, submit,
      ) async {
        offered = options;
        return null;
      },
    );
    try {
      controller.enter(
        item: {
          'Type': 'Series',
          'RunTimeTicks': 900000000,
          'ProviderIds': {'Tmdb': '42'},
        },
        resolveMedia: () async => null,
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.canRequest, isTrue);
      expect(controller.only4kRequestable, isTrue);
      await controller.request();
      expect(offered?.standard, isFalse);
      expect(offered?.fourK, isTrue);
      expect(repo.submissions, 0);
    } finally {
      controller.dispose();
    }
  });

  test('accepted TV seasons do not hide Request More for other seasons', () async {
    final repo = _Repo()..refreshed = _original;
    repo.post.complete(const SeerrRequest(
      id: 99,
      type: 'tv',
      status: SeerrRequest.statusApproved,
    ));
    final excludedAtPicker = <Set<int>>[];
    final controller = CinemaModeController(
      seerr: () async => repo,
      accountKey: () => 'server/user',
      onSkip: () async {},
      onRequestSeries: (
        repository,
        details,
        user,
        excluded,
        isCurrent,
        submit,
      ) {
        excludedAtPicker.add({...excluded.excludedStandard});
        return submit({
          'allSeasons': false,
          'seasons': <int>[excludedAtPicker.length + 1],
        }, null, isCurrent);
      },
    );
    try {
      controller.enter(
        item: {
          'Type': 'Series',
          'RunTimeTicks': 900000000,
          'ProviderIds': {'Tmdb': '42'},
        },
        resolveMedia: () async => null,
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.canRequest, isTrue);

      await controller.request();
      expect(controller.canRequest, isTrue);
      await controller.request();

      expect(excludedAtPicker, [<int>{}, <int>{2}]);
      expect(repo.submittedSeasons, [[2], [3]]);
      expect(controller.canRequest, isFalse);
    } finally {
      controller.dispose();
    }
  });

  test('Cinema All Seasons timeout confirms exactly the missing seasons', () {
    fakeAsync((clock) {
      final repo = _Repo();
      SeerrTvDetails? confirmed;
      submitCinemaTvRequest(
        repository: repo,
        details: _original,
        selection: {'allSeasons': true, 'seasons': <int>[]},
        quota: null,
        isAllowed: () => true,
      ).then((value) => confirmed = value?.confirmed);
      clock.flushMicrotasks();
      repo.refreshed = _requestedSeasons([2, 3]);
      clock.elapse(const Duration(seconds: 20));
      clock.flushMicrotasks();
      expect(repo.submissions, 1);
      expect(repo.lookups, 1);
      expect(confirmed, same(repo.refreshed));
    });
  });

  test('unconfirmed timeout reports failure without retrying the POST', () {
    fakeAsync((clock) {
      final repo = _Repo();
      Object? failure;
      submitCinemaTvRequest(
        repository: repo,
        details: _original,
        selection: {'allSeasons': false, 'seasons': <int>[2, 3]},
        quota: null,
        isAllowed: () => true,
      ).then<void>(
        (_) {},
        onError: (Object e) {
          failure = e;
        },
      );
      clock.flushMicrotasks();

      repo.refreshed = _requestedSeasons([2]);
      clock.elapse(const Duration(seconds: 20));
      clock.flushMicrotasks();
      expect(repo.submissions, 1);
      expect(repo.lookups, 1);
      expect(failure, isA<TimeoutException>());
    });
  });


  test('TV requests use the chosen quality and ignore the other track', () async {
    final repo = _Repo()..expected4k = true;
    repo.post.complete(const SeerrRequest(
      id: 99,
      type: 'tv',
      status: SeerrRequest.statusApproved,
      is4k: true,
    ));
    const details = SeerrTvDetails(
      id: 42,
      numberOfSeasons: 3,
      mediaInfo: SeerrMediaInfo(
        seasons: [
          SeerrSeasonAvailability(
            seasonNumber: 1,
            status4k: SeerrMediaStatus.available,
          ),
          SeerrSeasonAvailability(
            seasonNumber: 2,
            status: SeerrMediaStatus.available,
          ),
        ],
      ),
    );

    final result = await submitCinemaTvRequest(
      repository: repo,
      details: details,
      selection: {'is4k': true, 'allSeasons': false, 'seasons': <int>[2]},
      quota: null,
      isAllowed: () => true,
      allowStandard: false,
      allow4k: true,
    );

    expect(result?.seasons, {2});
    expect(repo.submitted4k, [true]);
    expect(repo.submittedSeasons, [[2]]);
  });

  test('a quality that is not requestable is never submitted', () async {
    final repo = _Repo();
    final result = await submitCinemaTvRequest(
      repository: repo,
      details: _original,
      selection: {'is4k': true, 'allSeasons': false, 'seasons': <int>[2]},
      quota: null,
      isAllowed: () => true,
      allowStandard: true,
      allow4k: false,
    );
    expect(result, isNull);
    expect(repo.submissions, 0);
  });

  test('a standard request cannot confirm a timed-out 4K request', () {
    fakeAsync((clock) {
      final repo = _Repo()..expected4k = true;
      Object? failure;
      submitCinemaTvRequest(
        repository: repo,
        details: _original,
        selection: {'is4k': true, 'allSeasons': false, 'seasons': <int>[2]},
        quota: null,
        isAllowed: () => true,
        allowStandard: false,
        allow4k: true,
      ).then<void>(
        (_) {},
        onError: (Object e) => failure = e,
      );
      clock.flushMicrotasks();
      repo.refreshed = _requestedSeasons([2]); // Standard, not 4K.
      clock.elapse(const Duration(seconds: 20));
      clock.flushMicrotasks();
      expect(repo.submitted4k, [true]);
      expect(repo.lookups, 1);
      expect(failure, isA<TimeoutException>());
    });
  });

  test('invalidated picker skips timeout reconciliation', () {
    fakeAsync((clock) {
      final repo = _Repo();
      var allowed = true;
      Object? result;
      submitCinemaTvRequest(
        repository: repo,
        details: _original,
        selection: {'allSeasons': false, 'seasons': <int>[2]},
        quota: null,
        isAllowed: () => allowed,
      ).then((value) => result = value);
      clock.flushMicrotasks();
      allowed = false;
      clock.elapse(const Duration(seconds: 20));
      clock.flushMicrotasks();
      expect(repo.submissions, 1);
      expect(repo.lookups, 0);
      expect(result, isNull);
    });
  });
}
