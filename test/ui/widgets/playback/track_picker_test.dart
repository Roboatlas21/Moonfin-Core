import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:moonfin/l10n/app_localizations.dart';

import 'package:moonfin/playback/media_kit_player_backend.dart';

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


  testWidgets('secondary offset uses 0%, +2%, +4%, +6% only', (
    tester,
  ) async {
    final prefs = GetIt.instance<UserPreferences>();
    final manager = _Manager(_AndroidBackend());
    addTearDown(manager.dispose);
    await openPicker(tester, manager, secondary: true);
    await tester.tap(find.byTooltip(l10n.decreaseValue(l10n.verticalOffset)));
    await tester.pumpAndSettle();
    expect(find.text('-2%'), findsNothing);
    expect(prefs.get(UserPreferences.secondarySubtitleOffsetPosition), 0.0);
    for (final expected in ['+2%', '+4%', '+6%']) {
      await tester.tap(find.byTooltip(l10n.increaseValue(l10n.verticalOffset)));
      await tester.pumpAndSettle();
      expect(find.text(expected), findsOneWidget);
    }
    await tester.tap(find.byTooltip(l10n.increaseValue(l10n.verticalOffset)));
    await tester.pumpAndSettle();
    expect(find.text('+6%'), findsOneWidget);
    expect(manager.secondarySubtitleOffset, 0.06);
    for (final expected in ['+4%', '+2%']) {
      await tester.tap(find.byTooltip(l10n.decreaseValue(l10n.verticalOffset)));
      await tester.pumpAndSettle();
      expect(find.text(expected), findsOneWidget);
    }
    await tester.tap(find.byTooltip(l10n.decreaseValue(l10n.verticalOffset)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(l10n.decreaseValue(l10n.verticalOffset)));
    await tester.pumpAndSettle();
    expect(find.text('-2%'), findsNothing);
    expect(prefs.get(UserPreferences.secondarySubtitleOffsetPosition), 0.0);
    expect(manager.secondarySubtitleOffset, 0.0);
  });


}
