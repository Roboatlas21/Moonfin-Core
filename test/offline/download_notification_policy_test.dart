import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/services/download_notification_service.dart';

void main() {
  group('Android download notifications', () {
    test('progress uses a new channel with no sound or vibration', () {
      const channel = DownloadNotificationService.progressChannel;
      expect(channel.id, isNot('moonfin_downloads'));
      expect(channel.importance, Importance.low);
      expect(channel.playSound, isFalse);
      expect(channel.enableVibration, isFalse);

      final details = DownloadNotificationService.androidProgressDetails(91);
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

    test('server messages retain their pre-existing notification channel', () {
      expect(DownloadNotificationService.serverMessageChannel.id,
          'moonfin_downloads');
    });
  });
}
