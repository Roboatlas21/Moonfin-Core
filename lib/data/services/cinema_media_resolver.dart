import 'package:server_core/server_core.dart';

/// Resolves typed identities from metadata or the optional server endpoint.
abstract final class CinemaMediaResolver {
  static bool _supported(Map<String, dynamic> item) => {
    'movie',
    'series',
    'video',
    'trailer',
    '',
  }.contains((item['Type']?.toString() ?? '').toLowerCase());

  static CinemaMedia? directMedia(Map<String, dynamic> item) {
    if (!_supported(item)) return null;
    final raw = item['ProviderIds'];
    if (raw is! Map) return null;
    final ids = {
      for (final entry in raw.entries)
        entry.key.toString().toLowerCase(): entry.value?.toString(),
    };
    final explicit = ids['tmdbmediatype'];
    if (explicit != null && explicit != 'movie' && explicit != 'tv') {
      return null;
    }
    final itemType = switch (item['Type']?.toString().toLowerCase()) {
      'movie' => 'movie',
      'series' => 'tv',
      _ => null,
    };
    // Enhanced downloaded movie trailers carry TMDB + this provider marker,
    // so they work even without the optional Moonbase identity endpoint.
    final legacy =
        explicit == null && ids.containsKey('trailers4jellyfin.trailer')
        ? 'movie'
        : null;
    final types = {?explicit, ?itemType, ?legacy};
    if (types.length != 1) return null;
    // Attached trailers must have their owner checked on the source server.
    final owner = item['OwnerId']?.toString().replaceAll('-', '');
    if (owner != null &&
        owner.isNotEmpty &&
        owner != '00000000000000000000000000000000') {
      return null;
    }
    return CinemaMedia.fromJson({
      'tmdbId': ids['tmdb'],
      'mediaType': types.single,
    });
  }

  static Future<CinemaMedia?> resolve({
    required MediaServerClient client,
    required String itemId,
    required Map<String, dynamic> item,
    CinemaMediaType? expectedMediaType,
  }) async {
    if (!_supported(item)) return null;
    final direct = directMedia(item);
    if (direct != null) return direct;
    final type = expectedMediaType ?? switch (item['__moonfinCinemaFeatureType']) {
      'Movie' => CinemaMediaType.movie,
      'Episode' => CinemaMediaType.tv,
      _ => null,
    };
    try {
      final media = await client
          .resolveCinemaMedia(itemId, expectedMediaType: type)
          .timeout(const Duration(seconds: 10));
      return media != null && media.tmdbId > 0 ? media : null;
    } catch (_) {
      // Includes older plugins without the typed endpoint. Never reinterpret
      // an untyped legacy result as a movie or a series.
      return null;
    }
  }
}
