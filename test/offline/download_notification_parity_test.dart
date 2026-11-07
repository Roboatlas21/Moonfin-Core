import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/services/download_notification_service.dart';

void main() {
  group('minimal Android download notification parity', () {
    test('each episode has a silent progress card with a Cancel action', () {
      final details = DownloadNotificationService.androidProgressDetails(
        42,
        actionId: 'moonfin.download.cancel.test-1',
      );
      expect(details.channelId,
          DownloadNotificationService.progressChannel.id);
      expect(details.importance, Importance.low);
      expect(details.playSound, isFalse);
      expect(details.enableVibration, isFalse);
      expect(details.silent, isTrue);
      expect(details.onlyAlertOnce, isTrue);
      expect(details.ongoing, isTrue);
      expect(details.showProgress, isTrue);
      expect(details.progress, 42);
      expect(details.actions, hasLength(1));
      expect(details.actions!.single.id, 'moonfin.download.cancel.test-1');
      expect(details.actions!.single.showsUserInterface, isFalse);
      expect(details.actions!.single.cancelNotification, isFalse);
    });

    test('foreground summary is stable and has no cancellation action', () {
      final summary = DownloadNotificationService.androidForegroundDetails();
      final episode = DownloadNotificationService.androidProgressDetails(
        -1,
        actionId: 'moonfin.download.cancel.test-2',
      );
      expect(summary.setAsGroupSummary, isTrue);
      expect(summary.groupKey, episode.groupKey);
      expect(summary.actions, isNull);
      expect(summary.ongoing, isTrue);
      expect(summary.silent, isTrue);
      expect(episode.indeterminate, isTrue);
    });

    test('alerts remain audible and unrelated server messages unchanged', () {
      const progress = DownloadNotificationService.progressChannel;
      const alerts = DownloadNotificationService.alertChannel;
      const messages = DownloadNotificationService.serverMessageChannel;
      expect(progress.id, isNot(alerts.id));
      expect(progress.playSound, isFalse);
      expect(alerts.importance, Importance.defaultImportance);
      expect(alerts.playSound, isTrue);
      expect(alerts.enableVibration, isTrue);
      expect(messages.id, 'moonfin_downloads');
    });
  });
}
