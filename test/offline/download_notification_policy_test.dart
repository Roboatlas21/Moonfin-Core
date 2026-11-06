import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/services/download_notification_service.dart';
import 'package:moonfin/data/services/download_progress_notification_registry.dart';

void main() {
  group('Android download notifications', () {
    test('progress uses a new channel with no sound or vibration', () {
      const channel = DownloadNotificationService.progressChannel;
      expect(channel.id, isNot('moonfin_downloads'));
      expect(channel.importance, Importance.low);
      expect(channel.playSound, isFalse);
      expect(channel.enableVibration, isFalse);

      const postedAt = 1710000000000;
      final details = DownloadNotificationService.androidProgressDetails(
        91,
        when: postedAt,
      );
      expect(details.when, postedAt);
      expect(details.channelId, channel.id);
      expect(details.importance, Importance.low);
      expect(details.priority, Priority.low);
      expect(details.playSound, isFalse);
      expect(details.enableVibration, isFalse);
      expect(details.silent, isTrue);
      expect(details.onlyAlertOnce, isTrue);
      expect(details.ongoing, isTrue);
      expect(details.autoCancel, isFalse);
      expect(details.showProgress, isTrue);
      expect(details.progress, 91);
      expect(details.indeterminate, isFalse);
    });

    test('unknown progress remains a silent indeterminate notification', () {
      final details = DownloadNotificationService.androidProgressDetails(-1);
      expect(details.indeterminate, isTrue);
      expect(details.progress, 0);
      expect(details.playSound, isFalse);
      expect(details.enableVibration, isFalse);
      expect(details.onlyAlertOnce, isTrue);
    });

    test('downloads use one silent progress and one audible alert channel', () {
      const progress = DownloadNotificationService.progressChannel;
      const alerts = DownloadNotificationService.alertChannel;

      expect(progress.id, isNot(alerts.id));
      expect(alerts.importance, Importance.defaultImportance);
      expect(alerts.playSound, isTrue);
      expect(alerts.enableVibration, isTrue);

      final details = DownloadNotificationService.androidAlertDetails(alerts);
      expect(details.channelId, alerts.id);
      expect(details.playSound, isTrue);
      expect(details.enableVibration, isTrue);
      expect(details.autoCancel, isTrue);
    });

    test('startup cleanup isolates our own stale progress cards', () {
      final own = DownloadNotificationService.progressChannel.id;
      expect(
        DownloadNotificationService.isOwnProgressNotification(1000, own),
        isTrue,
      );
      expect(
        DownloadNotificationService.isOwnProgressNotification(10000, own),
        isTrue,
      );
      expect(
        DownloadNotificationService.isOwnProgressNotification(
          1000, 'background_downloader'),
        isFalse,
      );
      expect(
        DownloadNotificationService.isOwnProgressNotification(1001, own),
        isFalse,
      );
      expect(
        DownloadNotificationService.isOwnProgressNotification(
          10000, DownloadNotificationService.alertChannel.id),
        isFalse,
      );
    });

    test('server messages retain their pre-existing notification channel', () {
      expect(DownloadNotificationService.serverMessageChannel.id,
          'moonfin_downloads');
    });
  });
  group('concurrent Android progress notification ownership', () {
    test('every active transfer gets one stable card', () {
      final registry = DownloadProgressNotificationRegistry();
      final first = registry.update(
        itemId: 'episode-1',
        title: 'Downloading',
        body: 'Episode 1 — 25%',
        percent: 25,
      );
      final second = registry.update(
        itemId: 'episode-2',
        title: 'Downloading',
        body: 'Episode 2 — 50%',
        percent: 50,
      );
      final third = registry.update(
        itemId: 'episode-3',
        title: 'Downloading',
        body: 'Episode 3 — 5%',
        percent: 5,
      );

      expect(first.notificationId,
          DownloadProgressNotificationRegistry.foregroundId);
      expect(second.notificationId,
          DownloadProgressNotificationRegistry.firstAdditionalId);
      expect(third.notificationId, second.notificationId + 1);
      expect(registry.activeCount, 3);
      expect(registry.usesNotificationId(second.notificationId), isTrue);
      expect(registry.foregroundItemId, 'episode-1');

      final updated = registry.update(
        itemId: 'episode-2',
        title: 'Downloading',
        body: 'Episode 2 — 91%',
        percent: 91,
      );
      expect(updated.notificationId, second.notificationId);
      expect(updated.createdAtMillis, second.createdAtMillis);
      expect(updated.percent, 91);
      expect(registry.activeCount, 3);
    });

    test('finishing a non-foreground episode cancels only its card', () {
      final registry = DownloadProgressNotificationRegistry();
      registry.update(
        itemId: 'a', title: 'Downloading', body: 'A', percent: 10,
      );
      final extra = registry.update(
        itemId: 'b', title: 'Downloading', body: 'B', percent: 20,
      );
      final removal = registry.remove('b');
      expect(removal?.removedId, extra.notificationId);
      expect(removal?.wasForeground, isFalse);
      expect(removal?.promoted, isNull);
      expect(registry.foregroundItemId, 'a');
      expect(registry.activeCount, 1);
    });

    test('foreground owner hands off without adding a summary card', () {
      final registry = DownloadProgressNotificationRegistry();
      registry.update(
        itemId: 'a', title: 'Downloading', body: 'A', percent: 10,
      );
      final oldExtra = registry.update(
        itemId: 'b', title: 'Downloading', body: 'B', percent: 42,
      );
      registry.update(
        itemId: 'c', title: 'Downloading', body: 'C', percent: 15,
      );

      final removal = registry.remove('a')!;
      expect(removal.wasForeground, isTrue);
      expect(removal.promotedFromId, oldExtra.notificationId);
      expect(removal.promoted?.notificationId,
          DownloadProgressNotificationRegistry.foregroundId);
      expect(removal.promoted?.itemId, 'b');
      expect(removal.promoted?.percent, 42);
      expect(removal.promoted?.createdAtMillis, oldExtra.createdAtMillis);
      expect(registry.activeCount, 2);
      expect(registry.foregroundItemId, 'b');
      expect(registry.idFor('c'),
          DownloadProgressNotificationRegistry.firstAdditionalId + 1);

      final lastExtra = registry.remove('c');
      expect(lastExtra?.wasForeground, isFalse);
      final last = registry.remove('b');
      expect(last?.wasForeground, isTrue);
      expect(last?.promoted, isNull);
      expect(registry.activeCount, 0);
      expect(registry.foregroundItemId, isNull);
    });

    test('cancellation clears all cards; late finishes are harmless', () {
      final registry = DownloadProgressNotificationRegistry();
      registry.update(
        itemId: 'a', title: 'Downloading', body: 'A', percent: 2,
      );
      registry.update(
        itemId: 'b', title: 'Downloading', body: 'B', percent: -1,
      );
      final ids = registry.clear();
      expect(ids, containsAll([
        DownloadProgressNotificationRegistry.foregroundId,
        DownloadProgressNotificationRegistry.firstAdditionalId,
      ]));
      expect(registry.activeCount, 0);
      expect(registry.usesNotificationId(
          DownloadProgressNotificationRegistry.foregroundId), isFalse);
      expect(registry.remove('a'), isNull);

      final restarted = registry.update(
        itemId: 'a', title: 'Downloading', body: 'Retry', percent: 0,
      );
      expect(restarted.notificationId,
          DownloadProgressNotificationRegistry.foregroundId);
    });
  });

}
