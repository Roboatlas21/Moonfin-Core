import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:moonfin/l10n/app_localizations_en.dart';
import 'package:moonfin/playback/appletv_backend.dart';
import 'package:moonfin/playback/appletv_subtitles.dart';
import 'package:moonfin/playback/subtitle_style.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:playback_core/playback_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _AppleTvBackend extends Fake implements AppleTvBackend {
  @override
  Future<void> configureSubtitleStyle({
    int? textColor,
    int? backgroundColor,
    int? strokeColor,
    double? fontSize,
    int? fontWeight,
    double? verticalOffset,
  }) async {}
}

class _TrackManager extends PlaybackManager {
  final _backend = _AppleTvBackend();
  final selections = <int?>[];
  @override
  PlayerBackend get backend => _backend;
  @override
  int? get subtitleStreamIndex => 2;
  @override
  bool canUseAsSecondarySubtitle(int index) => {2, 3}.contains(index);
  @override
  Future<void> changeSecondarySubtitleTrack(int? index) async {
    selections.add(index);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late UserPreferences prefs;
  late _TrackManager manager;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final store = PreferenceStore();
    await store.init();
    prefs = UserPreferences(store);
    manager = _TrackManager();
  });
  tearDown(() {
    manager.dispose();
    prefs.dispose();
  });

  test('native menu excludes the primary and unsupported tracks', () {
    final l10n = AppLocalizationsEn();
    final metadata = appleTvSubtitleMetadata(
      manager: manager,
      prefs: prefs,
      l10n: l10n,
      tracks: [
        {'index': 2, 'label': 'English'},
        {'index': 3, 'label': 'French', 'selected': true},
        {'index': 4, 'label': 'PGS'},
        {'index': 100000, 'label': 'CC'},
      ],
    );
    expect(metadata['tracks'], [
      {'index': 3, 'label': 'French', 'selected': true},
    ]);
    expect(metadata['title'], l10n.secondarySubtitleSlot);
    expect(metadata['sizeLabel'], l10n.subtitleSize);
    expect(metadata['primaryFontSize'], 20.0);
    expect(metadata['sizeAdjustment'], 0.0);
    expect(metadata['defaultLabel'], l10n.defaultLabel);
    expect(metadata['secondaryDelayLabel'], l10n.secondaryDelayAdjustment);
    expect(metadata['primaryVerticalOffset'], 0.04);
    expect(
      metadata['colors'],
      contains(equals({'label': l10n.yellow, 'value': 0xFFFFFF00})),
    );
  });

  test('native selection and off go through the shared manager', () async {
    for (final index in [3, -1]) {
      await handleAppleTvSubtitleAction(
        {'event': 'selectSecondarySubtitle', 'index': index},
        manager,
        prefs,
      );
    }
    expect(manager.selections, [3, null]);
    expect(
      handleAppleTvSubtitleAction({'event': 'selectSubtitle'}, manager, prefs),
      isNull,
    );
  });

  test(
    'native size menu keeps the percentage while rendering caps at 12–48',
    () async {
      await prefs.set(UserPreferences.subtitlesTextSize, 48.0);
      await prefs.set(UserPreferences.secondarySubtitleSizeAdjustment, 50.0);
      final metadata = appleTvSubtitleMetadata(
        manager: manager,
        prefs: prefs,
        l10n: AppLocalizationsEn(),
        tracks: [],
      );
      expect(metadata['sizeAdjustment'], 50.0);
      expect(metadata.containsKey('minSizeAdjustment'), isFalse);
      expect(metadata.containsKey('maxSizeAdjustment'), isFalse);
      await handleAppleTvSubtitleAction(
        {'event': 'configureSecondarySubtitleStyle', 'sizeAdjustment': 50.0},
        manager,
        prefs,
      );
      expect(prefs.get(UserPreferences.secondarySubtitleSizeAdjustment), 50.0);
      expect(manager.secondarySubtitleFontSize, 48.0);

      await prefs.set(UserPreferences.subtitlesTextSize, 12.0);
      await handleAppleTvSubtitleAction(
        {'event': 'configureSecondarySubtitleStyle', 'sizeAdjustment': -50.0},
        manager,
        prefs,
      );
      expect(prefs.get(UserPreferences.secondarySubtitleSizeAdjustment), -50.0);
      expect(manager.secondarySubtitleFontSize, 12.0);
    },
  );

  test(
    'native primary size uses the saved setting and its existing bounds',
    () async {
      for (final (size, expected) in [
        (26.0, 26.0),
        (80.0, 48.0),
        (2.0, 12.0),
        (double.nan, 12.0),
      ]) {
        await handleAppleTvSubtitleAction(
          {'event': 'setSubtitleSize', 'fontSize': size},
          manager,
          prefs,
        );
        expect(prefs.get(UserPreferences.subtitlesTextSize), expected);
      }
      expect(prefs.get(UserPreferences.secondarySubtitleSizeAdjustment), 0.0);
      expect(prefs.get(UserPreferences.subtitlesHdrTextSize), 20.0);
    },
  );

  test(
    'native delay is bounded and appearance persists for the next session',
    () async {
      await handleAppleTvSubtitleAction(
        {'event': 'setSecondarySubtitleDelay', 'delayMs': 9000},
        manager,
        prefs,
      );
      expect(manager.secondarySubtitleDelaySeconds, 5);
      await handleAppleTvSubtitleAction(
        {
          'event': 'configureSecondarySubtitleStyle',
          'sizeAdjustment': 50.0,
          'verticalOffset': 0.16,
          'textColor': 0xFFFFFF00,
        },
        manager,
        prefs,
      );
      expect(prefs.get(UserPreferences.secondarySubtitleSizeAdjustment), 50.0);
      expect(prefs.get(UserPreferences.secondarySubtitleOffsetPosition), 0.16);
      expect(prefs.get(UserPreferences.secondarySubtitleTextColor), 0xFFFFFF00);
      final next = PlaybackManager();
      addTearDown(next.dispose);
      await syncSecondarySubtitleStyle(next, prefs);
      expect(next.secondarySubtitleFontSize, 30.0);
      expect(next.secondarySubtitleOffset, 0.16);
      expect(next.secondarySubtitleTextColor, 0xFFFFFF00);
      // Changing only position must keep the chosen font and colour.
      await handleAppleTvSubtitleAction(
        {'event': 'configureSecondarySubtitleStyle', 'verticalOffset': 0.3},
        manager,
        prefs,
      );
      expect(manager.secondarySubtitleFontSize, 30.0);
      expect(manager.secondarySubtitleTextColor, 0xFFFFFF00);
    },
  );

  test('native Default clears overrides instead of copying the primary preferences', () async {
    await prefs.set(UserPreferences.subtitlesTextColor, 0xFF00FF00);
    await handleAppleTvSubtitleAction(
      {
        'event': 'configureSecondarySubtitleStyle',
        'sizeAdjustment': 40.0,
        'textColor': 0xFFFFFF00,
      },
      manager,
      prefs,
    );
    await handleAppleTvSubtitleAction(
      {
        'event': 'configureSecondarySubtitleStyle',
        'sizeAdjustment': 0.0,
        'textColor': -1,
      },
      manager,
      prefs,
    );
    expect(prefs.get(UserPreferences.secondarySubtitleTextColor), -1);
    expect(manager.secondarySubtitleTextColor, isNull);
    expect(manager.secondarySubtitleFontSize, isNull);
    await handleAppleTvSubtitleAction(
      {'event': 'configureSecondarySubtitleStyle', 'verticalOffset': 0.2},
      manager,
      prefs,
    );
    await prefs.set(UserPreferences.subtitlesTextSize, 28.0);
    expect(prefs.get(UserPreferences.secondarySubtitleSizeAdjustment), 0.0);
    final metadata = appleTvSubtitleMetadata(
      manager: manager,
      prefs: prefs,
      l10n: AppLocalizationsEn(),
      tracks: [],
    );
    expect(metadata['sizeAdjustment'], 0.0);
    expect(metadata['primaryFontSize'], 28.0);
  });
}
