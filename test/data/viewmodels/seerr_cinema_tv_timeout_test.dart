import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/repositories/seerr_repository.dart';
import 'package:moonfin/data/services/seerr/seerr_api_models.dart';
import 'package:moonfin/data/services/seerr/seerr_error.dart';
import 'package:moonfin/data/viewmodels/seerr_media_detail_view_model.dart';
import 'package:moonfin/preference/seerr_preferences.dart';
import 'package:server_core/server_core.dart';

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

  test('expired Cinema session never checks under a different user', () {
    fakeAsync((clock) {
      final repo = _CinemaTvRepository();
      var current = true;
      final vm = _newVm(repo, isCurrent: () => current);
      vm.submitRequest(seasons: [2]);
      clock.flushMicrotasks();
      current = false;
      clock.elapse(const Duration(seconds: 20));
      clock.flushMicrotasks();

      expect(repo.submitted, 1);
      expect(repo.lookups, 0);
      expect(vm.state.requestSuccess, isNull);
      expect(vm.confirmedCinemaTvDetails, isNull);
      vm.dispose();
      repo.post.complete(const SeerrRequest(id: 8, type: 'tv', status: 2));
      clock.flushMicrotasks();
    });
  });

  test('late quota loading preserves a successful TV submission', () async {
    final repo = _CinemaTvRepository();
    final vm = _newVm(repo, isCurrent: () => true);
    final loading = vm.loadQuota();
    final submitted = vm.submitRequest(seasons: [2]);

    repo.post.complete(const SeerrRequest(id: 8, type: 'tv', status: 2));
    await submitted;
    expect(vm.state.requestSuccess, 'Request submitted');
    expect(vm.state.requestError, isNull);
    expect(vm.confirmedCinemaTvDetails, isNull);

    repo.quota.complete(const SeerrQuota(
      tv: SeerrQuotaDetail(limit: 5, remaining: 3),
    ));
    await loading;
    expect(vm.state.quota?.tv?.remaining, 3);
    expect(vm.state.requestSuccess, 'Request submitted');
    expect(vm.state.requestError, isNull);
    vm.dispose();
  });

  test('late quota loading preserves a rejected TV request and error kind', () async {
    final repo = _CinemaTvRepository();
    final vm = _newVm(repo, isCurrent: () => true);
    final loading = vm.loadQuota();
    final submitted = vm.submitRequest(seasons: [2]);

    repo.post.completeError(const SeerrRequestException(
      SeerrRequestErrorKind.quotaExceeded,
      'Series quota exceeded',
    ));
    await submitted;
    final error = vm.state.requestError;
    expect(error, isNotNull);
    expect(vm.state.requestErrorKind, SeerrRequestErrorKind.quotaExceeded);

    repo.quota.complete(const SeerrQuota(
      tv: SeerrQuotaDetail(limit: 5, remaining: 0),
    ));
    await loading;
    expect(vm.state.quota?.tv?.remaining, 0);
    expect(vm.state.requestError, error);
    expect(vm.state.requestErrorKind, SeerrRequestErrorKind.quotaExceeded);
    expect(vm.state.requestSuccess, isNull);
    vm.dispose();
  });

  test('definite Seerr rejection is never reinterpreted as a timeout', () {
    fakeAsync((clock) {
      final repo = _CinemaTvRepository();
      final vm = _newVm(repo, isCurrent: () => true);
      vm.submitRequest(seasons: [2]);
      clock.flushMicrotasks();
      repo.post.completeError(
        const SeerrRequestException(
          SeerrRequestErrorKind.quotaExceeded,
          'Series Quota exceeded',
        ),
      );
      clock.flushMicrotasks();

      expect(repo.submitted, 1);
      expect(repo.lookups, 0);
      expect(vm.state.requestErrorKind, SeerrRequestErrorKind.quotaExceeded);
      expect(vm.confirmedCinemaTvDetails, isNull);
      vm.dispose();
    });
  });
}
