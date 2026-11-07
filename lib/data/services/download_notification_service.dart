import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../l10n/current_app_localizations.dart';
import '../../util/platform_detection.dart';
import 'local_notification_bootstrap.dart';
import 'download_progress_cards.dart';

class DownloadNotificationService {
  // A pre-existing Android channel cannot change its sound settings. Keep
  // server messages on their current channel, but give in-process progress a
  // new silent channel and completions/failures an audible one.
  static const progressChannel = AndroidNotificationChannel(
    'moonfin_download_progress_silent_v1',
    'Download progress',
    description: 'Silent progress for offline downloads',
    importance: Importance.low,
    playSound: false,
    enableVibration: false,
    showBadge: false,
  );
  static const alertChannel = AndroidNotificationChannel(
    'moonfin_download_alerts_v1',
    'Download alerts',
    description: 'Download completion, failure and storage alerts',
  );
  static const serverMessageChannel = AndroidNotificationChannel(
    'moonfin_downloads',
    'Downloads',
    description: 'Shows download progress for offline media',
  );
  static const _groupKey = 'moonfin.transcoded.downloads';
  static const _progressNotificationId = 1000;
  static const _completionNotificationId = 1001;
  static const _remoteMessageNotificationId = 1002;
  static const _storageNotificationId = 1003;

  FlutterLocalNotificationsPlugin get _plugin =>
      LocalNotificationBootstrap.instance.plugin;

  bool _initialized = false;
  DateTime _lastUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  bool _foregroundServiceRunning = false;
  String? _lastProgressSignature;

  Future<void> _pendingNotification = Future<void>.value();
  Future<void>? _initializing;

  // One Android foreground-service group summary remains stable while one or
  // more transfers run. Separate per-item cards carry the Cancel actions; the
  // system never reuses an action PendingIntent for a different episode.
  final DownloadProgressCards _cards = DownloadProgressCards();
  final Map<String, void Function()> _cancelCallbacks = {};
  final Map<String, ({String name, int percent})> _latest = {};
  final Set<String> _scheduled = {};
  final Map<String, DateTime> _lastAndroidUpdate = {};
  final Map<String, String> _lastAndroidSignature = {};

  Future<void> initialize() {
    if (_initialized) return Future<void>.value();
    return _initializing ??= _initialize().whenComplete(() {
      _initializing = null;
    });
  }

  Future<void> _initialize() async {
    await LocalNotificationBootstrap.instance.initialize();
    if (PlatformDetection.isAndroid) {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (android != null) {
        await android.createNotificationChannel(progressChannel);
        await android.createNotificationChannel(alertChannel);
        // Don't block download startup on an Android permission dialog.
        unawaited(android.requestNotificationsPermission().then<void>(
          (_) {},
          onError: (Object _, StackTrace __) {},
        ));
      }
    }
    _initialized = true;
    LocalNotificationBootstrap.instance.downloadCancelActionHandler =
        cancelFromNotification;
  }

  Future<void> _serialize(Future<void> Function() action) {
    final task = _pendingNotification.then((_) => action());
    _pendingNotification = task.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return task;
  }

  /// Android notification actions arrive in the plugin's background isolate
  /// and are forwarded to the running app through the existing Seerr port.
  bool cancelFromNotification(String actionId) {
    final card = _cards.forAction(actionId);
    final cancel = card == null ? null : _cancelCallbacks[card.cancelActionId];
    if (cancel == null) return false;
    cancel();
    return true;
  }

  bool _permissionRequested = false;

  /// Asks iOS for notification permission the first time a download starts,
  /// so the prompt appears next to the action it explains. Android asks at
  /// start-up above. The plugin and this service both post through the
  /// notification center, so one grant covers every download notification.
  Future<void> requestPermissionIfNeeded() async {
    if (!_initialized || _permissionRequested) return;
    _permissionRequested = true;
    if (!PlatformDetection.isIOS) return;
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    } catch (_) {}
  }

  Future<void> showProgress({
    required String itemId,
    required String itemName,
    required double progress,
    int batchTotal = 0,
    int batchCompleted = 0,
    bool startNewTransfer = false,
    void Function()? onCancel,
  }) async {
    if (!_initialized) await initialize();
    final rawPercent = (progress * 100).round();
    final percent = progress < 0
        ? -1
        : (rawPercent > 100 ? 100 : (rawPercent < 0 ? 0 : rawPercent));

    if (PlatformDetection.isAndroid) {
      final card = startNewTransfer
          ? _cards.register(itemId)
          : _cards.forTransfer(itemId);
      if (card == null) return;
      if (startNewTransfer && onCancel != null) {
        _cancelCallbacks[card.cancelActionId] = onCancel;
      }
      final signature = '$itemName/$percent';
      final now = DateTime.now();
      final last = _lastAndroidUpdate[itemId];
      if (!startNewTransfer &&
          (_lastAndroidSignature[itemId] == signature ||
              (last != null && now.difference(last).inMilliseconds < 1500))) {
        return;
      }
      _lastAndroidSignature[itemId] = signature;
      _lastAndroidUpdate[itemId] = now;
      _latest[itemId] = (name: itemName, percent: percent);
      if (!_scheduled.add(itemId)) return;

      try {
        await _serialize(() async {
          try {
            // A normal notification is not enough to protect an in-process
            // transcode. If foreground startup fails, the caller handles it
            // as a download failure rather than proceeding unprotected.
            await _ensureForeground();
            while (true) {
              final update = _latest.remove(itemId);
              if (update == null) break;
              if (!identical(_cards.forTransfer(itemId), card)) continue;
              final l10n = currentAppLocalizations();
              final body = update.percent >= 0
                  ? l10n.downloadNotificationProgress(
                      update.name, update.percent)
                  : l10n.downloadNotificationStarting(update.name);
              try {
                await _plugin.show(
                  id: card.notificationId,
                  title: l10n.downloadNotificationRunning,
                  body: body,
                  notificationDetails: NotificationDetails(
                    android: androidProgressDetails(
                      update.percent,
                      actionId: card.cancelActionId,
                      cancelLabel: l10n.cancel,
                    ),
                  ),
                );
              } catch (e) {
                debugPrint('[DownloadNotification] Item progress failed: $e');
              }
            }
          } finally {
            _scheduled.remove(itemId);
          }
        });
      } catch (e) {
        if (startNewTransfer) {
          _cards.remove(itemId);
          _cancelCallbacks.remove(card.cancelActionId);
          _latest.remove(itemId);
          _lastAndroidSignature.remove(itemId);
          _lastAndroidUpdate.remove(itemId);
          rethrow;
        }
        // Progress updates are fire-and-forget. Losing one card refresh must
        // never create an unhandled exception or interrupt the media transfer.
        debugPrint('[DownloadNotification] Progress update failed: $e');
      }
      return;
    }

    // Existing non-Android single-card behaviour is intentionally unchanged.
    final signature = '$itemName\n$batchCompleted/$batchTotal\n$percent';
    if (signature == _lastProgressSignature) return;
    final now = DateTime.now();
    if (now.difference(_lastUpdate).inMilliseconds < 1500) return;
    _lastUpdate = now;
    _lastProgressSignature = signature;
    final l10n = currentAppLocalizations();
    final title = batchTotal > 1
        ? l10n.downloadNotificationRunningBatch(batchCompleted + 1, batchTotal)
        : l10n.downloadNotificationRunning;
    final body = percent >= 0
        ? l10n.downloadNotificationProgress(itemName, percent)
        : l10n.downloadNotificationStarting(itemName);
    try {
      await _serialize(() => _showStandardProgress(title, body, percent));
    } catch (_) {}
  }

  Future<void> finishProgress(
    String itemId, {
    bool keepForegroundService = false,
  }) async {
    if (!_initialized || !PlatformDetection.isAndroid) return;
    final card = _cards.remove(itemId);
    if (card == null) return;
    _cancelCallbacks.remove(card.cancelActionId);
    _latest.remove(itemId);
    _lastAndroidSignature.remove(itemId);
    _lastAndroidUpdate.remove(itemId);
    try {
      await _serialize(() async {
        try {
          await _plugin.cancel(id: card.notificationId);
        } catch (e) {
          debugPrint('[DownloadNotification] Card cleanup failed: $e');
        }
        if (_cards.count == 0 && !keepForegroundService) {
          await _stopForegroundService();
        }
      });
    } catch (e) {
      debugPrint('[DownloadNotification] Finish progress failed: $e');
    }
  }

  /// Releases the stable foreground summary once the final batch ends,
  /// including any gap where another transcode was queued but never started.
  Future<void> releaseIdleForegroundService() async {
    if (!_initialized || !PlatformDetection.isAndroid) return;
    await _serialize(() async {
      if (_cards.count == 0) await _stopForegroundService();
    });
  }

  /// [batchSeries] names the show when every item of a finished batch
  /// belongs to it, so a season reads "Series: 8 episodes".
  Future<void> showComplete({
    required String itemName,
    int batchTotal = 0,
    String? batchSeries,
  }) async {
    if (!_initialized) return;
    _lastProgressSignature = null;
    if (!PlatformDetection.isAndroid) await _stopForegroundService();

    final l10n = currentAppLocalizations();
    final title = l10n.downloadNotificationCompleteTitle(
      batchTotal > 1 ? batchTotal : 1,
    );
    final body = batchTotal > 1
        ? batchSeries != null
              ? l10n.downloadNotificationSeriesEpisodes(batchSeries, batchTotal)
              : l10n.downloadNotificationSavedCount(batchTotal)
        : l10n.downloadNotificationSaved(itemName);
    await _showSimple(
      _completionNotificationId, title, body,
      androidChannel: alertChannel,
    );
  }

  /// [transfersRemain] keeps the foreground service up when other downloads
  /// are still running. Android refuses to start one again from the
  /// background, so taking it down for one failure would drop the rest to
  /// ordinary background work and lose them too.
  Future<void> showError({
    required String itemName,
    required String error,
    bool transfersRemain = false,
  }) async {
    if (!_initialized) return;
    _lastProgressSignature = null;
    if (!PlatformDetection.isAndroid && !transfersRemain) {
      await _stopForegroundService();
    }
    final l10n = currentAppLocalizations();
    await _showSimple(
      _completionNotificationId,
      l10n.downloadNotificationFailedTitle,
      l10n.downloadNotificationFailedBody(itemName, error),
      androidChannel: alertChannel,
    );
  }

  /// The automatic check held new episodes back for lack of space.
  Future<void> showStorageFull({
    required int count,
    required String firstLabel,
    required String firstSize,
  }) async {
    if (!_initialized) return;
    final l10n = currentAppLocalizations();
    await _showSimple(
      _storageNotificationId,
      l10n.autoDownloadStorageFullTitle,
      l10n.autoDownloadStorageFullBody(count, firstLabel, firstSize),
      androidChannel: alertChannel,
    );
  }

  /// Says whether the message actually reached a notification. A device with
  /// notifications switched off or never initialized answers false, and the
  /// caller then has to put the message somewhere the user will still see it.
  Future<bool> showRemoteMessage({
    required String text,
    String? header,
  }) async {
    if (!_initialized) return false;
    final l10n = currentAppLocalizations();
    final title = (header != null && header.trim().isNotEmpty)
        ? header.trim()
        : l10n.serverMessagesNotificationTitle;
    final body = text.trim().isNotEmpty
        ? text.trim()
        : l10n.serverMessagesNotificationReceived;
    await _showSimple(_remoteMessageNotificationId, title, body);
    return true;
  }

  Future<void> dismiss() async {
    if (!_initialized) return;
    _lastProgressSignature = null;
    if (!PlatformDetection.isAndroid) {
      await _stopForegroundService();
      await _plugin.cancel(id: _progressNotificationId);
      return;
    }
    final cards = _cards.clear();
    _cancelCallbacks.clear();
    _latest.clear();
    _lastAndroidUpdate.clear();
    _lastAndroidSignature.clear();
    await _serialize(() async {
      for (final card in cards) {
        try {
          await _plugin.cancel(id: card.notificationId);
        } catch (e) {
          debugPrint('[DownloadNotification] Cancel All cleanup failed: $e');
        }
      }
      if (_cards.count == 0) await _stopForegroundService();
    });
  }

  static AndroidNotificationDetails androidProgressDetails(
    int percent, {
    required String actionId,
    String cancelLabel = 'Cancel',
  }) => AndroidNotificationDetails(
    progressChannel.id,
    progressChannel.name,
    channelDescription: progressChannel.description,
    importance: Importance.low,
    priority: Priority.low,
    playSound: false,
    enableVibration: false,
    silent: true,
    onlyAlertOnce: true,
    ongoing: true,
    autoCancel: false,
    showWhen: false,
    groupKey: _groupKey,
    showProgress: true,
    maxProgress: 100,
    progress: percent >= 0 ? percent : 0,
    indeterminate: percent < 0,
    actions: [
      AndroidNotificationAction(
        actionId,
        cancelLabel,
        showsUserInterface: false,
        cancelNotification: false,
      ),
    ],
    category: AndroidNotificationCategory.progress,
  );

  static AndroidNotificationDetails androidForegroundDetails() =>
      AndroidNotificationDetails(
        progressChannel.id,
        progressChannel.name,
        channelDescription: progressChannel.description,
        importance: Importance.low,
        priority: Priority.low,
        playSound: false,
        enableVibration: false,
        silent: true,
        onlyAlertOnce: true,
        ongoing: true,
        autoCancel: false,
        showWhen: false,
        groupKey: _groupKey,
        setAsGroupSummary: true,
        category: AndroidNotificationCategory.progress,
      );

  Future<void> _ensureForeground() async {
    if (_foregroundServiceRunning) return;
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) {
      throw StateError('Android foreground notifications unavailable');
    }
    await android.startForegroundService(
      id: _progressNotificationId,
      title: currentAppLocalizations().downloadNotificationRunning,
      body: '',
      notificationDetails: androidForegroundDetails(),
      foregroundServiceTypes: {
        AndroidServiceForegroundType.foregroundServiceTypeDataSync,
      },
    );
    _foregroundServiceRunning = true;
  }

  Future<void> _showStandardProgress(
      String title, String body, int percent) async {
    await _plugin.show(
      id: _progressNotificationId,
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(
        iOS: DarwinNotificationDetails(),
        macOS: DarwinNotificationDetails(),
        linux: LinuxNotificationDetails(),
      ),
    );
  }

  Future<void> _showSimple(
    int id, String title, String body, {
    AndroidNotificationChannel androidChannel = serverMessageChannel,
  }) async {
    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          androidChannel.id,
          androidChannel.name,
          channelDescription: androidChannel.description,
          importance: androidChannel.importance,
          priority: Priority.defaultPriority,
          playSound: androidChannel.playSound,
          enableVibration: androidChannel.enableVibration,
          autoCancel: true,
        ),
        iOS: const DarwinNotificationDetails(),
        macOS: const DarwinNotificationDetails(),
        linux: const LinuxNotificationDetails(),
      ),
    );
  }

  Future<void> _stopForegroundService() async {
    if (!_foregroundServiceRunning) return;
    try {
      final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (androidPlugin == null) return;
      await androidPlugin.stopForegroundService();
      _foregroundServiceRunning = false;
    } catch (e) {
      // Leave the flag true: stopping another episode must never make a
      // currently running transfer look as if foreground protection vanished.
      debugPrint('[DownloadNotification] Foreground stop failed: $e');
    }
  }
}
