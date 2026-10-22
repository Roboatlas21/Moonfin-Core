package org.moonfin.nativevideo.subtitle

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.Timeline
import androidx.media3.common.text.CueGroup
import androidx.media3.common.util.Clock
import androidx.media3.datasource.ByteArrayDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import androidx.media3.exoplayer.LoadingInfo
import androidx.media3.exoplayer.RendererConfiguration
import androidx.media3.exoplayer.analytics.PlayerId
import androidx.media3.exoplayer.source.MediaPeriod
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.MergingMediaSource
import androidx.media3.exoplayer.source.SampleStream
import androidx.media3.exoplayer.source.SilenceMediaSource
import androidx.media3.exoplayer.text.TextOutput
import androidx.media3.exoplayer.text.TextRenderer
import androidx.media3.exoplayer.trackselection.ExoTrackSelection
import androidx.media3.exoplayer.trackselection.FixedTrackSelection
import androidx.media3.exoplayer.upstream.DefaultAllocator
import androidx.media3.extractor.text.DefaultSubtitleParserFactory
import java.io.FileNotFoundException
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** Exercises the real lazy source, parsers, merged period and second TextRenderer. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], manifest = Config.NONE)
class SidecarSecondarySubtitleTest {
    private class File(val mime: String, val text: String, slow: Boolean = false, val missing: Boolean = false) {
        val gate = CountDownLatch(if (slow) 1 else 0)
        val opens = AtomicInteger()
        val closes = AtomicInteger()
    }

    private val srt = "1\n00:00:10,000 --> 00:00:20,000\nPrimary\n\n"
    private val vtt = "WEBVTT\n\n00:10.000 --> 00:20.000\nSecondary\n\n"

    private fun await(condition: () -> Boolean) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
        while (!condition()) {
            check(System.nanoTime() < deadline) { "Timed out waiting for Media3" }
            shadowOf(android.os.Looper.getMainLooper()).idle()
            Thread.sleep(5)
        }
        shadowOf(android.os.Looper.getMainLooper()).idle()
    }

    private inner class Playback(val files: List<File>) : AutoCloseable {
        val errors = ArrayList<IOException>()
        private val offsets = files.mapIndexed { index, file ->
            val factory = DataSource.Factory {
                object : DataSource {
                    val data = ByteArrayDataSource(file.text.toByteArray())
                    override fun addTransferListener(listener: TransferListener) = data.addTransferListener(listener)
                    override fun getUri(): Uri? = data.uri
                    override fun open(spec: DataSpec): Long {
                        file.opens.incrementAndGet()
                        try {
                            file.gate.await()
                        } catch (e: InterruptedException) {
                            throw IOException(e)
                        }
                        if (file.missing) throw FileNotFoundException("subtitle missing")
                        return data.open(spec)
                    }
                    override fun read(buffer: ByteArray, offset: Int, length: Int) = data.read(buffer, offset, length)
                    override fun close() {
                        file.closes.incrementAndGet()
                        data.close()
                    }
                }
            }
            TimeOffsetMediaSource(
                SidecarSourceFactory.create(
                    MediaItem.SubtitleConfiguration.Builder(Uri.parse("https://test/$index"))
                        .setId("file-$index").setMimeType(file.mime).build(),
                    factory, DefaultSubtitleParserFactory(),
                ), 2_000_000L, -500_000L, onSecondaryError = { errors.add(it) },
            )
        }
        private val source = MergingMediaSource(SilenceMediaSource(60_000_000L), *offsets.toTypedArray())
        private var timeline: Timeline? = null
        private val caller = MediaSource.MediaSourceCaller { _, value -> timeline = value }
        val period: MediaPeriod
        val periodId: MediaSource.MediaPeriodId
        val streams = arrayOfNulls<SampleStream>(3)
        private val renderers = ArrayList<TextRenderer>()
        var positionUs = 9_750_000L
        var selectedPositionUs = C.TIME_UNSET

        init {
            source.prepareSource(caller, null, PlayerId.UNSET)
            await { timeline != null }
            periodId = MediaSource.MediaPeriodId(timeline!!.getUidOfPeriod(0))
            period = source.createPeriod(periodId, DefaultAllocator(true, C.DEFAULT_BUFFER_SEGMENT_SIZE), positionUs)
            var prepared = false
            period.prepare(object : MediaPeriod.Callback {
                override fun onPrepared(mediaPeriod: MediaPeriod) { prepared = true }
                override fun onContinueLoadingRequested(source: MediaPeriod) {}
            }, positionUs)
            await { prepared }
        }

        fun select(primary: Int?, secondary: Int?) {
            fun track(file: Int?) = file?.let { FixedTrackSelection(period.trackGroups[it + 1], 0) }
            val selections = arrayOf<ExoTrackSelection?>(FixedTrackSelection(period.trackGroups[0], 0), track(primary), track(secondary))
            selectedPositionUs = period.selectTracks(selections, BooleanArray(3) { true }, streams, BooleanArray(3), positionUs)
            load()
        }

        fun load() { period.continueLoading(LoadingInfo.Builder().setPlaybackPositionUs(positionUs).build()) }
        fun loaded(file: Int) = !offsets[file].isSubtitleLoading

        fun renderer(slot: Int, file: Int, onText: (String) -> Unit): TextRenderer {
            val renderer = TextRenderer(object : TextOutput {
                override fun onCues(cueGroup: CueGroup) { onText(cueGroup.cues.joinToString("\n") { it.text.toString() }) }
            }, null)
            renderer.init(slot, PlayerId.UNSET, Clock.DEFAULT)
            renderer.enable(RendererConfiguration.DEFAULT, arrayOf(period.trackGroups[file + 1].getFormat(0)),
                streams[slot]!!, positionUs, false, true, positionUs, 0L, periodId)
            renderer.start()
            renderers.add(renderer)
            return renderer
        }

        override fun close() {
            renderers.forEach { it.stop(); it.disable(); it.reset() }
            files.forEach { it.gate.countDown() }
            source.releasePeriod(period)
            source.releaseSource(caller)
        }
    }

    @Test
    fun `native SRT and VTT render with independent delays and retain primary on secondary off`() {
        val files = listOf(File(MimeTypes.APPLICATION_SUBRIP, srt), File(MimeTypes.TEXT_VTT, vtt))
        Playback(files).use { playback ->
            assertTrue(files.all { it.opens.get() == 0 }) // Declaring files does not download them.
            playback.select(0, 1)
            await { playback.load(); playback.loaded(0) && playback.loaded(1) }
            assertEquals(playback.positionUs, playback.selectedPositionUs)
            var primaryText = ""
            var secondaryText = ""
            val primary = playback.renderer(1, 0) { primaryText = it }
            val secondary = playback.renderer(2, 1) { secondaryText = it }
            repeat(3) { primary.render(9_750_000L, 0); secondary.render(9_750_000L, 0) }
            assertEquals("", primaryText)
            assertEquals("Secondary", secondaryText)
            repeat(3) { primary.render(12_500_000L, 0); secondary.render(12_500_000L, 0) }
            assertEquals("Primary", primaryText)
            assertEquals("Secondary", secondaryText)
            repeat(3) { primary.render(19_750_000L, 0); secondary.render(19_750_000L, 0) }
            assertEquals("Primary", primaryText)
            assertEquals("", secondaryText)
            val primaryStream = playback.streams[1]
            playback.select(0, null)
            assertSame(primaryStream, playback.streams[1])
            assertNull(playback.streams[2])
        }
    }

    @Test
    fun `slow secondary is cancellable and a different language loads without waiting`() {
        val slow = File(MimeTypes.APPLICATION_SUBRIP, srt, slow = true)
        val fast = File(MimeTypes.TEXT_VTT, vtt)
        Playback(listOf(slow, fast)).use { playback ->
            playback.select(null, 0)
            await { slow.opens.get() == 1 }
            assertTrue(playback.streams[0]!!.isReady)
            assertEquals(C.TIME_END_OF_SOURCE, playback.period.nextLoadPositionUs)
            val audio = playback.streams[0]
            playback.select(null, 1)
            await { slow.closes.get() > 0 && playback.loaded(1) }
            assertSame(audio, playback.streams[0])
            assertEquals(playback.positionUs, playback.selectedPositionUs)
            var text = ""
            val renderer = playback.renderer(2, 1) { text = it }
            repeat(3) { renderer.render(playback.positionUs, 0) }
            assertEquals("Secondary", text)
            assertEquals(C.TIME_UNSET, playback.period.readDiscontinuity())
        }
    }

    @Test
    fun `a file arriving after playback advances uses the current position without a reprepare`() {
        val slow = File(MimeTypes.TEXT_VTT, vtt, slow = true)
        Playback(listOf(slow)).use { playback ->
            playback.select(null, 0)
            await { slow.opens.get() == 1 }
            val audio = playback.streams[0]
            playback.positionUs = 15_000_000L
            slow.gate.countDown()
            await { playback.load(); playback.loaded(0) }
            var text = ""
            val renderer = playback.renderer(2, 0) { text = it }
            repeat(3) { renderer.render(playback.positionUs, 0) }
            assertEquals("Secondary", text)
            assertSame(audio, playback.streams[0])
            assertEquals(C.TIME_UNSET, playback.period.readDiscontinuity())
        }
    }

    @Test
    fun `missing secondary reports an error without failing the content stream`() {
        val missing = File(MimeTypes.TEXT_VTT, vtt, missing = true)
        Playback(listOf(missing)).use { playback ->
            playback.select(null, 0)
            val secondary = playback.streams[2]!!
            await { playback.load(); secondary.maybeThrowError(); playback.errors.isNotEmpty() }
            assertTrue(playback.errors.single() is FileNotFoundException)
            playback.streams[0]!!.maybeThrowError()
            assertTrue(playback.streams[0]!!.isReady)
            assertTrue(playback.loaded(0))
            assertEquals(C.TIME_UNSET, playback.period.readDiscontinuity())
        }
    }
}
