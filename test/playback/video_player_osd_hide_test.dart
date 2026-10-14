import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:playback_core/playback_core.dart';
import 'package:server_core/server_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
import 'package:moonfin/ui/widgets/playback/skip_segment_overlay.dart';
import 'package:moonfin/util/platform_detection.dart';

class _Client extends Fake implements MediaServerClient {
  @override
  ServerType get serverType => ServerType.jellyfin;
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

class _PlaybackManager extends PlaybackManager {
  int nextCalls = 0;
  int nextInQueueCalls = 0;

  @override
  Future<void> next() async {
    nextCalls++;
  }

  @override
  Future<void> nextInQueue() async {
    nextInQueueCalls++;
    queueService.next();
  }
}

void main() {
  late _PlaybackManager manager;
  late PipService pip;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final store = PreferenceStore();
    await store.init();
    manager = _PlaybackManager();
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

  for (final enabled in [false, true]) {
    testWidgets('pre-roll Fast Forward with Cinema Skip enabled=$enabled', (
      tester,
    ) async {
      await GetIt.instance<UserPreferences>().set(
        UserPreferences.cinemaModeSkipEnabled, enabled,
      );
      // Below the minimum length, so no visible button can handle the key.
      manager.queueService.setQueue([
        {'Id': 'intro', '__moonfinIsPreroll': true, 'RunTimeTicks': 50000000},
      ]);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: const [Locale('en')],
          home: const VideoPlayerScreen(),
        ),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.mediaFastForward);
      await tester.pump();

      expect(manager.nextInQueueCalls, enabled ? 1 : 0);
      expect(manager.nextCalls, enabled ? 0 : 1);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('Cinema Skip handles Back, Right, Select and the next clip', (
    tester,
  ) async {
    PlatformDetection.setTvMode(true);
    addTearDown(() => PlatformDetection.setTvMode(false));
    await GetIt.instance<UserPreferences>().set(
      UserPreferences.cinemaModeSkipEnabled, true,
    );
    manager.queueService.setQueue([
      {'Id': 'first-intro', '__moonfinIsPreroll': true, 'RunTimeTicks': 900000000},
      {'Id': 'second-intro', '__moonfinIsPreroll': true, 'RunTimeTicks': 450000000},
    ]);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: const [Locale('en')],
        home: const VideoPlayerScreen(),
      ),
    );
    await tester.pumpAndSettle();

    final skip = find.byType(SkipSegmentOverlay);
    expect(skip, findsOneWidget);
    final first = tester.widget<SkipSegmentOverlay>(skip);
    expect(first.segment.itemId, 'first-intro');
    expect(first.segment.end, const Duration(seconds: 90));
    expect(first.focusNode!.hasPrimaryFocus, isTrue);
    expect(find.byType(Slider), findsNothing);

    // Use actual key events: dismissing the focused button must leave the
    // player listening for the next remote press without popping the route.
    await tester.sendKeyEvent(LogicalKeyboardKey.goBack);
    await tester.pumpAndSettle();
    expect(skip, findsNothing);
    expect(find.byType(VideoPlayerScreen), findsOneWidget);
    expect(manager.queueService.currentIndex, 0);
    expect(manager.nextInQueueCalls, 0);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(skip, findsOneWidget);
    expect(
      tester.widget<SkipSegmentOverlay>(skip).focusNode!.hasPrimaryFocus,
      isTrue,
    );
    expect(manager.nextInQueueCalls, 0);
    expect(find.byType(Slider), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(manager.nextInQueueCalls, 1);
    expect(manager.nextCalls, 0);
    expect(manager.queueService.currentIndex, 1);
    expect(skip, findsOneWidget);
    final second = tester.widget<SkipSegmentOverlay>(skip);
    expect(second.segment.itemId, 'second-intro');
    expect(second.segment.end, const Duration(seconds: 45));
    expect(second.focusNode!.hasPrimaryFocus, isTrue);
    expect(find.byType(Slider), findsNothing);

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
