import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:moonfin/playback/aether_backend.dart';
import 'package:moonfin/playback/appletv_backend.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:playback_core/playback_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final tv in [false, true]) {
    group(tv ? 'tvOS secondary subtitles' : 'Aether secondary subtitles', () {
      final prefix = tv ? 'appletv_video' : 'ios_aether';
      final control = MethodChannel('moonfin/${prefix}_control');
      final events = MethodChannel('moonfin/${prefix}_events');
      late PlayerBackend backend;
      final calls = <MethodCall>[];

      setUp(() async {
        calls.clear();
        SharedPreferences.setMockInitialValues({});
        final store = PreferenceStore();
        await store.init();
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(control, (call) async {
          calls.add(call);
          return null;
        });
        messenger.setMockMethodCallHandler(events, (_) async => null);
        backend = tv
            ? AppleTvBackend(UserPreferences(store))
            : AetherBackend(UserPreferences(store));
      });

      tearDown(() {
        backend.dispose();
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(control, null);
        messenger.setMockMethodCallHandler(events, null);
      });


      test('secondary selection is sent before tracks arrive and clears explicitly', () async {
        await backend.setSecondarySubtitle(embeddedTrackId: 2, codec: 'srt');
        expect(calls.last.method, 'setSecondarySubtitle');
        expect(calls.last.arguments['embeddedTrackId'], 2);
        await backend.disableSubtitleTrack();
        expect(calls.last.method, 'disableSubtitleTrack');
        expect(
          calls.where((call) => call.method == 'setSecondarySubtitle'),
          hasLength(1),
        );

        await backend.setSecondarySubtitle(
          url: '/downloads/french.vtt',
          codec: 'vtt',
        );
        expect(calls.last.arguments['url'], '/downloads/french.vtt');
        expect(calls.last.arguments['embeddedTrackId'], isNull);
        await backend.setSecondarySubtitle();
        expect(calls.last.method, 'setSecondarySubtitle');
        expect(calls.last.arguments['url'], isNull);
        expect(calls.last.arguments['embeddedTrackId'], isNull);
      });

    });
  }
}
