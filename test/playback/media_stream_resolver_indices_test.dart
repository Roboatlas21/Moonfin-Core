import 'package:flutter_test/flutter_test.dart';
import 'package:playback_core/playback_core.dart';

Map<String, String> _params(String url) => Uri.parse(url).queryParameters;

void main() {
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
  group('MediaStreamResolver.extractExternalSubtitles', () {
    test('preserves hosted URLs and joins server-relative paths', () {
      const streams = <Map<String, dynamic>>[
        {
          'Type': 'Subtitle',
          'Index': 1,
          'Codec': 'vtt',
          'IsExternal': true,
          'DeliveryUrl': '/Videos/item/Subtitles/1/Stream.vtt?ApiKey=abc',
        },
        {
          'Type': 'Subtitle',
          'Index': 2,
          'Codec': 'vtt',
          'IsExternal': true,
          'DeliveryUrl': 'Videos/item/Subtitles/2/Stream.vtt',
        },
        {
          'Type': 'Subtitle',
          'Index': 3,
          'Codec': 'vtt',
          'IsExternal': true,
          'DeliveryUrl': 'https://subtitles.example.org/movie.vtt?sig=123',
        },
        {
          'Type': 'Subtitle',
          'Index': 4,
          'Codec': 'vtt',
          'IsExternal': true,
          'DeliveryUrl': 'http://subtitles.example.org/movie.vtt',
        },
      ];
      for (final base in ['https://server.example/jellyfin', 'https://server.example/jellyfin/']) {
        final urls = MediaStreamResolver.extractExternalSubtitles(streams, base)
            .map((sub) => sub.deliveryUrl)
            .toList();
        expect(urls, [
          'https://server.example/jellyfin/Videos/item/Subtitles/1/Stream.vtt?ApiKey=abc',
          'https://server.example/jellyfin/Videos/item/Subtitles/2/Stream.vtt',
          'https://subtitles.example.org/movie.vtt?sig=123',
          'http://subtitles.example.org/movie.vtt',
        ]);
      }
    });
  });

}
