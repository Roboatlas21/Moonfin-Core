import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/playback/media_kit_player_backend.dart';

void main() {
  group('MediaKit Live TV startup playing gate', () {
    test('gates every live video session', () {
      expect(
        MediaKitPlayerBackend.shouldGateLiveVideoStartup(
          isLive: true,
          mediaType: 'video',
        ),
        isTrue,
      );
      expect(
        MediaKitPlayerBackend.shouldGateLiveVideoStartup(
          isLive: true,
          mediaType: 'Video',
        ),
        isTrue,
      );
    });

    test('does not gate VOD or live audio', () {
      expect(
        MediaKitPlayerBackend.shouldGateLiveVideoStartup(
          isLive: false,
          mediaType: 'video',
        ),
        isFalse,
      );
      expect(
        MediaKitPlayerBackend.shouldGateLiveVideoStartup(
          isLive: true,
          mediaType: 'audio',
        ),
        isFalse,
      );
    });

    test('suppresses optimistic playing until video output is ready', () {
      expect(
        MediaKitPlayerBackend.reportedPlayingForLiveStartup(
          stale: false,
          gateEnabled: true,
          videoReady: false,
          playerPlaying: true,
        ),
        isFalse,
      );
    });

    test('releases the existing playing state once video output is ready', () {
      expect(
        MediaKitPlayerBackend.reportedPlayingForLiveStartup(
          stale: false,
          gateEnabled: true,
          videoReady: true,
          playerPlaying: true,
        ),
        isTrue,
      );
    });

    test('never exposes a stale source as playing', () {
      expect(
        MediaKitPlayerBackend.reportedPlayingForLiveStartup(
          stale: true,
          gateEnabled: false,
          videoReady: true,
          playerPlaying: true,
        ),
        isFalse,
      );
    });

    test('requires a current mpv frame and configured video output', () {
      expect(
        MediaKitPlayerBackend.mpvFrameOutputReady(
          sourceCurrent: true,
          frameInfo: 'no',
          voConfigured: 'yes',
        ),
        isTrue,
      );

      expect(
        MediaKitPlayerBackend.mpvFrameOutputReady(
          sourceCurrent: false,
          frameInfo: 'no',
          voConfigured: 'yes',
        ),
        isFalse,
      );
      expect(
        MediaKitPlayerBackend.mpvFrameOutputReady(
          sourceCurrent: true,
          frameInfo: null,
          voConfigured: 'yes',
        ),
        isFalse,
      );
      expect(
        MediaKitPlayerBackend.mpvFrameOutputReady(
          sourceCurrent: true,
          frameInfo: 'no',
          voConfigured: 'no',
        ),
        isFalse,
      );
    });

    test('accepts libmpv boolean spellings for vo-configured', () {
      for (final value in const ['yes', 'true', '1']) {
        expect(
          MediaKitPlayerBackend.mpvFrameOutputReady(
            sourceCurrent: true,
            frameInfo: 'yes',
            voConfigured: value,
          ),
          isTrue,
        );
      }
    });
  });
}
