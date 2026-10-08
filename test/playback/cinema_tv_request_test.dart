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

void main() {
  test('Cinema All Seasons timeout confirms exactly the missing seasons', () {
    fakeAsync((clock) {
      final repo = _Repo();
      SeerrTvDetails? confirmed;
      Object? failure;
      submitCinemaTvRequest(
        repository: repo,
        details: _original,
        selection: {'allSeasons': true, 'seasons': <int>[]},
        quota: null,
        isAllowed: () => true,
      ).then((value) => confirmed = value, onError: (Object e) => failure = e);
      clock.flushMicrotasks();
      expect(repo.submissions, 1);

      repo.refreshed = const SeerrTvDetails(
        id: 42,
        mediaInfo: SeerrMediaInfo(
          status: SeerrMediaStatus.processing,
          requests: [
            SeerrRequest(
              id: 8,
              status: SeerrRequest.statusApproved,
              type: 'tv',
              seasons: [
                SeerrSeasonRequest(id: 2, seasonNumber: 2, status: 2),
                SeerrSeasonRequest(id: 3, seasonNumber: 3, status: 2),
              ],
            ),
          ],
        ),
      );
      clock.elapse(const Duration(seconds: 20));
      clock.flushMicrotasks();
      expect(repo.submissions, 1);
      expect(repo.lookups, 1);
      expect(confirmed, same(repo.refreshed));
      expect(failure, isNull);
      repo.post.complete(const SeerrRequest(id: 8, type: 'tv', status: 2));
      clock.flushMicrotasks();
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

      repo.refreshed = const SeerrTvDetails(
        id: 42,
        mediaInfo: SeerrMediaInfo(
          status: SeerrMediaStatus.processing,
          requests: [
            SeerrRequest(
              id: 8,
              status: SeerrRequest.statusApproved,
              type: 'tv',
              seasons: [
                SeerrSeasonRequest(id: 2, seasonNumber: 2, status: 2),
              ],
            ),
          ],
        ),
      );
      clock.elapse(const Duration(seconds: 20));
      clock.flushMicrotasks();
      expect(repo.submissions, 1);
      expect(repo.lookups, 1);
      expect(failure, isA<TimeoutException>());
      repo.post.complete(const SeerrRequest(id: 8, type: 'tv', status: 2));
      clock.flushMicrotasks();
    });
  });

  test('account change prevents timeout reconciliation under a new user', () {
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
      repo.post.complete(const SeerrRequest(id: 8, type: 'tv', status: 2));
      clock.flushMicrotasks();
    });
  });
}
