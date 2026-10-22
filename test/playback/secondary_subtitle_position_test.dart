import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/playback/secondary_subtitle_position.dart';

void main() {

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


}
