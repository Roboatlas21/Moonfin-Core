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

      test('exposes each shared secondary control', () {
        expect(backend, isA<SecondarySubtitleBackend>());
        expect(
          (backend as SecondarySubtitleBackend).supportsSecondarySubtitleDelay,
          isTrue,
        );
        expect(
          (backend as SecondarySubtitleBackend)
              .supportsSecondarySubtitlePosition,
          isTrue,
        );
        expect(
          (backend as SecondarySubtitleBackend).supportsSecondarySubtitleStyle,
          isTrue,
        );
      });

      test(
        'startup keeps the native ordinal, fallback and appearance together',
        () async {
          final secondary = <String, dynamic>{
            'secondarySubtitleTrackId': 3,
            'secondarySubtitleUrl': 'https://server/subtitle.srt',
            'secondarySubtitleCodec': 'subrip',
            'secondarySubtitleDelayMs': 750,
            'secondarySubtitleOffset': 0.12,
            'secondarySubtitleFontSize': 28.0,
            'secondarySubtitleTextColor': 0xFFFFFF00,
          };
          await backend.play({
            'url': 'https://server/episode.mkv',
            ...secondary,
          });
          final source = calls.lastWhere((call) => call.method == 'setSource');
          for (final entry in secondary.entries) {
            expect(source.arguments[entry.key], entry.value, reason: entry.key);
          }

          await backend.play({'url': 'https://server/next.mkv'});
          final next = calls.lastWhere((call) => call.method == 'setSource');
          expect(next.arguments['secondarySubtitleTrackId'], isNull);
          expect(next.arguments['secondarySubtitleUrl'], isNull);
          expect(next.arguments['secondarySubtitleDelayMs'], 0);
          expect(next.arguments['secondarySubtitleOffset'], 0.08);
          expect(next.arguments['secondarySubtitleFontSize'], isNull);
          expect(next.arguments['secondarySubtitleTextColor'], isNull);
        },
      );

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

      test(
        'secondary delay and appearance use independent bounded controls',
        () async {
          await backend.setSecondarySubtitleDelay(-1.25);
          expect(calls.last.method, 'setSecondarySubtitleDelay');
          expect(calls.last.arguments['delayMs'], -1250);
          await backend.setSecondarySubtitleDelay(12);
          expect(calls.last.arguments['delayMs'], 5000);
          await backend.configureSecondarySubtitleStyle(
            fontSize: 100,
            verticalOffset: -0.2,
            textColor: 0xFF00FF00,
          );
          expect(calls.last.method, 'configureSecondarySubtitleStyle');
          expect(calls.last.arguments, {
            'fontSize': 72.0,
            'verticalOffset': 0.0,
            'textColor': 0xFF00FF00,
          });
          await backend.configureSecondarySubtitleStyle(verticalOffset: 0.2);
          expect(calls.last.arguments, {'verticalOffset': 0.2});
        },
      );
    });
  }
}
