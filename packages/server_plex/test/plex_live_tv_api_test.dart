import 'dart:async';

import 'package:dio/dio.dart';
import 'package:server_plex/src/api/plex_live_tv_api.dart';
import 'package:server_plex/src/api/plex_playback_api.dart';
import 'package:test/test.dart';

class _FakeServer extends Interceptor {
  _FakeServer(this.answer);

  final Object? Function(RequestOptions options) answer;
  final requests = <RequestOptions>[];

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    requests.add(options);
    handler.resolve(Response(requestOptions: options, data: answer(options)));
  }
}

// One program showing on two channels, as the XMLTV guide lists it.
const _teletubbies = {
  'type': 'episode',
  'title': 'Episode 5',
  'grandparentTitle': 'Teletubbies',
  'summary': 'The Teletubbies learn gymnastics.',
  'index': 5,
  'parentIndex': 3,
  'Media': [
    {
      'beginsAt': 1792699380,
      'endsAt': 1792703040,
      'channelIdentifier': '4',
      'channelTitle': '4 USA Teletubbies',
      'premiere': '1',
      'onAir': true,
    },
    {
      'beginsAt': 1792710000,
      'endsAt': 1792713660,
      'channelIdentifier': '9',
      'channelTitle': '9 USA Barney',
    },
  ],
};

(Dio, _FakeServer) _server() {
  final server = _FakeServer(
    (options) => switch (options.uri.path) {
      '/livetv/dvrs' => {
        'MediaContainer': {
          'Dvr': [
            {'key': '2', 'epgIdentifier': 'tv.plex.providers.epg.xmltv:2'},
          ],
        },
      },
      '/tv.plex.providers.epg.xmltv:2/lineups/dvr/channels' => {
        'MediaContainer': {
          'Channel': [
            {
              'id': '4',
              'vcn': '4',
              'title': 'USA Teletubbies',
              'thumb': 'http://dispatcharr/logos/4',
            },
          ],
        },
      },
      '/lineups/plex/channels' => {
        'MediaContainer': {
          'Channel': [
            {
              'id': 'abc-66635fc0',
              'vcn': '000',
              'title': 'CW Forever',
              'thumb': 'https://provider-static.plex.tv/cw.png',
            },
            {'id': 'locked-1', 'title': 'Locked', 'drm': true},
          ],
        },
      },
      '/library/search' => {
        'MediaContainer': {
          'SearchResults': [
            {
              'id': 'liveTv',
              'SearchResult': [
                {
                  'Metadata': {
                    'type': 'show',
                    'title': 'World Poker Tour',
                    'Media': [
                      {
                        'channelIdentifier': 'abc-66635fc0',
                        'beginsAt': 1792699200,
                        'endsAt': 1792706400,
                      },
                    ],
                  },
                },
                {
                  'Channel': {
                    'id': 'abc-66635fc0',
                    'title': 'World Poker Tour',
                  },
                },
              ],
            },
            {
              'id': 'plex',
              'SearchResult': [
                {
                  'Metadata': {
                    'type': 'movie',
                    'title': 'World Poker Tour',
                    'Media': [
                      {
                        'channelIdentifier': 'abc-66635fc0',
                        'beginsAt': 1792699200,
                        'endsAt': 1792706400,
                      },
                    ],
                  },
                },
              ],
            },
          ],
        },
      },
      '/tv.plex.providers.epg.xmltv:2/library/search' => {
        'MediaContainer': {
          'SearchResult': [
            {
              'Metadata': {
                'ratingKey': 'sintel',
                'type': 'movie',
                'title': 'Sintel',
                'Media': [
                  {
                    'channelIdentifier': '4',
                    'beginsAt': 1792699380,
                    'endsAt': 1792703040,
                  },
                ],
              },
            },
            {
              'Metadata': {
                'ratingKey': 'teletubbies',
                'type': 'show',
                'title': 'Teletubbies',
                'key': '/tv.plex.providers.epg.xmltv:2/metadata/tubbies/children',
              },
            },
          ],
        },
      },
      '/tv.plex.providers.epg.xmltv:2/metadata/tubbies/grandchildren' => {
        'MediaContainer': {'Metadata': [_teletubbies]},
      },
      '/tv.plex.providers.epg.xmltv:2/grid' => {
        'MediaContainer': {
          'Metadata': [
            _teletubbies,
            {
              'type': 'movie',
              'title': 'SuperKitties',
              'Media': [
                {
                  'beginsAt': 1792703040,
                  'endsAt': 1792704540,
                  'channelIdentifier': '4',
                },
              ],
            },
          ],
        },
      },
      '/media/subscriptions/scheduled' => {
        'MediaContainer': {
          'MediaGrabOperation': [
            {
              'id': 'once',
              'mediaSubscriptionID': 7,
              'mediaIndex': 0,
              'status': 'scheduled',
              'provider': 'tv.plex.providers.epg.xmltv:2',
              'Metadata': _teletubbies,
            },
            {
              'id': 'weekly',
              'mediaSubscriptionID': 8,
              'mediaIndex': 1,
              'status': 'inprogress',
              'provider': 'tv.plex.providers.epg.xmltv:2',
              'Metadata': {..._teletubbies, 'grandparentSubscriptionID': '8'},
            },
          ],
        },
      },
      '/media/subscriptions/template' => {
        'MediaContainer': {
          'SubscriptionTemplate': [
            {
              'MediaSubscription': [
                {
                  'type': 4,
                  'parameters': 'hints%5Btype%5D=4',
                  'targetLibrarySectionID': 2,
                  'targetSectionLocationID': 3,
                  'Setting': [
                    {'id': 'recordPartials', 'value': 'true'},
                    {'id': 'lineupChannel', 'value': ''},
                  ],
                },
                {
                  'type': 2,
                  'parameters': 'hints%5Btype%5D=2',
                  'Setting': [
                    {'id': 'onlyNewAirings', 'value': '1'},
                  ],
                },
              ],
            },
          ],
        },
      },
      '/media/subscriptions/8' => {
        'MediaContainer': {
          'MediaSubscription': [
            {
              'key': '8',
              'type': 2,
              'Setting': [
                {'id': 'onlyNewAirings', 'value': '1'},
              ],
            },
          ],
        },
      },
      '/livetv/dvrs/2/channels/4/tune' => {
        'MediaContainer': {
          'MediaSubscription': [
            {
              'MediaGrabOperation': [
                {
                  'Metadata': {
                    'key': '/livetv/sessions/f00d',
                    'ratingKey': '12345',
                  },
                },
              ],
            },
          ],
        },
      },
      '/grid' => {
        'MediaContainer': {
          'Metadata': [
            {
              'type': 'movie',
              'title': 'Law Abiding Citizen',
              'Media': [
                {'beginsAt': 1792699200, 'endsAt': 1792706400},
                {'beginsAt': 1792800000, 'endsAt': 1792807200},
              ],
            },
          ],
        },
      },
      _ => {'MediaContainer': <String, dynamic>{}},
    },
  );
  return (Dio()..interceptors.add(server), server);
}

void main() {
  test('searches DVR movies and series without fetching free-channel EPG', () async {
    final (dio, server) = _server();
    final api = PlexLiveTvApi(dio);
    final movie = await api.searchProgramTitles('Sintel', isCurrent: () => true);
    expect(movie.single['ChannelId'], 'channel-2-4');
    expect(movie.single['StartDate'], '2026-10-22T20:03:00.000Z');

    final shows = await api.searchProgramTitles('Teletubbies', isCurrent: () => true);
    expect(shows.map((p) => p['ChannelId']), ['channel-2-4', 'channel-2-9']);
    expect(shows.map((p) => p['Name']), ['Teletubbies', 'Teletubbies']);
    expect(server.requests.where((r) => r.uri.path.endsWith('/grandchildren')),
        hasLength(1));
    expect(server.requests.where((r) => r.uri.host == 'epg.provider.plex.tv'),
        isEmpty);
    var currentChecks = 0;
    expect(await api.searchProgramTitles(
      'Sintel', isCurrent: () => currentChecks++ == 0,
    ), isEmpty);
    expect(
      server.requests.where(
        (r) => r.uri.path.endsWith('/library/search') &&
            r.uri.host != 'discover.provider.plex.tv',
      ),
      hasLength(2),
    );
  });

  test('publishes DVR matches before the cloud search completes', () async {
    final (dio, _) = _server();
    final cloudRequested = Completer<void>();
    RequestOptions? cloudOptions;
    RequestInterceptorHandler? cloudHandler;
    dio.interceptors.insert(
      0,
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.uri.host == 'discover.provider.plex.tv') {
            cloudOptions = options;
            cloudHandler = handler;
            cloudRequested.complete();
          } else {
            handler.next(options);
          }
        },
      ),
    );

    final batches = <List<Map<String, dynamic>>>[];
    final pending = PlexLiveTvApi(dio).searchProgramTitlesIncrementally(
      'Sintel',
      isCurrent: () => true,
      onBatch: (batch) => batches.add(batch),
    );
    await cloudRequested.future;
    expect(batches, hasLength(1));
    expect(batches.single.single['ChannelId'], 'channel-2-4');

    cloudHandler!.next(cloudOptions!);
    final combined = await pending;
    expect(combined, hasLength(1));
    expect(combined.single['ChannelId'], 'channel-2-4');
  });

  test('publishes ready movies before a slow series lookup in the same page', () async {
    final (dio, server) = _server();
    final detailRequested = Completer<void>();
    RequestOptions? detailOptions;
    RequestInterceptorHandler? detailHandler;
    dio.interceptors.insert(
      0,
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.uri.path == '/tv.plex.providers.epg.xmltv:2/library/search') {
            // Put the show first so it would block the movie in a serial walk.
            final container =
                (server.answer(options) as Map)['MediaContainer'] as Map;
            handler.resolve(
              Response(
                requestOptions: options,
                data: {
                  'MediaContainer': {
                    ...container,
                    'SearchResult':
                        (container['SearchResult'] as List).reversed.toList(),
                  },
                },
              ),
            );
          } else if (options.uri.path.endsWith('/grandchildren')) {
            detailOptions = options;
            detailHandler = handler;
            detailRequested.complete();
          } else {
            handler.next(options);
          }
        },
      ),
    );

    final batches = <List<Map<String, dynamic>>>[];
    final pending = PlexLiveTvApi(dio).searchProgramTitlesIncrementally(
      'tel',
      isCurrent: () => true,
      onBatch: (batch) => batches.add(batch),
    );
    await detailRequested.future;

    // Sintel matches "tel" and is ready even though the first hit is a show.
    expect(batches, hasLength(1));
    expect(batches.single.map((program) => program['Name']), ['Sintel']);
    expect(
      server.requests.where(
        (request) => request.uri.host == 'discover.provider.plex.tv',
      ),
      isEmpty,
    );

    detailHandler!.next(detailOptions!);
    final results = await pending;
    expect(batches, hasLength(2));
    expect(
      batches.last.map((program) => program['Name']),
      ['Teletubbies', 'Teletubbies'],
    );
    expect(
      results.map((program) => program['Name']),
      ['Sintel', 'Teletubbies', 'Teletubbies'],
    );
  });

  test('continues after a failed series lookup', () async {
    final (dio, server) = _server();
    const epg = '/tv.plex.providers.epg.xmltv:2';
    const searchPath = '$epg/library/search';
    const brokenPath = '$epg/metadata/broken/grandchildren';
    const goodPath = '$epg/metadata/tubbies/grandchildren';
    var failures = 0;

    dio.interceptors.insert(
      0,
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.uri.path == searchPath) {
            final container =
                (server.answer(options) as Map)['MediaContainer'] as Map;
            handler.resolve(
              Response(
                requestOptions: options,
                data: {
                  'MediaContainer': {
                    ...container,
                    'SearchResult': [
                      {
                        'Metadata': {
                          'ratingKey': 'broken',
                          'type': 'show',
                          'title': 'Teletubbies Broken',
                          'key': '$epg/metadata/broken/children',
                        },
                      },
                      ...(container['SearchResult'] as List),
                    ],
                  },
                },
              ),
            );
          } else if (options.uri.path == brokenPath) {
            failures++;
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.badResponse,
                response: Response(requestOptions: options, statusCode: 500),
                message: 'Broken series details',
              ),
            );
          } else {
            handler.next(options);
          }
        },
      ),
    );

    final batches = <List<Map<String, dynamic>>>[];
    final programs = await PlexLiveTvApi(dio).searchProgramTitlesIncrementally(
      'tel',
      isCurrent: () => true,
      onBatch: batches.add,
    );

    expect(failures, 1);
    expect(
      server.requests.where((request) => request.uri.path == goodPath),
      hasLength(1),
    );
    expect(
      batches.map((batch) => batch.map((p) => p['Name']).toList()).toList(),
      [
        ['Sintel'],
        ['Teletubbies', 'Teletubbies'],
      ],
    );
    expect(programs.map((p) => p['Name']).toList(), [
      'Sintel',
      'Teletubbies',
      'Teletubbies',
    ]);
    expect(
      server.requests.where(
        (request) => request.uri.host == 'discover.provider.plex.tv',
      ),
      hasLength(1),
    );
  });

  test('keeps DVR matches if Plex Discover search fails', () async {
    final (dio, server) = _server();
    var cloudAttempts = 0;
    dio.interceptors.insert(
      0,
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.uri.host == 'discover.provider.plex.tv') {
            cloudAttempts++;
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.connectionError,
                message: 'Plex Discover unavailable',
              ),
            );
          } else {
            handler.next(options);
          }
        },
      ),
    );

    final api = PlexLiveTvApi(dio);
    final results = await api.searchProgramTitles(
      'Sintel',
      isCurrent: () => true,
    );
    expect(results, hasLength(1));
    expect(results.single['ChannelId'], 'channel-2-4');
    expect(cloudAttempts, 1);
    expect(
      server.requests.where(
        (request) => request.uri.path.endsWith('/library/search'),
      ),
      hasLength(1),
    );

    // Without any DVR matches, keep the normal failed-search behavior.
    await expectLater(
      api.searchProgramTitles('World Poker Tour', isCurrent: () => true),
      throwsA(isA<DioException>()),
    );
    expect(cloudAttempts, 2);
  });

  for (final failure in [
    DioExceptionType.connectionError,
    DioExceptionType.badResponse,
  ]) {
    test('free-channel search survives DVR discovery ${failure.name}', () async {
      final (dio, server) = _server();
      var dvrAttempts = 0;
      dio.interceptors.insert(
        0,
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.uri.path == '/livetv/dvrs') {
              dvrAttempts++;
              handler.reject(
                DioException(
                  requestOptions: options,
                  type: failure,
                  response: failure == DioExceptionType.badResponse
                      ? Response(requestOptions: options, statusCode: 503)
                      : null,
                  message: 'DVR discovery unavailable',
                ),
              );
            } else {
              handler.next(options);
            }
          },
        ),
      );

      final results = await PlexLiveTvApi(dio).searchProgramTitles(
        'World Poker Tour',
        isCurrent: () => true,
      );
      expect(dvrAttempts, 1);
      expect(results, hasLength(1));
      expect(results.single['ChannelId'], 'channel-plex-abc-66635fc0');
      expect(
        server.requests.where(
          (request) => request.uri.host == 'discover.provider.plex.tv',
        ),
        hasLength(1),
      );
      expect(
        server.requests.where(
          (request) => request.uri.path.endsWith('/grid'),
        ),
        isEmpty,
      );
    });
  }

  for (final path in [
    '/tv.plex.providers.epg.xmltv:2/library/search',
    '/tv.plex.providers.epg.xmltv:2/metadata/tubbies/grandchildren',
  ]) {
    test('free-channel search survives a DVR program failure at $path', () async {
      final (dio, server) = _server();
      var dvrFailures = 0;
      dio.interceptors.insert(
        0,
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.uri.path == path) {
              dvrFailures++;
              handler.reject(
                DioException(
                  requestOptions: options,
                  type: DioExceptionType.badResponse,
                  response: Response(requestOptions: options, statusCode: 500),
                  message: 'DVR EPG unavailable',
                ),
              );
            } else {
              handler.next(options);
            }
          },
        ),
      );

      final results = await PlexLiveTvApi(dio).searchProgramTitles(
        'World Poker Tour',
        isCurrent: () => true,
      );
      expect(dvrFailures, 1);
      expect(results, hasLength(1));
      expect(results.single['ChannelId'], 'channel-plex-abc-66635fc0');
      expect(
        server.requests.where(
          (request) => request.uri.host == 'discover.provider.plex.tv',
        ),
        hasLength(1),
      );
    });
  }

  test('a later DVR failure keeps matches from an earlier DVR', () async {
    final (dio, server) = _server();
    var failures = 0;
    dio.interceptors.insert(
      0,
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.uri.path == '/livetv/dvrs') {
            handler.resolve(
              Response(
                requestOptions: options,
                data: {
                  'MediaContainer': {
                    'Dvr': [
                      {'key': '2', 'epgIdentifier': 'tv.plex.providers.epg.xmltv:2'},
                      {'key': '3', 'epgIdentifier': 'tv.plex.providers.epg.xmltv:3'},
                    ],
                  },
                },
              ),
            );
          } else if (
              options.uri.path ==
              '/tv.plex.providers.epg.xmltv:3/library/search') {
            failures++;
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.connectionError,
                message: 'Second DVR offline',
              ),
            );
          } else {
            handler.next(options);
          }
        },
      ),
    );

    final batches = <List<Map<String, dynamic>>>[];
    final results = await PlexLiveTvApi(dio).searchProgramTitlesIncrementally(
      'Sintel',
      isCurrent: () => true,
      onBatch: (batch) => batches.add(batch),
    );
    expect(failures, 1);
    expect(batches, hasLength(1));
    expect(batches.single.single['ChannelId'], 'channel-2-4');
    expect(results, hasLength(1));
    expect(results.single['ChannelId'], 'channel-2-4');
    expect(
      server.requests.where(
        (request) => request.uri.host == 'discover.provider.plex.tv',
      ),
      hasLength(1),
    );
  });

  test('searches free channel programs without fetching their grids', () async {
    final (dio, server) = _server();
    final api = PlexLiveTvApi(dio);
    final channels = ((await api.getChannels())['Items'] as List).cast<Map>();
    final programs = await api.searchProgramTitles(
      'World Poker Tour',
      isCurrent: () => true,
    );
    expect(programs, hasLength(1));
    expect(programs.single['ChannelId'], channels.last['Id']);
    expect(programs.single['StartDate'], '2026-10-22T20:00:00.000Z');

    final requests = server.requests.where(
      (r) => r.uri.host == 'discover.provider.plex.tv',
    );
    expect(requests, hasLength(1));
    expect(
      requests.single.queryParameters,
      containsPair('searchProviders', 'plexFAST'),
    );
    expect(requests.single.queryParameters, containsPair('limit', 500));
    expect(server.requests.where((r) => r.uri.path == '/grid'), isEmpty);
  });

  test('channel-only search results do not become EPG programs', () async {
    final (dio, _) = _server();
    expect(
      await PlexLiveTvApi(dio).searchProgramTitles(
        'news',
        isCurrent: () => true,
      ),
      isEmpty,
    );
  });

  test('channel and showing ids come apart again', () {
    expect(plexChannelOf('channel-2-4'), (source: '2', channel: '4'));
    expect(plexChannelOf('channel-plex-abc-66635fc0'), (
      source: 'plex',
      channel: 'abc-66635fc0',
    ));
    expect(plexChannelOf('1715'), isNull);
    expect(plexAiringOf('airing-plex-1792699380-abc-66635fc0'), (
      source: 'plex',
      beginsAt: 1792699380,
      channel: 'abc-66635fc0',
    ));
  });

  test(
    "the tuner's channels come first, numbered, then the free ones",
    () async {
      final (dio, _) = _server();
      final result = await PlexLiveTvApi(dio).getChannels();

      final channels = (result['Items'] as List).cast<Map>();
      expect(channels.map((c) => c['Id']), [
        'channel-2-4',
        'channel-plex-abc-66635fc0',
      ]);
      expect(channels.first, containsPair('ChannelNumber', '4'));
      expect(channels.first['Type'], 'TvChannel');
      expect(channels.last.containsKey('ChannelNumber'), isFalse);
      expect(result['TotalRecordCount'], 2);
    },
  );

  test('every showing of a program is a program of its own', () async {
    final (dio, server) = _server();
    final result = await PlexLiveTvApi(dio).getGuide(
      startDate: DateTime.utc(2026, 10, 22),
      endDate: DateTime.utc(2026, 10, 23),
      channelIds: ['channel-2-4'],
    );

    final programs = (result['Items'] as List).cast<Map>();
    expect(programs, hasLength(2));
    expect(
      programs.first,
      allOf(
        containsPair('Id', 'airing-2-1792699380-4'),
        containsPair('ChannelId', 'channel-2-4'),
        containsPair('Name', 'Teletubbies'),
        containsPair('EpisodeTitle', 'Episode 5'),
        containsPair('IsPremiere', true),
        containsPair('IndexNumber', 5),
        containsPair('StartDate', '2026-10-22T20:03:00.000Z'),
      ),
    );
    expect(programs.first['TimerId'], 'once');
    expect(
      programs.last,
      allOf(
        containsPair('Name', 'SuperKitties'),
        containsPair('IsMovie', false),
      ),
    );
    expect(programs.last.containsKey('TimerId'), isFalse);
    final grid = server.requests.singleWhere(
      (r) => r.uri.path.endsWith('/grid'),
    );
    expect(grid.queryParameters['type'], '1,4');
  });

  test('recording one showing holds it to its channel and time', () async {
    final (dio, server) = _server();
    await PlexLiveTvApi(dio).createTimer('airing-2-1792699380-4');

    final post = server.requests.singleWhere((r) => r.method == 'POST');
    expect(post.uri.path, '/media/subscriptions');
    expect(post.uri.query, startsWith('hints%5Btype%5D=4&'));
    expect(
      post.uri.queryParameters,
      allOf(
        containsPair('type', '4'),
        containsPair('targetLibrarySectionID', '2'),
        containsPair('prefs[recordPartials]', 'true'),
        containsPair('prefs[lineupChannel]', '4'),
        containsPair('prefs[startTimeslot]', '1792699380'),
      ),
    );
  });

  test('a series rule takes repeats or not, and can be changed', () async {
    final (dio, server) = _server();
    final api = PlexLiveTvApi(dio);

    await api.createSeriesTimer(
      'airing-2-1792699380-4',
      settings: {'RecordNewOnly': false, 'SkipEpisodesInLibrary': true},
    );
    final rule = await api.getSeriesTimer('8');
    await api.updateSeriesTimer('8', {...rule, 'RecordNewOnly': false});

    final post = server.requests.singleWhere((r) => r.method == 'POST');
    expect(
      post.uri.queryParameters,
      allOf(
        containsPair('type', '2'),
        containsPair('prefs[onlyNewAirings]', '0'),
      ),
    );
    expect(rule, containsPair('RecordNewOnly', true));
    final put = server.requests.singleWhere((r) => r.method == 'PUT');
    expect(put.uri.path, '/media/subscriptions/8');
    expect(put.uri.queryParameters, {'prefs[onlyNewAirings]': '0'});
  });

  test('scheduled showings are timers, and each cancels its own way', () async {
    final (dio, server) = _server();
    final api = PlexLiveTvApi(dio);

    final timers = ((await api.getTimers())['Items'] as List).cast<Map>();
    expect(
      timers.first,
      allOf(
        containsPair('Id', 'once'),
        containsPair('ProgramId', 'airing-2-1792699380-4'),
        containsPair('Status', 'New'),
      ),
    );
    expect(timers.first.containsKey('SeriesTimerId'), isFalse);
    expect(
      timers.last,
      allOf(
        containsPair('ProgramId', 'airing-2-1792710000-9'),
        containsPair('SeriesTimerId', '8'),
        containsPair('Status', 'InProgress'),
      ),
    );

    await api.cancelTimer('once');
    await api.cancelTimer('airing-2-1792710000-9');
    expect(
      server.requests.where((r) => r.method == 'DELETE').map((r) => r.uri.path),
      ['/media/subscriptions/7', '/media/grabbers/operations/weekly'],
    );
  });

  test('a free channel only asks plex.tv for showings in the window', () async {
    final (dio, server) = _server();
    final result = await PlexLiveTvApi(dio).getGuide(
      startDate: DateTime.utc(2026, 10, 22, 20).toLocal(),
      endDate: DateTime.utc(2026, 10, 22, 22).toLocal(),
      channelIds: ['channel-plex-abc-66635fc0'],
    );

    final programs = (result['Items'] as List).cast<Map>();
    expect(programs.map((p) => p['Id']), [
      'airing-plex-1792699200-abc-66635fc0',
    ]);
    final grid = server.requests.single;
    expect(grid.uri.path, '/grid');
    expect(grid.queryParameters['date'], '2026-10-22');
  });

  test('a free channel plays straight from plex.tv', () async {
    final (dio, server) = _server();
    final info = await PlexPlaybackApi(dio, const {
      'X-Plex-Product': 'Moonfin',
    }).getPlaybackInfo('channel-plex-abc-66635fc0');

    final source = (info['MediaSources'] as List).single as Map;
    expect(
      source['TranscodingUrl'],
      startsWith(
        'https://epg.provider.plex.tv/library/parts/abc-66635fc0.m3u8?',
      ),
    );
    expect(source['SupportsDirectPlay'], isFalse);
    expect(server.requests, isEmpty);
  });

  test('a tuner channel is tuned, decided, then streamed', () async {
    final (dio, server) = _server();
    final api = PlexPlaybackApi(dio, const {'X-Plex-Product': 'Moonfin'});
    final info = await api.getPlaybackInfo('channel-2-4');

    expect(server.requests.map((r) => r.uri.path), [
      '/livetv/dvrs/2/channels/4/tune',
      '/video/:/transcode/universal/decision',
    ]);
    final source = (info['MediaSources'] as List).single as Map;
    final start = Uri.parse(source['TranscodingUrl'] as String);
    expect(start.path, '/video/:/transcode/universal/start.m3u8');
    expect(start.queryParameters['path'], '/livetv/sessions/f00d');
    expect(start.queryParameters['session'], info['PlaySessionId']);

    await api.reportPlaybackProgress({
      'ItemId': 'channel-2-4',
      'PlaySessionId': info['PlaySessionId'],
      'PositionTicks': 300000000,
    });
    expect(
      server.requests.last.uri.queryParameters,
      allOf(
        containsPair('ratingKey', '12345'),
        containsPair('key', '/livetv/sessions/f00d'),
        containsPair('time', '30000'),
      ),
    );
  });

  test('only a cap a broadcast could pass reaches a tuner stream', () async {
    Future<Map<String, String>> startFor(int bitrate) async {
      final (dio, _) = _server();
      final info = await PlexPlaybackApi(dio, const {}).getPlaybackInfo(
        'channel-2-4',
        requestBody: {'MaxStreamingBitrate': bitrate},
      );
      final source = (info['MediaSources'] as List).single as Map;
      return Uri.parse(source['TranscodingUrl'] as String).queryParameters;
    }

    expect((await startFor(120000000)).containsKey('maxVideoBitrate'), isFalse);
    expect((await startFor(8000000))['maxVideoBitrate'], '8000');
  });
}
