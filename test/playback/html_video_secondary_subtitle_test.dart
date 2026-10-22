@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/playback/html_video_backend.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:web/web.dart' as web;

class _Preferences extends Fake implements UserPreferences {}

class _ViewRegistry extends ui_web.PlatformViewRegistry {
  late web.HTMLVideoElement video;

  @override
  bool registerViewFactory(
    String viewType,
    Function viewFactory, {
    bool isVisible = true,
  }) {
    video = Function.apply(viewFactory, [0]) as web.HTMLVideoElement;
    return true;
  }
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Browser condition timed out');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HtmlVideoBackend backend;
  late web.HTMLVideoElement video;
  late String mediaUrl;
  final urls = <String>[];

  String subtitle(String text) {
    final url = web.URL.createObjectURL(
      web.Blob([text.toJS].toJS, web.BlobPropertyBag(type: 'text/plain')),
    );
    urls.add(url);
    return url;
  }

  web.HTMLTrackElement secondary() =>
      video.querySelector('track[label="Secondary"]')! as web.HTMLTrackElement;

  Future<web.HTMLTrackElement> loadedSecondary() async {
    await _until(() {
      final track = video.querySelector('track[label="Secondary"]');
      return track != null &&
          (track as web.HTMLTrackElement).track.mode == 'showing';
    });
    return secondary();
  }

  setUp(() async {
    final registry = _ViewRegistry();
    ui_web.debugOverridePlatformViewRegistry(registry);
    backend = HtmlVideoBackend(_Preferences());
    video = registry.video;
    web.document.body!.appendChild(video);
    // A short silent WAV keeps these tests independent of remote media and
    // exercises the real browser clock, track parser, and active cue list.
    final bytes = Uint8List(44 + 8000 * 8);
    final data = ByteData.sublistView(bytes);
    void ascii(int offset, String value) =>
        bytes.setRange(offset, offset + value.length, value.codeUnits);
    ascii(0, 'RIFF');
    data.setUint32(4, bytes.length - 8, Endian.little);
    ascii(8, 'WAVEfmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little);
    data.setUint16(22, 1, Endian.little);
    data.setUint32(24, 8000, Endian.little);
    data.setUint32(28, 8000, Endian.little);
    data.setUint16(32, 1, Endian.little);
    data.setUint16(34, 8, Endian.little);
    ascii(36, 'data');
    data.setUint32(40, bytes.length - 44, Endian.little);
    bytes.fillRange(44, bytes.length, 128);
    mediaUrl = web.URL.createObjectURL(
      web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: 'audio/wav')),
    );
    urls.add(mediaUrl);
    await backend.play({'url': mediaUrl, 'autoPlay': false});
    await _until(() => video.readyState >= web.HTMLMediaElement.HAVE_METADATA);
  });

  tearDown(() {
    ui_web.debugOverridePlatformViewRegistry(null);
    backend.dispose();
    video.remove();
    for (final url in urls) {
      web.URL.revokeObjectURL(url);
    }
    urls.clear();
  });

  test('SRT and primary VTT remain independently selectable', () async {
    await backend.setSubtitleTrack(
      1,
      isExternalSubtitle: true,
      externalSubtitleUrl: subtitle(
        'WEBVTT\n\n00:01.000 --> 00:03.000\nPrimary\n',
      ),
    );
    final primary = video.querySelector('track')! as web.HTMLTrackElement;
    await backend.setSecondarySubtitle(
      url: subtitle(
        '\uFEFF1\r\n00:00:01,000 --> 00:00:03,000\r\n<i>日本語, العربية</i>\r\n',
      ),
      codec: 'subrip',
    );
    final second = await loadedSecondary();
    expect(primary.track.mode, 'showing');
    final cue = second.track.cues![0] as web.VTTCue;
    expect(cue.startTime, 1);
    expect(cue.getCueAsHTML().textContent, '日本語, العربية');
    await backend.disableSubtitleTrack();
    expect(second.track.mode, 'showing');
    await backend.setSubtitleTrack(1);
    await backend.setSecondarySubtitle();
    expect(primary.track.mode, 'showing');
    expect(video.querySelector('track[label="Secondary"]'), isNull);
  });

  test(
    'delay updates from original times and survives backward seeks',
    () async {
      await backend.setSecondarySubtitle(
        url: subtitle('WEBVTT\n\n00:01.000 --> 00:03.000\nSecond\n'),
        codec: 'vtt',
      );
      final second = await loadedSecondary();
      final cue = second.track.cues![0] as web.VTTCue;
      await backend.setSecondarySubtitleDelay(2);
      expect(cue.startTime, 3);
      await backend.setSecondarySubtitleDelay(-2);
      expect(cue.startTime, -1);
      expect(cue.endTime, 1);
      await backend.setSecondarySubtitleDelay(0);
      await backend.seekTo(const Duration(seconds: 2));
      await _until(() => second.track.activeCues?.length == 1);
      await backend.seekTo(const Duration(seconds: 4));
      await _until(() => second.track.activeCues?.length == 0);
      await backend.seekTo(const Duration(seconds: 2));
      await _until(() => second.track.activeCues?.length == 1);
    },
  );

  test(
    'startup restores style and primary positioning leaves secondary alone',
    () async {
      await backend.play({
        'url': mediaUrl,
        'autoPlay': false,
        'secondarySubtitleUrl': subtitle(
          'WEBVTT\n\n00:01.000 --> 00:03.000\nSecond\n',
        ),
        'secondarySubtitleCodec': 'vtt',
        'secondarySubtitleDelayMs': 500,
        'secondarySubtitleFontSize': 24,
        'secondarySubtitleTextColor': 0xFFFFFF00,
        'secondarySubtitleOffset': 0.12,
      });
      final second = await loadedSecondary();
      final cue = second.track.cues![0] as web.VTTCue;
      expect(cue.startTime, 1.5);
      expect(cue.line.dartify(), 12);
      await backend.configureSubtitleStyle(fontSize: 48, verticalOffset: 0.2);
      expect(cue.line.dartify(), 12);
      final styles = web.document.head!.textContent!;
      expect(styles, contains('font-size: 50.0%'));
      expect(styles, contains('color: rgb(255, 255, 0)'));
      await backend.configureSecondarySubtitleStyle();
      expect(cue.line.dartify(), 8);
      expect(web.document.head!.textContent, contains('font-size: 100.0%'));
    },
  );

  test('replaced loads and Off cannot resurrect old tracks', () async {
    final firstUrl = subtitle('WEBVTT\n\n00:01.000 --> 00:03.000\nOld\n');
    await backend.setSecondarySubtitle(url: firstUrl, codec: 'vtt');
    final old = await loadedSecondary();
    await backend.setSecondarySubtitle(
      url: subtitle('WEBVTT\n\n00:01.000 --> 00:03.000\nNew\n'),
      codec: 'vtt',
    );
    old.dispatchEvent(web.Event('load'));
    final second = await loadedSecondary();
    expect(
      (second.track.cues![0] as web.VTTCue).getCueAsHTML().textContent,
      'New',
    );
    expect(old.parentNode, isNull);
    await backend.setSecondarySubtitle(url: firstUrl, codec: 'vtt');
    await backend.setSecondarySubtitle();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(video.querySelector('track[label="Secondary"]'), isNull);
  });

  test('source changes and stop clear the secondary track', () async {
    final url = subtitle('WEBVTT\n\n00:01.000 --> 00:03.000\nSecond\n');
    await backend.setSecondarySubtitle(url: url, codec: 'vtt');
    await loadedSecondary();
    await backend.play({'url': mediaUrl, 'autoPlay': false});
    expect(video.querySelector('track[label="Secondary"]'), isNull);
    await backend.setSecondarySubtitle(url: url, codec: 'vtt');
    await loadedSecondary();
    await backend.stop();
    expect(video.querySelector('track[label="Secondary"]'), isNull);
  });

  test(
    'load failures report a subtitle error without stopping playback',
    () async {
      final error = backend.errorStream.first;
      await backend.setSecondarySubtitle(url: 'data:invalid', codec: 'vtt');
      expect((await error)['event'], 'subtitleError');
      expect(video.src, mediaUrl);
      expect(video.querySelector('track[label="Secondary"]'), isNull);
    },
  );
}
