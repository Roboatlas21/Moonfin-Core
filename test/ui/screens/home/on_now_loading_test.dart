import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moonfin/auth/models/user.dart';
import 'package:moonfin/auth/repositories/user_repository.dart';
import 'package:moonfin/data/models/aggregated_item.dart';
import 'package:moonfin/data/models/home_row.dart';
import 'package:moonfin/data/repositories/multi_server_repository.dart';
import 'package:moonfin/data/services/plugin_sync_service.dart';
import 'package:moonfin/data/services/plex_live_tv_favorites.dart';
import 'package:moonfin/data/services/row_data_source.dart';
import 'package:moonfin/data/services/user_data_sync.dart';
import 'package:moonfin/data/viewmodels/media_bar_view_model.dart';
import 'package:moonfin/preference/home_section_config.dart';
import 'package:moonfin/preference/preference_constants.dart';
import 'package:moonfin/preference/seerr_preferences.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:moonfin/ui/screens/home/home_view_model.dart';
import 'package:server_core/server_core.dart';
import 'package:server_plex/server_plex.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockDataSource extends Mock implements RowDataSource {}

class _MockClient extends Mock implements MediaServerClient {}

class _MockPlexClient extends Mock implements PlexMediaServerClient {}

class _CloudFavorites extends Mock implements PlexLiveTvFavoritesApi {}

class _LiveTvApi extends Mock implements LiveTvApi {}

class _MockMediaBar extends Mock implements MediaBarViewModel {}

class _MockMultiServer extends Mock implements MultiServerRepository {}

class _MockSync extends Mock implements PluginSyncService {}

class _MockSeerrPrefs extends Mock implements SeerrPreferences {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _MockDataSource source;
  late HomeViewModel model;
  late UserPreferences prefs;

  HomeViewModel homeFor(MediaServerClient client) {
    when(() => client.userId).thenReturn('user');
    when(() => client.baseUrl).thenReturn('http://server.test');
    final mediaBar = _MockMediaBar();
    when(() => mediaBar.load(force: any(named: 'force')))
        .thenAnswer((_) async {});
    return HomeViewModel(
      dataSource: source,
      prefs: prefs,
      client: client,
      mediaBarViewModel: mediaBar,
      multiServerRepo: _MockMultiServer(),
    );
  }

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    SharedPreferences.setMockInitialValues({});
    final store = PreferenceStore();
    await store.init();
    prefs = UserPreferences(store);
    await prefs.setHomeSectionsConfig([
      for (final config in HomeSectionConfig.defaults())
        config.copyWith(enabled: config.type == HomeSectionType.onNow),
    ]);
    await prefs.set(
      UserPreferences.lastExternalRowsRefreshTime,
      DateTime.now().millisecondsSinceEpoch,
    );

    final sync = _MockSync();
    when(() => sync.seerrAvailable).thenReturn(false);
    when(() => sync.pluginAvailable).thenReturn(false);
    GetIt.instance.registerSingleton<PluginSyncService>(sync);
    GetIt.instance.registerSingleton<SeerrPreferences>(_MockSeerrPrefs());

    source = _MockDataSource();
    final client = _MockClient();
    model = homeFor(client);

  });

  tearDown(() async {
    model.dispose();
    debugDefaultTargetPlatformOverride = null;
    await GetIt.instance.reset();
  });

  HomeRow favoriteChannels([List<AggregatedItem> items = const []]) =>
      HomeRow(
        id: 'liveTvFavorites',
        title: 'Favorite Channels',
        rowType: HomeRowType.liveTvFavorites,
        items: items,
      );

  void stubLiveTvRows() {
    when(() => source.hasLiveTvChannels()).thenAnswer((_) async => true);
    when(() => source.loadOnNow('http://server.test')).thenAnswer(
      (_) async => HomeRow(
        id: 'liveTvOnNow',
        title: 'On Now',
        rowType: HomeRowType.liveTvOnNow,
        items: [
          AggregatedItem(
            id: 'program',
            serverId: 'http://server.test',
            rawData: {'Type': 'Program'},
          ),
        ],
      ),
    );
    when(() => source.loadFavoritesChannels('http://server.test'))
        .thenAnswer((_) async => favoriteChannels());
  }

  void stubFavoriteChannel() {
    when(() => source.loadFavoritesChannels('http://server.test')).thenAnswer(
      (_) async => favoriteChannels([
        AggregatedItem(
          id: 'favorite',
          serverId: 'http://server.test',
          rawData: {'Type': 'TvChannel'},
        ),
      ]),
    );
  }

  Future<HomeRow> loadPopulatedRow() async {
    stubLiveTvRows();
    await model.load();
    return model.rows.single;
  }

  test(
    'a failed channel check preserves the visible row during refresh',
    () async {
      final existing = await loadPopulatedRow();
      when(() => source.hasLiveTvChannels())
          .thenThrow(Exception('unavailable'));

      await model.load(preserveExisting: true);

      expect(model.rows.single, same(existing));
      expect(model.isLoading, isFalse);
    },
  );

  test(
    'a failed program request preserves the visible row during refresh',
    () async {
      final existing = await loadPopulatedRow();
      when(() => source.loadOnNow('http://server.test'))
          .thenThrow(Exception('EPG unavailable'));

      await model.load(preserveExisting: true);

      expect(model.rows.single, same(existing));
      expect(model.isLoading, isFalse);
    },
  );

  test(
    'confirmed absence of channels removes the visible row during refresh',
    () async {
      await loadPopulatedRow();
      when(() => source.hasLiveTvChannels()).thenAnswer((_) async => false);

      await model.load(preserveExisting: true);

      expect(model.rows, isEmpty);
    },
  );

  test(
    'a successful empty EPG response removes the visible row during refresh',
    () async {
      await loadPopulatedRow();
      when(() => source.loadOnNow('http://server.test')).thenAnswer(
        (_) async => const HomeRow(
          id: 'liveTvOnNow',
          title: 'On Now',
          rowType: HomeRowType.liveTvOnNow,
        ),
      );

      await model.load(preserveExisting: true);

      expect(model.rows, isEmpty);
    },
  );

  test(
    'no Live TV channels skips program loading and clears the placeholder',
    () async {
      when(() => source.hasLiveTvChannels()).thenAnswer((_) async => false);

      await model.load();

      verify(() => source.hasLiveTvChannels()).called(1);
      verifyNever(() => source.loadOnNow(any()));
      expect(model.rows, isEmpty);
      expect(model.isLoading, isFalse);
    },
  );

  test('a failed channel check skips program loading without leaving a placeholder', () async {
    when(() => source.hasLiveTvChannels()).thenThrow(Exception('unavailable'));

    await model.load();

    verify(() => source.hasLiveTvChannels()).called(1);
    verifyNever(() => source.loadOnNow(any()));
    expect(model.rows, isEmpty);
    expect(model.isLoading, isFalse);
  });

  Future<void> enableSections(Set<HomeSectionType> types) =>
      prefs.setHomeSectionsConfig([
        for (final config in HomeSectionConfig.defaults())
          config.copyWith(enabled: types.contains(config.type)),
      ]);

  test(
    'Live TV leaves On Now to the standalone section when both are on',
    () async {
      await enableSections({HomeSectionType.liveTv, HomeSectionType.onNow});
      stubLiveTvRows();

      await model.load();

      expect(model.rows.map((row) => row.id), ['liveTv', 'onNow']);
      verify(() => source.loadOnNow('http://server.test')).called(1);
    },
  );

  test(
    'Live TV keeps its own On Now row when the standalone section is off',
    () async {
      await enableSections({HomeSectionType.liveTv});
      stubLiveTvRows();

      await model.load();

      expect(model.rows.map((row) => row.id), ['liveTv', 'liveTvOnNow']);
    },
  );

  test('returning from Kids Mode restores live rows even when listings go offline', () async {
    await enableSections({HomeSectionType.liveTv});
    stubLiveTvRows();
    stubFavoriteChannel();
    await model.load();
    final ids = model.rows.map((row) => row.id).toList();
    expect(ids, ['liveTv', 'liveTvOnNow', 'liveTvFavorites']);
    await prefs.set(UserPreferences.kidsModeEnabled, true);
    expect(model.rows, isEmpty);
    when(() => source.loadOnNow('http://server.test')).thenThrow(Exception('EPG unavailable'));
    await prefs.set(UserPreferences.kidsModeEnabled, false);
    expect(model.rows.map((row) => row.id), ids);
    await model.load();
    expect(model.rows.map((row) => row.id), ['liveTv', 'liveTvFavorites']);
  });

  test(
    'available channels load airing programs as the standalone row',
    () async {
      when(() => source.hasLiveTvChannels()).thenAnswer((_) async => true);
      final program = AggregatedItem(
        id: 'program',
        serverId: 'http://server.test',
        rawData: {'Type': 'Program'},
      );
      when(() => source.loadOnNow('http://server.test')).thenAnswer(
        (_) async => HomeRow(
          id: 'liveTvOnNow',
          title: 'On Now',
          rowType: HomeRowType.liveTvOnNow,
          items: [program],
        ),
      );

      await model.load();

      expect(model.rows.single.id, 'onNow');
      expect(model.rows.single.items, [program]);
      expect(model.isLoading, isFalse);
    },
  );

  for (final serverType in [ServerType.jellyfin, ServerType.emby, ServerType.plex]) {
    test('returning from the guide updates ${serverType.name} channel favorites', () async {
      await enableSections({HomeSectionType.liveTv});
      stubLiveTvRows();
      final MediaServerClient serverClient;
      if (serverType == ServerType.plex) {
        final plex = _MockPlexClient();
        serverClient = plex;
      } else {
        serverClient = _MockClient();
      }
      when(() => serverClient.serverType).thenReturn(serverType);
      var favorites = <AggregatedItem>[];
      when(() => source.loadFavoritesChannels('http://server.test'))
          .thenAnswer((_) async => favoriteChannels(List.of(favorites)));
      model.dispose();
      model = homeFor(serverClient);
      await model.load();
      expect(model.rows.any((r) => r.rowType == HomeRowType.liveTvFavorites), isFalse);

      favorites = [
        AggregatedItem(
          id: 'favorite-channel',
          serverId: 'http://server.test',
          rawData: {'Type': 'TvChannel', 'Name': 'Favorite Channel'},
        ),
      ];
      await model.refreshResumeAndNextUp();
      expect(model.rows.map((r) => r.id), contains('liveTvFavorites'));
      expect(
        model.rows.firstWhere((r) => r.rowType == HomeRowType.liveTvFavorites).items.single.id,
        'favorite-channel',
      );

      favorites = [];
      await model.refreshResumeAndNextUp();
      expect(model.rows.any((r) => r.rowType == HomeRowType.liveTvFavorites), isFalse);
      verify(() => source.loadFavoritesChannels('http://server.test')).called(3);
      verify(() => source.hasLiveTvChannels()).called(1);
    });
  }

  test('return to Home waits for the Plex account favorites and keeps them through an outage', () async {
    await enableSections({HomeSectionType.liveTv});
    stubLiveTvRows();
    final client = _MockPlexClient();
    final api = _LiveTvApi();
    const device = DeviceInfo(id: 'device', name: 'Test', appName: 'Moonfin', appVersion: '1');
    when(() => client.serverType).thenReturn(ServerType.plex);
    when(() => client.deviceInfo).thenReturn(device);
    when(() => client.liveTvApi).thenReturn(api);
    when(() => api.getChannels(fields: 'ImageTags,UserData')).thenAnswer((_) async => {
      'Items': [
        {'Id': 'channel-plex-news', 'Name': 'News', 'Type': 'TvChannel'},
      ],
    });
    final rows = RowDataSource(client);
    when(() => source.loadFavoritesChannels('http://server.test'))
        .thenAnswer((_) => rows.loadFavoritesChannels('http://server.test'));
    final users = UserRepository()..setCurrentUser(PrivateUser(
      id: 'user', name: 'Viewer', serverId: 'pms', accessToken: 'local',
      plexToken: 'account', lastUsed: DateTime.utc(2026),
    ));
    GetIt.instance.registerSingleton<UserRepository>(users);
    addTearDown(users.dispose);
    GetIt.instance.registerSingleton<UserPreferences>(prefs);
    final cloud = _CloudFavorites();
    PlexLiveTvFavorites.testApi = cloud;
    addTearDown(PlexLiveTvFavorites.resetForTesting);
    Future<List<Map<String, dynamic>>> read() =>
        cloud.readFavorites(deviceInfo: device, accountToken: 'account');
    when(read).thenAnswer((_) async => []);
    model.dispose();
    model = homeFor(client);
    await model.load();
    await pumpEventQueue();
    verify(read).called(1);

    final delayed = Completer<List<Map<String, dynamic>>>();
    when(read).thenAnswer((_) => delayed.future);
    var returns = 0;
    final returning = Future.wait([
      for (var i = 0; i < 2; i++)
        model.refreshResumeAndNextUp().then((_) => returns++),
    ]);
    await pumpEventQueue();
    final earlyReturns = returns;
    delayed.complete([{'source': 'provider://tv.plex.provider.epg', 'id': 'news'}]);
    await returning;
    verify(read).called(1);
    expect(earlyReturns, 0);
    Iterable<String> favorites() => model.rows.where((r) => r.rowType == HomeRowType.liveTvFavorites)
        .expand((row) => row.items.map((item) => item.id));
    expect(favorites(), ['channel-plex-news']);

    when(read).thenThrow(StateError('Plex Cloud unavailable'));
    await model.refreshResumeAndNextUp();
    expect(favorites(), ['channel-plex-news']);
    when(read).thenAnswer((_) async => []);
    await model.refreshResumeAndNextUp();
    expect(favorites(), isEmpty);

    final other = _MockPlexClient();
    when(() => other.userId).thenReturn('user');
    when(() => other.serverType).thenReturn(ServerType.plex);
    when(() => other.deviceInfo).thenReturn(device);
    when(read).thenAnswer((_) async => [
      {'source': 'provider://tv.plex.provider.epg', 'id': 'news'},
    ]);
    await PlexLiveTvFavorites.refresh(other);
    await pumpEventQueue();
    final key = PlexLiveTvFavorites.syncKey(client, 'channel-plex-news');
    expect(userDataSync.favoriteFor(key), isFalse);
    bool cardIsFavorite() => model.rows
        .singleWhere((row) => row.rowType == HomeRowType.liveTvFavorites)
        .items.single.isFavorite;
    expect(cardIsFavorite(), isTrue);

    userDataSync.addListener(model.applyUserDataChanges);
    addTearDown(() {
      userDataSync.removeListener(model.applyUserDataChanges);
      userDataSync.reset();
    });
    userDataSync.publish('unrelated-movie', {'Played': true});
    expect(cardIsFavorite(), isTrue);
    userDataSync.requestFavorite(key, false);
    userDataSync.publish('unrelated-movie', {'Played': false});
    expect(cardIsFavorite(), isFalse);
  });

  test('a favorites row read for a previous Home user cannot replace the current row', () async {
    await enableSections({HomeSectionType.liveTv});
    stubLiveTvRows();
    stubFavoriteChannel();
    final client = _MockPlexClient();
    when(() => client.serverType).thenReturn(ServerType.plex);
    model.dispose();
    model = homeFor(client);
    await model.load();
    final entered = Completer<void>(), release = Completer<HomeRow>();
    when(() => source.loadFavoritesChannels('http://server.test')).thenAnswer((_) {
      entered.complete();
      return release.future;
    });
    final returning = model.refreshResumeAndNextUp();
    await entered.future;
    when(() => client.userId).thenReturn('another user');
    release.complete(favoriteChannels());
    await returning;
    expect(model.rows.singleWhere((row) => row.rowType == HomeRowType.liveTvFavorites)
        .items.single.id, 'favorite');
  });

  group('returning to Home', () {
    HomeRow airing(List<String> ids) => HomeRow(
      id: 'liveTvOnNow',
      title: 'On Now',
      rowType: HomeRowType.liveTvOnNow,
      items: [
        for (final id in ids)
          AggregatedItem(
            id: id,
            serverId: 'http://server.test',
            rawData: {'Type': 'Program'},
          ),
      ],
    );

    test('refreshes On Now in place', () async {
      await loadPopulatedRow();
      when(() => source.loadOnNow('http://server.test'))
          .thenAnswer((_) async => airing(['next']));

      await model.refreshResumeAndNextUp();

      expect(model.rows.single.id, 'onNow');
      expect(model.rows.single.items.map((item) => item.id), ['next']);
    });

    test('a second return while the first is out waits on it', () async {
      await loadPopulatedRow();
      final answer = Completer<HomeRow>();
      when(() => source.loadOnNow('http://server.test'))
          .thenAnswer((_) => answer.future);
      clearInteractions(source);

      final first = model.refreshResumeAndNextUp();
      var secondDone = false;
      final second = model.refreshResumeAndNextUp().then(
        (_) => secondDone = true,
      );
      await pumpEventQueue();
      expect(secondDone, isFalse);

      answer.complete(airing(['next']));
      await Future.wait([first, second]);

      verify(() => source.loadOnNow('http://server.test')).called(1);
      expect(model.rows.single.items.map((item) => item.id), ['next']);
    });

    test('brings On Now back once programs are airing', () async {
      when(() => source.hasLiveTvChannels()).thenAnswer((_) async => true);
      when(() => source.loadOnNow('http://server.test'))
          .thenAnswer((_) async => airing(const []));
      await model.load();
      expect(model.rows, isEmpty);

      when(() => source.loadOnNow('http://server.test'))
          .thenAnswer((_) async => airing(['program']));
      await model.refreshResumeAndNextUp();

      expect(model.rows.map((row) => row.id), ['onNow']);
    });

    test('asks nothing for Live TV without channels', () async {
      await enableSections({HomeSectionType.liveTv});
      when(() => source.hasLiveTvChannels()).thenAnswer((_) async => false);
      await model.load();
      expect(model.rows, isEmpty);

      await model.refreshResumeAndNextUp();

      verifyNever(() => source.loadOnNow(any()));
    });
  });
}
