#!/usr/bin/env bash
# Moonfin Media3 subtitle retries: NO GRADLE CHANGES, cleanup included.
# BASELINE: 0af64440fae2b2946ece912b89a43676fed82934
# REPLACES Appendix A of the independent-review handoff and earlier scripts.
# Updated 2026-09-16: retry interrupted fixed-length/chunked HTTP response bodies.
# Run this script alone from the baseline above or its script-only upload commit.
# It already includes cleanup; uploading the script does not apply the patch.
# If the previous scripts were applied, the HEAD guard refuses this replacement.
# Do not undo existing commits automatically just to satisfy the guard.
#
# Creates TWO LOCAL commits: functional fix, then removable diagnostics.
# Does not push or run a workflow. Unrelated staged changes are preserved.
#
# Behavior:
# - Keep the requested subtitle; transient preparation failure never selects Off.
# - Retry recoverable HTTP/network failures indefinitely, with 2..30 second backoff.
# - Keep a 120 second connect timeout and 600 second read inactivity timeout.
#   There is NO total extraction deadline and NO attempt limit.
# - Cancel obsolete HTTP calls on new selections, Off, captions, source changes,
#   stop and release. Old completions cannot change a newer selection, including
#   a new selection of the same URL. A canceled extraction slot is released by
#   its worker before a replacement extraction request starts.
# - Use OkHttp already exposed by Coil 2.7.0 for HTTP subtitle warm-up.
#   Local/content subtitles still use Media3. Gradle is not changed.
# - Share subtitle-selection and pending-state handling; remove obsolete Dart
#   defer wiring and the always-false configuration argument.
# - Retry OkHttp ProtocolException("unexpected end of stream") after truncated
#   responses. Other protocol, local-file, permission/certificate errors and
#   non-retryable HTTP statuses remain permanent until a new selection.
#
# Combined functional diff from before 216d530 (edb3ba1), excluding diagnostics:
# 457 insertions / 96 deletions across FOUR files, net +361 lines.
#
# Validation: guarded application in an isolated Git fixture, exact source bytes,
# independent diagnostic removal, real OkHttp truncated-response regression tests
# and extracted retry-state tests for both variants, and focused API compilation.
# This is not a full Android APK build or device playback test.
#
# Known scope: warm-up still discards bytes; Media3 fetches the URL again.
# Recovery of that second fetch is not added here. Canceling client HTTP cannot
# guarantee cancellation of subtitle extraction already running on Jellyfin.
# If a commit hook fails, inspect git status; this script does not roll back.
(
set -eu
cd /workspaces/Moonfin-Core
expected_head='0af64440fae2b2946ece912b89a43676fed82934'
current_head=$(git rev-parse HEAD)
if [ "$current_head" != "$expected_head" ]; then
  # Uploading this script adds one commit without changing application source.
  # Accept only that single-parent, script-only commit on the reviewed baseline.
  if [ "$(git rev-list --parents -n 1 HEAD)" != "$current_head $expected_head" ] ||
     [ "$(git diff --name-only "$expected_head" HEAD)" != 'moonfin-subtitle-retry-updated.sh' ]; then
    echo 'ERROR: Expected HEAD 0af6444 or its script-only upload commit. Nothing applied.' >&2
    exit 1
  fi
fi
files=(
  'lib/playback/media3_player_backend.dart'
  'packages/moonfin_native_video/android/src/main/kotlin/org/moonfin/nativevideo/Media3VideoView.kt'
  'packages/playback_core/lib/src/playback_manager.dart'
  'packages/playback_core/lib/src/player_backend.dart'
)
diagnostic_files=(
  'lib/playback/media3_player_backend.dart'
  'packages/moonfin_native_video/android/src/main/kotlin/org/moonfin/nativevideo/Media3VideoView.kt'
)
guard_files=("${files[@]}" 'packages/moonfin_native_video/android/build.gradle')
if ! git diff --quiet -- "${guard_files[@]}" ||
   ! git diff --cached --quiet -- "${guard_files[@]}"; then
  echo 'ERROR: A target file already has tracked changes. Nothing applied.' >&2
  exit 1
fi
git var GIT_AUTHOR_IDENT >/dev/null
git var GIT_COMMITTER_IDENT >/dev/null
patch_dir=$(mktemp -d /tmp/moonfin-subtitle-retry-updated.XXXXXX)
trap 'rm -rf -- "$patch_dir"' EXIT
cat > "$patch_dir/fix.patch" <<'MOONFIN_REVISED_RETRY_FIX'
diff --git a/lib/playback/media3_player_backend.dart b/lib/playback/media3_player_backend.dart
--- a/lib/playback/media3_player_backend.dart
+++ b/lib/playback/media3_player_backend.dart
@@ -15,7 +15,7 @@
 import 'server_transcode_capabilities.dart';
 
 class Media3PlayerBackend extends PlayerBackend
-    implements PreloadsExternalSubtitles, ReportsSubtitleSelectionFailures {
+    implements PreloadsExternalSubtitles {
   static const _discontinuityWindowMs = 15000;
   static const _discontinuityThreshold = 3;
   static const _audioSinkErrorThreshold = 2;
@@ -142,15 +142,6 @@
   bool _bufferingFailed = false;
   bool _sourceIsLive = false;
   String? _lastFrameRateLine;
-
-  static int _nextSubtitleRequestId = 0;
-  int _subtitleRequestId = 0;
-  final _subtitleFailures =
-      StreamController<SubtitleSelectionFailure>.broadcast(sync: true);
-
-  @override
-  Stream<SubtitleSelectionFailure> get subtitleSelectionFailures =>
-      _subtitleFailures.stream;
 
   final _positionStream = StreamController<Duration>.broadcast();
   final _durationStream = StreamController<Duration>.broadcast();
@@ -322,19 +313,6 @@
           '${_toInt(map['elapsedMs'])}ms since last feed)',
           level: LogLevel.warning,
         );
-      case 'subtitleSelectionFailed':
-        if (map['requestId'] != _subtitleRequestId) return;
-        _diag(
-          'Media3: subtitle track ${_toInt(map['trackId'])} failed to load; '
-          'keeping track ${_toInt(map['activeTrackId'])}',
-          level: LogLevel.warning,
-        );
-        _subtitleFailures.add(
-          SubtitleSelectionFailure(
-            requestedTrackIndex: _toInt(map['trackId']),
-            activeTrackIndex: _toInt(map['activeTrackId']),
-          ),
-        );
       case 'subtitleSelection':
         final how = map['how']?.toString() ?? 'unknown';
         _diag(
@@ -931,7 +909,6 @@
         ? mediaItem
         : payload['url']?.toString() ?? '';
     if (_disposed || url.isEmpty) return;
-    _subtitleRequestId = ++_nextSubtitleRequestId;
 
     final mediaType = payload['mediaType']?.toString() ?? 'video';
     final container = payload['container']?.toString();
@@ -1030,8 +1007,6 @@
       'preferredTextLanguage': preferredSubtitleLanguage,
       if (payload['externalSubtitles'] is List)
         'externalSubtitles': payload['externalSubtitles'],
-      if (payload['deferExternalSubtitleSelection'] == true)
-        'deferExternalSubtitleSelection': true,
       if (payload['audioTrackOrdinal'] is int)
         'audioTrackOrdinal': payload['audioTrackOrdinal'],
       'selectUndeterminedTextLanguage': false,
@@ -1090,7 +1065,6 @@
   }
 
   Future<void> _teardown(String command) async {
-    _subtitleRequestId = ++_nextSubtitleRequestId;
     // The watchdogs guard a single item's bring-up, so stopping has to stop
     // the timer too or it keeps warning about a player that was told to stop.
     _watchdogTimer?.cancel();
@@ -1281,9 +1255,7 @@
     bool isExternalSubtitle = false,
     String? externalSubtitleUrl,
   }) async {
-    final requestId = _subtitleRequestId = ++_nextSubtitleRequestId;
     await _invoke<void>('setSubtitleTrack', {
-      'requestId': requestId,
       'index': index,
       'isBitmapSubtitle': isBitmapSubtitle,
       'codec': subtitleCodec,
@@ -1300,13 +1272,11 @@
 
   @override
   Future<void> setEmbeddedCaptionTrack(int id) async {
-    _subtitleRequestId = ++_nextSubtitleRequestId;
     await _invoke<void>('setClosedCaptionTrack', {'id': id});
   }
 
   @override
   Future<void> disableSubtitleTrack() async {
-    _subtitleRequestId = ++_nextSubtitleRequestId;
     await _invoke<void>('disableSubtitleTrack');
   }
 
@@ -1475,7 +1445,6 @@
     _playingStream.close();
     _bufferingStream.close();
     _completedStream.close();
-    _subtitleFailures.close();
     _errorStream.close();
     _tracksChangedController.close();
   }
diff --git a/packages/moonfin_native_video/android/src/main/kotlin/org/moonfin/nativevideo/Media3VideoView.kt b/packages/moonfin_native_video/android/src/main/kotlin/org/moonfin/nativevideo/Media3VideoView.kt
--- a/packages/moonfin_native_video/android/src/main/kotlin/org/moonfin/nativevideo/Media3VideoView.kt
+++ b/packages/moonfin_native_video/android/src/main/kotlin/org/moonfin/nativevideo/Media3VideoView.kt
@@ -49,10 +49,12 @@
 import androidx.media3.common.util.TimestampAdjuster
 import androidx.media3.common.util.UnstableApi
 import androidx.media3.common.util.Util
-import androidx.media3.datasource.DataSource
+import androidx.media3.datasource.DataSourceInputStream
+import androidx.media3.datasource.DataSourceException
 import androidx.media3.datasource.DataSpec
 import androidx.media3.datasource.DefaultDataSource
 import androidx.media3.datasource.DefaultHttpDataSource
+import androidx.media3.datasource.HttpDataSource
 import androidx.media3.decoder.av1.Dav1dLibrary
 import androidx.media3.decoder.av1.Libdav1dVideoRenderer
 import androidx.media3.decoder.ffmpeg.FfmpegLibrary
@@ -92,9 +94,18 @@
 import io.github.peerless2012.ass.media.kt.withAssSupport
 import io.github.peerless2012.ass.media.parser.AssSubtitleParserFactory
 import io.github.peerless2012.ass.media.type.AssRenderType
+import okhttp3.Call
+import okhttp3.OkHttpClient
+import okhttp3.Request
+import okhttp3.Response
 import java.io.File
+import java.io.FileNotFoundException
+import java.io.InputStream
+import java.io.InterruptedIOException
+import java.io.IOException
 import java.nio.ByteBuffer
 import java.util.Locale
+import java.util.concurrent.TimeUnit
 import kotlin.math.roundToInt
 
 @OptIn(ExperimentalApi::class)
@@ -817,10 +828,20 @@
     private var pendingSubtitleIsBitmap: Boolean? = null
     private var pendingExternalSubtitleUrl: String? = null
     private var deferExternalSubtitleSelection = false
-    private var subtitleSelectionRequestId: Long? = null
-    private var subtitleWarmGeneration = 0
+    private var subtitleSelectionGeneration = 0L
+    private val subtitleHttpClient by lazy {
+        OkHttpClient.Builder()
+            .connectTimeout(120, TimeUnit.SECONDS)
+            .readTimeout(600, TimeUnit.SECONDS)
+            // Individual stalled reads time out; extraction has no total deadline.
+            .callTimeout(0, TimeUnit.MILLISECONDS)
+            .build()
+    }
+    private var subtitleRetry: Runnable? = null
+    private var subtitleRetryDelayMs = 2_000L
+    private var failedSubtitleUrl: String? = null
     private var warmingExtractionSubtitleUrl: String? = null
-    private val warmingExternalSubtitleUrls = mutableSetOf<String>()
+    private val warmingExternalSubtitleRequests = mutableMapOf<String, SubtitleWarmRequest>()
     private val warmedExternalSubtitleUrls = mutableSetOf<String>()
     private val extractionBackedExternalSubtitleUrls = mutableSetOf<String>()
     private var pendingAudioIndex: Int? = null
@@ -1084,46 +1105,14 @@
         }
 
         override fun onTracksChanged(tracks: androidx.media3.common.Tracks) {
-            val pendingExternalUrl = pendingExternalSubtitleUrl?.takeIf { it.isNotBlank() }
-
-            if (
-                pendingSubtitleIndex != null &&
-                pendingExternalUrl != null &&
-                pendingExternalUrl in warmedExternalSubtitleUrls &&
-                player.playbackState == Player.STATE_READY
+            val pendingIndex = pendingSubtitleIndex
+            val isExternal = !pendingExternalSubtitleUrl.isNullOrBlank()
+            if (!applyPendingSubtitle() && !isExternal &&
+                pendingIndex != null && pendingIndex in 1..trackCount(C.TRACK_TYPE_TEXT)
             ) {
-                // The merged text track can appear after the warm-up finishes.
-                applyWarmedPendingSubtitle()
-            }
-
-            pendingSubtitleIndex
-                ?.takeIf { pendingExternalUrl == null }
-                ?.let { index ->
-                if (selectTextTrack(index, null)) {
-                    clearDeferredExternalSubtitleSelection()
-                    selectedSubtitleCodec = pendingSubtitleCodec?.trim()?.lowercase()
-                    selectedSubtitleIsExternal = pendingSubtitleIsExternal ?: false
-                    selectedSubtitleIsBitmap = pendingSubtitleIsBitmap ?: false
-                    selectedExternalSubtitleUrl = pendingExternalSubtitleUrl?.takeIf { it.isNotBlank() }
-                    subtitleTrackEnabled = true
-                    applyTrackSelectorForCurrentSource()
-                    refreshSubtitleRendererMode()
-
-                    pendingSubtitleIndex = null
-                    pendingSubtitleCodec = null
-                    pendingSubtitleIsExternal = null
-                    pendingSubtitleIsBitmap = null
-                    pendingExternalSubtitleUrl = null
-                } else if (index in 1..trackCount(C.TRACK_TYPE_TEXT)) {
-                    // The target track exists but can't be selected (for
-                    // example an unsupported codec), so retrying on the next
-                    // tracks change won't help.
-                    pendingSubtitleIndex = null
-                    pendingSubtitleCodec = null
-                    pendingSubtitleIsExternal = null
-                    pendingSubtitleIsBitmap = null
-                    pendingExternalSubtitleUrl = null
-                }
+                // An existing unsupported embedded track cannot become selectable
+                // on a later callback. Missing tracks and external URLs stay pending.
+                clearPendingSubtitle()
             }
             pendingClosedCaptionId
                 ?.let { id ->
@@ -1472,7 +1461,6 @@
             "isExternalSubtitle" to if (pending) pendingSubtitleIsExternal else selectedSubtitleIsExternal,
             "isBitmapSubtitle" to if (pending) pendingSubtitleIsBitmap else selectedSubtitleIsBitmap,
             "externalSubtitleUrl" to if (pending) pendingExternalSubtitleUrl else selectedExternalSubtitleUrl,
-            "requestId" to subtitleSelectionRequestId,
         )
     }
 
@@ -1496,7 +1484,7 @@
             "caption" -> handleSetClosedCaptionTrack(selection)
             "off" -> {
                 subtitleTrackEnabled = false
-                clearDeferredExternalSubtitleSelection()
+                deferExternalSubtitleSelection = false
                 applyTrackSelectorForCurrentSource()
             }
         }
@@ -1507,7 +1495,7 @@
         lastSourceArguments = lastSourceArguments?.toMutableMap()?.apply {
             this["restoreSubtitleSelection"] = subtitleSelectionForRestore()
         }
-        subtitleWarmGeneration++
+        cancelSubtitlePreparation()
         lastPlaybackPositionMs = player.currentPosition
         isPlayerReleased = true
         isDisposed = true
@@ -2152,6 +2140,7 @@
                 }
 
                 "disableSubtitleTrack" -> {
+                    cancelSubtitlePreparation()
                     trackSelector.parameters = trackSelector.parameters
                         .buildUpon()
                         .clearOverridesOfType(C.TRACK_TYPE_TEXT)
@@ -2162,13 +2151,9 @@
                     selectedSubtitleIsBitmap = false
                     selectedExternalSubtitleUrl = null
                     subtitleTrackEnabled = false
-                    clearDeferredExternalSubtitleSelection()
-
-                    pendingSubtitleIndex = null
-                    pendingSubtitleCodec = null
-                    pendingSubtitleIsExternal = null
-                    pendingSubtitleIsBitmap = null
-                    pendingExternalSubtitleUrl = null
+                    deferExternalSubtitleSelection = false
+
+                    clearPendingSubtitle()
                     pendingClosedCaptionId = null
 
                     applyTrackSelectorForCurrentSource()
@@ -2313,6 +2298,7 @@
                 }
 
                 "disableSubtitleTrack" -> {
+                    cancelSubtitlePreparation()
                     trackSelector.parameters = trackSelector.parameters
                         .buildUpon()
                         .clearOverridesOfType(C.TRACK_TYPE_TEXT)
@@ -2323,12 +2309,8 @@
                     selectedSubtitleIsBitmap = false
                     selectedExternalSubtitleUrl = null
                     subtitleTrackEnabled = false
-                    clearDeferredExternalSubtitleSelection()
-                    pendingSubtitleIndex = null
-                    pendingSubtitleCodec = null
-                    pendingSubtitleIsExternal = null
-                    pendingSubtitleIsBitmap = null
-                    pendingExternalSubtitleUrl = null
+                    deferExternalSubtitleSelection = false
+                    clearPendingSubtitle()
                     pendingClosedCaptionId = null
                     applyTrackSelectorForCurrentSource()
                     clearAssSubtitleScript()
@@ -2432,9 +2414,9 @@
         subtitleEmbeddedStylesEnabled = args["subtitleEmbeddedStylesEnabled"] as? Boolean ?: true
         subtitleEmbeddedFontSizesEnabled = args["subtitleEmbeddedFontSizesEnabled"] as? Boolean ?: true
 
-        subtitleWarmGeneration++
-        warmingExtractionSubtitleUrl = null
-        warmingExternalSubtitleUrls.clear()
+        cancelSubtitlePreparation()
+        // Canceled workers release their own slots before a replacement starts.
+        // Keeping the slots here also serializes extraction across source changes.
         warmedExternalSubtitleUrls.clear()
         extractionBackedExternalSubtitleUrls.clear()
 
@@ -2464,7 +2446,6 @@
             val configuration = buildExternalSubtitleConfiguration(
                 subtitle,
                 configurationId,
-                isDefault = false,
             ) ?: return@forEach
 
             externalSubtitleConfigurations.add(configuration)
@@ -2488,11 +2469,7 @@
         deferExternalSubtitleSelection =
             !forceSubtitlesDisabledOnStart && externalSubtitleConfigurations.isNotEmpty()
         subtitleTrackEnabled = !forceSubtitlesDisabledOnStart
-        pendingSubtitleIndex = null
-        pendingSubtitleCodec = null
-        pendingSubtitleIsExternal = null
-        pendingSubtitleIsBitmap = null
-        pendingExternalSubtitleUrl = null
+        clearPendingSubtitle()
         // The first onTracksChanged applies this while the player is still
         // buffering, so playback starts on the requested track rather than
         // opening the container default and switching once it lands.
@@ -2688,7 +2665,7 @@
         // A canonical stop ends ownership of this source. Clear it before
         // touching the player because appPaused may already have released it,
         // and an immediately queued appResumed must not restore stale media.
-        subtitleWarmGeneration++
+        cancelSubtitlePreparation()
         pendingSubtitleIndex = null
         pendingExternalSubtitleUrl = null
         lastSourceArguments = null
@@ -3431,7 +3408,6 @@
     private fun buildExternalSubtitleConfiguration(
         args: Map<*, *>,
         id: Int,
-        isDefault: Boolean,
     ): MediaItem.SubtitleConfiguration? {
         val url = args["url"]?.toString() ?: return null
         val codec = args["codec"]?.toString()
@@ -3441,10 +3417,6 @@
         val subtitleBuilder = MediaItem.SubtitleConfiguration.Builder(parseUri(url))
             // ass-media matches selected Media3 text tracks back to libass tracks by ID.
             .setId(id.toString())
-
-        if (isDefault) {
-            subtitleBuilder.setSelectionFlags(C.SELECTION_FLAG_DEFAULT)
-        }
 
         val mimeType = codecToMimeType(codec)
         if (!mimeType.isNullOrEmpty()) {
@@ -3467,7 +3439,6 @@
         val configuration = buildExternalSubtitleConfiguration(
             subtitle,
             id,
-            isDefault = false,
         ) ?: return
         if (externalSubtitleConfigurations.any { it.uri == configuration.uri }) return
 
@@ -4093,36 +4064,71 @@
         }
     }
 
-    private fun warmPendingExternalSubtitle(retry: Boolean = false) {
+    // Call.cancel() can abort HTTP before headers arrive or while reading the body.
+    // The worker alone closes streams; closing them from the UI thread
+    // would race with open/read. Volatile publication also covers cancellation
+    // before the HTTP call has been created.
+    private class SubtitleWarmRequest(
+        val generation: Long,
+        private val client: OkHttpClient,
+    ) : Call.Factory {
+        @Volatile
+        var canceled = false
+            private set
+
+        @Volatile
+        private var call: Call? = null
+
+        override fun newCall(request: Request): Call = client.newCall(request).also {
+            call = it
+            if (canceled) it.cancel()
+        }
+
+        fun cancel() {
+            canceled = true
+            call?.cancel()
+        }
+    }
+
+    private fun warmPendingExternalSubtitle() {
+        if (isDisposed) return
         val url = pendingExternalSubtitleUrl?.takeIf { it.isNotBlank() } ?: return
         if (url in warmedExternalSubtitleUrls) {
-            applyWarmedPendingSubtitle()
+            applyPendingSubtitle()
             return
         }
-        if (url in warmingExternalSubtitleUrls) return
+        if (subtitleRetry != null || url == failedSubtitleUrl) return
+        if (url in warmingExternalSubtitleRequests) return
 
         val needsExtraction = url in extractionBackedExternalSubtitleUrls
         if (needsExtraction && warmingExtractionSubtitleUrl != null) return
 
-        warmingExternalSubtitleUrls.add(url)
+        val request = SubtitleWarmRequest(subtitleSelectionGeneration, subtitleHttpClient)
+        warmingExternalSubtitleRequests[url] = request
         if (needsExtraction) warmingExtractionSubtitleUrl = url
-        val generation = subtitleWarmGeneration
         val headers = currentHeaders
 
         Thread({
-            val succeeded = readSubtitle(url, headers)
+            val failure = readSubtitle(url, headers, request)
             mainHandler.post {
-                if (generation != subtitleWarmGeneration) return@post
-                warmingExternalSubtitleUrls.remove(url)
+                if (warmingExternalSubtitleRequests[url] !== request) return@post
+                warmingExternalSubtitleRequests.remove(url)
                 if (warmingExtractionSubtitleUrl == url) warmingExtractionSubtitleUrl = null
                 if (isDisposed) return@post
-                if (succeeded) warmedExternalSubtitleUrls.add(url)
-
+
+                // A new selection owns both success and failure, even for the
+                // same URL. Release the old slot and start the current request.
+                if (request.canceled || request.generation != subtitleSelectionGeneration) {
+                    warmPendingExternalSubtitle()
+                    return@post
+                }
+                if (failure == null) warmedExternalSubtitleUrls.add(url)
                 when {
                     pendingExternalSubtitleUrl != url -> warmPendingExternalSubtitle()
-                    succeeded -> applyWarmedPendingSubtitle()
-                    !retry -> warmPendingExternalSubtitle(retry = true)
-                    else -> clearPendingExternalSubtitleSelection(url)
+                    failure == null -> applyPendingSubtitle()
+                    canRetrySubtitle(url, failure) -> scheduleSubtitleRetry(url)
+                    // Preserve intent. A manual selection starts a fresh attempt.
+                    else -> failedSubtitleUrl = url
                 }
             }
         }, "MoonfinSubtitleWarm").start()
@@ -4130,65 +4136,127 @@
 
     // Complete Jellyfin's extraction outside Media3's merged loader. Selecting
     // the cold subtitle there can prevent the next HLS segment from loading.
-    private fun readSubtitle(url: String, headers: Map<String, String>): Boolean {
-        var dataSource: DataSource? = null
+    private fun readSubtitle(
+        url: String,
+        headers: Map<String, String>,
+        request: SubtitleWarmRequest,
+    ): Exception? {
+        var input: InputStream? = null
+        var response: Response? = null
         return try {
-            val httpFactory = DefaultHttpDataSource.Factory()
-                .setAllowCrossProtocolRedirects(true)
-                .setConnectTimeoutMs(120_000)
-                .setReadTimeoutMs(600_000)
-                .setDefaultRequestProperties(headers)
-            dataSource = DefaultDataSource.Factory(context, httpFactory).createDataSource()
-            dataSource.open(DataSpec.Builder().setUri(parseUri(url)).build())
+            if (request.canceled) throw InterruptedIOException()
+            val uri = parseUri(url)
+            val dataSpec = DataSpec.Builder().setUri(uri).build()
+            input = if (uri.scheme.equals("http", true) || uri.scheme.equals("https", true)) {
+                // Coil already exposes OkHttp; no extra Media3 adapter is needed.
+                val builder = Request.Builder().url(url)
+                headers.forEach { (name, value) -> builder.header(name, value) }
+                builder.header("Accept-Encoding", "identity")
+                response = request.newCall(builder.build()).execute()
+                if (!response.isSuccessful) {
+                    throw HttpDataSource.InvalidResponseCodeException(
+                        response.code, response.message, null, response.headers.toMultimap(),
+                        dataSpec, ByteArray(0),
+                    )
+                }
+                response.body?.byteStream() ?: throw IOException("Missing subtitle response body")
+            } else {
+                DataSourceInputStream(DefaultDataSource.Factory(context).createDataSource(), dataSpec)
+            }
             val buffer = ByteArray(64 * 1024)
-            while (dataSource.read(buffer, 0, buffer.size) != C.RESULT_END_OF_INPUT) {
-                // Read to EOF before making this URL selectable.
-            }
-            true
-        } catch (_: Exception) {
-            // Report failure without logging URLs that may contain credentials.
-            false
+            while (true) {
+                if (request.canceled) throw InterruptedIOException()
+                if (input.read(buffer) == C.RESULT_END_OF_INPUT) break
+            }
+            null
+        } catch (failure: Exception) {
+            failure
         } finally {
-            runCatching { dataSource?.close() }
-        }
-    }
-
-    private fun clearPendingExternalSubtitleSelection(url: String) {
-        if (pendingExternalSubtitleUrl != url) return
-
-        val failedIndex = pendingSubtitleIndex
-        val activeIndex = activeSubtitleIndex()
-        Media3Bridge.emitEvent(
-            mapOf(
-                "event" to "subtitleSelectionFailed",
-                "requestId" to subtitleSelectionRequestId,
-                "trackId" to failedIndex,
-                "activeTrackId" to activeIndex,
-                "reason" to "warmFailed",
-            ),
-        )
+            runCatching { input?.close() }
+            runCatching { response?.close() }
+        }
+    }
+
+    private fun canRetrySubtitle(url: String, failure: Exception): Boolean {
+        // File/content URIs cannot recover through a network retry policy.
+        val scheme = parseUri(url).scheme
+        if (!scheme.equals("http", true) && !scheme.equals("https", true)) return false
+
+        val causes = generateSequence<Throwable>(failure) { it.cause }.take(16).toList()
+        if (causes.any {
+                it is FileNotFoundException || it is SecurityException ||
+                    it is java.net.MalformedURLException ||
+                    // OkHttp reports truncated response bodies as protocol errors.
+                    (it is java.net.ProtocolException &&
+                        it.message != "unexpected end of stream") ||
+                    it is java.net.UnknownServiceException ||
+                    it is java.security.cert.CertificateException ||
+                    it is javax.net.ssl.SSLPeerUnverifiedException ||
+                    it is HttpDataSource.CleartextNotPermittedException ||
+                    it is HttpDataSource.InvalidContentTypeException
+            }
+        ) return false
+        val response = causes.filterIsInstance<HttpDataSource.InvalidResponseCodeException>()
+            .firstOrNull()
+        if (response != null) {
+            return response.responseCode == 408 || response.responseCode == 429 ||
+                response.responseCode in 500..599
+        }
+        if (causes.filterIsInstance<DataSourceException>().any {
+                it.reason == PlaybackException.ERROR_CODE_IO_FILE_NOT_FOUND ||
+                    it.reason == PlaybackException.ERROR_CODE_IO_NO_PERMISSION ||
+                    it.reason == PlaybackException.ERROR_CODE_IO_CLEARTEXT_NOT_PERMITTED ||
+                    it.reason == PlaybackException.ERROR_CODE_IO_READ_POSITION_OUT_OF_RANGE ||
+                    it.reason == PlaybackException.ERROR_CODE_FAILED_RUNTIME_CHECK
+            }
+        ) return false
+        return failure is IOException
+    }
+
+    private fun scheduleSubtitleRetry(url: String) {
+        val generation = subtitleSelectionGeneration
+        val delayMs = subtitleRetryDelayMs
+        subtitleRetryDelayMs = (delayMs * 2).coerceAtMost(30_000L)
+        val retry = Runnable {
+            subtitleRetry = null
+            if (!isDisposed && generation == subtitleSelectionGeneration &&
+                pendingExternalSubtitleUrl == url
+            ) {
+                warmPendingExternalSubtitle()
+            }
+        }
+        subtitleRetry = retry
+        mainHandler.postDelayed(retry, delayMs)
+    }
+
+    private fun cancelSubtitlePreparation() {
+        subtitleSelectionGeneration++
+        subtitleRetry?.let { mainHandler.removeCallbacks(it) }
+        subtitleRetry = null
+        subtitleRetryDelayMs = 2_000L
+        failedSubtitleUrl = null
+        warmingExternalSubtitleRequests.values.forEach { it.cancel() }
+    }
+
+    private fun clearPendingSubtitle() {
         pendingSubtitleIndex = null
         pendingSubtitleCodec = null
         pendingSubtitleIsExternal = null
         pendingSubtitleIsBitmap = null
         pendingExternalSubtitleUrl = null
-
-        if (deferExternalSubtitleSelection) {
-            subtitleTrackEnabled = false
-            clearDeferredExternalSubtitleSelection()
-            applyTrackSelectorForCurrentSource()
-        }
-    }
-
-    private fun applyWarmedPendingSubtitle() {
-        val index = pendingSubtitleIndex ?: return
-        val url = pendingExternalSubtitleUrl?.takeIf { it.isNotBlank() } ?: return
-        if (url !in warmedExternalSubtitleUrls || player.playbackState != Player.STATE_READY) return
-
-        if (!selectTextTrack(index, url)) return
-
-        clearDeferredExternalSubtitleSelection()
-
+    }
+
+    // External subtitles wait for warm-up and READY. Embedded tracks can be
+    // selected during buffering, before the first frame, as they were before.
+    private fun applyPendingSubtitle(): Boolean {
+        val index = pendingSubtitleIndex ?: return false
+        val url = pendingExternalSubtitleUrl?.takeIf { it.isNotBlank() }
+        if (url != null &&
+            (url !in warmedExternalSubtitleUrls || player.playbackState != Player.STATE_READY)
+        ) return false
+        if (!selectTextTrack(index, url)) return false
+
+        deferExternalSubtitleSelection = false
         selectedSubtitleCodec = pendingSubtitleCodec?.trim()?.lowercase()
         selectedSubtitleIsExternal = pendingSubtitleIsExternal ?: false
         selectedSubtitleIsBitmap = pendingSubtitleIsBitmap ?: false
@@ -4196,21 +4264,8 @@
         subtitleTrackEnabled = true
         applyTrackSelectorForCurrentSource()
         refreshSubtitleRendererMode()
-
-        pendingSubtitleIndex = null
-        pendingSubtitleCodec = null
-        pendingSubtitleIsExternal = null
-        pendingSubtitleIsBitmap = null
-        pendingExternalSubtitleUrl = null
-    }
-
-    private fun clearDeferredExternalSubtitleSelection() {
-        if (!deferExternalSubtitleSelection) return
-
-        deferExternalSubtitleSelection = false
-        lastSourceArguments = lastSourceArguments?.toMutableMap()?.apply {
-            remove("deferExternalSubtitleSelection")
-        }
+        clearPendingSubtitle()
+        return true
     }
 
     // Keep server stream positions stable even when Media3 rejects a track.
@@ -4221,7 +4276,7 @@
         val isExternal = args?.get("isExternalSubtitle") as? Boolean ?: false
         val isBitmap = args?.get("isBitmapSubtitle") as? Boolean ?: false
         val externalUrl = args?.get("externalSubtitleUrl")?.toString()
-        subtitleSelectionRequestId = (args?.get("requestId") as? Number)?.toLong()
+        cancelSubtitlePreparation()
 
         pendingClosedCaptionId = null
         pendingSubtitleIndex = index
@@ -4232,25 +4287,8 @@
 
         if (!externalUrl.isNullOrBlank()) {
             warmPendingExternalSubtitle()
-            return
-        }
-
-        val selected = selectTextTrack(index, externalUrl)
-        if (selected) {
-            clearDeferredExternalSubtitleSelection()
-            selectedSubtitleCodec = codec?.trim()?.lowercase()
-            selectedSubtitleIsExternal = isExternal
-            selectedSubtitleIsBitmap = isBitmap
-            selectedExternalSubtitleUrl = externalUrl?.takeIf { it.isNotBlank() }
-            subtitleTrackEnabled = true
-            applyTrackSelectorForCurrentSource()
-            refreshSubtitleRendererMode()
-
-            pendingSubtitleIndex = null
-            pendingSubtitleCodec = null
-            pendingSubtitleIsExternal = null
-            pendingSubtitleIsBitmap = null
-            pendingExternalSubtitleUrl = null
+        } else {
+            applyPendingSubtitle()
         }
     }
 
@@ -4258,13 +4296,10 @@
     // there yet when the viewer asks for them. The request is kept pending and
     // retried on every track change, the same way a subtitle request is.
     private fun handleSetClosedCaptionTrack(args: Map<*, *>?) {
+        cancelSubtitlePreparation()
         val id = (args?.get("id") as? Number)?.toInt() ?: 0
 
-        pendingSubtitleIndex = null
-        pendingSubtitleCodec = null
-        pendingSubtitleIsExternal = null
-        pendingSubtitleIsBitmap = null
-        pendingExternalSubtitleUrl = null
+        clearPendingSubtitle()
         pendingClosedCaptionId = id
 
         if (selectClosedCaptionTrack(id)) {
@@ -4281,7 +4316,7 @@
     }
 
     private fun applyClosedCaptionSelection() {
-        clearDeferredExternalSubtitleSelection()
+        deferExternalSubtitleSelection = false
         pendingClosedCaptionId = null
         selectedSubtitleCodec = null
         selectedSubtitleIsExternal = false
diff --git a/packages/playback_core/lib/src/playback_manager.dart b/packages/playback_core/lib/src/playback_manager.dart
--- a/packages/playback_core/lib/src/playback_manager.dart
+++ b/packages/playback_core/lib/src/playback_manager.dart
@@ -391,7 +391,6 @@
     double? normalizationGainDb,
     String? hybridAudioUrl,
     List<Map<String, dynamic>> externalSubtitles = const [],
-    bool deferExternalSubtitleSelection = false,
     bool isLive = false,
     bool autoPlay = true,
   }) {
@@ -492,8 +491,6 @@
       if (hybridAudioUrl != null && hybridAudioUrl.isNotEmpty)
         'hybridAudioUrl': hybridAudioUrl,
       if (externalSubtitles.isNotEmpty) 'externalSubtitles': externalSubtitles,
-      if (deferExternalSubtitleSelection)
-        'deferExternalSubtitleSelection': true,
       'isLive': isLive,
       'mediaType':
           (resolvedMediaType == 'audio' || resolvedMediaType == 'video')
@@ -741,50 +738,12 @@
       backend.completedStream.listen(_onTrackCompleted),
     ]);
 
-    if (backend is ReportsSubtitleSelectionFailures) {
-      _streamSubs.add(
-        (backend as ReportsSubtitleSelectionFailures)
-            .subtitleSelectionFailures
-            .listen(_onSubtitleSelectionFailure),
-      );
-    }
     final errorStream = backend.errorStream;
     if (errorStream != null) {
       _streamSubs.add(
         errorStream.listen(_onBackendErrorEvent, onError: (_) {}),
       );
     }
-  }
-
-  void _onSubtitleSelectionFailure(SubtitleSelectionFailure failure) {
-    final requested = _subtitleStreamIndex;
-    if (requested == null ||
-        requested < 0 ||
-        _mpvTrackIdForStream(requested, 'Subtitle') != failure.requestedTrackIndex) {
-      return;
-    }
-    final active = failure.activeTrackIndex > 0
-        ? _streamIndexForMpvTrackId(failure.activeTrackIndex, 'Subtitle')
-        : -1;
-    if (active == null) return;
-    _subtitleStreamIndex = active;
-    _lastExplicitSubtitleEnabled = active >= 0;
-    _lastExplicitSubtitleLanguage = null;
-    if (active >= 0) {
-      final stream = _currentMediaStreams.firstWhere(
-        (stream) => stream['Type'] == 'Subtitle' && stream['Index'] == active,
-        orElse: () => const <String, dynamic>{},
-      );
-      _lastExplicitSubtitleLanguage = _extractLanguage(stream);
-    }
-    final item = queueService.currentItem;
-    if (item != null) {
-      onSubtitleTrackChanged?.call(
-        MediaStreamResolver.extractItemId(item),
-        active >= 0 ? active : null,
-      );
-    }
-    _diagnosticLogger?.call('Subtitle selection failed; retained stream $active.');
   }
 
   void _disposeStreamSubs() {
@@ -1751,13 +1710,6 @@
       }
     }
 
-    final deferExternalSubtitleSelection =
-        _subtitleStreamIndex != null &&
-        _subtitleStreamIndex != -1 &&
-        preloadedExternalSubtitles.any(
-          (subtitle) => subtitle['streamIndex'] == _subtitleStreamIndex,
-        );
-
     try {
       final backendMediaPayload = _buildBackendMediaPayload(
         url: resolution.streamUrl,
@@ -1771,7 +1723,6 @@
         normalizationGainDb: resolution.normalizationGainDb,
         hybridAudioUrl: resolution.hybridAudioUrl,
         externalSubtitles: preloadedExternalSubtitles,
-        deferExternalSubtitleSelection: deferExternalSubtitleSelection,
         isLive: resolution.liveStreamId != null,
         autoPlay: autoPlay,
       );
diff --git a/packages/playback_core/lib/src/player_backend.dart b/packages/playback_core/lib/src/player_backend.dart
--- a/packages/playback_core/lib/src/player_backend.dart
+++ b/packages/playback_core/lib/src/player_backend.dart
@@ -49,21 +49,6 @@
 
 /// Backend receives effective external subtitles with the initial media source.
 abstract interface class PreloadsExternalSubtitles {}
-
-/// A requested subtitle could not replace the currently active track.
-class SubtitleSelectionFailure {
-  const SubtitleSelectionFailure({
-    required this.requestedTrackIndex,
-    required this.activeTrackIndex,
-  });
-
-  final int requestedTrackIndex;
-  final int activeTrackIndex;
-}
-
-abstract interface class ReportsSubtitleSelectionFailures {
-  Stream<SubtitleSelectionFailure> get subtitleSelectionFailures;
-}
 
 abstract class PlayerBackend {
   Future<void> play(
MOONFIN_REVISED_RETRY_FIX
cat > "$patch_dir/diagnostics.patch" <<'MOONFIN_REVISED_RETRY_DIAGNOSTICS'
diff --git a/lib/playback/media3_player_backend.dart b/lib/playback/media3_player_backend.dart
--- a/lib/playback/media3_player_backend.dart
+++ b/lib/playback/media3_player_backend.dart
@@ -313,6 +313,8 @@
           '${_toInt(map['elapsedMs'])}ms since last feed)',
           level: LogLevel.warning,
         );
+      case 'subtitleWarmDiagnostic':
+        _diag('Media3 subtitle warm: ${map['message'] ?? ''}');
       case 'subtitleSelection':
         final how = map['how']?.toString() ?? 'unknown';
         _diag(
diff --git a/packages/moonfin_native_video/android/src/main/kotlin/org/moonfin/nativevideo/Media3VideoView.kt b/packages/moonfin_native_video/android/src/main/kotlin/org/moonfin/nativevideo/Media3VideoView.kt
--- a/packages/moonfin_native_video/android/src/main/kotlin/org/moonfin/nativevideo/Media3VideoView.kt
+++ b/packages/moonfin_native_video/android/src/main/kotlin/org/moonfin/nativevideo/Media3VideoView.kt
@@ -829,6 +829,7 @@
     private var pendingExternalSubtitleUrl: String? = null
     private var deferExternalSubtitleSelection = false
     private var subtitleSelectionGeneration = 0L
+    private var subtitleWarmAttempt = 0L
     private val subtitleHttpClient by lazy {
         OkHttpClient.Builder()
             .connectTimeout(120, TimeUnit.SECONDS)
@@ -4108,10 +4109,32 @@
         if (needsExtraction) warmingExtractionSubtitleUrl = url
         val headers = currentHeaders
 
+        val attempt = ++subtitleWarmAttempt
+        val track = pendingSubtitleIndex
+        val startedMs = SystemClock.elapsedRealtime()
+        subtitleWarmDiagnostic(
+            "attempt=$attempt generation=${request.generation} track=$track started extraction=$needsExtraction",
+        )
         Thread({
-            val failure = readSubtitle(url, headers, request)
+            var bytesRead = 0L
+            val failure = readSubtitle(url, headers, request) { bytesRead = it }
+            val elapsedMs = SystemClock.elapsedRealtime() - startedMs
             mainHandler.post {
                 if (warmingExternalSubtitleRequests[url] !== request) return@post
+                val status = generateSequence<Throwable>(failure) { it.cause }.take(16)
+                    .filterIsInstance<HttpDataSource.InvalidResponseCodeException>()
+                    .firstOrNull()?.responseCode
+                val stillRequested = !isDisposed && !request.canceled &&
+                    request.generation == subtitleSelectionGeneration && pendingExternalSubtitleUrl == url
+                val outcome = if (failure == null) "downloaded" else "failed"
+                subtitleWarmDiagnostic(
+                    "attempt=$attempt generation=${request.generation} track=$track $outcome " +
+                        "elapsedMs=$elapsedMs bytes=$bytesRead http=$status " +
+                        "error=${failure?.javaClass?.simpleName} " +
+                        "cause=${failure?.cause?.javaClass?.simpleName} " +
+                        "canceled=${request.canceled} stillRequested=$stillRequested " +
+                        "retryable=${failure?.let { canRetrySubtitle(url, it) }}",
+                )
                 warmingExternalSubtitleRequests.remove(url)
                 if (warmingExtractionSubtitleUrl == url) warmingExtractionSubtitleUrl = null
                 if (isDisposed) return@post
@@ -4140,9 +4163,11 @@
         url: String,
         headers: Map<String, String>,
         request: SubtitleWarmRequest,
+        onBytesRead: (Long) -> Unit,
     ): Exception? {
         var input: InputStream? = null
         var response: Response? = null
+        var bytesRead = 0L
         return try {
             if (request.canceled) throw InterruptedIOException()
             val uri = parseUri(url)
@@ -4166,15 +4191,25 @@
             val buffer = ByteArray(64 * 1024)
             while (true) {
                 if (request.canceled) throw InterruptedIOException()
-                if (input.read(buffer) == C.RESULT_END_OF_INPUT) break
+                val count = input.read(buffer)
+                if (count == C.RESULT_END_OF_INPUT) break
+                bytesRead += count
             }
             null
         } catch (failure: Exception) {
             failure
         } finally {
+            onBytesRead(bytesRead)
             runCatching { input?.close() }
             runCatching { response?.close() }
         }
+    }
+
+    private fun subtitleWarmDiagnostic(message: String) {
+        // Constructed metadata only: no URL, headers, exception message or subtitle text.
+        Media3Bridge.emitEvent(
+            mapOf("event" to "subtitleWarmDiagnostic", "message" to "view=$platformViewId $message"),
+        )
     }
 
     private fun canRetrySubtitle(url: String, failure: Exception): Boolean {
@@ -4226,10 +4261,17 @@
             }
         }
         subtitleRetry = retry
+        subtitleWarmDiagnostic("generation=$generation track=$pendingSubtitleIndex retry scheduled delayMs=$delayMs")
         mainHandler.postDelayed(retry, delayMs)
     }
 
     private fun cancelSubtitlePreparation() {
+        val active = warmingExternalSubtitleRequests.values.count { !it.canceled }
+        if (active > 0 || subtitleRetry != null) {
+            subtitleWarmDiagnostic(
+                "generation=$subtitleSelectionGeneration cancel active=$active scheduledRetry=${subtitleRetry != null}",
+            )
+        }
         subtitleSelectionGeneration++
         subtitleRetry?.let { mainHandler.removeCallbacks(it) }
         subtitleRetry = null
MOONFIN_REVISED_RETRY_DIAGNOSTICS

# Validate both diffs together before changing the working files or real index.
GIT_INDEX_FILE="$patch_dir/index" git read-tree HEAD
GIT_INDEX_FILE="$patch_dir/index" git apply --cached --whitespace=error-all "$patch_dir/fix.patch"
GIT_INDEX_FILE="$patch_dir/index" git apply --cached --check --whitespace=error-all "$patch_dir/diagnostics.patch"
git apply --check --whitespace=error-all "$patch_dir/fix.patch"
git apply --whitespace=error-all "$patch_dir/fix.patch"
git diff --check -- "${files[@]}"
git commit --only -m 'Keep requested Media3 subtitles with cancellable retries' -- "${files[@]}"
fix_commit=$(git rev-parse HEAD)
echo "Functional fix committed: $fix_commit"

git apply --check --whitespace=error-all "$patch_dir/diagnostics.patch"
git apply --whitespace=error-all "$patch_dir/diagnostics.patch"
git diff --check -- "${diagnostic_files[@]}"
git commit --only -m 'TEMP: trace Media3 subtitle preparation and cancellation' -- "${diagnostic_files[@]}"
diagnostic_commit=$(git rev-parse HEAD)
echo "Temporary diagnostics committed: $diagnostic_commit"
echo "To remove only temporary diagnostics later: git revert $diagnostic_commit"
git --no-pager log -2 --oneline
git status --short
echo 'Ready for your manual push and Android workflow run.'
)
