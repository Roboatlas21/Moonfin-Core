import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moonfin/auth/repositories/session_repository.dart';
import 'package:moonfin/data/offline/connectivity_aware_media_server_client.dart';
import 'package:moonfin/data/services/guide_pin_transport.dart';
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
  RequestOptions? lastPinRequest;
  bool supportsPinChanges = true;
  bool failPinChanges = false;
  String? unavailablePin;
  String? rejectedPin;
  bool missingProfileUntilPins = false;
  bool confirmsEmptyPins = false;
  Completer<void>? responseReady;
  Completer<void>? responseGate;
  final List<String> pinActions = [];

  void applyPinChange(Map<dynamic, dynamic> change) {
    final action = change['action'] as String;
    pinActions.add(action);
    if (action == 'initializeIfAbsent') {
      savedPins ??= List<String>.from(change['filters'] as List);
      return;
    }
    final pins = savedPins ??= <String>[];
    final filter = change['filter'] as String;
    if (action == 'add' && !pins.contains(filter)) pins.add(filter);
    if (action == 'remove') pins.remove(filter);
  }

  Future<void> holdResponse() async {
    final gate = responseGate;
    if (gate == null) return;
    if (responseReady?.isCompleted == false) {
      responseReady!.complete();
    }
    await gate.future;
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
        return ResponseBody.fromString(
          confirmsEmptyPins && options.queryParameters['includeLiveTvSavedFilters'] == true
              ? '{"liveTvSavedFilters":[]}'
              : '{}',
          404,
          headers: {Headers.contentTypeHeader: [Headers.jsonContentType]},
        );
      }
      body = {
        ...resolvedProfile,
        if (savedPins != null) 'liveTvSavedFilters': List<String>.of(savedPins!),
      };
      await holdResponse();
    } else if (path.contains('/Moonfin/Settings/Profile/')) {
      if (options.data?['liveTvSavedFilterChange'] != null) lastPinRequest = options;
      final filter = options.data?['liveTvSavedFilterChange']?['filter'];
      if (filter != null && filter == rejectedPin) return ResponseBody.fromString('', 400);
      if (options.method == 'POST' && (failPinChanges || (filter != null && filter == unavailablePin))) {
        return ResponseBody.fromString('Temporarily unavailable', 503);
      }
      body = {
        if (supportsPinChanges && savedPins != null)
          'liveTvSavedFilters': List<String>.of(savedPins!),
      };
      if (options.method == 'POST') await holdResponse();
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

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'pref_last_server_id': 'srv1', 'pref_last_user_id': 'user1',
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
    when(() => client.deviceInfo).thenReturn(const DeviceInfo(
      id: 'dev1', name: 'test', appName: 'moonfin', appVersion: '0.0.0',
    ));

    adapter = _RecordingAdapter();
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
      if (request.method == 'POST' &&
          request.path.contains('/Settings/Profile/') &&
          request.data is Map) {
        final body = request.data as Map;
        if (body['profile'] case final Map profile) {
          adapter.lastPushedProfile = Map<String, dynamic>.from(profile);
        }
        if (body['liveTvSavedFilterChange'] case final Map change
            when adapter.supportsPinChanges && !adapter.failPinChanges &&
                change['filter'] != adapter.unavailablePin && change['filter'] != adapter.rejectedPin) {
          adapter.applyPinChange(change);
        }
      }
      handler.next(request);
    }));
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

  test('guide pin edits on an HTTP server opt into guarded redirects', () async {
    expect(await togglePin('group:Sports'), ['group:Sports']);
    final request = adapter.lastPinRequest!;
    expect(request.uri.scheme, 'http');
    expect(request.followRedirects, isFalse);
    expect(request.extra[sameOriginRedirectsOnly], isTrue);
  });

  test('the browser pin transport sends the edit with redirects disabled', () async {
    final options = RequestOptions(path: 'https://plugin.test/pins', data: {'action': 'add'});
    final reply = await http.runWithClient(
      () => postBrowserGuidePin(options),
      () => MockClient((request) async {
        expect(request.followRedirects, isFalse);
        expect(jsonDecode(request.body), options.data);
        return http.Response('{"liveTvSavedFilters":["group:Sports"]}', 200);
      }),
    );
    expect(reply.data?['liveTvSavedFilters'], ['group:Sports']);
  });

  test('a second tap updates the guide while the first upload is waiting', () async {
    adapter.savedPins = [];
    adapter.responseReady = Completer<void>();
    adapter.responseGate = Completer<void>();
    final first = togglePin('group:Sports');
    await adapter.responseReady!.future;
    final local = Completer<void>();
    final second = service.changePinnedGuideFilter(
      client, filter: 'group:Sports', onLocalChange: local.complete,
    );
    await local.future;
    expect(prefs.get(UserPreferences.liveTvSavedFilters), isEmpty);
    expect(adapter.pinActions, ['add']);
    adapter.responseGate!.complete();
    await Future.wait([first, second]);
    expect(adapter.pinActions, ['add', 'remove']);
    expect(adapter.savedPins, isEmpty);
    expect(prefs.get(UserPreferences.liveTvSavedFilterChanges), isEmpty);
  });

  test('switching sync off keeps queued pins local even after a settings event', () async {
    adapter.responseReady = Completer<void>();
    adapter.responseGate = Completer<void>();
    final first = togglePin('group:Sports');
    await adapter.responseReady!.future;
    final local = Completer<void>();
    final second = service.changePinnedGuideFilter(
      client, filter: 'group:News', onLocalChange: local.complete,
    );
    await local.future;
    final event = service.handleServerEvent(client, {'type': 'settingsUpdated'});
    await prefs.set(UserPreferences.pluginSyncEnabled, false);
    adapter.responseGate!.complete();
    await first;
    expect(await second, isNull);
    await event;
    await service.handleServerEvent(client, {'type': 'settingsUpdated'});
    expect(resolvedCount(), 0);
    expect(adapter.savedPins, ['group:Sports']);
    expect(prefs.get(UserPreferences.liveTvSavedFilters), ['group:Sports', 'group:News']);
    expect(prefs.get(UserPreferences.liveTvSavedFilterChanges), ['add:group:News']);
  });

  test('turning sync off cancels a reset queued behind a pin upload', () async {
    adapter.responseReady = Completer<void>();
    adapter.responseGate = Completer<void>();
    final saving = togglePin('group:Sports');
    await adapter.responseReady!.future;

    final reset = service.resetProfileToDefaults(client, profile: 'global');
    await service.setSyncEnabled(false);
    adapter.responseGate!.complete();
    await saving;

    expect(await reset, isFalse);
    expect(
      adapter.requests.where((request) => request.startsWith('DELETE ')),
      isEmpty,
    );
    expect(prefs.get(UserPreferences.liveTvSavedFilters), ['group:Sports']);
  });

  test('manual Save distinguishes profile failure from a pending or rejected pin', () async {
    Future<ProfilePushResult> save() => service.pushSettingsForProfile(client, profile: 'tv', force: true);
    adapter.failPinChanges = true; // The adapter returns 503 for all profile POSTs.
    expect(await save(), ProfilePushResult.failed);
    adapter.failPinChanges = false;
    adapter.unavailablePin = 'group:News';
    expect(await togglePin('group:News'), isNull);
    expect(await save(), ProfilePushResult.savedWithPinErrors);
    expect(prefs.get(UserPreferences.liveTvSavedFilterChanges), ['add:group:News']);
    adapter.unavailablePin = null;
    adapter.savedPins = ['group:Sports'];
    expect(await save(), ProfilePushResult.saved);
    expect(adapter.savedPins, ['group:Sports', 'group:News']);
    expect(prefs.get(UserPreferences.liveTvSavedFilterChanges), isEmpty);

    await prefs.set(UserPreferences.pluginSyncEnabled, false);
    await togglePin('group:Rejected');
    await prefs.set(UserPreferences.pluginSyncEnabled, true);
    adapter.rejectedPin = 'group:Rejected';
    expect(await save(), ProfilePushResult.savedWithPinErrors);
    expect(prefs.get(UserPreferences.liveTvSavedFilterChanges), isEmpty);
    expect(adapter.savedPins, ['group:Sports', 'group:News']);
  });

  test('only an explicit empty profile clears cached pins on another device', () async {
    await togglePin('group:News');
    adapter.savedPins = null;
    adapter.missingProfileUntilPins = true;
    await service.handleServerEvent(client, {'type': 'settingsUpdated'});
    expect(prefs.get(UserPreferences.liveTvSavedFilters), ['group:News']);
    adapter.confirmsEmptyPins = true;
    await service.handleServerEvent(client, {'type': 'settingsUpdated'});
    expect(prefs.get(UserPreferences.liveTvSavedFilters), isEmpty);

    service.resetState();
    await togglePin('group:Sports');
    await service.refreshAvailability(client);
    adapter.failPinChanges = true;
    await service.handleServerEvent(client, {'type': 'settingsUpdated'});
    expect(prefs.get(UserPreferences.liveTvSavedFilters), ['group:Sports']);
    expect(prefs.get(UserPreferences.liveTvSavedFilterChanges), ['add:group:Sports']);
  });

  test('an empty pin list in a resaved profile clears cached pins', () async {
    await togglePin('group:Sports');
    adapter.resolvedProfile = {'liveTvCategoryDisplay': 'groups'};
    adapter.savedPins = null;
    await service.handleServerEvent(client, {'type': 'settingsUpdated'});
    expect(prefs.get(UserPreferences.liveTvSavedFilters), ['group:Sports']);

    adapter.savedPins = [];
    await service.handleServerEvent(client, {'type': 'settingsUpdated'});
    expect(prefs.get(UserPreferences.liveTvSavedFilters), isEmpty);
  });

  test('regular settings updates do not overwrite atomic guide pins', () async {
    const local = ['group:US | SPORTS, Canada', 'category:sports'];
    service.resetState();
    for (final filter in local) {
      expect(await togglePin(filter), isNull);
    }
    expect(await service.refreshAvailability(client), isTrue);
    await service.pushSettingsForProfile(client, profile: 'desktop');
    expect(adapter.lastPushedProfile?.containsKey('liveTvSavedFilters'), isFalse);

    expect(await togglePin('group:News'), [...local, 'group:News']);
    expect(adapter.pinActions, ['add', 'add', 'add']);
    adapter.savedPins = ['group:News', 'category:movies'];
    await service.handleServerEvent(client, {'type': 'settingsUpdated'});
    expect(prefs.get(UserPreferences.liveTvSavedFilters), adapter.savedPins);
    // With no personal pins, subsequent pulls follow changed admin defaults.
    adapter.savedPins = null;
    for (final pins in [
      ['group:Sports'],
      ['group:News'],
      <String>[],
    ]) {
      adapter.resolvedProfile = {'liveTvSavedFilters': pins};
      expect(await service.pullSettingsForProfile(client, profile: 'desktop'), isTrue);
      expect(prefs.get(UserPreferences.liveTvSavedFilters), pins);
    }
    expect(adapter.pinActions, ['add', 'add', 'add']);

    // Even an existing empty server list must accept offline additions.
    adapter.savedPins = [];
    service.resetState();
    expect(await togglePin('group:Local'), isNull);
    expect(await service.refreshAvailability(client), isTrue);
    expect(await service.pullSettingsForProfile(client, profile: 'desktop'), isTrue);
    expect(prefs.get(UserPreferences.liveTvSavedFilters), ['group:Local']);
  });

  test('offline pins replay when Moonbase first becomes available', () async {
    adapter.missingProfileUntilPins = true;
    service.resetState();
    expect(await togglePin('group:Sports'), isNull);
    expect(
      await Future.wait([togglePin('group:Movies'), togglePin('group:News')]),
      [null, null],
    );
    expect(adapter.requests, isEmpty);
    expect(prefs.get(UserPreferences.liveTvSavedFilterChanges), [
      'add:group:Sports', 'add:group:Movies', 'add:group:News',
    ]);

    expect(await service.refreshAvailability(client), isTrue);
    expect(await service.pullSettingsForProfile(client, profile: 'desktop'), isTrue);
    expect(adapter.pinActions, ['add', 'add', 'add']);
    expect(adapter.savedPins, ['group:Sports', 'group:Movies', 'group:News']);
    expect(prefs.get(UserPreferences.liveTvSavedFilterChanges), isEmpty);
  });

  test('legacy and failing Moonbase writes preserve pins until recovery', () async {
    adapter.supportsPinChanges = false;
    adapter.savedPins = ['group:Admin'];
    adapter.resolvedProfile = {'use24HourClock': true};
    service.resetState();
    expect(await togglePin('group:Sports'), isNull);
    expect(await service.refreshAvailability(client), isTrue);
    expect(await togglePin('group:Movies'), isNull);
    const local = ['group:Sports', 'group:Movies'];

    // Old Moonbase must still restore unrelated settings without losing pins.
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
    expect(adapter.savedPins, ['group:Admin', ...local]);
    expect(prefs.get(UserPreferences.liveTvSavedFilters),
        ['group:Admin', ...local]);
    expect(prefs.get(UserPreferences.liveTvSavedFilterChanges), isEmpty);
  });

  test('offline edits preserve unrelated pins added by another device', () async {
    adapter.savedPins = ['group:Sports', 'group:News'];
    await service.handleServerEvent(client, {'type': 'settingsUpdated'});
    service.resetState();
    expect(await togglePin('group:Sports'), isNull);
    expect(await togglePin('group:Movies'), isNull);
    adapter.savedPins!.add('group:Kids');

    expect(await service.refreshAvailability(client), isTrue);
    expect(await service.pullSettingsForProfile(client, profile: 'desktop'), isTrue);
    expect(adapter.pinActions, ['remove', 'add']);
    expect(adapter.savedPins, ['group:News', 'group:Kids', 'group:Movies']);
    expect(prefs.get(UserPreferences.liveTvSavedFilters), adapter.savedPins);
    expect(prefs.get(UserPreferences.liveTvSavedFilterChanges), isEmpty);
  });

  test('replay keeps the last choice per group and retires confirmed edits', () async {
    service.resetState();
    await togglePin('group:Sports');
    await togglePin('group:Sports');
    await togglePin('group:Sports');
    await togglePin('group:News');
    expect(prefs.get(UserPreferences.liveTvSavedFilterChanges),
        ['add:group:Sports', 'add:group:News']);
    await service.refreshAvailability(client);
    adapter.unavailablePin = 'group:News';
    await service.pullSettingsForProfile(client, profile: 'global');
    expect(prefs.get(UserPreferences.liveTvSavedFilterChanges), ['add:group:News']);
    expect(prefs.get(UserPreferences.liveTvSavedFilters), ['group:Sports', 'group:News']);
    adapter.savedPins!.remove('group:Sports'); // Another device unpins it.
    adapter.unavailablePin = null;
    await service.pullSettingsForProfile(client, profile: 'global');
    expect(adapter.savedPins, ['group:News']);
    expect(prefs.get(UserPreferences.liveTvSavedFilters), adapter.savedPins);
  });

  test('removing an over-limit local pin does not queue a server edit', () async {
    final pin = 'group:${'x' * 1024}';
    await prefs.set(UserPreferences.liveTvSavedFilters, [pin]);
    await togglePin(pin);
    expect(prefs.get(UserPreferences.liveTvSavedFilters), isEmpty);
    expect(prefs.get(UserPreferences.liveTvSavedFilterChanges), isEmpty);
    expect(adapter.pinActions, isEmpty);
    await expectLater(togglePin(pin), throwsFormatException);
  });

  test('invalid pins surface an error and never block later edits', () async {
    await expectLater(togglePin('group:${'x' * 1024}'), throwsFormatException);
    adapter.rejectedPin = 'group:Rejected';
    await expectLater(togglePin('group:Rejected'), throwsA(isA<DioException>()));
    expect(prefs.get(UserPreferences.liveTvSavedFilters), isEmpty);
    service.resetState();
    await togglePin('group:Rejected');
    await togglePin('group:News');
    await service.refreshAvailability(client);
    await service.pullSettingsForProfile(client, profile: 'global');
    expect(adapter.savedPins, ['group:News']);
    expect(prefs.get(UserPreferences.liveTvSavedFilterChanges), isEmpty);
  });

  test('failed pin POST keeps the intended removal pending', () async {
    adapter.savedPins = ['group:Sports'];
    await service.handleServerEvent(client, {'type': 'settingsUpdated'});
    adapter.failPinChanges = true;
    expect(await togglePin('group:Sports'), isNull);
    expect(prefs.get(UserPreferences.liveTvSavedFilters), isEmpty);
    expect(prefs.get(UserPreferences.liveTvSavedFilterChanges),
        ['remove:group:Sports']);

    adapter.failPinChanges = false;
    await service.handleServerEvent(client, {'type': 'settingsUpdated'});
    expect(adapter.savedPins, isEmpty);
    expect(prefs.get(UserPreferences.liveTvSavedFilterChanges), isEmpty);
  });

  test('queued pin replies cannot overwrite newer settings or another account', () async {
    adapter.savedPins = [];
    adapter.responseReady = Completer<void>();
    adapter.responseGate = Completer<void>();
    final saving = togglePin('group:Sports');
    await adapter.responseReady!.future;
    adapter.savedPins = ['group:Sports', 'group:News'];
    expect(prefs.get(UserPreferences.liveTvSavedFilters), ['group:Sports']);
    final updating = service.handleServerEvent(client, {'type': 'settingsUpdated'});
    await Future<void>.delayed(Duration.zero);
    expect(resolvedCount(), 0);
    adapter.responseGate!.complete();
    expect(await saving, ['group:Sports']);
    await updating;
    expect(prefs.get(UserPreferences.liveTvSavedFilters),
        ['group:Sports', 'group:News']);

    adapter.responseReady = Completer<void>();
    adapter.responseGate = Completer<void>();
    final stale = togglePin('group:Movies');
    await adapter.responseReady!.future;
    final local = Completer<void>();
    final queued = service.changePinnedGuideFilter(
      client, filter: 'group:Kids', onLocalChange: local.complete,
    );
    await local.future;
    final rejected = expectLater(stale, throwsA(isA<StateError>()));
    final queuedRejected = expectLater(queued, throwsA(isA<StateError>()));
    when(() => client.userId).thenReturn('other');
    adapter.responseGate!.complete();
    await Future.wait([rejected, queuedRejected]);
    // The old account keeps both local edits. Neither stale reply acknowledges them.
    expect(prefs.get(UserPreferences.liveTvSavedFilters),
        ['group:Sports', 'group:News', 'group:Movies', 'group:Kids']);
    expect(prefs.get(UserPreferences.liveTvSavedFilterChanges),
        ['add:group:Movies', 'add:group:Kids']);
    expect(adapter.pinActions, ['add', 'add']);
  });

  test('settings events wait for the sign-in pin snapshot to apply', () async {
    adapter.savedPins = ['group:Sports'];
    await prefs.set(UserPreferences.pluginSyncInitializedForServer('srv1'), true);
    adapter.responseReady = Completer<void>();
    adapter.responseGate = Completer<void>();
    final signingIn = service.syncOnLogin(client, serverId: 'srv1');
    await adapter.responseReady!.future;
    final event = service.handleServerEvent(client, {'type': 'settingsUpdated'});
    await Future<void>.delayed(Duration.zero);
    // The event must not fetch and apply a competing profile during sign-in.
    expect(resolvedCount(), 1);
    adapter.responseGate!.complete();
    await signingIn;
    await event;
    expect(prefs.get(UserPreferences.liveTvSavedFilters), ['group:Sports']);
  });

  test('pin edits wait for sign-in through the active client wrapper', () async {
    final active = _MockConnectivityAwareClient();
    when(() => active.onlineClient).thenReturn(client);
    await GetIt.instance.unregister<MediaServerClient>();
    GetIt.instance.registerSingleton<MediaServerClient>(active);
    adapter.resolvedProfile = {'use24HourClock': true};
    adapter.savedPins = ['group:Sports'];
    await prefs.set(UserPreferences.pluginSyncInitializedForServer('srv1'), true);
    adapter.responseReady = Completer<void>();
    adapter.responseGate = Completer<void>();
    final signingIn = service.syncOnLogin(client, serverId: 'srv1');
    await adapter.responseReady!.future;
    // No local pins until the sign-in snapshot is applied. Toggling Sports
    // must remove the server pin, not add it from the empty local cache.
    final remove = togglePin('group:Sports');
    expect(adapter.pinActions, isEmpty);
    adapter.responseGate!.complete();
    await signingIn;
    expect(prefs.get(UserPreferences.use24HourClock), isTrue);
    expect(await remove, isEmpty);
    expect(adapter.pinActions, ['remove']);
    expect(prefs.get(UserPreferences.liveTvSavedFilters), isEmpty);
    service.resetState();
  });

  test('only changed, forced, or reset settings push again', () async {
    await service.pushSettingsForProfile(client, profile: 'desktop');
    await service.pushSettingsForProfile(client, profile: 'desktop');
    expect(postCount(), 1);

    await prefs.set(UserPreferences.use24HourClock, true);
    await service.pushSettingsForProfile(client, profile: 'desktop');
    expect(postCount(), 2);

    await service.pushSettingsForProfile(client, profile: 'desktop', force: true);
    expect(postCount(), 3);

    service.resetState();
    await service.refreshAvailability(client);
    await service.pushSettingsForProfile(client, profile: 'desktop');
    expect(postCount(), 4);
  });

  test('remote settings apply without pushing them back', () async {
    adapter.resolvedProfile = {'use24HourClock': true};
    var notified = false;
    prefs.addListener(() => notified = true);
    await service.handleServerEvent(client, {'type': 'settingsUpdated'});
    expect(prefs.get(UserPreferences.use24HourClock), isTrue);
    expect(notified, isTrue);

    await service.pushSettings(client);
    // Allow the push debounce to expire before checking for an echo.
    await Future<void>.delayed(const Duration(milliseconds: 1400));
    expect(resolvedCount(), 1);
    expect(postCount(), 0);
  });

}
