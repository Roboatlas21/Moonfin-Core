import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:playback_core/playback_core.dart';
import 'package:web/web.dart' as web;

import '../preference/user_preferences.dart';
import 'html_video_backend_profile.dart';
import 'letterbox_croppers.dart';
import 'secondary_subtitle_position.dart';
import 'web_subtitle_overlay_web.dart';

extension type _MoonfinHlsBridge._(JSObject _) implements JSObject {
  external JSBoolean canUseHlsJs(
    web.HTMLVideoElement video,
    JSString url,
    JSBoolean forceHls,
  );

  external JSAny? attach(
    web.HTMLVideoElement video,
    JSString url,
    JSBoolean forceHls,
  );

  external void destroy(JSAny? controller);
}

class HtmlVideoBackend extends PlayerBackend
    implements SecondarySubtitleBackend {
  HtmlVideoBackend(this._prefs)
    : _viewType = 'moonfin-html-video-${_nextViewId++}' {
    _videoElement = _createVideoElement();
    _registerViewFactory();
  }

  static int _nextViewId = 1;
  static final Set<String> _registeredViewTypes = <String>{};

  final UserPreferences _prefs;
  final String _viewType;

  late final web.HTMLVideoElement _videoElement;
  final List<({String url, web.HTMLTrackElement element})> _externalTracks = [];
  JSAny? _hlsController;

  WebSubtitleOverlay? _subtitleOverlay;
  WebSubtitleOverlay get _overlay =>
      _subtitleOverlay ??= WebSubtitleOverlay(_videoElement);

  /// Marks a track whose cues are already being placed, so a track seen twice
  /// does not collect a second listener.
  static const _cueHookProperty = 'moonfinCuePlacement';
  static const _authoredSrtAlignment = 'moonfinAuthoredSrtAlignment';
  static const _autoPositionedCue = 'moonfinAutoPositionedCue';
  static const _stackedMiddleLine = 'moonfinStackedMiddleLine';
  static final _srtAlignmentTag = RegExp(r'^\s*\{\\an([1-9])\}');

  /// The size the cue percentage is measured against, so the setting at its
  /// default leaves the browser drawing cues at its own size.
  static final double _referenceTextSize =
      UserPreferences.subtitlesTextSize.defaultValue;

  web.HTMLStyleElement? _subtitleStyleElement;
  int? _subtitleTextColor;
  int? _subtitleBackgroundColor;
  int? _subtitleStrokeColor;
  double? _subtitleFontSize;
  int? _subtitleFontWeight;
  double _subtitleVerticalOffset = 0;

  web.HTMLTrackElement? _secondaryTrack;
  web.AbortController? _secondaryRequest;
  String? _secondaryUrl;
  String? _secondaryObjectUrl;
  int _secondaryGeneration = 0;
  final _secondaryCues = <({web.VTTCue cue, double start, double end})>[];
  double _secondaryDelay = 0;
  double _secondaryOffset = 0.0;
  double? _secondaryFontSize;
  int? _secondaryTextColor;

  @override
  bool get supportsSecondarySubtitleDelay => true;
  @override
  bool get supportsSecondarySubtitlePosition => true;
  @override
  bool get supportsSecondarySubtitleStyle => true;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffer = Duration.zero;
  bool _isPlaying = false;
  bool _isBuffering = false;
  bool _completed = false;
  double _playbackSpeed = 1.0;
  double _volume = 100.0;
  bool _disposed = false;
  bool _tracksKnown = false;

  Timer? _statePollTimer;
  Completer<void>? _tracksReadyCompleter;

  final _positionStream = StreamController<Duration>.broadcast();
  final _durationStream = StreamController<Duration>.broadcast();
  final _bufferStream = StreamController<Duration>.broadcast();
  final _playingStream = StreamController<bool>.broadcast();
  final _bufferingStream = StreamController<bool>.broadcast();
  final _completedStream = StreamController<bool>.broadcast();
  final _errorStream = StreamController<Map<String, dynamic>>.broadcast();
  final _tracksChangedStream = StreamController<void>.broadcast();

  int _knownTextTrackCount = 0;

  web.HTMLVideoElement _createVideoElement() {
    final element = web.HTMLVideoElement()
      // The id is what the cue stylesheet selects on, so a second player on
      // the page keeps its own look.
      ..id = _viewType
      ..autoplay = false
      ..controls = false
      ..preload = 'auto'
      ..style.border = '0'
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.objectFit = 'contain'
      ..style.pointerEvents = 'none'
      ..style.backgroundColor = 'black';
    element.setAttribute('playsinline', '');
    return element;
  }

  void _registerViewFactory() {
    if (_registeredViewTypes.add(_viewType)) {
      ui_web.platformViewRegistry.registerViewFactory(
        _viewType,
        (int _) => _videoElement,
      );
    }
  }

  void _startStatePolling() {
    _statePollTimer ??= Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _pollState(),
    );
  }

  void _stopStatePolling() {
    _statePollTimer?.cancel();
    _statePollTimer = null;
  }

  void _pollState() {
    if (_disposed) return;

    final positionMs = (_videoElement.currentTime * 1000).round();
    final position = Duration(milliseconds: positionMs.clamp(0, 1 << 31));
    _setPosition(position);

    final rawDuration = _videoElement.duration;
    if (rawDuration.isFinite && rawDuration >= 0) {
      final durationMs = (rawDuration * 1000).round();
      final duration = Duration(milliseconds: durationMs.clamp(0, 1 << 31));
      _setDuration(duration);
    }

    final buffered = _readBufferedDuration();
    _setBuffer(buffered);

    final ended = _videoElement.ended;
    if (ended != _completed) {
      _completed = ended;
      _completedStream.add(_completed);
    }

    final currentlyPlaying = !_videoElement.paused && !ended;
    _setPlaying(currentlyPlaying);

    final bufferingNow =
        currentlyPlaying &&
        (_videoElement.readyState < web.HTMLMediaElement.HAVE_FUTURE_DATA);
    _setBuffering(bufferingNow);

    if (!_tracksKnown &&
        _videoElement.readyState > web.HTMLMediaElement.HAVE_NOTHING) {
      _tracksKnown = true;
      _tracksReadyCompleter?.complete();
      _tracksReadyCompleter = null;
    }

    // Captions carried inside the video only turn up once enough of the stream
    // has been read, which on a live channel can be well after playback began.
    final textTrackCount = _videoElement.textTracks.length;
    if (textTrackCount != _knownTextTrackCount) {
      _knownTextTrackCount = textTrackCount;
      _forEachTextTrack(_watchCuesFor);
      if (!_tracksChangedStream.isClosed) {
        _tracksChangedStream.add(null);
      }
    }
  }

  /// The caption tracks the browser found in the stream itself.
  ///
  /// Only Safari reports these, from the CEA-608 data an HLS live channel
  /// carries inside its video. Tracks this backend added are always kind
  /// `subtitles`, so the kind alone tells the two apart.
  List<web.TextTrack> _inBandCaptionTracks() {
    final found = <web.TextTrack>[];
    try {
      final tracks = _videoElement.textTracks;
      for (var i = 0; i < tracks.length; i++) {
        final track = tracks[i];
        if (track.kind != 'captions') continue;
        found.add(track);
      }
    } catch (_) {}
    return found;
  }

  Duration _readBufferedDuration() {
    try {
      final ranges = _videoElement.buffered;
      final rangeCount = ranges.length;
      if (rangeCount <= 0) return Duration.zero;
      final end = ranges.end(rangeCount - 1);
      final bufferedMs = (end * 1000).round();
      return Duration(milliseconds: bufferedMs.clamp(0, 1 << 31));
    } catch (_) {
      return Duration.zero;
    }
  }

  void _setPosition(Duration value) {
    if (_position == value) return;
    _position = value;
    _positionStream.add(value);
  }

  void _setDuration(Duration value) {
    if (_duration == value) return;
    _duration = value;
    _durationStream.add(value);
  }

  void _setBuffer(Duration value) {
    if (_buffer == value) return;
    _buffer = value;
    _bufferStream.add(value);
  }

  void _setPlaying(bool value) {
    if (_isPlaying == value) return;
    _isPlaying = value;
    _playingStream.add(value);
  }

  void _setBuffering(bool value) {
    if (_isBuffering == value) return;
    _isBuffering = value;
    _bufferingStream.add(value);
  }

  _MoonfinHlsBridge? _resolveHlsBridge() {
    if (!web.window.has('MoonfinHlsBridge')) {
      return null;
    }

    final bridgeAny = web.window.getProperty('MoonfinHlsBridge'.toJS);
    return _MoonfinHlsBridge._(bridgeAny as JSObject);
  }

  bool _isLikelyHlsContainer(String? container) {
    if (container == null || container.isEmpty) {
      return false;
    }
    final normalized = container.toLowerCase();
    return normalized.contains('hls') || normalized.contains('m3u8');
  }

  bool _canUseHlsJs(String url, {required bool forceHls}) {
    final bridge = _resolveHlsBridge();
    if (bridge == null) {
      return false;
    }

    try {
      return bridge.canUseHlsJs(_videoElement, url.toJS, forceHls.toJS).toDart;
    } catch (_) {
      return false;
    }
  }

  bool _attachHlsJsSource(String url, {required bool forceHls}) {
    final bridge = _resolveHlsBridge();
    if (bridge == null) {
      return false;
    }

    try {
      _hlsController = bridge.attach(_videoElement, url.toJS, forceHls.toJS);
      return _hlsController != null;
    } catch (_) {
      _hlsController = null;
      return false;
    }
  }

  void _detachHlsJsSource() {
    final controller = _hlsController;
    _hlsController = null;
    if (controller == null) {
      return;
    }

    final bridge = _resolveHlsBridge();
    if (bridge == null) {
      return;
    }

    try {
      bridge.destroy(controller);
    } catch (_) {}
  }

  static bool _isCrossOrigin(String url) {
    final target = Uri.tryParse(url);
    if (target == null || !target.hasAuthority) return false;
    final page = Uri.base;
    return target.scheme != page.scheme ||
        target.host != page.host ||
        target.port != page.port;
  }

  void _applyNativeSource(String url) {
    _videoElement.src = url;
    _videoElement.load();
  }

  Future<void> _applySource(
    String url, {
    String? container,
    required Duration startPosition,
  }) async {
    _clearExternalTracks();

    // Subtitle tracks are fetched in whatever CORS mode the video element is
    // in, so a remote server needs this, and hls.js never touches the src
    // attribute, so it has to be set here rather than on the native path.
    // Asking for CORS on a same origin stream only gives playback another way
    // to fail, and the element outlives the source, so it comes back off again.
    if (_isCrossOrigin(url)) {
      _videoElement.crossOrigin = 'anonymous';
    } else {
      _videoElement.removeAttribute('crossorigin');
    }

    final forceHls = _isLikelyHlsContainer(container);
    _detachHlsJsSource();
    final attachedWithHlsJs = _canUseHlsJs(url, forceHls: forceHls)
        ? _attachHlsJsSource(url, forceHls: forceHls)
        : false;

    if (!attachedWithHlsJs) {
      _applyNativeSource(url);
    }

    if (startPosition > Duration.zero) {
      _videoElement.currentTime = startPosition.inMilliseconds / 1000;
    }

    _videoElement.playbackRate = _playbackSpeed;
    _videoElement.volume = (_volume / 100).clamp(0.0, 1.0);
  }

  void _clearExternalTracks() {
    _clearSecondarySubtitle();
    for (final track in _externalTracks) {
      track.element.remove();
    }
    _externalTracks.clear();
    _subtitleOverlay?.clear();
  }

  @override
  Future<void> play(
    dynamic mediaItem, {
    Duration startPosition = Duration.zero,
  }) async {
    if (_disposed) return;

    final payload = mediaItem is Map ? mediaItem : const <String, dynamic>{};
    final autoPlay = payload['autoPlay'] != false;
    final url = mediaItem is String
        ? mediaItem
        : payload['url']?.toString() ?? '';
    final container = payload['container']?.toString();
    if (url.isEmpty) return;

    _tracksKnown = false;
    _tracksReadyCompleter = null;
    _knownTextTrackCount = 0;
    _completed = false;
    _completedStream.add(false);

    await _applySource(url, container: container, startPosition: startPosition);
    await setSecondarySubtitleDelay(
      ((payload['secondarySubtitleDelayMs'] as num?) ?? 0) / 1000,
    );
    await configureSecondarySubtitleStyle(
      fontSize: (payload['secondarySubtitleFontSize'] as num?)?.toDouble(),
      verticalOffset: (payload['secondarySubtitleOffset'] as num?)?.toDouble(),
      textColor: (payload['secondarySubtitleTextColor'] as num?)?.toInt(),
    );
    await setSecondarySubtitle(
      url: payload['secondarySubtitleUrl'] as String?,
      codec: payload['secondarySubtitleCodec'] as String?,
    );

    if (autoPlay) {
      _setBuffering(true);
      try {
        await _videoElement.play().toDart;
        _setPlaying(true);
      } catch (error) {
        _setPlaying(false);
        _errorStream.add(<String, dynamic>{
          'event': 'playerError',
          'message': error.toString(),
        });
      } finally {
        _setBuffering(false);
      }
    } else {
      _setPlaying(false);
      _setBuffering(false);
    }

    _startStatePolling();
  }

  @override
  Future<void> resume() async {
    if (_disposed) return;
    try {
      await _videoElement.play().toDart;
      _setPlaying(true);
    } catch (error) {
      _errorStream.add(<String, dynamic>{
        'event': 'playerError',
        'message': error.toString(),
      });
      _setPlaying(false);
    }
    _startStatePolling();
  }

  @override
  Future<void> pause() async {
    if (_disposed) return;
    _videoElement.pause();
    _setPlaying(false);
    _setBuffering(false);
  }

  @override
  Future<void> stop() async {
    if (_disposed) return;
    _videoElement.pause();
    _detachHlsJsSource();
    _videoElement.removeAttribute('src');
    _videoElement.load();
    _clearExternalTracks();
    _tracksKnown = false;
    _tracksReadyCompleter = null;
    _knownTextTrackCount = 0;
    _setPlaying(false);
    _setBuffering(false);
    _setPosition(Duration.zero);
    _setBuffer(Duration.zero);
    _setDuration(Duration.zero);
    if (_completed) {
      _completed = false;
      _completedStream.add(false);
    }
    _stopStatePolling();
  }

  @override
  Future<void> seekTo(Duration position) async {
    if (_disposed) return;
    final seconds = position.inMilliseconds / 1000;
    _videoElement.currentTime = seconds;
    _setPosition(position);
  }

  @override
  Duration get position => _position;

  @override
  Duration get duration => _duration;

  @override
  Duration get buffer => _buffer;

  @override
  bool get isPlaying => _isPlaying;

  @override
  bool get isBuffering => _isBuffering;

  @override
  double get playbackSpeed => _playbackSpeed;

  @override
  Stream<Duration> get positionStream => _positionStream.stream;

  @override
  Stream<Duration> get durationStream => _durationStream.stream;

  @override
  Stream<Duration> get bufferStream => _bufferStream.stream;

  @override
  Stream<bool> get playingStream => _playingStream.stream;

  @override
  Stream<bool> get bufferingStream => _bufferingStream.stream;

  @override
  Stream<bool> get completedStream => _completedStream.stream;

  @override
  Stream<Map<String, dynamic>> get errorStream => _errorStream.stream;

  @override
  Map<String, dynamic> getDeviceProfile({
    bool useProgressiveTranscode = false,
  }) {
    return buildHtmlVideoBackendDeviceProfile(
      _prefs,
      useProgressiveTranscode: useProgressiveTranscode,
    );
  }

  @override
  Future<void> setPlaybackSpeed(double speed) async {
    _playbackSpeed = speed;
    if (_disposed) return;
    _videoElement.playbackRate = speed;
  }

  @override
  Future<void> setAudioTrack(int index) async {
  }


  @override
  Future<void> setSubtitleTrack(
    int index, {
    bool isBitmapSubtitle = false,
    String? subtitleCodec,
    bool isExternalSubtitle = false,
    String? externalSubtitleUrl,
  }) async {
    if (_disposed) return;

    if (isExternalSubtitle &&
        externalSubtitleUrl != null &&
        externalSubtitleUrl.isNotEmpty) {
      await _showExternalSubtitle(externalSubtitleUrl, codec: subtitleCodec);
      return;
    }

    // Track ordinals count from one over the tracks the player was handed, and
    // the only ones a browser is ever handed are the ones added here, so the
    // ordinal is a position in that list.
    _showTrackAt(index - 1);
  }

  /// Shows the track at [position] in add order and hides everything else. A
  /// position outside the list just clears the screen.
  void _showTrackAt(int position) {
    _subtitleOverlay?.clear();

    try {
      final tracks = _videoElement.textTracks;
      for (var i = 0; i < tracks.length; i++) {
        if (tracks[i] == _secondaryTrack?.track) continue;
        tracks[i].mode = 'disabled';
      }

      for (var i = 0; i < _externalTracks.length; i++) {
        final element = _externalTracks[i].element;
        // Safari only draws cues for a track that carries the default
        // attribute when the page supplies its own controls, as this one does.
        if (i == position) {
          if (element.parentNode == null) {
            _videoElement.appendChild(element);
          }
          element.setAttribute('default', '');
          element.track.mode = 'showing';
        } else {
          element.removeAttribute('default');
          // Chromium turns on any subtitle track the page has never set a
          // mode on once another one is showing, and setting a track that is
          // already disabled to disabled does not count. Only the picked track
          // stays on the element, so the browser has nothing to add under it
          // and nothing to bring back after Off.
          element.remove();
        }
      }
    } catch (_) {}
  }

  @override
  List<EmbeddedCaptionTrack> get embeddedCaptionTracks {
    final tracks = _inBandCaptionTracks();
    return List.unmodifiable([
      for (var i = 0; i < tracks.length; i++)
        EmbeddedCaptionTrack(
          id: i + 1,
          label: tracks[i].label.isEmpty ? 'CC${i + 1}' : tracks[i].label,
          language: tracks[i].language.isEmpty ? null : tracks[i].language,
        ),
    ]);
  }

  @override
  Stream<void> get tracksChangedStream => _tracksChangedStream.stream;

  @override
  Future<void> setEmbeddedCaptionTrack(int id) async {
    if (_disposed) return;
    final tracks = _inBandCaptionTracks();
    if (id <= 0 || id > tracks.length) return;

    _showTrackAt(-1);
    tracks[id - 1].mode = 'showing';
  }

  @override
  Future<void> disableSubtitleTrack() async {
    if (_disposed) return;
    _showTrackAt(-1);
  }

  @override
  Future<void> waitForTracksReady() async {
    if (_tracksKnown) {
      return;
    }

    _tracksReadyCompleter ??= Completer<void>();
    try {
      await _tracksReadyCompleter!.future.timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  @override
  Future<void> waitForEmbeddedSubtitleCount(int count) async {
    await waitForTracksReady();
  }

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 100.0);
    if (_disposed) return;
    _videoElement.volume = (_volume / 100).clamp(0.0, 1.0);
  }

  @override
  Future<void> setAudioDelay(double seconds) async {}

  @override
  Future<void> setSubtitleDelay(double seconds) async {}

  @override
  Future<void> setSecondarySubtitle({
    String? url,
    String? codec,
    int? embeddedTrackId,
  }) async {
    if (_disposed || (url != null && url == _secondaryUrl)) return;
    _clearSecondarySubtitle();
    if (url == null || url.isEmpty) return;
    _secondaryUrl = url;
    // This backend does not demux embedded tracks. The manager supplies the
    // server's text delivery URL, including for subtitles inside an MKV.
    unawaited(_loadSecondarySubtitle(url, _secondaryGeneration));
  }

  Future<void> _loadSecondarySubtitle(String url, int generation) async {
    final abort = _secondaryRequest = web.AbortController();
    try {
      final response = await web.window
          .fetch(url.toJS, web.RequestInit(signal: abort.signal))
          .toDart;
      if (!response.ok) throw StateError('HTTP ${response.status}');
      final content = (await response.text().toDart).toDart;
      if (_disposed || generation != _secondaryGeneration) return;
      // Browsers parse WebVTT only. Jellyfin usually converts SRT itself, but
      // fallback extraction URLs and external sidecars can still deliver SRT.
      final vtt = _asWebVtt(content);
      final objectUrl = _secondaryObjectUrl = web.URL.createObjectURL(
        web.Blob([vtt.toJS].toJS, web.BlobPropertyBag(type: 'text/vtt')),
      );
      final element = _secondaryTrack = web.HTMLTrackElement()
        ..kind = 'subtitles'
        ..label = 'Secondary'
        ..src = objectUrl;
      element.addEventListener(
        'load',
        ((web.Event _) {
          if (_disposed || generation != _secondaryGeneration) return;
          final cues = element.track.cues;
          _secondaryCues.clear();
          if (cues != null) {
            for (var i = 0; i < cues.length; i++) {
              final cue = cues[i] as web.VTTCue;
              _secondaryCues.add((
                cue: cue,
                start: cue.startTime,
                end: cue.endTime,
              ));
              cue.text = '<c.moonfin-secondary>${cue.text}</c>';
            }
          }
          _retimeSecondaryCues();
          _positionSecondaryCues();
          element.setAttribute('default', '');
          element.track.mode = 'showing';
        }).toJS,
      );
      element.addEventListener(
        'error',
        ((web.Event _) {
          _secondaryLoadFailed(generation);
        }).toJS,
      );
      _videoElement.appendChild(element);
      // Load without briefly rendering at the primary track's position.
      element.track.mode = 'hidden';
    } catch (_) {
      _secondaryLoadFailed(generation);
    }
  }

  static String _asWebVtt(String content) {
    final text = content
        .replaceFirst(RegExp(r'^\uFEFF'), '')
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .trim();
    if (text.startsWith('WEBVTT')) return '$text\n\n';
    // Only replace decimal commas on timing lines, leaving dialogue intact.
    final timing = RegExp(
      r'^(\d{2,}:\d{2}:\d{2}),(\d{3})(\s+-->\s+\d{2,}:\d{2}:\d{2}),(\d{3})',
      multiLine: true,
    );
    return 'WEBVTT\n\n${text.replaceAllMapped(timing, (m) => '${m[1]}.${m[2]}${m[3]}.${m[4]}')}\n\n';
  }

  void _secondaryLoadFailed(int generation) {
    if (_disposed || generation != _secondaryGeneration) return;
    _clearSecondarySubtitle();
    _errorStream.add({
      'event': 'subtitleError',
      'message': 'Could not load secondary subtitle file',
    });
  }

  void _clearSecondarySubtitle() {
    _secondaryGeneration++;
    _secondaryRequest?.abort();
    _secondaryRequest = null;
    _secondaryTrack?.track.mode = 'disabled';
    _secondaryTrack?.remove();
    _secondaryTrack = null;
    _secondaryCues.clear();
    _restorePrimaryMiddlePosition();
    _secondaryUrl = null;
    final objectUrl = _secondaryObjectUrl;
    _secondaryObjectUrl = null;
    if (objectUrl != null) web.URL.revokeObjectURL(objectUrl);
  }

  @override
  Future<void> setSecondarySubtitleDelay(double seconds) async {
    if (_disposed) return;
    final delay = seconds.clamp(-5.0, 5.0);
    if (_secondaryDelay == delay) return;
    _secondaryDelay = delay;
    _retimeSecondaryCues();
  }

  @override
  Future<void> configureSecondarySubtitleStyle({
    double? fontSize,
    double? verticalOffset,
    int? textColor,
  }) async {
    if (_disposed) return;
    final size = fontSize?.clamp(6.0, 72.0);
    final styleChanged = _secondaryFontSize != size ||
        _secondaryTextColor != textColor ||
        _subtitleStyleElement == null;
    if (styleChanged) {
      _secondaryFontSize = size;
      _secondaryTextColor = textColor;
      _applySubtitleAppearance();
    }
    final offset = (verticalOffset ?? 0.0).clamp(-0.4, 0.4);
    if (_secondaryOffset == offset && !styleChanged) return;
    _secondaryOffset = offset;
    _positionSecondaryCues();
  }

  void _retimeSecondaryCues() {
    for (final original in _secondaryCues) {
      original.cue
        ..startTime = original.start + _secondaryDelay
        ..endTime = original.end + _secondaryDelay;
    }
  }

  void _restorePrimaryMiddlePosition() {
    _forEachTextTrack((track) {
      final cues = track.cues;
      if (cues == null) return;
      for (var i = 0; i < cues.length; i++) {
        if (!cues[i].isA<web.VTTCue>()) continue;
        final cue = cues[i] as web.VTTCue;
        final original = cue.getProperty<JSNumber?>(_stackedMiddleLine.toJS);
        if (original != null) cue.line = original;
      }
    });
  }

  web.VTTCue? _activePrimaryCue() {
    final tracks = _videoElement.textTracks;
    for (var i = 0; i < tracks.length; i++) {
      final track = tracks[i];
      if (track == _secondaryTrack?.track || track.mode != 'showing') continue;
      final cues = track.activeCues;
      if (cues == null) continue;
      for (var j = 0; j < cues.length; j++) {
        if (cues[j].isA<web.VTTCue>()) return cues[j] as web.VTTCue;
      }
    }
    return null;
  }

  int _primaryAlignment(web.VTTCue? cue) {
    if (cue == null) return 2;
    final authored = int.tryParse(
      cue.getProperty<JSString?>(_authoredSrtAlignment.toJS)?.toDart ?? '',
    );
    if (authored != null) return authored;
    final row = switch (cue.lineAlign) {
      'start' => 2,
      'center' => 1,
      _ => 0,
    };
    final column = switch (cue.align) {
      'left' || 'start' => 0,
      'right' || 'end' => 2,
      _ => 1,
    };
    return row * 3 + column + 1;
  }

  void _positionSecondaryCues() {
    if (_secondaryCues.isEmpty) return;
    final primary = _activePrimaryCue();
    final alignment = _primaryAlignment(primary);
    final primaryRows = primary?.text.split('\n').length ?? 1;
    final primaryHeight = primaryRows *
        ((_subtitleFontSize ?? _referenceTextSize) / 24 * 0.055);
    final secondaryRows = _secondaryCues.first.cue.text.split('\n').length;
    final secondaryHeight = secondaryRows *
        ((_secondaryFontSize ?? _subtitleFontSize ?? _referenceTextSize) /
            24 * 0.055);
    const gap = 0.015;
    final originalCentre =
        primary?.getProperty<JSNumber?>(_stackedMiddleLine.toJS);
    final primaryLine = originalCentre?.toDartDouble ??
        ((primary?.line.dartify() as num?)?.toDouble() ??
            ((1 - _subtitleVerticalOffset) * 100));
    final position = (primaryLine / 100).clamp(0.0, 1.0).toDouble();
    if (primary != null && (alignment - 1) ~/ 3 == 1) {
      if (originalCentre == null) {
        primary.setProperty(_stackedMiddleLine.toJS, primaryLine.toJS);
      }
      primary.line = ((position + (secondaryHeight +
                      middleSubtitleGap(gap, _secondaryOffset)) / 2) * 100)
          .clamp(0.0, 100.0).toDouble().toJS;
    }
    final top = primary == null
        ? (0.96 - secondaryHeight - _secondaryOffset)
            .clamp(0.0, (1 - secondaryHeight).clamp(0.0, 1.0)).toDouble()
        : stackedSecondaryTop(
            alignment: alignment,
            primaryAnchor: position,
            primaryHeight: primaryHeight,
            secondaryHeight: secondaryHeight,
            offset: _secondaryOffset,
          );
    final column = (alignment - 1) % 3;
    for (final original in _secondaryCues) {
      original.cue
        ..region = null
        ..vertical = ''
        ..snapToLines = false
        ..lineAlign = 'start'
        ..line = (top * 100).toJS
        ..align = column == 0 ? 'left' : column == 2 ? 'right' : 'center'
        ..positionAlign =
            column == 0 ? 'line-left' : column == 2 ? 'line-right' : 'center'
        ..position = (column == 0 ? 5 : column == 2 ? 95 : 50).toJS
        ..size = 90;
    }
  }

  /// Adds the subtitle without showing it, so tracks loaded at startup stay
  /// off until one is picked.
  @override
  Future<void> addExternalSubtitle(
    String url, {
    String? title,
    String? language,
    String? codec,
  }) async {
    if (_disposed || url.isEmpty) return;
    // The overlay fetches its file when the subtitle is picked, so there is
    // nothing to add ahead of that.
    if (WebSubtitleOverlay.isOverlayCodec(codec)) return;
    _addTrack(url, title: title, language: language, codec: codec);
  }

  Future<void> _showExternalSubtitle(String url, {String? codec}) async {
    if (WebSubtitleOverlay.isOverlayCodec(codec)) {
      _showTrackAt(-1);
      await _overlay.show(url, codec);
      return;
    }
    _showTrackAt(_addTrack(url, codec: codec));
  }

  /// Makes a track for [url], or finds the one already made, and returns its
  /// position in add order. The track only goes on the element once it is
  /// picked, which also keeps the browser from fetching a file nobody asked
  /// for.
  int _addTrack(String url, {String? title, String? language, String? codec}) {
    final existing = _externalTracks.indexWhere((track) => track.url == url);
    if (existing >= 0) return existing;

    final element = web.HTMLTrackElement()
      ..kind = 'subtitles'
      ..src = url
      ..label = title ?? language ?? 'External Subtitle'
      ..srclang = language ?? 'en';

    if (codec != null && codec.isNotEmpty) {
      element.setAttribute('data-codec', codec);
    }

    _externalTracks.add((url: url, element: element));
    _watchCuesFor(element.track);
    return _externalTracks.length - 1;
  }

  @override
  Future<void> configureSubtitleStyle({
    int? textColor,
    int? backgroundColor,
    int? strokeColor,
    double? fontSize,
    int? fontWeight,
    double? verticalOffset,
  }) async {
    if (_disposed) return;
    if (textColor != null) _subtitleTextColor = textColor;
    if (backgroundColor != null) _subtitleBackgroundColor = backgroundColor;
    if (strokeColor != null) _subtitleStrokeColor = strokeColor;
    if (fontSize != null && fontSize > 0) _subtitleFontSize = fontSize;
    if (fontWeight != null) _subtitleFontWeight = fontWeight;
    if (verticalOffset != null) {
      _subtitleVerticalOffset = verticalOffset.clamp(0.0, 1.0);
    }
    _applySubtitleAppearance();
    _forEachTextTrack(_positionCues);
  }

  /// Appearance goes through a stylesheet, since `::cue` is the only hook the
  /// browser gives for text it draws itself.
  void _applySubtitleAppearance() {
    final rules = <String>[];
    final text = _cssColor(_subtitleTextColor);
    if (text != null) rules.add('color: $text');
    // An unset or fully transparent background has to be written out, or the
    // browser keeps drawing its own black box behind every line.
    rules.add(
      'background-color: ${_cssColor(_subtitleBackgroundColor) ?? 'transparent'}',
    );
    final size = _subtitleFontSize;
    if (size != null) {
      final percent = size / _referenceTextSize * 100;
      rules.add('font-size: ${percent.round()}%');
    }
    final weight = _subtitleFontWeight;
    if (weight != null) {
      rules.add('font-weight: ${weight >= 600 ? 'bold' : 'normal'}');
    }
    final stroke = _cssColor(_subtitleStrokeColor);
    // Offsets in em so the outline keeps its weight as the text is resized.
    rules.add(
      stroke == null
          ? 'text-shadow: none'
          : 'text-shadow: -0.04em -0.04em 0 $stroke, 0.04em -0.04em 0 $stroke, '
                '-0.04em 0.04em 0 $stroke, 0.04em 0.04em 0 $stroke',
    );

    final style = _subtitleStyleElement ??= _createSubtitleStyleElement();
    final secondaryColor = _cssColor(_secondaryTextColor);
    final primarySize = _subtitleFontSize ?? _referenceTextSize;
    final secondaryPercent =
        (_secondaryFontSize ?? primarySize) / primarySize * 100;
    style.textContent =
        '#$_viewType::cue { ${rules.join('; ')} }\n'
        '#$_viewType::cue(.moonfin-secondary) { '
        'font-size: $secondaryPercent%; '
        '${secondaryColor == null ? '' : 'color: $secondaryColor;'} }';
  }

  web.HTMLStyleElement _createSubtitleStyleElement() {
    final style = web.HTMLStyleElement();
    (web.document.head ?? web.document.documentElement)?.appendChild(style);
    return style;
  }

  void _forEachTextTrack(void Function(web.TextTrack track) action) {
    try {
      final tracks = _videoElement.textTracks;
      for (var i = 0; i < tracks.length; i++) {
        if (tracks[i] == _secondaryTrack?.track) continue;
        action(tracks[i]);
      }
    } catch (_) {}
  }

  /// `::cue` cannot move a cue, so the position comes from the cue's own line,
  /// read as a percentage of the video box with the cue's bottom edge on it.
  /// A zero offset therefore puts the line on the bottom edge itself.
  void _positionCues(web.TextTrack track) {
    final cues = track.activeCues;
    if (cues == null) return;
    final line = (1 - _subtitleVerticalOffset) * 100;
    for (var i = 0; i < cues.length; i++) {
      final cue = cues[i];
      if (!cue.isA<web.VTTCue>()) continue;
      final vtt = cue as web.VTTCue;
      final tag = _srtAlignmentTag.firstMatch(vtt.text);
      if (tag != null) {
        vtt.text = vtt.text.replaceFirst(_srtAlignmentTag, '');
        vtt.setProperty(_authoredSrtAlignment.toJS, tag[1]!.toJS);
      }
      final alignment = int.tryParse(
        vtt.getProperty<JSString?>(_authoredSrtAlignment.toJS)?.toDart ?? '',
      );
      if (alignment != null) {
        final column = (alignment - 1) % 3;
        final row = (alignment - 1) ~/ 3;
        vtt
          ..snapToLines = false
          ..lineAlign = row == 0 ? 'end' : row == 1 ? 'center' : 'start'
          ..line = (row == 0
                  ? line
                  : row == 1
                      ? 50
                      : 5 + _subtitleVerticalOffset * 100)
              .clamp(0.0, 100.0).toDouble().toJS
          ..align = column == 0 ? 'left' : column == 2 ? 'right' : 'center'
          ..positionAlign =
              column == 0 ? 'line-left' : column == 2 ? 'line-right' : 'center'
          ..position = (column == 0 ? 5 : column == 2 ? 95 : 50).toJS
          ..size = 90;
        continue;
      }
      // A cue with explicit WebVTT line settings already has an authored
      // position. Only apply the user's bottom offset to automatic cues.
      if (!vtt.has(_autoPositionedCue) &&
          vtt.line.dartify() != 'auto') {
        continue;
      }
      vtt.setProperty(_autoPositionedCue.toJS, true.toJS);
      vtt.lineAlign = 'end';
      if (vtt.lineAlign != 'end') continue;
      vtt.snapToLines = false;
      vtt.line = line.toJS;
    }
    _positionSecondaryCues();
  }

  /// A cue can only be placed once it exists, and the ones carried inside a
  /// stream turn up long after playback began, so the track is asked again
  /// every time its active set changes.
  void _watchCuesFor(web.TextTrack track) {
    if (track.has(_cueHookProperty)) return;
    track.setProperty(_cueHookProperty.toJS, true.toJS);
    track.addEventListener(
      'cuechange',
      ((web.Event _) => _positionCues(track)).toJS,
    );
  }

  static String? _cssColor(int? argb) {
    if (argb == null) return null;
    final alpha = (argb >> 24) & 0xFF;
    if (alpha == 0) return null;
    final red = (argb >> 16) & 0xFF;
    final green = (argb >> 8) & 0xFF;
    final blue = argb & 0xFF;
    if (alpha == 0xFF) return 'rgb($red, $green, $blue)';
    return 'rgba($red, $green, $blue, ${(alpha / 255).toStringAsFixed(3)})';
  }

  @override
  Future<void> setSubtitleRendererMode(SubtitleRendererMode mode) async {
  }

  @override
  bool get supportsRuntimeTrackSelection => false;

  @override
  LetterboxCropper get letterboxCropper => const HtmlLetterboxCropper();

  @override
  bool get requiresStartupMediaReadyCheck => false;

  @override
  bool get nativelyHandlesStartPosition => true;

  @override
  bool get canRenderBitmapSubtitles => true;

  @override
  bool get demuxesEmbeddedSubtitles => false;

  Widget buildView({BoxFit fit = BoxFit.contain}) {
    _videoElement.style.objectFit = _cssObjectFit(fit);
    return HtmlElementView(viewType: _viewType);
  }

  String _cssObjectFit(BoxFit fit) {
    switch (fit) {
      case BoxFit.fill:
        return 'fill';
      case BoxFit.contain:
        return 'contain';
      case BoxFit.cover:
        return 'cover';
      case BoxFit.fitWidth:
        return 'scale-down';
      case BoxFit.fitHeight:
        return 'scale-down';
      case BoxFit.none:
        return 'none';
      case BoxFit.scaleDown:
        return 'scale-down';
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _stopStatePolling();
    _clearExternalTracks();
    _subtitleOverlay?.dispose();
    _subtitleOverlay = null;
    _subtitleStyleElement?.remove();
    _subtitleStyleElement = null;
    _detachHlsJsSource();
    _videoElement.pause();
    _videoElement.removeAttribute('src');
    _videoElement.load();

    _positionStream.close();
    _durationStream.close();
    _bufferStream.close();
    _playingStream.close();
    _bufferingStream.close();
    _completedStream.close();
    _errorStream.close();
    _tracksChangedStream.close();
  }
}
