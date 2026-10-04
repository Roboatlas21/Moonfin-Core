import 'dart:async';

import 'letterbox_crop.dart';

enum SubtitleRendererMode { native, assOverlay }

enum LiveRecoveryTrigger { startupTimeout, stalled, sourceReset }

enum LiveRecoveryEventType { inactive, healthy, recoveryRequired }

class LiveRecoveryEvent {
  const LiveRecoveryEvent.inactive()
    : type = LiveRecoveryEventType.inactive,
      trigger = null,
      tryInPlaceFirst = false;

  const LiveRecoveryEvent.healthy()
    : type = LiveRecoveryEventType.healthy,
      trigger = null,
      tryInPlaceFirst = false;

  const LiveRecoveryEvent.recoveryRequired({
    required this.trigger,
    required this.tryInPlaceFirst,
  }) : type = LiveRecoveryEventType.recoveryRequired;

  final LiveRecoveryEventType type;
  final LiveRecoveryTrigger? trigger;
  final bool tryInPlaceFirst;
}

/// Timing shared by backend-owned Live TV detectors.
///
/// Backends decide what counts as real progress. This class only turns those
/// engine-specific progress signals into the common 30s startup, 15s in-place
/// resume, and 8s mid-stream recovery windows.
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
  bool _recoveryRequested = false;
  bool _resumingInPlace = false;
  bool _stallArmed = true;
  bool _suspendedAfterHealthy = false;
  bool _tryInPlaceFirst = false;
  DateTime? _windowStartedAt;
  DateTime? _lastProgressAt;
  Duration? _lastPosition;

  Stream<LiveRecoveryEvent> get events => _events.stream;

  void start({
    required bool live,
    required bool wantsPlay,
    required bool tryInPlaceFirst,
  }) {
    _timer?.cancel();
    _timer = null;
    _live = live;
    _wantsPlay = wantsPlay;
    _healthy = false;
    _everHealthy = false;
    _recoveryRequested = false;
    _resumingInPlace = false;
    _stallArmed = true;
    _suspendedAfterHealthy = false;
    _tryInPlaceFirst = tryInPlaceFirst;
    _lastProgressAt = null;
    _lastPosition = null;
    _windowStartedAt = live && wantsPlay ? DateTime.now() : null;

    if (!live) return;
    _emit(const LiveRecoveryEvent.inactive());
    _timer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _check(),
    );
  }

  void setPlayIntent(bool wantsPlay) {
    if (!_live || _wantsPlay == wantsPlay) return;
    _wantsPlay = wantsPlay;
    _lastPosition = null;
    _lastProgressAt = null;
    _healthy = false;
    _recoveryRequested = false;
    _resumingInPlace = wantsPlay && _everHealthy;
    _stallArmed = wantsPlay;
    _suspendedAfterHealthy = !wantsPlay && _everHealthy;
    _windowStartedAt = wantsPlay ? DateTime.now() : null;
    _emit(const LiveRecoveryEvent.inactive());
  }

  /// Disarms mid-stream stall timing for a settled engine state that is
  /// neither playing nor buffering. On engines without playWhenReady this is
  /// the only safe way to distinguish an external/system pause from a stall.
  /// Startup still times out until the source has proved healthy once.
  void setStallArmed(bool armed) {
    if (!_live || _stallArmed == armed) return;
    _stallArmed = armed;

    if (!armed) {
      if (_everHealthy && _healthy) {
        _healthy = false;
        _lastProgressAt = null;
        _lastPosition = null;
        _windowStartedAt = null;
        _suspendedAfterHealthy = true;
        _emit(const LiveRecoveryEvent.inactive());
      }
      return;
    }

    if (_wantsPlay && _suspendedAfterHealthy) {
      _resumingInPlace = true;
      _windowStartedAt = DateTime.now();
      _lastPosition = null;
      _suspendedAfterHealthy = false;
    }
  }

  void beginInPlaceRecovery() {
    if (!_live) return;
    _healthy = false;
    _recoveryRequested = false;
    _resumingInPlace = true;
    _stallArmed = true;
    _suspendedAfterHealthy = false;
    _windowStartedAt = _wantsPlay ? DateTime.now() : null;
    _lastProgressAt = null;
    _lastPosition = null;
    _emit(const LiveRecoveryEvent.inactive());
  }

  /// Records a backend-specific progress sample. The first eligible sample is
  /// only a baseline; a changed sample proves that playback actually moved.
  void observeProgress(Duration position, {bool eligible = true}) {
    if (!_live || !_wantsPlay || !eligible) return;
    final previous = _lastPosition;
    _lastPosition = position;
    if (previous == null || previous == position) return;
    _markHealthyAt(DateTime.now());
  }

  /// For engines with an authoritative first-frame/presentation callback.
  void markHealthy() {
    if (!_live || !_wantsPlay) return;
    _markHealthyAt(DateTime.now());
  }

  void requestRecovery(
    LiveRecoveryTrigger trigger, {
    bool? tryInPlaceFirst,
  }) {
    if (!_live || !_wantsPlay || _recoveryRequested) return;
    _healthy = false;
    _recoveryRequested = true;
    _emit(
      LiveRecoveryEvent.recoveryRequired(
        trigger: trigger,
        tryInPlaceFirst: tryInPlaceFirst ?? _tryInPlaceFirst,
      ),
    );
  }

  void stop() {
    final wasLive = _live;
    _timer?.cancel();
    _timer = null;
    _live = false;
    _wantsPlay = false;
    _healthy = false;
    _everHealthy = false;
    _recoveryRequested = false;
    _resumingInPlace = false;
    _stallArmed = false;
    _suspendedAfterHealthy = false;
    _windowStartedAt = null;
    _lastProgressAt = null;
    _lastPosition = null;
    if (wasLive) _emit(const LiveRecoveryEvent.inactive());
  }

  void dispose() {
    stop();
    _events.close();
  }

  void _markHealthyAt(DateTime now) {
    _lastProgressAt = now;
    _windowStartedAt = now;
    _resumingInPlace = false;
    _stallArmed = true;
    _suspendedAfterHealthy = false;
    _recoveryRequested = false;
    _everHealthy = true;
    if (_healthy) return;
    _healthy = true;
    _emit(const LiveRecoveryEvent.healthy());
  }

  void _check() {
    if (!_live || !_wantsPlay || _recoveryRequested) return;
    final now = DateTime.now();

    if (!_healthy) {
      final startedAt = _windowStartedAt;
      if (startedAt == null) return;
      final timeout = _resumingInPlace ? resumeTimeout : startupTimeout;
      if (now.difference(startedAt) < timeout) return;
      requestRecovery(
        _resumingInPlace
            ? LiveRecoveryTrigger.stalled
            : LiveRecoveryTrigger.startupTimeout,
      );
      return;
    }

    if (!_stallArmed) return;
    final lastProgressAt = _lastProgressAt;
    if (lastProgressAt == null ||
        now.difference(lastProgressAt) < stallTimeout) {
      return;
    }
    requestRecovery(LiveRecoveryTrigger.stalled);
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
  Stream<LiveRecoveryEvent> get liveRecoveryEvents => const Stream.empty();


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
