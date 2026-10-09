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
    expect(
      CinemaMediaResolver.directMedia({
        ...item,
        '__moonfinCinemaFeatureType': 'Episode',
        'ProviderIds': {'Tmdb': '42', 'TmdbMediaType': 'movie'},
      })?.type,
      CinemaMediaType.movie,
    );
  });
}
