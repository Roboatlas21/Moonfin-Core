package org.moonfin.nativevideo.subtitle

import androidx.media3.common.util.TimestampAdjuster
import org.junit.Assert.assertEquals
import org.junit.Test

class HlsTimestampOffsetObserverTest {

    private val reported = mutableListOf<Long>()
    private val observer = HlsTimestampOffsetObserver(
        delegate = { _, _, _, _, _, _, _ -> throw UnsupportedOperationException() },
        onOffsetUs = { reported.add(it) },
    )

    @Test
    fun `nothing is reported before the adjuster settles`() {
        val adjuster = TimestampAdjuster(10_000_000L)
        observer.reportIfSettled(adjuster)
        assertEquals(emptyList<Long>(), reported)
    }

    @Test
    fun `the settled offset is reported once`() {
        val adjuster = TimestampAdjuster(10_000_000L)
        adjuster.adjustSampleTimestamp(8_000_000L)
        observer.reportIfSettled(adjuster)
        observer.reportIfSettled(adjuster)
        adjuster.adjustSampleTimestamp(8_500_000L)
        observer.reportIfSettled(adjuster)
        assertEquals(listOf(2_000_000L), reported)
    }

    @Test
    fun `a reset that settles on a new value is reported`() {
        val adjuster = TimestampAdjuster(10_000_000L)
        adjuster.adjustSampleTimestamp(8_000_000L)
        observer.reportIfSettled(adjuster)
        adjuster.reset(30_000_000L)
        observer.reportIfSettled(adjuster)
        adjuster.adjustSampleTimestamp(29_000_000L)
        observer.reportIfSettled(adjuster)
        assertEquals(listOf(2_000_000L, 1_000_000L), reported)
    }

    @Test
    fun `a reset that settles on the same value is reported again`() {
        val adjuster = TimestampAdjuster(10_000_000L)
        adjuster.adjustSampleTimestamp(8_000_000L)
        observer.reportIfSettled(adjuster)
        adjuster.reset(30_000_000L)
        observer.reportIfSettled(adjuster)
        adjuster.adjustSampleTimestamp(28_000_000L)
        observer.reportIfSettled(adjuster)
        assertEquals(listOf(2_000_000L, 2_000_000L), reported)
    }

    @Test
    fun `MPEG TS padding does not advance external subtitles`() {
        val observer = observerWithTransportPadding()
        val adjuster = TimestampAdjuster(0L)
        adjuster.adjustSampleTimestamp(10_000_000L)
        observer.reportIfSettled(adjuster)
        assertEquals(listOf(0L), reported)
    }

    @Test
    fun `starting at a resume point preserves the preroll correction`() {
        val observer = observerWithTransportPadding()
        val adjuster = TimestampAdjuster(600_000_000L)
        // Source audio starts 1.5 seconds before the requested segment.
        adjuster.adjustSampleTimestamp(598_500_000L + 10_000_000L)
        observer.reportIfSettled(adjuster)
        assertEquals(listOf(1_500_000L), reported)

        adjuster.reset(900_000_000L)
        adjuster.adjustSampleTimestamp(900_000_000L + 10_000_000L)
        observer.reportIfSettled(adjuster)
        assertEquals(listOf(1_500_000L, 0L), reported)
    }

    @Test
    fun `a real negative correction is preserved after removing padding`() {
        val observer = observerWithTransportPadding()
        val adjuster = TimestampAdjuster(600_000_000L)
        adjuster.adjustSampleTimestamp(600_250_000L + 10_000_000L)
        observer.reportIfSettled(adjuster)
        assertEquals(listOf(-250_000L), reported)
    }

    private fun observerWithTransportPadding() = HlsTimestampOffsetObserver(
        delegate = { _, _, _, _, _, _, _ -> throw UnsupportedOperationException() },
        onOffsetUs = { reported.add(it) },
        transportOffsetUs = 10_000_000L,
    )
}
