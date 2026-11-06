/// Completion alert policy shared by original-quality and transcoded batches.
///
/// A season is ready only after every successful episode's post-download
/// processing settles. Failed/cancelled transfers don't produce a misleading
/// "season downloaded" alert.
class DownloadBatchNotificationPolicy {
  const DownloadBatchNotificationPolicy._();

  static bool shouldNotifyComplete({
    required int completed,
    required int total,
  }) =>
      total > 0 && completed >= total;

  static Future<void> awaitPostProcessing(
    Iterable<Future<void>> pending,
  ) async {
    await Future.wait<void>(
      pending.map((task) async {
        // Sidecar processing is best effort. Even if it fails unexpectedly,
        // the successful media file still counts as a finished transfer.
        try {
          await task;
        } catch (_) {}
      }),
    );
  }
}

/// De-duplicates the native transfers recovered after a restart. One
/// notification summarises all completions observed during reconciliation.
class RecoveredDownloadNotificationBuffer {
  final Map<String, String> _completed = {};

  int get count => _completed.length;

  void add(String itemId, String label) {
    _completed[itemId] = label;
  }

  ({int count, String itemName})? take() {
    if (_completed.isEmpty) return null;
    final result = (count: _completed.length, itemName: _completed.values.last);
    _completed.clear();
    return result;
  }

  void clear() => _completed.clear();
}
