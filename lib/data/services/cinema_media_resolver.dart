import 'package:server_core/server_core.dart';

/// Finds which movie or TV show a trailer belongs to, using its metadata or a server lookup.
abstract final class CinemaMediaResolver {
  static bool _supported(Map<String, dynamic> item) => {
    'movie',
    'series',
    'video',
    'trailer',
    '',
  }.contains((item['Type']?.toString() ?? '').toLowerCase());

  static CinemaMediaType? _featureType(Map<String, dynamic> item) =>
      switch (item['__moonfinCinemaFeatureType']) {
        'Movie' => CinemaMediaType.movie,
        'Episode' => CinemaMediaType.tv,
        _ => null,
      };

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
    final types = {?explicit, ?itemType};
    if (types.length > 1) return null;
    // Only treat a TMDB ID without a media type as a movie when this trailer plays before a
    // movie. Never guess that it belongs to a show.
    final type = types.isNotEmpty
        ? types.single
        : (_featureType(item) == CinemaMediaType.movie ? 'movie' : null);
    if (type == null) return null;
    // If a trailer is attached to another item, let the server identify its parent.
    final owner = item['OwnerId']?.toString().replaceAll('-', '');
    if (owner != null &&
        owner.isNotEmpty &&
        owner != '00000000000000000000000000000000') {
      return null;
    }
    return CinemaMedia.fromJson({
      'tmdbId': ids['tmdb'],
      'mediaType': type,
    });
  }

  static Future<CinemaMedia?> resolve({
    required MediaServerClient client,
    required String itemId,
    required Map<String, dynamic> item,
  }) async {
    if (!_supported(item)) return null;
    final direct = directMedia(item);
    if (direct != null) return direct;
    final type = _featureType(item);
    try {
      final media = await client
          .resolveCinemaMedia(itemId, expectedMediaType: type)
          .timeout(const Duration(seconds: 10));
      return media != null && media.tmdbId > 0 ? media : null;
    } catch (_) {
      // If the server cannot identify the trailer, leave it unmatched rather than guessing
      // whether it is a movie or show.
      return null;
    }
  }
}
