import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moonfin/data/repositories/user_views_repository.dart';
import 'package:moonfin/data/services/connectivity_service.dart';
import 'package:server_core/server_core.dart';

class _MockClient extends Mock implements MediaServerClient {}

class _MockUsersApi extends Mock implements UsersApi {}

class _MockViewsApi extends Mock implements UserViewsApi {}

class _TestConnectivity extends ConnectivityService {
  @override
  bool canReachServer = false;

  void reportReachable(bool value) {
    canReachServer = value;
    notifyListeners();
  }
}

void main() {
  late _MockUsersApi users;
  late _MockViewsApi views;
  late _TestConnectivity connectivity;
  late UserViewsRepository repo;

  setUp(() {
    users = _MockUsersApi();
    views = _MockViewsApi();
    final client = _MockClient();
    when(() => client.usersApi).thenReturn(users);
    when(() => client.userViewsApi).thenReturn(views);
    connectivity = _TestConnectivity();
    repo = UserViewsRepository(client, connectivity: connectivity);
  });

  tearDown(() {
    repo.dispose();
    connectivity.dispose();
  });

  // Answers on the next event loop turn, so callers that ask together are all
  // waiting on the same request rather than each finding the cache empty.
  Future<T> later<T>(T value) => Future.delayed(Duration.zero, () => value);

  test('rows asking together share one configuration request', () async {
    when(() => users.getUserConfiguration()).thenAnswer(
      (_) => later(const UserConfiguration(myMediaExcludes: ['hidden'])),
    );
    when(() => views.getUserViews(includeHidden: true)).thenAnswer(
      (_) => later({
        'Items': [
          {'Id': 'movies', 'Name': 'Movies'},
          {'Id': 'hidden', 'Name': 'Hidden'},
        ],
      }),
    );

    final results = await Future.wait([
      repo.getUserViews(),
      repo.getUserViews(),
      repo.getUserViews(),
    ]);

    verify(() => users.getUserConfiguration()).called(1);
    verify(() => views.getUserViews(includeHidden: true)).called(1);
    expect(results.every((r) => r.single.id == 'movies'), isTrue);
  });

  test('the raw and parsed views share one request', () async {
    when(
      () => users.getUserConfiguration(),
    ).thenAnswer((_) => later(const UserConfiguration()));
    when(() => views.getUserViews(includeHidden: true)).thenAnswer(
      (_) => later({
        'Items': [
          {'Id': 'movies', 'Name': 'Movies'},
        ],
      }),
    );

    final raw = repo.getVisibleViewsResponse();
    final parsed = repo.getAllViewsIncludingHidden();
    expect((await raw)['Items'], hasLength(1));
    expect((await parsed).single.name, 'Movies');
    verify(() => views.getUserViews(includeHidden: true)).called(1);
  });

  group('the views are kept for the session', () {
    setUpAll(() => registerFallbackValue(const UserConfiguration()));

    setUp(() {
      when(
        () => users.getUserConfiguration(),
      ).thenAnswer((_) => later(const UserConfiguration()));
      when(() => views.getUserViews(includeHidden: true)).thenAnswer(
        (_) => later({
          'Items': [
            {'Id': 'movies', 'Name': 'Movies'},
          ],
        }),
      );
    });

    test('a later screen reads them without a request', () async {
      await repo.getUserViews();
      await repo.getUserViews();

      verify(() => views.getUserViews(includeHidden: true)).called(1);
    });

    test('invalidating reads them again and tells the nav chrome', () async {
      var notified = 0;
      repo.addListener(() => notified++);
      await repo.getUserViews();

      repo.invalidateViews();
      await repo.getUserViews();

      expect(notified, 1);
      verify(() => views.getUserViews(includeHidden: true)).called(2);
    });

    test('saving the configuration reads them again', () async {
      when(() => users.updateUserConfiguration(any())).thenAnswer((_) async {});
      await repo.getUserViews();

      await repo.updateUserConfiguration(
        const UserConfiguration(orderedViews: ['movies']),
      );
      await repo.getUserViews();

      verify(() => views.getUserViews(includeHidden: true)).called(2);
    });
  });

  test('reconnect reloads the toolbar and Library Visibility lists', () async {
    final online = {
      'Items': [
        {'Id': 'movies', 'Name': 'Movies'},
        {'Id': 'hidden', 'Name': 'Hidden'},
      ],
    };
    when(() => users.getUserConfiguration()).thenAnswer(
      (_) async => const UserConfiguration(myMediaExcludes: ['hidden']),
    );
    when(() => views.getUserViews(includeHidden: true)).thenAnswer(
      (_) async => connectivity.canReachServer ? online : {'Items': []},
    );
    expect(await repo.getAllViewsIncludingHidden(), isEmpty);
    var reloads = 0;
    repo.addListener(() => reloads++);

    connectivity.reportReachable(true);
    connectivity.reportReachable(true);

    expect(reloads, 1);
    expect((await repo.getUserViews()).single.id, 'movies');
    expect((await repo.getAllViewsIncludingHidden()).map((v) => v.id), [
      'movies',
      'hidden',
    ]);
    verify(() => views.getUserViews(includeHidden: true)).called(2);
  });

  test('a late offline response cannot replace the online libraries', () async {
    final offline = Completer<Map<String, dynamic>>();
    when(() => views.getUserViews(includeHidden: true)).thenAnswer(
      (_) => connectivity.canReachServer
          ? later({
              'Items': [
                {'Id': 'movies', 'Name': 'Movies'},
              ],
            })
          : offline.future,
    );
    final pending = repo.getAllViewsIncludingHidden();
    connectivity.reportReachable(true);
    expect((await repo.getAllViewsIncludingHidden()).single.id, 'movies');

    offline.complete({'Items': []});
    expect((await pending).single.id, 'movies');
    expect((await repo.getAllViewsIncludingHidden()).single.id, 'movies');
    verify(() => views.getUserViews(includeHidden: true)).called(2);
  });

  test(
    'a forced configuration read still collapses while one is in flight',
    () async {
      when(
        () => users.getUserConfiguration(),
      ).thenAnswer((_) => later(const UserConfiguration()));

      await Future.wait([
        repo.getUserConfiguration(),
        repo.getUserConfiguration(),
      ]);
      verify(() => users.getUserConfiguration()).called(1);

      await repo.getUserConfiguration();
      verify(() => users.getUserConfiguration()).called(1);
    },
  );
}
