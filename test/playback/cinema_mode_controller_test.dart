import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/repositories/seerr_repository.dart';
import 'package:moonfin/data/services/seerr/seerr_api_models.dart';
import 'package:moonfin/playback/cinema_mode_controller.dart';

class FakeCinemaSeerr extends Fake implements SeerrRepository {
  SeerrMediaInfo? info;
  int permissions = SeerrPermission.requestMovie;
  bool movie4kEnabled = true;
  Completer<Map<String, dynamic>>? settingsResponse;
  Completer<SeerrRequest>? submission;
  int lookups = 0;
  final submitted = <int>[];
  final requested4k = <bool>[];

  @override
  bool get isAvailable => true;

  @override
  Future<void> ensureInitialized({bool force = false}) async {}

  @override
  Future<SeerrUser> getCurrentUser() async =>
      SeerrUser(id: 5, permissions: permissions);

  @override
  Future<Map<String, dynamic>> getPublicSettings() =>
      settingsResponse?.future ??
      Future.value({'movie4kEnabled': movie4kEnabled});

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
  }) {
    expect(mediaType, 'movie');
    submitted.add(mediaId);
    requested4k.add(is4k);
    return submission?.future ??
        Future.value(const SeerrRequest(
          id: 1,
          status: SeerrRequest.statusApproved,
          type: 'movie',
        ));
  }
}

Map<String, dynamic> cinemaItem({int tmdb = 42}) => {
  'Type': 'Movie',
  'RunTimeTicks': 900000000,
  'ProviderIds': {'Tmdb': '$tmdb'},
};

Future<void> flush() => Future<void>.delayed(Duration.zero);

void main() {
  test('movie statuses distinguish available, blocked and requestable', () {
    for (final entry in {
      1: CinemaSeerrState.request,
      2: CinemaSeerrState.pending,
      5: CinemaSeerrState.available,
      6: CinemaSeerrState.hidden,
      7: CinemaSeerrState.request,
      999: CinemaSeerrState.hidden,
    }.entries) {
      expect(cinemaSeerrState(mediaStatus: entry.key), entry.value);
    }
  });

  late FakeCinemaSeerr seerr;
  late CinemaModeController controller;
  var skips = 0;

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

  test('a late movie request cannot change the next trailer', () {
    fakeAsync((clock) {
      seerr.submission = Completer<SeerrRequest>();
      enter();
      clock.flushMicrotasks();
      controller.request();
      clock.flushMicrotasks();

      enter(tmdb: 99);
      clock.flushMicrotasks();
      seerr.submission!.complete(
        const SeerrRequest(id: 1, status: 2, type: 'movie'),
      );
      clock.flushMicrotasks();
      expect(controller.media?.tmdbId, 99);
      expect(controller.canRequest, isTrue);
    });
  });

  test('an uncertain movie timeout never submits the same quality twice', () {
    fakeAsync((clock) {
      seerr.submission = Completer<SeerrRequest>();
      seerr.info = const SeerrMediaInfo(status: SeerrMediaStatus.unknown);
      enter();
      clock.flushMicrotasks();
      controller.request();
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 20));
      clock.flushMicrotasks();

      expect(seerr.lookups, 2);
      expect(controller.canRequest, isFalse);
      controller.request();
      clock.flushMicrotasks();
      expect(seerr.submitted, [42]);

      seerr.submission!.complete(
        const SeerrRequest(id: 1, status: 2, type: 'movie'),
      );
      clock.flushMicrotasks();
      expect(controller.canRequest, isFalse);
    });
  });

  test('standard Request works while optional 4K settings are pending', () async {
    seerr.permissions =
        SeerrPermission.requestMovie | SeerrPermission.request4kMovie;
    seerr.info = const SeerrMediaInfo(
      status: SeerrMediaStatus.unknown,
      status4k: SeerrMediaStatus.available,
    );
    seerr.settingsResponse = Completer<Map<String, dynamic>>();
    enter();
    await flush();
    expect(controller.canRequest, isTrue);

    // Submit before the settings request has finished.
    await controller.request();
    expect(seerr.requested4k, [false]);
    seerr.settingsResponse!.complete({'movie4kEnabled': false});
    await flush();
  });

  test('a disabled 4K backend blocks a 4K-only request', () async {
    seerr.permissions = SeerrPermission.request4kMovie;
    seerr.movie4kEnabled = false;
    enter();
    await flush();
    expect(controller.canRequest, isFalse);
    expect(seerr.submitted, isEmpty);
  });

  test('HD availability does not prevent a direct 4K request', () async {
    seerr.permissions =
        SeerrPermission.requestMovie | SeerrPermission.request4kMovie;
    seerr.info = const SeerrMediaInfo(
      status: SeerrMediaStatus.available,
      status4k: SeerrMediaStatus.unknown,
    );
    enter();
    await flush();
    expect(controller.only4kRequestable, isTrue);
    await controller.request();
    expect(seerr.requested4k, [true]);
  });

  test('both qualities prompt, then the remaining one submits directly', () async {
    seerr.permissions =
        SeerrPermission.requestMovie | SeerrPermission.request4kMovie;
    var prompts = 0;
    final choice = CinemaModeController(
      seerr: () async => seerr,
      accountKey: () => 'server/user',
      onSkip: () async {},
      onRequestMovie: (repository, details, user, isCurrent, submit) async {
        prompts++;
        await submit(true);
      },
    );
    try {
      choice.enter(item: cinemaItem(), resolveMedia: () async => null);
      await flush();
      await choice.request();
      expect(prompts, 1);
      expect(seerr.requested4k, [true]);

      await choice.request();
      expect(prompts, 1);
      expect(seerr.requested4k, [true, false]);
      expect(choice.canRequest, isFalse);
    } finally {
      choice.dispose();
    }
  });

  test('rapid double Skip does not advance twice', () {
    enter();
    controller.skip();
    controller.skip();
    expect(skips, 1);
    enter(tmdb: 99);
    controller.skip();
    expect(skips, 1);
  });
}
