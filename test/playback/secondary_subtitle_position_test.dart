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

  test('top stacks below and positive offset moves secondary downward', () {
    const anchor = 0.05;
    final top = stackedSecondaryTop(
      alignment: 7, primaryAnchor: anchor, primaryHeight: 0.06,
      secondaryHeight: 0.06, offset: 0,
    );
    expect(top, closeTo(0.125, 0.0001));
    expect(stackedSecondaryTop(
      alignment: 7, primaryAnchor: anchor, primaryHeight: 0.06,
      secondaryHeight: 0.06, offset: 0.02,
    ), closeTo(top + 0.02, 0.0001));
    expect(stackedSecondaryTop(
      alignment: 7, primaryAnchor: anchor, primaryHeight: 0.06,
      secondaryHeight: 0.06, offset: -0.02,
    ), closeTo(top - 0.02, 0.0001));
  });

  test('middle pair keeps its combined bounds centred at every offset', () {
    const anchor = 0.5;
    const primaryHeight = 0.08;
    const secondaryHeight = 0.12;
    for (final offset in [-0.06, -0.02, 0.0, 0.02, 0.06]) {
      final separation = middleSubtitleGap(0.015, offset);
      final secondaryTop = stackedSecondaryTop(
        alignment: 5, primaryAnchor: anchor, primaryHeight: primaryHeight,
        secondaryHeight: secondaryHeight, offset: offset,
      );
      final primaryCentre = anchor + (secondaryHeight + separation) / 2;
      final primaryBottom = primaryCentre + primaryHeight / 2;
      expect((secondaryTop + primaryBottom) / 2, closeTo(anchor, 0.0001));
      expect(primaryCentre - primaryHeight / 2 -
          (secondaryTop + secondaryHeight), closeTo(separation, 0.0001));
      expect(separation, greaterThan(0));
    }
  });

  test('middle separation changes equally in both directions', () {
    const anchor = 0.5;
    const primaryHeight = 0.06;
    const secondaryHeight = 0.06;
    final initial = stackedSecondaryTop(
      alignment: 5, primaryAnchor: anchor, primaryHeight: primaryHeight,
      secondaryHeight: secondaryHeight, offset: 0,
    );
    expect(initial, closeTo(0.4325, 0.0001));
    final adjusted = stackedSecondaryTop(
      alignment: 5, primaryAnchor: anchor, primaryHeight: primaryHeight,
      secondaryHeight: secondaryHeight, offset: 0.02,
    );
    expect(adjusted, closeTo(initial - 0.01, 0.0001));
    expect(middleSubtitleGap(0.015, -0.06), 0.002);
  });

  test('keeps subtitles inside the viewport', () {
    expect(stackedSecondaryTop(
      alignment: 8, primaryAnchor: 0.95, primaryHeight: 0.1,
      secondaryHeight: 0.08, offset: -0.3,
    ), closeTo(0.765, 0.0001));
    expect(stackedSecondaryTop(
      alignment: 2, primaryAnchor: 0.05, primaryHeight: 0.1,
      secondaryHeight: 0.08, offset: 0.2,
    ), 0);
  });
}
