import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/playback/cinema_skip_controller.dart';

void main() {
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
