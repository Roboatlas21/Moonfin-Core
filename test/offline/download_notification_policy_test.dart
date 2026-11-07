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

    test('active Android progress has a silent background cancel button', () {
      const actionId = 'moonfin.download.cancel.example';
      final details = DownloadNotificationService.androidProgressDetails(
        42,
        cancelActionId: actionId,
        cancelLabel: 'Cancel',
      );
      expect(details.actions, hasLength(1));
      final action = details.actions!.single;
      expect(action.id, actionId);
      expect(action.title, 'Cancel');
      expect(action.showsUserInterface, isFalse);
      expect(action.cancelNotification, isFalse);
      expect(details.playSound, isFalse);
      expect(details.enableVibration, isFalse);
      expect(details.onlyAlertOnce, isTrue);

      final idle = DownloadNotificationService.androidProgressDetails(-1);
      expect(idle.actions, isNull);
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
      expect(updated.cancelActionId, second.cancelActionId);
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
      expect(removal.promoted?.cancelActionId, oldExtra.cancelActionId);
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

  group('latest progress update buffer', () {
    test('coalesces repeated progress updates before the worker runs', () {
      final buffer = DownloadProgressUpdateBuffer<int>();
      expect(buffer.offer('episode-a', 1), isTrue);
      expect(buffer.offer('episode-a', 50), isFalse);
      expect(buffer.offer('episode-b', 25), isTrue);
      expect(buffer.offer('episode-a', 91), isFalse);
      expect(buffer.pendingCount, 2);
      expect(buffer.take('episode-a'), 91);
      expect(buffer.take('episode-b'), 25);
      expect(buffer.pendingCount, 0);

      buffer.release('episode-a');
      buffer.release('episode-b');
      expect(buffer.offer('episode-a', 99), isTrue);
    });

    test('finishing an episode discards pending updates', () {
      final buffer = DownloadProgressUpdateBuffer<int>();
      expect(buffer.offer('episode-a', 12), isTrue);
      buffer.discard('episode-a');
      expect(buffer.take('episode-a'), isNull);
      buffer.release('episode-a');
      expect(buffer.offer('episode-a', 0), isTrue);
    });

    test('clear invalidates pending updates without duplicating workers', () {
      final buffer = DownloadProgressUpdateBuffer<int>();
      expect(buffer.offer('episode-a', 10), isTrue);
      buffer.clear();
      expect(buffer.take('episode-a'), isNull);
      expect(buffer.offer('episode-a', 15), isFalse);
      buffer.release('episode-a');
      expect(buffer.offer('episode-a', 20), isTrue);
    });
  });

  group('per-transfer cancel action identity', () {
    test('each active episode has a distinct resolvable action', () {
      final registry = DownloadProgressNotificationRegistry();
      final first = registry.update(
        itemId: 'episode-a',
        title: 'Downloading',
        body: 'A',
        percent: 20,
      );
      final second = registry.update(
        itemId: 'episode-b',
        title: 'Downloading',
        body: 'B',
        percent: 50,
      );
      expect(first.cancelActionId,
          startsWith(DownloadProgressNotificationRegistry.cancelActionPrefix));
      expect(first.cancelActionId, isNot(second.cancelActionId));
      expect(registry.targetForCancelAction(first.cancelActionId)?.itemId,
          'episode-a');
      expect(registry.targetForCancelAction(second.cancelActionId)?.itemId,
          'episode-b');
      expect(registry.targetForCancelAction('approve'), isNull);
    });

    test('old action cannot cancel the retry or promoted episode', () {
      final registry = DownloadProgressNotificationRegistry();
      final first = registry.update(
        itemId: 'episode-a',
        title: 'Downloading',
        body: 'A',
        percent: 20,
      );
      final second = registry.update(
        itemId: 'episode-b',
        title: 'Downloading',
        body: 'B',
        percent: 50,
      );
      final removal = registry.remove('episode-a')!;
      expect(removal.promoted?.cancelActionId, second.cancelActionId);
      expect(registry.targetForCancelAction(first.cancelActionId), isNull);
      expect(registry.targetForCancelAction(second.cancelActionId)?.itemId,
          'episode-b');

      final retry = registry.update(
        itemId: 'episode-a',
        title: 'Downloading',
        body: 'Retry A',
        percent: 0,
      );
      expect(retry.cancelActionId, isNot(first.cancelActionId));
      expect(registry.targetForCancelAction(first.cancelActionId), isNull);
      expect(registry.targetForCancelAction(retry.cancelActionId)?.itemId,
          'episode-a');
    });

    test('cancel IDs are unique across notification service lifetimes', () {
      final firstRegistry = DownloadProgressNotificationRegistry();
      final secondRegistry = DownloadProgressNotificationRegistry();
      final first = firstRegistry.update(
        itemId: 'same-episode',
        title: 'Downloading',
        body: 'A',
        percent: 10,
      );
      final second = secondRegistry.update(
        itemId: 'same-episode',
        title: 'Downloading',
        body: 'A',
        percent: 10,
      );
      expect(first.cancelActionId, isNot(second.cancelActionId));
    });
  });

  group('native Android failure notification compatibility', () {
    test('matches Java String.hashCode notification IDs', () {
      expect(androidNativeTaskNotificationId(''), 0);
      expect(androidNativeTaskNotificationId('abc'), 96354);
      expect(androidNativeTaskNotificationId('moonfinMedia'),
          'moonfinMedia'.codeUnits.fold<int>(
            0, (value, unit) => (31 * value + unit).toSigned(32),
          ));
    });

    test('does not use Moonfin progress IDs for native errors', () {
      expect(androidNativeTaskNotificationId('episode::1'),
          isNot(DownloadProgressNotificationRegistry.foregroundId));
    });
  });

  group('cross-server notification ownership', () {
    test('same media ID on different servers retains independent actions', () {
      final registry = DownloadProgressNotificationRegistry();
      final first = registry.update(
        itemId: 'server-a::episode-1::attempt-1',
        title: 'Downloading', body: 'A', percent: 12,
      );
      final second = registry.update(
        itemId: 'server-b::episode-1::attempt-2',
        title: 'Downloading', body: 'B', percent: 44,
      );
      expect(first.notificationId, isNot(second.notificationId));
      expect(first.cancelActionId, isNot(second.cancelActionId));
      registry.remove('server-a::episode-1::attempt-1');
      expect(registry.targetForCancelAction(first.cancelActionId), isNull);
      expect(registry.targetForCancelAction(second.cancelActionId)?.itemId,
          'server-b::episode-1::attempt-2');
    });
  });

  group('late foreground start reconciliation', () {
    test('stops service after final transfer finishes during startup', () {
      expect(
        shouldStopLateForegroundStart(
          hasActiveProgress: false,
          retainingBetweenTransfers: false,
          stopRequested: true,
        ),
        isTrue,
      );
    });

    test('retains service when another episode is active', () {
      expect(
        shouldStopLateForegroundStart(
          hasActiveProgress: true,
          retainingBetweenTransfers: false,
          stopRequested: false,
        ),
        isFalse,
      );
    });

    test('retains service across the gap between queued transcodes', () {
      expect(
        shouldStopLateForegroundStart(
          hasActiveProgress: false,
          retainingBetweenTransfers: true,
          stopRequested: false,
        ),
        isFalse,
      );
    });
  });

  test('foreground cancel action is absent for unowned service placeholder', () {
    final details = DownloadNotificationService.androidProgressDetails(-1);
    expect(details.actions, isNull);
    expect(details.silent, isTrue);
  });

  group('stale notification cancellation retry budget', () {
    test('uses a capped exponential backoff', () {
      expect(cancellationRetryBackoff(0), const Duration(seconds: 2));
      expect(cancellationRetryBackoff(1), const Duration(seconds: 4));
      expect(cancellationRetryBackoff(4), const Duration(seconds: 30));
      expect(cancellationRetryBackoff(100), const Duration(seconds: 30));
    });
  });

  group('native failure card deduplication', () {
    test('removes only the actual native terminal error for that task', () {
      expect(isNativeFailureCard(
        id: 1234, expectedId: 1234, channelId: 'background_downloader',
        title: 'Download failed', failureTitle: 'Download failed'), isTrue);
      expect(isNativeFailureCard(
        id: 1234, expectedId: 1234, channelId: 'background_downloader',
        title: 'Downloading', failureTitle: 'Download failed'), isFalse);
      expect(isNativeFailureCard(
        id: 1235, expectedId: 1234, channelId: 'background_downloader',
        title: 'Download failed', failureTitle: 'Download failed'), isFalse);
      expect(isNativeFailureCard(
        id: 1234, expectedId: 1234, channelId: 'moonfin_download_alerts_v1',
        title: 'Download failed', failureTitle: 'Download failed'), isFalse);
    });
  });

  group('late Android foreground stop handling', () {
    test('waits until stop resolves before trying to restart', () {
      expect(foregroundRestartRequired(
        serviceRunning: true, stopUncertain: false,
        startInFlight: false, stopInFlight: true,
      ), isFalse);
    });
    test('restarts after stop succeeds or errors', () {
      expect(foregroundRestartRequired(
        serviceRunning: false, stopUncertain: false,
        startInFlight: false, stopInFlight: false,
      ), isTrue);
      expect(foregroundRestartRequired(
        serviceRunning: true, stopUncertain: true,
        startInFlight: false, stopInFlight: false,
      ), isTrue);
    });
    test('avoids overlapping foreground starts', () {
      expect(foregroundRestartRequired(
        serviceRunning: false, stopUncertain: false,
        startInFlight: true, stopInFlight: false,
      ), isFalse);
    });
  });

  group('Android download foreground readiness', () {
    test('rejects an ordinary card without a foreground service', () {
      expect(androidForegroundProtectionReady(
        running: false, startInFlight: false,
        stopInFlight: false, stopUncertain: false,
      ), isFalse);
    });

    test('rejects pending startup and shutdown operations', () {
      expect(androidForegroundProtectionReady(
        running: true, startInFlight: true,
        stopInFlight: false, stopUncertain: false,
      ), isFalse);
      expect(androidForegroundProtectionReady(
        running: true, startInFlight: false,
        stopInFlight: true, stopUncertain: false,
      ), isFalse);
    });

    test('requires a confirmed live foreground service', () {
      expect(androidForegroundProtectionReady(
        running: true, startInFlight: false,
        stopInFlight: false, stopUncertain: false,
      ), isTrue);
      expect(androidForegroundProtectionReady(
        running: true, startInFlight: false,
        stopInFlight: false, stopUncertain: true,
      ), isFalse);
    });
  });

}
