import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moonfin/l10n/app_localizations.dart';
import 'package:moonfin/playback/appletv_backend.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:moonfin/ui/screens/playback/appletv_player_host_screen.dart';
import 'package:moonfin/ui/widgets/playback/player_loading_overlay.dart';
import 'package:playback_core/playback_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockPlaybackManager extends Mock implements PlaybackManager {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => registerFallbackValue(Duration.zero));

  late _MockPlaybackManager manager;
  late QueueService queue;
  late PlayerState playerState;
  late StreamController<PlaybackBringupState> bringupController;

  setUp(() {
    manager = _MockPlaybackManager();
    queue = QueueService();
    playerState = PlayerState();
    bringupController = StreamController<PlaybackBringupState>.broadcast();

    when(() => manager.bringupState).thenReturn(
      const PlaybackBringupState(phase: PlaybackBringupPhase.preparing),
    );
    when(
      () => manager.bringupStateStream,
    ).thenAnswer((_) => bringupController.stream);
    when(() => manager.queueService).thenReturn(queue);
    when(
      () => manager.sessionEndedStream,
    ).thenAnswer((_) => const Stream<void>.empty());
    when(() => manager.state).thenReturn(playerState);
    when(
      () => manager.stop(userInitiated: any(named: 'userInitiated')),
    ).thenAnswer((_) async {});

    GetIt.instance.registerSingleton<PlaybackManager>(manager);
  });

  tearDown(() async {
    await GetIt.instance.reset();
    await bringupController.close();
    queue.dispose();
    playerState.dispose();
  });

  testWidgets('native Select pauses short pre-rolls without skipping', (
    tester,
  ) async {
    const control = MethodChannel('moonfin/appletv_video_control');
    const events = MethodChannel('moonfin/appletv_video_events');
    final messenger = tester.binding.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(control, (call) async {
      calls.add(call);
      return null;
    });
    messenger.setMockMethodCallHandler(events, (_) async => null);
    SharedPreferences.setMockInitialValues({});
    final store = PreferenceStore();
    await store.init();
    final prefs = UserPreferences(store);
    await prefs.set(UserPreferences.cinemaModeSkipEnabled, true);
    final backend = AppleTvBackend(prefs);
    addTearDown(backend.dispose);
    GetIt.instance.registerSingleton<UserPreferences>(prefs);
    GetIt.instance.registerSingleton<AppleTvBackend>(backend);
    when(() => manager.isOfflinePlayback).thenReturn(false);
    when(() => manager.playbackDeferredToExternalPlayer).thenReturn(false);
    when(() => manager.pause()).thenAnswer(
      (_) async => playerState.setPlaying(false),
    );
    when(() => manager.resume()).thenAnswer(
      (_) async => playerState.setPlaying(true),
    );
    queue.setQueue([
      {'Id': 'short-intro', '__moonfinIsPreroll': true, 'RunTimeTicks': 50000000},
    ]);
    playerState.setPlaying(true);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: const [Locale('en')],
        home: const AppleTvPlayerHostScreen(),
      ),
    );
    await tester.pump();
    final cinema = calls
        .lastWhere((c) => c.method == 'setCinemaSkipState')
        .arguments as Map;
    expect(cinema['active'], isTrue);
    expect(cinema['visible'], isFalse);
    final generation = cinema['generation'] as int;

    Future<void> select(int token) async {
      await messenger.handlePlatformMessage(
        events.name,
        const StandardMethodCodec().encodeSuccessEnvelope({
          'event': 'cinemaSkipAction',
          'action': 'activate',
          'generation': token,
        }),
        (_) {},
      );
      await tester.pump();
    }

    await select(generation - 1);
    verifyNever(() => manager.pause());
    await select(generation);
    verify(() => manager.pause()).called(1);
    await select(generation);
    verify(() => manager.resume()).called(1);
    verifyNever(() => manager.nextInQueue());

    await prefs.set(UserPreferences.cinemaModeSkipEnabled, false);
    await select(generation);
    verifyNever(() => manager.pause());
    await tester.pumpWidget(const SizedBox());
  });


  testWidgets('system Forward Skip is distinct from seeking on Apple TV', (
    tester,
  ) async {
    const control = MethodChannel('moonfin/appletv_video_control');
    const events = MethodChannel('moonfin/appletv_video_events');
    final messenger = tester.binding.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(control, (call) async {
      calls.add(call);
      return null;
    });
    messenger.setMockMethodCallHandler(events, (_) async => null);
    addTearDown(() {
      messenger.setMockMethodCallHandler(control, null);
      messenger.setMockMethodCallHandler(events, null);
    });

    SharedPreferences.setMockInitialValues({});
    final store = PreferenceStore();
    await store.init();
    final prefs = UserPreferences(store);
    await prefs.set(UserPreferences.cinemaModeSkipEnabled, true);
    final backend = AppleTvBackend(prefs);
    addTearDown(backend.dispose);
    GetIt.instance.registerSingleton<UserPreferences>(prefs);
    GetIt.instance.registerSingleton<AppleTvBackend>(backend);
    when(() => manager.isOfflinePlayback).thenReturn(false);
    when(() => manager.playbackDeferredToExternalPlayer).thenReturn(false);
    when(() => manager.seekTo(any())).thenAnswer((_) async {});
    when(() => manager.nextInQueue()).thenAnswer((_) async => queue.next());
    queue.setQueue([
      {'Id': 'short', '__moonfinIsPreroll': true, 'RunTimeTicks': 50000000},
      {'Id': 'long', '__moonfinIsPreroll': true, 'RunTimeTicks': 900000000},
      {'Id': 'movie', 'RunTimeTicks': 900000000},
    ]);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: const [Locale('en')],
        home: const AppleTvPlayerHostScreen(),
      ),
    );
    await tester.pump();

    Future<void> send(Map<String, Object> action) async {
      await messenger.handlePlatformMessage(
        events.name,
        const StandardMethodCodec().encodeSuccessEnvelope(action),
        (_) {},
      );
      await tester.pump();
    }

    // An ordinary position seek remains a seek during Cinema Mode.
    await send({'event': 'seek', 'positionMs': 8000});
    verify(() => manager.seekTo(const Duration(seconds: 8))).called(1);
    verifyNever(() => manager.nextInQueue());

    // A system Forward Skip advances even when the clip is below the minimum.
    await send({
      'event': 'seek',
      'positionMs': 30000,
      'isForwardSkip': true,
    });
    verify(() => manager.nextInQueue()).called(1);
    expect(queue.currentIndex, 1);
    verifyNever(() => manager.seekTo(const Duration(seconds: 30)));

    // Back-hidden controls must not stop system Fast Forward from skipping.
    final cinema = calls.lastWhere((call) => call.method == 'setCinemaSkipState')
        .arguments as Map;
    await send({
      'event': 'cinemaSkipAction',
      'action': 'hide',
      'generation': cinema['generation'] as int,
    });
    await tester.pump(const Duration(milliseconds: 400));
    await send({
      'event': 'seek',
      'positionMs': 35000,
      'isForwardSkip': true,
    });
    verify(() => manager.nextInQueue()).called(1);
    expect(queue.currentIndex, 2);
    verifyNever(() => manager.seekTo(const Duration(seconds: 35)));

    // Without a Cinema pre-roll, Fast Forward keeps seeking as before.
    await send({
      'event': 'seek',
      'positionMs': 13000,
      'isForwardSkip': true,
    });
    verify(() => manager.seekTo(const Duration(seconds: 13))).called(1);

    // Opting out also restores the original interval-seek behavior.
    queue.setQueue([
      {'Id': 'disabled', '__moonfinIsPreroll': true, 'RunTimeTicks': 900000000},
    ]);
    await prefs.set(UserPreferences.cinemaModeSkipEnabled, false);
    await tester.pump();
    await send({
      'event': 'seek',
      'positionMs': 14000,
      'isForwardSkip': true,
    });
    verify(() => manager.seekTo(const Duration(seconds: 14))).called(1);
    // The host schedules one metadata refresh 300 ms after normal seek events.
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('uses a white native spinner throughout tvOS bring-up', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: AppleTvPlayerHostScreen()));

    expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
    expect(find.byType(PlayerLoadingOverlay), findsNothing);
    final spinner = tester.widget<CupertinoActivityIndicator>(
      find.byType(CupertinoActivityIndicator),
    );
    expect(spinner.radius, 20);
    expect(spinner.color, Colors.white);

    bringupController.add(
      const PlaybackBringupState(phase: PlaybackBringupPhase.resolving),
    );
    await tester.pump();
    expect(find.byType(CupertinoActivityIndicator), findsOneWidget);

    bringupController.add(
      const PlaybackBringupState(phase: PlaybackBringupPhase.ready),
    );
    await tester.pump();
    expect(find.byType(CupertinoActivityIndicator), findsNothing);
  });

  testWidgets('removes tvOS launch feedback after startup failure', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: AppleTvPlayerHostScreen()));

    bringupController.add(
      const PlaybackBringupState(phase: PlaybackBringupPhase.failed),
    );
    await tester.pump();

    expect(find.byType(CupertinoActivityIndicator), findsNothing);
  });
}
