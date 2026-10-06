import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/services/cinema_movie_resolver.dart';
import 'package:server_core/server_core.dart';

class _Client extends Fake implements MediaServerClient {
  @override
  String baseUrl = 'https://server';
  @override
  String? userId = 'user';
  @override
  String? accessToken = 'token';
  int calls = 0;
  Completer<CinemaMedia?> reply = Completer();
  @override
  Future<CinemaMedia?> resolveCinemaMedia(
    String itemId, {
    CinemaMediaType? expectedMediaType,
  }) {
    calls++;
    return reply.future;
  }
}

void main() {
  test(
    'IDs require a trustworthy type; overlapping namespaces stay distinct',
    () {
      CinemaMedia? direct(String type, Map<String, String> ids) =>
          CinemaMovieResolver.directMedia({'Type': type, 'ProviderIds': ids});
      expect(direct('Movie', {'Tmdb': '42'})?.type, CinemaMediaType.movie);
      expect(direct('Series', {'Tmdb': '42'})?.type, CinemaMediaType.tv);
      expect(direct('Video', {'Tmdb': '42'}), isNull);
      expect(direct('Episode', {'Tmdb': '42', 'TmdbMediaType': 'tv'}), isNull);
      expect(direct('Video', {'Tmdb': '-4', 'TmdbMediaType': 'movie'}), isNull);
      expect(direct('Movie', {'Tmdb': '42', 'TmdbMediaType': 'tv'}), isNull);
      expect(
        direct('Video', {'Tmdb': '42', 'TmdbMediaType': 'unknown'}),
        isNull,
      );
      final series = direct('Video', {
        'tmdb': '42',
        'TmdbMediaType': 'tv',
        'TmdbSeason': '5',
      });
      expect(series?.type, CinemaMediaType.tv);
      expect(series?.season, 5);
      expect(
        direct('Video', {
          'Tmdb': '42',
          'trailers4jellyfin.trailer': '/movie.mp4',
        })?.type,
        CinemaMediaType.movie,
      );
      expect(CinemaMedia.fromJson({'tmdbId': 42}), isNull);
    },
  );

  test(
    'typed trailers work before either feature category without lookup',
    () async {
      final client = _Client();
      final resolver = CinemaMovieResolver();
      for (final type in CinemaMediaType.values) {
        final result = await resolver.resolve(
          client: client,
          itemId: 'intro',
          item: {
            'Type': 'Video',
            'ProviderIds': {'Tmdb': '42', 'TmdbMediaType': type.name},
          },
          expectedMediaType: type == CinemaMediaType.tv
              ? CinemaMediaType.movie
              : CinemaMediaType.tv,
        );
        expect(result?.type, type);
      }
      expect(client.calls, 0);
    },
  );

  test('deduplication includes source, account, token, and search category; no completed cache', () async {
    final client = _Client();
    final resolver = CinemaMovieResolver();
    Future<CinemaMedia?> resolve([
      CinemaMediaType type = CinemaMediaType.movie,
    ]) => resolver.resolve(
      client: client,
      itemId: 'intro',
      item: {},
      expectedMediaType: type,
    );
    final a = resolve();
    final b = resolve();
    expect(client.calls, 1);
    final tv = resolve(CinemaMediaType.tv);
    client.userId = 'other';
    final other = resolve();
    client.accessToken = 'new-token';
    final token = resolve();
    client.baseUrl = 'https://other';
    final source = resolve();
    expect(client.calls, 5);
    client.reply.complete(null);
    await Future.wait([a, b, tv, other, token, source]);
    client.reply = Completer();
    final fresh = resolve();
    expect(client.calls, 6);
    client.reply.complete(const CinemaMedia(42, CinemaMediaType.movie));
    expect((await fresh)?.tmdbId, 42);
  });

  test('endpoint failures and old plugins hide the action and clear in-flight work', () async {
    final client = _Client();
    final resolver = CinemaMovieResolver();
    final a = resolver.resolve(client: client, itemId: 'intro', item: {});
    client.reply.completeError(StateError('404'));
    expect(await a, isNull);
    client.reply = Completer();
    final b = resolver.resolve(client: client, itemId: 'intro', item: {});
    client.reply.complete(null);
    expect(await b, isNull);
    expect(client.calls, 2);
  });
}
