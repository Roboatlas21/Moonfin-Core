import 'package:server_core/server_core.dart';

/// A search can have useful results even when a provider failed.
class GuideProgramSearchPartialException implements Exception {
  final List<GuideTitleMatch> matches;
  final Object cause;

  const GuideProgramSearchPartialException(this.matches, this.cause);
}

class GuideTitleMatch {
  final String channelId;
  final String? programId;
  final String title;
  final DateTime start;
  final DateTime end;
  // Null means this classification was not supplied by the search response.
  final bool? isMovie;
  final bool? isSeries;
  final bool? isSports;
  final bool? isNews;
  final bool? isKids;
  final bool? isPremiere;

  const GuideTitleMatch({
    required this.channelId,
    this.programId,
    required this.title,
    required this.start,
    required this.end,
    this.isMovie,
    this.isSeries,
    this.isSports,
    this.isNews,
    this.isKids,
    this.isPremiere,
  });
}

/// Merge incomplete searches without repeating the same program.
/// The newer result wins if a showing's metadata has changed.
List<GuideTitleMatch> mergeGuideTitleMatches(
  List<GuideTitleMatch> earlier,
  List<GuideTitleMatch> newer,
) {
  final byShowing = <Object, GuideTitleMatch>{};
  Object key(GuideTitleMatch match) => match.programId != null
      ? (match.channelId, match.programId)
      : (match.channelId, match.title, match.start, match.end);
  for (final match in earlier) {
    byShowing[key(match)] = match;
  }
  for (final match in newer) {
    byShowing[key(match)] = match;
  }
  return byShowing.values.toList();
}

Set<String> programChannelsInWindow(
  List<GuideTitleMatch> matches,
  DateTime start,
  DateTime end,
) => {
  for (final match in matches)
    if (match.start.isBefore(end) && match.end.isAfter(start))
      match.channelId,
};

// The mobile list only shows Now and Next. Find the earliest later match
// without repeating a program the card already displays.
GuideTitleMatch? laterProgramSearchMatch(
  List<GuideTitleMatch> matches, {
  required String channelId,
  required DateTime windowStart,
  required DateTime windowEnd,
  required DateTime now,
  DateTime? currentStart,
  DateTime? nextStart,
}) {
  GuideTitleMatch? later;
  for (final match in matches) {
    if (match.channelId != channelId ||
        !match.start.isBefore(windowEnd) ||
        !match.end.isAfter(windowStart)) {
      continue;
    }
    if ((currentStart != null && match.start.isAtSameMomentAs(currentStart)) ||
        (nextStart != null && match.start.isAtSameMomentAs(nextStart))) {
      return null;
    }
    if (!match.start.isAfter(now) ||
        (nextStart != null && !match.start.isAfter(nextStart))) {
      continue;
    }
    if (later == null || match.start.isBefore(later.start)) later = match;
  }
  return later;
}

/// Jellyfin and Emby search the item index; Plex searches its DVR provider.
Future<List<GuideTitleMatch>> searchGuideProgramTitles(
  MediaServerClient client,
  String query, {
  required bool Function() isCurrent,
  void Function(List<GuideTitleMatch>)? onPartialResults,
}) async {
  final term = query.trim();
  if (term.length < 2) return const [];
  final foldedTerm = term.toLowerCase();
  final programTypes = switch (client.serverType) {
    ServerType.jellyfin => const ['LiveTvProgram'],
    ServerType.emby => const ['Program'],
    _ => null,
  };
  const pageSize = 200;
  final results = <GuideTitleMatch>[];
  final seen = <String>{};

  void addItems(List items) {
    for (final raw in items) {
      if (raw is! Map) continue;
      if (raw['Type'] != 'LiveTvProgram' && raw['Type'] != 'Program') {
        continue;
      }
      final id = raw['Id']?.toString();
      final channelId = raw['ChannelId']?.toString();
      final name = raw['Name']?.toString().trim() ?? '';
      final episode = raw['EpisodeTitle']?.toString().trim() ?? '';
      final start = parseServerDate(raw['StartDate'])?.toLocal();
      final end = parseServerDate(raw['EndDate'])?.toLocal();
      if (id == null ||
          id.isEmpty ||
          channelId == null ||
          channelId.isEmpty ||
          (!name.toLowerCase().contains(foldedTerm) &&
              !episode.toLowerCase().contains(foldedTerm)) ||
          start == null ||
          end == null ||
          !end.isAfter(start) ||
          !seen.add(id)) {
        continue;
      }
      final title = [
        if (name.isNotEmpty) name,
        if (episode.isNotEmpty && episode != name) episode,
      ].join(' · ');
      results.add(GuideTitleMatch(
        channelId: channelId,
        programId: id,
        title: title,
        start: start,
        end: end,
        isMovie: raw['IsMovie'] is bool ? raw['IsMovie'] as bool : null,
        isSeries: raw['IsSeries'] is bool ? raw['IsSeries'] as bool : null,
        isSports: raw['IsSports'] is bool ? raw['IsSports'] as bool : null,
        isNews: raw['IsNews'] is bool ? raw['IsNews'] as bool : null,
        isKids: raw['IsKids'] is bool ? raw['IsKids'] as bool : null,
        isPremiere: raw['IsPremiere'] is bool ? raw['IsPremiere'] as bool : null,
      ));
    }
  }

  List<GuideTitleMatch> incomplete(
    LiveTvPartialProgramSearchException error,
  ) {
    if (!isCurrent()) return const [];
    addItems(error.results);
    throw GuideProgramSearchPartialException(
      List<GuideTitleMatch>.unmodifiable(results),
      error.cause,
    );
  }

  final searchApi = client.liveTvApi;
  if (searchApi is LiveTvIncrementalProgramSearchApi &&
      onPartialResults != null) {
    try {
      final rows = await searchApi.searchProgramTitlesIncrementally(
        term,
        isCurrent: isCurrent,
        onBatch: (batch) {
          if (!isCurrent()) return;
          final before = results.length;
          addItems(batch);
          if (results.length > before) {
            onPartialResults(List<GuideTitleMatch>.of(results));
          }
        },
      );
      if (!isCurrent()) return const [];
      addItems(rows);
      return results;
    } on LiveTvPartialProgramSearchException catch (error) {
      return incomplete(error);
    }
  }
  if (searchApi is LiveTvProgramSearchApi) {
    try {
      final rows = await searchApi.searchProgramTitles(
        term, isCurrent: isCurrent,
      );
      if (!isCurrent()) return const [];
      addItems(rows);
      return results;
    } on LiveTvPartialProgramSearchException catch (error) {
      return incomplete(error);
    }
  }
  if (client.serverType == ServerType.plex ||
      client.serverType == ServerType.silo) {
    return const [];
  }

  var offset = 0;
  String? previousPage;
  try {
    while (isCurrent()) {
      final response = await client.itemsApi.getItems(
        searchTerm: term,
        includeItemTypes: programTypes,
        recursive: true,
        startIndex: offset,
        limit: pageSize,
      );
      if (!isCurrent()) return const [];
      final items = response['Items'] as List? ?? const [];
      final total = response['TotalRecordCount'];
      if (items.isEmpty) {
        if (total is num && total > offset) {
          throw StateError('Program search returned an incomplete page');
        }
        break;
      }

      // An ignored pagination offset must not produce silent partial results.
      final signature = [
        for (final raw in items)
          if (raw is Map) raw['Id']?.toString() ?? '',
      ].join(',');
      if (signature == previousPage) {
        throw StateError('Program search pagination did not advance');
      }
      previousPage = signature;

      final before = results.length;
      addItems(items);
      offset += items.length;
      if (results.length > before && isCurrent()) {
        onPartialResults?.call(List<GuideTitleMatch>.unmodifiable(results));
      }
      if (total is num && total > 0) {
        if (offset >= total) break;
      } else if (items.length < pageSize) {
        break;
      }
    }
  } catch (error) {
    if (!isCurrent()) return const [];
    if (offset > 0) {
      throw GuideProgramSearchPartialException(
        List<GuideTitleMatch>.unmodifiable(results),
        error,
      );
    }
    rethrow;
  }
  return isCurrent() ? results : const [];
}
