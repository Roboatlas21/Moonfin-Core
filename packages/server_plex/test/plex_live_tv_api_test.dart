import 'dart:async';

import 'package:dio/dio.dart';
import 'package:server_plex/src/api/plex_live_tv_api.dart';
import 'package:server_plex/src/api/plex_playback_api.dart';
import 'package:test/test.dart';

class _FakeServer extends Interceptor {
  _FakeServer(this.answer);

  final Object? Function(RequestOptions options) answer;
  final requests = <RequestOptions>[];
  bool Function(RequestOptions)? failWhen;
  int? Function()? failureStatus;
  Map<String, dynamic>? tunerReply;
  Map<String, dynamic>? discoveryReply;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (failWhen?.call(options) == true) {
      final code = failureStatus?.call();
      handler.reject(DioException(
        requestOptions: options,
        type: code == null
            ? DioExceptionType.connectionError
            : DioExceptionType.badResponse,
        response: code == null
            ? null
            : Response(requestOptions: options, statusCode: code),
      ));
      return;
    }
    requests.add(options);
    final reply = options.uri.path.startsWith('/tv.plex.providers.epg.xmltv:2/')
        ? tunerReply
        : null;
    final discovery = options.uri.path == '/livetv/dvrs' ? discoveryReply : null;
    handler.resolve(Response(requestOptions: options, data: discovery ?? reply ?? answer(options)));
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

(Dio, _FakeServer) _server({
  bool secondDvr = false,
  bool liveDvr = false,
  bool malformedDvrGrid = false,
}) {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final server = _FakeServer(
    (options) => switch (options.uri.path) {
      '/identity' => {
        'MediaContainer': {'machineIdentifier': 'pms-machine-1'},
      },
      '/livetv/dvrs' => {
        'MediaContainer': {
          'Dvr': [
            {'key': '2', 'epgIdentifier': 'tv.plex.providers.epg.xmltv:2'},
            if (secondDvr)
              {'key': '3', 'epgIdentifier': 'tv.plex.providers.epg.xmltv:3'},
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
      '/tv.plex.providers.epg.xmltv:3/lineups/dvr/channels' => {
        'MediaContainer': {'Channel': [{'id': '7', 'title': 'Station Seven'}]},
      },
      '/lineups/plex/channels' || '/lineups/plex/channels/featured' => {
        'MediaContainer': {
          'Channel': [
            {
              'id': 'abc-66635fc0',
              'gridKey': 'provider-42',
              'vcn': '000',
              'title': 'CW Forever',
              'genreRatingKeys': [8, '7', 'blank', 'unknown'],
              'thumb': 'https://provider-static.plex.tv/cw.png',
            },
            // Present in All Channels, but deliberately absent from Featured.
            if (options.uri.path == '/lineups/plex/channels')
              {'id': 'news-extra', 'title': 'News Extra'},
            {'id': 'locked-1', 'title': 'Locked', 'drm': true},
          ],
        },
      },
      '/tv.plex.providers.epg.xmltv:2/grid' => {
        'MediaContainer': {
          'Metadata': malformedDvrGrid ? <String, dynamic>{} : liveDvr ? [
            {'title': 'Malformed listing', 'Media': {}},
            {..._teletubbies, 'Media': [
              for (final offset in [-3600, 0, 7200])
                {'channelIdentifier': '4', 'beginsAt': now + offset - 60,
                 'endsAt': now + offset + 60},
            ]},
          ] : [
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
      '/' => {
        'MediaProvider': {
          'Feature': [
            {
              'type': 'grid',
              'GridChannelFilter': [
                {'genreRatingKey': 7.0, 'title': ' News '},
                {'genreRatingKey': '8', 'title': 'Movies'},
                {'genreRatingKey': 'blank', 'title': '   '},
              ],
              'PromotedGridChannelFilter': [
                {'key': '/lineups/plex/channels/featured', 'title': 'Featured'},
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
      '/hubs/sections/home/whatsOnNow' => {
        'MediaContainer': {
          'Hub': [
            {
              'Metadata': [
                {
                  'type': 'episode',
                  'title': 'Episode 2',
                  'grandparentTitle': 'Free TV show',
                  'Media': [
                    {'beginsAt': now - 60, 'endsAt': now + 3600,
                     'channelIdentifier': 'abc-66635fc0'},
                  ],
                },
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
        'channel-plex-news-extra',
      ]);
      expect(channels.first, containsPair('ChannelNumber', '4'));
      expect(channels.first['Type'], 'TvChannel');
      expect(channels.first['PlexFavoriteSource'],
          'server://pms-machine-1/tv.plex.providers.epg.xmltv:2');
      expect(channels.first['PlexFavoriteId'], '4');
      expect(channels.last.containsKey('PlexFavoriteSource'), isFalse);
      expect(channels.last.containsKey('ChannelNumber'), isFalse);
      expect(result['TotalRecordCount'], 3);
    },
  );

  test('a failed DVR preserves healthy DVR channels and programs', () async {
    final (dio, server) = _server(secondDvr: true);
    var badGridRequests = 0;
    server.failWhen = (options) {
      final failed = options.uri.path.startsWith('/tv.plex.providers.epg.xmltv:3/');
      if (failed && options.uri.path.endsWith('/grid')) badGridRequests++;
      return failed;
    };

    final api = PlexLiveTvApi(dio);
    final lineup = await api.getChannelGroups();
    expect(lineup.groupsByChannelId['channel-2-4'], {'source:dvr'});
    expect(lineup.sources.where((s) => s.groupId == 'source:dvr'), hasLength(1));

    final start = DateTime.utc(2026, 10, 22);
    final end = DateTime.utc(2026, 10, 23);
    final partial = await api.getGuide(
      startDate: start,
      endDate: end,
      channelIds: ['channel-2-4', 'channel-3-9'],
    );
    expect(partial['FailedChannelIds'], ['channel-3-9']);
    expect(
      (partial['Items'] as List).map((p) => p['ChannelId']).toSet(),
      {'channel-2-4'},
    );

    final previousRequests = badGridRequests;
    final healthy = await api.getGuide(
      startDate: start,
      endDate: end,
      channelIds: ['channel-2-4'],
    );
    expect(healthy.containsKey('FailedChannelIds'), isFalse);
    expect(badGridRequests, previousRequests);
  });

  test('DVR discovery preserves sources until Plex confirms an empty list', () async {
    final (dio, server) = _server();
    final api = PlexLiveTvApi(dio);
    final healthy = await api.getChannelGroups();
    expect(healthy.sources, isNotEmpty);

    for (final incomplete in <Map<String, dynamic>>[
      {}, {'MediaContainer': {'size': 1}},
      {'MediaContainer': {'size': 1, 'Dvr': [{}]}},
      {'MediaContainer': {'Dvr': [{'epgIdentifier': 'tuner'}]}},
      {'MediaContainer': {'Dvr': [{'key': '2', 'epgIdentifier': ' '}]}},
    ]) {
      server.discoveryReply = incomplete;
      final partial = await api.getChannelGroups();
      expect(partial.partial, isTrue);
      expect(partial.sources, healthy.sources);
      expect(partial.channels, healthy.channels);
      expect(partial.unresolvedChannelIds, {'channel-2-4'});
    }

    server.discoveryReply = {'MediaContainer': {'Dvr': [
      {}, {'key': 2, 'epgIdentifier': 'tv.plex.providers.epg.xmltv:2'},
    ]}};
    final cold = await PlexLiveTvApi(dio).getChannelGroups();
    expect(cold.partial, isTrue);
    expect(cold.channels, healthy.channels);

    server.discoveryReply = {'MediaContainer': <String, dynamic>{}};
    final empty = await api.getChannelGroups();
    expect(empty.partial, isFalse);
    expect(empty.sources, isEmpty);
  });

  test('ordinary channel reads recheck an ambiguous DVR removal only once', () async {
    final (dio, server) = _server();
    final api = PlexLiveTvApi(dio);
    int discoveries() => server.requests.where((r) => r.uri.path == '/livetv/dvrs').length;
    Future<List> channelIds() async =>
        [for (final row in (await api.getChannels())['Items'] as List) row['Id']];

    for (final empty in <Map<String, dynamic>>[{}, {'size': 0}, {'Dvr': []}]) {
      server.discoveryReply = null;
      expect((await api.getChannelGroups()).groupsByChannelId, contains('channel-2-4'));
      server.discoveryReply = {'MediaContainer': empty};
      expect((await api.getChannelGroups()).sources, isEmpty);
      final before = discoveries();
      server.discoveryReply = null;
      final ids = await channelIds();
      expect(ids.contains('channel-2-4'), empty.isEmpty);
      await channelIds();
      expect(discoveries() - before, empty.isEmpty ? 1 : 0);
    }

    await api.getChannelGroups();
    server.discoveryReply = {'MediaContainer': <String, dynamic>{}};
    await api.getChannelGroups();
    final before = discoveries();
    expect(await channelIds(), isNot(contains('channel-2-4')));
    expect(await channelIds(), isNot(contains('channel-2-4')));
    expect(discoveries() - before, 1);
  });

  test('incomplete discovery marks only unresolved tuner schedules for retry', () async {
    final (dio, server) = _server(secondDvr: true);
    final api = PlexLiveTvApi(dio);
    const missing = 'channel-2-4', empty = 'channel-3-7', free = 'channel-plex-abc-66635fc0';
    Future<Map> guide([List<String>? ids]) => api.getGuide(
      startDate: DateTime.utc(2026, 10, 22), endDate: DateTime.utc(2026, 10, 23), channelIds: ids,
    );
    await api.getChannelGroups();
    server.discoveryReply = {'MediaContainer': {'Dvr': [
      {'key': '2'}, {'key': '3', 'epgIdentifier': 'tv.plex.providers.epg.xmltv:3'},
    ]}};
    expect((await api.getChannelGroups()).unresolvedChannelIds, {missing});
    server.discoveryReply = {'MediaContainer': {'size': 2, 'Dvr': [
      {'key': '3', 'epgIdentifier': 'tv.plex.providers.epg.xmltv:3'},
    ]}};
    final shortened = await api.getChannelGroups();
    expect(shortened.partial, isTrue);
    expect(shortened.unresolvedChannelIds, {missing});
    expect(shortened.groupsByChannelId, contains(missing));
    final mixed = await guide([missing, empty, free]);
    expect(mixed['FailedChannelIds'], [missing]);
    expect((mixed['Items'] as List).map((row) => row['ChannelId']).toSet(), {free});
    expect((await guide())['FailedChannelIds'], [missing]);
    expect((await guide([empty])).containsKey('FailedChannelIds'), isFalse);
    server.discoveryReply = null;
    final recovered = await guide([missing]);
    expect(recovered.containsKey('FailedChannelIds'), isFalse);
    expect((recovered['Items'] as List).first['ChannelId'], missing);
  });

  test('a malformed tuner reports its channels for retry and preserves Free TV', () async {
    final (dio, server) = _server();
    final api = PlexLiveTvApi(dio);
    const tuner = 'channel-2-4', free = 'channel-plex-abc-66635fc0';
    Future<Map<String, dynamic>> guide(List<String> ids) => api.getGuide(
      startDate: DateTime.utc(2026, 10, 22), endDate: DateTime.utc(2026, 10, 23), channelIds: ids,
    );
    server.tunerReply = {'MediaContainer': {'Metadata': [{'Media': 'invalid'}]}};
    final mixed = await guide([tuner, free]);
    expect(mixed['FailedChannelIds'], [tuner]);
    expect((mixed['Items'] as List).map((p) => p['ChannelId']).toSet(), {free});
    expect((await guide([tuner]))['FailedChannelIds'], [tuner]);
    server.tunerReply = null;
    final recovered = await guide([tuner]);
    expect(recovered.containsKey('FailedChannelIds'), isFalse);
    expect((recovered['Items'] as List).first['ChannelId'], tuner);
  });

  test('a missing tuner envelope is retryable and a valid empty one is complete', () async {
    final (dio, server) = _server();
    final api = PlexLiveTvApi(dio);
    final healthy = await api.getChannelGroups();
    Future<Map<String, dynamic>> guide() => api.getGuide(
      startDate: DateTime.utc(2026, 10, 22), endDate: DateTime.utc(2026, 10, 23),
      channelIds: ['channel-2-4', 'channel-plex-abc-66635fc0'],
    );

    server.tunerReply = {};
    final partial = await api.getChannelGroups();
    expect(partial.partial, isTrue);
    expect(partial.sources, healthy.sources);
    expect((await guide())['FailedChannelIds'], ['channel-2-4']);

    for (final invalid in [
      {'Channel': [null]},
      {'Channel': [{'id': '5'}, {'id': ' '}]},
      {'size': 1},
    ]) {
      server.tunerReply = {'MediaContainer': invalid};
      final malformed = await api.getChannelGroups();
      expect(malformed.partial, isTrue);
      expect(malformed.channels, healthy.channels);
      expect(malformed.unresolvedChannelIds, {'channel-2-4'});
    }
    server.failWhen = (r) => r.uri.path.endsWith('/lineups/dvr/channels');
    server.failureStatus = () => 503;
    expect((await api.getChannelGroups()).channels, healthy.channels);
    server.failWhen = null;

    server.tunerReply = {'MediaContainer': {'size': '2', 'Channel': [{'id': '5'}]}};
    final shortened = await api.getChannelGroups();
    expect(shortened.partial, isTrue);
    expect(shortened.unresolvedChannelIds, {'channel-2-4'});
    expect(shortened.groupsByChannelId.keys, containsAll(['channel-2-4', 'channel-2-5']));
    final cold = await PlexLiveTvApi(dio).getChannelGroups();
    expect(cold.partial, isTrue);
    expect(cold.groupsByChannelId, contains('channel-2-5'));

    server.tunerReply = {'MediaContainer': {'size': 0, 'Channel': []}};
    final empty = await api.getChannelGroups();
    expect(empty.partial, isFalse);
    expect(empty.sources, isEmpty);
    expect((await guide()).containsKey('FailedChannelIds'), isFalse);
  });

  test('a forbidden tuner grid preserves other grids, but 401 stays fatal', () async {
    final (dio, server) = _server(secondDvr: true);
    final api = PlexLiveTvApi(dio);
    server.failWhen = (r) => r.uri.path == '/tv.plex.providers.epg.xmltv:3/grid';
    server.failureStatus = () => 403;
    const denied = 'channel-3-9';
    const free = 'channel-plex-abc-66635fc0';
    Future<Map<String, dynamic>> guide(List<String> ids) => api.getGuide(
      startDate: DateTime.utc(2026, 10, 22),
      endDate: DateTime.utc(2026, 10, 23),
      channelIds: ids,
    );
    for (final healthy in ['channel-2-4', free]) {
      final result = await guide([healthy, denied]);
      expect(result['FailedChannelIds'], [denied]);
      expect((result['Items'] as List).map((p) => p['ChannelId']), contains(healthy));
    }
    final retry = await guide([denied]);
    expect(retry['Items'], isEmpty);
    expect(retry['FailedChannelIds'], [denied]);
    await expectLater(api.getProgram('airing-3-1792699380-9'), throwsA(isA<DioException>()
        .having((e) => e.response?.statusCode, 'status', 403)));
    server.failureStatus = () => 401;
    await expectLater(guide([free, denied]), throwsA(isA<DioException>()
        .having((e) => e.response?.statusCode, 'status', 401)));

    server.failWhen = (r) {
      final path = r.uri.path;
      server.failureStatus = () => path == '/grid' ? 503 : 403;
      return path == '/grid' || path == '/tv.plex.providers.epg.xmltv:3/grid';
    };
    final mixed = await PlexLiveTvApi(dio).getGuide(
      startDate: DateTime.utc(2026, 10, 22), endDate: DateTime.utc(2026, 10, 23),
      channelIds: [denied, free],
    );
    expect(mixed['FailedChannelIds'], unorderedEquals([denied, free]));
  });

  test('a forbidden Free TV grid leaves other guide listings available', () async {
    final (dio, server) = _server();
    final api = PlexLiveTvApi(dio);
    const denied = 'channel-plex-abc-66635fc0';
    Future<Map<String, dynamic>> guide(List<String> ids) => api.getGuide(
      startDate: DateTime.utc(2026, 10, 22), endDate: DateTime.utc(2026, 10, 23),
      channelIds: ids,
    );
    server.failWhen = (r) =>
        r.uri.path == '/grid' && r.queryParameters['channelGridKey'] == 'provider-42';
    server.failureStatus = () => 403;
    for (final healthy in ['channel-2-4', 'channel-plex-news-extra']) {
      final result = await guide([healthy, denied]);
      expect(result['FailedChannelIds'], [denied]);
      expect((result['Items'] as List).map((row) => row['ChannelId']), contains(healthy));
    }
    expect((await guide([denied]))['FailedChannelIds'], [denied]);
    await expectLater(api.getProgram('airing-plex-1792699200-abc-66635fc0'),
        throwsA(isA<DioException>().having((e) => e.response?.statusCode, 'status', 403)));
    server.failureStatus = () => 401;
    await expectLater(guide([denied, 'channel-2-4']),
        throwsA(isA<DioException>().having((e) => e.response?.statusCode, 'status', 401)));
    server.failWhen = null;
    final recovered = await guide([denied]);
    expect(recovered.containsKey('FailedChannelIds'), isFalse);
    expect((recovered['Items'] as List).single['ChannelId'], denied);
  });

  test('a forbidden Free TV catalog preserves DVR listings in a mixed guide', () async {
    final (dio, server) = _server();
    final api = PlexLiveTvApi(dio);
    const dvr = 'channel-2-4';
    const free = ['channel-plex-abc-66635fc0', 'channel-plex-news-extra'];
    Future<Map<String, dynamic>> guide(List<String> ids) => api.getGuide(
      startDate: DateTime.utc(2026, 10, 22), endDate: DateTime.utc(2026, 10, 23),
      channelIds: ids,
    );
    server.failWhen = (r) => r.uri.path == '/lineups/plex/channels';
    server.failureStatus = () => 403;
    final partial = await guide([dvr, ...free]);
    expect((partial['Items'] as List).map((row) => row['ChannelId']).toSet(), {dvr});
    expect(partial['FailedChannelIds'], unorderedEquals(free));
    expect(server.requests.where((r) => r.uri.path == '/grid'), isEmpty);
    await expectLater(guide(free),
        throwsA(isA<DioException>().having((e) => e.response?.statusCode, 'status', 403)));
    server.failWhen = (r) {
      final catalog = r.uri.path == '/lineups/plex/channels';
      server.failureStatus = () => catalog ? 403 : 503;
      return catalog || r.uri.path.endsWith('/grid');
    };
    await expectLater(guide([dvr, ...free]),
        throwsA(isA<DioException>().having((e) => e.response?.statusCode, 'status', 403)));
    server.failWhen = (r) => r.uri.path == '/lineups/plex/channels';
    server.failureStatus = () => 401;
    await expectLater(guide([dvr, ...free]),
        throwsA(isA<DioException>().having((e) => e.response?.statusCode, 'status', 401)));
    server.failWhen = null;
    final recovered = await guide(free);
    expect(recovered.containsKey('FailedChannelIds'), isFalse);
    expect((recovered['Items'] as List).map((row) => row['ChannelId']).toSet(), free.toSet());
  });

  test('one inaccessible tuner does not discard the other DVR channels', () async {
    final (dio, server) = _server(secondDvr: true);
    server.failWhen = (request) =>
        request.uri.path == '/tv.plex.providers.epg.xmltv:3/lineups/dvr/channels';
    server.failureStatus = () => 403;

    final lineup = await PlexLiveTvApi(dio).getChannelGroups();
    expect(lineup.groupsByChannelId['channel-2-4'], {'source:dvr'});
    expect(lineup.channels?.map((row) => row['Id']), contains('channel-2-4'));
    expect(lineup.partial, isFalse);
  });

  test('an expired Plex session does not become an empty DVR lineup', () async {
    final (dio, server) = _server();
    server.failWhen = (request) => request.uri.path == '/livetv/dvrs';
    server.failureStatus = () => 401;

    await expectLater(
      PlexLiveTvApi(dio).getChannelGroups(),
      throwsA(isA<DioException>().having((e) => e.response?.statusCode, 'status', 401)),
    );
  });

  test('Plex matches Moonbase genre names and loads Featured on demand', () async {
    final (dio, server) = _server();
    final api = PlexLiveTvApi(dio);
    final lineup = await api.getChannelGroups();
    expect(lineup.groupsByChannelId, {
      'channel-2-4': {'source:dvr'},
      'channel-plex-abc-66635fc0': {'source:plexFreeTv', 'Movies', 'News'},
      'channel-plex-news-extra': {'source:plexFreeTv'},
    });
    final promoted = lineup.promoted!;
    expect((await api.getChannelGroups()).promoted, same(promoted));
    final cloud = server.requests.where(
      (r) => r.uri.host == 'epg.provider.plex.tv',
    );
    expect(cloud.map((r) => r.uri.path), [
      '/lineups/plex/channels', '/', '/lineups/plex/channels', '/',
    ]);
    await promoted.refresh(DateTime.now);
    expect(promoted.channelIds, {'channel-plex-abc-66635fc0'});
    expect(promoted.channelIds, isNot(contains('channel-plex-news-extra')));
    expect(server.requests.last.uri.path, '/lineups/plex/channels/featured');
    expect(server.requests.last.headers['X-Plex-Provider-Version'], '7.2');
  });



  test('full lineup refresh picks up new Free TV channels and genres', () async {
    var name = 'Sports';
    final server = _FakeServer((request) => switch (request.uri.path) {
      '/lineups/plex/channels' => {'MediaContainer': {'Channel': [
        {'id': name, 'title': name, 'genreRatingKeys': ['genre']},
      ]}},
      '/' => {'MediaProvider': {'Feature': [
        {'type': 'grid', 'GridChannelFilter': [
          {'genreRatingKey': 'genre', 'title': name},
        ]},
      ]}},
      _ => throw StateError('Unexpected request ${request.uri.path}'),
    });
    final api = PlexLiveTvApi(Dio()..interceptors.add(server), cloudOnly: true);
    await api.getChannelGroups();
    name = 'News';
    final (lineup, concurrent) = await (api.getChannelGroups(), api.getChannelGroups()).wait;
    expect(concurrent, same(lineup));
    expect(lineup.groupsByChannelId, {'channel-plex-News': {'News'}});
    expect((await api.getChannels())['Items'], lineup.channels);
    expect(server.requests, hasLength(4));

    server.failWhen = (r) => r.uri.path == '/lineups/plex/channels';
    server.failureStatus = () => 503;
    final stale = await api.getChannelGroups();
    expect(stale.channels, lineup.channels);
    expect(stale.partial, isTrue);
    server.failWhen = null;
    name = 'Movies';
    final recovered = (await api.getChannels())['Items'] as List;
    expect(recovered.single['Id'], 'channel-plex-Movies');
  });

  test('an advertised tuner with a 404 stays unresolved until discovery confirms removal', () async {
    final (dio, server) = _server(secondDvr: true);
    final api = PlexLiveTvApi(dio);
    await api.getChannelGroups();
    server.failWhen = (r) => r.uri.path == '/tv.plex.providers.epg.xmltv:3/lineups/dvr/channels';
    server.failureStatus = () => 404;
    final missing = await api.getChannelGroups();
    expect(missing.partial, isTrue);
    expect(missing.unresolvedChannelIds, {'channel-3-7'});
    expect(missing.groupsByChannelId, contains('channel-3-7'));
    server.discoveryReply = {'MediaContainer': {'Dvr': [
      {'key': '2', 'epgIdentifier': 'tv.plex.providers.epg.xmltv:2'},
    ]}};
    final channels = (await api.getChannels())['Items'] as List;
    expect(channels.map((row) => row['Id']), isNot(contains('channel-3-7')));
    expect((await api.getChannelGroups()).partial, isFalse);
  });

  test('a tuner outage retains only its last lineup until access is denied', () async {
    final (dio, server) = _server(secondDvr: true);
    const second = '/tv.plex.providers.epg.xmltv:3/lineups/dvr/channels';
    final api = PlexLiveTvApi(dio);
    final healthy = await api.getChannelGroups();
    server.tunerReply = {'MediaContainer': {'Channel': [{'id': '5', 'title': 'New station'}]}};
    server.failWhen = (r) => r.uri.path == second;
    server.failureStatus = () => 503;
    final outage = await api.getChannelGroups();
    expect(outage.partial, isTrue);
    expect(outage.sources, healthy.sources);
    expect(outage.groupsByChannelId['channel-plex-abc-66635fc0'], contains('source:plexFreeTv'));
    expect(outage.groupsByChannelId.containsKey('channel-2-4'), isFalse);
    expect(outage.groupsByChannelId['channel-2-5'], {'source:dvr'});
    expect(outage.groupsByChannelId['channel-3-7'], {'source:dvr'});
    expect(outage.unresolvedChannelIds, {'channel-3-7'});
    expect(outage.channels?.map((row) => row['Id']), contains('channel-3-7'));
    expect((await api.getChannels())['Items'], outage.channels);

    server.failWhen = null;
    expect((await api.getChannelGroups()).partial, isFalse);
    server.failWhen = (r) => r.uri.path == second;
    server.failureStatus = () => 403;
    expect((await api.getChannelGroups()).groupsByChannelId.containsKey('channel-3-7'), isFalse);
    server.failureStatus = () => 503;
    expect((await api.getChannelGroups()).unresolvedChannelIds, isEmpty);
  });

  test('a Free TV outage preserves the last lineup alongside the DVR', () async {
    final (dio, server) = _server();
    final api = PlexLiveTvApi(dio);
    final healthy = await api.getChannelGroups();
    bool isFreeLineup(RequestOptions r) => r.uri.path == '/lineups/plex/channels';
    server.failWhen = isFreeLineup;
    for (var i = 0; i < 2; i++) {
      final stale = await api.getChannelGroups();
      expect(stale.channels, healthy.channels);
      expect(stale.partial, isTrue);
      expect(stale.unresolvedChannelIds, isNull);
    }
    expect((await api.getChannels())['Items'], healthy.channels);
    server.failWhen = null;
    server.requests.clear();
    await api.getChannels();
    expect(server.requests.where(isFreeLineup), hasLength(1));
    server.failWhen = isFreeLineup;
    server.failureStatus = () => 403;
    final denied = await api.getChannelGroups();
    expect(denied.channels!.length, lessThan(healthy.channels!.length));
  });

  for (final cloudOnly in [true, false]) {
    test('malformed Free TV rows cannot replace the last good lineup (cloudOnly=$cloudOnly)', () async {
      final (_, fixture) = _server();
      List<Object?> rows = [{'id': 'news'}];
      final server = _FakeServer((r) => r.uri.path == '/lineups/plex/channels'
          ? {'MediaContainer': {'size': rows.length, 'Channel': rows}}
          : fixture.answer(r));
      final api = PlexLiveTvApi(Dio()..interceptors.add(server), cloudOnly: cloudOnly);
      final healthy = await api.getChannelGroups();
      expect(healthy.groupsByChannelId, contains('channel-plex-news'));

      for (final malformed in <List<Object?>>[
        [{}], [null], [{'id': 'replacement'}, {'id': ' '}], [{'id': []}],
      ]) {
        rows = malformed;
        final partial = await api.getChannelGroups();
        expect(partial.partial, isTrue);
        expect(partial.channels, healthy.channels);
        expect((await api.getChannels())['Items'], healthy.channels);
      }

      rows = [{'id': 42}, {'id': 'locked', 'drm': true}];
      final recovered = (await api.getChannels())['Items'] as List;
      final dvrIds = [if (!cloudOnly) 'channel-2-4'];
      expect(recovered.map((c) => c['Id']), unorderedEquals([...dvrIds, 'channel-plex-42']));
      rows = [];
      final empty = await api.getChannelGroups();
      expect(empty.partial, isFalse);
      expect(empty.groupsByChannelId.keys, unorderedEquals(dvrIds));
    });

    test('Free TV retains its stations until Plex confirms zero (cloudOnly=$cloudOnly)', () async {
      final rows = [
        {'id': 'news', 'title': 'News'}, {'id': 'film', 'title': 'Film'},
        {'id': 'locked', 'drm': true},
      ];
      var size = rows.length;
      final server = _FakeServer((r) => {'MediaContainer': r.uri.path == '/lineups/plex/channels'
          ? {'Channel': rows, 'size': size} : <String, dynamic>{}});
      final api = PlexLiveTvApi(Dio()..interceptors.add(server), cloudOnly: cloudOnly);
      final healthy = await api.getChannelGroups();
      expect(healthy.channels, hasLength(2));
      for (final count in [1, 0]) {
        rows.length = count;
        final incomplete = await api.getChannelGroups();
        expect(incomplete.partial, isTrue);
        expect(incomplete.channels, healthy.channels);
      }
      size = 0;
      expect((await api.getChannels())['Items'], isEmpty);
      expect((await api.getChannelGroups()).partial, isFalse);
    });
  }

  test('Plex retains unresolved genre groups when metadata fails and recovers', () async {
    final (dio, server) = _server();
    var metadataUnavailable = true;
    server.failWhen = (request) => metadataUnavailable &&
        request.uri.host == 'epg.provider.plex.tv' &&
        request.uri.path == '/';

    final api = PlexLiveTvApi(dio);
    final incomplete = await api.getChannelGroups();
    expect(incomplete.partial, isTrue);
    expect(incomplete.unresolvedChannelIds, {
      'channel-plex-abc-66635fc0',
      'channel-plex-news-extra',
    });
    expect(incomplete.groupsByChannelId['channel-2-4'], {'source:dvr'});
    expect(incomplete.groupsByChannelId['channel-plex-abc-66635fc0'],
        {'source:plexFreeTv'});
    expect(incomplete.channels, hasLength(3));

    metadataUnavailable = false;
    final recovered = await api.getChannelGroups();
    expect(recovered.partial, isFalse);
    expect(recovered.unresolvedChannelIds, isNull);
    expect(recovered.groupsByChannelId['channel-plex-abc-66635fc0'],
        {'source:plexFreeTv', 'Movies', 'News'});
    expect(server.requests.where((r) => r.uri.path == '/'), hasLength(1));
  });

  test('cloud-only lineup failures propagate while Plex DVRs remain usable', () async {
    final (dio, server) = _server();
    server.failWhen = (request) => request.uri.path == '/lineups/plex/channels';

    final cloud = PlexLiveTvApi(dio, cloudOnly: true);
    final cloudFailure = isA<DioException>().having(
      (error) => error.type,
      'Free TV connection failure',
      DioExceptionType.connectionError,
    );
    await expectLater(cloud.getChannelGroups(), throwsA(cloudFailure));
    await expectLater(cloud.getChannels(), throwsA(cloudFailure));
    expect(server.requests, isEmpty);

    final serverWithDvr = PlexLiveTvApi(dio);
    final lineup = await serverWithDvr.getChannelGroups();
    expect(lineup.channels?.map((channel) => channel['Id']), ['channel-2-4']);
    expect(lineup.partial, isTrue);
    expect(lineup.unresolvedChannelIds, isNull);
    expect(lineup.groupsByChannelId, {
      'channel-2-4': {'source:dvr'},
    });
    expect(lineup.sources.map((source) => source.groupId), ['source:dvr']);
  });





  test('Plex On Now uses a cached hub after the DVR lineup', () async {
    const hubPath = '/hubs/sections/home/whatsOnNow';
    final (dio, server) = _server(liveDvr: true);
    final cloud = PlexLiveTvApi(dio, cloudOnly: true);
    final free = (await cloud.getRecommendedPrograms(limit: 15))['Items'] as List;
    expect(free, hasLength(1));
    expect(free.single['ChannelId'], 'channel-plex-abc-66635fc0');
    expect(free.single['Name'], 'Free TV show');
    await cloud.getRecommendedPrograms(limit: 15);
    expect(server.requests.where((r) => r.uri.path == hubPath), hasLength(1));
    expect(server.requests.any((r) => r.uri.path == '/grid'), isFalse);

    final dvr = PlexLiveTvApi(dio);
    expect((await dvr.getRecommendedPrograms(limit: 1))['Items'], hasLength(1));
    expect(server.requests.where((r) => r.uri.path == hubPath), hasLength(1));
    // Past and future repeats of the DVR show must leave room for Free TV.
    final combined = (await dvr.getRecommendedPrograms(limit: 2))['Items'] as List;
    expect(combined.map((item) => item['ChannelId']), [
      'channel-2-4', 'channel-plex-abc-66635fc0',
    ]);
  });

  test('On Now prefers exact channel references and skips ambiguous suffixes', () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    var refreshedLineup = false;
    final references = {
      'Shared grid only': {'channelGridKey': 'shared-grid'},
      'East news': {'channelGridKey': 'shared-grid'},
      'Exact ID': {'channelIdentifier': 'east'},
      'Retired station': {'channelId': {'id': 'retired-west', 'gridKey': 'west-grid'}},
      'Conflicting short ID': {'channelIdentifier': 'south', 'channelGridKey': 'west-grid'},
      'West broadcast': {'channelGridKey': 'west-grid'},
      'Nested grid key': {'channelId': {'id': '', 'gridKey': 'north-grid'}},
      'Unique suffix': {'channelId': 'south'},
      'Ambiguous suffix': {'channelId': 'shared'},
    };
    final server = _FakeServer((options) => {
      'MediaContainer': options.uri.path == '/lineups/plex/channels'
          ? {'Channel': [
              for (final id in ['city-east', 'east', 'city-south', 'a-shared', 'b-shared'])
                {'id': id, 'title': id},
              {'id': 'west-news', 'gridKey': 'shared-grid'},
              {'id': 'east-news', 'gridKey': refreshedLineup ? 'east-grid' : 'shared-grid'},
              {'id': 'city-west', 'gridKey': refreshedLineup ? 'north-grid' : 'west-grid'},
              {'id': 'city-north', 'gridKey': refreshedLineup ? 'west-grid' : 'north-grid'},
            ]}
          : {'Metadata': [
              for (final entry in references.entries)
                {'title': entry.key, 'type': 'movie',
                 if (entry.key == 'East news') 'channelIdentifier': 'east-news',
                 'Media': [
                  {...entry.value, 'beginsAt': now - 60, 'endsAt': now + 60},
                ]},
            ]},
    });
    final api = PlexLiveTvApi(Dio()..interceptors.add(server), cloudOnly: true);
    final items = (await api.getRecommendedPrograms(limit: 10))['Items'] as List;
    expect({for (final item in items) item['Name']: item['ChannelId']}, {
      'East news': 'channel-plex-east-news',
      'Exact ID': 'channel-plex-east',
      'West broadcast': 'channel-plex-city-west',
      'Nested grid key': 'channel-plex-city-north',
      'Unique suffix': 'channel-plex-city-south',
    });

    await api.getChannelGroups();
    await api.getRecommendedPrograms();
    expect(server.requests.where((r) => r.uri.path.endsWith('/whatsOnNow')), hasLength(1));

    refreshedLineup = true;
    references['North broadcast'] = references.remove('West broadcast')!;
    await api.getChannelGroups();
    final refreshed = (await api.getRecommendedPrograms())['Items'] as List;
    expect({for (final item in refreshed) item['Name']: item['ChannelId']}, {
      'Shared grid only': 'channel-plex-west-news',
      'East news': 'channel-plex-east-news',
      'Exact ID': 'channel-plex-east',
      'North broadcast': 'channel-plex-city-north',
      'Nested grid key': 'channel-plex-city-west',
      'Unique suffix': 'channel-plex-city-south',
    });
    expect(server.requests.where((r) => r.uri.path.endsWith('/whatsOnNow')), hasLength(2));
    final pms = PlexLiveTvApi(Dio()..interceptors.add(server));
    await pms.getChannels();
    server.failWhen = (r) => r.uri.path == '/lineups/plex/channels';
    server.failureStatus = () => 503;
    await pms.getChannelGroups();
    final duringOutage = (await pms.getRecommendedPrograms())['Items'] as List;
    expect(duringOutage.map((row) => row['Name']), ['East news', 'Exact ID']);
  });

  test('a fresh Home hub rechecks aliases and uses exact station IDs directly', () async {
    var owner = 'west';
    final reference = <String, dynamic>{'channelIdentifier': 'west'};
    final server = _FakeServer((r) {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if (r.uri.path == '/lineups/plex/channels') {
        return {'MediaContainer': {'Channel': [for (final id in ['west', 'north'])
            {'id': id, if (id == owner) 'gridKey': 'moving-key'}]}};
      }
      final title = '$owner broadcast';
      if (reference.containsKey('channelGridKey')) owner = 'north';
      return {'MediaContainer': {'Metadata': [{'title': title, 'Media': [
              {...reference, 'beginsAt': now - 60, 'endsAt': now + 2},
          ]}]}};
    });
    final api = PlexLiveTvApi(Dio()..interceptors.add(server), cloudOnly: true);
    await api.getChannels();
    Future<Map> onNow() async =>
        ((await api.getRecommendedPrograms())['Items'] as List).single as Map;
    final first = await onNow();
    expect(first['ChannelId'], 'channel-plex-west');
    expect(server.requests.where((r) => r.uri.path == '/lineups/plex/channels'), hasLength(1));
    reference..clear()..['channelGridKey'] = 'moving-key';
    await Future<void>.delayed(DateTime.parse(first['EndDate']).difference(DateTime.now()));
    final refreshed = await Future.wait([onNow(), onNow()]);
    expect(refreshed.map((row) => row['ChannelId']), everyElement('channel-plex-north'));
    expect(refreshed.map((row) => row['Name']), everyElement('north broadcast'));
    expect(server.requests.where((r) => r.uri.path.endsWith('/whatsOnNow')), hasLength(3));
  });

  test('an unavailable Plex hub does not discard DVR On Now', () async {
    final (dio, server) = _server(liveDvr: true);
    server.failWhen = (request) =>
        request.uri.path == '/hubs/sections/home/whatsOnNow';
    server.failureStatus = () => 404;
    // Request room for the Free TV hub so its failure is actually exercised.
    final programs = (await PlexLiveTvApi(dio)
        .getRecommendedPrograms(limit: 4))['Items'] as List;
    expect(programs.map((item) => item['ChannelId']), [
      'channel-2-4',
    ]);
  });

  test('Plex On Now falls back for an unavailable tuner and preserves authorization errors', () async {
    final (dio, server) = _server();
    int? status;
    server.failWhen = (request) =>
        request.uri.path == '/tv.plex.providers.epg.xmltv:2/grid';
    server.failureStatus = () => status;
    for (final failure in [null, 403, 503]) {
      status = failure;
      final programs = (await PlexLiveTvApi(dio)
          .getRecommendedPrograms(limit: 3))['Items'] as List;
      expect(programs.map((item) => item['ChannelId']), ['channel-plex-abc-66635fc0']);
    }

    for (final (path, denied) in [
      ('/tv.plex.providers.epg.xmltv:2/grid', 401), ('/livetv/dvrs', 403),
    ]) {
      status = denied;
      server.failWhen = (r) => r.uri.path == path;
      await expectLater(
        PlexLiveTvApi(dio).getRecommendedPrograms(limit: 3),
        throwsA(isA<DioException>().having((e) => e.response?.statusCode, 'status', denied)),
      );
    }
  });

  test('On Now preserves the tuner outage when Free TV has no programmes', () async {
    final (_, fixture) = _server(liveDvr: true);
    final server = _FakeServer((r) => r.uri.path == '/lineups/plex/channels'
        ? {'MediaContainer': {'size': 0, 'Channel': []}} : fixture.answer(r));
    final api = PlexLiveTvApi(Dio()..interceptors.add(server));
    Future<List> onNow() async => (await api.getRecommendedPrograms(limit: 1))['Items'] as List;
    expect(await onNow(), hasLength(1));
    server.failWhen = (r) => r.uri.path.endsWith(':2/grid');
    server.failureStatus = () => 503;
    await expectLater(onNow(), throwsA(isA<DioException>()
        .having((e) => e.response?.statusCode, 'status', 503)
        .having((e) => e.requestOptions.uri.path, 'path', endsWith(':2/grid'))));
    server.failWhen = null;
    expect(await onNow(), hasLength(1));
    server.tunerReply = {'MediaContainer': {'Metadata': []}};
    expect(await onNow(), isEmpty);
  });

  test('On Now distinguishes malformed DVR data from a confirmed empty schedule', () async {
    final (_, fixture) = _server(liveDvr: true);
    final server = _FakeServer((r) => r.uri.path.endsWith('/whatsOnNow')
        ? {'MediaContainer': {'Metadata': []}} : fixture.answer(r));
    final api = PlexLiveTvApi(Dio()..interceptors.add(server));
    Future<List> onNow() async => (await api.getRecommendedPrograms())['Items'] as List;

    expect(await onNow(), hasLength(1));
    server.tunerReply = {'MediaContainer': {'Metadata': {}}};
    await expectLater(onNow(), throwsA(isA<TypeError>()));
    server.tunerReply = {};
    await expectLater(onNow(), throwsFormatException);
    server.tunerReply = {'MediaContainer': {'Metadata': []}};
    expect(await onNow(), isEmpty);
  });

  test('Plex On Now uses Free TV when the DVR grid metadata is malformed', () async {
    final (dio, _) = _server(malformedDvrGrid: true);
    final programs = (await PlexLiveTvApi(dio)
        .getRecommendedPrograms(limit: 3))['Items'] as List;
    expect(programs.map((item) => item['ChannelId']),
        ['channel-plex-abc-66635fc0']);
  });

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

  test('DVR guide excludes showings ending at the start or starting at the end', () async {
    final (dio, _) = _server();
    final result = await PlexLiveTvApi(dio).getGuide(
      startDate: DateTime.utc(2026, 10, 22, 21, 4),
      endDate: DateTime.utc(2026, 10, 22, 23),
      channelIds: ['channel-2-4', 'channel-2-9'],
    );
    expect((result['Items'] as List).map((p) => p['Name']), ['SuperKitties']);
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

  test('recording a channel does not query unrelated inaccessible DVRs', () async {
    final (dio, server) = _server(secondDvr: true);
    server.failWhen = (request) =>
        request.uri.path == '/tv.plex.providers.epg.xmltv:3/grid';
    server.failureStatus = () => 403;

    await PlexLiveTvApi(dio).createTimer('airing-2-1792699380-4');
    expect(server.requests.where((request) => request.uri.path ==
        '/tv.plex.providers.epg.xmltv:3/grid'), isEmpty);
    expect(server.requests.where((request) => request.method == 'POST'), hasLength(1));
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

  test('a missing Free TV program list is retryable until Plex confirms zero', () async {
    final grid = <String, dynamic>{'size': 1};
    final server = _FakeServer((r) => r.uri.path == '/grid'
        ? {'MediaContainer': grid}
        : {'MediaContainer': {'Channel': [{'id': 'test', 'gridKey': 'test'}]}});
    final api = PlexLiveTvApi(Dio()..interceptors.add(server), cloudOnly: true);
    Future<Map<String, dynamic>> guide() => api.getGuide(
      startDate: DateTime.utc(2026, 10, 22, 20), endDate: DateTime.utc(2026, 10, 22, 22),
      channelIds: ['channel-plex-test'],
    );
    await expectLater(guide(), throwsFormatException);
    grid.clear();
    await expectLater(guide(), throwsFormatException);
    grid['size'] = 0;
    expect((await guide())['Items'], isEmpty);
    expect((await guide())['Items'], isEmpty);
    expect(server.requests.where((r) => r.uri.path == '/grid'), hasLength(3));
  });

  test('Free TV guide and program details share the published grid key', () async {
    final (dio, server) = _server();
    final api = PlexLiveTvApi(dio, cloudOnly: true);
    final result = await api.getGuide(
      startDate: DateTime.utc(2026, 10, 22, 20).toLocal(),
      endDate: DateTime.utc(2026, 10, 22, 22).toLocal(),
      channelIds: ['channel-plex-abc-66635fc0'],
    );

    final programs = (result['Items'] as List).cast<Map>();
    expect(programs.map((p) => p['Id']), [
      'airing-plex-1792699200-abc-66635fc0',
    ]);
    expect((await api.getProgram(programs.single['Id']))['Name'], 'Law Abiding Citizen');
    expect(server.requests.map((r) => r.uri.path), ['/lineups/plex/channels', '/grid']);
    expect(server.requests.last.queryParameters, {
      'date': '2026-10-22', 'channelGridKey': 'provider-42',
    });

    server.failWhen = (r) => r.uri.path == '/lineups/plex/channels';
    server.failureStatus = () => 503;
    expect((await api.getChannelGroups()).partial, isTrue);
    expect((await api.getProgram(programs.single['Id']))['Name'], 'Law Abiding Citizen');
    expect(server.requests.where((r) => r.uri.path == '/grid'), hasLength(1));

    final offline = PlexLiveTvApi(dio);
    await offline.getProgram('airing-plex-1792699200-abc-66635fc0');
    expect(server.requests.last.queryParameters['channelGridKey'], '66635fc0');

    server.failureStatus = () => 403;
    await expectLater(api.getChannelGroups(), throwsA(isA<DioException>()));
    await expectLater(api.getProgram(programs.single['Id']), throwsA(isA<DioException>()));
  });

  test('a reassigned guide key loads a separate schedule for each station', () async {
    var station = 'west';
    final server = _FakeServer((r) => {'MediaContainer': switch (r.uri.path) {
      '/lineups/plex/channels' => {'Channel': [{'id': station, 'gridKey': 'shared'}]},
      '/grid' => {'Metadata': [{'title': '$station show', 'Media': [
        {'beginsAt': 1792699200, 'endsAt': 1792706400},
      ]}]},
      _ => <String, dynamic>{},
    }});
    final api = PlexLiveTvApi(Dio()..interceptors.add(server), cloudOnly: true);
    for (station in ['west', 'north']) {
      await api.getChannelGroups();
      for (var read = 0; read < 2; read++) {
        final result = await api.getGuide(startDate: DateTime.utc(2026, 10, 22),
            endDate: DateTime.utc(2026, 10, 23), channelIds: ['channel-plex-$station']);
        final item = (result['Items'] as List).single;
        expect(item['ChannelId'], 'channel-plex-$station');
        expect(item['Name'], '$station show');
      }
    }
    final grids = server.requests.where((r) => r.uri.path == '/grid');
    expect(grids.map((r) => r.queryParameters['channelGridKey']), ['shared', 'shared']);
  });

  test('a later guide batch can expire a cached grid without losing its listings', () async {
    var now = DateTime.utc(2026, 10, 22, 12);
    const stations = ['a', 'b', 'c', 'd'];
    final server = _FakeServer((r) {
      if (r.uri.path == '/lineups/plex/channels') {
        return {'MediaContainer': {'Channel': [for (final id in stations) {'id': id}]}};
      }
      final station = r.queryParameters['channelGridKey'];
      if (station == 'c') now = now.add(const Duration(minutes: 2));
      return {'MediaContainer': {'Metadata': [
        {'title': 'Show $station', 'Media': [{'beginsAt': 1792699200, 'endsAt': 1792706400}]},
      ]}};
    });
    final api = PlexLiveTvApi(
      Dio()..interceptors.add(server), cloudOnly: true, gridCacheNow: () => now,
    );
    Future<Map> guide(List<String> ids) => api.getGuide(
      startDate: DateTime.utc(2026, 10, 22), endDate: DateTime.utc(2026, 10, 23),
      channelIds: [for (final id in ids) 'channel-plex-$id'],
    );
    await guide(['a']);
    now = now.add(const Duration(minutes: 9));
    final result = await guide(stations);
    expect((result['Items'] as List).map((item) => item['Name']), unorderedEquals(
      [for (final id in stations) 'Show $id'],
    ));
    expect(result['FailedChannelIds'], isNull);
    await guide(['a']);
    expect(server.requests.where((r) => r.uri.path == '/grid')
        .map((r) => r.queryParameters['channelGridKey']), ['a', 'b', 'c', 'd', 'a']);
  });

  test('a pending grid cannot publish after its key changes stations', () async {
    final started = Completer<void>(), release = Completer<void>();
    var owner = 'west';
    final server = _FakeServer((r) => {'MediaContainer': switch (r.uri.path) {
      '/lineups/plex/channels' => {'Channel': [for (final id in ['west', 'north'])
          {'id': id, 'gridKey': id == owner ? 'shared' : 'other'}]},
      '/grid' => {'Metadata': [{'title': r.queryParameters['channelGridKey'] == 'shared'
          ? '$owner show' : 'Other show', 'Media': [
        {'beginsAt': 1792699200, 'endsAt': 1792706400},
      ]}]},
      _ => <String, dynamic>{},
    }});
    final dio = Dio()..interceptors.add(InterceptorsWrapper(onRequest: (r, handler) async {
      if (r.uri.path == '/grid' && !started.isCompleted) {
        started.complete();
        await release.future;
      }
      handler.next(r);
    }))..interceptors.add(server);
    final api = PlexLiveTvApi(dio, cloudOnly: true);
    Future<Map> guide() => api.getGuide(startDate: DateTime.utc(2026, 10, 22),
        endDate: DateTime.utc(2026, 10, 23), channelIds: ['channel-plex-west']);
    final pending = guide();
    await started.future;
    owner = 'north';
    await api.getChannelGroups();
    release.complete();
    final stale = await pending;
    expect(stale['Items'], isEmpty);
    expect(stale['FailedChannelIds'], ['channel-plex-west']);
    expect(((await guide())['Items'] as List).single['Name'], 'Other show');
  });

  test('a conflicting grid station during a catalog outage is retryable', () async {
    const channel = 'channel-plex-abc-66635fc0';
    final (_, fixture) = _server();
    final media = <String, dynamic>{'channelIdentifier': 'news-extra',
        'beginsAt': 1792699200, 'endsAt': 1792706400};
    final server = _FakeServer((r) => r.uri.path == '/grid'
        ? {'MediaContainer': {'Metadata': [{'title': 'News', 'Media': [
            media, {'beginsAt': 1792699200},
          ]}]}}
        : fixture.answer(r));
    final api = PlexLiveTvApi(Dio()..interceptors.add(server));
    await api.getChannels();
    server.failWhen = (r) => r.uri.path == '/lineups/plex/channels';
    server.failureStatus = () => 503;
    expect((await api.getChannelGroups()).partial, isTrue);
    Future<Map> guide() => api.getGuide(startDate: DateTime.utc(2026, 10, 22),
        endDate: DateTime.utc(2026, 10, 23), channelIds: [channel]);
    final failed = await guide();
    expect(failed['Items'], isEmpty);
    expect(failed['FailedChannelIds'], [channel]);
    server.failWhen = null;
    media['channelIdentifier'] = {'id': channel};
    final recovered = await guide();
    expect((recovered['Items'] as List).single['ChannelId'], channel);
    expect(recovered.containsKey('FailedChannelIds'), isFalse);
    expect(server.requests.where((r) => r.uri.path == '/grid'), hasLength(2));
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
