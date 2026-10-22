import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:playback_core/playback_core.dart';

import '../preference/user_preferences.dart';
import 'aether_backend.dart';
import 'appletv_backend.dart';
import 'media3_player_backend.dart';

/// Apple keeps its existing 24–120 point renderer range on a 1080pt canvas.
/// Round the percentage endpoints inward so every displayed size is usable.
({double min, double max}) secondarySubtitleSizeBounds(
  PlayerBackend? backend,
  double primarySize,
) {
  if (backend is! AetherBackend && backend is! AppleTvBackend) {
    return (min: -50, max: 50);
  }
  return (
    min: ((24 * 24 / 55 / primarySize - 1) * 100).ceilToDouble().clamp(
      -50.0,
      0.0,
    ),
    max: ((120 * 24 / 55 / primarySize - 1) * 100).floorToDouble().clamp(
      0.0,
      50.0,
    ),
  );
}

double secondarySubtitleMaxOffset(PlayerBackend? backend) =>
    backend is Media3PlayerBackend ? 0.2 : 0.4;

/// Updates the active SDR/HDR appearance, including relative secondary size.
Future<void> setPrimarySubtitleSize(
  PlaybackManager manager,
  UserPreferences prefs,
  double size,
) => setPrimarySubtitleAppearance(manager, prefs, fontSize: size);

Future<void> setPrimarySubtitleAppearance(
  PlaybackManager manager,
  UserPreferences prefs, {
  double? fontSize,
  double? verticalOffset,
}) async {
  if (fontSize?.isFinite == false || verticalOffset?.isFinite == false) return;
  final resolution = manager.currentResolution;
  final useHdr =
      prefs.get(UserPreferences.subtitlesHdrSeparate) &&
      isHdrSubtitleOutput(
        videoRangeType: resolution?.videoRangeType,
        isTranscoding: resolution?.playMethod == StreamPlayMethod.transcode,
      );
  if (fontSize != null) {
    await prefs.set(
      useHdr
          ? UserPreferences.subtitlesHdrTextSize
          : UserPreferences.subtitlesTextSize,
      fontSize.clamp(12.0, 48.0),
    );
  }
  if (verticalOffset != null) {
    await prefs.set(
      useHdr
          ? UserPreferences.subtitlesHdrOffsetPosition
          : UserPreferences.subtitlesOffsetPosition,
      verticalOffset.clamp(0.0, 0.4),
    );
  }
  // Some backends default omitted colours, so send the full saved appearance.
  final style = SubtitleStyle.forResolution(prefs, manager.currentResolution);
  await manager.backend?.configureSubtitleStyle(
    textColor: style.textColor,
    backgroundColor: style.backgroundColor,
    strokeColor: style.strokeColor,
    fontSize: style.fontSize,
    fontWeight: style.fontWeight,
    verticalOffset: style.verticalOffset,
  );
  await syncSecondarySubtitleStyle(manager, prefs);
}

/// Default keeps the override unset so the engine follows the primary style,
/// including subsequent colour, size and HDR changes.
Future<void> syncSecondarySubtitleStyle(
  PlaybackManager manager,
  UserPreferences prefs,
) {
  final primarySize = SubtitleStyle.forResolution(
    prefs,
    manager.currentResolution,
  ).fontSize;
  final bounds = secondarySubtitleSizeBounds(manager.backend, primarySize);
  final adjustment = prefs
      .get(UserPreferences.secondarySubtitleSizeAdjustment)
      .clamp(bounds.min, bounds.max);
  return manager.configureSecondarySubtitleStyle(
    fontSize: adjustment == 0 ? null : primarySize * (1 + adjustment / 100),
    verticalOffset: prefs
        .get(UserPreferences.secondarySubtitleOffsetPosition)
        .clamp(-0.4, secondarySubtitleMaxOffset(manager.backend)),
    textColor: switch (prefs.get(UserPreferences.secondarySubtitleTextColor)) {
      -1 => null,
      final color => color,
    },
  );
}

/// Whether what reaches the screen is HDR. A transcode lands as SDR even when
/// the source was HDR, so the subtitles have to follow the output rather than
/// the file.
bool isHdrSubtitleOutput({
  required String? videoRangeType,
  required bool isTranscoding,
}) {
  if (isTranscoding) return false;
  final range = (videoRangeType ?? '').toUpperCase();
  if (range.isEmpty) return false;
  return range != 'SDR';
}

/// The subtitle appearance to draw with, taken from the normal values or the
/// HDR ones.
class SubtitleStyle {
  final int textColor;
  final int backgroundColor;
  final int strokeColor;
  final double fontSize;
  final int fontWeight;
  final double verticalOffset;

  const SubtitleStyle({
    required this.textColor,
    required this.backgroundColor,
    required this.strokeColor,
    required this.fontSize,
    required this.fontWeight,
    required this.verticalOffset,
  });

  /// Reads the appearance for whatever [resolution] is putting on screen.
  factory SubtitleStyle.forResolution(
    UserPreferences prefs,
    StreamResolutionResult? resolution,
  ) => SubtitleStyle.resolve(
    prefs,
    isHdr: isHdrSubtitleOutput(
      videoRangeType: resolution?.videoRangeType,
      isTranscoding: resolution?.playMethod == StreamPlayMethod.transcode,
    ),
  );

  factory SubtitleStyle.resolve(UserPreferences prefs, {required bool isHdr}) {
    final useHdr = isHdr && prefs.get(UserPreferences.subtitlesHdrSeparate);
    T pick<T>(Preference<T> base, Preference<T> hdr) =>
        prefs.get(useHdr ? hdr : base);

    return SubtitleStyle(
      textColor: pick(
        UserPreferences.subtitlesTextColor,
        UserPreferences.subtitlesHdrTextColor,
      ),
      backgroundColor: pick(
        UserPreferences.subtitlesBackgroundColor,
        UserPreferences.subtitlesHdrBackgroundColor,
      ),
      strokeColor: pick(
        UserPreferences.subtitleTextStrokeColor,
        UserPreferences.subtitlesHdrTextStrokeColor,
      ),
      fontSize: pick(
        UserPreferences.subtitlesTextSize,
        UserPreferences.subtitlesHdrTextSize,
      ),
      fontWeight: pick(
        UserPreferences.subtitlesTextWeight,
        UserPreferences.subtitlesHdrTextWeight,
      ),
      verticalOffset: pick(
        UserPreferences.subtitlesOffsetPosition,
        UserPreferences.subtitlesHdrOffsetPosition,
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SubtitleStyle &&
      other.textColor == textColor &&
      other.backgroundColor == backgroundColor &&
      other.strokeColor == strokeColor &&
      other.fontSize == fontSize &&
      other.fontWeight == fontWeight &&
      other.verticalOffset == verticalOffset;

  @override
  int get hashCode => Object.hash(
    textColor,
    backgroundColor,
    strokeColor,
    fontSize,
    fontWeight,
    verticalOffset,
  );
}
