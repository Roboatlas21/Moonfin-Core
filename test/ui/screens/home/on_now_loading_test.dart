import 'dart:async';

import 'package:dio/dio.dart';
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
import 'package:moonfin/data/services/plex_live_tv_favorites.dart';
import 'package:moonfin/data/services/plugin_sync_service.dart';
import 'package:moonfin/data/services/row_data_source.dart';
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

class _MockMediaBar extends Mock implements MediaBarViewModel {}

class _MockMultiServer extends Mock implements MultiServerRepository {}

class _MockSync extends Mock implements PluginSyncService {}

class _MockSeerrPrefs extends Mock implements SeerrPreferences {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _MockDataSource source;
  late HomeViewModel model;
  late UserPreferences prefs;

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
    when(() => client.userId).thenReturn('user');
    when(() => client.baseUrl).thenReturn('http://server.test');
    final mediaBar = _MockMediaBar();
    when(() => mediaBar.load(force: any(named: 'force')))
        .thenAnswer((_) async {});
    model = HomeViewModel(
      dataSource: source,
      prefs: prefs,
      client: client,
      mediaBarViewModel: mediaBar,
      multiServerRepo: _MockMultiServer(),
    );
  });

  tearDown(() async {
    model.dispose();
    debugDefaultTargetPlatformOverride = null;
    await GetIt.instance.reset();
  });

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
    when(() => source.loadFavoritesChannels('http://server.test')).thenAnswer(
      (_) async => const HomeRow(
        id: 'liveTvFavorites',
        title: 'Favorite Channels',
        rowType: HomeRowType.liveTvFavorites,
      ),
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

  test(
    'Plex Cloud shows its Live TV shortcut without a Free TV On Now row',
    () async {
      await enableSections({HomeSectionType.onNow});
      stubLiveTvRows();
      // The real cloud-only Plex API returns no On Now programs.
      when(() => source.loadOnNow('http://server.test')).thenAnswer(
        (_) async => const HomeRow(
          id: 'liveTvOnNow',
          title: 'On Now',
          rowType: HomeRowType.liveTvOnNow,
        ),
      );
      final cloudClient = _MockPlexClient();
      when(() => cloudClient.cloudOnly).thenReturn(true);
      when(() => cloudClient.serverType).thenReturn(ServerType.plex);
      when(() => cloudClient.userId).thenReturn('user');
      when(() => cloudClient.baseUrl).thenReturn('http://server.test');

      model.dispose();
      model = HomeViewModel(
        dataSource: source,
        prefs: prefs,
        client: cloudClient,
        mediaBarViewModel: _MockMediaBar(),
        multiServerRepo: _MockMultiServer(),
      );

      await model.load();

      expect(model.rows.map((row) => row.id), ['liveTv']);
      verify(() => source.loadOnNow('http://server.test')).called(1);
      verifyNever(() => source.hasLiveTvChannels());
    },
  );


  test('Plex Cloud restores its embedded On Now when saved standalone is on', () async {
    await enableSections({HomeSectionType.liveTv, HomeSectionType.onNow});
    stubLiveTvRows();
    var programs = <AggregatedItem>[];
    when(() => source.loadOnNow('http://server.test')).thenAnswer(
      (_) async => HomeRow(
        id: 'liveTvOnNow',
        title: 'On Now',
        rowType: HomeRowType.liveTvOnNow,
        items: List.of(programs),
      ),
    );
    final plex = _MockPlexClient();
    when(() => plex.cloudOnly).thenReturn(true);
    when(() => plex.serverType).thenReturn(ServerType.plex);
    when(() => plex.userId).thenReturn('user');
    when(() => plex.baseUrl).thenReturn('http://server.test');
    model.dispose();
    model = HomeViewModel(
      dataSource: source,
      prefs: prefs,
      client: plex,
      mediaBarViewModel: _MockMediaBar(),
      multiServerRepo: _MockMultiServer(),
    );
    await model.load();
    expect(model.rows.map((row) => row.id), ['liveTv']);

    programs = [
      AggregatedItem(
        id: 'now',
        serverId: 'http://server.test',
        rawData: {'Type': 'Program'},
      ),
    ];
    await model.refreshResumeAndNextUp();
    expect(model.rows.map((row) => row.id), ['liveTv', 'liveTvOnNow']);
  });

  test('Plex cloud favorites populate Home after the initial cached rows', () async {
    await enableSections({HomeSectionType.liveTv});
    stubLiveTvRows();
    PlexLiveTvFavorites.resetForTesting();
    GetIt.instance.registerSingleton<UserPreferences>(prefs);
    final users = UserRepository()..setCurrentUser(PrivateUser(
      id: 'plex-user', name: 'Viewer', serverId: 'plex-cloud',
      accessToken: 'pms-token', plexToken: 'cloud-token',
      lastUsed: DateTime.utc(2026),
    ));
    GetIt.instance.registerSingleton<UserRepository>(users);
    addTearDown(users.dispose);

    final pending = Completer<void>();
    final http = Dio()..interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        unawaited(pending.future.then((_) {
          handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: {'MediaContainer': {'FavoriteChannel': [
              {'source': 'provider://tv.plex.provider.epg', 'id': 'free123'},
            ]}},
          ));
        }));
      },
    ));
    PlexLiveTvFavorites.testHttp = http;
    addTearDown(() {
      PlexLiveTvFavorites.resetForTesting();
      http.close();
    });

    final cloudClient = _MockPlexClient();
    when(() => cloudClient.cloudOnly).thenReturn(true);
    when(() => cloudClient.serverType).thenReturn(ServerType.plex);
    when(() => cloudClient.userId).thenReturn('plex-user');
    when(() => cloudClient.baseUrl).thenReturn('http://server.test');
    when(() => cloudClient.deviceInfo).thenReturn(const DeviceInfo(
      id: 'device', name: 'Test', appName: 'Moonfin', appVersion: '1',
    ));
    when(() => source.loadOnNow('http://server.test')).thenAnswer(
      (_) async => const HomeRow(
        id: 'liveTvOnNow',
        title: 'On Now',
        rowType: HomeRowType.liveTvOnNow,
      ),
    );
    var loads = 0;
    when(() => source.loadFavoritesChannels('http://server.test')).thenAnswer(
      (_) async {
        loads++;
        return HomeRow(
          id: 'liveTvFavorites',
          title: 'Favorite Channels',
          rowType: HomeRowType.liveTvFavorites,
          items: prefs.get(Preference<List<String>>(
            key: 'plex_live_tv_favorite_keys_plex-user',
            defaultValue: const [],
          )).contains('provider://tv.plex.provider.epg\u0000free123')
              ? [
                  AggregatedItem(
                    id: 'channel-plex-free123',
                    serverId: 'http://server.test',
                    rawData: {'Type': 'TvChannel', 'Name': 'Free Channel'},
                  ),
                ]
              : const [],
        );
      },
    );

    model.dispose();
    model = HomeViewModel(
      dataSource: source,
      prefs: prefs,
      client: cloudClient,
      mediaBarViewModel: _MockMediaBar(),
      multiServerRepo: _MockMultiServer(),
    );
    await model.load();
    expect(model.rows.map((row) => row.id), ['liveTv']);
    expect(loads, 1);

    pending.complete();
    await pumpEventQueue();
    expect(prefs.get(Preference<List<String>>(
      key: 'plex_live_tv_favorite_keys_plex-user',
      defaultValue: const [],
    )), contains('provider://tv.plex.provider.epg\u0000free123'));
    expect(model.rows.map((row) => row.id), ['liveTv', 'liveTvFavorites']);
    expect(loads, 2);
  });

  test('Plex account changes rebuild Home favorite row membership', () async {
    await enableSections({HomeSectionType.liveTv});
    stubLiveTvRows();
    final plex = _MockPlexClient();
    when(() => plex.cloudOnly).thenReturn(true);
    when(() => plex.serverType).thenReturn(ServerType.plex);
    when(() => plex.userId).thenReturn('user');
    when(() => plex.baseUrl).thenReturn('http://server.test');

    var favorites = <AggregatedItem>[];
    var calls = 0;
    when(() => source.loadFavoritesChannels('http://server.test')).thenAnswer(
      (_) async {
        calls++;
        return HomeRow(
          id: 'liveTvFavorites',
          title: 'Favorite Channels',
          rowType: HomeRowType.liveTvFavorites,
          items: List.of(favorites),
        );
      },
    );
    model.dispose();
    model = HomeViewModel(
      dataSource: source,
      prefs: prefs,
      client: plex,
      mediaBarViewModel: _MockMediaBar(),
      multiServerRepo: _MockMultiServer(),
    );
    await model.load();
    expect(model.rows.map((row) => row.id), ['liveTv', 'liveTvOnNow']);
    final initialCalls = calls;

    favorites = [
      AggregatedItem(
        id: 'channel-plex-free123',
        serverId: 'http://server.test',
        rawData: {'Type': 'TvChannel', 'UserData': {'IsFavorite': true}},
      ),
    ];
    PlexLiveTvFavorites.favoriteListChanged.value = (userId: 'user', revision: 1);
    await pumpEventQueue();
    expect(model.rows.map((row) => row.id), ['liveTv', 'liveTvOnNow', 'liveTvFavorites']);
    expect(calls, initialCalls + 1);

    favorites = [];
    PlexLiveTvFavorites.favoriteListChanged.value = (userId: 'user', revision: 2);
    await pumpEventQueue();
    expect(model.rows.map((row) => row.id), ['liveTv', 'liveTvOnNow']);
    expect(calls, initialCalls + 2);

    PlexLiveTvFavorites.favoriteListChanged.value = (userId: 'other', revision: 3);
    await pumpEventQueue();
    expect(calls, initialCalls + 2);
    PlexLiveTvFavorites.favoriteListChanged.value = null;
  });

  test('an older favorites response cannot overwrite a newer Home load', () async {
    await enableSections({HomeSectionType.liveTv});
    stubLiveTvRows();
    final old = Completer<HomeRow>();
    var calls = 0;
    HomeRow favoriteRow(String id) => HomeRow(
      id: 'liveTvFavorites',
      title: 'Favorite Channels',
      rowType: HomeRowType.liveTvFavorites,
      items: [
        AggregatedItem(
          id: id,
          serverId: 'http://server.test',
          rawData: {'Type': 'TvChannel'},
        ),
      ],
    );
    when(() => source.loadFavoritesChannels('http://server.test'))
        .thenAnswer((_) {
      calls++;
      if (calls == 1) return Future.value(favoriteRow('initial'));
      if (calls == 2) return old.future;
      return Future.value(favoriteRow('new'));
    });

    await model.load();
    expect(model.rows.last.items.single.id, 'initial');
    final staleRefresh = model.refreshResumeAndNextUp();
    await pumpEventQueue();
    expect(calls, 2);

    await model.load(preserveExisting: true);
    expect(model.rows.any((row) =>
        row.rowType == HomeRowType.liveTvFavorites &&
        row.items.single.id == 'new'), isTrue);

    expect(model.rows.last.items.single.id, 'new');
    old.complete(favoriteRow('old'));
    await staleRefresh;
    expect(model.rows.last.items.single.id, 'new');
    expect(calls, 4);
  });

  test('failed On Now listings do not hide favorite channels', () async {
    await enableSections({HomeSectionType.liveTv});
    stubLiveTvRows();
    when(() => source.loadOnNow('http://server.test'))
        .thenAnswer((_) async => throw Exception('EPG unavailable'));
    when(() => source.loadFavoritesChannels('http://server.test')).thenAnswer(
      (_) async => HomeRow(
        id: 'liveTvFavorites',
        title: 'Favorite Channels',
        rowType: HomeRowType.liveTvFavorites,
        items: [
          AggregatedItem(
            id: 'favorite',
            serverId: 'http://server.test',
            rawData: {'Type': 'TvChannel'},
          ),
        ],
      ),
    );

    await model.load();

    expect(model.rows.map((row) => row.id), ['liveTv', 'liveTvFavorites']);
    verify(() => source.loadFavoritesChannels('http://server.test')).called(1);
  });

  test('Kids Mode hides every Live TV row without removing saved rows', () async {
    await enableSections({HomeSectionType.liveTv});
    stubLiveTvRows();
    when(() => source.loadFavoritesChannels('http://server.test')).thenAnswer(
      (_) async => HomeRow(
        id: 'liveTvFavorites',
        title: 'Favorite Channels',
        rowType: HomeRowType.liveTvFavorites,
        items: [
          AggregatedItem(
            id: 'favorite',
            serverId: 'http://server.test',
            rawData: {'Type': 'TvChannel'},
          ),
        ],
      ),
    );
    await model.load();
    final ids = model.rows.map((row) => row.id).toList();
    expect(ids, ['liveTv', 'liveTvOnNow', 'liveTvFavorites']);

    await prefs.set(UserPreferences.kidsModeEnabled, true);
    expect(model.rows, isEmpty);
    await prefs.set(UserPreferences.kidsModeEnabled, false);
    expect(model.rows.map((row) => row.id), ids);
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

  test('returning from the guide updates Plex Cloud channel favorites in place', () async {
    await enableSections({HomeSectionType.liveTv});
    stubLiveTvRows();
    final cloudClient = _MockPlexClient();
    when(() => cloudClient.cloudOnly).thenReturn(true);
    when(() => cloudClient.serverType).thenReturn(ServerType.plex);
    when(() => cloudClient.userId).thenReturn('user');
    when(() => cloudClient.baseUrl).thenReturn('http://server.test');
    when(() => source.loadOnNow('http://server.test')).thenAnswer(
      (_) async => const HomeRow(
        id: 'liveTvOnNow',
        title: 'On Now',
        rowType: HomeRowType.liveTvOnNow,
      ),
    );

    var favorites = <AggregatedItem>[];
    when(() => source.loadFavoritesChannels('http://server.test')).thenAnswer(
      (_) async => HomeRow(
        id: 'liveTvFavorites',
        title: 'Favorite Channels',
        rowType: HomeRowType.liveTvFavorites,
        items: List.of(favorites),
      ),
    );
    model.dispose();
    model = HomeViewModel(
      dataSource: source,
      prefs: prefs,
      client: cloudClient,
      mediaBarViewModel: _MockMediaBar(),
      multiServerRepo: _MockMultiServer(),
    );
    await model.load();
    expect(model.rows.map((r) => r.id), ['liveTv']);

    favorites = [
      AggregatedItem(
        id: 'channel-plex-123',
        serverId: 'http://server.test',
        rawData: {'Type': 'TvChannel', 'Name': 'Favorite Channel'},
      ),
    ];
    await model.refreshResumeAndNextUp();
    expect(model.rows.map((r) => r.id), ['liveTv', 'liveTvFavorites']);
    expect(model.rows.last.items.single.id, 'channel-plex-123');

    favorites = [];
    await model.refreshResumeAndNextUp();
    expect(model.rows.map((r) => r.id), ['liveTv']);
    verify(() => source.loadFavoritesChannels('http://server.test')).called(3);
    verifyNever(() => source.hasLiveTvChannels());
  });

  for (final serverType in [
    ServerType.jellyfin,
    ServerType.emby,
    ServerType.plex,
  ]) {
    test('returning from the guide updates $serverType channel favorites', () async {
      await enableSections({HomeSectionType.liveTv});
      stubLiveTvRows();
      final MediaServerClient serverClient;
      if (serverType == ServerType.plex) {
        final plex = _MockPlexClient();
        when(() => plex.cloudOnly).thenReturn(false);
        serverClient = plex;
      } else {
        serverClient = _MockClient();
      }
      when(() => serverClient.serverType).thenReturn(serverType);
      when(() => serverClient.userId).thenReturn('user');
      when(() => serverClient.baseUrl).thenReturn('http://server.test');

      var favorites = <AggregatedItem>[];
      when(() => source.loadFavoritesChannels('http://server.test')).thenAnswer(
        (_) async => HomeRow(
          id: 'liveTvFavorites',
          title: 'Favorite Channels',
          rowType: HomeRowType.liveTvFavorites,
          items: List.of(favorites),
        ),
      );
      model.dispose();
      final mediaBar = _MockMediaBar();
      when(() => mediaBar.load(force: any(named: 'force')))
          .thenAnswer((_) async {});
      model = HomeViewModel(
        dataSource: source,
        prefs: prefs,
        client: serverClient,
        mediaBarViewModel: mediaBar,
        multiServerRepo: _MockMultiServer(),
      );
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
      expect(model.rows.last.items.single.id, 'favorite-channel');

      favorites = [];
      await model.refreshResumeAndNextUp();
      expect(model.rows.any((r) => r.rowType == HomeRowType.liveTvFavorites), isFalse);
      verify(() => source.loadFavoritesChannels('http://server.test')).called(3);
      verify(() => source.hasLiveTvChannels()).called(1);
    });
  }

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
