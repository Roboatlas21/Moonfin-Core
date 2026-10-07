import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:playback_core/playback_core.dart';
import 'package:server_core/server_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:moonfin/auth/repositories/session_repository.dart';
import 'package:moonfin/ui/widgets/playback/cinema_mode_actions_overlay.dart';
import 'package:moonfin/util/platform_detection.dart';
import 'package:moonfin/data/services/cast/cast_service.dart';
import 'package:moonfin/data/services/cast/cast_target.dart';
import 'package:moonfin/data/services/cast/native_airplay_channel.dart';
import 'package:moonfin/data/services/cast/native_cast_channel.dart';
import 'package:moonfin/data/services/cast/native_dlna_channel.dart';
import 'package:moonfin/data/services/media_server_client_factory.dart';
import 'package:moonfin/data/services/theme_music_service.dart';
import 'package:moonfin/l10n/app_localizations.dart';
import 'package:moonfin/platform/pip_service.dart';
import 'package:moonfin/playback/playback_lifecycle_handler.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:moonfin/ui/screens/playback/video_player_screen.dart';
import 'package:moonfin/ui/screensaver/screensaver_controller.dart';

class _Client extends Fake implements MediaServerClient {
  @override
  String get baseUrl => 'https://server';
  @override
  String? get userId => 'user';
  @override
  String? get accessToken => 'token';
  @override
  Future<CinemaMedia?> resolveCinemaMedia(
    String id, {
    CinemaMediaType? expectedMediaType,
  }) async => null;
  @override
  ServerType get serverType => ServerType.jellyfin;
}

class _CinemaAccount extends Fake implements SessionRepository {
  @override
  String? get activeServerId => 'server';
  @override
  String? get activeUserId => 'user';
}

class _Manager extends PlaybackManager {
  int advances = 0;
  @override
  PlaybackBringupState get bringupState {
    final item = queueService.currentItem;
    return item is Map
        ? PlaybackBringupState(
            phase: PlaybackBringupPhase.ready,
            sessionToken: queueService.currentIndex + 1,
            itemId: item['Id'] as String,
          )
        : super.bringupState;
  }

  @override
  Future<void> nextInQueue() async {
    advances++;
    queueService.next();
  }
}

class _Factory extends Fake implements MediaServerClientFactory {
  @override
  MediaServerClient? getClientIfExists(String id) => null;
}

class _Cast extends Fake implements CastService {
  @override
  final activeKindNotifier = ValueNotifier<CastTargetKind?>(null);
  @override
  CastTargetKind? get activeKind => null;
}

class _ThemeMusic extends Fake implements ThemeMusicService {
  @override
  void setExternalAudioActive(bool active) {}
}

class _Screensaver extends Fake implements ScreensaverController {
  @override
  void setPlaybackActive(bool active) {}
}

class _Lifecycle extends Fake implements PlaybackLifecycleHandler {}

void main() {
  late _Manager manager;
  late PipService pip;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final store = PreferenceStore();
    await store.init();
    manager = _Manager();
    GetIt.instance.registerSingleton<PlaybackManager>(manager);
    GetIt.instance.registerSingleton<UserPreferences>(UserPreferences(store));
    GetIt.instance.registerSingleton<MediaServerClient>(_Client());
    GetIt.instance.registerSingleton<MediaServerClientFactory>(_Factory());
    GetIt.instance.registerSingleton<CastService>(_Cast());
    GetIt.instance.registerSingleton<NativeCastChannel>(NativeCastChannel());
    GetIt.instance.registerSingleton<NativeDlnaChannel>(NativeDlnaChannel());
    GetIt.instance.registerSingleton<NativeAirPlayChannel>(
      NativeAirPlayChannel(),
    );
    pip = PipService();
    GetIt.instance.registerSingleton<PipService>(pip);
    GetIt.instance.registerSingleton<PlaybackLifecycleHandler>(_Lifecycle());
    GetIt.instance.registerSingleton<ThemeMusicService>(_ThemeMusic());
    GetIt.instance.registerSingleton<ScreensaverController>(_Screensaver());
  });

  tearDown(() async {
    manager.dispose();
    pip.dispose();
    await GetIt.instance.reset();
  });

  Future<void> openCinema(WidgetTester tester) async {
    GetIt.instance.registerSingleton<SessionRepository>(_CinemaAccount());
    manager.queueService.setQueue([
      for (var i = 0; i < 2; i++)
        {
          'Id': 'intro-$i',
          'Type': 'Video',
          '__moonfinIsPreroll': true,
          'RunTimeTicks': 900000000,
        },
      {'Id': 'movie', 'Type': 'Movie'},
    ]);
    manager.state.setPlaying(true);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: const [Locale('en')],
        home: const VideoPlayerScreen(),
      ),
    );
    await tester.pump();
  }

  testWidgets('desktop hover restores cinema actions after auto hide', (
    tester,
  ) async {
    await openCinema(tester);
    expect(find.byType(CinemaModeActionsOverlay), findsOneWidget);
    await tester.pump(const Duration(seconds: 11));
    expect(find.byType(CinemaModeActionsOverlay), findsNothing);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(20, 20));
    await mouse.moveTo(const Offset(80, 80));
    await tester.pump();
    expect(find.byType(CinemaModeActionsOverlay), findsOneWidget);
    expect(manager.advances, 0);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('a held Select skips one trailer across the queue transition', (
    tester,
  ) async {
    PlatformDetection.setTvMode(true);
    addTearDown(() => PlatformDetection.setTvMode(false));
    await openCinema(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(manager.advances, 1);
    expect(manager.queueService.currentIndex, 1);
    expect(find.byType(CinemaModeActionsOverlay), findsOneWidget);
    await tester.pump(const Duration(seconds: 11));
    expect(
      find.byType(CinemaModeActionsOverlay),
      findsNothing,
      reason: 'a source already ready at queue notification still arms auto hide',
    );
    await tester.pumpWidget(const SizedBox());
  });

  // Issue #1688: a resume that takes longer than the hide delay to start
  // playing left the controls up until a key was pressed.
  testWidgets('controls hide after a start slower than the hide delay', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: const [Locale('en')],
        home: const VideoPlayerScreen(),
      ),
    );
    await tester.pump();
    expect(find.byType(Slider), findsOneWidget);

    await tester.pump(const Duration(seconds: 10));
    expect(
      find.byType(Slider),
      findsOneWidget,
      reason: 'nothing is playing yet, so the controls stay',
    );

    manager.state.setPlaying(true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(find.byType(Slider), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  // Issue #985: a double-click toggles fullscreen without delaying a single
  // click, which still hides the controls at once.
  testWidgets('desktop double-click toggles fullscreen', (tester) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async {
        calls.add(call);
        if (call.method == 'isVisible') return true;
        return call.method.startsWith('is') ? false : null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        null,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: const [Locale('en')],
        home: const VideoPlayerScreen(),
      ),
    );
    await tester.pump();
    expect(find.byType(Slider), findsOneWidget);

    await tester.tapAt(const Offset(100, 300));
    await tester.pump();
    expect(find.byType(Slider), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    expect(calls.where((c) => c.method == 'setFullScreen'), isEmpty);

    await tester.tapAt(const Offset(100, 300));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(const Offset(100, 300));
    await tester.pumpAndSettle();
    expect(
      calls.where((c) => c.method == 'setFullScreen').map((c) => c.arguments),
      [
        {'isFullScreen': true},
      ],
    );

    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
