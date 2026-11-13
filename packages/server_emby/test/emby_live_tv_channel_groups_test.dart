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
}
