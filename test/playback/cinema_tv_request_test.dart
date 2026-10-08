import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/repositories/seerr_repository.dart';
import 'package:moonfin/data/services/seerr/seerr_api_models.dart';
import 'package:moonfin/playback/cinema_mode_controller.dart';

class _Repo extends Fake implements SeerrRepository {
  int submissions = 0;
  int lookups = 0;
  final post = Completer<SeerrRequest>();
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
    expect(is4k, false);
    submissions++;
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
      ).then((value) => confirmed = value);
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

  test('invalidated picker skips timeout reconciliation', () {
    fakeAsync((clock) {
      final repo = _Repo();
      var allowed = true;
      SeerrTvDetails? result;
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
