/// Enforce minimum separation for a pair; positive adjustments add space.
double middleSubtitleGap(double gap, double offset) =>
    (gap + offset).clamp(0.002, 1.0).toDouble();

/// Pure placement for mpv's secondary subtitle top edge. Its bottom edge is
/// the controlled position; top-anchored text needs its own height added back.
/// The primary's authored alignment dictates the pair's vertical zone.
double stackedSecondaryTop({
  required int alignment,
  bool primaryEnabled = true,
  required double primaryAnchor,
  required double primaryHeight,
  required double secondaryHeight,
  required double offset,
  double gap = 0.015,
}) {
  // Without a primary, secondary occupies the normal bottom regardless of gap.
  if (!primaryEnabled) return (1 - secondaryHeight).clamp(0.0, 1.0).toDouble();
  final row = (alignment - 1) ~/ 3;
  final top = switch (row) {
    2 => primaryAnchor + primaryHeight + gap + offset,
    1 => primaryAnchor -
        primaryHeight / 2 - secondaryHeight - middleSubtitleGap(gap, offset),
    _ => primaryAnchor - primaryHeight - secondaryHeight - gap - offset,
  };
  return top.clamp(0.0, (1 - secondaryHeight).clamp(0.0, 1.0))
      .toDouble();
}
