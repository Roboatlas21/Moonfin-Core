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

  test('movie context permits an unattached trailer without a server lookup', () async {
    final item = <String, dynamic>{
      'Type': 'Video',
      'ProviderIds': {'Tmdb': '42'},
      '__moonfinCinemaFeatureType': 'Movie',
    };
    final client = _Client();
    final media = await CinemaMediaResolver.resolve(
      client: client,
      itemId: 'trailer',
      item: item,
    );
    expect(media?.type, CinemaMediaType.movie);
    expect(media?.tmdbId, 42);
    expect(client.calls, 0);

    expect(
      CinemaMediaResolver.directMedia({
        ...item,
        '__moonfinCinemaFeatureType': 'Episode',
      }),
      isNull,
    );
    expect(
      CinemaMediaResolver.directMedia({
        ...item,
        'OwnerId': '11111111-1111-1111-1111-111111111111',
      }),
      isNull,
    );
  });

  test('an untyped TV trailer uses the server to identify its show', () async {
    final client = _Client()
      ..reply.complete(const CinemaMedia(42, CinemaMediaType.tv));
    final media = await CinemaMediaResolver.resolve(
      client: client,
      itemId: 'trailer',
      item: {
        'Type': 'Video',
        'ProviderIds': {'Tmdb': '42'},
        '__moonfinCinemaFeatureType': 'Episode',
      },
    );
    expect(media?.type, CinemaMediaType.tv);
    expect(client.calls, 1);
    expect(client.requestedType, CinemaMediaType.tv);
  });

}
