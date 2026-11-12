import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moonfin/data/models/live_tv_recording_state.dart';
import 'package:moonfin/data/services/user_data_sync.dart';
import 'package:moonfin/data/viewmodels/live_tv_guide_view_model.dart';
import 'package:moonfin/preference/preference_constants.dart';
import 'package:server_core/server_core.dart';

class _MockClient extends Mock implements MediaServerClient {}

class _MockLiveTvApi extends Mock implements LiveTvApi {}

class _GroupedLiveTvApi extends _MockLiveTvApi implements ChannelGroupApi {}

class _MockUserLibraryApi extends Mock implements UserLibraryApi {}

Map<String, dynamic> _channel(String id, {String? number}) => {
  'Id': id,
  'Name': 'Ch $id',
  'ChannelNumber': ?number,
};

Map<String, dynamic> _program(
  String id,
  String channelId, {
  DateTime? start,
  bool isSports = false,
  bool isKids = false,
  bool isPremiere = false,
}) {
  final programStart = start ?? DateTime.parse('2026-09-11T10:00:00Z');
  return {
    'Id': id,
    'ChannelId': channelId,
    'Name': id,
    'StartDate': programStart.toIso8601String(),
    'EndDate': programStart.add(const Duration(minutes: 30)).toIso8601String(),
    'IsSports': isSports,
    'IsKids': isKids,
    'IsPremiere': isPremiere,
  };
}

Map<String, dynamic> _span(
  String id,
  String channelId,
  DateTime start,
  DateTime end,
) => {
  'Id': id,
  'ChannelId': channelId,
  'Name': id,
  'StartDate': start.toIso8601String(),
  'EndDate': end.toIso8601String(),
};

List<String> _requestedIds(Invocation inv) =>
    (inv.namedArguments[#channelIds] as List<String>?) ?? const [];

Future<Map<String, dynamic>> Function(Invocation) _serverFiltered(
  bool Function(String id) isSports,
) =>
    (inv) async => {
      'Items': [
        for (final id in _requestedIds(inv))
          if (isSports(id)) _program('p-$id', id, isSports: true),
      ],
    };

Future<Map<String, dynamic>> _guide(
  LiveTvApi api, {
  GuideFilter? category,
  bool captureChannelIds = false,
}) {
  bool? flag(GuideFilter f, String name) =>
      category == null ? any(named: name) : (category == f ? true : null);
  return api.getGuide(
    startDate: any(named: 'startDate'),
    endDate: any(named: 'endDate'),
    channelIds: captureChannelIds
        ? captureAny(named: 'channelIds')
        : any(named: 'channelIds'),
    isMovie: flag(GuideFilter.movies, 'isMovie'),
    isSeries: flag(GuideFilter.series, 'isSeries'),
    isSports: flag(GuideFilter.sports, 'isSports'),
    isNews: flag(GuideFilter.news, 'isNews'),
    isKids: flag(GuideFilter.kids, 'isKids'),
    fields: any(named: 'fields'),
    enableTotalRecordCount: any(named: 'enableTotalRecordCount'),
    enableImages: any(named: 'enableImages'),
    enableUserData: any(named: 'enableUserData'),
    userId: any(named: 'userId'),
  );
}

Future<Map<String, dynamic>> _channelsRequest(LiveTvApi api) => api.getChannels(
  sortBy: any(named: 'sortBy'),
  sortOrder: any(named: 'sortOrder'),
  fields: any(named: 'fields'),
  enableTotalRecordCount: any(named: 'enableTotalRecordCount'),
  userId: any(named: 'userId'),
);

void _stubChannels(LiveTvApi api, List<Map<String, dynamic>> channels) {
  when(() => _channelsRequest(api))
      .thenAnswer((_) async => {'Items': channels});
}

void main() {
  late _MockClient client;
  late _MockLiveTvApi liveTv;

  setUp(() {
    userDataSync.reset();
    client = _MockClient();
    liveTv = _MockLiveTvApi();
    when(() => client.liveTvApi).thenReturn(liveTv);
    when(() => client.serverType).thenReturn(ServerType.jellyfin);
    when(() => client.userId).thenReturn('user');
    when(() => _guide(liveTv)).thenAnswer((_) async => {'Items': <dynamic>[]});
  });

  test('Plex leaves out the genre filters its programs never carry', () {
    when(() => client.serverType).thenReturn(ServerType.plex);
    expect(
      LiveTvGuideViewModel(client).filters,
      isNot(
        anyOf(
          contains(GuideFilter.sports),
          contains(GuideFilter.news),
          contains(GuideFilter.kids),
        ),
      ),
    );

    for (final type in [ServerType.jellyfin, ServerType.emby]) {
      when(() => client.serverType).thenReturn(type);
      expect(LiveTvGuideViewModel(client).filters, GuideFilter.values);
    }
  });

  group('automatic lineup refresh', () {
    late _GroupedLiveTvApi api;
    late LiveTvGuideViewModel vm;
    var revision = '1';

    setUp(() {
      revision = '1';
      api = _GroupedLiveTvApi();
      when(() => client.liveTvApi).thenReturn(api);
      when(() => client.baseUrl).thenReturn('fixture');
      when(() => _guide(api)).thenAnswer((_) async => {'Items': []});
      vm = LiveTvGuideViewModel(client);
      addTearDown(vm.dispose);
    });

    test(
      'keeps listings after a timeout and retries the same import',
      () async {
        _stubChannels(api, [_channel('one')]);
        when(api.getChannelGroups).thenAnswer(
          (_) async => ChannelGroupLineup({}, guideRevision: revision),
        );
        void show(String title) => when(() => _guide(api)).thenAnswer(
          (_) async => {
            'Items': [_program(title, 'one')],
          },
        );
        show('old');
        await vm.load();
        revision = '2';
        when(() => _guide(api)).thenThrow(TimeoutException('guide'));
        await vm.refreshGuide();
        expect(vm.state, GuideState.ready);
        expect(vm.programsForChannel('one').single.name, 'old');
        show('new');
        await vm.refreshGuide();
        expect(vm.programsForChannel('one').single.name, 'new');
        verify(api.getChannelGroups).called(3);
      },
    );

    test('Now uses the loaded channels while a server notification refreshes their IDs', () async {
      _stubChannels(api, [_channel('old')]);
      when(api.getChannelGroups).thenAnswer(
        (_) async => const ChannelGroupLineup({
          'old': {'Canadian'},
        }),
      );
      await vm.load();
      vm.setGroup('Canadian');
      await vm.goToNow();
      verify(api.getChannelGroups).called(1);
      _stubChannels(api, [_channel('new')]);
      when(api.getChannelGroups).thenAnswer(
        (_) async => const ChannelGroupLineup({
          'new': {'Canadian'},
        }),
      );
      await vm.refreshGuide();
      expect(vm.selectedGroup, 'Canadian');
      expect(vm.filteredChannels.single.id, 'new');
    });

    test('an old All failure leaves the selected group ready', () async {
      _stubChannels(
        api,
        List.generate(100, (i) => _channel('c$i', number: '$i')),
      );
      when(api.getChannelGroups).thenAnswer(
        (_) async => const ChannelGroupLineup({
          'c95': {'Canadian'},
        }, guideRevision: '1'),
      );
      final all = Completer<Map<String, dynamic>>();
      when(() => _guide(api)).thenAnswer((invocation) async {
        if (_requestedIds(invocation).contains('c95')) {
          return {
            'Items': [_program('Game', 'c95')],
          };
        }
        return all.future;
      });
      final opening = vm.load();
      await Future<void>.delayed(Duration.zero);
      vm.setGroup('Canadian');
      await Future<void>.delayed(Duration.zero);
      all.completeError(TimeoutException('initial All page'));
      await opening;
      expect(vm.state, GuideState.ready);
      expect(vm.programsForChannel('c95').single.name, 'Game');
      expect(vm.error, isNull);
    });

    test(
      'removes a healthy tuner’s old group while another tuner is offline',
      () async {
        _stubChannels(api, [_channel('healthy'), _channel('offline')]);
        when(api.getChannelGroups).thenAnswer(
          (_) async => const ChannelGroupLineup({
            'healthy': {'Sports'},
            'offline': {'UK'},
          }, guideRevision: '1'),
        );
        await vm.load();
        vm.setGroup('Sports');
        revision = '2';
        when(api.getChannelGroups).thenAnswer(
          (_) async => const ChannelGroupLineup(
            {},
            partial: true,
            unresolvedChannelIds: {'offline'},
            guideRevision: '2',
          ),
        );
        await vm.refreshGuide();
        expect(vm.availableGroups, ['UK']);
        expect(vm.selectedGroup, isNull);
        vm.setGroup('UK');
        expect(vm.filteredChannels.single.id, 'offline');
      },
    );

    test(
      'a date change during a lineup refresh keeps the new window',
      () async {
        _stubChannels(api, [_channel('one')]);
        when(api.getChannelGroups).thenAnswer(
          (_) async => ChannelGroupLineup({
            'one': {revision},
          }, guideRevision: revision),
        );
        await vm.load();
        final channels = Completer<Map<String, dynamic>>();
        when(
          () => api.getChannels(
            sortBy: any(named: 'sortBy'),
            sortOrder: any(named: 'sortOrder'),
            fields: any(named: 'fields'),
            enableTotalRecordCount: any(named: 'enableTotalRecordCount'),
            userId: any(named: 'userId'),
          ),
        ).thenAnswer((_) => channels.future);
        final pending = vm.refreshGuide();
        final tomorrow = vm.guideDate.add(const Duration(days: 1));
        await vm.setDate(tomorrow);
        channels.complete({
          'Items': [_channel('one')],
        });
        await pending;
        revision = '2';
        await vm.refreshGuide();
        expect(vm.availableGroups, ['2']);
        expect(vm.guideDate, tomorrow);
        expect(vm.atLivePosition, isFalse);
      },
    );

    for (final refresh in [true, false]) {
      test(
        'native denial clears cached guide data on ${refresh ? 'refresh' : 'load'}',
        () async {
          _stubChannels(api, [_channel('one'), _channel('two')]);
          when(api.getChannelGroups).thenAnswer(
            (_) async => const ChannelGroupLineup(
              {
                'one': {'Kids'},
              },
              programmeCategories: {'kids'},
              guideRevision: '1',
            ),
          );
          when(() => _guide(api)).thenAnswer(
            (_) async => {
              'Items': [_program('Kids show', 'one')],
            },
          );
          await vm.load();
          vm.setGroup('Kids');
          expect(vm.filteredChannels.single.id, 'one');
          expect(vm.programsForChannel('one'), isNotEmpty);

          final request = RequestOptions(path: '/LiveTv/Channels');
          final denied = DioException(
            requestOptions: request,
            response: Response(
              requestOptions: request,
              statusCode: refresh ? 403 : 401,
            ),
          );
          when(() => _channelsRequest(api)).thenThrow(denied);
          await (refresh ? vm.refreshGuide() : vm.load());
          expect(vm.state, GuideState.error);
          expect(vm.error, same(denied));
          expect(vm.playbackChannels, isEmpty);
          expect(vm.filteredChannels, isEmpty);
          expect(vm.programsForChannel('one'), isEmpty);
          expect(vm.availableGroups, isEmpty);
          expect(vm.availableProgrammeCategories, isEmpty);

          _stubChannels(api, [_channel('one')]);
          await vm.refreshGuide();
          expect(vm.state, GuideState.ready);
          expect(vm.filteredChannels.single.id, 'one');
        },
      );
    }

    test('a plugin-only denial keeps native channels available', () async {
      _stubChannels(api, [_channel('one')]);
      final request = RequestOptions(path: '/Moonfin/LiveTv/ChannelGroups');
      when(api.getChannelGroups).thenThrow(
        DioException(
          requestOptions: request,
          response: Response(requestOptions: request, statusCode: 403),
        ),
      );
      await vm.load();
      await vm.refreshGuide();
      expect(vm.state, GuideState.ready);
      expect(vm.playbackChannels.single.id, 'one');
      expect(vm.availableProgrammeCategories, isEmpty);
    });

    testWidgets(
      'a missing category list retries metadata and stops on an answer',
      (tester) async {
        _stubChannels(api, [_channel('one')]);
        const groups = {
          'one': {'Kids'},
        };
        var reads = 0;
        when(api.getChannelGroups).thenAnswer(
          (_) async => ChannelGroupLineup(
            groups,
            guideRevision: '1',
            programmeCategories: ++reads == 3 ? {'kids'} : null,
          ),
        );
        await vm.load();
        await tester.pump();
        expect(vm.availableGroups, ['Kids']);
        expect(vm.availableProgrammeCategories, isEmpty);
        await tester.pump(const Duration(seconds: 3));
        await tester.pump(const Duration(seconds: 15));
        expect(vm.availableProgrammeCategories, [GuideFilter.kids]);
        await tester.pump(const Duration(minutes: 2));
        expect(reads, 3);
        verify(() => _channelsRequest(api)).called(1);
        verify(() => _guide(api)).called(1);
      },
    );

    testWidgets(
      'showing categories rechecks a missing answer even with cached filters',
      (tester) async {
        _stubChannels(api, [_channel('one')]);
        Set<String>? categories = {'news'};
        when(api.getChannelGroups).thenAnswer(
          (_) async => ChannelGroupLineup(
            const {},
            guideRevision: '1',
            programmeCategories: categories,
          ),
        );
        await vm.load();
        vm.setProgrammeCategoriesVisible(false);
        categories = null;
        await vm.refreshGuide();
        await tester.pump(const Duration(minutes: 2));
        expect(vm.availableProgrammeCategories, [GuideFilter.news]);
        categories = {'sports'};
        vm.setProgrammeCategoriesVisible(true);
        await tester.pump(const Duration(seconds: 3));
        expect(vm.availableProgrammeCategories, [GuideFilter.sports]);
        verify(api.getChannelGroups).called(3);
      },
    );

    testWidgets(
      'category retries are bounded when the server keeps omitting them',
      (tester) async {
        _stubChannels(api, [_channel('one')]);
        when(api.getChannelGroups).thenAnswer(
          (_) async => const ChannelGroupLineup({}, guideRevision: '1'),
        );
        await vm.load();
        for (final seconds in [3, 15, 60, 120]) {
          await tester.pump(Duration(seconds: seconds));
        }
        verify(api.getChannelGroups).called(4);
      },
    );

    test(
      'the legacy fallback restores programme filters after a plugin change',
      () async {
        _stubChannels(api, [_channel('one')]);
        when(api.getChannelGroups).thenAnswer(
          (_) async => const ChannelGroupLineup(
            {},
            programmeCategories: {'sports'},
            guideRevision: '1',
          ),
        );
        await vm.load();
        expect(vm.availableProgrammeCategories, [GuideFilter.sports]);
        when(api.getChannelGroups)
            .thenAnswer((_) async => const ChannelGroupLineup({}));
        await vm.refreshGuide();
        expect(
          vm.availableProgrammeCategories,
          vm.filters.where(
            (f) => f != GuideFilter.all && f != GuideFilter.favorites,
          ),
        );
      },
    );

    for (final denied in [false, true]) {
      test(
        'a late native ${denied ? 'denial' : 'timeout'} leaves a newer import ready',
        () async {
          when(api.getChannelGroups)
              .thenAnswer((_) async => const ChannelGroupLineup({}));
          _stubChannels(api, [_channel('old')]);
          await vm.load();
          final slow = Completer<Map<String, dynamic>>();
          when(() => _channelsRequest(api)).thenAnswer((_) => slow.future);
          final window = vm.windowStart.add(const Duration(hours: 2));
          final returning = vm.load(windowStart: window, livePosition: false);
          _stubChannels(api, [_channel('current')]);
          await vm.refreshGuide();
          expect(vm.state, GuideState.ready);
          final request = RequestOptions(path: '/LiveTv/Channels');
          slow.completeError(
            denied
                ? DioException(
                    requestOptions: request,
                    response: Response(
                      requestOptions: request,
                      statusCode: 403,
                    ),
                  )
                : TimeoutException('superseded native read'),
          );
          await returning;
          expect(vm.state, GuideState.ready);
          expect(vm.error, isNull);
          expect(vm.filteredChannels.single.id, 'current');
          expect(vm.windowStart, window);
          expect(vm.atLivePosition, isFalse);
        },
      );
    }

    test(
      'a native channel edit is visible while group metadata is pending',
      () async {
        _stubChannels(api, [_channel('old')]);
        when(api.getChannelGroups).thenAnswer(
          (_) async => const ChannelGroupLineup(
            {
              'old': {'UK'},
            },
            programmeCategories: {'sports'},
            guideRevision: '1',
          ),
        );
        when(() => _guide(api)).thenAnswer(
          (_) async => {
            'Items': [_program('The game', 'old')],
          },
        );
        await vm.load();
        vm.setGroup('UK');
        _stubChannels(api, [
          {..._channel('old'), 'Name': 'Studio B'},
        ]);
        when(api.getChannelGroups).thenAnswer(
          (_) async => const ChannelGroupLineup({}, guideRevision: 'pending'),
        );
        when(() => _guide(api)).thenAnswer((_) async => {'Items': []});
        await vm.refreshGuide();
        expect(vm.filteredChannels.single.name, 'Studio B');
        expect(vm.selectedGroup, 'UK');
        expect(vm.programsForChannel('old').single.name, 'The game');
        expect(vm.availableProgrammeCategories, [GuideFilter.sports]);
      },
    );

    test('replaces channel IDs and group memberships together', () async {
      _stubChannels(api, [_channel('old'), _channel('outside')]);
      when(api.getChannelGroups).thenAnswer(
        (_) async => ChannelGroupLineup({
          'old': {'Canadian'},
        }, guideRevision: revision),
      );
      await vm.load();
      vm.setGroup('Canadian');
      final date = vm.guideDate.add(const Duration(days: 1));
      await vm.setDate(date);
      revision = '2';
      _stubChannels(api, [_channel('new'), _channel('outside')]);
      final membership = Completer<ChannelGroupLineup>();
      when(api.getChannelGroups).thenAnswer((_) => membership.future);
      final refresh = vm.refreshGuide();
      await Future<void>.delayed(Duration.zero);
      expect(vm.filteredChannels.single.id, 'old');
      membership.complete(
        ChannelGroupLineup({
          'new': {'Canadian'},
        }, guideRevision: revision),
      );
      await refresh;
      expect(vm.selectedGroup, 'Canadian');
      expect(vm.filteredChannels.single.id, 'new');
      expect(vm.channelForId('old'), isNull);
      expect(vm.hasProgramsFor('new'), isTrue);
      expect(vm.guideDate, date);
      expect(vm.atLivePosition, isFalse);
    });

    test('a newer notification supersedes an earlier lineup read', () async {
      _stubChannels(api, [_channel('old')]);
      when(api.getChannelGroups).thenAnswer(
        (_) async => const ChannelGroupLineup({
          'old': {'Canadian'},
        }),
      );
      await vm.load();
      vm.setGroup('Canadian');
      final slow = Completer<ChannelGroupLineup>();
      when(api.getChannelGroups).thenAnswer((_) => slow.future);
      final first = vm.refreshGuide();
      await Future<void>.delayed(Duration.zero);
      _stubChannels(api, [_channel('new')]);
      when(api.getChannelGroups).thenAnswer(
        (_) async => const ChannelGroupLineup({
          'new': {'Canadian'},
        }),
      );
      await vm.refreshGuide();
      slow.complete(const ChannelGroupLineup({}));
      await first;
      expect(vm.selectedGroup, 'Canadian');
      expect(vm.filteredChannels.single.id, 'new');
    });

    test('paging while the guide refreshes keeps the new page', () async {
      _stubChannels(
        api,
        List.generate(120, (i) => _channel('c$i', number: '$i')),
      );
      when(api.getChannelGroups).thenAnswer(
        (_) async => ChannelGroupLineup({}, guideRevision: revision),
      );
      Future<Map<String, dynamic>> result(Invocation inv) async => {
        'Items': [for (final id in _requestedIds(inv)) _program(id, id)],
      };
      when(() => _guide(api)).thenAnswer(result);
      await vm.load();
      revision = '2';
      final delayed = Completer<Map<String, dynamic>>();
      when(() => _guide(api)).thenAnswer(
        (inv) =>
            _requestedIds(inv).contains('c0') ? delayed.future : result(inv),
      );
      final updating = vm.refreshGuide();
      await Future<void>.delayed(Duration.zero);
      await vm.loadMorePrograms();
      expect(vm.programsHighWater, 100);
      expect(vm.hasProgramsFor('c80'), true);
      delayed.complete({'Items': []});
      await updating;
      expect(vm.hasProgramsFor('c80'), true);
    });

    test(
      'an import during a date change restores every browsed page',
      () async {
        _stubChannels(
          api,
          List.generate(120, (i) => _channel('c$i', number: '$i')),
        );
        when(api.getChannelGroups)
            .thenAnswer((_) async => const ChannelGroupLineup({}));
        await vm.load();
        await vm.loadMorePrograms();
        expect(vm.programsHighWater, 100);

        final slow = Completer<Map<String, dynamic>>();
        when(() => _guide(api)).thenAnswer((_) => slow.future);
        final changingDate = vm.setDate(
          vm.guideDate.add(const Duration(days: 1)),
        );
        when(() => _guide(api)).thenAnswer(
          (inv) async => {
            'Items': [for (final id in _requestedIds(inv)) _program('new', id)],
          },
        );
        await vm.refreshGuide();
        slow.complete({'Items': []});
        await changingDate;

        expect(vm.programsHighWater, 100);
        expect(vm.programsForChannel('c99').single.name, 'new');
        expect(vm.state, GuideState.ready);
      },
    );
    test('import notification replaces first-open listings even when all channel IDs match', () async {
      _stubChannels(api, [_channel('one')]);
      final oldGroups = Completer<ChannelGroupLineup>();
      when(api.getChannelGroups).thenAnswer((_) => oldGroups.future);
      when(() => _guide(api)).thenAnswer(
        (_) async => {
          'Items': [_program('Old show', 'one')],
        },
      );
      await vm.load();
      expect(vm.programsForChannel('one').single.name, 'Old show');
      when(api.getChannelGroups).thenAnswer(
        (_) async => const ChannelGroupLineup({
          'one': {'Canada'},
        }),
      );
      when(() => _guide(api)).thenAnswer(
        (_) async => {
          'Items': [_program('New show', 'one')],
        },
      );
      await vm.refreshGuide();
      oldGroups.complete(
        const ChannelGroupLineup({
          'one': {'UK'},
        }),
      );
      await Future<void>.delayed(Duration.zero);
      expect(vm.programsForChannel('one').single.name, 'New show');
      expect(vm.availableGroups, ['Canada']);
    });

    test('a new time window updates the channels in Sports', () async {
      _stubChannels(api, [_channel('a'), _channel('b')]);
      when(api.getChannelGroups).thenAnswer(
        (_) async =>
            const ChannelGroupLineup({}, programmeCategories: {'sports'}),
      );
      var sportsChannel = 'a';
      when(() => _guide(api, category: GuideFilter.sports))
          .thenAnswer(_serverFiltered((id) => id == sportsChannel));
      await vm.load();
      vm.setFilter(GuideFilter.sports);
      await Future<void>.delayed(Duration.zero);
      expect(vm.filteredChannels.single.id, 'a');
      sportsChannel = 'b';
      await vm.setWindowStart(vm.windowStart.add(const Duration(hours: 3)));
      expect(vm.filteredChannels.single.id, 'b');
    });

    for (final leaveSports in [false, true]) {
      test(
        'refreshes Sports results when Sports is ${leaveSports ? 'closed' : 'open'}',
        () async {
          _stubChannels(api, [_channel('one'), _channel('two')]);
          when(api.getChannelGroups).thenAnswer(
            (_) async => ChannelGroupLineup(
              {},
              guideRevision: revision,
              programmeCategories: {'sports'},
            ),
          );
          var sports = 'one';
          when(() => _guide(api, category: GuideFilter.sports))
              .thenAnswer(_serverFiltered((id) => id == sports));
          await vm.load();
          vm.setFilter(GuideFilter.sports);
          await Future<void>.delayed(Duration.zero);
          expect(vm.filteredChannels.single.id, 'one');
          if (leaveSports) vm.setFilter(GuideFilter.all);
          revision = '2';
          sports = 'two';
          await vm.refreshGuide();
          vm.setFilter(GuideFilter.sports);
          await Future<void>.delayed(Duration.zero);
          expect(vm.filteredChannels.single.id, 'two');
        },
      );
    }

    test(
      'retries a partial lineup once it recovers at the same revision',
      () async {
        _stubChannels(api, [_channel('a'), _channel('b')]);
        when(api.getChannelGroups).thenAnswer(
          (_) async => ChannelGroupLineup(
            {
              'a': {'US'},
            },
            partial: true,
            guideRevision: revision,
          ),
        );
        await vm.load();
        when(api.getChannelGroups).thenAnswer(
          (_) async => ChannelGroupLineup({
            'a': {'US'},
            'b': {'Canada'},
          }, guideRevision: revision),
        );
        await vm.refreshGuide();
        expect(vm.availableGroups, ['Canada', 'US']);
        verify(api.getChannelGroups).called(2);
      },
    );
  });

  test('clearing a failed channel search restores the loaded guide', () async {
    _stubChannels(
      liveTv,
      List.generate(90, (i) => _channel('c$i', number: '$i')),
    );
    final vm = LiveTvGuideViewModel(client);
    addTearDown(vm.dispose);
    await vm.load();
    when(() => _guide(liveTv)).thenThrow(TimeoutException('search listings'));
    vm.setChannelQuery('c80');
    await Future<void>.delayed(Duration.zero);
    expect(vm.state, GuideState.error);
    when(() => _guide(liveTv)).thenAnswer((_) async => {'Items': []});
    vm.setChannelQuery('');
    await Future<void>.delayed(Duration.zero);
    expect(vm.state, GuideState.ready);
    expect(vm.error, isNull);
    expect(vm.filteredChannels, hasLength(90));
    expect(vm.hasProgramsFor('c0'), isTrue);
  });

  for (final fails in [false, true]) {
    test(
      'Sports owns the guide when the superseded date reload ${fails ? 'fails' : 'succeeds'}',
      () async {
        _stubChannels(
          liveTv,
          List.generate(120, (i) => _channel('c$i', number: '$i')),
        );
        final vm = LiveTvGuideViewModel(client);
        addTearDown(vm.dispose);
        await vm.load();
        vm.setChannelQuery('c110');
        await Future<void>.delayed(Duration.zero);
        final all = Completer<Map<String, dynamic>>();
        final sports = Completer<Map<String, dynamic>>();
        when(() => _guide(liveTv)).thenAnswer((_) => all.future);
        when(() => _guide(liveTv, category: GuideFilter.sports))
            .thenAnswer((_) => sports.future);
        final change = vm.setDate(vm.guideDate.add(const Duration(days: 1)));
        vm.setFilter(GuideFilter.sports);
        if (fails) {
          all.completeError(TimeoutException('old listings'));
        } else {
          all.complete({'Items': []});
        }
        await change;
        expect(vm.state, GuideState.loading);
        sports.complete({
          'Items': [_program('game', 'c110', isSports: true)],
        });
        await Future<void>.delayed(Duration.zero);
        expect(vm.state, GuideState.ready);
        expect(vm.error, isNull);
        expect(vm.filteredChannels.single.id, 'c110');
      },
    );
  }

  test('unconfirmed guide updates preserve only the current account’s last categories', () async {
    final grouped = _GroupedLiveTvApi();
    when(() => client.liveTvApi).thenReturn(grouped);
    when(() => client.baseUrl).thenReturn('fixture');
    _stubChannels(grouped, [_channel('one')]);
    when(() => _guide(grouped)).thenAnswer((_) async => {'Items': []});
    final vm = LiveTvGuideViewModel(client);
    addTearDown(vm.dispose);
    void reply(ChannelGroupLineup lineup) =>
        when(grouped.getChannelGroups).thenAnswer((_) async => lineup);

    reply(
      const ChannelGroupLineup(
        {},
        programmeCategories: {'sports'},
        guideRevision: '1',
      ),
    );
    await vm.load();
    reply(const ChannelGroupLineup({}, guideRevision: 'pending'));
    await vm.load();
    expect(vm.availableProgrammeCategories, [GuideFilter.sports]);
    when(grouped.getChannelGroups).thenThrow(TimeoutException('fixture'));
    await vm.load();
    expect(vm.availableProgrammeCategories, [GuideFilter.sports]);

    final oldReply = Completer<ChannelGroupLineup>();
    when(grouped.getChannelGroups).thenAnswer((_) => oldReply.future);
    final refresh = vm.refreshGuide();
    await Future<void>.delayed(Duration.zero);
    when(() => client.userId).thenReturn('other-user');
    reply(const ChannelGroupLineup({}, guideRevision: 'pending'));
    await vm.load();
    oldReply.complete(
      const ChannelGroupLineup(
        {},
        programmeCategories: {'sports'},
        guideRevision: '2',
      ),
    );
    await refresh;
    expect(vm.availableProgrammeCategories, isEmpty);
  });

  test(
    'channel search pages the full scoped lineup by name or number without EPG',
    () async {
      final grouped = _GroupedLiveTvApi();
      when(() => client.liveTvApi).thenReturn(grouped);
      when(() => client.baseUrl).thenReturn('fixture');
      _stubChannels(grouped, [
        for (var i = 0; i < 100; i++) _channel('c$i', number: '$i'),
        {
          ..._channel('fox', number: '7002'),
          'UserData': {'IsFavorite': true},
        },
        _channel('fox plus', number: '7041'),
      ]);
      when(grouped.getChannelGroups).thenAnswer(
        (_) async => const ChannelGroupLineup({
          'fox': {'US'},
          'fox plus': {'CA'},
        }),
      );
      final pages = <List<String>>[];
      when(() => _guide(grouped)).thenAnswer((inv) async {
        pages.add(_requestedIds(inv));
        return {'Items': []};
      });
      final vm = LiveTvGuideViewModel(client);
      addTearDown(vm.dispose);
      await vm.load();
      vm.setChannelQuery(' FOX ');
      await Future<void>.delayed(Duration.zero);
      expect(vm.filteredChannels.map((c) => c.id), ['fox', 'fox plus']);
      expect(pages.last, ['fox', 'fox plus']);
      vm.setGroup('CA');
      expect(vm.filteredChannels.single.id, 'fox plus');
      vm.setChannelQuery('7002');
      expect(vm.filteredChannels, isEmpty);
      vm.setFilter(GuideFilter.favorites);
      expect(vm.filteredChannels.single.id, 'fox');
      vm.setFilter(GuideFilter.all);
      vm.setChannelQuery('');
      expect(vm.filteredChannels.length, 102);
    },
  );

  test(
    'category search checks matching channels beyond the first category page',
    () async {
      _stubChannels(liveTv, [
        for (var i = 0; i < 480; i++) _channel('c$i', number: '$i'),
      ]);
      when(() => _guide(liveTv, category: GuideFilter.sports))
          .thenAnswer(_serverFiltered((id) => id != 'c476'));
      final vm = LiveTvGuideViewModel(client);
      addTearDown(vm.dispose);
      await vm.load();
      vm.setFilter(GuideFilter.sports);
      await Future<void>.delayed(Duration.zero);
      expect(vm.filteredChannels.any((c) => c.id == 'c475'), false);
      vm.setChannelQuery('47');
      await Future<void>.delayed(Duration.zero);
      expect(vm.filteredChannels.map((c) => c.id), contains('c475'));
      expect(vm.filteredChannels.map((c) => c.id), isNot(contains('c476')));
      vm.setFilter(GuideFilter.all);
      vm.setChannelQuery('310');
      vm.setFilter(GuideFilter.sports);
      await Future<void>.delayed(Duration.zero);
      expect(vm.filteredChannels.single.id, 'c310');
    },
  );

  test('channel groups page by channel and keep every programme', () async {
    final grouped = _GroupedLiveTvApi();
    when(() => client.liveTvApi).thenReturn(grouped);
    when(() => client.baseUrl).thenReturn('fixture');
    final channels = [
      for (var i = 0; i < 200; i++) _channel('c$i', number: '$i'),
    ];
    _stubChannels(grouped, channels);
    when(grouped.getChannelGroups).thenAnswer(
      (_) async => ChannelGroupLineup({
        for (var i = 100; i < 162; i++) 'c$i': {'US| SPORTS', 'Kids'},
        'invisible': {'private group'},
      }),
    );
    final pages = <List<String>>[];
    when(() => _guide(grouped)).thenAnswer((inv) async {
      final ids = _requestedIds(inv);
      pages.add(ids);
      return {
        'Items': [
          for (final id in ids) ...[
            _program('news-$id', id),
            _program('sport-$id', id, isSports: true),
          ],
        ],
      };
    });
    final vm = LiveTvGuideViewModel(client);
    addTearDown(vm.dispose);
    await vm.load();
    expect(vm.availableGroups, ['Kids', 'US| SPORTS']);
    vm.setGroup('US| SPORTS');
    await Future<void>.delayed(Duration.zero);
    expect(
      vm.filteredChannels.map((c) => c.id),
      channels.skip(100).take(62).map((c) => c['Id']),
    );
    expect(vm.programsForChannel('c100').map((p) => p.name), [
      'news-c100',
      'sport-c100',
    ]);
    expect(vm.programsHighWater, 50);
    await vm.loadMorePrograms();
    expect(vm.hasMorePrograms, false);
    expect(pages.map((p) => p.length), [50, 50, 12]);
    expect(pages.last.first, 'c150');
    vm.setGroup('Kids');
    await Future<void>.delayed(Duration.zero);
    expect(pages.length, 3);
    verify(grouped.getChannelGroups).called(1);
    when(grouped.getChannelGroups)
        .thenAnswer((_) async => const ChannelGroupLineup({}));
    await vm.load();
    expect(vm.selectedGroup, isNull);
    expect(vm.filteredChannels.length, 200);
  });

  test(
    'a group survives new channel IDs until a complete lineup removes it',
    () async {
      final api = _GroupedLiveTvApi();
      when(() => client.liveTvApi).thenReturn(api);
      when(() => client.baseUrl).thenReturn('fixture');
      when(() => _guide(api)).thenAnswer((_) async => {'Items': []});
      _stubChannels(api, [_channel('old'), _channel('outside')]);
      when(api.getChannelGroups).thenAnswer(
        (_) async => const ChannelGroupLineup({
          'old': {'Canadian'},
        }),
      );
      final vm = LiveTvGuideViewModel(client);
      addTearDown(vm.dispose);
      await vm.load();
      vm.setGroup('Canadian');

      when(api.getChannelGroups).thenThrow(TimeoutException('lineup'));
      await vm.load();
      expect(vm.filteredChannels.map((c) => c.id), ['old']);
      expect(vm.selectedGroup, 'Canadian');

      _stubChannels(api, [_channel('new'), _channel('outside')]);
      final pending = Completer<ChannelGroupLineup>();
      when(api.getChannelGroups).thenAnswer((_) => pending.future);
      await vm.load();
      expect(vm.selectedGroup, 'Canadian');
      expect(vm.availableGroups, contains('Canadian'));
      expect(vm.filteredChannels, isEmpty);
      pending.complete(
        const ChannelGroupLineup({
          'outside': {'News'},
        }, partial: true),
      );
      await Future<void>.delayed(Duration.zero);
      expect(vm.selectedGroup, 'Canadian');
      expect(vm.filteredChannels, isEmpty);
      expect(vm.channelCountForGroup('News'), 1);

      when(api.getChannelGroups).thenAnswer(
        (_) async => const ChannelGroupLineup({
          'new': {'Canadian'},
        }),
      );
      await vm.load();
      expect(vm.selectedGroup, 'Canadian');
      expect(vm.filteredChannels.map((c) => c.id), ['new']);
      await Future<void>.delayed(Duration.zero);
      expect(vm.hasProgramsFor('new'), isTrue);

      when(api.getChannelGroups).thenAnswer(
        (_) async => const ChannelGroupLineup({
          'outside': {'News'},
        }),
      );
      await vm.load();
      expect(vm.selectedGroup, isNull);
      expect(vm.availableGroups, ['News']);
      expect(vm.filteredChannels.map((c) => c.id), ['new', 'outside']);
    },
  );

  test(
    'a failed or superseded group lookup leaves the current guide usable',
    () async {
      final grouped = _GroupedLiveTvApi();
      when(() => client.liveTvApi).thenReturn(grouped);
      when(() => client.baseUrl).thenReturn('fixture');
      _stubChannels(grouped, [_channel('one')]);
      when(() => _guide(grouped)).thenAnswer((_) async => {'Items': []});
      when(grouped.getChannelGroups).thenAnswer(
        (_) async => const ChannelGroupLineup({
          'one': {'old group'},
        }),
      );
      final vm = LiveTvGuideViewModel(client);
      addTearDown(vm.dispose);
      await vm.load();
      vm.setGroup('old group');
      final pending = Completer<ChannelGroupLineup>();
      when(grouped.getChannelGroups).thenAnswer((_) => pending.future);
      await vm.load();
      expect(vm.selectedGroup, 'old group');
      when(() => client.userId).thenReturn('other');
      when(grouped.getChannelGroups).thenThrow(StateError('forbidden'));
      await vm.load();
      pending.complete(
        const ChannelGroupLineup({
          'one': {'old group'},
        }),
      );
      await Future<void>.delayed(Duration.zero);
      expect(vm.availableGroups, isEmpty);
      expect(vm.selectedGroup, isNull);
      expect(vm.filteredChannels.single.id, 'one');
      expect(vm.state, GuideState.ready);
    },
  );

  test('load() fetches only the first batch; loadMorePrograms() paginates the rest', () async {
    // 120 channels → batches of 50 (never one giant all-channels request).
    final channels = List.generate(120, (i) => _channel('c$i'));
    when(
      () => liveTv.getChannels(
        sortBy: any(named: 'sortBy'),
        sortOrder: any(named: 'sortOrder'),
        fields: any(named: 'fields'),
        enableTotalRecordCount: any(named: 'enableTotalRecordCount'),
        userId: any(named: 'userId'),
      ),
    ).thenAnswer((_) async => {'Items': channels});

    final vm = LiveTvGuideViewModel(client);
    await vm.load();

    // Initial load requested exactly one batch of 50 channels, not all 120.
    final captured = verify(
      () => liveTv.getGuide(
        startDate: any(named: 'startDate'),
        endDate: any(named: 'endDate'),
        channelIds: captureAny(named: 'channelIds'),
        fields: any(named: 'fields'),
        enableTotalRecordCount: any(named: 'enableTotalRecordCount'),
        enableImages: any(named: 'enableImages'),
        enableUserData: any(named: 'enableUserData'),
        userId: any(named: 'userId'),
      ),
    ).captured;
    expect(captured.length, 1);
    expect((captured.single as List).length, 50);
    expect(vm.programsHighWater, 50);
    expect(vm.hasMorePrograms, isTrue);

    await vm.loadMorePrograms();
    expect(vm.programsHighWater, 100);
    expect(vm.hasMorePrograms, isTrue);

    await vm.loadMorePrograms();
    expect(vm.programsHighWater, 120);
    expect(vm.hasMorePrograms, isFalse);

    // Further calls are no-ops once every channel has been requested.
    await vm.loadMorePrograms();
    expect(vm.programsHighWater, 120);
  });

  test('a stale response for a superseded window is discarded', () async {
    final pending = <Completer<Map<String, dynamic>>>[];
    when(
      () => liveTv.getGuide(
        startDate: any(named: 'startDate'),
        endDate: any(named: 'endDate'),
        channelIds: any(named: 'channelIds'),
        fields: any(named: 'fields'),
        enableTotalRecordCount: any(named: 'enableTotalRecordCount'),
        enableImages: any(named: 'enableImages'),
        enableUserData: any(named: 'enableUserData'),
        userId: any(named: 'userId'),
      ),
    ).thenAnswer((_) {
      final completer = Completer<Map<String, dynamic>>();
      pending.add(completer);
      return completer.future;
    });

    final vm = LiveTvGuideViewModel(client);
    final early = DateTime(2026, 9, 9, 20);
    final later = early.add(const Duration(hours: 3));

    final superseded = vm.replacePrograms(
      channelIds: const ['c1'],
      from: early,
      to: later,
    );
    await pumpEventQueue();
    final current = vm.replacePrograms(
      channelIds: const ['c1'],
      from: later,
      to: later.add(const Duration(hours: 3)),
    );
    await pumpEventQueue();

    expect(pending.length, 2);
    pending[1].complete({
      'Items': [_program('current', 'c1', start: later)],
    });
    await current;
    // The first window's reply lands last and must not overwrite the second.
    pending[0].complete({
      'Items': [_program('stale', 'c1', start: early)],
    });
    await superseded;

    expect(vm.programsForChannel('c1').map((p) => p.id), ['current']);
  });

  test('a stale lazy batch cannot merge into a reloaded window', () async {
    when(
      () => liveTv.getChannels(
        sortBy: any(named: 'sortBy'),
        sortOrder: any(named: 'sortOrder'),
        fields: any(named: 'fields'),
        enableTotalRecordCount: any(named: 'enableTotalRecordCount'),
        userId: any(named: 'userId'),
      ),
    ).thenAnswer(
      (_) async => {
        'Items': [_channel('c1')],
      },
    );
    final pending = <Completer<Map<String, dynamic>>>[];
    when(
      () => liveTv.getGuide(
        startDate: any(named: 'startDate'),
        endDate: any(named: 'endDate'),
        channelIds: any(named: 'channelIds'),
        fields: any(named: 'fields'),
        enableTotalRecordCount: any(named: 'enableTotalRecordCount'),
        enableImages: any(named: 'enableImages'),
        enableUserData: any(named: 'enableUserData'),
        userId: any(named: 'userId'),
      ),
    ).thenAnswer((_) {
      final completer = Completer<Map<String, dynamic>>();
      pending.add(completer);
      return completer.future;
    });

    final vm = LiveTvGuideViewModel(client);
    final early = DateTime(2026, 9, 9, 20);
    final later = early.add(const Duration(hours: 3));
    final superseded = vm.load(windowStart: early);
    await pumpEventQueue();
    final current = vm.load(windowStart: later);
    await pumpEventQueue();

    expect(pending, hasLength(2));
    pending[1].complete({
      'Items': [_program('current', 'c1', start: later)],
    });
    await current;
    pending[0].complete({
      'Items': [_program('stale', 'c1', start: early)],
    });
    await superseded;

    expect(vm.programsForChannel('c1').map((p) => p.id), ['current']);
    expect(vm.programsHighWater, 1);
  });

  test('targeted replacement leaves unrelated channels untouched', () async {
    when(
      () => liveTv.getChannels(
        sortBy: any(named: 'sortBy'),
        sortOrder: any(named: 'sortOrder'),
        fields: any(named: 'fields'),
        enableTotalRecordCount: any(named: 'enableTotalRecordCount'),
        userId: any(named: 'userId'),
      ),
    ).thenAnswer(
      (_) async => {
        'Items': [_channel('c0'), _channel('c1')],
      },
    );

    final start = DateTime(2026, 9, 9, 20);
    void stubGuide(String prefix) {
      when(
        () => liveTv.getGuide(
          startDate: any(named: 'startDate'),
          endDate: any(named: 'endDate'),
          channelIds: any(named: 'channelIds'),
          fields: any(named: 'fields'),
          enableTotalRecordCount: any(named: 'enableTotalRecordCount'),
          enableImages: any(named: 'enableImages'),
          enableUserData: any(named: 'enableUserData'),
          userId: any(named: 'userId'),
        ),
      ).thenAnswer((invocation) async {
        final ids = invocation.namedArguments[#channelIds] as List<String>;
        return {
          'Items': [
            for (final id in ids) _program('$prefix-$id', id, start: start),
          ],
        };
      });
    }

    stubGuide('old');
    final vm = LiveTvGuideViewModel(client);
    await vm.load();
    expect(vm.programsForChannel('c0').single.id, 'old-c0');

    stubGuide('new');
    await vm.replacePrograms(
      channelIds: const ['c1'],
      from: start,
      to: start.add(const Duration(hours: 3)),
    );

    expect(vm.programsForChannel('c0').single.id, 'old-c0');
    expect(vm.programsForChannel('c1').single.id, 'new-c1');
    expect(vm.state, GuideState.ready);
  });

  test('a targeted initial load requests only the named channels', () async {
    final channels = List.generate(120, (i) => _channel('c$i'));
    when(
      () => liveTv.getChannels(
        sortBy: any(named: 'sortBy'),
        sortOrder: any(named: 'sortOrder'),
        fields: any(named: 'fields'),
        enableTotalRecordCount: any(named: 'enableTotalRecordCount'),
        userId: any(named: 'userId'),
      ),
    ).thenAnswer((_) async => {'Items': channels});

    final vm = LiveTvGuideViewModel(client);
    await vm.load(initialChannelIds: const ['c7', 'c9']);

    final captured = verify(
      () => liveTv.getGuide(
        startDate: any(named: 'startDate'),
        endDate: any(named: 'endDate'),
        channelIds: captureAny(named: 'channelIds'),
        fields: any(named: 'fields'),
        enableTotalRecordCount: any(named: 'enableTotalRecordCount'),
        enableImages: any(named: 'enableImages'),
        enableUserData: any(named: 'enableUserData'),
        userId: any(named: 'userId'),
      ),
    ).captured;
    expect(captured.length, 1);
    expect(captured.single, ['c7', 'c9']);
    // The ordered scroll prefix is untouched by a targeted open.
    expect(vm.programsHighWater, 0);
  });

  test(
    'moving the window replaces loaded rows without a loading state',
    () async {
      when(
        () => liveTv.getChannels(
          sortBy: any(named: 'sortBy'),
          sortOrder: any(named: 'sortOrder'),
          fields: any(named: 'fields'),
          enableTotalRecordCount: any(named: 'enableTotalRecordCount'),
          userId: any(named: 'userId'),
        ),
      ).thenAnswer(
        (_) async => {
          'Items': [_channel('c0')],
        },
      );

      final firstStart = DateTime(2026, 9, 9, 20);
      final secondStart = firstStart.add(const Duration(minutes: 30));
      final replacement = Completer<Map<String, dynamic>>();
      var call = 0;
      when(
        () => liveTv.getGuide(
          startDate: any(named: 'startDate'),
          endDate: any(named: 'endDate'),
          channelIds: any(named: 'channelIds'),
          fields: any(named: 'fields'),
          enableTotalRecordCount: any(named: 'enableTotalRecordCount'),
          enableImages: any(named: 'enableImages'),
          enableUserData: any(named: 'enableUserData'),
          userId: any(named: 'userId'),
        ),
      ).thenAnswer((_) {
        call++;
        if (call == 1) {
          return Future.value({
            'Items': [_program('old', 'c0', start: firstStart)],
          });
        }
        return replacement.future;
      });

      final vm = LiveTvGuideViewModel(client);
      await vm.load(windowStart: firstStart);
      final moving = vm.setWindowStart(secondStart);
      await pumpEventQueue();

      expect(vm.state, GuideState.ready);
      expect(vm.windowStart, secondStart);
      expect(vm.programsForChannel('c0').single.id, 'old');

      replacement.complete({
        'Items': [_program('new', 'c0', start: secondStart)],
      });
      await moving;
      expect(vm.programsForChannel('c0').single.id, 'new');
    },
  );

  group('program-end boundary refresh', () {
    final base = DateTime.now();
    late DateTime clock;
    late int guideCalls;
    late List<Map<String, dynamic>> items;
    late List<DateTime> requestedFrom;
    late List<DateTime> requestedTo;
    late List<List<String>> requestedChannelIds;
    late bool guideThrows;

    DateTime at(int minutes) => base.add(Duration(minutes: minutes));

    setUp(() {
      clock = base;
      guideCalls = 0;
      guideThrows = false;
      items = <Map<String, dynamic>>[];
      requestedFrom = <DateTime>[];
      requestedTo = <DateTime>[];
      requestedChannelIds = <List<String>>[];

      when(
        () => liveTv.getChannels(
          sortBy: any(named: 'sortBy'),
          sortOrder: any(named: 'sortOrder'),
          fields: any(named: 'fields'),
          enableTotalRecordCount: any(named: 'enableTotalRecordCount'),
          userId: any(named: 'userId'),
        ),
      ).thenAnswer(
        (_) async => {
          'Items': [_channel('c0')],
        },
      );

      when(
        () => liveTv.getGuide(
          startDate: any(named: 'startDate'),
          endDate: any(named: 'endDate'),
          channelIds: any(named: 'channelIds'),
          fields: any(named: 'fields'),
          enableTotalRecordCount: any(named: 'enableTotalRecordCount'),
          enableImages: any(named: 'enableImages'),
          enableUserData: any(named: 'enableUserData'),
          userId: any(named: 'userId'),
        ),
      ).thenAnswer((invocation) async {
        guideCalls++;
        requestedFrom.add(invocation.namedArguments[#startDate] as DateTime);
        requestedTo.add(invocation.namedArguments[#endDate] as DateTime);
        requestedChannelIds.add(
          List<String>.from(
            invocation.namedArguments[#channelIds] as List<String>,
          ),
        );
        if (guideThrows) throw StateError('guide unavailable');
        return {'Items': List<Map<String, dynamic>>.from(items)};
      });
    });

    // A retained ended program plus one airing program. The schedule stops at
    // at(30), so a refresh past that boundary genuinely needs extending.
    void seedLapsingSchedule() {
      items = [
        _span('ended', 'c0', at(-90), at(-60)),
        _span('airing', 'c0', at(-60), at(30)),
      ];
    }

    test('the boundary is the next future end, not the retained minimum', () {
      seedLapsingSchedule();
      final vm = LiveTvGuideViewModel(client, now: () => clock);
      return vm.load().then((_) {
        vm.scheduleBoundaryRefresh();
        // at(-60) is retained by the back-slice and must never be selected.
        expect(vm.boundaryDueAt, at(30));
        vm.cancelBoundaryRefresh();
      });
    });

    test(
      'a cached future start promotes without a future-guide reload',
      () async {
        items = [_span('upcoming', 'c0', at(30), at(60))];
        final vm = LiveTvGuideViewModel(client, now: () => clock);
        await vm.load(windowStart: at(90), livePosition: false);

        vm.scheduleBoundaryRefresh();
        expect(vm.boundaryDueAt, at(30));

        clock = at(31);
        await vm.handleBoundaryElapsed();

        expect(guideCalls, 1);
        expect(vm.boundaryDueAt, at(60));
        vm.cancelBoundaryRefresh();
      },
    );

    test('an elapsed boundary refreshes exactly once, not in a loop', () async {
      seedLapsingSchedule();
      final vm = LiveTvGuideViewModel(client, now: () => clock);
      await vm.load();
      vm.scheduleBoundaryRefresh();
      expect(guideCalls, 1);

      clock = at(31);
      await vm.handleBoundaryElapsed();
      await pumpEventQueue();

      // The server returns the same retained programs. One request, no storm.
      expect(guideCalls, 2);
      expect(vm.programsForChannel('c0').map((p) => p.id), ['ended', 'airing']);
      // Both past boundaries are processed, so neither can be selected again.
      expect(vm.nextBoundaryAt, isNull);
      vm.cancelBoundaryRefresh();
    });

    test('no newer coverage arms the retry delay', () async {
      seedLapsingSchedule();
      final vm = LiveTvGuideViewModel(client, now: () => clock);
      await vm.load();
      vm.scheduleBoundaryRefresh();

      clock = at(31);
      await vm.handleBoundaryElapsed();

      expect(
        vm.boundaryDueAt,
        at(31).add(LiveTvGuideViewModel.noNewCoverageRetry),
      );
      vm.cancelBoundaryRefresh();
    });

    test('a cached next program promotes with no request', () async {
      items = [
        _span('ended', 'c0', at(-90), at(-60)),
        _span('airing', 'c0', at(-60), at(30)),
        _span('next', 'c0', at(30), at(90)),
      ];
      final vm = LiveTvGuideViewModel(client, now: () => clock);
      await vm.load();
      vm.scheduleBoundaryRefresh();
      expect(guideCalls, 1);

      clock = at(31);
      await vm.handleBoundaryElapsed();

      expect(guideCalls, 1);
      expect(vm.boundaryDueAt, at(90));
      vm.cancelBoundaryRefresh();
    });

    test(
      'boundary refresh preserves the viewport and covers live horizon',
      () async {
        seedLapsingSchedule();
        final vm = LiveTvGuideViewModel(client, now: () => clock);
        await vm.load(windowStart: at(-360));
        vm.scheduleBoundaryRefresh();

        clock = at(31);
        items = [...items, _span('next', 'c0', at(30), at(200))];
        await vm.handleBoundaryElapsed();

        expect(requestedFrom.last, vm.windowStart);
        expect(
          requestedTo.last,
          at(31).add(LiveTvGuideViewModel.rollingRefreshHorizon),
        );
        expect(vm.boundaryDueAt, at(200));
        vm.cancelBoundaryRefresh();
      },
    );

    test(
      'rolling refresh reanchors beyond cached coverage in one bounded window',
      () async {
        when(
          () => liveTv.getChannels(
            sortBy: any(named: 'sortBy'),
            sortOrder: any(named: 'sortOrder'),
            fields: any(named: 'fields'),
            enableTotalRecordCount: any(named: 'enableTotalRecordCount'),
            userId: any(named: 'userId'),
          ),
        ).thenAnswer(
          (_) async => {
            'Items': [_channel('c0'), _channel('c1')],
          },
        );
        items = [
          _span('old-0', 'c0', at(-60), at(30)),
          _span('old-1', 'c1', at(-60), at(30)),
        ];
        final vm = LiveTvGuideViewModel(client, now: () => clock);
        await vm.load();

        // The cache ends before the current clock. Staleness is coverage-based.
        clock = at(45);
        items = [
          _span('new-0', 'c0', at(35), at(90)),
          _span('new-1', 'c1', at(35), at(90)),
        ];
        await vm.refreshCarouselPrograms();

        expect(guideCalls, 2);
        expect(requestedChannelIds.last, containsAll(<String>['c0', 'c1']));
        expect(
          requestedFrom.last,
          at(45).subtract(LiveTvGuideViewModel.rollingRefreshLookback),
        );
        expect(
          requestedTo.last,
          at(45).add(LiveTvGuideViewModel.rollingRefreshHorizon),
        );
        expect(vm.programsForChannel('c0').single.id, 'new-0');
        expect(vm.programsForChannel('c1').single.id, 'new-1');
        vm.cancelBoundaryRefresh();
      },
    );

    test('overlapping rolling refresh calls share one request', () async {
      seedLapsingSchedule();
      final vm = LiveTvGuideViewModel(client, now: () => clock);
      await vm.load();

      final reply = Completer<Map<String, dynamic>>();
      when(() => _guide(liveTv)).thenAnswer((_) {
        guideCalls++;
        return reply.future;
      });

      final first = vm.refreshCarouselPrograms();
      await pumpEventQueue();
      final second = vm.refreshCarouselPrograms();

      expect(second, same(first));
      expect(guideCalls, 2);
      reply.complete({
        'Items': [_span('new', 'c0', at(-10), at(90))],
      });
      await Future.wait([first, second]);

      expect(vm.programsForChannel('c0').single.id, 'new');
      vm.cancelBoundaryRefresh();
    });

    test('a superseding replacement rejects a stale rolling reply', () async {
      seedLapsingSchedule();
      final vm = LiveTvGuideViewModel(client, now: () => clock);
      await vm.load();

      final pending = <Completer<Map<String, dynamic>>>[];
      when(() => _guide(liveTv)).thenAnswer((_) {
        final reply = Completer<Map<String, dynamic>>();
        pending.add(reply);
        return reply.future;
      });

      vm.scheduleBoundaryRefresh();
      final rolling = vm.refreshCarouselPrograms();
      await pumpEventQueue();
      final replacement = vm.replacePrograms(
        channelIds: const ['c0'],
        from: at(0),
        to: at(90),
      );
      await pumpEventQueue();

      expect(pending, hasLength(2));
      pending[1].complete({
        'Items': [_span('current', 'c0', at(-10), at(90))],
      });
      await replacement;
      pending[0].complete({
        'Items': [_span('stale', 'c0', at(-10), at(60))],
      });
      await rolling;

      expect(vm.programsForChannel('c0').single.id, 'current');
      expect(vm.boundaryDueAt, at(90));
      vm.cancelBoundaryRefresh();
    });

    test('a failed rolling refresh preserves the existing cache', () async {
      seedLapsingSchedule();
      final vm = LiveTvGuideViewModel(client, now: () => clock);
      await vm.load();

      guideThrows = true;
      await vm.refreshCarouselPrograms();

      expect(vm.programsForChannel('c0').map((p) => p.id), ['ended', 'airing']);
      expect(vm.boundaryDueAt, clock.add(LiveTvGuideViewModel.failureBackoff));
      vm.cancelBoundaryRefresh();
    });

    test('a disposed view model ignores a rolling refresh request', () async {
      seedLapsingSchedule();
      final vm = LiveTvGuideViewModel(client, now: () => clock);
      await vm.load();
      clearInteractions(liveTv);

      vm.dispose();
      await vm.refreshCarouselPrograms();

      verifyNever(
        () => liveTv.getGuide(
          startDate: any(named: 'startDate'),
          endDate: any(named: 'endDate'),
          channelIds: any(named: 'channelIds'),
          fields: any(named: 'fields'),
          enableTotalRecordCount: any(named: 'enableTotalRecordCount'),
          enableImages: any(named: 'enableImages'),
          enableUserData: any(named: 'enableUserData'),
          userId: any(named: 'userId'),
        ),
      );
    });

    test('a failed refresh backs off and keeps the data', () async {
      seedLapsingSchedule();
      final vm = LiveTvGuideViewModel(client, now: () => clock);
      await vm.load();
      vm.scheduleBoundaryRefresh();

      clock = at(31);
      guideThrows = true;
      await vm.handleBoundaryElapsed();

      expect(vm.programsForChannel('c0').map((p) => p.id), ['ended', 'airing']);
      expect(vm.boundaryDueAt, at(31).add(LiveTvGuideViewModel.failureBackoff));
      vm.cancelBoundaryRefresh();
    });

    test('a boundary passed while suspended refreshes on resume', () async {
      seedLapsingSchedule();
      final vm = LiveTvGuideViewModel(client, now: () => clock);
      await vm.load();
      vm.scheduleBoundaryRefresh();

      // The timer couldn't fire while the app was suspended.
      clock = at(45);
      vm.scheduleBoundaryRefresh();
      await pumpEventQueue();

      expect(guideCalls, 2);
      vm.cancelBoundaryRefresh();
    });

    test('an empty schedule arms no timer', () async {
      items = <Map<String, dynamic>>[];
      final vm = LiveTvGuideViewModel(client, now: () => clock);
      await vm.load();
      vm.scheduleBoundaryRefresh();

      expect(vm.boundaryDueAt, isNull);
      expect(guideCalls, 1);
    });

    test('an all-expired schedule refreshes immediately once', () async {
      items = [_span('expired', 'c0', at(-90), at(-30))];
      final vm = LiveTvGuideViewModel(client, now: () => clock);
      await vm.load();

      vm.scheduleBoundaryRefresh();
      await pumpEventQueue();

      expect(guideCalls, 2);
      expect(
        vm.boundaryDueAt,
        clock.add(LiveTvGuideViewModel.noNewCoverageRetry),
      );
      vm.cancelBoundaryRefresh();
    });
  });

  group('re-entry and exit', () {
    setUp(() {
      when(
        () => liveTv.getChannels(
          sortBy: any(named: 'sortBy'),
          sortOrder: any(named: 'sortOrder'),
          fields: any(named: 'fields'),
          enableTotalRecordCount: any(named: 'enableTotalRecordCount'),
          userId: any(named: 'userId'),
        ),
      ).thenAnswer(
        (_) async => {
          'Items': [_channel('c0')],
        },
      );
    });

    test(
      're-entry with a window over 30 minutes stale forces a reload',
      () async {
        var clock = DateTime(2026, 9, 9, 20);
        final vm = LiveTvGuideViewModel(client, now: () => clock);
        await vm.load();
        clearInteractions(liveTv);

        clock = clock.add(const Duration(minutes: 31));
        await vm.reloadIfStale();

        verify(
          () => liveTv.getGuide(
            startDate: any(named: 'startDate'),
            endDate: any(named: 'endDate'),
            channelIds: any(named: 'channelIds'),
            fields: any(named: 'fields'),
            enableTotalRecordCount: any(named: 'enableTotalRecordCount'),
            enableImages: any(named: 'enableImages'),
            enableUserData: any(named: 'enableUserData'),
            userId: any(named: 'userId'),
          ),
        ).called(1);
        // A forced reload recomputes the window from the current clock.
        expect(vm.windowStart, DateTime(2026, 9, 9, 20));
      },
    );

    test('re-entry within 30 minutes does not reload', () async {
      var clock = DateTime(2026, 9, 9, 20);
      final vm = LiveTvGuideViewModel(client, now: () => clock);
      await vm.load();
      clearInteractions(liveTv);

      clock = clock.add(const Duration(minutes: 29));
      await vm.reloadIfStale();

      verifyNever(
        () => liveTv.getGuide(
          startDate: any(named: 'startDate'),
          endDate: any(named: 'endDate'),
          channelIds: any(named: 'channelIds'),
          fields: any(named: 'fields'),
          enableTotalRecordCount: any(named: 'enableTotalRecordCount'),
          enableImages: any(named: 'enableImages'),
          enableUserData: any(named: 'enableUserData'),
          userId: any(named: 'userId'),
        ),
      );
    });

    test('exiting a paged-ahead session resets the window to now', () async {
      var clock = DateTime(2026, 9, 9, 20);
      final vm = LiveTvGuideViewModel(client, now: () => clock);
      await vm.load();

      await vm.shiftWindow(const Duration(hours: 6));
      expect(vm.windowStart, DateTime(2026, 9, 9, 26));

      clock = clock.add(const Duration(hours: 2));
      vm.resetWindowOnExit();

      expect(vm.windowStart, DateTime(2026, 9, 9, 22));
      expect(vm.windowEnd, DateTime(2026, 9, 10, 0, 30));
      expect(vm.guideDate, clock);
    });

    test('a reset window is reloaded on the next entry', () async {
      var clock = DateTime(2026, 9, 9, 20);
      final vm = LiveTvGuideViewModel(client, now: () => clock);
      await vm.load();
      await vm.shiftWindow(const Duration(hours: 3));

      final liveStart = DateTime(2026, 9, 9, 21, 45);
      clock = DateTime(2026, 9, 9, 22);
      vm.resetWindowOnExit(windowStart: liveStart);
      clearInteractions(liveTv);

      await vm.reloadIfStale(windowStart: liveStart);

      verify(
        () => liveTv.getGuide(
          startDate: liveStart,
          endDate: any(named: 'endDate'),
          channelIds: any(named: 'channelIds'),
          fields: any(named: 'fields'),
          enableTotalRecordCount: any(named: 'enableTotalRecordCount'),
          enableImages: any(named: 'enableImages'),
          enableUserData: any(named: 'enableUserData'),
          userId: any(named: 'userId'),
        ),
      ).called(1);
    });
  });

  group('recording defaults carry the program id', () {
    setUp(() {
      when(
        () => liveTv.getChannels(
          sortBy: any(named: 'sortBy'),
          sortOrder: any(named: 'sortOrder'),
          fields: any(named: 'fields'),
          enableTotalRecordCount: any(named: 'enableTotalRecordCount'),
          userId: any(named: 'userId'),
        ),
      ).thenAnswer(
        (_) async => {
          'Items': [_channel('c0')],
        },
      );
      when(() => liveTv.createTimer(any())).thenAnswer((_) async {});
    });

    test(
      'toggleProgramRecording creates a timer for the program\'s own id',
      () async {
        final vm = LiveTvGuideViewModel(client);
        await vm.load();

        final program = GuideProgram(
          id: 'program-42',
          channelId: 'c0',
          name: 'Test',
          startDate: DateTime(2026, 9, 9, 20),
          endDate: DateTime(2026, 9, 9, 21),
          rawData: const {},
        );
        await vm.toggleProgramRecording(program);

        verify(() => liveTv.createTimer('program-42')).called(1);
      },
    );
  });

  test(
    'favoriting re-sorts only when the sort reads the favorite flag',
    () async {
      final channels = [
        {'Id': 'c1', 'Name': 'Ch 1', 'ChannelNumber': '1'},
        {'Id': 'c2', 'Name': 'Ch 2', 'ChannelNumber': '2'},
        {'Id': 'c3', 'Name': 'Ch 3', 'ChannelNumber': '3'},
      ];
      when(
        () => liveTv.getChannels(
          sortBy: any(named: 'sortBy'),
          sortOrder: any(named: 'sortOrder'),
          fields: any(named: 'fields'),
          enableTotalRecordCount: any(named: 'enableTotalRecordCount'),
          userId: any(named: 'userId'),
        ),
      ).thenAnswer((_) async => {'Items': channels});
      final userLibrary = _MockUserLibraryApi();
      when(() => client.userLibraryApi).thenReturn(userLibrary);
      when(() => userLibrary.markFavorite(any())).thenAnswer((_) async {});

      final byNumber = LiveTvGuideViewModel(
        client,
        initialSortBy: ChannelSortBy.number,
      );
      await byNumber.load();
      await byNumber.toggleChannelFavorite('c3');
      expect(byNumber.filteredChannels.map((c) => c.id), ['c1', 'c2', 'c3']);

      userDataSync.reset();
      final favoritesFirst = LiveTvGuideViewModel(
        client,
        initialSortBy: ChannelSortBy.favoritesFirst,
      );
      await favoritesFirst.load();
      await favoritesFirst.toggleChannelFavorite('c3');
      expect(favoritesFirst.filteredChannels.map((c) => c.id), [
        'c3',
        'c1',
        'c2',
      ]);
    },
  );

  test('channel favorites follow user-data updates and the favorites filter', () async {
    _stubChannels(liveTv, [_channel('c1'), _channel('c2')]);
    final vm = LiveTvGuideViewModel(client);
    await vm.load();
    vm.setFilter(GuideFilter.favorites);
    expect(vm.filteredChannels, isEmpty);

    userDataSync.publish('c2', {'IsFavorite': true});
    vm.syncChannelUserData();
    expect(vm.filteredChannels.map((channel) => channel.id), ['c2']);
    userDataSync.publish('c2', {'IsFavorite': false});
    vm.syncChannelUserData();
    expect(vm.filteredChannels, isEmpty);
    vm.dispose();
  });

  test('a channel favorited under the favorites filter gets its programs', () async {
    _stubChannels(liveTv, [
      for (var i = 0; i < 120; i++) _channel('c$i', number: '$i'),
    ]);
    final vm = LiveTvGuideViewModel(client);
    await vm.load();
    vm.setFilter(GuideFilter.favorites);
    expect(vm.hasProgramsFor('c110'), isFalse);

    userDataSync.publish('c110', {'IsFavorite': true});
    vm.syncChannelUserData();
    await Future<void>.delayed(Duration.zero);
    expect(vm.hasProgramsFor('c110'), isTrue);
    vm.dispose();
  });

  test('overlapping program requests fetch a channel once', () async {
    _stubChannels(liveTv, [
      for (var i = 0; i < 120; i++) _channel('c$i', number: '$i'),
    ]);
    final vm = LiveTvGuideViewModel(client);
    await vm.load();
    final reply = Completer<Map<String, dynamic>>();
    final requested = <String>[];
    when(() => _guide(liveTv)).thenAnswer((inv) {
      requested.addAll(_requestedIds(inv));
      return reply.future;
    });

    final first = vm.ensureProgramsForChannels(['c110']);
    final second = vm.ensureProgramsForChannels(['c110']);
    reply.complete({
      'Items': [_program('p', 'c110')],
    });
    await Future.wait([first, second]);

    expect(requested, ['c110']);
    expect(vm.programsForChannel('c110').map((p) => p.id), ['p']);
    vm.dispose();
  });

  test('a failed favorite program request is asked again later', () async {
    _stubChannels(liveTv, [
      for (var i = 0; i < 120; i++) _channel('c$i', number: '$i'),
    ]);
    final vm = LiveTvGuideViewModel(client);
    await vm.load();
    vm.setFilter(GuideFilter.favorites);
    when(() => _guide(liveTv)).thenThrow(Exception('offline'));

    userDataSync.publish('c110', {'IsFavorite': true});
    vm.syncChannelUserData();
    await pumpEventQueue();
    expect(vm.hasProgramsFor('c110'), isFalse);

    when(() => _guide(liveTv)).thenAnswer((_) async => {'Items': <dynamic>[]});
    await vm.ensureProgramsForChannels(['c110']);
    expect(vm.hasProgramsFor('c110'), isTrue);
    vm.dispose();
  });

  test('a lazy batch waits on a request already out and retries it', () async {
    _stubChannels(liveTv, [
      for (var i = 0; i < 120; i++) _channel('c$i', number: '$i'),
    ]);
    final vm = LiveTvGuideViewModel(client);
    await vm.load();
    expect(vm.programsHighWater, 50);

    final calls =
        <({List<String> ids, Completer<Map<String, dynamic>> reply})>[];
    when(() => _guide(liveTv)).thenAnswer((inv) {
      final reply = Completer<Map<String, dynamic>>();
      calls.add((ids: _requestedIds(inv), reply: reply));
      return reply.future;
    });
    final favorite = vm.ensureProgramsForChannels(['c60']);
    final lazy = vm.loadMorePrograms();
    await pumpEventQueue();
    expect(calls, hasLength(2));
    expect(calls[1].ids, isNot(contains('c60')));

    calls[1].reply.complete({'Items': <dynamic>[]});
    calls[0].reply.completeError(Exception('offline'));
    await expectLater(favorite, throwsException);
    await lazy;
    expect(vm.hasProgramsFor('c60'), isFalse);
    expect(vm.programsHighWater, 50);

    final retry = vm.loadMorePrograms();
    await pumpEventQueue();
    expect(calls.last.ids, ['c60']);
    calls.last.reply.complete({'Items': <dynamic>[]});
    await retry;
    expect(vm.hasProgramsFor('c60'), isTrue);
    expect(vm.programsHighWater, 100);
    vm.dispose();
  });

  test('a lineup from before a user switch is dropped', () async {
    final reply = Completer<Map<String, dynamic>>();
    when(
      () => liveTv.getChannels(
        sortBy: any(named: 'sortBy'),
        sortOrder: any(named: 'sortOrder'),
        fields: any(named: 'fields'),
        enableTotalRecordCount: any(named: 'enableTotalRecordCount'),
        userId: any(named: 'userId'),
      ),
    ).thenAnswer((_) => reply.future);
    final vm = LiveTvGuideViewModel(client);
    final loading = vm.load();
    await pumpEventQueue();

    userDataSync.reset();
    reply.complete({
      'Items': [
        {
          ..._channel('c1'),
          'UserData': {'IsFavorite': true},
        },
      ],
    });
    await loading;

    expect(userDataSync.favoriteFor('c1'), isNull);
    vm.dispose();
  });

  group('category filters', () {
    for (final changeSort in [true, false]) {
      final action = changeSort
          ? 'changing sort'
          : 'leaving and reopening Sports';
      test('a pending Sports search finishes after $action', () async {
        _stubChannels(liveTv, [
          _channel('fox2', number: '1'),
          _channel('fox1', number: '2'),
          _channel('other', number: '3'),
        ]);
        when(() => _guide(liveTv, category: GuideFilter.sports))
            .thenAnswer(_serverFiltered((_) => true));
        final vm = LiveTvGuideViewModel(client);
        addTearDown(vm.dispose);
        await vm.load();
        vm.setFilter(GuideFilter.sports);
        await Future<void>.delayed(Duration.zero);

        final stale = Completer<Map<String, dynamic>>();
        when(() => _guide(liveTv, category: GuideFilter.sports))
            .thenAnswer((_) => stale.future);
        vm.setChannelQuery('fox');
        expect(vm.state, GuideState.loading);
        when(() => _guide(liveTv, category: GuideFilter.sports))
            .thenAnswer(_serverFiltered((_) => true));
        if (changeSort) {
          vm.setSortBy(ChannelSortBy.name);
        } else {
          vm.setFilter(GuideFilter.all);
          vm.setFilter(GuideFilter.sports);
        }
        await Future<void>.delayed(Duration.zero);
        expect(vm.state, GuideState.ready);
        stale.complete({'Items': []});
        await Future<void>.delayed(Duration.zero);
        expect(
          vm.filteredChannels.map((c) => c.id),
          changeSort ? ['fox1', 'fox2'] : ['fox2', 'fox1'],
        );
      });
    }

    test(
      'a Sports page that times out after switching to All is ignored',
      () async {
        _stubChannels(
          liveTv,
          List.generate(250, (i) => _channel('c$i', number: '$i')),
        );
        when(() => _guide(liveTv, category: GuideFilter.sports))
            .thenAnswer(_serverFiltered((_) => true));
        final vm = LiveTvGuideViewModel(client);
        addTearDown(vm.dispose);
        await vm.load();
        vm.setFilter(GuideFilter.sports);
        await Future<void>.delayed(Duration.zero);
        final pending = Completer<Map<String, dynamic>>();
        when(() => _guide(liveTv, category: GuideFilter.sports))
            .thenAnswer((_) => pending.future);
        final page = vm.loadMorePrograms();
        vm.setFilter(GuideFilter.all);
        await vm.loadMorePrograms();
        expect(vm.hasProgramsFor('c99'), isTrue);
        pending.completeError(TimeoutException('Sports page'));
        await page;
        expect(vm.state, GuideState.ready);
        expect(vm.error, isNull);
        expect(vm.filteredChannels, hasLength(250));
      },
    );

    test('a category chip walks the lineup in flagged batches', () async {
      final channels = List.generate(120, (i) => _channel('c$i', number: '$i'));
      _stubChannels(liveTv, channels);
      when(() => _guide(liveTv, category: GuideFilter.sports)).thenAnswer(
        (inv) async => {
          'Items': [
            for (final id in _requestedIds(inv))
              if (const {'c110', 'c7', 'c60'}.contains(id))
                _program('p-$id', id, isSports: true),
            _program('p4', 'c8', isKids: true),
          ],
        },
      );

      final vm = LiveTvGuideViewModel(client);
      await vm.load();
      expect(vm.programsHighWater, 50);

      vm.setFilter(GuideFilter.sports);
      expect(vm.state, GuideState.loading);
      await Future<void>.delayed(Duration.zero);
      expect(vm.state, GuideState.ready);

      final captured = verify(
        () => _guide(
          liveTv,
          category: GuideFilter.sports,
          captureChannelIds: true,
        ),
      ).captured;
      expect((captured.single as List).length, 120);
      expect(vm.filteredChannels.map((c) => c.id), ['c7', 'c60', 'c110']);
      expect(vm.hasProgramsFor('c110'), isTrue);
      expect(vm.programsForChannel('c110').single.id, 'p-c110');
      expect(vm.programsHighWater, 3);
      expect(vm.hasMorePrograms, isFalse);
    });

    test('scrolling a category pulls the next batch of channels', () async {
      _stubChannels(
        liveTv,
        List.generate(500, (i) => _channel('c$i', number: '$i')),
      );
      when(() => _guide(liveTv, category: GuideFilter.sports)).thenAnswer(
        _serverFiltered((id) => int.parse(id.substring(1)) % 10 == 0),
      );

      final vm = LiveTvGuideViewModel(client);
      await vm.load();
      vm.setFilter(GuideFilter.sports);
      await Future<void>.delayed(Duration.zero);

      expect(vm.filteredChannels.length, 40);
      expect(vm.filteredChannels.first.id, 'c0');
      expect(vm.filteredChannels.last.id, 'c390');
      expect(vm.programsHighWater, 40);
      expect(vm.hasMorePrograms, isTrue);

      await vm.loadMorePrograms();
      expect(vm.filteredChannels.length, 50);
      expect(vm.filteredChannels.last.id, 'c490');
      expect(vm.hasMorePrograms, isFalse);
      await vm.loadMorePrograms();
      expect(vm.filteredChannels.length, 50);
      verify(() => _guide(liveTv, category: GuideFilter.sports)).called(3);
    });

    test(
      're-sorting keeps category rows and requests only unseen channels',
      () async {
        _stubChannels(
          liveTv,
          List.generate(500, (i) => _channel('c$i', number: '$i')),
        );
        when(() => _guide(liveTv, category: GuideFilter.sports)).thenAnswer(
          _serverFiltered((id) => int.parse(id.substring(1)) % 10 == 0),
        );

        final vm = LiveTvGuideViewModel(client);
        await vm.load();
        vm.setFilter(GuideFilter.sports);
        await Future<void>.delayed(Duration.zero);
        expect(vm.filteredChannels.length, 40);
        clearInteractions(liveTv);

        vm.setSortBy(ChannelSortBy.name);
        await Future<void>.delayed(Duration.zero);

        expect(vm.filteredChannels.length, 50);
        expect(vm.filteredChannels.first.name, 'Ch c0');
        expect(vm.hasMorePrograms, isFalse);
        final captured = verify(
          () => _guide(
            liveTv,
            category: GuideFilter.sports,
            captureChannelIds: true,
          ),
        ).captured;
        final requested = captured.expand((ids) => ids as List<String>).toSet();
        expect(requested.length, 100);
        expect(
          requested.every((id) => int.parse(id.substring(1)) >= 400),
          isTrue,
        );
      },
    );

    test('a sparse category keeps walking until it finds rows', () async {
      _stubChannels(
        liveTv,
        List.generate(1000, (i) => _channel('c$i', number: '$i')),
      );
      when(() => _guide(liveTv, category: GuideFilter.sports))
          .thenAnswer(_serverFiltered((id) => id == 'c999'));

      final vm = LiveTvGuideViewModel(client);
      await vm.load();
      vm.setFilter(GuideFilter.sports);
      await Future<void>.delayed(Duration.zero);

      expect(vm.state, GuideState.ready);
      expect(vm.filteredChannels.map((c) => c.id), ['c999']);
      expect(vm.hasMorePrograms, isFalse);
      verify(() => _guide(liveTv, category: GuideFilter.sports)).called(5);
    });

    test('premiere has no server flag, so it matches client-side', () async {
      _stubChannels(
        liveTv,
        List.generate(120, (i) => _channel('c$i', number: '$i')),
      );
      when(() => _guide(liveTv, category: GuideFilter.premiere)).thenAnswer(
        (inv) async => {
          'Items': [
            for (final id in _requestedIds(inv))
              _program('p-$id', id, isPremiere: id == 'c100'),
          ],
        },
      );

      final vm = LiveTvGuideViewModel(client);
      await vm.load();
      vm.setFilter(GuideFilter.premiere);
      await Future<void>.delayed(Duration.zero);

      expect(vm.filteredChannels.map((c) => c.id), ['c100']);
      expect(vm.programsForChannel('c100').single.id, 'p-c100');
      expect(vm.hasMorePrograms, isFalse);
    });

    test('switching chips drops a stale in-flight category response', () async {
      _stubChannels(liveTv, List.generate(10, (i) => _channel('c$i')));
      final sports = Completer<Map<String, dynamic>>();
      when(() => _guide(liveTv, category: GuideFilter.sports))
          .thenAnswer((_) => sports.future);
      when(() => _guide(liveTv, category: GuideFilter.kids)).thenAnswer(
        (_) async => {
          'Items': [_program('k1', 'c3', isKids: true)],
        },
      );

      final vm = LiveTvGuideViewModel(client);
      await vm.load();
      vm.setFilter(GuideFilter.sports);
      vm.setFilter(GuideFilter.kids);
      await Future<void>.delayed(Duration.zero);
      expect(vm.state, GuideState.ready);
      expect(vm.filteredChannels.map((c) => c.id), ['c3']);

      sports.complete({
        'Items': [_program('s1', 'c1', isSports: true)],
      });
      await Future<void>.delayed(Duration.zero);
      expect(vm.filter, GuideFilter.kids);
      expect(vm.filteredChannels.map((c) => c.id), ['c3']);
    });

    test('backing out of a pending category returns to All', () async {
      _stubChannels(liveTv, List.generate(10, (i) => _channel('c$i')));
      final sports = Completer<Map<String, dynamic>>();
      when(() => _guide(liveTv, category: GuideFilter.sports))
          .thenAnswer((_) => sports.future);

      final vm = LiveTvGuideViewModel(client);
      await vm.load();
      vm.setFilter(GuideFilter.sports);
      expect(vm.state, GuideState.loading);
      vm.setFilter(GuideFilter.all);
      expect(vm.state, GuideState.ready);
      expect(vm.filteredChannels.length, 10);

      sports.complete({'Items': <dynamic>[]});
      await Future<void>.delayed(Duration.zero);
      expect(vm.state, GuideState.ready);
      expect(vm.filteredChannels.length, 10);
    });

    test('shifting the window re-fetches the active category', () async {
      _stubChannels(liveTv, List.generate(10, (i) => _channel('c$i')));
      when(() => _guide(liveTv, category: GuideFilter.kids)).thenAnswer(
        (_) async => {
          'Items': [_program('k1', 'c5', isKids: true)],
        },
      );

      final vm = LiveTvGuideViewModel(client);
      await vm.load();
      vm.setFilter(GuideFilter.kids);
      await Future<void>.delayed(Duration.zero);
      await vm.shiftWindow(const Duration(hours: 3));

      verify(() => _guide(liveTv, category: GuideFilter.kids)).called(2);
      expect(vm.filteredChannels.map((c) => c.id), ['c5']);
    });
  });

  group('recording changes refresh the loaded rows in place', () {
    Map<String, dynamic> recorded(Map<String, dynamic> program) => {
      ...program,
      'TimerId': 'timer-1',
    };

    test('recordingChanged re-reads programs without a loading state', () async {
      _stubChannels(liveTv, [_channel('c0')]);
      when(() => _guide(liveTv)).thenAnswer(
        (_) async => {
          'Items': [_program('p0', 'c0')],
        },
      );
      final vm = LiveTvGuideViewModel(client);
      await vm.load();
      expect(vm.programsForChannel('c0').single.hasTimer, isFalse);

      when(() => _guide(liveTv)).thenAnswer(
        (_) async => {
          'Items': [recorded(_program('p0', 'c0'))],
        },
      );
      final states = <GuideState>[];
      vm.addListener(() => states.add(vm.state));
      final revision = liveTvRecordingRevision.value;
      await vm.recordingChanged();

      expect(states, isNot(contains(GuideState.loading)));
      expect(vm.state, GuideState.ready);
      expect(vm.programsForChannel('c0').single.hasTimer, isTrue);
      expect(liveTvRecordingRevision.value, revision + 1);
    });

    test('a category filter refreshes its own rows too', () async {
      _stubChannels(liveTv, List.generate(10, (i) => _channel('c$i')));
      when(() => _guide(liveTv, category: GuideFilter.kids)).thenAnswer(
        (_) async => {
          'Items': [_program('k1', 'c5', isKids: true)],
        },
      );
      final vm = LiveTvGuideViewModel(client);
      await vm.load();
      vm.setFilter(GuideFilter.kids);
      await Future<void>.delayed(Duration.zero);
      expect(vm.programsForChannel('c5').single.hasTimer, isFalse);

      when(() => _guide(liveTv, category: GuideFilter.kids)).thenAnswer(
        (_) async => {
          'Items': [recorded(_program('k1', 'c5', isKids: true))],
        },
      );
      final states = <GuideState>[];
      vm.addListener(() => states.add(vm.state));
      await vm.recordingChanged();

      expect(states, isNot(contains(GuideState.loading)));
      expect(vm.filteredChannels.map((c) => c.id), ['c5']);
      expect(vm.programsForChannel('c5').single.hasTimer, isTrue);
    });

    test('reloadIfRecordingsChanged does nothing until a recording changes', () async {
      _stubChannels(liveTv, [_channel('c0')]);
      when(() => _guide(liveTv)).thenAnswer(
        (_) async => {
          'Items': [_program('p0', 'c0')],
        },
      );
      final vm = LiveTvGuideViewModel(client);
      await vm.load();
      clearInteractions(liveTv);

      await vm.reloadIfRecordingsChanged();
      verifyNever(() => _guide(liveTv));

      when(() => _guide(liveTv)).thenAnswer(
        (_) async => {
          'Items': [recorded(_program('p0', 'c0'))],
        },
      );
      final states = <GuideState>[];
      vm.addListener(() => states.add(vm.state));
      notifyLiveTvRecordingsChanged();
      await vm.reloadIfRecordingsChanged();

      expect(states, isNot(contains(GuideState.loading)));
      expect(vm.programsForChannel('c0').single.hasTimer, isTrue);

      clearInteractions(liveTv);
      await vm.reloadIfRecordingsChanged();
      verifyNever(() => _guide(liveTv));
    });
  });

  test(
    'artworkSourceFor evicts only the oldest entry past the cache cap',
    () async {
      when(
        () => liveTv.getProgram(any(), userId: any(named: 'userId')),
      ).thenAnswer(
        (inv) async => _program(inv.positionalArguments[0] as String, 'c0'),
      );

      final vm = LiveTvGuideViewModel(client);
      GuideProgram program(String id) => GuideProgram(
        id: id,
        channelId: 'c0',
        name: id,
        startDate: DateTime.parse('2026-09-11T10:00:00Z'),
        endDate: DateTime.parse('2026-09-11T10:30:00Z'),
        rawData: const {},
      );

      // One past the cap: a clear-everything eviction would leave only the
      // last entry cached, where the single-entry eviction this guards
      // leaves every entry but the oldest.
      final cap = LiveTvGuideViewModel.artworkCacheCap;
      for (var i = 0; i <= cap; i++) {
        await vm.artworkSourceFor(program('p$i'));
      }

      expect(vm.hasArtworkResult('p0'), isFalse);
      expect(vm.hasArtworkResult('p1'), isTrue);
      expect(vm.hasArtworkResult('p$cap'), isTrue);
    },
  );

  test(
    'a failed artwork lookup does not poison the cache and a later call retries',
    () async {
      var callCount = 0;
      when(
        () => liveTv.getProgram(any(), userId: any(named: 'userId')),
      ).thenAnswer((inv) async {
        callCount++;
        if (callCount == 1) throw Exception('transient failure');
        return _program(inv.positionalArguments[0] as String, 'c0');
      });

      final vm = LiveTvGuideViewModel(client);
      final program = GuideProgram(
        id: 'p1',
        channelId: 'c0',
        name: 'p1',
        startDate: DateTime.parse('2026-09-11T10:00:00Z'),
        endDate: DateTime.parse('2026-09-11T10:30:00Z'),
        rawData: const {},
      );

      final first = await vm.artworkSourceFor(program);
      expect(first, isNull);
      expect(
        vm.hasArtworkResult('p1'),
        isFalse,
        reason:
            'a transient lookup failure must not be cached as a permanent '
            'negative',
      );

      await vm.artworkSourceFor(program);
      expect(
        callCount,
        2,
        reason: 'the retry must issue a fresh request, not reuse a cached '
            'null from the failed attempt',
      );
      expect(
        vm.hasArtworkResult('p1'),
        isTrue,
        reason: 'a genuine (non-error) result is still cached',
      );
    },
  );

  test(
    'same-named programs without an episode title do not share artwork '
    'across channels',
    () async {
      var callCount = 0;
      when(
        () => liveTv.getProgram(any(), userId: any(named: 'userId')),
      ).thenAnswer((inv) async {
        callCount++;
        final id = inv.positionalArguments[0] as String;
        return {
          'Id': id,
          'ChannelId': id == 'p1' ? 'c0' : 'c1',
          'Name': 'Paid Programming',
          'StartDate': '2026-09-11T10:00:00Z',
          'EndDate': '2026-09-11T10:30:00Z',
          'ImageTags': {'Primary': 'tag-$id'},
        };
      });

      final vm = LiveTvGuideViewModel(client);
      GuideProgram filler(String id, String channelId) => GuideProgram(
        id: id,
        channelId: channelId,
        name: 'Paid Programming',
        startDate: DateTime.parse('2026-09-11T10:00:00Z'),
        endDate: DateTime.parse('2026-09-11T10:30:00Z'),
        rawData: const {},
      );

      final first = await vm.artworkSourceFor(filler('p1', 'c0'));
      final second = await vm.artworkSourceFor(filler('p2', 'c1'));

      expect(first?.tag, 'tag-p1');
      expect(
        second?.tag,
        'tag-p2',
        reason: 'a generic name with no episode title recurs across unrelated '
            'channels, so it must not inherit artwork from another channel',
      );
      expect(
        callCount,
        2,
        reason: 'the second channel must resolve its own artwork rather than '
            'reusing the content-key entry of the first',
      );
    },
  );

  test(
    'an empty replacing submission clears the pending prefetch queue',
    () async {
      final completers = <String, Completer<Map<String, dynamic>>>{};
      when(
        () => liveTv.getProgram(any(), userId: any(named: 'userId')),
      ).thenAnswer((inv) {
        final id = inv.positionalArguments[0] as String;
        return completers
            .putIfAbsent(id, () => Completer<Map<String, dynamic>>())
            .future;
      });

      final vm = LiveTvGuideViewModel(client);
      GuideProgram program(String id) => GuideProgram(
        id: id,
        channelId: 'c0',
        name: id,
        startDate: DateTime.parse('2026-09-11T10:00:00Z'),
        endDate: DateTime.parse('2026-09-11T10:30:00Z'),
        rawData: const {},
      );

      // Concurrency is 3, so p0-p2 start and p3/p4 sit queued behind them.
      vm.queueArtworkPrefetch([
        program('p0'),
        program('p1'),
        program('p2'),
        program('p3'),
        program('p4'),
      ]);

      // The guide screen relies on this to drop work for a lineup that a
      // filter has emptied.
      vm.queueArtworkPrefetch(const [], replace: true);

      completers['p0']!.complete(_program('p0', 'c0'));
      await Future<void>.delayed(Duration.zero);
      completers['p1']!.complete(_program('p1', 'c0'));
      await Future<void>.delayed(Duration.zero);
      completers['p2']!.complete(_program('p2', 'c0'));
      await Future<void>.delayed(Duration.zero);

      expect(
        completers.containsKey('p3'),
        isFalse,
        reason: 'an emptied lineup must not keep fetching its old programs',
      );
      expect(completers.containsKey('p4'), isFalse);
    },
  );

  test(
    'replacing the prefetch queue drops previously queued, now-obsolete '
    'programs',
    () async {
      final completers = <String, Completer<Map<String, dynamic>>>{};
      when(
        () => liveTv.getProgram(any(), userId: any(named: 'userId')),
      ).thenAnswer((inv) {
        final id = inv.positionalArguments[0] as String;
        return completers
            .putIfAbsent(id, () => Completer<Map<String, dynamic>>())
            .future;
      });

      final vm = LiveTvGuideViewModel(client);
      GuideProgram program(String id) => GuideProgram(
        id: id,
        channelId: 'c0',
        name: id,
        startDate: DateTime.parse('2026-09-11T10:00:00Z'),
        endDate: DateTime.parse('2026-09-11T10:30:00Z'),
        rawData: const {},
      );

      // Concurrency is 3: p0-p2 start fetching immediately (blocked on
      // their completers) and p3/p4 sit queued behind them, never dequeued.
      vm.queueArtworkPrefetch([
        program('p0'),
        program('p1'),
        program('p2'),
        program('p3'),
        program('p4'),
      ]);

      // Replace the queue with an unrelated program before any of the
      // active three complete.
      vm.queueArtworkPrefetch([program('q0')], replace: true);

      completers['p0']!.complete(_program('p0', 'c0'));
      await Future<void>.delayed(Duration.zero);
      completers['p1']!.complete(_program('p1', 'c0'));
      await Future<void>.delayed(Duration.zero);
      completers['p2']!.complete(_program('p2', 'c0'));
      await Future<void>.delayed(Duration.zero);

      expect(
        completers.containsKey('p3'),
        isFalse,
        reason: 'p3 was only queued, not in flight, and the replace should '
            'have dropped it',
      );
      expect(
        completers.containsKey('p4'),
        isFalse,
        reason: 'p4 was only queued, not in flight, and the replace should '
            'have dropped it',
      );
      expect(
        completers.containsKey('q0'),
        isTrue,
        reason: 'the replacement program should start once a concurrency '
            'slot frees up',
      );
    },
  );

  group("artwork prefetch doesn't run away", () {
    List<GuideProgram> makePrograms(int n) => [
      for (var i = 0; i < n; i++)
        GuideProgram(
          id: 'p$i',
          // Distinct channels, so the content-key cache can't absorb these
          // and hide the behaviour under test.
          channelId: 'c$i',
          name: 'Show $i',
          startDate: DateTime.now().add(const Duration(minutes: 5)),
          endDate: DateTime.now().add(const Duration(minutes: 35)),
          rawData: const {},
        ),
    ];

    test('resubmitting a resolved lineup fetches nothing', () async {
      var fetches = 0;
      when(
        () => liveTv.getProgram(any(), userId: any(named: 'userId')),
      ).thenAnswer((inv) async {
        fetches++;
        final id = inv.positionalArguments[0] as String;
        return _program(id, 'c${id.substring(1)}');
      });

      final vm = LiveTvGuideViewModel(client);
      final programs = makePrograms(600);

      vm.queueArtworkPrefetch(programs, replace: true);
      await pumpEventQueue(times: 5000);
      final settled = fetches;
      expect(settled, programs.length);

      // The screen resubmits the current window on every notification, and
      // every resolved fetch notifies. A submission bigger than the cache
      // used to evict entries that the next pass then re-fetched, so this
      // fed itself instead of settling.
      for (var i = 0; i < 3; i++) {
        vm.queueArtworkPrefetch(programs, replace: true);
        await pumpEventQueue(times: 200);
      }

      expect(fetches, settled);
    });

    test("a server that can't answer getProgram is asked a bounded number "
        'of times', () async {
      var fetches = 0;
      when(
        () => liveTv.getProgram(any(), userId: any(named: 'userId')),
      ).thenAnswer((_) async {
        fetches++;
        throw StateError('no such route');
      });

      final vm = LiveTvGuideViewModel(client);
      final programs = makePrograms(600);

      vm.queueArtworkPrefetch(programs, replace: true);
      await pumpEventQueue(times: 5000);
      // A later resubmission must not restart the storm.
      vm.queueArtworkPrefetch(programs, replace: true);
      await pumpEventQueue(times: 5000);

      expect(vm.artworkLookupsDisabled, isTrue);
      expect(
        fetches,
        lessThan(20),
        reason: "failures aren't cached per program, so without the breaker "
            'every program in the lineup was retried on every resubmission',
      );
    });

    test('a program that already carries its art is never fetched', () async {
      var fetches = 0;
      when(
        () => liveTv.getProgram(any(), userId: any(named: 'userId')),
      ).thenAnswer((inv) async {
        fetches++;
        return _program(inv.positionalArguments[0] as String, 'c0');
      });

      final vm = LiveTvGuideViewModel(client);
      final carriesOwnArt = GuideProgram(
        id: 'p1',
        channelId: 'c1',
        name: 'Show',
        startDate: DateTime.now(),
        endDate: DateTime.now(),
        rawData: const {
          'ImageTags': {'Primary': 'tag1'},
        },
      );

      final source = await vm.artworkSourceFor(carriesOwnArt);

      expect(source?.itemId, 'p1');
      expect(fetches, 0, reason: 'its art came with the program already');
    });
  });

  group('episodeLine', () {
    GuideProgram program({String? episodeTitle, int? season, int? episode}) =>
        GuideProgram(
          id: 'p1',
          channelId: 'c1',
          name: 'Show',
          startDate: DateTime.now(),
          endDate: DateTime.now(),
          episodeTitle: episodeTitle,
          rawData: <String, dynamic>{
            'ParentIndexNumber': ?season,
            'IndexNumber': ?episode,
          },
        );

    test('carries the title and the numbering together', () {
      final line = program(
        episodeTitle: 'The Reckoning',
        season: 1,
        episode: 5,
      ).episodeLine;

      expect(line, 'The Reckoning (S1:E5)');
    });

    // Listings often name an episode without numbering it.
    test('keeps the title when there is no numbering', () {
      expect(
        program(episodeTitle: 'The Reckoning').episodeLine,
        'The Reckoning',
      );
    });

    test('keeps the numbering when there is no title', () {
      expect(program(season: 2, episode: 9).episodeLine, '(S2:E9)');
    });

    test('is empty when the program carries neither', () {
      expect(program().episodeLine, isEmpty);
      expect(program(episodeTitle: '   ').episodeLine, isEmpty);
    });

    test('never renders a null into the line', () {
      for (final line in [
        program(episodeTitle: 'Name').episodeLine,
        program(season: 3, episode: 1).episodeLine,
        program().episodeLine,
      ]) {
        expect(line, isNot(contains('null')));
      }
    });
  });

  group('artwork source picks the right image endpoint', () {
    GuideProgram withRaw(Map<String, dynamic> raw) => GuideProgram(
      id: 'p1',
      channelId: 'c1',
      name: 'Show',
      startDate: DateTime.now(),
      endDate: DateTime.now(),
      rawData: raw,
    );

    test('a parent thumb is flagged so callers use the Thumb endpoint', () {
      final source = withRaw(const {
        'ParentThumbItemId': 'parent1',
        'ParentThumbImageTag': 'thumbtag',
      }).artworkSource;

      expect(source?.itemId, 'parent1');
      expect(source?.tag, 'thumbtag');
      expect(
        source?.isThumb,
        isTrue,
        reason: 'ParentThumbImageTag tags the parent Thumb image, so asking '
            'for its Primary with that tag serves the wrong image or nothing',
      );
    });

    test('a series poster stays on the Primary endpoint', () {
      final source = withRaw(const {
        'SeriesId': 's1',
        'SeriesPrimaryImageTag': 'ptag',
      }).artworkSource;

      expect(source?.itemId, 's1');
      expect(source?.isThumb, isFalse);
    });

    test("the program's own art wins over every fallback", () {
      final source = withRaw(const {
        'ImageTags': {'Primary': 'own'},
        'SeriesId': 's1',
        'SeriesPrimaryImageTag': 'ptag',
        'ParentThumbItemId': 'parent1',
        'ParentThumbImageTag': 'thumbtag',
      }).artworkSource;

      expect(source?.tag, 'own');
      expect(source?.isThumb, isFalse);
    });
  });
}
