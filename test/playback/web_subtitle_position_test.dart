import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/playback/web_subtitle_position.dart';

void main() {
  const centre = (align: 'center', position: 50.0, positionAlign: 'center', size: 100.0);

  test('automatic cues stack by measured height above the chosen edge margin', () {
    for (final offset in [0.0, 0.04, 0.2, 0.04]) {
      final occupied = <WebVttCueBox>[];
      var expectedBottom = 1 - offset;
      for (final height in [0.06, 0.12, 0.09]) {
        final top = fitWebAutomaticCue(1 - offset, height, centre, occupied);
        expect(top, closeTo(expectedBottom - height, 0.000001));
        occupied.add((top: top, bottom: top + height, horizontal: centre));
        expectedBottom = top - 0.002;
      }
      final secondaryTop = fitWebSecondaryGroup(occupied.first.top - 0.075,
          0.06, [for (final box in occupied) (top: box.top, bottom: box.bottom)],
          0.015, preferBelow: false);
      expect(secondaryTop + 0.06, closeTo(occupied.last.top - 0.015, 0.000001));
    }
  });

  test('automatic cues keep separate columns and avoid authored boxes', () {
    const left = (align: 'left', position: 0.0, positionAlign: 'line-left', size: 40.0);
    const right = (align: 'right', position: 100.0, positionAlign: 'line-right', size: 40.0);
    final occupied = <WebVttCueBox>[(top: 0.8, bottom: 0.9, horizontal: left)];
    expect(fitWebAutomaticCue(0.9, 0.1, right, occupied), closeTo(0.8, 0.000001));
    expect(fitWebAutomaticCue(0.9, 0.1, left, occupied), closeTo(0.698, 0.000001));
    expect(fitWebAutomaticCue(0.7, 0.1, left, occupied), closeTo(0.6, 0.000001));
    expect(occupied.single.top, 0.8);
    expect(fitWebAutomaticCue(0.9, 0.1, left, const []), closeTo(0.8, 0.000001));
  });

  test('SRT alignment tags use the same edge margin in all three columns', () {
    for (final offset in [0.0, 0.1, 0.2, 0.0]) {
      for (var alignment = 1; alignment <= 9; alignment++) {
        expect(webSrtVerticalPosition(alignment, offset),
            alignment <= 3 ? 1 - offset : alignment <= 6 ? 0.5 : offset);
      }
    }
  });

  test('logical alignment keeps the primary box when text direction changes', () {
    for (final (native, align, position, edge, expectedPosition, expectedSize) in [
      (false, 'start', 25.0, 'right', 100.0, 75.0),
      (false, 'end', 25.0, 'left', 0.0, 25.0),
      (true, 'start', 25.0, 'right', 25.0, 25.0),
      (true, 'end', 25.0, 'left', 25.0, 75.0),
      (false, 'start', null, 'right', 100.0, 100.0),
      (false, 'end', null, 'left', 0.0, 100.0),
      (true, 'start', null, 'right', 50.0, 50.0),
      (true, 'end', null, 'left', 50.0, 50.0),
    ]) {
      final box = webVttHorizontalPlacement(align: align, position: position,
          positionAlign: 'auto', size: 100, rtl: true, supportsPositionAlign: native);
      expect(box, (align: edge, position: expectedPosition,
          positionAlign: 'line-$edge', size: expectedSize));
    }
  });

  test('resolved placement survives reuse with the opposite language', () {
    for (final native in [false, true]) {
      for (final rtl in [false, true]) {
        for (final align in ['start', 'end', 'left', 'right', 'center']) {
          for (final anchor in ['auto', 'line-left', 'line-right', 'center']) {
            final box = webVttHorizontalPlacement(align: align, position: 25,
                positionAlign: anchor, size: 100, rtl: rtl, supportsPositionAlign: native);
            final secondary = webVttHorizontalPlacement(align: box.align, position: box.position,
                positionAlign: box.positionAlign, size: box.size, rtl: !rtl,
                supportsPositionAlign: native);
            expect(secondary, box, reason: '$native $rtl $align $anchor');
            if (native && anchor != 'auto') expect(box.positionAlign, anchor);
          }
        }
      }
    }
    for (final anchor in ['line-left', 'line-right']) {
      final box = webVttHorizontalPlacement(align: 'center',
          position: anchor == 'line-left' ? 5 : 95, positionAlign: anchor,
          size: 90, rtl: true, supportsPositionAlign: true);
      expect(box.size, 90);
      expect(box.align, 'center');
      expect(box.positionAlign, anchor);
    }
  });

  test('a farther gap on the intended side wins over a nearer opposite gap', () {
    for (final below in [false, true]) {
      final occupied = below
          ? [(top: 0.20, bottom: 0.30), (top: 0.36, bottom: 0.60)]
          : [(top: 0.70, bottom: 0.80), (top: 0.40, bottom: 0.64)];
      final top = fitWebSecondaryGroup(below ? 0.315 : 0.585, 0.10,
          occupied, 0.015, preferBelow: below);
      expect(top, closeTo(below ? 0.615 : 0.285, 0.000001));
    }
  });

  test('placement retains its fallback when the intended side has no room', () {
    expect(fitWebSecondaryGroup(-0.065, 0.10, [(top: 0.05, bottom: 0.15)],
        0.015, preferBelow: false), closeTo(0.165, 0.000001));
    expect(fitWebSecondaryGroup(0.2, 0.10, [(top: 0.0, bottom: 1.0)],
        0.015, preferBelow: false), 0.2);
  });
}
