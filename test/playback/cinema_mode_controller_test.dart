import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:server_core/server_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/repositories/seerr_repository.dart';
import 'package:moonfin/data/services/seerr/seerr_api_models.dart';
import 'package:moonfin/playback/cinema_mode_controller.dart';

class FakeCinemaSeerr extends Fake implements SeerrRepository {
  bool available = true;
  int permissions = SeerrPermission.requestMovie;
  SeerrMediaInfo? info;
  int lookups = 0;
  final submitted = <int>[];
  Completer<SeerrRequest>? submission;
  Completer<SeerrMovieDetails>? details;
  Object? failure;

  @override
  bool get isAvailable => available;
  @override
  Future<void> ensureInitialized({bool force = false}) async {}
  @override
  Future<SeerrUser> getCurrentUser() async =>
      SeerrUser(id: 5, permissions: permissions);
  @override
  Future<SeerrMovieDetails> getMovieDetails(int tmdbId) async {
    lookups++;
    return details?.future ??
        Future.value(
          SeerrMovieDetails(id: tmdbId, title: 'Movie', mediaInfo: info),
        );
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
    expect(mediaType, 'movie');
    expect(is4k, false);
    submitted.add(mediaId);
    if (failure != null) throw failure!;
    return submission?.future ??
        Future.value(
          const SeerrRequest(
            id: 1,
            status: SeerrRequest.statusApproved,
            type: 'movie',
          ),
        );
  }
}

Map<String, dynamic> cinemaItem({int? seconds = 90, int? tmdb = 42}) => {
  'Type': 'Movie',
  if (seconds != null) 'RunTimeTicks': seconds * 10000000,
  if (tmdb != null) 'ProviderIds': {'Tmdb': '$tmdb'},
};

void main() {

  test(
    'media statuses stay distinct; blocked and unknown codes are hidden',
    () {
      final expected = {
        1: CinemaSeerrState.request,
        2: CinemaSeerrState.pending,
        3: CinemaSeerrState.processing,
        4: CinemaSeerrState.partiallyAvailable,
        5: CinemaSeerrState.available,
        6: CinemaSeerrState.hidden,
        7: CinemaSeerrState.request,
        999: CinemaSeerrState.hidden,
      };
      for (final entry in expected.entries) {
        expect(
          cinemaSeerrState(mediaStatus: entry.key),
          entry.value,
        );
      }
      expect(cinemaSeerrState(), CinemaSeerrState.request);
    },
  );

  late FakeCinemaSeerr seerr;
  late CinemaModeController controller;
  late String account;
  late int skips;
  late List<Object> errors;
  setUp(() {
    seerr = FakeCinemaSeerr();
    account = 'server/user';
    skips = 0;
    errors = [];
    controller = CinemaModeController(
      seerr: () async => seerr,
      accountKey: () => account,
      onSkip: () async {
        skips++;
      },
      onError: errors.add,
    );
  });
  tearDown(() => controller.dispose());

  void enter({int? seconds = 90, int? tmdb = 42, Future<int?>? resolve}) =>
      controller.enter(
        item: cinemaItem(seconds: seconds, tmdb: tmdb),
        resolveMedia: () async {
          final id = await resolve;
          return id == null ? null : CinemaMedia(id, CinemaMediaType.movie);
        },
      );

  test(
    'account changes invalidate pending lookup and submission responses',
    () {
      fakeAsync((time) {
        seerr.submission = Completer();
        enter();
        time.flushMicrotasks();
        controller.request();
        time.flushMicrotasks();
        account = 'server/other';
        seerr.submission!.complete(
          const SeerrRequest(id: 1, status: 2, type: 'movie'),
        );
        time.flushMicrotasks();
        expect(controller.visible, false);
        expect(errors, isEmpty);
        controller.activate();
        expect(skips, 0);
      });
    },
  );

  for (final status in [
    SeerrMediaStatus.unknown,
    SeerrMediaStatus.deleted,
  ]) {
    test('movie POST timeout with stale status $status never offers retry', () {
      fakeAsync((time) {
        seerr.submission = Completer<SeerrRequest>();
        seerr.info = SeerrMediaInfo(status: status);
        enter();
        time.flushMicrotasks();
        expect(controller.canRequest, isTrue);

        controller.request();
        time.flushMicrotasks();
        expect(seerr.submitted, [42]);
        time.elapse(const Duration(seconds: 20));
        time.flushMicrotasks();

        expect(seerr.lookups, 2);
        expect(controller.seerrState, CinemaSeerrState.hidden);
        expect(controller.canRequest, isFalse);
        expect(errors, hasLength(1));

        controller.request();
        time.flushMicrotasks();
        expect(seerr.submitted, [42]);

        // A late POST response cannot restore the stale Request action.
        seerr.submission!.complete(
          const SeerrRequest(id: 1, status: 2, type: 'movie'),
        );
        time.flushMicrotasks();
        expect(controller.seerrState, CinemaSeerrState.hidden);
      });
    });
  }

  test(
    'repeat presses and rapid double taps skip only once across a transition',
    () {
      enter();
      controller.skip();
      controller.skip();
      expect(skips, 1);
      enter(tmdb: 99);
      controller.skip();
      expect(skips, 1);
    },
  );
}
