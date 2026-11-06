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
    required this.cancelActionId,
  });

  final int notificationId;
  final String itemId;
  final String title;
  final String body;
  final int percent;
  // Keep Android's sorting timestamp stable when progress is updated.
  final int createdAtMillis;

  // Per-transfer action identity, stable across progress updates and
  // foreground promotion; an action from an earlier attempt won't cancel
  // a later retry (or a different episode).
  final String cancelActionId;

  DownloadProgressNotificationSnapshot withNotificationId(int id) =>
      DownloadProgressNotificationSnapshot(
        notificationId: id,
        itemId: itemId,
        title: title,
        body: body,
        percent: percent,
        createdAtMillis: createdAtMillis,
        cancelActionId: cancelActionId,
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
  DownloadProgressNotificationRegistry()
      : _cancelSession =
            '${DateTime.now().microsecondsSinceEpoch}_${++_sessionCounter}';

  static const int foregroundId = 1000;
  static const int firstAdditionalId = 10000;
  static const String cancelActionPrefix = 'moonfin.download.cancel.';
  static int _sessionCounter = 0;

  final String _cancelSession;
  int _nextCancelAction = 0;

  final Map<String, DownloadProgressNotificationSnapshot> _active = {};
  String? _foregroundItemId;
  int _nextId = firstAdditionalId;

  int get activeCount => _active.length;
  String? get foregroundItemId => _foregroundItemId;
  DownloadProgressNotificationSnapshot? get foregroundSnapshot =>
      _foregroundItemId == null ? null : _active[_foregroundItemId];
  int? idFor(String itemId) => _active[itemId]?.notificationId;
  bool usesNotificationId(int id) =>
      _active.values.any((snapshot) => snapshot.notificationId == id);

  /// Action tokens are the lookup key, not notification IDs. The foreground
  /// notification ID is reused by other episodes when ownership transfers.
  DownloadProgressNotificationSnapshot? targetForCancelAction(
    String actionId,
  ) {
    if (!actionId.startsWith(cancelActionPrefix)) return null;
    for (final snapshot in _active.values) {
      if (snapshot.cancelActionId == actionId) return snapshot;
    }
    return null;
  }

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
      cancelActionId: existing?.cancelActionId ??
          '${cancelActionPrefix}${_cancelSession}_${++_nextCancelAction}',
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

/// Stores only the latest pending update for each episode while its
/// single worker is queued. A busy Android notification API therefore cannot
/// accumulate one native call per progress callback.
class DownloadProgressUpdateBuffer<T> {
  final Map<String, T> _latest = {};
  final Set<String> _scheduled = {};

  int get pendingCount => _latest.length;

  /// Returns true only when a worker must be scheduled for this item.
  bool offer(String itemId, T update) {
    _latest[itemId] = update;
    return _scheduled.add(itemId);
  }

  T? take(String itemId) => _latest.remove(itemId);

  void discard(String itemId) => _latest.remove(itemId);

  /// Workers call release in their own finally block.
  void release(String itemId) => _scheduled.remove(itemId);

  /// Does not clear scheduled: an already-queued worker still owns release.
  void clear() => _latest.clear();
}

/// Mirrors Java String.hashCode (UTF-16 units), used by the pinned
/// background_downloader Android plugin for per-task notification IDs.
/// Only used to dismiss a redundant, terminal native error card.
int androidNativeTaskNotificationId(String taskId) {
  var hash = 0;
  for (final unit in taskId.codeUnits) {
    hash = (31 * hash + unit) & 0xffffffff;
  }
  return hash.toSigned(32);
}

/// A foreground-start RPC can finish after Dart's timeout. The final
/// Android reply determines whether the service should be retained or
/// stopped, based on the current transfer set rather than the old request.
bool shouldStopLateForegroundStart({
  required bool hasActiveProgress,
  required bool retainingBetweenTransfers,
  required bool stopRequested,
}) =>
    stopRequested || (!hasActiveProgress && !retainingBetweenTransfers);

/// Retry delays for failed Android notification cancellations. The maximum
/// is deliberately small enough for recovery but never on the download's
/// critical path. 2, 4, 8, 16, 30, 30... seconds.
Duration cancellationRetryBackoff(int attempt) {
  const seconds = [2, 4, 8, 16, 30];
  final index = attempt < 0
      ? 0
      : (attempt >= seconds.length ? seconds.length - 1 : attempt);
  return Duration(seconds: seconds[index]);
}

/// The native downloader uses one low-priority channel for progress and
/// failures. Remove only a visibly terminal error for the exact task, never
/// a running notification or an unrelated channel's notification.
bool isNativeFailureCard({
  required int id,
  required int expectedId,
  required String? channelId,
  required String? title,
  required String failureTitle,
}) =>
    id == expectedId &&
    channelId == 'background_downloader' &&
    title == failureTitle;
