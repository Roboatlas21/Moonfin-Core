import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/playback/web_secondary_subtitle_url.dart';

void main() {
  test('requests WebVTT for embedded SRT on Jellyfin-style endpoints', () {
    const raw = 'https://jellyfin.example/Moonfin/Videos/item/source/'
        'Subtitles/3/0/Stream.srt?api_key=token';
    const vtt = 'https://jellyfin.example/Moonfin/Videos/item/source/'
        'Subtitles/3/0/Stream.vtt?api_key=token';
    expect(preferServerWebVttSubtitleUrl(raw), vtt);
  });

  test('supports server sidecars without start ticks', () {
    expect(
      preferServerWebVttSubtitleUrl(
        '/emby/Videos/item/source/Subtitles/4/Stream.SRT?ApiKey=test',
      ),
      '/emby/Videos/item/source/Subtitles/4/Stream.vtt?ApiKey=test',
    );
  });

  test('leaves standalone subtitle URLs and existing WebVTT untouched', () {
    for (final url in [
      'https://subtitles.example/movie.en.srt?token=abc',
      'https://example.com/Stream.srt',
      'https://jellyfin.example/Videos/item/source/Subtitles/3/0/Stream.vtt',
      'https://example.com/watch?next=/Videos/a/b/Subtitles/3/0/Stream.srt',
      'https://jellyfin.example/Videos/item/source/Subtitles/3/0/Stream.srt?format=srt',
    ]) {
      expect(preferServerWebVttSubtitleUrl(url), url);
    }
  });
}
