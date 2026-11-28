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

class _TestPreferences extends UserPreferences {
  _TestPreferences(super.store);
  final failWrites = <String>[];
  Future<void> Function()? beforePinClear;

  @override
  Future<void> set<T>(Preference<T> pref, T value) async {
    if (pref == UserPreferences.liveTvSavedFilters && value is List<String> && value.isEmpty) {
      await beforePinClear?.call();
    }
    await super.set(pref, value);
    if (pref.key == failWrites.firstOrNull) {
      failWrites.removeAt(0);
      throw StateError('Simulated preference write failure');
    }
  }
}

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
  bool serverSyncEnabled = true;
  bool failPinChanges = false;
  String? unavailablePin;
  String? rejectedPin;
  bool missingProfileUntilPins = false;
  bool confirmsEmptyPins = false;
  Completer<void>? responseReady;
  Completer<void>? responseGate;
  String? pausedPath;
  bool pausePinsOnly = false;
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

  void pauseResponses({String? path}) {
    pausedPath = path;
    responseReady = Completer<void>();
    responseGate = Completer<void>();
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

    Future<ResponseBody> respond(ResponseBody response) async {
      final pause = pausedPath == null
          ? path.contains('/Moonfin/Settings/Resolved/') || options.method == 'POST'
          : path == pausedPath;
      if (pause && (!pausePinsOnly || options.data?['liveTvSavedFilterChange'] != null)) {
        await holdResponse();
      }
      return response;
    }

    Map<String, dynamic>? body;
    if (path.endsWith('/Moonfin/Ping')) {
      body = {'installed': true, 'settingsSyncEnabled': serverSyncEnabled};
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
    } else if (path.contains('/Moonfin/Settings/Profile/')) {
      final change = options.data?['liveTvSavedFilterChange'];
      if (change != null) lastPinRequest = options;
      if (options.data?['profile'] case final Map profile) lastPushedProfile = Map<String, dynamic>.from(profile);
      final filter = options.data?['liveTvSavedFilterChange']?['filter'];
      if (filter != null && filter == rejectedPin) {
        return respond(ResponseBody.fromString('', 400));
      }
      if (options.method == 'POST' && (failPinChanges || (filter != null && filter == unavailablePin))) {
        return respond(ResponseBody.fromString('Temporarily unavailable', 503));
      }
      if (options.method == 'POST' && supportsPinChanges && change is Map) applyPinChange(change);
      body = {
        if (supportsPinChanges && savedPins != null)
          'liveTvSavedFilters': List<String>.of(savedPins!),
      };
    }

    if (body == null) {
      return respond(ResponseBody.fromString('', 404));
    }
    return respond(ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    ));
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _RecordingAdapter adapter;
  late _TestPreferences prefs;
  late PluginSyncService service;
  late _MockClient client;

  Future<List<String>?> togglePin(String filter) =>
      service.changePinnedGuideFilter(client, filter: filter);

  ({Future<List<String>?> saved, Future<void> local}) editPin(String pin) {
    final local = Completer<void>();
    final saved = service.changePinnedGuideFilter(client, filter: pin, onLocalChange: local.complete);
    return (saved: saved, local: local.future);
  }

  Future<void> settingsUpdated() => service.handleServerEvent(client, {'type': 'settingsUpdated'});
  List<String> getPins() => prefs.get(UserPreferences.liveTvSavedFilters);
  List<String> pendingPins() => prefs.get(UserPreferences.liveTvSavedFilterChanges);

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
    prefs = _TestPreferences(store);

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
    final dio = Dio()..httpClientAdapter = adapter;
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

  for (final editClock in [false, true]) {
    test('pin replay with no profile snapshot only uploads a separate settings edit ($editClock)', () async {
      adapter.pauseResponses();
      await prefs.batchNotifications(() async {
        final saving = togglePin('group:Sports');
        await adapter.responseReady!.future;
        if (editClock) await prefs.set(UserPreferences.use24HourClock, true);
        adapter.responseGate!.complete();
        await saving;
      });
      await Future<void>.delayed(const Duration(milliseconds: 1400));
      expect(adapter.pinActions, ['add']);
      expect(postCount(), editClock ? 2 : 1);
      if (editClock) expect(adapter.lastPushedProfile?['use24HourClock'], isTrue);
    });
  }

  for (final editClock in [false, true]) {
    test('confirmed-empty pin clear with ${editClock ? 'a concurrent clock edit' : 'no other edit'}', () async {
      await prefs.set(UserPreferences.liveTvSavedFilters, ['group:News']);
      adapter.missingProfileUntilPins = true;
      adapter.confirmsEmptyPins = true;
      if (editClock) {
        prefs.beforePinClear = () => prefs.set(UserPreferences.use24HourClock, true);
      }

      await settingsUpdated();
      expect(getPins(), isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 1400));
      expect(postCount(), editClock ? 1 : 0);
      if (editClock) expect(adapter.lastPushedProfile?['use24HourClock'], isTrue);
    });
  }

  for (final manual in [false, true]) {
    test('a ${manual ? 'manual load' : 'settings event'} preserves a clock edit during pin replay', () async {
      adapter.failPinChanges = true;
      await togglePin('group:News');
      adapter.failPinChanges = false;
      adapter.savedPins = ['group:Sports'];
      adapter.resolvedProfile = {'use24HourClock': false};
      final profile = service.syncProfile;
      adapter.pauseResponses(path: '/Moonfin/Settings/Profile/$profile');
      final pull = manual
          ? service.pullSettingsForProfile(client, profile: profile)
          : settingsUpdated();
      await adapter.responseReady!.future;
      await prefs.set(UserPreferences.use24HourClock, true);
      adapter.responseGate!.complete();
      await pull;

      expect(prefs.get(UserPreferences.use24HourClock), isTrue);
      expect(getPins(), ['group:Sports', 'group:News']);
      expect(pendingPins(), isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 1400));
      expect(adapter.lastPushedProfile?['use24HourClock'], isTrue);
    });
  }

  test('a rejected replay restores the downloaded pins from another device', () async {
    adapter.failPinChanges = true;
    await togglePin('group:News');
    adapter.failPinChanges = false;
    adapter.savedPins = ['group:Sports'];
    adapter.rejectedPin = 'group:News';
    await settingsUpdated();
    expect(getPins(), ['group:Sports']);
    expect(pendingPins(), isEmpty);
  });

  test('an automatic save queued for desktop cannot upload a loaded TV profile', () async {
    await service.setSyncProfile('desktop');
    await prefs.set(UserPreferences.use24HourClock, true);
    adapter.pauseResponses(path: '/Moonfin/Settings/Profile/desktop');
    final first = service.pushSettings(client);
    await adapter.responseReady!.future;
    final queued = service.pushSettings(client);
    await service.setSyncProfile('tv');
    adapter.resolvedProfile = {'use24HourClock': false};
    expect(await service.pullSettingsForProfile(client, profile: 'tv'), isTrue);
    adapter.responseGate!.complete();
    await Future.wait([first, queued]);
    expect(postCount(), 1);
    expect(adapter.lastPushedProfile?['use24HourClock'], isTrue);

    await service.pushSettingsForProfile(client, profile: 'desktop', force: true);
    expect(postCount(), 2);
    expect(adapter.lastPushedProfile?['use24HourClock'], isFalse);
  });

  test('enabling sync drops its queued upload if another profile is selected', () async {
    when(() => client.serverType).thenReturn(ServerType.emby);
    await service.setSyncProfile('desktop');
    adapter.pauseResponses(path: '/Moonfin/Settings/Profile/desktop');
    final pin = togglePin('group:Sports');
    await adapter.responseReady!.future;
    await service.setSyncEnabled(false);
    final enabling = service.setSyncEnabled(true);
    await Future<void>.delayed(Duration.zero);
    await service.setSyncProfile('tv');
    adapter.responseGate!.complete();
    await pin;
    await enabling;
    expect(adapter.pinActions, ['add']);
    expect(postCount(), 1);
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

  for (final pref in [UserPreferences.liveTvSavedFilters, UserPreferences.liveTvSavedFilterChanges]) {
    test('a failed write to ${pref.key} preserves only earlier pin edits', () async {
      adapter.failPinChanges = true;
      await togglePin('group:News');
      prefs.failWrites.add(prefs.getEffectivePreference(pref).key);
      await expectLater(togglePin('group:Sports'), throwsStateError);
      expect(getPins(), ['group:News']);
      expect(pendingPins(), ['add:group:News']);
      adapter.failPinChanges = false;
      await settingsUpdated();
      expect(adapter.savedPins, ['group:News']);
      expect(adapter.pinActions, ['add']);
    });
  }

  test('a failed journal rollback still restores the visible pins', () async {
    prefs.failWrites.addAll([
      prefs.getEffectivePreference(UserPreferences.liveTvSavedFilters).key,
      prefs.getEffectivePreference(UserPreferences.liveTvSavedFilterChanges).key,
    ]);
    await expectLater(togglePin('group:News'), throwsStateError);
    expect(getPins(), isEmpty);
    expect(pendingPins(), isEmpty);
  });

  test('a rejection after disabling sync keeps the local choice pending', () async {
    adapter.rejectedPin = 'group:News';
    adapter.pauseResponses();
    final saving = togglePin('group:News');
    await adapter.responseReady!.future;
    await service.setSyncEnabled(false);
    adapter.responseGate!.complete();
    await saving;
    expect(getPins(), ['group:News']);
    expect(pendingPins(), ['add:group:News']);
    await prefs.set(UserPreferences.pluginSyncEnabled, true);
    await service.retryPendingGuidePins(client);
    expect(getPins(), isEmpty);
    expect(pendingPins(), isEmpty);
  });

  for (final pinned in [true, false]) {
    test('repeating a pending offline choice rolls back to its original membership ($pinned)', () async {
      const filter = 'group:Sports';
      final original = [if (!pinned) filter];
      await prefs.set(UserPreferences.liveTvSavedFilters, original);
      adapter.savedPins = List.of(original);
      service.resetState();
      await service.changePinnedGuideFilter(client, filter: filter, pinned: pinned);
      await togglePin('group:News');
      final pending = pendingPins();
      await service.changePinnedGuideFilter(client, filter: filter, pinned: pinned);
      expect(pendingPins(), pending);
      adapter.rejectedPin = filter;
      adapter.unavailablePin = 'group:News';
      await service.retryPendingGuidePins(client);
      expect(getPins().contains(filter), !pinned);
      expect(adapter.savedPins, original);
      expect(pendingPins(), ['add:group:News']);
    });

    for (final retry in [false, true]) {
      test('rejecting an already satisfied pin choice preserves it (pinned=$pinned, retry=$retry)', () async {
        const filter = 'group:Sports';
        final original = ['group:News', if (pinned) filter, 'group:Kids'];
        adapter.savedPins = List.of(original);
        await prefs.set(UserPreferences.liveTvSavedFilters, original);
        adapter.rejectedPin = filter;
        if (retry) service.resetState();

        final edit = service.changePinnedGuideFilter(client, filter: filter, pinned: pinned);
        if (retry) {
          await edit;
          expect(pendingPins(), hasLength(1));
          expect(postCount(), 0);
          service.resetState();
          await service.retryPendingGuidePins(client);
        } else {
          await expectLater(edit, throwsA(isA<DioException>()));
        }

        expect(adapter.lastPinRequest?.data['liveTvSavedFilterChange'], {
          'action': pinned ? 'add' : 'remove', 'filter': filter,
        });
        expect(getPins(), original);
        expect(adapter.savedPins, original);
        expect(pendingPins(), isEmpty);
      });
    }

    test('a server reply preserves a pending explicit pin choice (pinned=$pinned)', () async {
      const filter = 'group:Sports';
      service.resetState();
      await prefs.set(UserPreferences.liveTvSavedFilters, [if (pinned) filter]);
      await togglePin('group:News');
      await service.changePinnedGuideFilter(client, filter: filter, pinned: pinned);
      adapter.savedPins = [if (!pinned) filter];
      adapter.unavailablePin = filter;
      await service.retryPendingGuidePins(client);
      expect(getPins(), ['group:News', if (pinned) filter]);
      expect(pendingPins(), hasLength(1));

      adapter.unavailablePin = null;
      await service.retryPendingGuidePins(client);
      expect(adapter.savedPins, getPins());
      expect(getPins(), ['group:News', if (pinned) filter]);
      expect(pendingPins(), isEmpty);
    });
  }

  test('a final rejection keeps remote pins from the preceding successful reply', () async {
    service.resetState();
    await togglePin('group:News');
    await togglePin('group:Rejected');
    adapter.savedPins = ['group:Sports'];
    adapter.rejectedPin = 'group:Rejected';
    await service.retryPendingGuidePins(client, serverId: 'srv1');
    expect(getPins(), ['group:Sports', 'group:News']);
    expect(pendingPins(), isEmpty);
  });

  for (final rejected in [true, false]) {
    test('identical taps share the in-flight result (rejected=$rejected)', () async {
      const filter = 'group:Sports';
      adapter.pauseResponses();
      if (rejected) adapter.rejectedPin = filter;
      final first = service.changePinnedGuideFilter(client, filter: filter, pinned: true);
      await adapter.responseReady!.future;
      final local = Completer<void>();
      final repeated = service.changePinnedGuideFilter(
        client, filter: filter, pinned: true, onLocalChange: local.complete,
      );
      await local.future;
      final result = rejected ? throwsA(isA<DioException>()) : completion([filter]);
      final checks = [expectLater(first, result), expectLater(repeated, result)];
      adapter.responseGate!.complete();
      await Future.wait(checks);
      expect(postCount(), 1);
      expect(pendingPins(), isEmpty);
      expect(getPins().contains(filter), !rejected);
    });
  }

  test('a queued tap keeps remote pins from an earlier tap when rejected', () async {
    adapter.savedPins = ['group:Sports'];
    adapter.pauseResponses();
    final saving = togglePin('group:News');
    await adapter.responseReady!.future;
    adapter.rejectedPin = 'group:Rejected';
    final edit = editPin('group:Rejected');
    await edit.local;
    final rejection = expectLater(edit.saved, throwsA(isA<DioException>()));
    adapter.responseGate!.complete();
    await saving;
    await rejection;
    expect(getPins(), adapter.savedPins);
    expect(pendingPins(), isEmpty);
  });

  for (final restoreProfile in [false, true]) {
    test('sign-in keeps a queued pin local until ${restoreProfile ? 'a profile is restored' : 'sync is enabled'}', () async {
      when(() => client.serverType).thenReturn(ServerType.emby);
      await prefs.removePreference(UserPreferences.pluginSyncEnabled);
      adapter.missingProfileUntilPins = true;
      adapter.confirmsEmptyPins = true;
      await togglePin('group:News');
      await service.syncOnLogin(client, serverId: 'srv1');
      expect(postCount(), 0);
      expect(resolvedCount(), 1);
      expect(prefs.get(UserPreferences.pluginSyncEnabled), isFalse);
      expect(getPins(), ['group:News']);
      expect(pendingPins(), ['add:group:News']);

      if (restoreProfile) {
        adapter.savedPins = ['group:Sports'];
        await service.syncOnLogin(client, serverId: 'srv1');
      } else {
        await service.setSyncEnabled(true);
      }
      expect(prefs.get(UserPreferences.pluginSyncEnabled), isTrue);
      expect(adapter.pinActions, ['add']);
      expect(getPins(), [if (restoreProfile) 'group:Sports', 'group:News']);
      expect(pendingPins(), isEmpty);
    });
  }

  test('enabling sync before the first profile GET uploads the restored settings', () async {
    when(() => client.serverType).thenReturn(ServerType.emby);
    await prefs.set(UserPreferences.pluginSyncEnabled, false);
    adapter.resolvedProfile = {'liveTvCategoryDisplay': 'groups'};
    adapter.pauseResponses(path: '/Moonfin/Seerr/Config');
    final login = service.syncOnLogin(client, serverId: 'srv1');
    await adapter.responseReady!.future;
    final enabling = service.setSyncEnabled(true);
    await Future<void>.delayed(Duration.zero);
    adapter.responseGate!.complete();
    await Future.wait([login, enabling]);
    final profile = service.syncProfile;
    expect(adapter.requests, containsAllInOrder([
      'GET /Moonfin/Settings/Resolved/$profile', 'POST /Moonfin/Settings/Profile/$profile',
    ]));
    expect(adapter.lastPushedProfile?['liveTvCategoryDisplay'], 'groups');
  });

  test('first sign-in restores the newly created profile after a partial pin replay', () async {
    when(() => client.serverType).thenReturn(ServerType.emby);
    const sports = 'group:Sports';
    const news = 'group:News';
    adapter.missingProfileUntilPins = true;
    adapter.unavailablePin = news;
    adapter.resolvedProfile = {'use24HourClock': true};
    await prefs.set(UserPreferences.liveTvSavedFilters, [sports, news]);
    await prefs.set(UserPreferences.liveTvSavedFilterChanges, ['add:$sports', 'add:$news']);

    await service.syncOnLogin(client, serverId: 'srv1');
    expect(resolvedCount(), 2);
    expect(service.isSyncInitializedForServer(client, serverId: 'srv1'), isTrue);
    expect(prefs.get(UserPreferences.use24HourClock), isTrue);
    expect(adapter.savedPins, [sports]);
    expect(getPins(), [sports, news]);
    expect(pendingPins(), ['add:$news']);

    adapter.unavailablePin = null;
    await service.retryPendingGuidePins(client, serverId: 'srv1');
    expect(adapter.pinActions, ['add', 'add']);
    expect(adapter.savedPins, [sports, news]);
    expect(pendingPins(), isEmpty);
  });

  for (final pending in [false, true]) {
    test('manual Save during sign-in with ${pending ? 'a queued pin' : 'no queued pins'}', () async {
      when(() => client.serverType).thenReturn(ServerType.emby);
      adapter.savedPins = [];
      if (pending) {
        service.resetState();
        await togglePin('group:News');
      }
      adapter.pauseResponses(path: '/Moonfin/Seerr/Config');
      final login = service.syncOnLogin(client, serverId: 'srv1');
      await adapter.responseReady!.future;
      final save = service.pushSettingsForProfile(client, profile: 'global', force: true);
      adapter.responseGate!.complete();
      expect(await save, ProfilePushResult.saved);
      await login;

      final read = 'GET /Moonfin/Settings/Resolved/${service.syncProfile}';
      const write = 'POST /Moonfin/Settings/Profile/global';
      expect(
        adapter.requests.where((r) => r == read || r == write),
        pending ? [read, write] : [write, read],
      );
      expect(adapter.savedPins, [if (pending) 'group:News']);
    });
  }

  test('network regain during a failed sign-in replay retries on Emby', () async {
    when(() => client.serverType).thenReturn(ServerType.emby);
    service.resetState();
    await togglePin('group:News');
    adapter.failPinChanges = true;
    adapter.pauseResponses(path: '/Moonfin/Settings/Profile/${service.syncProfile}');
    final login = service.syncOnLogin(client, serverId: 'srv1');
    await adapter.responseReady!.future;
    final reconnect = service.retryPendingGuidePins(client, serverId: 'srv1');
    adapter.failPinChanges = false;
    adapter.responseGate!.complete();
    await Future.wait([login, reconnect]);
    expect(adapter.pinActions, ['add']);
    expect(pendingPins(), isEmpty);
  });

  test('rejecting the first add preserves a later add of the same pin', () async {
    const filter = 'group:Sports';
    adapter.rejectedPin = filter;
    adapter.pauseResponses();
    final first = togglePin(filter);
    await adapter.responseReady!.future;
    adapter.rejectedPin = null;
    final (saved: remove, local: removedChange) = editPin(filter);
    await removedChange;
    final (saved: add, local: addedChange) = editPin(filter);
    await addedChange;
    adapter.responseGate!.complete();
    await Future.wait([first, remove, add]);
    expect(postCount(), 2);
    expect(adapter.savedPins, [filter]);
    expect(getPins(), [filter]);
    expect(pendingPins(), isEmpty);
  });

  test('queued edits keep the last pin order after an unpin and re-pin', () async {
    adapter.pauseResponses();
    final saving = togglePin('group:Sports');
    await adapter.responseReady!.future;
    final edits = <Future<List<String>?>>[saving];
    for (final pin in ['group:News', 'group:Kids', 'group:News', 'group:News']) {
      final edit = editPin(pin);
      await edit.local;
      edits.add(edit.saved);
    }
    const expected = ['group:Sports', 'group:Kids', 'group:News'];
    expect(getPins(), expected);
    adapter.responseGate!.complete();
    await Future.wait(edits);
    expect(adapter.savedPins, expected);
    expect(getPins(), expected);
    expect(pendingPins(), isEmpty);
  });

  test('a session reset invalidates a held reply even if the client is reused', () async {
    adapter.pauseResponses();
    final saving = togglePin('group:Sports');
    await adapter.responseReady!.future;
    service.resetState();
    await service.refreshAvailability(client);
    final stale = expectLater(saving, throwsStateError);
    adapter.responseGate!.complete();
    await stale;
    expect(pendingPins(), ['add:group:Sports']);
    adapter.savedPins!.add('group:News');
    await service.retryPendingGuidePins(client, serverId: 'srv1');
    expect(getPins(), adapter.savedPins);
    expect(pendingPins(), isEmpty);
  });

  test('a settings event discards a held read after selecting another profile', () async {
    adapter.resolvedProfile = {'liveTvCategoryDisplay': 'groups'};
    adapter.pauseResponses();
    final event = settingsUpdated();
    await adapter.responseReady!.future;
    final display = prefs.get(UserPreferences.liveTvCategoryDisplay);
    await service.setSyncProfile('global');
    adapter.responseGate!.complete();
    await event;
    expect(prefs.get(UserPreferences.liveTvCategoryDisplay), display);
  });

  test('network regain rechecks server opt-in after an offline start', () async {
    service.resetState();
    await togglePin('group:News');
    adapter.savedPins = ['group:Sports'];
    adapter.serverSyncEnabled = false;
    await service.retryPendingGuidePins(client, serverId: 'srv1');
    expect(adapter.pinActions, isEmpty);
    expect(pendingPins(), ['add:group:News']);
    adapter.serverSyncEnabled = true;
    await service.retryPendingGuidePins(client, serverId: 'srv1');
    expect(adapter.pinActions, ['add']);
    expect(getPins(), ['group:Sports', 'group:News']);
    expect(pendingPins(), isEmpty);
  });

  test('overlapping reconnects share account pins across device profiles', () async {
    service.resetState();
    await togglePin('group:News');
    await togglePin('group:Kids');
    await service.refreshAvailability(client);
    adapter.savedPins = ['group:Sports'];
    adapter.pauseResponses();
    final reconnect = service.retryPendingGuidePins(client, serverId: 'srv1');
    await adapter.responseReady!.future;
    final stream = service.retryPendingGuidePins(client);
    await service.setSyncProfile('global');
    adapter.responseGate!.complete();
    await Future.wait([reconnect, stream]);
    expect(adapter.pinActions, ['add', 'add']);
    expect(getPins(), ['group:Sports', 'group:News', 'group:Kids']);
    expect(pendingPins(), isEmpty);
  });

  test('a second tap updates the guide while the first upload is waiting', () async {
    adapter.savedPins = [];
    adapter.pauseResponses();
    final first = togglePin('group:Sports');
    await adapter.responseReady!.future;
    final (saved: second, local: localChange) = editPin('group:Sports');
    await localChange;
    expect(getPins(), isEmpty);
    expect(adapter.pinActions, ['add']);
    adapter.responseGate!.complete();
    await Future.wait([first, second]);
    expect(adapter.pinActions, ['add', 'remove']);
    expect(adapter.savedPins, isEmpty);
    expect(pendingPins(), isEmpty);
  });

  test('switching sync off keeps queued pins local even after a settings event', () async {
    adapter.pauseResponses();
    final first = togglePin('group:Sports');
    await adapter.responseReady!.future;
    final (saved: second, local: localChange) = editPin('group:News');
    await localChange;
    final event = settingsUpdated();
    await prefs.set(UserPreferences.pluginSyncEnabled, false);
    adapter.responseGate!.complete();
    await first;
    expect(await second, isNull);
    await event;
    await settingsUpdated();
    expect(resolvedCount(), 0);
    expect(adapter.savedPins, ['group:Sports']);
    expect(getPins(), ['group:Sports', 'group:News']);
    expect(pendingPins(), ['add:group:News']);
  });

  test('device reset reloads settings and leaves offline pins for the next sync', () async {
    service.resetState();
    await togglePin('group:Sports');
    adapter.savedPins = ['group:News'];
    adapter.resolvedProfile = {'use24HourClock': true};
    await service.refreshAvailability(client);

    expect(await service.resetProfileToDefaults(client, profile: 'desktop'), isTrue);
    expect(adapter.requests, contains('DELETE /Moonfin/Settings/Profile/desktop'));
    expect(postCount(), 0);
    expect(prefs.get(UserPreferences.use24HourClock), isTrue);
    expect(getPins(), ['group:Sports']);
    expect(pendingPins(), ['add:group:Sports']);

    await settingsUpdated();
    expect(adapter.pinActions, ['add']);
    expect(adapter.savedPins, ['group:News', 'group:Sports']);
    expect(getPins(), adapter.savedPins);
    expect(pendingPins(), isEmpty);
  });

  test('turning sync off cancels a reset queued behind a pin upload', () async {
    adapter.pauseResponses();
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
    expect(getPins(), ['group:Sports']);
  });

  for (final (accountChanged, pinAccepted, expected) in [
    (false, false, ProfilePushResult.savedWithPinErrors),
    (false, true, ProfilePushResult.saved),
    (true, true, ProfilePushResult.accountChanged),
  ]) {
    test('manual Save preserves the profile acknowledgement (accountChanged=$accountChanged, pinAccepted=$pinAccepted)', () async {
      service.resetState();
      await togglePin('group:News');
      await service.refreshAvailability(client);
      adapter.pausePinsOnly = true;
      adapter.pauseResponses();
      if (!pinAccepted) adapter.unavailablePin = 'group:News';
      final saving = service.pushSettingsForProfile(client, profile: 'tv', force: true);
      await adapter.responseReady!.future;
      expect(postCount(), 2);
      if (accountChanged) {
        when(() => client.userId).thenReturn('other');
      } else {
        await service.setSyncEnabled(false);
      }
      adapter.responseGate!.complete();
      expect(await saving, expected);
      expect(pendingPins().isEmpty, pinAccepted && !accountChanged);
    });
  }

  test('manual Save distinguishes profile failure from a pending or rejected pin', () async {
    Future<ProfilePushResult> save() => service.pushSettingsForProfile(client, profile: 'tv', force: true);
    adapter.failPinChanges = true; // The adapter returns 503 for all profile POSTs.
    expect(await save(), ProfilePushResult.failed);
    adapter.failPinChanges = false;
    adapter.unavailablePin = 'group:News';
    expect(await togglePin('group:News'), isNull);
    expect(await save(), ProfilePushResult.savedWithPinErrors);
    expect(pendingPins(), ['add:group:News']);
    adapter.unavailablePin = null;
    adapter.savedPins = ['group:Sports'];
    expect(await save(), ProfilePushResult.saved);
    expect(adapter.savedPins, ['group:Sports', 'group:News']);
    expect(pendingPins(), isEmpty);

    await prefs.set(UserPreferences.pluginSyncEnabled, false);
    await togglePin('group:Rejected');
    await prefs.set(UserPreferences.pluginSyncEnabled, true);
    adapter.rejectedPin = 'group:Rejected';
    expect(await save(), ProfilePushResult.savedWithPinErrors);
    expect(pendingPins(), isEmpty);
    expect(adapter.savedPins, ['group:Sports', 'group:News']);
  });

  test('only an explicit empty profile clears cached pins on another device', () async {
    await togglePin('group:News');
    adapter.savedPins = null;
    adapter.missingProfileUntilPins = true;
    await settingsUpdated();
    expect(getPins(), ['group:News']);
    adapter.confirmsEmptyPins = true;
    await settingsUpdated();
    expect(getPins(), isEmpty);

    service.resetState();
    await togglePin('group:Sports');
    await service.refreshAvailability(client);
    adapter.failPinChanges = true;
    await settingsUpdated();
    expect(getPins(), ['group:Sports']);
    expect(pendingPins(), ['add:group:Sports']);
  });

  for (final freshProfile in [false, true]) {
    test('offline guide edits survive a profile push and replay on reconnect (new profile=$freshProfile)', () async {
      const local = ['group:US | SPORTS, Canada', 'category:sports'];
      adapter.missingProfileUntilPins = freshProfile;
      adapter.savedPins = freshProfile ? null : [];
      service.resetState();
      expect(await Future.wait(local.map(togglePin)), [null, null]);
      expect(adapter.requests, isEmpty);
      expect(pendingPins(), [for (final pin in local) 'add:$pin']);

      await service.refreshAvailability(client);
      final push = await service.pushSettingsForProfile(client, profile: 'desktop');
      expect(push, ProfilePushResult.saved);
      expect(adapter.lastPushedProfile, isNotNull);
      expect(adapter.lastPushedProfile!, isNot(contains('liveTvSavedFilters')));
      expect(await service.pullSettingsForProfile(client, profile: 'desktop'), isTrue);
      expect(await togglePin('group:News'), [...local, 'group:News']);
      expect(adapter.pinActions, ['add', 'add', 'add']);
      expect(adapter.savedPins, getPins());
      expect(pendingPins(), isEmpty);

      adapter.savedPins = ['group:News', 'category:movies'];
      await settingsUpdated();
      expect(getPins(), adapter.savedPins);
      adapter.missingProfileUntilPins = false;
      adapter.savedPins = null;
      adapter.resolvedProfile = {'liveTvCategoryDisplay': 'groups'};
      await settingsUpdated();
      expect(getPins(), ['group:News', 'category:movies']);
      for (final pins in [['group:Sports'], <String>[]]) {
        adapter.resolvedProfile = {'liveTvSavedFilters': pins};
        await service.pullSettingsForProfile(client, profile: 'desktop');
        expect(getPins(), pins);
      }
      expect(adapter.pinActions, ['add', 'add', 'add']);
    });
  }

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
    expect(getPins(), local);

    adapter.supportsPinChanges = true;
    adapter.failPinChanges = true;
    await settingsUpdated();
    expect(getPins(), local);
    expect(prefs.get(UserPreferences.use24HourClock), isTrue);
    adapter.failPinChanges = false;
    await settingsUpdated();
    expect(adapter.savedPins, ['group:Admin', ...local]);
    expect(getPins(), adapter.savedPins);
    expect(pendingPins(), isEmpty);
  });

  test('reconnecting replays the last local choice and keeps edits made on another device', () async {
    adapter.savedPins = ['group:Sports', 'group:Kids'];
    await settingsUpdated();
    adapter.failPinChanges = true;
    expect(await togglePin('group:Sports'), isNull);
    expect(getPins(), ['group:Kids']);
    expect(pendingPins(), ['remove:group:Sports']);
    service.resetState();
    for (var tap = 0; tap < 3; tap++) { await togglePin('group:Movies'); }
    expect(pendingPins(), ['remove:group:Sports', 'add:group:Movies']);
    adapter.savedPins!.add('group:News');
    adapter.failPinChanges = false;
    adapter.unavailablePin = 'group:Movies';
    await service.refreshAvailability(client);
    await service.pullSettingsForProfile(client, profile: 'global');
    expect(pendingPins(), ['add:group:Movies']);
    expect(getPins(), contains('group:Movies'));

    adapter.savedPins!.add('group:Sports'); // Someone else re-pins it after our removal was confirmed.
    adapter.unavailablePin = null;
    await settingsUpdated();
    expect(adapter.pinActions, ['remove', 'add']);
    expect(getPins(), ['group:Kids', 'group:News', 'group:Sports', 'group:Movies']);
    expect(adapter.savedPins, getPins());
    expect(pendingPins(), isEmpty);
  });

  test('removing an over-limit local pin does not queue a server edit', () async {
    final pin = 'group:${'x' * 1024}';
    await prefs.set(UserPreferences.liveTvSavedFilters, [pin]);
    await togglePin(pin);
    expect(getPins(), isEmpty);
    expect(pendingPins(), isEmpty);
    expect(adapter.pinActions, isEmpty);
    await expectLater(togglePin(pin), throwsFormatException);
  });

  test('invalid pins surface an error and never block later edits', () async {
    await expectLater(togglePin('group:${'x' * 1024}'), throwsFormatException);
    adapter.rejectedPin = 'group:Rejected';
    await expectLater(togglePin('group:Rejected'), throwsA(isA<DioException>()));
    expect(getPins(), isEmpty);
    service.resetState();
    await togglePin('group:Rejected');
    await togglePin('group:News');
    await service.refreshAvailability(client);
    await service.pullSettingsForProfile(client, profile: 'global');
    expect(adapter.savedPins, ['group:News']);
    expect(pendingPins(), isEmpty);
  });

  test('queued pin replies cannot overwrite newer settings or another account', () async {
    adapter.savedPins = [];
    adapter.pauseResponses();
    final saving = togglePin('group:Sports');
    await adapter.responseReady!.future;
    adapter.savedPins = ['group:Sports', 'group:News'];
    expect(getPins(), ['group:Sports']);
    final updating = settingsUpdated();
    await Future<void>.delayed(Duration.zero);
    expect(resolvedCount(), 0);
    adapter.responseGate!.complete();
    expect(await saving, ['group:Sports']);
    await updating;
    expect(getPins(),
        ['group:Sports', 'group:News']);

    adapter.pauseResponses();
    final stale = togglePin('group:Movies');
    await adapter.responseReady!.future;
    final (saved: queued, local: localChange) = editPin('group:Kids');
    await localChange;
    final rejected = expectLater(stale, throwsA(isA<StateError>()));
    final queuedRejected = expectLater(queued, throwsA(isA<StateError>()));
    when(() => client.userId).thenReturn('other');
    adapter.responseGate!.complete();
    await Future.wait([rejected, queuedRejected]);
    // The old account keeps both local edits. Neither stale reply acknowledges them.
    expect(getPins(),
        ['group:Sports', 'group:News', 'group:Movies', 'group:Kids']);
    expect(pendingPins(),
        ['add:group:Movies', 'add:group:Kids']);
    expect(adapter.pinActions, ['add', 'add']);
  });

  for (final pinned in [null, true, false]) {
    test('sign-in orders settings events and preserves the displayed pin action ($pinned)', () async {
      final active = _MockConnectivityAwareClient();
      when(() => active.onlineClient).thenReturn(client);
      await GetIt.instance.unregister<MediaServerClient>();
      GetIt.instance.registerSingleton<MediaServerClient>(active);
      adapter.resolvedProfile = {'use24HourClock': true};
      const sports = 'group:Sports';
      const news = 'group:News';
      if (pinned == false) await prefs.set(UserPreferences.liveTvSavedFilters, [sports]);
      adapter.savedPins = [news, if (pinned != false) sports];
      await prefs.set(UserPreferences.pluginSyncInitializedForServer('srv1'), true);
      adapter.pauseResponses();
      final signingIn = service.syncOnLogin(client, serverId: 'srv1');
      await adapter.responseReady!.future;
      var notified = false;
      final edit = pinned == null ? null : service.changePinnedGuideFilter(
        client, filter: sports, pinned: pinned, onLocalChange: () => notified = true,
      );
      final event = pinned == null ? settingsUpdated() : null;
      await pumpEventQueue();
      expect(resolvedCount(), 1);
      expect(adapter.pinActions, isEmpty);
      if (pinned != null) {
        expect(notified, isTrue);
        expect(getPins().contains(sports), pinned);
        expect(pendingPins(), [pinned ? 'add:$sports' : 'remove:$sports']);
      }
      adapter.responseGate!.complete();
      await signingIn;
      await event;
      await edit;
      expect(prefs.get(UserPreferences.use24HourClock), isTrue);
      expect(adapter.pinActions, [if (pinned != null) pinned ? 'add' : 'remove']);
      expect(getPins(), [news, if (pinned != false) sports]);
      expect(adapter.savedPins, getPins());
      expect(pendingPins(), isEmpty);
      service.resetState();
    });
  }

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
    await settingsUpdated();
    expect(prefs.get(UserPreferences.use24HourClock), isTrue);
    expect(notified, isTrue);

    await service.pushSettings(client);
    // Allow the push debounce to expire before checking for an echo.
    await Future<void>.delayed(const Duration(milliseconds: 1400));
    expect(resolvedCount(), 1);
    expect(postCount(), 0);
  });

}
