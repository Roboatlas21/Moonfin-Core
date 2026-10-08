import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/repositories/seerr_repository.dart';
import 'package:moonfin/data/services/seerr/seerr_api_models.dart';
import 'package:moonfin/data/viewmodels/seerr_media_detail_view_model.dart';
import 'package:moonfin/preference/seerr_preferences.dart';

class _CinemaTvRepository extends Fake implements SeerrRepository {
  int submitted = 0;
  int lookups = 0;
  final post = Completer<SeerrRequest>();
  final quota = Completer<SeerrQuota>();
  SeerrTvDetails details = const SeerrTvDetails(id: 42);

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
    submitted++;
    return post.future;
  }

  @override
  Future<SeerrQuota> getUserQuota(int userId) {
    expect(userId, 5);
    return quota.future;
  }

  @override
  Future<SeerrTvDetails> getTvDetails(int tmdbId) async {
    expect(tmdbId, 42);
    lookups++;
    return details;
  }
}

class _Preferences extends Fake implements SeerrPreferences {}

const _original = SeerrTvDetails(
  id: 42,
  numberOfSeasons: 3,
  mediaInfo: SeerrMediaInfo(
    status: SeerrMediaStatus.partiallyAvailable,
    seasons: [SeerrSeasonAvailability(seasonNumber: 1, status: 5)],
  ),
);

SeerrMediaDetailViewModel _newVm(
  _CinemaTvRepository repo, {
  required bool Function() isCurrent,
}) => SeerrMediaDetailViewModel.forCinema(
  repo,
  _Preferences(),
  details: _original,
  user: const SeerrUser(id: 5, permissions: SeerrPermission.requestTv),
  requestAllowed: isCurrent,
);

void main() {

  test('Cinema All Seasons timeout confirms only requested missing seasons', () {
    fakeAsync((clock) {
      final repo = _CinemaTvRepository();
      final vm = _newVm(repo, isCurrent: () => true);
      vm.submitRequest(allSeasons: true);
      clock.flushMicrotasks();
      expect(repo.submitted, 1);

      // Season 1 was already owned. The response must prove 2 and 3 were
      // requested; the title's overall status alone cannot prove success.
      repo.details = const SeerrTvDetails(
        id: 42,
        numberOfSeasons: 3,
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

      expect(repo.submitted, 1);
      expect(repo.lookups, 1);
      expect(vm.state.requestSuccess, 'Request submitted');
      expect(vm.state.requestError, isNull);
      expect(vm.state.isRequesting, isFalse);
      expect(vm.confirmedCinemaTvDetails, same(repo.details));
      vm.dispose();
      repo.post.complete(const SeerrRequest(id: 8, type: 'tv', status: 2));
      clock.flushMicrotasks();
    });
  });

  test('incomplete confirmation remains an uncertain failure, never retries', () {
    fakeAsync((clock) {
      final repo = _CinemaTvRepository();
      final vm = _newVm(repo, isCurrent: () => true);
      vm.submitRequest(seasons: [2, 3]);
      clock.flushMicrotasks();

      repo.details = const SeerrTvDetails(
        id: 42,
        mediaInfo: SeerrMediaInfo(
          status: SeerrMediaStatus.processing,
          requests: [
            SeerrRequest(
              id: 8,
              status: SeerrRequest.statusApproved,
              type: 'tv',
              seasons: [SeerrSeasonRequest(id: 2, seasonNumber: 2, status: 2)],
            ),
          ],
        ),
      );
      clock.elapse(const Duration(seconds: 20));
      clock.flushMicrotasks();

      expect(repo.submitted, 1);
      expect(repo.lookups, 1);
      expect(vm.state.requestSuccess, isNull);
      expect(vm.state.requestError, contains('TimeoutException'));
      expect(vm.confirmedCinemaTvDetails, isNull);
      vm.dispose();
      repo.post.complete(const SeerrRequest(id: 8, type: 'tv', status: 2));
      clock.flushMicrotasks();
    });
  });
}
