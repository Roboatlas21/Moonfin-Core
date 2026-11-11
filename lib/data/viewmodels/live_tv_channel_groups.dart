/// Resolves channel group metadata from Moonbase and older server channel tags.
///
/// The Moonbase response carries the original ChannelGroup and takes priority
/// over Tags (which Jellyfin can split on the literal '|' character). Emby and
/// existing tuner plugins can still supply tags when Moonbase isn't installed.
Map<String, List<String>> resolveLiveTvChannelGroups(
  List<Map<String, dynamic>> channels,
  Map<String, dynamic>? moonbase,
) {
  final actualIds = <String, String>{
    for (final channel in channels)
      if (channel['Id']?.toString().isNotEmpty == true)
        _groupChannelId(channel['Id'].toString()): channel['Id'].toString(),
  };
  final fromMoonbase = <String, Set<String>>{};

  final entries = moonbase?['Channels'] ?? moonbase?['channels'];
  for (final entry in (entries is List ? entries : const [])) {
    if (entry is! Map) continue;
    final rawId = entry['ChannelId'] ?? entry['channelId'];
    final id = actualIds[_groupChannelId(rawId?.toString() ?? '')];
    final group = entry['Group'] ?? entry['group'];
    if (id == null || group is! String || group.trim().isEmpty) continue;
    // Preserve spaces around pipes exactly: "US| SPORTS" is one group.
    fromMoonbase.putIfAbsent(id, () => <String>{}).add(group);
  }

  return {
    for (final channel in channels)
      if (channel['Id'] != null)
        channel['Id'].toString(): [
          ...(fromMoonbase[channel['Id'].toString()] ??
              _channelGroupsFromTags(channel['Tags'])),
        ],
  }..removeWhere((_, groups) => groups.isEmpty);
}

String _groupChannelId(String value) =>
    value.replaceAll('-', '').toLowerCase();

List<String> _channelGroupsFromTags(Object? value) {
  if (value is! List) return const [];
  final tags = <String>[];
  for (final raw in value) {
    if (raw is! String || raw.trim().isEmpty) continue;
    // Older Jellyfin versions serialise Tags as a pipe-joined string. A
    // whitespace-adjacent pipe is recoverable without altering ordinary tags.
    if (tags.isNotEmpty &&
        (raw.startsWith(' ') || tags.last.endsWith(' '))) {
      tags[tags.length - 1] = '${tags.last}|$raw';
    } else {
      tags.add(raw);
    }
  }
  return tags.toSet().toList();
}
