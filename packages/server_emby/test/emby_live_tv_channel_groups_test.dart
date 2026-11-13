import 'package:dio/dio.dart';
import 'package:server_emby/src/api/emby_live_tv_api.dart';
import 'package:test/test.dart';

import 'admin_fake.dart';

void main() {
  test('Emby groups come from channel tags in a single user-scoped request', () async {
    final channels = <Map<String, dynamic>>[
      {
        'Id': 'espn',
        'Name': 'ESPN',
        'ChannelNumber': '25',
        'UserData': {'IsFavorite': true},
        'TagItems': [
          {'Id': 1, 'Name': 'US | SPORTS'},
          {'Id': 2, 'Name': 'US|SPORTS'},
          {'Id': 3, 'Name': 'HD'},
          {'Id': 3, 'Name': 'HD'},
        ],
      },
      {
        'Id': 'news',
        'Name': 'News',
        'TagItems': [
          {'Name': 'News'},
          {'Name': 'HD'},
        ],
      },
      {'Id': 'untagged', 'Name': 'Local', 'TagItems': <dynamic>[]},
    ];
    final fake = AdminFake({'/LiveTv/Channels': {'Items': channels}});
    final result = await EmbyLiveTvApi(fake.dio).getChannelGroups(
      userId: 'viewer',
    );

    expect(fake.requests, hasLength(1));
    expect(fake.last.path, '/LiveTv/Channels');
    expect(fake.last.queryParameters, {
      'SortBy': 'SortName',
      'SortOrder': 'Ascending',
      'Fields': 'ImageTags,UserData,Tags',
      'EnableTotalRecordCount': false,
      'UserId': 'viewer',
    });
    expect(result.channels, channels);
    expect(result.groupsByChannelId, {
      'espn': {'US | SPORTS', 'US|SPORTS', 'HD'},
      'news': {'News', 'HD'},
    });
    expect(result.partial, isFalse);
    expect(result.endpointAvailable, isTrue);
  });

  test('prefers whole TagItems and uses Tags when TagItems are missing', () async {
    final fake = AdminFake({
      '/LiveTv/Channels': {
        'Items': [
          {
            'Id': 'whole',
            'Name': 'Whole',
            'TagItems': [
              {'Name': 'CA | SPORTS'},
              {'Name': '  Kids  '},
              {'Name': 'CA | SPORTS'},
              {'Name': ''},
              {'Id': 3},
              null,
            ],
            'Tags': ['Do not use'],
          },
          {'Id': 'fallback', 'Name': 'Fallback', 'Tags': ['US|SPORTS', ' ']},
          {'Id': 'empty', 'Name': 'Empty', 'TagItems': [], 'Tags': ['Radio']},
          {'Id': 'none', 'Name': 'None', 'TagItems': []},
        ],
      },
    });
    final result = await EmbyLiveTvApi(fake.dio).getChannelGroups();

    expect(result.groupsByChannelId, {
      'whole': {'CA | SPORTS', 'Kids'},
      'fallback': {'US|SPORTS'},
      'empty': {'Radio'},
    });
    expect(result.channels, hasLength(4));
    expect(fake.last.queryParameters.containsKey('UserId'), isFalse);
  });

  test('channel authorization errors are not hidden by group fallback', () async {
    final fake = AdminFake()..statuses['/LiveTv/Channels'] = 403;
    await expectLater(
      EmbyLiveTvApi(fake.dio).getChannelGroups(userId: 'viewer'),
      throwsA(isA<DioException>()),
    );
    expect(fake.requests, hasLength(1));
  });

  test('program categories use small, user-scoped, date-scoped requests', () async {
    final fake = AdminFake({'/LiveTv/Programs': {'Items': []}});
    final api = EmbyLiveTvApi(fake.dio);
    final from = DateTime.utc(2026, 11, 13, 10);
    final to = from.add(const Duration(hours: 6));
    final categories = await api.getProgrammeCategories(
      from: from,
      to: to,
      userId: 'viewer',
    );

    expect(categories, isEmpty);
    expect(fake.requests, hasLength(6));
    expect(
      fake.requests.map((request) => request.queryParameters.keys
          .where((key) => key.startsWith('Is')).single).toSet(),
      {'IsMovie', 'IsSeries', 'IsSports', 'IsNews', 'IsKids', 'IsPremiere'},
    );
    for (final request in fake.requests) {
      expect(request.path, '/LiveTv/Programs');
      expect(request.queryParameters['UserId'], 'viewer');
      expect(request.queryParameters['MinEndDate'], from.toIso8601String());
      expect(request.queryParameters['MaxStartDate'], to.toIso8601String());
      expect(request.queryParameters['Limit'], 1);
      expect(request.queryParameters['EnableTotalRecordCount'], false);
      expect(request.queryParameters['EnableImages'], false);
      expect(request.queryParameters['EnableUserData'], false);
    }

    // Same scope uses the cached result rather than sending six more probes.
    expect(
      await api.getProgrammeCategories(from: from, to: to, userId: 'viewer'),
      isEmpty,
    );
    expect(fake.requests, hasLength(6));
    await api.getProgrammeCategories(from: to, to: to.add(const Duration(hours: 6)), userId: 'viewer');
    expect(fake.requests, hasLength(12));
    await api.getProgrammeCategories(from: from, to: to, userId: 'another');
    expect(fake.requests, hasLength(18));
  });

  test('failed or invalid category checks do not hide program filters', () async {
    final fake = AdminFake()..statuses['/LiveTv/Programs'] = 503;
    final api = EmbyLiveTvApi(fake.dio);
    final from = DateTime.utc(2026, 11, 13);
    final to = from.add(const Duration(days: 1));
    expect(
      await api.getProgrammeCategories(from: from, to: to, userId: 'viewer'),
      isNull,
    );
    expect(fake.requests, hasLength(6));
    fake.statuses.clear();
    fake.responses['/LiveTv/Programs'] = {'Items': []};
    expect(
      await api.getProgrammeCategories(from: from, to: to, userId: 'viewer'),
      isEmpty,
    );
    expect(fake.requests, hasLength(12));
    fake.responses['/LiveTv/Programs'] = {};
    expect(
      await api.getProgrammeCategories(from: to, to: to.add(const Duration(days: 1)), userId: 'viewer'),
      isNull,
    );
  });
}
