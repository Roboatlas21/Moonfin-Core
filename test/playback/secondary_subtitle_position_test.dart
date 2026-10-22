import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/playback/secondary_subtitle_position.dart';

void main() {
  test('bottom stacks above and positive offsets move secondary upward', () {
    final top = stackedSecondaryTop(
      alignment: 2, primaryAnchor: 0.96, primaryHeight: 0.1,
      secondaryHeight: 0.06, offset: 0,
    );
    expect(top, closeTo(0.785, 0.0001));
    expect(stackedSecondaryTop(
      alignment: 2, primaryAnchor: 0.96, primaryHeight: 0.1,
      secondaryHeight: 0.06, offset: 0.02,
    ), closeTo(top - 0.02, 0.0001));
  });

  test('top stacks below and centre straddles the authored anchor', () {
    expect(stackedSecondaryTop(
      alignment: 7, primaryAnchor: 0.05, primaryHeight: 0.06,
      secondaryHeight: 0.06, offset: 0,
    ), closeTo(0.125, 0.0001));
    expect(stackedSecondaryTop(
      alignment: 5, primaryAnchor: 0.5, primaryHeight: 0.06,
      secondaryHeight: 0.06, offset: 0,
    ), closeTo(0.4325, 0.0001));
  });

  test('keeps subtitles inside the viewport', () {
    expect(stackedSecondaryTop(
      alignment: 8, primaryAnchor: 0.95, primaryHeight: 0.1,
      secondaryHeight: 0.08, offset: -0.3,
    ), closeTo(0.92, 0.0001));
    expect(stackedSecondaryTop(
      alignment: 2, primaryAnchor: 0.05, primaryHeight: 0.1,
      secondaryHeight: 0.08, offset: 0.2,
    ), 0);
  });
}
