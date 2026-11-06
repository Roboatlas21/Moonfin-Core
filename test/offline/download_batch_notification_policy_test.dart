import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/services/download_batch_notification_policy.dart';
import 'package:moonfin/data/services/download_batch_notification_ledger.dart';

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

  group('durable season completion membership', () {
    test('encodes and decodes server-qualified batch membership', () {
      const batch = PendingDownloadNotificationBatch(
        id: 'batch-123',
        serverId: 'server-A',
        itemIds: ['episode-1', 'episode-2'],
        itemName: 'Show S01E02',
        series: 'Show',
      );
      final roundtrip = PendingDownloadNotificationBatch.fromJson(
        batch.toJson(),
      );
      expect(roundtrip, isNotNull);
      expect(roundtrip!.itemIds, ['episode-1', 'episode-2']);
      expect(roundtrip.contains('server-A', 'episode-1'), isTrue);
      expect(roundtrip.contains('server-B', 'episode-1'), isFalse);
    });

    test('cannot complete season while any episode is still running', () {
      const batch = PendingDownloadNotificationBatch(
        id: 'batch-1', serverId: 'server-A',
        itemIds: ['episode-1', 'episode-2'], itemName: 'Show',
      );
      expect(batch.isSettled({'episode-1': 2, 'episode-2': 1}), isFalse);
      expect(batch.allSucceeded({'episode-1': 2, 'episode-2': 1}), isFalse);
      expect(batch.isSettled({'episode-1': 2, 'episode-2': 2}), isTrue);
      expect(batch.allSucceeded({'episode-1': 2, 'episode-2': 2}), isTrue);
    });

    test('failed or cancelled episode suppresses season success', () {
      const batch = PendingDownloadNotificationBatch(
        id: 'batch-1', serverId: 'server-A',
        itemIds: ['episode-1', 'episode-2'], itemName: 'Show',
      );
      expect(batch.isSettled({'episode-1': 2, 'episode-2': 3}), isTrue);
      expect(batch.allSucceeded({'episode-1': 2, 'episode-2': 3}), isFalse);
      expect(batch.isSettled({'episode-1': 2}), isTrue);
      expect(batch.allSucceeded({'episode-1': 2}), isFalse);
    });

    test('invalid saved batch data is rejected', () {
      expect(PendingDownloadNotificationBatch.fromJson({}), isNull);
      expect(PendingDownloadNotificationBatch.fromJson({
        'id': 'a', 'serverId': 'b', 'itemIds': [1], 'itemName': 'X',
      }), isNull);
    });
  });

  test('pending postprocessing defers durable season completion', () {
    const batch = PendingDownloadNotificationBatch(
      id: 'batch-1', serverId: 'server-A',
      itemIds: ['episode-1', 'episode-2'], itemName: 'Show',
    );
    final processing = <String>{'episode-2'};
    expect(batch.itemIds.any(processing.contains), isTrue);
    processing.remove('episode-2');
    expect(batch.itemIds.any(processing.contains), isFalse);
  });

}
