import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Durable membership of an original-quality download batch. Native Android
/// tasks may outlive the Dart isolate; time-window grouping cannot recover
/// which episodes should produce a single season-complete alert.
class PendingDownloadNotificationBatch {
  const PendingDownloadNotificationBatch({
    required this.id,
    required this.serverId,
    required this.itemIds,
    required this.itemName,
    this.series,
  });

  final String id;
  final String serverId;
  final List<String> itemIds;
  final String itemName;
  final String? series;

  Map<String, dynamic> toJson() => {
    'id': id,
    'serverId': serverId,
    'itemIds': itemIds,
    'itemName': itemName,
    'series': series,
  };

  static PendingDownloadNotificationBatch? fromJson(dynamic value) {
    if (value is! Map) return null;
    final id = value['id'];
    final serverId = value['serverId'];
    final ids = value['itemIds'];
    final itemName = value['itemName'];
    if (id is! String || id.isEmpty ||
        serverId is! String || serverId.isEmpty ||
        ids is! List || ids.isEmpty ||
        itemName is! String || itemName.isEmpty ||
        ids.any((id) => id is! String || id.isEmpty)) {
      return null;
    }
    return PendingDownloadNotificationBatch(
      id: id,
      serverId: serverId,
      itemIds: List<String>.from(ids),
      itemName: itemName,
      series: value['series'] is String ? value['series'] as String : null,
    );
  }

  bool contains(String itemServerId, String itemId) =>
      serverId == itemServerId && itemIds.contains(itemId);

  /// Status 2 = fully downloaded. Status 1 = still in progress.
  /// Missing/cancelled/failed rows terminate without a success alert.
  bool isSettled(Map<String, int> statuses) =>
      itemIds.every((id) => statuses[id] != 1);

  bool allSucceeded(Map<String, int> statuses) =>
      itemIds.every((id) => statuses[id] == 2);
}

/// Separate shared-preferences entry per batch: concurrent server sessions
/// never overwrite each other's manifests. SharedPreferencesAsync avoids
/// stale per-isolate caches in Android headless background workers.
class DownloadBatchNotificationLedger {
  static const _prefix = 'moonfin_download_batch_notification_v1_';
  final SharedPreferencesAsync _prefs = SharedPreferencesAsync();

  Future<String> register({
    required String serverId,
    required List<String> itemIds,
    required String itemName,
    String? series,
  }) async {
    final id = const Uuid().v4();
    final record = PendingDownloadNotificationBatch(
      id: id,
      serverId: serverId,
      itemIds: List.unmodifiable(itemIds),
      itemName: itemName,
      series: series,
    );
    await _prefs.setString('$_prefix$id', jsonEncode(record.toJson()));
    return id;
  }

  Future<List<PendingDownloadNotificationBatch>> pending() async {
    final keys = await _prefs.getKeys();
    final results = <PendingDownloadNotificationBatch>[];
    for (final key in keys.where((key) => key.startsWith(_prefix))) {
      final raw = await _prefs.getString(key);
      if (raw == null) continue;
      try {
        final parsed = PendingDownloadNotificationBatch.fromJson(jsonDecode(raw));
        if (parsed != null) results.add(parsed);
      } catch (_) {
        // Do not crash startup for an obsolete or damaged saved manifest.
      }
    }
    return results;
  }

  Future<void> consume(String id) => _prefs.remove('$_prefix$id');

  /// Cancel All is intentionally global across servers.
  Future<void> clearAll() async {
    final keys = await _prefs.getKeys();
    for (final key in keys.where((key) => key.startsWith(_prefix))) {
      await _prefs.remove(key);
    }
  }
}
