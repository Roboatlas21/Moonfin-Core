import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playback_core/playback_core.dart';

void main() {
  BackendLiveRecoveryMonitor monitorFor(FakeAsync _) =>
      BackendLiveRecoveryMonitor();

  List<LiveRecoveryEvent> recoveryEvents(List<LiveRecoveryEvent> events) =>
      events
          .where(
            (event) =>
                event == LiveRecoveryEvent.startupTimeout ||
                event == LiveRecoveryEvent.stalled,
          )
          .toList();

  void markProgressing(BackendLiveRecoveryMonitor monitor) {
    monitor.observeProgress(Duration.zero, eligible: true);
    monitor.observeProgress(const Duration(seconds: 1), eligible: true);
  }

  test('source setup time is not charged to the startup window', () {
    fakeAsync((async) {
      final monitor = monitorFor(async);
      final events = <LiveRecoveryEvent>[];
      monitor.events.listen(events.add);

      async.elapse(const Duration(seconds: 45));
      monitor.start(live: true, wantsPlay: true);
      async.flushMicrotasks();

      async.elapse(const Duration(seconds: 29));
      async.flushMicrotasks();
      expect(recoveryEvents(events), isEmpty);

      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(
        recoveryEvents(events).single,
        LiveRecoveryEvent.startupTimeout,
      );
      monitor.dispose();
    });
  });

  test('a live source gets the full 30s startup window', () {
    fakeAsync((async) {
      final monitor = monitorFor(async);
      final events = <LiveRecoveryEvent>[];
      monitor.events.listen(events.add);

      monitor.start(live: true, wantsPlay: true);
      async.flushMicrotasks();

      async.elapse(const Duration(seconds: 29));
      async.flushMicrotasks();
      expect(recoveryEvents(events), isEmpty);

      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(
        recoveryEvents(events).single,
        LiveRecoveryEvent.startupTimeout,
      );
      monitor.dispose();
    });
  });

  test('real progress marks healthy then an 8s stall requests recovery', () {
    fakeAsync((async) {
      final monitor = monitorFor(async);
      final events = <LiveRecoveryEvent>[];
      monitor.events.listen(events.add);

      monitor.start(live: true, wantsPlay: true);
      markProgressing(monitor);
      async.flushMicrotasks();

      expect(
        events.where((event) => event == LiveRecoveryEvent.healthy),
        hasLength(1),
      );

      async.elapse(const Duration(seconds: 7));
      async.flushMicrotasks();
      expect(recoveryEvents(events), isEmpty);

      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(recoveryEvents(events).single, LiveRecoveryEvent.stalled);
      monitor.dispose();
    });
  });

  test('unchanged eligible position does not mask a later stall', () {
    fakeAsync((async) {
      final monitor = monitorFor(async);
      final events = <LiveRecoveryEvent>[];
      monitor.events.listen(events.add);

      monitor.start(live: true, wantsPlay: true);
      markProgressing(monitor);
      async.flushMicrotasks();

      for (var i = 0; i < 7; i++) {
        async.elapse(const Duration(seconds: 1));
        monitor.observeProgress(const Duration(seconds: 1), eligible: true);
        async.flushMicrotasks();
      }
      expect(recoveryEvents(events), isEmpty);

      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(recoveryEvents(events).single, LiveRecoveryEvent.stalled);
      monitor.dispose();
    });
  });

  test('a viewer pause never consumes the live recovery budget', () {
    fakeAsync((async) {
      final monitor = monitorFor(async);
      final events = <LiveRecoveryEvent>[];
      monitor.events.listen(events.add);

      monitor.start(live: true, wantsPlay: true);
      markProgressing(monitor);
      monitor.setPlayIntent(false);
      async.flushMicrotasks();

      async.elapse(const Duration(minutes: 2));
      async.flushMicrotasks();

      expect(recoveryEvents(events), isEmpty);
      expect(events.last, LiveRecoveryEvent.inactive);
      monitor.dispose();
    });
  });

  test('an in-place live resume gets the 15s resume window', () {
    fakeAsync((async) {
      final monitor = monitorFor(async);
      final events = <LiveRecoveryEvent>[];
      monitor.events.listen(events.add);

      monitor.start(live: true, wantsPlay: true);
      markProgressing(monitor);
      monitor.beginInPlaceRecovery();
      async.flushMicrotasks();

      async.elapse(const Duration(seconds: 14));
      async.flushMicrotasks();
      expect(recoveryEvents(events), isEmpty);

      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(recoveryEvents(events).single, LiveRecoveryEvent.stalled);
      monitor.dispose();
    });
  });

  test('a settled external pause disarms stall timing until playback returns', () {
    fakeAsync((async) {
      final monitor = monitorFor(async);
      final events = <LiveRecoveryEvent>[];
      monitor.events.listen(events.add);

      monitor.start(live: true, wantsPlay: true);
      markProgressing(monitor);
      monitor.setActive(false);
      async.flushMicrotasks();

      async.elapse(const Duration(minutes: 1));
      async.flushMicrotasks();
      expect(recoveryEvents(events), isEmpty);

      monitor.setActive(true);
      async.elapse(const Duration(seconds: 14));
      async.flushMicrotasks();
      expect(recoveryEvents(events), isEmpty);

      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(recoveryEvents(events).single, LiveRecoveryEvent.stalled);
      monitor.dispose();
    });
  });

  test('non-live playback never starts recovery monitoring', () {
    fakeAsync((async) {
      final monitor = monitorFor(async);
      final events = <LiveRecoveryEvent>[];
      monitor.events.listen(events.add);

      monitor.start(live: false, wantsPlay: true);
      async.elapse(const Duration(minutes: 5));
      async.flushMicrotasks();

      expect(events, isEmpty);
      monitor.dispose();
    });
  });
}
