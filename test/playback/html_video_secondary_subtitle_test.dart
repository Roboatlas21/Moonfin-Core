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

@JS('Object.getOwnPropertyDescriptor')
external JSObject _propertyDescriptor(JSObject object, JSString property);

@JS('Object.defineProperty')
external void _defineProperty(
  JSObject object,
  JSString property,
  JSObject descriptor,
);

// Count assignments even when the value is unchanged, while still calling
// the browser's real VTTCue/TextTrackCue accessors.
void _watchCueWrites(
  web.VTTCue cue,
  String owner,
  String property,
  List<String> writes,
) {
  final prototype = globalContext
      .getProperty<JSObject>(owner.toJS)
      .getProperty<JSObject>('prototype'.toJS);
  final descriptor = _propertyDescriptor(prototype, property.toJS);
  final getter = descriptor.getProperty<JSFunction>('get'.toJS);
  final setter = descriptor.getProperty<JSFunction>('set'.toJS);
  _defineProperty(
    cue,
    property.toJS,
    JSObject()
      ..setProperty('get'.toJS, (() => getter.callAsFunction(cue)).toJS)
      ..setProperty(
        'set'.toJS,
        ((JSAny? value) {
          writes.add(property);
          setter.callAsFunction(cue, value);
        }).toJS,
      ),
  );
}

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

  test('primary SRT alignment and explicit WebVTT settings survive styling', () async {
    await backend.setSubtitleTrack(
      1,
      isExternalSubtitle: true,
      externalSubtitleUrl: subtitle(
        'WEBVTT\n\n00:01.000 --> 00:03.000\n{\\an7}Top left\n'
        '\n00:04.000 --> 00:06.000\n{\\an5}Middle\n'
        '\n00:07.000 --> 00:09.000 line:20% position:80% align:end\nAuthored VTT\n',
      ),
    );
    final primary = video.querySelector('track')! as web.HTMLTrackElement;
    await _until(() => primary.track.cues?.length == 3);
    await backend.seekTo(const Duration(seconds: 2));
    await _until(() => primary.track.activeCues?.length == 1);
    final top = primary.track.cues![0] as web.VTTCue;
    expect(top.line.dartify(), 5);
    expect(top.position, 5);
    expect(top.text, 'Top left');

    await backend.configureSubtitleStyle(verticalOffset: 0.02);
    expect(top.line.dartify(), 7);
    await backend.seekTo(const Duration(seconds: 5));
    final middle = primary.track.cues![1] as web.VTTCue;
    await _until(() => middle.line.dartify() == 50);
    expect(middle.line.dartify(), 50);

    await backend.seekTo(const Duration(seconds: 8));
    await _until(() => primary.track.activeCues?.length == 1);
    final authored = primary.track.cues![2] as web.VTTCue;
    expect(authored.line.dartify(), 20);
    await backend.configureSubtitleStyle(verticalOffset: 0.04);
    expect(authored.line.dartify(), 20);
  });

  test('bottom-aligned primary SRT moves upward from the bottom edge', () async {
    await backend.setSubtitleTrack(
      1,
      isExternalSubtitle: true,
      externalSubtitleUrl: subtitle(
        'WEBVTT\n\n00:01.000 --> 00:03.000\n{\\an2}Bottom\n',
      ),
    );
    final primary = video.querySelector('track')! as web.HTMLTrackElement;
    await _until(() => primary.track.cues?.length == 1);
    await backend.seekTo(const Duration(seconds: 2));
    await _until(() => primary.track.activeCues?.length == 1);
    final cue = primary.track.cues![0] as web.VTTCue;
    expect(cue.line.dartify(), 100);
    await backend.configureSubtitleStyle(verticalOffset: 0.02);
    expect(cue.line.dartify(), 98);
    await backend.configureSubtitleStyle(verticalOffset: 0);
    expect(cue.line.dartify(), 100);
  });

  test('secondary follows top-left and centred primary alignment', () async {
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
    expect(cue.line.dartify(), greaterThan(5));
    final topPosition = (cue.line.dartify() as num).toDouble();
    await backend.configureSecondarySubtitleStyle(verticalOffset: 0.02);
    expect(cue.line.dartify(), closeTo(topPosition + 2, 0.01));
    await backend.configureSecondarySubtitleStyle(verticalOffset: -0.02);
    expect(cue.line.dartify(), closeTo(topPosition - 2, 0.01));
    await backend.configureSecondarySubtitleStyle(verticalOffset: 0);

    await backend.seekTo(const Duration(seconds: 5));
    await _until(() => cue.align == 'center');
    final primary = video.querySelector('track')! as web.HTMLTrackElement;
    final centre = primary.track.cues![1] as web.VTTCue;
    expect(centre.line.dartify(), greaterThan(50));
    expect(cue.line.dartify(), lessThan(50));
    final middlePosition = (cue.line.dartify() as num).toDouble();
    final primaryPosition = (centre.line.dartify() as num).toDouble();
    // A positive 2% gap adjustment moves each side by exactly 1%.
    await backend.configureSecondarySubtitleStyle(verticalOffset: 0.02);
    expect(cue.line.dartify(), closeTo(middlePosition - 1, 0.01));
    expect(centre.line.dartify(), closeTo(primaryPosition + 1, 0.01));
    const lineHeightPercent = 20 / 24 * 0.055 * 100;
    final primaryBottom = (centre.line.dartify() as num).toDouble() +
        lineHeightPercent / 2;
    final secondaryTop = (cue.line.dartify() as num).toDouble();
    expect((secondaryTop + primaryBottom) / 2, closeTo(50, 0.01));
    await backend.configureSecondarySubtitleStyle(verticalOffset: -0.02);
    final closePrimaryBottom = (centre.line.dartify() as num).toDouble() +
        lineHeightPercent / 2;
    expect(
      ((cue.line.dartify() as num).toDouble() + closePrimaryBottom) / 2,
      closeTo(50, 0.01),
    );
    expect(closePrimaryBottom - (cue.line.dartify() as num).toDouble() -
        2 * lineHeightPercent, greaterThan(0));

    // A font-size change must re-centre both labels even when offset is unchanged.
    await backend.configureSecondarySubtitleStyle(
      fontSize: 40, verticalOffset: 0,
    );
    const primaryHeightPercent = 20 / 24 * 0.055 * 100;
    final largerPrimaryBottom = (centre.line.dartify() as num).toDouble() +
        primaryHeightPercent / 2;
    expect(
      ((cue.line.dartify() as num).toDouble() + largerPrimaryBottom) / 2,
      closeTo(50, 0.01),
    );
    await backend.setSecondarySubtitle();
    expect(centre.line.dartify(), 50);
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
        'secondarySubtitleOffset': -0.04,
      });
      final second = await loadedSecondary();
      final cue = second.track.cues![0] as web.VTTCue;
      expect(cue.startTime, 1.5);
      expect(cue.line.dartify(), closeTo(94.5, 0.2));
      await backend.configureSubtitleStyle(fontSize: 48, verticalOffset: 0.2);
      expect(cue.line.dartify(), closeTo(94.5, 0.2));
      final styles = web.document.head!.textContent!;
      expect(styles, matches(RegExp(r'font-size: 50(?:\.0+)?%')));
      expect(styles, contains('color: rgb(255, 255, 0)'));
      await backend.configureSecondarySubtitleStyle();
      expect(cue.line.dartify(), closeTo(85, 0.2));
      expect(
        web.document.head!.textContent,
        matches(RegExp(r'font-size: 100(?:\.0+)?%')),
      );
    },
  );

  test(
    'appearance and position changes do not rewrite cue timestamps',
    () async {
      await backend.setSecondarySubtitle(
        url: subtitle(
          'WEBVTT\n\n00:01.000 --> 00:03.000\nFirst\n\n00:04.000 --> 00:06.000\nSecond\n',
        ),
        codec: 'vtt',
      );
      final second = await loadedSecondary();
      final cues = second.track.cues!;
      final writes = <String>[];
      for (var i = 0; i < cues.length; i++) {
        final cue = cues[i] as web.VTTCue;
        _watchCueWrites(cue, 'TextTrackCue', 'startTime', writes);
        _watchCueWrites(cue, 'TextTrackCue', 'endTime', writes);
        _watchCueWrites(cue, 'VTTCue', 'line', writes);
      }

      await backend.configureSecondarySubtitleStyle(
        fontSize: 32,
        textColor: 0xFFFFFF00,
      );
      // A font-size change repositions the cue but must not rewrite timing.
      expect(writes, ['line', 'line']);
      writes.clear();
      final styles = web.document.head!.textContent;
      expect(styles, contains('color: rgb(255, 255, 0)'));
      await backend.configureSecondarySubtitleStyle(
        fontSize: 36,
        textColor: 0xFFFFFF00,
      );
      expect(writes, ['line', 'line']);
      writes.clear();
      expect(web.document.head!.textContent, isNot(styles));

      // Changing colour alone is styling, not a position or timing change.
      await backend.configureSecondarySubtitleStyle(
        fontSize: 36,
        textColor: 0xFF00FFFF,
      );
      expect(writes, isEmpty);
      await backend.configureSecondarySubtitleStyle(
        fontSize: 36,
        textColor: 0xFFFFFF00,
        verticalOffset: -0.12,
      );
      expect(writes, ['line', 'line']);
      expect((cues[0] as web.VTTCue).line.dartify(), closeTo(91.75, 0.2));
      writes.clear();
      await backend.setSecondarySubtitleDelay(1.25);
      expect(writes, ['startTime', 'endTime', 'startTime', 'endTime']);
      expect(cues[0].startTime, 2.25);
      expect(cues[0].endTime, 4.25);
      expect(cues[1].startTime, 5.25);
      expect(cues[1].endTime, 7.25);
      writes.clear();
      await backend.setSecondarySubtitleDelay(1.25);
      await backend.configureSecondarySubtitleStyle(
        fontSize: 36,
        textColor: 0xFFFFFF00,
        verticalOffset: -0.12,
      );
      expect(writes, isEmpty);
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
