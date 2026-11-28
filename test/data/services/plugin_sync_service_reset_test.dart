import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moonfin/auth/repositories/session_repository.dart';
import 'package:moonfin/data/services/incomplete_recordings_service.dart';
import 'package:moonfin/data/services/plugin_sync_service.dart';
import 'package:moonfin/preference/seerr_preferences.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:server_core/server_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockClient extends Mock implements MediaServerClient {}

class _MockSessionRepository extends Mock implements SessionRepository {}

/// Serves canned plugin responses and records every request, so the tests can
/// assert exactly which calls the reset made.
class _RecordingAdapter implements HttpClientAdapter {
  final List<String> requests = [];
  Map<String, dynamic>? postedProfile;

  /// Body returned for the Resolved endpoint, replaceable per test.
  Map<String, dynamic> resolvedProfile = {};

  /// Set when the server should refuse to delete.
  bool failDeletes = false;
  Future<void> Function(String method, String path)? beforeResponse;

  /// Set when nothing is left to resolve after a delete.
  bool failResolved = false;

  /// What the ping says about incomplete recordings.
  bool incompleteRecordingsSupported = false;

  /// The notification choices the server keeps for the user.
  Map<String, dynamic> notificationPrefs = {};

  /// Set when the server should refuse to save notification choices.
  bool failNotificationPosts = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    requests.add('${options.method} $path');
    await beforeResponse?.call(options.method, path);

    if (options.method == 'DELETE') {
      return ResponseBody.fromString('', failDeletes ? 500 : 200);
    }

    Map<String, dynamic>? body;
    if (path.endsWith('/Moonfin/Notifications/Prefs')) {
      if (options.method == 'POST') {
        return ResponseBody.fromString('', failNotificationPosts ? 500 : 204);
      }
      body = notificationPrefs;
    } else if (path.endsWith('/Moonfin/Ping')) {
      body = {
        'installed': true,
        'settingsSyncEnabled': true,
        'incompleteRecordingsSupported': incompleteRecordingsSupported,
      };
    } else if (path.contains('/Moonfin/Settings/Resolved/')) {
      body = failResolved ? null : resolvedProfile;
    } else if (path.contains('/Moonfin/Settings/Profile/')) {
      if (options.method == 'POST') postedProfile = options.data['profile'];
      body = {};
    }

    if (body == null) {
      return ResponseBody.fromString('', 404);
    }
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _RecordingAdapter adapter;
  late UserPreferences prefs;
  late PluginSyncService service;
  late _MockClient client;

  int postCount() => adapter.requests
      .where((r) => r.startsWith('POST') && r.contains('/Settings/Profile/'))
      .length;

  /// Waits out the 1000ms push debounce plus slack.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 1400));

  setUp(() async {
    SharedPreferences.setMockInitialValues({'pref_last_server_id': 'srv1'});
    final store = PreferenceStore();
    await store.init();
    prefs = UserPreferences(store);

    final session = _MockSessionRepository();
    when(() => session.activeUserId).thenReturn('user1');
    GetIt.instance.registerSingleton<SeerrPreferences>(
      SeerrPreferences(store, session),
    );

    client = _MockClient();
    when(() => client.baseUrl).thenReturn('http://plugin.test');
    when(() => client.accessToken).thenReturn('token');
    when(() => client.serverType).thenReturn(ServerType.jellyfin);
    when(() => client.deviceInfo).thenReturn(
      const DeviceInfo(
        id: 'dev1',
        name: 'test',
        appName: 'moonfin',
        appVersion: '0.0.0',
      ),
    );

    adapter = _RecordingAdapter();
    final dio = Dio();
    dio.httpClientAdapter = adapter;
    service = PluginSyncService(prefs, store, dio: dio);

    await prefs.set(UserPreferences.pluginSyncEnabled, true);
    expect(await service.refreshAvailability(client), isTrue);
    GetIt.instance.registerSingleton<MediaServerClient>(client);
    adapter.requests.clear();
  });

  tearDown(() async {
    await GetIt.instance.reset();
  });

  test('a device profile reset deletes it and reloads what is left', () async {
    final ok = await service.resetProfileToDefaults(client, profile: 'desktop');

    expect(ok, isTrue);
    expect(
      adapter.requests,
      containsAllInOrder([
        'DELETE /Moonfin/Settings/Profile/desktop',
        'GET /Moonfin/Settings/Resolved/desktop',
      ]),
    );
  });

  test('resetting global deletes the whole settings file', () async {
    final ok = await service.resetProfileToDefaults(client, profile: 'global');

    expect(ok, isTrue);
    expect(adapter.requests, contains('DELETE /Moonfin/Settings'));
  });

  test('only a successful global reset discards pending guide pins', () async {
    const pins = ['group:Sports'];
    const edits = ['add:group:Sports'];
    await prefs.set(UserPreferences.liveTvSavedFilters, pins);
    await prefs.set(UserPreferences.liveTvSavedFilterChanges, edits);
    adapter.failDeletes = true;
    expect(
      await service.resetProfileToDefaults(client, profile: 'global'),
      isFalse,
    );
    adapter.failDeletes = false;
    expect(await service.resetProfileToDefaults(client, profile: 'desktop'), isTrue);
    expect(adapter.requests, contains('DELETE /Moonfin/Settings/Profile/desktop'));
    expect(prefs.get(UserPreferences.liveTvSavedFilters), pins);
    expect(prefs.get(UserPreferences.liveTvSavedFilterChanges), edits);
    adapter.requests.clear();
    adapter.resolvedProfile = {
      'liveTvSavedFilters': ['group:Admin'],
    };
    expect(
      await service.resetProfileToDefaults(client, profile: 'global'),
      isTrue,
    );
    expect(prefs.get(UserPreferences.liveTvSavedFilters), ['group:Admin']);
    expect(prefs.get(UserPreferences.liveTvSavedFilterChanges), isEmpty);
    expect(adapter.requests.where((r) => r.startsWith('POST')), isEmpty);
  });

  test('a changed setting is back to its default afterwards', () async {
    await prefs.set(UserPreferences.use24HourClock, true);
    expect(prefs.get(UserPreferences.use24HourClock), isTrue);

    await service.resetProfileToDefaults(client, profile: 'desktop');

    expect(prefs.get(UserPreferences.use24HourClock), isFalse);
  });

  test('what the server still resolves lands on top of the defaults', () async {
    adapter.resolvedProfile = {'use24HourClock': true};

    await service.resetProfileToDefaults(client, profile: 'desktop');

    expect(prefs.get(UserPreferences.use24HourClock), isTrue);
  });

  test('the reset never pushes the cleared settings back', () async {
    await prefs.set(UserPreferences.use24HourClock, true);
    await service.resetProfileToDefaults(client, profile: 'desktop');
    await settle();

    expect(postCount(), 0);
  });

  test('a background refresh during reset cannot recreate the device profile', () async {
    final profile = service.syncProfile;
    adapter.resolvedProfile = {'use24HourClock': true};
    await prefs.set(UserPreferences.use24HourClock, true);
    await service.pushSettings(client, force: true);
    adapter.requests.clear();

    final deleteStarted = Completer<void>();
    final releaseDelete = Completer<void>();
    final reloadStarted = Completer<void>();
    final releaseReload = Completer<void>();
    adapter.beforeResponse = (method, path) async {
      if (method == 'DELETE') {
        deleteStarted.complete();
        await releaseDelete.future;
      } else if (path == '/Moonfin/Settings/Resolved/$profile') {
        reloadStarted.complete();
        await releaseReload.future;
      }
    };
    final reset = service.resetProfileToDefaults(client, profile: profile);
    await deleteStarted.future;
    await prefs.set(UserPreferences.lastSonarrCalendarFetchTime, 123456);
    await settle();
    releaseDelete.complete();

    await reloadStarted.future;
    await prefs.set(UserPreferences.lastSonarrCalendarFetchTime, 123457);
    await settle();
    releaseReload.complete();

    expect(await reset, isTrue);
    await settle();
    expect(adapter.requests, contains('GET /Moonfin/Settings/Resolved/$profile'));
    expect(postCount(), 0);
    expect(prefs.get(UserPreferences.use24HourClock), isTrue);
  });

  test('an edit after a reset still reaches the server', () async {
    await service.resetProfileToDefaults(client, profile: 'desktop');

    await prefs.set(UserPreferences.use24HourClock, true);
    await settle();

    expect(postCount(), 1);
  });

  for (final editClock in [false, true]) {
    test('missing profile after reset uploads only a synced edit (clock edit: $editClock)', () async {
      final profile = service.syncProfile;
      final loading = Completer<void>();
      final release = Completer<void>();
      adapter.failResolved = true;
      adapter.beforeResponse = (method, path) async {
        if (path == '/Moonfin/Settings/Resolved/$profile') {
          loading.complete();
          await release.future;
        }
      };
      final reset = service.resetProfileToDefaults(client, profile: profile);
      await loading.future;
      await prefs.set(UserPreferences.lastSonarrCalendarFetchTime, 123456);
      if (editClock) await prefs.set(UserPreferences.use24HourClock, true);
      await settle();
      expect(postCount(), 0);
      release.complete();
      expect(await reset, isTrue);
      await settle();
      expect(postCount(), editClock ? 1 : 0);
      if (editClock) expect(adapter.postedProfile?['use24HourClock'], isTrue);
    });
  }

  test('the snapshot of the deleted profile stops suppressing', () async {
    // Pushed while everything is still at its default, so the payload the
    // reset leaves behind is the one already recorded. Only clearing the
    // snapshot lets the push below through.
    await service.pushSettingsForProfile(client, profile: 'desktop');
    expect(postCount(), 1);

    adapter.failResolved = true;
    await service.resetProfileToDefaults(client, profile: 'desktop');
    await service.pushSettingsForProfile(client, profile: 'desktop');

    expect(postCount(), 2);
  });

  test('a refused delete leaves the settings alone', () async {
    await prefs.set(UserPreferences.use24HourClock, true);
    adapter.failDeletes = true;

    final ok = await service.resetProfileToDefaults(client, profile: 'desktop');

    expect(ok, isFalse);
    expect(prefs.get(UserPreferences.use24HourClock), isTrue);
    await settle();
    expect(postCount(), 1);
  });

  test('a re-ping keeps the incomplete recordings it already has', () async {
    final incomplete = IncompleteRecordingsService(
      client: () => client,
      dio: Dio()..httpClientAdapter = adapter,
    );
    GetIt.instance.registerSingleton<IncompleteRecordingsService>(incomplete);
    int reads() => adapter.requests
        .where((r) => r == 'GET /Moonfin/LiveTv/Recordings/Incomplete')
        .length;

    adapter.incompleteRecordingsSupported = true;
    await service.refreshAvailability(client);
    await pumpEventQueue();
    await service.refreshAvailability(client);
    await pumpEventQueue();

    expect(incomplete.supported, isTrue);
    expect(reads(), 1);

    adapter.incompleteRecordingsSupported = false;
    await service.refreshAvailability(client);

    expect(incomplete.supported, isFalse);
    incomplete.dispose();
  });

  test('signing in takes the notification choices the server keeps', () async {
    final seerrPrefs = GetIt.instance<SeerrPreferences>();
    adapter.notificationPrefs = {
      'notifyOnNewMedia': true,
      'notifyOnIssues': false,
    };

    await service.syncNotificationPrefs(client);

    expect(seerrPrefs.notifyOnNewMedia, isTrue);
    expect(seerrPrefs.notifyOnIssues, isFalse);
    expect(
      adapter.requests,
      isNot(contains('POST /Moonfin/Notifications/Prefs')),
    );
  });

  test('a change the server never got goes up at the next sign-in', () async {
    final seerrPrefs = GetIt.instance<SeerrPreferences>();
    adapter.failNotificationPosts = true;
    await seerrPrefs.setNotifyOnNewMedia(true);
    await service.pushNotificationPrefs(client);
    expect(seerrPrefs.notificationPrefsUnsynced, isTrue);

    adapter.failNotificationPosts = false;
    adapter.notificationPrefs = {'notifyOnNewMedia': false};
    adapter.requests.clear();
    await service.syncNotificationPrefs(client);

    expect(seerrPrefs.notifyOnNewMedia, isTrue);
    expect(seerrPrefs.notificationPrefsUnsynced, isFalse);
    expect(adapter.requests, contains('POST /Moonfin/Notifications/Prefs'));
    expect(
      adapter.requests,
      isNot(contains('GET /Moonfin/Notifications/Prefs')),
    );
  });
}
