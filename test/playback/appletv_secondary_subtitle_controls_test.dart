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


}
