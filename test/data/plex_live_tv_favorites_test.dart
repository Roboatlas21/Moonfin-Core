import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:moonfin/auth/models/user.dart';
import 'package:moonfin/auth/repositories/user_repository.dart';
import 'package:moonfin/data/repositories/item_mutation_repository.dart';
import 'package:moonfin/data/services/plex_live_tv_favorites.dart';
import 'package:moonfin/data/services/user_data_sync.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:server_core/server_core.dart';
import 'package:server_plex/server_plex.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _device = DeviceInfo(id: 'device', name: 'Test', appName: 'Moonfin', appVersion: '1');
const _channel = <String, dynamic>{
  'Id': 'channel-plex-free123', 'Name': 'Free Channel',
  'ImageTags': {'Primary': 'https://example.test/logo.png'},
};
const _source = 'provider://tv.plex.provider.epg';

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
      handler.resolve(Response(requestOptions: request, statusCode: 200,
        data: {'MediaContainer': {'FavoriteChannel': [
          for (final row in rows) {...row},
        ]}},
      ));
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
