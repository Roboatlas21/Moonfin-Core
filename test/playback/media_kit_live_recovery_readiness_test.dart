import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/playback/media_kit_player_backend.dart';

void main() {
  group('MediaKit live video readiness', () {
    test('requires the current source, configured VO, and a real frame', () {
      expect(
        MediaKitPlayerBackend.liveVideoFrameReady(
          sourceCurrent: true,
          voConfigured: 'yes',
          frameInfo: 'picture-type=P',
        ),
        isTrue,
      );

      expect(
        MediaKitPlayerBackend.liveVideoFrameReady(
          sourceCurrent: false,
          voConfigured: 'yes',
          frameInfo: 'picture-type=P',
        ),
        isFalse,
      );
      expect(
        MediaKitPlayerBackend.liveVideoFrameReady(
          sourceCurrent: true,
          voConfigured: 'no',
          frameInfo: 'picture-type=P',
        ),
        isFalse,
      );
      expect(
        MediaKitPlayerBackend.liveVideoFrameReady(
          sourceCurrent: true,
          voConfigured: 'yes',
          frameInfo: '',
        ),
        isFalse,
      );
    });

    test('accepts mpv boolean spellings for vo-configured', () {
      for (final value in const ['yes', 'true', '1']) {
        expect(
          MediaKitPlayerBackend.liveVideoFrameReady(
            sourceCurrent: true,
            voConfigured: value,
            frameInfo: 'interlaced=no',
          ),
          isTrue,
        );
      }
    });
  });
}
