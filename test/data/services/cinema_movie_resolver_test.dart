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
  Completer<int?> reply = Completer();
  @override
  Future<int?> resolveCinemaMovie(String itemId) {
    calls++;
    return reply.future;
  }
}

void main() {
  test(
    'direct positive movie IDs avoid the endpoint; known TV IDs are rejected',
    () async {
      final client = _Client();
      final resolver = CinemaMovieResolver();
      expect(
        await resolver.resolve(
          client: client,
          itemId: '1',
          item: {
            'Type': 'Video',
            'ProviderIds': {'tmdb': '42'},
          },
        ),
        42,
      );
      expect(
        await resolver.resolve(
          client: client,
          itemId: '1',
          item: {
            'Type': 'Episode',
            'ProviderIds': {'Tmdb': '42'},
          },
        ),
        isNull,
      );
      expect(client.calls, 0);
      expect(
        CinemaMovieResolver.directMovieId({
          'ProviderIds': {'Tmdb': '-4'},
        }),
        isNull,
      );
    },
  );
  test(
    'only overlapping lookups deduplicate, scoped to server and user',
    () async {
      final client = _Client();
      final resolver = CinemaMovieResolver();
      Future<int?> resolve() =>
          resolver.resolve(client: client, itemId: 'intro', item: {});
      final a = resolve();
      final b = resolve();
      expect(client.calls, 1);
      client.reply.complete(42);
      expect(await a, 42);
      expect(await b, 42);
      client.reply = Completer();
      final c = resolve();
      expect(client.calls, 2);
      client.userId = 'other';
      final d = resolve();
      expect(client.calls, 3);
      client.reply.complete(43);
      expect(await c, 43);
      expect(await d, 43);
    },
  );
  test(
    'failures clean up in-flight lookups and unsupported servers return null',
    () async {
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
    },
  );
}
