import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/repositories/seerr_repository.dart';
import 'package:moonfin/data/services/seerr/seerr_api_models.dart';
import 'package:moonfin/playback/cinema_mode_controller.dart';

class FakeCinemaSeerr extends Fake implements SeerrRepository {
  SeerrMediaInfo? info;
  int lookups = 0;
  final submitted = <int>[];
  Completer<SeerrRequest>? submission;

  @override
  bool get isAvailable => true;
  @override
  Future<void> ensureInitialized({bool force = false}) async {}
  @override
  Future<SeerrUser> getCurrentUser() async =>
      SeerrUser(id: 5, permissions: SeerrPermission.requestMovie);
  @override
  Future<SeerrMovieDetails> getMovieDetails(int tmdbId) async {
    lookups++;
    return SeerrMovieDetails(id: tmdbId, title: 'Movie', mediaInfo: info);
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

Map<String, dynamic> cinemaItem({int tmdb = 42}) => {
  'Type': 'Movie',
  'RunTimeTicks': 900000000,
  'ProviderIds': {'Tmdb': '$tmdb'},
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
  late int skips;
  setUp(() {
    seerr = FakeCinemaSeerr();
    skips = 0;
    controller = CinemaModeController(
      seerr: () async => seerr,
      accountKey: () => 'server/user',
      onSkip: () async {
        skips++;
      },
    );
  });
  tearDown(() => controller.dispose());

  void enter({int tmdb = 42}) => controller.enter(
    item: cinemaItem(tmdb: tmdb),
    resolveMedia: () async => null,
  );

  test('late movie POST cannot change the next trailer', () {
    fakeAsync((time) {
      seerr.submission = Completer<SeerrRequest>();
      enter();
      time.flushMicrotasks();
      controller.request();
      time.flushMicrotasks();

      enter(tmdb: 99);
      time.flushMicrotasks();
      seerr.submission!.complete(
        const SeerrRequest(id: 1, status: 2, type: 'movie'),
      );
      time.flushMicrotasks();
      expect(controller.media?.tmdbId, 99);
      expect(controller.canRequest, isTrue);
    });
  });

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
