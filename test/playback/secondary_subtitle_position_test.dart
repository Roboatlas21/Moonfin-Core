import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/playback/secondary_subtitle_position.dart';

void main() {
  test('mpv bottom position does not apply primary margin twice', () {
    expect(mpvPrimaryStackingAnchor(7), 0.05);
    expect(mpvPrimaryStackingAnchor(5), 0.5);
    expect(mpvPrimaryStackingAnchor(2), 1.0);

    // mpv applies sub-margin-y to both tracks, including at primary offsets
    // of 0%, 4% and 8%. The bottom secondary-sub-pos value must stay the
    // same for a given spacing, rather than subtracting that margin again.
    for (final spacing in [0.0, 0.02, 0.04]) {
      final top = stackedSecondaryTop(
        alignment: 2, primaryAnchor: mpvPrimaryStackingAnchor(2),
        primaryHeight: 0.055, secondaryHeight: 0.055, offset: spacing,
      );
      final subPos = ((top + 0.055) * 100).round();
      expect(subPos, 93 - (spacing * 100).round());
    }
  });

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

  test('middle secondary bottom stays anchored when its own height changes', () {
    const anchor = 0.5;
    const primaryHeight = 0.08;
    for (final offset in [0.0, 0.02, 0.06]) {
      final separation = middleSubtitleGap(0.015, offset);
      for (final secondaryHeight in [0.0, 0.06, 0.14]) {
        final secondaryTop = stackedSecondaryTop(
          alignment: 5, primaryAnchor: anchor, primaryHeight: primaryHeight,
          secondaryHeight: secondaryHeight, offset: offset,
        );
        expect(secondaryTop + secondaryHeight,
            closeTo(anchor - primaryHeight / 2 - separation, 0.0001));
      }
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
    expect(initial, closeTo(0.395, 0.0001));
    final adjusted = stackedSecondaryTop(
      alignment: 5, primaryAnchor: anchor, primaryHeight: primaryHeight,
      secondaryHeight: secondaryHeight, offset: 0.02,
    );
    expect(adjusted, closeTo(initial - 0.02, 0.0001));
    expect(middleSubtitleGap(0.015, -0.06), 0.002);
  });

  test('Primary Off ignores spacing and re-enabling restores it', () {
    for (final offset in [0.0, 0.02, 0.06]) {
      final top = stackedSecondaryTop(
        primaryEnabled: false, alignment: 7, primaryAnchor: 0.05,
        primaryHeight: 0.12, secondaryHeight: 0.06, offset: offset,
      );
      expect(top + 0.06, closeTo(1, 0.0001));
    }
    expect(stackedSecondaryTop(
      primaryEnabled: true, alignment: 7, primaryAnchor: 0.05,
      primaryHeight: 0.12, secondaryHeight: 0.06, offset: 0.06,
    ), closeTo(0.245, 0.0001));
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
