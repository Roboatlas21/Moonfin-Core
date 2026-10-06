import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:moonfin/data/services/seerr/seerr_api_models.dart';
import 'package:moonfin/data/viewmodels/seerr_media_detail_view_model.dart';
import 'package:moonfin/l10n/app_localizations.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:moonfin/ui/widgets/seerr/seerr_request_dialog.dart';
import 'package:moonfin/ui/widgets/seerr/seerr_tv_controls.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../playback/cinema_series_request_test.dart'
    show CinemaTvRepository, CinemaTvPreferences;

void main() {
  late CinemaTvRepository repo;
  late SeerrMediaDetailViewModel vm;
  var current = true;
  var closed = false;
  setUp(() async {
    await GetIt.instance.reset();
    SharedPreferences.setMockInitialValues({});
    final store = PreferenceStore();
    await store.init();
    GetIt.instance.registerSingleton<UserPreferences>(UserPreferences(store));
    repo = CinemaTvRepository();
    current = true;
    closed = false;
    vm = SeerrMediaDetailViewModel.forCinema(
      repo,
      CinemaTvPreferences(),
      details: repo.details,
      user: const SeerrUser(id: 5, permissions: SeerrPermission.requestTv),
      requestAllowed: () => current,
    );
  });
  tearDown(() async {
    vm.dispose();
    await GetIt.instance.reset();
  });

  Future<void> open(WidgetTester tester, {int? season}) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                await showSeerrRequestDialog(
                  context: context,
                  vm: vm,
                  is4k: false,
                  season: season,
                  selectAllSeasons: false,
                  waitForSubmission: true,
                );
                closed = true;
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'unidentified season starts empty and cannot submit the whole series',
    (tester) async {
      await open(tester);
      expect(find.text('Request Series'), findsOneWidget);
      expect(
        tester.widget<SeerrToggleRow>(find.byType(SeerrToggleRow)).value,
        false,
      );
      expect(
        tester
            .widgetList<SeerrChoiceChip>(find.byType(SeerrChoiceChip))
            .where((c) => c.selected),
        isEmpty,
      );
      await tester.tap(find.text('Submit Request'));
      await tester.pumpAndSettle();
      expect(repo.submissions, isEmpty);
      expect(closed, false);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(closed, true);
    },
  );

  testWidgets(
    'validated season is preselected and dialog awaits its TV submission',
    (tester) async {
      await open(tester, season: 5);
      final selected = tester
          .widgetList<SeerrChoiceChip>(find.byType(SeerrChoiceChip))
          .where((c) => c.selected);
      expect(selected.length, 1);
      await tester.tap(find.text('Submit Request'));
      await tester.pumpAndSettle();
      expect(repo.submissions.single.id, 42);
      expect(repo.submissions.single.type, 'tv');
      expect(repo.submissions.single.seasons, [5]);
      expect(repo.submissions.single.all, false);
      expect(closed, true);
      expect(find.byType(SeerrRequestDialog), findsNothing);
    },
  );

  testWidgets('stale dialog cannot submit to a newly active account', (
    tester,
  ) async {
    await open(tester, season: 5);
    current = false;
    await tester.tap(find.text('Submit Request'));
    await tester.pumpAndSettle();
    expect(repo.submissions, isEmpty);
    expect(closed, true);
  });
}
