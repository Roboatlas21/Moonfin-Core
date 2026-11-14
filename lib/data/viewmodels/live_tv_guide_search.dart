import 'package:server_core/server_core.dart';

typedef GuideTitleMatch = ({
  String channelId,
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

/// Jellyfin and Emby search the item index; Plex searches its DVR provider.
Future<List<GuideTitleMatch>> searchGuideProgramTitles(
  MediaServerClient client,
  String query, {
  required bool Function() isCurrent,
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
      final name = raw['Name']?.toString().toLowerCase() ?? '';
      final episode = raw['EpisodeTitle']?.toString().toLowerCase() ?? '';
      final start = parseServerDate(raw['StartDate'])?.toLocal();
      final end = parseServerDate(raw['EndDate'])?.toLocal();
      if (id == null ||
          id.isEmpty ||
          channelId == null ||
          channelId.isEmpty ||
          (!name.contains(foldedTerm) && !episode.contains(foldedTerm)) ||
          start == null ||
          end == null ||
          !end.isAfter(start) ||
          !seen.add(id)) {
        continue;
      }
      results.add((channelId: channelId, start: start, end: end));
    }
  }

  final searchApi = client.liveTvApi;
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
