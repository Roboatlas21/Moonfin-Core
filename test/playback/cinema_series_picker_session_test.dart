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

  test('submission owns its lifetime after the trailer ends', () {
    fakeAsync((time) {
      var dismissed = 0;
      final session = CinemaSeriesPickerSession(
        accountKey: () => 'account',
        isMounted: () => true,
      )..dismissDialog = () => dismissed++;
      session.beginGrace();
      time.elapse(const Duration(seconds: 9));
      session.markSubmitting();
      session.beginGrace();
      time.elapse(const Duration(seconds: 30));
      expect(session.isCurrent, isTrue);
      expect(dismissed, 0);
      session.dispose();
    });
  });

  test('account changes and disposal prevent submission', () {
    var account = 'a';
    final session = CinemaSeriesPickerSession(
      accountKey: () => account,
      isMounted: () => true,
    );
    account = 'b';
    expect(session.isCurrent, isFalse);
    session.dispose();
    account = 'a';
    expect(session.isCurrent, isFalse);
  });

  test('picker submission remains valid when the original trailer changes', () {
    fakeAsync((time) {
      var playingOriginalTrailer = true;
      final session = CinemaSeriesPickerSession(
        accountKey: () => 'account',
        isMounted: () => true,
      );
      final requestAllowed = () => session.isCurrent;
      session.beginGrace();
      playingOriginalTrailer = false;
      time.elapse(const Duration(seconds: 9));
      expect(playingOriginalTrailer, isFalse);
      expect(requestAllowed(), isTrue);
      session.markSubmitting();
      time.elapse(const Duration(seconds: 20));
      expect(requestAllowed(), isTrue);
      session.dispose();
      expect(requestAllowed(), isFalse);
    });
  });

  test('expired picker cannot regain permission by starting submission', () {
    fakeAsync((time) {
      final session = CinemaSeriesPickerSession(
        accountKey: () => 'account',
        isMounted: () => true,
      );
      session.beginGrace();
      time.elapse(const Duration(seconds: 10));
      session.markSubmitting();
      expect(session.isCurrent, isFalse);
    });
  });

  test('expiry before the dialog attaches still closes the dialog', () {
    fakeAsync((time) {
      final session = CinemaSeriesPickerSession(
        accountKey: () => 'account',
        isMounted: () => true,
      );
      session.beginGrace();
      time.elapse(const Duration(seconds: 10));
      var dismissed = 0;
      session.dismissDialog = () => dismissed++;
      expect(dismissed, 1);
    });
  });
}
