import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:moonfin/data/services/seerr/seerr_api_models.dart';
import 'package:moonfin/l10n/app_localizations.dart';
import 'package:moonfin/playback/cinema_mode_controller.dart';
import 'package:moonfin/preference/preference_constants.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:moonfin/ui/widgets/playback/cinema_mode_actions_overlay.dart';
import 'package:moonfin/util/platform_detection.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cinema_mode_controller_test.dart' show FakeCinemaSeerr, cinemaItem;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CinemaModeController controller;
  late FakeCinemaSeerr seerr;
  late FocusNode skipFocus;
  late FocusNode requestFocus;
  late StreamController<Duration> positions;
  var skipped = 0;
  setUp(() async {
    await GetIt.instance.reset();
    SharedPreferences.setMockInitialValues({});
    final store = PreferenceStore();
    await store.init();
    GetIt.instance.registerSingleton<UserPreferences>(UserPreferences(store));
    seerr = FakeCinemaSeerr();
    skipped = 0;
    controller = CinemaModeController(
      seerr: () async => seerr,
      accountKey: () => 'account',
      onSkip: () async {
        skipped++;
      },
      onError: (_) {},
    );
    skipFocus = FocusNode();
    requestFocus = FocusNode();
    positions = StreamController.broadcast();
  });
  tearDown(() async {
    controller.dispose();
    skipFocus.dispose();
    requestFocus.dispose();
    await positions.close();
    PlatformDetection.setTvMode(false);
    debugDefaultTargetPlatformOverride = null;
    await GetIt.instance.reset();
  });
  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(800, 450),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Stack(
            children: [
              AnimatedBuilder(
                animation: controller,
                builder: (context, _) => controller.visible
                    ? CinemaModeActionsOverlay(
                        controller: controller,
                        skipFocus: skipFocus,
                        requestFocus: requestFocus,
                        positionStream: positions.stream,
                        position: Duration.zero,
                        countdownStyle: MediaSegmentCountdown.progressBar,
                        onDismiss: controller.hide,
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
  }

  final capsule = find.byKey(const ValueKey('skip-segment-capsule'));
  final dismiss = find.byIcon(Icons.close_rounded);
  testWidgets(
    'phone anchors Skip and its single X across asynchronous labels/status',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final lookup = Completer<int?>();
      seerr.details = Completer();
      controller.enter(
        item: cinemaItem(tmdb: null),
        resolveMovie: () => lookup.future,
      );
      await pump(tester);
      final anchor = tester.getRect(capsule);
      final closeAnchor = tester.getCenter(dismiss);
      expect(anchor.bottom, 450 - 16);
      expect(anchor.right, 800 - 24);
      expect(closeAnchor.dx, anchor.center.dx);
      expect(dismiss, findsOneWidget);
      lookup.complete(42);
      await tester.pump();
      expect(tester.getRect(capsule), anchor);
      expect(tester.getCenter(dismiss), closeAnchor);
      seerr.details!.complete(
        const SeerrMovieDetails(
          id: 42,
          title: 'Movie',
          mediaInfo: SeerrMediaInfo(status: 4),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Partially Available'), findsOneWidget);
      expect(tester.getRect(capsule), anchor);
      expect(tester.getCenter(dismiss), closeAnchor);
      expect(requestFocus.canRequestFocus, false);
      await tester.tap(dismiss);
      await tester.pump();
      expect(capsule, findsNothing);
      expect(find.text('Partially Available'), findsNothing);
      expect(skipped, 0);
      debugDefaultTargetPlatformOverride = null;
    },
  );
  testWidgets(
    'tablet uses the same bottom placement and direct Request action',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      controller.enter(item: cinemaItem(), resolveMovie: () async => null);
      await pump(tester, size: const Size(1024, 768));
      expect(tester.getBottomRight(capsule), const Offset(1000, 752));
      expect(dismiss, findsOneWidget);
      await tester.tap(find.text('Request Movie'));
      await tester.pump();
      expect(seerr.submitted, [42]);
      expect(skipped, 0);
      debugDefaultTargetPlatformOverride = null;
    },
  );
  testWidgets('TV keeps placement and has no dismiss X', (tester) async {
    PlatformDetection.setTvMode(true);
    controller.enter(item: cinemaItem(), resolveMovie: () async => null);
    await pump(tester);
    expect(tester.getBottomRight(capsule), const Offset(776, 426));
    expect(dismiss, findsNothing);
    expect(controller.focusedAction, CinemaAction.skip);
  });
  testWidgets(
    'narrow viewport stays in one row without moving Skip or overflowing',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      seerr.info = const SeerrMediaInfo(status: 4);
      controller.enter(item: cinemaItem(), resolveMovie: () async => null);
      await pump(tester, size: const Size(360, 740));
      expect(tester.getBottomRight(capsule), const Offset(336, 724));
      expect(tester.takeException(), isNull);
      expect(dismiss, findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
