import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:moonfin/playback/aether_backend.dart';
import 'package:moonfin/playback/appletv_backend.dart';
import 'package:moonfin/playback/media3_player_backend.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:playback_core/playback_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final (name, create)
      in <(String, PlayerBackend Function(UserPreferences))>[
        ('media3_video', Media3PlayerBackend.new),
        ('ios_aether', AetherBackend.new),
        ('appletv_video', AppleTvBackend.new),
      ]) {
    test('$name preserves delay until a new viewing session', () async {
      SharedPreferences.setMockInitialValues({});
      final store = PreferenceStore();
      await store.init();
      final prefs = UserPreferences(store);
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final control = MethodChannel('moonfin/${name}_control');
      final events = MethodChannel('moonfin/${name}_events');
      messenger.setMockMethodCallHandler(control, (call) async {
        calls.add(call);
        return null;
      });
      messenger.setMockMethodCallHandler(events, (_) async => null);
      final backend = create(prefs);
      addTearDown(() {
        backend.dispose();
        prefs.dispose();
        messenger.setMockMethodCallHandler(control, null);
        messenger.setMockMethodCallHandler(events, null);
      });

      Future<void> open(int? session, {String url = 'https://server/video'}) =>
          backend.play({'url': url, 'subtitleDelaySessionId': session});
      int sourceDelay() =>
          (calls.lastWhere((c) => c.method == 'setSource').arguments
                  as Map)['subtitleDelayMs']
              as int;

      await open(1);
      await backend.setSubtitleDelay(1.25);
      await backend.disableSubtitleTrack();
      await backend.setSecondarySubtitle(embeddedTrackId: 2);
      await backend.pause();
      await backend.resume();
      expect(backend.subtitleDelaySeconds, 1.25);

      // Quality changes and background restoration can stop and reopen the player.
      await backend.stop();
      await open(1, url: 'https://server/new-transcode');
      expect(sourceDelay(), 1250);
      expect(backend.subtitleDelaySeconds, 1.25);

      await open(2);
      expect(sourceDelay(), 0);
      expect(backend.subtitleDelaySeconds, 0);
      await backend.setSubtitleDelay(-0.5);
      await open(null);
      expect(sourceDelay(), 0);
    });
  }
}
