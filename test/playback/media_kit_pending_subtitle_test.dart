import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:media_kit/media_kit.dart';
import 'package:moonfin/playback/media_kit_player_backend.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Native extends Fake implements NativePlayer {
  List<Map<String, dynamic>> tracks = [];
  final properties = <String, String>{'sid': 'no'};
  Completer<String>? delayedTracks;
  Completer<void>? delayedSubtitleLoad;
  final commands = <List<String>>[];
  int rejectedSecondarySelections = 0;

  @override
  Future<void> command(
    List<String> args, {
    bool waitForInitialization = true,
  }) async {
    commands.add(args);
    if (args.first == 'sub-add') {
      await delayedSubtitleLoad?.future;
      tracks.add({
        'type': 'sub',
        'id': 52,
        'codec': 'subrip',
        'external': true,
        'external-filename': args[1],
      });
    }
  }

  @override
  Future<String> getProperty(
    String property, {
    bool waitForInitialization = true,
  }) async {
    if (property == 'track-list') {
      return delayedTracks == null ? jsonEncode(tracks) : delayedTracks!.future;
    }
    return properties[property] ?? '';
  }

  @override
  Future<void> setProperty(
    String property,
    String value, {
    bool waitForInitialization = true,
  }) async {
    if (int.tryParse(value) != null) {
      if (property == 'secondary-sid' && properties['sid'] == value) {
        rejectedSecondarySelections++;
        return;
      }
      if (property == 'sid' && properties['secondary-sid'] == value) return;
    }
    properties[property] = value;
  }
}

class _Streams extends Fake implements PlayerStream {
  final changes = StreamController<Tracks>.broadcast();
  @override
  Stream<Tracks> get tracks => changes.stream;
  @override
  Stream<VideoParams> get videoParams => const Stream.empty();
  @override
  Stream<Duration> get position => const Stream.empty();
}

class _Player extends Fake implements Player {
  @override
  final _Native platform = _Native();
  @override
  final _Streams stream = _Streams();
  @override
  PlayerState get state => const PlayerState();
  final selections = <String>[];
  final opened = <String>[];
  String? automaticSubtitleSid;
  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {
    selections.add(track.id);
    await platform.setProperty('sid', track.id);
  }

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    opened.add((playable as Media).uri);
    if (platform.properties['sid'] == 'auto' && automaticSubtitleSid != null) {
      platform.properties['sid'] = automaticSubtitleSid!;
    }
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {
    await stream.changes.close();
  }

  void discover() {
    platform.tracks = [
      {'type': 'sub', 'id': 3, 'codec': 'eia_608'},
      {'type': 'sub', 'id': 8, 'codec': 'subrip', 'external': true},
      {'type': 'sub', 'id': 11, 'codec': 'subrip'},
      {'type': 'sub', 'id': 17, 'codec': 'subrip'},
    ];
    stream.changes.add(const Tracks());
  }
}

Future<void> _flush() async {
  for (var n = 0; n < 5; n++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Player player;
  late UserPreferences prefs;
  late MediaKitPlayerBackend backend;
  bool disposed = false;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final store = PreferenceStore();
    await store.init();
    prefs = UserPreferences(store);
    player = _Player();
    backend = MediaKitPlayerBackend.forTesting(player, prefs);
    disposed = false;
  });
  tearDown(() {
    if (!disposed) backend.dispose();
    prefs.dispose();
  });

  test(
    'secondary embedded track uses its real sid and survives primary changes',
    () async {
      player.discover();
      await backend.setSubtitleTrack(1);
      await backend.setSecondarySubtitle(embeddedTrackId: 2);
      expect(player.platform.properties['sid'], '11');
      expect(player.platform.properties['secondary-sid'], '17');
      await backend.setSubtitleTrack(1);
      await backend.disableSubtitleTrack();
      expect(player.platform.properties['secondary-sid'], '17');
      expect(player.platform.properties['secondary-sub-visibility'], 'yes');
      await backend.setSubtitleTrack(1);
      await backend.setSecondarySubtitle();
      expect(player.platform.properties['sid'], '11');
      expect(player.platform.properties['secondary-sid'], 'no');
    },
  );

  test(
    'secondary selection waits for discovery and off cancels a pending read',
    () async {
      await backend.setSecondarySubtitle(embeddedTrackId: 2);
      player.discover();
      await _flush();
      expect(player.platform.properties['secondary-sid'], '17');
      final read = Completer<String>();
      player.platform.delayedTracks = read;
      final selection = backend.setSecondarySubtitle(embeddedTrackId: 1);
      await _flush();
      await backend.setSecondarySubtitle();
      read.complete(jsonEncode(player.platform.tracks));
      await selection;
      expect(player.platform.properties['secondary-sid'], 'no');
    },
  );

  test(
    'restores secondary selection on open and resets it on the next source',
    () async {
      player.discover();
      await backend.play({
        'url': 'https://example.com/video.mkv',
        'autoPlay': false,
        'secondarySubtitleTrackId': 2,
      });
      expect(player.platform.properties['secondary-sid'], '17');
      await backend.play({
        'url': 'https://example.com/next.mkv',
        'autoPlay': false,
      });
      expect(player.platform.properties['secondary-sid'], 'no');
    },
  );

  for (final primary in ['Japanese', 'Off']) {
    test(
      'restores default English secondary after primary becomes $primary',
      () async {
        player.discover();
        player.automaticSubtitleSid = '17';
        await backend.play({
          'url': 'https://example.com/video.mkv',
          'autoPlay': false,
          'secondarySubtitleTrackId': 2,
        });
        expect(player.platform.properties['sid'], '17');
        expect(player.platform.properties['secondary-sid'], 'no');
        expect(player.platform.rejectedSecondarySelections, greaterThan(0));

        // The manager applies its primary selection after backend.play returns.
        if (primary == 'Off') {
          await backend.disableSubtitleTrack();
        } else {
          await backend.setSubtitleTrack(1);
        }
        expect(player.platform.properties['sid'], primary == 'Off' ? 'no' : '11');
        expect(player.platform.properties['secondary-sid'], '17');
        expect(player.platform.properties['secondary-sub-visibility'], 'yes');
      },
    );
  }

  test(
    'secondary Off cancels a selection rejected by the automatic primary',
    () async {
      player.discover();
      player.platform.properties['sid'] = '17';
      await backend.setSecondarySubtitle(embeddedTrackId: 2);
      expect(player.platform.rejectedSecondarySelections, greaterThan(0));
      await backend.setSecondarySubtitle();
      await backend.setSubtitleTrack(1);
      expect(player.platform.properties['secondary-sid'], 'no');
    },
  );

  test('external secondary uses sub-add auto without changing primary or adding duplicates', () async {
    const url = '/downloads/secondary.srt';
    player.discover();
    await backend.setSubtitleTrack(1);
    await backend.setSecondarySubtitle(url: url, codec: 'srt');
    await _flush();
    expect(player.platform.properties['sid'], '11');
    expect(player.platform.properties['secondary-sid'], '52');
    expect(player.platform.commands.single.take(3), ['sub-add', url, 'auto']);
    await backend.addExternalSubtitle(url);
    await backend.setSecondarySubtitle(url: url);
    expect(player.platform.commands, hasLength(1));
  });

  for (final action in ['off', 'stop', 'source', 'choice', 'dispose']) {
    test(
      '$action prevents a late external load from selecting the secondary track',
      () async {
        player.discover();
        final load = Completer<void>();
        player.platform.delayedSubtitleLoad = load;
        await backend.setSecondarySubtitle(url: '/downloads/secondary.srt');
        await _flush();
        switch (action) {
          case 'off':
            await backend.setSecondarySubtitle();
          case 'stop':
            await backend.stop();
          case 'source':
            await backend.play({
              'url': 'https://example.com/next.mkv',
              'autoPlay': false,
            });
          case 'choice':
            await backend.setSecondarySubtitle(embeddedTrackId: 2);
          case 'dispose':
            backend.dispose();
            disposed = true;
        }
        load.complete();
        await _flush();
        expect(
          player.platform.properties['secondary-sid'],
          action == 'choice' ? '17' : 'no',
        );
      },
    );
  }

  test(
    'older mpv exposes selection without unsupported delay or style controls',
    () async {
      await backend.setSecondarySubtitleDelay(1);
      await backend.configureSecondarySubtitleStyle(
        verticalOffset: 0.2,
        fontSize: 30,
        textColor: 0xFFFFFF00,
      );
      expect(backend.supportsSecondarySubtitleDelay, isFalse);
      expect(backend.supportsSecondarySubtitlePosition, isFalse);
      expect(backend.supportsSecondarySubtitleStyle, isFalse);
      expect(
        player.platform.properties.containsKey('secondary-sub-delay'),
        isFalse,
      );
      expect(player.platform.properties.containsKey('sub-font-size'), isFalse);
    },
  );

  test('mpv centres a middle pair and restores the original primary position', () async {
    final other = _Player();
    other.platform.properties.addAll({
      'secondary-sub-delay': '0',
      'secondary-sub-pos': '0',
      'sub-pos': '100',
      'sub-text/ass': r'{\an5}Middle',
      'secondary-sub-text': 'Other language',
    });
    final second = MediaKitPlayerBackend.forTesting(other, prefs);
    try {
      other.discover();
      await second.setSecondarySubtitle(embeddedTrackId: 1);
      await second.configureSecondarySubtitleStyle(verticalOffset: 0);
      expect(other.platform.properties['secondary-sub-pos'], '44');
      expect(other.platform.properties['sub-pos'], '104');

      await second.configureSecondarySubtitleStyle(verticalOffset: 0.02);
      expect(other.platform.properties['secondary-sub-pos'], '43');
      expect(other.platform.properties['sub-pos'], '105');

      other.platform.properties['sub-text/ass'] = r'{\an2}Bottom';
      await second.configureSecondarySubtitleStyle(verticalOffset: 0);
      expect(other.platform.properties['sub-pos'], '100');

      other.platform.properties['sub-text/ass'] = r'{\an5}Middle';
      await second.configureSecondarySubtitleStyle(verticalOffset: 0);
      expect(other.platform.properties['sub-pos'], '104');
      other.platform.properties['secondary-sub-text'] = '';
      await second.configureSecondarySubtitleStyle(verticalOffset: 0);
      expect(other.platform.properties['sub-pos'], '100');
      other.platform.properties['secondary-sub-text'] = 'Other language';
      await second.configureSecondarySubtitleStyle(verticalOffset: 0);
      expect(other.platform.properties['sub-pos'], '104');
      await second.setSecondarySubtitle();
      expect(other.platform.properties['sub-pos'], '100');
    } finally {
      second.dispose();
    }
  });

  test('secondary mpv vertical placement follows top-aligned SRT', () async {
    final other = _Player();
    other.platform.properties.addAll({
      'secondary-sub-delay': '0', 'secondary-sub-pos': '0',
      'sub-text/ass': r'{\an8}Top text', 'secondary-sub-text': 'Other',
    });
    final second = MediaKitPlayerBackend.forTesting(other, prefs);
    try {
      other.discover();
      await second.setSecondarySubtitle(embeddedTrackId: 1);
      await second.configureSecondarySubtitleStyle(verticalOffset: 0);
      expect(other.platform.properties['secondary-sub-pos'], '12');
    } finally {
      second.dispose();
    }
  });

  test('mpv adds secondary delay to the primary and positions independently', () async {
    final other = _Player();
    other.platform.properties.addAll({
      'secondary-sub-delay': '0',
      'secondary-sub-pos': '0',
      'sub-delay': '0.500',
      'sub-color': '#ffffffff',
    });
    final second = MediaKitPlayerBackend.forTesting(other, prefs);
    try {
      await second.setSecondarySubtitleDelay(1.25);
      other.discover();
      await second.setSecondarySubtitle(embeddedTrackId: 1);
      await second.configureSecondarySubtitleStyle(
        verticalOffset: -0.12,
        textColor: 0xFFFFFF00,
      );
      expect(second.supportsSecondarySubtitleDelay, isTrue);
      expect(second.supportsSecondarySubtitlePosition, isTrue);
      expect(other.platform.properties['secondary-sub-delay'], '1.750');
      expect(other.platform.properties['secondary-sub-pos'], '95');
      expect(other.platform.properties['sub-delay'], '0.500');
      expect(other.platform.properties['sub-color'], '#ffffffff');
      await second.setSubtitleDelay(-0.25);
      expect(other.platform.properties['secondary-sub-delay'], '1.000');
      await second.setSecondarySubtitleDelay(0);
      expect(other.platform.properties['secondary-sub-delay'], '-0.250');
    } finally {
      second.dispose();
    }
  });

  test('discovery selects the embedded ordinal once, excluding external and CC tracks', () async {
    await backend.setSubtitleTrack(2);
    player.discover();
    await _flush();
    expect(player.platform.properties['sid'], '17');
    player.discover();
    await _flush();
    expect(player.selections.where((id) => id == '17'), hasLength(1));
  });

  for (final action in ['off', 'stop', 'source', 'choice', 'dispose']) {
    test('$action cancels the pending Windows subtitle selection', () async {
      await backend.setSubtitleTrack(1);
      switch (action) {
        case 'off':
          await backend.disableSubtitleTrack();
        case 'stop':
          await backend.stop();
        case 'source':
          await backend.play({
            'url': 'https://example.com/next.mkv',
            'autoPlay': false,
          });
          expect(player.opened, hasLength(1));
        case 'choice':
          await backend.setSubtitleTrack(2);
        case 'dispose':
          backend.dispose();
          disposed = true;
      }
      player.selections.clear();
      if (disposed) return;
      player.discover();
      await _flush();
      expect(player.selections, action == 'choice' ? ['17'] : isEmpty);
    });
  }

  for (final action in ['off', 'stop', 'dispose', 'source', 'choice']) {
    test('$action cancels a discovery read already in flight', () async {
      await backend.setSubtitleTrack(1);
      final read = Completer<String>();
      player.platform.delayedTracks = read;
      player.discover();
      await _flush();
      Future<void>? replacement;
      switch (action) {
        case 'off':
          await backend.disableSubtitleTrack();
        case 'stop':
          await backend.stop();
        case 'dispose':
          backend.dispose();
          disposed = true;
        case 'source':
          await backend.play({
            'url': 'https://example.com/next.mkv',
            'autoPlay': false,
          });
        case 'choice':
          replacement = backend.setSubtitleTrack(2);
      }
      player.selections.clear();
      read.complete(jsonEncode(player.platform.tracks));
      await replacement;
      await _flush();
      expect(player.selections, action == 'choice' ? ['17'] : isEmpty);
    });
  }
}
