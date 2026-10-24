import 'package:flutter_test/flutter_test.dart';
import 'package:playback_core/playback_core.dart';

Map<String, String> _params(String url) => Uri.parse(url).queryParameters;

void main() {

  group('MediaStreamResolver.isServerUrl', () {
    const base = 'https://media.example.com/jellyfin';
    test('accepts the configured server and reverse-proxy base path', () {
      for (final url in [
        base,
        '$base/',
        '$base/Videos/123/stream?ApiKey=old',
        'https://MEDIA.example.com:443/jellyfin/Videos/123/stream',
      ]) {
        expect(MediaStreamResolver.isServerUrl(url, base), isTrue, reason: url);
        expect(MediaStreamResolver.isServerUrl(url, '$base/'), isTrue,
            reason: url);
      }
      expect(MediaStreamResolver.isServerUrl(
        'https://media.example.com/Movies/123', 'https://media.example.com',
      ), isTrue);
      expect(MediaStreamResolver.isServerUrl(
        'https://media.example.com:8920/emby/Videos/123',
        'https://media.example.com:8920/emby',
      ), isTrue);
    });

    test('rejects unrelated origins and paths', () {
      for (final url in [
        'https://media.example.com.attacker.net/jellyfin/Videos/123',
        'https://media.example.com@attacker.net/jellyfin/Videos/123',
        'https://other.example.com/jellyfin/Videos/123',
        'http://media.example.com/jellyfin/Videos/123',
        'https://media.example.com:8443/jellyfin/Videos/123',
        'https://media.example.com/jellyfin-other/Videos/123',
        'https://media.example.com/otherapp/Videos/123',
        '//media.example.com/jellyfin/Videos/123',
        '/jellyfin/Videos/123',
      ]) {
        expect(MediaStreamResolver.isServerUrl(url, base), isFalse, reason: url);
      }
    });
  });

  group('MediaStreamResolver.applyStreamIndices', () {
    test('emits a single canonical AudioStreamIndex', () {
      final url = MediaStreamResolver.applyStreamIndices(
        'https://server/videos/abc/master.m3u8?DeviceId=d&AudioStreamIndex=3',
        1,
        null,
      );

      final params = _params(url);
      expect(params['AudioStreamIndex'], '1');
      expect(
        params.keys.where((k) => k.toLowerCase() == 'audiostreamindex'),
        hasLength(1),
      );
    });

    test('strips every casing of a pre-existing audio index param', () {
      // Emby/Jellyfin bind query params case-insensitively: any surviving
      // duplicate casing merges into "1,1" server-side and 500s the manifest.
      final url = MediaStreamResolver.applyStreamIndices(
        'https://server/videos/abc/master.m3u8'
        '?audioStreamIndex=3&AUDIOSTREAMINDEX=4&audiostreamindex=5',
        1,
        null,
      );

      final params = _params(url);
      expect(params['AudioStreamIndex'], '1');
      expect(
        params.keys.where((k) => k.toLowerCase() == 'audiostreamindex'),
        hasLength(1),
      );
    });

    test('subtitle index -1 removes every casing and writes nothing', () {
      final url = MediaStreamResolver.applyStreamIndices(
        'https://server/videos/abc/master.m3u8'
        '?SubtitleStreamIndex=2&subtitleStreamIndex=2&DeviceId=d',
        null,
        -1,
      );

      final params = _params(url);
      expect(
        params.keys.where((k) => k.toLowerCase() == 'subtitlestreamindex'),
        isEmpty,
      );
      expect(params['DeviceId'], 'd');
    });

    test('subtitle index >= 0 leaves one canonical param', () {
      final url = MediaStreamResolver.applyStreamIndices(
        'https://server/videos/abc/master.m3u8?subtitlestreamindex=9',
        null,
        4,
      );

      final params = _params(url);
      expect(params['SubtitleStreamIndex'], '4');
      expect(
        params.keys.where((k) => k.toLowerCase() == 'subtitlestreamindex'),
        hasLength(1),
      );
    });

    test('null indices leave the url untouched', () {
      const original =
          'https://server/videos/abc/master.m3u8?audioStreamIndex=3';
      final url = MediaStreamResolver.applyStreamIndices(original, null, null);
      expect(_params(url)['audioStreamIndex'], '3');
    });
  });
}
