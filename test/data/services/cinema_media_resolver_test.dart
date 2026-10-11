import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/services/cinema_media_resolver.dart';
import 'package:server_core/server_core.dart';

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

  test('untyped trailer IDs use playback context', () {
    final item = <String, dynamic>{
      'Type': 'Video',
      'ProviderIds': {'Tmdb': '42'},
    };
    CinemaMediaType? inContext(String feature) =>
        CinemaMediaResolver.directMedia({
          ...item,
          '__moonfinCinemaFeatureType': feature,
        })?.type;

    expect(inContext('Movie'), CinemaMediaType.movie);
    expect(inContext('Episode'), CinemaMediaType.tv);
    for (final owner in ['', 0, '00000000-0000-0000-0000-000000000000']) {
      expect(
        CinemaMediaResolver.directMedia({
          ...item,
          'OwnerId': owner,
          '__moonfinCinemaFeatureType': 'Movie',
        })?.type,
        CinemaMediaType.movie,
      );
    }
    expect(
      CinemaMediaResolver.directMedia({
        ...item,
        'OwnerId': 'movie-owner',
        '__moonfinCinemaFeatureType': 'Episode',
        'ProviderIds': {'Tmdb': '42', 'TmdbMediaType': 'movie'},
      })?.type,
      CinemaMediaType.movie,
    );
  });

  test('an attached trailer uses its owner before playback context', () async {
    final item = <String, dynamic>{
      'Type': 'Trailer',
      'OwnerId': 'movie-owner',
      'ProviderIds': {'Tmdb': '42'},
      '__moonfinCinemaFeatureType': 'Episode',
    };
    expect(CinemaMediaResolver.directMedia(item), isNull);
    final media = await CinemaMediaResolver.resolve(
      client: _OwnerClient(),
      itemId: 'trailer',
      item: item,
    );
    expect(media?.tmdbId, 42);
    expect(media?.type, CinemaMediaType.movie);
  });
}

class _OwnerClient implements MediaServerClient {
  @override
  Future<CinemaMedia?> resolveCinemaMedia(
    String itemId, {
    CinemaMediaType? expectedMediaType,
  }) async => const CinemaMedia(42, CinemaMediaType.movie);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
