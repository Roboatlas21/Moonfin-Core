import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:moonfin/data/models/aggregated_library.dart';
import 'package:moonfin/data/repositories/user_views_repository.dart';
import 'package:moonfin/l10n/app_localizations.dart';
import 'package:moonfin/ui/screens/settings/library_settings_screen.dart';
import 'package:server_core/server_core.dart';

class _LibraryViews extends Fake
    with ChangeNotifier
    implements UserViewsRepository {
  _LibraryViews({required this.configUnavailable});

  bool configUnavailable;
  List<AggregatedLibrary> libraries = [];

  @override
  Future<UserConfiguration> getUserConfiguration() async {
    if (configUnavailable) throw StateError('Server unreachable');
    return const UserConfiguration();
  }

  @override
  Future<List<AggregatedLibrary>> getAllViewsIncludingHidden() async =>
      libraries;

  void reconnect() {
    configUnavailable = false;
    libraries = const [
      AggregatedLibrary(
        id: 'movies',
        name: 'Movies',
        collectionType: 'movies',
        serverId: 'server',
      ),
    ];
    notifyListeners();
  }
}

void main() {
  for (final offlineError in [false, true]) {
    final initialState = offlineError ? 'a load error' : 'an empty list';
    testWidgets('Library Visibility recovers from $initialState while open', (
      tester,
    ) async {
      final repo = _LibraryViews(configUnavailable: offlineError);
      GetIt.instance.registerSingleton<UserViewsRepository>(repo);
      addTearDown(() => GetIt.instance.reset());
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const LibraryVisibilityScreen(),
        ),
      );
      await tester.pumpAndSettle();
      final strings = AppLocalizations.of(
        tester.element(find.byType(LibraryVisibilityScreen)),
      );
      expect(
        find.text(
          offlineError
              ? strings.failedToLoadLibraries
              : strings.noLibrariesFound,
        ),
        findsOneWidget,
      );

      repo.reconnect();
      await tester.pumpAndSettle();

      expect(find.text('Movies'), findsOneWidget);
    });
  }
}
