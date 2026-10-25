import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/l10n/app_localizations_en.dart';
import 'package:moonfin/playback/appletv_subtitles.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:playback_core/playback_core.dart';
import '../util/media_segment_fakes.dart' show testPrefs;

class _TrackManager extends PlaybackManager {
  @override
  int? get subtitleStreamIndex => 2;
  @override
  bool canUseAsSecondarySubtitle(int index) => {2, 3, 5, 6, 7}.contains(index);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('native menu prefers secondary language and preserves track indexes', () async {
    final prefs = await testPrefs();
    final manager = _TrackManager();
    addTearDown(prefs.dispose);
    addTearDown(manager.dispose);
    await prefs.set(UserPreferences.preferredSecondarySubtitleLanguage, 'jpn');
    const languages = {3: 'eng', 5: 'fra', 6: 'ja', 7: 'jpn', 2: 'eng', 4: 'ja'};
    final streams = [for (final entry in languages.entries)
      {'Index': entry.key, 'Language': entry.value}];
    final tracks = [for (final index in languages.keys)
      {'index': index, 'label': 'Track $index', 'selected': index == 7}];
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
    expect(tracks.map((track) => track['index']).toList(), [3, 5, 6, 7, 2, 4]);
  });
}
