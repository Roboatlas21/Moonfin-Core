import 'dart:async';

import 'package:custom_tv_text_field/custom_tv_text_field.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:mocktail/mocktail.dart';
import 'package:playback_core/playback_core.dart';
import 'package:moonfin/data/viewmodels/live_tv_guide_view_model.dart';
import 'package:moonfin/data/services/user_data_sync.dart';
import 'package:moonfin/l10n/app_localizations.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:moonfin/preference/preference_constants.dart';
import 'package:moonfin/ui/navigation/destinations.dart';
import 'package:moonfin/ui/screens/livetv/guide/guide_filter_picker.dart';
import 'package:moonfin/ui/screens/livetv/epg/widgets/epg_filter_rail.dart';
import 'package:moonfin/ui/screens/livetv/epg/widgets/epg_channel_cell.dart';
import 'package:moonfin/ui/screens/livetv/epg/widgets/epg_now_next_card.dart';
import 'package:moonfin/ui/screens/livetv/epg/widgets/epg_program_cell.dart';
import 'package:moonfin/ui/screens/livetv/epg/widgets/epg_hero_preview.dart';
import 'package:moonfin/ui/screens/livetv/guide/guide_window.dart';
import 'package:moonfin/ui/screens/livetv/guide/guide_layout_profile.dart';
import 'package:moonfin/ui/screens/livetv/live_tv_guide_screen.dart';
import 'package:moonfin/ui/widgets/local_search_field.dart';
import 'package:moonfin/ui/widgets/overlay_sheet.dart' show DialogBackSuppressor;
import 'package:moonfin/util/clock_format.dart';
import 'package:moonfin/util/platform_detection.dart';
import 'package:server_core/server_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

// MaterialApp hosts the guide in these tests. Forward Android's system Back
// through the same dismissal check that MoonfinApp uses before its navigator.
class _DialogBackObserver extends WidgetsBindingObserver {
  int suppressed = 0;

  @override
  Future<bool> didPopRoute() async {
    if (!DialogBackSuppressor.consume()) return false;
    suppressed++;
    return true;
  }
}

class _MockMediaServerClient extends Mock implements MediaServerClient {}

class _MockLiveTvApi extends Mock implements LiveTvApi, ChannelGroupApi {}

class _MockUserLibrary extends Mock implements UserLibraryApi {}

class _MockPlaybackManager extends Mock implements PlaybackManager {}

/// Deliberately asymmetric row shapes: differing program durations give the
/// rows differing cell counts and boundaries, which is what makes a drifting
/// vertical move visible as a different cell index.
const _durations = <int>[20, 30, 45, 60, 180];

const _channelCount = 48;

/// One batch is 50 channels, so a lineup past that leaves the tail rows
/// genuinely unloaded, the only honest way to observe a loading row.
const _deferredChannelCount = 60;
const _firstDeferredChannelId = 'ch50';

/// The window's left edge, computed exactly as the screen computes it: the
/// previous quarter hour less the fifteen-minute back-slice. Captured once per
/// test so the fixture and the assertions share one origin.
late DateTime _fixtureWindowStart;

int _durationForRow(int row) => _durations[row % _durations.length];

/// The cell boundaries the screen derives for a row, in minutes from the
/// window start. Mirrors `buildRowCells` over a gapless fixture lineup.
int _cellIndexForRow(int row, int minutesFromWindowStart) =>
    minutesFromWindowStart ~/ _durationForRow(row);

int _minutesIntoRowCell(int row, int cellIndex) =>
    cellIndex * _durationForRow(row);

Map<String, dynamic> _channelRaw(int index) => <String, dynamic>{
  'Id': 'ch$index',
  'Name': 'Channel $index',
  'ChannelNumber': '${index + 1}',
  'ImageTags': <String, dynamic>{},
  'UserData': <String, dynamic>{'IsFavorite': false},
};

List<Map<String, dynamic>> _programsFor(String channelId, {bool sports = false}) {
  final row = int.parse(channelId.substring(2));
  final duration = _durationForRow(row);
  final start = _fixtureWindowStart;
  final programs = <Map<String, dynamic>>[];
  // Twelve hours of listings, so whatever window width the surface derives is
  // tiled edge to edge and every row's cells are whole programs.
  for (var minute = 0; minute < 720; minute += duration) {
    programs.add(<String, dynamic>{
      'Id': '$channelId-p$minute',
      'ChannelId': channelId,
      'Name': '$channelId show $minute',
      'IsSports': sports,
      'StartDate': start.add(Duration(minutes: minute)).toIso8601String(),
      'EndDate': start
          .add(Duration(minutes: minute + duration))
          .toIso8601String(),
    });
  }
  return programs;
}

Widget _hosted(Widget guide, {required bool embedded}) =>
    embedded ? Material(color: Colors.black, child: guide) : guide;

/// `AlertDialog.adaptive` builds a private subclass, which `find.byType` will
/// not match, so match the supertype instead.
final Finder _alertDialog = find.byWidgetPredicate((w) => w is AlertDialog);

/// `pumpAndSettle` can't be used once any row is loading. That row's cell
/// draws an indefinite progress indicator, so frames never stop. Pump a fixed
/// span instead, comfortably past the guide's 200 ms row-scroll animation.
Future<void> _pumpFrames(WidgetTester tester) async {
  for (var i = 0; i < 24; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// Send one remote key and let the guide settle its deferred focus frames.
Future<void> _sendKeyAndPump(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await _pumpFrames(tester);
}

/// Drive a real held Select (rather than a tap) through the TV focus path.
Future<void> _holdSelect(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
  await tester.pump(const Duration(milliseconds: 550));
  await _pumpFrames(tester);
  await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
  await _pumpFrames(tester);
}

/// Every focus node in the guide carries a debug label, which is the only
/// handle a test has on the rows' private nodes.
FocusNode _nodeLabelled(WidgetTester tester, String label) => tester
    .widgetList<Focus>(find.byType(Focus))
    .map((focus) => focus.focusNode)
    .whereType<FocusNode>()
    .firstWhere((node) => node.debugLabel == label);

String? _focusedLabel() => FocusManager.instance.primaryFocus?.debugLabel;

String _windowRangeText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((text) => text.data)
    .whereType<String>()
    .firstWhere((text) => text.contains(' – '));

/// `(row, cellIndex)` of the focused program cell, or null when focus is
/// somewhere else in the guide.
({int row, int index})? _focusedCell() {
  final label = _focusedLabel();
  if (label == null || !label.startsWith('GuideProgramRow')) return null;
  final parts = label.substring('GuideProgramRow'.length).split(':');
  return (row: int.parse(parts[0]), index: int.parse(parts[1]));
}

/// The horizontal scroll offsets of every horizontal scrollable in the guide
/// (the grid and the time header, which are kept in sync).
List<double> _horizontalOffsets(WidgetTester tester) => tester
    .stateList<ScrollableState>(find.byType(Scrollable))
    .where(
      (state) =>
          state.position.axis == Axis.horizontal &&
          state.widget.physics is! NeverScrollableScrollPhysics,
    )
    .map((state) => state.position.pixels)
    .toList();

Future<Map<String, dynamic>> _channelsRequest(LiveTvApi api) => api.getChannels(
  startIndex: any(named: 'startIndex'),
  limit: any(named: 'limit'),
  sortBy: any(named: 'sortBy'),
  sortOrder: any(named: 'sortOrder'),
  fields: any(named: 'fields'),
  enableTotalRecordCount: any(named: 'enableTotalRecordCount'),
  userId: any(named: 'userId'),
);

Future<Map<String, dynamic>> _guideRequest(LiveTvApi api) => api.getGuide(
  startDate: any(named: 'startDate'),
  endDate: any(named: 'endDate'),
  channelIds: any(named: 'channelIds'),
  isSports: any(named: 'isSports'),
  fields: any(named: 'fields'),
  enableTotalRecordCount: any(named: 'enableTotalRecordCount'),
  enableImages: any(named: 'enableImages'),
  enableUserData: any(named: 'enableUserData'),
  userId: any(named: 'userId'),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MockMediaServerClient client;
  late _MockLiveTvApi liveTvApi;

  /// Overridable per test so a lineup can outgrow a single program batch.
  late int channelCount;
  Exception? guideFailure;

  /// When set, any guide request covering this channel is held open until the
  /// test releases it, so its row can be observed mid-load.
  String? deferredChannelId;
  late List<VoidCallback> releaseDeferredGuide;

  setUp(() async {
    await GetIt.instance.reset();
    SharedPreferences.setMockInitialValues(const {});
    final store = PreferenceStore();
    await store.init();
    GetIt.instance.registerSingleton<PreferenceStore>(store);
    GetIt.instance.registerSingleton<UserPreferences>(UserPreferences(store));

    await GetIt.instance<UserPreferences>().set(
      UserPreferences.liveTvCategoryDisplay,
      LiveTvCategoryDisplay.programmes,
    );
    channelCount = _channelCount;
    guideFailure = null;
    _fixtureWindowStart = guideLeftEdge(DateTime.now());
    deferredChannelId = null;
    releaseDeferredGuide = <VoidCallback>[];

    final playback = _MockPlaybackManager();
    when(() => playback.backend).thenReturn(null);
    when(() => playback.backendChangedStream)
        .thenAnswer((_) => const Stream<PlayerBackend>.empty());
    GetIt.instance.registerSingleton<PlaybackManager>(playback);

    client = _MockMediaServerClient();
    liveTvApi = _MockLiveTvApi();
    when(() => client.liveTvApi).thenReturn(liveTvApi);
    when(() => client.serverType).thenReturn(ServerType.jellyfin);
    when(() => client.baseUrl).thenReturn('fixture');
    when(() => liveTvApi.getChannelGroups(userId: 'user'))
        .thenAnswer((_) async => const ChannelGroupLineup({}));
    when(() => client.userId).thenReturn('user');

    when(() => _channelsRequest(liveTvApi)).thenAnswer(
      (_) async => <String, dynamic>{
        'Items': [for (var i = 0; i < channelCount; i++) _channelRaw(i)],
      },
    );

    when(() => _guideRequest(liveTvApi)).thenAnswer((invocation) async {
      if (guideFailure case final failure?) throw failure;
      final ids =
          (invocation.namedArguments[#channelIds] as List?)?.cast<String>() ??
          const <String>[];
      final sportsChannel = invocation.namedArguments[#startDate] == _fixtureWindowStart ? 'ch0' : 'ch1';
      final payload = <String, dynamic>{
        'Items': [for (final id in ids) ..._programsFor(id, sports: id == sportsChannel)],
      };
      final gate = deferredChannelId;
      if (gate == null || !ids.contains(gate)) return payload;

      final completer = Completer<Map<String, dynamic>>();
      releaseDeferredGuide.add(() => completer.complete(payload));
      return completer.future;
    });

    GetIt.instance.registerSingleton<MediaServerClient>(client);
  });

  tearDown(() async {
    await GetIt.instance.reset();
  });

  Future<void> pumpGuide(
    WidgetTester tester, {
    bool miniPlayerMode = false,
    bool? embedded,
    GuideChannel? currentChannel,
    GuideFilterChoice initialFilter = (GuideFilter.all, null),
    Size surface = const Size(900, 700),
    List<NavigatorObserver> observers = const [],
    LiveTvGuideBackController? backController,
    DateTime Function()? now,
    Locale? locale,
  }) async {
    final openedAt = (now ?? DateTime.now)();
    _fixtureWindowStart = guideLeftEdge(openedAt);
    // Wide enough for a multi-hour window and tall enough for a dozen rows.
    // The guide sizes its own time density to whatever surface it is given.
    tester.view.physicalSize = surface;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: observers,
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        // Embedded mode drops the guide's own Scaffold because the host
        // supplies it. Stand in for that host here.
        home: _hosted(
          LiveTvGuideScreen(
            now: now ?? () => openedAt,
            miniPlayerMode: miniPlayerMode,
            embedded: embedded ?? miniPlayerMode,
            currentChannel: currentChannel,
            initialFilter: initialFilter,
            onChannelSelected: miniPlayerMode ? (_, _) {} : null,
            onClose: miniPlayerMode ? () {} : null,
            backController: backController,
          ),
          embedded: embedded ?? miniPlayerMode,
        ),
      ),
    );
    // TV labels may keep scrolling, so don't wait for every animation to stop.
    await _pumpFrames(tester);
  }

  Future<void> pumpRoutedGuide(WidgetTester tester, Size size, GoRouter router) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: router,
    ));
    await _pumpFrames(tester);
  }

  void stubGroups(ChannelGroupLineup lineup) =>
      when(() => liveTvApi.getChannelGroups(userId: 'user')).thenAnswer((_) async => lineup);

  void stubFavoriteChannel(int index) {
    final favorite = _channelRaw(index)
      ..['UserData'] = <String, dynamic>{'IsFavorite': true};
    when(() => _channelsRequest(liveTvApi)).thenAnswer(
      (_) async => <String, dynamic>{
        'Items': [
          for (var i = 0; i < channelCount; i++)
            if (i == index) favorite else _channelRaw(i),
        ],
      },
    );
  }

  void useLayout(InterfaceLayout layout) {
    PlatformDetection.setInterfaceLayout(layout);
    addTearDown(
      () => PlatformDetection.setInterfaceLayout(InterfaceLayout.automatic),
    );
  }

  void useTvLayout() => useLayout(InterfaceLayout.tv);

  /// Open the guide through a host route so Back and focus restoration are real.
  Future<void> openGuideRoute(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const LiveTvGuideScreen(),
              ),
            ),
            child: const Text('open guide'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open guide'));
    await tester.pumpAndSettle();
  }

  final picker = find.byType(GuideFilterPicker);
  const phone = Size(390, 844);
  Future<void> tapAndPump(WidgetTester tester, Finder target) async {
    await tester.tap(target);
    await _pumpFrames(tester);
  }
  Finder pickerOption(String name) => find.descendant(of: picker, matching: find.text(name));

  LiveTvGuideViewModel guideModel(WidgetTester tester) =>
      (tester.state(find.byType(LiveTvGuideScreen)) as dynamic).debugGuideViewModel as LiveTvGuideViewModel;

  Future<void> focusGuideNode(WidgetTester tester, String label) async {
    _nodeLabelled(tester, label).requestFocus();
    await _pumpFrames(tester);
  }

  Future<void> expectFocusAfter(WidgetTester tester, LogicalKeyboardKey key, String label) async {
    await _sendKeyAndPump(tester, key);
    expect(_focusedLabel(), label);
  }

  testWidgets('replacing filter nodes restores focus to the selected chip', (tester) async {
    useTvLayout();
    const labels = ['All', 'Favorites', 'Sports', 'News'];
    List<FocusNode> makeNodes() => [for (final label in labels) FocusNode(debugLabel: label)];
    final original = makeNodes();
    final replacement = makeNodes();
    addTearDown(() {
      for (final node in [...original, ...replacement]) {
        node.dispose();
      }
    });
    Future<void> show(List<FocusNode> nodes) async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(
        width: 160,
        child: EpgFilterRail(
          labels: labels, selectedIndex: 2, onSelect: (_) {}, apple: false,
          focusNodeFor: (index) => nodes[index],
        ),
      ))));
      await _pumpFrames(tester);
    }
    await show(original);
    original.first.requestFocus();
    await _pumpFrames(tester);
    expect(original.first.hasFocus, isTrue);
    await show(replacement);
    expect(replacement[2].hasFocus, isTrue);
  });

  testWidgets('Favorites stays in view when categories move its focused chip', (tester) async {
    useTvLayout();
    final nodes = <String, FocusNode>{};
    addTearDown(() {
      for (final node in nodes.values) {
        node.dispose();
      }
    });
    Future<void> show(List<String> labels) async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(
        width: 160,
        child: EpgFilterRail(
          labels: labels, selectedIndex: 0, onSelect: (_) {}, apple: false,
          focusNodeFor: (i) => nodes.putIfAbsent(labels[i], () => FocusNode(debugLabel: labels[i])),
        ),
      ))));
      await tester.pumpAndSettle();
    }

    await show(['All', 'Favorites']);
    nodes['Favorites']!.requestFocus();
    await tester.pumpAndSettle();
    await show(['All', 'Movies', 'Series', 'Sports', 'News', 'Kids', 'Premiere', 'Favorites']);
    expect(nodes['Favorites']!.hasPrimaryFocus, isTrue);
    expect(find.text('Favorites').hitTestable(), findsOneWidget);
  });

  testWidgets('TV guide error Retry is reachable from the window bar', (
    tester,
  ) async {
    useTvLayout();
    guideFailure = Exception('Guide unavailable');
    await openGuideRoute(tester);
    expect(find.text('Retry'), findsOneWidget);
    await focusGuideNode(tester, 'GuideWindowBar:0');
    await expectFocusAfter(tester, LogicalKeyboardKey.arrowDown, 'GuideErrorRetry');
    await expectFocusAfter(tester, LogicalKeyboardKey.arrowUp, 'GuideWindowBar:0');
    await expectFocusAfter(tester, LogicalKeyboardKey.arrowDown, 'GuideErrorRetry');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('open guide'), findsOneWidget);
  });

  // A wider guide needs more time slots than the 900-point fixture.
  Duration resizedGuideWindow(Size size) {
    final area = guideAvailableArea(
      maxWidth: size.width,
      maxHeight: size.height,
      landscape: true,
      miniPlayerMode: false,
    );
    return GuideLayoutProfile.fromAvailableArea(
      availableWidth: area.width,
      availableHeight: area.height,
    ).guideWindow;
  }

  for (final hour in [12, 23]) {
    testWidgets('Right retries a failed page from $hour:45 without moving remote focus', (tester) async {
      useTvLayout();
      await pumpGuide(tester);
      final today = DateTime.now();
      _fixtureWindowStart = DateTime(today.year, today.month, today.day + 1, hour, 45);
      await guideModel(tester).setWindowStart(_fixtureWindowStart);
      await _pumpFrames(tester);

      // Row 4 has one program spanning the visible window.
      final cell = _nodeLabelled(tester, 'GuideProgramRow4:0');
      cell.requestFocus();
      await _pumpFrames(tester);
      final range = _windowRangeText(tester);
      final target = _fixtureWindowStart.add(const Duration(minutes: 30));
      final context = tester.element(find.byType(LiveTvGuideScreen));
      final label = DateUtils.isSameDay(target, _fixtureWindowStart)
          ? formatClockTime(target, use24Hour: GetIt.instance<UserPreferences>().get(UserPreferences.use24HourClock))
          : MaterialLocalizations.of(context).formatMediumDate(target);
      final notice = find.text(AppLocalizations.of(context).guideWindowLoadFailed(label));

      guideFailure = Exception('offline');
      await _sendKeyAndPump(tester, LogicalKeyboardKey.arrowRight);
      expect(_windowRangeText(tester), range);
      expect(FocusManager.instance.primaryFocus, same(cell));
      expect(notice, findsOneWidget);

      guideFailure = null;
      await _sendKeyAndPump(tester, LogicalKeyboardKey.arrowRight);
      expect(_windowRangeText(tester), isNot(range));
      expect(guideModel(tester).windowStart, target);
      expect(notice, findsNothing);
    });
  }

  testWidgets('paging back at the history limit cancels an unfinished forward page', (tester) async {
    useTvLayout();
    final now = DateTime(2026, 9, 11, 10, 10);
    await pumpGuide(tester, now: () => now);
    final vm = guideModel(tester);
    final floor = guideLeftEdge(now).subtract(const Duration(hours: 24));
    await vm.setWindowStart(floor);
    await _pumpFrames(tester);
    deferredChannelId = 'ch0';
    await tapAndPump(tester, find.byIcon(Icons.chevron_right).first);
    expect(vm.pendingWindowStart, floor.add(vm.guideWindow));
    await tapAndPump(tester, find.byIcon(Icons.chevron_left).first);
    releaseDeferredGuide.single();
    await _pumpFrames(tester);
    expect(vm.windowStart, floor);
  });

  testWidgets('a superseded page cannot overwrite the newer failure notice', (tester) async {
    useTvLayout();
    channelCount = 8;
    await pumpGuide(tester);
    final vm = guideModel(tester);
    final today = DateTime.now();
    _fixtureWindowStart = DateTime(today.year, today.month, today.day + 1, 10);
    await vm.setWindowStart(_fixtureWindowStart);
    await _pumpFrames(tester);

    deferredChannelId = 'ch0';
    await tapAndPump(tester, find.byIcon(Icons.chevron_right).first);
    expect(vm.pendingWindowStart, _fixtureWindowStart.add(vm.guideWindow));
    expect(releaseDeferredGuide, hasLength(1));

    // Right at the row edge requests 10:30 while the full-page move is pending.
    guideFailure = TimeoutException('offline');
    await focusGuideNode(tester, 'GuideProgramRow4:0');
    await _sendKeyAndPump(tester, LogicalKeyboardKey.arrowRight);
    final notice = find.textContaining('Couldn’t load');
    final message = tester.widget<Text>(notice).data!;
    expect(message, contains('10:30'));
    releaseDeferredGuide.single();
    await _pumpFrames(tester);
    expect(tester.widget<Text>(notice).data, message);
    expect(vm.windowStart, _fixtureWindowStart);
  });

  for (final timing in ['before', 'after']) {
    testWidgets('paging uses the original width when restored $timing a resize failure', (tester) async {
      await pumpGuide(tester);
      final vm = guideModel(tester);
      final size = tester.view.physicalSize;
      final window = vm.guideWindow;
      final start = vm.windowStart;
      final resize = Completer<Map<String, dynamic>>();
      final resizeWidths = <Duration>[];
      when(() => _guideRequest(liveTvApi)).thenAnswer((call) {
        final from = call.namedArguments[#startDate] as DateTime;
        final to = call.namedArguments[#endDate] as DateTime;
        resizeWidths.add(to.difference(from));
        return resize.future;
      });
      tester.view.physicalSize = const Size(1700, 700);
      await _pumpFrames(tester);
      expect(resizeWidths, contains(greaterThan(window)));
      if (timing == 'before') {
        tester.view.physicalSize = size;
        await _pumpFrames(tester);
      }
      resize.completeError(Exception('resize failed'));
      await _pumpFrames(tester);
      tester.view.physicalSize = size;
      await _pumpFrames(tester);
      expect(vm.guideWindow, window);

      final pageRequests = <(DateTime, DateTime)>{};
      when(() => _guideRequest(liveTvApi)).thenAnswer((call) async {
        pageRequests.add((
          call.namedArguments[#startDate] as DateTime,
          call.namedArguments[#endDate] as DateTime,
        ));
        return {'Items': []};
      });
      await tester.tap(find.byIcon(Icons.chevron_right).first);
      await _pumpFrames(tester);
      final nextStart = start.add(window);
      expect(pageRequests, {(nextStart, nextStart.add(window))});
      expect(vm.windowStart, nextStart);
      expect(vm.guideWindow, window);
    });
  }

  testWidgets('choosing a date shows a notice when listings access is denied', (tester) async {
    final request = RequestOptions();
    when(() => _guideRequest(liveTvApi)).thenThrow(DioException(
      requestOptions: request,
      response: Response(requestOptions: request, statusCode: 403),
    ));
    await pumpGuide(tester, surface: phone);
    final vm = guideModel(tester);
    expect(vm.listingsAccessDenied, isTrue);
    expect(vm.filteredChannels, isNotEmpty);
    final start = vm.guideDate;
    final target = DateUtils.addDaysToDate(start, start.day == 1 ? 1 : -1);
    await tapAndPump(tester, find.byIcon(Icons.calendar_today));
    final calendar = find.byType(CalendarDatePicker);
    await tapAndPump(tester, find.descendant(of: calendar, matching: find.text('${target.day}')));
    await tapAndPump(tester, find.text('OK'));
    expect(vm.guideDate, start);
    expect(find.textContaining(' ${target.day} listings.'), findsOneWidget);
  });

  testWidgets('Now/Next shows the listings denial reason alongside tunable channels', (tester) async {
    useLayout(InterfaceLayout.phone);
    await GetIt.instance<UserPreferences>().set(UserPreferences.epgMobileView, EpgMobileView.list);
    final request = RequestOptions();
    const reason = 'Programme listings are restricted for this viewer';
    when(() => _guideRequest(liveTvApi)).thenThrow(DioException(
      requestOptions: request,
      response: Response(requestOptions: request, statusCode: 403, data: {'message': reason}),
    ));
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, _) => const LiveTvGuideScreen()),
      GoRoute(path: Destinations.liveTvPlayer, builder: (_, state) {
        final extra = state.extra as Map;
        final channels = extra['channels'] as List<GuideChannel>;
        return Text('Playing ${channels[extra['startIndex'] as int].id}');
      }),
    ]);
    await pumpRoutedGuide(tester, phone, router);
    expect(find.textContaining(reason), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
    await tapAndPump(tester, find.text('Channel 0'));
    expect(find.text('Playing ch0'), findsOneWidget);
  });

  testWidgets('the TV grid explains missing listings and keeps the station selectable', (tester) async {
    useTvLayout();
    const reason = 'Programme listings are restricted for this viewer';
    final request = RequestOptions();
    when(() => _guideRequest(liveTvApi)).thenThrow(DioException(
      requestOptions: request,
      response: Response(requestOptions: request, statusCode: 403, data: {'message': reason}),
    ));
    await pumpGuide(tester);
    expect(find.textContaining(reason), findsOneWidget);
    expect(find.descendant(of: find.byType(EpgProgramCell), matching: find.byIcon(Icons.refresh)), findsNothing);
    await focusGuideNode(tester, 'GuideChannel:0');
    expect(_focusedLabel(), 'GuideChannel:0');
  });

  testWidgets('a failed same-day picker request names the selected date', (tester) async {
    final now = DateTime(2026, 9, 11, 10, 30);
    await pumpGuide(tester, surface: phone, now: () => now);
    final vm = guideModel(tester);
    final today = vm.guideDate;
    final start = DateTime(today.year, today.month, today.day, 10, 30);
    await vm.setWindowStart(start);
    await _pumpFrames(tester);
    guideFailure = TimeoutException('Listings unavailable');
    await tapAndPump(tester, find.byIcon(Icons.calendar_today));
    expect(tester.widget<CalendarDatePicker>(find.byType(CalendarDatePicker)).currentDate,
        DateUtils.dateOnly(now));
    await tapAndPump(tester, find.text('OK'));

    final context = tester.element(find.byType(LiveTvGuideScreen));
    final date = MaterialLocalizations.of(context).formatMediumDate(start);
    expect(find.text(AppLocalizations.of(context).guideWindowLoadFailed(date)), findsOneWidget);
    expect(vm.windowStart, start);
  });

  testWidgets('the grid marks the program airing at the Guide time as live', (tester) async {
    final now = DateTime(2026, 9, 11, 10, 10);
    await pumpGuide(tester, now: () => now);
    final cell = tester.widgetList<EpgProgramCell>(find.byType(EpgProgramCell))
        .firstWhere((cell) => cell.title == 'ch0 show 0');
    expect(cell.isLive, isTrue);
    expect(cell.isPast, isFalse);
  });

  for (final reloadDuringRequest in [false, true]) {
    testWidgets('a guide reload during resize finishes at the visible width (request pending=$reloadDuringRequest)', (tester) async {
      await pumpGuide(tester);
      final vm = guideModel(tester);
      final original = vm.guideWindow;
      const wider = Size(1700, 700);
      final expected = resizedGuideWindow(wider);
      expect(expected, isNot(original));
      if (reloadDuringRequest) {
        final held = Completer<Map<String, dynamic>>();
        var waiting = false;
        when(() => _guideRequest(liveTvApi)).thenAnswer((inv) async {
          final from = inv.namedArguments[#startDate] as DateTime;
          final to = inv.namedArguments[#endDate] as DateTime;
          if (!waiting && to.difference(from) == expected) {
            waiting = true;
            return held.future;
          }
          final ids = (inv.namedArguments[#channelIds] as List).cast<String>();
          return {'Items': [for (final id in ids) ..._programsFor(id)]};
        });
        tester.view.physicalSize = wider;
        await _pumpFrames(tester);
        expect(waiting, isTrue);
        await vm.load(window: original, windowStart: vm.windowStart);
        expect(vm.guideWindow, original);
        held.complete({'Items': []});
      } else {
        final channels = Completer<Map<String, dynamic>>();
        when(() => _channelsRequest(liveTvApi)).thenAnswer((_) => channels.future);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          unawaited(vm.load(window: original, windowStart: vm.windowStart));
        });
        tester.view.physicalSize = wider;
        await tester.pump();
        expect(vm.state, GuideState.loading);
        channels.complete({'Items': [for (var i = 0; i < channelCount; i++) _channelRaw(i)]});
      }
      await _pumpFrames(tester);
      expect(vm.state, GuideState.ready);
      expect(vm.guideWindow, expected);
    });
  }

  for (final (layout, moveFocus) in [
    (InterfaceLayout.tv, false),
    (InterfaceLayout.tv, true),
    (InterfaceLayout.phone, false),
  ]) {
    testWidgets('empty and partly loaded categories can retry on ${layout.name} (move focus: $moveFocus)', (
      tester,
    ) async {
      PlatformDetection.setInterfaceLayout(layout);
      addTearDown(
        () => PlatformDetection.setInterfaceLayout(InterfaceLayout.automatic),
      );
      channelCount = 2;
      final failed = {'ch0', 'ch1'};
      Completer<void>? retry;
      stubGroups(const ChannelGroupLineup(
          {},
          programmeCategories: {'sports'},
        ));
      when(() => _guideRequest(liveTvApi)).thenAnswer((inv) async {
        final ids =
            (inv.namedArguments[#channelIds] as List?)?.cast<String>() ??
            const <String>[];
        if (inv.namedArguments[#isSports] != true) {
          return {'Items': [for (final id in ids) ..._programsFor(id)]};
        }
        if (retry != null) await retry.future;
        return {
          'Items': [for (final id in ids.where((id) => !failed.contains(id)))
            ..._programsFor(id, sports: true)],
          'FailedChannelIds': ids.where(failed.contains).toList(),
        };
      });

      await pumpGuide(
        tester,
        surface: layout == InterfaceLayout.phone
            ? const Size(390, 844)
            : const Size(900, 700),
      );
      final vm = guideModel(tester);
      vm.setFilter(GuideFilter.sports);
      await _pumpFrames(tester);
      expect(vm.hasFailedCategoryListings, isTrue);
      expect(find.text('Failed to load'), findsOneWidget);
      expect(find.text('No channels found'), findsNothing);
      if (layout == InterfaceLayout.tv) {
        await focusGuideNode(tester, 'GuideWindowBar:0');
        await expectFocusAfter(tester, LogicalKeyboardKey.arrowDown, 'GuideCategoryRetry');
        await expectFocusAfter(tester, LogicalKeyboardKey.arrowUp, 'GuideWindowBar:0');
      }

      failed.remove('ch1');
      await tester.tap(find.text('Retry'));
      await _pumpFrames(tester);
      expect(vm.filteredChannels.map((c) => c.id), ['ch1']);
      final partialRetry = find.text('Some listings failed to load. Retry');
      expect(partialRetry, findsOneWidget);
      if (layout == InterfaceLayout.tv) {
        await focusGuideNode(tester, 'GuideWindowBar:0');
        await expectFocusAfter(tester, LogicalKeyboardKey.arrowDown, 'GuideCategoryRetry');
        await expectFocusAfter(tester, LogicalKeyboardKey.arrowDown, 'GuideChannel:0');
        await expectFocusAfter(tester, LogicalKeyboardKey.arrowUp, 'GuideCategoryRetry');
      }
      failed.clear();
      if (layout == InterfaceLayout.tv) {
        retry = Completer<void>();
        await _sendKeyAndPump(tester, LogicalKeyboardKey.select);
        expect(vm.retryingCategoryListings, isTrue);
        expect(_focusedLabel(), 'GuideCategoryRetry');
        if (moveFocus) {
          await expectFocusAfter(tester, LogicalKeyboardKey.arrowUp, 'GuideWindowBar:0');
        }
        retry.complete();
      } else {
        await tester.tap(partialRetry);
      }
      await _pumpFrames(tester);
      expect(vm.hasFailedCategoryListings, isFalse);
      expect(vm.filteredChannels.map((c) => c.id), ['ch0', 'ch1']);
      if (layout == InterfaceLayout.tv) {
        expect(_focusedLabel(), moveFocus ? 'GuideWindowBar:0' : 'GuideChannel:0');
      }
      expect(partialRetry, findsNothing);
      expect(find.text('Failed to load'), findsNothing);
    });
  }

  testWidgets('category Retry retains focus when paging completes', (tester) async {
    useTvLayout();
    channelCount = 2;
    final issued = Completer<void>(), release = Completer<void>();
    var hold = false;
    when(() => _guideRequest(liveTvApi)).thenAnswer((inv) async {
      final ids = (inv.namedArguments[#channelIds] as List).cast<String>();
      final category = inv.namedArguments[#isSports] == true;
      if (hold && category) {
        if (!issued.isCompleted) issued.complete();
        await release.future;
      }
      return {
        'Items': [
          for (final id in ids)
            if (!category || id == 'ch0') ..._programsFor(id, sports: true),
        ],
        if (category && ids.contains('ch1')) 'FailedChannelIds': ['ch1'],
      };
    });
    await pumpGuide(tester);
    final vm = guideModel(tester)..setFilter(GuideFilter.sports);
    await _pumpFrames(tester);
    expect(vm.hasFailedCategoryListings, isTrue);
    final last = _cellIndexForRow(0, vm.guideWindow.inMinutes - 1);
    final nextStart = vm.windowStart.add(const Duration(minutes: 30));
    await focusGuideNode(tester, 'GuideProgramRow0:$last');
    hold = true;
    await _sendKeyAndPump(tester, LogicalKeyboardKey.arrowRight);
    expect(issued.isCompleted, isTrue);
    await focusGuideNode(tester, 'GuideCategoryRetry');
    expect(_focusedLabel(), 'GuideCategoryRetry');
    release.complete();
    await _pumpFrames(tester);
    expect(vm.windowStart, nextStart);
    expect(vm.hasFailedCategoryListings, isTrue);
    expect(_focusedLabel(), 'GuideCategoryRetry');
  });

  testWidgets('a searched channel keeps its group when the playback guide opens', (
    tester,
  ) async {
    useTvLayout();
    await GetIt.instance<UserPreferences>().set(
      UserPreferences.liveTvCategoryDisplay,
      LiveTvCategoryDisplay.both,
    );
    stubGroups(const ChannelGroupLineup({
        'ch1': {'Local'},
        'ch46': {'Local'},
        'ch47': {'Local'},
      }));
    late List<GuideChannel> lineup;
    String? picked;
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const LiveTvGuideScreen()),
        GoRoute(
          path: Destinations.liveTvPlayer,
          builder: (_, s) {
            lineup = (s.extra as Map)['channels'] as List<GuideChannel>;
            final current = lineup[(s.extra as Map)['startIndex'] as int];
            expect(current.id, 'ch47');
            return Material(
              child: LiveTvGuideScreen(
                miniPlayerMode: true,
                embedded: true,
                currentChannel: current,
                initialFilter:
                    (s.extra as Map)['guideFilter'] as GuideFilterChoice,
                onChannelSelected: (id, currentLineup) {
                  expect(currentLineup.filter, (GuideFilter.all, 'Local'));
                  expect(currentLineup.channels.map((c) => c.id), [
                    'ch1', 'ch46', 'ch47',
                  ]);
                  picked = id;
                },
                onClose: () {},
              ),
            );
          },
        ),
      ],
    );
    await pumpRoutedGuide(tester, const Size(900, 700), router);
    await tapAndPump(tester, find.byTooltip('Filters'));
    await tapAndPump(tester, pickerOption('Local'));
    // The TV field's internal TextField is read-only outside its keyboard.
    // The TV keyboard commits text through the LocalSearchField controller.
    tester.widget<LocalSearchField>(
      find.byType(LocalSearchField),
    ).controller.text = 'Channel 47';
    await _pumpFrames(tester);
    expect(
      tester.widgetList<EpgChannelCell>(find.byType(EpgChannelCell))
          .map((channel) => channel.name),
      ['Channel 47'],
    );
    await focusGuideNode(tester, 'GuideChannel:0');
    await _sendKeyAndPump(tester, LogicalKeyboardKey.enter);
    expect(lineup.map((channel) => channel.id), ['ch1', 'ch46', 'ch47']);
    final playbackGuide = find.byWidgetPredicate(
      (widget) => widget is LiveTvGuideScreen && widget.miniPlayerMode,
    );
    expect(
      tester.widgetList<EpgChannelCell>(
        find.descendant(of: playbackGuide, matching: find.byType(EpgChannelCell)),
      ).map((channel) => channel.name),
      ['Channel 1', 'Channel 46', 'Channel 47'],
    );
    expect(_focusedLabel(), 'GuideChannel:2');
    expect(picked, isNull);
    await tapAndPump(tester, find.byWidgetPredicate((w) => w is EpgChannelCell && w.name == 'Channel 46'));
    expect(picked, 'ch46');
  });

  for (final layout in [InterfaceLayout.phone, InterfaceLayout.tv]) {
    testWidgets('the ${layout.name} playback guide reopens in Sports', (
      tester,
    ) async {
      PlatformDetection.setInterfaceLayout(layout);
      addTearDown(
        () => PlatformDetection.setInterfaceLayout(InterfaceLayout.automatic),
      );
      channelCount = 4;
      stubGroups(const ChannelGroupLineup({
        'ch1': {'Sports'},
        'ch2': {'Sports'},
        'ch3': {'News'},
      }));
      await GetIt.instance<UserPreferences>().set(
        UserPreferences.liveTvCategoryDisplay,
        LiveTvCategoryDisplay.both,
      );
      await pumpGuide(
        tester,
        miniPlayerMode: true,
        embedded: layout == InterfaceLayout.phone,
        currentChannel: GuideChannel.fromRawItem(_channelRaw(2)),
        initialFilter: (GuideFilter.all, 'Sports'),
        surface: layout == InterfaceLayout.phone
            ? const Size(900, 430)
            : const Size(960, 640),
      );
      final vm = guideModel(tester);
      expect(vm.selectedGroup, 'Sports');
      expect(vm.filteredChannels.map((c) => c.id), ['ch1', 'ch2']);
      expect(_focusedLabel(), 'GuideChannel:1');
    });
  }

  testWidgets('Select on a guide card Retry requests the failed listings', (tester) async {
    channelCount = 2;
    final prefs = GetIt.instance<UserPreferences>();
    await prefs.set(UserPreferences.epgMobileView, EpgMobileView.list);
    final requests = <List<String>>[];
    when(() => _guideRequest(liveTvApi)).thenAnswer((inv) async {
      final ids = (inv.namedArguments[#channelIds] as List).cast<String>();
      requests.add(ids);
      if (ids.length == 1) return {'Items': _programsFor(ids.single)};
      return {'Items': _programsFor('ch1'), 'FailedChannelIds': ['ch0']};
    });
    await pumpGuide(tester, surface: phone);
    final retry = find.descendant(of: find.byType(EpgNowNextCard), matching: find.text('Retry'));
    final node = Focus.of(tester.element(retry));
    node.requestFocus();
    await _pumpFrames(tester);
    expect(node.hasPrimaryFocus, isTrue);
    requests.clear();
    await _sendKeyAndPump(tester, LogicalKeyboardKey.select);
    expect(requests, [['ch0']]);
    expect(retry, findsNothing);
  });

  testWidgets('Now/Next keeps the focused station through two lineup changes', (tester) async {
    channelCount = 140;
    await GetIt.instance<UserPreferences>().set(UserPreferences.epgMobileView, EpgMobileView.list);
    await pumpGuide(tester, surface: phone);
    final vm = guideModel(tester);
    vm.setChannelQuery('Channel 2');
    await _pumpFrames(tester);
    expect(vm.filteredChannels.first.id, 'ch2');
    await focusGuideNode(tester, 'GuideChannel:0');

    vm.setChannelQuery('');
    await tester.pump(); // Reveal the station in number order before focus is restored.
    expect(vm.filteredChannels[2].id, 'ch2');
    vm.setSortBy(ChannelSortBy.name);
    final index = vm.filteredChannels.indexWhere((c) => c.id == 'ch2');
    expect(index, greaterThan(20));
    await _pumpFrames(tester);
    expect(_focusedLabel(), 'GuideChannel:$index');
    expect(find.text('Channel 2').hitTestable(), findsOneWidget);
  });

  for (final style in [KeyboardStyle.native, KeyboardStyle.docked]) {
    testWidgets('TV channel search keeps its ${style.name} keyboard open when groups arrive', (tester) async {
      useTvLayout();
      final prefs = GetIt.instance<UserPreferences>();
      await prefs.set(UserPreferences.keyboardStyle, style);
      await prefs.set(UserPreferences.liveTvCategoryDisplay, LiveTvCategoryDisplay.both);
      final groups = Completer<ChannelGroupLineup>();
      when(() => liveTvApi.getChannelGroups(userId: 'user')).thenAnswer((_) => groups.future);
      await pumpGuide(tester);
      await focusGuideNode(tester, 'GuideSearch');
      await _sendKeyAndPump(tester, LogicalKeyboardKey.select);
      final controller = tester.widget<LocalSearchField>(find.byType(LocalSearchField)).controller;

      if (style == KeyboardStyle.native) {
        tester.testTextInput.enterText('4');
      } else {
        await tester.sendKeyEvent(LogicalKeyboardKey.digit4, character: '4');
      }
      expect(controller.text, '4');
      groups.complete(const ChannelGroupLineup({'ch1': {'Sports'}}));
      await _pumpFrames(tester);
      expect(guideModel(tester).availableGroups, contains('Sports'));
      expect(CustomTVTextField.isKeyboardVisibleNotifier.value, isTrue);
      expect(controller.text, '4');

      if (style == KeyboardStyle.native) {
        tester.testTextInput.enterText('47');
      } else {
        await tester.sendKeyEvent(LogicalKeyboardKey.digit7, character: '7');
      }
      await _pumpFrames(tester);
      expect(guideModel(tester).filteredChannels.map((c) => c.id), unorderedEquals(['ch46', 'ch47']));
    });
  }

  testWidgets('channel search fits a narrow desktop guide', (tester) async {
    PlatformDetection.setInterfaceLayout(InterfaceLayout.desktop);
    addTearDown(() => PlatformDetection.setInterfaceLayout(InterfaceLayout.automatic));
    await pumpGuide(tester, surface: const Size(240, 600));
    final search = find.byType(TextField);
    await tester.enterText(search, 'Channel 5');
    await _pumpFrames(tester);
    expect(guideModel(tester).filteredChannels.first.name, 'Channel 5');
    expect(tester.takeException(), isNull);
  });

  testWidgets('mobile filter picker changes the visible channel group', (
    tester,
  ) async {
    final prefs = GetIt.instance<UserPreferences>();
    await prefs.set(
      UserPreferences.liveTvCategoryDisplay,
      LiveTvCategoryDisplay.both,
    );
    await prefs.set(UserPreferences.epgMobileView, EpgMobileView.list);
    stubGroups(const ChannelGroupLineup({
        'ch1': {'Sports'},
        'ch47': {'US | PRIME'},
      }));
    await pumpGuide(tester, surface: phone);
    await tester.enterText(find.byType(TextField), 'Channel 4');
    await tester.pump(const Duration(milliseconds: 220));
    await _pumpFrames(tester);
    expect(guideModel(tester).filteredChannels.map((c) => c.id),
        unorderedEquals(['ch4', for (var i = 40; i <= 47; i++) 'ch$i']));

    await tapAndPump(tester, find.byTooltip('Filters'));
    expect(picker, findsOneWidget);
    expect(tester.getSize(picker).width, 390);
    Navigator.of(tester.element(picker)).pop();
    await _pumpFrames(tester);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
    expect(guideModel(tester).filteredChannels.length, channelCount);
    await tapAndPump(tester, find.byTooltip('Filters'));
    await tapAndPump(tester, pickerOption('US | PRIME'));
    expect(picker, findsNothing);
    expect(find.text('Channel 47'), findsOneWidget);
  });

  testWidgets('closing Browse restores the offscreen Now/Next station', (tester) async {
    useLayout(InterfaceLayout.phone);
    final prefs = GetIt.instance<UserPreferences>();
    await prefs.set(UserPreferences.liveTvCategoryDisplay, LiveTvCategoryDisplay.both);
    await prefs.set(UserPreferences.epgMobileView, EpgMobileView.list);
    stubGroups(const ChannelGroupLineup({'ch47': {'Local'}}));
    await pumpGuide(tester, surface: phone);
    await tester.enterText(find.byType(TextField), 'Channel 47');
    await tester.pump(const Duration(milliseconds: 250));
    await _pumpFrames(tester);
    await focusGuideNode(tester, 'GuideChannel:0');
    final cardName = find.descendant(of: find.byType(EpgNowNextCard), matching: find.text('Channel 47')).hitTestable();
    expect(cardName, findsOneWidget);
    await tapAndPump(tester, find.byTooltip('Filters'));
    Navigator.of(tester.element(picker)).pop();
    await _pumpFrames(tester);
    expect(cardName, findsOneWidget);
    expect(_focusedLabel(), 'GuideChannel:47');
  });

  testWidgets('swiping a short Sports list after closing Browse loads more stations', (tester) async {
    useLayout(InterfaceLayout.phone);
    final prefs = GetIt.instance<UserPreferences>();
    await prefs.set(UserPreferences.liveTvCategoryDisplay, LiveTvCategoryDisplay.both);
    await prefs.set(UserPreferences.epgMobileView, EpgMobileView.list);
    channelCount = 1001;
    stubGroups(const ChannelGroupLineup({'ch0': {'Local'}}, programmeCategories: {'sports'}));
    final pending = Completer<void>();
    when(() => _guideRequest(liveTvApi)).thenAnswer((inv) async {
      final ids = (inv.namedArguments[#channelIds] as List).cast<String>();
      if (inv.namedArguments[#isSports] != true) return {'Items': []};
      if (ids.contains('ch400')) await pending.future;
      if (ids.contains('ch200') || ids.contains('ch400')) throw TimeoutException('listings');
      return {'Items': [
        for (final id in ['ch0', 'ch800'])
          if (ids.contains(id)) ..._programsFor(id, sports: true),
      ]};
    });
    await pumpGuide(tester, surface: phone);
    final vm = guideModel(tester);
    vm.setFilter(GuideFilter.sports);
    await _pumpFrames(tester);
    await focusGuideNode(tester, 'GuideChannel:0');
    await tapAndPump(tester, find.byTooltip('Filters'));
    Navigator.of(tester.element(picker)).pop();
    await _pumpFrames(tester);
    pending.complete();
    await _pumpFrames(tester);
    expect(vm.filteredChannels.map((c) => c.id), ['ch0']);
    expect(vm.hasMorePrograms, isTrue);
    await tester.drag(find.byType(EpgNowNextCard).first, const Offset(0, -120));
    await _pumpFrames(tester);
    expect(vm.filteredChannels.map((c) => c.id), contains('ch800'));
  });

  testWidgets('closing Browse restores the card selected after a lineup change', (tester) async {
    useLayout(InterfaceLayout.phone);
    final prefs = GetIt.instance<UserPreferences>();
    await prefs.set(UserPreferences.liveTvCategoryDisplay, LiveTvCategoryDisplay.both);
    await prefs.set(UserPreferences.epgMobileView, EpgMobileView.list);
    stubGroups(const ChannelGroupLineup({'ch3': {'Local'}}));
    await pumpGuide(tester, surface: phone);
    final vm = guideModel(tester);
    vm.setChannelQuery('Channel 2');
    await _pumpFrames(tester);
    await focusGuideNode(tester, 'GuideChannel:0');
    vm.setChannelQuery('');
    await _pumpFrames(tester);
    expect(_focusedLabel(), 'GuideChannel:2');
    await focusGuideNode(tester, 'GuideChannel:3');
    await tapAndPump(tester, find.byTooltip('Filters'));
    Navigator.of(tester.element(picker)).pop();
    await _pumpFrames(tester);
    expect(_focusedLabel(), 'GuideChannel:3');
  });

  for (final afterFirstFrame in [false, true]) {
    testWidgets('Shift-Tab keeps header focus while rows move (after first frame: $afterFirstFrame)', (tester) async {
      useTvLayout();
      userDataSync.reset();
      addTearDown(userDataSync.reset);
      stubFavoriteChannel(5);
      await openGuideRoute(tester);
      final vm = guideModel(tester);
      vm.setFilter(GuideFilter.favorites);
      await _pumpFrames(tester);
      await focusGuideNode(tester, 'GuideChannel:0');
      userDataSync.publish(channelFavoriteKey(vm.channelForId('ch1')!.rawData)!, {'IsFavorite': true});
      if (afterFirstFrame) await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.idle();
      final header = FocusManager.instance.primaryFocus;
      expect(header?.debugLabel, startsWith('GuideWindowBar:'));
      await _pumpFrames(tester);
      expect(FocusManager.instance.primaryFocus, same(header));
    });
  }

  testWidgets('leaving a channel cancels a held Select even after focus returns', (tester) async {
    useTvLayout();
    userDataSync.reset();
    addTearDown(userDataSync.reset);
    final prefs = GetIt.instance<UserPreferences>();
    final api = _MockUserLibrary();
    when(() => client.userLibraryApi).thenReturn(api);
    when(() => api.markFavorite('ch0')).thenAnswer((_) async {});
    await pumpGuide(tester);
    await focusGuideNode(tester, 'GuideChannel:0');
    await prefs.set(UserPreferences.liveTvLastChannelId, 'ch4');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump(const Duration(milliseconds: 32));
    expect(_focusedLabel(), 'GuideChannel:1');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump(const Duration(milliseconds: 32));
    expect(_focusedLabel(), 'GuideChannel:0');
    await tester.pump(const Duration(milliseconds: 550));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await _pumpFrames(tester);
    verifyNever(() => api.markFavorite('ch0'));
    expect(prefs.get(UserPreferences.liveTvLastChannelId), 'ch4');
    expect(_alertDialog, findsNothing);
  });

  testWidgets('picker shows the first matches after a search with no results', (tester) async {
    await GetIt.instance<UserPreferences>().set(
      UserPreferences.liveTvCategoryDisplay,
      LiveTvCategoryDisplay.groups,
    );
    stubGroups(ChannelGroupLineup({
      'ch0': {for (var i = 10; i < 60; i++) 'Group $i'},
    }));
    await pumpGuide(tester, surface: phone, initialFilter: (GuideFilter.all, 'Group 45'));
    await tapAndPump(tester, find.byTooltip('Filters'));
    expect(pickerOption('Group 45').hitTestable(), findsOneWidget);
    expect(pickerOption('Group 10').hitTestable(), findsNothing);

    final field = find.descendant(of: picker, matching: find.byType(TextField));
    await tester.enterText(field, 'no such group');
    await _pumpFrames(tester);
    expect(pickerOption('No results'), findsOneWidget);
    await tester.enterText(field, 'group');
    await _pumpFrames(tester);
    expect(pickerOption('Group 10').hitTestable(), findsOneWidget);
  });

  testWidgets('TV picker selects with OK and closes with Right or Android Back', (
    tester,
  ) async {
    useTvLayout();
    channelCount = 3;
    final observer = _DialogBackObserver();
    tester.binding.addObserver(observer);
    addTearDown(() => tester.binding.removeObserver(observer));
    addTearDown(DialogBackSuppressor.newBackPress);
    await GetIt.instance<UserPreferences>().set(
      UserPreferences.liveTvCategoryDisplay,
      LiveTvCategoryDisplay.groups,
    );
    stubGroups(const ChannelGroupLineup({'ch1': {'Sports'}, 'ch2': {'Sports'}}));
    await openGuideRoute(tester);
    await focusGuideNode(tester, 'GuideChannel:0');
    await _sendKeyAndPump(tester, LogicalKeyboardKey.arrowLeft);
    expect(picker, findsOneWidget);
    tester.widget<ListTile>(
      find.widgetWithText(ListTile, 'Sports'),
    ).focusNode!.requestFocus();
    await _pumpFrames(tester);
    await _sendKeyAndPump(tester, LogicalKeyboardKey.select);
    expect(picker, findsNothing);
    expect(
      tester.widget<EpgChannelCell>(find.byType(EpgChannelCell).first).name,
      'Channel 1',
    );
    await focusGuideNode(tester, 'GuideChannel:0');
    await _sendKeyAndPump(tester, LogicalKeyboardKey.arrowLeft);
    expect(picker, findsOneWidget);
    await _sendKeyAndPump(tester, LogicalKeyboardKey.arrowRight);
    expect(picker, findsNothing);

    await focusGuideNode(tester, 'GuideBrowse');
    await _sendKeyAndPump(tester, LogicalKeyboardKey.enter);
    tester.widget<ListTile>(find.widgetWithText(ListTile, 'Favorites')).focusNode!.requestFocus();
    await _pumpFrames(tester);
    await tester.sendKeyEvent(
      LogicalKeyboardKey.accept,
      platform: 'windows',
      physicalKey: PhysicalKeyboardKey.enter,
    );
    await _pumpFrames(tester);
    expect(picker, findsNothing);
    expect(guideModel(tester).filter, GuideFilter.favorites);

    for (final apiLevel in [32, 33]) {
      await focusGuideNode(tester, 'GuideBrowse');
      await _sendKeyAndPump(tester, LogicalKeyboardKey.enter);
      expect(picker, findsOneWidget);

      DialogBackSuppressor.newBackPress();
      await tester.sendKeyDownEvent(
        LogicalKeyboardKey.goBack,
        physicalKey: PhysicalKeyboardKey.escape,
      );
      final handledKeyUp = await tester.sendKeyUpEvent(
        LogicalKeyboardKey.goBack,
        physicalKey: PhysicalKeyboardKey.escape,
      );
      await _pumpFrames(tester);
      expect(picker, findsNothing);
      final popsBefore = observer.suppressed;
      final sendsPopRoute = apiLevel >= 33 || !handledKeyUp;
      if (sendsPopRoute) {
        await tester.binding.handlePopRoute();
        await _pumpFrames(tester);
      }
      expect(observer.suppressed, popsBefore + (sendsPopRoute ? 1 : 0));
      expect(find.byType(LiveTvGuideScreen), findsOneWidget);
    }
  });

  for (final (apiLevel, consumeRelease) in [(32, false), (32, true), (33, false), (33, true)]) {
    testWidgets('Back dismisses the native search keyboard before the picker on API $apiLevel (handled release: $consumeRelease)', (tester) async {
      useTvLayout();
      final prefs = GetIt.instance<UserPreferences>();
      await prefs.set(UserPreferences.liveTvCategoryDisplay, LiveTvCategoryDisplay.groups);
      await prefs.set(UserPreferences.keyboardStyle, KeyboardStyle.native);
      stubGroups(const ChannelGroupLineup({'ch1': {'Local'}}));
      final observer = _DialogBackObserver();
      tester.binding.addObserver(observer);
      addTearDown(() => tester.binding.removeObserver(observer));
      addTearDown(DialogBackSuppressor.newBackPress);
      bool appKeyboardHandler(KeyEvent event) {
        if (event.logicalKey != LogicalKeyboardKey.goBack) return false;
        if (event is KeyUpEvent) return consumeRelease;
        if (event is! KeyDownEvent) return false;
        DialogBackSuppressor.newBackPress();
        return DialogBackSuppressor.handleAppKeyboardBack(event, isAndroid: true);
      }
      HardwareKeyboard.instance.addHandler(appKeyboardHandler);
      addTearDown(() => HardwareKeyboard.instance.removeHandler(appKeyboardHandler));
      await openGuideRoute(tester);
      await focusGuideNode(tester, 'GuideBrowse');
      await _sendKeyAndPump(tester, LogicalKeyboardKey.enter);
      final field = find.descendant(of: picker, matching: find.byType(LocalSearchField));
      tester.widget<LocalSearchField>(field).focusNode.requestFocus();
      await _pumpFrames(tester);
      await _sendKeyAndPump(tester, LogicalKeyboardKey.select);
      expect(CustomTVTextField.isKeyboardVisibleNotifier.value, isTrue);

      Future<void> pressBack() async {
        const back = LogicalKeyboardKey.goBack;
        const physical = PhysicalKeyboardKey.escape;
        final suppressed = observer.suppressed;
        await tester.sendKeyDownEvent(back, physicalKey: physical);
        await tester.sendKeyRepeatEvent(back, physicalKey: physical);
        final handledUp = await tester.sendKeyUpEvent(back, physicalKey: physical);
        expect(handledUp, consumeRelease);
        await _pumpFrames(tester);
        final sendsPopRoute = apiLevel >= 33 || !handledUp;
        if (sendsPopRoute) {
          await tester.binding.handlePopRoute();
          await _pumpFrames(tester);
        }
        expect(observer.suppressed, suppressed + (sendsPopRoute ? 1 : 0));
      }

      await pressBack();
      expect(CustomTVTextField.isKeyboardVisibleNotifier.value, isFalse);
      expect(picker, findsOneWidget);
      await pressBack();
      expect(picker, findsNothing);
      expect(find.byType(LiveTvGuideScreen), findsOneWidget);
    });
  }

  testWidgets('holding Select updates Favorites and rolls back failures', (tester) async {
    useTvLayout();
    userDataSync.reset();
    addTearDown(userDataSync.reset);
    final api = _MockUserLibrary();
    when(() => client.userLibraryApi).thenReturn(api);
    when(() => api.markFavorite('ch0')).thenAnswer((_) async {});
    final removal = Completer<void>();
    when(() => api.unmarkFavorite('ch0')).thenAnswer((_) => removal.future);
    await GetIt.instance<UserPreferences>().set(
      UserPreferences.liveTvCategoryDisplay,
      LiveTvCategoryDisplay.groups,
    );
    stubGroups(const ChannelGroupLineup({'ch1': {'Local'}}));
    await pumpGuide(tester);
    await focusGuideNode(tester, 'GuideChannel:0');
    bool isFavorite() => tester.widget<EpgChannelCell>(
      find.byType(EpgChannelCell).first,
    ).isFavorite;
    await _holdSelect(tester);
    verify(() => api.markFavorite('ch0')).called(1);
    expect(isFavorite(), isTrue);
    await _holdSelect(tester);
    verify(() => api.unmarkFavorite('ch0')).called(1);
    expect(isFavorite(), isFalse);
    removal.completeError(Exception('offline'));
    await _pumpFrames(tester);
    expect(isFavorite(), isTrue);
    when(() => api.unmarkFavorite('ch0')).thenAnswer((_) async {});
    await tapAndPump(tester, find.byTooltip('Filters'));
    await tapAndPump(tester, pickerOption('Favorites'));
    expect(isFavorite(), isTrue);
    await focusGuideNode(tester, 'GuideChannel:0');
    await _holdSelect(tester);
    expect(find.byType(EpgChannelCell), findsNothing);
    expect(_focusedLabel(), 'GuideBrowse');
  });

  testWidgets('removing the last favorite in the mini Guide focuses the player', (tester) async {
    useTvLayout();
    userDataSync.reset();
    addTearDown(userDataSync.reset);
    channelCount = 1;
    stubFavoriteChannel(0);
    final api = _MockUserLibrary();
    when(() => client.userLibraryApi).thenReturn(api);
    when(() => api.unmarkFavorite('ch0')).thenAnswer((_) async {});
    await pumpGuide(tester, miniPlayerMode: true, initialFilter: (GuideFilter.favorites, null));
    await focusGuideNode(tester, 'GuideChannel:0');
    await _holdSelect(tester);
    verify(() => api.unmarkFavorite('ch0')).called(1);
    expect(find.byType(EpgChannelCell), findsNothing);
    expect(_focusedLabel(), 'GuideMiniPlayer');
  });

  /// Focuses a row-0 cell two hours into the window and then steps right once,
  /// which is the only move permitted to rewrite the anchor. Returns the
  /// anchor's offset in minutes from the window start.
  Future<int> establishAnchor(WidgetTester tester) async {
    final seedIndex = _cellIndexForRow(0, 120);
    _nodeLabelled(tester, 'GuideProgramRow0:$seedIndex').requestFocus();
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();

    final focused = _focusedCell();
    expect(focused, isNotNull);
    expect(focused!.row, 0);
    return _minutesIntoRowCell(0, focused.index);
  }

  Future<void> pressDown(WidgetTester tester, int times) async {
    for (var i = 0; i < times; i++) {
      await _sendKeyAndPump(tester, LogicalKeyboardKey.arrowDown);
    }
  }

  testWidgets('browsing down the guide and back up keeps the same time in view', (tester) async {
    useTvLayout();
    await pumpGuide(tester);
    final anchor = await establishAnchor(tester);
    final offset = _horizontalOffsets(tester);
    expect(offset, isNotEmpty);
    Future<void> move(LogicalKeyboardKey key, int row) async {
      await _sendKeyAndPump(tester, key);
      expect(_horizontalOffsets(tester), offset, reason: 'horizontal scroll changed on row $row');
      expect(_focusedCell(), (row: row, index: _cellIndexForRow(row, anchor)));
    }

    // Includes clipped and oversized programs and the long scroll that used to drift.
    for (var row = 1; row <= 45; row++) {
      await move(LogicalKeyboardKey.arrowDown, row);
    }
    for (var row = 44; row >= 25; row--) {
      await move(LogicalKeyboardKey.arrowUp, row);
    }
  });

  /// Pumps a lineup one batch longer than the loader fetches, walks focus to
  /// the last loaded row (49), and leaves row 50's request outstanding.
  /// Returns the anchor's offset in minutes from the window start.
  Future<int> reachLoadedEdge(WidgetTester tester) async {
    useTvLayout();
    channelCount = _deferredChannelCount;
    deferredChannelId = _firstDeferredChannelId;

    await pumpGuide(tester);
    final anchorMinutes = await establishAnchor(tester);
    await pressDown(tester, 49);

    final focused = _focusedCell();
    expect(focused, isNotNull);
    expect(focused!.row, 49, reason: 'did not reach the last loaded row');
    expect(
      releaseDeferredGuide,
      isNotEmpty,
      reason: 'the next batch was never requested, so no row is loading',
    );
    return anchorMinutes;
  }

  Future<void> releaseGuideData(WidgetTester tester) async {
    for (final release in releaseDeferredGuide) {
      release();
    }
    releaseDeferredGuide.clear();
    await _pumpFrames(tester);
  }

  for (final moveToSearch in [false, true]) {
    final destination = moveToSearch ? 'channel search' : 'the program grid';
    testWidgets('a delayed guide page keeps focus in $destination', (tester) async {
      useTvLayout();
      channelCount = 3;
      await GetIt.instance<UserPreferences>().set(
        UserPreferences.liveTvCategoryDisplay,
        LiveTvCategoryDisplay.groups,
      );
      stubGroups(const ChannelGroupLineup({'ch0': {'Sports'}}));
      await pumpGuide(tester);
      final vm = guideModel(tester);
      final start = vm.windowStart;
      final target = start.add(const Duration(minutes: 30));
      final lastCell = _cellIndexForRow(0, vm.guideWindow.inMinutes - 1);
      await focusGuideNode(tester, 'GuideProgramRow0:$lastCell');

      deferredChannelId = 'ch0';
      await _sendKeyAndPump(tester, LogicalKeyboardKey.arrowRight);
      expect(releaseDeferredGuide, isNotEmpty);
      expect(vm.pendingWindowStart, target);
      expect(vm.windowStart, start);

      if (moveToSearch) {
        await expectFocusAfter(tester, LogicalKeyboardKey.arrowUp, 'GuideWindowBar:0');
        await expectFocusAfter(tester, LogicalKeyboardKey.arrowUp, 'GuideBrowse');
        await _sendKeyAndPump(tester, LogicalKeyboardKey.arrowRight);
        if (_focusedLabel() == 'GuideShortcut:category:favorites') {
          await _sendKeyAndPump(tester, LogicalKeyboardKey.arrowRight);
        }
        expect(_focusedLabel(), 'GuideSearch');
        expect(vm.pendingWindowStart, target);
      }

      deferredChannelId = null;
      await releaseGuideData(tester);
      expect(vm.windowStart, target);
      expect(vm.pendingWindowStart, isNull);
      if (moveToSearch) {
        expect(_focusedLabel(), 'GuideSearch');
      } else {
        expect(_focusedCell()?.row, 0);
      }
    });
  }

  testWidgets('scrolling a Hebrew channel group keeps the program title visible', (tester) async {
    useLayout(InterfaceLayout.phone);
    final prefs = GetIt.instance<UserPreferences>();
    await prefs.set(UserPreferences.liveTvCategoryDisplay, LiveTvCategoryDisplay.groups);
    await prefs.set(UserPreferences.epgMobileView, EpgMobileView.grid);
    stubGroups(const ChannelGroupLineup({'ch4': {'Sports'}}));
    await pumpGuide(tester, surface: const Size(1800, 800), locale: const Locale('he'),
        initialFilter: (GuideFilter.all, 'Sports'));
    tester.view.physicalSize = phone;
    await _pumpFrames(tester);
    final title = find.descendant(of: find.byType(EpgProgramCell), matching: find.text('ch4 show 0'));
    final scroll = Scrollable.of(tester.element(title), axis: Axis.horizontal);
    expect(scroll.position.maxScrollExtent, greaterThan(95));
    scroll.position.jumpTo(95);
    await _pumpFrames(tester);
    expect(title.hitTestable(), findsOneWidget);
  });

  testWidgets('TV arrows follow the visible Hebrew Browse header', (tester) async {
    useTvLayout();
    await GetIt.instance<UserPreferences>().set(UserPreferences.liveTvCategoryDisplay, LiveTvCategoryDisplay.groups);
    stubGroups(const ChannelGroupLineup({'ch0': {'Sports'}}));
    await pumpGuide(tester, surface: const Size(1280, 720), locale: const Locale('he'));
    await focusGuideNode(tester, 'GuideBrowse');
    const favorite = 'GuideShortcut:category:favorites';
    await expectFocusAfter(tester, LogicalKeyboardKey.arrowLeft, favorite);
    await expectFocusAfter(tester, LogicalKeyboardKey.arrowLeft, 'GuideSearch');
    await expectFocusAfter(tester, LogicalKeyboardKey.arrowRight, favorite);
    await expectFocusAfter(tester, LogicalKeyboardKey.arrowRight, 'GuideBrowse');
    await _sendKeyAndPump(tester, LogicalKeyboardKey.arrowRight);
    expect(picker, findsOneWidget);
    await _sendKeyAndPump(tester, LogicalKeyboardKey.arrowLeft);
    expect(picker, findsNothing);
    for (final target in ['GuideChannel:0', 'GuideWindowBar:0']) {
      await focusGuideNode(tester, target);
      await _sendKeyAndPump(tester, LogicalKeyboardKey.arrowRight);
      expect(picker, findsOneWidget, reason: target);
      await _sendKeyAndPump(tester, LogicalKeyboardKey.arrowLeft);
      expect(picker, findsNothing);
      await focusGuideNode(tester, target);
      await _sendKeyAndPump(tester, LogicalKeyboardKey.arrowLeft);
      if (target == 'GuideChannel:0') {
        expect(_focusedCell()?.row, 0);
      } else {
        expect(_focusedLabel(), 'GuideWindowBar:1');
      }
    }
    await focusGuideNode(tester, 'GuideProgramRow0:0');
    final first = _nodeLabelled(tester, 'GuideProgramRow0:0').rect;
    await expectFocusAfter(tester, LogicalKeyboardKey.arrowLeft, 'GuideProgramRow0:1');
    expect(_nodeLabelled(tester, 'GuideProgramRow0:1').rect.center.dx, lessThan(first.center.dx));
    await expectFocusAfter(tester, LogicalKeyboardKey.arrowRight, 'GuideProgramRow0:0');
    await expectFocusAfter(tester, LogicalKeyboardKey.arrowRight, 'GuideChannel:0');
  });

  for (final action in ['wait', 'move up', 'open details']) {
    testWidgets('a loading row respects the viewer’s next action: $action', (tester) async {
      final anchor = await reachLoadedEdge(tester);
      void expectRow(int row) =>
          expect(_focusedCell(), (row: row, index: _cellIndexForRow(row, anchor)));
      await _sendKeyAndPump(tester, LogicalKeyboardKey.arrowDown);
      expectRow(49);
      switch (action) {
        case 'move up':
          await _sendKeyAndPump(tester, LogicalKeyboardKey.arrowUp);
          expectRow(48);
        case 'open details':
          await _sendKeyAndPump(tester, LogicalKeyboardKey.enter);
          expect(_alertDialog, findsOneWidget);
      }
      await releaseGuideData(tester);
      if (action == 'open details') {
        expect(_focusedCell(), isNull);
        Navigator.of(tester.element(_alertDialog)).pop();
        await _pumpFrames(tester);
        expectRow(49);
      } else {
        expectRow(action == 'wait' ? 50 : 48);
      }
    });
  }

  testWidgets('browse from listings through the header, channel column and page controls', (tester) async {
    useTvLayout();
    await pumpGuide(tester);
    Future<void> move(LogicalKeyboardKey key, String label) => expectFocusAfter(tester, key, label);
    await focusGuideNode(tester, 'GuideProgramRow0:0');
    await move(LogicalKeyboardKey.arrowUp, 'GuideWindowBar:0');
    await move(LogicalKeyboardKey.arrowUp, 'GuideFilter:0');
    await move(LogicalKeyboardKey.arrowDown, 'GuideWindowBar:0');
    for (final index in [1, 2, 3, 4, 5, 5]) {
      await move(LogicalKeyboardKey.arrowRight, 'GuideWindowBar:$index');
    }
    for (var index = 4; index >= 0; index--) {
      await move(LogicalKeyboardKey.arrowLeft, 'GuideWindowBar:$index');
    }
    await move(LogicalKeyboardKey.arrowDown, 'GuideChannel:0');
    await move(LogicalKeyboardKey.arrowDown, 'GuideChannel:1');
    await _sendKeyAndPump(tester, LogicalKeyboardKey.arrowRight);
    expect(_focusedLabel(), startsWith('GuideProgramRow1:'));
    await move(LogicalKeyboardKey.arrowLeft, 'GuideChannel:1');
    await move(LogicalKeyboardKey.arrowUp, 'GuideChannel:0');
    await move(LogicalKeyboardKey.arrowLeft, 'GuideFilter:0');
    await focusGuideNode(tester, 'GuideChannel:0');
    await _sendKeyAndPump(tester, LogicalKeyboardKey.mediaFastForward);
    expect(_focusedLabel(), startsWith('GuideChannel:'));
    final pagedRow = int.parse(_focusedLabel()!.split(':').last);
    expect(pagedRow, greaterThan(0));
    await move(LogicalKeyboardKey.mediaRewind, 'GuideChannel:0');

    final anchorMinutes = await establishAnchor(tester);
    final offsets = _horizontalOffsets(tester);
    await _sendKeyAndPump(tester, LogicalKeyboardKey.mediaFastForward);
    expect(_focusedCell()!.row, pagedRow);
    expect(_focusedCell()!.index, _cellIndexForRow(pagedRow, anchorMinutes));
    expect(_horizontalOffsets(tester), offsets);

    await _sendKeyAndPump(tester, LogicalKeyboardKey.mediaRewind);
    expect(_focusedCell()!.row, 0);
    expect(_focusedCell()!.index, _cellIndexForRow(0, anchorMinutes));
    expect(_horizontalOffsets(tester), offsets);
  });

  testWidgets(
    'a paged-ahead guide does not re-anchor at a half-hour boundary',
    (tester) async {
      await pumpGuide(tester);

      final next = _nodeLabelled(tester, 'GuideWindowBar:2');
      next.requestFocus();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      final futureRange = _windowRangeText(tester);
      expect(_focusedLabel(), 'GuideWindowBar:2');

      // The fake timer advances far enough for the scheduled half-hour callback
      // to run. DateTime.now remains fixed in Flutter's test clock, so the
      // assertion exercises the non-live guard rather than simulating a wall
      // clock change.
      await tester.pump(const Duration(minutes: 31));

      expect(_windowRangeText(tester), futureRange);
      expect(_focusedLabel(), 'GuideWindowBar:2');
    },
  );

  testWidgets('compact desktop search keeps its height when Clear appears', (tester) async {
    useLayout(InterfaceLayout.desktop);
    await pumpGuide(tester, surface: const Size(900, 430));
    final field = find.byType(TextField);
    expect(tester.getSize(field).height, 36);
    await tester.enterText(field, 'ch1');
    await _pumpFrames(tester);
    expect(tester.getSize(field).height, 36);
    await tester.tap(find.descendant(of: field, matching: find.byType(IconButton)));
    await tester.pump();
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
  });

  testWidgets('landscape width is restored after a stale portrait resume', (tester) async {
    useLayout(InterfaceLayout.phone);
    const wide = Size(1500, 700);
    await pumpGuide(tester, surface: wide);
    final vm = guideModel(tester);
    final landscapeWindow = vm.guideWindow;
    tester.view.physicalSize = phone;
    await _pumpFrames(tester);
    await vm.setWindowStart(vm.windowStart.subtract(const Duration(days: 1)));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _pumpFrames(tester);
    expect(vm.guideWindow, lessThan(landscapeWindow));
    tester.view.physicalSize = wide;
    await _pumpFrames(tester);
    expect(vm.guideWindow, landscapeWindow);
  });

  testWidgets('landscape search keeps its field and matches above a tall keyboard', (tester) async {
    useLayout(InterfaceLayout.phone);
    userDataSync.reset();
    addTearDown(userDataSync.reset);
    channelCount = 5;
    final api = _MockUserLibrary();
    when(() => client.userLibraryApi).thenReturn(api);
    when(() => api.markFavorite('ch4')).thenAnswer((_) async {});
    when(() => api.unmarkFavorite('ch4')).thenAnswer((_) async {});
    await pumpGuide(tester, surface: const Size(640, 360));
    final field = find.byType(TextField);
    await tester.tap(field);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await _pumpFrames(tester);
    expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
    tester.testTextInput.enterText('Channel 4');
    await _pumpFrames(tester);
    final match = find.widgetWithText(ListTile, 'Channel 4').hitTestable();
    final heart = find.descendant(of: match, matching: find.byIcon(Icons.favorite));
    expect(match, findsOneWidget);
    expect(heart, findsNothing);
    await tester.longPress(match);
    await _pumpFrames(tester);
    expect(heart, findsOneWidget);
    await tester.longPress(match);
    await _pumpFrames(tester);
    expect(heart, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Up from category Retry returns to search above a tall keyboard', (tester) async {
    useLayout(InterfaceLayout.phone);
    channelCount = 2;
    stubGroups(const ChannelGroupLineup({}, programmeCategories: {'sports'}));
    when(() => _guideRequest(liveTvApi)).thenAnswer((inv) async {
      final ids = inv.namedArguments[#channelIds] as List;
      return {
        'Items': [for (final id in ids.where((id) => id != 'ch0')) ..._programsFor(id, sports: true)],
        if (inv.namedArguments[#isSports] == true) 'FailedChannelIds': ['ch0'],
      };
    });
    await pumpGuide(tester, surface: const Size(640, 360));
    guideModel(tester).setFilter(GuideFilter.sports);
    await _pumpFrames(tester);
    final field = find.byType(TextField);
    await tester.tap(field);
    tester.view.viewInsets = const FakeViewPadding(bottom: 212);
    await _pumpFrames(tester);
    expect(find.text('Channel 1').hitTestable(), findsOneWidget);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await _pumpFrames(tester);
    await focusGuideNode(tester, 'GuideCategoryRetry');
    expect(_focusedLabel(), 'GuideCategoryRetry');
    await _sendKeyAndPump(tester, LogicalKeyboardKey.arrowUp);
    expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
  });

  testWidgets('landscape phone search and Clear have full touch targets', (tester) async {
    useLayout(InterfaceLayout.phone);
    await pumpGuide(tester, surface: const Size(900, 430));
    final field = find.byType(TextField);
    expect(tester.getSize(field).height, greaterThanOrEqualTo(kMinInteractiveDimension));
    await tester.enterText(field, 'ch1');
    await _pumpFrames(tester);
    final clear = find.descendant(of: field, matching: find.byType(IconButton));
    final size = tester.getSize(clear);
    expect(size.shortestSide, greaterThanOrEqualTo(kMinInteractiveDimension));
    await tester.tap(clear);
    await tester.pump();
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
  });

  testWidgets('moving into the mini player skips hero artwork', (tester) async {
    useTvLayout();
    await pumpGuide(tester, miniPlayerMode: true);
    await focusGuideNode(tester, 'GuideProgramRow0:0');
    await expectFocusAfter(tester, LogicalKeyboardKey.arrowUp, 'GuideMiniPlayer');
    await tester.pump(const Duration(seconds: 1));
    verifyNever(() => liveTvApi.getProgram(any(), userId: any(named: 'userId')));
  });

  Future<void> back(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  }

  testWidgets('Back retries the live window after a newer date request fails', (tester) async {
    useTvLayout();
    channelCount = 8;
    await openGuideRoute(tester);
    final vm = guideModel(tester);
    final tomorrow = vm.windowStart.add(const Duration(days: 1));
    expect(await vm.setWindowStart(tomorrow), isTrue);
    await focusGuideNode(tester, 'GuideChannel:0');

    deferredChannelId = 'ch0';
    await tester.binding.handlePopRoute();
    await _pumpFrames(tester);
    expect(releaseDeferredGuide, hasLength(1));
    final failures = vm.failedWindowMoveRevision;
    guideFailure = TimeoutException('offline');
    expect(await vm.setDate(tomorrow.add(const Duration(days: 1))), isFalse);
    expect(vm.failedWindowMoveRevision, failures + 1);
    deferredChannelId = null;
    guideFailure = null;
    releaseDeferredGuide.single();
    await _pumpFrames(tester);

    expect(vm.windowStart, tomorrow);
    await back(tester);
    expect(find.byType(LiveTvGuideScreen), findsOneWidget);
    expect(vm.atLivePosition, isTrue);
  });

  testWidgets('Back returns to live after the picker recovers from a failed live reset', (tester) async {
    useTvLayout();
    channelCount = 8;
    await openGuideRoute(tester);
    final vm = guideModel(tester);
    final day = DateUtils.addDaysToDate(vm.guideDate, -1);
    expect(await vm.setDate(day), isTrue);
    await focusGuideNode(tester, 'GuideChannel:0');
    guideFailure = TimeoutException('offline');
    await tester.binding.handlePopRoute();
    await _pumpFrames(tester);
    expect(vm.atLivePosition, isFalse);

    guideFailure = null;
    final target = DateUtils.addDaysToDate(day, day.day == 1 ? 1 : -1);
    await tapAndPump(tester, find.byIcon(Icons.calendar_today));
    final calendar = find.byType(CalendarDatePicker);
    await tapAndPump(tester, find.descendant(of: calendar, matching: find.text('${target.day}')));
    await tapAndPump(tester, find.text('OK'));
    expect(DateUtils.isSameDay(vm.guideDate, target), isTrue);
    await focusGuideNode(tester, 'GuideChannel:0');
    await tester.binding.handlePopRoute();
    await _pumpFrames(tester);
    expect(find.byType(LiveTvGuideScreen), findsOneWidget);
    expect(vm.atLivePosition, isTrue);
  });

  testWidgets('TV back returns to the tuned channel, then header, then exits', (
    tester,
  ) async {
    useTvLayout();
    await GetIt.instance<UserPreferences>().set(
      UserPreferences.liveTvLastChannelId,
      'ch3',
    );
    await openGuideRoute(tester);
    _nodeLabelled(tester, 'GuideChannel:4').requestFocus();
    await tester.pumpAndSettle();
    clearInteractions(liveTvApi);
    await back(tester);
    expect(_focusedLabel(), 'GuideChannel:3');
    // Already live, so returning to the channel reloads nothing.
    verifyNever(() => _channelsRequest(liveTvApi));
    await back(tester);
    expect(_focusedLabel(), 'GuideFilter:0');
    await expectFocusAfter(tester, LogicalKeyboardKey.arrowDown, 'GuideWindowBar:0');
    await expectFocusAfter(tester, LogicalKeyboardKey.arrowDown, 'GuideChannel:3');

    // Re-entering the rows starts the same sequence again.
    _nodeLabelled(tester, 'GuideChannel:4').requestFocus();
    await tester.pumpAndSettle();
    await back(tester);
    expect(_focusedLabel(), 'GuideChannel:3');
    await back(tester);
    expect(_focusedLabel(), 'GuideFilter:0');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(LiveTvGuideScreen), findsNothing);
  });

  for (final layout in [InterfaceLayout.desktop, InterfaceLayout.tv]) {
    testWidgets('filtering out the entry channel updates the hero and lets Back exit on ${layout.name}', (tester) async {
      useLayout(layout);
      stubFavoriteChannel(5);
      await GetIt.instance<UserPreferences>().set(UserPreferences.liveTvLastChannelId, 'ch0');
      await openGuideRoute(tester);
      await focusGuideNode(tester, 'GuideChannel:0');
      String? hero() => tester.widget<EpgHeroPreview>(find.byType(EpgHeroPreview)).title;
      expect(hero(), 'Channel 0');
      final rail = tester.widget<EpgFilterRail>(find.byType(EpgFilterRail));
      rail.onSelect(rail.labels.indexOf('Favorites'));
      await tester.pumpAndSettle();
      expect(_focusedLabel(), 'GuideChannel:0');
      expect(hero(), 'Channel 5');
      await back(tester);
      if (layout == InterfaceLayout.tv) {
        expect(_focusedLabel(), startsWith('GuideFilter:'));
        await back(tester);
      }
      expect(find.byType(LiveTvGuideScreen), findsNothing);
    });
  }

  testWidgets('closing Browse keeps the focused station when another favorite appears above it', (tester) async {
    useTvLayout();
    await GetIt.instance<UserPreferences>().set(UserPreferences.liveTvCategoryDisplay, LiveTvCategoryDisplay.groups);
    userDataSync.reset();
    addTearDown(userDataSync.reset);
    stubFavoriteChannel(5);
    stubGroups(const ChannelGroupLineup({'ch1': {'Local'}}));
    await pumpGuide(tester, initialFilter: (GuideFilter.favorites, null));
    await focusGuideNode(tester, 'GuideChannel:0');
    final vm = guideModel(tester);
    userDataSync.publish(channelFavoriteKey(vm.channelForId('ch1')!.rawData)!, {'IsFavorite': true});
    expect(vm.filteredChannels.map((c) => c.id), ['ch1', 'ch5']);
    await _sendKeyAndPump(tester, LogicalKeyboardKey.arrowLeft);
    expect(picker, findsOneWidget);
    Navigator.of(tester.element(picker)).pop();
    await _pumpFrames(tester);
    expect(_focusedLabel(), 'GuideChannel:1');
  });

  testWidgets('the TV preview follows the focused row when its station disappears during a rebind', (tester) async {
    useTvLayout();
    userDataSync.reset();
    addTearDown(userDataSync.reset);
    stubFavoriteChannel(5);
    await openGuideRoute(tester);
    final vm = guideModel(tester);
    void favorite(String id, bool value) {
      userDataSync.publish(channelFavoriteKey(vm.channelForId(id)!.rawData)!, {'IsFavorite': value});
    }
    favorite('ch8', true);
    vm.setFilter(GuideFilter.favorites);
    await _pumpFrames(tester);
    await focusGuideNode(tester, 'GuideChannel:0');
    String? preview() => tester.widget<EpgHeroPreview>(find.byType(EpgHeroPreview)).title;
    expect(preview(), 'Channel 5');

    favorite('ch1', true);
    expect(vm.filteredChannels.map((c) => c.id), ['ch1', 'ch5', 'ch8']);
    favorite('ch5', false);
    await _pumpFrames(tester);
    expect(vm.filteredChannels.map((c) => c.id), ['ch1', 'ch8']);
    expect(_focusedLabel(), 'GuideChannel:0');
    expect(preview(), 'Channel 1');
  });

  testWidgets('a lineup change behind the player leaves focus on the player', (tester) async {
    useTvLayout();
    stubFavoriteChannel(5);
    await openGuideRoute(tester);
    await establishAnchor(tester);
    final vm = guideModel(tester);
    final rail = tester.widget<EpgFilterRail>(find.byType(EpgFilterRail));
    final player = FocusNode(debugLabel: 'Player');
    addTearDown(player.dispose);
    Navigator.of(tester.element(find.byType(LiveTvGuideScreen))).push(
      MaterialPageRoute<void>(builder: (_) => Focus(focusNode: player, autofocus: true, child: const SizedBox())),
    );
    await tester.pumpAndSettle();
    expect(player.hasPrimaryFocus, isTrue);
    rail.onSelect(rail.labels.indexOf('Favorites'));
    await tester.pumpAndSettle();
    expect(vm.filteredChannels.map((c) => c.id), ['ch5']);
    expect(player.hasPrimaryFocus, isTrue);
  });

  testWidgets(
    'returning from the player focuses the preference channel, not the '
    'one launched',
    (tester) async {
      tester.view.physicalSize = const Size(900, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => const LiveTvGuideScreen()),
          GoRoute(
            path: Destinations.liveTvPlayer,
            builder: (_, _) => const Scaffold(body: SizedBox.shrink()),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        MaterialApp.router(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      );
      await tester.pumpAndSettle();

      // Launch ch0 from the guide.
      _nodeLabelled(tester, 'GuideChannel:0').requestFocus();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      // The player route is up. Simulate it having switched to ch3 while the
      // guide waited underneath, exactly as the carousel does.
      await GetIt.instance<UserPreferences>().set(
        UserPreferences.liveTvLastChannelId,
        'ch3',
      );

      router.pop();
      await tester.pumpAndSettle();

      expect(_focusedLabel(), 'GuideChannel:3');
    },
  );

  for (final layout in [InterfaceLayout.desktop, InterfaceLayout.tv]) {
    for (final lastChannel in [null, 'ch2']) {
      testWidgets('Back from a past guide window restores the tuned channel on ${layout.name} ($lastChannel)', (tester) async {
        useLayout(layout);
        await openGuideRoute(tester);
        if (lastChannel != null) {
          await GetIt.instance<UserPreferences>().set(UserPreferences.liveTvLastChannelId, lastChannel);
        } else {
          await focusGuideNode(tester, 'GuideChannel:3');
        }
        final live = _windowRangeText(tester);
        await focusGuideNode(tester, 'GuideWindowBar:0');
        await _sendKeyAndPump(tester, LogicalKeyboardKey.enter);
        expect(_windowRangeText(tester), isNot(live));
        if (layout == InterfaceLayout.tv) {
          // Back from the TV header exits. Return to the grid to re-home it.
          await _sendKeyAndPump(tester, LogicalKeyboardKey.arrowDown);
          expect(_focusedLabel(), startsWith('GuideChannel:'));
        }
        await back(tester);
        expect(find.byType(LiveTvGuideScreen), findsOneWidget);
        expect(guideModel(tester).atLivePosition, isTrue);
        expect(_focusedLabel(), lastChannel == null ? 'GuideChannel:0' : 'GuideChannel:2');
      });
    }
  }
}
