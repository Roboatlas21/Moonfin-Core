import 'dart:async';

import 'letterbox_crop.dart';

enum SubtitleRendererMode { native, assOverlay }

enum LiveRecoveryEvent { inactive, healthy, startupTimeout, stalled }

/// Turns backend-specific progress signals into the common Live TV recovery
/// windows. Backends decide what proves useful playback; this class only owns
/// the 30s startup, 15s resume, and 8s mid-stream clocks.
class BackendLiveRecoveryMonitor {
  BackendLiveRecoveryMonitor({
    this.startupTimeout = const Duration(seconds: 30),
    this.resumeTimeout = const Duration(seconds: 15),
    this.stallTimeout = const Duration(seconds: 8),
  });

  final Duration startupTimeout;
  final Duration resumeTimeout;
  final Duration stallTimeout;

  final _events = StreamController<LiveRecoveryEvent>.broadcast();
  Timer? _timer;
  bool _live = false;
  bool _wantsPlay = false;
  bool _healthy = false;
  bool _everHealthy = false;
  bool _active = false;
  Duration? _lastPosition;

  Stream<LiveRecoveryEvent> get events => _events.stream;

  void start({required bool live, required bool wantsPlay}) {
    _cancelTimer();
    _live = live;
    _wantsPlay = wantsPlay;
    _healthy = false;
    _everHealthy = false;
    _active = wantsPlay;
    _lastPosition = null;

    if (!live) return;
    _emit(LiveRecoveryEvent.inactive);
    if (wantsPlay) {
      _arm(startupTimeout, LiveRecoveryEvent.startupTimeout);
    }
  }

  void setPlayIntent(bool wantsPlay) {
    if (!_live || _wantsPlay == wantsPlay) return;
    _wantsPlay = wantsPlay;
    _healthy = false;
    _active = wantsPlay;
    _lastPosition = null;
    _cancelTimer();
    _emit(LiveRecoveryEvent.inactive);

    if (wantsPlay) {
      _arm(
        _everHealthy ? resumeTimeout : startupTimeout,
        _everHealthy
            ? LiveRecoveryEvent.stalled
            : LiveRecoveryEvent.startupTimeout,
      );
    }
  }

  void setActive(bool active) {
    if (!_live || !_everHealthy || _active == active) return;
    _active = active;
    _healthy = false;
    _lastPosition = null;
    _cancelTimer();
    _emit(LiveRecoveryEvent.inactive);

    if (active && _wantsPlay) {
      _arm(resumeTimeout, LiveRecoveryEvent.stalled);
    }
  }

  void beginInPlaceRecovery() {
    if (!_live) return;
    _healthy = false;
    _active = true;
    _lastPosition = null;
    _cancelTimer();
    _emit(LiveRecoveryEvent.inactive);

    if (_wantsPlay) {
      _arm(resumeTimeout, LiveRecoveryEvent.stalled);
    }
  }

  /// The first eligible sample establishes a baseline; movement from it proves
  /// that playback is genuinely advancing.
  void observeProgress(Duration position, {required bool eligible}) {
    if (!_live || !_wantsPlay || !eligible) return;
    final previous = _lastPosition;
    _lastPosition = position;
    if (previous == null || previous == position) return;

    final becameHealthy = !_healthy;
    _healthy = true;
    _everHealthy = true;
    _active = true;
    _arm(stallTimeout, LiveRecoveryEvent.stalled);

    if (becameHealthy) {
      _emit(LiveRecoveryEvent.healthy);
    }
  }

  void stop() {
    final notify = _live;
    _cancelTimer();
    _live = false;
    _wantsPlay = false;
    _healthy = false;
    _everHealthy = false;
    _active = false;
    _lastPosition = null;
    if (notify) _emit(LiveRecoveryEvent.inactive);
  }

  void dispose() {
    stop();
    _events.close();
  }

  void _arm(Duration timeout, LiveRecoveryEvent failure) {
    _cancelTimer();
    _timer = Timer(timeout, () {
      _timer = null;
      if (!_live || !_wantsPlay) return;
      _healthy = false;
      _emit(failure);
    });
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void _emit(LiveRecoveryEvent event) {
    if (!_events.isClosed) _events.add(event);
  }
}

/// A caption track the player found inside the video itself, like the CEA-608
/// captions broadcasters carry in H.264 SEI data.
///
/// Servers don't list these as subtitle streams because nothing declares them
/// ahead of time, so they have no stream index and only exist once the player
/// has read far enough into the stream to find them.
class EmbeddedCaptionTrack {
  const EmbeddedCaptionTrack({
    required this.id,
    required this.label,
    this.language,
  });

  /// Identifies the track to the backend it came from. Only meaningful to that
  /// backend.
  final int id;

  /// What to show in a track menu, like "CC1".
  final String label;

  final String? language;

  /// Reads the caption tracks a platform player reports finding inside the
  /// video, as a list of `{id, label, language}` maps. An entry without a
  /// usable id is dropped rather than offered as a menu row that can't be
  /// selected.
  static List<EmbeddedCaptionTrack> listFromWire(dynamic value) {
    if (value is! List) return const [];
    final tracks = <EmbeddedCaptionTrack>[];
    for (final entry in value) {
      if (entry is! Map) continue;
      final id = entry['id'];
      if (id is! int || id <= 0) continue;
      final label = entry['label']?.toString() ?? '';
      final language = entry['language']?.toString() ?? '';
      tracks.add(
        EmbeddedCaptionTrack(
          id: id,
          label: label.isEmpty ? 'CC$id' : label,
          language: language.isEmpty ? null : language,
        ),
      );
    }
    return List.unmodifiable(tracks);
  }
}

abstract class PlayerBackend {
  Future<void> play(
    dynamic mediaItem, {
    Duration startPosition = Duration.zero,
  });
  Future<void> resume();
  Future<void> pause();
  Future<void> stop();
  Future<void> seekTo(Duration position);

  Duration get position;
  Duration get duration;
  Duration get buffer;
  bool get isPlaying;
  bool get isBuffering;
  double get playbackSpeed;

  Stream<Duration> get positionStream;
  Stream<Duration> get durationStream;
  Stream<Duration> get bufferStream;
  Stream<bool> get playingStream;
  Stream<bool> get bufferingStream;
  Stream<bool> get completedStream;
  Stream<Map<String, dynamic>>? get errorStream => null;

  /// Backend-owned Live TV health and recovery signals. The renderer decides
  /// what proves useful playback; PlaybackManager only orchestrates retries.
  Stream<LiveRecoveryEvent> get liveRecoveryEvents =>
      const Stream<LiveRecoveryEvent>.empty();

  /// Whether the player has been told to play. Null on engines that don't
  /// expose their own intent, and callers then fall back to "not playing".
  ///
  /// This exists because `isPlaying` is derived: a viewer pause, a starved
  /// stream and a transient audio focus loss all read as not playing. Only a
  /// starved stream leaves this true.
  bool? get playWhenReady => null;

  Map<String, dynamic> getDeviceProfile({bool useProgressiveTranscode = false});

  Future<void> setPlaybackSpeed(double speed);
  Future<void> setAudioTrack(int index);
  Future<void> setSubtitleTrack(
    int index, {
    bool isBitmapSubtitle = false,
    String? subtitleCodec,
    bool isExternalSubtitle = false,
    String? externalSubtitleUrl,
  });
  Future<void> disableSubtitleTrack();
  Future<void> waitForTracksReady();
  Future<void> waitForEmbeddedSubtitleCount(int count);
  Future<void> setVolume(double volume);
  Future<void> setAudioDelay(double seconds);
  Future<void> setSubtitleDelay(double seconds);
  Future<void> addExternalSubtitle(
    String url, {
    String? title,
    String? language,
    String? codec,
  });
  Future<void> configureSubtitleStyle({
    int? textColor,
    int? backgroundColor,
    int? strokeColor,
    double? fontSize,
    int? fontWeight,
    double? verticalOffset,
  });

  Future<void> setSubtitleRendererMode(SubtitleRendererMode mode);

  bool get supportsRuntimeTrackSelection;

  /// Whether a direct-played source can switch audio tracks in place through
  /// [setAudioTrack]. When true the manager skips the PlaybackInfo round trip
  /// and player rebuild that a re-resolve costs, since every embedded track is
  /// already in the stream.
  bool get supportsDirectPlayAudioSwitch => false;

  int? get activeSubtitleTrackIndex => null;

  Future<int?> getActiveSubtitleTrackIndexAsync() async => null;

  bool get requiresStartupMediaReadyCheck => true;

  bool get nativelyHandlesStartPosition => false;

  /// Whether this backend requests and holds Android audio focus itself, like
  /// media3/ExoPlayer built with handleAudioFocus=true. When true, the Dart
  /// audio_session layer stays out of the way so the two do not fight over focus
  /// and pause each other.
  bool get managesAudioFocus => false;

  bool get canRenderBitmapSubtitles;

  /// Whether the player reads subtitle tracks out of the stream itself. A
  /// browser only shows what it is handed as its own file, so subtitles living
  /// inside the container have to be added the same way an external one is,
  /// even when nothing stripped them from the stream.
  bool get demuxesEmbeddedSubtitles => true;

  /// Caption tracks the player found inside the video, which no server stream
  /// list can describe. Empty on engines that don't decode them.
  List<EmbeddedCaptionTrack> get embeddedCaptionTracks => const [];

  /// Turns on one of [embeddedCaptionTracks]. Turning captions back off goes
  /// through [disableSubtitleTrack], the same as any other subtitle.
  Future<void> setEmbeddedCaptionTrack(int id) async {}

  /// Picks a live stream back up after the player ran out of media, returning
  /// whether it could. A live source has no end, so reaching one means the
  /// source starved, and the cheapest answer is to re-open it where the stream
  /// is now rather than tear the server session down. False means the engine
  /// did nothing, and the caller must escalate rather than wait for a recovery
  /// that is never coming.
  Future<bool> resumeLiveEdge() async => false;

  /// Fires when the player's own track list changes. Captions carried inside
  /// the video turn up part way through playback, so a menu built when the
  /// stream started has to be rebuilt when this fires.
  Stream<void> get tracksChangedStream => const Stream.empty();

  /// How long this player usually takes to render again after a seek. Only
  /// paces how often SyncPlay may correct: the cost it actually compensates
  /// for is measured from the player, never taken from here.
  Duration get typicalSeekLatency => const Duration(milliseconds: 1500);

  /// The longest a seek on this player may plausibly take. SyncPlay treats a
  /// gap larger than this as the client being genuinely late rather than as
  /// the seek still landing, and stops waiting on a seek that exceeds it.
  /// Backends that restart a transcode to seek need this much higher than the
  /// in-buffer seek a desktop player does.
  Duration get maxSeekLatency => const Duration(seconds: 8);

  /// Whether the rate can be changed a few percent mid-playback without the
  /// audio dropping or glitching. mpv and ExoPlayer stretch audio in place;
  /// the AVPlayer-based engines rebuild the audio pipeline on every rate write
  /// and cannot pass Dolby audio through at anything but 1x. SyncPlay only
  /// nudges the rate where this is true, and holds the player instead where
  /// it is not.
  bool get supportsSmoothRateChange => true;

  /// Detect encoded letterbox and crop it. Cover-zoom is not this.
  ///
  /// Desktop libmpv ships a cropper. Media3 / Aether / Tizen / HTML return
  /// [UnsupportedLetterboxCropper] until they implement [LetterboxCropper].
  LetterboxCropper get letterboxCropper => const UnsupportedLetterboxCropper();

  bool get supportsLetterboxCrop => letterboxCropper.isSupported;

  void dispose();
}
