import 'package:playback_core/playback_core.dart';

import '../l10n/app_localizations.dart';
import '../preference/user_preferences.dart';

/// Builds native tvOS subtitle menu data from the same track rules and saved appearance
/// used by the Flutter picker. Used by video and Live TV; Live TV uses a single
/// subtitle menu.
Map<String, dynamic> appleTvSubtitleMetadata({
  required PlaybackManager manager,
  required UserPreferences prefs,
  required AppLocalizations l10n,
  required List<Map<String, dynamic>> tracks,
  List<Map<String, dynamic>> sourceStreams = const [],
}) {
  final eligible = tracks.where((track) {
    final index = track['index'];
    return index is int &&
        index != manager.subtitleStreamIndex &&
        manager.canUseAsSecondarySubtitle(index);
  });
  return {
    'tracks': eligible.toList(),
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
  };
}

/// Returns null when this handler does not recognise the event.
Future<void>? handleAppleTvSubtitleAction(
  Map<String, dynamic> action,
  PlaybackManager manager,
  UserPreferences prefs,
) {
  switch (action['event']) {
    case 'selectSecondarySubtitle':
      final index = (action['index'] as num?)?.toInt();
      if (index == null) return Future<void>.value();
      return manager.changeSecondarySubtitleTrack(index < 0 ? null : index);
    case 'setSecondarySubtitleDelay':
      final delay = (action['delayMs'] as num?)?.toDouble();
      if (delay == null || !delay.isFinite) return Future<void>.value();
      return manager.setSecondarySubtitleDelay(delay / 1000);
    default:
      return null;
  }
}
