import 'dart:async';

import 'package:clock/clock.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moonfin/auth/models/user.dart';
import 'package:moonfin/auth/repositories/user_repository.dart';
import 'package:moonfin/data/models/aggregated_item.dart';
import 'package:moonfin/data/repositories/item_mutation_repository.dart';
import 'package:moonfin/data/repositories/search_repository.dart';
import 'package:moonfin/data/services/plex_live_tv_favorites.dart';
import 'package:moonfin/data/services/row_data_source.dart';
import 'package:moonfin/data/services/user_data_sync.dart';
import 'package:moonfin/data/viewmodels/live_tv_guide_view_model.dart';
import 'package:moonfin/data/viewmodels/search_view_model.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:server_core/server_core.dart';
import 'package:server_plex/server_plex.dart';
import 'package:server_plex/src/api/plex_live_tv_api.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _device = DeviceInfo(id: 'device', name: 'Test', appName: 'Moonfin', appVersion: '1');
const _channel = <String, dynamic>{
  'Id': 'channel-plex-free123', 'Name': 'Free Channel',
  'Type': 'TvChannel',
  'ImageTags': {'Primary': 'https://example.test/logo.png'},
};
const _source = 'provider://tv.plex.provider.epg';

class _FailingPlexPreferences extends UserPreferences {
  _FailingPlexPreferences(super.store);

  @override
  Future<void> set<T>(Preference<T> pref, T value) async {
    if (pref.key.startsWith('plex_live_tv_favorite_keys_')) {
      throw StateError('Local preference write failed');
    }
    await super.set(pref, value);
  }
}

PlexMediaServerClient _plex({bool cloudOnly = false, String userId = 'plex-user'}) {
  final client = PlexMediaServerClient(
      baseUrl: cloudOnly ? 'https://plex.tv' : 'https://pms.example',
      deviceInfo: _device,
    )..userId = userId
     ..accessToken = cloudOnly ? 'cloud-token' : 'pms-token';
  addTearDown(client.dispose);
  return client;
}

bool _saved(MediaServerClient client, String id) =>
    (PlexLiveTvFavorites.applyToItem(client, {
      ..._channel, 'Id': id,
    })['UserData'] as Map)['IsFavorite'] == true;

class _LineupApi extends Mock implements LiveTvApi, DirectChannelGroupApi {}

class _ChannelSearch extends SearchRepository {
  _ChannelSearch(super.client);

  @override
  Future<List<AggregatedItem>> searchPeople(String query, {int limit = 24}) async => [];

  @override
  Future<List<AggregatedItem>> searchGroups(String query, List<List<String>> groups,
      {required int perGroup, required int limit}) async => [];
}

class _LineupClient extends PlexMediaServerClient {
  _LineupClient(this.liveTvApi) : super(baseUrl: 'https://pms.example', deviceInfo: _device);
  @override
  final LiveTvApi liveTvApi;
}

class _Cloud extends Interceptor {
  final requests = <RequestOptions>[];
  List<Map<String, dynamic>> rows = [];
  int? getError, putError;
  Map<String, dynamic>? responseOverride;
  Future<void>? holdGet;
  Future<void>? holdPut;

  @override
  void onRequest(RequestOptions request, RequestInterceptorHandler handler) async {
    requests.add(request);
    final error = request.method == 'GET' ? getError : putError;
    if (error != null) {
      handler.reject(DioException(
        requestOptions: request,
        response: Response(requestOptions: request, statusCode: error),
        type: DioExceptionType.badResponse,
      ));
      return;
    }
    if (request.method == 'GET') {
      final response = Response(requestOptions: request, statusCode: 200,
        data: responseOverride ?? {'MediaContainer': {'FavoriteChannel': [
          for (final row in rows) {...row},
        ]}},
      );
      final pending = holdGet;
      if (pending == null) {
        handler.resolve(response);
      } else {
        unawaited(pending.then((_) => handler.resolve(response)));
      }
    } else {
      rows = [for (final row in request.data as List)
        Map<String, dynamic>.from(row as Map)];
      if (holdPut != null) await holdPut;
      handler.resolve(Response(requestOptions: request, statusCode: 200));
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late UserPreferences prefs;
  late UserRepository users;
  late _Cloud cloud;
  late Dio http;

  setUp(() async {
    userDataSync.reset();
    PlexLiveTvFavorites.resetForTesting();
    SharedPreferences.setMockInitialValues({});
    final store = PreferenceStore();
    await store.init();
    prefs = UserPreferences(store);
    users = UserRepository()..setCurrentUser(PrivateUser(
      id: 'plex-user', name: 'Plex User', serverId: 'plex-cloud',
      accessToken: 'pms-token', plexToken: 'account-token',
      lastUsed: DateTime.utc(2026),
    ));
    GetIt.instance.registerSingleton<UserPreferences>(prefs);
    GetIt.instance.registerSingleton<UserRepository>(users);
    cloud = _Cloud();
    http = Dio()..interceptors.add(cloud);
    PlexLiveTvFavorites.testApi = PlexLiveTvFavoritesApi(dio: http);
  });

  tearDown(() async {
    userDataSync.reset();
    PlexLiveTvFavorites.resetForTesting();
    users.dispose();
    http.close();
    await GetIt.instance.reset();
  });

  for (final legacy in [false, true]) {
    test('Cloud and PMS share account favorites with a saved ${legacy ? 'legacy' : 'account'} token', () async {
      if (legacy) users.setCurrentUser(PrivateUser.fromJson('plex-user', 'pms', {'accessToken': 'legacy-owner-token'}));

      final direct = _plex(cloudOnly: true);
      final pms = _plex();

      cloud.rows = [
        {'source': _source, 'id': 'free123', 'title': 'Free Channel'},
        {'source': 'server://other/dvr', 'id': 'channel7', 'thumb': 'keep'},
      ];
      PlexLiveTvFavorites.applyToItem(direct, _channel);
      await PlexLiveTvFavorites.refresh(direct);
      expect(_saved(pms, 'channel-plex-free123'), isTrue);

      await ItemMutationRepository(pms).setFavorite('channel-plex-free123', isFavorite: false);
      expect(cloud.rows.single, containsPair('thumb', 'keep'));
      expect(_saved(direct, 'channel-plex-free123'), isFalse);

      await ItemMutationRepository(direct).setFavorite('channel-plex-free123', isFavorite: true);
      expect(_saved(pms, 'channel-plex-free123'), isTrue);
      expect(cloud.rows.last, containsPair('source', _source));
      expect(cloud.requests.map((r) => r.headers['X-Plex-Token']), everyElement(legacy ? 'legacy-owner-token' : 'account-token'));
      expect(cloud.requests.where((r) => r.method == 'PUT'), hasLength(2));
    });
  }

  test('cloud replaces older local favorites without uploading them', () async {
    final direct = _plex(cloudOnly: true);
    await prefs.set(Preference<List<String>>(
      key: 'plex_live_tv_favorite_keys_plex-user', defaultValue: [],
    ), ['provider://tv.plex.provider.epg\u0000free123']);
    PlexLiveTvFavorites.applyToItem(direct, _channel);
    expect(_saved(direct, 'channel-plex-free123'), isTrue);

    cloud.rows = [{'source': 'server://other/dvr', 'id': 'different'}];
    await PlexLiveTvFavorites.refresh(direct);
    expect(_saved(direct, 'channel-plex-free123'), isFalse);
    expect(cloud.rows.single['id'], 'different');
    expect(cloud.requests.where((r) => r.method == 'PUT'), isEmpty);

    cloud.getError = 503;
    await expectLater(PlexLiveTvFavorites.refresh(direct), throwsA(isA<DioException>()));
    expect(_saved(direct, 'channel-plex-free123'), isFalse);
    cloud.getError = null;
    cloud.responseOverride = {'MediaContainer': {'size': 2, 'FavoriteChannel': []}};
    final mutations = ItemMutationRepository(direct);
    Future<void> save() => mutations.setFavorite('channel-plex-free123', isFavorite: true);
    await expectLater(save(), throwsFormatException);
    expect(cloud.requests.where((r) => r.method == 'PUT'), isEmpty);
    cloud.responseOverride = null;
    cloud.putError = 403;
    await expectLater(save(), throwsA(isA<DioException>()));
    expect(_saved(direct, 'channel-plex-free123'), isFalse);
    expect(cloud.rows.single['id'], 'different');
  });

  test('an incomplete favorites list keeps the saved heart and a valid empty list clears it', () async {
    final client = _plex();
    cloud.rows = [{'source': _source, 'id': 'free123'}];
    await PlexLiveTvFavorites.refresh(client);
    cloud.rows = [{'id': 'free123'}];
    await expectLater(PlexLiveTvFavorites.refresh(client), throwsFormatException);
    expect(_saved(client, 'channel-plex-free123'), isTrue);
    cloud.rows.clear();
    await PlexLiveTvFavorites.refresh(client);
    expect(_saved(client, 'channel-plex-free123'), isFalse);
  });

  test('Search updates a visible favorite in a 2,001-channel Plex lineup', () async {
    final api = _LineupApi();
    final client = _LineupClient(api)..userId = 'plex-user';
    addTearDown(client.dispose);
    when(() => api.getChannels(fields: 'ImageTags', enableTotalRecordCount: false, userId: 'plex-user'))
        .thenAnswer((_) async => {'Items': [
          _channel,
          for (var i = 0; i < 2000; i++) {'Id': 'channel-plex-$i', 'Type': 'TvChannel', 'Name': 'Other'},
        ]});
    final reply = Completer<void>();
    cloud.holdGet = reply.future;
    cloud.rows = [{'source': _source, 'id': 'free123'}];
    final model = SearchViewModel(_ChannelSearch(client), client);
    addTearDown(model.dispose);
    model.searchImmediate('Free Channel');
    await pumpEventQueue();
    expect(model.results.single.items.single.isFavorite, isFalse);
    reply.complete();
    await pumpEventQueue();
    expect(model.results.single.items.single.isFavorite, isTrue);
  });

  for (final changeUser in [true, false]) {
    test('Home discards a delayed lineup after a ${changeUser ? 'user change' : 'session reset'}', () async {
      const id = 'channel-2-4';
      const station = {'Id': id, 'Type': 'TvChannel', 'Name': 'CBC'};
      const currentStation = {
        ...station, 'PlexFavoriteSource': 'server://current/epg', 'PlexFavoriteId': '4',
      };
      final api = _LineupApi();
      final client = _LineupClient(api)..userId = changeUser ? 'previous-user' : 'plex-user';
      addTearDown(client.dispose);
      final home = RowDataSource(client);
      final delayed = Completer<Map<String, dynamic>>();
      Future<Map<String, dynamic>> lineup() => api.getChannels(fields: 'ImageTags,UserData');
      when(lineup).thenAnswer((_) => delayed.future);
      final oldLoad = home.loadFavoritesChannels('pms');
      if (changeUser) {
        client.userId = 'plex-user';
      } else {
        userDataSync.reset();
      }
      final current = PlexLiveTvFavorites.applyToItem(client, currentStation);
      delayed.complete({'Items': [station]});
      await expectLater(oldLoad, throwsStateError);

      await ItemMutationRepository(client).setFavorite(
        id, isFavorite: true, expectedChannelKey: current['PlexFavoriteSyncKey'] as String,
      );
      expect(cloud.rows.single['source'], currentStation['PlexFavoriteSource']);
      when(lineup).thenAnswer((_) async => {'Items': [currentStation]});
      final refreshed = await home.loadFavoritesChannels('pms');
      expect(refreshed.items.single.id, id);
    });
  }

  test('Featured survives a cold Free TV catalog outage and clears when the catalog is empty', () async {
    const featured = PromotedChannelGroup.groupId;
    const free = 'channel-plex-free123';
    var catalogStatus = 503;
    final dio = Dio(BaseOptions(baseUrl: 'https://pms.example'));
    addTearDown(dio.close);
    dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
      final path = request.uri.path;
      if (path == '/lineups/plex/channels' && catalogStatus == 503) {
        handler.reject(DioException.badResponse(
          statusCode: 503,
          requestOptions: request,
          response: Response(requestOptions: request, statusCode: 503),
        ));
        return;
      }
      final data = switch (path) {
        '/lineups/plex/channels' || '/lineups/plex/channels/featured' => {
          'MediaContainer': {
            'Channel': [if (catalogStatus == 200) {'id': 'free123', 'title': 'Free Channel'}],
          },
        },
        '/' => {
          'MediaProvider': {'Feature': [
            {'type': 'grid', 'PromotedGridChannelFilter': [
              {'key': '/lineups/plex/channels/featured', 'title': 'Featured'},
            ]},
          ]},
        },
        '/livetv/dvrs' => {'MediaContainer': {'Dvr': []}},
        _ => {'MediaContainer': {'Metadata': []}},
      };
      handler.resolve(Response(requestOptions: request, data: data));
    }));
    final client = _LineupClient(PlexLiveTvApi(dio))..userId = 'plex-user';
    addTearDown(client.dispose);
    final guide = LiveTvGuideViewModel(client, initialFilter: (GuideFilter.all, featured));
    addTearDown(guide.dispose);

    await guide.load();
    expect(guide.selectedGroup, featured);
    expect(guide.state, GuideState.error);

    catalogStatus = 200;
    await guide.load();
    await pumpEventQueue();
    expect(guide.selectedGroup, featured);
    expect(guide.state, GuideState.ready);
    expect(guide.filteredChannels.single.id, free);

    catalogStatus = 204;
    await guide.load();
    expect(guide.selectedGroup, isNull);
    expect(guide.state, GuideState.ready);
  });

  test('Guide keeps the Plex heart current when a large account lineup fills the sync cache', () async {
    const provider = 'server://pms/epg';
    final api = _LineupApi();
    final client = _LineupClient(api)..userId = 'plex-user';
    addTearDown(client.dispose);
    when(() => api.getChannelGroups(userId: 'plex-user')).thenAnswer((_) async {
      return ChannelGroupLineup({}, channels: [
        for (var i = 0; i < 4001; i++)
          {
            'Id': 'channel-2-$i',
            'Type': 'TvChannel',
            'Name': 'Station $i',
            'PlexFavoriteSource': provider,
            'PlexFavoriteId': '$i',
          },
      ]);
    });
    when(() => api.getGuide(
      startDate: any(named: 'startDate'), endDate: any(named: 'endDate'),
      channelIds: any(named: 'channelIds'), fields: any(named: 'fields'),
      enableTotalRecordCount: false, enableImages: false, enableUserData: false, userId: 'plex-user',
    )).thenAnswer((_) async => {'Items': []});
    final guide = LiveTvGuideViewModel(client);
    userDataSync.addListener(guide.syncChannelUserData);
    addTearDown(() {
      userDataSync.removeListener(guide.syncChannelUserData);
      guide.dispose();
    });
    await guide.load();
    await pumpEventQueue();
    const id = 'channel-2-0';
    expect(guide.channelForId(id)!.isFavorite, isFalse);

    cloud.rows = [{'source': provider, 'id': '0'}];
    await PlexLiveTvFavorites.refresh(client);
    final key = channelFavoriteKey(guide.channelForId(id)!.rawData)!;
    expect(userDataSync.favoriteFor(key), isNull);
    expect(guide.channelForId(id)!.isFavorite, isTrue);
  });

  group('Global Search DVR favorites', () {
    const favorite = {'source': 'server://pms/epg', 'id': '4'};
    const station = {
      'Id': 'channel-2-4', 'Type': 'TvChannel', 'Name': 'CBC News',
      'PlexFavoriteSource': 'server://pms/epg', 'PlexFavoriteId': '4',
    };
    late _LineupApi api;
    late _LineupClient client;
    late SearchViewModel model;

    Future<Map<String, dynamic>> lineup() =>
        api.getChannels(fields: 'ImageTags', enableTotalRecordCount: false, userId: 'plex-user');

    Future<void> search(String query) async {
      model.searchImmediate(query);
      await pumpEventQueue();
      expect(model.state, SearchState.ready);
    }

    setUp(() {
      api = _LineupApi();
      client = _LineupClient(api)..userId = 'plex-user';
      addTearDown(client.dispose);
      when(lineup).thenAnswer((_) async => {'Items': [station]});
      model = SearchViewModel(_ChannelSearch(client), client);
      addTearDown(model.dispose);
    });

    for (final changeUser in [true, false]) {
      test('a delayed lineup is discarded after a ${changeUser ? 'user change' : 'session reset'}', () async {
        final originalUser = changeUser ? 'previous-user' : 'plex-user';
        client.userId = originalUser;
        final delayed = Completer<Map<String, dynamic>>();
        when(() => api.getChannels(fields: 'ImageTags', enableTotalRecordCount: false, userId: originalUser))
            .thenAnswer((_) => delayed.future);
        model.searchImmediate('CBC');
        await pumpEventQueue();
        expect(model.state, SearchState.loading);

        if (changeUser) {
          client.userId = 'plex-user';
        } else {
          userDataSync.reset();
        }
        final current = PlexLiveTvFavorites.applyToItem(client, station);
        final key = current['PlexFavoriteSyncKey'] as String;
        // The old row lacks a provider and would clear the current mapping.
        delayed.complete({'Items': [
          {'Id': station['Id'], 'Type': 'TvChannel', 'Name': 'CBC Old'},
        ]});
        await pumpEventQueue();
        expect(model.results, isEmpty);
        expect(cloud.requests, isEmpty);
        await ItemMutationRepository(client).setFavorite(
          station['Id']!, isFavorite: true, expectedChannelKey: key,
        );
        expect(cloud.rows.single, containsPair('source', favorite['source']));

        when(lineup).thenAnswer((_) async => {'Items': [station]});
        await search('CBC News');
        expect(model.results.single.items.single.isFavorite, isTrue);
      });
    }

    test('the Guide refreshes a stale DVR identity before the viewer retries a favorite', () async {
      const id = 'channel-2-4';
      var guideRow = {'Id': id, 'Type': 'TvChannel', 'Name': 'CBC'};
      when(() => api.getChannelGroups(userId: 'plex-user'))
          .thenAnswer((_) async => ChannelGroupLineup({}, channels: [guideRow]));
      when(() => api.getGuide(
        startDate: any(named: 'startDate'), endDate: any(named: 'endDate'),
        channelIds: any(named: 'channelIds'), fields: any(named: 'fields'),
        enableTotalRecordCount: false, enableImages: false, enableUserData: false, userId: 'plex-user',
      )).thenAnswer((_) async => {'Items': []});
      final guide = LiveTvGuideViewModel(client);
      addTearDown(guide.dispose);
      await guide.load();

      guideRow = station;
      await search('CBC');
      final key = channelFavoriteKey(model.results.single.items.single.rawData);
      expect(channelFavoriteKey(guide.channelForId(id)!.rawData), isNot(key));
      await expectLater(guide.toggleChannelFavorite(id), throwsStateError);
      expect(cloud.requests.where((r) => r.method == 'PUT'), isEmpty);
      expect(channelFavoriteKey(guide.channelForId(id)!.rawData), key);
      expect(guide.channelForId(id)!.name, 'CBC News');

      await guide.toggleChannelFavorite(id);
      expect(cloud.rows.single, containsPair('source', favorite['source']));
      expect(cloud.requests.where((r) => r.method == 'PUT'), hasLength(1));
    });

    test('a refresh on another server updates Search and preserves a pending local edit', () async {
      final other = _plex()..baseUrl = 'https://other-pms.example';
      await search('CBC');
      final row = model.results.single.items.single;
      final key = row.rawData['PlexFavoriteSyncKey'] as String;
      expect(row.isFavorite, isFalse);

      cloud.rows = [favorite];
      await PlexLiveTvFavorites.refresh(other);
      expect(model.results.single.items.single.isFavorite, isTrue);
      expect(userDataSync.favoriteFor(key), isTrue);
      expect(cloud.requests, hasLength(2));

      userDataSync.requestFavorite(key, false);
      cloud.rows.add({'source': favorite['source'], 'id': '7'});
      await PlexLiveTvFavorites.refresh(other);
      expect(model.results.single.items.single.isFavorite, isFalse);
      expect(userDataSync.pendingFavorite(key), isFalse);
      expect(cloud.requests, hasLength(3));
    });

    for (final failed in [false, true]) {
      test('cached lineup refreshes favorites after ${failed ? 'failure' : 'expiry'}', () async {
        var now = DateTime.utc(2026);
        await withClock(Clock(() => now), () async {
          cloud.getError = failed ? 503 : null;
          await search('CBC');
          expect(model.results.single.items.single.isFavorite, isFalse);
          expect(cloud.requests, hasLength(1));

          cloud.getError = null;
          cloud.rows = [favorite];
          if (!failed) {
            now = now.add(const Duration(seconds: 29));
            await search('News');
            expect(cloud.requests, hasLength(1));
            expect(model.results.single.items.single.isFavorite, isFalse);
            now = now.add(const Duration(seconds: 1));
          }
          await search('CBC News');
          expect(model.results.single.items.single.isFavorite, isTrue);
          expect(cloud.requests, hasLength(2));
          verify(lineup).called(1);
        });
      });
    }
  });

  test('Home can remove a DVR favorite fetched by another Plex connection', () async {
    const id = 'channel-2-4';
    const source = 'server://pms-a/epg';
    const station = {
      'Id': id, 'Type': 'TvChannel', 'Name': 'CBC', 'PlexFavoriteSource': source, 'PlexFavoriteId': '4',
    };
    final api = _LineupApi();
    final client = _LineupClient(api)..userId = 'plex-user';
    addTearDown(client.dispose);
    final other = _plex()..baseUrl = 'https://other-pms.example';
    when(() => api.getChannels(fields: 'ImageTags,UserData'))
        .thenAnswer((_) async => {'Items': [station]});
    PlexLiveTvFavorites.applyToItem(client, station);
    await PlexLiveTvFavorites.refresh(client);

    cloud.rows = [{'source': source, 'id': '4'}];
    await PlexLiveTvFavorites.refresh(other);
    final row = await RowDataSource(client).loadFavoritesChannels('home-pms');
    final item = row.items.single;
    final key = channelFavoriteKey(item.rawData)!;
    expect(item.isFavorite, isTrue);
    expect(userDataSync.favoriteFor(key), isFalse);

    Future<void> remove() => ItemMutationRepository(client).setFavorite(
      id, isFavorite: false, isChannel: true, expectedChannelKey: key,
    );
    cloud.putError = 503;
    await expectLater(remove(), throwsA(isA<DioException>()));
    expect(userDataSync.favoriteFor(key), isTrue);
    expect(cloud.rows.single['id'], '4');

    cloud.putError = null;
    await remove();
    expect(cloud.rows, isEmpty);
    expect(cloud.requests.where((r) => r.method == 'PUT'), hasLength(2));
  });

  test('a failed favorite check rolls back to the last completed browse read', () async {
    final client = _plex();
    const id = 'channel-plex-free123';
    PlexLiveTvFavorites.applyToItem(client, _channel);
    await PlexLiveTvFavorites.refresh(client);
    final key = PlexLiveTvFavorites.syncKey(client, id);
    expect(userDataSync.favoriteFor(key), isFalse);

    cloud.rows = [{'source': _source, 'id': 'free123'}];
    final release = Completer<void>();
    cloud.holdGet = release.future;
    final browse = PlexLiveTvFavorites.refresh(client);
    await pumpEventQueue();
    expect(cloud.requests, hasLength(2));
    final edit = ItemMutationRepository(client).setFavorite(id, isFavorite: true);
    final rejected = expectLater(edit, throwsA(isA<DioException>()));
    expect(userDataSync.pendingFavorite(key), isTrue);
    cloud.getError = 503;
    release.complete();
    await browse;
    await rejected;
    expect(userDataSync.favoriteFor(key), isTrue);
    expect(cloud.requests.where((r) => r.method == 'PUT'), isEmpty);
  });

  group('two DVRs with channel 4', () {
    late PlexMediaServerClient first, second;
    late Map<String, dynamic> a, b;
    const id = 'channel-2-4', sourceA = 'server://pms-a/epg', sourceB = 'server://pms-b/epg';
    setUp(() {
      first = _plex();
      second = _plex()..baseUrl = 'https://second-pms.example';
      Map<String, dynamic> station(PlexMediaServerClient client, String source) =>
          PlexLiveTvFavorites.applyToItem(client, {
            'Id': id, 'Type': 'TvChannel', 'Name': 'CBC', 'ChannelNumber': '4',
            'PlexFavoriteSource': source, 'PlexFavoriteId': '4',
            'ImageTags': {'Primary': 'http://pms.example/cbc.png'},
          });
      a = station(first, sourceA);
      b = station(second, sourceB);
    });

    test('favorite changes affect only the selected provider in the guide and on Home', () async {
      expect(a['PlexFavoriteSyncKey'], isNot(b['PlexFavoriteSyncKey']));
      await Future.wait([
        for (final client in [first, second]) ItemMutationRepository(client).setFavorite(id, isFavorite: true),
      ]);
      expect(cloud.rows.map((r) => r['source']), unorderedEquals([sourceA, sourceB]));
      expect(cloud.rows.every((r) => r['thumb'] == 'http://pms.example/cbc.png'), isTrue);
      await ItemMutationRepository(first).setFavorite(id, isFavorite: false);
      expect(cloud.rows.single['source'], sourceB);
      expect(GuideChannel.fromRawItem(a).withSyncedUserData().isFavorite, isFalse);
      expect(GuideChannel.fromRawItem(b).withSyncedUserData().isFavorite, isTrue);
      userDataSync.publish(id, {'IsFavorite': false});
      bool onHome(String server, Map<String, dynamic> row) =>
          userDataSync.apply(AggregatedItem(id: id, serverId: server, rawData: row)).isFavorite;
      expect(onHome('a', a), isFalse);
      expect(onHome('b', b), isTrue);
    });

    test('browsing another DVR picks up remote edits from the shared account cache', () async {
      final key = b['PlexFavoriteSyncKey'] as String;
      expect(userDataSync.favoriteFor(key), isNull);
      for (final saved in [true, false]) {
        cloud.rows = [if (saved) {'source': sourceB, 'id': '4'}];
        await PlexLiveTvFavorites.refresh(first);
        expect(await PlexLiveTvFavorites.refreshForBrowse(second), isTrue);
        expect(userDataSync.favoriteFor(key), saved);
        expect(cloud.requests.where((r) => r.method == 'GET'), hasLength(saved ? 1 : 2));
      }
    });
  });

  for (final pending in ['GET', 'PUT']) {
    test('session reset stops a favorite save waiting on $pending', () async {
      final client = _plex();
      final gate = Completer<void>();
      if (pending == 'GET') cloud.holdGet = gate.future;
      if (pending == 'PUT') cloud.holdPut = gate.future;
      final id = _channel['Id'] as String;
      PlexLiveTvFavorites.applyToItem(client, _channel);
      final save = ItemMutationRepository(client).setFavorite(id, isFavorite: true);
      await pumpEventQueue();
      expect(cloud.requests.last.method, pending);
      userDataSync.reset();
      gate.complete();
      await save;
      expect(cloud.requests.where((r) => r.method == 'PUT'), hasLength(pending == 'PUT' ? 1 : 0));
      expect(PlexLiveTvFavorites.favoriteListChanged.value, isNull);
      expect(_saved(client, id), isFalse);
    });
  }

  test('saving a Free TV favorite by ID succeeds even when the local cache write fails', () async {
    final client = _plex();
    await GetIt.instance.unregister<UserPreferences>();
    final store = PreferenceStore();
    await store.init();
    GetIt.instance.registerSingleton<UserPreferences>(
      _FailingPlexPreferences(store),
    );

    await ItemMutationRepository(client).setFavorite(
      'channel-plex-free123',
      isFavorite: true,
    );
    expect(cloud.requests.where((r) => r.method == 'PUT'), hasLength(1));
    expect(cloud.rows.single['id'], 'free123');
    expect(
      userDataSync.favoriteFor(PlexLiveTvFavorites.syncKey(
        client, 'channel-plex-free123')),
      isTrue,
    );
    // A failed cache write shouldn't make the cloud data look fresh.
    expect(_saved(client, 'channel-plex-free123'), isTrue);
    expect(await PlexLiveTvFavorites.refreshForBrowse(client), isFalse);
    expect(cloud.requests.where((r) => r.method == 'GET'), hasLength(2));
  });

  const id = 'channel-2-4';
  for (final (partial, unresolved, keepFavorite) in <(bool, Set<String>?, bool)>[
    (false, null, false),
    (true, null, true),
    (true, {id}, true),
    (true, {'channel-plex-free123'}, false),
  ]) {
    test('a missing DVR channel during a favorite save (partial: $partial, unresolved: $unresolved)', () async {
      final api = _LineupApi();
      final client = _LineupClient(api)..userId = 'plex-user'..accessToken = 'pms-token';
      addTearDown(client.dispose);
      when(() => api.getChannelGroups(userId: 'plex-user'))
          .thenAnswer((_) async => ChannelGroupLineup(
            {}, channels: [], partial: partial, unresolvedChannelIds: unresolved,
          ));
      final guide = LiveTvGuideViewModel(client);
      addTearDown(guide.dispose);
      PlexLiveTvFavorites.applyToItem(client, {
        'Id': id, 'Type': 'TvChannel', 'PlexFavoriteSource': 'server://pms/epg', 'PlexFavoriteId': '4',
      });

      final gate = Completer<void>();
      cloud.holdGet = gate.future;
      final save = PlexLiveTvFavorites.setFavorite(client, id, isFavorite: true);
      await pumpEventQueue();
      expect(cloud.requests.single.method, 'GET');
      await guide.load();
      expect(guide.error, isNull);
      gate.complete();
      await expectLater(save, keepFavorite ? completes : throwsStateError);
      expect(cloud.requests.where((r) => r.method == 'PUT'), hasLength(keepFavorite ? 1 : 0));
    });
  }

  group('DVR favorite identity', () {
    const id = 'channel-2-4';
    late PlexMediaServerClient client;
    late ItemMutationRepository mutations;
    setUp(() {
      client = _plex();
      mutations = ItemMutationRepository(client);
    });
    Map<String, dynamic> publish(String? provider, {String favoriteId = '4'}) =>
        PlexLiveTvFavorites.applyToItem(client, {
          'Id': id, 'Type': 'TvChannel',
          if (provider != null) ...{'PlexFavoriteSource': provider, 'PlexFavoriteId': favoriteId},
        });
    Future<void> favorite() => PlexLiveTvFavorites.setFavorite(client, id, isFavorite: true);

    test('reassignment is checked at queue time and against the selected row', () async {
      final old = publish('server://old/epg');
      final queued = mutations.setFavorite(id, isFavorite: true);
      publish('server://old/epg', favoriteId: 'replacement');
      await expectLater(queued, throwsStateError);
      final current = publish('server://new/epg');
      Future<void> select(Map<String, dynamic> row) => mutations.setFavorite(
        id, isFavorite: true, isChannel: true, expectedChannelKey: channelFavoriteKey(row),
      );
      await expectLater(select(old), throwsStateError);
      expect(cloud.requests, isEmpty);
      await select(current);
      expect(cloud.rows.single['source'], 'server://new/epg');
    });

    for (final replacement in ['server://new/epg', null]) {
      test('a pending favorite cannot cross a provider change to $replacement', () async {
        publish('server://old/epg');
        expect(PlexLiveTvFavorites.syncKey(client, id), contains('old/epg'));
        final gate = Completer<void>();
        cloud.holdGet = gate.future;
        final refresh = replacement == null ? null : PlexLiveTvFavorites.refresh(client);
        final rejected = expectLater(favorite(), throwsStateError);
        await pumpEventQueue();
        expect(cloud.requests.single.method, 'GET');
        final updated = publish(replacement);
        gate.complete();
        await refresh;
        await rejected;
        if (replacement == null) {
          expect(updated['PlexFavoriteSyncKey'], isNot(contains('old/epg')));
          await expectLater(favorite(), throwsStateError);
        }
        expect(cloud.requests.map((r) => r.method), ['GET']);
      });
    }
  });

  test('serializes separate channel updates and rejects a different Home user', () async {
    final pms = _plex();
    PlexLiveTvFavorites.applyToItem(pms, _channel);
    PlexLiveTvFavorites.applyToItem(pms, {..._channel, 'Id': 'channel-plex-extra'});
    await PlexLiveTvFavorites.refresh(pms);
    await Future.wait([
      ItemMutationRepository(pms).setFavorite('channel-plex-free123', isFavorite: true),
      ItemMutationRepository(pms).setFavorite('channel-plex-extra', isFavorite: true),
    ]);
    expect(cloud.rows.map((row) => row['id']).toSet(), {'free123', 'extra'});

    users.setCurrentUser(PrivateUser(
      id: 'other-user', name: 'Other', serverId: 'plex-cloud',
      accessToken: 'other-pms', plexToken: 'other-cloud',
      lastUsed: DateTime.utc(2026),
    ));
    final requests = cloud.requests.length;
    await expectLater(PlexLiveTvFavorites.refresh(pms), throwsA(isA<StateError>()));
    expect(cloud.requests, hasLength(requests));
  });
}
