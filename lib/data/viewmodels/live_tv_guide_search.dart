import 'package:server_core/server_core.dart';

typedef GuideTitleMatch = ({
  String channelId,
  String title,
  DateTime start,
  DateTime end,
});

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
      results.add((
        channelId: channelId,
        title: title,
        start: start,
        end: end,
      ));
    }
  }

  final searchApi = client.liveTvApi;
  if (searchApi is LiveTvIncrementalProgramSearchApi &&
      onPartialResults != null) {
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
  }
  if (searchApi is LiveTvProgramSearchApi) {
    final rows = await searchApi.searchProgramTitles(term, isCurrent: isCurrent);
    if (!isCurrent()) return const [];
    addItems(rows);
    return results;
  }
  if (client.serverType == ServerType.plex ||
      client.serverType == ServerType.silo) {
    return const [];
  }

  var offset = 0;
  String? previousPage;
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

    // Fail rather than silently show incomplete results if a server ignores
    // the pagination offset.
    final signature = [
      for (final raw in items)
        if (raw is Map) raw['Id']?.toString() ?? '',
    ].join(',');
    if (signature == previousPage) {
      throw StateError('Program search pagination did not advance');
    }
    previousPage = signature;

    addItems(items);

    offset += items.length;
    if (total is num && total > 0) {
      if (offset >= total) break;
    } else if (items.length < pageSize) {
      break;
    }
  }
  return isCurrent() ? results : const [];
}
