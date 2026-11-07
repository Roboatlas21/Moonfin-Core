import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/services/download_progress_cards.dart';

void main() {
  group('in-process Android download cards', () {
    test('one stable card and action for each live episode', () {
      final cards = DownloadProgressCards(firstId: 20000, sessionId: 'test');
      final a = cards.register('server-a::episode-1');
      final b = cards.register('server-b::episode-1');
      expect(a.notificationId, 20000);
      expect(b.notificationId, 20001);
      expect(cards.register('server-a::episode-1'), same(a));
      expect(cards.forAction(a.cancelActionId)?.transferKey,
          'server-a::episode-1');
      expect(cards.forAction(b.cancelActionId)?.transferKey,
          'server-b::episode-1');
    });

    test('completed and retried transfers cannot use a stale action', () {
      final cards = DownloadProgressCards(firstId: 20000, sessionId: 'test');
      final before = cards.register('episode-1');
      cards.remove('episode-1');
      final retry = cards.register('episode-1');
      expect(retry.notificationId, isNot(before.notificationId));
      expect(retry.cancelActionId, isNot(before.cancelActionId));
      expect(cards.forAction(before.cancelActionId), isNull);
      expect(cards.forAction(retry.cancelActionId)?.transferKey, 'episode-1');
    });

    test('Cancel All invalidates actions without reusing notification IDs', () {
      final cards = DownloadProgressCards(firstId: 20000, sessionId: 'test');
      final first = cards.register('episode-1');
      final second = cards.register('episode-2');
      expect(cards.clear().map((c) => c.notificationId), [20000, 20001]);
      expect(cards.count, 0);
      expect(cards.forAction(first.cancelActionId), isNull);
      expect(cards.forAction(second.cancelActionId), isNull);
      expect(cards.register('episode-3').notificationId, 20002);
    });
  });
}
