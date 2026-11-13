import 'dart:async';

import 'package:dio/dio.dart';

/// Reads the grouped Live TV lineup from the server's supported source.
abstract interface class ChannelGroupApi {
  Future<ChannelGroupLineup> getChannelGroups({String? userId});
}

/// Groups and channels come from the same mandatory request, not an optional
/// plugin. An error must be reported rather than retried as a separate lineup.
abstract interface class DirectChannelGroupApi implements ChannelGroupApi {}

/// Checks the entire imported EPG, independently of the selected guide date.
/// Null means the check was unavailable, so the guide keeps all its filters.
abstract interface class ProgrammeCategoryApi {
  Future<Set<String>?> getProgrammeCategories({String? userId});
}

/// Runs six small category checks concurrently and caches the result per user.
/// Each server adapter supplies its own native API query.
class ProgrammeCategoryChecker {
  ProgrammeCategoryChecker(this._hasCategory);

  static const categories = [
    'movies', 'series', 'sports', 'news', 'kids', 'premiere',
  ];
  final Future<bool> Function(String category, String? userId) _hasCategory;
  ({String? userId, DateTime until, Future<Set<String>?> result})? _cached;

  Future<Set<String>?> check({String? userId}) {
    final cached = _cached;
    if (cached != null &&
        cached.userId == userId &&
        DateTime.now().isBefore(cached.until)) {
      return cached.result;
    }
    final result = _query(userId);
    _cached = (
      userId: userId,
      until: DateTime.now().add(const Duration(minutes: 15)),
      result: result,
    );
    // A failed check is unknown, not an empty EPG. Retry on the next load.
    unawaited(result.then((value) {
      if (value == null && identical(_cached?.result, result)) _cached = null;
    }));
    return result;
  }

  Future<Set<String>?> _query(String? userId) async {
    try {
      final found = await Future.wait([
        for (final category in categories)
          _hasCategory(category, userId).then(
            (present) => present ? category : null,
          ),
      ]);
      return found.whereType<String>().toSet();
    } catch (_) {
      return null;
    }
  }
}

class ChannelGroupLineup {
  final Map<String, Set<String>> groupsByChannelId;

  /// Channels this viewer can access, or null if only group data is available.
  final List<Map<String, dynamic>>? channels;
  final bool partial;

  /// False when an optional group source (such as Moonbase) is unavailable.
  final bool endpointAvailable;

  /// Channel IDs the tuner couldn't match in a partial response.
  final Set<String>? unresolvedChannelIds;

  const ChannelGroupLineup(
    this.groupsByChannelId, {
    this.channels,
    this.partial = false,
    this.endpointAvailable = true,
    this.unresolvedChannelIds,
  });

  static Future<ChannelGroupLineup> fetch(Dio dio) async {
    try {
      final response = await dio.get(
        '/Moonfin/LiveTv/ChannelGroups',
        options: Options(receiveTimeout: const Duration(seconds: 6)),
      );
      final data = response.data;
      if (data is! Map ||
          data['supported'] is! bool ||
          data['channels'] is! List) {
        throw const FormatException('Invalid channel group response');
      }
      final channels = <Map<String, dynamic>>[];
      final memberships = <String, Set<String>>{};
      Set<String> labels(List values) => {
        for (final value in values)
          if (value is String && value.trim().isNotEmpty) value.trim(),
      };
      for (final row in data['channels'] as List) {
        if (row is! Map<String, dynamic> ||
            row['Id'] is! String ||
            (row['Id'] as String).isEmpty ||
            row['Name'] is! String ||
            row['groups'] is! List) {
          throw const FormatException('Invalid guide channel');
        }
        channels.add(row);
        final groups = labels(row['groups'] as List);
        if (groups.isNotEmpty) memberships[row['Id'] as String] = groups;
      }
      final unresolved = data['unresolvedChannelIds'];
      return ChannelGroupLineup(
        memberships,
        channels: channels,
        partial: data['partial'] == true,
        unresolvedChannelIds:
            unresolved is List && unresolved.every((id) => id is String)
            ? unresolved.cast<String>().toSet()
            : null,
      );
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) {
        return const ChannelGroupLineup({}, endpointAvailable: false);
      }
      rethrow;
    }
  }
}

abstract class LiveTvApi {
  Future<Map<String, dynamic>> getChannels({
    int? startIndex,
    int? limit,
    String? sortBy,
    String? sortOrder,
    String? fields,
    bool? enableTotalRecordCount,
    String? userId,
  });

  /// A genre flag ([isMovie], [isSeries], [isSports], [isNews], [isKids]) makes
  /// the server return only that genre's programs for the given [channelIds],
  /// so the guide's category chips can walk the lineup in large batches
  /// without pulling every program. Omitting [channelIds] searches every
  /// channel; the guide does not use that form.
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
  });

  /// [isAiring] has to be true for the server to recommend anything. Without
  /// it the endpoint falls back to a plain guide listing sorted by start date,
  /// which is neither filtered to what is on right now nor ranked.
  Future<Map<String, dynamic>> getRecommendedPrograms({
    int? limit,
    bool? isAiring,
  });

  /// A single program, images enabled. [getGuide] disables images for its
  /// whole batch to keep the payload small (issue #666), which also means a
  /// program's own `ImageTags` never comes back from it even when the server
  /// has one on file — this is the only call that can see it.
  Future<Map<String, dynamic>> getProgram(String programId, {String? userId});

  Future<Map<String, dynamic>> getRecordings({
    int? limit,
    String? fields,
    bool? enableImages,
    bool? isSeries,
    bool? isMovie,
    bool? isSports,
    bool? isKids,
  });

  Future<Map<String, dynamic>> getTimers();

  Future<Map<String, dynamic>> getSeriesTimers();

  Future<void> createTimer(String programId);

  /// Records every showing of a program's series, not just this one.
  /// [settings] replaces fields of the server's defaults for the new rule,
  /// such as `RecordNewOnly`.
  Future<void> createSeriesTimer(
    String programId, {
    Map<String, dynamic>? settings,
  });

  Future<Map<String, dynamic>> getSeriesTimer(String seriesTimerId);

  /// The server replaces every field of the rule with [seriesTimer], so pass
  /// the whole rule from [getSeriesTimer] with only the changed fields altered.
  Future<void> updateSeriesTimer(
    String seriesTimerId,
    Map<String, dynamic> seriesTimer,
  );

  Future<void> cancelTimer(String timerId);

  Future<void> cancelSeriesTimer(String seriesTimerId);
}
