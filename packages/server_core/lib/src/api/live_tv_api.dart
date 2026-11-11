import 'package:dio/dio.dart';

/// Optional Moonbase capability. Other backends can keep their standard guide.
abstract interface class ChannelGroupApi {
  Future<ChannelGroupLineup> getChannelGroups();
  Future<String?> getGuideRevision();
}

class ChannelGroupLineup {
  final Map<String, Set<String>> groupsByChannelId;
  final bool partial;

  /// Null when the server could not determine availability or predates this field.
  final Set<String>? programmeCategories;

  /// Last stable guide import, or "pending" while no reliable snapshot is available.
  final String? guideRevision;

  const ChannelGroupLineup(
    this.groupsByChannelId, {
    this.partial = false,
    this.programmeCategories,
    this.guideRevision,
  });

  static Future<String?> fetchGuideRevision(Dio dio) async {
    try {
      final response = await dio.get(
        '/Moonfin/LiveTv/ChannelGroups',
        queryParameters: {'guideRevisionOnly': true},
      );
      final data = response.data;
      return data is Map ? data['guideRevision'] as String? : null;
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  static Future<ChannelGroupLineup> fetch(Dio dio) async {
    try {
      final response = await dio.get('/Moonfin/LiveTv/ChannelGroups');
      final data = response.data;
      if (data is! Map || data['version'] != 1) {
        throw const FormatException('Unknown channel group response');
      }
      final raw = data['supported'] == false
          ? const {}
          : data['groupsByChannelId'];
      if (data['supported'] is! bool || raw is! Map) {
        throw const FormatException('Invalid channel group response');
      }
      final categories = data['programmeCategories'];
      return ChannelGroupLineup(
        {
          for (final entry in raw.entries)
            if (entry.key is String && entry.value is List)
              entry.key as String: {
                for (final label in entry.value as List)
                  if (label is String && label.trim().isNotEmpty) label.trim(),
              },
        },
        partial: data['partial'] == true,
        guideRevision: data['guideRevision'] as String?,
        programmeCategories:
            categories is List && categories.every((c) => c is String)
            ? categories.cast<String>().toSet()
            : null,
      );
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) {
        return const ChannelGroupLineup({});
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
