@TestOn('browser')
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:server_core/server_core.dart';
import 'package:server_plex/src/api/plex_live_tv_api.dart';
import 'package:server_plex/src/api/plex_live_tv_favorites_api.dart';
import 'package:test/test.dart';

void main() {
  test(
    'the browser reads and writes Plex Cloud data directly and rejects redirects',
    () async {
      final fixture = spawnHybridUri(
        'fixtures/plex_cloud_server.dart',
        message: Uri.base.origin,
      );
      final origin = await fixture.stream.first as String;
      var redirect = false;
      Dio client() {
        final dio = Dio(BaseOptions(baseUrl: origin));
        addTearDown(dio.close);
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (request, handler) {
              if (request.uri.host == 'epg.provider.plex.tv') {
                request.path =
                    '$origin${redirect ? '/redirect' : ''}${request.uri.path}';
              }
              handler.next(request);
            },
          ),
        );
        return dio;
      }

      final guideClient = client();
      Future<List> channels() async =>
          (await PlexLiveTvApi(guideClient).getChannels())['Items'] as List;
      final favorites = PlexLiveTvFavoritesApi(dio: client());
      const device = DeviceInfo(
        id: 'test',
        name: 'test',
        appName: 'Moonfin',
        appVersion: '1',
      );
      const rows = [
        {'source': 'provider://fixture', 'id': 'one'},
      ];
      Future<List> read() =>
          favorites.readFavorites(deviceInfo: device, accountToken: 'fixture');
      Future<void> write() => favorites.writeFavorites(
        deviceInfo: device,
        accountToken: 'fixture',
        rows: rows,
      );

      expect((await channels()).single['Id'], 'channel-plex-one');
      await write();
      expect(await read(), rows);

      redirect = true;
      expect(await channels(), isEmpty);
      await expectLater(read(), throwsA(isA<DioException>()));
      await expectLater(write(), throwsA(isA<DioException>()));
      final counts = (await guideClient.get('/counts')).data;
      expect(counts, {'redirects': 3, 'followed': 0});
    },
  );

  test(
    'a progressing browser response still reaches its total deadline',
    () async {
      final fixture = spawnHybridUri(
        'fixtures/plex_cloud_server.dart',
        message: Uri.base.origin,
      );
      final origin = await fixture.stream.first as String;
      const timeout = Duration(milliseconds: 600);
      final dio = Dio(
        BaseOptions(
          baseUrl: origin,
          connectTimeout: timeout,
          receiveTimeout: timeout,
        ),
      );
      addTearDown(dio.close);
      PlexLiveTvApi(dio);
      await expectLater(
        dio.get('/trickle', options: Options(followRedirects: false)),
        throwsA(
          isA<DioException>()
              .having((e) => e.type, 'type', DioExceptionType.receiveTimeout)
              .having(
                (e) => (e.error as TimeoutException).duration,
                'elapsed deadline',
                timeout + timeout,
              ),
        ),
      );
    },
  );
}
