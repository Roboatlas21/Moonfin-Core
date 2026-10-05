import 'dart:async';

import 'package:fake_async/fake_async.dart';
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
  'Type': 'Video',
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
          cinemaSeerrState(mediaStatus: entry.key, canRequest: true),
          entry.value,
        );
      }
      expect(cinemaSeerrState(canRequest: true), CinemaSeerrState.request);
      expect(cinemaSeerrState(canRequest: false), CinemaSeerrState.hidden);
    },
  );

  test('only active standard movie requests suppress Request Movie', () {
    for (final status in [1, 2, 3, 4, 5]) {
      for (final is4k in [false, true]) {
        final requests = [
          SeerrRequest(id: 1, status: status, type: 'movie', is4k: is4k),
        ];
        expect(
          cinemaSeerrState(
            mediaStatus: 1,
            requests: requests,
            canRequest: true,
          ),
          !is4k && status <= 2
              ? CinemaSeerrState.requested
              : CinemaSeerrState.request,
        );
        expect(
          cinemaSeerrState(
            mediaStatus: 3,
            requests: requests,
            canRequest: true,
          ),
          CinemaSeerrState.processing,
        );
        expect(
          cinemaSeerrState(
            mediaStatus: 6,
            requests: requests,
            canRequest: true,
          ),
          CinemaSeerrState.hidden,
        );
      }
    }
  });

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
        resolveMovie: () => resolve ?? Future.value(),
      );

  test(
    'minimum uses total metadata, hides unknown, and zero allows unknown',
    () {
      fakeAsync((time) {
        enter(seconds: 14);
        time.flushMicrotasks();
        expect(controller.visible, false);
        expect(controller.canRequest, false);
        controller.activate();
        expect(controller.visible, false);
        expect(skips, 0);
        enter(seconds: 15);
        expect(controller.visible, true);
        controller.updatePlayback(
          duration: const Duration(seconds: 2),
          playing: true,
        );
        expect(controller.duration.inSeconds, 15);
        enter(seconds: null);
        expect(controller.visible, false);
        controller.configure(minimumSeconds: 0, autoHideSeconds: 10);
        expect(controller.visible, true);
      });
    },
  );

  test('duration learned for one item is cleared before the next intro', () {
    enter(seconds: null);
    controller.updatePlayback(
      duration: const Duration(seconds: 60),
      playing: true,
    );
    expect(controller.visible, true);
    enter(seconds: null);
    expect(controller.visible, false);
    controller.activate();
    expect(skips, 0);
  });

  test(
    'late identity and Seerr never reveal a dismissed rail or change focus',
    () {
      fakeAsync((time) {
        final lookup = Completer<int?>();
        enter(tmdb: null, resolve: lookup.future);
        expect(controller.movieId, null);
        controller.hide();
        lookup.complete(42);
        time.flushMicrotasks();
        expect(controller.movieId, 42);
        expect(controller.visible, false);
        expect(controller.canRequest, false);
        controller.activate();
        expect(controller.visible, true);
        expect(skips, 0);
        expect(controller.focusedAction, CinemaAction.skip);
        controller.activate();
        expect(skips, 1);
      });
    },
  );

  test('navigation only moves focus; submitting locks duplicate activation', () {
    fakeAsync((time) {
      seerr.submission = Completer();
      enter();
      time.flushMicrotasks();
      expect(controller.focusedAction, CinemaAction.skip);
      controller.moveRight();
      expect(skips, 0);
      expect(seerr.submitted, isEmpty);
      controller.moveLeft();
      expect(controller.focusedAction, CinemaAction.request);
      controller.moveLeft();
      expect(seerr.submitted, isEmpty);
      controller.moveRight();
      expect(controller.focusedAction, CinemaAction.skip);
      controller.moveLeft();
      controller.activate();
      controller.request();
      time.flushMicrotasks();
      expect(seerr.submitted, [42]);
      expect(controller.seerrState, CinemaSeerrState.requesting);
      expect(controller.focusedAction, CinemaAction.skip);
      seerr.submission!.complete(
        const SeerrRequest(
          id: 1,
          status: SeerrRequest.statusApproved,
          type: 'movie',
        ),
      );
      time.flushMicrotasks();
      // Approved request status 2 must NOT be read as media status Pending (2).
      expect(controller.seerrState, CinemaSeerrState.requested);
    });
  });

  test('specific response media status wins over request acknowledgement', () {
    fakeAsync((time) {
      seerr.submission = Completer();
      enter();
      time.flushMicrotasks();
      controller.request();
      time.flushMicrotasks();
      seerr.submission!.complete(
        const SeerrRequest(
          id: 1,
          status: 2,
          type: 'movie',
          media: SeerrMedia(id: 1, status: SeerrMediaStatus.processing),
        ),
      );
      time.flushMicrotasks();
      expect(controller.seerrState, CinemaSeerrState.processing);
    });
  });

  test(
    'auto hide starts with playback, resets on navigation, pauses for request',
    () {
      fakeAsync((time) {
        seerr.submission = Completer();
        enter();
        time.flushMicrotasks();
        time.elapse(const Duration(seconds: 30));
        expect(controller.visible, true);
        controller.updatePlayback(
          duration: const Duration(seconds: 90),
          playing: true,
        );
        time.elapse(const Duration(seconds: 9));
        controller.moveLeft();
        time.elapse(const Duration(seconds: 9));
        expect(controller.visible, true);
        controller.request();
        time.flushMicrotasks();
        time.elapse(const Duration(seconds: 11));
        expect(controller.visible, true);
        controller.hide();
        expect(controller.visible, false);
        seerr.submission!.complete(
          const SeerrRequest(id: 1, status: 2, type: 'movie'),
        );
        time.flushMicrotasks();
        expect(controller.visible, false);
        controller.reveal();
        time.elapse(const Duration(seconds: 10));
        expect(controller.visible, false);
      });
    },
  );

  test('disabled statuses and denied movie permission cannot receive request focus', () {
    fakeAsync((time) {
      seerr.info = const SeerrMediaInfo(
        status: SeerrMediaStatus.partiallyAvailable,
      );
      enter();
      time.flushMicrotasks();
      controller.moveLeft();
      expect(controller.focusedAction, CinemaAction.skip);
      seerr.permissions = SeerrPermission.requestTv;
      enter();
      time.flushMicrotasks();
      expect(controller.seerrState, CinemaSeerrState.hidden);
      expect(controller.movieId, 42);
    });
  });

  test('stale identity is discarded even when the same item returns later', () {
    fakeAsync((time) {
      final old = Completer<int?>();
      enter(tmdb: null, resolve: old.future);
      enter(tmdb: 43);
      enter(tmdb: null);
      old.complete(42);
      time.flushMicrotasks();
      expect(controller.movieId, null);
      expect(controller.seerrState, CinemaSeerrState.hidden);
    });
  });

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

  test('completion for the old movie cannot replace the new movie status', () {
    fakeAsync((time) {
      seerr.submission = Completer();
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
      expect(controller.movieId, 99);
      expect(controller.seerrState, CinemaSeerrState.request);
      expect(seerr.submitted, [42]);
    });
  });

  test('failure reconciles once and never automatically resubmits', () {
    fakeAsync((time) {
      enter();
      time.flushMicrotasks();
      seerr.failure = StateError('offline');
      seerr.info = const SeerrMediaInfo(status: SeerrMediaStatus.pending);
      controller.request();
      time.flushMicrotasks();
      expect(seerr.submitted, [42]);
      expect(seerr.lookups, 2);
      expect(controller.seerrState, CinemaSeerrState.pending);
      expect(errors, hasLength(1));
    });
  });

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
