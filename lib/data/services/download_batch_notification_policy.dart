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
