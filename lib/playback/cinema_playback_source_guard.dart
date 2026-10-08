import 'package:playback_core/playback_core.dart';

/// Tracks the queue item whose playback source Cinema may observe.
/// A ready event from the outgoing source must not arm the next trailer.
class CinemaPlaybackSourceGuard {
  Object? _item;
  int _index = -1;
  int? _lastReadyToken;
  int? _previousReadyToken;

  /// Returns true only for a new queue item (or a forced initial snapshot).
  bool enter(Object? item, int index, {bool initial = false}) {
    if (!initial && identical(item, _item) && index == _index) return false;
    _previousReadyToken = initial ? null : _lastReadyToken;
    _item = item;
    _index = index;
    return true;
  }

  /// Accepts readiness only after the right item/source has begun.
  bool observeReady({
    required Object? item,
    required int index,
    required String? itemId,
    required PlaybackBringupState source,
  }) {
    if (source.phase != PlaybackBringupPhase.ready ||
        !identical(item, _item) ||
        index != _index ||
        source.itemId != itemId ||
        source.sessionToken == _previousReadyToken) {
      return false;
    }
    _lastReadyToken = source.sessionToken;
    return true;
  }
}
