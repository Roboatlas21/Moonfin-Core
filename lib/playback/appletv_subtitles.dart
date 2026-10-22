import 'package:playback_core/playback_core.dart';

import '../l10n/app_localizations.dart';
import '../preference/user_preferences.dart';
import 'subtitle_style.dart';

/// The native tvOS menus use the same eligibility, selection and saved
/// appearance as the Flutter picker. Both video and Live TV use this bridge.
Map<String, dynamic> appleTvSubtitleMetadata({
  required PlaybackManager manager,
  required UserPreferences prefs,
  required AppLocalizations l10n,
  required List<Map<String, dynamic>> tracks,
}) {
  final style = SubtitleStyle.forResolution(prefs, manager.currentResolution);
  return {
    'tracks': tracks.where((track) {
      final index = track['index'];
      return index is int &&
          index != manager.subtitleStreamIndex &&
          manager.canUseAsSecondarySubtitle(index);
    }).toList(),
    'title': l10n.secondarySubtitleSlot,
    'menuTitle': l10n.subtitles,
    'primaryTitle': l10n.primarySubtitleSlot,
    'secondaryTitle': l10n.secondarySubtitleTrack,
    'secondaryDelayLabel': l10n.secondaryDelayAdjustment,
    'off': l10n.off,
    'cancel': l10n.cancel,
    'done': l10n.done,
    'reset': l10n.reset,
    'defaultLabel': l10n.defaultLabel,
    'delayLabel': l10n.subtitleDelay,
    'sizeLabel': l10n.subtitleSize,
    'positionLabel': l10n.verticalOffset,
    'colorLabel': l10n.textFillColor,
    'primaryFontSize': style.fontSize,
    'sizeAdjustment': prefs.get(UserPreferences.secondarySubtitleSizeAdjustment),
    'primaryVerticalOffset': style.verticalOffset,
    'verticalOffset': manager.secondarySubtitleOffset,
    'textColor': prefs.get(UserPreferences.secondarySubtitleTextColor),
    'colors': [
      {'label': l10n.defaultLabel, 'value': -1},
      {'label': l10n.white, 'value': 0xFFFFFFFF},
      {'label': l10n.yellow, 'value': 0xFFFFFF00},
    ],
  };
}

/// Null means the action belongs to another player control.
Future<void>? handleAppleTvSubtitleAction(
  Map<String, dynamic> action,
  PlaybackManager manager,
  UserPreferences prefs,
) {
  switch (action['event']) {
    case 'setSubtitleSize':
      final size = (action['fontSize'] as num?)?.toDouble();
      if (size == null) return Future<void>.value();
      return setPrimarySubtitleSize(manager, prefs, size);
    case 'setSubtitlePosition':
      final offset = (action['verticalOffset'] as num?)?.toDouble();
      if (offset == null) return Future<void>.value();
      return setPrimarySubtitleAppearance(
        manager,
        prefs,
        verticalOffset: offset,
      );
    case 'selectSecondarySubtitle':
      final index = (action['index'] as num?)?.toInt();
      if (index == null) return Future<void>.value();
      return manager.changeSecondarySubtitleTrack(index < 0 ? null : index);
    case 'setSecondarySubtitleDelay':
      final delay = (action['delayMs'] as num?)?.toDouble();
      if (delay == null || !delay.isFinite) return Future<void>.value();
      return manager.setSecondarySubtitleDelay(delay / 1000);
    case 'configureSecondarySubtitleStyle':
      return _saveAppearance(action, manager, prefs);
    default:
      return null;
  }
}

Future<void> _saveAppearance(
  Map<String, dynamic> action,
  PlaybackManager manager,
  UserPreferences prefs,
) async {
  final size = (action['sizeAdjustment'] as num?)?.toDouble();
  final offset = (action['verticalOffset'] as num?)?.toDouble();
  final color = (action['textColor'] as num?)?.toInt();
  if (size != null && size.isFinite) {
    await prefs.set(
      UserPreferences.secondarySubtitleSizeAdjustment,
      size.clamp(-50.0, 50.0).toDouble(),
    );
  }
  if (offset != null && offset.isFinite) {
    await prefs.set(
      UserPreferences.secondarySubtitleOffsetPosition,
      offset
          .clamp(-secondarySubtitleMaxOffset, secondarySubtitleMaxOffset)
          .toDouble(),
    );
  }
  if (color != null) {
    await prefs.set(UserPreferences.secondarySubtitleTextColor, color);
  }
  await syncSecondarySubtitleStyle(manager, prefs);
}
