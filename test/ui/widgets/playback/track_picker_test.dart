import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:moonfin/l10n/app_localizations.dart';
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

  testWidgets('the secondary subtitle delay opens in the same bar', (
    tester,
  ) async {
    final manager = _Manager(_Backend());
    await openPicker(tester, manager, secondary: true);

    await tester.tap(find.text(l10n.subtitleDelay));
    await tester.pumpAndSettle();
    expect(find.text(l10n.secondarySubtitleTrack), findsNothing);
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
    'secondary size keeps inheritance until adjusted and can restore it',
    (tester) async {
      final prefs = GetIt.instance<UserPreferences>();
      final manager = _Manager(_Backend(secondaryStyle: true));
      addTearDown(manager.dispose);
      await openPicker(tester, manager, secondary: true);
      expect(find.text('${l10n.defaultLabel} (20)'), findsOneWidget);

      await tester.tap(find.byTooltip(l10n.increaseValue(l10n.verticalOffset)));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(l10n.next));
      await tester.pumpAndSettle();
      expect(manager.secondarySubtitleFontSize, isNull);
      expect(prefs.get(UserPreferences.secondarySubtitleTextSize), 0.0);

      await tester.tap(find.byTooltip(l10n.increaseValue(l10n.subtitleSize)));
      await tester.pumpAndSettle();
      expect(manager.secondarySubtitleFontSize, 22.0);
      await tester.tap(find.byTooltip(l10n.decreaseValue(l10n.subtitleSize)));
      await tester.pumpAndSettle();
      expect(find.text('${l10n.defaultLabel} (20)'), findsNothing);
      expect(prefs.get(UserPreferences.secondarySubtitleTextSize), 20.0);

      Focus.of(tester.element(find.byIcon(Icons.restore))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('${l10n.defaultLabel} (20)'), findsOneWidget);
      expect(manager.secondarySubtitleFontSize, isNull);
      expect(prefs.get(UserPreferences.secondarySubtitleTextSize), 0.0);
      expect(manager.secondarySubtitleOffset, closeTo(0.1, 0.001));
      expect(manager.secondarySubtitleTextColor, 0xFFFFFFFF);

      Navigator.of(tester.element(find.byType(Dialog))).pop();
      await tester.pumpAndSettle();
      await setPrimarySubtitleSize(manager, prefs, 26.0);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('${l10n.defaultLabel} (26)'), findsOneWidget);
      expect(manager.secondarySubtitleFontSize, isNull);
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
      expect(find.text(l10n.verticalOffset), findsNothing);

      await tester.tap(find.byTooltip(l10n.increaseValue(l10n.subtitleSize)));
      await tester.pumpAndSettle();
      expect(backend.fontSizes, [hdr ? 32.0 : 22.0]);
      expect(backend.textColor, hdr ? 0xFF808080 : 0xFF00FF00);
      expect(prefs.get(UserPreferences.subtitlesTextSize), hdr ? 20.0 : 22.0);
      expect(
        prefs.get(UserPreferences.subtitlesHdrTextSize),
        hdr ? 32.0 : 30.0,
      );
      expect(prefs.get(UserPreferences.secondarySubtitleTextSize), 0.0);
    });
  }
}
