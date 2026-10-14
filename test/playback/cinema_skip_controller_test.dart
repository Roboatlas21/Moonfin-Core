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

    void sync(Object item, int index, PlaybackBringupState source, Duration duration) {
      controller.synchronize(
        item: item,
        index: index,
        preroll: trailer,
        itemId: 'trailer',
        source: source,
        duration: duration,
        playing: true,
      );
    }

    PlaybackBringupState ready(String id, int token) => PlaybackBringupState(
      phase: PlaybackBringupPhase.ready,
      sessionToken: token,
      itemId: id,
    );

    sync(first, 0, ready('trailer', 7), const Duration(seconds: 50));
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

  test('Fast Forward skips short and hidden clips only when enabled', () {
    fakeAsync((clock) {
      var skips = 0;
      final controller = CinemaSkipController(onSkip: () async {
        skips++;
      });
      controller.enter({'RunTimeTicks': 50000000});
      controller.skip(requireVisible: false);
      expect(skips, 0);

      controller.configure(enabled: true, minimumSeconds: 15, autoHideSeconds: 10);
      expect(controller.eligible, isFalse);
      controller.skip();
      expect(skips, 0);
      controller.skip(requireVisible: false);
      clock.flushMicrotasks();
      expect(skips, 1);

      clock.elapse(const Duration(milliseconds: 400));
      controller.enter({'RunTimeTicks': 900000000});
      controller.hide();
      controller.skip();
      expect(skips, 1);
      controller.skip(requireVisible: false);
      clock.flushMicrotasks();
      expect(skips, 2);
      controller.dispose();
    });
  });

  test('rapid Skip presses cannot advance two successive pre-rolls', () {
    fakeAsync((clock) {
      var skips = 0;
      final controller = CinemaSkipController(onSkip: () async {
        skips++;
      });
      controller.configure(enabled: true, minimumSeconds: 0, autoHideSeconds: 0);
      controller.enter({'Id': 'first'});
      controller.skip();
      clock.flushMicrotasks();
      controller.enter({'Id': 'second'});
      clock.elapse(const Duration(milliseconds: 399));
      controller.skip();
      expect(skips, 1);
      clock.elapse(const Duration(milliseconds: 1));
      controller.skip();
      clock.flushMicrotasks();
      expect(skips, 2);
      controller.dispose();
    });
  });

  test('a failed Skip restores the current control and permits a retry', () {
    fakeAsync((clock) {
      var attempts = 0;
      final controller = CinemaSkipController(onSkip: () {
        attempts++;
        if (attempts == 1) throw StateError('transition failed');
        return Future<void>.value();
      });
      controller.configure(enabled: true, minimumSeconds: 0, autoHideSeconds: 0);
      controller.enter({'Id': 'trailer'});
      controller.skip();
      clock.flushMicrotasks();
      expect(controller.visible, isTrue);
      clock.elapse(const Duration(milliseconds: 400));
      controller.skip();
      clock.flushMicrotasks();
      expect(attempts, 2);
      controller.dispose();
    });
  });
}
