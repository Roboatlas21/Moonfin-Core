import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/services/download_batch_notification_policy.dart';

void main() {
  group('download batch notification policy', () {
    test('only a fully successful batch gets a completion alert', () {
      expect(
        DownloadBatchNotificationPolicy.shouldNotifyComplete(
          completed: 3, total: 3),
        isTrue,
      );
      expect(
        DownloadBatchNotificationPolicy.shouldNotifyComplete(
          completed: 2, total: 3),
        isFalse,
      );
      expect(
        DownloadBatchNotificationPolicy.shouldNotifyComplete(
          completed: 0, total: 0),
        isFalse,
      );
    });

    test('waits for slow episode postprocessing before batch completion',
        () async {
      final first = Completer<void>();
      final second = Completer<void>();
      var settled = false;
      final completion = DownloadBatchNotificationPolicy.awaitPostProcessing(
        [first.future, second.future],
      ).then((_) => settled = true);

      first.complete();
      await Future<void>.delayed(Duration.zero);
      expect(settled, isFalse);
      second.complete();
      await completion;
      expect(settled, isTrue);
    });

    test('one failed sidecar task does not block batch finalization', () async {
      final other = Completer<void>();
      final completion = DownloadBatchNotificationPolicy.awaitPostProcessing([
        Future<void>.error(StateError('subtitle failed')),
        other.future,
      ]);
      other.complete();
      await completion;
    });
  });
  group('recovered download completion aggregation', () {
    test('deduplicates the same recovered episode', () {
      final buffer = RecoveredDownloadNotificationBuffer();
      buffer.add('episode-a', 'Show S1E1');
      buffer.add('episode-a', 'Show S1E1');
      buffer.add('episode-b', 'Show S1E2');
      expect(buffer.count, 2);
      final notice = buffer.take();
      expect(notice?.count, 2);
      expect(notice?.itemName, 'Show S1E2');
      expect(buffer.take(), isNull);
    });

    test('cancellation discards pending recovered notification', () {
      final buffer = RecoveredDownloadNotificationBuffer();
      buffer.add('episode-a', 'Show S1E1');
      buffer.clear();
      expect(buffer.count, 0);
      expect(buffer.take(), isNull);
    });
  });

}
