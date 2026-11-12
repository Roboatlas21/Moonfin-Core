import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/viewmodels/live_tv_channel_groups.dart';

void main() {
  test('Moonbase returns exact group names without splitting vertical bars', () {
    final resolved = resolveLiveTvChannelGroups(
      [
        {'Id': '72aB-00dE', 'Tags': ['US', ' SPORTS', 'Kids']},
        {'Id': 'b2', 'Tags': ['US', ' MOVIES']},
      ],
      {
        'Channels': [
          {'ChannelId': '72ab00de', 'Group': 'US| SPORTS'},
          {'ChannelId': 'b2', 'Group': 'US| MOVIES'},
        ],
      },
    );

    expect(resolved['72aB-00dE'], ['US| SPORTS']);
    expect(resolved['b2'], ['US| MOVIES']);
  });

  test('accepts camelCase metadata from alternate server serializers', () {
    final resolved = resolveLiveTvChannelGroups(
      [{'Id': 'aabb', 'Name': 'ESPN'}],
      {
        'channels': [
          {'channelId': 'aabb', 'group': 'US| SPORTS'},
        ],
      },
    );
    expect(resolved['aabb'], ['US| SPORTS']);
  });

  test('Jellyfin and Emby channel tags work without Moonbase', () {
    final resolved = resolveLiveTvChannelGroups(
      [
        {'Id': 'c1', 'Tags': ['US', ' SPORTS', 'Kids']},
        {'Id': 'c2', 'Tags': ['US ', ' NEWS']},
        {'Id': 'c3', 'Tags': ['US', 'SPORTS']},
        {'Id': 'c4', 'Tags': ['Sports', 'News']},
        {'Id': 'c5', 'TagItems': [{'Name': 'US| SPORTS'}, {'Name': 'News'}]},
        {'Id': 'c6', 'Tags': ['Sports'], 'TagItems': [{'Name': 'Ignored'}]},
      ],
      null,
    );

    expect(resolved['c1'], ['US| SPORTS', 'Kids']);
    expect(resolved['c2'], ['US | NEWS']);
    expect(resolved['c3'], ['US', 'SPORTS']);
    expect(resolved['c4'], ['Sports', 'News']);
    expect(resolved['c5'], ['US| SPORTS', 'News']);
    expect(resolved['c6'], ['Sports']);
  });

  test('unknown plugin IDs are ignored and empty tags yield no groups', () {
    final resolved = resolveLiveTvChannelGroups(
      [
        {'Id': 'c1', 'Tags': <String>[]},
        {'Id': 'c2'},
      ],
      {
        'Channels': [
          {'ChannelId': 'missing', 'Group': 'US| SPORTS'},
          {'ChannelId': 'c2', 'Group': 'US| KIDS'},
        ],
      },
    );

    expect(resolved.containsKey('c1'), false);
    expect(resolved['c2'], ['US| KIDS']);
  });

  test('a tuner group named Kids is not silently discarded', () {
    final resolved = resolveLiveTvChannelGroups(
      [
        {'Id': 'c1', 'Tags': ['Kids']},
      ],
      null,
    );
    expect(resolved['c1'], ['Kids']);
  });
}
