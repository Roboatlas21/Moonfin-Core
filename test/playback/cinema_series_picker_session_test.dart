import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/playback/cinema_series_picker_session.dart';

void main() {

  test('queue transitions give one ten-second grace period', () {
    fakeAsync((time) {
      var dismissed = 0;
      final session = CinemaSeriesPickerSession(
        accountKey: () => 'account',
        isMounted: () => true,
      )..dismissDialog = () => dismissed++;
      session.beginGrace();
      time.elapse(const Duration(seconds: 9));
      session.beginGrace(); // Another transition must not extend the deadline.
      expect(session.isCurrent, isTrue);
      time.elapse(const Duration(seconds: 1));
      expect(session.isCurrent, isFalse);
      expect(dismissed, 1);
      session.close();
      expect(dismissed, 1);
    });
  });

  test('Skip preserves a submitting request; player exit still closes it', () {
    fakeAsync((time) {
      var dismissals = 0;
      final session = CinemaSeriesPickerSession(
        accountKey: () => 'account',
        isMounted: () => true,
      )..dismissDialog = () => dismissals++;
      session.beginGrace();
      session.markSubmitting();
      expect(session.closeForSkip(), isFalse);
      session.beginGrace();
      time.elapse(const Duration(seconds: 30));
      expect(session.isCurrent, isTrue);
      expect(dismissals, 0);

      session.close(); // Player exit or explicit cancellation still wins.
      expect(session.isCurrent, isFalse);
      expect(dismissals, 1);
    });
  });

  test('Skip does not preserve a submission after the account changes', () {
    var account = 'first';
    var dismissals = 0;
    final session = CinemaSeriesPickerSession(
      accountKey: () => account,
      isMounted: () => true,
    )..dismissDialog = () => dismissals++;
    session.markSubmitting();
    account = 'second';
    expect(session.closeForSkip(), isTrue);
    expect(session.isCurrent, isFalse);
    expect(dismissals, 1);
  });
}
