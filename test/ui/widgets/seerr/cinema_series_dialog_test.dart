import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:moonfin/data/services/seerr/seerr_api_models.dart';
import 'package:moonfin/data/viewmodels/seerr_media_detail_view_model.dart';
import 'package:moonfin/l10n/app_localizations.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:moonfin/ui/widgets/overlay_sheet.dart';
import 'package:moonfin/ui/widgets/seerr/seerr_request_dialog.dart';
import 'package:moonfin/ui/widgets/seerr/seerr_tv_controls.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../playback/cinema_series_request_test.dart'
    show CinemaTvRepository, CinemaTvPreferences;

void main() {
  late CinemaTvRepository repo;
  late SeerrMediaDetailViewModel vm;
  late VoidCallback dismissDialog;
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
    DialogBackSuppressor.newBackPress();
    vm.dispose();
    await GetIt.instance.reset();
  });

  Future<void> open(
    WidgetTester tester, {
    int? season,
    bool showAdvancedOptions = false,
  }) async {
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
                  showAdvancedOptions: showAdvancedOptions,
                  waitForSubmission: true,
                  onDismissReady: (dismiss) => dismissDialog = dismiss,
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
    'Cinema hides advanced options even for users with advanced permission',
    (tester) async {
      vm.dispose();
      vm = SeerrMediaDetailViewModel.forCinema(
        repo,
        CinemaTvPreferences(),
        details: repo.details,
        user: const SeerrUser(
          id: 5,
          permissions:
              SeerrPermission.requestTv | SeerrPermission.requestAdvanced,
        ),
        requestAllowed: () => current,
      );
      expect(vm.canRequestAdvanced, true);
      await open(tester, season: 5);
      expect(find.text('Advanced Options'), findsNothing);
      await tester.tap(find.text('Submit Request'));
      await tester.pumpAndSettle();
      expect(repo.submissions.single.seasons, [5]);
      expect(repo.submissions.single.all, false);
      expect(closed, true);
    },
  );

  testWidgets('normal Seerr dialog still offers advanced options', (
    tester,
  ) async {
    vm.dispose();
    vm = SeerrMediaDetailViewModel.forCinema(
      repo,
      CinemaTvPreferences(),
      details: repo.details,
      user: const SeerrUser(
        id: 5,
        permissions: SeerrPermission.requestTv | SeerrPermission.requestAdvanced,
      ),
      requestAllowed: () => current,
    );
    await open(tester, season: 5, showAdvancedOptions: true);
    expect(find.text('Advanced Options'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(repo.submissions, isEmpty);
  });

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

  testWidgets(
    'successful submission closes without waiting for another details read',
    (tester) async {
      repo.detailsResponse = Completer<SeerrTvDetails>();
      await open(tester, season: 5);
      await tester.tap(find.text('Submit Request'));
      await tester.pumpAndSettle();
      expect(repo.submissions, hasLength(1));
      expect(repo.lookups, 0);
      expect(closed, isTrue);
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

  testWidgets(
    'expiry closes the season dialog and its advanced-options picker',
    (tester) async {
      await open(tester, season: 5);
      final childClosed = showSeerrOptionPicker(
        tester.element(find.byType(SeerrRequestDialog)),
        title: 'Quality profile',
        labels: ['Default profile'],
        selectedIndex: 0,
      );
      await tester.pumpAndSettle();
      expect(find.text('Quality profile'), findsOneWidget);

      current = false;
      dismissDialog();
      await tester.pumpAndSettle();

      expect(await childClosed, isNull);
      expect(find.text('Quality profile'), findsNothing);
      expect(find.byType(SeerrRequestDialog), findsNothing);
      expect(find.text('Open'), findsOneWidget);
      expect(closed, true);
      expect(repo.submissions, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('an old dismissal handle cannot close a newer dialog', (
    tester,
  ) async {
    await open(tester, season: 5);
    final oldDismiss = dismissDialog;
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    closed = false;
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    oldDismiss();
    await tester.pumpAndSettle();
    expect(find.byType(SeerrRequestDialog), findsOneWidget);
    expect(closed, false);
    dismissDialog();
    await tester.pumpAndSettle();
    expect(find.byType(SeerrRequestDialog), findsNothing);
    expect(closed, true);
    expect(tester.takeException(), isNull);
  });

  testWidgets('remote Back waits for a pending submission to finish', (
    tester,
  ) async {
    repo.submission = Completer<SeerrRequest>();
    await open(tester, season: 5);
    await tester.tap(find.text('Submit Request'));
    await tester.pump();
    expect(repo.submissions, hasLength(1));
    expect(vm.state.isRequesting, true);

    await tester.sendKeyEvent(
      LogicalKeyboardKey.goBack,
      physicalKey: PhysicalKeyboardKey.escape,
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(SeerrRequestDialog), findsOneWidget);
    expect(closed, false);

    repo.submission!.complete(const SeerrRequest(id: 1, status: 2, type: 'tv'));
    await tester.pumpAndSettle();
    expect(find.byType(SeerrRequestDialog), findsNothing);
    expect(closed, true);
    expect(repo.submissions, hasLength(1));
    expect(vm.state.requestError, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('remote Back still cancels before submission', (tester) async {
    await open(tester, season: 5);
    await tester.sendKeyEvent(
      LogicalKeyboardKey.goBack,
      physicalKey: PhysicalKeyboardKey.escape,
    );
    await tester.pumpAndSettle();
    expect(find.byType(SeerrRequestDialog), findsNothing);
    expect(closed, true);
    expect(repo.submissions, isEmpty);
  });
}
