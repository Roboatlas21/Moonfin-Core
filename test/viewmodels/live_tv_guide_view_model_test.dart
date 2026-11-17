import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moonfin/data/models/live_tv_recording_state.dart';
import 'package:moonfin/data/services/user_data_sync.dart';
import 'package:moonfin/data/viewmodels/live_tv_guide_search.dart';
import 'package:moonfin/data/viewmodels/live_tv_guide_view_model.dart';
import 'package:moonfin/preference/preference_constants.dart';

import 'package:server_core/server_core.dart';

class _MockClient extends Mock implements MediaServerClient {}

class _MockLiveTvApi extends Mock implements LiveTvApi {}

class _SearchableLiveTvApi extends _MockLiveTvApi
    implements LiveTvProgramSearchApi {}

class _IncrementalSearchableLiveTvApi extends _SearchableLiveTvApi
    implements LiveTvIncrementalProgramSearchApi {}

class _GroupedLiveTvApi extends _MockLiveTvApi implements ChannelGroupApi {}

class _GroupedSearchableLiveTvApi extends _SearchableLiveTvApi
    implements ChannelGroupApi {}

class _DirectGroupedLiveTvApi extends _GroupedLiveTvApi
    implements DirectChannelGroupApi {}

class _MockUserLibraryApi extends Mock implements UserLibraryApi {}

class _MockItemsApi extends Mock implements ItemsApi {}

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

  test('Jellyfin and Emby paginate program titles', () async {
    final items = _MockItemsApi();
    when(() => client.itemsApi).thenReturn(items);
    Map<String, dynamic> item(String id, String title) => {
      'Id': id,
      'ChannelId': id,
      'Type': client.serverType == ServerType.emby ? 'Program' : 'LiveTvProgram',
      'Name': title,
      'Overview': 'Soccer',
      'IsSports': true,
      'IsNews': false,
      'StartDate': '2026-11-14T19:00:00Z',
      'EndDate': '2026-11-14T20:00:00Z',
    };
    final offsets = <int>[];
    when(
      () => items.getItems(
        searchTerm: 'soccer',
        includeItemTypes: any(named: 'includeItemTypes'),
        recursive: true,
        startIndex: any(named: 'startIndex'),
        limit: 200,
      ),
    ).thenAnswer((call) async {
      expect(call.namedArguments[#includeItemTypes], [
        client.serverType == ServerType.emby ? 'Program' : 'LiveTvProgram',
      ]);
      final offset = call.namedArguments[#startIndex] as int;
      offsets.add(offset);
      return {
        'TotalRecordCount': 3,
        'Items': offset == 0
            ? [item('tsn', 'Soccer'), item('espn', 'Baseball')]
            : [item('sports', 'Soccer Highlights')],
      };
    });
    final found = await searchGuideProgramTitles(
      client, 'soccer', isCurrent: () => true,
    );
    expect(offsets, [0, 2]);
    expect(found.map((p) => p.channelId), ['tsn', 'sports']);
    expect(found.first.title, 'Soccer');
    expect(found.first.isSports, isTrue);
    expect(found.first.isNews, isFalse);
    final start = DateTime.utc(2026, 11, 14, 19);
    expect(programChannelsInWindow(
      found, start, start.add(const Duration(hours: 2)),
    ), {'tsn', 'sports'});

    var checks = 0;
    expect(await searchGuideProgramTitles(
      client, 'soccer', isCurrent: () => checks++ == 0,
    ), isEmpty);

    when(() => client.serverType).thenReturn(ServerType.emby);
    offsets.clear();
    final emby = await searchGuideProgramTitles(
      client, 'soccer', isCurrent: () => true,
    );
    expect(offsets, [0, 2]);
    expect(emby.map((p) => p.channelId), ['tsn', 'sports']);
    expect(emby.first.isSports, isTrue);
    expect(emby.first.isNews, isFalse);
  });

  test('Jellyfin and Emby retain completed search pages on failure', () async {
    for (final server in [ServerType.jellyfin, ServerType.emby]) {
      when(() => client.serverType).thenReturn(server);
      final items = _MockItemsApi();
      when(() => client.itemsApi).thenReturn(items);
      final type = server == ServerType.jellyfin ? 'LiveTvProgram' : 'Program';
      final start = DateTime.utc(2026, 11, 14, 19);
      final page = [
        for (var i = 0; i < 200; i++)
          <String, dynamic>{
            'Id': 'match-$i',
            'ChannelId': 'channel-$i',
            'Type': type,
            'Name': 'Soccer $i',
            'IsSports': true,
            'StartDate': start.toIso8601String(),
            'EndDate': start.add(const Duration(hours: 1)).toIso8601String(),
          },
      ];
      final offsets = <int>[];
      when(() => items.getItems(
        searchTerm: 'soccer',
        includeItemTypes: any(named: 'includeItemTypes'),
        recursive: true,
        startIndex: any(named: 'startIndex'),
        limit: 200,
      )).thenAnswer((call) async {
        final offset = call.namedArguments[#startIndex] as int;
        offsets.add(offset);
        if (offset == 0) {
          return {'TotalRecordCount': 400, 'Items': page};
        }
        throw StateError('Later page failed');
      });

      final updates = <List<GuideTitleMatch>>[];
      GuideProgramSearchPartialException? partial;
      try {
        await searchGuideProgramTitles(
          client, 'soccer', isCurrent: () => true,
          onPartialResults: updates.add,
        );
      } on GuideProgramSearchPartialException catch (error) {
        partial = error;
      }
      expect(offsets, [0, 200]);
      expect(updates, hasLength(1));
      expect(updates.single, hasLength(200));
      expect(partial, isNotNull);
      final outcome = partial!;
      expect(outcome.matches, hasLength(200));
      expect(outcome.matches.first.programId, 'match-0');
      expect(outcome.matches.last.programId, 'match-199');
      expect(outcome.cause, isA<StateError>());
    }
  });

  test('a first-page failure remains a failed search', () async {
    final items = _MockItemsApi();
    when(() => client.itemsApi).thenReturn(items);
    when(() => items.getItems(
      searchTerm: 'soccer',
      includeItemTypes: any(named: 'includeItemTypes'),
      recursive: true,
      startIndex: 0,
      limit: 200,
    )).thenAnswer((_) async => throw StateError('Offline'));

    await expectLater(
      searchGuideProgramTitles(client, 'soccer', isCurrent: () => true),
      throwsA(isA<StateError>()),
    );
  });

  test('failed title searches are retryable and not reported as no matches', () async {
    final api = _SearchableLiveTvApi();
    when(() => client.serverType).thenReturn(ServerType.plex);
    when(() => client.liveTvApi).thenReturn(api);
    _stubChannels(api, [_channel('c0')]);
    when(() => _guide(api)).thenAnswer((_) async => {'Items': []});
    var requests = 0;
    when(() => api.searchProgramTitles(
      'soccer', isCurrent: any(named: 'isCurrent'),
    )).thenAnswer((_) async {
      requests++;
      if (requests == 1) throw StateError('Title index unavailable');
      return <Map<String, dynamic>>[];
    });

    final now = DateTime.utc(2026, 11, 14, 17);
    final vm = LiveTvGuideViewModel(client, now: () => now);
    addTearDown(vm.dispose);
    await vm.load(windowStart: now);
    vm.setChannelQuery('soccer');
    await pumpEventQueue();

    expect(vm.programSearchStatus, GuideProgramSearchStatus.failed);
    expect(vm.searchingProgramTitles, isFalse);
    expect(vm.filteredChannels, isEmpty);

    vm.retryProgramTitleSearch();
    await pumpEventQueue();
    expect(requests, 2);
    expect(vm.programSearchStatus, GuideProgramSearchStatus.complete);
    vm.setChannelQuery('');
    expect(vm.programSearchStatus, GuideProgramSearchStatus.idle);
  });

  test('partial EPG search keeps the valid programs and reports an issue', () async {
    final api = _SearchableLiveTvApi();
    when(() => client.serverType).thenReturn(ServerType.plex);
    when(() => client.liveTvApi).thenReturn(api);
    _stubChannels(api, [_channel('c0')]);
    when(() => _guide(api)).thenAnswer((_) async => {'Items': []});

    final now = DateTime.utc(2026, 11, 14, 17);
    final hit = <String, dynamic>{
      'Id': 'soccer-1',
      'Type': 'Program',
      'ChannelId': 'c0',
      'Name': 'Soccer Final',
      'StartDate': now.add(const Duration(minutes: 30)).toIso8601String(),
      'EndDate': now.add(const Duration(minutes: 90)).toIso8601String(),
    };
    when(() => api.searchProgramTitles(
      'soccer', isCurrent: any(named: 'isCurrent'),
    )).thenThrow(LiveTvPartialProgramSearchException(
      [hit], StateError('One provider timed out'),
    ));

    final vm = LiveTvGuideViewModel(client, now: () => now);
    addTearDown(vm.dispose);
    await vm.load(windowStart: now);
    vm.setChannelQuery('soccer');
    await pumpEventQueue();

    expect(vm.programSearchStatus, GuideProgramSearchStatus.partial);
    expect(vm.searchingProgramTitles, isFalse);
    expect(vm.filteredChannels.map((ch) => ch.id), ['c0']);
    expect(vm.futureSearchMatchForChannel('c0'), isNull);
  });

  test('Plex retry keeps old future results and merges partial replies', () async {
    final api = _IncrementalSearchableLiveTvApi();
    when(() => client.serverType).thenReturn(ServerType.plex);
    when(() => client.liveTvApi).thenReturn(api);
    when(() => _guide(api)).thenAnswer((_) async => {'Items': []});
    _stubChannels(api, [
      _channel('tsn', number: '10'),
      _channel('espn', number: '20'),
      _channel('cnn', number: '30'),
    ]);
    final now = DateTime.utc(2026, 11, 14, 17);
    final future = now.add(const Duration(days: 1));

    Map<String, dynamic> hit(
      String id,
      String channel,
      DateTime start, {
      bool sports = true,
    }) => {
      'Id': id,
      'Type': 'Program',
      'Name': 'Soccer $id',
      'ChannelId': channel,
      'IsSports': sports,
      'StartDate': start.toIso8601String(),
      'EndDate': start.add(const Duration(hours: 1)).toIso8601String(),
    };
    final oldTsn = hit('tsn-showing', 'tsn', future);
    final oldEspn = hit('espn-showing', 'espn', future);
    final newTsn = hit('tsn-showing', 'tsn',
        now.add(const Duration(minutes: 30)));
    final newCnn = hit('cnn-showing', 'cnn', future, sports: false);

    var searches = 0;
    late void Function(List<Map<String, dynamic>>) publishRetry;
    final retryResult = Completer<List<Map<String, dynamic>>>();
    when(() => api.searchProgramTitlesIncrementally(
      'soccer',
      isCurrent: any(named: 'isCurrent'),
      onBatch: any(named: 'onBatch'),
    )).thenAnswer((call) {
      searches++;
      if (searches == 1) {
        return Future<List<Map<String, dynamic>>>.error(
          LiveTvPartialProgramSearchException(
            [oldTsn, oldEspn], StateError('DVR offline'),
          ),
        );
      }
      if (searches == 2) {
        publishRetry = call.namedArguments[#onBatch]
            as void Function(List<Map<String, dynamic>>);
        return retryResult.future;
      }
      return Future.value([newTsn]);
    });

    final vm = LiveTvGuideViewModel(client, now: () => now);
    addTearDown(vm.dispose);
    await vm.load(windowStart: now);
    vm.setChannelQuery('soccer');
    await pumpEventQueue();
    expect(vm.programSearchStatus, GuideProgramSearchStatus.partial);
    expect(vm.filteredChannels.map((c) => c.id), ['tsn', 'espn']);
    expect(vm.futureSearchMatchForChannel('tsn')?.start, future);

    vm.retryProgramTitleSearch();
    expect(vm.searchingProgramTitles, isTrue);
    expect(vm.filteredChannels.map((c) => c.id), ['tsn', 'espn']);
    expect(vm.futureSearchMatchForChannel('tsn')?.start, future);
    expect(vm.futureSearchMatchForChannel('espn')?.start, future);
    expect(vm.nextSearchMatchForChannel('tsn')?.start, future);

    publishRetry([newTsn, newCnn]);
    // Incremental batches must not drop known future-only rows or move their
    // next-airing labels while another provider is still loading.
    expect(vm.filteredChannels.map((c) => c.id), ['tsn', 'espn']);
    expect(vm.futureSearchMatchForChannel('tsn')?.start, future);

    retryResult.completeError(LiveTvPartialProgramSearchException(
      [newTsn, newCnn], StateError('Cloud search failed'),
    ));
    await pumpEventQueue();
    expect(vm.programSearchStatus, GuideProgramSearchStatus.partial);
    expect(vm.searchingProgramTitles, isFalse);
    expect(vm.filteredChannels.map((c) => c.id), ['tsn', 'espn', 'cnn']);
    expect(vm.futureSearchMatchForChannel('tsn'), isNull);
    expect(vm.futureSearchMatchForChannel('espn')?.start, future);
    expect(vm.futureSearchMatchForChannel('cnn')?.start, future);

    // A successful retry replaces old partial hits rather than keeping them.
    vm.retryProgramTitleSearch();
    await pumpEventQueue();
    expect(vm.programSearchStatus, GuideProgramSearchStatus.complete);
    expect(vm.filteredChannels.map((c) => c.id), ['tsn']);
    expect(vm.futureSearchMatchForChannel('espn'), isNull);
    expect(searches, 3);
  });

  test('merged retry hits use showing IDs and prefer newer metadata', () {
    final now = DateTime.utc(2026, 11, 14, 17);
    GuideTitleMatch match(
      String id, String title, DateTime start,
    ) => GuideTitleMatch(
      channelId: 'tsn',
      programId: id,
      title: title,
      start: start,
      end: start.add(const Duration(hours: 1)),
    );
    final old = match('showing', 'Soccer first', now);
    final revised = match('showing', 'Soccer revised',
        now.add(const Duration(minutes: 30)));
    final other = match('different', 'Soccer other', now);
    final merged = mergeGuideTitleMatches([old, other], [revised]);
    expect(merged, hasLength(2));
    expect(merged.first.title, 'Soccer revised');
    expect(merged.last.programId, 'different');
  });

  test('unwrapped incremental retry errors retain both result sets', () async {
    final api = _IncrementalSearchableLiveTvApi();
    when(() => client.serverType).thenReturn(ServerType.plex);
    when(() => client.liveTvApi).thenReturn(api);
    when(() => _guide(api)).thenAnswer((_) async => {'Items': []});
    _stubChannels(api, [
      _channel('tsn', number: '10'),
      _channel('espn', number: '20'),
    ]);
    final now = DateTime.utc(2026, 11, 14, 17);
    Map<String, dynamic> hit(String id, String channel) => {
      'Id': id,
      'Type': 'Program',
      'ChannelId': channel,
      'Name': 'Soccer $id',
      'StartDate': now.add(const Duration(days: 1)).toIso8601String(),
      'EndDate': now.add(const Duration(days: 1, hours: 1)).toIso8601String(),
    };
    final tsn = hit('first', 'tsn');
    final espn = hit('second', 'espn');
    final pending = Completer<List<Map<String, dynamic>>>();
    late void Function(List<Map<String, dynamic>>) publish;
    var calls = 0;
    when(() => api.searchProgramTitlesIncrementally(
      'soccer',
      isCurrent: any(named: 'isCurrent'),
      onBatch: any(named: 'onBatch'),
    )).thenAnswer((call) {
      calls++;
      if (calls == 1) {
        return Future<List<Map<String, dynamic>>>.error(
          LiveTvPartialProgramSearchException(
            [tsn], StateError('First search incomplete'),
          ),
        );
      }
      publish = call.namedArguments[#onBatch]
          as void Function(List<Map<String, dynamic>>);
      return pending.future;
    });

    final vm = LiveTvGuideViewModel(client, now: () => now);
    addTearDown(vm.dispose);
    await vm.load(windowStart: now);
    vm.setChannelQuery('soccer');
    await pumpEventQueue();
    vm.retryProgramTitleSearch();
    publish([espn]);
    expect(vm.filteredChannels.map((c) => c.id), ['tsn']);
    pending.completeError(StateError('Unexpected provider error'));
    await pumpEventQueue();

    expect(vm.programSearchStatus, GuideProgramSearchStatus.partial);
    expect(vm.filteredChannels.map((c) => c.id), ['tsn', 'espn']);
    expect(vm.futureSearchMatchForChannel('tsn'), isNotNull);
    expect(vm.futureSearchMatchForChannel('espn'), isNotNull);
  });

  test('Plex guide titles use the DVR search API', () async {
    final api = _SearchableLiveTvApi();
    when(() => client.serverType).thenReturn(ServerType.plex);
    when(() => client.liveTvApi).thenReturn(api);
    when(() => api.searchProgramTitles(
      'soccer', isCurrent: any(named: 'isCurrent'),
    )).thenAnswer((_) async => [{
      'Id': 'airing-2-123-4',
      'Type': 'Program',
      'ChannelId': 'channel-2-4',
      'Name': 'Soccer',
      'StartDate': '2026-11-14T19:00:00Z',
      'EndDate': '2026-11-14T20:00:00Z',
    }]);
    final result = await searchGuideProgramTitles(
      client, 'soccer', isCurrent: () => true,
    );
    expect(result.single.channelId, 'channel-2-4');
  });

  test('Plex DVR matches appear before its cloud search finishes', () async {
    final api = _IncrementalSearchableLiveTvApi();
    when(() => client.serverType).thenReturn(ServerType.plex);
    when(() => client.liveTvApi).thenReturn(api);
    when(() => _guide(api)).thenAnswer((_) async => {'Items': []});
    _stubChannels(api, [_channel('dvr'), _channel('free')]);

    final pending = Completer<List<Map<String, dynamic>>>();
    late void Function(List<Map<String, dynamic>>) publish;
    when(
      () => api.searchProgramTitlesIncrementally(
        'soccer',
        isCurrent: any(named: 'isCurrent'),
        onBatch: any(named: 'onBatch'),
      ),
    ).thenAnswer((invocation) {
      publish = invocation.namedArguments[#onBatch]
          as void Function(List<Map<String, dynamic>>);
      return pending.future;
    });

    final now = DateTime.utc(2026, 11, 14, 17);
    final vm = LiveTvGuideViewModel(client, now: () => now);
    addTearDown(vm.dispose);
    await vm.load(windowStart: now);
    vm.setChannelQuery('soccer');
    expect(vm.filteredChannels, isEmpty);
    expect(vm.searchingProgramTitles, isTrue);

    Map<String, dynamic> hit(String id, String channel, DateTime start) => {
      'Id': id,
      'Type': 'Program',
      'Name': 'Soccer',
      'ChannelId': channel,
      'StartDate': start.toIso8601String(),
      'EndDate': start.add(const Duration(hours: 1)).toIso8601String(),
    };
    final future = hit('tomorrow', 'dvr', now.add(const Duration(days: 1)));
    publish([future]);
    expect(vm.futureSearchMatchForChannel('dvr'), isNull);
    expect(vm.searchingProgramTitles, isTrue);

    final dvr = hit('dvr-now', 'dvr', now.add(const Duration(minutes: 30)));
    publish([dvr]);
    expect(vm.filteredChannels.map((ch) => ch.id), ['dvr']);
    expect(vm.searchingProgramTitles, isTrue);

    final free = hit('free-now', 'free', now.add(const Duration(minutes: 40)));
    // The repeated DVR item must not duplicate a match.
    publish([dvr, free]);
    expect(vm.filteredChannels.map((ch) => ch.id), ['dvr', 'free']);

    pending.complete([future, dvr, free]);
    await Future<void>.delayed(Duration.zero);
    expect(vm.searchingProgramTitles, isFalse);
    expect(vm.filteredChannels.map((ch) => ch.id), ['dvr', 'free']);
    expect(
      vm.nextSearchMatchForChannel(
        'dvr',
        after: now.add(const Duration(hours: 2)),
      )?.start,
      now.add(const Duration(days: 1)),
    );
  });

  test('holds future-only channels until the full search completes', () async {
    final api = _IncrementalSearchableLiveTvApi();
    when(() => client.serverType).thenReturn(ServerType.plex);
    when(() => client.liveTvApi).thenReturn(api);
    when(() => _guide(api)).thenAnswer((_) async => {'Items': []});
    _stubChannels(api, [_channel('dvr'), _channel('free')]);

    final pending = Completer<List<Map<String, dynamic>>>();
    late void Function(List<Map<String, dynamic>>) publish;
    when(
      () => api.searchProgramTitlesIncrementally(
        'silo',
        isCurrent: any(named: 'isCurrent'),
        onBatch: any(named: 'onBatch'),
      ),
    ).thenAnswer((invocation) {
      publish = invocation.namedArguments[#onBatch]
          as void Function(List<Map<String, dynamic>>);
      return pending.future;
    });

    final now = DateTime.utc(2026, 11, 14, 17);
    final vm = LiveTvGuideViewModel(client, now: () => now);
    addTearDown(vm.dispose);
    await vm.load(windowStart: now);
    vm.setChannelQuery('silo');

    Map<String, dynamic> hit(String id, String channel, DateTime start) => {
      'Id': id,
      'Type': 'Program',
      'Name': 'Silo',
      'ChannelId': channel,
      'StartDate': start.toIso8601String(),
      'EndDate': start.add(const Duration(hours: 1)).toIso8601String(),
    };
    final tomorrow = hit('tomorrow', 'dvr', now.add(const Duration(days: 1)));
    final tonightStart = vm.windowEnd.add(const Duration(minutes: 30));
    final tonight = hit('tonight', 'free', tonightStart);

    publish([tomorrow]);
    expect(vm.filteredChannels, isEmpty);
    expect(vm.searchingProgramTitles, isTrue);
    expect(vm.futureSearchMatchForChannel('dvr'), isNull);

    // Later providers may return earlier airings. Wait before showing future-only rows.
    publish([tonight]);
    expect(vm.filteredChannels, isEmpty);
    expect(vm.searchingProgramTitles, isTrue);
    expect(vm.futureSearchMatchForChannel('free'), isNull);

    pending.complete([tomorrow, tonight]);
    await Future<void>.delayed(Duration.zero);
    expect(vm.searchingProgramTitles, isFalse);
    expect(vm.filteredChannels.map((c) => c.id), ['dvr', 'free']);
    expect(vm.futureSearchMatchForChannel('dvr')?.title, 'Silo');
    expect(vm.futureSearchMatchForChannel('free')?.start, tonightStart);
    expect(vm.futureSearchMatchForChannel('free')?.start, tonightStart);
  });

  test('search keeps future-only channels without including unrelated ones', () async {
    final api = _SearchableLiveTvApi();
    when(() => client.serverType).thenReturn(ServerType.plex);
    when(() => client.liveTvApi).thenReturn(api);
    when(() => _guide(api)).thenAnswer((_) async => {'Items': []});
    _stubChannels(api, [
      {'Id': 'tsn', 'Name': 'TSN'},
      {'Id': 'onesoccer', 'Name': 'OneSoccer'},
      {'Id': 'soccertv', 'Name': 'Soccer TV'},
      {'Id': 'espn', 'Name': 'ESPN'},
    ]);

    final now = DateTime.utc(2026, 11, 14, 17);
    final future = now.add(const Duration(days: 1));
    final inWindow = now.add(const Duration(minutes: 90));
    Map<String, dynamic> match(
      String id, String channelId, String title, DateTime start,
    ) => {
      'Id': id,
      'Type': 'Program',
      'Name': title,
      'ChannelId': channelId,
      'StartDate': start.toIso8601String(),
      'EndDate': start.add(const Duration(minutes: 30)).toIso8601String(),
    };
    when(() => api.searchProgramTitles(
      'soccer', isCurrent: any(named: 'isCurrent'),
    )).thenAnswer((_) async => [
      match('tsn-future', 'tsn', 'Soccer: Portugal vs USA', future),
      match('onesoccer-visible', 'onesoccer', 'Soccer Highlights', inWindow),
    ]);

    final vm = LiveTvGuideViewModel(client, now: () => now);
    addTearDown(vm.dispose);
    await vm.load(windowStart: now);
    vm.setChannelQuery('soccer');
    await Future<void>.delayed(Duration.zero);

    expect(
      vm.filteredChannels.map((channel) => channel.id),
      ['tsn', 'onesoccer', 'soccertv'],
    );
    expect(vm.futureSearchMatchForChannel('tsn')?.title,
        'Soccer: Portugal vs USA');
    expect(vm.futureSearchMatchForChannel('onesoccer'), isNull);
    expect(vm.futureSearchMatchForChannel('soccertv'), isNull);
    expect(vm.futureSearchMatchForChannel('espn'), isNull);

    expect(vm.nextSearchMatchForChannel('onesoccer')?.title,
        'Soccer Highlights');
    expect(
      vm.nextSearchMatchForChannel('onesoccer',
          after: inWindow.add(const Duration(minutes: 30))),
      isNull,
    );
    expect(vm.nextSearchMatchForChannel('tsn')?.start, future);
    vm.setChannelQuery('');
    expect(vm.futureSearchMatchForChannel('tsn'), isNull);
    expect(vm.nextSearchMatchForChannel('tsn'), isNull);
  });

  group('full guide reload refreshes active program searches', () {
    late _SearchableLiveTvApi api;
    late LiveTvGuideViewModel vm;
    late DateTime clock;
    final start = DateTime.utc(2026, 11, 14, 17);

    Map<String, dynamic> airing(String id, String channelId) => {
      'Id': id,
      'Type': 'Program',
      'ChannelId': channelId,
      'Name': 'Soccer $id',
      'IsSports': true,
      'StartDate': start.add(const Duration(days: 1)).toIso8601String(),
      'EndDate': start.add(const Duration(days: 1, hours: 1))
          .toIso8601String(),
    };

    setUp(() {
      clock = start;
      api = _SearchableLiveTvApi();
      when(() => client.liveTvApi).thenReturn(api);
      when(() => _guide(api)).thenAnswer((_) async => {'Items': []});
      _stubChannels(api, [_channel('tsn'), _channel('espn')]);
      vm = LiveTvGuideViewModel(client, now: () => clock);
      addTearDown(vm.dispose);
    });

    test('full reload replaces stale category search results', () async {
      var hits = [airing('old', 'tsn')];
      when(() => api.searchProgramTitles(
        'soccer', isCurrent: any(named: 'isCurrent'),
      )).thenAnswer((_) async => hits);

      await vm.load(windowStart: start);
      vm.setFilter(GuideFilter.sports);
      await pumpEventQueue();
      vm.setChannelQuery('soccer');
      await pumpEventQueue();
      expect(vm.filteredChannels.map((c) => c.id), ['tsn']);

      hits = [airing('new', 'espn')];
      await vm.load(windowStart: start);
      await pumpEventQueue();

      expect(vm.channelQuery, 'soccer');
      expect(vm.searchingProgramTitles, isFalse);
      expect(vm.filteredChannels.map((c) => c.id), ['espn']);
      expect(vm.futureSearchMatchForChannel('tsn'), isNull);
      expect(vm.futureSearchMatchForChannel('espn')?.title, 'Soccer new');
      verify(() => api.searchProgramTitles(
        'soccer', isCurrent: any(named: 'isCurrent'),
      )).called(2);
    });

    test('stale re-entry refreshes search but a fresh re-entry does not', () async {
      when(() => api.searchProgramTitles(
        'soccer', isCurrent: any(named: 'isCurrent'),
      )).thenAnswer((_) async => [airing('match', 'espn')]);

      await vm.load(windowStart: start);
      vm.setChannelQuery('soccer');
      await pumpEventQueue();
      clock = start.add(const Duration(minutes: 29));
      await vm.reloadIfStale(windowStart: start);
      await pumpEventQueue();
      verify(() => api.searchProgramTitles(
        'soccer', isCurrent: any(named: 'isCurrent'),
      )).called(1);

      clock = start.add(const Duration(minutes: 31));
      await vm.reloadIfStale(windowStart: start);
      await pumpEventQueue();
      verify(() => api.searchProgramTitles(
        'soccer', isCurrent: any(named: 'isCurrent'),
      )).called(1);
    });

    test('moving dates and time windows never reissues title search', () async {
      when(() => api.searchProgramTitles(
        'soccer', isCurrent: any(named: 'isCurrent'),
      )).thenAnswer((_) async => [airing('match', 'tsn')]);
      await vm.load(windowStart: start);
      vm.setChannelQuery('soccer');
      await pumpEventQueue();

      await vm.setWindowStart(start.add(const Duration(minutes: 30)));
      await vm.shiftWindow(const Duration(hours: 3));
      await vm.setDate(start.add(const Duration(days: 1)));
      await vm.setWindow(const Duration(hours: 3));
      await pumpEventQueue();

      expect(vm.channelQuery, 'soccer');
      verify(() => api.searchProgramTitles(
        'soccer', isCurrent: any(named: 'isCurrent'),
      )).called(1);
    });


    test('old search response during full reload cannot supersede its listings',
        () async {
      _stubChannels(api, [
        {..._channel('soccertv'), 'Name': 'Soccer TV'},
        _channel('tsn'),
        _channel('espn'),
      ]);
      final stale = Completer<List<Map<String, dynamic>>>();
      final delayedGuide = Completer<Map<String, dynamic>>();
      var refreshing = false;
      var calls = 0;
      when(() => _guide(api)).thenAnswer((_) =>
          refreshing ? delayedGuide.future : Future.value({'Items': []}));
      when(() => api.searchProgramTitles(
        'soccer', isCurrent: any(named: 'isCurrent'),
      )).thenAnswer((_) {
        calls++;
        return calls == 1
            ? stale.future
            : Future.value([airing('fresh', 'espn')]);
      });

      await vm.load(windowStart: start);
      vm.setChannelQuery('soccer');
      expect(vm.searchingProgramTitles, isTrue);

      refreshing = true;
      final loading = vm.load(windowStart: start);
      await pumpEventQueue();
      expect(vm.state, GuideState.loading);

      // This hit would add TSN to the search rows and invalidate the
      // in-flight guide page if the old search were still allowed to publish.
      stale.complete([airing('stale', 'tsn')]);
      await pumpEventQueue();
      expect(vm.futureSearchMatchForChannel('tsn'), isNull);
      expect(vm.searchingProgramTitles, isFalse);

      delayedGuide.complete({'Items': []});
      await loading;
      await pumpEventQueue();

      expect(vm.state, GuideState.ready);
      expect(calls, 2);
      expect(vm.channelQuery, 'soccer');
      expect(vm.filteredChannels.map((c) => c.id).toSet(),
          {'soccertv', 'espn'});
      expect(vm.futureSearchMatchForChannel('tsn'), isNull);
      expect(vm.futureSearchMatchForChannel('espn')?.title, 'Soccer fresh');
    });

    test('query changed during full reload searches only the latest text',
        () async {
      final delayedGuide = Completer<Map<String, dynamic>>();
      var refreshing = false;
      when(() => _guide(api)).thenAnswer((_) =>
          refreshing ? delayedGuide.future : Future.value({'Items': []}));
      when(() => api.searchProgramTitles(
        'soccer', isCurrent: any(named: 'isCurrent'),
      )).thenAnswer((_) async => [airing('old', 'tsn')]);
      when(() => api.searchProgramTitles(
        'news', isCurrent: any(named: 'isCurrent'),
      )).thenAnswer((_) async => [
        {...airing('bulletin', 'espn'), 'Name': 'Evening News'},
      ]);

      await vm.load(windowStart: start);
      vm.setChannelQuery('soccer');
      await pumpEventQueue();
      expect(vm.futureSearchMatchForChannel('tsn'), isNotNull);

      refreshing = true;
      final loading = vm.load(windowStart: start);
      await pumpEventQueue();
      vm.setChannelQuery('news');
      expect(vm.channelQuery, 'news');
      expect(vm.searchingProgramTitles, isFalse);
      verifyNever(() => api.searchProgramTitles(
        'news', isCurrent: any(named: 'isCurrent'),
      ));

      delayedGuide.complete({'Items': []});
      await loading;
      await pumpEventQueue();

      expect(vm.state, GuideState.ready);
      expect(vm.channelQuery, 'news');
      expect(vm.searchingProgramTitles, isFalse);
      expect(vm.filteredChannels.map((c) => c.id), ['espn']);
      expect(vm.futureSearchMatchForChannel('tsn'), isNull);
      expect(vm.futureSearchMatchForChannel('espn')?.title, 'Evening News');
      verify(() => api.searchProgramTitles(
        'news', isCurrent: any(named: 'isCurrent'),
      )).called(1);
    });


    test('clearing search mid-reload restores the unfiltered channel rows',
        () async {
      _stubChannels(api, [
        {..._channel('soccertv'), 'Name': 'Soccer TV'},
        _channel('espn'),
      ]);
      final delayedGuide = Completer<Map<String, dynamic>>();
      var refreshing = false;
      when(() => _guide(api)).thenAnswer((_) =>
          refreshing ? delayedGuide.future : Future.value({'Items': []}));
      when(() => api.searchProgramTitles(
        'soccer', isCurrent: any(named: 'isCurrent'),
      )).thenAnswer((_) async => []);

      await vm.load(windowStart: start);
      vm.setChannelQuery('soccer');
      await pumpEventQueue();
      expect(vm.filteredChannels.map((c) => c.id), ['soccertv']);

      refreshing = true;
      final loading = vm.load(windowStart: start);
      await pumpEventQueue();
      vm.setChannelQuery('');
      expect(vm.channelQuery, '');

      delayedGuide.complete({'Items': []});
      await loading;
      await pumpEventQueue();

      expect(vm.state, GuideState.ready);
      expect(vm.filteredChannels.map((c) => c.id).toSet(),
          {'soccertv', 'espn'});
      expect(vm.channelQuery, '');
      expect(vm.searchingProgramTitles, isFalse);
    });


    test('date navigation completes a full reload pending title search',
        () async {
      _stubChannels(api, [
        {..._channel('soccertv'), 'Name': 'Soccer TV'},
        _channel('tsn'),
        _channel('espn'),
      ]);
      final oldGuide = Completer<Map<String, dynamic>>();
      var blockReload = false;
      when(() => _guide(api)).thenAnswer((call) {
        final from = call.namedArguments[#startDate] as DateTime;
        if (blockReload && from.isAtSameMomentAs(start)) {
          return oldGuide.future;
        }
        return Future.value({'Items': []});
      });
      var searches = 0;
      when(() => api.searchProgramTitles(
        'soccer', isCurrent: any(named: 'isCurrent'),
      )).thenAnswer((_) {
        searches++;
        return Future.value([
          airing(searches == 1 ? 'old' : 'fresh',
              searches == 1 ? 'tsn' : 'espn'),
        ]);
      });

      await vm.load(windowStart: start);
      vm.setChannelQuery('soccer');
      await pumpEventQueue();
      expect(searches, 1);
      expect(vm.filteredChannels.map((c) => c.id), contains('tsn'));

      blockReload = true;
      final fullReload = vm.load(windowStart: start);
      await pumpEventQueue();
      expect(vm.state, GuideState.loading);

      // This date reload supersedes Now while its listings are still pending.
      await vm.setDate(start.add(const Duration(days: 1)));
      await pumpEventQueue();
      expect(vm.state, GuideState.ready);
      expect(searches, 2);
      expect(vm.filteredChannels.map((c) => c.id).toSet(),
          {'soccertv', 'espn'});

      oldGuide.complete({'Items': []});
      await fullReload;
      await pumpEventQueue();
      expect(searches, 2);
      expect(vm.filteredChannels.map((c) => c.id).toSet(),
          {'soccertv', 'espn'});
    });

    test('query change during superseding date reload is searched only once',
        () async {
      _stubChannels(api, [
        {..._channel('soccertv'), 'Name': 'Soccer TV'},
        _channel('tsn'),
        _channel('espn'),
      ]);
      final oldGuide = Completer<Map<String, dynamic>>();
      final newGuide = Completer<Map<String, dynamic>>();
      var blockReload = false;
      final later = start.add(const Duration(days: 1));
      when(() => _guide(api)).thenAnswer((call) {
        final from = call.namedArguments[#startDate] as DateTime;
        if (!blockReload) return Future.value({'Items': []});
        return from.isAtSameMomentAs(start)
            ? oldGuide.future : newGuide.future;
      });
      when(() => api.searchProgramTitles(
        'soccer', isCurrent: any(named: 'isCurrent'),
      )).thenAnswer((_) async => [airing('old', 'tsn')]);
      when(() => api.searchProgramTitles(
        'news', isCurrent: any(named: 'isCurrent'),
      )).thenAnswer((_) async => [
        {...airing('bulletin', 'espn'), 'Name': 'Evening News'},
      ]);

      await vm.load(windowStart: start);
      vm.setChannelQuery('soccer');
      await pumpEventQueue();

      blockReload = true;
      final fullReload = vm.load(windowStart: start);
      await pumpEventQueue();
      final dateReload = vm.setDate(later);
      await pumpEventQueue();
      vm.setChannelQuery('news');
      verifyNever(() => api.searchProgramTitles(
        'news', isCurrent: any(named: 'isCurrent'),
      ));

      newGuide.complete({'Items': []});
      await dateReload;
      await pumpEventQueue();
      expect(vm.channelQuery, 'news');
      expect(vm.filteredChannels.map((c) => c.id), ['espn']);
      verify(() => api.searchProgramTitles(
        'news', isCurrent: any(named: 'isCurrent'),
      )).called(1);

      oldGuide.complete({'Items': []});
      await fullReload;
      await pumpEventQueue();
      verifyNever(() => api.searchProgramTitles(
        'news', isCurrent: any(named: 'isCurrent'),
      ));
    });

    test('window paging during full reload completes the deferred search',
        () async {
      _stubChannels(api, [
        {..._channel('soccertv'), 'Name': 'Soccer TV'},
        _channel('tsn'),
        _channel('espn'),
      ]);
      final oldGuide = Completer<Map<String, dynamic>>();
      var blockReload = false;
      when(() => _guide(api)).thenAnswer((call) {
        final from = call.namedArguments[#startDate] as DateTime;
        if (blockReload && from.isAtSameMomentAs(start)) {
          return oldGuide.future;
        }
        return Future.value({'Items': []});
      });
      var searches = 0;
      when(() => api.searchProgramTitles(
        'soccer', isCurrent: any(named: 'isCurrent'),
      )).thenAnswer((_) {
        searches++;
        return Future.value([
          airing(searches == 1 ? 'old' : 'fresh',
              searches == 1 ? 'tsn' : 'espn'),
        ]);
      });

      await vm.load(windowStart: start);
      vm.setChannelQuery('soccer');
      await pumpEventQueue();

      blockReload = true;
      final fullReload = vm.load(windowStart: start);
      await pumpEventQueue();
      await vm.setWindowStart(start.add(const Duration(hours: 3)));
      await pumpEventQueue();

      expect(vm.state, GuideState.ready);
      expect(searches, 2);
      expect(vm.filteredChannels.map((c) => c.id).toSet(),
          {'soccertv', 'espn'});
      oldGuide.complete({'Items': []});
      await fullReload;
      expect(searches, 2);
    });



    test('category retyping is not deferred behind an obsolete full reload',
        () async {
      final oldGuide = Completer<Map<String, dynamic>>();
      final sportsGuide = Completer<Map<String, dynamic>>();
      var reloading = false;
      when(() => _guide(api)).thenAnswer((_) =>
          reloading ? oldGuide.future : Future.value({'Items': []}));
      when(() => _guide(api, category: GuideFilter.sports))
          .thenAnswer((_) => sportsGuide.future);
      when(() => api.searchProgramTitles(
        'soccer', isCurrent: any(named: 'isCurrent'),
      )).thenAnswer((_) async => [airing('old', 'tsn')]);
      when(() => api.searchProgramTitles(
        'hockey', isCurrent: any(named: 'isCurrent'),
      )).thenAnswer((_) async => [
        {...airing('game', 'espn'), 'Name': 'Hockey playoffs'},
      ]);

      await vm.load(windowStart: start);
      vm.setChannelQuery('soccer');
      await pumpEventQueue();

      reloading = true;
      final fullReload = vm.load(windowStart: start);
      await pumpEventQueue();
      vm.clearChannelSearchForCategoryChange();
      vm.setFilter(GuideFilter.sports);
      await pumpEventQueue();
      vm.setChannelQuery('hockey');
      await pumpEventQueue();

      expect(vm.channelQuery, 'hockey');
      expect(vm.programSearchStatus, GuideProgramSearchStatus.complete);
      verify(() => api.searchProgramTitles(
        'hockey', isCurrent: any(named: 'isCurrent'),
      )).called(1);

      sportsGuide.complete({'Items': []});
      await pumpEventQueue();
      oldGuide.complete({'Items': []});
      await fullReload;
      await pumpEventQueue();

      expect(vm.filter, GuideFilter.sports);
      expect(vm.channelQuery, 'hockey');
      expect(vm.filteredChannels.map((c) => c.id), ['espn']);
      expect(vm.futureSearchMatchForChannel('espn')?.title, 'Hockey playoffs');
    });

    test('sorting during a full reload hands the title refresh to lazy paging',
        () async {
      _stubChannels(api, [
        {..._channel('soccertv'), 'Name': 'Soccer TV'},
        _channel('tsn'),
        _channel('espn'),
      ]);
      final oldGuide = Completer<Map<String, dynamic>>();
      var delayNextGuide = false;
      when(() => _guide(api)).thenAnswer((_) {
        if (delayNextGuide) {
          delayNextGuide = false;
          return oldGuide.future;
        }
        return Future.value({'Items': []});
      });
      var searches = 0;
      when(() => api.searchProgramTitles(
        'soccer', isCurrent: any(named: 'isCurrent'),
      )).thenAnswer((_) {
        searches++;
        return Future.value([
          airing(searches == 1 ? 'old' : 'fresh',
              searches == 1 ? 'tsn' : 'espn'),
        ]);
      });

      await vm.load(windowStart: start);
      vm.setChannelQuery('soccer');
      await pumpEventQueue();
      expect(searches, 1);

      delayNextGuide = true;
      final fullReload = vm.load(windowStart: start);
      await pumpEventQueue();
      vm.setSortBy(ChannelSortBy.name);
      await pumpEventQueue();

      expect(vm.state, GuideState.ready);
      expect(searches, 2);
      expect(vm.filteredChannels.map((c) => c.id).toSet(),
          {'soccertv', 'espn'});

      oldGuide.complete({'Items': []});
      await fullReload;
      await pumpEventQueue();
      expect(searches, 2);
    });

    test('two quick window shifts resume only after the latest lazy page',
        () async {
      _stubChannels(api, [
        {..._channel('soccertv'), 'Name': 'Soccer TV'},
        _channel('tsn'),
        _channel('espn'),
      ]);
      final oldFullPage = Completer<Map<String, dynamic>>();
      final oldWindowPage = Completer<Map<String, dynamic>>();
      final firstWindow = start.add(const Duration(hours: 3));
      final latestWindow = start.add(const Duration(hours: 6));
      var delaying = false;
      when(() => _guide(api)).thenAnswer((invocation) {
        if (!delaying) return Future.value({'Items': []});
        final from = invocation.namedArguments[#startDate] as DateTime;
        if (from.isAtSameMomentAs(start)) return oldFullPage.future;
        if (from.isAtSameMomentAs(firstWindow)) return oldWindowPage.future;
        return Future.value({'Items': []});
      });
      var searches = 0;
      when(() => api.searchProgramTitles(
        'soccer', isCurrent: any(named: 'isCurrent'),
      )).thenAnswer((_) {
        searches++;
        return Future.value([
          airing(searches == 1 ? 'old' : 'fresh',
              searches == 1 ? 'tsn' : 'espn'),
        ]);
      });

      await vm.load(windowStart: start);
      vm.setChannelQuery('soccer');
      await pumpEventQueue();
      expect(searches, 1);

      delaying = true;
      final fullReload = vm.load(windowStart: start);
      await pumpEventQueue();
      final firstShift = vm.setWindowStart(firstWindow);
      await pumpEventQueue();
      expect(searches, 1);

      await vm.setWindowStart(latestWindow);
      await pumpEventQueue();
      expect(vm.windowStart, latestWindow);
      expect(vm.state, GuideState.ready);
      expect(searches, 2);
      expect(vm.filteredChannels.map((c) => c.id).toSet(),
          {'soccertv', 'espn'});

      oldWindowPage.complete({'Items': []});
      await firstShift;
      oldFullPage.complete({'Items': []});
      await fullReload;
      await pumpEventQueue();
      expect(searches, 2);
      expect(vm.windowStart, latestWindow);
    });

    test('category selection clears the search and rejects its late reply',
        () async {
      final pending = Completer<List<Map<String, dynamic>>>();
      when(() => api.searchProgramTitles(
        'soccer', isCurrent: any(named: 'isCurrent'),
      )).thenAnswer((_) => pending.future);
      when(() => _guide(api, category: GuideFilter.sports))
          .thenAnswer((_) async => {'Items': []});

      await vm.load(windowStart: start);
      vm.setChannelQuery('soccer');
      expect(vm.searchingProgramTitles, isTrue);

      vm.clearChannelSearchForCategoryChange();
      vm.setFilter(GuideFilter.sports);
      await pumpEventQueue();
      expect(vm.channelQuery, '');
      expect(vm.programSearchStatus, GuideProgramSearchStatus.idle);
      expect(vm.searchingProgramTitles, isFalse);

      pending.complete([airing('stale', 'tsn')]);
      await pumpEventQueue();
      expect(vm.futureSearchMatchForChannel('tsn'), isNull);
      expect(vm.channelQuery, '');
      expect(vm.filter, GuideFilter.sports);
    });

    test('category selection cancels a full reload pending title refresh',
        () async {
      _stubChannels(api, [
        {..._channel('soccertv'), 'Name': 'Soccer TV'},
        _channel('tsn'),
      ]);
      final delayedGuide = Completer<Map<String, dynamic>>();
      var reloading = false;
      when(() => _guide(api)).thenAnswer((_) =>
          reloading ? delayedGuide.future : Future.value({'Items': []}));
      when(() => _guide(api, category: GuideFilter.sports))
          .thenAnswer((_) async => {'Items': []});
      var searches = 0;
      when(() => api.searchProgramTitles(
        'soccer', isCurrent: any(named: 'isCurrent'),
      )).thenAnswer((_) {
        searches++;
        return Future.value([airing('match', 'tsn')]);
      });

      await vm.load(windowStart: start);
      vm.setChannelQuery('soccer');
      await pumpEventQueue();
      expect(searches, 1);

      reloading = true;
      final refresh = vm.load(windowStart: start);
      await pumpEventQueue();
      expect(vm.state, GuideState.loading);
      vm.clearChannelSearchForCategoryChange();
      vm.setFilter(GuideFilter.sports);
      await pumpEventQueue();

      delayedGuide.complete({'Items': []});
      await refresh;
      await pumpEventQueue();
      expect(vm.channelQuery, '');
      expect(vm.programSearchStatus, GuideProgramSearchStatus.idle);
      expect(searches, 1);
    });


    test(
      'query typed during a failed reload still runs without hiding guide error',
      () async {
      _stubChannels(api, [
        {..._channel('soccertv'), 'Name': 'Soccer TV'},
        {..._channel('hockeytv'), 'Name': 'Hockey TV'},
        _channel('espn'),
      ]);
      final failedPage = Completer<Map<String, dynamic>>();
      var refreshing = false;
      when(() => _guide(api)).thenAnswer((_) =>
          refreshing ? failedPage.future : Future.value({'Items': []}));
      when(() => api.searchProgramTitles(
        'soccer', isCurrent: any(named: 'isCurrent'),
      )).thenAnswer((_) async => [airing('old', 'soccertv')]);
      when(() => api.searchProgramTitles(
        'hockey', isCurrent: any(named: 'isCurrent'),
      )).thenAnswer((_) async => [
        {...airing('playoffs', 'espn'), 'Name': 'Hockey playoffs'},
      ]);

      await vm.load(windowStart: start);
      vm.setChannelQuery('soccer');
      await pumpEventQueue();
      refreshing = true;
      final reloading = vm.load(windowStart: start);
      await pumpEventQueue();

      vm.setChannelQuery('hockey');
      expect(vm.programSearchStatus, GuideProgramSearchStatus.idle);
      verifyNever(() => api.searchProgramTitles(
        'hockey', isCurrent: any(named: 'isCurrent'),
      ));

      failedPage.completeError(StateError('offline'));
      await reloading;
      await pumpEventQueue();

      expect(vm.state, GuideState.error);
      expect(vm.error, isA<StateError>());
      expect(vm.channelQuery, 'hockey');
      expect(vm.programSearchStatus, GuideProgramSearchStatus.complete);
      expect(vm.filteredChannels.map((c) => c.id).toSet(),
          {'hockeytv', 'espn'});
      expect(vm.futureSearchMatchForChannel('soccertv'), isNull);
      verify(() => api.searchProgramTitles(
        'hockey', isCurrent: any(named: 'isCurrent'),
      )).called(1);
    });

    test('unchanged query is not searched again after a failed full reload',
        () async {
      final failedPage = Completer<Map<String, dynamic>>();
      var refreshing = false;
      when(() => _guide(api)).thenAnswer((_) =>
          refreshing ? failedPage.future : Future.value({'Items': []}));
      var searches = 0;
      when(() => api.searchProgramTitles(
        'soccer', isCurrent: any(named: 'isCurrent'),
      )).thenAnswer((_) {
        searches++;
        return Future.value([airing('old', 'tsn')]);
      });

      await vm.load(windowStart: start);
      vm.setChannelQuery('soccer');
      await pumpEventQueue();
      expect(searches, 1);

      refreshing = true;
      final reloading = vm.load(windowStart: start);
      await pumpEventQueue();
      failedPage.completeError(StateError('offline'));
      await reloading;
      await pumpEventQueue();

      expect(vm.state, GuideState.error);
      expect(vm.channelQuery, 'soccer');
      expect(vm.programSearchStatus, GuideProgramSearchStatus.idle);
      expect(searches, 1);
    });


    test('pending lineup fetch uses latest requested guide window', () async {
      final original = start;
      final latest = start.add(const Duration(days: 1, hours: 6));
      const finalSpan = Duration(hours: 4);
      final replacementLineup = Completer<Map<String, dynamic>>();
      var lineupReads = 0;
      when(() => _channelsRequest(api)).thenAnswer((_) {
        lineupReads++;
        return lineupReads == 2
            ? replacementLineup.future
            : Future.value({'Items': [_channel('old')]});
      });

      final requests = <({DateTime from, DateTime to, List<String> ids})>[];
      when(() => _guide(api)).thenAnswer((invocation) async {
        final from = invocation.namedArguments[#startDate] as DateTime;
        final to = invocation.namedArguments[#endDate] as DateTime;
        final ids = List<String>.of(_requestedIds(invocation));
        requests.add((from: from, to: to, ids: ids));
        return {
          'Items': [
            for (final id in ids)
              _program('$id-program', id, start: from),
          ],
        };
      });

      await vm.load(windowStart: original);
      expect(requests, hasLength(1));
      expect(vm.playbackChannels.map((c) => c.id), ['old']);

      final reloading = vm.load(windowStart: original);
      await pumpEventQueue();
      expect(lineupReads, 2);
      expect(vm.state, GuideState.loading);

      // Date, paging, explicit window navigation, and span changes must
      // update the target without fetching programs for the stale lineup.
      await vm.setDate(start.add(const Duration(days: 1)));
      await vm.shiftWindow(const Duration(hours: 3));
      await vm.setWindowStart(latest);
      await vm.setWindow(finalSpan);
      await pumpEventQueue();

      expect(vm.windowStart, latest);
      expect(vm.windowEnd, latest.add(finalSpan));
      expect(vm.guideWindow, finalSpan);
      expect(vm.state, GuideState.loading);
      expect(requests, hasLength(1));

      replacementLineup.complete({'Items': [_channel('fresh')]});
      await reloading;
      await pumpEventQueue();

      expect(vm.state, GuideState.ready);
      expect(vm.windowStart, latest);
      expect(vm.windowEnd, latest.add(finalSpan));
      expect(vm.playbackChannels.map((c) => c.id), ['fresh']);
      expect(requests, hasLength(2));
      expect(requests.last.ids, ['fresh']);
      expect(requests.last.from, latest);
      expect(requests.last.to, latest.add(finalSpan));
      expect(vm.programsForChannel('fresh').single.id, 'fresh-program');
      expect(vm.hasProgramsFor('old'), isFalse);
    });

    test('old Sports reply cannot finish a newer full load before its lineup',
        () async {
      final delayedLineup = Completer<Map<String, dynamic>>();
      final oldSports = Completer<Map<String, dynamic>>();
      var lineupReads = 0;
      var sportsReads = 0;
      when(() => _channelsRequest(api)).thenAnswer((_) {
        lineupReads++;
        return lineupReads == 2
            ? delayedLineup.future
            : Future.value({'Items': [_channel('old')]});
      });
      when(() => _guide(api, category: GuideFilter.sports))
          .thenAnswer((_) {
        sportsReads++;
        return sportsReads == 1
            ? oldSports.future
            : Future.value({
                'Items': [_program('fresh-game', 'fresh', isSports: true)],
              });
      });

      await vm.load(windowStart: start);
      vm.setFilter(GuideFilter.sports);
      await pumpEventQueue();
      expect(vm.state, GuideState.loading);
      expect(sportsReads, 1);

      final refreshing = vm.load(windowStart: start);
      await pumpEventQueue();
      expect(lineupReads, 2);
      expect(vm.state, GuideState.loading);

      // The older category result arrives while the new lineup is still
      // pending. It must not publish rows or complete the guide load.
      oldSports.complete({
        'Items': [_program('stale-game', 'old', isSports: true)],
      });
      await pumpEventQueue();
      expect(vm.state, GuideState.loading);
      expect(vm.filter, GuideFilter.sports);
      expect(vm.filteredChannels, isEmpty);
      expect(sportsReads, 1);

      delayedLineup.complete({'Items': [_channel('fresh')]});
      await refreshing;
      await pumpEventQueue();

      expect(vm.state, GuideState.ready);
      expect(vm.filter, GuideFilter.sports);
      expect(vm.filteredChannels.map((c) => c.id), ['fresh']);
      expect(vm.programsForChannel('fresh').single.id, 'fresh-game');
      expect(vm.programsForChannel('old'), isEmpty);
      expect(sportsReads, 2);
    });

    test(
      'category switches do not page the old lineup during a full lineup fetch',
      () async {
        final channels = [
          for (var i = 0; i < 120; i++) _channel('c$i', number: '$i'),
        ];
        final oldSportsPage = Completer<Map<String, dynamic>>();
        final newLineup = Completer<Map<String, dynamic>>();
        var lineupReads = 0;
        when(() => _channelsRequest(api)).thenAnswer((_) {
          lineupReads++;
          return lineupReads == 2
              ? newLineup.future
              : Future.value({'Items': channels});
        });
        final allPages = <List<String>>[];
        when(() => _guide(api)).thenAnswer((invocation) async {
          allPages.add(List<String>.of(_requestedIds(invocation)));
          return {'Items': []};
        });
        var sportsReads = 0;
        when(() => _guide(api, category: GuideFilter.sports))
            .thenAnswer((_) {
              sportsReads++;
              return oldSportsPage.future;
            });

        await vm.load(windowStart: start);
        expect(allPages, hasLength(1));
        expect(vm.hasMorePrograms, isTrue);

        vm.setFilter(GuideFilter.sports);
        await pumpEventQueue();
        expect(sportsReads, 1);
        expect(vm.state, GuideState.loading);

        final reloading = vm.load(windowStart: start);
        await pumpEventQueue();
        expect(lineupReads, 2);
        expect(vm.state, GuideState.loading);

        // The old category request has not returned. Switching to All must
        // not expose the old lineup or permit a second lazy-page fetch.
        vm.setFilter(GuideFilter.all);
        expect(vm.state, GuideState.loading);
        await vm.loadMorePrograms();
        await pumpEventQueue();
        expect(allPages, hasLength(1));

        // Repeated category changes during the same lineup must also wait.
        vm.setFilter(GuideFilter.sports);
        vm.setFilter(GuideFilter.all);
        await vm.loadMorePrograms();
        await pumpEventQueue();
        expect(vm.state, GuideState.loading);
        expect(sportsReads, 1);
        expect(allPages, hasLength(1));

        newLineup.complete({'Items': channels});
        await reloading;
        await pumpEventQueue();

        expect(vm.filter, GuideFilter.all);
        expect(vm.state, GuideState.ready);
        expect(allPages, hasLength(2));
        expect(allPages.last, [
          for (var i = 0; i < 50; i++) 'c$i',
        ]);
        await vm.loadMorePrograms();
        expect(allPages, hasLength(3));
        expect(allPages.last.first, 'c50');

        // The late category reply must not reinstate its cancelled results.
        oldSportsPage.complete({
          'Items': [_program('obsolete', 'c1', isSports: true)],
        });
        await pumpEventQueue();
        expect(vm.filter, GuideFilter.all);
        expect(vm.state, GuideState.ready);
        expect(vm.filteredChannels, hasLength(120));
        expect(vm.programsForChannel('c1'), isEmpty);
      },
    );

    test(
      'category selection waits for the lineup before fetching programs',
      () async {
      final channels = [
        {..._channel('soccertv'), 'Name': 'Soccer TV'},
        {..._channel('hockeytv'), 'Name': 'Hockey TV'},
        _channel('espn'),
      ];
      final delayedLineup = Completer<Map<String, dynamic>>();
      var lineupReads = 0;
      when(() => _channelsRequest(api)).thenAnswer((_) {
        lineupReads++;
        return lineupReads == 2
            ? delayedLineup.future
            : Future.value({'Items': channels});
      });
      var allGuideReads = 0;
      var sportsGuideReads = 0;
      when(() => _guide(api)).thenAnswer((_) async {
        allGuideReads++;
        return {'Items': []};
      });
      when(() => _guide(api, category: GuideFilter.sports))
          .thenAnswer((_) async {
        sportsGuideReads++;
        return {'Items': []};
      });
      when(() => api.searchProgramTitles(
        'soccer', isCurrent: any(named: 'isCurrent'),
      )).thenAnswer((_) async => [airing('old', 'tsn')]);
      when(() => api.searchProgramTitles(
        'hockey', isCurrent: any(named: 'isCurrent'),
      )).thenAnswer((_) async => [
        {...airing('game', 'espn'), 'Name': 'Hockey playoffs'},
      ]);

      await vm.load(windowStart: start);
      vm.setChannelQuery('soccer');
      await pumpEventQueue();
      expect(allGuideReads, 1);

      final reloading = vm.load(windowStart: start);
      await pumpEventQueue();
      expect(vm.state, GuideState.loading);
      vm.clearChannelSearchForCategoryChange();
      vm.setFilter(GuideFilter.sports);
      vm.setChannelQuery('hockey');
      await pumpEventQueue();
      expect(vm.filter, GuideFilter.sports);
      expect(vm.channelQuery, 'hockey');
      expect(vm.state, GuideState.loading);
      expect(allGuideReads, 1);
      expect(sportsGuideReads, 0);
      verifyNever(() => api.searchProgramTitles(
        'hockey', isCurrent: any(named: 'isCurrent'),
      ));

      delayedLineup.complete({'Items': channels});
      await reloading;
      await pumpEventQueue();

      expect(lineupReads, 2);
      expect(allGuideReads, 2);
      expect(sportsGuideReads, 1);
      expect(vm.state, GuideState.ready);
      expect(vm.filter, GuideFilter.sports);
      expect(vm.channelQuery, 'hockey');
      expect(vm.programSearchStatus, GuideProgramSearchStatus.complete);
      expect(vm.filteredChannels.map((c) => c.id), ['espn']);
      verify(() => api.searchProgramTitles(
        'hockey', isCurrent: any(named: 'isCurrent'),
      )).called(1);
    });

    test(
      'sort selection during a delayed lineup does not load stale pages',
      () async {
      final channels = [
        {..._channel('tsn'), 'Name': 'Z TSN'},
        {..._channel('espn'), 'Name': 'A ESPN'},
      ];
      final delayedLineup = Completer<Map<String, dynamic>>();
      var lineupReads = 0;
      when(() => _channelsRequest(api)).thenAnswer((_) {
        lineupReads++;
        return lineupReads == 2
            ? delayedLineup.future
            : Future.value({'Items': channels});
      });
      var guideReads = 0;
      when(() => _guide(api)).thenAnswer((_) async {
        guideReads++;
        return {'Items': []};
      });
      await vm.load(windowStart: start);
      expect(guideReads, 1);

      final reloading = vm.load(windowStart: start);
      await pumpEventQueue();
      vm.setSortBy(ChannelSortBy.name);
      await pumpEventQueue();
      expect(guideReads, 1);

      delayedLineup.complete({'Items': channels});
      await reloading;
      await pumpEventQueue();
      expect(guideReads, 2);
      expect(vm.state, GuideState.ready);
      expect(vm.sortBy, ChannelSortBy.name);
      expect(vm.filteredChannels.map((c) => c.id), ['espn', 'tsn']);
    });

    test('failed full reload does not leave cancelled title search loading',
        () async {
      // A channel-name match ensures the reload actually requests listings.
      _stubChannels(api, [
        {..._channel('soccertv'), 'Name': 'Soccer TV'},
        _channel('tsn'),
        _channel('espn'),
      ]);
      final pendingSearch = Completer<List<Map<String, dynamic>>>();
      var failing = false;
      var failedGuideCalls = 0;
      when(() => _guide(api)).thenAnswer((_) {
        if (failing) {
          failedGuideCalls++;
          return Future<Map<String, dynamic>>.error(StateError('offline'));
        }
        return Future.value({'Items': []});
      });
      when(() => api.searchProgramTitles(
        'soccer', isCurrent: any(named: 'isCurrent'),
      )).thenAnswer((_) => pendingSearch.future);

      await vm.load(windowStart: start);
      vm.setChannelQuery('soccer');
      expect(vm.searchingProgramTitles, isTrue);

      failing = true;
      await vm.load(windowStart: start);
      expect(failedGuideCalls, 1);
      expect(vm.state, GuideState.error);
      expect(vm.searchingProgramTitles, isFalse);
      expect(vm.channelQuery, 'soccer');

      pendingSearch.complete([airing('stale', 'tsn')]);
      await pumpEventQueue();
      expect(vm.searchingProgramTitles, isFalse);
      expect(vm.futureSearchMatchForChannel('tsn'), isNull);
    });


    test('failed full reload allows a new query without hiding guide error',
        () async {
      _stubChannels(api, [
        {..._channel('soccertv'), 'Name': 'Soccer TV'},
        {..._channel('hockeytv'), 'Name': 'Hockey TV'},
        _channel('espn'),
      ]);
      final stale = Completer<List<Map<String, dynamic>>>();
      var failing = false;
      var failedGuideCalls = 0;
      when(() => _guide(api)).thenAnswer((_) {
        if (failing) {
          failedGuideCalls++;
          return Future<Map<String, dynamic>>.error(StateError('offline'));
        }
        return Future.value({'Items': []});
      });
      when(() => api.searchProgramTitles(
        'soccer', isCurrent: any(named: 'isCurrent'),
      )).thenAnswer((_) => stale.future);
      when(() => api.searchProgramTitles(
        'hockey', isCurrent: any(named: 'isCurrent'),
      )).thenAnswer((_) async => [
        {...airing('game', 'espn'), 'Name': 'Hockey playoffs'},
      ]);

      await vm.load(windowStart: start);
      vm.setChannelQuery('soccer');
      expect(vm.searchingProgramTitles, isTrue);

      failing = true;
      await vm.load(windowStart: start);
      expect(failedGuideCalls, 1);
      expect(vm.state, GuideState.error);

      vm.setChannelQuery('hockey');
      await pumpEventQueue();
      expect(vm.channelQuery, 'hockey');
      expect(vm.programSearchStatus, GuideProgramSearchStatus.complete);
      expect(vm.state, GuideState.error);
      expect(vm.error, isA<StateError>());
      expect(vm.filteredChannels.map((c) => c.id).toSet(),
          {'hockeytv', 'espn'});
      verify(() => api.searchProgramTitles(
        'hockey', isCurrent: any(named: 'isCurrent'),
      )).called(1);

      stale.complete([airing('old', 'soccertv')]);
      await pumpEventQueue();
      expect(vm.channelQuery, 'hockey');
      expect(vm.state, GuideState.error);
      expect(vm.futureSearchMatchForChannel('soccertv'), isNull);
    });

    test('clearing search after failed reload restores channels and cancels refresh',
        () async {
      _stubChannels(api, [
        {..._channel('soccertv'), 'Name': 'Soccer TV'},
        _channel('espn'),
      ]);
      final stale = Completer<List<Map<String, dynamic>>>();
      var failing = false;
      when(() => _guide(api)).thenAnswer((_) => failing
          ? Future<Map<String, dynamic>>.error(StateError('offline'))
          : Future.value({'Items': []}));
      when(() => api.searchProgramTitles(
        'soccer', isCurrent: any(named: 'isCurrent'),
      )).thenAnswer((_) => stale.future);

      await vm.load(windowStart: start);
      vm.setChannelQuery('soccer');
      expect(vm.searchingProgramTitles, isTrue);

      failing = true;
      await vm.load(windowStart: start);
      expect(vm.state, GuideState.error);

      vm.setChannelQuery('');
      expect(vm.channelQuery, '');
      expect(vm.programSearchStatus, GuideProgramSearchStatus.idle);
      expect(vm.filteredChannels.map((c) => c.id).toSet(),
          {'soccertv', 'espn'});
      expect(vm.state, GuideState.error);

      stale.complete([airing('late', 'espn')]);
      await pumpEventQueue();
      expect(vm.futureSearchMatchForChannel('espn'), isNull);
      expect(vm.state, GuideState.error);

      failing = false;
      await vm.load(windowStart: start);
      await pumpEventQueue();
      expect(vm.state, GuideState.ready);
      expect(vm.channelQuery, '');
      verify(() => api.searchProgramTitles(
        'soccer', isCurrent: any(named: 'isCurrent'),
      )).called(1);
    });

    test('reply from before a reload cannot overwrite refreshed matches', () async {
      final stale = Completer<List<Map<String, dynamic>>>();
      var calls = 0;
      when(() => api.searchProgramTitles(
        'soccer', isCurrent: any(named: 'isCurrent'),
      )).thenAnswer((_) {
        calls++;
        return calls == 1
            ? stale.future
            : Future.value([airing('new', 'espn')]);
      });

      await vm.load(windowStart: start);
      vm.setChannelQuery('soccer');
      expect(vm.searchingProgramTitles, isTrue);
      await vm.load(windowStart: start);
      await pumpEventQueue();
      stale.complete([airing('stale', 'tsn')]);
      await pumpEventQueue();

      expect(calls, 2);
      expect(vm.filteredChannels.map((c) => c.id), ['espn']);
      expect(vm.futureSearchMatchForChannel('tsn'), isNull);
      expect(vm.searchingProgramTitles, isFalse);
    });
  });

  test('only matching EPG titles or episode titles get search highlights', () async {
    final api = _SearchableLiveTvApi();
    when(() => client.serverType).thenReturn(ServerType.plex);
    when(() => client.liveTvApi).thenReturn(api);
    _stubChannels(api, [{'Id': 'onesoccer', 'Name': 'OneSoccer'}]);
    final now = DateTime.utc(2026, 11, 14, 17);
    when(() => _guide(api)).thenAnswer((_) async => {
      'Items': [
        _program('Canadian Premier League', 'onesoccer', start: now),
        _program('Soccer Highlights', 'onesoccer',
            start: now.add(const Duration(minutes: 30))),
        {
          ..._program('Episode', 'onesoccer',
              start: now.add(const Duration(minutes: 60))),
          'EpisodeTitle': 'Soccer semifinals',
        },
      ],
    });
    when(() => api.searchProgramTitles(
      'soccer', isCurrent: any(named: 'isCurrent'),
    )).thenAnswer((_) async => [
      {
        'Id': 'soccer-highlights',
        'Type': 'Program',
        'Name': 'Soccer Highlights',
        'ChannelId': 'onesoccer',
        'StartDate': now.add(const Duration(minutes: 30)).toIso8601String(),
        'EndDate': now.add(const Duration(minutes: 60)).toIso8601String(),
      },
      {
        'Id': 'soccer-episode',
        'Type': 'Program',
        'Name': 'Episode',
        'EpisodeTitle': 'Soccer semifinals',
        'ChannelId': 'onesoccer',
        'StartDate': now.add(const Duration(minutes: 60)).toIso8601String(),
        'EndDate': now.add(const Duration(minutes: 90)).toIso8601String(),
      },
    ]);
    final vm = LiveTvGuideViewModel(client, now: () => now);
    addTearDown(vm.dispose);
    await vm.load(windowStart: now);
    vm.setChannelQuery('soccer');
    await Future<void>.delayed(Duration.zero);

    final programs = vm.programsForChannel('onesoccer');
    final canadian = programs.firstWhere((p) => p.name == 'Canadian Premier League');
    final highlights = programs.firstWhere((p) => p.name == 'Soccer Highlights');
    final episode = programs.firstWhere((p) => p.name == 'Episode');
    expect(vm.programMatchesSearch(canadian), isFalse);
    expect(vm.programMatchesSearch(highlights), isTrue);
    expect(vm.programMatchesSearch(episode), isTrue);
    expect(
      vm.nextSearchMatchForChannel('onesoccer', after: canadian.endDate)?.title,
      'Soccer Highlights',
    );
    expect(vm.futureSearchMatchForChannel('onesoccer'), isNull);
  });

  test('old Plex search batches cannot change a newer query', () async {
    final api = _IncrementalSearchableLiveTvApi();
    when(() => client.serverType).thenReturn(ServerType.plex);
    when(() => client.liveTvApi).thenReturn(api);
    when(() => _guide(api)).thenAnswer((_) async => {'Items': []});
    _stubChannels(api, [_channel('dvr')]);
    final oldReply = Completer<List<Map<String, dynamic>>>();
    late void Function(List<Map<String, dynamic>>) publishOld;
    when(
      () => api.searchProgramTitlesIncrementally(
        'soccer',
        isCurrent: any(named: 'isCurrent'),
        onBatch: any(named: 'onBatch'),
      ),
    ).thenAnswer((invocation) {
      publishOld = invocation.namedArguments[#onBatch]
          as void Function(List<Map<String, dynamic>>);
      return oldReply.future;
    });
    when(
      () => api.searchProgramTitlesIncrementally(
        'hockey',
        isCurrent: any(named: 'isCurrent'),
        onBatch: any(named: 'onBatch'),
      ),
    ).thenAnswer((_) async => []);

    final now = DateTime.utc(2026, 11, 14, 17);
    final vm = LiveTvGuideViewModel(client, now: () => now);
    addTearDown(vm.dispose);
    await vm.load(windowStart: now);
    vm.setChannelQuery('soccer');
    vm.setChannelQuery('hockey');
    publishOld([{
      'Id': 'stale',
      'Type': 'Program',
      'Name': 'Soccer',
      'ChannelId': 'dvr',
      'StartDate': now.toIso8601String(),
      'EndDate': now.add(const Duration(hours: 1)).toIso8601String(),
    }]);
    oldReply.complete([]);
    await Future<void>.delayed(Duration.zero);
    expect(vm.channelQuery, 'hockey');
    expect(vm.filteredChannels, isEmpty);
    expect(vm.futureSearchMatchForChannel('dvr'), isNull);
  });

  test('shows the earliest later program, not Now or Next', () {
    final t = DateTime.utc(2026, 11, 14, 17);
    GuideTitleMatch match(String channel, int minutes) => GuideTitleMatch(
      channelId: channel,
      title: 'Soccer at $minutes',
      start: t.add(Duration(minutes: minutes)),
      end: t.add(Duration(minutes: minutes + 30)),
    );
    GuideTitleMatch? find(List<GuideTitleMatch> matches, {
      DateTime? currentStart,
      DateTime? nextStart,
    }) => laterProgramSearchMatch(
      matches,
      channelId: 'tsn',
      windowStart: t,
      windowEnd: t.add(const Duration(minutes: 150)),
      now: t,
      currentStart: currentStart,
      nextStart: nextStart,
    );

    final later = [match('espn', 60), match('tsn', 120), match('tsn', 90)];
    expect(find(later, nextStart: t.add(const Duration(minutes: 30)))?.title,
        'Soccer at 90');
    expect(find([match('tsn', 30), ...later],
        nextStart: t.add(const Duration(minutes: 30))), isNull);
    expect(find([match('tsn', 0), ...later], currentStart: t), isNull);
    expect(find([match('tsn', 150)]), isNull);
  });

  group('future guide search matches', () {
    late _SearchableLiveTvApi api;
    late LiveTvGuideViewModel vm;
    final now = DateTime.utc(2026, 11, 14, 17);
    final end = now.add(const Duration(minutes: 150));

    Map<String, dynamic> airing(String id, String channel, DateTime start) => {
      'Id': id,
      'Type': 'Program',
      'Name': 'Silo',
      'ChannelId': channel,
      'StartDate': start.toIso8601String(),
      'EndDate': start.add(const Duration(hours: 1)).toIso8601String(),
    };

    setUp(() {
      api = _SearchableLiveTvApi();
      when(() => client.serverType).thenReturn(ServerType.plex);
      when(() => client.liveTvApi).thenReturn(api);
      when(() => _guide(api)).thenAnswer((_) async => {'Items': []});
      _stubChannels(api, [_channel('tsn'), _channel('espn')]);
      vm = LiveTvGuideViewModel(client, now: () => now);
      addTearDown(vm.dispose);
    });

    Future<void> search(List<Map<String, dynamic>> results) async {
      when(() => api.searchProgramTitles(
        'silo', isCurrent: any(named: 'isCurrent'),
      )).thenAnswer((_) async => results);
      await vm.load(windowStart: now);
      vm.setChannelQuery('silo');
      await Future<void>.delayed(Duration.zero);
      expect(vm.searchingProgramTitles, isFalse);
    }

    test('future matches respond to the visible guide window', () async {
      await search([
        airing('late', 'tsn', end.add(const Duration(minutes: 30))),
        airing('unknown', 'not-in-lineup', end.add(const Duration(minutes: 1))),
        airing('early', 'espn', end),
        airing('visible', 'tsn', now.add(const Duration(minutes: 30))),
      ]);
      expect(vm.futureSearchMatchForChannel('espn')?.start, end);
      // TSN already has a visible match, so it needs no calendar marker.
      expect(vm.futureSearchMatchForChannel('tsn'), isNull);
      expect(vm.nextSearchMatchForChannel('tsn', after: end)?.title, 'Silo');
      await vm.setWindowStart(end, livePosition: false);
      expect(vm.futureSearchMatchForChannel('espn'), isNull);
      expect(vm.filteredChannels.map((ch) => ch.id), containsAll(['tsn', 'espn']));
    });

    test('same-time airings both appear after moving the window', () async {
      await search([
        airing('one', 'tsn', end),
        airing('two', 'espn', end),
      ]);
      expect(vm.futureSearchMatchForChannel('tsn')?.start, end);
      expect(vm.futureSearchMatchForChannel('espn')?.start, end);
      await vm.setWindowStart(end, livePosition: false);
      expect(vm.filteredChannels.map((ch) => ch.id), containsAll(['tsn', 'espn']));
      expect(vm.futureSearchMatchForChannel('tsn'), isNull);
      expect(vm.futureSearchMatchForChannel('espn'), isNull);
      verify(() => api.searchProgramTitles(
        'silo', isCurrent: any(named: 'isCurrent'),
      )).called(1);
    });

    test('future-only search keeps its query when moving the window', () async {
      final nextDay = end.add(const Duration(days: 1));
      await search([airing('future', 'espn', nextDay)]);
      expect(vm.filteredChannels.map((c) => c.id), ['espn']);
      expect(vm.futureSearchMatchForChannel('espn')?.start, nextDay);

      await vm.setWindowStart(nextDay, livePosition: false);

      expect(vm.channelQuery, 'silo');
      expect(vm.windowStart, nextDay);
      expect(vm.filteredChannels.map((channel) => channel.id), ['espn']);
      expect(vm.futureSearchMatchForChannel('espn'), isNull);
      verify(
        () => api.searchProgramTitles(
          'silo',
          isCurrent: any(named: 'isCurrent'),
        ),
      ).called(1);
    });

    test('cleared and failed searches leave no future matches', () async {
      await search([]);
      expect(vm.futureSearchMatchForChannel('tsn'), isNull);
      vm.setChannelQuery('');
      expect(vm.nextSearchMatchForChannel('tsn'), isNull);
      when(() => api.searchProgramTitles(
        'tsn', isCurrent: any(named: 'isCurrent'),
      )).thenThrow(StateError('EPG unavailable'));
      vm.setChannelQuery('tsn');
      await Future<void>.delayed(Duration.zero);
      expect(vm.searchingProgramTitles, isFalse);
      expect(vm.filteredChannels.map((ch) => ch.id).toList(), ['tsn']);
      expect(vm.futureSearchMatchForChannel('tsn'), isNull);
    });

    test('does not show future matches while a search is pending', () async {
      final pending = Completer<List<Map<String, dynamic>>>();
      when(() => api.searchProgramTitles(
        'silo', isCurrent: any(named: 'isCurrent'),
      )).thenAnswer((_) => pending.future);
      await vm.load(windowStart: now);
      vm.setChannelQuery('silo');
      expect(vm.searchingProgramTitles, isTrue);
      expect(vm.futureSearchMatchForChannel('tsn'), isNull);
      pending.complete([airing('future', 'tsn', end)]);
      await Future<void>.delayed(Duration.zero);
      expect(vm.filteredChannels.map((ch) => ch.id), ['tsn']);
      expect(vm.futureSearchMatchForChannel('tsn')?.start, end);
    });

    test('respects Favorites when only some channels are saved', () async {
      _stubChannels(api, [
        {'Id': 'tsn', 'Name': 'TSN', 'UserData': {'IsFavorite': true}},
        _channel('espn'),
      ]);
      await search([
        airing('espn-early', 'espn', end),
        airing('tsn-late', 'tsn', end.add(const Duration(hours: 1))),
      ]);
      vm.setFilter(GuideFilter.favorites);
      expect(vm.filteredChannels.map((ch) => ch.id), ['tsn']);
      expect(
        vm.futureSearchMatchForChannel('tsn')?.start,
        end.add(const Duration(hours: 1)),
      );
    });

    test('respects the selected channel group', () async {
      final grouped = _GroupedSearchableLiveTvApi();
      when(() => client.liveTvApi).thenReturn(grouped);
      when(() => client.baseUrl).thenReturn('fixture');
      when(() => _guide(grouped)).thenAnswer((_) async => {'Items': []});
      _stubChannels(grouped, [_channel('tsn'), _channel('espn')]);
      when(() => grouped.getChannelGroups(userId: 'user')).thenAnswer(
        (_) async => const ChannelGroupLineup({
          'tsn': {'Sports'},
          'espn': {'News'},
        }),
      );
      when(() => grouped.searchProgramTitles(
        'silo', isCurrent: any(named: 'isCurrent'),
      )).thenAnswer((_) async => [
        airing('news', 'espn', end),
        airing('sports', 'tsn', end.add(const Duration(hours: 1))),
      ]);
      final groupedVm = LiveTvGuideViewModel(client, now: () => now);
      addTearDown(groupedVm.dispose);
      await groupedVm.load(windowStart: now);
      groupedVm.setGroup('Sports');
      groupedVm.setChannelQuery('silo');
      await Future<void>.delayed(Duration.zero);
      expect(groupedVm.filteredChannels.map((ch) => ch.id), ['tsn']);
      expect(
        groupedVm.futureSearchMatchForChannel('tsn')?.start,
        end.add(const Duration(hours: 1)),
      );
    });

    test('does not show future-only channels outside the active filter', () async {
      await search([
        airing('espn-early', 'espn', end),
        airing('tsn-late', 'tsn', end.add(const Duration(hours: 1))),
      ]);
      vm.setFilter(GuideFilter.favorites);
      expect(vm.filteredChannels, isEmpty);
      vm.setFilter(GuideFilter.sports);
      await Future<void>.delayed(Duration.zero);
      expect(vm.filteredChannels, isEmpty);
    });
  });

  test('unchanged search preserves an in-flight guide page', () async {
    _stubChannels(liveTv, [
      for (var i = 0; i < 100; i++)
        {'Id': 'c$i', 'Name': 'Soccer $i', 'ChannelNumber': '$i'},
    ]);
    final vm = LiveTvGuideViewModel(client);
    addTearDown(vm.dispose);
    await vm.load();
    final page = Completer<Map<String, dynamic>>();
    when(() => _guide(liveTv)).thenAnswer((_) => page.future);
    final pending = vm.loadMorePrograms();
    vm.setChannelQuery('s');
    page.complete({'Items': []});
    await pending;
    expect(vm.filteredChannels, hasLength(100));
    expect(vm.programsHighWater, 100);
    verify(() => _guide(liveTv)).called(2);
  });


  test('async EPG search keeps an in-flight guide page', () async {
    _stubChannels(liveTv, [
      for (var i = 0; i < 100; i++)
        {'Id': 'c$i', 'Name': 'Soccer $i', 'ChannelNumber': '$i'},
    ]);
    final items = _MockItemsApi();
    when(() => client.itemsApi).thenReturn(items);
    final search = Completer<Map<String, dynamic>>();
    when(
      () => items.getItems(
        searchTerm: 'soccer',
        includeItemTypes: any(named: 'includeItemTypes'),
        recursive: true,
        startIndex: 0,
        limit: 200,
      ),
    ).thenAnswer((_) => search.future);

    final vm = LiveTvGuideViewModel(client);
    addTearDown(vm.dispose);
    await vm.load();
    final page = Completer<Map<String, dynamic>>();
    when(() => _guide(liveTv)).thenAnswer((_) => page.future);
    final pending = vm.loadMorePrograms();

    vm.setChannelQuery('soccer');
    expect(vm.searchingProgramTitles, isTrue);
    expect(vm.filteredChannels, hasLength(100));

    final start = vm.windowStart.add(const Duration(minutes: 30));
    search.complete({
      'TotalRecordCount': 1,
      'Items': [
        {
          'Id': 'match-1',
          'ChannelId': 'c0',
          'Type': 'LiveTvProgram',
          'Name': 'Soccer',
          'StartDate': start.toUtc().toIso8601String(),
          'EndDate': start
              .add(const Duration(hours: 1))
              .toUtc()
              .toIso8601String(),
        },
      ],
    });
    await Future<void>.delayed(Duration.zero);
    expect(vm.searchingProgramTitles, isFalse);
    expect(vm.filteredChannels, hasLength(100));

    page.complete({'Items': []});
    await pending;
    expect(vm.programsHighWater, 100);
    verify(() => _guide(liveTv)).called(2);
    verify(
      () => items.getItems(
        searchTerm: 'soccer',
        includeItemTypes: any(named: 'includeItemTypes'),
        recursive: true,
        startIndex: 0,
        limit: 200,
      ),
    ).called(1);
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

  group('group membership on guide reload', () {
    late _GroupedLiveTvApi api;
    late LiveTvGuideViewModel vm;
    setUp(() {
      api = _GroupedLiveTvApi();
      when(() => client.liveTvApi).thenReturn(api);
      when(() => client.baseUrl).thenReturn('fixture');
      when(() => _guide(api)).thenAnswer((_) async => {'Items': []});
      vm = LiveTvGuideViewModel(client);
      addTearDown(vm.dispose);
    });
    testWidgets('edits appear on the next reload and browsing does not poll', (
      tester,
    ) async {
      _stubChannels(api, [_channel('one')]);
      var name = 'Sports';
      when(() => api.getChannelGroups(userId: 'user')).thenAnswer(
        (_) async => ChannelGroupLineup({
          'one': {name},
        }, partial: name == 'Sports'),
      );
      await vm.load();
      vm.setGroup('Sports');
      name = 'Local sports';
      await vm.shiftWindow(const Duration(hours: 1));
      await tester.pump(const Duration(minutes: 10));
      expect(vm.availableGroups, ['Sports']);
      verify(() => api.getChannelGroups(userId: 'user')).called(1);

      await vm.goToNow();
      expect(vm.availableGroups, ['Local sports']);
      expect(vm.selectedGroup, isNull);
      verify(() => api.getChannelGroups(userId: 'user')).called(1);
    });
    test(
      'unknown categories or missing plugin restore default filters',
      () async {
        _stubChannels(api, [_channel('one')]);
        when(() => api.getChannelGroups(userId: 'user')).thenAnswer(
          (_) async => const ChannelGroupLineup(
            {
              'one': {'Local'},
            },
            programmeCategories: {'movies'},
          ),
        );
        await vm.load();
        vm.setGroup('Local');
        expect(vm.availableProgrammeCategories, [GuideFilter.movies]);

        when(() => api.getChannelGroups(userId: 'user')).thenThrow(
          Exception('Moonbase timed out'),
        );
        await vm.load();
        expect(vm.availableProgrammeCategories, contains(GuideFilter.sports));
        expect(vm.selectedGroup, 'Local');
        expect(vm.filteredChannels.single.id, 'one');

        // A successful lineup may omit categories while the guide imports.
        when(() => api.getChannelGroups(userId: 'user')).thenAnswer(
          (_) async => const ChannelGroupLineup({'one': {'Local'}}),
        );
        await vm.load();
        expect(vm.availableProgrammeCategories, contains(GuideFilter.sports));
        expect(vm.availableProgrammeCategories, contains(GuideFilter.news));

        when(() => api.getChannelGroups(userId: 'user')).thenAnswer(
          (_) async => const ChannelGroupLineup({}, endpointAvailable: false),
        );
        await vm.load();
        expect(vm.availableGroups, isEmpty);
        expect(vm.selectedGroup, isNull);
        expect(vm.availableProgrammeCategories, contains(GuideFilter.sports));
        expect(vm.playbackChannels.single.id, 'one');
      },
    );
    for (final removeChannel in [false, true]) {
      test(
        'clears the selected group when its last channel is ${removeChannel ? 'deleted' : 'ungrouped'} and another tuner is offline',
        () async {
          _stubChannels(api, [_channel('healthy'), _channel('offline')]);
          when(() => api.getChannelGroups(userId: 'user')).thenAnswer(
            (_) async => const ChannelGroupLineup({
              'healthy': {'Sports'},
              'offline': {'UK'},
            }),
          );
          await vm.load();
          vm.setGroup('Sports');
          if (removeChannel) _stubChannels(api, [_channel('offline')]);
          when(() => api.getChannelGroups(userId: 'user')).thenAnswer(
            (_) async => const ChannelGroupLineup(
              {},
              partial: true,
              unresolvedChannelIds: {'offline'},
            ),
          );
          await vm.load();
          expect(vm.availableGroups, ['UK']);
          expect(vm.selectedGroup, isNull);
          expect(vm.filteredChannels, isNotEmpty);
          vm.setGroup('UK');
          expect(vm.filteredChannels.single.id, 'offline');
        },
      );
    }
  });
  test('Emby 403 clears the lineup without another fetch', () async {
    final api = _DirectGroupedLiveTvApi();
    when(() => client.liveTvApi).thenReturn(api);
    when(() => client.baseUrl).thenReturn('emby');
    when(() => _guide(api)).thenAnswer((_) async => {'Items': []});
    when(() => api.getChannelGroups(userId: 'user')).thenAnswer(
      (_) async => ChannelGroupLineup({}, channels: [_channel('one')]),
    );
    final vm = LiveTvGuideViewModel(client);
    addTearDown(vm.dispose);
    await vm.load();
    expect(vm.playbackChannels, hasLength(1));
    final request = RequestOptions(path: '/LiveTv/Channels');
    when(() => api.getChannelGroups(userId: 'user')).thenThrow(DioException(
      requestOptions: request,
      response: Response(requestOptions: request, statusCode: 403),
    ));
    await vm.load();
    expect(vm.playbackChannels, isEmpty);
    verifyNever(() => _channelsRequest(api));
  });

  test('channel groups page by channel and keep every programme', () async {
    final grouped = _GroupedLiveTvApi();
    when(() => client.liveTvApi).thenReturn(grouped);
    when(() => client.baseUrl).thenReturn('fixture');
    final channels = [
      for (var i = 0; i < 200; i++) _channel('c$i', number: '$i'),
    ];
    _stubChannels(grouped, channels);
    when(() => grouped.getChannelGroups(userId: 'user')).thenAnswer(
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
    verify(() => grouped.getChannelGroups(userId: 'user')).called(1);
    when(() => grouped.getChannelGroups(userId: 'user'))
        .thenAnswer((_) async => const ChannelGroupLineup({}));
    await vm.load();
    expect(vm.selectedGroup, isNull);
    expect(vm.filteredChannels.length, 200);
  });
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

  group('guide window cache', () {
    test('revisiting a window reuses listings including empty channels', () async {
      final now = DateTime.utc(2026, 11, 14, 17);
      _stubChannels(liveTv, [_channel('c0'), _channel('c1')]);
      final requested = <DateTime>[];
      when(() => _guide(liveTv)).thenAnswer((call) async {
        final from = call.namedArguments[#startDate] as DateTime;
        requested.add(from);
        return {'Items': [_program('p-${from.hour}', 'c0', start: from)]};
      });
      final vm = LiveTvGuideViewModel(client, now: () => now);
      addTearDown(vm.dispose);
      await vm.load(windowStart: now);
      expect(vm.programsForChannel('c0').single.id, 'p-17');
      await vm.shiftWindow(const Duration(hours: 3));
      expect(vm.programsForChannel('c0').single.id, 'p-20');
      await vm.shiftWindow(const Duration(hours: -3));
      expect(vm.programsForChannel('c0').single.id, 'p-17');
      expect(vm.programsForChannel('c1'), isEmpty);
      expect(requested, [now, now.add(const Duration(hours: 3))]);
    });

    test('category windows reuse the cached filtered guide', () async {
      final now = DateTime.utc(2026, 11, 14, 17);
      _stubChannels(liveTv, [_channel('c0'), _channel('c1')]);
      when(() => _guide(liveTv)).thenAnswer((_) async => {'Items': []});
      final requests = <DateTime>[];
      when(() => _guide(liveTv, category: GuideFilter.sports))
          .thenAnswer((call) async {
            final from = call.namedArguments[#startDate] as DateTime;
            requests.add(from);
            return {'Items': [_program('sport', 'c0', start: from, isSports: true)]};
          });
      final vm = LiveTvGuideViewModel(client, now: () => now);
      addTearDown(vm.dispose);
      await vm.load(windowStart: now);
      vm.setFilter(GuideFilter.sports);
      await pumpEventQueue();
      expect(vm.filteredChannels.map((c) => c.id), ['c0']);
      await vm.shiftWindow(const Duration(hours: 3));
      await vm.shiftWindow(const Duration(hours: -3));
      expect(vm.filteredChannels.map((c) => c.id), ['c0']);
      expect(requests, [now, now.add(const Duration(hours: 3))]);
    });

    test('guide windows expire after 30 minutes, including empty channels', () async {
      final start = DateTime.utc(2026, 11, 14, 17);
      var clock = start;
      _stubChannels(liveTv, [_channel('c0'), _channel('c1')]);
      final requests = <({DateTime from, List<String> ids})>[];
      when(() => _guide(liveTv)).thenAnswer((call) async {
        final from = call.namedArguments[#startDate] as DateTime;
        final ids = List<String>.of(_requestedIds(call));
        requests.add((from: from, ids: ids));
        return {
          'Items': [
            _program('revision-${requests.length}', 'c0', start: from),
          ],
        };
      });

      final vm = LiveTvGuideViewModel(client, now: () => clock);
      addTearDown(vm.dispose);
      await vm.load(windowStart: start);
      await vm.shiftWindow(const Duration(hours: 3));
      clock = clock.add(const Duration(minutes: 29, seconds: 59));
      await vm.shiftWindow(const Duration(hours: -3));
      expect(vm.programsForChannel('c0').single.id, 'revision-1');
      expect(vm.programsForChannel('c1'), isEmpty);
      expect(requests, hasLength(2));

      clock = clock.add(const Duration(seconds: 1));
      await vm.shiftWindow(const Duration(hours: 3));
      expect(vm.programsForChannel('c0').single.id, 'revision-3');
      expect(requests.map((r) => r.from), [
        start,
        start.add(const Duration(hours: 3)),
        start.add(const Duration(hours: 3)),
      ]);
      // Both the positive and negative channel entries have expired.
      expect(requests.last.ids, ['c0', 'c1']);
    });

    test('a refresh invalidates cached hits in a mixed category batch', () async {
      final api = _SearchableLiveTvApi();
      when(() => client.liveTvApi).thenReturn(api);
      final start = DateTime.utc(2026, 11, 14, 17);
      _stubChannels(api, [
        {..._channel('c0'), 'Name': 'TSN One'},
        {..._channel('c1'), 'Name': 'TSN Two'},
      ]);
      when(() => _guide(api)).thenAnswer((_) async => {'Items': []});
      for (final query in ['one', 'tsn']) {
        when(() => api.searchProgramTitles(
          query, isCurrent: any(named: 'isCurrent'),
        )).thenAnswer((_) async => <Map<String, dynamic>>[]);
      }
      final stalePending = Completer<Map<String, dynamic>>();
      final sportsRequests = <List<String>>[];
      var seeded = false;
      var stalled = false;
      when(() => _guide(api, category: GuideFilter.sports))
          .thenAnswer((call) {
            final requested = List<String>.of(_requestedIds(call));
            sportsRequests.add(requested);
            if (requested.length == 1 && requested.single == 'c0' && !seeded) {
              seeded = true;
              return Future.value({
                'Items': [_program('old-c0', 'c0', start: start, isSports: true)],
              });
            }
            if (requested.length == 1 && requested.single == 'c1' && !stalled) {
              stalled = true;
              return stalePending.future;
            }
            return Future.value({
              'Items': [
                for (final id in requested)
                  _program('fresh-$id', id, start: start, isSports: true),
              ],
            });
          });

      final vm = LiveTvGuideViewModel(client, now: () => start);
      addTearDown(vm.dispose);
      await vm.load(windowStart: start);
      vm.setChannelQuery('one');
      await pumpEventQueue();
      vm.setFilter(GuideFilter.sports);
      await pumpEventQueue();
      expect(vm.programsForChannel('c0').single.id, 'old-c0');

      // Retain c0 in the window cache, but reset the category cursor so the
      // next category page contains a cache hit for c0 and a miss for c1.
      vm.setFilter(GuideFilter.all);
      vm.setChannelQuery('tsn');
      await pumpEventQueue();
      await vm.loadInitialPrograms(channelIds: const []);
      vm.setFilter(GuideFilter.sports);
      await pumpEventQueue();
      expect(vm.state, GuideState.loading);
      expect(sportsRequests.last, ['c1']);

      await vm.recordingChanged();
      stalePending.complete({
        'Items': [_program('stale-c1', 'c1', start: start, isSports: true)],
      });
      await pumpEventQueue();

      // Both channels must be requested again; the earlier cache hit must
      // not survive just because it was read before the pending API call.
      expect(sportsRequests, [
        ['c0'],
        ['c1'],
        ['c0', 'c1'],
      ]);
      expect(vm.state, GuideState.ready);
      expect(vm.programsForChannel('c0').single.id, 'fresh-c0');
      expect(vm.programsForChannel('c1').single.id, 'fresh-c1');
      expect(vm.filteredChannels.map((c) => c.id), ['c0', 'c1']);
    });

    test('All Channels retries a page invalidated by a recording refresh', () async {
      _stubChannels(liveTv, [
        for (var i = 0; i < 100; i++) _channel('c$i', number: '$i'),
      ]);
      final stalePage = Completer<Map<String, dynamic>>();
      var laterCalls = 0;
      when(() => _guide(liveTv)).thenAnswer((call) {
        final ids = _requestedIds(call);
        if (ids.first == 'c50') {
          laterCalls++;
          if (laterCalls == 1) return stalePage.future;
        }
        return Future.value({
          'Items': [
            for (final id in ids)
              _program('fresh-$id', id),
          ],
        });
      });

      final vm = LiveTvGuideViewModel(client);
      addTearDown(vm.dispose);
      await vm.load();
      expect(vm.hasProgramsFor('c0'), isTrue);
      expect(vm.hasProgramsFor('c50'), isFalse);

      final paging = vm.loadMorePrograms();
      await pumpEventQueue();
      expect(laterCalls, 1);
      await vm.recordingChanged();
      expect(vm.hasProgramsFor('c50'), isFalse);

      stalePage.complete({
        'Items': [_program('stale-c50', 'c50')],
      });
      await paging;
      await pumpEventQueue();

      expect(laterCalls, 2);
      expect(vm.hasProgramsFor('c50'), isTrue);
      expect(vm.programsForChannel('c50').single.id, 'fresh-c50');
      expect(vm.hasMorePrograms, isFalse);
    });

    test('All Channels drops cached hits from an invalidated mixed batch', () async {
      _stubChannels(liveTv, [
        for (var i = 0; i < 100; i++) _channel('c$i', number: '$i'),
      ]);
      final stalePage = Completer<Map<String, dynamic>>();
      var seeded = false;
      var interrupted = false;
      final requested = <List<String>>[];
      when(() => _guide(liveTv)).thenAnswer((call) {
        final ids = List<String>.of(_requestedIds(call));
        requested.add(ids);
        if (ids.length == 1 && ids.single == 'c75' && !seeded) {
          seeded = true;
          return Future.value({
            'Items': [_program('cached-c75', 'c75')],
          });
        }
        if (ids.first == 'c50' && !interrupted) {
          interrupted = true;
          return stalePage.future;
        }
        return Future.value({
          'Items': [
            for (final id in ids)
              _program('fresh-$id', id),
          ],
        });
      });

      final vm = LiveTvGuideViewModel(client);
      addTearDown(vm.dispose);
      await vm.load();
      await vm.ensureProgramsForChannels(['c75']);
      expect(vm.programsForChannel('c75').single.id, 'cached-c75');

      // Clear the loaded-state cursor without clearing the window cache.
      await vm.loadInitialPrograms(channelIds: const []);
      await vm.loadMorePrograms();
      expect(vm.programsHighWater, 50);

      final paging = vm.loadMorePrograms();
      await pumpEventQueue();
      expect(requested.last, [
        for (var i = 50; i < 100; i++)
          if (i != 75) 'c$i',
      ]);
      await vm.recordingChanged();
      stalePage.complete({'Items': [_program('stale-c50', 'c50')]});
      await paging;
      await pumpEventQueue();

      expect(vm.hasProgramsFor('c75'), isTrue);
      expect(vm.programsForChannel('c75').single.id, 'fresh-c75');
      expect(vm.programsForChannel('c50').single.id, 'fresh-c50');
      expect(vm.hasMorePrograms, isFalse);
      expect(requested.where((ids) => ids.contains('c75')), hasLength(2));
    });

    test('a successful empty All Channels response still marks rows loaded', () async {
      _stubChannels(liveTv, [_channel('c0')]);
      when(() => _guide(liveTv)).thenAnswer((_) async => {'Items': []});
      final vm = LiveTvGuideViewModel(client);
      addTearDown(vm.dispose);
      await vm.load();

      expect(vm.hasProgramsFor('c0'), isTrue);
      expect(vm.programsForChannel('c0'), isEmpty);
      expect(vm.hasMorePrograms, isFalse);
    });

    test('a window with no loaded rows starts its first guide page', () async {
      final now = DateTime.utc(2026, 11, 14, 17);
      final later = now.add(const Duration(hours: 3));
      _stubChannels(liveTv, [_channel('old')]);
      when(() => _guide(liveTv)).thenAnswer((call) async => {
        'Items': [
          for (final id in _requestedIds(call))
            _program('listing-$id', id, start: now),
        ],
      });

      final vm = LiveTvGuideViewModel(client, now: () => now);
      addTearDown(vm.dispose);
      await vm.load(windowStart: now);
      expect(vm.hasProgramsFor('old'), isTrue);

      // The player's new lineup has no loaded program IDs and inherits the
      // old cursor position. Navigating should fetch its first page anyway.
      vm.usePlaybackLineup([
        GuideChannel.fromRawItem(_channel('replacement')),
      ]);
      expect(vm.hasProgramsFor('replacement'), isFalse);
      await vm.setWindowStart(later);
      await pumpEventQueue();

      expect(vm.windowStart, later);
      expect(vm.programsForChannel('replacement').single.id, 'listing-replacement');
      expect(vm.hasProgramsFor('replacement'), isTrue);
    });

    test('overlapping window failure restores the last loaded window', () async {
      final start = DateTime.utc(2026, 11, 14, 17);
      final middle = start.add(const Duration(hours: 3));
      final later = start.add(const Duration(hours: 6));
      _stubChannels(liveTv, [_channel('c0')]);
      final middleReply = Completer<Map<String, dynamic>>();
      when(() => _guide(liveTv)).thenAnswer((call) {
        final from = call.namedArguments[#startDate] as DateTime;
        if (from == middle) return middleReply.future;
        if (from == later) {
          return Future.error(DioException(
            requestOptions: RequestOptions(path: '/LiveTv/Programs'),
            type: DioExceptionType.connectionError,
          ));
        }
        return Future.value({
          'Items': [_program('confirmed', 'c0', start: start)],
        });
      });

      final vm = LiveTvGuideViewModel(client, now: () => start);
      addTearDown(vm.dispose);
      await vm.load(windowStart: start);
      final middleLoad = vm.setWindowStart(middle);
      await pumpEventQueue();
      expect(vm.windowStart, middle);

      await expectLater(
        vm.setWindowStart(later),
        throwsA(isA<DioException>()),
      );
      expect(vm.state, GuideState.ready);
      expect(vm.windowStart, start);
      expect(vm.windowEnd, start.add(vm.guideWindow));
      expect(vm.guideDate, start);
      expect(vm.programsForChannel('c0').single.id, 'confirmed');

      middleReply.complete({
        'Items': [_program('obsolete-middle', 'c0', start: middle)],
      });
      await middleLoad;
      expect(vm.windowStart, start);
      expect(vm.programsForChannel('c0').single.id, 'confirmed');
    });

    test('a targeted replacement only leaves the other window channels to fetch', () async {
      final start = DateTime.utc(2026, 11, 14, 17);
      final later = start.add(const Duration(hours: 3));
      _stubChannels(liveTv, [
        for (var i = 0; i < 50; i++) _channel('c$i', number: '$i'),
      ]);
      final olderReply = Completer<Map<String, dynamic>>();
      final laterRequests = <List<String>>[];
      when(() => _guide(liveTv)).thenAnswer((call) {
        final from = call.namedArguments[#startDate] as DateTime;
        final ids = List<String>.of(_requestedIds(call));
        if (from == later) {
          laterRequests.add(ids);
          if (ids.length == 50) return olderReply.future;
          return Future.value({
            'Items': [
              for (final id in ids)
                _program(ids.length == 1 ? 'targeted-$id' : 'loaded-$id',
                    id, start: later),
            ],
          });
        }
        return Future.value({
          'Items': [
            for (final id in ids) _program('old-$id', id, start: start),
          ],
        });
      });

      final vm = LiveTvGuideViewModel(client, now: () => start);
      addTearDown(vm.dispose);
      await vm.load(windowStart: start);
      expect(vm.programsHighWater, 50);

      final navigating = vm.setWindowStart(later);
      await pumpEventQueue();
      expect(laterRequests.map((ids) => ids.length), [50]);

      await vm.replacePrograms(
        channelIds: const ['c0'],
        from: later,
        to: later.add(vm.guideWindow),
      );
      expect(vm.programsForChannel('c0').single.id, 'targeted-c0');

      olderReply.complete({
        'Items': [_program('stale-c0', 'c0', start: later)],
      });
      await navigating;

      expect(vm.windowStart, later);
      expect(vm.state, GuideState.ready);
      expect(vm.hasMorePrograms, isFalse);
      expect(vm.programsForChannel('c0').single.id, 'targeted-c0');
      expect(vm.programsForChannel('c1').single.id, 'loaded-c1');
      expect(vm.programsForChannel('c49').single.id, 'loaded-c49');
      expect(laterRequests, [
        [for (var i = 0; i < 50; i++) 'c$i'],
        ['c0'],
        [for (var i = 1; i < 50; i++) 'c$i'],
      ]);
    });

    test('pending targeted replacement finishes before missing window rows load', () async {
      final start = DateTime.utc(2026, 11, 14, 17);
      final later = start.add(const Duration(hours: 3));
      _stubChannels(liveTv, [
        _channel('c0'), _channel('c1'), _channel('c2'),
      ]);
      final olderReply = Completer<Map<String, dynamic>>();
      final targetedReply = Completer<Map<String, dynamic>>();
      final laterRequests = <List<String>>[];
      when(() => _guide(liveTv)).thenAnswer((call) {
        final from = call.namedArguments[#startDate] as DateTime;
        final ids = List<String>.of(_requestedIds(call));
        if (from == later) {
          laterRequests.add(ids);
          if (ids.length == 3) return olderReply.future;
          if (ids.length == 1) return targetedReply.future;
        }
        return Future.value({
          'Items': [
            for (final id in ids)
              _program(from == later ? 'fresh-$id' : 'old-$id',
                  id, start: from),
          ],
        });
      });

      final vm = LiveTvGuideViewModel(client, now: () => start);
      addTearDown(vm.dispose);
      await vm.load(windowStart: start);
      final navigating = vm.setWindowStart(later);
      await pumpEventQueue();

      final targeted = vm.replacePrograms(
        channelIds: const ['c0'],
        from: later,
        to: later.add(vm.guideWindow),
      );
      await pumpEventQueue();

      olderReply.complete({'Items': [
        _program('superseded', 'c0', start: later),
      ]});
      await pumpEventQueue();

      // The pending c0 update must finish before the window repair chooses
      // which channels are still missing.
      expect(laterRequests, [
        ['c0', 'c1', 'c2'],
        ['c0'],
      ]);

      targetedReply.complete({'Items': [
        _program('targeted-c0', 'c0', start: later),
      ]});
      await targeted;
      await navigating;

      expect(laterRequests, [
        ['c0', 'c1', 'c2'],
        ['c0'],
        ['c1', 'c2'],
      ]);
      expect(vm.programsForChannel('c0').single.id, 'targeted-c0');
      expect(vm.programsForChannel('c1').single.id, 'fresh-c1');
      expect(vm.programsForChannel('c2').single.id, 'fresh-c2');
      expect(vm.windowStart, later);
      expect(vm.state, GuideState.ready);
    });

    test('failed partial-window repair restores every confirmed channel', () async {
      final start = DateTime.utc(2026, 11, 14, 17);
      final later = start.add(const Duration(hours: 3));
      _stubChannels(liveTv, [
        _channel('c0'), _channel('c1'), _channel('c2'),
      ]);
      final olderReply = Completer<Map<String, dynamic>>();
      when(() => _guide(liveTv)).thenAnswer((call) {
        final from = call.namedArguments[#startDate] as DateTime;
        final ids = List<String>.of(_requestedIds(call));
        if (from == later && ids.length == 3) return olderReply.future;
        if (from == later && ids.length == 2) {
          return Future.error(DioException(
            requestOptions: RequestOptions(path: '/LiveTv/Programs'),
            type: DioExceptionType.connectionError,
          ));
        }
        return Future.value({
          'Items': [
            for (final id in ids)
              _program(from == later ? 'targeted-$id' : 'old-$id',
                  id, start: from),
          ],
        });
      });

      final vm = LiveTvGuideViewModel(client, now: () => start);
      addTearDown(vm.dispose);
      await vm.load(windowStart: start);
      final navigating = vm.setWindowStart(later);
      await pumpEventQueue();
      await vm.replacePrograms(
        channelIds: const ['c0'],
        from: later,
        to: later.add(vm.guideWindow),
      );
      expect(vm.programsForChannel('c0').single.id, 'targeted-c0');

      final failure = expectLater(navigating, throwsA(isA<DioException>()));
      olderReply.complete({'Items': [
        _program('stale-c0', 'c0', start: later),
      ]});
      await failure;

      expect(vm.windowStart, start);
      expect(vm.state, GuideState.ready);
      expect(vm.programsHighWater, 3);
      for (final id in ['c0', 'c1', 'c2']) {
        expect(vm.programsForChannel(id).single.id, 'old-$id');
      }
    });

    test('failed guide window change restores the previous valid schedule', () async {
      final start = DateTime.utc(2026, 11, 14, 17);
      final later = start.add(const Duration(hours: 3));
      _stubChannels(liveTv, [_channel('c0')]);
      when(() => _guide(liveTv)).thenAnswer((call) async {
        final from = call.namedArguments[#startDate] as DateTime;
        if (from == later) {
          throw DioException(
            requestOptions: RequestOptions(path: '/LiveTv/Programs'),
            type: DioExceptionType.connectionError,
          );
        }
        return {'Items': [_program('original', 'c0', start: start)]};
      });

      final vm = LiveTvGuideViewModel(client, now: () => start);
      addTearDown(vm.dispose);
      await vm.load(windowStart: start);
      final previousDate = vm.guideDate;
      final previousEnd = vm.windowEnd;
      final previousLivePosition = vm.atLivePosition;

      await expectLater(
        vm.setWindowStart(later, livePosition: false),
        throwsA(isA<DioException>()),
      );
      expect(vm.state, GuideState.ready);
      expect(vm.windowStart, start);
      expect(vm.windowEnd, previousEnd);
      expect(vm.guideDate, previousDate);
      expect(vm.atLivePosition, previousLivePosition);
      expect(vm.programsForChannel('c0').single.id, 'original');
      expect(vm.hasProgramsFor('c0'), isTrue);
    });

    test('successful empty future Sports EPG advances the timeline', () async {
      final start = DateTime.utc(2026, 11, 14, 17);
      final later = start.add(const Duration(hours: 3));
      _stubChannels(liveTv, [_channel('sports')]);
      final requested = <DateTime>[];
      when(() => _guide(liveTv, category: GuideFilter.sports))
          .thenAnswer((call) async {
        final from = call.namedArguments[#startDate] as DateTime;
        requested.add(from);
        return {
          'Items': [
            if (from == start)
              _program('current-sport', 'sports',
                  start: start, isSports: true),
          ],
        };
      });

      final vm = LiveTvGuideViewModel(client, now: () => start);
      addTearDown(vm.dispose);
      await vm.load(windowStart: start);
      vm.setFilter(GuideFilter.sports);
      await pumpEventQueue();
      expect(vm.filteredChannels.map((c) => c.id), ['sports']);

      await vm.setWindowStart(later, livePosition: false);
      expect(vm.state, GuideState.ready);
      expect(vm.windowStart, later);
      expect(vm.windowEnd, later.add(vm.guideWindow));
      expect(vm.guideDate, later);
      expect(vm.atLivePosition, isFalse);
      expect(vm.filteredChannels, isEmpty);
      expect(vm.programsForChannel('sports'), isEmpty);
      expect(vm.hasMorePrograms, isFalse);
      expect(requested, [start, later]);
    });

    test('late failed window request does not roll back a newer guide load', () async {
      final start = DateTime.utc(2026, 11, 14, 17);
      final later = start.add(const Duration(hours: 3));
      _stubChannels(liveTv, [_channel('c0')]);
      final oldReply = Completer<Map<String, dynamic>>();
      var laterCalls = 0;
      when(() => _guide(liveTv)).thenAnswer((call) {
        final from = call.namedArguments[#startDate] as DateTime;
        if (from == later) {
          laterCalls++;
          if (laterCalls == 1) return oldReply.future;
          return Future.value({
            'Items': [_program('current', 'c0', start: later)],
          });
        }
        return Future.value({
          'Items': [_program('previous', 'c0', start: start)],
        });
      });

      final vm = LiveTvGuideViewModel(client, now: () => start);
      addTearDown(vm.dispose);
      await vm.load(windowStart: start);
      final older = vm.setWindowStart(later);
      await pumpEventQueue();
      expect(laterCalls, 1);
      await vm.load(windowStart: later);
      expect(vm.programsForChannel('c0').single.id, 'current');

      final failure = expectLater(older, throwsA(isA<StateError>()));
      oldReply.completeError(StateError('older request failed'));
      await failure;
      await pumpEventQueue();

      expect(vm.windowStart, later);
      expect(vm.state, GuideState.ready);
      expect(vm.programsForChannel('c0').single.id, 'current');
      expect(laterCalls, 2);
    });

    for (final refreshFinishesFirst in [true, false]) {
      test(
        refreshFinishesFirst
            ? 'completed recording refresh avoids another window reload'
            : 'pending recording refresh avoids another window reload when done',
        () async {
          final start = DateTime.utc(2026, 11, 14, 17);
          final later = start.add(const Duration(hours: 3));
          _stubChannels(liveTv, [_channel('c0')]);
          final oldWindowReply = Completer<Map<String, dynamic>>();
          final freshRecordingReply = Completer<Map<String, dynamic>>();
          var recordingStarted = false;
          var windowRequests = 0;
          var recordingRequests = 0;
          when(() => _guide(liveTv)).thenAnswer((call) {
            final from = call.namedArguments[#startDate] as DateTime;
            if (from == later) {
              windowRequests++;
              if (windowRequests == 1) return oldWindowReply.future;
              return Future.value({
                'Items': [_program('redundant', 'c0', start: later)],
              });
            }
            if (recordingStarted) {
              recordingRequests++;
              return freshRecordingReply.future;
            }
            return Future.value({
              'Items': [_program('initial', 'c0', start: start)],
            });
          });

          final vm = LiveTvGuideViewModel(client, now: () => start);
          addTearDown(vm.dispose);
          await vm.load(windowStart: start);
          final windowChange = vm.setWindowStart(later);
          await pumpEventQueue();
          expect(windowRequests, 1);

          recordingStarted = true;
          final refreshing = vm.recordingChanged();
          await pumpEventQueue();
          expect(recordingRequests, 1);

          final updated = {
            'Items': [{
              ..._program('recorded', 'c0', start: later),
              'TimerId': 'timer-new',
            }],
          };
          if (refreshFinishesFirst) {
            freshRecordingReply.complete(updated);
            await refreshing;
            oldWindowReply.complete({
              'Items': [_program('stale', 'c0', start: later)],
            });
            await windowChange;
          } else {
            oldWindowReply.complete({
              'Items': [_program('stale', 'c0', start: later)],
            });
            await windowChange;
            freshRecordingReply.complete(updated);
            await refreshing;
          }
          await pumpEventQueue();

          expect(vm.windowStart, later);
          expect(vm.state, GuideState.ready);
          expect(vm.programsForChannel('c0').single.id, 'recorded');
          expect(vm.programsForChannel('c0').single.hasTimer, isTrue);
          expect(windowRequests, 1);
          expect(recordingRequests, 1);

          clearInteractions(liveTv);
          await vm.reloadIfRecordingsChanged();
          verifyNever(() => _guide(liveTv));
        },
      );
    }

    test('older window reply does not reload a successful full guide load', () async {
      final start = DateTime.utc(2026, 11, 14, 17);
      final later = start.add(const Duration(hours: 3));
      _stubChannels(liveTv, [_channel('c0')]);
      final oldReply = Completer<Map<String, dynamic>>();
      var laterCalls = 0;
      when(() => _guide(liveTv)).thenAnswer((call) {
        final from = call.namedArguments[#startDate] as DateTime;
        if (from == later) {
          laterCalls++;
          if (laterCalls == 1) return oldReply.future;
          return Future.value({
            'Items': [_program('fresh', 'c0', start: later)],
          });
        }
        return Future.value({
          'Items': [_program('initial', 'c0', start: start)],
        });
      });

      final vm = LiveTvGuideViewModel(client, now: () => start);
      addTearDown(vm.dispose);
      await vm.load(windowStart: start);
      final obsolete = vm.setWindowStart(later);
      await pumpEventQueue();
      expect(laterCalls, 1);

      await vm.load(windowStart: later);
      expect(laterCalls, 2);
      expect(vm.programsForChannel('c0').single.id, 'fresh');
      clearInteractions(liveTv);

      oldReply.complete({
        'Items': [_program('obsolete', 'c0', start: later)],
      });
      await obsolete;
      await pumpEventQueue();

      verifyNever(() => _guide(liveTv));
      expect(laterCalls, 2);
      expect(vm.state, GuideState.ready);
      expect(vm.programsForChannel('c0').single.id, 'fresh');
    });

    test('unrelated program replacement does not reload a superseded window', () async {
      final start = DateTime.utc(2026, 11, 14, 17);
      final later = start.add(const Duration(hours: 3));
      _stubChannels(liveTv, [_channel('c0')]);
      final oldReply = Completer<Map<String, dynamic>>();
      var laterCalls = 0;
      when(() => _guide(liveTv)).thenAnswer((call) {
        final from = call.namedArguments[#startDate] as DateTime;
        if (from == later) {
          laterCalls++;
          if (laterCalls == 1) return oldReply.future;
          return Future.value({
            'Items': [_program('replacement', 'c0', start: later)],
          });
        }
        return Future.value({
          'Items': [_program('initial', 'c0', start: start)],
        });
      });

      final vm = LiveTvGuideViewModel(client, now: () => start);
      addTearDown(vm.dispose);
      await vm.load(windowStart: start);
      final obsolete = vm.setWindowStart(later);
      await pumpEventQueue();
      expect(laterCalls, 1);

      await vm.replacePrograms(
        channelIds: const ['c0'],
        from: later,
        to: later.add(const Duration(hours: 3)),
      );
      expect(vm.programsForChannel('c0').single.id, 'replacement');
      clearInteractions(liveTv);

      oldReply.complete({
        'Items': [_program('obsolete', 'c0', start: later)],
      });
      await obsolete;
      await pumpEventQueue();

      verifyNever(() => _guide(liveTv));
      expect(laterCalls, 2);
      expect(vm.programsForChannel('c0').single.id, 'replacement');
    });

    test('older guide replies cannot replace a newer window cache entry', () async {
      final start = DateTime.utc(2026, 11, 14, 17);
      final later = start.add(const Duration(hours: 3));
      _stubChannels(liveTv, [_channel('c0')]);
      final laterReplies = <Completer<Map<String, dynamic>>>[];
      when(() => _guide(liveTv)).thenAnswer((call) {
        final from = call.namedArguments[#startDate] as DateTime;
        if (from == later) {
          final pending = Completer<Map<String, dynamic>>();
          laterReplies.add(pending);
          return pending.future;
        }
        return Future.value({
          'Items': [_program('base', 'c0', start: start)],
        });
      });

      final vm = LiveTvGuideViewModel(client, now: () => start);
      addTearDown(vm.dispose);
      await vm.load(windowStart: start);
      final older = vm.setWindowStart(later);
      await pumpEventQueue();
      expect(laterReplies, hasLength(1));
      await vm.setWindowStart(start);
      final newer = vm.setWindowStart(later);
      await pumpEventQueue();
      expect(laterReplies, hasLength(2));

      laterReplies.last.complete({
        'Items': [_program('newer', 'c0', start: later)],
      });
      await newer;
      laterReplies.first.complete({
        'Items': [_program('older', 'c0', start: later)],
      });
      await older;

      await vm.setWindowStart(start);
      await vm.setWindowStart(later);
      expect(laterReplies, hasLength(2));
      expect(vm.programsForChannel('c0').single.id, 'newer');
    });

    test('expired category windows refetch on demand', () async {
      final start = DateTime.utc(2026, 11, 14, 17);
      var clock = start;
      _stubChannels(liveTv, [_channel('c0'), _channel('c1')]);
      when(() => _guide(liveTv)).thenAnswer((_) async => {'Items': []});
      final requests = <DateTime>[];
      when(() => _guide(liveTv, category: GuideFilter.sports))
          .thenAnswer((call) async {
            final from = call.namedArguments[#startDate] as DateTime;
            requests.add(from);
            return {
              'Items': [
                _program('sport-${requests.length}', 'c0',
                    start: from, isSports: true),
              ],
            };
          });

      final vm = LiveTvGuideViewModel(client, now: () => clock);
      addTearDown(vm.dispose);
      await vm.load(windowStart: start);
      vm.setFilter(GuideFilter.sports);
      await pumpEventQueue();
      await vm.shiftWindow(const Duration(hours: 3));
      clock = clock.add(const Duration(minutes: 30));
      await vm.shiftWindow(const Duration(hours: -3));
      expect(vm.filteredChannels.map((c) => c.id), ['c0']);
      expect(vm.programsForChannel('c0').single.id, 'sport-3');
      expect(requests, [
        start,
        start.add(const Duration(hours: 3)),
        start,
      ]);
    });

    test('full reload discards cached guide windows', () async {
      final now = DateTime.utc(2026, 11, 14, 17);
      _stubChannels(liveTv, [_channel('c0')]);
      var revisions = 0;
      when(() => _guide(liveTv)).thenAnswer((call) async {
        revisions++;
        final from = call.namedArguments[#startDate] as DateTime;
        return {'Items': [_program('v$revisions', 'c0', start: from)]};
      });
      final vm = LiveTvGuideViewModel(client, now: () => now);
      addTearDown(vm.dispose);
      await vm.load(windowStart: now);
      await vm.shiftWindow(const Duration(hours: 3));
      await vm.shiftWindow(const Duration(hours: -3));
      expect(revisions, 2);
      await vm.load(windowStart: now);
      expect(revisions, 3);
      expect(vm.programsForChannel('c0').single.id, 'v3');
    });
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

    test('window reload without a search retains normal category paging', () async {
      _stubChannels(
        liveTv,
        [for (var i = 0; i < 450; i++) _channel('c$i')],
      );
      final now = DateTime.utc(2026, 11, 14, 17);
      final later = now.add(const Duration(hours: 3));
      final laterPages = <List<String>>[];
      when(() => _guide(liveTv, category: GuideFilter.sports)).thenAnswer(
        (invocation) async {
          final start = invocation.namedArguments[#startDate] as DateTime;
          final ids = _requestedIds(invocation);
          if (start.isAtSameMomentAs(later)) laterPages.add(ids);
          return {
            'Items': [
              for (final id in ids)
                _program('sport-$id', id, start: start, isSports: true),
            ],
          };
        },
      );

      final vm = LiveTvGuideViewModel(client, now: () => now);
      addTearDown(vm.dispose);
      await vm.load(windowStart: now);
      vm.setFilter(GuideFilter.sports);
      await pumpEventQueue();
      await vm.shiftWindow(const Duration(hours: 3));

      expect(laterPages.map((ids) => ids.length), [200]);
      expect(vm.filteredChannels, hasLength(200));
      expect(vm.hasMorePrograms, isTrue);
    });

    for (final duringInitialLoad in [false, true]) {
      test(
        duringInitialLoad
            ? 'search checks uncached channel names during category loading'
            : 'search checks uncached channel names despite unrelated cached rows',
        () async {
          final api = _SearchableLiveTvApi();
          when(() => client.liveTvApi).thenReturn(api);
          when(() => _guide(api)).thenAnswer((_) async => {'Items': []});
          _stubChannels(api, [
            for (var i = 0; i < 450; i++) {
              ..._channel('c$i', number: '$i'),
              if (i == 420) 'Name': 'TSN',
              if (i == 430) 'Name': 'TSN Two',
            },
          ]);
          final now = DateTime.utc(2026, 11, 14, 17);
          final initialPage = Completer<Map<String, dynamic>>();
          Map<String, dynamic> responseFor(List<String> ids) => {
            'Items': [
              for (final id in ids)
                if (int.parse(id.substring(1)) < 24 || id == 'c420')
                  _program('sport-$id', id, start: now, isSports: true),
            ],
          };
          when(() => _guide(api, category: GuideFilter.sports))
              .thenAnswer((invocation) {
                final ids = _requestedIds(invocation);
                if (duringInitialLoad && ids.contains('c0')) {
                  return initialPage.future;
                }
                return Future.value(responseFor(ids));
              });
          when(() => api.searchProgramTitles(
            'tsn', isCurrent: any(named: 'isCurrent'),
          )).thenAnswer((_) async => <Map<String, dynamic>>[]);

          final vm = LiveTvGuideViewModel(client, now: () => now);
          addTearDown(vm.dispose);
          await vm.load(windowStart: now);
          vm.setFilter(GuideFilter.sports);
          if (duringInitialLoad) {
            vm.setChannelQuery('tsn');
            await pumpEventQueue();
            clearInteractions(api);
            initialPage.complete(responseFor([
              for (var i = 0; i < 200; i++) 'c$i',
            ]));
          } else {
            await pumpEventQueue();
            expect(vm.filteredChannels, hasLength(24));
            clearInteractions(api);
            vm.setChannelQuery('tsn');
          }
          await pumpEventQueue();

          expect(vm.filteredChannels.map((c) => c.id), ['c420']);
          expect(vm.programsForChannel('c420').single.isSports, isTrue);
          expect(vm.hasMorePrograms, isFalse);
          final requested = verify(
            () => _guide(
              api,
              category: GuideFilter.sports,
              captureChannelIds: true,
            ),
          ).captured;
          expect(requested, hasLength(1));
          expect(requested.single, ['c420', 'c430']);

          // Negative category results are cached too.
          clearInteractions(api);
          vm.setChannelQuery('');
          await pumpEventQueue();
          vm.setChannelQuery('tsn');
          await pumpEventQueue();
          expect(vm.filteredChannels.map((c) => c.id), ['c420']);
          verifyNever(() => _guide(api, category: GuideFilter.sports));
        },
      );
    }

    test('revisiting category search refreshes expired positive and negative matches', () async {
      final api = _SearchableLiveTvApi();
      when(() => client.liveTvApi).thenReturn(api);
      when(() => _guide(api)).thenAnswer((_) async => {'Items': []});
      _stubChannels(api, [
        for (var i = 0; i < 450; i++) {
          ..._channel('c$i', number: '$i'),
          if (i == 420 || i == 430) 'Name': 'TSN $i',
        },
      ]);
      final start = DateTime.utc(2026, 11, 14, 17);
      var clock = start;
      final searched = <List<String>>[];
      when(() => _guide(api, category: GuideFilter.sports))
          .thenAnswer((call) async {
            final ids = List<String>.of(_requestedIds(call));
            var revision = searched.length;
            if (ids.contains('c420')) {
              searched.add(ids);
              revision = searched.length;
            }
            return {
              'Items': [
                for (final id in ids)
                  if (int.parse(id.substring(1)) < 24 ||
                      (id == 'c420' && revision == 1) ||
                      (id == 'c430' && revision == 2))
                    _program('sport-$id', id, start: start, isSports: true),
              ],
            };
          });
      when(() => api.searchProgramTitles(
        'tsn', isCurrent: any(named: 'isCurrent'),
      )).thenAnswer((_) async => <Map<String, dynamic>>[]);

      final vm = LiveTvGuideViewModel(client, now: () => clock);
      addTearDown(vm.dispose);
      await vm.load(windowStart: start);
      vm.setFilter(GuideFilter.sports);
      await pumpEventQueue();
      vm.setChannelQuery('tsn');
      await pumpEventQueue();
      expect(vm.filteredChannels.map((c) => c.id), ['c420']);
      expect(searched, [['c420', 'c430']]);

      // A fresh positive/negative cache pair should not be requested again.
      vm.setChannelQuery('');
      await pumpEventQueue();
      vm.setChannelQuery('tsn');
      await pumpEventQueue();
      expect(searched, hasLength(1));
      expect(vm.filteredChannels.map((c) => c.id), ['c420']);

      // The old positive disappears and the old negative becomes a match.
      clock = clock.add(const Duration(minutes: 31));
      vm.setChannelQuery('');
      await pumpEventQueue();
      vm.setChannelQuery('tsn');
      await pumpEventQueue();
      expect(searched, [
        ['c420', 'c430'],
        ['c420', 'c430'],
      ]);
      expect(vm.filteredChannels.map((c) => c.id), ['c430']);
      expect(vm.programsForChannel('c430').single.isSports, isTrue);
    });

    test('category prefetch count updates when the search candidates change', () async {
      final api = _SearchableLiveTvApi();
      when(() => client.liveTvApi).thenReturn(api);
      when(() => _guide(api)).thenAnswer((_) async => {'Items': []});
      _stubChannels(api, [
        for (var i = 0; i < 200; i++) {
          ..._channel('c$i', number: '$i'),
          if (i < 24) 'Name': 'TSN $i',
          if (i >= 24 && i < 34) 'Name': 'ESPN $i',
        },
      ]);
      final now = DateTime.utc(2026, 11, 14, 17);
      when(() => _guide(api, category: GuideFilter.sports))
          .thenAnswer((call) async => {
            'Items': [
              for (final id in _requestedIds(call))
                if (int.parse(id.substring(1)) < 48)
                  _program('sport-$id', id, start: now, isSports: true),
            ],
          });
      for (final query in ['tsn', 'espn']) {
        when(() => api.searchProgramTitles(
          query, isCurrent: any(named: 'isCurrent'),
        )).thenAnswer((_) async => <Map<String, dynamic>>[]);
      }

      final vm = LiveTvGuideViewModel(client, now: () => now);
      addTearDown(vm.dispose);
      await vm.load(windowStart: now);
      vm.setFilter(GuideFilter.sports);
      await pumpEventQueue();
      expect(vm.programsHighWater, 48);

      clearInteractions(api);
      vm.setChannelQuery('tsn');
      await pumpEventQueue();
      expect(vm.programsHighWater, 24);
      // Row builders can consult this repeatedly without another traversal.
      for (var i = 0; i < 30; i++) {
        expect(vm.programsHighWater, 24);
      }
      vm.setChannelQuery('espn');
      await pumpEventQueue();
      expect(vm.programsHighWater, 10);
      vm.setChannelQuery('');
      await pumpEventQueue();
      expect(vm.programsHighWater, 48);
      verifyNever(() => _guide(api, category: GuideFilter.sports));
    });

    test('category refresh recalculates the search prefetch count', () async {
      final api = _SearchableLiveTvApi();
      when(() => client.liveTvApi).thenReturn(api);
      when(() => _guide(api)).thenAnswer((_) async => {'Items': []});
      _stubChannels(api, [
        for (var i = 0; i < 500; i++) {
          ..._channel('c$i', number: '$i'),
          if (i < 90 || (i >= 420 && i < 426)) 'Name': 'TSN $i',
        },
      ]);
      var removeEarlierSports = false;
      when(() => _guide(api, category: GuideFilter.sports))
          .thenAnswer((call) async => {
            'Items': [
              for (final id in _requestedIds(call))
                if ((int.parse(id.substring(1)) < 90 &&
                        (!removeEarlierSports ||
                            int.parse(id.substring(1)) >= 50)) ||
                    (int.parse(id.substring(1)) >= 420 &&
                        int.parse(id.substring(1)) < 426))
                  _program('sport-$id', id, isSports: true),
            ],
          });
      when(() => api.searchProgramTitles(
        'tsn', isCurrent: any(named: 'isCurrent'),
      )).thenAnswer((_) async => <Map<String, dynamic>>[]);

      final vm = LiveTvGuideViewModel(client);
      addTearDown(vm.dispose);
      await vm.load();
      vm.setFilter(GuideFilter.sports);
      await pumpEventQueue();
      vm.setChannelQuery('tsn');
      await pumpEventQueue();
      expect(vm.filteredChannels, hasLength(90));
      // Prime the memoized high-water count before the refresh.
      expect(vm.programsHighWater, 90);
      expect(vm.hasMorePrograms, isTrue);

      removeEarlierSports = true;
      await vm.recordingChanged();
      expect(vm.filteredChannels, hasLength(40));
      // The cursor didn't move, but the number of visible matches did.
      expect(vm.programsHighWater, 40);
      expect(vm.hasMorePrograms, isTrue);

      // The row-builder's prefetch threshold must now reach the next page.
      expect(39 + 12 >= vm.programsHighWater, isTrue);
      await vm.loadMorePrograms();
      expect(vm.filteredChannels.map((c) => c.id), [
        for (var i = 50; i < 90; i++) 'c$i',
        for (var i = 420; i < 426; i++) 'c$i',
      ]);
      expect(vm.hasMorePrograms, isFalse);
    });

    test('category search prefetch counts checked matching rows, not all cached programs', () async {
      final api = _SearchableLiveTvApi();
      when(() => client.liveTvApi).thenReturn(api);
      when(() => _guide(api)).thenAnswer((_) async => {'Items': []});
      _stubChannels(api, [
        for (var i = 0; i < 500; i++) {
          ..._channel('c$i', number: '$i'),
          if (i < 24 || (i >= 420 && i < 426)) 'Name': 'TSN $i',
        },
      ]);
      final now = DateTime.utc(2026, 11, 14, 17);
      when(() => _guide(api, category: GuideFilter.sports))
          .thenAnswer((invocation) async => {
            'Items': [
              for (final id in _requestedIds(invocation))
                if (int.parse(id.substring(1)) < 100 ||
                    (int.parse(id.substring(1)) >= 420 &&
                        int.parse(id.substring(1)) < 426))
                  _program('sport-$id', id, start: now, isSports: true),
            ],
          });
      when(() => api.searchProgramTitles(
        'tsn', isCurrent: any(named: 'isCurrent'),
      )).thenAnswer((_) async => <Map<String, dynamic>>[]);

      final vm = LiveTvGuideViewModel(client, now: () => now);
      addTearDown(vm.dispose);
      await vm.load(windowStart: now);
      vm.setFilter(GuideFilter.sports);
      await pumpEventQueue();
      expect(vm.filteredChannels, hasLength(100));
      expect(vm.programsHighWater, 100);

      clearInteractions(api);
      vm.setChannelQuery('tsn');
      await pumpEventQueue();
      expect(vm.filteredChannels, hasLength(24));
      // The other 76 cached Sports channels must not delay prefetch.
      expect(vm.programsHighWater, 24);
      expect(vm.hasMorePrograms, isTrue);
      verifyNever(() => _guide(api, category: GuideFilter.sports));

      // A scroll near the 24th row should now ask for the next page.
      if (23 + 12 >= vm.programsHighWater) {
        await vm.loadMorePrograms();
      }
      expect(vm.filteredChannels, hasLength(30));
      expect(vm.programsHighWater, 30);
      expect(vm.hasMorePrograms, isFalse);
      final requested = verify(() => _guide(
        api, category: GuideFilter.sports, captureChannelIds: true,
      )).captured;
      expect(requested, hasLength(1));
      expect(requested.single, [
        for (var i = 420; i < 426; i++) 'c$i',
      ]);
      // The unrelated cache remains intact, without another EPG search.
      expect(vm.programsForChannel('c99').single.isSports, isTrue);
      verify(() => api.searchProgramTitles(
        'tsn', isCurrent: any(named: 'isCurrent'),
      )).called(1);
    });

    test('search reuses already-checked category programs', () async {
      final api = _SearchableLiveTvApi();
      when(() => client.liveTvApi).thenReturn(api);
      when(() => _guide(api)).thenAnswer((_) async => {'Items': []});
      _stubChannels(api, [
        _channel('c10'),
        _channel('c20'),
        _channel('c30'),
      ]);
      final now = DateTime.utc(2026, 11, 14, 17);
      Map<String, dynamic> program(String id, String channel, String title) => {
        ..._program(id, channel, start: now, isSports: true),
        'Name': title,
      };
      Map<String, dynamic> hit(String id, String channel, String title) => {
        ...program(id, channel, title),
        'Type': 'Program',
      };

      when(() => _guide(api, category: GuideFilter.sports)).thenAnswer(
        (invocation) async => {
          'Items': [
            for (final id in _requestedIds(invocation))
              if (id == 'c10') program('s1', id, 'Soccer Highlights'),
            for (final id in _requestedIds(invocation))
              if (id == 'c20') program('h1', id, 'Hockey Night'),
          ],
        },
      );
      when(() => api.searchProgramTitles(
        'soccer', isCurrent: any(named: 'isCurrent'),
      )).thenAnswer((_) async => [hit('s1', 'c10', 'Soccer Highlights')]);
      when(() => api.searchProgramTitles(
        'hockey', isCurrent: any(named: 'isCurrent'),
      )).thenAnswer((_) async => [hit('h1', 'c20', 'Hockey Night')]);

      final vm = LiveTvGuideViewModel(client, now: () => now);
      addTearDown(vm.dispose);
      await vm.load(windowStart: now);
      vm.setFilter(GuideFilter.sports);
      await pumpEventQueue();
      expect(vm.filteredChannels.map((c) => c.id), ['c10', 'c20']);

      clearInteractions(api);
      vm.setChannelQuery('soccer');
      await pumpEventQueue();
      expect(vm.filteredChannels.map((c) => c.id), ['c10']);
      vm.setChannelQuery('hockey');
      await pumpEventQueue();
      expect(vm.filteredChannels.map((c) => c.id), ['c20']);
      vm.setChannelQuery('');
      await pumpEventQueue();
      expect(vm.filteredChannels.map((c) => c.id), ['c10', 'c20']);
      verifyNever(() => _guide(api, category: GuideFilter.sports));
    });

    test('incremental category matches do not fetch verification pages', () async {
      final api = _IncrementalSearchableLiveTvApi();
      when(() => client.liveTvApi).thenReturn(api);
      when(() => _guide(api)).thenAnswer((_) async => {'Items': []});
      _stubChannels(api, [
        for (var i = 0; i < 250; i++) _channel('c$i', number: '$i'),
      ]);
      final now = DateTime.utc(2026, 11, 14, 17);
      Map<String, dynamic> program(String id, String channel, String title) => {
        ..._program(id, channel, start: now, isSports: true),
        'Name': title,
      };
      Map<String, dynamic> hit(String id, String channel, String title) => {
        ...program(id, channel, title),
        'Type': 'Program',
      };
      when(() => _guide(api, category: GuideFilter.sports)).thenAnswer(
        (invocation) async => {
          'Items': [
            for (final id in _requestedIds(invocation))
              if (int.parse(id.substring(1)) % 5 == 0)
                program(
                  'sport-$id',
                  id,
                  id == 'c10' ? 'Soccer Highlights' :
                    id == 'c210' ? 'Soccer Tournament' : 'SportsCentre',
                ),
          ],
        },
      );
      final pending = Completer<List<Map<String, dynamic>>>();
      late void Function(List<Map<String, dynamic>>) publish;
      when(() => api.searchProgramTitlesIncrementally(
        'soccer',
        isCurrent: any(named: 'isCurrent'),
        onBatch: any(named: 'onBatch'),
      )).thenAnswer((invocation) {
        publish = invocation.namedArguments[#onBatch]
            as void Function(List<Map<String, dynamic>>);
        return pending.future;
      });

      final vm = LiveTvGuideViewModel(client, now: () => now);
      addTearDown(vm.dispose);
      await vm.load(windowStart: now);
      vm.setFilter(GuideFilter.sports);
      await pumpEventQueue();
      expect(vm.programsForChannel('c10').single.name, 'Soccer Highlights');
      expect(vm.hasMorePrograms, isTrue);

      clearInteractions(api);
      vm.setChannelQuery('soccer');
      publish([hit('first', 'c10', 'Soccer Highlights')]);
      await pumpEventQueue();
      expect(vm.filteredChannels.map((c) => c.id), ['c10']);
      verifyNever(() => _guide(api, category: GuideFilter.sports));

      publish([hit('second', 'c210', 'Soccer Tournament')]);
      await pumpEventQueue();
      expect(vm.filteredChannels.map((c) => c.id), ['c10', 'c210']);
      verifyNever(() => _guide(api, category: GuideFilter.sports));

      pending.complete([
        hit('first', 'c10', 'Soccer Highlights'),
        hit('second', 'c210', 'Soccer Tournament'),
      ]);
      await pumpEventQueue();
      expect(vm.searchingProgramTitles, isFalse);
      expect(vm.programsForChannel('c10').single.name, 'Soccer Highlights');
      // The search result qualifies without requesting another EPG page.
      // Regular guide paging may load this channel's timeline on demand.
      expect(vm.programsForChannel('c210'), isEmpty);
      expect(vm.hasMorePrograms, isTrue);
    });

    test('search changes during lazy category paging load only missing matches', () async {
      final api = _SearchableLiveTvApi();
      when(() => client.liveTvApi).thenReturn(api);
      when(() => _guide(api)).thenAnswer((_) async => {'Items': []});
      _stubChannels(api, [
        for (var i = 0; i < 500; i++) {
          ..._channel('c$i', number: '$i'),
          if (i == 420 || i == 430) 'Name': 'TSN $i',
        },
      ]);
      final now = DateTime.utc(2026, 11, 14, 17);
      final pendingPage = Completer<Map<String, dynamic>>();
      final requested = <List<String>>[];
      when(() => _guide(api, category: GuideFilter.sports))
          .thenAnswer((invocation) {
            final ids = List<String>.from(_requestedIds(invocation));
            requested.add(ids);
            if (ids.first == 'c200') return pendingPage.future;
            return Future.value({
              'Items': [
                for (final id in ids)
                  if (int.parse(id.substring(1)) < 24 || id == 'c420')
                    _program('sport-$id', id, start: now, isSports: true),
              ],
            });
          });
      when(() => api.searchProgramTitles(
        'tsn', isCurrent: any(named: 'isCurrent'),
      )).thenAnswer((_) async => <Map<String, dynamic>>[]);

      final vm = LiveTvGuideViewModel(client, now: () => now);
      addTearDown(vm.dispose);
      await vm.load(windowStart: now);
      vm.setFilter(GuideFilter.sports);
      await pumpEventQueue();
      expect(vm.filteredChannels, hasLength(24));
      expect(requested, hasLength(1));

      final lazyPage = vm.loadMorePrograms();
      await pumpEventQueue();
      expect(requested, hasLength(2));
      expect(requested.last.first, 'c200');

      vm.setChannelQuery('tsn');
      await pumpEventQueue();
      expect(vm.filteredChannels, isEmpty);
      expect(requested, hasLength(2));

      // The previous page completes with enough unrelated Sports programs
      // that its original paging loop would stop without checking TSN.
      pendingPage.complete({
        'Items': [
          for (var i = 200; i < 224; i++)
            _program('sport-c$i', 'c$i', start: now, isSports: true),
        ],
      });
      await lazyPage;
      await pumpEventQueue();

      expect(requested, hasLength(3));
      expect(requested.last, ['c420', 'c430']);
      expect(vm.filteredChannels.map((c) => c.id), ['c420']);
      expect(vm.programsForChannel('c0').single.isSports, isTrue);
      expect(vm.programsForChannel('c200').single.isSports, isTrue);
      expect(vm.hasMorePrograms, isFalse);
      verify(() => api.searchProgramTitles(
        'tsn', isCurrent: any(named: 'isCurrent'),
      )).called(1);
    });

    test('a search change reuses an in-flight category page', () async {
      final api = _SearchableLiveTvApi();
      when(() => client.liveTvApi).thenReturn(api);
      when(() => _guide(api)).thenAnswer((_) async => {'Items': []});
      _stubChannels(api, [
        for (var i = 0; i < 200; i++) _channel('c$i'),
      ]);
      final now = DateTime.utc(2026, 11, 14, 17);
      Map<String, dynamic> hit(String id, String channel, String title) => {
        ..._program(id, channel, start: now, isSports: true),
        'Type': 'Program',
        'Name': title,
      };
      final page = Completer<Map<String, dynamic>>();
      when(() => _guide(api, category: GuideFilter.sports))
          .thenAnswer((_) => page.future);
      when(() => api.searchProgramTitles(
        'soccer', isCurrent: any(named: 'isCurrent'),
      )).thenAnswer((_) async => [hit('s1', 'c10', 'Soccer Highlights')]);

      final vm = LiveTvGuideViewModel(client, now: () => now);
      addTearDown(vm.dispose);
      await vm.load(windowStart: now);
      vm.setFilter(GuideFilter.sports);
      expect(vm.state, GuideState.loading);
      vm.setChannelQuery('soccer');
      await pumpEventQueue();

      page.complete({
        'Items': [
          for (var i = 0; i < 30; i++)
            hit('p$i', 'c$i',
              i == 10 ? 'Soccer Highlights' : 'SportsCentre'),
        ],
      });
      await pumpEventQueue();
      expect(vm.state, GuideState.ready);
      expect(vm.filteredChannels.map((c) => c.id), ['c10']);
      verify(() => _guide(api, category: GuideFilter.sports)).called(1);
    });


    test('program categories filter search results across guide dates', () async {
      final api = _SearchableLiveTvApi();
      when(() => client.liveTvApi).thenReturn(api);
      when(() => _guide(api)).thenAnswer((_) async => {'Items': []});
      _stubChannels(api, [
        {'Id': 'tsn', 'Name': 'TSN', 'ChannelNumber': '10'},
        {'Id': 'hbo', 'Name': 'HBO', 'ChannelNumber': '20'},
        {'Id': 'espn', 'Name': 'ESPN', 'ChannelNumber': '30'},
        {'Id': 'unknown', 'Name': 'Channel Four', 'ChannelNumber': '40'},
        {'Id': 'onesoccer', 'Name': 'OneSoccer', 'ChannelNumber': '50'},
      ]);
      final now = DateTime.utc(2026, 11, 14, 17);
      final future = now.add(const Duration(days: 2));
      Map<String, dynamic> hit(
        String id, String channel, {
        bool? sports,
        bool? movie,
        bool? series,
      }) => {
        'Id': id,
        'Type': 'Program',
        'ChannelId': channel,
        'Name': 'Soccer $id',
        'StartDate': future.toIso8601String(),
        'EndDate': future.add(const Duration(hours: 1)).toIso8601String(),
        if (sports != null) 'IsSports': sports,
        if (movie != null) 'IsMovie': movie,
        if (series != null) 'IsSeries': series,
      };
      when(() => api.searchProgramTitles(
        'soccer', isCurrent: any(named: 'isCurrent'),
      )).thenAnswer((_) async => [
        hit('match', 'tsn', sports: true),
        hit('documentary', 'hbo', sports: false, movie: true),
        hit('highlights', 'espn', sports: true, series: true),
        hit('special', 'unknown'),
      ]);
      when(() => _guide(api, category: GuideFilter.sports)).thenAnswer(
        (_) async => {'Items': []},
      );
      when(() => _guide(api, category: GuideFilter.movies)).thenAnswer(
        (_) async => {'Items': []},
      );
      when(() => _guide(api, category: GuideFilter.series)).thenAnswer(
        (_) async => {'Items': []},
      );

      final vm = LiveTvGuideViewModel(client, now: () => now);
      addTearDown(vm.dispose);
      await vm.load(windowStart: now);
      vm.setChannelQuery('soccer');
      await pumpEventQueue();
      expect(vm.filteredChannels.map((c) => c.id), [
        'tsn', 'hbo', 'espn', 'unknown', 'onesoccer',
      ]);

      vm.setFilter(GuideFilter.sports);
      await pumpEventQueue();
      expect(vm.filteredChannels.map((c) => c.id), ['tsn', 'espn']);
      expect(vm.futureSearchMatchForChannel('tsn')?.start, future);
      expect(vm.futureSearchMatchForChannel('espn')?.start, future);
      expect(vm.futureSearchMatchForChannel('hbo'), isNull);
      expect(vm.futureSearchMatchForChannel('unknown'), isNull);
      expect(vm.nextSearchMatchForChannel('tsn')?.title, 'Soccer match');

      vm.setFilter(GuideFilter.movies);
      await pumpEventQueue();
      expect(vm.filteredChannels.map((c) => c.id), ['hbo']);
      expect(vm.futureSearchMatchForChannel('hbo')?.start, future);

      vm.setFilter(GuideFilter.series);
      await pumpEventQueue();
      expect(vm.filteredChannels.map((c) => c.id), ['espn']);

      vm.setFilter(GuideFilter.all);
      await pumpEventQueue();
      expect(vm.filteredChannels.map((c) => c.id), [
        'tsn', 'hbo', 'espn', 'unknown', 'onesoccer',
      ]);
      verify(() => api.searchProgramTitles(
        'soccer', isCurrent: any(named: 'isCurrent'),
      )).called(1);
    });

    test('search result flags preserve missing versus explicit false', () async {
      final items = _MockItemsApi();
      when(() => client.itemsApi).thenReturn(items);
      when(() => items.getItems(
        searchTerm: 'soccer',
        includeItemTypes: any(named: 'includeItemTypes'),
        recursive: true,
        startIndex: 0,
        limit: 200,
      )).thenAnswer((_) async => {
        'TotalRecordCount': 2,
        'Items': [
          {
            'Id': 'sports',
            'Type': 'LiveTvProgram',
            'ChannelId': 'tsn',
            'Name': 'Soccer',
            'StartDate': '2026-11-16T19:00:00Z',
            'EndDate': '2026-11-16T20:00:00Z',
            'IsSports': true,
            'IsMovie': false,
            'IsSeries': true,
            'IsNews': false,
            'IsKids': false,
            'IsPremiere': true,
          },
          {
            'Id': 'unknown',
            'Type': 'LiveTvProgram',
            'ChannelId': 'hbo',
            'Name': 'Soccer Special',
            'StartDate': '2026-11-16T19:00:00Z',
            'EndDate': '2026-11-16T20:00:00Z',
          },
        ],
      });

      final results = await searchGuideProgramTitles(
        client, 'soccer', isCurrent: () => true,
      );
      expect(results, hasLength(2));
      expect(results.first.isSports, isTrue);
      expect(results.first.isMovie, isFalse);
      expect(results.first.isSeries, isTrue);
      expect(results.first.isPremiere, isTrue);
      expect(results.first.isNews, isFalse);
      expect(results.first.isKids, isFalse);
      expect(results.last.isSports, isNull);
      expect(results.last.isMovie, isNull);
      expect(results.last.isSeries, isNull);
    });

    test('Emby search carries program category flags', () async {
      final items = _MockItemsApi();
      when(() => client.itemsApi).thenReturn(items);
      when(() => client.serverType).thenReturn(ServerType.emby);
      when(() => items.getItems(
        searchTerm: 'soccer',
        includeItemTypes: any(named: 'includeItemTypes'),
        recursive: true,
        startIndex: 0,
        limit: 200,
      )).thenAnswer((invocation) async {
        expect(invocation.namedArguments[#includeItemTypes], ['Program']);
        return {
          'TotalRecordCount': 1,
          'Items': [{
            'Id': 'match',
            'Type': 'Program',
            'ChannelId': 'tsn',
            'Name': 'Soccer Final',
            'StartDate': '2026-11-16T19:00:00Z',
            'EndDate': '2026-11-16T20:00:00Z',
            'IsSports': true,
            'IsMovie': false,
            'IsNews': true,
          }],
        };
      });
      final matches = await searchGuideProgramTitles(
        client, 'soccer', isCurrent: () => true,
      );
      expect(matches, hasLength(1));
      expect(matches.single.isSports, isTrue);
      expect(matches.single.isMovie, isFalse);
      expect(matches.single.isNews, isTrue);
      expect(matches.single.isKids, isNull);
    });

    test('mobile later-match uses only the selected program category', () async {
      final api = _SearchableLiveTvApi();
      when(() => client.liveTvApi).thenReturn(api);
      final now = DateTime.utc(2026, 11, 14, 17);
      final nextTime = now.add(const Duration(minutes: 30));
      final soccerTime = now.add(const Duration(minutes: 60));
      final movieTime = now.add(const Duration(minutes: 90));
      _stubChannels(api, [{'Id': 'tsn', 'Name': 'TSN'}]);
      when(() => _guide(api)).thenAnswer((_) async => {'Items': []});
      when(() => _guide(api, category: GuideFilter.sports))
          .thenAnswer((_) async => {
            'Items': [
              _program('SportsCentre', 'tsn', start: now, isSports: true),
              _program('Hockey Tonight', 'tsn', start: nextTime, isSports: true),
              _program('Soccer Highlights', 'tsn', start: soccerTime, isSports: true),
            ],
          });
      Map<String, dynamic> hit(String id, DateTime start, bool? isSports) => {
        'Id': id,
        'Type': 'Program',
        'ChannelId': 'tsn',
        'Name': id,
        'StartDate': start.toIso8601String(),
        'EndDate': start.add(const Duration(minutes: 30)).toIso8601String(),
        if (isSports != null) 'IsSports': isSports,
      };
      when(() => api.searchProgramTitles(
        'soccer', isCurrent: any(named: 'isCurrent'),
      )).thenAnswer((_) async => [
        hit('Soccer Movie', movieTime, false),
        hit('Soccer Highlights', soccerTime, true),
        hit('Soccer Special', movieTime.add(const Duration(minutes: 30)), null),
      ]);

      final vm = LiveTvGuideViewModel(client, now: () => now);
      addTearDown(vm.dispose);
      await vm.load(windowStart: now);
      vm.setFilter(GuideFilter.sports);
      await pumpEventQueue();
      vm.setChannelQuery('soccer');
      await pumpEventQueue();
      final nowNext = vm.nowNextForChannel('tsn');
      expect(nowNext.now?.name, 'SportsCentre');
      expect(nowNext.next?.name, 'Hockey Tonight');
      final match = vm.laterSearchMatchForChannel(
        'tsn', now: nowNext.now, next: nowNext.next,
      );
      expect(match?.title, 'Soccer Highlights');
      expect(match?.start, soccerTime);
      expect(vm.futureSearchMatchForChannel('tsn'), isNull);
      expect(vm.nextSearchMatchForChannel('tsn',
        after: soccerTime.add(const Duration(minutes: 30))), isNull);
    });

    test('future-only category hits prefetch pages only near the loaded edge', () async {
      final api = _SearchableLiveTvApi();
      when(() => client.liveTvApi).thenReturn(api);
      final now = DateTime.utc(2026, 11, 14, 17);
      final future = now.add(const Duration(days: 1));
      _stubChannels(api, [
        for (var i = 0; i < 250; i++)
          _channel('c$i', number: '$i'),
      ]);
      when(() => _guide(api)).thenAnswer((_) async => {'Items': []});
      when(() => _guide(api, category: GuideFilter.sports))
          .thenAnswer((_) async => {'Items': []});
      when(() => api.searchProgramTitles(
        'soccer', isCurrent: any(named: 'isCurrent'),
      )).thenAnswer((_) async => [
        for (var i = 0; i < 250; i++)
          {
            'Id': 'future-$i',
            'Type': 'Program',
            'ChannelId': 'c$i',
            'Name': 'Soccer Tournament',
            'IsSports': true,
            'StartDate': future.toIso8601String(),
            'EndDate': future.add(const Duration(hours: 1))
                .toIso8601String(),
          },
      ]);

      final vm = LiveTvGuideViewModel(client, now: () => now);
      addTearDown(vm.dispose);
      await vm.load(windowStart: now);
      vm.setChannelQuery('soccer');
      await pumpEventQueue();
      vm.setFilter(GuideFilter.sports);
      await pumpEventQueue();

      expect(vm.filteredChannels, hasLength(250));
      expect(vm.programsForChannel('c0'), isEmpty);
      expect(vm.programsHighWater, 200);
      expect(vm.hasMorePrograms, isTrue);
      verify(() => _guide(api, category: GuideFilter.sports)).called(1);
      clearInteractions(api);

      // Only an explicit next-page request loads the remaining channels.
      await vm.loadMorePrograms();
      expect(vm.programsHighWater, 250);
      expect(vm.hasMorePrograms, isFalse);
      verify(() => _guide(api, category: GuideFilter.sports)).called(1);
    });

    test('category search does not scan later windows for verification', () async {
      final api = _SearchableLiveTvApi();
      when(() => client.liveTvApi).thenReturn(api);
      when(() => _guide(api)).thenAnswer((_) async => {'Items': []});
      _stubChannels(api, [
        for (var i = 0; i < 450; i++) _channel('c$i'),
      ]);
      final now = DateTime.utc(2026, 11, 14, 17);
      final future = now.add(const Duration(days: 1));
      when(() => api.searchProgramTitles(
        'soccer', isCurrent: any(named: 'isCurrent'),
      )).thenAnswer((_) async => [
        {
          'Id': 'future',
          'Type': 'Program',
          'ChannelId': 'c420',
          'Name': 'Soccer Tournament',
          'IsSports': true,
          'StartDate': future.toIso8601String(),
          'EndDate': future.add(const Duration(hours: 1)).toIso8601String(),
        },
      ]);
      when(() => _guide(api, category: GuideFilter.sports)).thenAnswer(
        (call) async => {
          'Items': [
            for (final id in _requestedIds(call))
              _program('sports-$id', id, start: now, isSports: true),
          ],
        },
      );

      final vm = LiveTvGuideViewModel(client, now: () => now);
      addTearDown(vm.dispose);
      await vm.load(windowStart: now);
      vm.setFilter(GuideFilter.sports);
      await pumpEventQueue();
      clearInteractions(api);
      vm.setChannelQuery('soccer');
      await pumpEventQueue();
      expect(vm.filteredChannels.map((c) => c.id), ['c420']);
      expect(vm.futureSearchMatchForChannel('c420')?.start, future);
      verifyNever(() => _guide(api, category: GuideFilter.sports));
      verify(() => api.searchProgramTitles(
        'soccer', isCurrent: any(named: 'isCurrent'),
      )).called(1);
    });

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

    for (final newerHasPrograms in [true, false]) {
      test(
        newerHasPrograms
            ? 'targeted category result wins over an older paging response'
            : 'newer negative category result is not replaced by an old match',
        () async {
          _stubChannels(liveTv, [
            for (var i = 0; i < 450; i++) _channel('c$i', number: '$i'),
          ]);
          when(() => _guide(liveTv)).thenAnswer((_) async => {'Items': []});
          final olderPage = Completer<Map<String, dynamic>>();
          when(() => _guide(liveTv, category: GuideFilter.sports))
              .thenAnswer((call) {
                final ids = _requestedIds(call);
                if (ids.length == 200 && ids.first == 'c200') {
                  return olderPage.future;
                }
                if (ids.length == 1 && ids.single == 'c210') {
                  return Future.value({
                    'Items': [
                      if (newerHasPrograms)
                        _program('newer', 'c210', isSports: true),
                    ],
                  });
                }
                return Future.value({
                  'Items': [
                    for (final id in ids)
                      if (int.parse(id.substring(1)) < 24)
                        _program('initial-$id', id, isSports: true),
                  ],
                });
              });

          final vm = LiveTvGuideViewModel(client);
          addTearDown(vm.dispose);
          await vm.load();
          vm.setFilter(GuideFilter.sports);
          await pumpEventQueue();
          expect(vm.filteredChannels, hasLength(24));

          final paging = vm.loadMorePrograms();
          await pumpEventQueue();
          final targeted = await vm.ensureCategoryChannel('c210');
          expect(targeted, newerHasPrograms);
          if (newerHasPrograms) {
            expect(vm.programsForChannel('c210').single.id, 'newer');
          } else {
            expect(vm.programsForChannel('c210'), isEmpty);
          }

          olderPage.complete({
            'Items': [
              _program('older', 'c210', isSports: true),
              for (var i = 200; i < 224; i++)
                if (i != 210)
                  _program('sport-c$i', 'c$i', isSports: true),
            ],
          });
          await paging;
          expect(vm.filteredChannels.any((c) => c.id == 'c210'),
              newerHasPrograms);
          if (newerHasPrograms) {
            expect(vm.programsForChannel('c210').single.id, 'newer');
          } else {
            expect(vm.programsForChannel('c210'), isEmpty);
          }
        },
      );
    }

    for (final finishCategoryFirst in [true, false]) {
      test(
        finishCategoryFirst
            ? 'initial category resumes after recording refresh completes'
            : 'initial category resumes after late page arrives',
        () async {
          _stubChannels(liveTv, [
            for (var i = 0; i < 450; i++) _channel('c$i', number: '$i'),
          ]);
          final firstCategory = Completer<Map<String, dynamic>>();
          final recordingGuide = Completer<Map<String, dynamic>>();
          var holdRecordingGuide = false;
          final requested = <List<String>>[];
          when(() => _guide(liveTv)).thenAnswer((_) =>
              holdRecordingGuide ? recordingGuide.future :
              Future.value({'Items': []}));
          when(() => _guide(liveTv, category: GuideFilter.sports))
              .thenAnswer((call) {
                final ids = List<String>.of(_requestedIds(call));
                requested.add(ids);
                if (requested.length == 1) return firstCategory.future;
                return Future.value({
                  'Items': [
                    for (final id in ids.take(25))
                      _program('current-$id', id, isSports: true),
                  ],
                });
              });

          final vm = LiveTvGuideViewModel(client);
          addTearDown(vm.dispose);
          await vm.load();
          vm.setFilter(GuideFilter.sports);
          await pumpEventQueue();
          expect(vm.state, GuideState.loading);
          expect(requested, hasLength(1));

          holdRecordingGuide = true;
          final refreshing = vm.recordingChanged();
          await pumpEventQueue();
          if (finishCategoryFirst) {
            firstCategory.complete({'Items': [
              _program('superseded', 'c0', isSports: true),
            ]});
            await pumpEventQueue();
            expect(requested, hasLength(1));
            recordingGuide.complete({'Items': []});
            await refreshing;
          } else {
            recordingGuide.complete({'Items': []});
            await refreshing;
            expect(requested, hasLength(1));
            firstCategory.complete({'Items': [
              _program('superseded', 'c0', isSports: true),
            ]});
          }
          await pumpEventQueue();
          expect(vm.state, GuideState.ready);
          expect(requested, hasLength(2));
          expect(requested.last.first, 'c0');
          expect(vm.filteredChannels, hasLength(25));
          expect(vm.programsForChannel('c0').single.id, 'current-c0');
          expect(vm.hasMorePrograms, isTrue);
        },
      );
    }

    for (final completeOldPageFirst in [true, false]) {
      test(
        completeOldPageFirst
            ? 'recording refresh resumes an invalidated page after the refresh'
            : 'recording refresh resumes an in-flight page when it finishes',
        () async {
          final api = _SearchableLiveTvApi();
          when(() => client.liveTvApi).thenReturn(api);
          _stubChannels(api, [
            for (var i = 0; i < 500; i++) {
              ..._channel('c$i', number: '$i'),
              if (i == 420 || i == 430) 'Name': 'TSN $i',
            },
          ]);
          final oldPage = Completer<Map<String, dynamic>>();
          final refreshGuide = Completer<Map<String, dynamic>>();
          var holdUnfilteredRefresh = false;
          final requested = <List<String>>[];
          when(() => _guide(api)).thenAnswer((_) =>
              holdUnfilteredRefresh ? refreshGuide.future :
              Future.value({'Items': []}));
          when(() => _guide(api, category: GuideFilter.sports))
              .thenAnswer((call) {
                final ids = List<String>.of(_requestedIds(call));
                requested.add(ids);
                if (ids.first == 'c200') return oldPage.future;
                return Future.value({
                  'Items': [
                    for (final id in ids)
                      if (int.parse(id.substring(1)) < 24 || id == 'c420')
                        _program('sport-$id', id, isSports: true),
                  ],
                });
              });
          when(() => api.searchProgramTitles(
            'tsn', isCurrent: any(named: 'isCurrent'),
          )).thenAnswer((_) async => <Map<String, dynamic>>[]);

          final vm = LiveTvGuideViewModel(client);
          addTearDown(vm.dispose);
          await vm.load();
          vm.setFilter(GuideFilter.sports);
          await pumpEventQueue();
          expect(vm.filteredChannels, hasLength(24));

          final paging = vm.loadMorePrograms();
          await pumpEventQueue();
          expect(requested.last.first, 'c200');
          vm.setChannelQuery('tsn');
          await pumpEventQueue();
          expect(vm.filteredChannels, isEmpty);

          holdUnfilteredRefresh = true;
          final refreshing = vm.recordingChanged();
          await pumpEventQueue();

          if (completeOldPageFirst) {
            oldPage.complete({
              'Items': [_program('old', 'c210', isSports: true)],
            });
            await paging;
            expect(requested.where((ids) => ids.contains('c420')), isEmpty);
            refreshGuide.complete({'Items': []});
            await refreshing;
          } else {
            refreshGuide.complete({'Items': []});
            await refreshing;
            expect(requested.where((ids) => ids.contains('c420')), isEmpty);
            oldPage.complete({
              'Items': [_program('old', 'c210', isSports: true)],
            });
            await paging;
          }
          await pumpEventQueue();
          expect(requested.where((ids) => ids.contains('c420')), hasLength(1));
          expect(vm.filteredChannels.map((c) => c.id), ['c420']);
          expect(vm.programsForChannel('c420').single.isSports, isTrue);
          expect(vm.hasMorePrograms, isFalse);
        },
      );
    }

    for (final targetedFinishesFirst in [true, false]) {
      test(
        targetedFinishesFirst
            ? 'completed targeted lookup lets category paging advance'
            : 'category paging waits for a pending targeted lookup',
        () async {
          _stubChannels(liveTv, [
            for (var i = 0; i < 500; i++) _channel('c$i', number: '$i'),
          ]);
          final oldPage = Completer<Map<String, dynamic>>();
          final targetReply = Completer<Map<String, dynamic>>();
          final requested = <List<String>>[];
          when(() => _guide(liveTv)).thenAnswer((_) async => {'Items': []});
          when(() => _guide(liveTv, category: GuideFilter.sports))
              .thenAnswer((call) {
                final ids = List<String>.of(_requestedIds(call));
                requested.add(ids);
                if (ids.first == 'c200') return oldPage.future;
                if (ids.length == 1 && ids.single == 'c210') {
                  return targetReply.future;
                }
                return Future.value({
                  'Items': [
                    for (final id in ids)
                      if (int.parse(id.substring(1)) < 24 || id == 'c420')
                        _program('sport-$id', id, isSports: true),
                  ],
                });
              });

          final vm = LiveTvGuideViewModel(client);
          addTearDown(vm.dispose);
          await vm.load();
          vm.setFilter(GuideFilter.sports);
          await pumpEventQueue();
          expect(vm.filteredChannels, hasLength(24));

          final paging = vm.loadMorePrograms();
          await pumpEventQueue();
          expect(requested.last.first, 'c200');
          final targeted = vm.ensureCategoryChannel('c210');
          await pumpEventQueue();
          expect(requested.last, ['c210']);

          if (targetedFinishesFirst) {
            targetReply.complete({'Items': []});
            expect(await targeted, isFalse);
            oldPage.complete({'Items': []});
          } else {
            oldPage.complete({'Items': []});
            await pumpEventQueue();
            expect(requested.any((ids) => ids.first == 'c400'), isFalse);
            targetReply.complete({'Items': []});
            expect(await targeted, isFalse);
          }
          await paging;
          expect(requested.where((ids) => ids.first == 'c400'), hasLength(1));
          expect(requested.where((ids) =>
              ids.length == 1 && ids.single == 'c210'), hasLength(1));
          expect(vm.filteredChannels.map((c) => c.id), [
            for (var i = 0; i < 24; i++) 'c$i',
            'c420',
          ]);
          expect(vm.hasMorePrograms, isFalse);
        },
      );
    }

    for (final targetedFailsFirst in [true, false]) {
      test(
        targetedFailsFirst
            ? 'failed targeted lookup does not stop later category pages'
            : 'background page continues after a pending targeted lookup fails',
        () async {
          _stubChannels(liveTv, [
            for (var i = 0; i < 500; i++) _channel('c$i', number: '$i'),
          ]);
          final background = Completer<Map<String, dynamic>>();
          final firstTarget = Completer<Map<String, dynamic>>();
          final requested = <List<String>>[];
          var targetedRequests = 0;
          when(() => _guide(liveTv)).thenAnswer((_) async => {'Items': []});
          when(() => _guide(liveTv, category: GuideFilter.sports))
              .thenAnswer((call) {
                final ids = List<String>.of(_requestedIds(call));
                requested.add(ids);
                if (ids.length == 200 && ids.first == 'c200') {
                  return background.future;
                }
                if (ids.length == 1 && ids.single == 'c210') {
                  targetedRequests++;
                  if (targetedRequests == 1) return firstTarget.future;
                  return Future.value({
                    'Items': [_program('retried', 'c210', isSports: true)],
                  });
                }
                return Future.value({
                  'Items': [
                    for (final id in ids)
                      if (int.parse(id.substring(1)) < 24 || id == 'c420')
                        _program('sport-$id', id, isSports: true),
                  ],
                });
              });

          final vm = LiveTvGuideViewModel(client);
          addTearDown(vm.dispose);
          await vm.load();
          vm.setFilter(GuideFilter.sports);
          await pumpEventQueue();
          expect(vm.filteredChannels, hasLength(24));

          final paging = vm.loadMorePrograms();
          await pumpEventQueue();
          final targeted = vm.ensureCategoryChannel('c210');
          final failed = expectLater(targeted, throwsA(isA<StateError>()));
          await pumpEventQueue();
          expect(targetedRequests, 1);

          if (targetedFailsFirst) {
            firstTarget.completeError(StateError('Temporary lookup failure'));
            await failed;
            background.complete({'Items': []});
          } else {
            background.complete({'Items': []});
            await pumpEventQueue();
            expect(requested.where((ids) => ids.first == 'c400'), isEmpty);
            firstTarget.completeError(StateError('Temporary lookup failure'));
            await failed;
          }
          await paging;

          // The unsuccessful lookup is not marked as successfully checked.
          expect(vm.hasProgramsFor('c210'), isFalse);
          expect(vm.filteredChannels.map((c) => c.id), [
            for (var i = 0; i < 24; i++) 'c$i',
            'c420',
          ]);
          expect(requested.where((ids) => ids.first == 'c400'), hasLength(1));
          expect(targetedRequests, 1);
          expect(vm.hasMorePrograms, isFalse);

          // An explicit targeted request can retry the previously failed channel.
          expect(await vm.ensureCategoryChannel('c210'), isTrue);
          expect(targetedRequests, 2);
          expect(vm.programsForChannel('c210').single.id, 'retried');
        },
      );
    }

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

    test('invalidated Sports refresh cannot acknowledge a recording change', () async {
      _stubChannels(liveTv, [_channel('c0'), _channel('c1')]);
      when(() => _guide(liveTv)).thenAnswer((_) async => {
        'Items': [
          _program('unfiltered-c0', 'c0'),
          _program('unfiltered-c1', 'c1'),
        ],
      });
      final staleSports = Completer<Map<String, dynamic>>();
      var sportsCalls = 0;
      when(() => _guide(liveTv, category: GuideFilter.sports))
          .thenAnswer((_) {
            sportsCalls++;
            if (sportsCalls == 2) return staleSports.future;
            final prefix = sportsCalls == 1 ? 'old' : 'fresh';
            return Future.value({
              'Items': [
                _program('$prefix-c0', 'c0', isSports: true),
                _program('$prefix-c1', 'c1', isSports: true),
              ],
            });
          });

      final vm = LiveTvGuideViewModel(client);
      addTearDown(vm.dispose);
      await vm.load();
      vm.setFilter(GuideFilter.sports);
      await pumpEventQueue();
      expect(vm.programsForChannel('c0').single.id, 'old-c0');

      final changing = vm.recordingChanged();
      await pumpEventQueue();
      expect(sportsCalls, 2);

      // This replaces the unfiltered programs successfully, but invalidates
      // the pending Sports response without updating the category listings.
      await vm.replacePrograms(
        channelIds: const ['c0'],
        from: vm.windowStart,
        to: vm.windowEnd,
      );
      staleSports.complete({
        'Items': [_program('stale-c0', 'c0', isSports: true)],
      });
      await changing;
      await pumpEventQueue();

      // The recording revision stays pending until Sports itself refreshes.
      expect(sportsCalls, 3);
      expect(vm.programsForChannel('c0').single.id, 'fresh-c0');
      expect(vm.programsForChannel('c1').single.id, 'fresh-c1');
      clearInteractions(liveTv);
      await vm.reloadIfRecordingsChanged();
      verifyNever(() => _guide(liveTv));
    });

    test('Sports refresh waits for unfiltered channel replacements too', () async {
      _stubChannels(liveTv, [_channel('c0'), _channel('c1')]);
      final heldUnfiltered = Completer<Map<String, dynamic>>();
      var recordingStarted = false;
      var unfilteredCalls = 0;
      when(() => _guide(liveTv)).thenAnswer((call) {
        final ids = List<String>.of(_requestedIds(call));
        if (!recordingStarted) {
          return Future.value({'Items': [
            for (final id in ids) _program('initial-$id', id),
          ]});
        }
        unfilteredCalls++;
        if (unfilteredCalls == 1) return heldUnfiltered.future;
        return Future.value({'Items': [
          for (final id in ids)
            {..._program('updated-$id', id), 'TimerId': 'timer-new'},
        ]});
      });
      var sportsCalls = 0;
      when(() => _guide(liveTv, category: GuideFilter.sports))
          .thenAnswer((call) {
            sportsCalls++;
            return Future.value({'Items': [
              for (final id in _requestedIds(call))
                _program('sport-$id', id, isSports: true),
            ]});
          });

      final vm = LiveTvGuideViewModel(client);
      addTearDown(vm.dispose);
      await vm.load();
      vm.setFilter(GuideFilter.sports);
      await pumpEventQueue();
      expect(sportsCalls, 1);

      recordingStarted = true;
      final changing = vm.recordingChanged();
      await pumpEventQueue();
      expect(sportsCalls, 2);
      expect(unfilteredCalls, 1);

      // Supersede the unfiltered request after Sports already refreshed.
      await vm.replacePrograms(
        channelIds: const ['c0'],
        from: vm.windowStart,
        to: vm.windowEnd,
      );
      heldUnfiltered.complete({'Items': [_program('stale-c0', 'c0')]});
      await changing;
      await pumpEventQueue();

      // A ready Sports category alone must not acknowledge the revision.
      expect(sportsCalls, 3);
      expect(vm.unfilteredProgramsForChannel('c1').single.hasTimer, isTrue);
      clearInteractions(liveTv);
      await vm.reloadIfRecordingsChanged();
      verifyNever(() => _guide(liveTv));
    });

    test('successful category refresh removes channels with no matching programs', () async {
      _stubChannels(liveTv, [_channel('c0'), _channel('c1')]);
      when(() => _guide(liveTv)).thenAnswer((_) async => {'Items': []});
      var currentSports = true;
      when(() => _guide(liveTv, category: GuideFilter.sports))
          .thenAnswer((_) async => {
            'Items': [
              if (currentSports)
                _program('sports-on-c0', 'c0', isSports: true),
              _program('sports-on-c1', 'c1', isSports: true),
            ],
          });

      final vm = LiveTvGuideViewModel(client);
      addTearDown(vm.dispose);
      await vm.load();
      vm.setFilter(GuideFilter.sports);
      await pumpEventQueue();
      expect(vm.filteredChannels.map((c) => c.id), ['c0', 'c1']);

      currentSports = false;
      await vm.recordingChanged();
      expect(vm.state, GuideState.ready);
      expect(vm.filteredChannels.map((c) => c.id), ['c1']);
      expect(vm.programsForChannel('c0'), isEmpty);
      expect(vm.programsForChannel('c1').single.name, 'sports-on-c1');
      verify(() => _guide(liveTv, category: GuideFilter.sports)).called(2);
    });

    test('refresh refills a category search after its visible rows disappear', () async {
      final api = _SearchableLiveTvApi();
      when(() => client.liveTvApi).thenReturn(api);
      when(() => _guide(api)).thenAnswer((_) async => {'Items': []});
      _stubChannels(api, [
        for (var i = 0; i < 500; i++) {
          ..._channel('c$i', number: '$i'),
          if (i < 24 || (i >= 420 && i < 426)) 'Name': 'TSN $i',
        },
      ]);
      var oldSportsRemoved = false;
      final requested = <List<String>>[];
      when(() => _guide(api, category: GuideFilter.sports))
          .thenAnswer((call) async {
            final ids = List<String>.of(_requestedIds(call));
            requested.add(ids);
            return {
              'Items': [
                for (final id in ids)
                  if ((!oldSportsRemoved && int.parse(id.substring(1)) < 24) ||
                      (int.parse(id.substring(1)) >= 420 &&
                          int.parse(id.substring(1)) < 426))
                    _program('sport-$id', id, isSports: true),
              ],
            };
          });
      when(() => api.searchProgramTitles(
        'tsn', isCurrent: any(named: 'isCurrent'),
      )).thenAnswer((_) async => <Map<String, dynamic>>[]);

      final vm = LiveTvGuideViewModel(client);
      addTearDown(vm.dispose);
      await vm.load();
      vm.setFilter(GuideFilter.sports);
      await pumpEventQueue();
      vm.setChannelQuery('tsn');
      await pumpEventQueue();
      expect(vm.filteredChannels, hasLength(24));
      expect(vm.hasMorePrograms, isTrue);

      requested.clear();
      oldSportsRemoved = true;
      await vm.recordingChanged();
      await pumpEventQueue();

      expect(requested, [
        [for (var i = 0; i < 24; i++) 'c$i'],
        [for (var i = 420; i < 426; i++) 'c$i'],
      ]);
      expect(vm.filteredChannels.map((c) => c.id), [
        for (var i = 420; i < 426; i++) 'c$i',
      ]);
      expect(vm.hasMorePrograms, isFalse);
    });

    test('overlapping recording refreshes preserve removed-row paging', () async {
      final api = _SearchableLiveTvApi();
      when(() => client.liveTvApi).thenReturn(api);
      when(() => _guide(api)).thenAnswer((_) async => {'Items': []});
      _stubChannels(api, [
        for (var i = 0; i < 500; i++) {
          ..._channel('c$i', number: '$i'),
          if (i < 24 || (i >= 420 && i < 426)) 'Name': 'TSN $i',
        },
      ]);
      final firstRefresh = Completer<Map<String, dynamic>>();
      var refreshRequests = 0;
      final requested = <List<String>>[];
      when(() => _guide(api, category: GuideFilter.sports))
          .thenAnswer((call) {
            final ids = List<String>.of(_requestedIds(call));
            requested.add(ids);
            if (ids.length == 24 && ids.first == 'c0') {
              refreshRequests++;
              if (refreshRequests == 1) return firstRefresh.future;
              return Future.value({'Items': []});
            }
            return Future.value({
              'Items': [
                for (final id in ids)
                  if (int.parse(id.substring(1)) < 24 ||
                      (int.parse(id.substring(1)) >= 420 &&
                          int.parse(id.substring(1)) < 426))
                    _program('sport-$id', id, isSports: true),
              ],
            });
          });
      when(() => api.searchProgramTitles(
        'tsn', isCurrent: any(named: 'isCurrent'),
      )).thenAnswer((_) async => <Map<String, dynamic>>[]);

      final vm = LiveTvGuideViewModel(client);
      addTearDown(vm.dispose);
      await vm.load();
      vm.setFilter(GuideFilter.sports);
      await pumpEventQueue();
      vm.setChannelQuery('tsn');
      await pumpEventQueue();
      expect(vm.filteredChannels, hasLength(24));
      expect(vm.hasMorePrograms, isTrue);

      requested.clear();
      final older = vm.recordingChanged();
      await pumpEventQueue();
      expect(refreshRequests, 1);
      final newer = vm.recordingChanged();
      await newer;
      expect(refreshRequests, 2);
      expect(vm.filteredChannels, isEmpty);
      expect(requested.any((ids) => ids.contains('c420')), isFalse);

      // The refresh that removed all visible matches finished first.
      firstRefresh.complete({
        'Items': [_program('stale', 'c0', isSports: true)],
      });
      await older;
      await pumpEventQueue();

      expect(requested.where((ids) => ids.contains('c420')), hasLength(1));
      expect(vm.filteredChannels.map((c) => c.id), [
        for (var i = 420; i < 426; i++) 'c$i',
      ]);
      expect(vm.hasMorePrograms, isFalse);
    });

    test('an older recording refresh cannot lower the loaded revision', () async {
      _stubChannels(liveTv, [_channel('c0')]);
      when(() => _guide(liveTv)).thenAnswer(
        (_) async => {'Items': [_program('p0', 'c0')]},
      );
      final vm = LiveTvGuideViewModel(client);
      addTearDown(vm.dispose);
      await vm.load();

      final olderReply = Completer<Map<String, dynamic>>();
      var refreshCalls = 0;
      when(() => _guide(liveTv)).thenAnswer((_) {
        refreshCalls++;
        if (refreshCalls == 1) return olderReply.future;
        return Future.value({
          'Items': [{
            ..._program('p0', 'c0'),
            'TimerId': 'timer-new',
          }],
        });
      });

      final older = vm.recordingChanged();
      await pumpEventQueue();
      expect(refreshCalls, 1);
      final newer = vm.recordingChanged();
      await newer;
      expect(refreshCalls, 2);
      expect(vm.programsForChannel('c0').single.hasTimer, isTrue);

      olderReply.complete({'Items': [_program('p0', 'c0')]});
      await older;
      clearInteractions(liveTv);

      await vm.reloadIfRecordingsChanged();
      verifyNever(() => _guide(liveTv));
      expect(vm.programsForChannel('c0').single.hasTimer, isTrue);
    });

    test('a full guide load cannot lower a newer recording revision', () async {
      _stubChannels(liveTv, [_channel('c0')]);
      when(() => _guide(liveTv)).thenAnswer(
        (_) async => {'Items': [_program('p0', 'c0')]},
      );
      final vm = LiveTvGuideViewModel(client);
      addTearDown(vm.dispose);
      await vm.load();

      final lineupReply = Completer<Map<String, dynamic>>();
      when(() => _channelsRequest(liveTv))
          .thenAnswer((_) => lineupReply.future);
      final loading = vm.load();
      await pumpEventQueue();

      // The recording refresh finishes while the older full load is still
      // waiting for the channel lineup.
      await vm.recordingChanged();
      lineupReply.complete({'Items': [_channel('c0')]});
      await loading;

      clearInteractions(liveTv);
      await vm.reloadIfRecordingsChanged();
      verifyNever(() => _guide(liveTv));
    });

    test('a window reload cannot lower a newer recording revision', () async {
      final start = DateTime.utc(2026, 11, 14, 17);
      _stubChannels(liveTv, [_channel('c0')]);
      when(() => _guide(liveTv)).thenAnswer(
        (_) async => {'Items': [_program('initial', 'c0', start: start)]},
      );
      final vm = LiveTvGuideViewModel(client, now: () => start);
      addTearDown(vm.dispose);
      await vm.load(windowStart: start);

      final pending = Completer<Map<String, dynamic>>();
      var requests = 0;
      when(() => _guide(liveTv)).thenAnswer((_) {
        requests++;
        return pending.future;
      });
      final reloading = vm.shiftWindow(const Duration(hours: 3));
      await pumpEventQueue();
      expect(requests, 1);

      await vm.recordingChanged();
      pending.complete({
        'Items': [_program('old-window', 'c0',
            start: start.add(const Duration(hours: 3)))],
      });
      await reloading;

      clearInteractions(liveTv);
      await vm.reloadIfRecordingsChanged();
      verifyNever(() => _guide(liveTv));
    });

    test('recording refresh stops old-window batches after a guide shift', () async {
      final start = DateTime.utc(2026, 11, 14, 17);
      final later = start.add(const Duration(hours: 3));
      _stubChannels(liveTv, [
        for (var i = 0; i < 100; i++) _channel('c$i', number: '$i'),
      ]);
      final oldBatch = Completer<Map<String, dynamic>>();
      var recordingStarted = false;
      var heldOldBatch = false;
      final refreshRequests = <({DateTime from, List<String> ids})>[];
      when(() => _guide(liveTv)).thenAnswer((call) {
        final from = call.namedArguments[#startDate] as DateTime;
        final ids = List<String>.of(_requestedIds(call));
        if (recordingStarted) refreshRequests.add((from: from, ids: ids));
        if (recordingStarted &&
            !heldOldBatch &&
            from == start &&
            ids.first == 'c0') {
          heldOldBatch = true;
          return oldBatch.future;
        }
        return Future.value({
          'Items': [
            for (final id in ids)
              _program('${from == start ? 'earlier' : 'later'}-$id',
                  id, start: from),
          ],
        });
      });

      final vm = LiveTvGuideViewModel(client, now: () => start);
      addTearDown(vm.dispose);
      await vm.load(windowStart: start);
      await vm.loadMorePrograms();
      expect(vm.hasProgramsFor('c99'), isTrue);

      recordingStarted = true;
      final refreshing = vm.recordingChanged();
      await pumpEventQueue();
      expect(heldOldBatch, isTrue);

      await vm.shiftWindow(const Duration(hours: 3));
      expect(vm.windowStart, later);
      expect(vm.programsForChannel('c99').single.id, 'later-c99');

      oldBatch.complete({
        'Items': [_program('stale-c0', 'c0', start: start)],
      });
      await refreshing;
      await pumpEventQueue();

      // A late batch from the old window must never be issued for c50-c99.
      expect(refreshRequests.where((r) =>
          r.from == start && r.ids.contains('c50')), isEmpty);
      expect(vm.programsForChannel('c0').single.id, 'later-c0');
      expect(vm.programsForChannel('c99').single.id, 'later-c99');
      clearInteractions(liveTv);
      await vm.reloadIfRecordingsChanged();
      verifyNever(() => _guide(liveTv));
    });

    test('Sports load resumes a recording refresh deferred while loading', () async {
      _stubChannels(liveTv, [_channel('c0')]);
      when(() => _guide(liveTv)).thenAnswer((_) async => {
        'Items': [_program('all', 'c0')],
      });
      final firstSports = Completer<Map<String, dynamic>>();
      var sportsCalls = 0;
      when(() => _guide(liveTv, category: GuideFilter.sports))
          .thenAnswer((_) {
            sportsCalls++;
            if (sportsCalls == 1) return firstSports.future;
            return Future.value({
              'Items': [{
                ..._program('recorded-sport', 'c0', isSports: true),
                'TimerId': 'timer-new',
              }],
            });
          });

      final vm = LiveTvGuideViewModel(client);
      addTearDown(vm.dispose);
      await vm.load();
      // Simulate the ready guide having no loaded rows before switching chips.
      await vm.loadInitialPrograms(channelIds: const []);
      expect(vm.state, GuideState.ready);
      expect(vm.hasProgramsFor('c0'), isFalse);

      final refreshing = vm.recordingChanged();
      vm.setFilter(GuideFilter.sports);
      await pumpEventQueue();
      expect(vm.state, GuideState.loading);
      expect(sportsCalls, 1);
      await refreshing;
      expect(vm.state, GuideState.loading);

      firstSports.complete({
        'Items': [_program('old-sport', 'c0', isSports: true)],
      });
      await pumpEventQueue();

      expect(vm.state, GuideState.ready);
      expect(sportsCalls, 2);
      expect(vm.programsForChannel('c0').single.id, 'recorded-sport');
      expect(vm.programsForChannel('c0').single.hasTimer, isTrue);

      clearInteractions(liveTv);
      await vm.reloadIfRecordingsChanged();
      verifyNever(() => _guide(liveTv, category: GuideFilter.sports));
    });

    test('a recording change during a window reload is refreshed after loading', () async {
      final start = DateTime.utc(2026, 11, 14, 17);
      _stubChannels(liveTv, [_channel('c0')]);
      final stalePage = Completer<Map<String, dynamic>>();
      var reloading = false;
      var reloadCalls = 0;
      when(() => _guide(liveTv)).thenAnswer((_) {
        if (!reloading) {
          return Future.value({
            'Items': [_program('initial', 'c0', start: start)],
          });
        }
        reloadCalls++;
        if (reloadCalls == 1) return stalePage.future;
        return Future.value({
          'Items': [{
            ..._program('updated', 'c0', start: start.add(const Duration(hours: 3))),
            'TimerId': 'timer-new',
          }],
        });
      });

      final vm = LiveTvGuideViewModel(client, now: () => start);
      addTearDown(vm.dispose);
      await vm.load(windowStart: start);
      reloading = true;
      final shifting = vm.shiftWindow(const Duration(hours: 3));
      await pumpEventQueue();
      expect(reloadCalls, 1);
      expect(vm.hasProgramsFor('c0'), isFalse);

      // There are no loaded channels to refresh yet. Keep the revision pending.
      await vm.recordingChanged();
      expect(reloadCalls, 1);
      stalePage.complete({
        'Items': [_program('superseded', 'c0',
            start: start.add(const Duration(hours: 3)))],
      });
      await shifting;
      await pumpEventQueue();

      expect(reloadCalls, greaterThanOrEqualTo(2));
      expect(vm.programsForChannel('c0').single.hasTimer, isTrue);
      clearInteractions(liveTv);
      await vm.reloadIfRecordingsChanged();
      verifyNever(() => _guide(liveTv));
    });

    test('a recording change can reload an empty ready All Channels page', () async {
      _stubChannels(liveTv, [_channel('c0')]);
      var currentProgramIsRecorded = false;
      when(() => _guide(liveTv)).thenAnswer((_) async => {
        'Items': [
          {
            ..._program('p0', 'c0'),
            if (currentProgramIsRecorded) 'TimerId': 'timer-new',
          },
        ],
      });

      final vm = LiveTvGuideViewModel(client);
      addTearDown(vm.dispose);
      await vm.load();
      await vm.loadInitialPrograms(channelIds: const []);
      expect(vm.state, GuideState.ready);
      expect(vm.hasProgramsFor('c0'), isFalse);

      currentProgramIsRecorded = true;
      await vm.recordingChanged();
      await pumpEventQueue();
      expect(vm.hasProgramsFor('c0'), isTrue);
      expect(vm.programsForChannel('c0').single.hasTimer, isTrue);
      clearInteractions(liveTv);
      await vm.reloadIfRecordingsChanged();
      verifyNever(() => _guide(liveTv));
    });

    test('a recording change during a full load does not leave blank rows', () async {
      _stubChannels(liveTv, [_channel('c0')]);
      final stalePage = Completer<Map<String, dynamic>>();
      var reloading = false;
      var loadCalls = 0;
      when(() => _guide(liveTv)).thenAnswer((_) {
        if (!reloading) {
          return Future.value({
            'Items': [_program('initial', 'c0')],
          });
        }
        loadCalls++;
        if (loadCalls == 1) return stalePage.future;
        return Future.value({
          'Items': [{
            ..._program('updated', 'c0'),
            'TimerId': 'timer-new',
          }],
        });
      });

      final vm = LiveTvGuideViewModel(client);
      addTearDown(vm.dispose);
      await vm.load();
      reloading = true;
      final loading = vm.load();
      await pumpEventQueue();
      expect(loadCalls, 1);
      expect(vm.hasProgramsFor('c0'), isFalse);

      await vm.recordingChanged();
      expect(loadCalls, 1);
      stalePage.complete({'Items': [_program('superseded', 'c0')]});
      await loading;
      await pumpEventQueue();

      expect(loadCalls, greaterThanOrEqualTo(2));
      expect(vm.hasProgramsFor('c0'), isTrue);
      expect(vm.programsForChannel('c0').single.hasTimer, isTrue);
      clearInteractions(liveTv);
      await vm.reloadIfRecordingsChanged();
      verifyNever(() => _guide(liveTv));
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
