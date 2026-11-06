/// Pure Android progress-card ownership bookkeeping, independent of plugins.
/// Only one card is the foreground service notification; all other active
/// downloads own distinct ordinary progress notification IDs.
class DownloadProgressNotificationSnapshot {
  const DownloadProgressNotificationSnapshot({
    required this.notificationId,
    required this.itemId,
    required this.title,
    required this.body,
    required this.percent,
    required this.createdAtMillis,
  });

  final int notificationId;
  final String itemId;
  final String title;
  final String body;
  final int percent;
  // Keep Android's sorting timestamp stable when progress is updated.
  final int createdAtMillis;

  DownloadProgressNotificationSnapshot withNotificationId(int id) =>
      DownloadProgressNotificationSnapshot(
        notificationId: id,
        itemId: itemId,
        title: title,
        body: body,
        percent: percent,
        createdAtMillis: createdAtMillis,
      );
}

class DownloadProgressNotificationRemoval {
  const DownloadProgressNotificationRemoval({
    required this.removedId,
    required this.wasForeground,
    this.promoted,
    this.promotedFromId,
  });

  final int removedId;
  final bool wasForeground;
  final DownloadProgressNotificationSnapshot? promoted;
  final int? promotedFromId;
}

class DownloadProgressNotificationRegistry {
  static const int foregroundId = 1000;
  static const int firstAdditionalId = 10000;

  final Map<String, DownloadProgressNotificationSnapshot> _active = {};
  String? _foregroundItemId;
  int _nextId = firstAdditionalId;

  int get activeCount => _active.length;
  String? get foregroundItemId => _foregroundItemId;
  int? idFor(String itemId) => _active[itemId]?.notificationId;

  DownloadProgressNotificationSnapshot update({
    required String itemId,
    required String title,
    required String body,
    required int percent,
  }) {
    final existing = _active[itemId];
    final id = existing?.notificationId ??
        (_foregroundItemId == null ? foregroundId : _nextId++);
    if (existing == null && id == foregroundId) {
      _foregroundItemId = itemId;
    }
    final snapshot = DownloadProgressNotificationSnapshot(
      notificationId: id,
      itemId: itemId,
      title: title,
      body: body,
      percent: percent,
      createdAtMillis:
          existing?.createdAtMillis ?? DateTime.now().millisecondsSinceEpoch,
    );
    _active[itemId] = snapshot;
    return snapshot;
  }

  DownloadProgressNotificationRemoval? remove(String itemId) {
    final removed = _active.remove(itemId);
    if (removed == null) return null;
    if (itemId != _foregroundItemId) {
      return DownloadProgressNotificationRemoval(
        removedId: removed.notificationId,
        wasForeground: false,
      );
    }

    _foregroundItemId = null;
    if (_active.isEmpty) {
      return DownloadProgressNotificationRemoval(
        removedId: foregroundId,
        wasForeground: true,
      );
    }

    // In insertion order, promote the oldest remaining transfer. Reuse the
    // foreground notification ID without stopping or restarting the service.
    final next = _active.entries.first;
    final promoted = next.value.withNotificationId(foregroundId);
    _active[next.key] = promoted;
    _foregroundItemId = next.key;
    return DownloadProgressNotificationRemoval(
      removedId: foregroundId,
      wasForeground: true,
      promoted: promoted,
      promotedFromId: next.value.notificationId,
    );
  }

  /// Returns every live notification ID for best-effort cancellation.
  List<int> clear() {
    final ids = _active.values.map((entry) => entry.notificationId).toList();
    _active.clear();
    _foregroundItemId = null;
    return ids;
  }
}
