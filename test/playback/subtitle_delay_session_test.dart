import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/playback/media3_player_backend.dart';
import '../util/media_segment_fakes.dart' show testPrefs;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('media3 preserves subtitle delay until a new viewing session', () async {
    final prefs = await testPrefs();
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const control = MethodChannel('moonfin/media3_video_control');
    const events = MethodChannel('moonfin/media3_video_events');
    messenger.setMockMethodCallHandler(control, (call) async {
      calls.add(call);
      return null;
    });
    messenger.setMockMethodCallHandler(events, (_) async => null);
    final backend = Media3PlayerBackend(prefs);
    addTearDown(() {
      backend.dispose();
      prefs.dispose();
      messenger.setMockMethodCallHandler(control, null);
      messenger.setMockMethodCallHandler(events, null);
    });

    Future<void> open(int? session, {String url = 'https://server/video'}) =>
        backend.play({
          'url': url,
          'subtitleDelaySessionId': session,
          'secondarySubtitleTrackId': 3,
        });
    Map source() =>
        calls.lastWhere((call) => call.method == 'setSource').arguments as Map;

    await open(1);
    expect(source()['secondarySubtitleTrackId'], 3);
    await backend.setSubtitleDelay(1.25);
    await backend.disableSubtitleTrack();
    await backend.setSecondarySubtitle(embeddedTrackId: 2);
    expect(calls.last.arguments['embeddedTrackId'], 2);
    await backend.setSecondarySubtitle();
    expect(calls.last.arguments['embeddedTrackId'], isNull);
    expect(backend.subtitleDelaySeconds, 1.25);

    for (final (session, expected) in [(1, 1.25), (2, 0.0), (null, 0.0)]) {
      await backend.setSubtitleDelay(1.25);
      await backend.stop();
      await open(session, url: 'https://server/new-transcode');
      expect(source()['subtitleDelayMs'], (expected * 1000).round());
      expect(backend.subtitleDelaySeconds, expected);
    }
  });
}
