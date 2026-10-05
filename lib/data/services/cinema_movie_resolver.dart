import 'package:server_core/server_core.dart';

/// Only overlapping requests are retained. Completed lookups are never cached.
class CinemaMovieResolver {
  final _inFlight = <(String, String?, String?, String), Future<int?>>{};

  static bool isMovieCompatible(Map<String, dynamic> item) => const {
    'movie',
    'video',
    'trailer',
    '',
  }.contains((item['Type']?.toString() ?? '').toLowerCase());

  static int? directMovieId(Map<String, dynamic> item) {
    if (!isMovieCompatible(item)) return null;
    final ids = item['ProviderIds'];
    if (ids is! Map) return null;
    for (final entry in ids.entries) {
      if (entry.key.toString().toLowerCase() != 'tmdb') continue;
      final id = int.tryParse(entry.value.toString());
      return id != null && id > 0 ? id : null;
    }
    return null;
  }

  Future<int?> resolve({
    required MediaServerClient client,
    required String itemId,
    required Map<String, dynamic> item,
  }) {
    if (!isMovieCompatible(item)) return Future.value();
    final direct = directMovieId(item);
    if (direct != null) return Future.value(direct);
    final key = (client.baseUrl, client.userId, client.accessToken, itemId);
    return _inFlight.putIfAbsent(key, () async {
      try {
        final id = await client
            .resolveCinemaMovie(itemId)
            .timeout(const Duration(seconds: 10));
        return id != null && id > 0 ? id : null;
      } catch (_) {
        // Older Moonbase, unsupported servers, no match and errors all leave Skip usable.
        return null;
      } finally {
        _inFlight.remove(key);
      }
    });
  }
}
