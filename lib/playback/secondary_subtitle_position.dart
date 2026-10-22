/// Preserve a visible gap when negative adjustment draws a centred pair closer.
/// Positive adjustment adds space, half above and half below the centre.
double middleSubtitleGap(double gap, double offset) =>
    (gap + offset).clamp(0.002, 1.0).toDouble();

/// Pure relative stacking calculation for browser and mpv subtitle renderers.
/// ASS/SRT numpad alignment: bottom 1-3, centre 4-6, top 7-9.
double stackedSecondaryTop({
  required int alignment,
  required double primaryAnchor,
  required double primaryHeight,
  required double secondaryHeight,
  required double offset,
  double gap = 0.015,
}) {
  final row = (alignment - 1) ~/ 3;
  final top = switch (row) {
    2 => primaryAnchor + primaryHeight + gap + offset,
    1 => primaryAnchor -
        (primaryHeight + secondaryHeight + middleSubtitleGap(gap, offset)) / 2,
    _ => primaryAnchor - primaryHeight - secondaryHeight - gap - offset,
  };
  return top.clamp(0.0, (1 - secondaryHeight).clamp(0.0, 1.0))
      .toDouble();
}
