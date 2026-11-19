import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:moonfin/data/repositories/item_mutation_repository.dart';
import 'package:moonfin/data/services/plex_free_tv_favorites.dart';
import 'package:moonfin/data/services/user_data_sync.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:server_core/server_core.dart';
import 'package:server_plex/server_plex.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _device = DeviceInfo(
  id: 'device',
  name: 'Test',
  appName: 'Moonfin',
  appVersion: '1.0.0',
);

PlexMediaServerClient _plex(String userId, {bool cloudOnly = false}) =>
    PlexMediaServerClient(
      baseUrl: cloudOnly ? 'https://plex.tv' : 'https://pms.example',
      deviceInfo: _device,
      cloudOnly: cloudOnly,
    )..userId = userId;

class _ServerTypeProbe extends Fake implements MediaServerClient {
  _ServerTypeProbe(this._type);

  final ServerType _type;
  int reads = 0;

  @override
  ServerType get serverType {
    reads++;
    return _type;
  }
}

void main() {
  test('unrelated item IDs skip the Plex server-type lookup', () {
    final plex = _ServerTypeProbe(ServerType.plex);
    for (final id in ['', 'movie-1', 'book-1', 'channel-2-4']) {
      expect(isPlexFreeTvChannel(plex, id), isFalse);
    }
    expect(plex.reads, 0);

    expect(isPlexFreeTvChannel(plex, 'channel-plex-free123'), isTrue);
    expect(plex.reads, 1);

    final jellyfin = _ServerTypeProbe(ServerType.jellyfin);
    expect(isPlexFreeTvChannel(jellyfin, 'channel-plex-free123'), isFalse);
    expect(jellyfin.reads, 1);
  });

  setUp(() async {
    userDataSync.reset();
    SharedPreferences.setMockInitialValues({});
    final store = PreferenceStore();
    await store.init();
    GetIt.instance.registerSingleton<UserPreferences>(UserPreferences(store));
  });

  tearDown(() async {
    userDataSync.reset();
    await GetIt.instance.reset();
  });

  test('cloud favorites persist for the same Plex profile on a media server', () async {
    final cloud = _plex('plex-user', cloudOnly: true);
    final server = _plex('plex-user');
    final anotherUser = _plex('other-user');

    const freeChannel = <String, dynamic>{
      'Id': 'channel-plex-free123',
      'UserData': {'IsFavorite': false},
    };
    const dvrChannel = <String, dynamic>{
      'Id': 'channel-2-4',
      'UserData': {'IsFavorite': false},
    };

    await ItemMutationRepository(cloud).setFavorite(
      'channel-plex-free123',
      isFavorite: true,
    );
    expect(
      (PlexFreeTvFavorites.applyToItem(server, freeChannel)['UserData']
          as Map)['IsFavorite'],
      isTrue,
    );
    expect(
      (PlexFreeTvFavorites.applyToItem(anotherUser, freeChannel)['UserData']
          as Map)['IsFavorite'],
      isFalse,
    );
    expect(
      (PlexFreeTvFavorites.applyToItem(server, dvrChannel)['UserData']
          as Map)['IsFavorite'],
      isFalse,
    );
    await ItemMutationRepository(server).setFavorite(
      'channel-plex-free123',
      isFavorite: false,
    );
    expect(
      (PlexFreeTvFavorites.applyToItem(cloud, freeChannel)['UserData']
          as Map)['IsFavorite'],
      isFalse,
    );

    cloud.dispose();
    server.dispose();
    anotherUser.dispose();
  });
}
