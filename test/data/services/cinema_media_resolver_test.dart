import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/services/cinema_media_resolver.dart';
import 'package:server_core/server_core.dart';

class _Client extends Fake implements MediaServerClient {
  int calls = 0;
  CinemaMediaType? requestedType;
  final reply = Completer<CinemaMedia?>();

  @override
  Future<CinemaMedia?> resolveCinemaMedia(
    String itemId, {
    CinemaMediaType? expectedMediaType,
  }) {
    calls++;
    requestedType = expectedMediaType;
    return reply.future;
  }
}

void main() {
  test('a TMDB ID must identify the correct movie or series', () {
    CinemaMedia? direct(String type, Map<String, String> ids) =>
        CinemaMediaResolver.directMedia({'Type': type, 'ProviderIds': ids});

    expect(direct('Movie', {'Tmdb': '42'})?.type, CinemaMediaType.movie);
    expect(direct('Series', {'Tmdb': '42'})?.type, CinemaMediaType.tv);
    expect(direct('Video', {'Tmdb': '42'}), isNull);
    expect(
      direct('Movie', {'Tmdb': '42', 'TmdbMediaType': 'tv'}),
      isNull,
    );
    expect(
      direct('Video', {'Tmdb': '42', 'TmdbMediaType': 'tv'})?.type,
      CinemaMediaType.tv,
    );
    expect(direct('Video', {'Tmdb': '-4', 'TmdbMediaType': 'movie'}), isNull);
  });

  test('untyped IDs use movie or episode playback context without a server lookup', () async {
    final client = _Client();
    for (final (feature, expected) in [
      ('Movie', CinemaMediaType.movie),
      ('Episode', CinemaMediaType.tv),
    ]) {
      final media = await CinemaMediaResolver.resolve(
        client: client,
        itemId: 'trailer',
        item: {
          'Type': 'Video',
          'ProviderIds': {'Tmdb': '42'},
          '__moonfinCinemaFeatureType': feature,
        },
      );
      expect(media?.tmdbId, 42);
      expect(media?.type, expected);
    }
    expect(client.calls, 0);
  });

  test('explicit type or item classification takes priority over playback context', () {
    CinemaMedia? resolve(String type, Map<String, String> ids) =>
        CinemaMediaResolver.directMedia({
          'Type': type,
          'ProviderIds': ids,
          '__moonfinCinemaFeatureType': 'Episode',
        });

    expect(
      resolve('Video', {'Tmdb': '42', 'TmdbMediaType': 'movie'})?.type,
      CinemaMediaType.movie,
    );
    expect(resolve('Movie', {'Tmdb': '42'})?.type, CinemaMediaType.movie);
    expect(
      resolve('Series', {'Tmdb': '42', 'TmdbMediaType': 'movie'}),
      isNull,
    );
  });

  test('a missing TMDB ID uses the server with the movie or series context', () async {
    for (final (feature, expected) in [
      ('Movie', CinemaMediaType.movie),
      ('Episode', CinemaMediaType.tv),
    ]) {
      final client = _Client()
        ..reply.complete(CinemaMedia(42, expected));
      final media = await CinemaMediaResolver.resolve(
        client: client,
        itemId: 'trailer',
        item: {
          'Type': 'Video',
          '__moonfinCinemaFeatureType': feature,
        },
      );
      expect(media?.type, expected);
      expect(client.calls, 1);
      expect(client.requestedType, expected);
    }
  });

}
