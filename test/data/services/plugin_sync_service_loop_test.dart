import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moonfin/auth/repositories/session_repository.dart';
import 'package:moonfin/data/services/plugin_sync_service.dart';
import 'package:moonfin/preference/seerr_preferences.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:server_core/server_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockClient extends Mock implements MediaServerClient {}

class _MockSessionRepository extends Mock implements SessionRepository {}

/// Serves canned plugin responses and records every request, so the tests can
/// assert exactly which sync calls went over the wire.
class _RecordingAdapter implements HttpClientAdapter {
  final List<String> requests = [];

  /// Body returned for the Resolved endpoint, replaceable per test.
  Map<String, dynamic> resolvedProfile = {};
  Map<String, dynamic>? lastPushedProfile;
  List<String>? savedPins;
  final List<String> pinActions = [];

  void applyPinChange(Map<dynamic, dynamic> change) {
    final action = change['action'] as String;
    pinActions.add(action);
    if (action == 'initializeIfAbsent') {
      savedPins ??= List<String>.from(change['filters'] as List);
    } else if (action == 'add') {
      savedPins ??= [];
      final filter = change['filter'] as String;
      if (!savedPins!.contains(filter)) savedPins!.add(filter);
    } else if (action == 'remove') {
      savedPins ??= [];
      savedPins!.remove(change['filter']);
    }
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    requests.add('${options.method} $path');

    Map<String, dynamic>? body;
    if (path.endsWith('/Moonfin/Ping')) {
      body = {'installed': true, 'settingsSyncEnabled': true};
    } else if (path.contains('/Moonfin/Settings/Resolved/')) {
      body = {
        ...resolvedProfile,
        if (savedPins != null) 'liveTvSavedFilters': savedPins,
      };
    } else if (path.contains('/Moonfin/Settings/Profile/')) {
      body = {
        if (savedPins != null) 'liveTvSavedFilters': savedPins,
      };
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
  int resolvedCount() =>
      adapter.requests.where((r) => r.contains('/Settings/Resolved/')).length;

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
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (request, handler) {
        if (request.method == 'POST' &&
            request.path.contains('/Settings/Profile/') &&
            request.data is Map) {
          final profile = (request.data as Map)['profile'];
          if (profile is Map) {
            adapter.lastPushedProfile = Map<String, dynamic>.from(profile);
          }
          final change = (request.data as Map)['liveTvSavedFilterChange'];
          if (change is Map) adapter.applyPinChange(change);
        }
        handler.next(request);
      },
    ));
    dio.httpClientAdapter = adapter;
    service = PluginSyncService(prefs, store, dio: dio);

    // Enabled while the plugin still reads unavailable, so this set schedules
    // nothing. Availability comes from the canned Ping afterwards.
    await prefs.set(UserPreferences.pluginSyncEnabled, true);
    expect(await service.refreshAvailability(client), isTrue);
    GetIt.instance.registerSingleton<MediaServerClient>(client);
    adapter.requests.clear();
  });

  tearDown(() async {
    await GetIt.instance.reset();
  });

  test('applying a resolved profile does not schedule a push back', () async {
    await service.handleServerEvent(client, {'type': 'settingsUpdated'});
    await settle();

    expect(resolvedCount(), 1);
    expect(postCount(), 0, reason: 'the apply echoed back to the server');
  });

  test('ordinary settings pushes cannot overwrite saved guide pins', () async {
    const local = ['group:US | SPORTS, Canada', 'category:sports'];
    await prefs.set(UserPreferences.liveTvSavedFilters, local);
    await service.pushSettingsForProfile(client, profile: 'desktop');
    expect(adapter.lastPushedProfile?.containsKey('liveTvSavedFilters'), isFalse);

    final updated = await service.changePinnedGuideFilter(
      client,
      filter: 'group:News, English',
      add: true,
    );
    expect(adapter.pinActions, ['initializeIfAbsent', 'add']);
    expect(updated, [...local, 'group:News, English']);

    // A change on another device arrives through the existing settings stream.
    adapter.savedPins = ['group:News, English', 'category:movies'];
    await service.handleServerEvent(client, {'type': 'settingsUpdated'});
    expect(prefs.get(UserPreferences.liveTvSavedFilters), adapter.savedPins);

    adapter.savedPins = <String>[];
    await service.handleServerEvent(client, {'type': 'settingsUpdated'});
    expect(prefs.get(UserPreferences.liveTvSavedFilters), isEmpty);
  });

  test('installing Moonbase mid-session imports local pins before another pin', () async {
    const local = ['group:Sports', 'group:News, Canada'];
    await prefs.set(UserPreferences.liveTvSavedFilters, local);
    service.resetState(); // The client has not observed the new Moonbase yet.

    final pins = await service.changePinnedGuideFilter(
      client,
      filter: 'group:Movies',
      add: true,
    );
    expect(adapter.pinActions, ['initializeIfAbsent', 'add']);
    expect(pins, [...local, 'group:Movies']);
    expect(adapter.requests.first, contains('/Moonfin/Ping'));
    expect(adapter.requests.where((r) => r.contains('/Settings/Resolved/')).length, 2);
  });

  test('a shared list blocks first-install import, even when explicitly empty', () async {
    await prefs.set(UserPreferences.liveTvSavedFilters, ['group:Local']);
    adapter.savedPins = <String>[];
    final pins = await service.changePinnedGuideFilter(
      client,
      filter: 'group:Movies',
      add: true,
    );
    expect(adapter.pinActions, ['add']);
    expect(pins, ['group:Movies']);
  });

  test('an unchanged payload is pushed once, a changed one again', () async {
    await service.pushSettingsForProfile(client, profile: 'desktop');
    await service.pushSettingsForProfile(client, profile: 'desktop');
    expect(postCount(), 1);

    await prefs.set(UserPreferences.use24HourClock, true);
    await service.pushSettingsForProfile(client, profile: 'desktop');
    expect(postCount(), 2);
  });

  test('a push right after an apply is recognized as the echo', () async {
    await service.handleServerEvent(client, {'type': 'settingsUpdated'});
    await service.pushSettings(client);
    expect(postCount(), 0);
  });

  test('a genuinely changed remote value still lands and notifies', () async {
    adapter.resolvedProfile = {'use24HourClock': true};
    expect(prefs.get(UserPreferences.use24HourClock), isFalse);

    var notified = false;
    prefs.addListener(() => notified = true);
    await service.handleServerEvent(client, {'type': 'settingsUpdated'});

    expect(prefs.get(UserPreferences.use24HourClock), isTrue);
    expect(notified, isTrue);
  });

  test('a real local change still pushes after the debounce', () async {
    await prefs.set(UserPreferences.use24HourClock, true);
    await settle();
    expect(postCount(), 1);
  });

  test('force pushes even when the payload matches the snapshot', () async {
    await service.pushSettingsForProfile(client, profile: 'desktop');
    await service.pushSettingsForProfile(
      client,
      profile: 'desktop',
      force: true,
    );
    expect(postCount(), 2);
  });

  test('resetState clears the snapshots', () async {
    await service.pushSettingsForProfile(client, profile: 'desktop');
    expect(postCount(), 1);

    service.resetState();
    await service.refreshAvailability(client);
    await service.pushSettingsForProfile(client, profile: 'desktop');
    expect(postCount(), 2);
  });
}
