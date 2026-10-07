import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:moonfin/playback/appletv_backend.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const control = MethodChannel('moonfin/appletv_video_control');
  const events = MethodChannel('moonfin/appletv_video_events');
  final calls = <MethodCall>[];
  late AppleTvBackend backend;

  setUp(() async {
    calls.clear();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(control, (call) async {
      calls.add(call);
      return null;
    });
    messenger.setMockMethodCallHandler(events, (_) async => null);
    SharedPreferences.setMockInitialValues({});
    final store = PreferenceStore();
    await store.init();
    backend = AppleTvBackend(UserPreferences(store));
  });

  tearDown(() => backend.dispose());

  test('native request picker returns options and preserves cancellation', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    Object? reply = {
      'seasons': [2, 5],
      'serverId': 1,
      'profileId': 11,
      'rootFolderId': 101,
    };
    messenger.setMockMethodCallHandler(control, (call) async {
      calls.add(call);
      return call.method == 'showCinemaRequestOptions' ? reply : null;
    });
    expect(
      await backend.showCinemaRequestOptions({
        'seasons': [2, 5],
      }),
      {
        'seasons': [2, 5],
        'serverId': 1,
        'profileId': 11,
        'rootFolderId': 101,
      },
    );
    reply = null;
    expect(
      await backend.showCinemaRequestOptions({
        'seasons': [2, 5],
      }),
      isNull,
    );
    await backend.dismissCinemaRequestOptions();
    expect(calls.last.method, 'dismissCinemaRequestOptions');
  });

  test('tvOS bridge preserves quota and All Seasons request semantics', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(control, (call) async {
      calls.add(call);
      return call.method == 'showCinemaRequestOptions'
          ? {'allSeasons': true, 'seasons': <int>[]}
          : null;
    });

    final result = await backend.showCinemaRequestOptions({
      'seasons': [2, 5],
      'quotaLabel': '1 of 3 seasons remaining',
      'quotaRemaining': 1,
      'quotaRestricted': false,
      'quotaBlockedLabel': 'Quota exceeded',
    });
    expect(result, {'allSeasons': true, 'seasons': <int>[]});
    final args = calls.last.arguments as Map;
    expect(args['quotaRemaining'], 1);
    expect(args['quotaRestricted'], false);
    expect(args['quotaLabel'], '1 of 3 seasons remaining');
    expect(args['quotaBlockedLabel'], 'Quota exceeded');
  });

  test(
    'native cinema input retains the generation that owned the press',
    () async {
      final action = backend.uiActionStream.first;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      await messenger.handlePlatformMessage(
        'moonfin/appletv_video_events',
        const StandardMethodCodec().encodeSuccessEnvelope({
          'event': 'cinemaAction',
          'action': 'select',
          'generation': 7,
        }),
        (_) {},
      );
      expect(await action, {
        'event': 'cinemaAction',
        'action': 'select',
        'generation': 7,
      });
    },
  );

  test('the session navigation bridge preserves each command', () async {
    for (final command in [
      'moveup',
      'movedown',
      'moveleft',
      'moveright',
      'select',
      'back',
    ]) {
      await backend.sendRemoteNavigation(command);
      expect(calls.last.method, 'remoteNavigation');
      expect(calls.last.arguments, {'command': command});
    }
  });

  test(
    'volume keeps percent units and persists into the next source',
    () async {
      await backend.setVolume(1);
      expect(calls.last.method, 'setVolume');
      expect(calls.last.arguments, {'volume': 1.0});
      await backend.play({
        'url': 'https://example.com/video',
        'mediaType': 'video',
      });
      final source = calls.lastWhere((call) => call.method == 'setSource');
      expect(source.arguments['volume'], 1.0);
    },
  );

  test(
    'native volume failure propagates and does not replace the stored level',
    () async {
      await backend.setVolume(40);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(control, (call) async {
            calls.add(call);
            if (call.method == 'setVolume') {
              throw PlatformException(code: 'no_player');
            }
            return null;
          });
      await expectLater(
        backend.setVolume(5),
        throwsA(isA<PlatformException>()),
      );
      await backend.play({
        'url': 'https://example.com/video',
        'mediaType': 'video',
      });
      expect(
        calls
            .lastWhere((call) => call.method == 'setSource')
            .arguments['volume'],
        40,
      );
    },
  );

  test(
    'audio-only playback does not claim the visible native player',
    () async {
      expect(backend.isPlayerPresented, isFalse);
      await backend.play({
        'url': 'https://example.com/audio',
        'mediaType': 'audio',
      });
      expect(backend.isPlayerPresented, isFalse);
      await backend.dismissPlayer();
      await backend.play({
        'url': 'https://example.com/video',
        'mediaType': 'video',
      });
      expect(backend.isPlayerPresented, isTrue);
      await backend.dismissPlayer();
      expect(backend.isPlayerPresented, isFalse);
    },
  );
}
