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
  final replies = <String, Object? Function(RequestOptions)>{};

  void fail(String path, int? status) {
    failWhen = (r) => r.uri.path == path;
    failureStatus = () => status;
  }

  int reads(String path) => requests.where((r) => r.uri.path == path).length;

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
    handler.resolve(Response(requestOptions: options, data: replies[options.uri.path]?.call(options) ?? discovery ?? reply ?? answer(options)));
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
  String Function()? machineId,
}) {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final server = _FakeServer(
    (options) => switch (options.uri.path) {
      '/identity' => {
        'MediaContainer': {'machineIdentifier': machineId?.call() ?? 'pms-machine-1'},
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
      '/tv.plex.providers.epg.xmltv:3/grid' => {
        'MediaContainer': {'Metadata': []},
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

Map<String, dynamic> _channels(List<Object?> rows, {int? size}) =>
    {'MediaContainer': {'Channel': rows, 'size': ?size}};

Map<String, dynamic> _schedule(String title, List<Map<String, dynamic>> airings) =>
    {'MediaContainer': {'Metadata': [{'title': title, 'Media': airings}]}};

const _airing = {'beginsAt': 1792699200, 'endsAt': 1792706400};

Matcher _httpError(int status) =>
    throwsA(isA<DioException>().having((e) => e.response?.statusCode, 'status', status));

extension on PlexLiveTvApi {
  Future<Map<String, dynamic>> testGuide([List<String>? ids]) => getGuide(
    startDate: DateTime.utc(2026, 10, 22),
    endDate: DateTime.utc(2026, 10, 23),
    channelIds: ids,
  );
}

void main() {
  const free = 'channel-plex-abc-66635fc0';
  const extra = 'channel-plex-news-extra';
  const tuner = 'channel-2-4';
  const other = 'channel-3-9';

  for (final denied in [false, true]) {
    test('browse uses the refreshed Free TV catalog after waiting for its tuner (denied: $denied)', () async {
      final (dio, server) = _server();
      final api = PlexLiveTvApi(dio);
      await api.getChannels();
      final entered = Completer<void>();
      final release = Completer<void>();
      dio.interceptors.insert(0, InterceptorsWrapper(onRequest: (request, handler) async {
        if (request.path.endsWith('/lineups/dvr/channels') && !entered.isCompleted) {
          entered.complete();
          await release.future;
        }
        handler.next(request);
      }));
      final browse = api.getChannels();
      await entered.future;
      if (denied) {
        server.fail('/lineups/plex/channels', 403);
      } else {
        server.replies['/lineups/plex/channels'] = (_) => _channels([{'id': 'replacement'}]);
      }
      final expected = [tuner, if (!denied) 'channel-plex-replacement'];
      expect((await api.getChannelGroups()).channels!.map((row) => row['Id']), expected);
      release.complete();
      expect((await browse)['Items'].map((row) => row['Id']), expected);
    });
  }

  for (final outageFirst in [false, true]) {
    test('group rows and tuner outage status come from the same read (outage first: $outageFirst)', () async {
      final (dio, server) = _server();
      final api = PlexLiveTvApi(dio);
      await api.getChannelGroups();
      final entered = Completer<void>();
      final release = Completer<void>();
      dio.interceptors.insert(0, InterceptorsWrapper(onRequest: (request, handler) async {
        if (request.uri.path == '/') {
          entered.complete();
          await release.future;
        }
        handler.next(request);
      }));
      const path = '/tv.plex.providers.epg.xmltv:2/lineups/dvr/channels';
      if (outageFirst) server.fail(path, 503);
      final guide = api.getChannelGroups();
      await entered.future;
      if (outageFirst) {
        server.failWhen = null;
        server.tunerReply = _channels([{'id': '5'}]);
      } else {
        server.fail(path, 503);
      }
      final latest = (await api.getChannels())['Items'];
      release.complete();
      final published = await guide;
      expect(published.channels, latest);
      expect(published.partial, !outageFirst);
      expect(published.unresolvedChannelIds, outageFirst ? null : {tuner});
    });
  }

  test('an older cloud denial cannot erase the lineup retained by a newer outage', () async {
    const path = '/lineups/plex/channels';
    final (dio, server) = _server();
    final api = PlexLiveTvApi(dio);
    final healthy = await api.getChannelGroups();
    server.fail(path, 503);
    expect((await api.getChannelGroups()).partial, isTrue);
    final entered = Completer<void>(), release = Completer<void>();
    dio.interceptors.insert(0, InterceptorsWrapper(onRequest: (request, handler) async {
      if (request.uri.path == path && !entered.isCompleted) {
        entered.complete();
        await release.future;
        handler.reject(DioException(requestOptions: request,
            response: Response(requestOptions: request, statusCode: 403)));
      } else {
        handler.next(request);
      }
    }));
    final browse = api.getChannels();
    await entered.future;
    expect((await api.getChannelGroups()).channels, healthy.channels);
    release.complete();
    expect((await browse)['Items'], healthy.channels);
    expect((await api.getChannels())['Items'], healthy.channels);
  });

  for (final denied in [false, true]) {
    test('a guide load uses the latest catalog after a concurrent browse (denied: $denied)', () async {
      final (dio, server) = _server();
      final api = PlexLiveTvApi(dio);
      final warm = await api.getChannelGroups();
      expect(warm.channels, hasLength(3));
      final entered = Completer<void>(), release = Completer<void>();
      dio.interceptors.insert(
        0,
        InterceptorsWrapper(
          onRequest: (r, h) async {
            if (r.uri.path == '/' && !entered.isCompleted) {
              final metadata = server.answer(r);
              entered.complete();
              await release.future;
              h.resolve(Response(requestOptions: r, data: metadata));
              return;
            }
            h.next(r);
          },
        ),
      );
      server.fail('/lineups/plex/channels', 503);
      final guide = api.getChannelGroups();
      await entered.future.timeout(const Duration(seconds: 3));
      if (denied) {
        server.fail('/lineups/plex/channels', 403);
      } else {
        server.failWhen = null;
        server.replies['/lineups/plex/channels'] = (_) => _channels([
          {'id': 'jazz', 'genreRatingKeys': ['music']},
        ]);
        server.replies['/'] = (_) => {
          'MediaProvider': {
            'Feature': [
              {
                'type': 'grid',
                'GridChannelFilter': [
                  {'genreRatingKey': 'music', 'title': 'Music'},
                ],
              },
            ],
          },
        };
      }
      final expected = [tuner, if (!denied) 'channel-plex-jazz'];
      expect((await api.getChannels())['Items'], hasLength(expected.length));
      release.complete();
      final published = await guide;
      expect(published.channels!.map((c) => c['Id']), unorderedEquals(expected));
      expect(published.partial, denied);
      if (!denied) {
        expect(published.groupsByChannelId['channel-plex-jazz'], contains('Music'));
      }
    });
  }

  test('a missing tuner channel list retains the channel and its healthy listings', () async {
    final (dio, server) = _server();
    final api = PlexLiveTvApi(dio);
    expect((await api.getChannelGroups()).channels, hasLength(3));
    server.replies['/tv.plex.providers.epg.xmltv:2/lineups/dvr/channels'] =
        (_) => {'MediaContainer': <String, dynamic>{}};
    final lineup = await api.getChannelGroups();
    expect(lineup.channels!.any((c) => c['Id'] == tuner), isTrue);
    expect(lineup.partial, isTrue);
    final guide = await api.testGuide([tuner]);
    final listings = (guide['Items'] as List).map((p) => (p['ChannelId'], p['Name']));
    expect(listings, contains((tuner, 'Teletubbies')));
    expect(guide.containsKey('FailedChannelIds'), isFalse);
  });

  test('malformed provider metadata preserves Featured until a complete response removes it', () async {
    final (dio, server) = _server();
    final api = PlexLiveTvApi(dio);
    final featured = (await api.getChannelGroups()).promoted;
    expect(featured, isNotNull);
    for (final features in [
      [null],
      [{}],
      [{'type': 'grid', 'PromotedGridChannelFilter': [null]}],
      [{'type': 'grid', 'PromotedGridChannelFilter': [{'key': '/lineups/plex/channels/featured'}]}],
    ]) {
      server.replies['/'] = (_) => {'MediaProvider': {'Feature': features}};
      final lineup = await api.getChannelGroups();
      expect(lineup.partial, isTrue);
      expect(lineup.promoted, same(featured));
    }
    server.replies['/'] = (_) => {'MediaProvider': {'Feature': []}};
    final empty = await api.getChannelGroups();
    expect(empty.partial, isFalse);
    expect(empty.promoted, isNull);
  });

  test('partial Featured counts preserve the last verified membership', () async {
    final (dio, server) = _server();
    final api = PlexLiveTvApi(dio);
    final featured = (await api.getChannelGroups()).promoted!;
    final instant = DateTime.now();
    const path = '/lineups/plex/channels/featured';
    server.replies[path] = (_) => _channels([
      {'id': 'abc-66635fc0'},
      {'id': 'news-extra'},
    ], size: 2);
    await featured.refresh(() => instant);
    expect(featured.channelIds, {free, extra});
    final expiry = featured.expiresAt;
    for (final malformed in [null, {}, {'id': ' '}, {'id': []}]) {
      server.replies[path] = (_) => _channels([{'id': 'news-extra'}, malformed], size: 2);
      await expectLater(featured.refresh(() => instant.add(const Duration(hours: 1))), throwsFormatException);
      expect(featured.channelIds, {free, extra});
      expect(featured.expiresAt, expiry);
    }
    server.replies[path] = (_) => _channels([
      {'id': 'abc-66635fc0'},
    ], size: 2);
    await expectLater(
      featured.refresh(() => instant.add(const Duration(hours: 1))),
      throwsA(isA<FormatException>()),
    );
    expect(featured.channelIds, {free, extra});
    server.replies[path] = (_) => {'MediaContainer': {'size': 0}};
    await featured.refresh(() => instant);
    expect(featured.channelIds, isEmpty);
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

  test('a delayed channel read uses the DVR provider discovered by a newer guide', () async {
    final (dio, server) = _server();
    final api = PlexLiveTvApi(dio);
    final started = Completer<void>();
    final release = Completer<void>();
    dio.interceptors.insert(0, InterceptorsWrapper(onRequest: (request, handler) async {
      if (request.path.endsWith('/lineups/dvr/channels') && !started.isCompleted) {
        started.complete();
        await release.future;
      }
      handler.next(request);
    }));
    final browse = api.getChannels();
    await started.future;
    server.discoveryReply = {'MediaContainer': {'Dvr': [
      {'key': '2', 'epgIdentifier': 'replacement'},
    ]}};
    server.replies['/replacement/lineups/dvr/channels'] = (_) => _channels([{'id': '4', 'title': 'Replacement'}]);
    final newer = (await api.getChannelGroups()).channels!.first;
    expect(newer['PlexFavoriteSource'], 'server://pms-machine-1/replacement');
    release.complete();
    expect((await browse)['Items'].first, newer);
  });

  test('replacing a PMS or losing contact with it cannot bind favorites to an old tuner', () async {
    var machine = 'first';
    final (dio, server) = _server(secondDvr: true, machineId: () => machine);
    final api = PlexLiveTvApi(dio);
    Future<Map> refresh() async => (await api.getChannelGroups()).channels!.first;
    final original = await refresh();
    expect(original['PlexFavoriteSource'], 'server://first/tv.plex.providers.epg.xmltv:2');
    server.fail('/livetv/dvrs', 503);
    expect(await refresh(), original);

    machine = 'replacement';
    final cached = await refresh();
    expect(cached['Id'], tuner);
    expect(cached.keys, isNot(contains('PlexFavoriteSource')));
    expect(cached.keys, isNot(contains('PlexFavoriteId')));
    server.failWhen = (r) => r.path == '/livetv/dvrs' || r.path == '/identity';
    expect((await refresh()).containsKey('PlexFavoriteSource'), isFalse);

    server.fail('/tv.plex.providers.epg.xmltv:3/lineups/dvr/channels', 503);
    final lineup = await api.getChannelGroups();
    const verified = 'server://replacement/tv.plex.providers.epg.xmltv:2';
    expect(lineup.channels!.first['PlexFavoriteSource'], verified);
    final retained = lineup.channels!.singleWhere((row) => row['Id'] == 'channel-3-7');
    expect(retained.containsKey('PlexFavoriteSource'), isFalse);
    final reads = server.reads('/identity');
    await api.getChannels();
    expect(server.reads('/identity'), reads);
    server.fail('/identity', 503);
    expect((await refresh()).containsKey('PlexFavoriteSource'), isFalse);
    server.failWhen = null;
    expect((await api.getChannels())['Items'].first['PlexFavoriteSource'], verified);
  });

  test('browsing a cached DVR distinguishes incomplete discovery from a removed tuner', () async {
    final (dio, server) = _server();
    final api = PlexLiveTvApi(dio);
    final healthy = await api.getChannelGroups();
    Future<List> browse() async => [for (final row in (await api.getChannels())['Items'] as List) row['Id']];
    for (final container in <Map<String, dynamic>?>[
      null, {'Dvr': null}, {'size': null}, {'size': 1}, {'size': 1, 'Dvr': [{}]},
      {'Dvr': [{'epgIdentifier': 'tuner'}]}, {'Dvr': [{'key': '2', 'epgIdentifier': ' '}]},
    ]) {
      server.discoveryReply = {if (container != null) 'MediaContainer': container};
      final partial = await api.getChannelGroups();
      expect(partial.channels, healthy.channels);
      expect(partial.sources, healthy.sources);
      expect(partial.partial, isTrue);
      expect(partial.unresolvedChannelIds, {tuner});
    }
    server.discoveryReply = {'MediaContainer': {'Dvr': [{}, {'key': 2, 'epgIdentifier': 'tv.plex.providers.epg.xmltv:2'}]}};
    final cold = await PlexLiveTvApi(dio).getChannelGroups();
    expect(cold.partial, isTrue);
    expect(cold.channels, healthy.channels);

    for (final empty in <Map<String, dynamic>>[{}, {'size': 0}, {'Dvr': []}]) {
      server.discoveryReply = null;
      await api.getChannelGroups();
      server.discoveryReply = {'MediaContainer': empty};
      final lineup = await api.getChannelGroups();
      expect(lineup.partial, empty.isEmpty);
      expect(lineup.groupsByChannelId.containsKey(tuner), empty.isEmpty);
      if (empty.isNotEmpty) expect(lineup.sources, isEmpty);
      server.discoveryReply = null;
      final reads = server.reads('/livetv/dvrs');
      expect((await browse()).contains(tuner), empty.isEmpty);
      await browse();
      expect(server.reads('/livetv/dvrs') - reads, empty.isEmpty ? 1 : 0);
    }
    await api.getChannelGroups();
    server.discoveryReply = {'MediaContainer': <String, dynamic>{}};
    await api.getChannelGroups();
    server.fail('/livetv/dvrs', 503);
    expect(await browse(), contains(tuner));
    server.failWhen = null;
    final reads = server.reads('/livetv/dvrs');
    expect(await browse(), contains(tuner));
    expect((await api.getChannelGroups()).unresolvedChannelIds, {tuner});
    server.discoveryReply = {'MediaContainer': {'size': '0'}};
    expect(await browse(), isNot(contains(tuner)));
    expect(await browse(), isNot(contains(tuner)));
    expect(server.reads('/livetv/dvrs') - reads, 3);
  });

  test('incomplete discovery marks only unresolved tuner schedules for retry', () async {
    final (dio, server) = _server(secondDvr: true);
    final api = PlexLiveTvApi(dio);
    const missing = 'channel-2-4', empty = 'channel-3-7', free = 'channel-plex-abc-66635fc0';
    final guide = api.testGuide;
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

  test('a missing tuner envelope is retryable and a valid empty one is complete', () async {
    final (dio, server) = _server();
    final api = PlexLiveTvApi(dio);
    final healthy = await api.getChannelGroups();
    Future<Map<String, dynamic>> guide() => api.testGuide([tuner, free]);

    for (final badRow in [null, {'Media': 'invalid'}, {'Media': [null]}]) {
      server.tunerReply = {'MediaContainer': {'size': 1, 'Metadata': [badRow]}};
      final mixed = await guide();
      expect(mixed['FailedChannelIds'], [tuner]);
      expect((mixed['Items'] as List).map((row) => row['ChannelId']).toSet(), {free});
      expect((await api.testGuide([tuner]))['FailedChannelIds'], [tuner]);
    }
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

  for (final (path, denied, healthy, program) in [
    ('/tv.plex.providers.epg.xmltv:3/grid', [other], [tuner, free], 'airing-3-1792699380-9'),
    ('/grid', [free], [tuner, extra], 'airing-plex-1792699200-abc-66635fc0'),
    ('/livetv/dvrs', [tuner, 'channel-2-9'], [free], 'airing-2-1792699380-4'),
    ('/lineups/plex/channels', [free, extra], [tuner], 'airing-plex-1792699200-abc-66635fc0'),
  ]) {
    test('guide scopes a 403 from $path and propagates a 401', () async {
      final (dio, server) = _server(secondDvr: true);
      final api = PlexLiveTvApi(dio);
      bool affected(RequestOptions r) => r.uri.path == path &&
          (path != '/grid' || r.queryParameters['channelGridKey'] == 'provider-42');
      var failedReads = 0;
      server.failWhen = (r) {
        if (!affected(r)) return false;
        failedReads++;
        return true;
      };
      server.failureStatus = () => 403;
      for (final station in healthy) {
        final partial = await api.testGuide([station, ...denied]);
        expect(partial['FailedChannelIds'], unorderedEquals(denied));
        expect((partial['Items'] as List).map((p) => p['ChannelId']).toSet(), {station});
      }
      if (path.endsWith(':3/grid')) {
        final before = failedReads;
        expect((await api.testGuide([tuner])).containsKey('FailedChannelIds'), isFalse);
        expect(failedReads, before);
      }
      final partial = await api.testGuide(denied);
      expect(partial['Items'], isEmpty);
      expect(partial['FailedChannelIds'], unorderedEquals(denied));
      if (path == '/lineups/plex/channels') {
        expect(server.reads('/grid'), 0);
        expect((await api.testGuide([tuner]))['Items'], isNotEmpty);
      }
      if (path == '/livetv/dvrs') await expectLater(api.testGuide(), _httpError(403));
      await expectLater(api.getProgram(program), _httpError(403));
      server.failureStatus = () => 401;
      if (path == '/livetv/dvrs') await expectLater(api.getChannelGroups(), _httpError(401));
      await expectLater(api.testGuide([...healthy, ...denied]), _httpError(401));
      server.failWhen = null;
      final recovered = await api.testGuide([...healthy, ...denied]);
      expect(recovered.containsKey('FailedChannelIds'), isFalse);
      expect((recovered['Items'] as List).map((p) => p['ChannelId']), containsAll(healthy));
      if (path == '/lineups/plex/channels' || path == '/livetv/dvrs') {
        expect((recovered['Items'] as List).map((p) => p['ChannelId']), containsAll(denied));
      }
    });
  }

  for (final catalogDenied in [true, false]) {
    test('mixed guide failure preserves the scope of a denial (catalog: $catalogDenied)', () async {
      final (dio, server) = _server(secondDvr: true);
      server.failWhen = (request) {
        final path = request.uri.path;
        final forbidden = path == (catalogDenied ? '/lineups/plex/channels' : '/tv.plex.providers.epg.xmltv:3/grid');
        server.failureStatus = () => forbidden ? 403 : 503;
        return forbidden || path.endsWith('/grid');
      };
      final channels = catalogDenied ? [tuner, free, extra] : [other, free];
      final result = await PlexLiveTvApi(dio).testGuide(channels);
      expect(result['Items'], isEmpty);
      expect(result['FailedChannelIds'], unorderedEquals(channels));
    });
  }

  test('Plex Cloud guide requests disable automatic redirects', () async {
    final (dio, server) = _server();
    final api = PlexLiveTvApi(dio);
    final lineup = await api.getChannelGroups();
    await lineup.promoted!.refresh(DateTime.now);
    await api.testGuide([free]);
    await api.getRecommendedPrograms(limit: 1);

    final cloud = server.requests.where((r) => r.uri.host == 'epg.provider.plex.tv');
    expect(cloud.map((r) => r.uri.path).toSet(), {
      '/', '/lineups/plex/channels', '/lineups/plex/channels/featured',
      '/grid', '/hubs/sections/home/whatsOnNow',
    });
    expect(cloud.map((r) => r.followRedirects), everyElement(isFalse));
  });

  test('opening the guide during a genre outage keeps sources and loads Featured after recovery', () async {
    final (dio, server) = _server();
    final api = PlexLiveTvApi(dio);
    server.fail('/', 503);
    final incomplete = await api.getChannelGroups();
    expect(incomplete.channels, hasLength(3));
    expect(incomplete.promoted, isNull);
    expect((incomplete.promotedError as DioException).response?.statusCode, 503);
    expect(incomplete.partial, isTrue);
    expect(incomplete.unresolvedChannelIds, {free, extra});
    expect(incomplete.groupsByChannelId[tuner], {'source:dvr'});
    expect(incomplete.groupsByChannelId[free], {'source:plexFreeTv'});
    server.failWhen = null;
    final lineup = await api.getChannelGroups();
    expect(lineup.partial, isFalse);
    expect(lineup.promotedError, isNull);
    expect(lineup.unresolvedChannelIds, isNull);
    expect(lineup.groupsByChannelId, {
      'channel-2-4': {'source:dvr'},
      'channel-plex-abc-66635fc0': {'source:plexFreeTv', 'Movies', 'News'},
      'channel-plex-news-extra': {'source:plexFreeTv'},
    });
    final promoted = lineup.promoted!;
    final before = server.requests.length;
    expect((await api.getChannelGroups()).promoted, same(promoted));
    final cloud = server.requests.skip(before).where(
      (r) => r.uri.host == 'epg.provider.plex.tv',
    );
    expect(cloud.map((r) => r.uri.path), [
      '/lineups/plex/channels', '/',
    ]);
    await promoted.refresh(DateTime.now);
    expect(promoted.channelIds, {'channel-plex-abc-66635fc0'});
    expect(promoted.channelIds, isNot(contains('channel-plex-news-extra')));
    expect(server.requests.last.uri.path, '/lineups/plex/channels/featured');
    expect(server.requests.last.headers['X-Plex-Provider-Version'], '7.2');
  });


  test('tuner errors preserve healthy sources until discovery confirms removal', () async {
    final (dio, server) = _server(secondDvr: true);
    final api = PlexLiveTvApi(dio);
    final healthy = await api.getChannelGroups();
    server.tunerReply = {'MediaContainer': {'Channel': [{'id': '5', 'title': 'New station'}]}};
    server.failWhen = (r) => r.uri.path.endsWith(':3/lineups/dvr/channels');
    for (final status in [503, 404]) {
      server.failureStatus = () => status;
      final partial = await api.getChannelGroups();
      expect(partial.partial, isTrue);
      expect(partial.sources, healthy.sources);
      expect(partial.unresolvedChannelIds, {'channel-3-7'});
      expect(partial.groupsByChannelId.keys, containsAll(['channel-2-5', 'channel-3-7', free]));
      expect(partial.groupsByChannelId, isNot(contains(tuner)));
      expect((await api.getChannels())['Items'], partial.channels);
    }
    server.discoveryReply = {'MediaContainer': {'Dvr': [
      {'key': '2', 'epgIdentifier': 'tv.plex.providers.epg.xmltv:2'},
    ]}};
    expect((await api.getChannels())['Items'].map((c) => c['Id']), isNot(contains('channel-3-7')));
    server.discoveryReply = null;
    server.failWhen = null;
    expect((await api.getChannelGroups()).partial, isFalse);
    server.failWhen = (r) => r.uri.path.endsWith(':3/lineups/dvr/channels');
    server.failureStatus = () => 403;
    final denied = await api.getChannelGroups();
    expect(denied.partial, isFalse);
    expect(denied.groupsByChannelId['channel-2-5'], {'source:dvr'});
    expect(denied.groupsByChannelId, isNot(contains('channel-3-7')));
    server.failureStatus = () => 503;
    final unknown = await api.getChannelGroups();
    expect(unknown.partial, isTrue);
    expect(unknown.unresolvedChannelIds, isNull);
  });

  for (final cloudOnly in [false, true]) {
    test('Free TV keeps the last complete lineup until zero is confirmed (cloudOnly=$cloudOnly)', () async {
      final (dio, server) = _server();
      if (cloudOnly) server.discoveryReply = {'MediaContainer': {'Dvr': []}};
      List<Object?> rows = [{'id': 'news'}, {'id': 'film'}, {'id': 'locked', 'drm': true}];
      var size = rows.length;
      server.replies['/lineups/plex/channels'] = (_) => _channels(rows, size: size);
      final api = PlexLiveTvApi(dio);
      final healthy = await api.getChannelGroups();
      final dvrIds = [if (!cloudOnly) 'channel-2-4'];
      expect(healthy.groupsByChannelId.keys, unorderedEquals([...dvrIds, 'channel-plex-news', 'channel-plex-film']));

      for (final (reported, stations) in <(int, List<Object?>)>[
        (3, [{'id': 'news'}]), (3, []), (1, [{}]), (1, [null]), (1, [{'id': []}]),
        (2, [{'id': 'replacement'}, {'id': ' '}]),
      ]) {
        size = reported;
        rows = stations;
        final partial = await api.getChannelGroups();
        expect(partial.partial, isTrue);
        expect(partial.channels, healthy.channels);
        expect((await api.getChannels())['Items'], healthy.channels);
      }

      rows = [{'id': 42}, {'id': 'locked', 'drm': true}];
      size = rows.length;
      final recovered = (await api.getChannels())['Items'] as List;
      expect(recovered.map((c) => c['Id']), unorderedEquals([...dvrIds, 'channel-plex-42']));
      rows = [];
      size = 0;
      final empty = await api.getChannelGroups();
      expect(empty.partial, isFalse);
      expect(empty.groupsByChannelId.keys, unorderedEquals(dvrIds));
      expect((await api.getChannels())['Items'].length, dvrIds.length);
    });
  }





  test('On Now retains programs from healthy sources and propagates session errors', () async {
    const grid = '/tv.plex.providers.epg.xmltv:2/grid';
    for (final (path, status, expected) in <(String, int?, String?)>[
      ('/hubs/sections/home/whatsOnNow', 404, tuner),
      (grid, null, free), (grid, 403, free), (grid, 503, free),
      (grid, 401, null), ('/livetv/dvrs', 403, null),
    ]) {
      final (dio, server) = _server(liveDvr: true);
      server.fail(path, status);
      final result = PlexLiveTvApi(dio).getRecommendedPrograms(limit: 4);
      if (expected == null) {
        await expectLater(result, _httpError(status!));
      } else {
        expect(((await result)['Items'] as List).map((p) => p['ChannelId']), [expected]);
      }
    }
    final (dio, _) = _server(malformedDvrGrid: true);
    final result = await PlexLiveTvApi(dio).getRecommendedPrograms();
    expect((result['Items'] as List).map((p) => p['ChannelId']), [free]);
  });

  test('On Now fills slots vacated by a tuner showing ending during the hub read', () async {
    final (dio, server) = _server();
    final start = DateTime.utc(2026, 10, 22, 20);
    final seconds = start.millisecondsSinceEpoch ~/ 1000;
    var now = start;
    Map<String, dynamic> airing(String channel, int duration) => {
      'beginsAt': seconds - 60, 'endsAt': seconds + duration, 'channelIdentifier': channel,
    };
    server.replies['/tv.plex.providers.epg.xmltv:2/grid'] =
        (_) => _schedule('Ending', [airing('4', 1)]);
    final entered = Completer<void>(), release = Completer<void>();
    dio.interceptors.insert(0, InterceptorsWrapper(onRequest: (request, handler) async {
      if (request.uri.path == '/hubs/sections/home/whatsOnNow') {
        entered.complete();
        await release.future;
        handler.resolve(Response(requestOptions: request, data: _schedule(
          'News', [airing('abc-66635fc0', 300), airing('news-extra', 600)],
        )));
      } else {
        handler.next(request);
      }
    }));
    final api = PlexLiveTvApi(dio, now: () => now);
    final response = api.getRecommendedPrograms(limit: 2);
    await entered.future;
    now = start.add(const Duration(seconds: 1));
    release.complete();
    expect((await response)['Items'].map((row) => row['ChannelId']), [free, extra]);
  });

  test('program lookup distinguishes a catalog outage from a missing Free TV station', () async {
    final (dio, server) = _server();
    final api = PlexLiveTvApi(dio);
    const path = '/lineups/plex/channels';
    const program = 'airing-plex-1792699200-abc-66635fc0';
    const unknown = 'airing-plex-1792699200-unknown';

    server.fail(path, 503);
    await expectLater(api.getProgram(program), _httpError(503));
    expect((await api.testGuide([free]))['FailedChannelIds'], [free]);

    server.failWhen = null;
    await expectLater(api.getProgram(unknown), throwsStateError);
    server.fail(path, 503);
    expect((await api.getChannelGroups()).partial, isTrue);
    await expectLater(api.getProgram(unknown), _httpError(503));
    expect(server.reads('/grid'), 0);
    expect((await api.getProgram(program))['Id'], program);
  });

  test('a removed station cannot borrow a grid with the same suffix', () async {
    final (dio, server) = _server();
    final api = PlexLiveTvApi(dio);
    await api.getChannelGroups();
    server.replies['/lineups/plex/channels'] = (_) => _channels([{'id': 'new-66635fc0'}]);
    await api.getChannelGroups();
    final response = await api.testGuide([free, 'channel-plex-new-66635fc0']);
    expect(response['FailedChannelIds'], [free]);
    expect((response['Items'] as List).map((p) => p['ChannelId']), ['channel-plex-new-66635fc0']);
    expect(server.reads('/grid'), 1);
  });

  test('incomplete Free TV grids can retry through a media server', () async {
    final (dio, server) = _server();
    final grid = <String, dynamic>{'size': 2, 'Metadata': []};
    server.replies['/grid'] = (_) => {'MediaContainer': grid};
    final api = PlexLiveTvApi(dio);
    await expectLater(api.testGuide([free]), throwsFormatException);
    grid.addAll({'size': 1, 'Metadata': [17]});
    final partial = await api.testGuide([free, tuner]);
    expect(partial['FailedChannelIds'], [free]);
    expect((partial['Items'] as List).map((row) => row['ChannelId']).toSet(), {tuner});
    grid['Metadata'] = [{'Media': [null]}];
    await expectLater(api.testGuide([free]), throwsFormatException);
    grid.addAll({'size': 0, 'Metadata': []});
    expect((await api.testGuide([free]))['Items'], isEmpty);
    expect((await api.testGuide([free]))['Items'], isEmpty);
    expect(server.reads('/grid'), 4);
  });

  test('Home shows a tuner outage when Free TV has nothing airing and recovers on retry', () async {
    final (dio, server) = _server(liveDvr: true);
    final api = PlexLiveTvApi(dio);
    Future<List> onNow() async => (await api.getRecommendedPrograms(limit: 1))['Items'] as List;
    server.replies['/lineups/plex/channels'] = (_) => _channels([], size: 0);
    expect(await onNow(), hasLength(1));
    server.fail('/tv.plex.providers.epg.xmltv:2/grid', 503);
    await expectLater(onNow(), throwsA(isA<DioException>()
        .having((e) => e.response?.statusCode, 'status', 503)
        .having((e) => e.requestOptions.uri.path, 'path', endsWith(':2/grid'))));
    server.failWhen = null;
    expect(await onNow(), hasLength(1));
    server.tunerReply = {'MediaContainer': {'Metadata': {}}};
    await expectLater(onNow(), throwsFormatException);
    server.tunerReply = {'MediaContainer': {'size': 1}};
    await expectLater(onNow(), throwsFormatException);
    server.tunerReply = {};
    await expectLater(onNow(), throwsFormatException);
    server.tunerReply = {'MediaContainer': {'Metadata': []}};
    expect(await onNow(), isEmpty);
    server.discoveryReply = {'MediaContainer': {'size': 1}};
    await api.getChannelGroups();
    await expectLater(onNow(), throwsFormatException);
    server.discoveryReply = {'MediaContainer': {'size': 0}};
    expect(await onNow(), isEmpty);
  });

  test('Home surfaces a partial tuner outage only when no source has a live program', () async {
    final (dio, server) = _server(secondDvr: true);
    final api = PlexLiveTvApi(dio, now: () => DateTime.utc(2026, 10, 22, 20, 30));
    Future<List> onNow() async => (await api.getRecommendedPrograms(limit: 1))['Items'] as List;
    server.fail('/tv.plex.providers.epg.xmltv:2/grid', 503);
    server.replies['/hubs/sections/home/whatsOnNow'] = (_) =>
        _schedule('Free TV', [{..._airing, 'channelIdentifier': 'abc-66635fc0'}]);
    expect((await onNow()).single['ChannelId'], free);

    server.replies['/lineups/plex/channels'] = (_) => _channels([], size: 0);
    await api.getChannelGroups();
    await expectLater(onNow(), _httpError(503));

    server.replies['/tv.plex.providers.epg.xmltv:3/grid'] = (_) =>
        _schedule('Tuner', [{..._airing, 'channelIdentifier': '7'}]);
    expect((await onNow()).single['ChannelId'], 'channel-3-7');
  });

  test('recording from the guide targets the selected channel, showing and time', () async {
    final (dio, server) = _server(secondDvr: true);
    final api = PlexLiveTvApi(dio);
    var otherGridReads = 0;
    server.failWhen = (request) {
      if (request.uri.path != '/tv.plex.providers.epg.xmltv:3/grid') return false;
      otherGridReads++;
      return true;
    };
    server.failureStatus = () => 403;
    final result = await api.testGuide([tuner]);
    final programs = (result['Items'] as List).cast<Map>();
    expect(programs, hasLength(2));
    final selected = programs.first;
    final expected = {
      'Id': 'airing-2-1792699380-4', 'ChannelId': tuner, 'Name': 'Teletubbies',
      'EpisodeTitle': 'Episode 5', 'IsPremiere': true, 'IndexNumber': 5,
      'StartDate': '2026-10-22T20:03:00.000Z', 'TimerId': 'once',
    };
    for (final field in expected.entries) {
      expect(selected, containsPair(field.key, field.value));
    }
    expect(programs.last['Name'], 'SuperKitties');
    expect(programs.last['IsMovie'], isFalse);
    expect(programs.last.containsKey('TimerId'), isFalse);
    final grid = server.requests.singleWhere((r) => r.uri.path.endsWith('/grid'));
    expect(grid.queryParameters['type'], '1,4');

    final bounded = await api.getGuide(
      startDate: DateTime.utc(2026, 10, 22, 21, 4), endDate: DateTime.utc(2026, 10, 22, 23),
      channelIds: [tuner, 'channel-2-9'],
    );
    expect((bounded['Items'] as List).map((item) => item['Name']), ['SuperKitties']);
    await api.createTimer(selected['Id']);
    final post = server.requests.singleWhere((r) => r.method == 'POST');
    expect(post.uri.path, '/media/subscriptions');
    expect(post.uri.query, startsWith('hints%5Btype%5D=4&'));
    expect(post.uri.queryParameters, allOf(
      containsPair('type', '4'), containsPair('targetLibrarySectionID', '2'),
      containsPair('prefs[recordPartials]', 'true'), containsPair('prefs[lineupChannel]', '4'),
      containsPair('prefs[startTimeslot]', '1792699380'),
    ));
    expect(otherGridReads, 0);
  });

  test('manage a series rule and cancel individual scheduled showings', () async {
    final (dio, server) = _server();
    final api = PlexLiveTvApi(dio);
    await api.createSeriesTimer('airing-2-1792699380-4',
        settings: {'RecordNewOnly': false, 'SkipEpisodesInLibrary': true});
    final post = server.requests.singleWhere((r) => r.method == 'POST');
    expect(post.uri.queryParameters['type'], '2');
    expect(post.uri.queryParameters['prefs[onlyNewAirings]'], '0');
    final rule = await api.getSeriesTimer('8');
    expect(rule['RecordNewOnly'], isTrue);
    await api.updateSeriesTimer('8', {...rule, 'RecordNewOnly': false});
    final put = server.requests.singleWhere((r) => r.method == 'PUT');
    expect(put.uri.path, '/media/subscriptions/8');
    expect(put.uri.queryParameters, {'prefs[onlyNewAirings]': '0'});

    final timers = ((await api.getTimers())['Items'] as List).cast<Map>();
    expect((timers.first['Id'], timers.first['ProgramId'], timers.first['Status']),
        ('once', 'airing-2-1792699380-4', 'New'));
    expect(timers.first.containsKey('SeriesTimerId'), isFalse);
    expect((timers.last['ProgramId'], timers.last['SeriesTimerId'], timers.last['Status']),
        ('airing-2-1792710000-9', '8', 'InProgress'));
    await api.cancelTimer(timers.first['Id']);
    await api.cancelTimer(timers.last['ProgramId']);
    expect(server.requests.where((r) => r.method == 'DELETE').map((r) => r.uri.path),
        ['/media/subscriptions/7', '/media/grabbers/operations/weekly']);
  });





  for (final publishFirst in [true, false]) {
    test('an old grid preserves a catalog refresh (publish first: $publishFirst)', () async {
      const catalog = '/lineups/plex/channels';
      final (dio, server) = _server();
      final api = PlexLiveTvApi(dio);
      await api.getChannels();
      server.replies[catalog] = (_) => _channels([{'id': 'abc-66635fc0', 'gridKey': 'replacement'}]);
      server.replies['/grid'] = (r) => _schedule('News', [
        if (r.queryParameters['date'] == '2026-10-22') {..._airing, 'channelIdentifier': 'news-extra'},
      ]);

      final firstGrid = Completer<void Function()>(), lastGrid = Completer<void Function()>();
      final catalogRead = Completer<void Function()>();
      dio.interceptors.insert(0, InterceptorsWrapper(onRequest: (r, handler) {
        final gate = switch ((r.uri.path, r.queryParameters['date'])) {
          ('/grid', '2026-10-19') => firstGrid,
          ('/grid', '2026-10-22') => lastGrid,
          (catalog, _) => catalogRead,
          _ => null,
        };
        if (gate == null || gate.isCompleted) return handler.next(r);
        gate.complete(() => handler.next(r));
      }));

      // Four days put the last grid in a second batch, after the refresh starts.
      final guide = api.getGuide(channelIds: [free],
          startDate: DateTime.utc(2026, 10, 19), endDate: DateTime.utc(2026, 10, 23));
      final releaseFirst = await firstGrid.future;
      final refresh = api.getChannelGroups();
      final publish = await catalogRead.future;
      releaseFirst();
      final releaseLast = await lastGrid.future;
      if (publishFirst) {
        publish();
        await refresh;
      }
      releaseLast();
      expect((await guide)['FailedChannelIds'], [free]);
      if (!publishFirst) publish();
      final lineup = await refresh;
      expect(lineup.partial, isFalse);
      expect((await api.getChannels())['Items'], lineup.channels);
      expect(server.reads(catalog), 2);
    });
  }

  test('a conflicting grid station during a catalog outage is retryable', () async {
    const channel = free;
    final (dio, server) = _server();
    final media = <String, dynamic>{..._airing, 'channelIdentifier': channel, 'channelId': 'news-extra'};
    server.replies['/grid'] = (_) => _schedule('News', [media, {'beginsAt': 1792699200}]);
    final api = PlexLiveTvApi(dio);
    await api.getChannels();
    server.fail('/lineups/plex/channels', 503);
    expect((await api.getChannelGroups()).partial, isTrue);
    Future<Map> guide() => api.testGuide([channel]);
    final failed = await guide();
    expect(failed['Items'], isEmpty);
    expect(failed['FailedChannelIds'], [channel]);
    server.failWhen = null;
    media['channelId'] = {'id': 'abc-66635fc0'};
    final recovered = await guide();
    expect((recovered['Items'] as List).single['ChannelId'], channel);
    expect(recovered.containsKey('FailedChannelIds'), isFalse);
    expect(server.reads('/grid'), 2);
  });

  test('On Now skips conflicting explicit stations and accepts agreeing references', () async {
    final (dio, server) = _server();
    final api = PlexLiveTvApi(dio, now: () => DateTime.utc(2026, 10, 22, 20, 30));
    server.discoveryReply = {'MediaContainer': {'Dvr': []}};
    server.replies['/hubs/sections/home/whatsOnNow'] = (_) => {
      'MediaContainer': {
        'Metadata': [
          for (final id in [extra, free])
            {'title': id, 'channelId': id, 'Media': [{..._airing, 'channelIdentifier': 'abc-66635fc0'}]},
        ],
      },
    };
    final programs = (await api.getRecommendedPrograms())['Items'] as List;
    expect(programs.single['Name'], free);
    expect(programs.single['ChannelId'], free);
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
