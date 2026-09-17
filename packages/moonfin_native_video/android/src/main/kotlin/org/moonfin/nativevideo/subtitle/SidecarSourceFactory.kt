package org.moonfin.nativevideo.subtitle

import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.TrackGroup
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.decoder.DecoderInputBuffer
import androidx.media3.exoplayer.FormatHolder
import androidx.media3.exoplayer.LoadingInfo
import androidx.media3.exoplayer.SeekParameters
import androidx.media3.exoplayer.source.MediaPeriod
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.exoplayer.source.SampleStream
import androidx.media3.exoplayer.source.TrackGroupArray
import androidx.media3.exoplayer.source.WrappingMediaSource
import androidx.media3.exoplayer.trackselection.ExoTrackSelection
import androidx.media3.exoplayer.trackselection.FixedTrackSelection
import androidx.media3.exoplayer.upstream.Allocator
import androidx.media3.extractor.Extractor
import androidx.media3.extractor.ExtractorInput
import androidx.media3.extractor.ExtractorOutput
import androidx.media3.extractor.ExtractorsFactory
import androidx.media3.extractor.PositionHolder
import androidx.media3.extractor.SeekMap
import androidx.media3.extractor.text.SubtitleExtractor
import androidx.media3.extractor.text.SubtitleParser
import java.io.IOException

/**
 * Lists subtitle tracks without opening their URLs. Jellyfin can take minutes
 * to extract a subtitle, so wait until the track is selected before loading it.
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
        val supported = parserFactory.supportsFormat(format)
        val trackFormat = format.buildUpon()
            .setSampleMimeType(if (supported) MimeTypes.APPLICATION_MEDIA3_CUES else MimeTypes.TEXT_UNKNOWN)
            .setCodecs(format.sampleMimeType)
            .apply {
                if (supported) {
                    setCueReplacementBehavior(parserFactory.getCueReplacementBehavior(format))
                }
            }
            .build()
        val extractorsFactory = ExtractorsFactory {
            arrayOf<Extractor>(
                if (supported) {
                    SubtitleExtractor(parserFactory.create(format), format)
                } else {
                    UnknownSubtitlesExtractor(format)
                },
            )
        }
        val source = ProgressiveMediaSource.Factory(dataSourceFactory, extractorsFactory)
            .createMediaSource(MediaItem.fromUri(configuration.uri))
        return object : WrappingMediaSource(source) {
            override fun createPeriod(
                id: MediaSource.MediaPeriodId,
                allocator: Allocator,
                startPositionUs: Long,
            ): MediaPeriod = LazySubtitlePeriod(
                trackFormat,
                createChild = { positionUs -> mediaSource.createPeriod(id, allocator, positionUs) },
                releaseChild = { period -> mediaSource.releasePeriod(period) },
            )

            override fun releasePeriod(mediaPeriod: MediaPeriod) {
                (mediaPeriod as LazySubtitlePeriod).release()
            }
        }
    }
}

/** Exposes one text track before loading it. All calls run on the playback thread. */
@UnstableApi
private class LazySubtitlePeriod(
    format: Format,
    private val createChild: (Long) -> MediaPeriod,
    private val releaseChild: (MediaPeriod) -> Unit,
) : MediaPeriod, MediaPeriod.Callback {
    private val tracks = TrackGroupArray(TrackGroup("0", format))
    private var callback: MediaPeriod.Callback? = null
    private var child: MediaPeriod? = null
    private var prepared = false
    private var stream: DeferredSubtitleStream? = null
    private val selected: Boolean get() = stream != null
    private val childStreams = arrayOfNulls<SampleStream>(1)
    private var positionUs = 0L
    private var endPositionUs = C.TIME_END_OF_SOURCE
    private val preparedChild: MediaPeriod? get() = child?.takeIf { prepared }

    override fun prepare(callback: MediaPeriod.Callback, positionUs: Long) {
        this.callback = callback
        this.positionUs = positionUs
        callback.onPrepared(this)
    }

    override fun getTrackGroups(): TrackGroupArray = tracks

    override fun maybeThrowPrepareError() {
        if (selected) child?.maybeThrowPrepareError()
    }

    override fun selectTracks(
        selections: Array<out ExoTrackSelection?>,
        mayRetainStreamFlags: BooleanArray,
        streams: Array<SampleStream?>,
        streamResetFlags: BooleanArray,
        positionUs: Long,
    ): Long {
        this.positionUs = positionUs
        val index = selections.indexOfFirst { it != null }
        val retain = index >= 0 && selected && streams[index] === stream && mayRetainStreamFlags[index]
        if (!retain) stream = if (index >= 0) DeferredSubtitleStream() else null
        for (i in streams.indices) {
            streams[i] = if (i == index) stream else null
        }
        if (selected && !retain) streamResetFlags[index] = true

        val current = child
        if (!selected && !prepared) {
            release()
        } else if (prepared) {
            // Reuse the prepared period when a timing change reselects the track.
            // Media3 cancels any pending read when the track is disabled.
            val reset = selectChild(checkNotNull(current), retain)
            if (selected && reset) streamResetFlags[index] = true
        } else if (current == null) {
            val period = createChild(positionUs)
            child = period
            period.prepare(this, positionUs)
        }
        return positionUs
    }

    private fun selectChild(period: MediaPeriod, retain: Boolean): Boolean {
        // The child has just one track, so a fixed selection is enough.
        val track = if (selected) FixedTrackSelection(period.trackGroups[0], 0) else null
        val reset = BooleanArray(1)
        val selectedPositionUs = period.selectTracks(
            arrayOf(track), booleanArrayOf(retain), childStreams, reset, positionUs,
        )
        check(selectedPositionUs == positionUs)
        return reset[0]
    }

    override fun onPrepared(mediaPeriod: MediaPeriod) {
        if (mediaPeriod !== child || !selected) return
        prepared = true
        mediaPeriod.setEndPositionUs(endPositionUs)
        selectChild(mediaPeriod, retain = false)
        callback?.onContinueLoadingRequested(this)
    }

    override fun onContinueLoadingRequested(source: MediaPeriod) {
        if (source === child && selected) callback?.onContinueLoadingRequested(this)
    }

    fun release() {
        val previous = child
        child = null
        prepared = false
        stream = null
        childStreams[0] = null
        if (previous != null) releaseChild(previous)
    }

    override fun discardBuffer(positionUs: Long, toKeyframe: Boolean) {
        preparedChild?.discardBuffer(positionUs, toKeyframe)
    }

    override fun readDiscontinuity(): Long =
        if (selected) preparedChild?.readDiscontinuity() ?: C.TIME_UNSET else C.TIME_UNSET

    override fun seekToUs(positionUs: Long): Long {
        this.positionUs = positionUs
        return preparedChild?.seekToUs(positionUs) ?: positionUs
    }

    override fun getAdjustedSeekPositionUs(positionUs: Long, seekParameters: SeekParameters): Long =
        preparedChild?.getAdjustedSeekPositionUs(positionUs, seekParameters) ?: positionUs

    override fun getBufferedPositionUs(): Long =
        if (selected) preparedChild?.bufferedPositionUs ?: positionUs else C.TIME_END_OF_SOURCE

    override fun getNextLoadPositionUs(): Long =
        if (selected) preparedChild?.nextLoadPositionUs ?: positionUs else C.TIME_END_OF_SOURCE

    override fun continueLoading(loadingInfo: LoadingInfo): Boolean =
        selected && (child?.continueLoading(loadingInfo) ?: false)

    override fun isLoading(): Boolean = selected && (child?.isLoading ?: false)

    override fun reevaluateBuffer(positionUs: Long) {
        preparedChild?.reevaluateBuffer(positionUs)
    }

    override fun setEndPositionUs(endPositionUs: Long): Long {
        this.endPositionUs = endPositionUs
        return preparedChild?.setEndPositionUs(endPositionUs) ?: endPositionUs
    }

    private inner class DeferredSubtitleStream : SampleStream {
        override fun isReady(): Boolean = childStreams[0]?.isReady ?: false

        override fun maybeThrowError() {
            maybeThrowPrepareError()
            childStreams[0]?.maybeThrowError()
        }

        override fun readData(holder: FormatHolder, buffer: DecoderInputBuffer, readFlags: Int): Int =
            childStreams[0]?.readData(holder, buffer, readFlags) ?: C.RESULT_NOTHING_READ

        override fun skipData(positionUs: Long): Int = childStreams[0]?.skipData(positionUs) ?: 0
    }
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
