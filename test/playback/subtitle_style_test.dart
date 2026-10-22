import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:moonfin/playback/aether_backend.dart';
import 'package:moonfin/playback/media3_player_backend.dart';
import 'package:moonfin/playback/subtitle_style.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:playback_core/playback_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _AppleBackend extends Fake implements AetherBackend {}

class _AndroidBackend extends Fake implements Media3PlayerBackend {}

class _Manager extends PlaybackManager {
  _Manager(this._backend);

  final PlayerBackend _backend;
  StreamResolutionResult? resolution;

  @override
  PlayerBackend get backend => _backend;

  @override
  StreamResolutionResult? get currentResolution => resolution;
}

Future<UserPreferences> _prefs() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final store = PreferenceStore();
  await store.init();
  return UserPreferences(store);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a transcode is SDR on screen whatever the source was', () {
    expect(
      isHdrSubtitleOutput(videoRangeType: 'HDR10', isTranscoding: true),
      isFalse,
    );
    expect(
      isHdrSubtitleOutput(videoRangeType: 'DOVI', isTranscoding: true),
      isFalse,
    );
  });

  test('anything the server does not call SDR counts as HDR', () {
    expect(
      isHdrSubtitleOutput(videoRangeType: 'HDR10', isTranscoding: false),
      isTrue,
    );
    expect(
      isHdrSubtitleOutput(videoRangeType: 'hlg', isTranscoding: false),
      isTrue,
    );
    expect(
      isHdrSubtitleOutput(videoRangeType: 'SDR', isTranscoding: false),
      isFalse,
    );
  });

  test('an unknown range is treated as SDR rather than guessed at', () {
    expect(
      isHdrSubtitleOutput(videoRangeType: null, isTranscoding: false),
      isFalse,
    );
    expect(
      isHdrSubtitleOutput(videoRangeType: '', isTranscoding: false),
      isFalse,
    );
  });

  test(
    'HDR keeps the normal style until the separate one is turned on',
    () async {
      final prefs = await _prefs();
      await prefs.set(UserPreferences.subtitlesTextColor, 0xFFFFFFFF);
      await prefs.set(UserPreferences.subtitlesHdrTextColor, 0xFF808080);

      expect(SubtitleStyle.resolve(prefs, isHdr: true).textColor, 0xFFFFFFFF);

      await prefs.set(UserPreferences.subtitlesHdrSeparate, true);
      expect(SubtitleStyle.resolve(prefs, isHdr: true).textColor, 0xFF808080);
    },
  );

  test('SDR playback never reads the HDR values', () async {
    final prefs = await _prefs();
    await prefs.set(UserPreferences.subtitlesHdrSeparate, true);
    await prefs.set(UserPreferences.subtitlesTextSize, 20.0);
    await prefs.set(UserPreferences.subtitlesHdrTextSize, 44.0);

    expect(SubtitleStyle.resolve(prefs, isHdr: false).fontSize, 20.0);
    expect(SubtitleStyle.resolve(prefs, isHdr: true).fontSize, 44.0);
  });

  test('every value has its own HDR twin', () async {
    final prefs = await _prefs();
    await prefs.set(UserPreferences.subtitlesHdrSeparate, true);
    await prefs.set(UserPreferences.subtitlesHdrTextColor, 0xFF111111);
    await prefs.set(UserPreferences.subtitlesHdrBackgroundColor, 0xFF222222);
    await prefs.set(UserPreferences.subtitlesHdrTextStrokeColor, 0xFF333333);
    await prefs.set(UserPreferences.subtitlesHdrTextSize, 30.0);
    await prefs.set(UserPreferences.subtitlesHdrTextWeight, 700);
    await prefs.set(UserPreferences.subtitlesHdrOffsetPosition, 0.2);

    final style = SubtitleStyle.resolve(prefs, isHdr: true);
    expect(style.textColor, 0xFF111111);
    expect(style.backgroundColor, 0xFF222222);
    expect(style.strokeColor, 0xFF333333);
    expect(style.fontSize, 30.0);
    expect(style.fontWeight, 700);
    expect(style.verticalOffset, 0.2);
  });

  test(
    'secondary preferences retain overrides and restore inheritance',
    () async {
      final prefs = await _prefs();
      final manager = PlaybackManager();
      addTearDown(prefs.dispose);
      addTearDown(manager.dispose);
      await prefs.set(UserPreferences.secondarySubtitleSizeAdjustment, 50.0);
      await prefs.set(UserPreferences.secondarySubtitleTextColor, 0xFFFFFF00);
      await prefs.set(UserPreferences.secondarySubtitleOffsetPosition, 0.16);
      await syncSecondarySubtitleStyle(manager, prefs);
      expect(manager.secondarySubtitleFontSize, 30.0);
      await prefs.set(UserPreferences.subtitlesTextSize, 40.0);
      await syncSecondarySubtitleStyle(manager, prefs);
      expect(manager.secondarySubtitleFontSize, 60.0);
      await prefs.set(UserPreferences.secondarySubtitleSizeAdjustment, -50.0);
      await prefs.set(UserPreferences.subtitlesTextSize, 12.0);
      await syncSecondarySubtitleStyle(manager, prefs);
      expect(manager.secondarySubtitleFontSize, 6.0);
      expect(manager.secondarySubtitleTextColor, 0xFFFFFF00);
      expect(manager.secondarySubtitleOffset, 0.16);

      await prefs.set(UserPreferences.secondarySubtitleSizeAdjustment, 0.0);
      await prefs.set(UserPreferences.secondarySubtitleTextColor, -1);
      await syncSecondarySubtitleStyle(manager, prefs);
      expect(manager.secondarySubtitleFontSize, isNull);
      expect(manager.secondarySubtitleTextColor, isNull);
      expect(manager.secondarySubtitleOffset, 0.16);
      expect(prefs.get(UserPreferences.secondarySubtitleTextColor), -1);
    },
  );

  test(
    'Apple caps effective size at 12–48 without changing the saved percentage',
    () async {
      final prefs = await _prefs();
      final manager = _Manager(_AppleBackend());
      addTearDown(prefs.dispose);
      addTearDown(manager.dispose);

      await prefs.set(UserPreferences.subtitlesTextSize, 48.0);
      await prefs.set(UserPreferences.secondarySubtitleSizeAdjustment, 50.0);
      await syncSecondarySubtitleStyle(manager, prefs);
      expect(manager.secondarySubtitleFontSize, 48.0);
      expect(prefs.get(UserPreferences.secondarySubtitleSizeAdjustment), 50.0);

      await prefs.set(UserPreferences.subtitlesTextSize, 24.0);
      await syncSecondarySubtitleStyle(manager, prefs);
      expect(manager.secondarySubtitleFontSize, 36.0);
      expect(prefs.get(UserPreferences.secondarySubtitleSizeAdjustment), 50.0);

      await prefs.set(UserPreferences.subtitlesTextSize, 12.0);
      await prefs.set(UserPreferences.secondarySubtitleSizeAdjustment, -50.0);
      await syncSecondarySubtitleStyle(manager, prefs);
      expect(manager.secondarySubtitleFontSize, 12.0);
      expect(prefs.get(UserPreferences.secondarySubtitleSizeAdjustment), -50.0);

      await prefs.set(UserPreferences.subtitlesTextSize, 40.0);
      await syncSecondarySubtitleStyle(manager, prefs);
      expect(manager.secondarySubtitleFontSize, 20.0);

      await prefs.set(UserPreferences.secondarySubtitleSizeAdjustment, 0.0);
      await syncSecondarySubtitleStyle(manager, prefs);
      expect(manager.secondarySubtitleFontSize, isNull);
    },
  );

  test('Apple cap follows the active SDR or HDR primary size', () async {
    final prefs = await _prefs();
    final manager = _Manager(_AppleBackend());
    addTearDown(prefs.dispose);
    addTearDown(manager.dispose);
    await prefs.set(UserPreferences.subtitlesHdrSeparate, true);
    await prefs.set(UserPreferences.subtitlesHdrTextSize, 48.0);
    await prefs.set(UserPreferences.secondarySubtitleSizeAdjustment, 50.0);
    for (final (method, expected) in [
      (StreamPlayMethod.directPlay, 48.0),
      (StreamPlayMethod.transcode, 30.0),
    ]) {
      manager.resolution = StreamResolutionResult(
        streamUrl: 'https://host/video',
        mediaSourceId: 'source',
        playMethod: method,
        videoRangeType: 'HDR10',
      );
      await syncSecondarySubtitleStyle(manager, prefs);
      expect(manager.secondarySubtitleFontSize, expected);
    }
    expect(prefs.get(UserPreferences.secondarySubtitleSizeAdjustment), 50.0);
  });

  test(
    'Media3 bounds legacy positive offsets and retains negative travel',
    () async {
      final prefs = await _prefs();
      final manager = _Manager(_AndroidBackend());
      addTearDown(prefs.dispose);
      addTearDown(manager.dispose);
      await prefs.set(UserPreferences.secondarySubtitleOffsetPosition, 0.4);
      await syncSecondarySubtitleStyle(manager, prefs);
      expect(manager.secondarySubtitleOffset, 0.2);
      expect(prefs.get(UserPreferences.secondarySubtitleOffsetPosition), 0.4);

      await prefs.set(UserPreferences.secondarySubtitleOffsetPosition, -0.4);
      await syncSecondarySubtitleStyle(manager, prefs);
      expect(manager.secondarySubtitleOffset, -0.4);
    },
  );
}
