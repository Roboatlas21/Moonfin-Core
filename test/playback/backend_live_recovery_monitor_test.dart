import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playback_core/playback_core.dart';

void main() {
  BackendLiveRecoveryMonitor monitorFor(FakeAsync async) {
    final base = DateTime(2026, 10, 4, 12);
    return BackendLiveRecoveryMonitor(
      clock: () => base.add(async.elapsed),
      pollInterval: const Duration(seconds: 1),
    );
  }

  List<LiveRecoveryEvent> recoveryEvents(List<LiveRecoveryEvent> events) =>
      events
          .where((event) => event.type == LiveRecoveryEventType.recoveryRequired)
          .toList();

  test('a live source gets the full 30s startup window', () {
    fakeAsync((async) {
      final monitor = monitorFor(async);
      final events = <LiveRecoveryEvent>[];
      monitor.events.listen(events.add);

      monitor.start(
        live: true,
        wantsPlay: true,
        tryInPlaceFirst: false,
      );
      async.flushMicrotasks();

      async.elapse(const Duration(seconds: 29));
      async.flushMicrotasks();
      expect(recoveryEvents(events), isEmpty);

      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();

      final recovery = recoveryEvents(events).single;
      expect(recovery.trigger, LiveRecoveryTrigger.startupTimeout);
      expect(recovery.tryInPlaceFirst, isFalse);
      monitor.dispose();
    });
  });

  test('real progress marks healthy then an 8s stall requests recovery', () {
    fakeAsync((async) {
      final monitor = monitorFor(async);
      final events = <LiveRecoveryEvent>[];
      monitor.events.listen(events.add);

      monitor.start(
        live: true,
        wantsPlay: true,
        tryInPlaceFirst: true,
      );
      monitor.observeProgress(Duration.zero);
      monitor.observeProgress(const Duration(seconds: 1));
      async.flushMicrotasks();

      expect(
        events.where((event) => event.type == LiveRecoveryEventType.healthy),
        hasLength(1),
      );

      async.elapse(const Duration(seconds: 7));
      async.flushMicrotasks();
      expect(recoveryEvents(events), isEmpty);

      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();

      final recovery = recoveryEvents(events).single;
      expect(recovery.trigger, LiveRecoveryTrigger.stalled);
      expect(recovery.tryInPlaceFirst, isTrue);
      monitor.dispose();
    });
  });

  test('a viewer pause never consumes the live recovery budget', () {
    fakeAsync((async) {
      final monitor = monitorFor(async);
      final events = <LiveRecoveryEvent>[];
      monitor.events.listen(events.add);

      monitor.start(
        live: true,
        wantsPlay: true,
        tryInPlaceFirst: true,
      );
      monitor.markHealthy();
      monitor.setPlayIntent(false);
      async.flushMicrotasks();

      async.elapse(const Duration(minutes: 2));
      async.flushMicrotasks();

      expect(recoveryEvents(events), isEmpty);
      expect(events.last.type, LiveRecoveryEventType.inactive);
      monitor.dispose();
    });
  });

  test('an in-place live resume gets the 15s resume window', () {
    fakeAsync((async) {
      final monitor = monitorFor(async);
      final events = <LiveRecoveryEvent>[];
      monitor.events.listen(events.add);

      monitor.start(
        live: true,
        wantsPlay: true,
        tryInPlaceFirst: true,
      );
      monitor.markHealthy();
      monitor.beginInPlaceRecovery();
      async.flushMicrotasks();

      async.elapse(const Duration(seconds: 14));
      async.flushMicrotasks();
      expect(recoveryEvents(events), isEmpty);

      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();

      final recovery = recoveryEvents(events).single;
      expect(recovery.trigger, LiveRecoveryTrigger.stalled);
      expect(recovery.tryInPlaceFirst, isTrue);
      monitor.dispose();
    });
  });

  test('a settled external pause disarms stall timing until playback returns', () {
    fakeAsync((async) {
      final monitor = monitorFor(async);
      final events = <LiveRecoveryEvent>[];
      monitor.events.listen(events.add);

      monitor.start(
        live: true,
        wantsPlay: true,
        tryInPlaceFirst: false,
      );
      monitor.markHealthy();
      monitor.setStallArmed(false);
      async.flushMicrotasks();

      async.elapse(const Duration(minutes: 1));
      async.flushMicrotasks();
      expect(recoveryEvents(events), isEmpty);

      monitor.setStallArmed(true);
      async.elapse(const Duration(seconds: 14));
      async.flushMicrotasks();
      expect(recoveryEvents(events), isEmpty);

      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(recoveryEvents(events).single.trigger, LiveRecoveryTrigger.stalled);
      monitor.dispose();
    });
  });

  test('non-live playback never starts recovery monitoring', () {
    fakeAsync((async) {
      final monitor = monitorFor(async);
      final events = <LiveRecoveryEvent>[];
      monitor.events.listen(events.add);

      monitor.start(
        live: false,
        wantsPlay: true,
        tryInPlaceFirst: true,
      );
      async.elapse(const Duration(minutes: 5));
      async.flushMicrotasks();

      expect(events, isEmpty);
      monitor.dispose();
    });
  });
}
