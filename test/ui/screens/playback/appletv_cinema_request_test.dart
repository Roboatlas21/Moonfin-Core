import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moonfin/auth/repositories/session_repository.dart';
import 'package:moonfin/data/repositories/seerr_repository.dart';
import 'package:moonfin/data/services/seerr/seerr_api_models.dart';
import 'package:moonfin/l10n/app_localizations.dart';
import 'package:moonfin/playback/appletv_backend.dart';
import 'package:moonfin/preference/seerr_preferences.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:moonfin/ui/screens/playback/appletv_player_host_screen.dart';
import 'package:playback_core/playback_core.dart';
import 'package:server_core/server_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Manager extends Mock implements PlaybackManager {}

class _Session extends Fake implements SessionRepository {
  @override
  String? get activeServerId => 'server';
  @override
  String? get activeUserId => 'user';
}

class _Preferences extends Fake implements SeerrPreferences {}

class _Repository extends Fake implements SeerrRepository {
  final lookups = <int>[];
  final posts = <int, Completer<SeerrRequest>>{};
  final quotas = <Completer<SeerrQuota>>[];
  final confirmed = <int>{};

  @override
  bool get isAvailable => true;
  @override
  Future<void> ensureInitialized({bool force = false}) async {}
  @override
  Future<SeerrUser> getCurrentUser() async =>
      const SeerrUser(id: 5, permissions: SeerrPermission.requestTv);
  @override
  Future<SeerrTvDetails> getTvDetails(int tmdbId) async {
    lookups.add(tmdbId);
    return SeerrTvDetails(
      id: tmdbId,
      numberOfSeasons: 1,
      mediaInfo: confirmed.contains(tmdbId)
          ? const SeerrMediaInfo(
              status: SeerrMediaStatus.processing,
              requests: [
                SeerrRequest(
                  id: 1,
                  type: 'tv',
                  status: SeerrRequest.statusApproved,
                  seasons: [
                    SeerrSeasonRequest(id: 1, seasonNumber: 1, status: 2),
                  ],
                ),
              ],
            )
          : null,
    );
  }

  @override
  Future<SeerrQuota> getUserQuota(int userId) {
    final result = Completer<SeerrQuota>();
    quotas.add(result);
    return result.future;
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
    expect(mediaType, 'tv');
    expect(seasons, [1]);
    expect(posts.containsKey(mediaId), isFalse, reason: 'Never retry the POST');
    final result = Completer<SeerrRequest>();
    posts[mediaId] = result;
    return result.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const control = MethodChannel('moonfin/appletv_video_control');
  const events = MethodChannel('moonfin/appletv_video_events');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late _Repository repository;
  late AppleTvBackend backend;
  late UserPreferences preferences;
  late QueueService queue;
  late PlayerState playerState;
  final calls = <MethodCall>[];
  final pickers = <int, Completer<Map<String, dynamic>?>>{};

  setUp(() async {
    await GetIt.instance.reset();
    calls.clear();
    pickers.clear();
    messenger.setMockMethodCallHandler(control, (call) async {
      calls.add(call);
      if (call.method == 'showCinemaRequestOptions') {
        final result = Completer<Map<String, dynamic>?>();
        pickers[call.arguments['requestId'] as int] = result;
        return result.future;
      }
      if (call.method == 'dismissCinemaRequestOptions') {
        final picker = pickers[call.arguments['requestId']];
        if (picker != null && !picker.isCompleted) picker.complete(null);
      }
      return call.method == 'updateCinemaRequestQuota' ? true : null;
    });
    messenger.setMockMethodCallHandler(events, (_) async => null);
    SharedPreferences.setMockInitialValues({});
    final store = PreferenceStore();
    await store.init();
    preferences = UserPreferences(store);
    backend = AppleTvBackend(preferences);
    repository = _Repository();
    playerState = PlayerState();
    queue = QueueService()
      ..setQueue([
        for (final id in [42, 43])
          <String, dynamic>{
            'Id': 'intro-$id',
            'Type': 'Video',
            '__moonfinIsPreroll': true,
            'RunTimeTicks': 900000000,
            'ProviderIds': {
              'Tmdb': '$id',
              'TmdbMediaType': 'tv',
              'TmdbSeason': '1',
            },
          },
      ]);
    final manager = _Manager();
    when(() => manager.bringupState).thenAnswer(
      (_) => PlaybackBringupState(
        phase: PlaybackBringupPhase.ready,
        itemId: queue.currentItem['Id'] as String,
        sessionToken: queue.currentIndex + 1,
      ),
    );
    when(() => manager.bringupStateStream)
        .thenAnswer((_) => const Stream<PlaybackBringupState>.empty());
    when(() => manager.sessionEndedStream)
        .thenAnswer((_) => const Stream<void>.empty());
    when(() => manager.queueService).thenReturn(queue);
    when(() => manager.state).thenReturn(playerState);
    when(() => manager.playbackDeferredToExternalPlayer).thenReturn(false);
    when(() => manager.nextInQueue()).thenAnswer((_) async {
      queue.next();
    });
    when(() => manager.stop(userInitiated: any(named: 'userInitiated')))
        .thenAnswer((_) async {});
    GetIt.instance.registerSingleton<PlaybackManager>(manager);
    GetIt.instance.registerSingleton<AppleTvBackend>(backend);
    GetIt.instance.registerSingleton<UserPreferences>(preferences);
    GetIt.instance.registerSingleton<SessionRepository>(_Session());
    GetIt.instance.registerSingleton<SeerrPreferences>(_Preferences());
    GetIt.instance.registerSingletonAsync<SeerrRepository>(
      () async => repository,
    );
    await GetIt.instance.allReady();
  });

  tearDown(() async {
    backend.dispose();
    preferences.dispose();
    queue.dispose();
    playerState.dispose();
    await GetIt.instance.reset();
    messenger.setMockMethodCallHandler(control, null);
    messenger.setMockMethodCallHandler(events, null);
  });

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: [Locale('en')],
        home: AppleTvPlayerHostScreen(),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> action(WidgetTester tester, String action) async {
    final state = calls.lastWhere((call) => call.method == 'setCinemaActions');
    await messenger.handlePlatformMessage(
      events.name,
      const StandardMethodCodec().encodeSuccessEnvelope({
        'event': 'cinemaAction',
        'action': action,
        'generation': state.arguments['generation'],
      }),
      (_) {},
    );
    await tester.pumpAndSettle();
  }

  Future<int> openPicker(WidgetTester tester) async {
    await action(tester, 'left');
    await action(tester, 'select');
    return pickers.keys.last;
  }

  Future<void> submit(WidgetTester tester, int id) async {
    pickers[id]!.complete({
      'requestId': id,
      'allSeasons': false,
      'seasons': [1],
    });
    await tester.pumpAndSettle();
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    for (final picker in pickers.values) {
      if (!picker.isCompleted) picker.complete(null);
    }
    for (final post in repository.posts.values) {
      if (!post.isCompleted) {
        post.complete(const SeerrRequest(id: 1, type: 'tv', status: 2));
      }
    }
    for (final quota in repository.quotas) {
      if (!quota.isCompleted) quota.complete(const SeerrQuota());
    }
    await tester.pumpAndSettle();
  }

  for (final confirmed in [true, false]) {
    testWidgets(
      'next picker preserves earlier timeout reconciliation ($confirmed)',
      (tester) async {
        await mount(tester);
        await submit(tester, await openPicker(tester));
        expect(repository.posts.keys, [42]);
        await action(tester, 'select'); // Skip remains focused during the POST.
        expect(queue.currentIndex, 1);
        final next = await openPicker(tester);
        if (confirmed) repository.confirmed.add(42);

        await tester.pump(const Duration(seconds: 20));
        await tester.pumpAndSettle();
        expect(repository.lookups.where((id) => id == 42), hasLength(2));
        expect(repository.posts.keys, [42]);
        expect(pickers[next]!.isCompleted, isFalse);
        expect(
          calls.where((call) => call.method == 'showCinemaError'),
          hasLength(confirmed ? 0 : 1),
        );
        await unmount(tester);
      },
    );
  }

  testWidgets('prior trailer rejection leaves the next native picker active', (
    tester,
  ) async {
    await mount(tester);
    await submit(tester, await openPicker(tester));
    await action(tester, 'select'); // Skip while the original POST is pending.
    final next = await openPicker(tester);

    repository.posts[42]!.completeError(StateError('Seerr rejected request'));
    await tester.pumpAndSettle();

    expect(repository.posts.keys, [42]);
    expect(pickers[next]!.isCompleted, isFalse);
    expect(
      calls.where((call) => call.method == 'showCinemaError'),
      hasLength(1),
    );
    expect(
      calls.where(
        (call) =>
            call.method == 'dismissCinemaRequestOptions' &&
            call.arguments['requestId'] == next,
      ),
      isEmpty,
    );
    await unmount(tester);
  });

  testWidgets(
    'Submit near grace expiry preserves the POST after the deadline',
    (tester) async {
      await mount(tester);
      final picker = await openPicker(tester);
      queue.next(); // Natural trailer completion leaves the old picker open.
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 9));
      await submit(tester, picker);
      await tester.pump(const Duration(seconds: 2));
      expect(repository.posts.keys, [42]);
      expect(
        calls.where((call) => call.method == 'dismissCinemaRequestOptions'),
        isEmpty,
      );
      repository.posts[42]!.completeError(StateError('Seerr rejected request'));
      await tester.pumpAndSettle();
      expect(
        calls.where((call) => call.method == 'showCinemaError'),
        hasLength(1),
      );
      await unmount(tester);
    },
  );

  testWidgets('quota arriving before a native selection reports its rejection', (
    tester,
  ) async {
    await mount(tester);
    final picker = await openPicker(tester);
    repository.quotas.single.complete(
      const SeerrQuota(tv: SeerrQuotaDetail(limit: 1, remaining: 0)),
    );
    await tester.pumpAndSettle();
    // UIKit may have already accepted Submit while this update was in transit.
    await submit(tester, picker);
    expect(repository.posts, isEmpty);
    expect(
      calls.where((call) => call.method == 'showCinemaError'),
      hasLength(1),
    );
    await unmount(tester);
  });

  testWidgets('late quota cannot revoke Submit; unmount stops reconciliation', (
    tester,
  ) async {
    await mount(tester);
    await submit(tester, await openPicker(tester));
    repository.quotas.single.complete(
      const SeerrQuota(tv: SeerrQuotaDetail(limit: 1, remaining: 0)),
    );
    await tester.pumpAndSettle();
    expect(repository.posts.keys, [42]);
    expect(
      calls.where((call) => call.method == 'updateCinemaRequestQuota'),
      isEmpty,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 20));
    expect(repository.lookups, [42]);
    expect(calls.where((call) => call.method == 'showCinemaError'), isEmpty);
    await unmount(tester);
  });
}
