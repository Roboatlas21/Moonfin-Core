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
  final properties = <String, String>{'sid': 'no', 'secondary-sub-delay': '0', 'secondary-sub-pos': '100'};
  Completer<String>? delayedTracks;
  Completer<String>? delayedSecondaryText;
  Completer<void>? secondaryTextReadStarted;
  final commands = <List<String>>[];
  int rejectedSecondarySelections = 0;

  @override
  Future<void> command(
    List<String> args, {
    bool waitForInitialization = true,
  }) async {
    commands.add(args);
    if (args.first == 'sub-add') {
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
    if (property == 'secondary-sub-text' && delayedSecondaryText != null) {
      if (secondaryTextReadStarted?.isCompleted == false) {
        secondaryTextReadStarted!.complete();
      }
      return delayedSecondaryText!.future;
    }
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
  _Player({PlatformPlayer? platform}) : platform = platform ?? _Native();
  @override
  final PlatformPlayer platform;
  _Native get native => platform as _Native;
  @override
  final _Streams stream = _Streams();
  @override
  PlayerState get state => const PlayerState();
  final selections = <String>[];
  final opened = <String>[];
  String? automaticSubtitleSid;

  @override
  Future<void> seek(Duration position) async {
    // mpv clears the old active subtitle when a seek lands.
    native.properties.remove('sub-text/ass');
  }
  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {
    selections.add(track.id);
    await native.setProperty('sid', track.id);
  }

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    opened.add((playable as Media).uri);
    if (platform is _Native && native.properties['sid'] == 'auto' && automaticSubtitleSid != null) {
      native.properties['sid'] = automaticSubtitleSid!;
    }
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {
    await stream.changes.close();
  }

  void discover() {
    native.tracks = [
      {'type': 'sub', 'id': 3, 'codec': 'eia_608'},
      {'type': 'sub', 'id': 8, 'codec': 'subrip', 'external': true},
      {'type': 'sub', 'id': 11, 'codec': 'subrip'},
      {'type': 'sub', 'id': 17, 'codec': 'subrip'},
    ];
    stream.changes.add(const Tracks());
  }
}

class _NonNativePlatform extends Fake implements PlatformPlayer {}

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
  late Map<String, String> properties;
  int position() => int.parse(properties['secondary-sub-pos']!);
  Future<void> selectPair({String primary = 'Primary', int secondary = 2}) async {
    properties.addAll({'sub-text/ass': primary, 'secondary-sub-text': 'Translation'});
    player.discover();
    await backend.setSubtitleTrack(1);
    await backend.setSecondarySubtitle(embeddedTrackId: secondary);
  }
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final store = PreferenceStore();
    await store.init();
    prefs = UserPreferences(store);
    player = _Player();
    properties = player.native.properties;
    backend = MediaKitPlayerBackend.forTesting(player, prefs);
    disposed = false;
  });
  tearDown(() {
    if (!disposed) backend.dispose();
    prefs.dispose();
  });

  test('audio startup does not require a native player', () async {
    final other = _Player(platform: _NonNativePlatform());
    final second = MediaKitPlayerBackend.forTesting(other, prefs);
    addTearDown(second.dispose);
    await second.play({
      'url': 'https://server/song.mp3',
      'mediaType': 'audio',
      'autoPlay': false,
    }, startPosition: const Duration(seconds: 30));
    expect(other.opened, ['https://server/song.mp3']);
    await second.setSubtitleDelay(1.25);
    expect(second.subtitleDelaySeconds, 1.25);
  });

  test('seeks and track changes clear placement while dialogue gaps keep it', () async {
    await selectPair(primary: r'{\an2}Bottom primary');
    final bottomPosition = position();
    expect(bottomPosition, greaterThan(50));

    properties.remove('sub-text/ass');
    await backend.configureSecondarySubtitleStyle(verticalOffset: 0);
    expect(position(), bottomPosition);

    await backend.seekTo(const Duration(seconds: 51));
    expect(position(), lessThan(50));

    properties['sub-text/ass'] = r'{\an2}Bottom primary';
    final delayed = player.native.delayedSecondaryText = Completer<String>();
    final started = player.native.secondaryTextReadStarted = Completer<void>();
    final update = backend.configureSecondarySubtitleStyle(verticalOffset: 0);
    await started.future;
    final seek = backend.seekTo(const Duration(seconds: 60));
    await _flush();
    delayed.complete('Translation');
    await Future.wait([update, seek]);
    expect(position(), lessThan(50));
    player.native.delayedSecondaryText = null;
    player.native.tracks.add({'type': 'sub', 'id': 23, 'codec': 'subrip'});
    await backend.setSecondarySubtitle(embeddedTrackId: 3);
    properties['sub-text/ass'] = r'{\an2}Bottom primary';
    await backend.setSubtitleTrack(1);
    final positionBeforeSwitch = position();
    properties.remove('sub-text/ass');
    await backend.setSubtitleTrack(1);
    expect(position(), positionBeforeSwitch); // Same track preserves dialogue-gap placement.

    await backend.setSubtitleTrack(2);
    expect(properties['sid'], '17');
    expect(position(), lessThan(50));

    properties['sub-text/ass'] = 'Primary again';
    await backend.setSubtitleTrack(1);
    expect(position(), greaterThan(50));
    properties.remove('sub-text/ass');
    await backend.setEmbeddedCaptionTrack(1);
    expect(properties['sid'], '3');
    expect(position(), lessThan(50));
    await backend.setSubtitleTrack(1, isBitmapSubtitle: true);
    final fallback = position();
    expect(fallback, inExclusiveRange(0, 50));
    await backend.configureSecondarySubtitleStyle(verticalOffset: 0.06);
    expect(position(), fallback);
    properties['sub-text/ass'] = 'Primary';
    await backend.setSubtitleTrack(1);
    expect(position(), greaterThan(50));
    properties.remove('sub-text/ass');
    await backend.setSubtitleTrack(1, isBitmapSubtitle: true);
    expect(position(), fallback);
    await backend.disableSubtitleTrack();
    expect(position(), 100);
  });

  test('primary gaps remeasure fonts and valid viewports, with dimension fallbacks', () async {
    const primary = 'A primary subtitle which wraps in a narrow window';
    await selectPair(primary: primary);
    properties['osd-dimensions'] = 'not JSON';
    for (final (font, width, height, moves) in [
      (48.0, '1280', '720', true), (24.0, '400', '720', true),
      (24.0, 'invalid', '720', false), (24.0, '400', '0', false),
    ]) {
      properties.addAll({'sub-text/ass': primary, 'osd-width': '1280', 'osd-height': '720'});
      await backend.configureSubtitleStyle(fontSize: 24, verticalOffset: 0.04);
      final before = position();
      properties.remove('sub-text/ass');
      properties.addAll({'osd-width': width, 'osd-height': height});
      await backend.configureSubtitleStyle(fontSize: font);
      final gap = position();
      expect(gap, moves ? lessThan(before) : before);
      properties['sub-text/ass'] = primary;
      await backend.configureSecondarySubtitleStyle(verticalOffset: 0);
      expect(position(), gap, reason: 'Returning primary must match its gap reference');
    }
    double distance() => (1 - double.parse(properties['sub-margin-y']!) / 720) * (1 - position() / 100);
    await backend.configureSubtitleStyle(fontSize: 24, verticalOffset: 0);
    final baseline = distance();
    expect(baseline, greaterThan(55 / 720));
    await backend.configureSubtitleStyle(verticalOffset: 0.08);
    await backend.configureSecondarySubtitleStyle(verticalOffset: 0.04);
    expect(distance() - 0.04, closeTo(baseline, 0.01));
    expect(properties['sub-pos'], isNull);
  });

  test('paused subtitle delay refreshes secondary placement for the current cue', () async {
    properties.addAll({'osd-width': '1280', 'osd-height': '720'});
    await selectPair(primary: 'One line');
    await backend.configureSecondarySubtitleStyle(verticalOffset: 0);
    final before = position();
    // No position-stream tick occurs while this fake player is paused.
    properties['sub-text/ass'] = r'One\NTwo\NThree';
    await backend.setSubtitleDelay(1.0);
    expect(position(), lessThan(before));
    expect(properties['secondary-sub-delay'], '1.000');
  });

  testWidgets('window resize refreshes secondary placement without playback ticks', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    final other = _Player();
    other.native.properties.addAll({
      'secondary-sub-delay': '0',
      'secondary-sub-pos': '0',
      'sub-text/ass': 'A long primary subtitle which wraps only in a narrow window',
      'secondary-sub-text': 'Translation',
      'osd-width': '1280',
      'osd-height': '720',
    });
    final second = MediaKitPlayerBackend.forTesting(other, prefs);
    addTearDown(second.dispose);
    other.discover();
    await second.setSecondarySubtitle(embeddedTrackId: 1);
    await second.configureSecondarySubtitleStyle(verticalOffset: 0);
    final before = int.parse(other.native.properties['secondary-sub-pos']!);
    other.native.properties['osd-width'] = '400';
    // Exercise Flutter's real metrics observer, not the callback directly.
    tester.view.physicalSize = tester.view.physicalSize * 0.9;
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump();
    await tester.pump();
    expect(int.parse(other.native.properties['secondary-sub-pos']!), lessThan(before));
  });

  test('delay survives source reloads but resets for the next session', () async {
    Future<void> open(int? session, {int secondaryDelayMs = 0}) => backend.play({
      'url': 'https://server/video-$session',
      'subtitleDelaySessionId': session,
      'secondarySubtitleDelayMs': secondaryDelayMs,
    });
    await open(1);
    await backend.setSubtitleDelay(1.25);
    await backend.setSecondarySubtitleDelay(0.5);
    player.discover();
    await backend.setSubtitleTrack(1);
    await backend.setSubtitleTrack(2);
    expect(properties['sub-delay'], '1.250');
    expect(properties['secondary-sub-delay'], '1.750');

    await backend.stop();
    await open(1, secondaryDelayMs: 500);
    expect(properties['sub-delay'], '1.250');
    expect(properties['secondary-sub-delay'], '1.750');
    expect(backend.subtitleDelaySeconds, 1.25);

    await open(2);
    expect(properties['sub-delay'], '0.000');
    expect(properties['secondary-sub-delay'], '0.000');
    await backend.setSubtitleDelay(-0.5);
    await open(null);
    expect(properties['sub-delay'], '0.000');
  });

  test(
    'secondary embedded track uses its real sid and survives primary changes',
    () async {
      player.discover();
      await backend.setSubtitleTrack(1);
      await backend.setSecondarySubtitle(embeddedTrackId: 2);
      expect(properties['sid'], '11');
      expect(properties['secondary-sid'], '17');
      await backend.setSubtitleTrack(1);
      await backend.disableSubtitleTrack();
      expect(properties['secondary-sid'], '17');
      expect(properties['secondary-sub-visibility'], 'yes');
      expect(properties['secondary-sub-pos'], '100');
      player.automaticSubtitleSid = '11';
      properties.addAll({'sub-text/ass': 'Primary', 'secondary-sub-text': 'Translation'});
      await backend.play({'url': 'https://server/next.mkv', 'autoPlay': false});
      expect(properties['sid'], '11');
      await backend.setSecondarySubtitle(embeddedTrackId: 2);
      expect(position(), inInclusiveRange(50, 99));
      await backend.setSubtitleTrack(1);
      await backend.setSecondarySubtitle();
      expect(properties['sid'], '11');
      expect(properties['secondary-sid'], 'no');
      const url = '/downloads/secondary.srt';
      await backend.setSecondarySubtitle(url: url, codec: 'srt');
      await _flush();
      expect(properties['sid'], '11');
      expect(properties['secondary-sid'], '52');
      final additions = player.native.commands.where((command) => command.first == 'sub-add');
      expect(additions.single.take(3), ['sub-add', url, 'auto']);
      await backend.addExternalSubtitle(url);
      await backend.setSecondarySubtitle(url: url);
      expect(additions, hasLength(1));
      properties['sid'] = '17';
      await backend.setSecondarySubtitle(embeddedTrackId: 2);
      expect(player.native.rejectedSecondarySelections, greaterThan(0));
      await backend.setSecondarySubtitle();
      await backend.setSubtitleTrack(1);
      expect(properties['secondary-sid'], 'no');
    },
  );

  test('discovery selects the embedded ordinal once, excluding external and CC tracks', () async {
    await backend.setSubtitleTrack(2);
    player.discover();
    await _flush();
    expect(properties['sid'], '17');
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
      player.native.delayedTracks = read;
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
      read.complete(jsonEncode(player.native.tracks));
      await replacement;
      await _flush();
      expect(player.selections, action == 'choice' ? ['17'] : isEmpty);
    });
  }
}
