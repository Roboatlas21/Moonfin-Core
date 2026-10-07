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

class _QuotaExhaustedRepo extends CinemaTvRepository {
  @override
  Future<SeerrQuota> getUserQuota(int userId) async =>
      const SeerrQuota(tv: SeerrQuotaDetail(limit: 1, remaining: 0));
}

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
    bool cinema = true,
    FocusNode? launchFocus,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              focusNode: launchFocus,
              onPressed: () async {
                await showSeerrRequestDialog(
                  context: context,
                  vm: vm,
                  is4k: false,
                  season: season,
                  selectAllSeasons: !cinema,
                  showAdvancedOptions: !cinema,
                  waitForSubmission: cinema,
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
    if (launchFocus != null) {
      launchFocus.requestFocus();
      await tester.pump();
    }
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
      expect(
        tester.widget<SeerrDialogButton>(
          find.widgetWithText(SeerrDialogButton, 'Submit Request'),
        ).onPressed,
        isNull,
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

  testWidgets('ordinary Seerr still submits All Seasons without metadata', (
    tester,
  ) async {
    vm.dispose();
    vm = SeerrMediaDetailViewModel.forCinema(
      repo,
      CinemaTvPreferences(),
      details: const SeerrTvDetails(id: 42),
      user: const SeerrUser(id: 5, permissions: SeerrPermission.requestTv),
      requestAllowed: () => current,
    );
    await open(tester, cinema: false);
    expect(
      tester.widget<SeerrToggleRow>(find.byType(SeerrToggleRow)).value,
      isTrue,
    );
    expect(
      tester.widget<SeerrDialogButton>(
        find.widgetWithText(SeerrDialogButton, 'Submit Request'),
      ).onPressed,
      isNotNull,
    );
    await tester.tap(find.text('Submit Request'));
    await tester.pumpAndSettle();
    expect(repo.submissions.single.all, isTrue);
    expect(repo.submissions.single.seasons, isNull);
  });

  testWidgets('ordinary All Seasons retains its minimum quota for known seasons', (
    tester,
  ) async {
    vm.dispose();
    repo = _QuotaExhaustedRepo();
    vm = SeerrMediaDetailViewModel.forCinema(
      repo,
      CinemaTvPreferences(),
      details: const SeerrTvDetails(
        id: 42,
        numberOfSeasons: 2,
        mediaInfo: SeerrMediaInfo(
          seasons: [
            SeerrSeasonAvailability(
              seasonNumber: 1,
              status: SeerrMediaStatus.available,
            ),
            SeerrSeasonAvailability(
              seasonNumber: 2,
              status: SeerrMediaStatus.available,
            ),
          ],
        ),
      ),
      user: const SeerrUser(id: 5, permissions: SeerrPermission.requestTv),
      requestAllowed: () => current,
    );
    await open(tester, cinema: false);
    expect(
      tester.widget<SeerrDialogButton>(
        find.widgetWithText(SeerrDialogButton, 'Submit Request'),
      ).onPressed,
      isNull,
    );
    expect(repo.submissions, isEmpty);
  });

  testWidgets('Cinema still blocks missing season metadata', (tester) async {
    vm.dispose();
    vm = SeerrMediaDetailViewModel.forCinema(
      repo,
      CinemaTvPreferences(),
      details: const SeerrTvDetails(id: 42),
      user: const SeerrUser(id: 5, permissions: SeerrPermission.requestTv),
      requestAllowed: () => current,
    );
    await open(tester);
    expect(
      tester.widget<SeerrDialogButton>(
        find.widgetWithText(SeerrDialogButton, 'Submit Request'),
      ).onPressed,
      isNull,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(repo.submissions, isEmpty);
  });

  testWidgets(
    'validated season is preselected and dialog awaits its TV submission',
    (tester) async {
      await open(tester, season: 5);
      final selected = tester
          .widgetList<SeerrChoiceChip>(find.byType(SeerrChoiceChip))
          .where((c) => c.selected);
      expect(selected.length, 1);
      expect(
        tester.widget<SeerrDialogButton>(
          find.widgetWithText(SeerrDialogButton, 'Submit Request'),
        ).onPressed,
        isNotNull,
      );
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

  testWidgets('expiry dismisses the Cinema season picker safely', (
    tester,
  ) async {
    await open(tester, season: 5);
    current = false;
    dismissDialog();
    await tester.pumpAndSettle();

    expect(find.byType(SeerrRequestDialog), findsNothing);
    expect(find.text('Open'), findsOneWidget);
    expect(closed, true);
    expect(repo.submissions, isEmpty);
    expect(tester.takeException(), isNull);
  });

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

  testWidgets('an older Cinema submission cannot pop or refocus a newer picker', (
    tester,
  ) async {
    final launchFocus = FocusNode(debugLabel: 'original Cinema action');
    final nextFocus = FocusNode(debugLabel: 'next Cinema picker');
    addTearDown(launchFocus.dispose);
    addTearDown(nextFocus.dispose);
    repo.submission = Completer<SeerrRequest>();
    await open(tester, season: 5, launchFocus: launchFocus);
    await tester.tap(find.text('Submit Request'));
    await tester.pump();
    expect(vm.state.isRequesting, true);

    final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
    unawaited(
      showDialog<void>(
        context: navigator.context,
        builder: (_) => AlertDialog(
          content: Focus(
            focusNode: nextFocus,
            autofocus: true,
            child: const Text('New picker'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    nextFocus.requestFocus();
    await tester.pump();
    expect(nextFocus.hasPrimaryFocus, isTrue);

    repo.submission!.complete(const SeerrRequest(id: 1, status: 2, type: 'tv'));
    await tester.pumpAndSettle();

    expect(find.text('New picker'), findsOneWidget);
    expect(nextFocus.hasPrimaryFocus, isTrue);
    expect(closed, isTrue);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(find.byType(SeerrRequestDialog), findsNothing);
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
    // PopScope rejected this Back: don't suppress a follow-up system Back.
    expect(DialogBackSuppressor.consume(), isFalse);

    repo.submission!.complete(const SeerrRequest(id: 1, status: 2, type: 'tv'));
    await tester.pumpAndSettle();
    expect(find.byType(SeerrRequestDialog), findsNothing);
    expect(closed, true);
    expect(repo.submissions, hasLength(1));
    expect(vm.state.requestError, isNull);
    expect(tester.takeException(), isNull);

    // A later, ordinary Back still dismisses exactly one dialog.
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(
      LogicalKeyboardKey.goBack,
      physicalKey: PhysicalKeyboardKey.escape,
    );
    await tester.pumpAndSettle();
    expect(find.byType(SeerrRequestDialog), findsNothing);
    expect(DialogBackSuppressor.consume(), isTrue);
    expect(DialogBackSuppressor.consume(), isFalse);
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
    expect(DialogBackSuppressor.consume(), isTrue);
    expect(DialogBackSuppressor.consume(), isFalse);
  });
}
