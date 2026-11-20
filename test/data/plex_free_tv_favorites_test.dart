import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:moonfin/auth/models/user.dart';
import 'package:moonfin/auth/repositories/user_repository.dart';
import 'package:moonfin/data/repositories/item_mutation_repository.dart';
import 'package:moonfin/data/services/plex_free_tv_favorites.dart';
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
    (PlexFreeTvFavorites.applyToItem(client, {
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
    PlexFreeTvFavorites.resetForTesting();
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
    PlexFreeTvFavorites.testHttp = http;
  });

  tearDown(() async {
    userDataSync.reset();
    PlexFreeTvFavorites.resetForTesting();
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
    PlexFreeTvFavorites.applyToItem(direct, _channel);
    await PlexFreeTvFavorites.refresh(direct);
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
      key: 'plex_free_tv_favorites_plex-user', defaultValue: [],
    ), ['channel-plex-free123']);
    PlexFreeTvFavorites.applyToItem(direct, _channel);
    expect(_saved(direct, 'channel-plex-free123'), isTrue);

    cloud.rows = [{'source': 'server://other/dvr', 'id': 'different'}];
    await PlexFreeTvFavorites.refresh(direct);
    expect(_saved(direct, 'channel-plex-free123'), isFalse);
    expect(cloud.rows.single['id'], 'different');
    expect(cloud.requests.where((r) => r.method == 'PUT'), isEmpty);

    cloud.getError = 503;
    await expectLater(PlexFreeTvFavorites.refresh(direct), throwsA(isA<DioException>()));
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

  test('serializes separate channel updates and rejects a different Home user', () async {
    final pms = _plex();
    addTearDown(pms.dispose);
    PlexFreeTvFavorites.applyToItem(pms, _channel);
    PlexFreeTvFavorites.applyToItem(pms, {..._channel, 'Id': 'channel-plex-extra'});
    await PlexFreeTvFavorites.refresh(pms);
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
    await expectLater(PlexFreeTvFavorites.refresh(pms), throwsA(isA<StateError>()));
    expect(cloud.requests, hasLength(requests));
  });
}
