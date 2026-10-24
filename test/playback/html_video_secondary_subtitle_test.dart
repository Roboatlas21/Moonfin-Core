@TestOn('browser')
library;

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

  // Resolve or reject browser play() promises after a newer user action.
  void deferVideoPlay() {
    final script = web.HTMLScriptElement()..text = '''
      window.moonfinDeferredPlayCount = 0;
      window.moonfinDeferredPlays = [];
      document.getElementById('${video.id}').play = function() {
        window.moonfinDeferredPlayCount++;
        return new Promise((resolve, reject) => {
          window.moonfinDeferredPlays.push({resolve, reject});
        });
      };
    ''';
    web.document.head!.appendChild(script);
    script.remove();
  }

  int pendingPlayCount() => web.window
      .getProperty<JSNumber>('moonfinDeferredPlayCount'.toJS).toDartInt;

  void finishPlay(int index, {bool reject = false}) {
    final completion = reject ? 'reject(new Error("interrupted"))' : 'resolve()';
    final script = web.HTMLScriptElement()
      ..text = 'window.moonfinDeferredPlays[$index].$completion;';
    web.document.head!.appendChild(script);
    script.remove();
  }

  setUp(() async {
    final registry = _ViewRegistry();
    ui_web.debugOverridePlatformViewRegistry(registry);
    backend = HtmlVideoBackend(_Preferences());
    video = registry.video;
    video.style.width = '1280px';
    video.style.height = '720px';
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
    web.window.delete('moonfinDeferredPlayCount'.toJS);
    web.window.delete('moonfinDeferredPlays'.toJS);
    video.remove();
    for (final url in urls) {
      web.URL.revokeObjectURL(url);
    }
    urls.clear();
  });

  test('Stop ignores a rejected old play request and does not restart polling', () async {
    await backend.stop();
    deferVideoPlay();
    final errors = <Map<String, dynamic>>[];
    var trackChanges = 0;
    final errorSub = backend.errorStream.listen(errors.add);
    final trackSub = backend.tracksChangedStream.listen((_) => trackChanges++);
    try {
      final oldPlay = backend.play({'url': mediaUrl});
      await _until(() => pendingPlayCount() == 1);
      await backend.stop();
      finishPlay(0, reject: true);
      await oldPlay;
      final track = web.HTMLTrackElement()..kind = 'subtitles';
      video.appendChild(track);
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(errors, isEmpty);
      expect(trackChanges, 0);
      expect(backend.isPlaying, isFalse);
      expect(backend.isBuffering, isFalse);
      track.remove();
    } finally {
      await errorSub.cancel();
      await trackSub.cancel();
    }
  });

  test('a newer Play keeps control of buffering and playback state', () async {
    await backend.stop();
    deferVideoPlay();
    final errors = <Map<String, dynamic>>[];
    final sub = backend.errorStream.listen(errors.add);
    try {
      final first = backend.play({'url': mediaUrl});
      await _until(() => pendingPlayCount() == 1);
      final latest = backend.play({'url': mediaUrl});
      await _until(() => pendingPlayCount() == 2);
      finishPlay(0, reject: true);
      await first;
      expect(errors, isEmpty);
      expect(backend.isBuffering, isTrue);
      finishPlay(1);
      await latest;
      expect(backend.isPlaying, isTrue);
      expect(backend.isBuffering, isFalse);
    } finally {
      await sub.cancel();
    }
  });

  test('a newer source stops an earlier Play during subtitle setup', () async {
    await backend.stop();
    deferVideoPlay();
    final oldPlay = backend.play({'url': mediaUrl});
    final latest = backend.play({'url': mediaUrl, 'autoPlay': false});
    await Future.wait([oldPlay, latest]);
    expect(pendingPlayCount(), 0);
  });

  test('Pause ignores a late successful Resume', () async {
    await backend.stop();
    deferVideoPlay();
    final pending = backend.resume();
    await _until(() => pendingPlayCount() == 1);
    await backend.pause();
    finishPlay(0);
    await pending;
    expect(backend.isPlaying, isFalse);
  });

  test('primary delay applies to both tracks without accumulating', () async {
    await backend.setSubtitleDelay(2);
    await backend.setSubtitleTrack(
      1, isExternalSubtitle: true,
      externalSubtitleUrl: subtitle('WEBVTT\n\n00:01.000 --> 00:03.000\nPrimary\n'),
    );
    final primary = video.querySelector('track')! as web.HTMLTrackElement;
    await _until(() => primary.track.cues?.length == 1);
    final cue = primary.track.cues![0];
    await _until(() => cue.startTime == 3);
    await backend.setSecondarySubtitleDelay(0.5);
    await backend.setSecondarySubtitle(
      url: subtitle('WEBVTT\n\n00:01.000 --> 00:03.000\nSecond\n'),
    );
    final second = (await loadedSecondary()).track.cues![0];
    expect(second.startTime, 3.5);

    await backend.setSubtitleDelay(-0.5);
    expect(cue.startTime, 0.5);
    expect(second.startTime, 1);
    await backend.disableSubtitleTrack();
    await backend.setSubtitleTrack(1);
    await backend.setSubtitleDelay(0);
    expect(cue.startTime, 1);
    expect(cue.endTime, 3);
    expect(second.startTime, 1.5);
  });

  test('web delay survives a same-session reload and resets for new playback', () async {
    Future<void> open(int? session, {int secondaryDelayMs = 0}) => backend.play({
      'url': mediaUrl,
      'autoPlay': false,
      'subtitleDelaySessionId': session,
      'secondarySubtitleDelayMs': secondaryDelayMs,
      'secondarySubtitleUrl': subtitle('WEBVTT\n\n00:01.000 --> 00:03.000\nSecond\n'),
    });
    await open(1);
    await backend.setSubtitleDelay(1.25);
    await backend.setSecondarySubtitleDelay(0.5);
    await backend.stop();
    await open(1, secondaryDelayMs: 500);
    expect(backend.subtitleDelaySeconds, 1.25);
    expect((await loadedSecondary()).track.cues![0].startTime, 2.75);
    await open(2);
    expect(backend.subtitleDelaySeconds, 0);
    expect((await loadedSecondary()).track.cues![0].startTime, 1);
    await backend.setSubtitleDelay(-0.5);
    await open(null);
    expect(backend.subtitleDelaySeconds, 0);
  });

  test('reselecting a detached primary applies its current delay', () async {
    final first = subtitle('WEBVTT\n\n00:01.000 --> 00:03.000\nFirst\n');
    final other = subtitle('WEBVTT\n\n00:01.000 --> 00:03.000\nOther\n');
    await backend.setSubtitleDelay(3);
    await backend.setSubtitleTrack(1,
        isExternalSubtitle: true, externalSubtitleUrl: first);
    final primary = video.querySelector('track')! as web.HTMLTrackElement;
    await _until(() => primary.track.cues?.length == 1);
    await _until(() => primary.track.cues![0].startTime == 4);
    await backend.setSubtitleTrack(2,
        isExternalSubtitle: true, externalSubtitleUrl: other);
    await backend.setSubtitleDelay(0);
    await backend.seekTo(const Duration(seconds: 2));
    await backend.setSubtitleTrack(1);
    expect(primary.track.cues![0].startTime, 1);
    expect(primary.track.cues![0].endTime, 3);
    await _until(() => primary.track.activeCues?.length == 1);
  });


  // These bounds follow the browser's native percentage-line semantics. Checking
  // lineAlign alone used to pass in Chrome even though it ignored that property.
  ({double top, double bottom}) bounds(web.VTTCue cue, {double font = 36}) {
    final measure = web.HTMLDivElement()
      ..style.cssText = 'position:fixed;visibility:hidden;white-space:pre-line;'
          'overflow-wrap:break-word;width:${1280 * cue.size / 100}px;'
          'font:400 ${font}px/1.2 sans-serif;';
    measure.appendChild(cue.getCueAsHTML());
    web.document.body!.appendChild(measure);
    final height = measure.getBoundingClientRect().height / 720;
    measure.remove();
    final line = (cue.line.dartify() as num).toDouble() / 100;
    final native = web.VTTCue(0, 1, '').has('lineAlign');
    final top = native ? line - switch (cue.lineAlign) {
      'end' => height, 'center' => height / 2, _ => 0,
    } : line * (1 - height);
    return (top: top, bottom: top + height);
  }

  test('native browser lines leave a gap around top and middle captions', () async {
    await backend.setSubtitleTrack(
      1, isExternalSubtitle: true,
      externalSubtitleUrl: subtitle(
        'WEBVTT\n\n00:01.000 --> 00:03.000\n{\\an7}Top left\n'
        '\n00:04.000 --> 00:06.000\n{\\an5}Middle\n',
      ),
    );
    await backend.setSecondarySubtitle(
      url: subtitle('WEBVTT\n\n00:01.000 --> 00:08.000\nSecond\n'),
    );
    final cue = (await loadedSecondary()).track.cues![0] as web.VTTCue;
    await backend.seekTo(const Duration(seconds: 2));
    await _until(() => cue.align == 'left');
    final top = bounds(cue).top;
    await backend.configureSecondarySubtitleStyle(verticalOffset: 0.02);
    expect(bounds(cue).top, closeTo(top + 0.02, 0.001));
    await backend.configureSecondarySubtitleStyle(verticalOffset: -0.02);
    expect(bounds(cue).top, closeTo(top - 0.013, 0.001));
    await backend.configureSecondarySubtitleStyle(verticalOffset: 0);

    await backend.seekTo(const Duration(seconds: 5));
    await _until(() => cue.align == 'center');
    final primary = video.querySelector('track')! as web.HTMLTrackElement;
    final centre = primary.track.cues![1] as web.VTTCue;
    expect(bounds(centre).top, closeTo(0.5075, 0.001));
    expect(bounds(cue).bottom, closeTo(0.4925, 0.001));
    // Unsupported native properties must stay absent, rather than becoming fields
    // that look supported to later capability checks.
    expect(cue.has('lineAlign'), web.VTTCue(0, 1, '').has('lineAlign'));
    await backend.configureSecondarySubtitleStyle(verticalOffset: 0.02);
    expect(bounds(centre).top - bounds(cue).bottom, closeTo(0.035, 0.001));
    await backend.configureSecondarySubtitleStyle(verticalOffset: -0.02);
    expect(bounds(centre).top - bounds(cue).bottom, closeTo(0.002, 0.001));
    await backend.configureSecondarySubtitleStyle(fontSize: 40, verticalOffset: 0);
    expect(bounds(centre).top, closeTo(0.5075, 0.001));
    expect(bounds(cue, font: 72).bottom, closeTo(0.4925, 0.001));
    await backend.setSecondarySubtitle();
    expect((bounds(centre).top + bounds(centre).bottom) / 2, closeTo(0.5, 0.001));
  });

  test('authored top remains top when offset crosses middle boundary', () async {
    await backend.setSubtitleTrack(
      1, isExternalSubtitle: true,
      externalSubtitleUrl: subtitle(
        'WEBVTT\n\n00:01.000 --> 00:08.000 line:30% '
        'position:30% align:left\nPrimary\n',
      ),
    );
    await backend.setSecondarySubtitle(
      url: subtitle('WEBVTT\n\n00:01.000 --> 00:08.000\nSecondary\n'),
    );
    final second = (await loadedSecondary()).track.cues![0] as web.VTTCue;
    final primary = video.querySelector('track')! as web.HTMLTrackElement;
    await backend.seekTo(const Duration(seconds: 2));
    await _until(() => second.align == 'left');
    final cue = primary.track.cues![0] as web.VTTCue;
    final originalTop = bounds(cue).top;
    final originalSecondary = bounds(second).top;
    expect(bounds(second).top, greaterThan(bounds(cue).bottom));
    await backend.configureSubtitleStyle(verticalOffset: 0.04);
    expect(bounds(cue).top, closeTo(originalTop + 0.04, 0.001));
    expect(bounds(second).top, closeTo(originalSecondary + 0.04, 0.001));
    expect(bounds(second).top, greaterThan(bounds(cue).bottom));
    await backend.configureSubtitleStyle(verticalOffset: 0);
    expect(bounds(cue).top, closeTo(originalTop, 0.001));
    expect(bounds(second).top, closeTo(originalSecondary, 0.001));
    expect(cue.has('moonfinStackedMiddleLine'), isFalse);
  });

  test('Primary Off keeps the normal offset and saves secondary spacing', () async {
    await backend.configureSubtitleStyle(verticalOffset: 0.12);
    await backend.setSubtitleTrack(
      1, isExternalSubtitle: true,
      externalSubtitleUrl: subtitle('WEBVTT\n\n00:01.000 --> 00:03.000\n{\\an7}Top primary\n'),
    );
    await backend.setSecondarySubtitle(
      url: subtitle('WEBVTT\n\n00:01.000 --> 00:09.000\nSecondary\n'),
    );
    final second = (await loadedSecondary()).track.cues![0] as web.VTTCue;
    final primary = video.querySelector('track')! as web.HTMLTrackElement;
    await backend.seekTo(const Duration(seconds: 2));
    await _until(() => second.align == 'left');
    await backend.configureSecondarySubtitleStyle(verticalOffset: 0.04);
    final stackedTop = bounds(second).top;
    await backend.seekTo(const Duration(seconds: 4));
    await _until(() => primary.track.activeCues?.length == 0);
    expect(bounds(second).top, closeTo(stackedTop, 0.001));
    await backend.disableSubtitleTrack();
    expect(bounds(second).bottom, closeTo(0.88, 0.001));
    expect(second.position.dartify(), 50);
    await backend.configureSecondarySubtitleStyle(verticalOffset: 0.06);
    expect(bounds(second).bottom, closeTo(0.88, 0.001));
    await backend.setSubtitleTrack(1);
    await backend.seekTo(const Duration(seconds: 2));
    await _until(() => second.align == 'left');
    expect(bounds(second).top, closeTo(stackedTop + 0.02, 0.001));
  });

  test('overlay primaries reserve the top while Primary Off uses the bottom', () async {
    // Stub only the canvas renderers; exercise real browser track coordinates.
    final script = web.HTMLScriptElement()..text = '''
      window.JASSUB = class { destroy() {} setCurrentTime() {} };
      window.libpgs = { PgsRenderer: class { dispose() {} } };
    ''';
    web.document.head!.appendChild(script);
    script.remove();
    try {
      await backend.configureSubtitleStyle(verticalOffset: 0.12);
      await backend.setSecondarySubtitle(
        url: subtitle('WEBVTT\n\n00:01.000 --> 00:08.000\nSecond\n'),
      );
      final cue = (await loadedSecondary()).track.cues![0] as web.VTTCue;
      await backend.seekTo(const Duration(seconds: 2));
      for (final codec in ['ass', 'pgs']) {
        await backend.setSubtitleTrack(1, isExternalSubtitle: true,
            externalSubtitleUrl: subtitle('overlay'), subtitleCodec: codec);
        expect(bounds(cue).top, closeTo(0.12, 0.001));
        await backend.configureSecondarySubtitleStyle(verticalOffset: 0.06);
        expect(bounds(cue).top, closeTo(0.12, 0.001));
        await backend.disableSubtitleTrack();
        expect(bounds(cue).bottom, closeTo(0.88, 0.001));
      }
    } finally {
      web.window.delete('JASSUB'.toJS);
      web.window.delete('libpgs'.toJS);
    }
  });

  test('clearing or replacing a pending overlay prevents stale renderers', () async {
    final script = web.HTMLScriptElement()..text = '''
      window.moonfinOverlayCreated = 0;
      window.moonfinOverlayUrl = '';
      window.JASSUB = class {
        constructor(options) {
          window.moonfinOverlayCreated++;
          window.moonfinOverlayUrl = options.subUrl;
        }
        destroy() {}
        setCurrentTime() {}
      };
      window.libpgs = { PgsRenderer: class {
        constructor(options) {
          window.moonfinOverlayCreated++;
          window.moonfinOverlayUrl = options.subUrl;
        }
        dispose() {}
      } };
    ''';
    web.document.head!.appendChild(script);
    script.remove();
    int created() => web.window
        .getProperty<JSNumber>('moonfinOverlayCreated'.toJS).toDartInt;
    try {
      for (final codec in ['ass', 'pgs']) {
        final pending = backend.setSubtitleTrack(
          1, isExternalSubtitle: true,
          externalSubtitleUrl: 'https://example.com/old.$codec',
          subtitleCodec: codec,
        );
        await backend.disableSubtitleTrack();
        await pending;
      }
      expect(created(), 0);

      final stale = backend.setSubtitleTrack(
        1, isExternalSubtitle: true,
        externalSubtitleUrl: 'https://example.com/stale.ass',
        subtitleCodec: 'ass',
      );
      final current = backend.setSubtitleTrack(
        1, isExternalSubtitle: true,
        externalSubtitleUrl: 'https://example.com/current.pgs',
        subtitleCodec: 'pgs',
      );
      await Future.wait([stale, current]);
      expect(created(), 1);
      expect(
        web.window.getProperty<JSString>('moonfinOverlayUrl'.toJS).toDart,
        'https://example.com/current.pgs',
      );
    } finally {
      await backend.disableSubtitleTrack();
      web.window.delete('JASSUB'.toJS);
      web.window.delete('libpgs'.toJS);
      web.window.delete('moonfinOverlayCreated'.toJS);
      web.window.delete('moonfinOverlayUrl'.toJS);
    }
  });

  test('multiline cues and larger secondary text grow away from the gap', () async {
    await backend.configureSubtitleStyle(verticalOffset: 0.04);
    await backend.setSubtitleTrack(
      1, isExternalSubtitle: true,
      externalSubtitleUrl: subtitle('WEBVTT\n\n00:01.000 --> 00:08.000\nOne\nTwo\nThree\n'),
    );
    await backend.setSecondarySubtitle(
      url: subtitle('WEBVTT\n\n00:01.000 --> 00:08.000\nFirst\nSecond\n'),
    );
    final second = (await loadedSecondary()).track.cues![0] as web.VTTCue;
    final primary = video.querySelector('track')! as web.HTMLTrackElement;
    await backend.seekTo(const Duration(seconds: 2));
    await _until(() => primary.track.activeCues?.length == 1);
    await backend.configureSecondarySubtitleStyle(fontSize: 40);
    final cue = primary.track.cues![0] as web.VTTCue;
    expect(bounds(cue).bottom, closeTo(0.96, 0.001));
    expect(bounds(cue).top - bounds(second, font: 72).bottom, closeTo(0.015, 0.001));
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


  test('secondary WebVTT retains italic, bold and underline markup', () async {
    await backend.setSecondarySubtitle(
      url: subtitle('WEBVTT\n\n00:01.000 --> 00:03.000\n'
          '<i>italic</i> <b>bold</b> <u>underline</u>\n'),
    );
    final track = await loadedSecondary();
    final cue = track.track.cues![0] as web.VTTCue;
    final html = cue.getCueAsHTML();
    expect(html.querySelector('i')?.textContent, 'italic');
    expect(html.querySelector('b')?.textContent, 'bold');
    expect(html.querySelector('u')?.textContent, 'underline');
  });


}
