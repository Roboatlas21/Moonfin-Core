import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:moonfin/l10n/app_localizations_en.dart';
import 'package:moonfin/playback/appletv_subtitles.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:playback_core/playback_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _TrackManager extends PlaybackManager {
  final selections = <int?>[];
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
