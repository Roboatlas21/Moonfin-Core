import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:moonfin/l10n/app_localizations_en.dart';
import 'package:moonfin/playback/appletv_secondary_subtitles.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:playback_core/playback_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _TrackManager extends PlaybackManager {
  final selections = <int?>[];
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
    final metadata = appleTvSecondarySubtitleMetadata(
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
    expect(
      metadata['colors'],
      contains({'label': l10n.yellow, 'value': 0xFFFFFF00}),
    );
  });

  test('native selection and off go through the shared manager', () async {
    for (final index in [3, -1]) {
      await handleAppleTvSecondarySubtitleAction(
        {'event': 'selectSecondarySubtitle', 'index': index},
        manager,
        prefs,
      );
    }
    expect(manager.selections, [3, null]);
    expect(
      handleAppleTvSecondarySubtitleAction(
        {'event': 'selectSubtitle'},
        manager,
        prefs,
      ),
      isNull,
    );
  });

  test(
    'native delay is bounded and appearance persists for the next session',
    () async {
      await handleAppleTvSecondarySubtitleAction(
        {'event': 'setSecondarySubtitleDelay', 'delayMs': 9000},
        manager,
        prefs,
      );
      expect(manager.secondarySubtitleDelaySeconds, 5);
      await handleAppleTvSecondarySubtitleAction(
        {
          'event': 'configureSecondarySubtitleStyle',
          'fontSize': 30.0,
          'verticalOffset': 0.16,
          'textColor': 0xFFFFFF00,
        },
        manager,
        prefs,
      );
      expect(prefs.get(UserPreferences.secondarySubtitleTextSize), 30.0);
      expect(prefs.get(UserPreferences.secondarySubtitleOffsetPosition), 0.16);
      expect(prefs.get(UserPreferences.secondarySubtitleTextColor), 0xFFFFFF00);
      final next = PlaybackManager();
      addTearDown(next.dispose);
      await syncAppleTvSecondarySubtitleStyle(next, prefs);
      expect(next.secondarySubtitleFontSize, 30.0);
      expect(next.secondarySubtitleOffset, 0.16);
      expect(next.secondarySubtitleTextColor, 0xFFFFFF00);
      // Changing only position must keep the chosen font and colour.
      await handleAppleTvSecondarySubtitleAction(
        {'event': 'configureSecondarySubtitleStyle', 'verticalOffset': 0.3},
        manager,
        prefs,
      );
      expect(manager.secondarySubtitleFontSize, 30.0);
      expect(manager.secondarySubtitleTextColor, 0xFFFFFF00);
    },
  );

  test(
    'default secondary appearance follows the primary preferences',
    () async {
      await prefs.set(UserPreferences.subtitlesTextColor, 0xFF00FF00);
      await handleAppleTvSecondarySubtitleAction(
        {'event': 'configureSecondarySubtitleStyle', 'textColor': -1},
        manager,
        prefs,
      );
      expect(prefs.get(UserPreferences.secondarySubtitleTextColor), -1);
      expect(manager.secondarySubtitleTextColor, 0xFF00FF00);
    },
  );
}
