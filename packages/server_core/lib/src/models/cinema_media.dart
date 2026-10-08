/// A TMDB ID is only meaningful together with its movie/TV namespace.
enum CinemaMediaType { movie, tv }

class CinemaMedia {
  const CinemaMedia(this.tmdbId, this.type);

  final int tmdbId;
  final CinemaMediaType type;

  static CinemaMedia? fromJson(Map data) {
    final id = int.tryParse(data['tmdbId']?.toString() ?? '');
    final type = switch (data['mediaType']) {
      'movie' => CinemaMediaType.movie,
      'tv' => CinemaMediaType.tv,
      _ => null,
    };
    if (id == null || id <= 0 || type == null) return null;
    return CinemaMedia(id, type);
  }
}
