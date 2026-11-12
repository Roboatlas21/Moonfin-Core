import 'package:dio/dio.dart';
import 'package:server_core/server_core.dart';
import 'package:test/test.dart';

Dio fixture(int status, {Object? body, bool revisionOnly = false}) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        expect(request.method, 'GET');
        expect(request.path, '/Moonfin/LiveTv/ChannelGroups');
        expect(
          request.queryParameters,
          revisionOnly ? {'guideRevisionOnly': true} : isEmpty,
        );
        final response = Response(
          requestOptions: request,
          data: body,
          statusCode: status,
        );
        if (status == 200) {
          handler.resolve(response);
        } else {
          handler.reject(
            DioException.badResponse(
              statusCode: status,
              requestOptions: request,
              response: response,
            ),
          );
        }
      },
    ),
  );
  return dio;
}

void main() {
  test('the revision check accepts a task-status-only response', () async {
    expect(
      await ChannelGroupLineup.fetchGuideRevision(
        fixture(200, body: {'guideRevision': '42'}, revisionOnly: true),
      ),
      '42',
    );
    expect(
      await ChannelGroupLineup.fetchGuideRevision(
        fixture(404, revisionOnly: true),
      ),
      isNull,
    );
  });

  test(
    'reads exact labels, removes blanks and preserves partial results',
    () async {
      final result = await ChannelGroupLineup.fetch(
        fixture(
          200,
          body: {
            'version': 1,
            'supported': true,
            'partial': true,
            'unresolvedChannelIds': ['offline'],
            'groupsByChannelId': {
              'seven': ['US| SPORTS', 'US|SPORTS', 'Kids', 'Kids', ' '],
            },
          },
        ),
      );
      expect(result.groupsByChannelId, {
        'seven': {'US| SPORTS', 'US|SPORTS', 'Kids'},
      });
      expect(result.partial, true);
      expect(result.unresolvedChannelIds, {'offline'});
      expect(result.programmeCategories, isNull);
    },
  );

  test('programme categories are independent of tuner group support', () async {
    Future<Set<String>?> read(Object? categories) async {
      final response = await ChannelGroupLineup.fetch(
        fixture(
          200,
          body: {
            'version': 1,
            'supported': false,
            'programmeCategories': categories,
          },
        ),
      );
      return response.programmeCategories;
    }

    expect(await read(['movies', 'premiere']), {'movies', 'premiere'});
    expect(await read([]), isEmpty);
    expect(await read(null), isNull);
    expect(await read(['movies', 123]), isNull);
  });

  test(
    'older Moonbase is optional and authorization failures reach the caller',
    () async {
      expect(
        (await ChannelGroupLineup.fetch(fixture(404))).groupsByChannelId,
        isEmpty,
      );
      for (final status in [401, 403, 503]) {
        await expectLater(
          ChannelGroupLineup.fetch(fixture(status)),
          throwsA(isA<DioException>()),
        );
      }
    },
  );
}
