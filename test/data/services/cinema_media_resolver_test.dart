import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/services/cinema_media_resolver.dart';
import 'package:server_core/server_core.dart';

class _Client extends Fake implements MediaServerClient {
  int calls = 0;
  CinemaMediaType? requestedType;
  Completer<CinemaMedia?> reply = Completer();
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
          'UnrelatedPlugin.Marker': '/movie.mp4',
        }),
        isNull,
      );
      expect(CinemaMedia.fromJson({'tmdbId': 42}), isNull);
    },
  );


  test('movie context resolves an untyped ID without Moonbase', () async {
    final item = <String, dynamic>{
      'Type': 'Video',
      'ProviderIds': {'Tmdb': '42'},
      '__moonfinCinemaFeatureType': 'Movie',
    };
    final client = _Client()..reply.complete(null);
    final result = await CinemaMediaResolver.resolve(
      client: client,
      itemId: 'trailer',
      item: item,
    );
    expect(result?.tmdbId, 42);
    expect(result?.type, CinemaMediaType.movie);
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
    expect(
      CinemaMediaResolver.directMedia({
        ...item,
        'ProviderIds': {'Tmdb': '42', 'TmdbMediaType': 'tv'},
      })?.type,
      CinemaMediaType.tv,
    );
  });

  test('untyped TV trailers require Moonbase identity resolution', () async {
    final client = _Client()
      ..reply.complete(const CinemaMedia(42, CinemaMediaType.tv));
    final result = await CinemaMediaResolver.resolve(
      client: client,
      itemId: 'trailer',
      item: {
        'Type': 'Video',
        'ProviderIds': {'Tmdb': '42'},
        '__moonfinCinemaFeatureType': 'Episode',
      },
    );
    expect(result?.type, CinemaMediaType.tv);
    expect(client.calls, 1);
    expect(client.requestedType, CinemaMediaType.tv);
  });

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
