import 'dart:math';

/// Only the in-process Android downloader uses these cards. The native
/// background_downloader plugin keeps ownership of original-quality transfers.
class DownloadProgressCard {
  const DownloadProgressCard({
    required this.transferKey,
    required this.notificationId,
    required this.cancelActionId,
  });

  final String transferKey;
  final int notificationId;
  final String cancelActionId;
}

/// Foreground service notification 1000 is a stable, non-actionable group
/// summary. Each transfer has a different Android notification ID and action,
/// so Android never retargets a stale Cancel PendingIntent to another episode.
class DownloadProgressCards {
  DownloadProgressCards({int? firstId, String? sessionId})
      : _nextId = firstId ??
            (20000 +
                (DateTime.now().microsecondsSinceEpoch % 20000000) +
                Random().nextInt(20000000)),
        _sessionId = sessionId ??
            '${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(1 << 30)}';

  static const int foregroundId = 1000;
  static const String cancelPrefix = 'moonfin.download.cancel.';

  int _nextId;
  int _nextToken = 0;
  final String _sessionId;
  final Map<String, DownloadProgressCard> _active = {};

  int get count => _active.length;
  DownloadProgressCard? forTransfer(String key) => _active[key];

  DownloadProgressCard register(String key) =>
      _active.putIfAbsent(key, () => DownloadProgressCard(
            transferKey: key,
            notificationId: _nextId++,
            cancelActionId: '$cancelPrefix${_sessionId}_${++_nextToken}',
          ));

  DownloadProgressCard? forAction(String actionId) {
    if (!actionId.startsWith(cancelPrefix)) return null;
    for (final card in _active.values) {
      if (card.cancelActionId == actionId) return card;
    }
    return null;
  }

  DownloadProgressCard? remove(String key) => _active.remove(key);

  List<DownloadProgressCard> clear() {
    final cards = _active.values.toList();
    _active.clear();
    return cards;
  }
}
