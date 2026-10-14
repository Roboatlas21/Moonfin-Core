import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/playback/cinema_skip_controller.dart';
import 'package:playback_core/playback_core.dart';

void main() {
  test('a new trailer rejects stale playback readiness even with the same item ID', () {
    final controller = CinemaSkipController(onSkip: () async {});
    addTearDown(controller.dispose);
    controller.configure(enabled: true, minimumSeconds: 15, autoHideSeconds: 0);
    final first = Object();
    final second = Object();
    final trailer = {'RunTimeTicks': '900000000'};

    void sync(Object item, int index, PlaybackBringupState source, Duration duration,
        {bool initial = false}) {
      controller.synchronize(
        item: item,
        index: index,
        preroll: trailer,
        itemId: 'trailer',
        source: source,
        duration: duration,
        playing: true,
        initial: initial,
      );
    }

    PlaybackBringupState ready(String id, int token) => PlaybackBringupState(
      phase: PlaybackBringupPhase.ready,
      sessionToken: token,
      itemId: id,
    );

    sync(first, 0, ready('trailer', 7), const Duration(seconds: 50), initial: true);
    expect(controller.duration, const Duration(seconds: 50));
    expect(controller.generation, 1);
    sync(first, 0, ready('trailer', 7), const Duration(seconds: 50));
    expect(controller.generation, 1);

    sync(second, 1, ready('trailer', 7), const Duration(seconds: 30));
    expect(controller.generation, 2);
    expect(controller.duration, const Duration(seconds: 90));
    sync(second, 1, ready('other', 8), const Duration(seconds: 30));
    expect(controller.duration, const Duration(seconds: 90));
    sync(second, 1, ready('trailer', 8), const Duration(seconds: 30));
    expect(controller.duration, const Duration(seconds: 30));
  });

  test('skipping stays opt-in and respects minimum clip length', () {
    final controller = CinemaSkipController(onSkip: () async {});
    addTearDown(controller.dispose);
    controller.enter({'Id': 'short', 'RunTimeTicks': 50000000});
    expect(controller.visible, isFalse);
    controller.configure(enabled: true, minimumSeconds: 15, autoHideSeconds: 15);
    expect(controller.visible, isFalse);
    controller.updatePlayback(
      duration: const Duration(seconds: 16),
      playing: true,
    );
    expect(controller.visible, isTrue);
    controller.configure(enabled: false, minimumSeconds: 15, autoHideSeconds: 15);
    expect(controller.visible, isFalse);
  });

  test('auto-hide begins when playback starts and can be revealed', () {
    fakeAsync((clock) {
      final controller = CinemaSkipController(onSkip: () async {});
      controller.configure(enabled: true, minimumSeconds: 15, autoHideSeconds: 10);
      controller.enter({'Id': 'first', 'RunTimeTicks': 900000000});
      expect(controller.visible, isTrue);
      clock.elapse(const Duration(seconds: 30));
      expect(controller.visible, isTrue);
      controller.updatePlayback(
        duration: const Duration(seconds: 90),
        playing: true,
      );
      clock.elapse(const Duration(seconds: 10));
      expect(controller.visible, isFalse);
      controller.reveal();
      expect(controller.visible, isTrue);
      controller.hide();
      expect(controller.visible, isFalse);
      controller.dispose();
    });
  });

  test('remote Back hides, Right reveals, and Select activates once', () {
    fakeAsync((clock) {
      var skips = 0;
      final controller = CinemaSkipController(onSkip: () async {
        skips++;
      });
      controller.configure(enabled: true, minimumSeconds: 15, autoHideSeconds: 10);
      controller.enter({'Id': 'trailer', 'RunTimeTicks': 900000000});
      controller.updatePlayback(
        duration: const Duration(seconds: 90),
        playing: true,
      );
      controller.hide();
      expect(controller.visible, isFalse);
      controller.skip(); // Ignore a late select from the hidden native button.
      clock.flushMicrotasks();
      expect(skips, 0);

      controller.reveal();
      expect(controller.visible, isTrue);
      clock.elapse(const Duration(seconds: 10));
      expect(controller.visible, isFalse);

      controller.activate(); // Select while hidden shows the control.
      expect(controller.visible, isTrue);
      expect(skips, 0);
      controller.activate(); // The next Select skips.
      clock.flushMicrotasks();
      expect(skips, 1);
      controller.dispose();
    });
  });

  test('a late skip completion does not change the next pre-roll', () {
    fakeAsync((clock) {
      final pending = Completer<void>();
      final controller = CinemaSkipController(onSkip: () => pending.future);
      controller.configure(enabled: true, minimumSeconds: 15, autoHideSeconds: 15);
      controller.enter({'Id': 'first', 'RunTimeTicks': 900000000});
      controller.updatePlayback(
        duration: const Duration(seconds: 90),
        playing: true,
      );
      controller.skip();
      expect(controller.visible, isFalse);
      controller.enter({'Id': 'second', 'RunTimeTicks': 900000000});
      controller.updatePlayback(
        duration: const Duration(seconds: 90),
        playing: true,
      );
      pending.complete();
      clock.flushMicrotasks();
      expect(controller.visible, isTrue);
      clock.elapse(const Duration(seconds: 15));
      expect(controller.visible, isFalse);
      controller.dispose();
    });
  });
}
