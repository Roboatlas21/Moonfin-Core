import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:mocktail/mocktail.dart' show Mock, when;
import 'package:moonfin/auth/repositories/plex_repository.dart';
import 'package:moonfin/auth/repositories/server_repository.dart';
import 'package:moonfin/auth/repositories/session_repository.dart';
import 'package:moonfin/auth/store/authentication_preferences.dart';
import 'package:moonfin/auth/store/authentication_store.dart';
import 'package:moonfin/auth/store/credential_store.dart';
import 'package:moonfin/data/services/media_server_client_factory.dart';
import 'package:moonfin/data/services/plex_tv_service.dart';
import 'package:moonfin/playback/headless_session_bootstrap.dart';
import 'package:playback_plex/playback_plex.dart';
import 'package:server_core/server_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _StoredCredentials extends Fake implements CredentialStore {
  @override
  Future<String?> getToken(String serverId) async => null;
}

class _PlexTv extends Mock implements PlexTvService {}

class _Session extends Mock implements SessionRepository {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a saved Free TV sign-in restores and resolves a cloud stream',
    () async {
      SharedPreferences.setMockInitialValues({});
      final getIt = GetIt.instance;
      await getIt.reset();
      addTearDown(() async {
        await getIt.reset();
      });

      final prefs = PreferenceStore();
      await prefs.init();
      final authPrefs = AuthenticationPreferences(prefs);
      final authStore = AuthenticationStore();
      await authStore.init();

      final factory = MediaServerClientFactory(
        deviceInfo: const DeviceInfo(
          id: 'device',
          name: 'Device',
          appName: 'Moonfin',
          appVersion: '1.0.0',
        ),
      );
      addTearDown(factory.disposeAll);
      const cloudId = 'plex-cloud-viewer';
      final tv = _PlexTv();
      when(() => tv.getAccount('token'))
          .thenAnswer((_) async => (id: 'viewer', name: 'Viewer'));
      final session = _Session();
      when(
        () => session.switchCurrentSession(serverId: cloudId, userId: 'viewer'),
      ).thenAnswer((_) async {
        await authPrefs.setLastServerId(cloudId);
        await authPrefs.setLastUserId('viewer');
        return true;
      });
      final signIn = PlexRepository(
        tv,
        ServerRepository(authStore, factory),
        authStore,
        session,
      );
      expect(await signIn.connectCloud('token'), isTrue);
      expect(authStore.getUser(cloudId, 'viewer')?.plexToken, 'token');
      getIt.registerSingleton<MediaServerClientFactory>(factory);
      getIt.registerSingleton<AuthenticationPreferences>(authPrefs);
      getIt.registerSingleton<AuthenticationStore>(authStore);
      getIt.registerSingleton<ServerRepository>(
        ServerRepository(authStore, factory),
      );
      getIt.registerSingleton<CredentialStore>(_StoredCredentials());

      final client = await HeadlessSessionBootstrap().restoreClientOrThrow();
      expect(isCloudOnlyPlexClient(client), isTrue);
      expect(client.userId, 'viewer');
      final stream = await PlexMediaStreamResolver(client)
          .resolve({'Id': 'channel-plex-news', 'Type': 'TvChannel'});
      final url = Uri.parse(stream.streamUrl);
      expect(url.scheme, 'https');
      expect(url.host, 'epg.provider.plex.tv');
      expect(url.path, '/library/parts/news.m3u8');
      expect(url.queryParameters['X-Plex-Token'], 'token');
      // Foreground restoration must reuse a correctly configured cached client.
      final reused = factory.getClient(
        serverId: cloudId,
        serverType: ServerType.plex,
        baseUrl: 'https://plex.tv',
        cloudOnly: true,
      );
      expect(identical(reused, client), isTrue);
      expect(isCloudOnlyPlexClient(reused), isTrue);
    },
  );
}
