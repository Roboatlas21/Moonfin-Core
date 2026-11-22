import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moonfin/auth/repositories/session_repository.dart';
import 'package:moonfin/data/offline/connectivity_aware_media_server_client.dart';
import 'package:moonfin/data/services/plugin_sync_service.dart';
import 'package:moonfin/preference/seerr_preferences.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:server_core/server_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockClient extends Mock implements MediaServerClient {}
class _MockConnectivityAwareClient extends Mock
    implements ConnectivityAwareMediaServerClient {}

class _MockSessionRepository extends Mock implements SessionRepository {}

/// Serves canned plugin responses and records every request, so the tests can
/// assert exactly which sync calls went over the wire.
class _RecordingAdapter implements HttpClientAdapter {
  final List<String> requests = [];

  /// Body returned for the Resolved endpoint, replaceable per test.
  Map<String, dynamic> resolvedProfile = {};
  Map<String, dynamic>? lastPushedProfile;
  List<String>? savedPins;
  bool supportsPinChanges = true;
  bool failPinChanges = false;
  bool missingProfileUntilPins = false;
  Completer<void>? pinResponseReady;
  Completer<void>? pinResponseGate;
  Completer<void>? resolvedResponseReady;
  Completer<void>? resolvedResponseGate;
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
      if (missingProfileUntilPins && savedPins == null) {
        return ResponseBody.fromString('', 404);
      }
      body = {
        ...resolvedProfile,
        if (savedPins != null) 'liveTvSavedFilters': List<String>.of(savedPins!),
      };
      if (resolvedResponseGate != null) {
        resolvedResponseReady?.complete();
        await resolvedResponseGate!.future;
      }
    } else if (path.contains('/Moonfin/Settings/Profile/')) {
      if (options.method == 'POST' && failPinChanges) {
        return ResponseBody.fromString('Temporarily unavailable', 503);
      }
      body = {
        if (supportsPinChanges && savedPins != null)
          'liveTvSavedFilters': List<String>.of(savedPins!),
      };
      if (options.method == 'POST' && pinResponseGate != null) {
        pinResponseReady?.complete();
        await pinResponseGate!.future;
      }
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

  Future<List<String>?> togglePin(String filter) =>
      service.changePinnedGuideFilter(client, filter: filter);

  int postCount() => adapter.requests
      .where((r) => r.startsWith('POST') && r.contains('/Settings/Profile/'))
      .length;
  int resolvedCount() =>
      adapter.requests.where((r) => r.contains('/Settings/Resolved/')).length;

  /// Waits out the 1000ms push debounce plus slack.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 1400));

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'pref_last_server_id': 'srv1',
      'pref_last_user_id': 'user1',
    });
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
    when(() => client.userId).thenReturn('user1');
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
          if (change is Map && adapter.supportsPinChanges && !adapter.failPinChanges) {
            adapter.applyPinChange(change);
          }
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

  test('atomic pin toggles remain ordered online and locally', () async {
    adapter.savedPins = [];
    await Future.wait([togglePin('group:Sports'), togglePin('group:Sports')]);
    expect(adapter.pinActions, ['add', 'remove']);
    expect(prefs.get(UserPreferences.liveTvSavedFilters), isEmpty);

    service.resetState();
    adapter.requests.clear();
    await Future.wait([togglePin('group:News'), togglePin('group:News')]);
    expect(prefs.get(UserPreferences.liveTvSavedFilters), isEmpty);
    expect(prefs.get(UserPreferences.liveTvSavedFiltersUnsynced), isTrue);
    expect(adapter.requests, isEmpty);
  });

  test('applying a resolved profile does not schedule a push back', () async {
    await service.handleServerEvent(client, {'type': 'settingsUpdated'});
    await settle();
    expect(resolvedCount(), 1);
    expect(postCount(), 0, reason: 'the apply echoed back to the server');
  });

  test('regular settings updates do not overwrite atomic guide pins', () async {
    const local = ['group:US | SPORTS, Canada', 'category:sports'];
    await prefs.set(UserPreferences.liveTvSavedFilters, local);
    await prefs.set(UserPreferences.liveTvSavedFiltersUnsynced, true);
    await service.pushSettingsForProfile(client, profile: 'desktop');
    expect(adapter.lastPushedProfile?.containsKey('liveTvSavedFilters'), isFalse);

    expect(await togglePin('group:News'), [...local, 'group:News']);
    expect(adapter.pinActions, ['initializeIfAbsent', 'add']);
    adapter.savedPins = ['group:News', 'category:movies'];
    await service.handleServerEvent(client, {'type': 'settingsUpdated'});
    expect(prefs.get(UserPreferences.liveTvSavedFilters), adapter.savedPins);
    adapter.savedPins = [];
    await service.handleServerEvent(client, {'type': 'settingsUpdated'});
    expect(prefs.get(UserPreferences.liveTvSavedFilters), isEmpty);
  });

  test('offline pins import when Moonbase first becomes available', () async {
    adapter.missingProfileUntilPins = true;
    await prefs.set(UserPreferences.liveTvSavedFilters, ['group:Sports']);
    service.resetState();
    expect(await togglePin('group:Movies'), isNull);
    expect(adapter.requests, isEmpty);
    expect(prefs.get(UserPreferences.liveTvSavedFiltersUnsynced), isTrue);

    expect(await service.refreshAvailability(client), isTrue);
    expect(await service.pullSettingsForProfile(client, profile: 'desktop'), isTrue);
    expect(adapter.pinActions, ['initializeIfAbsent']);
    expect(adapter.savedPins, ['group:Sports', 'group:Movies']);
    expect(prefs.get(UserPreferences.liveTvSavedFiltersUnsynced), isFalse);
  });

  test('legacy and failing Moonbase writes preserve pins until recovery', () async {
    adapter.supportsPinChanges = false;
    adapter.resolvedProfile = {
      'liveTvSavedFilters': ['group:Admin'],
      'use24HourClock': true,
    };
    await prefs.set(UserPreferences.liveTvSavedFilters, ['group:Sports']);
    expect(await togglePin('group:Movies'), isNull);
    const local = ['group:Sports', 'group:Movies'];
    // The first sign-in must restore ordinary settings even with old Moonbase.
    await service.syncOnLogin(client, serverId: 'srv1');
    expect(prefs.get(UserPreferences.use24HourClock), isTrue);
    expect(await service.pullSettingsForProfile(client, profile: 'desktop'), isTrue);
    expect(prefs.get(UserPreferences.liveTvSavedFilters), local);

    adapter.supportsPinChanges = true;
    adapter.failPinChanges = true;
    await service.handleServerEvent(client, {'type': 'settingsUpdated'});
    expect(prefs.get(UserPreferences.liveTvSavedFilters), local);
    expect(prefs.get(UserPreferences.use24HourClock), isTrue);
    adapter.failPinChanges = false;
    await service.handleServerEvent(client, {'type': 'settingsUpdated'});
    expect(adapter.savedPins, local);
    expect(prefs.get(UserPreferences.liveTvSavedFiltersUnsynced), isFalse);
  });

  test('administrator defaults and explicit empty pins retain precedence', () async {
    adapter.resolvedProfile = {'liveTvSavedFilters': ['group:Sports']};
    expect(await service.pullSettingsForProfile(client, profile: 'desktop'), isTrue);
    adapter.resolvedProfile = {'liveTvSavedFilters': ['group:News']};
    expect(await service.pullSettingsForProfile(client, profile: 'desktop'), isTrue);
    expect(prefs.get(UserPreferences.liveTvSavedFilters), ['group:News']);
    expect(adapter.pinActions, isEmpty);

    await prefs.set(UserPreferences.liveTvSavedFilters, ['group:Local']);
    await prefs.set(UserPreferences.liveTvSavedFiltersUnsynced, true);
    expect(await service.pullSettingsForProfile(client, profile: 'desktop'), isTrue);
    expect(adapter.savedPins, ['group:Local']);
    expect(adapter.pinActions, ['initializeIfAbsent']);

    adapter.savedPins = [];
    await prefs.set(UserPreferences.liveTvSavedFiltersUnsynced, true);
    expect(await service.pullSettingsForProfile(client, profile: 'desktop'), isTrue);
    expect(prefs.get(UserPreferences.liveTvSavedFilters), isEmpty);
  });

  test('queued pin replies cannot overwrite newer settings or another account', () async {
    adapter.savedPins = [];
    adapter.pinResponseReady = Completer<void>();
    adapter.pinResponseGate = Completer<void>();
    final saving = togglePin('group:Sports');
    await adapter.pinResponseReady!.future;
    adapter.savedPins = ['group:Sports', 'group:News'];
    final updating = service.handleServerEvent(client, {'type': 'settingsUpdated'});
    await Future<void>.delayed(Duration.zero);
    expect(resolvedCount(), 0);
    adapter.pinResponseGate!.complete();
    expect(await saving, ['group:Sports']);
    await updating;
    expect(prefs.get(UserPreferences.liveTvSavedFilters),
        ['group:Sports', 'group:News']);

    adapter.pinResponseReady = Completer<void>();
    adapter.pinResponseGate = Completer<void>();
    final stale = togglePin('group:Movies');
    await adapter.pinResponseReady!.future;
    final queued = togglePin('group:Kids');
    final rejected = expectLater(stale, throwsA(isA<StateError>()));
    final queuedRejected = expectLater(queued, throwsA(isA<StateError>()));
    when(() => client.userId).thenReturn('other');
    adapter.pinResponseGate!.complete();
    await Future.wait([rejected, queuedRejected]);
    expect(prefs.get(UserPreferences.liveTvSavedFilters),
        ['group:Sports', 'group:News']);
  });

  test('pin edits wait for sign-in through the active client wrapper', () async {
    final active = _MockConnectivityAwareClient();
    when(() => active.onlineClient).thenReturn(client);
    await GetIt.instance.unregister<MediaServerClient>();
    GetIt.instance.registerSingleton<MediaServerClient>(active);
    adapter.resolvedProfile = {'use24HourClock': true};
    adapter.savedPins = ['group:Sports'];
    await prefs.set(UserPreferences.pluginSyncInitializedForServer('srv1'), true);
    adapter.resolvedResponseReady = Completer<void>();
    adapter.resolvedResponseGate = Completer<void>();
    final signingIn = service.syncOnLogin(client, serverId: 'srv1');
    await adapter.resolvedResponseReady!.future;
    final add = togglePin('group:News');
    final remove = togglePin('group:Sports');
    expect(adapter.pinActions, isEmpty);
    adapter.resolvedResponseGate!.complete();
    await signingIn;
    expect(prefs.get(UserPreferences.use24HourClock), isTrue);
    expect(await add, ['group:Sports', 'group:News']);
    expect(await remove, ['group:News']);
    expect(prefs.get(UserPreferences.liveTvSavedFilters), ['group:News']);
    service.resetState();
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
