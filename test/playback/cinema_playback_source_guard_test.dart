import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/playback/cinema_playback_source_guard.dart';
import 'package:playback_core/playback_core.dart';

PlaybackBringupState ready(String id, int token) => PlaybackBringupState(
  phase: PlaybackBringupPhase.ready,
  sessionToken: token,
  itemId: id,
);

void main() {
  test('new item ignores outgoing source even when item IDs match', () {
    final guard = CinemaPlaybackSourceGuard();
    final first = Object();
    final second = Object();
    expect(guard.enter(first, 0, initial: true), isTrue);
    expect(
      guard.observeReady(item: first, index: 0, itemId: 'trailer', source: ready('trailer', 7)),
      isTrue,
    );
    expect(guard.enter(second, 1), isTrue);
    expect(
      guard.observeReady(item: second, index: 1, itemId: 'trailer', source: ready('trailer', 7)),
      isFalse,
    );
    expect(
      guard.observeReady(item: second, index: 1, itemId: 'trailer', source: ready('other', 8)),
      isFalse,
    );
    expect(
      guard.observeReady(item: second, index: 1, itemId: 'trailer', source: ready('trailer', 8)),
      isTrue,
    );
  });

  test('same queue entry is not reentered, but a changed index is', () {
    final guard = CinemaPlaybackSourceGuard();
    final item = Object();
    expect(guard.enter(item, 0, initial: true), isTrue);
    expect(guard.enter(item, 0), isFalse);
    expect(guard.enter(item, 1), isTrue);
    expect(
      guard.observeReady(item: item, index: 0, itemId: 'id', source: ready('id', 2)),
      isFalse,
    );
    expect(
      guard.observeReady(item: item, index: 1, itemId: 'id', source: ready('id', 2)),
      isTrue,
    );
  });
}
