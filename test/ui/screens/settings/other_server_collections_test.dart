import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moonfin/auth/models/server.dart';
import 'package:moonfin/data/repositories/multi_server_repository.dart';
import 'package:moonfin/data/services/plugin_sync_service.dart';
import 'package:moonfin/l10n/app_localizations.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:moonfin/ui/screens/settings/home_sections_screen.dart';
import 'package:moonfin/util/platform_detection.dart';
import 'package:server_core/server_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockClient extends Mock implements MediaServerClient {}

class _MockItemsApi extends Mock implements ItemsApi {}

class _MockMultiServer extends Mock implements MultiServerRepository {}

class _MockSyncService extends Mock implements PluginSyncService {}

MediaServerClient client(String baseUrl, String collection) {
  final items = _MockItemsApi();
  when(
    () => items.getItems(
      includeItemTypes: const ['BoxSet'],
      sortBy: 'SortName',
      sortOrder: 'Ascending',
      recursive: true,
      startIndex: 0,
      limit: 250,
    ),
  ).thenAnswer(
    (_) async => {
      'Items': [
        {'Id': collection, 'Name': collection},
      ],
      'TotalRecordCount': 1,
    },
  );
  final client = _MockClient();
  when(() => client.userId).thenReturn('user');
  when(() => client.baseUrl).thenReturn(baseUrl);
  when(() => client.itemsApi).thenReturn(items);
  return client;
}

// Issue #1028: with multi-server libraries on, collections from every
// signed-in server can be picked as Home rows.
void main() {
  late UserPreferences prefs;

  setUp(() async {
    PlatformDetection.setInterfaceLayout(InterfaceLayout.tv);
    SharedPreferences.setMockInitialValues({});
    final store = PreferenceStore();
    await store.init();
    prefs = UserPreferences(store);
    await prefs.set(UserPreferences.displayCollectionsRows, true);
    GetIt.instance.registerSingleton<UserPreferences>(prefs);
    GetIt.instance.registerSingleton<MediaServerClient>(
      client('http://server', 'Local'),
    );

    final multiServer = _MockMultiServer();
    when(() => multiServer.getLoggedInServers()).thenAnswer(
      (_) async => [
        ServerUserSession(
          server: Server(
            id: 'other-id',
            name: 'Other',
            address: 'http://other',
            version: '4.10',
            serverType: ServerType.emby,
            dateAdded: DateTime(2026),
          ),
          userId: 'user',
          client: client('http://other', 'Marvel'),
        ),
      ],
    );
    GetIt.instance.registerSingleton<MultiServerRepository>(multiServer);

    final sync = _MockSyncService();
    when(() => sync.pluginAvailable).thenReturn(false);
    when(() => sync.seerrAvailable).thenReturn(false);
    GetIt.instance.registerSingleton<PluginSyncService>(sync);
  });

  tearDown(() async {
    PlatformDetection.setInterfaceLayout(InterfaceLayout.automatic);
    await GetIt.instance.reset();
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 6000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const HomeSectionsScreen(),
      ),
    );
    await tester.pumpAndSettle();
    // The collection rows start disabled, inside the closed Collections group.
    await tester.tap(find.text('Collections').first);
    await tester.pumpAndSettle();
  }

  testWidgets('lists every server\'s collections, naming the other server', (
    tester,
  ) async {
    await prefs.set(UserPreferences.enableMultiServerLibraries, true);
    await pump(tester);

    expect(find.text('Local'), findsOneWidget);
    expect(find.text('Marvel'), findsOneWidget);
    expect(find.text('Collections row from Other'), findsOneWidget);
    expect(
      prefs.homeSectionsConfig.map((c) => c.stableId),
      contains('pluginDynamic:collections:http://other:collection:Marvel'),
    );
  });

  testWidgets('hides the other server\'s collections once multi-server is off', (
    tester,
  ) async {
    await prefs.set(UserPreferences.enableMultiServerLibraries, true);
    await pump(tester);
    await tester.pumpWidget(const SizedBox());

    await prefs.set(UserPreferences.enableMultiServerLibraries, false);
    await pump(tester);

    expect(find.text('Local'), findsOneWidget);
    expect(find.text('Marvel'), findsNothing);
    expect(
      prefs.homeSectionsConfig.map((c) => c.stableId),
      contains('pluginDynamic:collections:http://other:collection:Marvel'),
    );
  });
}
