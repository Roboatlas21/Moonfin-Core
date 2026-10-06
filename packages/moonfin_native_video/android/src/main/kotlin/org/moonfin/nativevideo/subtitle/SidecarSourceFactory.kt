package org.moonfin.nativevideo.subtitle

import android.util.Log
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.HttpDataSource
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.exoplayer.source.loadOnlyOnceSelected
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy
import androidx.media3.extractor.Extractor
import androidx.media3.extractor.ExtractorInput
import androidx.media3.extractor.ExtractorOutput
import androidx.media3.extractor.ExtractorsFactory
import androidx.media3.extractor.PositionHolder
import androidx.media3.extractor.SeekMap
import androidx.media3.extractor.text.SubtitleExtractor
import androidx.media3.extractor.text.SubtitleParser
import org.moonfin.nativevideo.Media3Bridge
import java.io.IOException

/**
 * Builds a media source for one sideloaded subtitle the way
 * DefaultMediaSourceFactory does, which has to be repeated here because that
 * factory is final.
 *
 * The file is only fetched once its track is selected. A server extracting
 * subtitles out of a large file can take minutes to answer the first time,
 * and a source that read every file at prepare couldn't start playback until
 * the last of them came back.
 */
@UnstableApi
internal object SidecarSourceFactory {

    fun create(
        configuration: MediaItem.SubtitleConfiguration,
        dataSourceFactory: DataSource.Factory,
        parserFactory: SubtitleParser.Factory,
    ): MediaSource {
        val format = Format.Builder()
            .setSampleMimeType(configuration.mimeType)
            .setLanguage(configuration.language)
            .setSelectionFlags(configuration.selectionFlags)
            .setRoleFlags(configuration.roleFlags)
            .setLabel(configuration.label)
            .setId(configuration.id)
            .build()
        val canParse = parserFactory.supportsFormat(format)
        val extractorsFactory = ExtractorsFactory {
            arrayOf<Extractor>(
                if (canParse) {
                    SubtitleExtractor(parserFactory.create(format), /* format= */ null)
                } else {
                    UnknownSubtitlesExtractor(format)
                },
            )
        }
        val announcedFormat = if (canParse) {
            format.buildUpon()
                .setSampleMimeType(MimeTypes.APPLICATION_MEDIA3_CUES)
                .setCodecs(format.sampleMimeType)
                .setCueReplacementBehavior(parserFactory.getCueReplacementBehavior(format))
                .build()
        } else {
            format
        }
        return ProgressiveMediaSource.Factory(dataSourceFactory, extractorsFactory)
            .setLoadErrorHandlingPolicy(SubtitleRetryLoggingPolicy)
            .loadOnlyOnceSelected(SubtitleExtractor.TRACK_ID, announcedFormat)
            .createMediaSource(MediaItem.fromUri(configuration.uri))
    }
}

/**
 * Diagnostic-only wrapper around Media3's stock policy. Every decision still
 * comes from DefaultLoadErrorHandlingPolicy; this only records enough timing
 * and error-count detail to see when the stock retry budget is exhausted.
 */
@UnstableApi
private object SubtitleRetryLoggingPolicy : DefaultLoadErrorHandlingPolicy() {
    private const val TAG = "MoonfinSubtitle"
    private val lastElapsedMsByTask = mutableMapOf<Long, Long>()
    private val lastRetryDelayMsByTask = mutableMapOf<Long, Long>()

    override fun getRetryDelayMsFor(loadErrorInfo: LoadErrorHandlingPolicy.LoadErrorInfo): Long {
        val load = loadErrorInfo.loadEventInfo
        val previousElapsedMs = lastElapsedMsByTask.put(load.loadTaskId, load.loadDurationMs) ?: 0L
        val previousRetryDelayMs = lastRetryDelayMsByTask[load.loadTaskId] ?: 0L
        val attemptMs = (load.loadDurationMs - previousElapsedMs - previousRetryDelayMs).coerceAtLeast(0L)
        val retryDelayMs = super.getRetryDelayMsFor(loadErrorInfo)
        lastRetryDelayMsByTask[load.loadTaskId] = if (retryDelayMs == C.TIME_UNSET) 0L else retryDelayMs
        val stockMinRetries = super.getMinimumLoadableRetryCount(loadErrorInfo.mediaLoadData.dataType)
        val stockBudgetExhausted = loadErrorInfo.errorCount > stockMinRetries
        val httpStatus = loadErrorInfo.exception.httpStatusCode()
        val outcome = when {
            retryDelayMs == C.TIME_UNSET -> "FATAL_POLICY"
            stockBudgetExhausted -> "STOCK_RETRY_BUDGET_EXHAUSTED"
            else -> "RETRY_ALLOWED"
        }

        Log.w(
            TAG,
            "[subtitle_media3] load_error " +
                "task=${load.loadTaskId} error_count=${loadErrorInfo.errorCount} " +
                "stock_min_retries=$stockMinRetries " +
                "total_attempts=${loadErrorInfo.errorCount} " +
                "attempt_ms=$attemptMs total_ms=${load.loadDurationMs} " +
                "retry_delay_ms=${if (retryDelayMs == C.TIME_UNSET) "none" else retryDelayMs} " +
                "http_status=${httpStatus ?: "none"} outcome=$outcome " +
                "exception=${loadErrorInfo.exception.javaClass.simpleName}",
        )
        Media3Bridge.emitEvent(
            mapOf(
                "event" to "subtitleRetryDiagnostic",
                "loadTaskId" to load.loadTaskId,
                "errorCount" to loadErrorInfo.errorCount,
                "stockMinRetries" to stockMinRetries,
                "totalAttempts" to loadErrorInfo.errorCount,
                "attemptMs" to attemptMs,
                "totalMs" to load.loadDurationMs,
                "retryDelayMs" to if (retryDelayMs == C.TIME_UNSET) -1L else retryDelayMs,
                "httpStatus" to (httpStatus ?: -1),
                "outcome" to outcome,
                "exception" to loadErrorInfo.exception.javaClass.simpleName,
            ),
        )
        return retryDelayMs
    }

    override fun onLoadTaskConcluded(loadTaskId: Long) {
        lastElapsedMsByTask.remove(loadTaskId)
        lastRetryDelayMsByTask.remove(loadTaskId)
        super.onLoadTaskConcluded(loadTaskId)
    }
}

private fun IOException.httpStatusCode(): Int? {
    var current: Throwable? = this
    repeat(8) {
        if (current is HttpDataSource.InvalidResponseCodeException) {
            return current.responseCode
        }
        current = current?.cause ?: return null
    }
    return null
}

/**
 * Announces a text track no parser understands so it still shows in the
 * track list, then drains the file. A copy of the private class inside
 * DefaultMediaSourceFactory.
 */
@UnstableApi
private class UnknownSubtitlesExtractor(private val format: Format) : Extractor {

    @Throws(IOException::class)
    override fun sniff(input: ExtractorInput): Boolean = true

    override fun init(output: ExtractorOutput) {
        val trackOutput = output.track(SubtitleExtractor.TRACK_ID, C.TRACK_TYPE_TEXT)
        output.seekMap(SeekMap.Unseekable(C.TIME_UNSET))
        output.endTracks()
        trackOutput.format(
            format.buildUpon()
                .setSampleMimeType(MimeTypes.TEXT_UNKNOWN)
                .setCodecs(format.sampleMimeType)
                .build(),
        )
    }

    @Throws(IOException::class)
    override fun read(input: ExtractorInput, seekPosition: PositionHolder): Int {
        val skipResult = input.skip(Int.MAX_VALUE)
        return if (skipResult == C.RESULT_END_OF_INPUT) Extractor.RESULT_END_OF_INPUT else Extractor.RESULT_CONTINUE
    }

    override fun seek(position: Long, timeUs: Long) {}

    override fun release() {}
}
