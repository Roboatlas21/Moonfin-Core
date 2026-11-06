import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../l10n/current_app_localizations.dart';
import '../../util/platform_detection.dart';
import 'download_progress_notification_registry.dart';
import 'local_notification_bootstrap.dart';

class DownloadNotificationService {
  static const _operationTimeout = Duration(seconds: 5);

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
  bool get isInitialized => _initialized;
  DateTime _lastUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  bool _foregroundServiceRunning = false;
  String? _lastProgressSignature;

  Future<void>? _pendingNotification;

  // Android needs one notification owned by its foreground service. Other
  // concurrent in-process transfers get their own progress cards, with one
  // of them promoted into the foreground slot when its owner finishes.
  final DownloadProgressNotificationRegistry _androidProgress =
      DownloadProgressNotificationRegistry();
  // Captures the owner of each running download, even if the user switches
  // Jellyfin servers while that transfer is still finishing.
  final Map<String, void Function()> _androidCancelHandlers = {};
  final Map<String, DateTime> _lastAndroidUpdate = {};
  final Map<String, String> _lastAndroidSignature = {};
  // The active generation map is cleared on completion/cancellation. Tokens
  // never repeat, so stale updates cannot revive a finished transfer card.
  final Map<String, int> _activeProgressGenerations = {};
  int _nextProgressGeneration = 0;
  final DownloadProgressUpdateBuffer<({
    String itemName,
    double progress,
    int generation,
    int dismissGeneration,
    bool startNewTransfer,
  })> _pendingAndroidProgress = DownloadProgressUpdateBuffer();
  final Set<int> _pendingCancellationIds = {};
  int _dismissGeneration = 0;
  Future<void>? _initializeFuture;
  bool _staleProgressReconciled = false;

  // Serializes starts, updates, cancellation and owner promotion. A single
  // foreground-service notification must never be replaced out of order.
  Future<void> _serializeNotification(Future<void> Function() action) async {
    final previous = _pendingNotification;
    final completer = Completer<void>();
    _pendingNotification = completer.future;
    try {
      if (previous != null) await previous;
      if (_pendingCancellationIds.isNotEmpty) {
        await _retryPendingCancellations();
      }
      await action();
    } finally {
      completer.complete();
    }
  }

  Future<void> initialize() async {
    final previous = _initializeFuture;
    if (previous != null) {
      await previous;
      return;
    }
    final task = _initialize();
    _initializeFuture = task;
    try {
      await task;
    } catch (_) {
      // A failed initial bootstrap must be retryable on the next attempt.
      if (identical(_initializeFuture, task)) _initializeFuture = null;
      rethrow;
    }
  }

  Future<void> _initialize() async {
    if (_initialized) return;
    await LocalNotificationBootstrap.instance.initialize();
    if (PlatformDetection.isAndroid) {
      final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      for (final channel in const [progressChannel, alertChannel]) {
        try {
          if (androidPlugin != null) {
            await androidPlugin
                .createNotificationChannel(channel)
                .timeout(_operationTimeout);
          }
        } catch (e) {
          debugPrint('[DownloadNotification] Channel registration failed: $e');
        }
      }
      // Stale progress cleanup is intentionally not performed here. A
      // headless auto-download worker also initializes this service, and
      // must never stop the main engine's active foreground download.
      // The Android permission prompt waits for user interaction. Do not
      // block download startup while the prompt is open.
      if (androidPlugin != null) {
        unawaited(
          androidPlugin.requestNotificationsPermission().then(
            (_) {},
            onError: (Object e) {
              debugPrint('[DownloadNotification] Permission request failed: $e');
            },
          ),
        );
      }
    }
    _initialized = true;
    if (PlatformDetection.isAndroid) {
      LocalNotificationBootstrap.instance.downloadCancelActionHandler =
          handleCancelAction;
    }
  }

  /// Only the interactive app's cold startup calls this. A worker or second
  /// Flutter engine must not interpret a live download as stale.
  Future<void> reconcileStaleProgressOnColdStart() async {
    if (!PlatformDetection.isAndroid || !_initialized ||
        _staleProgressReconciled) return;
    _staleProgressReconciled = true;
    if (_foregroundServiceRunning || _androidProgress.activeCount != 0) return;
    try {
      final active = await _plugin
          .getActiveNotifications()
          .timeout(const Duration(seconds: 5));
      for (final notification in active) {
        if (isOwnProgressNotification(notification.id, notification.channelId)) {
          // Cancel the obsolete Moonfin progress card, not the system's
          // background_downloader channel or an unrelated alert. Do not call
          // stopForegroundService here: a live engine might own it.
          await _cancelProgressId(notification.id);
        }
      }
    } catch (e) {
      debugPrint('[DownloadNotification] Cold-start cleanup failed: $e');
    }
  }

  /// Called on the main isolate after an Android notification action is
  /// forwarded. Reject old actions; they cannot cancel a reused notification
  /// ID, a different episode, or a retry of the same episode.
  bool handleCancelAction(String actionId) {
    if (!_initialized || !PlatformDetection.isAndroid) return false;
    final target = _androidProgress.targetForCancelAction(actionId);
    if (target == null ||
        !_activeProgressGenerations.containsKey(target.itemId)) {
      return false;
    }
    final cancel = _androidCancelHandlers[target.itemId];
    if (cancel == null) return false;
    try {
      cancel();
      return true;
    } catch (e) {
      debugPrint('[DownloadNotification] Cancel action failed: $e');
      return false;
    }
  }

  static bool isOwnProgressNotification(int id, String? channelId) =>
      channelId == progressChannel.id &&
      (id == DownloadProgressNotificationRegistry.foregroundId ||
          id >= DownloadProgressNotificationRegistry.firstAdditionalId);

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
    if (!_initialized) return;

    if (PlatformDetection.isAndroid) {
      if (startNewTransfer) {
        _activeProgressGenerations[itemId] = ++_nextProgressGeneration;
        if (onCancel != null) {
          _androidCancelHandlers[itemId] = onCancel;
        } else {
          _androidCancelHandlers.remove(itemId);
        }
      } else if (!_activeProgressGenerations.containsKey(itemId)) {
        return;
      }
      // Coalesce per episode before entering the native notification queue.
      // Only the latest pending state for that episode is retained.
      if (!_pendingAndroidProgress.offer(itemId, (
        itemName: itemName,
        progress: progress,
        generation: _activeProgressGenerations[itemId]!,
        dismissGeneration: _dismissGeneration,
        startNewTransfer: startNewTransfer,
      ))) {
        return;
      }

      try {
        await _serializeNotification(() async {
          try {
            while (true) {
              final next = _pendingAndroidProgress.take(itemId);
              if (next == null) break;
              if (_activeProgressGenerations[itemId] != next.generation ||
                  _dismissGeneration != next.dismissGeneration) {
                continue;
              }

              final percent =
                  next.progress >= 0 ? (next.progress * 100).round() : -1;
              final signature = '${next.itemName}/$percent';
              if (_lastAndroidSignature[itemId] == signature) continue;
              final now = DateTime.now();
              final last = _lastAndroidUpdate[itemId];
              if (!next.startNewTransfer &&
                  last != null &&
                  now.difference(last).inMilliseconds < 1500) {
                continue;
              }
              final l10n = currentAppLocalizations();
              final body = percent >= 0
                  ? l10n.downloadNotificationProgress(next.itemName, percent)
                  : l10n.downloadNotificationStarting(next.itemName);
              final snapshot = _androidProgress.update(
                itemId: itemId,
                title: l10n.downloadNotificationRunning,
                body: body,
                percent: percent,
              );
              try {
                await _postAndroidProgress(snapshot);
                _lastAndroidUpdate[itemId] = DateTime.now();
                _lastAndroidSignature[itemId] = signature;
              } catch (e) {
                debugPrint(
                  '[DownloadNotification] Progress failed for $itemId: $e',
                );
              }
            }
          } finally {
            _pendingAndroidProgress.release(itemId);
          }
        });
      } catch (e) {
        _pendingAndroidProgress.release(itemId);
        _pendingAndroidProgress.discard(itemId);
        debugPrint('[DownloadNotification] Progress queue failed: $e');
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
    _activeProgressGenerations.remove(itemId);
    _androidCancelHandlers.remove(itemId);
    _pendingAndroidProgress.discard(itemId);
    _lastAndroidUpdate.remove(itemId);
    _lastAndroidSignature.remove(itemId);
    try {
      await _serializeNotification(() async {
        final removal = _androidProgress.remove(itemId);
        if (removal == null) return;
        if (removal.wasForeground) {
          final promoted = removal.promoted;
          if (promoted != null) {
            try {
              await _postAndroidProgress(promoted);
            } catch (e) {
              debugPrint('[DownloadNotification] Foreground handoff failed: $e');
              // Retry once through the ordinary silent notification API.
              // Also allow a subsequent unchanged progress value to retry.
              _lastAndroidUpdate.remove(promoted.itemId);
              _lastAndroidSignature.remove(promoted.itemId);
              try {
                await _plugin
                    .show(
                      id: DownloadProgressNotificationRegistry.foregroundId,
                      title: promoted.title,
                      body: promoted.body,
                      notificationDetails: NotificationDetails(
                        android: androidProgressDetails(
                          promoted.percent,
                          when: promoted.createdAtMillis,
                          cancelActionId: promoted.cancelActionId,
                          cancelLabel: currentAppLocalizations().cancel,
                        ),
                      ),
                    )
                    .timeout(_operationTimeout);
              } catch (retryError) {
                debugPrint(
                  '[DownloadNotification] Foreground fallback failed: '
                  '$retryError',
                );
              }
            } finally {
              // Do not leak the old ordinary card, even if promotion failed.
              await _cancelProgressId(removal.promotedFromId!);
            }
          } else if (keepForegroundService) {
            // Another transcoded transfer is queued or preparing. Android
            // may refuse to restart a dataSync foreground service from the
            // background, so hold its existing ID across this short gap.
            // Replace the completed episode with a silent indeterminate card
            // until the next episode takes ownership of the same ID.
            final title = currentAppLocalizations().downloadNotificationRunning;
            try {
              await _plugin
                  .show(
                    id: DownloadProgressNotificationRegistry.foregroundId,
                    title: title,
                    body: '',
                    notificationDetails: NotificationDetails(
                      android: androidProgressDetails(-1),
                    ),
                  )
                  .timeout(_operationTimeout);
            } catch (e) {
              debugPrint('[DownloadNotification] Hold card failed: $e');
            }
          } else {
            await _stopForegroundService();
            if (!_foregroundServiceRunning) {
              await _cancelProgressId(
                DownloadProgressNotificationRegistry.foregroundId,
              );
            }
          }
        } else {
          await _cancelProgressId(removal.removedId);
        }
      });
    } catch (e) {
      debugPrint('[DownloadNotification] Finish cleanup failed: $e');
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
    _activeProgressGenerations.clear();
    _androidCancelHandlers.clear();
    _pendingAndroidProgress.clear();
    _lastAndroidUpdate.clear();
    _lastAndroidSignature.clear();
    try {
      await _serializeNotification(() async {
        final ids = _androidProgress.clear();
        for (final id in ids) {
          if (id != DownloadProgressNotificationRegistry.foregroundId) {
            await _cancelProgressId(id);
          }
        }
        await _stopForegroundService();
        if (!_foregroundServiceRunning) {
          await _cancelProgressId(
            DownloadProgressNotificationRegistry.foregroundId,
          );
        }
      });
    } catch (e) {
      debugPrint('[DownloadNotification] Dismiss failed: $e');
    }
  }

  /// Ends a retained foreground-service placeholder after a batch, without
  /// interrupting any other active standalone or concurrently queued work.
  Future<void> releaseIdleForegroundService() async {
    if (!_initialized || !PlatformDetection.isAndroid) return;
    try {
      await _serializeNotification(() async {
        if (_activeProgressGenerations.isNotEmpty ||
            _androidProgress.activeCount > 0) {
          return;
        }
        await _stopForegroundService();
        if (!_foregroundServiceRunning) {
          await _cancelProgressId(
            DownloadProgressNotificationRegistry.foregroundId,
          );
        }
      });
    } catch (e) {
      debugPrint('[DownloadNotification] Idle release failed: $e');
    }
  }

  Future<void> _cancelProgressId(int id) async {
    try {
      await _plugin.cancel(id: id).timeout(_operationTimeout);
      _pendingCancellationIds.remove(id);
    } catch (e) {
      _pendingCancellationIds.add(id);
      debugPrint('[DownloadNotification] Cancel $id failed: $e');
    }
  }

  /// The background_downloader fork pins its native notification ID to
  /// Java's String.hashCode(taskId). Keep its quiet failure card when Dart
  /// was killed; after our audible alert posts, remove the redundant card.
  Future<void> dismissNativeFailureCard(String taskId) async {
    if (!_initialized || !PlatformDetection.isAndroid) return;
    try {
      // The plugin queues terminal-state notifications asynchronously.
      await Future<void>.delayed(const Duration(milliseconds: 350));
      await _plugin
          .cancel(id: androidNativeTaskNotificationId(taskId))
          .timeout(const Duration(seconds: 4));
    } catch (e) {
      debugPrint('[DownloadNotification] Native error cleanup failed: $e');
    }
  }

  Future<void> _retryPendingCancellations() async {
    for (final id in _pendingCancellationIds.toList()) {
      if (_androidProgress.usesNotificationId(id) ||
          (id == DownloadProgressNotificationRegistry.foregroundId &&
              _foregroundServiceRunning)) {
        continue;
      }
      await _cancelProgressId(id);
    }
  }

  // Shared by foreground-service startup and later progress updates; both
  // must use the exact same silent channel and no-alert flags.
  static AndroidNotificationDetails androidProgressDetails(
    int percent, {
    int? when,
    String? cancelActionId,
    String cancelLabel = 'Cancel',
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
      actions: cancelActionId == null
          ? null
          : [
              AndroidNotificationAction(
                cancelActionId,
                cancelLabel,
                showsUserInterface: false,
                // Leave the foreground service running until the transfer's
                // normal cancellation cleanup removes or promotes its card.
                cancelNotification: false,
              ),
            ],
      category: AndroidNotificationCategory.progress,
    );
  }

  Future<void> _postAndroidProgress(
    DownloadProgressNotificationSnapshot snapshot,
  ) async {
    final details = androidProgressDetails(
      snapshot.percent,
      when: snapshot.createdAtMillis,
      cancelActionId: snapshot.cancelActionId,
      cancelLabel: currentAppLocalizations().cancel,
    );
    if (snapshot.notificationId !=
        DownloadProgressNotificationRegistry.foregroundId) {
      await _plugin
          .show(
            id: snapshot.notificationId,
            title: snapshot.title,
            body: snapshot.body,
            notificationDetails: NotificationDetails(android: details),
          )
          .timeout(_operationTimeout);
      return;
    }

    if (!_foregroundServiceRunning) {
      try {
        final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
        if (androidPlugin == null) {
          throw StateError('Android notifications are unavailable');
        }
        await androidPlugin
            .startForegroundService(
              id: DownloadProgressNotificationRegistry.foregroundId,
              title: snapshot.title,
              body: snapshot.body,
              notificationDetails: details,
              foregroundServiceTypes: {
                AndroidServiceForegroundType.foregroundServiceTypeDataSync,
              },
            )
            .timeout(_operationTimeout);
        _foregroundServiceRunning = true;
        return;
      } catch (e) {
        // Do not block a transfer forever on Android's notification IPC.
        // A regular silent card remains visible if foreground startup fails.
        debugPrint('[DownloadNotification] Foreground start failed: $e');
      }
    }

    await _plugin
        .show(
          id: DownloadProgressNotificationRegistry.foregroundId,
          title: snapshot.title,
          body: snapshot.body,
          notificationDetails: NotificationDetails(android: details),
        )
        .timeout(_operationTimeout);
  }

  Future<void> _showStandardProgress(
      String title, String body, int percent) async {
    await _plugin
        .show(
          id: _progressNotificationId,
          title: title,
          body: body,
          notificationDetails: const NotificationDetails(
            iOS: DarwinNotificationDetails(),
            macOS: DarwinNotificationDetails(),
            linux: LinuxNotificationDetails(),
          ),
        )
        .timeout(_operationTimeout);
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
    await _plugin
        .show(
          id: id,
          title: title,
          body: body,
          notificationDetails: NotificationDetails(
            android: androidAlertDetails(androidChannel),
            iOS: const DarwinNotificationDetails(),
            macOS: const DarwinNotificationDetails(),
            linux: const LinuxNotificationDetails(),
          ),
        )
        .timeout(_operationTimeout);
  }

  Future<void> _stopForegroundService() async {
    if (!_foregroundServiceRunning) return;
    try {
      final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (androidPlugin == null) {
        throw StateError('Android notification plugin unavailable');
      }
      await androidPlugin
          .stopForegroundService()
          .timeout(const Duration(seconds: 5));
      _foregroundServiceRunning = false;
      await _cancelProgressId(
        DownloadProgressNotificationRegistry.foregroundId,
      );
    } catch (e) {
      // Keep the running flag so a later cleanup attempt can retry the stop.
      debugPrint('[DownloadNotification] Foreground stop failed: $e');
    }
  }
}
