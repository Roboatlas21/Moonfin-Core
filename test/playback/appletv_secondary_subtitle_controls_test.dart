import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:moonfin/l10n/app_localizations_en.dart';
import 'package:moonfin/playback/native_apple_player_backend.dart';
import 'package:moonfin/playback/appletv_subtitles.dart';
import 'package:moonfin/playback/subtitle_style.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:playback_core/playback_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _NativeApplePlayerBackend extends Fake implements NativeApplePlayerBackend {
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
  final _backend = _NativeApplePlayerBackend();
  final selections = <int?>[];
  @override
  PlayerBackend get backend => _backend;
  @override
  int? get subtitleStreamIndex => 2;
  @override
  bool canUseAsSecondarySubtitle(int index) => {2, 3, 5, 6, 7}.contains(index);
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

  test('native menu prefers secondary language and preserves track indexes', () async {
    await prefs.set(UserPreferences.preferredSecondarySubtitleLanguage, 'jpn');
    const streams = <Map<String, dynamic>>[
      {'Index': 3, 'Language': 'eng'},
      {'Index': 5, 'Language': 'fra'},
      {'Index': 6, 'Language': 'ja'},
      {'Index': 7, 'Language': 'jpn'},
      {'Index': 2, 'Language': 'eng'},
      {'Index': 4, 'Language': 'ja'},
    ];
    final tracks = <Map<String, dynamic>>[
      {'index': 3, 'label': 'English', 'selected': false},
      {'index': 5, 'label': 'French', 'selected': false},
      {'index': 6, 'label': 'Japanese 1', 'selected': false},
      {'index': 7, 'label': 'Japanese 2', 'selected': true},
      {'index': 2, 'label': 'Primary'},
      {'index': 4, 'label': 'Unsupported'},
    ];
    final metadata = appleTvSubtitleMetadata(
      manager: manager,
      prefs: prefs,
      l10n: AppLocalizationsEn(),
      tracks: tracks,
      sourceStreams: streams,
    );
    final ordered = (metadata['tracks'] as List).cast<Map<String, dynamic>>();
    expect(ordered.map((track) => track['index']).toList(), [6, 7, 3, 5]);
    expect(ordered[1]['selected'], true);
    expect(ordered[1]['label'], 'Japanese 2');
    expect(tracks.map((track) => track['index']).toList(), [3, 5, 6, 7, 2, 4]);

    await handleAppleTvSubtitleAction(
      {'event': 'selectSecondarySubtitle', 'index': ordered[1]['index']},
      manager,
      prefs,
    )!;
    expect(manager.selections, [7]);
  });
}
