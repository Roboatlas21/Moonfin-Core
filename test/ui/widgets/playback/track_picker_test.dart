import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:moonfin/l10n/app_localizations.dart';
import 'package:moonfin/playback/aether_backend.dart';
import 'package:moonfin/playback/media3_player_backend.dart';
import 'package:moonfin/playback/media_kit_player_backend.dart';
import 'package:moonfin/playback/subtitle_style.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:moonfin/ui/widgets/playback/track_picker.dart';
import 'package:playback_core/playback_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Backend extends Fake implements MediaKitPlayerBackend {
  _Backend({this.secondaryStyle = false});
  final bool secondaryStyle;
  final audioDelays = <double>[];
  final fontSizes = <double?>[];
  int? textColor;

  @override
  bool get supportsSecondarySubtitleDelay => true;
  @override
  bool get supportsSecondarySubtitleStyle => secondaryStyle;
  @override
  bool get supportsSecondarySubtitlePosition => true;

  @override
  Future<void> configureSubtitleStyle({
    int? textColor,
    int? backgroundColor,
    int? strokeColor,
    double? fontSize,
    int? fontWeight,
    double? verticalOffset,
    bool? applyEmbeddedStyles,
    bool? applyEmbeddedFontSizes,
  }) async {
    fontSizes.add(fontSize);
    this.textColor = textColor;
  }

  @override
  Future<void> setAudioDelay(double seconds) async => audioDelays.add(seconds);
}

class _Manager extends PlaybackManager {
  _Manager(this._backend, {this.resolution});

  final PlayerBackend _backend;
  final StreamResolutionResult? resolution;

  @override
  StreamResolutionResult? get currentResolution => resolution;

  @override
  PlayerBackend? get backend => _backend;

  @override
  bool canUseAsSecondarySubtitle(int index) =>
      resolution?.mediaStreams.any((stream) => stream['Index'] == index) ??
      false;
}

class _AppleBackend extends _Backend implements AetherBackend {
  _AppleBackend() : super(secondaryStyle: true);
}

class _AndroidBackend extends _Backend implements Media3PlayerBackend {
  _AndroidBackend() : super(secondaryStyle: true);
}

void main() {
  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  setUp(() async {
    await GetIt.instance.reset();
    SharedPreferences.setMockInitialValues({});
    final store = PreferenceStore();
    await store.init();
    GetIt.instance.registerSingleton<UserPreferences>(UserPreferences(store));
    TrackPicker.resetDelays();
  });

  tearDown(() => GetIt.instance.reset());

  Future<void> openPicker(
    WidgetTester tester,
    PlaybackManager manager, {
    bool secondary = false,
    bool audio = true,
    ValueChanged<bool>? onDialogOpenChanged,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => TrackPicker.show(
              context,
              manager: manager,
              audio: audio && !secondary,
              secondary: secondary,
              clientFor: (_) => throw UnimplementedError(),
              onDialogOpenChanged: onDialogOpenChanged,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('reports its dialog opening and closing', (tester) async {
    final events = <bool>[];
    await openPicker(
      tester,
      PlaybackManager(),
      onDialogOpenChanged: events.add,
    );
    expect(find.byType(Dialog), findsOneWidget);
    expect(events, [true]);

    Navigator.of(tester.element(find.byType(Dialog))).pop();
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(events, [true, false]);
  });

  // Issue #1141: the delay is set from a bar that leaves the picture in view
  // rather than from under the track list.
  testWidgets(
    'the audio delay opens in a bar that leaves the picture undimmed',
    (tester) async {
      final backend = _Backend();
      final events = <bool>[];
      await openPicker(
        tester,
        _Manager(backend),
        onDialogOpenChanged: events.add,
      );
      expect(find.text(l10n.none), findsOneWidget);
      expect(find.byType(AnimatedModalBarrier), findsOneWidget);

      await tester.tap(find.text(l10n.audioDelay));
      await tester.pumpAndSettle();
      expect(find.text(l10n.audioTrack), findsNothing);
      expect(find.byType(AnimatedModalBarrier), findsNothing);

      await tester.tap(find.byTooltip(l10n.delayPlusMs(100)));
      await tester.pump();
      expect(find.text('+100 ms'), findsOneWidget);
      expect(backend.audioDelays, [0.1]);
      expect(TrackPicker.audioDelay, 0.1);

      Navigator.of(tester.element(find.byType(Dialog))).pop();
      await tester.pumpAndSettle();
      expect(events, [true, false, true, false]);
    },
  );

  testWidgets(
    'shared controls stay in the slot menu and primary opens only tracks',
    (tester) async {
      final manager = _Manager(
        _Backend(secondaryStyle: true),
        resolution: StreamResolutionResult(
          streamUrl: 'https://host/stream',
          mediaSourceId: 'source',
          playMethod: StreamPlayMethod.directPlay,
          mediaStreams: [
            {
              'Type': 'Subtitle',
              'Index': 2,
              'DisplayTitle': 'English',
              'Codec': 'srt',
            },
            {
              'Type': 'Subtitle',
              'Index': 3,
              'DisplayTitle': 'French',
              'Codec': 'srt',
            },
          ],
        ),
      );
      addTearDown(manager.dispose);
      await openPicker(tester, manager, audio: false);
      expect(find.text(l10n.primarySubtitleSlot), findsOneWidget);
      expect(find.text(l10n.secondarySubtitleSlot), findsOneWidget);
      expect(find.text(l10n.subtitleSize), findsOneWidget);
      expect(find.text(l10n.verticalOffset), findsOneWidget);
      expect(find.byIcon(Icons.av_timer), findsOneWidget);
      await tester.tap(find.text(l10n.primarySubtitleSlot));
      await tester.pumpAndSettle();
      expect(find.text(l10n.subtitleSize), findsNothing);
      expect(find.text(l10n.subtitleDelay), findsNothing);
      expect(find.textContaining('English'), findsOneWidget);
    },
  );

  testWidgets('the secondary subtitle delay opens in the same bar', (
    tester,
  ) async {
    final manager = _Manager(_Backend());
    await openPicker(tester, manager, secondary: true);

    await tester.tap(find.text(l10n.subtitleDelay));
    await tester.pumpAndSettle();
    expect(find.text(l10n.secondarySubtitleTrack), findsNothing);
    expect(find.text(l10n.secondaryDelayAdjustment), findsOneWidget);
    await tester.tap(find.byTooltip(l10n.delayPlusMs(100)));
    await tester.pump();
    expect(manager.secondarySubtitleDelaySeconds, 0.1);
  });

  testWidgets('the delay bar starts with Reset focused for a remote', (
    tester,
  ) async {
    final backend = _Backend();
    await openPicker(tester, _Manager(backend));
    await tester.tap(find.text(l10n.audioDelay));
    await tester.pumpAndSettle();
    expect(
      Focus.of(tester.element(find.text(l10n.reset))).hasPrimaryFocus,
      isTrue,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(backend.audioDelays, [0.1]);
  });

  testWidgets(
    'secondary size steps through Default and both 50 percent limits',
    (tester) async {
      final prefs = GetIt.instance<UserPreferences>();
      final manager = _Manager(_Backend(secondaryStyle: true));
      addTearDown(manager.dispose);
      await openPicker(tester, manager, secondary: true);
      expect(find.byIcon(Icons.restore), findsNothing);
      expect(find.byIcon(Icons.av_timer), findsOneWidget);
      await tester.tap(find.byTooltip(l10n.increaseValue(l10n.verticalOffset)));
      await tester.pumpAndSettle();
      expect(find.text('+2%'), findsOneWidget);
      expect(prefs.get(UserPreferences.subtitlesOffsetPosition), 0.04);
      await tester.tap(find.byTooltip(l10n.next));
      await tester.pumpAndSettle();
      for (var i = 0; i < 6; i++) {
        await tester.tap(find.byTooltip(l10n.increaseValue(l10n.subtitleSize)));
        await tester.pumpAndSettle();
      }
      expect(find.text('+50%'), findsOneWidget);
      expect(manager.secondarySubtitleFontSize, 30.0);
      await setPrimarySubtitleSize(manager, prefs, 24.0);
      expect(manager.secondarySubtitleFontSize, 36.0);
      for (var i = 0; i < 5; i++) {
        await tester.tap(find.byTooltip(l10n.decreaseValue(l10n.subtitleSize)));
        await tester.pumpAndSettle();
      }
      expect(manager.secondarySubtitleFontSize, isNull);
      expect(prefs.get(UserPreferences.secondarySubtitleSizeAdjustment), 0.0);
      expect(manager.secondarySubtitleOffset, 0.02);
      expect(manager.secondarySubtitleTextColor, 0xFFFFFFFF);
      for (var i = 0; i < 6; i++) {
        await tester.tap(find.byTooltip(l10n.decreaseValue(l10n.subtitleSize)));
        await tester.pumpAndSettle();
      }
      expect(find.text('-50%'), findsOneWidget);
      expect(manager.secondarySubtitleFontSize, 12.0);
    },
  );

  for (final (primary, saved, effective, reverse) in [
    (48.0, 50.0, 9.0, 0.0),
    (12.0, -50.0, -12.0, -10.0),
    (20.0, -50.0, -47.0, -40.0),
  ]) {
    testWidgets(
      'Apple size stops at $effective% and reverses onto the normal steps',
      (tester) async {
        final prefs = GetIt.instance<UserPreferences>();
        await prefs.set(UserPreferences.subtitlesTextSize, primary);
        await prefs.set(UserPreferences.secondarySubtitleSizeAdjustment, saved);
        final manager = _Manager(_AppleBackend());
        addTearDown(manager.dispose);
        await syncSecondarySubtitleStyle(manager, prefs);
        await openPicker(tester, manager, secondary: true);
        final label = '${effective > 0 ? '+' : ''}${effective.round()}%';
        expect(find.text(label), findsOneWidget);

        await tester.tap(
          find.byTooltip(
            effective > 0
                ? l10n.increaseValue(l10n.subtitleSize)
                : l10n.decreaseValue(l10n.subtitleSize),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(label), findsOneWidget);
        expect(
          prefs.get(UserPreferences.secondarySubtitleSizeAdjustment),
          effective,
        );

        await tester.tap(
          find.byTooltip(
            effective > 0
                ? l10n.decreaseValue(l10n.subtitleSize)
                : l10n.increaseValue(l10n.subtitleSize),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          prefs.get(UserPreferences.secondarySubtitleSizeAdjustment),
          reverse,
        );
        expect(
          manager.secondarySubtitleFontSize,
          reverse == 0
              ? isNull
              : closeTo(primary * (1 + reverse / 100), 0.0001),
        );
      },
    );
  }

  testWidgets('open Apple size control follows a changed primary size', (
    tester,
  ) async {
    final prefs = GetIt.instance<UserPreferences>();
    await prefs.set(UserPreferences.secondarySubtitleSizeAdjustment, 50.0);
    final manager = _Manager(_AppleBackend());
    addTearDown(manager.dispose);
    await openPicker(tester, manager, secondary: true);
    expect(find.text('+50%'), findsOneWidget);
    await setPrimarySubtitleSize(manager, prefs, 48.0);
    await tester.pumpAndSettle();
    expect(find.text('+9%'), findsOneWidget);
    expect(manager.secondarySubtitleFontSize, closeTo(52.32, 0.0001));
    expect(prefs.get(UserPreferences.secondarySubtitleSizeAdjustment), 50.0);
    await tester.tap(find.byTooltip(l10n.decreaseValue(l10n.subtitleSize)));
    await tester.pumpAndSettle();
    expect(prefs.get(UserPreferences.secondarySubtitleSizeAdjustment), 0.0);
    expect(manager.secondarySubtitleFontSize, isNull);
  });

  testWidgets('colour and position edits preserve capped Apple size intent', (
    tester,
  ) async {
    final prefs = GetIt.instance<UserPreferences>();
    await prefs.set(UserPreferences.subtitlesTextSize, 48.0);
    await prefs.set(UserPreferences.secondarySubtitleSizeAdjustment, 50.0);
    final manager = _Manager(_AppleBackend());
    addTearDown(manager.dispose);
    await openPicker(tester, manager, secondary: true);
    expect(find.text('+9%'), findsOneWidget);

    await tester.tap(find.byTooltip(l10n.playerTooltipPrevious));
    await tester.pumpAndSettle();
    expect(prefs.get(UserPreferences.secondarySubtitleTextColor), 0xFFFFFF00);
    expect(prefs.get(UserPreferences.secondarySubtitleSizeAdjustment), 50.0);
    await tester.tap(find.byTooltip(l10n.increaseValue(l10n.verticalOffset)));
    await tester.pumpAndSettle();
    expect(prefs.get(UserPreferences.secondarySubtitleOffsetPosition), 0.02);
    expect(prefs.get(UserPreferences.secondarySubtitleSizeAdjustment), 50.0);
    expect(manager.secondarySubtitleFontSize, closeTo(52.32, 0.0001));

    await setPrimarySubtitleSize(manager, prefs, 24.0);
    await tester.pumpAndSettle();
    expect(find.text('+50%'), findsOneWidget);
    expect(manager.secondarySubtitleFontSize, 36.0);
    expect(manager.secondarySubtitleTextColor, 0xFFFFFF00);
    expect(manager.secondarySubtitleOffset, 0.02);
  });

  testWidgets('size and colour edits preserve capped Media3 offset intent', (
    tester,
  ) async {
    final prefs = GetIt.instance<UserPreferences>();
    await prefs.set(UserPreferences.secondarySubtitleOffsetPosition, 0.4);
    final manager = _Manager(_AndroidBackend());
    addTearDown(manager.dispose);
    await openPicker(tester, manager, secondary: true);
    expect(find.text('+20%'), findsOneWidget);

    await tester.tap(find.byTooltip(l10n.playerTooltipPrevious));
    await tester.pumpAndSettle();
    expect(prefs.get(UserPreferences.secondarySubtitleOffsetPosition), 0.4);
    await tester.tap(find.byTooltip(l10n.increaseValue(l10n.subtitleSize)));
    await tester.pumpAndSettle();
    expect(prefs.get(UserPreferences.secondarySubtitleSizeAdjustment), 10.0);
    expect(prefs.get(UserPreferences.secondarySubtitleOffsetPosition), 0.4);
    expect(manager.secondarySubtitleOffset, 0.2);
  });

  testWidgets(
    'Media3 offset shows the effective legacy limit and reverses by 2%',
    (tester) async {
      final prefs = GetIt.instance<UserPreferences>();
      await prefs.set(UserPreferences.secondarySubtitleOffsetPosition, 0.4);
      final manager = _Manager(_AndroidBackend());
      addTearDown(manager.dispose);
      await syncSecondarySubtitleStyle(manager, prefs);
      await openPicker(tester, manager, secondary: true);
      expect(find.text('+20%'), findsOneWidget);
      expect(manager.secondarySubtitleOffset, 0.2);
      await tester.tap(find.byTooltip(l10n.increaseValue(l10n.verticalOffset)));
      await tester.pumpAndSettle();
      expect(find.text('+20%'), findsOneWidget);
      await tester.tap(find.byTooltip(l10n.decreaseValue(l10n.verticalOffset)));
      await tester.pumpAndSettle();
      expect(find.text('+18%'), findsOneWidget);
      expect(prefs.get(UserPreferences.secondarySubtitleOffsetPosition), 0.18);
      expect(manager.secondarySubtitleOffset, 0.18);
    },
  );

  for (final (name, method, separate, hdr) in [
    ('shared size for HDR', StreamPlayMethod.directPlay, false, false),
    ('separate HDR size', StreamPlayMethod.directPlay, true, true),
    ('SDR size for transcoded HDR', StreamPlayMethod.transcode, true, false),
  ]) {
    testWidgets('primary picker applies and saves $name', (tester) async {
      final prefs = GetIt.instance<UserPreferences>();
      await prefs.set(UserPreferences.subtitlesHdrSeparate, separate);
      await prefs.set(UserPreferences.subtitlesHdrTextSize, 30.0);
      await prefs.set(UserPreferences.subtitlesTextColor, 0xFF00FF00);
      final backend = _Backend();
      final manager = _Manager(
        backend,
        resolution: StreamResolutionResult(
          streamUrl: 'https://host/stream',
          mediaSourceId: 'source',
          playMethod: method,
          videoRangeType: 'HDR10',
        ),
      );
      addTearDown(manager.dispose);
      await openPicker(tester, manager, audio: false);
      expect(find.text(l10n.subtitleSize), findsOneWidget);
      expect(find.text(l10n.textFillColor), findsNothing);
      expect(find.text(l10n.verticalOffset), findsOneWidget);

      await tester.tap(find.byTooltip(l10n.increaseValue(l10n.subtitleSize)));
      await tester.pumpAndSettle();
      expect(backend.fontSizes, [hdr ? 32.0 : 22.0]);
      expect(backend.textColor, hdr ? 0xFF808080 : 0xFF00FF00);
      expect(prefs.get(UserPreferences.subtitlesTextSize), hdr ? 20.0 : 22.0);
      expect(
        prefs.get(UserPreferences.subtitlesHdrTextSize),
        hdr ? 32.0 : 30.0,
      );
      expect(prefs.get(UserPreferences.secondarySubtitleSizeAdjustment), 0.0);
    });
  }
}
