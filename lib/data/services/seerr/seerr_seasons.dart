import 'seerr_api_models.dart';

/// The season numbers a series actually has.
///
/// A provider that splits a run differently, like TVDB for anime, reports its
/// own season numbers, so counting off from one would offer seasons that
/// aren't there and request the wrong ones. The count is only a fallback for a
/// server that sends no season list.
List<int> seerrSeasonNumbersOf(List<SeerrSeason> seasons, int fallbackCount) {
  final reported = seasons
      .where((s) => s.seasonNumber > 0)
      .map((s) => s.seasonNumber)
      .toList();
  if (reported.isNotEmpty) return reported;
  return List.generate(fallbackCount, (i) => i + 1);
}

/// Seerr TV quota is measured in requested seasons, not series.
int seerrTvQuotaNeeded({
  required bool allSeasons,
  required Iterable<int> requestableSeasons,
  required Iterable<int> selectedSeasons,
}) => allSeasons
    ? requestableSeasons.toSet().length
    : selectedSeasons.toSet().length;

/// Quota unavailability must not prevent requests; Seerr remains authoritative.
bool seerrQuotaBlocked(SeerrQuotaDetail? quota, int needed) {
  if (quota == null || quota.isUnlimited) return false;
  return quota.restricted ||
      (quota.remaining != null && needed > quota.remaining!);
}
