import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/ui/screens/home/home_screen.dart';

void main() {
  test('Plex Cloud does not reserve a Home media bar or wait for its loading state', () {
    expect(
      HomeScreen.mediaBarEnabledForHome(
        enabledByMode: true,
        cloudOnlyPlex: true,
      ),
      isFalse,
    );
  });

  test('server-backed Home still uses its configured media bar', () {
    expect(
      HomeScreen.mediaBarEnabledForHome(
        enabledByMode: true,
        cloudOnlyPlex: false,
      ),
      isTrue,
    );
    expect(
      HomeScreen.mediaBarEnabledForHome(
        enabledByMode: false,
        cloudOnlyPlex: false,
      ),
      isFalse,
    );
  });
}
