import 'dart:convert';

import 'language_matching.dart';

List<Map<String, dynamic>> rankSecondarySubtitleStreams(
  List<Map<String, dynamic>> streams,
  String preferredLanguage,
) {
  final ranked = List<Map<String, dynamic>>.of(streams);
  final preferred = normalizeLanguage(preferredLanguage);
  if (preferred.isEmpty) return ranked;
  final preferredIso3 = toIso3Language(preferred);
  bool matches(Map<String, dynamic> stream) => languageMatchesPreferred(
    stream['Language'] as String?,
    preferred,
    preferredIso3,
  );
  return [
    ...ranked.where(matches),
    ...ranked.where((stream) => !matches(stream)),
  ];
}

Map<String, dynamic> secondarySubtitleTrackSelection(
  List<Map<String, dynamic>> streams,
  int? index,
) {
  if (index == null || index < 0) return const {'off': true};
  final ordinal = streams.indexWhere((s) => s['Index'] == index);
  if (ordinal < 0) return const {'off': true};
  final stream = streams[ordinal];
  final identity = _identity(stream);
  return {'index': index, 'ordinal': ordinal, 'identity': identity};
}

int? restoreSecondarySubtitleTrack(
  Map<String, dynamic>? saved,
  List<Map<String, dynamic>> streams, {
  required bool Function(Map<String, dynamic>) isCompatible,
}) {
  if (saved == null) return null;
  if (saved['off'] == true) return -1;
  final rawIdentity = saved['identity'];
  if (rawIdentity is! Map) return -1;
  final identity = rawIdentity.cast<String, dynamic>();
  if (identity.isEmpty) return -1;
  final signature = jsonEncode(identity);
  final candidates = streams.where(isCompatible).toList();
  final savedIndex = saved['index'] as int?;
  for (final stream in candidates) {
    if (stream['Index'] == savedIndex && _signature(stream) == signature) {
      return savedIndex;
    }
  }
  final matchingStreams = candidates
      .where((s) => _signature(s) == signature)
      .toList();
  if (matchingStreams.length == 1) {
    return matchingStreams.single['Index'] as int?;
  }
  final ordinal = saved['ordinal'] as int?;
  if (ordinal != null && ordinal >= 0 && ordinal < streams.length) {
    final stream = streams[ordinal];
    if (isCompatible(stream) && _signature(stream) == signature) {
      return stream['Index'] as int?;
    }
  }

  // Earlier downloads saved the local SRT/WebVTT sidecar identity. Newer
  // downloads expose the originating stream instead. Accept a legacy choice
  // only when the source title, language and normalized codec still agree.
  final legacyMatches = candidates
      .where((stream) => _matchesLegacyDownloadIdentity(identity, stream))
      .toList();
  final sameIndex = legacyMatches.where((s) => s['Index'] == savedIndex).toList();
  if (sameIndex.length == 1) return sameIndex.single['Index'] as int?;
  if (legacyMatches.length == 1) return legacyMatches.single['Index'] as int?;
  return -1;
}

Map<String, dynamic> _identity(Map<String, dynamic> stream) {
  // Transcoded downloads expose different playable codec/delivery fields,
  // but retain the originating server stream for identity matching only.
  final original = stream['OriginalSubtitleStream'];
  final source = original is Map ? original : stream;
  return {
    for (final key in const [
      'Language',
      'Title',
      'DisplayTitle',
      'Codec',
      'IsExternal',
      'IsForced',
      'IsHearingImpaired',
    ])
      if (source[key] != null) key: source[key],
  };
}

String _signature(Map<String, dynamic> stream) => jsonEncode(_identity(stream));

bool _matchesLegacyDownloadIdentity(
  Map<String, dynamic> saved,
  Map<String, dynamic> stream,
) {
  // This shape was written by transcoded downloads before they carried
  // OriginalSubtitleStream. Other identities must continue matching exactly.
  if (saved['IsExternal'] != true ||
      saved.keys.any((key) => !const {
        'Language',
        'Title',
        'Codec',
        'IsExternal',
      }.contains(key))) {
    return false;
  }
  final title = saved['Title'];
  final codec = _canonicalTextCodec(saved['Codec']);
  if (title is! String || title.trim().isEmpty || codec == null) return false;
  final original = stream['OriginalSubtitleStream'];
  final source = original is Map ? original : stream;
  if (_canonicalTextCodec(source['Codec']) != codec ||
      source['Language'] != saved['Language']) {
    return false;
  }
  final originalTitle = source['DisplayTitle'] ?? source['Title'];
  return originalTitle == title;
}

String? _canonicalTextCodec(Object? codec) => switch (
    codec?.toString().trim().toLowerCase()) {
  'srt' || 'subrip' => 'srt',
  'vtt' || 'webvtt' => 'vtt',
  _ => null,
};
