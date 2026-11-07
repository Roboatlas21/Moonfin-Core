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
    this.terminalOutcomes = const {},
  });

  final String id;
  final String serverId;
  final List<String> itemIds;
  final String itemName;
  final String? series;
  // Only explicit cancellation and failure are persisted here. DB status 2/3
  // is authoritative for completed transfers. Missing rows and status 0 are
  // never treated as terminal automatically.
  final Map<String, String> terminalOutcomes;

  PendingDownloadNotificationBatch withTerminalOutcome(
    String itemId,
    String outcome,
  ) => PendingDownloadNotificationBatch(
    id: id,
    serverId: serverId,
    itemIds: itemIds,
    itemName: itemName,
    series: series,
    terminalOutcomes: {
      ...terminalOutcomes,
      itemId: outcome,
    },
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'serverId': serverId,
    'itemIds': itemIds,
    'itemName': itemName,
    'series': series,
    'terminalOutcomes': terminalOutcomes,
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
      terminalOutcomes: {
        if (value['terminalOutcomes'] is Map)
          for (final entry in (value['terminalOutcomes'] as Map).entries)
            if (entry.key is String &&
                entry.value is String &&
                ids.contains(entry.key) &&
                (entry.value == 'cancelled' || entry.value == 'failed'))
              entry.key as String: entry.value as String,
      },
    );
  }

  bool contains(String itemServerId, String itemId) =>
      serverId == itemServerId && itemIds.contains(itemId);

  /// Status 2 = success, status 3 = known failure. Missing/0/1 are pending.
  /// A cancellation without an offline row must have an explicit terminal
  /// outcome; otherwise a crash before enqueuing could falsely finish a batch.
  bool isSettled(Map<String, int> statuses) =>
      itemIds.every((id) =>
          statuses[id] == 2 ||
          statuses[id] == 3 ||
          terminalOutcomes[id] == 'cancelled' ||
          terminalOutcomes[id] == 'failed');

  bool allSucceeded(Map<String, int> statuses) =>
      itemIds.every((id) =>
          statuses[id] == 2 && !terminalOutcomes.containsKey(id));
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

  /// Record a terminal event for an item whose row may have been deleted
  /// (cancellation) or never created (preflight failure).
  Future<void> markTerminal({
    required String serverId,
    required String itemId,
    required String outcome,
  }) async {
    if (outcome != 'cancelled' && outcome != 'failed') {
      throw ArgumentError.value(outcome, 'outcome');
    }
    final batches = await pending();
    for (final batch in batches) {
      if (!batch.contains(serverId, itemId)) continue;
      final next = batch.withTerminalOutcome(itemId, outcome);
      await _prefs.setString('$_prefix${batch.id}', jsonEncode(next.toJson()));
    }
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
