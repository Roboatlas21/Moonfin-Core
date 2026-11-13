import 'package:dio/dio.dart';
import 'package:server_jellyfin/src/api/jellyfin_live_tv_api.dart';
import 'package:test/test.dart';

void main() {
  test('Jellyfin checks all six program tags across the imported EPG', () async {
    final requests = <RequestOptions>[];
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            requests.add(request);
            final tag = request.queryParameters['Tags'];
            handler.resolve(
              Response(
                requestOptions: request,
                statusCode: 200,
                data: {
                  'Items': tag == 'Sports' || tag == 'Premiere'
                      ? <Map<String, dynamic>>[{'Id': 'program'}]
                      : <Map<String, dynamic>>[],
                },
              ),
            );
          },
        ),
      );
    final api = JellyfinLiveTvApi(dio);
    final first = api.getProgrammeCategories(userId: 'viewer');
    expect(identical(first, api.getProgrammeCategories(userId: 'viewer')), true);
    expect(await first, {'sports', 'premiere'});
    expect(requests, hasLength(6));
    expect(requests.map((r) => r.queryParameters['Tags']).toSet(), {
      'Movie', 'Series', 'Sports', 'News', 'Kids', 'Premiere',
    });
    for (final request in requests) {
      expect(request.method, 'GET');
      expect(request.path, '/Items');
      expect(request.queryParameters['UserId'], 'viewer');
      expect(request.queryParameters['IncludeItemTypes'], 'LiveTvProgram');
      expect(request.queryParameters['Recursive'], true);
      expect(request.queryParameters['Limit'], 1);
      expect(request.queryParameters['EnableTotalRecordCount'], false);
      expect(request.queryParameters.containsKey('MinStartDate'), false);
      expect(request.queryParameters.containsKey('MaxStartDate'), false);
      expect(request.queryParameters.containsKey('MinEndDate'), false);
      expect(request.queryParameters.containsKey('MaxEndDate'), false);
    }
    expect(await api.getProgrammeCategories(userId: 'viewer'), {
      'sports', 'premiere',
    });
    expect(requests, hasLength(6));
    await api.getProgrammeCategories(userId: 'another');
    expect(requests, hasLength(12));
  });

  test('a failed Jellyfin category probe stays unknown and can retry', () async {
    var responseStatus = 403;
    var valid = true;
    var calls = 0;
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            calls++;
            if (responseStatus != 200) {
              final response = Response(
                requestOptions: request,
                statusCode: responseStatus,
              );
              handler.reject(
                DioException.badResponse(
                  statusCode: responseStatus,
                  requestOptions: request,
                  response: response,
                ),
              );
              return;
            }
            handler.resolve(
              Response(
                requestOptions: request,
                statusCode: 200,
                data: valid ? {'Items': <dynamic>[]} : <String, dynamic>{},
              ),
            );
          },
        ),
      );
    final api = JellyfinLiveTvApi(dio);
    expect(await api.getProgrammeCategories(userId: 'viewer'), isNull);
    expect(calls, 6);
    responseStatus = 200;
    valid = false;
    expect(await api.getProgrammeCategories(userId: 'viewer'), isNull);
    expect(calls, 12);
    valid = true;
    expect(await api.getProgrammeCategories(userId: 'viewer'), isEmpty);
    expect(calls, 18);
  });
}
