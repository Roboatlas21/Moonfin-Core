import 'dart:async';

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

  test('native season picker returns choices and preserves cancellation', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    Object? reply = {
      'requestId': 42,
      'allSeasons': false,
      'seasons': [5],
    };
    messenger.setMockMethodCallHandler(control, (call) async {
      calls.add(call);
      return call.method == 'showCinemaRequestOptions' ? reply : null;
    });
    expect(
      await backend.showCinemaRequestOptions({
        'requestId': 42,
        'seasons': [2, 5],
        'selected': [5],
      }),
      reply,
    );
    reply = null;
    expect(
      await backend.showCinemaRequestOptions({
        'requestId': 43,
        'seasons': [2, 5],
      }),
      isNull,
    );
    await backend.dismissCinemaRequestOptions(requestId: 42);
    expect(calls.last.method, 'dismissCinemaRequestOptions');
    expect(calls.last.arguments, {'requestId': 42});
  });

  test('TV picker can return All Seasons with no advanced overrides', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(control, (call) async {
      calls.add(call);
      if (call.method == 'showCinemaRequestOptions') {
        return {
          'requestId': 42,
          'allSeasons': true,
          'seasons': <int>[],
        };
      }
      return null;
    });
    final answer = await backend.showCinemaRequestOptions({
      'requestId': 42,
      'seasons': [2, 5],
      'selected': <int>[],
      'allLabel': 'All Seasons',
    });
    expect(answer, {
      'requestId': 42,
      'allSeasons': true,
      'seasons': <int>[],
    });
    final payload = calls.single.arguments as Map;
    expect(payload.containsKey('servers'), false);
    expect(payload.containsKey('profiles'), false);
    expect(payload.containsKey('optionsLoading'), false);
    expect(payload.containsKey('advancedEnabled'), false);
  });

  test('quota update does not block a pending TV picker', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final completed = Completer<Map<String, dynamic>?>();
    messenger.setMockMethodCallHandler(control, (call) async {
      calls.add(call);
      if (call.method == 'showCinemaRequestOptions') {
        return completed.future;
      }
      if (call.method == 'updateCinemaRequestQuota') {
        return true;
      }
      return null;
    });

    final picker = backend.showCinemaRequestOptions({
      'requestId': 123,
      'seasons': [2, 5],
    });
    final updated = await backend.updateCinemaRequestQuota({
      'requestId': 123,
      'quotaLabel': '1 of 3 season requests remaining',
      'quotaRemaining': 1,
      'quotaRestricted': false,
    });
    expect(updated, isTrue);
    expect(calls.map((call) => call.method), [
      'showCinemaRequestOptions',
      'updateCinemaRequestQuota',
    ]);
    final payload = calls.first.arguments as Map;
    expect(payload.containsKey('serverLabel'), false);
    expect(payload.containsKey('optionsLoading'), false);

    completed.complete({
      'requestId': 123,
      'allSeasons': false,
      'seasons': [5],
    });
    expect((await picker)?['seasons'], [5]);
    await backend.dismissCinemaRequestOptions(requestId: 123);
    expect(calls.last.arguments, {'requestId': 123});
  });

  test('unsupported native quota update is optional', () async {
    expect(
      await backend.updateCinemaRequestQuota({
        'requestId': 123,
        'quotaRemaining': 1,
      }),
      isFalse,
    );
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
