package org.moonfin.nativevideo.subtitle

import androidx.media3.common.text.Cue
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

class PrimaryVerticalOffsetTest {
    private fun at(line: Float, anchor: Int): Cue = Cue.Builder()
        .setText("Primary")
        .setLine(line, Cue.LINE_TYPE_FRACTION)
        .setLineAnchor(anchor)
        .setPosition(0.3f)
        .setPositionAnchor(Cue.ANCHOR_TYPE_START)
        .build()

    private fun adjusted(cue: Cue, offset: Float) =
        offsetPrimaryCue(cue, offset, lineHeightFraction = 0.06f)

    @Test
    fun topAndBottomMoveInwardRegardlessOfSubtitleFormat() {
        // Coordinates can come from WebVTT or SRT positioning instructions.
        for ((position, anchor, expected) in listOf(
            Triple(0.08f, Cue.ANCHOR_TYPE_START, 0.12f),
            Triple(0.20f, Cue.ANCHOR_TYPE_START, 0.24f),
            Triple(0.92f, Cue.ANCHOR_TYPE_END, 0.88f),
            Triple(0.80f, Cue.ANCHOR_TYPE_START, 0.76f),
            Triple(0.10f, Cue.ANCHOR_TYPE_END, 0.14f),
        )) {
            val primary = at(position, anchor)
            val shifted = adjusted(primary, 0.04f)
            assertEquals(expected, shifted.line, 0.0001f)
            assertEquals(primary.lineAnchor, shifted.lineAnchor)
            assertEquals(primary.position, shifted.position, 0.0001f)
            assertEquals(primary.positionAnchor, shifted.positionAnchor)
            // Recompute from the original cue, not from a previous adjustment.
            assertEquals(expected, adjusted(primary, 0.04f).line, 0.0001f)
            assertSame(primary, adjusted(primary, 0f))
        }
    }

    @Test
    fun middleAndAutomaticCuesKeepTheirExistingPositioning() {
        val automatic = Cue.Builder().setText("Automatic").build()
        val middle = at(0.5f, Cue.ANCHOR_TYPE_MIDDLE)
        assertSame(automatic, adjusted(automatic, 0.04f))
        assertSame(middle, adjusted(middle, 0.04f))
    }

    @Test
    fun negativeAndPositiveWebvttLineNumbersShiftInwardAndRestoreAtZero() {
        val bottom = Cue.Builder().setText("Bottom")
            .setLine(-1f, Cue.LINE_TYPE_NUMBER).build()
        val top = Cue.Builder().setText("Top")
            .setLine(0f, Cue.LINE_TYPE_NUMBER).build()
        val shiftedBottom = adjusted(bottom, 0.04f)
        val shiftedTop = adjusted(top, 0.04f)
        assertEquals(Cue.LINE_TYPE_FRACTION, shiftedBottom.lineType)
        assertEquals(Cue.LINE_TYPE_FRACTION, shiftedTop.lineType)
        assertEquals(0.96f, shiftedBottom.line, 0.0001f)
        assertEquals(0.04f, shiftedTop.line, 0.0001f)
        assertEquals(Cue.ANCHOR_TYPE_END, shiftedBottom.lineAnchor)
        assertEquals(Cue.ANCHOR_TYPE_START, shiftedTop.lineAnchor)
        assertSame(bottom, adjusted(bottom, 0f))
        assertSame(top, adjusted(top, 0f))
    }
}
