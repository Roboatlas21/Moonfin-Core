import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moonfin/auth/models/user.dart';
import 'package:moonfin/auth/repositories/user_repository.dart';
import 'package:moonfin/auth/store/authentication_store.dart';
import 'package:moonfin/data/models/aggregated_item.dart';
import 'package:moonfin/data/repositories/item_mutation_repository.dart';
import 'package:moonfin/data/repositories/search_repository.dart';
import 'package:moonfin/data/services/plex_live_tv_favorites.dart';
import 'package:moonfin/data/services/media_server_client_factory.dart';
import 'package:moonfin/data/services/row_data_source.dart';
import 'package:moonfin/data/services/user_data_sync.dart';
import 'package:moonfin/data/viewmodels/live_tv_guide_view_model.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:server_core/server_core.dart';
import 'package:server_plex/server_plex.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _device = DeviceInfo(id: 'device', name: 'Test', appName: 'Moonfin', appVersion: '1');
const _channel = <String, dynamic>{
  'Id': 'channel-plex-free123', 'Name': 'Free Channel',
  'Type': 'TvChannel',
  'ImageTags': {'Primary': 'https://example.test/logo.png'},
};
const _source = 'provider://tv.plex.provider.epg';

class _ChannelClient extends Mock implements MediaServerClient {}
class _ChannelApi extends Mock implements LiveTvApi {}

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

PlexMediaServerClient _plex({bool cloudOnly = false, String userId = 'plex-user'}) =>
    PlexMediaServerClient(
      baseUrl: cloudOnly ? 'https://plex.tv' : 'https://pms.example',
      deviceInfo: _device, cloudOnly: cloudOnly,
    )..userId = userId
     ..accessToken = cloudOnly ? 'cloud-token' : 'pms-token';

bool _saved(MediaServerClient client, String id) =>
    (PlexLiveTvFavorites.applyToItem(client, {
      ..._channel, 'Id': id,
    })['UserData'] as Map)['IsFavorite'] == true;

class _Cloud extends Interceptor {
  final requests = <RequestOptions>[];
  List<Map<String, dynamic>> rows = [];
  int? getError, putError;
  Map<String, dynamic>? responseOverride;
  Future<void>? holdGet;

  @override
  void onRequest(RequestOptions request, RequestInterceptorHandler handler) {
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
    PlexLiveTvFavorites.testHttp = http;
  });

  tearDown(() async {
    userDataSync.reset();
    PlexLiveTvFavorites.resetForTesting();
    users.dispose();
    http.close();
    await GetIt.instance.reset();
  });

  test('Cloud and PMS use the same account favorites without touching DVR entries', () async {
    final direct = _plex(cloudOnly: true);
    final pms = _plex();
    addTearDown(direct.dispose);
    addTearDown(pms.dispose);
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
    expect(cloud.requests.every((r) => r.headers['X-Plex-Token'] == 'account-token'), isTrue);
    expect(cloud.requests.where((r) => r.method == 'PUT'), hasLength(2));
  });

  test('cloud replaces older local favorites without uploading them', () async {
    final direct = _plex(cloudOnly: true);
    addTearDown(direct.dispose);
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
    cloud.putError = 403;
    await expectLater(
      ItemMutationRepository(direct).setFavorite('channel-plex-free123', isFavorite: true),
      throwsA(isA<DioException>()),
    );
    expect(_saved(direct, 'channel-plex-free123'), isFalse);
    expect(cloud.rows.single['id'], 'different');
  });


  test('DVR favorites match machine/provider and preserve other PMS channels', () async {
    final pms = _plex();
    final direct = _plex(cloudOnly: true);
    addTearDown(pms.dispose);
    addTearDown(direct.dispose);
    const source = 'server://pms-machine-1/tv.plex.providers.epg.xmltv:2';
    const otherSource = 'server://another-pms/tv.plex.providers.epg.xmltv:2';
    const dvr = <String, dynamic>{
      'Id': 'channel-2-4',
      'Type': 'TvChannel',
      'Name': 'CBC',
      'ChannelNumber': '4',
      'PlexFavoriteSource': source,
      'PlexFavoriteId': '4',
      'ImageTags': {'Primary': 'http://pms.example/cbc.png'},
    };
    cloud.rows = [
      {'source': _source, 'id': 'free123', 'title': 'Free Channel'},
      {'source': otherSource, 'id': '4', 'title': 'Other PMS'},
      {'source': source, 'id': '4', 'title': 'CBC', 'thumb': 'keep'},
    ];
    PlexLiveTvFavorites.applyToItem(pms, dvr);
    PlexLiveTvFavorites.applyToItem(direct, _channel);
    await PlexLiveTvFavorites.refresh(pms);
    expect((PlexLiveTvFavorites.applyToItem(pms, dvr)['UserData'] as Map)['IsFavorite'],
        isTrue);
    expect(_saved(direct, 'channel-plex-free123'), isTrue);

    await ItemMutationRepository(pms).setFavorite('channel-2-4', isFavorite: false);
    expect(cloud.rows.map((row) => row['source']).toList(), [_source, otherSource]);
    expect((PlexLiveTvFavorites.applyToItem(pms, dvr)['UserData'] as Map)['IsFavorite'],
        isFalse);

    await ItemMutationRepository(pms).setFavorite('channel-2-4', isFavorite: true);
    expect(cloud.rows.last, {
      'source': source,
      'id': '4',
      'title': 'CBC',
      'thumb': 'http://pms.example/cbc.png',
      'vcn': '4',
    });
    expect(cloud.requests.every((r) => r.headers['X-Plex-Token'] == 'account-token'),
        isTrue);

    // A matching synthetic ID on another PMS must never reuse this metadata.
    final secondPms = _plex();
    secondPms.baseUrl = 'https://second-pms.example';
    addTearDown(secondPms.dispose);
    final before = cloud.requests.where((r) => r.method == 'PUT').length;
    await expectLater(
      ItemMutationRepository(secondPms).setFavorite('channel-2-4', isFavorite: false),
      throwsA(isA<StateError>()),
    );
    expect(cloud.requests.where((r) => r.method == 'PUT'), hasLength(before));
  });

  test('incomplete cloud favorites cannot replace an existing list', () async {
    final pms = _plex();
    addTearDown(pms.dispose);
    cloud.rows = [{'source': _source, 'id': 'free123'}];
    PlexLiveTvFavorites.applyToItem(pms, _channel);
    await PlexLiveTvFavorites.refresh(pms);
    expect(_saved(pms, 'channel-plex-free123'), isTrue);

    cloud.responseOverride = {'MediaContainer': <String, dynamic>{}};
    await expectLater(
      ItemMutationRepository(pms).setFavorite('channel-plex-free123', isFavorite: false),
      throwsA(isA<FormatException>()),
    );
    expect(cloud.requests.where((r) => r.method == 'PUT'), isEmpty);
    expect(_saved(pms, 'channel-plex-free123'), isTrue);

    cloud.responseOverride = {'MediaContainer': {'size': 0}};
    await PlexLiveTvFavorites.refresh(pms);
    expect(_saved(pms, 'channel-plex-free123'), isFalse);
  });



  test('different PMS channels with identical IDs remain independent', () async {
    final first = _plex();
    final second = _plex()..baseUrl = 'https://second-pms.example';
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    const dvr = <String, dynamic>{
      'Id': 'channel-2-4',
      'Type': 'TvChannel',
      'Name': 'CBC', 'PlexFavoriteId': '4',
    };
    final a = PlexLiveTvFavorites.applyToItem(first, {
      ...dvr, 'PlexFavoriteSource': 'server://pms-a/epg',
    });
    final b = PlexLiveTvFavorites.applyToItem(second, {
      ...dvr, 'PlexFavoriteSource': 'server://pms-b/epg',
    });
    expect(a['PlexFavoriteSyncKey'], isNot(b['PlexFavoriteSyncKey']));

    await Future.wait([
      ItemMutationRepository(first).setFavorite('channel-2-4', isFavorite: true),
      ItemMutationRepository(second).setFavorite('channel-2-4', isFavorite: true),
    ]);
    expect(cloud.rows.map((r) => r['source']).toSet(),
        {'server://pms-a/epg', 'server://pms-b/epg'});
    await ItemMutationRepository(first).setFavorite('channel-2-4', isFavorite: false);
    expect(cloud.rows.single['source'], 'server://pms-b/epg');
    expect(GuideChannel.fromRawItem(a).withSyncedUserData().isFavorite, isFalse);
    expect(GuideChannel.fromRawItem(b).withSyncedUserData().isFavorite, isTrue);

    // Home updates through AggregatedItem, not GuideChannel.
    userDataSync.publish('channel-2-4', {'IsFavorite': false});
    final homeA = AggregatedItem(id: 'channel-2-4', serverId: 'a', rawData: a);
    final homeB = AggregatedItem(id: 'channel-2-4', serverId: 'b', rawData: b);
    expect(userDataSync.apply(homeA).isFavorite, isFalse);
    expect(userDataSync.apply(homeB).isFavorite, isTrue);
  });




  test('DVR favorites remain available after the client address changes', () async {
    final pms = _plex();
    addTearDown(pms.dispose);
    const source = 'server://pms-machine/epg';
    const channel = {
      'Id': 'channel-2-4',
      'Type': 'TvChannel',
      'Name': 'DVR',
      'PlexFavoriteSource': source,
      'PlexFavoriteId': '4',
    };
    final initial = PlexLiveTvFavorites.syncKey(pms, 'channel-2-4');
    pms.baseUrl = 'https://new-pms-address.example';
    expect(PlexLiveTvFavorites.syncKey(pms, 'channel-2-4'), initial);
    PlexLiveTvFavorites.applyToItem(pms, channel);
    final known = PlexLiveTvFavorites.syncKey(pms, 'channel-2-4');
    pms.baseUrl = 'https://newer-pms-address.example';
    expect(PlexLiveTvFavorites.syncKey(pms, 'channel-2-4'), known);
    await ItemMutationRepository(pms).setFavorite('channel-2-4',
        isFavorite: true);
    expect(cloud.rows.single['source'], source);
  });


  test('search does not wait for a slow Plex cloud favorites read', () async {
    final client = _ChannelClient();
    final api = _ChannelApi();
    when(() => client.serverType).thenReturn(ServerType.plex);
    when(() => client.userId).thenReturn('plex-user');
    when(() => client.baseUrl).thenReturn('https://pms.example');
    when(() => client.deviceInfo).thenReturn(_device);
    when(() => client.liveTvApi).thenReturn(api);
    when(() => api.getChannels(
      fields: 'ImageTags',
      enableTotalRecordCount: false,
      userId: 'plex-user',
    )).thenAnswer((_) async => {'Items': [_channel]});
    cloud.rows = [{'source': _source, 'id': 'free123'}];
    final hold = Completer<void>();
    cloud.holdGet = hold.future;

    final result = await SearchRepository(client).fetchLiveTvChannels()
        .timeout(const Duration(seconds: 1));
    expect(result.single.isFavorite, isFalse);
    await pumpEventQueue();
    expect(cloud.requests.where((r) => r.method == 'GET'), hasLength(1));

    hold.complete();
    await pumpEventQueue();
    expect(userDataSync.favoriteFor(
      PlexLiveTvFavorites.syncKey(client, 'channel-plex-free123')), isTrue);
  });





  test('a second PMS applies another PMS cache without a second cloud GET', () async {
    final first = _plex();
    final second = _plex()..baseUrl = 'https://second-pms.example';
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    const dvr = <String, dynamic>{
      'Id': 'channel-2-4',
      'Type': 'TvChannel',
      'Name': 'DVR on second PMS',
      'PlexFavoriteSource': 'server://second-machine/epg',
      'PlexFavoriteId': '4',
    };
    final secondItem = PlexLiveTvFavorites.applyToItem(second, dvr);
    final key = secondItem['PlexFavoriteSyncKey'] as String;
    cloud.rows = [{'source': 'server://second-machine/epg', 'id': '4'}];

    await PlexLiveTvFavorites.refresh(first);
    expect(userDataSync.favoriteFor(key), isNull);
    expect(await PlexLiveTvFavorites.refreshForBrowse(second), isTrue);
    expect(userDataSync.favoriteFor(key), isTrue);
    expect(cloud.requests.where((r) => r.method == 'GET'), hasLength(1));

    // Removing the favorite elsewhere should also reconcile without a GET.
    cloud.rows = [];
    await PlexLiveTvFavorites.refresh(first);
    expect(await PlexLiveTvFavorites.refreshForBrowse(second), isTrue);
    expect(userDataSync.favoriteFor(key), isFalse);
    expect(cloud.requests.where((r) => r.method == 'GET'), hasLength(2));
  });



  test('a confirmed Plex PUT stays successful when local cache write fails', () async {
    final client = _plex();
    addTearDown(client.dispose);
    PlexLiveTvFavorites.applyToItem(client, _channel);
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
    // The failed local write must not falsely mark the cloud read as fresh.
    expect(await PlexLiveTvFavorites.refreshForBrowse(client), isFalse);
    expect(cloud.requests.where((r) => r.method == 'GET'), hasLength(2));
  });

  test('an unverified DVR row invalidates its previous provider', () async {
    final client = _plex();
    addTearDown(client.dispose);
    const known = <String, dynamic>{
      'Id': 'channel-2-4',
      'Type': 'TvChannel',
      'PlexFavoriteSource': 'server://old-pms/epg',
      'PlexFavoriteId': '4',
    };
    PlexLiveTvFavorites.applyToItem(client, known);
    expect(PlexLiveTvFavorites.syncKey(client, 'channel-2-4'),
        contains('old-pms'));

    final unverified = PlexLiveTvFavorites.applyToItem(client, {
      'Id': 'channel-2-4',
      'Type': 'TvChannel',
      'Name': 'DVR channel',
    });
    expect(unverified['PlexFavoriteSyncKey'] as String,
        isNot(contains('old-pms')));
    await expectLater(
      PlexLiveTvFavorites.setFavorite(client, 'channel-2-4', isFavorite: true),
      throwsA(isA<StateError>()),
    );
    expect(cloud.requests.where((r) => r.method == 'PUT'), isEmpty);
  });



  test('a client reused for another user drops its old DVR catalog', () {
    final pms = _plex();
    addTearDown(pms.dispose);
    const dvr = {
      'Id': 'channel-2-4',
      'Type': 'TvChannel',
      'PlexFavoriteSource': 'server://machine/epg',
      'PlexFavoriteId': '4',
    };
    PlexLiveTvFavorites.applyToItem(pms, dvr);
    final known = PlexLiveTvFavorites.syncKey(pms, 'channel-2-4');
    expect(known, contains('server://machine/epg'));
    pms.userId = 'other-user';
    expect(PlexLiveTvFavorites.syncKey(pms, 'channel-2-4'), isNot(known));
    pms.userId = 'plex-user';
    expect(PlexLiveTvFavorites.syncKey(pms, 'channel-2-4'), isNot(known));
  });

  test('serializes separate channel updates and rejects a different Home user', () async {
    final pms = _plex();
    addTearDown(pms.dispose);
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
