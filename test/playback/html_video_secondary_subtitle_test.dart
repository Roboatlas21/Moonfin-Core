@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
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


  test('secondary follows authored top and fixed middle anchors', () async {
    await backend.setSubtitleTrack(
      1, isExternalSubtitle: true,
      externalSubtitleUrl: subtitle(
        'WEBVTT\n\n00:01.000 --> 00:03.000\n{\\an7}Top left\n'
        '\n00:04.000 --> 00:06.000\n{\\an5}Middle\n',
      ),
    );
    await backend.setSecondarySubtitle(
      url: subtitle('WEBVTT\n\n00:01.000 --> 00:08.000\nSecond\n'),
      codec: 'vtt',
    );
    final second = await loadedSecondary();
    final cue = second.track.cues![0] as web.VTTCue;
    await backend.seekTo(const Duration(seconds: 2));
    await _until(() => cue.align == 'left');
    expect(cue.lineAlign, 'start');
    final topPosition = (cue.line.dartify() as num).toDouble();
    await backend.configureSecondarySubtitleStyle(verticalOffset: 0.02);
    expect(cue.line.dartify(), closeTo(topPosition + 2, 0.01));
    await backend.configureSecondarySubtitleStyle(verticalOffset: -0.02);
    // Legacy negative values never collapse the pair past its minimum gap.
    expect(cue.line.dartify(), closeTo(topPosition - 1.3, 0.01));
    await backend.configureSecondarySubtitleStyle(verticalOffset: 0);

    await backend.seekTo(const Duration(seconds: 5));
    await _until(() => cue.align == 'center');
    final primary = video.querySelector('track')! as web.HTMLTrackElement;
    final centre = primary.track.cues![1] as web.VTTCue;
    expect(centre.lineAlign, 'start');
    expect(cue.lineAlign, 'end');
    final originalPrimary = (centre.line.dartify() as num).toDouble();
    final originalSecondary = (cue.line.dartify() as num).toDouble();
    expect((originalPrimary + originalSecondary) / 2, closeTo(50, 0.01));
    expect(originalPrimary - originalSecondary, closeTo(1.5, 0.01));

    await backend.configureSecondarySubtitleStyle(verticalOffset: 0.02);
    expect(centre.line.dartify(), closeTo(originalPrimary + 1, 0.01));
    expect(cue.line.dartify(), closeTo(originalSecondary - 1, 0.01));
    await backend.configureSecondarySubtitleStyle(verticalOffset: -0.02);
    expect(
      (centre.line.dartify() as num) -
          (cue.line.dartify() as num),
      closeTo(0.2, 0.01),
    );

    // Changing font size must not change anchors when spacing is unchanged.
    await backend.configureSecondarySubtitleStyle(
      fontSize: 40, verticalOffset: 0,
    );
    expect(centre.line.dartify(), closeTo(originalPrimary, 0.01));
    expect(cue.line.dartify(), closeTo(originalSecondary, 0.01));
    await backend.setSecondarySubtitle();
    expect(centre.line.dartify(), 50);
    expect(centre.lineAlign, 'center');
  });


  test('authored top remains top when offset crosses middle boundary', () async {
    await backend.setSubtitleTrack(
      1, isExternalSubtitle: true,
      externalSubtitleUrl: subtitle(
        'WEBVTT\n\n00:01.000 --> 00:08.000 line:30%,start '
        'position:30% align:start\nPrimary\n',
      ),
    );
    await backend.setSecondarySubtitle(
      url: subtitle('WEBVTT\n\n00:01.000 --> 00:08.000\nSecondary\n'),
      codec: 'vtt',
    );
    final second = (await loadedSecondary()).track.cues![0] as web.VTTCue;
    final primary = video.querySelector('track')! as web.HTMLTrackElement;
    await _until(() => primary.track.cues?.length == 1);
    await backend.seekTo(const Duration(seconds: 2));
    await _until(() => primary.track.activeCues?.length == 1 &&
        second.lineAlign == 'start');
    final cue = primary.track.cues![0] as web.VTTCue;
    final originalSecondary = (second.line.dartify() as num).toDouble();
    expect(cue.line.dartify(), closeTo(30, 0.01));

    await backend.configureSubtitleStyle(verticalOffset: 0.04);
    expect(cue.line.dartify(), closeTo(34, 0.01));
    expect(second.lineAlign, 'start');
    expect(second.line.dartify(), closeTo(originalSecondary + 4, 0.1));

    await backend.configureSubtitleStyle(verticalOffset: 0);
    expect(cue.line.dartify(), closeTo(30, 0.01));
    expect(second.lineAlign, 'start');
    expect(second.line.dartify(), closeTo(originalSecondary, 0.1));
    expect(cue.has('moonfinStackedMiddleLine'), isFalse);
  });


  test('Primary Off uses normal bottom and retains secondary spacing', () async {
    await backend.setSubtitleTrack(
      1, isExternalSubtitle: true,
      externalSubtitleUrl: subtitle(
        'WEBVTT\n\n00:01.000 --> 00:03.000\n{\\an7}Top primary\n',
      ),
    );
    await backend.setSecondarySubtitle(
      url: subtitle('WEBVTT\n\n00:01.000 --> 00:09.000\nSecondary\n'),
      codec: 'vtt',
    );
    final second = (await loadedSecondary()).track.cues![0] as web.VTTCue;
    final primary = video.querySelector('track')! as web.HTMLTrackElement;
    await backend.seekTo(const Duration(seconds: 2));
    await _until(() => primary.track.activeCues?.length == 1 &&
        second.lineAlign == 'start');
    await backend.configureSecondarySubtitleStyle(verticalOffset: 0.04);
    final stackedLine = (second.line.dartify() as num).toDouble();

    // Silence does not discard the layout of the selected primary track.
    await backend.seekTo(const Duration(seconds: 4));
    await _until(() => primary.track.activeCues?.length == 0);
    expect(second.lineAlign, 'start');
    expect(second.line.dartify(), closeTo(stackedLine, 0.01));

    await backend.disableSubtitleTrack();
    expect(second.lineAlign, 'end');
    expect(second.line.dartify(), closeTo(96, 0.01));
    expect(second.position.dartify(), 50);
    await backend.configureSecondarySubtitleStyle(verticalOffset: 0.06);
    expect(second.line.dartify(), closeTo(96, 0.01));

    // Restoring primary uses the newly saved +6% spacing again.
    await backend.setSubtitleTrack(1);
    await backend.seekTo(const Duration(seconds: 2));
    await _until(() => primary.track.activeCues?.length == 1 &&
        second.lineAlign == 'start');
    expect(second.line.dartify(), closeTo(stackedLine + 2, 0.1));
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


}
