import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../l10n/current_app_localizations.dart';
import '../../util/platform_detection.dart';
import 'local_notification_bootstrap.dart';
import 'download_progress_notification_registry.dart';

class DownloadNotificationService {
  // Android doesn't allow an existing channel's sound or vibration to be
  // changed. The old moonfin_downloads channel mixed audible completion
  // alerts with rapidly updated progress, so use a fresh silent channel ID.
  static const progressChannel = AndroidNotificationChannel(
    'moonfin_download_progress_silent_v1',
    'Download progress',
    description: 'Silent progress for offline media downloads',
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

  // Preserve the existing channel for unrelated server messages. Only the
  // download progress and alerts channels are new in this change.
  static const serverMessageChannel = AndroidNotificationChannel(
    'moonfin_downloads',
    'Downloads',
    description: 'Shows download progress for offline media',
  );

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

  Future<void>? _pendingNotification;

  // Android needs one notification owned by its foreground service. Other
  // concurrent in-process transfers get their own progress cards, with one
  // of them promoted into the foreground slot when its owner finishes.
  final DownloadProgressNotificationRegistry _androidProgress =
      DownloadProgressNotificationRegistry();
  final Map<String, DateTime> _lastAndroidUpdate = {};
  final Map<String, String> _lastAndroidSignature = {};
  final Map<String, int> _progressGenerations = {};
  final Set<String> _finishedProgress = {};
  int _dismissGeneration = 0;

  // Serializes starts, updates, cancellation and owner promotion. A single
  // foreground-service notification must never be replaced out of order.
  Future<void> _serializeNotification(Future<void> Function() action) async {
    final previous = _pendingNotification;
    final completer = Completer<void>();
    _pendingNotification = completer.future;
    try {
      if (previous != null) await previous;
      await action();
    } finally {
      completer.complete();
    }
  }

  Future<void> initialize() async {
    if (_initialized) return;

    await LocalNotificationBootstrap.instance.initialize();
    _initialized = true;

    if (PlatformDetection.isAndroid) {
      final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      // Register every channel before showing notifications. A separate
      // channel keeps the progress card silent without muting errors.
      try {
        for (final channel in const [
          progressChannel,
          alertChannel,
        ]) {
          await androidPlugin?.createNotificationChannel(channel);
        }
      } catch (_) {}
      try {
        await androidPlugin?.requestNotificationsPermission();
      } catch (_) {}
    }
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
  }) async {
    if (!_initialized) return;

    if (PlatformDetection.isAndroid) {
      // Mark a retry as a new lifetime. Late updates from an earlier transfer
      // are rejected by its generation before they can recreate a card.
      if (startNewTransfer) {
        _finishedProgress.remove(itemId);
        _progressGenerations[itemId] =
            (_progressGenerations[itemId] ?? 0) + 1;
      } else if (_finishedProgress.contains(itemId)) {
        return;
      }
      final generation = _progressGenerations[itemId] ?? 0;
      final dismissGeneration = _dismissGeneration;
      try {
        await _serializeNotification(() async {
          if (_progressGenerations[itemId] != generation ||
              _finishedProgress.contains(itemId) ||
              _dismissGeneration != dismissGeneration) {
            return;
          }

          final percent = progress >= 0 ? (progress * 100).round() : -1;
          final signature = '$itemName/$percent';
          if (_lastAndroidSignature[itemId] == signature) return;
          final now = DateTime.now();
          final last = _lastAndroidUpdate[itemId];
          if (!startNewTransfer &&
              last != null &&
              now.difference(last).inMilliseconds < 1500) {
            return;
          }

          final l10n = currentAppLocalizations();
          final body = percent >= 0
              ? l10n.downloadNotificationProgress(itemName, percent)
              : l10n.downloadNotificationStarting(itemName);
          final snapshot = _androidProgress.update(
            itemId: itemId,
            title: l10n.downloadNotificationRunning,
            body: body,
            percent: percent,
          );
          await _postAndroidProgress(snapshot);
          _lastAndroidUpdate[itemId] = now;
          _lastAndroidSignature[itemId] = signature;
        });
      } catch (_) {
        // A notification failure must never fail a download.
      }
      return;
    }

    // Keep the existing single-card behaviour on platforms whose background
    // download notifications are managed differently.
    final percent = progress >= 0 ? (progress * 100).round() : -1;
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
    final dismissGeneration = _dismissGeneration;
    try {
      await _serializeNotification(() async {
        if (_dismissGeneration != dismissGeneration) return;
        await _showStandardProgress(title, body, percent);
      });
    } catch (_) {}
  }

  /// Removes only the completed, failed or cancelled transfer's card. If it
  /// owned the foreground service, move an existing active transfer into that
  /// slot before cancelling its old ordinary notification. No extra summary
  /// card is needed, so N active transfers display exactly N progress cards.
  Future<void> finishProgress(
    String itemId, {
    bool keepForegroundService = false,
  }) async {
    if (!_initialized || !PlatformDetection.isAndroid) return;
    _finishedProgress.add(itemId);
    _progressGenerations[itemId] =
        (_progressGenerations[itemId] ?? 0) + 1;
    _lastAndroidUpdate.remove(itemId);
    _lastAndroidSignature.remove(itemId);
    try {
      await _serializeNotification(() async {
        final removal = _androidProgress.remove(itemId);
        if (removal == null) return;
        if (removal.wasForeground) {
          final promoted = removal.promoted;
          if (promoted != null) {
            await _postAndroidProgress(promoted);
            await _plugin.cancel(id: removal.promotedFromId!);
          } else if (keepForegroundService) {
            // Another transcoded transfer is queued or preparing. Android
            // may refuse to restart a dataSync foreground service from the
            // background, so hold its existing ID across this short gap.
            // Replace the completed episode with a silent indeterminate card
            // until the next episode takes ownership of the same ID.
            final title = currentAppLocalizations().downloadNotificationRunning;
            await _plugin.show(
              id: DownloadProgressNotificationRegistry.foregroundId,
              title: title,
              body: '',
              notificationDetails: NotificationDetails(
                android: androidProgressDetails(-1),
              ),
            );
          } else {
            await _stopForegroundService();
            await _plugin.cancel(
              id: DownloadProgressNotificationRegistry.foregroundId,
            );
          }
        } else {
          await _plugin.cancel(id: removal.removedId);
        }
      });
    } catch (_) {
      // Cleanup is best-effort: the transfer itself has already ended.
    }
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
    // Android foreground ownership is ended by finishProgress for the final
    // active transfer, not by a completion from another concurrent engine.
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
      _completionNotificationId,
      title,
      body,
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
    // Do not take down the Android foreground service for an unrelated
    // failure: finishProgress alone decides whether any local transfers
    // remain. The native downloader owns its own foreground service.
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
    await _showSimple(
      _remoteMessageNotificationId,
      title,
      body,
      androidChannel: serverMessageChannel,
    );
    return true;
  }

  Future<void> dismiss() async {
    if (!_initialized) return;
    _dismissGeneration++;
    _lastProgressSignature = null;
    _finishedProgress.addAll(_progressGenerations.keys);
    _lastAndroidUpdate.clear();
    _lastAndroidSignature.clear();
    try {
      await _serializeNotification(() async {
        final notificationIds = _androidProgress.clear();
        for (final id in notificationIds) {
          if (id != DownloadProgressNotificationRegistry.foregroundId) {
            try {
              await _plugin.cancel(id: id);
            } catch (_) {
              // A failed extra-card cancellation must not skip service stop.
            }
          }
        }
        await _stopForegroundService();
        try {
          await _plugin.cancel(
            id: DownloadProgressNotificationRegistry.foregroundId,
          );
        } catch (_) {}

      });
    } catch (_) {}
  }

  // Shared by foreground-service startup and later progress updates; both
  // must use the exact same silent channel and no-alert flags.
  static AndroidNotificationDetails androidProgressDetails(
    int percent, {
    int? when,
  }) {
    return AndroidNotificationDetails(
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
      when: when,
      showProgress: true,
      maxProgress: 100,
      progress: percent >= 0 ? percent : 0,
      indeterminate: percent < 0,
      category: AndroidNotificationCategory.progress,
    );
  }

  Future<void> _postAndroidProgress(
    DownloadProgressNotificationSnapshot snapshot,
  ) async {
    final details = androidProgressDetails(
      snapshot.percent,
      when: snapshot.createdAtMillis,
    );
    if (snapshot.notificationId !=
        DownloadProgressNotificationRegistry.foregroundId) {
      await _plugin.show(
        id: snapshot.notificationId,
        title: snapshot.title,
        body: snapshot.body,
        notificationDetails: NotificationDetails(android: details),
      );
      return;
    }

    if (!_foregroundServiceRunning) {
      try {
        final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
        if (androidPlugin == null) {
          throw StateError('Android notifications are unavailable');
        }
        await androidPlugin.startForegroundService(
          id: DownloadProgressNotificationRegistry.foregroundId,
          title: snapshot.title,
          body: snapshot.body,
          notificationDetails: details,
          foregroundServiceTypes: {
            AndroidServiceForegroundType.foregroundServiceTypeDataSync,
          },
        );
        _foregroundServiceRunning = true;
        return;
      } catch (_) {
        // Keep a visible silent progress card even if Android rejects the
        // foreground start. The next update can attempt the service again.
      }
    }

    await _plugin.show(
      id: DownloadProgressNotificationRegistry.foregroundId,
      title: snapshot.title,
      body: snapshot.body,
      notificationDetails: NotificationDetails(android: details),
    );
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

  static AndroidNotificationDetails androidAlertDetails(
    AndroidNotificationChannel channel,
  ) {
    return AndroidNotificationDetails(
      channel.id,
      channel.name,
      channelDescription: channel.description,
      importance: channel.importance,
      priority: Priority.defaultPriority,
      playSound: channel.playSound,
      enableVibration: channel.enableVibration,
      autoCancel: true,
    );
  }

  Future<void> _showSimple(
    int id,
    String title,
    String body, {
    required AndroidNotificationChannel androidChannel,
  }) async {
    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: androidAlertDetails(androidChannel),
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
      await androidPlugin
          ?.stopForegroundService()
          .timeout(const Duration(seconds: 5));
    } catch (_) {
    }
    _foregroundServiceRunning = false;
    try {
      await _plugin.cancel(id: _progressNotificationId)
          .timeout(const Duration(seconds: 5));
    } catch (_) {
    }
  }
}
