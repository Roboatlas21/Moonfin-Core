import 'dart:async';

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
  _Manager(
    this._backend, {
    this.resolution,
    this.primaryIndex,
    this.secondaryIndex,
  });

  final PlayerBackend _backend;
  final StreamResolutionResult? resolution;
  final int? primaryIndex;
  final int? secondaryIndex;

  @override
  int? get subtitleStreamIndex => primaryIndex;

  @override
  int? get secondarySubtitleStreamIndex => secondaryIndex;

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

  // These tests don't mount the player screen that listens for style changes.
  void listenForAppleSubtitleChanges(_Manager manager) {
    final prefs = GetIt.instance<UserPreferences>();
    prefs.addListener(
      () => unawaited(syncSecondarySubtitleStyle(manager, prefs)),
    );
  }

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

  testWidgets('slot descriptions ignore blank display titles and titles', (
    tester,
  ) async {
    final manager = _Manager(
      _Backend(secondaryStyle: true),
      primaryIndex: 2,
      secondaryIndex: 3,
      resolution: StreamResolutionResult(
        streamUrl: 'https://host/stream',
        mediaSourceId: 'source',
        playMethod: StreamPlayMethod.directPlay,
        mediaStreams: [
          {
            'Type': 'Subtitle',
            'Index': 2,
            'DisplayTitle': '   ',
            'Title': '  English - SRT  ',
            'Language': 'eng',
          },
          {
            'Type': 'Subtitle',
            'Index': 3,
            'DisplayTitle': '',
            'Title': '  ',
            'Language': '  French  ',
          },
        ],
      ),
    );
    addTearDown(manager.dispose);
    await openPicker(tester, manager, audio: false);

    expect(find.text(l10n.primarySubtitleSlot), findsOneWidget);
    expect(find.text(l10n.secondarySubtitleSlot), findsOneWidget);
    expect(find.text('English - SRT'), findsOneWidget);
    expect(find.text('French'), findsOneWidget);
  });

  testWidgets('slot descriptions prefer a nonempty display title and fall back to Off', (
    tester,
  ) async {
    final manager = _Manager(
      _Backend(secondaryStyle: true),
      primaryIndex: 2,
      secondaryIndex: 3,
      resolution: StreamResolutionResult(
        streamUrl: 'https://host/stream',
        mediaSourceId: 'source',
        playMethod: StreamPlayMethod.directPlay,
        mediaStreams: [
          {
            'Type': 'Subtitle',
            'Index': 2,
            'DisplayTitle': '  English SDH  ',
            'Title': 'Ignored',
          },
          {
            'Type': 'Subtitle',
            'Index': 3,
            'DisplayTitle': '',
            'Title': '   ',
            'Language': '  ',
          },
        ],
      ),
    );
    addTearDown(manager.dispose);
    await openPicker(tester, manager, audio: false);

    expect(find.text('English SDH'), findsOneWidget);
    expect(find.text('Ignored'), findsNothing);
    expect(find.text(l10n.off), findsOneWidget);
  });

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

  testWidgets('saved secondary colours show their name and cycle through the full palette', (
    tester,
  ) async {
    final prefs = GetIt.instance<UserPreferences>();
    await prefs.set(UserPreferences.secondarySubtitleTextColor, 0xFF00FF00);
    final manager = _Manager(_AndroidBackend());
    addTearDown(manager.dispose);
    await openPicker(tester, manager, secondary: true);

    // An existing Green preference must not appear as Default.
    expect(find.text(l10n.green), findsOneWidget);
    for (final (label, color) in [
      (l10n.cyan, 0xFF00FFFF),
      (l10n.blue, 0xFF0000FF),
      (l10n.magenta, 0xFFFF00FF),
      (l10n.red, 0xFFFF0000),
    ]) {
      await tester.tap(find.byTooltip(l10n.next));
      await tester.pumpAndSettle();
      expect(find.text(label), findsOneWidget);
      expect(prefs.get(UserPreferences.secondarySubtitleTextColor), color);
      expect(manager.secondarySubtitleTextColor, color);
    }
    await tester.tap(find.byTooltip(l10n.next));
    await tester.pumpAndSettle();
    expect(prefs.get(UserPreferences.secondarySubtitleTextColor), -1);
    expect(manager.secondarySubtitleTextColor, isNull);
  });

  testWidgets('Apple keeps the chosen size percentage when the cap is reached', (
    tester,
  ) async {
    final prefs = GetIt.instance<UserPreferences>();
    await prefs.set(UserPreferences.subtitlesTextSize, 48.0);
    await prefs.set(UserPreferences.secondarySubtitleSizeAdjustment, 50.0);
    final manager = _Manager(_AppleBackend());
    listenForAppleSubtitleChanges(manager);
    addTearDown(manager.dispose);
    await syncSecondarySubtitleStyle(manager, prefs);
    await openPicker(tester, manager, secondary: true);

    expect(find.text('+50%'), findsOneWidget);
    expect(manager.secondarySubtitleFontSize, 48.0);
    await tester.tap(find.byTooltip(l10n.increaseValue(l10n.subtitleSize)));
    await tester.pumpAndSettle();
    expect(prefs.get(UserPreferences.secondarySubtitleSizeAdjustment), 50.0);
    expect(find.text('+50%'), findsOneWidget);
    expect(manager.secondarySubtitleFontSize, 48.0);

    await tester.tap(find.byTooltip(l10n.decreaseValue(l10n.subtitleSize)));
    await tester.pumpAndSettle();
    expect(prefs.get(UserPreferences.secondarySubtitleSizeAdjustment), 40.0);
    expect(find.text('+40%'), findsOneWidget);
    expect(manager.secondarySubtitleFontSize, 48.0);

    await setPrimarySubtitleSize(manager, prefs, 24.0);
    await tester.pumpAndSettle();
    expect(find.text('+40%'), findsOneWidget);
    expect(manager.secondarySubtitleFontSize, closeTo(33.6, 0.0001));
  });

  testWidgets('Apple retains -50% despite the minimum rendered size', (
    tester,
  ) async {
    final prefs = GetIt.instance<UserPreferences>();
    await prefs.set(UserPreferences.subtitlesTextSize, 12.0);
    await prefs.set(UserPreferences.secondarySubtitleSizeAdjustment, -50.0);
    final manager = _Manager(_AppleBackend());
    listenForAppleSubtitleChanges(manager);
    addTearDown(manager.dispose);
    await syncSecondarySubtitleStyle(manager, prefs);
    await openPicker(tester, manager, secondary: true);

    expect(find.text('-50%'), findsOneWidget);
    expect(manager.secondarySubtitleFontSize, 12.0);
    await tester.tap(find.byTooltip(l10n.decreaseValue(l10n.subtitleSize)));
    await tester.pumpAndSettle();
    expect(prefs.get(UserPreferences.secondarySubtitleSizeAdjustment), -50.0);

    await setPrimarySubtitleSize(manager, prefs, 40.0);
    await tester.pumpAndSettle();
    expect(find.text('-50%'), findsOneWidget);
    expect(manager.secondarySubtitleFontSize, 20.0);
  });

  testWidgets('colour and position edits preserve capped Apple size intent', (
    tester,
  ) async {
    final prefs = GetIt.instance<UserPreferences>();
    await prefs.set(UserPreferences.subtitlesTextSize, 48.0);
    await prefs.set(UserPreferences.secondarySubtitleSizeAdjustment, 50.0);
    final manager = _Manager(_AppleBackend());
    listenForAppleSubtitleChanges(manager);
    addTearDown(manager.dispose);
    await openPicker(tester, manager, secondary: true);
    expect(find.text('+50%'), findsOneWidget);

    await tester.tap(find.byTooltip(l10n.playerTooltipPrevious));
    await tester.pumpAndSettle();
    // Previous from Default wraps to Red in the restored full palette.
    expect(prefs.get(UserPreferences.secondarySubtitleTextColor), 0xFFFF0000);
    expect(prefs.get(UserPreferences.secondarySubtitleSizeAdjustment), 50.0);
    await tester.tap(find.byTooltip(l10n.increaseValue(l10n.verticalOffset)));
    await tester.pumpAndSettle();
    expect(prefs.get(UserPreferences.secondarySubtitleOffsetPosition), 0.02);
    expect(prefs.get(UserPreferences.secondarySubtitleSizeAdjustment), 50.0);
    expect(manager.secondarySubtitleFontSize, 48.0);

    await setPrimarySubtitleSize(manager, prefs, 24.0);
    await tester.pumpAndSettle();
    expect(find.text('+50%'), findsOneWidget);
    expect(manager.secondarySubtitleFontSize, 36.0);
    expect(manager.secondarySubtitleTextColor, 0xFFFF0000);
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
    expect(find.text('+6%'), findsOneWidget);

    await tester.tap(find.byTooltip(l10n.playerTooltipPrevious));
    await tester.pumpAndSettle();
    expect(prefs.get(UserPreferences.secondarySubtitleOffsetPosition), 0.4);
    await tester.tap(find.byTooltip(l10n.increaseValue(l10n.subtitleSize)));
    await tester.pumpAndSettle();
    expect(prefs.get(UserPreferences.secondarySubtitleSizeAdjustment), 10.0);
    expect(prefs.get(UserPreferences.secondarySubtitleOffsetPosition), 0.4);
    expect(manager.secondarySubtitleOffset, 0.06);
  });

  testWidgets(
    'Media3 offset shows the new legacy limit and reverses by 2%',
    (tester) async {
      final prefs = GetIt.instance<UserPreferences>();
      await prefs.set(UserPreferences.secondarySubtitleOffsetPosition, 0.4);
      final manager = _Manager(_AndroidBackend());
      addTearDown(manager.dispose);
      await syncSecondarySubtitleStyle(manager, prefs);
      await openPicker(tester, manager, secondary: true);
      expect(find.text('+6%'), findsOneWidget);
      expect(manager.secondarySubtitleOffset, 0.06);
      await tester.tap(find.byTooltip(l10n.increaseValue(l10n.verticalOffset)));
      await tester.pumpAndSettle();
      expect(find.text('+6%'), findsOneWidget);
      await tester.tap(find.byTooltip(l10n.decreaseValue(l10n.verticalOffset)));
      await tester.pumpAndSettle();
      expect(find.text('+4%'), findsOneWidget);
      expect(prefs.get(UserPreferences.secondarySubtitleOffsetPosition), 0.04);
      expect(manager.secondarySubtitleOffset, 0.04);
    },
  );

  testWidgets('primary offset has seven 2% steps from 0% to 12%', (tester) async {
    final prefs = GetIt.instance<UserPreferences>();
    final manager = _Manager(_Backend());
    addTearDown(manager.dispose);
    await openPicker(tester, manager, audio: false);
    expect(find.text('4%'), findsOneWidget);
    for (final expected in ['6%', '8%', '10%', '12%']) {
      await tester.tap(find.byTooltip(l10n.increaseValue(l10n.verticalOffset)));
      await tester.pumpAndSettle();
      expect(find.text(expected), findsOneWidget);
    }
    await tester.tap(find.byTooltip(l10n.increaseValue(l10n.verticalOffset)));
    await tester.pumpAndSettle();
    expect(find.text('12%'), findsOneWidget);
    expect(prefs.get(UserPreferences.subtitlesOffsetPosition), 0.12);

    for (var i = 0; i < 6; i++) {
      await tester.tap(find.byTooltip(l10n.decreaseValue(l10n.verticalOffset)));
      await tester.pumpAndSettle();
    }
    expect(find.text('0%'), findsOneWidget);
    await tester.tap(find.byTooltip(l10n.decreaseValue(l10n.verticalOffset)));
    await tester.pumpAndSettle();
    expect(prefs.get(UserPreferences.subtitlesOffsetPosition), 0.0);
  });

  testWidgets('secondary offset has seven steps from −6% to +6%', (
    tester,
  ) async {
    final prefs = GetIt.instance<UserPreferences>();
    final manager = _Manager(_AndroidBackend());
    addTearDown(manager.dispose);
    await openPicker(tester, manager, secondary: true);
    for (final expected in ['-2%', '-4%', '-6%']) {
      await tester.tap(find.byTooltip(l10n.decreaseValue(l10n.verticalOffset)));
      await tester.pumpAndSettle();
      expect(find.text(expected), findsOneWidget);
    }
    await tester.tap(find.byTooltip(l10n.decreaseValue(l10n.verticalOffset)));
    await tester.pumpAndSettle();
    expect(find.text('-6%'), findsOneWidget);
    expect(manager.secondarySubtitleOffset, -0.06);
    for (var i = 0; i < 6; i++) {
      await tester.tap(find.byTooltip(l10n.increaseValue(l10n.verticalOffset)));
      await tester.pumpAndSettle();
    }
    expect(find.text('+6%'), findsOneWidget);
    await tester.tap(find.byTooltip(l10n.increaseValue(l10n.verticalOffset)));
    await tester.pumpAndSettle();
    expect(prefs.get(UserPreferences.secondarySubtitleOffsetPosition), 0.06);
    expect(manager.secondarySubtitleOffset, 0.06);
  });

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
