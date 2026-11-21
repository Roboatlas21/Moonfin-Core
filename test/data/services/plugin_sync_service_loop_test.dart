import 'dart:async';
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

  test('applying a resolved profile does not schedule a push back', () async {
    await service.handleServerEvent(client, {'type': 'settingsUpdated'});
    await settle();

    expect(resolvedCount(), 1);
    expect(postCount(), 0, reason: 'the apply echoed back to the server');
  });

  test('ordinary settings pushes cannot overwrite saved guide pins', () async {
    const local = ['group:US | SPORTS, Canada', 'category:sports'];
    await prefs.set(UserPreferences.liveTvSavedFilters, local);
    await prefs.set(UserPreferences.liveTvSavedFiltersUnsynced, true);
    await service.pushSettingsForProfile(client, profile: 'desktop');
    expect(adapter.lastPushedProfile?.containsKey('liveTvSavedFilters'), isFalse);

    // Import pending pins before the first atomic edit, without a prior pull.
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

  test('stale pin replies and queued edits cannot update another account', () async {
    adapter.savedPins = [];
    adapter.pinResponseReady = Completer<void>();
    adapter.pinResponseGate = Completer<void>();
    final first = service.changePinnedGuideFilter(
      client, filter: 'group:Sports', add: true,
    );
    await adapter.pinResponseReady!.future;
    final queued = service.changePinnedGuideFilter(
      client, filter: 'group:News', add: true,
    );
    final firstRejected = expectLater(first, throwsA(isA<StateError>()));
    final queuedRejected = expectLater(queued, throwsA(isA<StateError>()));
    when(() => client.userId).thenReturn('user2');
    adapter.pinResponseGate!.complete();
    await Future.wait([firstRejected, queuedRejected]);
    expect(adapter.pinActions, ['add']);
    expect(postCount(), 1);
    expect(prefs.get(UserPreferences.liveTvSavedFilters), isEmpty);
  });

  test('a pending import cannot apply to another account', () async {
    const local = ['group:Local'];
    await prefs.set(UserPreferences.liveTvSavedFilters, local);
    await prefs.set(UserPreferences.liveTvSavedFiltersUnsynced, true);
    adapter.pinResponseReady = Completer<void>();
    adapter.pinResponseGate = Completer<void>();
    final pulling = service.pullSettingsForProfile(client, profile: 'desktop');
    await adapter.pinResponseReady!.future;
    when(() => client.userId).thenReturn('user2');
    adapter.pinResponseGate!.complete();
    expect(await pulling, isFalse);
    expect(adapter.pinActions, ['initializeIfAbsent']);
    expect(prefs.get(UserPreferences.liveTvSavedFilters), local);
    expect(prefs.get(UserPreferences.liveTvSavedFiltersUnsynced), isTrue);
  });

  test('a delayed pin reply cannot replace a newer settings update', () async {
    adapter.savedPins = [];
    adapter.pinResponseReady = Completer<void>();
    adapter.pinResponseGate = Completer<void>();

    final saving = service.changePinnedGuideFilter(
      client, filter: 'group:Sports', add: true,
    );
    await adapter.pinResponseReady!.future;
    // Another device adds News after the server handled our Sports request,
    // but before its older response reaches this device.
    adapter.savedPins = ['group:Sports', 'group:News'];
    final updated = service.handleServerEvent(client, {'type': 'settingsUpdated'});
    await Future<void>.delayed(Duration.zero);
    expect(resolvedCount(), 0, reason: 'settings must wait for the pin save');

    adapter.pinResponseGate!.complete();
    expect(await saving, ['group:Sports']);
    await updated;
    expect(prefs.get(UserPreferences.liveTvSavedFilters), ['group:Sports', 'group:News']);
  });

  test('manual sync cannot overwrite a pin saved during an older pull', () async {
    adapter.savedPins = ['group:Sports'];
    adapter.resolvedResponseReady = Completer<void>();
    adapter.resolvedResponseGate = Completer<void>();

    final pulling = service.pullSettingsForProfile(client, profile: 'desktop');
    await adapter.resolvedResponseReady!.future;
    final saving = service.changePinnedGuideFilter(
      client, filter: 'group:News', add: true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(adapter.pinActions, isEmpty, reason: 'save must wait for the manual pull');

    adapter.resolvedResponseGate!.complete();
    expect(await pulling, isTrue);
    expect(await saving, ['group:Sports', 'group:News']);
    expect(prefs.get(UserPreferences.liveTvSavedFilters),
        ['group:Sports', 'group:News']);
  });

  test('pin edits wait for sign-in and preserve their order', () async {
    adapter.savedPins = ['group:Sports'];
    await prefs.set(UserPreferences.pluginSyncInitializedForServer('srv1'), true);
    adapter.resolvedResponseReady = Completer<void>();
    adapter.resolvedResponseGate = Completer<void>();

    final signingIn = service.syncOnLogin(client, serverId: 'srv1');
    await adapter.resolvedResponseReady!.future;
    final addNews = service.changePinnedGuideFilter(
      client, filter: 'group:News', add: true,
    );
    final removeSports = service.changePinnedGuideFilter(
      client, filter: 'group:Sports', add: false,
    );
    expect(adapter.pinActions, isEmpty);
    adapter.resolvedResponseGate!.complete();
    await signingIn;
    expect(await addNews, ['group:Sports', 'group:News']);
    expect(await removeSports, ['group:News']);
    expect(adapter.pinActions, ['add', 'remove']);
    expect(prefs.get(UserPreferences.liveTvSavedFilters), ['group:News']);
    service.resetState();
  });

  test('an old server cannot import or apply the active account pins', () async {
    const local = ['group:Sports', 'category:news'];
    await prefs.set(UserPreferences.liveTvSavedFilters, local);
    final other = _MockClient();
    when(() => other.baseUrl).thenReturn('http://plugin.test');
    when(() => other.accessToken).thenReturn('token');
    when(() => other.userId).thenReturn('user1');
    when(() => other.serverType).thenReturn(ServerType.jellyfin);

    await service.handleServerEvent(other, {'type': 'settingsUpdated'});
    expect(resolvedCount(), 0, reason: 'a stale event must not read active pins');
    expect(await service.pullSettingsForProfile(other, profile: 'desktop'), isFalse);
    expect(adapter.pinActions, isEmpty);
    expect(prefs.get(UserPreferences.liveTvSavedFilters), local);
  });

  test('pins sync after Moonbase appears, even with no existing server profile', () async {
    adapter.missingProfileUntilPins = true;
    const existing = ['group:Sports', 'group:News, Canada'];
    await prefs.set(UserPreferences.liveTvSavedFilters, existing);
    service.resetState(); // Moonbase has not been detected in this session.

    final remote = await service.changePinnedGuideFilter(
      client,
      filter: 'group:Movies',
      add: true,
    );
    expect(remote, isNull);
    expect(adapter.requests, isEmpty, reason: 'pinning must not discover Moonbase');

    // The guide's local fallback stores the new pin without a plugin.
    const localWithMovies = [...existing, 'group:Movies'];
    await prefs.set(UserPreferences.liveTvSavedFilters, localWithMovies);
    await prefs.set(UserPreferences.liveTvSavedFiltersUnsynced, true);

    // A later normal availability check and settings sync import all three.
    expect(await service.refreshAvailability(client), isTrue);
    expect(await service.pullSettingsForProfile(client, profile: 'desktop'), isTrue);
    expect(adapter.pinActions, ['initializeIfAbsent']);
    expect(resolvedCount(), 2, reason: 'new server profile must be fetched after import');
    expect(adapter.savedPins, localWithMovies);
    expect(prefs.get(UserPreferences.liveTvSavedFilters), localWithMovies);
    expect(prefs.get(UserPreferences.liveTvSavedFiltersUnsynced), isFalse);
  });

  test('old Moonbase keeps pins local until its pin support is upgraded', () async {
    adapter.supportsPinChanges = false;
    adapter.resolvedProfile = {'liveTvSavedFilters': ['group:Admin']};
    const local = ['group:Sports', 'group:Movies'];
    expect(
      await service.changePinnedGuideFilter(
        client, filter: 'group:Movies', add: true,
      ),
      isNull,
    );
    expect(postCount(), 1);
    expect(adapter.pinActions, isEmpty);
    // The guide handles a null result by saving the pin locally.
    await prefs.set(UserPreferences.liveTvSavedFilters, local);
    await prefs.set(UserPreferences.liveTvSavedFiltersUnsynced, true);
    expect(await service.pullSettingsForProfile(client, profile: 'desktop'), isTrue);
    expect(adapter.savedPins, isNull);
    expect(prefs.get(UserPreferences.liveTvSavedFilters), local);

    adapter.supportsPinChanges = true;
    expect(await service.pullSettingsForProfile(client, profile: 'desktop'), isTrue);
    expect(adapter.pinActions, ['initializeIfAbsent']);
    expect(adapter.savedPins, local);
  });

  test('failed import keeps local pins through settings events until retry', () async {
    const local = ['group:Sports'];
    await prefs.set(UserPreferences.liveTvSavedFilters, local);
    await prefs.set(UserPreferences.liveTvSavedFiltersUnsynced, true);
    adapter.resolvedProfile = {
      'liveTvSavedFilters': ['group:Admin'],
      'use24HourClock': true,
    };
    adapter.failPinChanges = true;

    expect(await service.pullSettingsForProfile(client, profile: 'desktop'), isTrue);
    expect(prefs.get(UserPreferences.liveTvSavedFilters), local);
    expect(prefs.get(UserPreferences.use24HourClock), isTrue);
    expect(prefs.get(UserPreferences.liveTvSavedFiltersUnsynced), isTrue);
    await service.handleServerEvent(client, {'type': 'settingsUpdated'});
    expect(prefs.get(UserPreferences.liveTvSavedFilters), local);

    adapter.failPinChanges = false;
    await service.handleServerEvent(client, {'type': 'settingsUpdated'});
    expect(adapter.savedPins, local);
    expect(prefs.get(UserPreferences.liveTvSavedFilters), local);
    expect(prefs.get(UserPreferences.liveTvSavedFiltersUnsynced), isFalse);
    expect(adapter.pinActions, ['initializeIfAbsent']);
  });

  test('pre-Moonbase local pins override inherited admin defaults once', () async {
    const local = ['group:US | SPORTS', 'group:Kids'];
    adapter.resolvedProfile = {'liveTvSavedFilters': ['group:Admin']};
    await prefs.set(UserPreferences.liveTvSavedFilters, local);
    await prefs.set(UserPreferences.liveTvSavedFiltersUnsynced, true);

    expect(await service.pullSettingsForProfile(client, profile: 'desktop'), isTrue);
    expect(adapter.pinActions, ['initializeIfAbsent']);
    expect(adapter.savedPins, local);
    expect(prefs.get(UserPreferences.liveTvSavedFilters), local);
    // A subsequent settings pull must not import the same device values again.
    expect(await service.pullSettingsForProfile(client, profile: 'desktop'), isTrue);
    expect(adapter.pinActions, ['initializeIfAbsent']);
  });

  test('unmodified users follow later administrator pin default changes', () async {
    adapter.resolvedProfile = {'liveTvSavedFilters': ['group:Sports']};
    expect(await service.pullSettingsForProfile(client, profile: 'desktop'), isTrue);
    expect(prefs.get(UserPreferences.liveTvSavedFilters), ['group:Sports']);

    adapter.resolvedProfile = {'liveTvSavedFilters': ['group:News']};
    expect(await service.pullSettingsForProfile(client, profile: 'desktop'), isTrue);
    expect(adapter.pinActions, isEmpty, reason: 'inherited pins are not copied into a user override');
    expect(prefs.get(UserPreferences.liveTvSavedFilters), ['group:News']);
  });

  test('an explicit empty server list blocks pending local pin import', () async {
    await prefs.set(UserPreferences.liveTvSavedFilters, ['group:Local']);
    await prefs.set(UserPreferences.liveTvSavedFiltersUnsynced, true);
    adapter.savedPins = <String>[];
    expect(await service.pullSettingsForProfile(client, profile: 'desktop'), isTrue);
    expect(adapter.pinActions, ['initializeIfAbsent']);
    expect(prefs.get(UserPreferences.liveTvSavedFiltersUnsynced), isFalse);
    expect(prefs.get(UserPreferences.liveTvSavedFilters), isEmpty);
    final pins = await service.changePinnedGuideFilter(
      client,
      filter: 'group:Movies',
      add: true,
    );
    expect(adapter.pinActions, ['initializeIfAbsent', 'add']);
    expect(pins, ['group:Movies']);
  });

  test('pending empty pins override inherited defaults', () async {
    adapter.resolvedProfile = {'liveTvSavedFilters': ['group:Admin']};
    await prefs.set(UserPreferences.liveTvSavedFiltersUnsynced, true);

    expect(await service.pullSettingsForProfile(client, profile: 'desktop'), isTrue);
    expect(adapter.savedPins, isEmpty);
    expect(prefs.get(UserPreferences.liveTvSavedFilters), isEmpty);
    expect(prefs.get(UserPreferences.liveTvSavedFiltersUnsynced), isFalse);
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
