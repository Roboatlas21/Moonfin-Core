import 'dart:async';

import 'package:dio/dio.dart';
import 'package:server_core/server_core.dart';

class EmbyLiveTvApi
    implements LiveTvApi, DirectChannelGroupApi, ProgrammeCategoryApi {
  final Dio _dio;
  static const _postChannelIdsThreshold = 1800;
  static const _categoryFlags = <String, String>{
    'movies': 'IsMovie',
    'series': 'IsSeries',
    'sports': 'IsSports',
    'news': 'IsNews',
    'kids': 'IsKids',
    'premiere': 'IsPremiere',
  };
  ({
    String? userId,
    DateTime from,
    DateTime to,
    DateTime expiresAt,
    Future<Set<String>?> future,
  })? _categoryCache;

  EmbyLiveTvApi(this._dio);

  @override
  Future<Set<String>?> getProgrammeCategories({
    required DateTime from,
    required DateTime to,
    String? userId,
  }) {
    final start = from.toUtc();
    final end = to.toUtc();
    final cached = _categoryCache;
    if (cached != null &&
        cached.userId == userId &&
        cached.from == start &&
        cached.to == end &&
        DateTime.now().isBefore(cached.expiresAt)) {
      return cached.future;
    }
    final future = _queryProgrammeCategories(start, end, userId);
    _categoryCache = (
      userId: userId,
      from: start,
      to: end,
      expiresAt: DateTime.now().add(const Duration(minutes: 5)),
      future: future,
    );
    // Failed probes aren't cached: the next guide reload can try again.
    unawaited(future.then((value) {
      if (value == null && identical(_categoryCache?.future, future)) {
        _categoryCache = null;
      }
    }));
    return future;
  }

  Future<Set<String>?> _queryProgrammeCategories(
    DateTime from,
    DateTime to,
    String? userId,
  ) async {
    try {
      final matches = await Future.wait(
        _categoryFlags.entries.map((category) async {
          final response = await _dio.get(
            '/LiveTv/Programs',
            queryParameters: {
              'UserId': ?userId,
              'MinEndDate': from.toIso8601String(),
              'MaxStartDate': to.toIso8601String(),
              'Limit': 1,
              'EnableTotalRecordCount': false,
              'EnableImages': false,
              'EnableUserData': false,
              category.value: true,
            },
            options: Options(receiveTimeout: const Duration(seconds: 4)),
          );
          final body = response.data;
          final items = body is Map ? body['Items'] : null;
          if (items is! List) {
            throw const FormatException('Invalid Emby program category reply');
          }
          return items.isEmpty ? null : category.key;
        }),
      );
      return matches.whereType<String>().toSet();
    } catch (_) {
      // Unknown must not be treated as an empty EPG.
      return null;
    }
  }

  /// Emby exposes M3U groups (and other channel labels) as ordinary tags.
  /// The normal, user-scoped channel response is enough; Moonbase is not needed.
  @override
  Future<ChannelGroupLineup> getChannelGroups({String? userId}) async {
    final response = await getChannels(
      sortBy: 'SortName',
      sortOrder: 'Ascending',
      fields: 'ImageTags,UserData,Tags',
      enableTotalRecordCount: false,
      userId: userId,
    );
    final rawItems = response['Items'];
    if (rawItems is! List) {
      throw const FormatException('Invalid Emby Live TV channel response');
    }
    final channels = <Map<String, dynamic>>[];
    for (final item in rawItems) {
      if (item is! Map<String, dynamic> ||
          item['Id'] is! String ||
          (item['Id'] as String).isEmpty ||
          item['Name'] is! String) {
        throw const FormatException('Invalid Emby Live TV channel');
      }
      channels.add(item);
    }
    Set<String> nonEmptyNames(Iterable<dynamic> values) => {
      for (final name in values)
        if (name is String && name.trim().isNotEmpty) name.trim(),
    };
    final groups = <String, Set<String>>{};
    for (final channel in channels) {
      final id = channel['Id'];
      if (id is! String || id.isEmpty) continue;

      final tagItems = channel['TagItems'];
      final names = tagItems is List
          ? nonEmptyNames(
              tagItems.map((item) => item is Map ? item['Name'] : null),
            )
          : <String>{};
      // Preserve the complete TagItems labels, including vertical bars.
      if (names.isEmpty && channel['Tags'] is List) {
        names.addAll(nonEmptyNames(channel['Tags'] as List));
      }
      if (names.isNotEmpty) groups[id] = names;
    }
    return ChannelGroupLineup(groups, channels: channels);
  }

  @override
  Future<Map<String, dynamic>> getChannels({
    int? startIndex,
    int? limit,
    String? sortBy,
    String? sortOrder,
    String? fields,
    bool? enableTotalRecordCount,
    String? userId,
  }) async {
    final response = await _dio.get('/LiveTv/Channels', queryParameters: {
      'StartIndex': ?startIndex,
      'Limit': ?limit,
      'SortBy': ?sortBy,
      'SortOrder': ?sortOrder,
      'Fields': ?fields,
      'EnableTotalRecordCount': ?enableTotalRecordCount,
      'UserId': ?userId,
    });
    return response.data as Map<String, dynamic>;
  }

  @override
  Future<Map<String, dynamic>> getGuide({
    DateTime? startDate,
    DateTime? endDate,
    List<String>? channelIds,
    bool? isMovie,
    bool? isSeries,
    bool? isSports,
    bool? isNews,
    bool? isKids,
    String? fields,
    bool? enableTotalRecordCount,
    bool? enableImages,
    bool? enableUserData,
    String? userId,
  }) async {
    final ids =
        (channelIds != null && channelIds.isNotEmpty) ? channelIds : null;
    final joined = ids?.join(',');
    final usePost = joined != null && joined.length > _postChannelIdsThreshold;

    // EnableImages/EnableUserData are off for the guide to keep the per-program
    // payload small (issue #666). Channel logos come from /LiveTv/Channels, not
    // this response, so they are unaffected.
    final common = <String, dynamic>{
      if (startDate != null) 'MinEndDate': startDate.toUtc().toIso8601String(),
      if (endDate != null) 'MaxStartDate': endDate.toUtc().toIso8601String(),
      'IsMovie': ?isMovie,
      'IsSeries': ?isSeries,
      'IsSports': ?isSports,
      'IsNews': ?isNews,
      'IsKids': ?isKids,
      'Fields': ?fields,
      'EnableTotalRecordCount': ?enableTotalRecordCount,
      'EnableImages': ?enableImages,
      'EnableUserData': ?enableUserData,
      'UserId': ?userId,
    };

    // POST needs ChannelIds as a JSON array (Jellyfin GetProgramsDto and remux
    // GetProgramsBody both type it as a GUID list); a comma string is rejected
    // by strict servers. GET uses the conventional comma form.
    final Response response;
    if (usePost) {
      response = await _dio.post('/LiveTv/Programs', data: {
        ...common,
        'ChannelIds': ids,
      });
    } else {
      response = await _dio.get('/LiveTv/Programs', queryParameters: {
        ...common,
        'ChannelIds': ?joined,
      });
    }
    return response.data as Map<String, dynamic>;
  }

  @override
  Future<Map<String, dynamic>> getRecommendedPrograms({
    int? limit,
    bool? isAiring,
  }) async {
    final response = await _dio.get(
      '/LiveTv/Programs/Recommended',
      queryParameters: {'Limit': ?limit, 'IsAiring': ?isAiring},
    );
    return response.data as Map<String, dynamic>;
  }

  @override
  Future<Map<String, dynamic>> getProgram(
    String programId, {
    String? userId,
  }) async {
    final response = await _dio.get(
      '/LiveTv/Programs/${Uri.encodeComponent(programId)}',
      queryParameters: {'UserId': ?userId},
    );
    return response.data as Map<String, dynamic>;
  }

  @override
  Future<Map<String, dynamic>> getRecordings({
    int? limit,
    String? fields,
    bool? enableImages,
    bool? isSeries,
    bool? isMovie,
    bool? isSports,
    bool? isKids,
  }) async {
    final response = await _dio.get('/LiveTv/Recordings', queryParameters: {
      'Limit': ?limit,
      'Fields': ?fields,
      'EnableImages': ?enableImages,
      'IsSeries': ?isSeries,
      'IsMovie': ?isMovie,
      'IsSports': ?isSports,
      'IsKids': ?isKids,
    });
    return response.data as Map<String, dynamic>;
  }

  @override
  Future<Map<String, dynamic>> getTimers() async {
    final response = await _dio.get('/LiveTv/Timers');
    return response.data as Map<String, dynamic>;
  }

  @override
  Future<Map<String, dynamic>> getSeriesTimers() async {
    final response = await _dio.get('/LiveTv/SeriesTimers');
    return response.data as Map<String, dynamic>;
  }

  @override
  Future<void> createTimer(String programId) async {
    await _dio.post('/LiveTv/Timers', data: await _timerDefaults(programId));
  }

  @override
  Future<void> createSeriesTimer(
    String programId, {
    Map<String, dynamic>? settings,
  }) async {
    await _dio.post(
      '/LiveTv/SeriesTimers',
      data: {...await _timerDefaults(programId), ...?settings},
    );
  }

  @override
  Future<Map<String, dynamic>> getSeriesTimer(String seriesTimerId) async {
    final response = await _dio.get('/LiveTv/SeriesTimers/$seriesTimerId');
    return response.data as Map<String, dynamic>;
  }

  @override
  Future<void> updateSeriesTimer(
    String seriesTimerId,
    Map<String, dynamic> seriesTimer,
  ) async {
    await _dio.post('/LiveTv/SeriesTimers/$seriesTimerId', data: seriesTimer);
  }

  /// The server's own defaults for a program, which both kinds of timer post
  /// straight back. A server that wont hand them over still takes a bare
  /// program id.
  Future<Map<String, dynamic>> _timerDefaults(String programId) async {
    try {
      final defaults = await _dio.get(
        '/LiveTv/Timers/Defaults',
        queryParameters: {'ProgramId': programId},
      );
      final payload = Map<String, dynamic>.from(
        (defaults.data as Map?)?.cast<String, dynamic>() ??
            <String, dynamic>{},
      );
      return payload..putIfAbsent('ProgramId', () => programId);
    } catch (_) {
      return {'ProgramId': programId};
    }
  }

  @override
  Future<void> cancelTimer(String timerId) async {
    await _dio.delete('/LiveTv/Timers/$timerId');
  }

  @override
  Future<void> cancelSeriesTimer(String seriesTimerId) async {
    await _dio.delete('/LiveTv/SeriesTimers/$seriesTimerId');
  }
}
