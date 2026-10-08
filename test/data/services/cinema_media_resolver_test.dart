import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/services/cinema_media_resolver.dart';
import 'package:server_core/server_core.dart';

class _Client extends Fake implements MediaServerClient {
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
          CinemaMediaResolver.directMedia({'Type': type, 'ProviderIds': ids});
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
      });
      expect(series?.type, CinemaMediaType.tv);
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

  test('endpoint failures do not retain results', () async {
    final client = _Client();
    final a = CinemaMediaResolver.resolve(
      client: client,
      itemId: 'intro',
      item: {},
    );
    client.reply.completeError(StateError('404'));
    expect(await a, isNull);
    client.reply = Completer();
    final b = CinemaMediaResolver.resolve(
      client: client,
      itemId: 'intro',
      item: {},
    );
    client.reply.complete(null);
    expect(await b, isNull);
    expect(client.calls, 2);
  });
}
